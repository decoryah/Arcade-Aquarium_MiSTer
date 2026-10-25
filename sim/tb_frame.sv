// The frame bench: aquarium_video alone, behind aquarium_sdram and the behavioural SDRAM, with the ROM image (+IMAGE=<file>)
// downloaded through aquarium_loader first. sim/tb_frame.cpp writes MAME's video state (tools/lua/dump.lua's ram_<f>.bin) into the
// live video memories through the 68000's port, the snapshot takes it at the vblank, and the frame after it is captured: the core's
// picture of MAME's state, to compare with MAME's snapshot of the same frame. Driven by sim/run_frames.sh.
`default_nettype none
module tb_frame (
    input  logic        clk,
    input  logic        reset_in,
    // the 68000's port (aquarium_video's c_*)
    input  logic        c_mid, c_bak, c_txt, c_spr, c_pal, c_scr,
    input  logic [12:1] c_addr,
    input  logic [15:0] c_wdata,
    input  logic  [1:0] c_be,
    input  logic        c_we,
    output logic        c_hold,
    output logic        vbl_ev,
    output logic        loaded,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b
);
    logic [7:0] img [1 << 22];
    int         img_len = 0;
    logic [1:0] vmode = 2'd0;
    initial begin
        string f;
        int fd;
        if ($value$plusargs("IMAGE=%s", f)) begin
            fd = $fopen(f, "rb");
            if (fd == 0) begin $display("tb: cannot open %s", f); $finish; end
            img_len = $fread(img, fd);
            $fclose(fd);
        end else begin
            $display("tb: no +IMAGE=<file>"); $finish;
        end
        vmode = $test$plusargs("M263") ? 2'd1 : $test$plusargs("M240") ? 2'd2 : 2'd0;
    end

    localparam int NC = 4;
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
    aquarium_loader u_loader (.clk(clk), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .o_wr(ld_wr), .o_addr(ld_addr), .o_data(ld_data));

    logic mc_reset;
    logic [9:0] tail;
    always_ff @(posedge clk) begin
        if (reset_in || dl_on || dl_wr || dl_busy) tail <= 10'd0;
        else if (tail != 10'h3ff) tail <= tail + 10'd1;
        mc_reset <= reset_in || !sd_ready || (tail != 10'h3ff);
    end
    assign loaded = !mc_reset;

    logic [15:0] c_rdata_unused;
    logic        hs_unused, vs_unused, vbn_unused;
    aquarium_video u_video (
        .clk(clk), .rst_raster(reset_in), .reset(mc_reset), .vmode(vmode), .flip(2'b00),
        .c_mid(c_mid), .c_bak(c_bak), .c_txt(c_txt), .c_spr(c_spr), .c_pal(c_pal), .c_scr(c_scr),
        .c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be), .c_we(c_we), .c_rdata(c_rdata_unused),
        .c_hold(c_hold), .vbl_ev(vbl_ev), .vbl_pre(),
        .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack), .m_valid(m_valid), .m_rdata(m_rdata),
        .ce_pix(ce_pix), .o_hs(hs_unused), .o_vs(vs_unused), .o_hblank(hblank), .o_vblank(vblank), .o_vblank_next(vbn_unused),
        .o_r(r), .o_g(g), .o_b(b)
    );
endmodule
`default_nettype wire
