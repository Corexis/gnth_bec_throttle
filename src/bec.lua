--[[
    BEC Throttle - Entangler/IO Node batching state machine
    Author: corexis

    License: free to use, modify and redistribute.
    If you copy or share this script (as-is or modified), please keep
    a credit to the original author (corexis).

    Tested on: GTNH 2.9.0 daily 600
--]]

local component = require("component")
local sides = require("sides")
local term = require("term")
local computer = require("computer")

local VERSION = "1.0.0"
local VERSION_URL = "https://raw.githubusercontent.com/Corexis/gnth_bec_throttle/refs/heads/main/src/VERSION"

-- === AUTO-DISCOVERY ===
-- Find machines among all gt_machine components by internal name
local ENTANGLER_NAME = "multi.bec.generator"
local IONODE_NAME = "multi.bec.io-node"

local function findMachine(targetName)
    for address in component.list("gt_machine") do
        local proxy = component.proxy(address)
        local ok, name = pcall(function() return proxy.getName() end)
        if ok and name == targetName then
            return proxy, address
        end
    end
    return nil
end

local entangler, entanglerAddr = findMachine(ENTANGLER_NAME)
local io_node, ioNodeAddr = findMachine(IONODE_NAME)

if not entangler then
    error("Entangler not found (" .. ENTANGLER_NAME .. "). Check component.list('gt_machine').")
end
if not io_node then
    error("IO Node not found (" .. IONODE_NAME .. "). Check component.list('gt_machine').")
end

local rs = component.redstone
local gpu = component.gpu

-- IO Node is fed by a Stocking Input Bus - setWorkAllowed() is a soft pause
-- (finishes current recipe first) and the bus keeps pushing items in the
-- meantime, which overflows/voids. Must use the Controller Hatch's
-- "Pause Immediately" mode via redstone instead. Entangler is fine via OC.
local SIDE_IONODE_PAUSE = sides.up      -- Controller Hatch on IO Node (Pause Immediately)
local SIDE_GATE = sides.south           -- gate feeding raw materials into the Entangler
local SIDE_CONDENSATE_SENSOR = sides.west -- input: signal = there is liquid/condensate in the BEC

local MAX_LOG_LINES = 10
local STATUS_HEIGHT = 6

local logLines = {}

-- states: "ASSEMBLING" (IO Node is running) or "BATCHING" (Entangler is preparing a batch)
local state = "ASSEMBLING"

local lastIoProgress = 0
local lastEntanglerProgress = 0
local lastEntanglerMax = 0
local gateOpen = nil

local entanglerEverStarted = false
local entanglerIdleTicks = 0
local IDLE_CONFIRM_TICKS = 20  -- ~1 second at os.sleep(0.05); how many consecutive ticks of 0/0
-- are needed to consider the batch actually finished
local pendingAssembleAt = nil
local FLUSH_DELAY = 2  -- extra seconds to let the liquid move from the BEC Hatch into
-- the network after the confirmed idle state

local stuckSince = nil
local WATCHDOG_TIMEOUT = 20  -- seconds both machines can idle without condensate before
-- forcing a transition into BATCHING (only checked while gate is closed)

local function timestamp()
    return os.date("%H:%M:%S")
end

local function addLog(msg)
    table.insert(logLines, 1, string.format("[%s] %s", timestamp(), msg))
    while #logLines > MAX_LOG_LINES do
        table.remove(logLines)
    end
end

-- === UPDATE CHECK ===
-- Non-blocking best-effort check against VERSION_URL. Never fatal: no
-- internet card, no connectivity, or a slow/dead server just gets logged
-- and the script carries on running the version it already has.
local UPDATE_CHECK_TIMEOUT = 5

local function checkForUpdate()
    if not component.isAvailable("internet") then
        addLog("update check: no internet card, skipped")
        return
    end

    local internet = component.internet
    local ok, handle = pcall(internet.request, VERSION_URL)
    if not ok or not handle then
        addLog("update check: request failed")
        return
    end

    local deadline = computer.uptime() + UPDATE_CHECK_TIMEOUT
    local connected = false
    while computer.uptime() < deadline do
        local success, reason = handle.finishConnect()
        if success then
            connected = true
            break
        end
        if reason then
            handle.close()
            addLog("update check: " .. tostring(reason))
            return
        end
        os.sleep(0.05)
    end

    if not connected then
        handle.close()
        addLog("update check: timeout")
        return
    end

    local code = handle.response()
    if code ~= 200 then
        handle.close()
        addLog(string.format("update check: HTTP %s", tostring(code)))
        return
    end

    local chunks = {}
    while true do
        local chunk = handle.read()
        if not chunk then break end
        table.insert(chunks, chunk)
    end
    handle.close()

    local latest = table.concat(chunks):gsub("^%s+", ""):gsub("%s+$", "")
    if latest == "" then
        addLog("update check: empty VERSION response")
    elseif latest == VERSION then
        addLog(string.format("up to date (v%s)", VERSION))
    else
        addLog(string.format("UPDATE AVAILABLE: v%s -> v%s, run install_bec", VERSION, latest))
    end
end

addLog(string.format("found entangler @ %s", entanglerAddr:sub(1, 8)))
addLog(string.format("found io_node @ %s", ioNodeAddr:sub(1, 8)))

-- === OUTPUT CONTROL ===

local function setMachineWork(proxy, label, allowed)
    local ok, err = pcall(function() return proxy.setWorkAllowed(allowed) end)
    if not ok then
        addLog(string.format("ERR %s.setWorkAllowed(%s): %s", label, tostring(allowed), tostring(err)))
    end
end

local function setIoNodePaused(paused)
    -- Controller Hatch, Pause Immediately mode: redstone signal = paused
    rs.setOutput(SIDE_IONODE_PAUSE, paused and 15 or 0)
end

local function setGate(open)
    if open ~= gateOpen then
        gateOpen = open
        if open then
            rs.setOutput(SIDE_GATE, 0)
            addLog("gate open")
        else
            rs.setOutput(SIDE_GATE, 15)
            addLog("gate closed")
        end
    end
end

local function enterBatching()
    state = "BATCHING"
    setIoNodePaused(true)
    setMachineWork(entangler, "entangler", true)
    setGate(true)
    entanglerEverStarted = false
    entanglerIdleTicks = 0
    pendingAssembleAt = nil
    addLog("BATCHING | IO stop, Ent run, gate open")
end

local function enterAssembling()
    state = "ASSEMBLING"
    setMachineWork(entangler, "entangler", false)
    setIoNodePaused(false)
    setGate(false)
    addLog("ASSEMBLING | Ent stop, IO run, gate closed")
end

local function hasCondensate()
    -- assumption: signal present = liquid present. If it's the other way around,
    -- change > 0 to == 0
    return rs.getInput(SIDE_CONDENSATE_SENSOR) > 0
end

local function drawStatus(ioProgress, ioMax, entProgress, entMax)
    local w, h = gpu.getResolution()

    term.setCursor(1, 1)
    gpu.fill(1, 1, w, STATUS_HEIGHT, " ")

    term.setCursor(1, 1)
    print(string.format("=== BEC THROTTLE v%s ===", VERSION))
    term.setCursor(1, 2)
    print(string.format("IO   %d / %d", ioProgress, ioMax))
    term.setCursor(1, 3)
    print(string.format("Ent  %d / %d", entProgress, entMax))
    term.setCursor(1, 4)
    print(string.format("mode: %s", state))
    term.setCursor(1, 5)
    local watchdogText = "-"
    if stuckSince then
        watchdogText = string.format("%ds", math.floor(computer.uptime() - stuckSince))
    end
    print(string.format("Ent: %s  IO stop: %s  Gate: %s  watchdog: %s",
            state == "BATCHING" and "run" or "stop",
            state == "BATCHING" and "yes" or "no",
            gateOpen and "open" or "closed",
            watchdogText))
    term.setCursor(1, 6)
    print(string.rep("-", w))

    for i, line in ipairs(logLines) do
        term.setCursor(1, STATUS_HEIGHT + i)
        gpu.fill(1, STATUS_HEIGHT + i, w, 1, " ")
        print(line)
    end
end

-- === INITIALIZATION ===
term.clear()
addLog(string.format("start (v%s)", VERSION))
pcall(checkForUpdate)

local okIo, initIoProgress = pcall(function() return io_node.getWorkProgress() end)
lastIoProgress = okIo and initIoProgress or 0

local okEnt, initEntProgress = pcall(function() return entangler.getWorkProgress() end)
lastEntanglerProgress = okEnt and initEntProgress or 0

-- if the IO Node has no active recipe, start with a batch
if lastIoProgress == 0 then
    enterBatching()
else
    state = "ASSEMBLING"
    setMachineWork(entangler, "entangler", false)
    setIoNodePaused(false)
    addLog(string.format("start: IO already running (%d)", lastIoProgress))
end

-- === MAIN LOOP ===
while true do
    local okIoP, ioProgress = pcall(function() return io_node.getWorkProgress() end)
    local okIoM, ioMax = pcall(function() return io_node.getWorkMaxProgress() end)
    local okEntP, entProgress = pcall(function() return entangler.getWorkProgress() end)
    local okEntM, entMax = pcall(function() return entangler.getWorkMaxProgress() end)

    if not (okIoP and okEntP) then
        addLog("read error")
        os.sleep(1)
    else
        -- watchdog only guards against a missed transition into BATCHING
        -- (gate closed, both machines idle, no condensate). Not needed while
        -- gate is open.
        local bothIdle = okIoM and okEntM and ioMax == 0 and entMax == 0
        local noStock = not hasCondensate()
        local gateClosed = (gateOpen == false)

        if gateClosed and bothIdle and noStock then
            if not stuckSince then
                stuckSince = computer.uptime()
            elseif computer.uptime() - stuckSince >= WATCHDOG_TIMEOUT then
                addLog("watchdog: stuck, forcing batch")
                enterBatching()
                stuckSince = nil
            end
        else
            stuckSince = nil
        end

        if state == "ASSEMBLING" then
            if ioProgress < lastIoProgress then
                if hasCondensate() then
                    addLog("new recipe, stock ok")
                else
                    enterBatching()
                end
            end

        elseif state == "BATCHING" then
            -- Entangler picked up the batch and started working - close the gate,
            -- no more raw material is needed
            if okEntM and entMax > 0 and gateOpen then
                setGate(false)
            end

            if okEntM and entMax > 0 then
                entanglerEverStarted = true
                entanglerIdleTicks = 0
                if pendingAssembleAt then
                    pendingAssembleAt = nil
                    addLog("Ent active again, cancelling transition")
                end
            elseif okEntM and entMax == 0 and entanglerEverStarted then
                entanglerIdleTicks = entanglerIdleTicks + 1

                if entanglerIdleTicks >= IDLE_CONFIRM_TICKS and not pendingAssembleAt then
                    pendingAssembleAt = computer.uptime() + FLUSH_DELAY
                    addLog(string.format("idle confirmed, flush wait %ds", FLUSH_DELAY))
                end

                if pendingAssembleAt and computer.uptime() >= pendingAssembleAt then
                    addLog("batch done (confirmed)")
                    enterAssembling()
                end
            end
        end

        drawStatus(ioProgress, okIoM and ioMax or 0, entProgress, okEntM and entMax or 0)
        lastIoProgress = ioProgress
        lastEntanglerProgress = entProgress
        if okEntM then
            lastEntanglerMax = entMax
        end
    end

    os.sleep(0.05)
end