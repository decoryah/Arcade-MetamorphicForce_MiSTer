-- Freeze frames of Metamorphic Force and write everything the frame bench needs,
-- alongside MAME's own snapshot of that same frame. After the Monster Maulers core's
-- tools/lua/dump_state.lua (the two games share the board family's register layout;
-- this game's map is MAME's metamrph_map).
--
--   DUMPFRAMES=<f,f,f...>  frames to capture
--   DUMPDIR=<dir>          output directory (state_<frame>.txt and snap_<frame>.png go there)
--   FORCE_ENABLE=<hex>     override the K055555 layer-enable register, so a single
--                          layer can be isolated for diffing
--   SCHEDULE=survey|play|none   the scripted inputs (default none: attract mode only)
--
-- Write-only chip registers are shadowed through write taps. VRAM is 16 pages of
-- 4 KB behind a bank register: after the snapshot is taken (and only then, because
-- it perturbs the chip) the bank is cycled and all of it read, then the registers
-- the cycling touched are put back.
--
-- The K053250's line RAM is double buffered by its DMA (the falling edge of bit 1 of
-- its register 4, at most once a frame): the picture is drawn from the buffer the
-- LAST-BUT-ONE DMA filled (k053250_device::draw uses m_buffer[m_page] after dma()
-- toggled the page). The tap below keeps both buffers and the page.

local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local KEEP = {}
_G.DUMPKEEP = KEEP

local function newregs(n) local t = {} for i = 0, n-1 do t[i] = 0 end return t end

local k56_regs  = newregs(32)    -- VACSET   0x270000, word
local k56_regsb = newregs(4)     -- VSCCS    0x26c000, word
local k46_regs  = newregs(8)     -- K053246  0x240000, byte pairs
local k47_regs  = newregs(8)     -- K055673  0x244010, word
local k55_regs  = newregs(48)    -- K055555  0x258000, byte in low or high half
local k38_regs  = newregs(16)    -- K054338  0x254000, word
local k50_regs  = newregs(8)     -- K053250  0x250000, byte in the low half of a word

local FORCE_ENABLE = os.getenv("FORCE_ENABLE")
if FORCE_ENABLE then FORCE_ENABLE = tonumber(FORCE_ENABLE, 16) end

local function word_tap(base, size, regs, name)
  return sp:install_write_tap(base, base + size - 1, name, function(off, data, mask)
    local r = (off - base) // 2
    local old = regs[r]
    if mask == 0xffff then regs[r] = data & 0xffff
    elseif mask == 0xff00 then regs[r] = (old & 0x00ff) | (data & 0xff00)
    else regs[r] = (old & 0xff00) | (data & 0x00ff) end
  end)
end

KEEP.t1 = word_tap(0x270000, 0x40, k56_regs,  "k56")
KEEP.t2 = word_tap(0x26c000, 0x08, k56_regsb, "k56b")
KEEP.t3 = sp:install_write_tap(0x240000, 0x240007, "k46", function(off, data, mask)
  local w = (off - 0x240000) // 2
  if (mask & 0xff00) ~= 0 then k46_regs[w*2] = (data >> 8) & 0xff end
  if (mask & 0x00ff) ~= 0 then k46_regs[w*2+1] = data & 0xff end end)
KEEP.t4 = word_tap(0x244010, 0x10, k47_regs, "k47")
KEEP.t5 = sp:install_write_tap(0x258000, 0x2580ff, "k55", function(off, data, mask)
  -- K055555_word_w: mem_mask 0x00ff -> low byte, else high byte
  local r = (off - 0x258000) // 2
  local v
  if mask == 0x00ff then v = data & 0xff else v = (data >> 8) & 0xff end
  if r < 48 then k55_regs[r] = v end
  -- layer isolation: rewrite the ENABLE register (45) on its way to the chip
  if FORCE_ENABLE and r == 45 then
    if mask == 0x00ff then return (data & 0xff00) | FORCE_ENABLE
    else return (data & 0x00ff) | (FORCE_ENABLE << 8) end
  end
end)
KEEP.t6 = word_tap(0x254000, 0x20, k38_regs, "k38")

-- NOMIX=1: every sprite loses its mix code (attribute word 6, bits 9:8) as the game writes it, to test the
-- sprite path without per-sprite alpha blending
-- (from frame NOMIX_FROM, default 2000: the boot's RAM test reads sprite RAM back and would fail)
local NOMIX_ON = os.getenv("NOMIX") == "1"
local NOMIX_FROM = tonumber(os.getenv("NOMIX_FROM") or "2000")
local nomix_frame = 0
if NOMIX_ON then
  KEEP.nomix = sp:install_write_tap(0x210000, 0x210fff, "nomix", function(off, data, mask)
    local w = ((off - 0x210000) // 2)
    if nomix_frame >= NOMIX_FROM and w % 8 == 6 then
      return data & ~(tonumber(os.getenv("NOMIX_MASK") or "0x0300"))
    end
    -- ONLY_ENT=<n>[,<n>...]: every other sprite is switched off (word 0 bit 15 cleared as it is written)
    local only = os.getenv("ONLY_ENT")
    if only and nomix_frame >= NOMIX_FROM and w % 8 == 0 then
      local keep = false
      for n in string.gmatch(only, "%d+") do if tonumber(n) == w // 8 then keep = true end end
      if not keep then return data & 0x7fff end
    end
  end)
end

-- K053250: registers (low byte of a word each), and the DMA that fills its double buffer
local lvc_buf  = { {}, {} }
local lvc_page = 0
local lvc_last = -1
for b = 1, 2 do for i = 0, 0x7ff do lvc_buf[b][i] = 0 end end
local screen = mach.screens[":screen"]
KEEP.t7 = sp:install_write_tap(0x250000, 0x25000f, "k50", function(off, data, mask)
  if (mask & 0x00ff) == 0 then return end
  local r = (off - 0x250000) // 2
  if r == 4 and (data & 2) == 0 and (k50_regs[4] & 2) ~= 0 then
    -- dma(1): once per frame
    local fr = screen:frame_number()
    if fr ~= lvc_last then
      lvc_last = fr
      local dst = lvc_buf[lvc_page + 1]
      for i = 0, 0x7ff do dst[i] = sp:read_u16(0x24c000 + i * 2) end
      lvc_page = lvc_page ~ 1
    end
  end
  k50_regs[r] = data & 0xff
end)

-- The patch points are found by their code, so every set is handled alike.
local function find_bytes(r, pat, lo, hi)
  for a = lo, hi - #pat do
    local ok = true
    for i, b in ipairs(pat) do if r:read_u8(a + i - 1) ~= b then ok = false break end end
    if ok then return a end
  end
  return nil
end

-- SKIPBOOT=1: the same three program patches as the system bench's SKIPBOOT (sim/tb_mf.cpp), cutting ~800
-- frames of power-on RAM tests and two splash delays so a whole-machine run reaches the game in ~500
-- frames. Applied by read taps on the program ROM (the ROM itself is untouched).
--   1. the power-on test chain (POST): its first instructions after the three register writes become
--      jmp <the continuation the POST ends with> (lea $10e4,a1 / jmp $4bd6)
--   2. the "KONAMI" splash's outer delay count 0x100 -> 1
--   3. the second splash's outer delay count 0x80 -> 1
local function patch_word(addr, val, name)
  return sp:install_read_tap(addr, addr + 1, name, function(off, data, mask) return val end)
end
if os.getenv("SKIPBOOT") == "1" then
  local post = find_bytes(sp, {0x13,0xfc,0x00,0x00,0x00,0x25,0x80,0x5b, 0x13,0xfc,0x00,0xfe,0x00,0x26,0x80,0x0d,
                               0x13,0xfc,0x00,0x00,0x00,0x26,0x40,0x00, 0x72,0x00}, 0x1000, 0x10000)
  local cont = find_bytes(sp, {0x43,0xf9,0x00,0x00,0x10,0xe4, 0x4e,0xf9,0x00,0x00,0x4b,0xd6}, 0x1000, 0x2000)
  local d1 = find_bytes(sp, {0x3e,0x3c,0x01,0x00, 0x3c,0x3c,0x20,0x00, 0x51,0xce,0xff,0xfe}, 0x1000, 0x8000)
  local d2 = find_bytes(sp, {0x30,0x3c,0x00,0x80, 0x32,0x3c,0x30,0x00, 0x51,0xc9,0xff,0xfe}, 0x1000, 0x8000)
  assert(post and cont and d1 and d2, "SKIPBOOT: patch points not found")
  local j = post + 24
  KEEP.sk1 = patch_word(j,     0x4ef9, "sk1")
  KEEP.sk2 = patch_word(j + 2, 0x0000, "sk2")
  KEEP.sk3 = patch_word(j + 4, cont,   "sk3")
  KEEP.sk4 = patch_word(d1 + 2, 0x0001, "sk4")
  KEEP.sk5 = patch_word(d2 + 2, 0x0001, "sk5")
  print(string.format("SKIPBOOT: POST %06x -> jmp %06x, delays at %06x %06x", post, cont, d1, d2))
end

local FRAMES = {}
for n in string.gmatch(os.getenv("DUMPFRAMES") or "1800", "%d+") do FRAMES[tonumber(n)] = true end
local LAST = 0; for n in pairs(FRAMES) do if n > LAST then LAST = n end end
local DIR  = os.getenv("DUMPDIR") or "."
local f = 0

local function hexrun(read, n)
  local t = {}
  for i = 1, n do t[i] = string.format("%04x", read(i-1)) end
  return table.concat(t, " ")
end

local function dump()
  mach.video:snapshot()

  local out = assert(io.open(DIR .. "/state_" .. tostring(f) .. ".txt", "w"))
  out:write("# metamorphic force frozen state, frame ", tostring(f), "\n")
  out:write("FRAME ", tostring(f), "\n")

  local function regline(name, t, n)
    local a = {}
    for i = 0, n-1 do a[i+1] = string.format("%04x", t[i]) end
    out:write(name, " ", table.concat(a, " "), "\n")
  end
  regline("K56REGS",  k56_regs, 32)
  regline("K56REGSB", k56_regsb, 4)
  regline("K46REGS",  k46_regs, 8)
  regline("K47REGS",  k47_regs, 8)
  regline("K55REGS",  k55_regs, 48)
  regline("K38REGS",  k38_regs, 16)
  regline("K50REGS",  k50_regs, 8)

  -- the K053250 line RAM the picture is drawn from: m_buffer[m_page]
  local drawbuf = lvc_buf[lvc_page + 1]
  out:write("K50LINES ", hexrun(function(i) return drawbuf[i] end, 0x800), "\n")
  out:write("K50PAGE ", tostring(lvc_page), "\n")

  -- palette: 2048 entries, two 16-bit words each
  out:write("PALETTE ", hexrun(function(i) return sp:read_u16(0x330000 + i*2) end, 4096), "\n")

  -- sprite RAM: the K053247's 2048 words, direct at 0x210000
  out:write("SPRITERAM ", hexrun(function(w) return sp:read_u16(0x210000 + w * 2) end, 2048), "\n")

  -- VRAM: 16 pages of 0x1000 words behind the bank register at 0x270032. Done last:
  -- it perturbs the chip; the registers it touches are put back.
  local saved_r0  = k56_regs[0]
  local saved_r19 = k56_regs[0x19]
  out:write("CURPAGE ", hexrun(function(i) return sp:read_u16(0x300000 + i*2) end, 4096), "\n")
  for page = 0, 15 do
    local col, row = page & 3, (page >> 2) & 3
    sp:write_u16(0x270000, saved_r0 & ~0x0002)      -- internal linescroll
    sp:write_u16(0x270032, (row << 3) | col)
    out:write(string.format("VRAM %d ", page),
              hexrun(function(i) return sp:read_u16(0x300000 + i*2) end, 4096), "\n")
  end
  sp:write_u16(0x270000, saved_r0)
  sp:write_u16(0x270032, saved_r19)
  out:close()
  print("DUMPED frame " .. tostring(f))
  io.stdout:flush()
end

-- SURVEY=<every>: instead of full dumps, log a line every <every> frames to DUMPDIR/survey.csv
--   frame, K053250 control byte, active K053250 lines, K055555 enables, sub1 priority, sprites, K053246 reg 5
local SURVEY = tonumber(os.getenv("SURVEY") or "0")
local survey_f
if SURVEY > 0 then
  survey_f = assert(io.open(DIR .. "/survey.csv", "w"))
  survey_f:write("frame,k50ctl,k50regs,lines_active,en,pri_sub1,sprites,k46r5,k56r3,k56r5\n")
end
local function survey()
  local buf = lvc_buf[lvc_page + 1]
  local act = 0
  for e = 0, 0x1ff do
    local c, o = buf[e * 4], buf[e * 4 + 1]
    if c ~= 0xffff and not ((c & 0xff) == 0 and o == 0) then act = act + 1 end
  end
  local spr = 0
  for e = 0, 255 do if (sp:read_u16(0x210000 + e * 16) & 0x8000) ~= 0 then spr = spr + 1 end end
  survey_f:write(string.format("%d,%02x,%02x%02x%02x%02x%02x%02x%02x%02x,%d,%02x,%02x,%d,%02x,%04x,%04x\n", f, k50_regs[4],
    k50_regs[0], k50_regs[1], k50_regs[2], k50_regs[3], k50_regs[4], k50_regs[5], k50_regs[6], k50_regs[7],
    act, k55_regs[45], k55_regs[16], spr, k46_regs[5], k56_regs[3], k56_regs[5]))
  survey_f:flush()
end

-- scripted inputs
local p13 = mach.ioport.ports[":P1_P3"]
local in0 = mach.ioport.ports[":IN0"]
local coin, start, b1, b2, b3, rt, up, dn, lf
if in0 then coin = in0.fields["Coin 1"] end
if p13 then
  start = p13.fields["1 Player Start"]
  b1, b2, b3 = p13.fields["P1 Button 1"], p13.fields["P1 Button 2"], p13.fields["P1 Button 3"]
  rt, up, dn, lf = p13.fields["P1 Right"], p13.fields["P1 Up"], p13.fields["P1 Down"], p13.fields["P1 Left"]
end
local SCHED = os.getenv("SCHEDULE") or "none"
-- "Continuous Energy Increment: Yes" (IN1 bit 7 low) keeps the scripted player alive through the stages
if os.getenv("ENERGY") == "1" then
  local in1 = mach.ioport.ports[":IN1"]
  if in1 and in1.fields["Continuous Energy Increment"] then in1.fields["Continuous Energy Increment"]:set_value(0) end
end

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = f + 1
  nomix_frame = f
  local n = f
  if SCHED == "survey" and coin then
    coin:set_value((n > 200 and (n % 120) < 8) and 1 or 0)
    start:set_value((n > 260 and (n % 90) < 8 and (n % 120) >= 8) and 1 or 0)
    if n > 500 then
      b1:set_value((n % 11 < 4) and 1 or 0)
      b2:set_value((n % 29 < 3) and 1 or 0)
      b3:set_value((n % 43 < 3) and 1 or 0)
      rt:set_value((n % 97 < 40) and 1 or 0)
      lf:set_value((n % 131 > 100) and 1 or 0)
      up:set_value((n % 53 < 20) and 1 or 0)
      dn:set_value((n % 71 > 60) and 1 or 0)
    end
  end
  if SCHED == "play" and coin then
    coin:set_value((n > 200 and (n % 240) < 8) and 1 or 0)
    start:set_value((n > 260 and (n % 90) < 8 and (n % 240) >= 8) and 1 or 0)
    if n > 500 then
      b1:set_value((n % 7 < 3) and 1 or 0)
      b2:set_value((n % 61 < 2) and 1 or 0)
      b3:set_value((n % 83 < 2) and 1 or 0)
      rt:set_value((n % 160 < 130) and 1 or 0)
      lf:set_value(((n + 40) % 400 < 12) and 1 or 0)
      up:set_value((n % 97 < 18) and 1 or 0)
      dn:set_value((n % 131 > 112) and 1 or 0)
    end
  end
  if SURVEY > 0 and f % SURVEY == 0 then survey() end
  if FRAMES[f] then dump() end
  if f >= LAST then mach:exit() end
end)

-- RUSCRIPT=<file>: run another probe in the same MAME session (the scripted inputs above keep playing)
if os.getenv("RUSCRIPT") then dofile(os.getenv("RUSCRIPT")) end
