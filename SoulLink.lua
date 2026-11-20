-- Soul Link for Pokémon Black/White and Black 2/White 2 (BizHawk).
-- See other players in your game and play linked Nuzlockes together.
-- Load this script in BizHawk (Tools > Lua Console) with one of those games running,
-- or start everything with "Soul Link.exe".
--
-- This wrapper runs lib/main.lua and, if anything goes wrong, writes the error to
-- runtime/error.txt and shows it on screen instead of silently stopping.

local ROOT = (debug.getinfo(1, "S").source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$")) or "."
_G.SOULLINK_ROOT = ROOT

-- make a folder (and the ones above it) from inside BizHawk. (os.execute("mkdir") would start a
-- hidden cmd.exe, which antivirus "behaviour" checks treat as suspicious.)
function _G.SOULLINK_MKDIR(path)
  return pcall(function() luanet.import_type("System.IO.Directory").CreateDirectory((path:gsub("/", "\\"))) end)
end

local ok, err = xpcall(function() dofile(ROOT .. "/lib/main.lua") end, debug.traceback)
if not ok then
  SOULLINK_MKDIR(ROOT .. "/runtime")
  local f = io.open(ROOT .. "/runtime/error.txt", "w")
  if f then f:write(os.date() .. "\n" .. tostring(err) .. "\n"); f:close() end
  print("Soul Link stopped because of an error:\n" .. tostring(err))
  while true do
    gui.clearGraphics()
    gui.pixelText(2, 2, "Soul Link error - see runtime/error.txt", 0xFFFF6060, 0xC0000000)
    emu.frameadvance()
  end
end
