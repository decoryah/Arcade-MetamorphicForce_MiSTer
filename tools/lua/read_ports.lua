-- Idle values of the 68000-visible input words, and every input field's bit position.
local mach = manager.machine
local sp = mach.devices[":maincpu"].spaces["program"]
local n = 0
local KEEP = {}
_G.RPKEEP = KEEP
KEEP.notif = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n == 60 then
    for _, a in ipairs({0x274000, 0x274002, 0x278000, 0x278002}) do
      print(string.format("PORTWORD %06x = %04x", a, sp:read_u16(a)))
    end
    for _, name in ipairs({":IN0", ":IN1", ":P1_P3", ":P2_P4"}) do
      local p = mach.ioport.ports[name]
      if p then
        for fname, fld in pairs(p.fields) do
          print(string.format("FIELD %s '%s' mask=%04x defvalue=%04x", name, fname, fld.mask, fld.defvalue))
        end
      end
    end
    mach:exit()
  end
end)
