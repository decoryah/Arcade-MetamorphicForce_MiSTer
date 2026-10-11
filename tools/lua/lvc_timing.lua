-- When in the frame does the game write the K053250's control register, trigger its DMA, write
-- sprite RAM / the K053246's registers?  Logs (frame, vpos, hpos) of those events.
--   LVC_OUT=<file>   LVC_FRAMES=<last frame, default 3000>
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local out  = assert(io.open(os.getenv("LVC_OUT") or "lvc_timing.txt", "w"))
local LAST = tonumber(os.getenv("LVC_FRAMES") or "3000")
local f = 0
local k50_4 = 0
local KEEP = {}
_G.LVCKEEP = KEEP

-- this MAME's Lua has no vpos()/hpos(): derive the position from the time to the next (0, 0)
local function pos()
  local period = scr.frame_period
  if period > 1 then period = period / 1e18 end       -- attoseconds
  local until00 = scr:time_until_pos(0, 0)         -- seconds, a plain number in this build
  if type(until00) ~= "number" then until00 = until00:as_double() end
  local since = period - until00
  if since < 0 then since = 0 end
  local line = period / 264.0
  local v = math.floor(since / line)
  local h = math.floor((since - v * line) / (line / 384.0))
  return v, h
end

local function log(what, extra)
  local v, h = pos()
  out:write(string.format("%d %s vpos=%d hpos=%d %s\n", scr:frame_number(), what, v, h, extra or ""))
end

KEEP.t1 = sp:install_write_tap(0x250008, 0x250009, "k50r4", function(off, data, mask)
  if (mask & 0x00ff) ~= 0 then
    local new = data & 0xff
    local edge = ((new & 2) == 0 and (k50_4 & 2) ~= 0)
    log(edge and "K50_DMA_TRIGGER" or "K50_R4", string.format("data=%02x old=%02x", new, k50_4))
    k50_4 = new
  end
end)
KEEP.t2 = sp:install_write_tap(0x240000, 0x240007, "k46", function(off, data, mask)
  if off == 0x240004 then log("K46_R4R5", string.format("data=%04x mask=%04x", data & 0xffff, mask)) end
end)
KEEP.t3 = sp:install_write_tap(0x264000, 0x264001, "sndirq", function(off, data, mask) end)

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = f + 1
  log("FRAME_NOTIFIER", "")
  if f >= LAST then out:close(); mach:exit() end
end)
