-- Log every change of the brightness path with the frame number: the K055555's V_BRI register (index 42: a two-bit code per tile
-- layer, 0 = full brightness 0xff, 1..3 = the K054338's registers 11 / 12) and the K054338's registers 11 and 12 (the three
-- brightness levels). Run next to dump_state.lua's scripted inputs:
--   SCHEDULE=play ENERGY=1 SKIPBOOT=1 RUSCRIPT=<this file> BRILOG=<out file> DUMPFRAMES=<last frame> mame metamrph -autoboot_script dump_state.lua ...
-- Also counts the frames each code was in force for at least one layer.
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local out  = assert(io.open(os.getenv("BRILOG") or "bri_log.txt", "w"))
local screen = mach.screens[":screen"]
local vbri, r11, r12 = 0, 0, 0
local last = ""
local keep = {}
keep.k55 = sp:install_write_tap(0x258000, 0x2580ff, "brilog55", function(off, data, mask)
  local r = (off - 0x258000) // 2
  if r == 42 then
    if mask == 0x00ff then vbri = data & 0xff else vbri = (data >> 8) & 0xff end
  end
end)
local function word_tap(base, size, name, f)
  return sp:install_write_tap(base, base + size - 1, name, function(off, data, mask)
    local r = (off - base) // 2
    f(r, data, mask)
  end)
end
local regs = {}
for i = 0, 15 do regs[i] = 0 end
keep.k38 = word_tap(0x254000, 0x20, "brilog38", function(r, data, mask)
  local old = regs[r]
  if mask == 0xffff then regs[r] = data & 0xffff
  elseif mask == 0xff00 then regs[r] = (old & 0x00ff) | (data & 0xff00)
  else regs[r] = (old & 0xff00) | (data & 0x00ff) end
end)
_G.BRILOG_KEEP = keep
keep.n = emu.add_machine_frame_notifier(function()
  local s = string.format("vbri=%02x bri11=%04x bri12=%04x", vbri, regs[11], regs[12])
  if s ~= last then
    out:write(string.format("%d %s\n", screen:frame_number(), s)); out:flush()
    last = s
  end
end)
