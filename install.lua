--[[
    BEC Throttle Installer
    Author: corexis

    Downloads bec_throttle.lua from GitHub and installs it to /home.
    Requires an Internet Card in the computer/server rack.

    Usage (one-liner on a fresh OC computer):
      wget -f https://raw.githubusercontent.com/Corexis/gnth_bec_throttle/refs/heads/main/install.lua /home/install_bec.lua && install_bec
--]]

local component = require("component")
local shell = require("shell")
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

if filesystem.exists(INSTALL_PATH) then
    local backupPath = INSTALL_PATH .. ".bak"
    print(string.format("[installer] Existing file found, backing up to %s", backupPath))
    filesystem.remove(backupPath)
    filesystem.copy(INSTALL_PATH, backupPath)
end

print("[installer] Downloading bec_throttle.lua ...")
local ok, exitCode = shell.execute(string.format('wget -f "%s" "%s"', SCRIPT_URL, INSTALL_PATH))

if not ok or not filesystem.exists(INSTALL_PATH) then
    fail("Download failed. Check the Internet Card allowlist and SCRIPT_URL.")
end

print("[installer] Done. Script installed to " .. INSTALL_PATH)
print("[installer] Before running it, edit these in the file to match your setup:")
print("  - ENTANGLER_NAME / IONODE_NAME (must match your machine names)")
print("  - SIDE_IONODE_PAUSE / SIDE_ENTANGLER / SIDE_GATE / SIDE_CONDENSATE_SENSOR")
print("[installer] Run it with:  bec_throttle")
