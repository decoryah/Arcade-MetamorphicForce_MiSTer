-- The first N non-sequential PC changes of the 68000 (calls, jumps, taken branches farther than a few
-- bytes), from read taps on the program ROM: the shape of the boot sequence.
--   PCN=<n>      number of jumps to log (default 400)
--   PCOUT=<file> output (default pc_jumps.txt)
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local KEEP = {}
_G.PJKEEP = KEEP
local N = tonumber(os.getenv("PCN") or "400")
local out = assert(io.open(os.getenv("PCOUT") or "pc_jumps.txt", "w"))
local last, n, frame = -1, 0, 0
KEEP.tap = sp:install_read_tap(0x000000, 0x1fffff, "pj", function(off, data, mask)
  local pc = cpu.state["CURPC"].value
  if last >= 0 and (pc < last or pc > last + 10) then
    n = n + 1
    out:write(string.format("%d: %06x -> %06x\n", frame, last, pc))
    if n >= N then out:close(); mach:exit() end
  end
  last = pc
end)
KEEP.notif = emu.add_machine_frame_notifier(function() frame = frame + 1 end)
