-- Log every change of the K056832's layer configuration (flip, tile mode, scroll modes, page spans/starts) with the
-- frame number, to find which configurations a run of the game uses and so which the tilemap renderer must handle.
-- Run next to dump_state.lua's scripted inputs:
--   SCHEDULE=play ENERGY=1 SKIPBOOT=1 RUSCRIPT=<this file> CFGLOG=<out file> DUMPFRAMES=<last frame> mame metamrph -autoboot_script dump_state.lua ...
-- One line per change: frame, r0 (flip), r4 (tile modes), r5 (scroll modes), then per layer A..D: start y/x, span h/w,
-- and whether the page span is one the RTL flags (3 pages) -- plus the X flip bit.
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local out  = assert(io.open(os.getenv("CFGLOG") or "cfg_log.txt", "w"))
local regs = {}
for i = 0, 31 do regs[i] = 0 end
local screen = mach.screens[":screen"]
local last = ""
local keep = {}
keep.t = sp:install_write_tap(0x270000, 0x27003f, "cfglog", function(off, data, mask)
  local r = (off - 0x270000) // 2
  local old = regs[r]
  if mask == 0xffff then regs[r] = data & 0xffff
  elseif mask == 0xff00 then regs[r] = (old & 0x00ff) | (data & 0xff00)
  else regs[r] = (old & 0xff00) | (data & 0x00ff) end
end)
_G.CFGLOG_KEEP = keep
keep.n = emu.add_machine_frame_notifier(function()
  local s = string.format("r0=%04x r4=%04x r5=%04x", regs[0], regs[4] & 0xff, regs[5] & 0xff)
  local flags = {}
  for l = 0, 3 do
    local y, h = (regs[8 + l] & 0x18) >> 3, regs[8 + l] & 3
    local x, w = (regs[12 + l] & 0x18) >> 3, regs[12 + l] & 3
    s = s .. string.format(" %s:y%d h%d x%d w%d sm%d", string.char(65 + l), y, h, x, w, (regs[5] >> (l * 2)) & 3)
    if h == 2 or w == 2 then flags[#flags + 1] = "SPAN3" .. string.char(65 + l) end
  end
  if (regs[0] & 0x10) ~= 0 then flags[#flags + 1] = "XFLIP" end
  if #flags > 0 then s = s .. " !" .. table.concat(flags, ",") end
  if s ~= last then
    out:write(string.format("%d %s\n", screen:frame_number(), s)); out:flush()
    last = s
  end
end)
