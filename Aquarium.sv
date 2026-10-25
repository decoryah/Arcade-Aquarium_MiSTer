//============================================================================
//
//  Aquarium (Excellent System, 1996) for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/excellent/aquarium.cpp, with excellent_spr.cpp and the devices it uses).
//  The 68000 is Jorge Cwik's fx68k (modules/fx68k), the Z80 Guy Hutchison's tv80 (modules/cpu-tv80), the YM2151 Jose Tejada's
//  jt51 (modules/jt51); the platform layer (the SDRAM controller, the fast load, CRT Adjust, the video path) follows the owner's
//  Rabbit and Hexion cores.
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

wire  [1:0] ar = status[122:121];

`include "build_id.v"
localparam CONF_STR = {
	"Aquarium;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[54:53],Video Timing,270 lines (CRT),263 lines (CRT 240p),263 lines (RT4K DV1);",
	"P1,CRT Adjust;",
	"D2P1O[35],CRT Adjust,Off,On;",
	"H1P1O[40:36],CRT H-Size,0,+1,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[47:41],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[52:48],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"O[6],Service Mode,Off,On;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,+6 dB;",
	"O[11],Audio,Stereo,Mono;",
	"O[10],Swap stereo,No,Yes;",
	"-;",
	"R0,Reset;",
	"J1,Rotate Right,Rotate Left,Start,Coin;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the machine
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         dl_busy;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({13'd0, status[54:53] == 2'd2, ~(status[35] & (status[54:53] != 2'd2)), direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_busy),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1 / 2 start, 5 / 6 coin, 9 service, T tilt, F2 the service mode (MAME's defaults; F2 holds the switch while pressed,
// the OSD's Service Mode sets it; the game looks at it when it starts, so it takes a Reset)
reg key_start1, key_start2, key_coin1, key_coin2, key_service, key_tilt, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];
			9'h01E: key_start2  <= ps2_key[9];
			9'h02E: key_coin1   <= ps2_key[9];
			9'h036: key_coin2   <= ps2_key[9];
			9'h046: key_service <= ps2_key[9];
			9'h02C: key_tilt    <= ps2_key[9];      // T
			9'h006: key_test    <= ps2_key[9];      // F2
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4 / 5 buttons 1 / 2, 6 start, 7 coin (the J1 line above)
wire start1 = joystick_0[6] | key_start1, coin1 = joystick_0[7] | key_coin1;
wire start2 = joystick_1[6] | key_start2, coin2 = joystick_1[7] | key_coin2;

// MAME's INPUTS (d80084), active low: P1 in bits 15:8, P2 in 7:0, each 0 up, 1 down, 2 left, 3 right, 4 / 5 buttons 1 / 2, 6 unknown
// (1), 7 start
wire [15:0] in_inputs = ~{start1, 1'b0, joystick_0[5], joystick_0[4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3],
                          start2, 1'b0, joystick_1[5], joystick_1[4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};
// SYSTEM (d80086), active low: 7:0 unused (1), 8 coin 2, 9 coin 1, 10 tilt, 11 service 1, 12 the service mode, 14:13 unused (1);
// bit 15, the sound latch's pending flag, is the board's
wire [14:0] in_system = {2'b11, ~(key_test | status[6]), ~key_service, ~key_tilt, ~coin1, ~coin2, 8'hff};

// the DIP switches (the MRA's <switches>, ioctl index 254): DSW bits 7:0 (SW1) and 15:8 (SW2) as MAME reads them; MAME's
// defaults until they come
reg [7:0] sw[2];
initial begin sw[0] = 8'hFF; sw[1] = 8'hFF; end
always @(posedge clk_sys) if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[24:1]) sw[ioctl_addr[0]] <= ioctl_dout;

///////////////////////   MEMORY   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);

// Fast load (the MRA's address= attribute): Main_MiSTer copies the image into the DDR3 (byte 0x32000000) and ends a download that
// carries only a start address, the image's length; aquarium_fastload reads it back and plays it into the loader. An older
// Main_MiSTer streams the bytes as before. (The owner's Rabbit core, from the Metro core.)
reg         rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire        dl_start = rom_dl && !rom_dl_d;
wire        dl_done  = !rom_dl && rom_dl_d;
reg         fast_dl = 1'b0;
reg  [26:0] fast_len;
wire        fl_go    = fast_dl && dl_done;
wire        fl_done, fl_busy_unused;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr; end
	else if (fl_done || !pll_locked) fast_dl <= 1'b0;
end
wire        fl_wr;
wire [25:0] fl_addr;
wire  [7:0] fl_data;
wire        fl_ddr_rd;
wire [24:0] fl_ddr_addr;
wire  [7:0] fl_ddr_burst;

aquarium_fastload u_fastload
(
	.clk(clk_sys), .rst(~pll_locked), .go(fl_go), .len(fast_len), .busy(fl_busy_unused), .done(fl_done),
	.ddr_rd(fl_ddr_rd), .ddr_addr(fl_ddr_addr), .ddr_burst(fl_ddr_burst), .ddr_busy(DDRAM_BUSY), .ddr_dout(DDRAM_DOUT), .ddr_dready(DDRAM_DOUT_READY),
	.o_wr(fl_wr), .o_addr(fl_addr), .o_data(fl_data), .hold(dl_busy)
);
assign DDRAM_CLK      = clk_sys;
assign DDRAM_ADDR     = {4'd3, fl_ddr_addr};
assign DDRAM_BURSTCNT = fl_ddr_burst;
assign DDRAM_RD       = fl_ddr_rd;
assign DDRAM_WE       = 1'b0;
assign DDRAM_DIN      = 64'd0;
assign DDRAM_BE       = 8'hFF;

wire        ld_wr;
wire [24:0] ld_addr;
wire  [7:0] ld_data;

aquarium_loader u_loader
(
	.clk(clk_sys),
	.dl_wr(fl_wr || (ioctl_wr && rom_dl)), .dl_addr(fl_wr ? fl_addr[21:0] : ioctl_addr[21:0]), .dl_data(fl_wr ? fl_data : ioctl_dout),
	.o_wr(ld_wr), .o_addr(ld_addr), .o_data(ld_data)
);

// the SDRAM and its seven read clients (rtl/aquarium_core.sv)
wire        m_req [7], m_ack [7], m_valid [7];
wire [23:0] m_addr [7];
wire  [4:0] m_len [7];
wire [15:0] m_rdata;
wire        mem_ready;

aquarium_sdram #(.NC(7)) u_sdram
(
	.clk(clk_sys), .rst_n(pll_locked), .o_ready(mem_ready), .i_rd_late(1'b0),
	.i_dl_wr(ld_wr), .i_dl_addr(ld_addr), .i_dl_data(ld_data), .o_dl_busy(dl_busy),
	.c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_ack(m_ack), .c_valid(m_valid), .o_rdata(m_rdata),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
);

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw = RESET | status[0] | buttons[1];
// the SDRAM's download queue is busy only above 12 of its 16 words: after the image's last byte the machine waits 1,024 clocks more,
// for the queue's last writes (at most 16 words of about 10 clocks each, a refresh between) to land
reg   [9:0] dl_tail = 10'd0;
always @(posedge clk_sys) dl_tail <= ld_wr ? 10'h3ff : (dl_tail != 10'd0) ? dl_tail - 10'd1 : 10'd0;
// held while a ROM loads and until the memory is up; registered, it fans out to the whole core
reg         mc_rst = 1'b1;
always @(posedge clk_sys) mc_rst <= reset_sw | rom_dl | fast_dl | dl_busy | (dl_tail != 10'd0) | ~mem_ready | ~pll_locked;
// the raster runs from the PLL's lock on, through the machine's resets (the core starts its CPUs at a vblank of it)
reg         rst_raster = 1'b1;
always @(posedge clk_sys) rst_raster <= ~pll_locked;

wire        ce_pix, hs, vs, hblank, vblank, vblank_next;
wire  [7:0] r, g, b;
wire signed [15:0] snd_l, snd_r;
wire        running, frame_tick;

// Video Timing (the OSD's order): 270 lines (the default: 16.2 kHz, a 6.4 MHz dot, 14 blank lines, for a CRT; 60.009 Hz), 263
// lines CRT 240p (15.76 kHz, a 6.4 MHz dot, the picture's middle 240 lines: a standard 240p signal for a consumer CRT; 59.937 Hz),
// 263 lines RT4K DV1 (15.76 kHz, the 6.4 MHz dot, 7 blank lines, for a RetroTINK 4K in direct video, which takes 262-264 lines as
// "MiSTer 240p"; 59.937 Hz). Every line the same (rtl/aquarium_video.sv, whose vmode counts 0 270, 1 RT4K, 2 CRT 240p); a change
// takes effect at the next frame's start
reg   [1:0] vmode = 2'd0;
always @(posedge clk_sys) vmode <= {status[53], status[54]};
wire        m_crt = (vmode != 2'd1);        // a CRT raster: CRT Adjust works
wire        m240  = (vmode == 2'd2);

aquarium_core u_core
(
	.clk(clk_sys), .rst_raster(rst_raster), .reset(mc_rst), .vmode(vmode),
	.m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack), .m_valid(m_valid), .m_rdata(m_rdata),
	.dsw({sw[1], sw[0]}), .in_inputs(in_inputs), .in_system(in_system),
	.ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank), .vblank_next(vblank_next), .r(r), .g(g), .b(b),
	.audio_l(snd_l), .audio_r(snd_r), .running(running), .frame_tick(frame_tick), .dbg_pc()
);

///////////////////////   AUDIO   ///////////////////////

// the OSD's volume steps on MAME's own level
function automatic signed [15:0] f_vol(input signed [15:0] v, input [1:0] st);
	reg signed [16:0] gv;
	begin
		gv = (st == 2'd0) ? {v[15], v} : (st == 2'd1) ? {{2{v[15]}}, v[15:1]} : (st == 2'd2) ? {{3{v[15]}}, v[15:2]} : {v, 1'b0};
		f_vol = (gv > 17'sd32767) ? 16'sd32767 : (gv < -17'sd32768) ? $signed(16'h8000) : gv[15:0];
	end
endfunction
// Audio: Stereo, or Mono (both channels their mean); Swap stereo
wire signed [16:0] snd_sum = {snd_l[15], snd_l} + {snd_r[15], snd_r};
wire signed [15:0] snd_m   = snd_sum[16:1];
wire signed [15:0] snd_a   = status[11] ? snd_m : status[10] ? snd_r : snd_l;
wire signed [15:0] snd_b   = status[11] ? snd_m : status[10] ? snd_l : snd_r;
assign AUDIO_L = f_vol(snd_a, status[9:8]);
assign AUDIO_R = f_vol(snd_b, status[9:8]);

///////////////////////   VIDEO   ///////////////////////

// The picture, one clock later, before the CRT Adjust select (black while the machine is held: the raster keeps running, so the
// OSD's "Loading" pop-up has a signal to sit on and a scaler keeps its lock). HBlank is the horizontal blank alone, toggling on
// every line, vertical blank lines included, with the vertical blank on VBlank: the framework's scandoubler (Scandoubler Fx,
// MiSTer.ini's forced_scandoubler) takes its line timing from the horizontal blank's edges and without them loses the vertical sync
reg  [23:0] vq_rgb;
reg         vq_hb, vq_vb, vq_vbn, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= mc_rst ? 24'd0 : {r, g, b};
	vq_hb  <= hblank;
	vq_vb  <= vblank;
	vq_vbn <= vblank_next;
	vq_hs  <= hs;
	vq_vs  <= vs;
	vq_ce  <= ce_pix;
end

// CRT Adjust: the size, horizontal position and vertical position of the picture on a 15 kHz analog output (rmonic79's
// MiSTer-CRT-Adjust, modules/crt-adjust). The picture goes through a line buffer and is read out at a different pixel rate
// (H-Size) or a different place in the line (H-Position), and the vertical sync is delayed by whole lines (V-Shift); the sync
// pulses keep their rate, so the monitor stays locked. Off, the picture takes the path it always had. It works with the two CRT
// Video Timings, and does nothing while the scandoubler is in use (31 kHz); the menu greys it out with the RT4K's.
wire crt_sd = (|status[5:3]) | forced_scandoubler;

// the OSD values, as the menu counts them: H-Size 0..+1 then -16..-1, H-Position 0..+16 then -48..-1, V-Shift signed 5-bit.
// The picture is 320 dots in a line of 395 (270 lines), from 65 to 385 dots after the hsync pulse starts, or of 406 (CRT 240p),
// from 72 to 392; the module reads its line at the slower rate from the pulse on, so a size step (1/60 of a dot) moves the
// picture's end to 385 (392) * (60 + H-Size) / 60 dots, which must stay inside the line: +1 (391.4; 398.5) fits both (the picture
// is already as wide as a CRT shows)
localparam signed [8:0] CRT_HBIAS = -9'sd1;     // cancels the module's own one-dot delay of the picture
wire        [4:0] crt_hs_i = status[40:36];
wire signed [5:0] crt_hsz = (crt_hs_i <= 5'd1) ? $signed({1'b0, crt_hs_i}) : $signed({1'b0, crt_hs_i}) - 6'sd18;
wire        [6:0] crt_hp = status[47:41];
wire signed [8:0] crt_hpos = (crt_hp <= 7'd16) ? $signed({2'b00, crt_hp}) : $signed({2'b00, crt_hp}) - 9'sd65;
// the H-Position the picture can take at the H-Size (the module scales its distance from the hsync too): from a dot after the
// hsync pulse, (65 + p) * (60 + H-Size) / 4 >= 465 clocks, to a dot before the line's end, (385 + p) * (60 + H-Size) / 4 <= 5,910;
// with CRT 240p, (72 + p) ... >= 465 and (392 + p) ... <= 6,075: the same minimum 7 dots lower, the maximum 13 at H-Size 0 and 6 at
// +1. The menu's further values stop there, so the picture is always whole
reg signed  [8:0] crt_pmin, crt_pmax, crt_pmn, crt_pmx;
always @* begin
	crt_pmax = 9'sd16;
	case (crt_hsz)
		-6'sd16: crt_pmin = -9'sd22;
		-6'sd15: crt_pmin = -9'sd23;
		-6'sd14: crt_pmin = -9'sd24;
		-6'sd13: crt_pmin = -9'sd25;
		-6'sd12: crt_pmin = -9'sd26;
		-6'sd11, -6'sd10: crt_pmin = -9'sd27;
		-6'sd9:  crt_pmin = -9'sd28;
		-6'sd8,  -6'sd7:  crt_pmin = -9'sd29;
		-6'sd6:  crt_pmin = -9'sd30;
		-6'sd5,  -6'sd4:  crt_pmin = -9'sd31;
		-6'sd3,  -6'sd2:  crt_pmin = -9'sd32;
		-6'sd1:  begin crt_pmin = -9'sd33; crt_pmax = 9'sd15; end
		6'sd0:   begin crt_pmin = -9'sd34; crt_pmax = 9'sd9;  end
		default: begin crt_pmin = -9'sd34; crt_pmax = 9'sd2;  end     // +1
	endcase
	crt_pmn = m240 ? crt_pmin - 9'sd7 : crt_pmin;
	crt_pmx = !m240 ? crt_pmax : (crt_hsz == 6'sd0) ? 9'sd13 : (crt_hsz == 6'sd1) ? 9'sd6 : 9'sd16;
end
wire signed [8:0] crt_hpc = (crt_hpos < crt_pmn) ? crt_pmn : (crt_hpos > crt_pmx) ? crt_pmx : crt_hpos;
// the picture is read a line after it is written, so the sync is delayed one line to keep its place; a positive V-Shift moves
// the picture down, which is the sync coming earlier. Negative delays count from the frame's lines (vtotal: 270 or 263)
wire signed [6:0] crt_vs_t = 7'sd1 - $signed({status[52], status[52], status[52:48]});
reg               crt_on = 1'b0;
reg signed  [4:0] crt_hsize;
reg signed  [8:0] crt_hoff;
reg signed  [5:0] crt_voff;
always @(posedge clk_sys) if (vq_ce) begin
	crt_on    <= status[35] & ~crt_sd & m_crt;
	crt_hsize <= crt_hsz[4:0];
	crt_hoff  <= crt_hpc + CRT_HBIAS;
	crt_voff  <= crt_vs_t[5:0];
end

// the pixel read enable: one every (60 + H-Size) quarters of a clock (fifteen clocks a dot at 6.4 MHz), counted from the
// module's own line reference
wire       crt_hs_ref;
reg        crt_hs_ref_d;
wire [7:0] crt_period = 8'd60 + {{3{crt_hsize[4]}}, crt_hsize};
reg  [7:0] crt_acc;
wire       crt_tick = (crt_acc + 8'd4) >= crt_period;
always @(posedge clk_sys) begin
	crt_hs_ref_d <= crt_hs_ref;
	if      (crt_hs_ref & ~crt_hs_ref_d) crt_acc <= 8'd0;
	else if (crt_tick)                   crt_acc <= crt_acc + 8'd4 - crt_period;
	else                                 crt_acc <= crt_acc + 8'd4;
end
wire crt_rd_en = crt_on ? crt_tick : vq_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb_unused;
crt_adjust #(.VTOTAL(270), .HTOTAL(406), .HPOS_MODE(1), .AW(10)) u_crt
(
	.clk(clk_sys), .pxl_cen(vq_ce), .pxl2_cen(crt_rd_en), .active(crt_on),
	.hsize(crt_hsize), .hoffset(crt_hoff), .voffset(crt_voff), .vtotal(m240 ? 9'd263 : 9'd270),
	.r_in(vq_rgb[23:16]), .g_in(vq_rgb[15:8]), .b_in(vq_rgb[7:0]),
	.hs_in(vq_hs), .vs_in(vq_vs), .hb_in(vq_hb), .vb_in(vq_vbn),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb_unused),
	.hs_ref_out(crt_hs_ref)
);

wire        vga_de_i;
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.VGA_DE(vga_de_i),
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_rd_en : vq_ce),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : vq_rgb),
	.HBlank(crt_on ? (crt_hb | crt_hs) : vq_hb),   // CRT Adjust: nothing of the picture inside the hsync pulse; off: the horizontal blank alone
	.VBlank(crt_on ? 1'b0 : vq_vb),               // CRT Adjust: the module's blank already includes the vertical one
	.HSync(crt_on ? crt_hs : vq_hs),
	.VSync(crt_on ? crt_vs : vq_vs),
	.fx(status[5:3])
);

// Scale: the framework's video_freak; its SCALE input counts 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+, 4 HV-Integer
reg   [2:0] scale_sel;
always @* begin
	case (status[34:32])
		3'd1:    scale_sel = 3'd1;
		3'd2:    scale_sel = 3'd4;
		3'd3:    scale_sel = 3'd2;
		3'd4:    scale_sel = 3'd3;
		default: scale_sel = 3'd0;
	endcase
end
wire fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_i),
	// Original: the 320 x 256 picture is 4:3; CRT 240p shows 240 of its lines, 4:2.8125 (64:45)
	.ARX(fs_int ? HDMI_WIDTH  : (ar == 2'd0) ? ((vmode == 2'd2) ? 12'd64 : 12'd4) : {10'd0, ar - 2'd1}),
	.ARY(fs_int ? HDMI_HEIGHT : (ar == 2'd0) ? ((vmode == 2'd2) ? 12'd45 : 12'd3) : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on while a load / reset holds the machine, then a blink every frame
reg led_frame = 1'b0;
always @(posedge clk_sys) if (frame_tick) led_frame <= ~led_frame;
assign LED_USER = !running ? 1'b1 : led_frame;

endmodule
