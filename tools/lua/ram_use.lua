-- Which pages of a RAM range does the game touch?  Counts reads and writes per 1 KB block of RANGE
-- (default 0x210000-0x21ffff, the plain RAM behind the sprite RAM), over a scripted-play run.
--   RUFRAMES=<n>   frames to run (default 6000)       RUOUT=<file>   report (default ram_use.txt)
--   RULO / RUHI    range (hex)                        SKIPBOOT=1     as tools/lua/dump_state.lua
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local KEEP = {}
_G.RUKEEP = KEEP
local N   = tonumber(os.getenv("RUFRAMES") or "6000")
local LO  = tonumber(os.getenv("RULO") or "210000", 16)
local HI  = tonumber(os.getenv("RUHI") or "21ffff", 16)
local OUT = os.getenv("RUOUT") or "ram_use.txt"
local rd, wr, first = {}, {}, {}
local f = 0
local function blk(off) return (off // 1024) end
KEEP.r = sp:install_read_tap(LO, HI, "ru_r", function(off, data, mask)
  local b = blk(off - LO); rd[b] = (rd[b] or 0) + 1
  if not first[b] then first[b] = string.format("r f%d pc %06x", f, cpu.state["CURPC"].value) end
end)
KEEP.w = sp:install_write_tap(LO, HI, "ru_w", function(off, data, mask)
  local b = blk(off - LO); wr[b] = (wr[b] or 0) + 1
  if not first[b] then first[b] = string.format("w f%d pc %06x", f, cpu.state["CURPC"].value) end
end)
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f >= N then
    local o = assert(io.open(OUT, "w"))
    for b = 0, (HI - LO) // 1024 do
      if rd[b] or wr[b] then
        o:write(string.format("%06x  reads %9d  writes %9d  first %s\n", LO + b * 1024, rd[b] or 0, wr[b] or 0, first[b] or ""))
      end
    end
    o:close()
    mach:exit()
  end
end)
