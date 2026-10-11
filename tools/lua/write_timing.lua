-- Where in the frame (MAME vpos, buckets of 8 lines) does the game write each video-related region?
--   WT_OUT=<file>  WT_FROM=<first frame counted, default 4300>  WT_FRAMES=<last frame>
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local out  = assert(io.open(os.getenv("WT_OUT") or "write_timing.txt", "w"))
local FROM = tonumber(os.getenv("WT_FROM") or "4300")
local LAST = tonumber(os.getenv("WT_FRAMES") or "6200")
local f = 0
local KEEP = {}
_G.WTKEEP = KEEP

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
  { "sprram",  0x210000, 0x210fff },
  { "otherram",0x211000, 0x21ffff },
  { "workram", 0x200000, 0x20ffff },
  { "vram",    0x300000, 0x303fff },
  { "palette", 0x330000, 0x331fff },
  { "k56reg",  0x270000, 0x27003f },
  { "k56regb", 0x26c000, 0x26c007 },
  { "k55",     0x258000, 0x2580ff },
  { "k38",     0x254000, 0x25401f },
  { "k47",     0x244010, 0x24401f },
  { "k46",     0x240000, 0x240007 },
  { "k50ram",  0x24c000, 0x24ffff },
  { "k50reg",  0x250000, 0x25000f },
  { "k321",    0x268000, 0x26801f },
  { "sndirq",  0x264000, 0x264001 },
}
local hist = {}
for _, r in ipairs(regions) do
  local name = r[1]
  hist[name] = {}
  for b = 0, 32 do hist[name][b] = 0 end
  KEEP[name] = sp:install_write_tap(r[2], r[3], name, function(off, data, mask)
    if f >= FROM then
      local b = vpos() // 8
      hist[name][b] = hist[name][b] + 1
    end
  end)
end

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f >= LAST then
    out:write("buckets are MAME vpos/8 (bucket 1 = lines 8-15; the picture is lines 15-238; vblank 239+)\n")
    out:write(string.format("%-9s", "region"))
    for b = 0, 32 do out:write(string.format("%6d", b * 8)) end
    out:write("\n")
    for _, r in ipairs(regions) do
      out:write(string.format("%-9s", r[1]))
      for b = 0, 32 do out:write(string.format("%6d", hist[r[1]][b])) end
      out:write("\n")
    end
    out:close()
    mach:exit()
  end
end)
