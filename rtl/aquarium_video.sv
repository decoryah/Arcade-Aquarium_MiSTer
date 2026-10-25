//------------------------------------------------------------------------------
// Aquarium's video: the video memories, their snapshot at the vertical blank, the raster, the three tilemap layers, the sprites and
// MAME 0.289's mix of them (src/mame/excellent/aquarium.cpp screen_update, excellent_spr.cpp).
//
// The memories (the 68000's side, at its addresses in rtl/aquarium_core.sv): mid VRAM c00000 (2 K words), bak VRAM c01000 (2 K),
// txt VRAM c02000 (4 K), the sprite RAM c80000 (4 KB on the low byte lane), the palette d00000 (2 K words, RRRRGGGGBBBBRGBx), the
// six scroll words d80014 (mid x, y, bak x, y, txt x, y). Each is kept twice: the live copy the CPU reads and writes, and the
// display copy the picture is drawn from.
//
// MAME draws the whole frame at the start of the vertical blank (its screen: 60 Hz, 512 x 512, the visible area 320 x 256 at 16, 16,
// no vertical blank time): the picture is the state of that instant, and the game writes its video memory all through the frame
// (MAME 0.289 with a Lua write tap: VRAM and palette writes from 1.5 ms to 9 ms after the vblank, the sprite list in its first 1.5
// ms). The core does what MAME does: at the vblank (vbl_ev) the live copies are copied into the display copies in 512 clocks
// (5.3 us, 64-bit words; a 68000 write to an entry the copy has not yet reached waits for it, rtl/aquarium_core.sv), and the
// frame after it is drawn from them.
// The sprites are buffered once more, as excellent_spr_device does (its vblank copies the sprite RAM after the frame is drawn): the
// list is copied into one of two buffers at each vblank, and a frame shows the one copied at the vblank before.
//
// The raster: a 15 kHz raster of its own (MAME's screen for this driver is a placeholder: 512 lines at 60 Hz, 30.7 kHz), 320 x 256
// visible, every line the same length and every dot the same width (a scaler or a monitor locks onto it line by line; the first
// release spread MAME's 1,600,000-clock frame over lines of 6,083 and 6,084 clocks, and a RetroTINK 4K in direct video showed
// single lines shifted sideways), in one of three timings (vmode, the OSD's Video Timing):
//   0: 270 lines of 395 dots of 15 clocks (6.4 MHz; 5,925 clocks, 16.20 kHz; 1,599,750 clocks a frame, 60.009 Hz): the picture 50
//      us of the 61.7 us line, as wide as a usual 320-dot arcade board's on a CRT; 3 / 3 / 8 lines of front porch, vsync and back
//      porch;
//   1: 263 lines of 406 dots of 15 clocks (6.4 MHz; 6,090 clocks, 15.76 kHz; 1,601,670 clocks a frame, 59.937 Hz), for a
//      RetroTINK 4K in direct video (DV1), which takes 262-264 lines as "MiSTer 240p" and a 6.4 MHz dot's picture as 4:3 wide (an 8
//      MHz dot came out narrow): 2 / 2 / 3 lines, so the framework's direct-video DE is exactly the 256 lines;
//   2: 263 lines of 406 dots of 15 clocks (6.4 MHz; 6,090 clocks, 15.76 kHz; 1,601,670 clocks a frame, 59.937 Hz), for a consumer
//      CRT that wants a standard 240p signal: the 256 lines' middle 240 shown (8 blanked at the top and the bottom, which such a set
//      hides anyway), 3 / 3 / 17 lines.
// So the game runs at 60.009 or 59.937 frames a second, not MAME's 60.000. MAME_FRAME (the benches' define, never the
// core's) makes the frame's last line, in the vertical blank, as long as MAME's frame wants (6,175 or 4,420 clocks:
// 1,600,000), for the cycle-by-cycle comparisons with MAME.
// The visible line 0 is MAME's bitmap row 16. The vblank begins at line 256 (vbl_ev): MAME's vblank, the 68000's IRQ 1. The raster
// runs from power-up on, through resets (the core starts the CPUs PRE clocks before a vblank, vbl_pre).
//
// Flip (d80020 bits 1:0, which MAME does not have: the game writes 01a0, and 01a3 with its Flip Screen DIP on, and adds 8 to the
// txt layer's x scroll then; MAME shows the game unflipped with that txt offset): the picture turned 180 degrees, MAME's unflipped
// picture dot for dot, the txt layer's 8 taken back off. Which bit turns which axis is a guess (bit 0 x, bit 1 y): the game sets
// both. Taken at the vblank with the scroll words.
//
// Each visible line is drawn during the line before it into ping-pong line buffers (a layer each; the sprites' with a claim bit a
// pixel) and mixed as the beam runs, in MAME's order (screen_update): bak cat 0 (priority 1), mid cat 0 (2), txt cat 1 (4), bak cat 1
// (8), the sprites (a sprite with colour bit 3 is not drawn where the priority has bit 1 or 2: MAME's pri_mask GFX_PMASK_2 | 4 | 8),
// mid cat 1, txt cat 0, over palette entry 0; then the palette.
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_video #(
    parameter int PRE = 33              // vbl_pre: this many clocks before vbl_ev
) (
    input  logic        clk,            // 96 MHz
    input  logic        rst_raster,     // the raster's power-up reset
    input  logic        reset,          // the machine's
    input  logic  [1:0] vmode,          // the raster: 0 270 lines, 1 263 (RT4K), 2 263 (CRT 240p) (taken at a frame's start)
    input  logic  [1:0] flip,           // d80020 bits 1:0: {y, x}

    // the 68000's port to the video memories
    input  logic        c_mid,
    input  logic        c_bak,
    input  logic        c_txt,
    input  logic        c_spr,
    input  logic        c_pal,
    input  logic        c_scr,
    input  logic [12:1] c_addr,         // the word in the region (the scroll words: 0..5)
    input  logic [15:0] c_wdata,
    input  logic  [1:0] c_be,           // {UDS, LDS}
    input  logic        c_we,           // one clock
    output logic [15:0] c_rdata,        // the word at c_addr, one clock after it

    output logic        c_hold,         // the write at c_addr must wait: the snapshot has not yet copied its entry
    output logic        vbl_ev,         // one clock: the vertical blank begins
    output logic        vbl_pre,        // one clock, PRE clocks before vbl_ev

    // the SDRAM clients: 0 txt, 1 mid, 2 bak, 3 sprites
    output logic        m_req   [4],
    output logic [23:0] m_addr  [4],
    output logic  [4:0] m_len   [4],
    input  logic        m_ack   [4],
    input  logic        m_valid [4],
    input  logic [15:0] m_rdata,

    output logic        ce_pix,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_vblank_next,  // the next line is in the vertical blank
    output logic  [7:0] o_r,
    output logic  [7:0] o_g,
    output logic  [7:0] o_b
);
    // ================================================================== the raster
    logic  [1:0] mode;                          // the frame's vmode
    logic  [8:0] L, HS_A, HS_B, VS_A, VS_B, VB_A, VB_B;
    logic  [3:0] DOTC;
    logic [12:0] LLEN, LL_M;
    always_comb begin
        // lines, clocks a dot, clocks a line, hsync (dots), vsync (lines), the picture's lines [VB_B, VB_A), the last line for MAME_FRAME
        case (mode)
            2'd1:    begin L = 9'd263; DOTC = 4'd15; LLEN = 13'd6090; HS_A = 9'd334; HS_B = 9'd364; VS_A = 9'd258; VS_B = 9'd260;
                           VB_B = 9'd0; VB_A = 9'd256; LL_M = 13'd4420; end
            2'd2:    begin L = 9'd263; DOTC = 4'd15; LLEN = 13'd6090; HS_A = 9'd334; HS_B = 9'd364; VS_A = 9'd251; VS_B = 9'd254;
                           VB_B = 9'd8; VB_A = 9'd248; LL_M = 13'd4420; end
            default: begin L = 9'd270; DOTC = 4'd15; LLEN = 13'd5925; HS_A = 9'd330; HS_B = 9'd360; VS_A = 9'd259; VS_B = 9'd262;
                           VB_B = 9'd0; VB_A = 9'd256; LL_M = 13'd6175; end
        endcase
    end
`ifdef MAME_FRAME
    wire  [12:0] LLAST  = LL_M;                         // the frame's last line: L lines of 1,600,000 clocks
`else
    wire  [12:0] LLAST  = LLEN;
`endif

    logic [12:0] hc;                            // clock in the line
    logic  [3:0] sub;                           // clock in the dot
    logic  [8:0] dot;
    logic  [8:0] line;
    wire         line_end = (hc == ((line == L - 9'd1) ? LLAST : LLEN) - 13'd1);
    assign ce_pix = (sub == DOTC - 4'd1) || line_end;   // the last clock of a dot

    // the frame's first line, 256, takes the new mode
    wire  [8:0]  nline  = (line == L - 9'd1) ? 9'd0 : line + 9'd1;

    always_ff @(posedge clk) begin
        if (rst_raster) begin
            hc <= 13'd0; sub <= 4'd0; dot <= 9'd0; line <= 9'd256; mode <= 2'd0;
        end else if (line_end) begin
            hc <= 13'd0; sub <= 4'd0; dot <= 9'd0;
            line <= nline;
            if (nline == 9'd256) mode <= (vmode == 2'd3) ? 2'd0 : vmode;
        end else begin
            hc <= hc + 13'd1;
            if (sub == DOTC - 4'd1) begin sub <= 4'd0; dot <= dot + 9'd1; end
            else sub <= sub + 4'd1;
        end
    end

    wire line_start = (hc == 13'd0);
    assign vbl_ev  = line_start && (line == 9'd256) && !rst_raster;
    assign vbl_pre = (hc == LLEN - 13'(PRE)) && (line == 9'd255) && !rst_raster;

    // ================================================================== the video memories
    // live copies: port A the 68000's, port B the snapshot's read
    logic [63:0] mid_lq, bak_lq, txt_lq0, txt_lq1, spr_lq, pal_lq;
    logic [63:0] mid_lb, bak_lb, txt_lb0, txt_lb1, spr_lb, pal_lb;
    logic  [8:0] cp_ra;                         // the snapshot's read address

    wire  [1:0] cw   = c_addr[2:1];             // the word in a 64-bit entry
    wire  [7:0] be_w = {6'd0, c_be} << {cw, 1'b0};
    wire  [7:0] be_s = {7'd0, c_be[0]} << c_addr[3:1];
    aquarium_bram #(.AW(9), .NB(8)) u_mid_l (.clk(clk), .a_addr(c_addr[11:3]), .a_wdata({4{c_wdata}}), .a_be(be_w), .a_we(c_we && c_mid),
                                             .a_q(mid_lq), .b_addr(cp_ra), .b_q(mid_lb));
    aquarium_bram #(.AW(9), .NB(8)) u_bak_l (.clk(clk), .a_addr(c_addr[11:3]), .a_wdata({4{c_wdata}}), .a_be(be_w), .a_we(c_we && c_bak),
                                             .a_q(bak_lq), .b_addr(cp_ra), .b_q(bak_lb));
    // the txt VRAM's 1,024 entries in two banks (the entry's bit 0), so that the snapshot copies two at a time
    aquarium_bram #(.AW(9), .NB(8)) u_txt_l0 (.clk(clk), .a_addr(c_addr[12:4]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                              .a_we(c_we && c_txt && !c_addr[3]), .a_q(txt_lq0), .b_addr(cp_ra), .b_q(txt_lb0));
    aquarium_bram #(.AW(9), .NB(8)) u_txt_l1 (.clk(clk), .a_addr(c_addr[12:4]), .a_wdata({4{c_wdata}}), .a_be(be_w),
                                              .a_we(c_we && c_txt && c_addr[3]), .a_q(txt_lq1), .b_addr(cp_ra), .b_q(txt_lb1));
    aquarium_bram #(.AW(9), .NB(8)) u_pal_l (.clk(clk), .a_addr(c_addr[11:3]), .a_wdata({4{c_wdata}}), .a_be(be_w), .a_we(c_we && c_pal),
                                             .a_q(pal_lq), .b_addr(cp_ra), .b_q(pal_lb));
    // the sprite RAM: a sprite's 8 bytes an entry (the 68000's byte offset (A - c80000) / 2: entry bits 11:3, byte 2:0)
    aquarium_bram #(.AW(9), .NB(8)) u_spr_l (.clk(clk), .a_addr(c_addr[12:4]), .a_wdata({8{c_wdata[7:0]}}), .a_be(be_s), .a_we(c_we && c_spr),
                                             .a_q(spr_lq), .b_addr(cp_ra), .b_q(spr_lb));

    // the scroll words
    logic [15:0] scr_l [6];
    logic [15:0] scr_d [6];
    always_ff @(posedge clk) begin
        if (c_we && c_scr && c_addr[3:1] < 3'd6) begin
            if (c_be[1]) scr_l[c_addr[3:1]][15:8] <= c_wdata[15:8];
            if (c_be[0]) scr_l[c_addr[3:1]][7:0]  <= c_wdata[7:0];
        end
    end

    // the 68000's read: the word of the entry (the sprite RAM's byte on the low lane, 0 above it, MAME's umask16(0x00ff))
    logic       r_mid, r_bak, r_txt, r_spr, r_pal, r_tb;
    logic [1:0] r_cw;
    logic [2:0] r_sb;
    always_ff @(posedge clk) begin
        r_mid <= c_mid; r_bak <= c_bak; r_txt <= c_txt; r_spr <= c_spr; r_pal <= c_pal;
        r_cw <= cw; r_sb <= c_addr[3:1]; r_tb <= c_addr[3];
    end
    always_comb begin
        if      (r_mid) c_rdata = mid_lq[16 * r_cw +: 16];
        else if (r_bak) c_rdata = bak_lq[16 * r_cw +: 16];
        else if (r_txt) c_rdata = r_tb ? txt_lq1[16 * r_cw +: 16] : txt_lq0[16 * r_cw +: 16];
        else if (r_pal) c_rdata = pal_lq[16 * r_cw +: 16];
        else if (r_spr) c_rdata = {8'h00, spr_lq[8 * r_sb +: 8]};
        else            c_rdata = 16'h0000;
    end

    // ------------------------------------------------------------------ the snapshot
    // from vbl_ev: entry i is read from the live copies at clock i, written to the display copies at clock i + 1 (512 entries, the
    // txt VRAM's two banks side by side: 512 clocks, 5.3 us); the sprite list goes to buffer `sb` (flipped at each vblank), the frame
    // shows ~sb
    logic        cp_on, cp_w;
    logic  [8:0] cp_wa;
    logic  [1:0] flip_d;                        // the frame's flip: {y, x}
    /* verilator lint_off PROCASSINIT */
    logic        sb = 1'b0;
    /* verilator lint_on PROCASSINIT */
    initial for (int i = 0; i < 6; i++) begin scr_l[i] = 16'd0; scr_d[i] = 16'd0; end
    always_ff @(posedge clk) begin
        cp_w <= 1'b0;
        if (reset) begin
            cp_on <= 1'b0; cp_ra <= 9'd0; flip_d <= 2'd0;
        end else if (vbl_ev) begin
            cp_on <= 1'b1; cp_ra <= 9'd0;
            sb <= ~sb;
            for (int i = 0; i < 6; i++) scr_d[i] <= scr_l[i];
            flip_d <= flip;
        end else if (cp_on) begin
            cp_w  <= 1'b1;
            cp_wa <= cp_ra;
            cp_ra <= cp_ra + 9'd1;
            if (cp_ra == 9'd511) cp_on <= 1'b0;
        end
    end
    // a write waits while the snapshot is still to copy its entry (from vbl_ev, the snapshot's instant, until the copy's read has
    // passed the entry: the copy reads entry cp_ra in this clock, so a write to an entry below it changes only the live copy)
    wire  [8:0] c_ent = (c_txt || c_spr) ? c_addr[12:4] : c_addr[11:3];
    assign c_hold = vbl_ev || (cp_on && (c_scr ? 1'b0 : (c_ent >= cp_ra)));

    // display copies: port A the snapshot's write, port B the drawing's read
    logic  [9:0] t_va, m_va, b_va;
    logic [63:0] t_vq, t_vq0, t_vq1, m_vq, b_vq, s_q, p_q;
    logic  [8:0] s_a;
    logic  [8:0] p_a;
    logic        t_vb;
    logic [63:0] unused_a0, unused_a1, unused_a2, unused_a2b, unused_a3, unused_a4;
    aquarium_dpram #(.AW(9), .DW(64)) u_mid_d (.clk(clk), .a_addr(cp_wa), .a_wdata(mid_lb), .a_we(cp_w), .a_q(unused_a0),
                                               .b_addr(m_va[8:0]), .b_q(m_vq));
    aquarium_dpram #(.AW(9), .DW(64)) u_bak_d (.clk(clk), .a_addr(cp_wa), .a_wdata(bak_lb), .a_we(cp_w), .a_q(unused_a1),
                                               .b_addr(b_va[8:0]), .b_q(b_vq));
    aquarium_dpram #(.AW(9), .DW(64)) u_txt_d0 (.clk(clk), .a_addr(cp_wa), .a_wdata(txt_lb0), .a_we(cp_w), .a_q(unused_a2),
                                                .b_addr(t_va[9:1]), .b_q(t_vq0));
    aquarium_dpram #(.AW(9), .DW(64)) u_txt_d1 (.clk(clk), .a_addr(cp_wa), .a_wdata(txt_lb1), .a_we(cp_w), .a_q(unused_a2b),
                                                .b_addr(t_va[9:1]), .b_q(t_vq1));
    always_ff @(posedge clk) t_vb <= t_va[0];
    assign t_vq = t_vb ? t_vq1 : t_vq0;
    aquarium_dpram #(.AW(9), .DW(64)) u_pal_d (.clk(clk), .a_addr(cp_wa), .a_wdata(pal_lb), .a_we(cp_w), .a_q(unused_a3),
                                               .b_addr(p_a), .b_q(p_q));
    aquarium_dpram #(.AW(10), .DW(64)) u_spr_d (.clk(clk), .a_addr({sb, cp_wa}), .a_wdata(spr_lb), .a_we(cp_w), .a_q(unused_a4),
                                                .b_addr({~sb, s_a}), .b_q(s_q));

    // ================================================================== drawing the next line
    // at the start of each line the next visible line is started (bitmap row = line + 16; flipped, row 271 - line) into line buffer
    // bank line[0]
    wire        r_go = line_start && (nline < 9'd256) && !reset && !rst_raster;
    wire  [8:0] r_yb = (flip_d[1] ? 9'd255 - nline : nline) + 9'd16;
    wire [15:0] t_sx = flip_d[0] ? scr_d[4] - 16'd8 : scr_d[4];
    logic       t_busy, m_busy, b_busy, s_busy;

    logic        t_lwe, m_lwe, b_lwe, s_lwe;
    logic  [9:0] t_lwa, m_lwa, b_lwa, s_lwa;
    logic [10:0] t_lwd, m_lwd, b_lwd;
    logic  [7:0] s_lwd;

    aquarium_tmap #(.BIG(1'b0), .GFX_W(24'h080000)) u_txt (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .scrollx(t_sx), .scrolly(scr_d[5]), .busy(t_busy),
        .v_addr(t_va), .v_q(t_vq),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_rdata(m_rdata),
        .lb_we(t_lwe), .lb_addr(t_lwa), .lb_data(t_lwd)
    );
    aquarium_tmap #(.BIG(1'b1), .GFX_W(24'h100000)) u_mid (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .scrollx(scr_d[0]), .scrolly(scr_d[1]), .busy(m_busy),
        .v_addr(m_va), .v_q(m_vq),
        .m_req(m_req[1]), .m_addr(m_addr[1]), .m_len(m_len[1]), .m_ack(m_ack[1]), .m_valid(m_valid[1]), .m_rdata(m_rdata),
        .lb_we(m_lwe), .lb_addr(m_lwa), .lb_data(m_lwd)
    );
    aquarium_tmap #(.BIG(1'b1), .GFX_W(24'h180000)) u_bak (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .scrollx(scr_d[2]), .scrolly(scr_d[3]), .busy(b_busy),
        .v_addr(b_va), .v_q(b_vq),
        .m_req(m_req[2]), .m_addr(m_addr[2]), .m_len(m_len[2]), .m_ack(m_ack[2]), .m_valid(m_valid[2]), .m_rdata(m_rdata),
        .lb_we(b_lwe), .lb_addr(b_lwa), .lb_data(b_lwd)
    );

    logic       d_bank;
    logic [8:0] d_x;
    logic       s_claim;
    aquarium_sprites #(.GFX_W(24'h200000)) u_spr (
        .clk(clk), .reset(reset), .start(r_go), .yb(r_yb), .bank(nline[0]), .busy(s_busy),
        .s_addr(s_a), .s_q(s_q),
        .m_req(m_req[3]), .m_addr(m_addr[3]), .m_len(m_len[3]), .m_ack(m_ack[3]), .m_valid(m_valid[3]), .m_rdata(m_rdata),
        .lb_we(s_lwe), .lb_addr(s_lwa), .lb_data(s_lwd), .d_bank(d_bank), .d_x(d_x), .d_claimed(s_claim)
    );

    // the line buffers: port A the drawing's, port B the display's
    logic [10:0] t_px, m_px, b_px;
    logic  [7:0] s_px;
    logic [10:0] lb_u0, lb_u1, lb_u2;
    logic  [7:0] lb_u3;
    aquarium_dpram #(.AW(10), .DW(11)) u_lb_t (.clk(clk), .a_addr(t_lwa), .a_wdata(t_lwd), .a_we(t_lwe), .a_q(lb_u0),
                                               .b_addr({d_bank, d_x}), .b_q(t_px));
    aquarium_dpram #(.AW(10), .DW(11)) u_lb_m (.clk(clk), .a_addr(m_lwa), .a_wdata(m_lwd), .a_we(m_lwe), .a_q(lb_u1),
                                               .b_addr({d_bank, d_x}), .b_q(m_px));
    aquarium_dpram #(.AW(10), .DW(11)) u_lb_b (.clk(clk), .a_addr(b_lwa), .a_wdata(b_lwd), .a_we(b_lwe), .a_q(lb_u2),
                                               .b_addr({d_bank, d_x}), .b_q(b_px));
    aquarium_dpram #(.AW(10), .DW(8)) u_lb_s (.clk(clk), .a_addr(s_lwa), .a_wdata(s_lwd), .a_we(s_lwe), .a_q(lb_u3),
                                              .b_addr({d_bank, d_x}), .b_q(s_px));

    // ================================================================== the dot
    // sub 0: the line buffers' address (the dot); sub 1: their words, the mix (MAME's order), the palette's address; sub 2: the
    // palette entry; sub 3: the colour. Latched with the raster's signals at the dot's last clock (ce_pix): the outputs are one dot
    // behind the counters, all of them together. Flipped, the line is read from its end.
    always_ff @(posedge clk) begin
        d_bank <= line[0];
        d_x    <= flip_d[0] ? 9'd319 - dot : dot;
    end

    wire        bk_op = (b_px[4:0] != 5'd0), bk_cat = b_px[10];
    wire        md_op = (m_px[4:0] != 5'd0), md_cat = m_px[10];
    wire        tx_op = (t_px[3:0] != 4'd0), tx_cat = t_px[8];     // the txt colour's bit 3 is its category
    wire        sp_lo = s_px[7];                                    // the sprite colour's bit 3: behind mid cat 0 and txt cat 1
    wire [10:0] bk_i  = {1'b1, b_px[9:0]};                          // 0x400 + colour * 32 + pen
    wire [10:0] md_i  = {1'b1, m_px[9:0]};
    wire [10:0] tx_i  = {3'b010, t_px[8:5], t_px[3:0]};            // 0x200 + colour * 16 + pen
    wire [10:0] sp_i  = {3'b011, s_px};                             // 0x300 + colour * 16 + pen
    logic [10:0] mix;
    always_comb begin
        logic [3:0] pri;
        mix = 11'd0; pri = 4'd0;
        if (bk_op && !bk_cat) begin mix = bk_i; pri = pri | 4'd1; end
        if (md_op && !md_cat) begin mix = md_i; pri = pri | 4'd2; end
        if (tx_op &&  tx_cat) begin mix = tx_i; pri = pri | 4'd4; end
        if (bk_op &&  bk_cat) begin mix = bk_i; pri = pri | 4'd8; end
        if (s_claim && (!sp_lo || pri[2:1] == 2'd0)) mix = sp_i;
        if (md_op &&  md_cat) mix = md_i;
        if (tx_op && !tx_cat) mix = tx_i;
    end

    logic [1:0] p_sel;
    always_ff @(posedge clk) begin
        p_a   <= mix[10:2];
        p_sel <= mix[1:0];
    end
    wire [15:0] pw = p_q[16 * p_sel +: 16];
    // RRRRGGGGBBBBRGBx, 5 bits each (MAME's RRRRGGGGBBBBRGBx_decoder), pal5bit
    wire  [4:0] c5r = {pw[15:12], pw[3]};
    wire  [4:0] c5g = {pw[11:8],  pw[2]};
    wire  [4:0] c5b = {pw[7:4],   pw[1]};
    logic [7:0] cr, cg, cb;
    always_ff @(posedge clk) begin
        cr <= {c5r, c5r[4:2]};
        cg <= {c5g, c5g[4:2]};
        cb <= {c5b, c5b[4:2]};
    end

    wire pic_l   = (line >= VB_B) && (line < VB_A);            // a picture line (CRT 240p: the 256 lines' middle 240)
    wire pic_n   = (nline >= VB_B) && (nline < VB_A);
    wire visible = (dot < 9'd320) && pic_l;
    always_ff @(posedge clk) begin
        if (ce_pix) begin
            o_r <= (visible && !reset) ? cr : 8'd0;
            o_g <= (visible && !reset) ? cg : 8'd0;
            o_b <= (visible && !reset) ? cb : 8'd0;
            o_hblank <= (dot >= 9'd320);
            o_hs     <= (dot >= HS_A) && (dot < HS_B);
            o_vblank <= !pic_l;
            o_vs     <= (line >= VS_A) && (line < VS_B);
            o_vblank_next <= !pic_n;
        end
    end

    wire unused = &{1'b0, LL_M, t_busy, m_busy, b_busy, s_busy, unused_a0, unused_a1, unused_a2, unused_a2b, unused_a3, unused_a4,
                    lb_u0, lb_u1, lb_u2, lb_u3, t_px[10:9], t_px[4], m_va[9], b_va[9], pw[0]};
endmodule
`default_nettype wire
