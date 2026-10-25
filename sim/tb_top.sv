// The whole-machine bench: aquarium_core behind aquarium_sdram and the behavioural SDRAM (sim/sdram_model.sv). The ROM image
// (+IMAGE=<file>, tools/aquarium_rom.py) is downloaded first through aquarium_loader, a byte a clock while the SDRAM's download FIFO
// takes them, with the machine held in reset, as Aquarium.sv does it; then the machine runs (it starts its CPUs 32 clocks
// before a vblank of the raster, rtl/aquarium_core.sv). +DSW=<4 hex digits> sets the DIP switches (MAME's default FFFF);
// +M263 / +M240 the 263-line rasters (RT4K DV1 / CRT 240p; the default: 270, the core's default). Built with MAME_FRAME
// (sim/run_sys.sh) the frame is MAME's 1,600,000 clocks; without, the core's (rtl/aquarium_video.sv). Driven by
// sim/tb_aquarium.cpp.
//
// At every frame_tick (the vblank, MAME's frame_done) with +DUMPDIR=<dir> and the frame in +DUMPFROM / +DUMPTO / +DUMPEVERY,
// <dir>/ram_<frame>.bin: the work RAM (ff0000-ffffff, 64 KB), the mid, bak and txt VRAM (4 + 4 + 8 KB), the palette (4 KB), the
// sprite RAM (4 KB, its bytes), the scroll words (12 bytes), in the 68000's byte order, as tools/lua/dump.lua writes MAME's.
`default_nettype none
module tb_top (
    input  logic        clk,
    input  logic        reset_in,
    input  logic [15:0] in_inputs,
    input  logic [14:0] in_system,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic signed [15:0] ym_l,            // the chips' own outputs (AUDIO=2: the WAV's left the YM2151's left, its right the OKI's sum)
    output logic signed [13:0] oki_s,
    output logic        frame_tick,
    output logic        running,
    output logic        loaded,
    output logic [23:0] dbg_pc
);
    // ------------------------------------------------------------------ the image
    logic [7:0] img [1 << 22];
    int         img_len = 0;
    logic [15:0] dsw = 16'hFFFF;
    logic  [1:0] vmode = 2'd0;
    initial begin
        string f;
        int fd;
        if ($value$plusargs("IMAGE=%s", f)) begin
            fd = $fopen(f, "rb");
            if (fd == 0) begin $display("tb: cannot open %s", f); $finish; end
            img_len = $fread(img, fd);
            $fclose(fd);
            $display("tb: image %0d bytes from %s", img_len, f);
        end else begin
            $display("tb: no +IMAGE=<file>"); $finish;
        end
        void'($value$plusargs("DSW=%h", dsw));
        vmode = $test$plusargs("M263") ? 2'd1 : $test$plusargs("M240") ? 2'd2 : 2'd0;
    end

    // ------------------------------------------------------------------ the SDRAM
    localparam int NC = 7;
    logic        m_req [NC], m_ack [NC], m_valid [NC];
    logic [23:0] m_addr [NC];
    logic  [4:0] m_len [NC];
    logic [15:0] m_rdata;
    logic        sd_ready, dl_busy;
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic  [1:0] SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE;

    logic        ld_wr;
    logic [24:0] ld_addr;
    logic  [7:0] ld_data;

    aquarium_sdram #(.P_SHORT_INIT(1'b1), .NC(NC)) u_sdram (
        .clk(clk), .rst_n(!reset_in), .o_ready(sd_ready), .i_rd_late(1'b0),
        .i_dl_wr(ld_wr), .i_dl_addr(ld_addr), .i_dl_data(ld_data), .o_dl_busy(dl_busy),
        .c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_ack(m_ack), .c_valid(m_valid), .o_rdata(m_rdata),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
    );
    sdram_model u_sdr (
        .clk(clk), .A(SDRAM_A), .BA(SDRAM_BA), .DQ(SDRAM_DQ), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH),
        .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .CKE(SDRAM_CKE)
    );

    // ------------------------------------------------------------------ the download
    int          dl_i = 0;
    logic        dl_wr;
    logic [21:0] dl_addr;
    logic  [7:0] dl_data;
    wire         dl_on = (dl_i < img_len);
    always_ff @(posedge clk) begin
        dl_wr <= 1'b0;
        if (!reset_in && sd_ready && dl_on && !dl_busy && !dl_wr) begin
            dl_wr <= 1'b1; dl_addr <= 22'(dl_i); dl_data <= img[dl_i];
            dl_i <= dl_i + 1;
        end
    end

    aquarium_loader u_loader (
        .clk(clk), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data),
        .o_wr(ld_wr), .o_addr(ld_addr), .o_data(ld_data)
    );

    // ------------------------------------------------------------------ the machine
    logic mc_reset;
    logic [9:0] tail;           // after the last byte, for the loader's and the FIFO's last writes
    always_ff @(posedge clk) begin
        if (reset_in || dl_on || dl_wr || dl_busy) tail <= 10'd0;
        else if (tail != 10'h3ff) tail <= tail + 10'd1;
        mc_reset <= reset_in || !sd_ready || (tail != 10'h3ff);
    end
    assign loaded = !mc_reset;

    logic vblank_next_unused;
    aquarium_core u_core (
        .clk(clk), .rst_raster(reset_in), .reset(mc_reset), .vmode(vmode),
        .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack), .m_valid(m_valid), .m_rdata(m_rdata),
        .dsw(dsw), .in_inputs(in_inputs), .in_system(in_system),
        .ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank), .vblank_next(vblank_next_unused), .r(r), .g(g), .b(b),
        .audio_l(audio_l), .audio_r(audio_r), .running(running), .frame_tick(frame_tick), .dbg_pc(dbg_pc)
    );

    // ------------------------------------------------------------------ the 68000's instruction trace: +ITRACE=<cycles> prints
    // "I <clock> <pc> <opcode>" at each IR => IRD transfer of fx68k (enT1 with Ir2Ird) for the first <cycles> CPU cycles of MAME's
    // time, <clock> = the 96 MHz clocks since MAME's time 0 (the CPU starts START_EARLY clocks before it, rtl/aquarium_core.sv);
    // +ITRACEFROM=<cycle> starts it later. tools/cmp_trace.py compares them with MAME's debugger trace ({tracelog "%d ",totalcycles}).
    // The address is the PC then, less 2; some instructions (a MOVE to an absolute long address) transfer twice, the first time with
    // the PC 2 short (the script drops a line whose opcode is not the program's word at its address). +WLOG: "W <clock> <address>
    // <data> <lanes>" at each write the core makes; +FCYC: "F <frame> <clock>" at each vblank.
    longint itrace = 0, itfrom = 0, clk0 = 0;
    initial begin void'($value$plusargs("ITRACE=%d", itrace)); void'($value$plusargs("ITRACEFROM=%d", itfrom)); end
    wire    it_on = (clk0 >= itfrom * 6) && (clk0 < itrace * 6);
    always_ff @(posedge clk) begin
        if (!running) clk0 <= -longint'(u_core.START_EARLY);
        else begin
            clk0 <= clk0 + 1;
            if (frame_tick && $test$plusargs("FCYC")) $display("F %0d %0d owed %0d", frame, clk0, u_core.owed);
            // +OWEDLOG: "O <clock> <owed phases> <hold kind>" whenever the 68000's owed phases pass a multiple of 64 upwards
            if ($test$plusargs("OWEDLOG") && u_core.owed[5:0] == 6'd0 && u_core.owed != 0 && u_core.owed_n == u_core.owed + 1)
                $display("O %0d %0d %s a=%06x", clk0, u_core.owed + 1, u_core.rom_wait ? "rom" : (u_core.rw_n ? "read" : "write"), u_core.A);
            if (it_on && u_core.wr_go && $test$plusargs("WLOG")) $display("W %0d %06x %04x %b", clk0, u_core.A, u_core.cpu_dout, u_core.wr_be);
            if (it_on && u_core.u_cpu.enT1 && u_core.u_cpu.Nanod.Ir2Ird)
                $display("I %0d %06x %04x", clk0, {u_core.u_cpu.excUnit.PcH[7:0], u_core.u_cpu.excUnit.PcL} - 24'd2, u_core.u_cpu.Ir);
        end
    end

    // ------------------------------------------------------------------ the Z80's trace: +ZTRACE=<cycles> prints "Z <cycle> <pc>" at
    // each opcode fetch (M1) for the Z80's first <cycles> cycles (5.333 MHz), <cycle> = its steps since its start less the one tv80
    // spends after reset (the Hexion core's convention), as MAME's debugger trace of the audiocpu with {tracelog "%d ",totalcycles};
    // +ZTRACEFROM=<cycle> starts it later (a prefixed instruction logs each of its M1 fetches here, once in MAME)
    longint ztrace = 0, ztfrom = 0, zcyc = -1;
    logic   zm1_d = 1'b1;
    initial begin void'($value$plusargs("ZTRACE=%d", ztrace)); void'($value$plusargs("ZTRACEFROM=%d", ztfrom)); end
    wire    zt_on = (zcyc >= ztfrom) && (zcyc < ztrace);
    always_ff @(posedge clk) begin
        if (!u_core.snd_run) begin zcyc <= -1; zm1_d <= 1'b1; end
        else begin
            if (u_core.u_sound.cpu_ce) zcyc <= zcyc + 1;
            zm1_d <= u_core.u_sound.m1_n;
            if (!u_core.u_sound.m1_n && zm1_d && !u_core.u_sound.mreq_n && zt_on) $display("Z %0d %04x", zcyc, u_core.u_sound.A);
            else if (!u_core.u_sound.m1_n && zm1_d && zt_on) $display("Z %0d %04x", zcyc, u_core.u_sound.A);
        end
    end

    // +LAG=<frame>: from that frame on the bench numbers its frames one ahead (the dumps', with sim/tb_aquarium.cpp's pictures and
    // input schedule): the game's first sound command makes MAME's 68000 wait for the Z80's acknowledge until its next timeslice,
    // the vblank (MAME's scheduling: its Z80 runs after the 68000), where the core's Z80 acknowledges at once, so from there the core
    // runs a frame ahead of MAME (docs/hardware.md, "The sound latch")
    int frame = 0, lagfrom = 1 << 30;
    initial void'($value$plusargs("LAG=%d", lagfrom));
    wire [31:0] flbl = (frame >= lagfrom) ? frame + 1 : frame;

    // ------------------------------------------------------------------ +SNDLOG: "L <frame> <byte>" at each sound command the 68000
    // writes, "K <frame> <byte>" at each YM2151 key-on write (register 8), "O <frame> <byte>" at each MSM6295 command (frames as numbered
    // for the dumps)
    bit   sndlog = 1'b0;
    logic [7:0] ym_reg = 8'd0;
    initial sndlog = $test$plusargs("SNDLOG");
    always_ff @(posedge clk) if (sndlog && running) begin
        if (u_core.latch_wr) $display("L %0d %02x", flbl, u_core.latch_din);
        if (u_core.u_sound.ymq_push) begin
            if (!u_core.u_sound.port[0]) ym_reg <= u_core.u_sound.cpu_do;
            else if (ym_reg == 8'h08) $display("K %0d %02x", flbl, u_core.u_sound.cpu_do);
        end
        if (u_core.u_sound.io_wr && u_core.u_sound.port == 8'h02) $display("O %0d %02x", flbl, u_core.u_sound.rev8(u_core.u_sound.cpu_do));
    end

    // +YMLOG: "Y <clock> <a0> <data>" at each write jt51 takes (the clock since the sound board's start)
    longint sclk = 0;
    logic   ymwr_d = 1'b0;
    always_ff @(posedge clk) begin
        sclk <= u_core.snd_run ? sclk + 1 : 0;
        ymwr_d <= u_core.u_sound.ym_wr;
        if ($test$plusargs("YMLOG") && u_core.u_sound.ym_wr && !ymwr_d)
            $display("Y %0d %0d %02x", sclk, u_core.u_sound.ym_a0, u_core.u_sound.ym_din);
    end
    assign ym_l  = u_core.u_sound.ym_l;
    assign oki_s = u_core.u_sound.oki_s;

    // ------------------------------------------------------------------ the dumps
    string dumpdir = "";
    int    dfrom = 0, dto = -1, devery = 1;
    initial begin
        void'($value$plusargs("DUMPDIR=%s", dumpdir));
        void'($value$plusargs("DUMPFROM=%d", dfrom));
        void'($value$plusargs("DUMPTO=%d", dto));
        void'($value$plusargs("DUMPEVERY=%d", devery));
    end
    always_ff @(posedge clk) begin
        if (frame_tick) begin
            if (dumpdir != "" && flbl >= dfrom && (dto < 0 || flbl <= dto) && ((flbl - dfrom) % devery) == 0) dump(flbl);
            frame <= frame + 1;
        end
    end

    task automatic dump(input int f);
        int fd;
        string fn;
        fn = $sformatf("%s/ram_%0d.bin", dumpdir, f);
        fd = $fopen(fn, "wb");
        for (int i = 0; i < 32768; i++) begin
            $fwrite(fd, "%c", u_core.u_wram.g_lane[1].u_l.mem[i]);
            $fwrite(fd, "%c", u_core.u_wram.g_lane[0].u_l.mem[i]);
        end
        for (int i = 0; i < 4096; i++) $fwrite(fd, "%c", vb_mid(i));
        for (int i = 0; i < 4096; i++) $fwrite(fd, "%c", vb_bak(i));
        for (int i = 0; i < 8192; i++) $fwrite(fd, "%c", vb_txt(i));
        for (int i = 0; i < 4096; i++) $fwrite(fd, "%c", vb_pal(i));
        for (int i = 0; i < 4096; i++) $fwrite(fd, "%c", vb_spr(i));
        for (int i = 0; i < 6; i++) $fwrite(fd, "%c%c", u_core.u_video.scr_l[i][15:8], u_core.u_video.scr_l[i][7:0]);
        $fclose(fd);
    endtask

    // the lane of byte a in a 64-bit entry of 16-bit words: word (a / 2) & 3, its high byte (even a) in the word's upper lane
    function automatic int lane16(input int a);
        lane16 = ((a >> 1) & 3) * 2 + (((a & 1) != 0) ? 0 : 1);
    endfunction
    function automatic logic [7:0] vb_mid(input int a);
        int e = a >> 3, l = lane16(a);
        case (l)
            0: vb_mid = u_core.u_video.u_mid_l.g_lane[0].u_l.mem[e];  1: vb_mid = u_core.u_video.u_mid_l.g_lane[1].u_l.mem[e];
            2: vb_mid = u_core.u_video.u_mid_l.g_lane[2].u_l.mem[e];  3: vb_mid = u_core.u_video.u_mid_l.g_lane[3].u_l.mem[e];
            4: vb_mid = u_core.u_video.u_mid_l.g_lane[4].u_l.mem[e];  5: vb_mid = u_core.u_video.u_mid_l.g_lane[5].u_l.mem[e];
            6: vb_mid = u_core.u_video.u_mid_l.g_lane[6].u_l.mem[e];  default: vb_mid = u_core.u_video.u_mid_l.g_lane[7].u_l.mem[e];
        endcase
    endfunction
    function automatic logic [7:0] vb_bak(input int a);
        int e = a >> 3, l = lane16(a);
        case (l)
            0: vb_bak = u_core.u_video.u_bak_l.g_lane[0].u_l.mem[e];  1: vb_bak = u_core.u_video.u_bak_l.g_lane[1].u_l.mem[e];
            2: vb_bak = u_core.u_video.u_bak_l.g_lane[2].u_l.mem[e];  3: vb_bak = u_core.u_video.u_bak_l.g_lane[3].u_l.mem[e];
            4: vb_bak = u_core.u_video.u_bak_l.g_lane[4].u_l.mem[e];  5: vb_bak = u_core.u_video.u_bak_l.g_lane[5].u_l.mem[e];
            6: vb_bak = u_core.u_video.u_bak_l.g_lane[6].u_l.mem[e];  default: vb_bak = u_core.u_video.u_bak_l.g_lane[7].u_l.mem[e];
        endcase
    endfunction
    function automatic logic [7:0] vb_txt(input int a);
        int e = a >> 4, l = lane16(a);
        if ((a >> 3) & 1)
            case (l)
                0: vb_txt = u_core.u_video.u_txt_l1.g_lane[0].u_l.mem[e];
                1: vb_txt = u_core.u_video.u_txt_l1.g_lane[1].u_l.mem[e];
                2: vb_txt = u_core.u_video.u_txt_l1.g_lane[2].u_l.mem[e];
                3: vb_txt = u_core.u_video.u_txt_l1.g_lane[3].u_l.mem[e];
                4: vb_txt = u_core.u_video.u_txt_l1.g_lane[4].u_l.mem[e];
                5: vb_txt = u_core.u_video.u_txt_l1.g_lane[5].u_l.mem[e];
                6: vb_txt = u_core.u_video.u_txt_l1.g_lane[6].u_l.mem[e];
                default: vb_txt = u_core.u_video.u_txt_l1.g_lane[7].u_l.mem[e];
            endcase
        else
            case (l)
                0: vb_txt = u_core.u_video.u_txt_l0.g_lane[0].u_l.mem[e];
                1: vb_txt = u_core.u_video.u_txt_l0.g_lane[1].u_l.mem[e];
                2: vb_txt = u_core.u_video.u_txt_l0.g_lane[2].u_l.mem[e];
                3: vb_txt = u_core.u_video.u_txt_l0.g_lane[3].u_l.mem[e];
                4: vb_txt = u_core.u_video.u_txt_l0.g_lane[4].u_l.mem[e];
                5: vb_txt = u_core.u_video.u_txt_l0.g_lane[5].u_l.mem[e];
                6: vb_txt = u_core.u_video.u_txt_l0.g_lane[6].u_l.mem[e];
                default: vb_txt = u_core.u_video.u_txt_l0.g_lane[7].u_l.mem[e];
            endcase
    endfunction
    function automatic logic [7:0] vb_pal(input int a);
        int e = a >> 3, l = lane16(a);
        case (l)
            0: vb_pal = u_core.u_video.u_pal_l.g_lane[0].u_l.mem[e];  1: vb_pal = u_core.u_video.u_pal_l.g_lane[1].u_l.mem[e];
            2: vb_pal = u_core.u_video.u_pal_l.g_lane[2].u_l.mem[e];  3: vb_pal = u_core.u_video.u_pal_l.g_lane[3].u_l.mem[e];
            4: vb_pal = u_core.u_video.u_pal_l.g_lane[4].u_l.mem[e];  5: vb_pal = u_core.u_video.u_pal_l.g_lane[5].u_l.mem[e];
            6: vb_pal = u_core.u_video.u_pal_l.g_lane[6].u_l.mem[e];  default: vb_pal = u_core.u_video.u_pal_l.g_lane[7].u_l.mem[e];
        endcase
    endfunction
    // the sprite RAM: byte o is entry o >> 3, lane o & 7
    function automatic logic [7:0] vb_spr(input int o);
        int e = o >> 3;
        case (o & 7)
            0: vb_spr = u_core.u_video.u_spr_l.g_lane[0].u_l.mem[e];  1: vb_spr = u_core.u_video.u_spr_l.g_lane[1].u_l.mem[e];
            2: vb_spr = u_core.u_video.u_spr_l.g_lane[2].u_l.mem[e];  3: vb_spr = u_core.u_video.u_spr_l.g_lane[3].u_l.mem[e];
            4: vb_spr = u_core.u_video.u_spr_l.g_lane[4].u_l.mem[e];  5: vb_spr = u_core.u_video.u_spr_l.g_lane[5].u_l.mem[e];
            6: vb_spr = u_core.u_video.u_spr_l.g_lane[6].u_l.mem[e];  default: vb_spr = u_core.u_video.u_spr_l.g_lane[7].u_l.mem[e];
        endcase
    endfunction
endmodule
`default_nettype wire
