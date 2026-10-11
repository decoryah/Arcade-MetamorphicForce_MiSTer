-- Every CPU write to the video-related ranges during chosen frames, with the frame and MAME's vpos (the line of the
-- frame's raster): what the game does to the picture while it is being scanned out.
--   WL_FROM=<first frame>  WL_FRAMES=<count, default 2>  WL_OUT=<file>  WL_MAXVPOS=<only vpos below this, default 264>
--   (use with tools/lua/dump_state.lua's scripted inputs through RUSCRIPT if the game must be played into a state)
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local out  = assert(io.open(os.getenv("WL_OUT") or "write_log.txt", "w"))
local FROM = tonumber(os.getenv("WL_FROM") or "2900")
local N    = tonumber(os.getenv("WL_FRAMES") or "2")
local MAXV = tonumber(os.getenv("WL_MAXVPOS") or "264")
local f = 0
local KEEP = {}
_G.WLKEEP = KEEP

local function vpos()
  local period = scr.frame_period
  if period > 1 then period = period / 1e18 end
  local u = scr:time_until_pos(0, 0)
  if type(u) ~= "number" then u = u:as_double() end
  local since = period - u
  if since < 0 then since = 0 end
  return math.floor(since / (period / 264.0))
end

local regions = {
  { "sprram", 0x210000, 0x210fff }, { "k46", 0x240000, 0x240007 }, { "k47", 0x244010, 0x24401f },
  { "k50ram", 0x24c000, 0x24ffff }, { "k50reg", 0x250000, 0x25000f }, { "k38", 0x254000, 0x25401f },
  { "k55", 0x258000, 0x2580ff }, { "k252", 0x260000, 0x26001f }, { "k56b", 0x26c000, 0x26c007 },
  { "k56", 0x270000, 0x27003f }, { "vram", 0x300000, 0x303fff }, { "pal", 0x330000, 0x331fff },
}
for _, r in ipairs(regions) do
  KEEP[r[1]] = sp:install_write_tap(r[2], r[3], r[1], function(off, data, mask)
    if f >= FROM and f < FROM + N then
      local v = vpos()
      if v < MAXV then
        out:write(string.format("f%d v%3d %-7s %06x %04x/%04x pc %06x\n", f, v, r[1], off, data & 0xffff, mask & 0xffff, cpu.state["CURPC"].value))
      end
    end
  end)
end
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f >= FROM + N then out:close(); mach:exit() end
end)
