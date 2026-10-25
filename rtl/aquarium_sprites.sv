//------------------------------------------------------------------------------
// Aquarium's sprites, a line at a time into a line buffer: MAME 0.289's excellent_spr_device::aquarium_draw_sprites
// (src/mame/excellent/excellent_spr.cpp) for one bitmap row.
//
// The list (the display buffer: the sprite RAM as it was at the vblank before the frame's, rtl/aquarium_video.sv): 512 sprites of
// 8 bytes: x (bytes 1:0) and y (3:2), signed 16 bits; byte 4: bit 7 off, 5 flip x, 4 flip y, 3 the chain's direction (1 down, 0
// across), 2:0 the chain's length - 1; bytes 6:5 the code (& 0x3fff); byte 7 bits 3:0 the colour (colour base 0x300, 16 pens), bit
// 3 also the priority (aquarium_colpri_cb: behind the mid layer's category 0 and the txt layer's category 1).
//
// MAME draws the list from the last sprite to the first with prio_transpen, and each opaque pixel sets the priority bitmap to 31
// whether it was drawn or not, so the first sprite drawn at a pixel (the highest-numbered) owns it: here sprites are taken from 511
// down to 0 and a pixel is written only where no sprite has been ("claimed", a bit per pixel). The mix with the layers is
// aquarium_video's. A chain of chain + 1 tiles: code, code + 1, ... (the code wraps at 0x4000, MAME's element count; codes from
// 0x2000 are past the 1 MB ROM, zero in MAME's region: transparent), across 16 pixels apart from x (from x + chain * 16 leftwards
// with flip x) or down from y (from y + chain * 16 upwards with flip y); each tile also at y + 256 (MAME's wrap). The tile is 16 x 16
// x 4 planar: a row is 8 bytes, a 4-word burst at GFX_W + code * 64 + row * 4; pixel x's pen is {w3, w1, w2, w0} bit 15 - x (MAME's
// planes 48, 16, 32, 0).
//
// The work: the scan, two clocks a sprite, queues the tiles that touch the row (up to 8 a sprite); one tile's 4-word burst is
// fetched while the one before is drawn, a pixel a clock (a row whose 16 pens are all 0 is skipped).
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_sprites #(
    parameter logic [23:0] GFX_W = 24'h200000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // one clock: render bitmap row `yb` into line buffer bank `bank` (aborts a render under way)
    input  logic  [8:0] yb,
    input  logic        bank,
    output logic        busy,

    // the sprite list (one 64-bit entry a sprite, byte i in bits 8i+7:8i)
    output logic  [8:0] s_addr,
    input  logic [63:0] s_q,

    // the SDRAM client
    output logic        m_req,
    output logic [23:0] m_addr,
    output logic  [4:0] m_len,
    input  logic        m_ack,
    input  logic        m_valid,
    input  logic [15:0] m_rdata,

    // the line buffer: {colour, pen}; a pixel's sprite is there when its claim bit is set
    output logic        lb_we,
    output logic  [9:0] lb_addr,
    output logic  [7:0] lb_data,
    input  logic        d_bank,         // the display's read of the claim bits (registered)
    input  logic  [8:0] d_x,
    output logic        d_claimed
);
    // ------------------------------------------------------------------ the claim bits
    logic [319:0] claim0, claim1;               // banks 0 and 1 (two vectors: Quartus 17 fails on the 2-D array's partial writes)
    logic         lbank;

    // ------------------------------------------------------------------ the scan
    typedef enum logic [2:0] { S_IDLE, S_W, S_E, S_J, S_DONE } sst_e;
    sst_e        sst;
    logic signed [9:0] syb;                     // the row (16..271)

    // the sprite's fields
    wire signed [15:0] sx  = s_q[15:0];
    wire signed [15:0] sy  = s_q[31:16];
    wire         s_off   = s_q[39];
    wire         s_fx    = s_q[37];
    wire         s_fy    = s_q[36];
    wire         s_down  = s_q[35];
    wire   [2:0] s_chain = s_q[34:32];
    wire  [13:0] s_code  = s_q[53:40];
    wire   [3:0] s_col   = s_q[59:56];
    // where the row falls in the chain: d = the row's distance below the chain's top, or below its copy at y + 256
    wire signed [17:0] dy    = 18'(syb) - 18'(sy);
    wire  [7:0] span         = s_down ? {1'b0, s_chain, 4'd0} + 8'd16 : 8'd16;
    wire        in0          = (dy >= 18'sd0) && (dy < $signed({10'd0, span}));
    wire        in1          = (dy >= 18'sd256) && (dy < 18'sd256 + $signed({10'd0, span}));
    wire  [7:0] d            = in0 ? dy[7:0] : dy[7:0];             // (dy - 256)[7:0] = dy[7:0]
    wire  [3:0] d_row        = s_fy ? ~d[3:0] : d[3:0];
    wire  [2:0] d_slot       = d[6:4];                              // a down chain's tile from the top
    wire  [2:0] d_k          = s_fy ? s_chain - d_slot : d_slot;

    // the jobs being emitted for a chain across: tile k of j_n
    logic  [2:0] j_k, j_n;
    logic [13:0] j_code;
    logic signed [17:0] j_x;
    logic        j_fx, j_down;
    logic  [3:0] j_row, j_col;

    // the job queue: {code[12:0], x (line buffer, -15..319), row, flip x, colour}
    localparam int QW = 13 + 10 + 4 + 1 + 4;
    logic [QW-1:0] q [8];
    logic  [2:0] q_wp, q_rp;
    logic  [3:0] q_n;
    logic        q_push, q_pop;
    logic [QW-1:0] q_in;
    wire         q_full = (q_n == 4'd8);

    // tile k of the current job set: its code and its x in the line buffer, and whether it is to be queued at all
    wire  [2:0] jk_slot = j_fx ? j_n - j_k : j_k;
    wire signed [17:0] jk_xb = j_down ? j_x : j_x + 18'({jk_slot, 4'd0});
    wire signed [17:0] jk_xd = jk_xb - 18'sd16;
    wire [13:0] jk_code = j_down ? j_code : j_code + 14'(j_k);
    wire        jk_vis  = !jk_code[13] && (jk_xd > -18'sd16) && (jk_xd < 18'sd320);

    always_ff @(posedge clk) begin
        q_push <= 1'b0;
        if (reset || start) begin
            sst <= start ? S_W : S_IDLE;
            if (start) begin
                syb <= $signed({1'b0, yb});
                s_addr <= 9'd511;
                lbank <= bank;
            end
        end else begin
            case (sst)
                S_IDLE: ;
                S_W: sst <= S_E;                        // the RAM takes the address at this edge; the entry is there in the next clock
                S_E: begin
                    if (!s_off && (in0 || in1)) begin
                        j_k    <= s_down ? 3'd0 : 3'd0;
                        j_n    <= s_down ? 3'd0 : s_chain;      // a chain across: chain + 1 tiles; down: the one tile on the row
                        j_code <= s_down ? s_code + 14'(d_k) : s_code;
                        j_x    <= 18'(sx);
                        j_fx   <= s_fx;
                        j_down <= s_down;
                        j_row  <= d_row;
                        j_col  <= s_col;
                        sst    <= S_J;
                    end else if (s_addr == 9'd0) sst <= S_DONE;
                    else begin s_addr <= s_addr - 9'd1; sst <= S_W; end
                end
                S_J: if (!q_full && !q_push) begin
                    // one tile a clock (the queue's count is a clock behind its pushes: one at a time)
                    if (jk_vis) begin
                        q_push <= 1'b1;
                        q_in   <= {jk_code[12:0], jk_xd[9:0], j_row, j_fx, j_col};
                    end
                    if (j_k == j_n) begin
                        if (s_addr == 9'd0) sst <= S_DONE;
                        else begin s_addr <= s_addr - 9'd1; sst <= S_W; end
                    end else j_k <= j_k + 3'd1;
                end
                S_DONE: ;
                default: sst <= S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset || start) begin
            q_wp <= 3'd0; q_rp <= 3'd0; q_n <= 4'd0;
        end else begin
            if (q_push) begin q[q_wp] <= q_in; q_wp <= q_wp + 3'd1; end
            if (q_pop) q_rp <= q_rp + 3'd1;
            case ({q_push, q_pop})
                2'b10:   q_n <= q_n + 4'd1;
                2'b01:   q_n <= q_n - 4'd1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------ the fetch
    logic        f_on;                          // a burst is under way
    logic  [1:0] f_n;
    logic [QW-1:0] f_job;
    logic        rx_full;
    logic [63:0] rx;
    logic [QW-1:0] rx_job;
    logic        rx_take;
    wire  [QW-1:0] q_head = q[q_rp];
    assign q_pop = !f_on && (q_n != 4'd0) && (!rx_full || rx_take) && !(reset || start);

    always_ff @(posedge clk) begin
        if (reset || start) begin
            f_on <= 1'b0; m_req <= 1'b0; rx_full <= 1'b0;
        end else begin
            if (rx_take) rx_full <= 1'b0;
            if (q_pop) begin
                f_on   <= 1'b1;
                f_n    <= 2'd0;
                f_job  <= q_head;
                m_req  <= 1'b1;
                m_addr <= GFX_W + {5'd0, q_head[QW-1 -: 13], q_head[8:5], 2'b00};
                m_len  <= 5'd4;
            end
            if (f_on) begin
                if (m_ack) m_req <= 1'b0;
                if (m_valid) begin
                    rx  <= {rx[47:0], m_rdata};
                    f_n <= f_n + 2'd1;
                    if (f_n == 2'd3) begin f_on <= 1'b0; rx_full <= 1'b1; rx_job <= f_job; end
                end
            end
        end
    end

    // ------------------------------------------------------------------ the drawing
    logic        p_on;
    logic  [3:0] p_i;
    logic [63:0] p_w;                           // {w0, w1, w2, w3}
    logic signed [10:0] p_x0;
    logic        p_fx;
    logic  [3:0] p_col;
    assign rx_take = rx_full && (!p_on || p_i == 4'd15);

    wire   [3:0] ps  = p_fx ? ~p_i : p_i;
    wire   [3:0] nb  = 4'd15 - ps;                 // the bit of the pixel in each plane's word
    wire   [3:0] pen = {p_w[{2'd0, nb}], p_w[{2'd2, nb}], p_w[{2'd1, nb}], p_w[{2'd3, nb}]};
    wire signed [10:0] px = p_x0 + 11'(p_i);
    wire         p_in = (px >= 11'sd0) && (px < 11'sd320);

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (reset || start) begin
            p_on <= 1'b0; p_i <= 4'd0;
            if (start) begin                        // the new line's claims (the other bank's are the line on display)
                if (bank) claim1 <= '0; else claim0 <= '0;
            end
        end else begin
            if (p_on) begin
                if (pen != 4'd0 && p_in && !(lbank ? claim1[px[8:0]] : claim0[px[8:0]])) begin
                    lb_we   <= 1'b1;
                    lb_addr <= {lbank, px[8:0]};
                    lb_data <= {p_col, pen};
                    if (lbank) claim1[px[8:0]] <= 1'b1; else claim0[px[8:0]] <= 1'b1;
                end
                p_i <= p_i + 4'd1;
                if (p_i == 4'd15) p_on <= 1'b0;
            end
            if (rx_take) begin
                // a row with no opaque pixel is dropped here
                p_on  <= (rx != 64'd0);
                p_i   <= 4'd0;
                p_w   <= rx;
                p_x0  <= 11'($signed(rx_job[18:9]));
                p_fx  <= rx_job[4];
                p_col <= rx_job[3:0];
            end
        end
    end

    always_ff @(posedge clk) d_claimed <= d_bank ? claim1[d_x] : claim0[d_x];

    assign busy = (sst != S_IDLE && sst != S_DONE) || (q_n != 4'd0) || q_push || f_on || rx_full || p_on;

    wire unused = &{1'b0, s_q[63:60], s_q[55:54], s_q[38], d[7], rx_job[31:19], rx_job[8:5]};
endmodule
`default_nettype wire
