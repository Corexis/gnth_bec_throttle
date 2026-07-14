--[[
    BEC Throttle Uninstaller
    Author: corexis

    Removes bec_throttle.lua, its backup, and the autostart entry from
    /home/.shrc. This file stays in /home after running so it can be
    reused later if you reinstall.

    Usage:
      uninstall_bec
--]]

local filesystem = require("filesystem")

local INSTALL_PATH = "/home/bec_throttle.lua"
local BACKUP_PATH = INSTALL_PATH .. ".bak"
local SHRC_PATH = "/home/.shrc"
local AUTOSTART_CMD = "bec_throttle"

local function removeFile(path, label)
    if filesystem.exists(path) then
        filesystem.remove(path)
        print(string.format("[uninstaller] Removed %s (%s)", label, path))
    else
        print(string.format("[uninstaller] %s not found, skipping (%s)", label, path))
    end
end

local function removeAutostart()
    if not filesystem.exists(SHRC_PATH) then
        return
    end

    local rf = io.open(SHRC_PATH, "r")
    if not rf then
        print("[uninstaller] WARNING: could not read " .. SHRC_PATH)
        return
    end
    local content = rf:read("*a") or ""
    rf:close()

    local kept = {}
    local removedAny = false
    for line in (content .. "\n"):gmatch("(.-)\n") do
        if line:match("^%s*(.-)%s*$") == AUTOSTART_CMD then
            removedAny = true
        else
            table.insert(kept, line)
        end
    end

    if not removedAny then
        print("[uninstaller] No autostart entry found in " .. SHRC_PATH)
        return
    end

    -- trim trailing blank lines left behind by the removal
    while #kept > 0 and kept[#kept] == "" do
        table.remove(kept)
    end

    local wf, openErr = io.open(SHRC_PATH, "w")
    if not wf then
        print("[uninstaller] WARNING: could not rewrite " .. SHRC_PATH .. ": " .. tostring(openErr))
        return
    end
    if #kept > 0 then
        wf:write(table.concat(kept, "\n") .. "\n")
    end
    wf:close()
    print("[uninstaller] Removed autostart entry from " .. SHRC_PATH)
end

removeFile(INSTALL_PATH, "bec_throttle.lua")
removeFile(BACKUP_PATH, "backup file")
removeAutostart()

print("[uninstaller] Done. BEC Throttle has been removed.")
