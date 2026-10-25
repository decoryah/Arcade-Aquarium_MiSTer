-- MAME's Z80 (audiocpu) trace from its second instruction to frame TOF, with each instruction's total cycles. tracelog writes to
-- the debugger's visible CPU's trace: a breakpoint on the audiocpu's second instruction makes it the visible one
local mach = manager.machine
local dbg = mach.debugger
local scr = mach.screens[":screen"]
local TOF = tonumber(os.getenv("TOF") or "2")
local OUT = os.getenv("OUT") or "ztrace.log"
dbg:command('trace ' .. OUT .. ',audiocpu,noloop,{tracelog "%d ",totalcycles}')
dbg:command('bpset 3:audiocpu')
emu.register_frame_done(function()
  if scr:frame_number() >= TOF then dbg:command('trace off,audiocpu'); mach:exit() end
end)
