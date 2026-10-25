//------------------------------------------------------------------------------
// Aquarium (Excellent System, 1996; ES-9206): the machine, written from MAME 0.289's src/mame/excellent/aquarium.cpp.
//
//   TMP68HC000P-16 at 32 MHz / 2 (fx68k); the sound board (rtl/aquarium_sound.sv: Z80, YM2151, MSM6295); the video
//   (rtl/aquarium_video.sv: three tilemaps, the sprites, the palette).
//
// The 68000's memory map (MAME's main_map; nothing is mirrored, anything else reads 0, MAME's unmapped value, and ignores writes):
//   000000-07ffff ROM                     c00000-c00fff mid VRAM          c01000-c01fff bak VRAM        c02000-c03fff txt VRAM
//   c80000-c81fff sprite RAM (low byte; the high byte reads 0)            d00000-d00fff palette
//   d80014-d8001f scroll (write only)     d80080 DSW                      d80084 INPUTS                 d80086 SYSTEM
//   d80088 (high byte) the MB3773 watchdog: bit 7 its clock               d8008b the sound latch        ff0000-ffffff RAM
// IRQ 1 (autovectored) at the vblank, held until acknowledged (MAME's irq1_line_hold). The watchdog resets the machine 5 s after
// its clock last fell (MAME's mb3773_device).
//
// Clocking and MAME's timeline: one 96 MHz clock. The 68000's clock is a pair of phase enables (fx68k's enPhi1 / enPhi2), one every
// 3 clocks (32 MHz: the CPU at 16 MHz), from the CPUs' start, as MAME's CPUs start at time 0. MAME's memory is instant and has no
// wait states; here the program ROM is read through a cache from the SDRAM (rtl/aquarium_cache.sv) and the video memories are
// copied at the vblank (10.7 us; a CPU write to an entry not yet copied waits for it). DTACK is always asserted at once (no wait states, as
// in MAME); where the data is not there yet when the CPU would take it, or a write has to wait, the CPU's phases are held, and the
// phases it missed are given back right after, at one every 2 clocks, so its program stays on MAME's timeline. The IRQ, raised while
// the CPU is behind, reaches it after the phases it owes. (The scheme of the owner's Hexion core, for the 68000.)
//
// The machine starts just before a vblank of the raster (which runs from power-up on): MAME's screen is at the start of its vblank
// at time 0 and calls its vblank callbacks first a frame later (below); every vblank is 1,600,000 clocks apart (60 Hz).
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_core (
    input  logic        clk,            // 96 MHz
    input  logic        rst_raster,     // the raster's power-up reset
    input  logic        reset,          // the machine's (a ROM load, the OSD's reset)
    input  logic  [1:0] vmode,          // the raster: 0 270 lines, 1 263 (RT4K DV1), 2 263 (CRT 240p)

    // SDRAM read clients: 0 the 68000's ROM cache, 1 the Z80's ROM cache, 2 OKI, 3 txt, 4 mid, 5 bak, 6 sprites
    output logic        m_req   [7],
    output logic [23:0] m_addr  [7],
    output logic  [4:0] m_len   [7],
    input  logic        m_ack   [7],
    input  logic        m_valid [7],
    input  logic [15:0] m_rdata,

    // MAME's input ports, active low as read (SYSTEM bit 15, the latch's pending flag, is the board's)
    input  logic [15:0] dsw,
    input  logic [15:0] in_inputs,
    input  logic [14:0] in_system,

    output logic        ce_pix,
    output logic        hs,
    output logic        vs,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_next,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    output logic        running,        // the CPUs run
    output logic        frame_tick,     // one clock at each vblank while running (MAME's frame_done)
    output logic [23:0] dbg_pc
);
    // ================================================================== the start
    // MAME's screen begins at the start of a vblank at time 0 without its callbacks; its first vblank (the IRQ, the sprite buffer,
    // frame_done 0) is a frame later. The CPUs start START_EARLY clocks before a vblank of the raster (from vbl_pre, a frame after
    // the vblank that arms the start), which is then the time-0 vblank and is skipped; the next one is frame 0. START_EARLY: MAME
    // makes a bus access at the start of its bus cycle (the 4 cycles are counted after it), the core makes it when AS has gone low
    // (S2; a write is made then, a read's data is taken by the CPU at S6), and fx68k leaves its reset a cycle later than MAME's
    // 68000: measured (the bench's +WLOG against MAME's instruction trace, the writes of the first instructions and those around the
    // vblanks), the 68000 started 32 clocks early makes its writes in the clock MAME's time reaches theirs (5 1/3 cycles of 16 MHz).
    localparam int START_EARLY = 32;
    logic        vbl_ev, vbl_raw, vbl_pre, vid_hold;
    logic        run;
    logic        armed;
    logic        skip_vbl;              // the time-0 vblank is still to come
    logic        wd_fire;
    always_ff @(posedge clk) begin
        if (reset || wd_fire) begin
            run <= 1'b0; armed <= 1'b0; skip_vbl <= 1'b0;
        end else if (!run) begin
            if (vbl_raw) armed <= 1'b1;
            else if (armed && vbl_pre) begin run <= 1'b1; skip_vbl <= 1'b1; end     // run from START_EARLY clocks before vbl_raw
        end else if (vbl_raw) skip_vbl <= 1'b0;
    end
    assign vbl_ev = vbl_raw && run && !skip_vbl;
    wire game_reset = !run;
    // the sound board starts at MAME's time 0 (its Z80, YM2151 and OKI have no bus to line up), START_EARLY clocks after the 68000
    logic [5:0] snd_cnt;
    logic       snd_run;
    always_ff @(posedge clk) begin
        if (!run) begin snd_cnt <= 6'd0; snd_run <= 1'b0; end
        else if (!snd_run) begin
            if (snd_cnt == 6'(START_EARLY - 1)) snd_run <= 1'b1;
            snd_cnt <= snd_cnt + 6'd1;
        end
    end
    assign running = run;
    assign frame_tick = vbl_ev;

    // ================================================================== the 68000
    // the phase enables: decided a clock ahead (registered: they fan out to the whole CPU); never two in a row
    logic  [1:0] pdiv;                  // the nominal grid: a phase at pdiv == 0
    logic        en;                    // this clock is a phase of the CPU
    logic        ph;                    // the next phase is PHI2
    logic  [9:0] owed;                  // nominal phases the CPU has not had yet
    logic        hold;                  // the bus cycle cannot go on yet
    wire         tick = (pdiv == 2'd0);
    wire  [9:0]  owed_n = owed + {9'd0, tick && run} - {9'd0, en && run};
    wire         tick_n = (pdiv == 2'd2);
    wire         en_n = !en && (game_reset ? tick_n : (!hold && (owed_n != 10'd0 || tick_n)));
    always_ff @(posedge clk) begin
        if (reset) begin
            pdiv <= 2'd0; en <= 1'b0; ph <= 1'b0; owed <= 10'd0;
        end else begin
            pdiv <= (pdiv == 2'd2) ? 2'd0 : pdiv + 2'd1;
            en   <= en_n;
            if (en) ph <= ~ph;
            owed <= game_reset ? 10'd0 : owed_n;
        end
    end
    wire en_phi1 = en && !ph;
    wire en_phi2 = en &&  ph;

    logic        as_n, uds_n, lds_n, rw_n;
    logic  [2:0] fc;
    logic [23:1] eab;
    logic [15:0] cpu_dout;
    logic [15:0] cpu_din;
    logic        dtack_n, vpa_n, ipl0_n;
    logic  [1:0] wr_dsn;                // the write's {UDS, LDS}, from AS on (vendored fx68k: modules/VENDOR.md)
    logic        e_unused, vma_unused, bg_unused, oreset_unused, ohalted_unused;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1), .extReset(game_reset), .pwrUp(game_reset), .enPhi1(en_phi1), .enPhi2(en_phi2),
        .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n), .E(e_unused), .VMAn(vma_unused),
        .FC0(fc[0]), .FC1(fc[1]), .FC2(fc[2]), .BGn(bg_unused), .oRESETn(oreset_unused), .oHALTEDn(ohalted_unused),
        .DTACKn(dtack_n), .VPAn(vpa_n), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl0_n), .IPL1n(1'b1), .IPL2n(1'b1),
        .iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab), .oWrDSn(wr_dsn)
    );
    assign dbg_pc = {eab, 1'b0};

    // ------------------------------------------------------------------ the bus cycle
    // fx68k's outputs are its registers (they change the clock after a phase). A cycle begins when AS goes low: the address, the
    // direction and the function code are taken then; a read's data is taken by the CPU at the fifth phase after AS fell (the end of
    // S6). A write is made as soon as AS is low, with its data (fx68k's DOB is loaded with AS) and its byte lanes (wr_dsn), as MAME
    // makes it at the start of the bus cycle (its strobes come two phases later). `nph` counts the phases since AS fell: from the
    // fourth on, the CPU is held while the read's data is not on iEdb or the write is not done.
    logic        in_cyc;
    logic  [2:0] nph;
    logic        rd_ok, wr_done;
    wire         cs   = !as_n && !in_cyc;                   // the cycle begins (this clock)
    wire         iack = (fc == 3'b111);
    wire  [23:0] A    = {eab, 1'b0};

    // the decode (of the address on the bus)
    wire sel_rom  = (A[23:19] == 5'd0);
    wire sel_mid  = (A[23:12] == 12'hc00);
    wire sel_bak  = (A[23:12] == 12'hc01);
    wire sel_txt  = (A[23:13] == 11'h601);
    wire sel_spr  = (A[23:13] == 11'h640);
    wire sel_pal  = (A[23:12] == 12'hd00);
    wire sel_io   = (A[23:8]  == 16'hd800);
    wire sel_scr  = sel_io && (A[7:5] == 3'd0) && (A[4:1] >= 4'ha);   // d80014-d8001f
    wire sel_wram = (A[23:16] == 8'hff);
    wire sel_vid  = sel_mid || sel_bak || sel_txt || sel_spr || sel_pal || sel_scr;

    logic        rd_pend;                                   // a non-ROM read: the data is there two clocks after the cycle began
    logic  [1:0] rd_cnt;
    logic        rom_wait;
    logic        c_ack, c_ready_unused;
    logic [15:0] c_q;
    wire         wr_go    = !as_n && !rw_n && !wr_done && !iack && !(sel_vid && vid_hold);
    wire   [1:0] wr_be    = ~wr_dsn;                        // {UDS, LDS} of the write

    always_ff @(posedge clk) begin
        if (game_reset) begin
            in_cyc <= 1'b0; nph <= 3'd0; rd_ok <= 1'b0; wr_done <= 1'b0; rd_pend <= 1'b0; rom_wait <= 1'b0;
        end else begin
            if (as_n) begin
                in_cyc <= 1'b0; rd_ok <= 1'b0; wr_done <= 1'b0; rd_pend <= 1'b0; rom_wait <= 1'b0;
            end else if (cs) begin
                in_cyc <= 1'b1; nph <= 3'd0; rd_ok <= 1'b0; wr_done <= wr_go;
                if (rw_n && !iack) begin
                    if (sel_rom) rom_wait <= 1'b1;
                    else begin rd_pend <= 1'b1; rd_cnt <= 2'd0; end
                end
            end else begin
                if (en && nph != 3'd7) nph <= nph + 3'd1;
                if (rom_wait && c_ack) begin rom_wait <= 1'b0; rd_ok <= 1'b1; end
                if (rd_pend) begin
                    rd_cnt <= rd_cnt + 2'd1;
                    if (rd_cnt == 2'd1) begin rd_pend <= 1'b0; rd_ok <= 1'b1; end
                end
                if (wr_go) wr_done <= 1'b1;
            end
        end
    end
    always_comb hold = in_cyc && !iack && (nph >= 3'd4) && !(rw_n ? rd_ok : wr_done);

    assign dtack_n = !(in_cyc && !iack);
    assign vpa_n   = !(in_cyc && iack);

    // ------------------------------------------------------------------ the program ROM (through the cache)
    aquarium_cache #(.AW(18), .IDX(10), .BASE(24'h000000)) u_cache (
        .clk(clk), .reset(reset), .ready(c_ready_unused),
        .req(cs && rw_n && !iack && sel_rom), .addr(A[18:1]), .ack(c_ack), .q(c_q),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_data(m_rdata)
    );

    // ------------------------------------------------------------------ the work RAM
    logic [15:0] wram_q, wram_b_unused;
    aquarium_bram #(.AW(15), .NB(2)) u_wram (
        .clk(clk), .a_addr(A[15:1]), .a_wdata(cpu_dout), .a_be(wr_be), .a_we(wr_go && sel_wram), .a_q(wram_q),
        .b_addr(15'd0), .b_q(wram_b_unused)
    );

    // ------------------------------------------------------------------ the video memories (rtl/aquarium_video.sv)
    logic [15:0] vid_q;
    wire  [12:1] c_addr = sel_scr ? {9'd0, 3'(A[4:1] - 4'ha)} : A[12:1];

    // ------------------------------------------------------------------ I/O
    logic        latch_pending;
    logic        latch_wr;
    logic  [7:0] latch_din;
    logic        wd_ck;
    logic [28:0] wd_cnt;
    logic  [1:0] flip;                  // d80020 bits 1:0 (MAME: unmapped), the picture's flip (rtl/aquarium_video.sv)
    always_ff @(posedge clk) begin
        latch_wr <= 1'b0;
        wd_fire  <= 1'b0;
        if (game_reset) begin
            wd_ck <= 1'b0; wd_cnt <= 29'd0; flip <= 2'd0;
        end else begin
            if (wr_go && sel_io && A[7:1] == 7'h10 && wr_be[0]) flip <= cpu_dout[1:0];
            if (wd_cnt == 29'd479999999) begin wd_fire <= 1'b1; wd_cnt <= 29'd0; end
            else wd_cnt <= wd_cnt + 29'd1;
            if (wr_go && sel_io && A[7:1] == 7'h44 && wr_be[1]) begin             // d80088, the high byte: the MB3773's clock
                wd_ck <= cpu_dout[15];
                if (!cpu_dout[15] && wd_ck) wd_cnt <= 29'd0;                  // a falling edge restarts its 5 s
            end
            if (wr_go && sel_io && A[7:1] == 7'h45 && wr_be[0]) begin            // d8008b, the low byte of d8008a: the sound latch
                latch_wr <= 1'b1; latch_din <= cpu_dout[7:0];
            end
        end
    end

    // the latch's pending flag as the 68000 reads it: the board's. (The benches' MAME_SYNC: as MAME's 68000 sees it, its own write
    // at once and the Z80's acknowledge only at the next vblank, where MAME's scheduler next lets the Z80 run; docs/hardware.md)
    logic        pend_seen;
`ifdef MAME_SYNC
    logic        pend_m = 1'b0;
    always_ff @(posedge clk) begin
        if (game_reset) pend_m <= 1'b0;
        else if (latch_wr) pend_m <= 1'b1;
        else if (vbl_ev) pend_m <= latch_pending;
    end
    assign pend_seen = pend_m;
`else
    assign pend_seen = latch_pending;
`endif
    logic [15:0] io_q;
    always_comb begin
        case (A[7:1])
            7'h40:   io_q = dsw;                                // d80080
            7'h42:   io_q = in_inputs;                          // d80084
            7'h43:   io_q = {pend_seen, in_system};             // d80086
            default: io_q = 16'h0000;
        endcase
    end

    // the read data: the source of the cycle's address, taken when it is there
    logic        r_wram, r_vid, r_io;
    always_ff @(posedge clk) begin
        if (cs) begin r_wram <= sel_wram; r_vid <= sel_vid && !sel_scr; r_io <= sel_io && !sel_scr; end
        if (rom_wait && c_ack) cpu_din <= c_q;
        else if (rd_pend && rd_cnt == 2'd1) cpu_din <= r_wram ? wram_q : r_vid ? vid_q : r_io ? io_q : 16'h0000;
    end

    // ------------------------------------------------------------------ IRQ 1: raised at the vblank, cleared by its acknowledge
    logic        irq1;
    logic        irq_pend;
    logic  [9:0] irq_wait;
    always_ff @(posedge clk) begin
        if (game_reset) begin
            irq1 <= 1'b0; irq_pend <= 1'b0;
        end else begin
            if (vbl_ev) begin
                if (owed_n == 10'd0) irq1 <= 1'b1;
                else begin irq_pend <= 1'b1; irq_wait <= owed_n; end
            end else if (irq_pend && en) begin
                irq_wait <= irq_wait - 10'd1;
                if (irq_wait == 10'd1) begin irq1 <= 1'b1; irq_pend <= 1'b0; end
            end
            if (cs && iack && A[3:1] == 3'd1) irq1 <= 1'b0;
        end
    end
    assign ipl0_n = !irq1;

    // ================================================================== the SDRAM clients of the video (3..6) and the sound (1, 2)
    logic        v_req [4], v_ack [4], v_valid [4];
    logic [23:0] v_addr [4];
    logic  [4:0] v_len [4];
    logic        s_req [2], s_ack [2], s_valid [2];
    logic [23:0] s_addr [2];
    logic  [4:0] s_len [2];
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            m_req[3 + i] = v_req[i]; m_addr[3 + i] = v_addr[i]; m_len[3 + i] = v_len[i];
            v_ack[i] = m_ack[3 + i]; v_valid[i] = m_valid[3 + i];
        end
        for (int i = 0; i < 2; i++) begin
            m_req[1 + i] = s_req[i]; m_addr[1 + i] = s_addr[i]; m_len[1 + i] = s_len[i];
            s_ack[i] = m_ack[1 + i]; s_valid[i] = m_valid[1 + i];
        end
    end

    // ================================================================== the video
    aquarium_video #(.PRE(START_EARLY + 1)) u_video (
        .clk(clk), .rst_raster(rst_raster), .reset(reset), .vmode(vmode), .flip(flip),
        .c_mid(sel_mid), .c_bak(sel_bak), .c_txt(sel_txt), .c_spr(sel_spr), .c_pal(sel_pal), .c_scr(sel_scr),
        .c_addr(c_addr), .c_wdata(cpu_dout), .c_be(wr_be), .c_we(wr_go && sel_vid), .c_rdata(vid_q),
        .c_hold(vid_hold), .vbl_ev(vbl_raw), .vbl_pre(vbl_pre),
        .m_req(v_req), .m_addr(v_addr), .m_len(v_len), .m_ack(v_ack), .m_valid(v_valid), .m_rdata(m_rdata),
        .ce_pix(ce_pix), .o_hs(hs), .o_vs(vs), .o_hblank(hblank), .o_vblank(vblank), .o_vblank_next(vblank_next),
        .o_r(r), .o_g(g), .o_b(b)
    );

    // ================================================================== the sound board
    logic [15:0] snd_pc_unused;
    aquarium_sound u_sound (
        .clk(clk), .mreset(reset), .reset(!snd_run),
        .latch_wr(latch_wr), .latch_din(latch_din), .latch_pending(latch_pending),
        .m_req(s_req), .m_addr(s_addr), .m_len(s_len), .m_ack(s_ack), .m_valid(s_valid), .m_rdata(m_rdata),
        .audio_l(audio_l), .audio_r(audio_r), .dbg_pc(snd_pc_unused)
    );

    wire unused = &{1'b0, e_unused, vma_unused, bg_unused, oreset_unused, ohalted_unused, wram_b_unused, c_ready_unused,
                    snd_pc_unused, en_phi1, uds_n, lds_n, A[0]};
endmodule
`default_nettype wire
