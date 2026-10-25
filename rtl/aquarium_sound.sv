//------------------------------------------------------------------------------
// Aquarium's sound board: the Z80, the YM2151, the MSM6295 and the 68000's sound latch, written from MAME 0.289's
// src/mame/excellent/aquarium.cpp (with machine/gen_latch.cpp, sound/okim6295.cpp, sound/ymopm.cpp).
//
//   Z80 at 32 MHz / 6 (5.333 MHz): 0000-3fff ROM (the first 16 KB of the 256 KB), 7800-7fff RAM, 8000-ffff a 32 KB bank of the ROM
//   (z80_bank_w: the byte bitswapped 7,6,5,2,3,1,4,0, bits 2:0 the bank: the written bits 1, 4, 0); anything else reads 0.
//   I/O (8 bits): 00 / 01 YM2151 (a read of 00 gives 0xff, of 01 the status: ymfm's ym2151::read), 02 MSM6295 (both ways through
//   aquarium_state::snd_bitswap, the bits reversed), 04 the sound latch, 06 the latch's acknowledge (write), 08 the bank.
//   The NMI is the latch's pending flag (a separate acknowledge: reading does not clear it, writing 06 does); the IRQ (IM 1) the
//   YM2151's. The 68000 writes the latch (d8008b) and reads the pending flag (SYSTEM bit 15).
//   YM2151 at 14.31818 MHz / 4 (jt51; 3,579,545 Hz as a fractional clock enable of 96 MHz), MSM6295 at 1.056 MHz with pin 7 high
//   (one sample every 12,000 clocks: 8 kHz).
//
// The mix is MAME's: a stereo speaker, the YM2151's left and right at 0.45 each and the OKI at 0.47 to both, as 16 bits (ymfm's
// samples are 16-bit; the OKI's sum is in units of 1/2048 of full scale, so 0.47 of it is 7.52 x its sum): out = 0.45 * ym + 7.52 *
// oki, rounded down, clamped.
//
// Clocking and MAME's timeline (the owner's Hexion core's scheme): the Z80 steps once per 18 clocks of 96 MHz from its start, as
// MAME's Z80 starts executing at time 0. Its ROM is read through a cache from the SDRAM (rtl/aquarium_cache.sv); while a miss is
// filled its clock enable is held and the cycles it missed are given back right after at one step per 8 clocks, so the program
// stays on MAME's timeline; an interrupt raised meanwhile is held back by the steps still owed.
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_sound (
    input  logic        clk,            // 96 MHz
    input  logic        mreset,         // the machine's reset (the ROM cache's: its tags are cleared before the CPUs start)
    input  logic        reset,          // the sound board's (its start: MAME's time 0)

    // the 68000's side of the latch
    input  logic        latch_wr,       // one clock
    input  logic  [7:0] latch_din,
    output logic        latch_pending,

    // SDRAM clients: 0 the Z80's ROM cache, 1 the OKI
    output logic        m_req   [2],
    output logic [23:0] m_addr  [2],
    output logic  [4:0] m_len   [2],
    input  logic        m_ack   [2],
    input  logic        m_valid [2],
    input  logic [15:0] m_rdata,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic [15:0] dbg_pc
);
    // ------------------------------------------------------------------ clock enables
    logic [4:0] div;                    // the Z80's nominal cycle: one in 18 clocks
    always_ff @(posedge clk) div <= (reset || div == 5'd17) ? 5'd0 : div + 5'd1;
    wire  tick = (div == 5'd17);

    // the OKI's sample: 1.056 MHz / 132 = 8 kHz, one in 12,000 clocks
    logic [13:0] oki_div;
    logic        oki_tick;
    always_ff @(posedge clk) begin
        oki_tick <= 1'b0;
        if (reset) oki_div <= 14'd0;
        else if (oki_div == 14'd11999) begin oki_div <= 14'd0; oki_tick <= 1'b1; end
        else oki_div <= oki_div + 14'd1;
    end

    // the YM2151's clock: 3,579,545 Hz of 96 MHz (cen), and half of it (cen_p1). It runs while the board is held in reset too: jt51
    // keeps its operators' state in shift registers that take their reset values (the envelopes silent, in release) only as they shift
    // on cen during its reset; without it they start at full level in attack, and a channel never keyed on sounds. The board's start
    // (MAME's time 0) restarts it from phase 0, as jt51's counters leave their reset there
    logic [26:0] ym_acc;
    logic        ym_cen, ym_cen_p1, ym_half;
    logic        reset_d;
    always_ff @(posedge clk) reset_d <= reset;
    always_ff @(posedge clk) begin
        ym_cen <= 1'b0; ym_cen_p1 <= 1'b0;
        if (mreset || (reset_d && !reset)) begin
            ym_acc <= 27'd0; ym_half <= 1'b0;
        end else if (ym_acc >= 27'd96000000 - 27'd3579545) begin
            ym_acc <= ym_acc + 27'd3579545 - 27'd96000000;
            ym_cen <= 1'b1;
            ym_half <= ~ym_half;
            ym_cen_p1 <= ym_half;
        end else
            ym_acc <= ym_acc + 27'd3579545;
    end

    // ------------------------------------------------------------------ the Z80
    logic        cpu_ce;
    logic        stall;
    logic  [7:0] owed;                  // nominal cycles the Z80 has not had yet
    logic  [2:0] gap;                   // clocks since its last step (saturating at 7)
    always_comb cpu_ce = !reset && !stall && (gap == 3'd7) && ((owed != 8'd0) || tick);
    always_ff @(posedge clk) begin
        if (reset) begin
            // one step at the first clock: tv80 spends a step after reset before its first fetch (the Hexion core's finding)
            owed <= 8'd1; gap <= 3'd7;
        end else begin
            gap <= cpu_ce ? 3'd0 : (gap == 3'd7) ? 3'd7 : gap + 3'd1;
            case ({tick, cpu_ce})
                2'b10:   owed <= (owed == 8'hff) ? owed : owed + 8'd1;
                2'b01:   owed <= owed - 8'd1;
                default: ;
            endcase
        end
    end
    wire  [7:0] owed_next = (tick && !cpu_ce) ? owed + 8'd1 : (cpu_ce && !tick) ? owed - 8'd1 : owed;   // after this clock

    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic  [7:0] cpu_di, cpu_do;
    logic        irq_line, nmi_line;

    tv80s_cen u_cpu (
        .reset_n(~reset), .clk(clk), .cen(cpu_ce), .wait_n(1'b1),
        .int_n(~irq_line), .nmi_n(~nmi_line), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;

    // The Z80 steps on a clock enable at least 8 clocks apart, so its outputs are multicycle paths (Aquarium.sdc): the board sees the
    // strobes four clocks after the CPU raises them. A write becomes one pulse per bus cycle. The interrupt acknowledge (M1 with
    // IORQ) is not an I/O read.
    wire  mem_rd_raw = !mreq_n && !rd_n;
    wire  mem_wr_raw = !mreq_n && !wr_n;
    wire  io_rd_raw  = !iorq_n && !rd_n && m1_n;
    wire  io_wr_raw  = !iorq_n && !wr_n;
    logic [4:0] rd_dl, wr_dl, ird_dl, iwr_dl;
    always_ff @(posedge clk) begin
        rd_dl  <= {rd_dl[3:0], mem_rd_raw};
        wr_dl  <= {wr_dl[3:0], mem_wr_raw};
        ird_dl <= {ird_dl[3:0], io_rd_raw};
        iwr_dl <= {iwr_dl[3:0], io_wr_raw};
    end
    wire  mem_rd   = rd_dl[3];
    wire  rd_start = rd_dl[3] && !rd_dl[4];
    wire  mem_wr   = wr_dl[3] && !wr_dl[4];
    wire  io_rd    = ird_dl[3];
    wire  io_rds   = ird_dl[3] && !ird_dl[4];
    wire  io_wr    = iwr_dl[3] && !iwr_dl[4];

    // ------------------------------------------------------------------ decode
    wire sel_rom  = (A[15:14] == 2'b00) || A[15];
    wire sel_ram  = (A[15:11] == 5'b01111);
    wire [7:0] port = A[7:0];

    logic [2:0] bank;
    wire [17:0] rom_b = A[15] ? {bank, A[14:0]} : {4'd0, A[13:0]};

    // ------------------------------------------------------------------ the ROM (through the cache) and the RAM
    logic        c_ready, c_ack;
    logic [15:0] c_q;
    logic        rom_wait, rom_ok, rom_ok2;
    logic  [7:0] rom_byte;
    logic        rom_odd;
    aquarium_cache #(.AW(17), .IDX(8), .BASE(24'h040000)) u_cache (
        .clk(clk), .reset(mreset), .ready(c_ready),
        .req(rd_start && sel_rom), .addr(rom_b[17:1]), .ack(c_ack), .q(c_q),
        .m_req(m_req[0]), .m_addr(m_addr[0]), .m_len(m_len[0]), .m_ack(m_ack[0]), .m_valid(m_valid[0]), .m_data(m_rdata)
    );
    always_ff @(posedge clk) begin
        if (reset) begin
            rom_wait <= 1'b0; rom_ok <= 1'b0;
        end else begin
            if (rd_start && sel_rom) begin rom_wait <= 1'b1; rom_ok <= 1'b0; rom_odd <= rom_b[0]; end
            else if (rom_wait && c_ack) begin
                rom_wait <= 1'b0; rom_ok <= 1'b1;
                rom_byte <= rom_odd ? c_q[7:0] : c_q[15:8];
            end
            if (!mem_rd) rom_ok <= 1'b0;
        end
        rom_ok2 <= rom_ok && mem_rd;                // cpu_di has the byte (a clock after rom_byte)
    end

    logic [7:0] ram_q;
    aquarium_spram #(.AW(11), .DW(8)) u_ram (.clk(clk), .addr(A[10:0]), .wdata(cpu_do), .we(mem_wr && sel_ram), .q(ram_q));

    // the Z80 waits for a ROM read's word (a cache miss: an SDRAM burst); the cache clears its tags after the machine's reset, long
    // before the CPUs start (rtl/aquarium_core.sv)
    always_comb stall = mem_rd && sel_rom && !rom_ok2;

    // ------------------------------------------------------------------ the latch
    logic [7:0] latch;
    always_ff @(posedge clk) begin
        if (reset) begin
            latch <= 8'd0; latch_pending <= 1'b0;
        end else begin
            if (io_wr && port == 8'h06) latch_pending <= 1'b0;
            if (latch_wr) begin latch <= latch_din; latch_pending <= 1'b1; end
        end
    end

    // ------------------------------------------------------------------ the bank
    // bitswap<8>(data, 7, 6, 5, 2, 3, 1, 4, 0): result bit 2 = data bit 1, bit 1 = data bit 4, bit 0 = data bit 0
    always_ff @(posedge clk) begin
        if (reset) bank <= 3'd0;
        else if (io_wr && port == 8'h08) bank <= {cpu_do[1], cpu_do[4], cpu_do[0]};
    end

    // ------------------------------------------------------------------ the YM2151 (jt51)
    // jt51 takes a register on any clock its write is high but sets its busy flag on cen_p1: a write is given to it from the clock
    // after a cen_p1 to the next cen_p1 (half a microsecond after the Z80's OUT at most; the Z80's next instruction comes later).
    // Starting right after a cen_p1, the registers a write changes have settled 26 clocks before the chip's next clock enable, which
    // the two-clock constraint on jt51's own paths relies on (Aquarium.sdc)
    // (writes wait in a 4-entry queue: catching up after a cache miss the Z80 can OUT twice within one such window)
    logic       ym_wr, ym_a0;
    logic [7:0] ym_din;
    logic [8:0] ymq [4];
    logic [1:0] ymq_wp, ymq_rp;
    logic [2:0] ymq_n;
    wire        ymq_push = io_wr && port[7:1] == 7'd0;
    wire        ymq_pop  = ym_cen_p1 && !ym_wr && ymq_n != 3'd0;
    always_ff @(posedge clk) begin
        if (reset) begin ymq_wp <= 2'd0; ymq_rp <= 2'd0; ymq_n <= 3'd0; ym_wr <= 1'b0; end
        else begin
            if (ymq_push) begin ymq[ymq_wp] <= {port[0], cpu_do}; ymq_wp <= ymq_wp + 2'd1; end
            if (ymq_pop) begin {ym_a0, ym_din} <= ymq[ymq_rp]; ymq_rp <= ymq_rp + 2'd1; end
            case ({ymq_push, ymq_pop})
                2'b10:   ymq_n <= ymq_n + 3'd1;
                2'b01:   ymq_n <= ymq_n - 3'd1;
                default: ;
            endcase
            if (ym_cen_p1) ym_wr <= ymq_pop;
        end
    end
    logic  [7:0] ym_dout;
    logic        ym_irq_n;
    logic signed [15:0] ym_l, ym_r, ym_xl_unused, ym_xr_unused;
    logic        ym_sample_unused, ym_ct1_unused, ym_ct2_unused;
    jt51 u_ym (
        .rst(reset), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
        .cs_n(!ym_wr), .wr_n(!ym_wr), .a0(ym_a0), .din(ym_din), .dout(ym_dout),
        .ct1(ym_ct1_unused), .ct2(ym_ct2_unused), .irq_n(ym_irq_n),
        .sample(ym_sample_unused), .left(ym_l), .right(ym_r), .xleft(ym_xl_unused), .xright(ym_xr_unused)
    );

    // ------------------------------------------------------------------ the OKI
    function automatic logic [7:0] rev8(input logic [7:0] v);
        rev8 = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
    endfunction
    logic  [7:0] oki_status;
    logic signed [13:0] oki_s;
    aquarium_oki #(.ROM_W(24'h060000)) u_oki (
        .clk(clk), .reset(reset), .tick(oki_tick), .wr(io_wr && port == 8'h02), .din(rev8(cpu_do)),
        .r_req(m_req[1]), .r_addr(m_addr[1]), .r_len(m_len[1]), .r_ack(m_ack[1]), .r_valid(m_valid[1]), .r_rdata(m_rdata),
        .status(oki_status), .sample(oki_s)
    );

    // ------------------------------------------------------------------ the read data
    always_ff @(posedge clk) begin
        if (!iorq_n) begin
            case (port)
                8'h00:   cpu_di <= 8'hff;
                8'h01:   cpu_di <= ym_dout;
                8'h02:   cpu_di <= rev8(oki_status);
                8'h04:   cpu_di <= latch;
                default: cpu_di <= 8'h00;
            endcase
        end
        else if (sel_rom) cpu_di <= rom_byte;
        else if (sel_ram) cpu_di <= ram_q;
        else              cpu_di <= 8'h00;
    end

    // ------------------------------------------------------------------ the interrupts
    // the NMI is the latch's pending flag, the IRQ the YM2151's line; either goes up on the Z80's own timeline (behind by the steps
    // it still owes after a wait, it sees the line on the step MAME's Z80 would)
    logic       irq_src_d, nmi_src_d;
    logic       irq_pend, nmi_pend;
    logic [7:0] irq_wait, nmi_wait;
    wire        irq_src = !ym_irq_n;
    wire        nmi_src = latch_pending;
    always_ff @(posedge clk) begin
        if (reset) begin
            irq_line <= 1'b0; nmi_line <= 1'b0; irq_pend <= 1'b0; nmi_pend <= 1'b0; irq_src_d <= 1'b0; nmi_src_d <= 1'b0;
        end else begin
            irq_src_d <= irq_src; nmi_src_d <= nmi_src;
            if (irq_src && !irq_src_d) begin
                if (owed_next == 8'd0) irq_line <= 1'b1;
                else begin irq_pend <= 1'b1; irq_wait <= owed_next; end
            end else if (!irq_src) begin
                irq_line <= 1'b0; irq_pend <= 1'b0;
            end else if (irq_pend && cpu_ce) begin
                irq_wait <= irq_wait - 8'd1;
                if (irq_wait == 8'd1) begin irq_line <= 1'b1; irq_pend <= 1'b0; end
            end
            if (nmi_src && !nmi_src_d) begin
                if (owed_next == 8'd0) nmi_line <= 1'b1;
                else begin nmi_pend <= 1'b1; nmi_wait <= owed_next; end
            end else if (!nmi_src) begin
                nmi_line <= 1'b0; nmi_pend <= 1'b0;
            end else if (nmi_pend && cpu_ce) begin
                nmi_wait <= nmi_wait - 8'd1;
                if (nmi_wait == 8'd1) begin nmi_line <= 1'b1; nmi_pend <= 1'b0; end
            end
        end
    end

    // ------------------------------------------------------------------ the mix
    // 0.45 = 461 / 1024, 7.52 = 0.47 * 16 = 7700 / 1024; the chips' outputs registered first (jt51's are its DAC's float conversion,
    // combinational), the products next, then their sum
    logic signed [15:0] ym_lq, ym_rq;
    logic signed [13:0] oki_q;
    logic signed [27:0] p_l, p_r, p_o;
    always_ff @(posedge clk) begin
        ym_lq <= ym_l; ym_rq <= ym_r; oki_q <= oki_s;
        p_l <= 28'(ym_lq) * 28'sd461;
        p_r <= 28'(ym_rq) * 28'sd461;
        p_o <= 28'(oki_q) * 28'sd7700;
    end
    wire signed [27:0] mix_l = p_l + p_o;
    wire signed [27:0] mix_r = p_r + p_o;
    function automatic logic signed [15:0] clamp16(input logic signed [27:0] v);
        logic signed [17:0] s;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [9:0] fraction_unused;
        fraction_unused = v[9:0];
        /* verilator lint_on UNUSEDSIGNAL */
        s = v[27:10];
        clamp16 = (s > 18'sd32767) ? 16'sd32767 : (s < -18'sd32768) ? $signed(16'h8000) : s[15:0];
    endfunction
    always_ff @(posedge clk) begin
        audio_l <= clamp16(mix_l);
        audio_r <= clamp16(mix_r);
    end

    wire unused = &{1'b0, rfsh_n, io_rd, io_rds, c_ready, ym_xl_unused, ym_xr_unused, ym_sample_unused, ym_ct1_unused, ym_ct2_unused};
endmodule
`default_nettype wire
