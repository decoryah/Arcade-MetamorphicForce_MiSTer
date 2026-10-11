-- Where does the boot spend its time?  Samples the 68000's PC at read taps on the program ROM, so the
-- sample points follow instruction fetches rather than a clock, and writes, per frame, the 256-byte
-- code pages that got samples (with counts).  Used to find the boot's software delay / check loops.
--
--   PCLAST=<frames>  last frame (default 1500)
--   PCOUT=<file>     output (default pc_sample.txt in the cwd)
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local KEEP = {}
_G.PCKEEP = KEEP
local LAST = tonumber(os.getenv("PCLAST") or "1500")
local out = assert(io.open(os.getenv("PCOUT") or "pc_sample.txt", "w"))
local frame, cnt = 0, 0
local pages = {}
KEEP.tap = sp:install_read_tap(0x000000, 0x1fffff, "pcs", function(off, data, mask)
  cnt = cnt + 1
  if cnt % 256 == 0 then
    local pc = cpu.state["CURPC"].value
    local p = pc >> 8
    pages[p] = (pages[p] or 0) + 1
  end
end)
KEEP.notif = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local keys = {}
  for p in pairs(pages) do keys[#keys + 1] = p end
  table.sort(keys)
  local t = {}
  for _, p in ipairs(keys) do t[#t + 1] = string.format("%04x00:%d", p, pages[p]) end
  out:write(frame, " ", cnt, " ", table.concat(t, " "), "\n")
  pages = {}
  if frame >= LAST then out:close(); mach:exit() end
end)
