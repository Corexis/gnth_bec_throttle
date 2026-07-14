--[[
    BEC Throttle Installer
    Author: corexis

    Downloads bec_throttle.lua from GitHub, installs it to /home, and
    registers it to autostart via /home/.shrc.
    Requires an Internet Card in the computer/server rack.

    Usage (one-liner on a fresh OC computer):
      wget -f https://raw.githubusercontent.com/Corexis/gnth_bec_throttle/refs/heads/main/install.lua /home/install_bec.lua && install_bec
--]]

local component = require("component")
local filesystem = require("filesystem")

-- EDIT THIS: raw URL of bec_throttle.lua in your repo
local SCRIPT_URL = "https://raw.githubusercontent.com/Corexis/gnth_bec_throttle/refs/heads/main/src/bec.lua"
local INSTALL_PATH = "/home/bec_throttle.lua"

local function fail(msg)
    io.stderr:write("[installer] " .. msg .. "\n")
    os.exit(1)
end

if not component.isAvailable("internet") then
    fail("No Internet Card found. Install one and rerun this script.")
end

local internet = component.internet

-- Direct HTTP GET via the internet card, with an explicit response-code
-- check. shell.execute("wget ...") can report success even when the HTTP
-- request itself failed, and filesystem.exists() alone can't tell a fresh
-- download from a stale file left over from a previous run.
local function httpGet(url)
    local handle, err = internet.request(url)
    if not handle then
        return nil, tostring(err)
    end

    while true do
        local ok, reason = handle.finishConnect()
        if ok then break end
        if reason then
            handle.close()
            return nil, tostring(reason)
        end
        os.sleep(0.05)
    end

    local code, message = handle.response()
    if code ~= 200 then
        handle.close()
        return nil, string.format("HTTP %s %s", tostring(code), tostring(message))
    end

    local chunks = {}
    while true do
        local chunk = handle.read()
        if not chunk then break end
        table.insert(chunks, chunk)
    end
    handle.close()

    local body = table.concat(chunks)
    if #body == 0 then
        return nil, "empty response body"
    end
    return body
end

if filesystem.exists(INSTALL_PATH) then
    local backupPath = INSTALL_PATH .. ".bak"
    print(string.format("[installer] Existing file found, backing up to %s", backupPath))
    filesystem.remove(backupPath)
    filesystem.copy(INSTALL_PATH, backupPath)
    filesystem.remove(INSTALL_PATH)
end

print("[installer] Downloading bec_throttle.lua ...")
local body, err = httpGet(SCRIPT_URL)
if not body then
    fail("Download failed: " .. err .. ". Check the Internet Card allowlist and SCRIPT_URL.")
end

local f, openErr = io.open(INSTALL_PATH, "w")
if not f then
    fail("Could not write " .. INSTALL_PATH .. ": " .. tostring(openErr))
end
f:write(body)
f:close()

if not filesystem.exists(INSTALL_PATH) then
    fail("Write verification failed - file missing after save.")
end

print("[installer] Done. Script installed to " .. INSTALL_PATH)

-- === AUTOSTART ===
-- OpenOS sources /home/.shrc every time an interactive shell starts, which
-- happens automatically on boot. Appending the command here makes the
-- computer launch straight into bec_throttle after every reboot.
local AUTOSTART_CMD = "bec_throttle"
local SHRC_PATH = "/home/.shrc"

local function setupAutostart()
    local existing = ""
    if filesystem.exists(SHRC_PATH) then
        local rf = io.open(SHRC_PATH, "r")
        if rf then
            existing = rf:read("*a") or ""
            rf:close()
        end
    end

    if existing:find(AUTOSTART_CMD, 1, true) then
        print("[installer] Autostart already configured in " .. SHRC_PATH)
        return
    end

    local wf, openErr = io.open(SHRC_PATH, "a")
    if not wf then
        print("[installer] WARNING: could not update " .. SHRC_PATH .. ": " .. tostring(openErr))
        print("[installer] Add this line manually: " .. AUTOSTART_CMD)
        return
    end
    wf:write("\n" .. AUTOSTART_CMD .. "\n")
    wf:close()
    print("[installer] Autostart configured: added '" .. AUTOSTART_CMD .. "' to " .. SHRC_PATH)
end

setupAutostart()

print("[installer] Before running it, edit these in the file to match your setup:")
print("  - ENTANGLER_NAME / IONODE_NAME (must match your machine names)")
print("  - SIDE_IONODE_PAUSE / SIDE_ENTANGLER / SIDE_GATE / SIDE_CONDENSATE_SENSOR")
print("[installer] The computer will now auto-start bec_throttle on every reboot.")
print("[installer] Run it manually with:  bec_throttle")
