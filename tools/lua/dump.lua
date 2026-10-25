-- Aquarium: MAME's state at frame_done (the start of the vertical blank, where MAME has just drawn the frame), as the system bench
-- writes the core's (sim/tb_top.sv): ram_<f>.bin = the work RAM (ff0000-ffffff), the mid, bak and txt VRAM, the palette, the sprite
-- RAM (its 4 KB of bytes), the six scroll words, in the 68000's byte order; snap_<f>.png = MAME's snapshot of the frame.
--   DUMPFRAMES=<f,f,...> or DUMPFROM / DUMPTO / DUMPEVERY;  DUMPDIR=<dir>;  NOSNAP=1 (no snapshots);  LAST=<f> (the frame to stop at)
--   SCHED=play|test       the scripted inputs, the same as the system bench's (sim/tb_aquarium.cpp sched_in())
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local FR, LAST = {}, 0
for n in string.gmatch(os.getenv("DUMPFRAMES") or "", "%d+") do FR[tonumber(n)] = true; if tonumber(n) > LAST then LAST = tonumber(n) end end
local FROM, TO, EVERY = tonumber(os.getenv("DUMPFROM") or "-1"), tonumber(os.getenv("DUMPTO") or "-1"), tonumber(os.getenv("DUMPEVERY") or "1")
if TO > LAST then LAST = TO end
if os.getenv("LAST") then LAST = tonumber(os.getenv("LAST")) end
local DIR = os.getenv("DUMPDIR") or "."
local SCHED = os.getenv("SCHED")
if SCHED == "" then SCHED = nil end
local NOSNAP = os.getenv("NOSNAP") == "1"

local function field(port, name)
  local p = mach.ioport.ports[port]
  for n, f in pairs(p.fields) do if n == name then return f end end
end
local F = {
  coin1 = field(":SYSTEM", "Coin 1"), start1 = field(":INPUTS", "1 Player Start"),
  test = field(":SYSTEM", "Service Mode"),
  b1 = field(":INPUTS", "P1 Button 1"), b2 = field(":INPUTS", "P1 Button 2"),
  left = field(":INPUTS", "P1 Left"), right = field(":INPUTS", "P1 Right"), down = field(":INPUTS", "P1 Down"),
  up = field(":INPUTS", "P1 Up"),
}

-- the schedule (tb_aquarium.cpp's sched_in)
local function sched(f)
  local p = {}
  if SCHED == "test" then
    p.test = true                                         -- held from power-on (the game reads it at its start)
    -- the menu: button 1 at 300 (COLOR CHECK), button 2 at 400 (back), down at 450 and 470 (OBJ CHECK), button 1 at 500
    p.b1 = (f >= 300 and f < 306) or (f >= 500 and f < 506)
    p.b2 = (f >= 400 and f < 406)
    p.down = (f >= 450 and f < 456) or (f >= 470 and f < 476)
    return p
  end
  p.coin1 = (f >= 300 and f < 306)
  p.start1 = (f >= 400 and f < 406)
  if SCHED == "play" and f >= 600 then
    p.b1    = ((f // 10) % 6 == 0)
    p.b2    = ((f // 10) % 6 == 3)
    p.left  = ((f // 45) % 4 == 1)
    p.right = ((f // 45) % 4 == 3)
    p.down  = ((f // 30) % 5 == 4)
    p.up    = ((f // 30) % 5 == 2)
  end
  return p
end

local scroll = mach.memory.shares[":scroll"]
local function dump(f)
  local t = {}
  for a = 0xff0000, 0xffffff do t[#t + 1] = string.char(sp:read_u8(a)) end
  for a = 0xc00000, 0xc03fff do t[#t + 1] = string.char(sp:read_u8(a)) end
  for a = 0xd00000, 0xd00fff do t[#t + 1] = string.char(sp:read_u8(a)) end
  for i = 0, 0xfff do t[#t + 1] = string.char(sp:read_u8(0xc80001 + 2 * i)) end
  for i = 0, 5 do
    local w = scroll:read_u16(2 * i)
    t[#t + 1] = string.char((w >> 8) & 0xff, w & 0xff)
  end
  local fh = io.open(string.format("%s/ram_%d.bin", DIR, f), "wb"); fh:write(table.concat(t)); fh:close()
  if not NOSNAP then scr:snapshot(string.format("%s/snap_%d.png", DIR, f)) end
end

emu.register_frame_done(function()
  local f = scr:frame_number()
  if SCHED then
    local p = sched(f)
    for n, fld in pairs(F) do if fld then fld:set_value(p[n] and 1 or 0) end end
  end
  if FR[f] or (FROM >= 0 and f >= FROM and f <= TO and (f - FROM) % EVERY == 0) then dump(f) end
  if f >= LAST then mach:exit() end
end)
