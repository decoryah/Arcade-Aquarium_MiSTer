-- MAME's 68000 trace from time 0 (FROMF / TOF: frames), with each instruction's total cycles
local mach = manager.machine
local dbg = mach.debugger
local scr = mach.screens[":screen"]
local FROMF = tonumber(os.getenv("FROMF") or "0")
local TOF = tonumber(os.getenv("TOF") or "2")
local OUT = os.getenv("OUT") or "trace.log"
if FROMF == 0 then dbg:command('trace ' .. OUT .. ',maincpu,noloop,{tracelog "%d ",totalcycles}') end
emu.register_frame_done(function()
  local f = scr:frame_number()
  if FROMF > 0 and f == FROMF - 1 then dbg:command('trace ' .. OUT .. ',maincpu,noloop,{tracelog "%d ",totalcycles}') end
  if f >= TOF then dbg:command('trace off,maincpu'); mach:exit() end
end)
