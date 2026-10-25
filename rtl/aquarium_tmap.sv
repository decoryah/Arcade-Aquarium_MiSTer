//------------------------------------------------------------------------------
// One of Aquarium's tilemap layers, a line at a time into a line buffer: MAME 0.289's tilemap rules (src/mame/excellent/aquarium.cpp,
// src/emu/tilemap.cpp) for one bitmap row.
//
//   BIG = 1 (mid, bak): 32 x 32 tiles of 16 x 16, 5 bits a pixel. VRAM: two words a tile (rows of 32): word 0 the code (bits 11:0),
//         word 1 the attributes: bits 4:0 the colour, 5 the category, 8 flip x, 9 flip y. The pixel is the 4-bit packed pen of the
//         low ROM with the high ROM's bit as bit 4 (MAME's expand_gfx). Colour base 0x400, 32 pens a colour.
//   BIG = 0 (txt): 64 x 64 tiles of 8 x 8, 4 bits. VRAM: one word a tile: bits 11:0 the code, 15:12 the colour, bit 15 also the
//         category. No flip. Colour base 0x200, 16 pens a colour.
//
// The scroll (set_scrollx / set_scrolly with MAME's tilemap rule, effective_rowscroll): MAME's bitmap pixel (bx, by) shows the
// layer's pixel ((bx + scrollx) & 511, (by + scrolly) & 511). The visible area is bitmap x 16..335, y 16..271; the line buffer's
// x 0..319 is bitmap x 16..335.
//
// The gfx in the SDRAM (rtl/aquarium_loader.sv): BIG a 5-word burst a tile row at GFX_W + code * 128 + row * 8 (words 0-3 the
// sixteen 4-bit pens, the first pixel in bits 15:12 of word 0; word 4 the fifth bits, the first pixel in bit 15); txt a 2-word burst
// at GFX_W + code * 16 + row * 2 (the first pixel in bits 15:12 of word 0).
//
// The line: NT tiles (21 or 41) from the column under bitmap x 16; one tile's VRAM read and SDRAM burst while the one before is
// written to the line buffer, a pixel a clock. Every x 0..319 is written (transparent pixels with pen 0), so the buffer needs no
// clearing. The written word: {category, colour[4:0], pen[4:0]} (txt: the colour and pen zero-extended).
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_tmap #(
    parameter bit          BIG   = 1'b1,
    parameter logic [23:0] GFX_W = 24'h100000
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // one clock: render bitmap row `yb` into line buffer bank `bank` (aborts a render under way)
    input  logic  [8:0] yb,
    input  logic        bank,
    input  logic [15:0] scrollx,
    input  logic [15:0] scrolly,
    output logic        busy,

    // the display copy of the layer's VRAM (64-bit entries: BIG two tiles, txt four)
    output logic  [9:0] v_addr,
    input  logic [63:0] v_q,

    // the SDRAM client
    output logic        m_req,
    output logic [23:0] m_addr,
    output logic  [4:0] m_len,
    input  logic        m_ack,
    input  logic        m_valid,
    input  logic [15:0] m_rdata,

    // the line buffer
    output logic        lb_we,
    output logic  [9:0] lb_addr,        // {bank, x}
    output logic [10:0] lb_data
);
    localparam int NT  = BIG ? 21 : 41;         // tiles a line
    localparam int TW  = BIG ? 16 : 8;          // pixels a tile
    localparam int NW  = BIG ? 5 : 2;           // words a tile row

    // ------------------------------------------------------------------ the line's set-up
    logic        lbank;
    logic  [8:0] ty, tx0;
    logic  [5:0] t;                             // the tile being fetched (0..NT-1)
    wire   [3:0] row   = BIG ? ty[3:0] : {1'b0, ty[2:0]};
    wire   [5:0] mrow  = BIG ? {1'b0, ty[8:4]} : ty[8:3];
    wire   [5:0] col0  = BIG ? {1'b0, tx0[8:4]} : tx0[8:3];
    wire   [3:0] fine  = BIG ? tx0[3:0] : {1'b0, tx0[2:0]};
    wire   [5:0] colm  = BIG ? ((col0 + t) & 6'h1f) : (col0 + t);
    wire  [11:0] ti    = BIG ? {2'b00, mrow[4:0], colm[4:0]} : {mrow, colm};   // the tile's index in the map

    // ------------------------------------------------------------------ stage A: the VRAM read and the SDRAM burst
    typedef enum logic [2:0] { A_IDLE, A_VRD, A_VQ, A_REQ, A_WAIT } ast_e;
    ast_e        ast;
    logic [11:0] ti_q;
    logic  [4:0] a_col;
    logic        a_cat, a_fx;
    logic  [5:0] a_t;
    logic  [2:0] rx_n;                          // words of the burst received
    logic        rx_full;                       // a whole tile row is waiting for stage B
    logic [79:0] rx;                            // the words, word 0 first (in bits 79:64)
    logic        rx_take;                       // stage B takes it (this clock)
    // the tile's fields from the VRAM word
    wire  [31:0] vt    = BIG ? (ti_q[0] ? v_q[63:32] : v_q[31:0]) : 32'(v_q[16 * ti_q[1:0] +: 16]);
    wire  [11:0] code  = vt[11:0];
    wire  [15:0] attr  = vt[31:16];
    wire   [3:0] r_eff = (BIG && attr[9]) ? ~row : row;

    // the meta of the row in rx: {cat, colour, flip x, tile}
    logic        rx_cat, rx_fx;
    logic  [4:0] rx_col;
    logic  [5:0] rx_t;

    always_ff @(posedge clk) begin
        if (reset || start) begin
            ast <= start ? A_VRD : A_IDLE;
            m_req <= 1'b0; rx_n <= 3'd0; rx_full <= 1'b0;
            t <= 6'd0;
            if (start) begin
                lbank <= bank;
                ty    <= yb + scrolly[8:0];
                tx0   <= 9'd16 + scrollx[8:0];
            end
        end else begin
            if (rx_take) rx_full <= 1'b0;
            case (ast)
                A_IDLE: ;
                A_VRD: begin
                    v_addr <= BIG ? {1'b0, ti[9:1]} : ti[11:2];
                    ti_q   <= ti;
                    ast    <= A_VQ;
                end
                A_VQ: ast <= A_REQ;                     // the RAM takes the address at this edge; its word is there in the next clock
                A_REQ: begin
                    // the next burst only once the last one's words have gone on to stage B
                    if (!rx_full || rx_take) begin
                        m_req  <= 1'b1;
                        m_addr <= BIG ? GFX_W + {5'd0, code, r_eff, 3'b000} : GFX_W + {8'd0, code, r_eff[2:0], 1'b0};
                        m_len  <= 5'(NW);
                        a_col  <= BIG ? attr[4:0] : {1'b0, vt[15:12]};
                        a_cat  <= BIG ? attr[5] : vt[15];
                        a_fx   <= BIG ? attr[8] : 1'b0;
                        a_t    <= t;
                        rx_n   <= 3'd0;
                        ast    <= A_WAIT;
                    end
                end
                A_WAIT: begin
                    if (m_ack) m_req <= 1'b0;
                    if (m_valid) begin
                        rx <= {rx[63:0], m_rdata};
                        rx_n <= rx_n + 3'd1;
                        if (rx_n == 3'(NW - 1)) begin
                            rx_full <= 1'b1;
                            rx_cat <= a_cat; rx_col <= a_col; rx_fx <= a_fx; rx_t <= a_t;
                            if (t == 6'(NT - 1)) ast <= A_IDLE;
                            else begin t <= t + 6'd1; ast <= A_VRD; end
                        end
                    end
                end
                default: ast <= A_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ stage B: the pixels into the line buffer
    logic        b_on;
    logic  [4:0] b_i;
    logic [79:0] b_w;
    logic        b_cat, b_fx;
    logic  [4:0] b_col;
    logic signed [10:0] b_x0;                   // the line buffer's x of the tile's pixel 0
    assign rx_take = rx_full && (!b_on || b_i == 5'(TW - 1));

    // the pen of source column s: BIG words 0-3 the low nibbles, word 4 the fifth bits; txt words 0-1 (in b_w's low 32 bits)
    wire   [3:0] s    = b_fx ? 4'(TW - 1) - b_i[3:0] : b_i[3:0];
    wire  [63:0] lo   = BIG ? b_w[79:16] : {b_w[31:0], 32'd0};
    wire   [3:0] nib  = lo[63 - 4 * s -: 4];
    wire         hib  = BIG ? b_w[15 - s] : 1'b0;
    wire signed [10:0] bx = b_x0 + 11'(b_i);

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (reset || start) begin
            b_on <= 1'b0; b_i <= 5'd0;
        end else begin
            if (b_on) begin
                if (bx >= 11'sd0 && bx < 11'sd320) begin
                    lb_we   <= 1'b1;
                    lb_addr <= {lbank, bx[8:0]};
                    lb_data <= {b_cat, b_col, hib, nib};
                end
                b_i <= b_i + 5'd1;
                if (b_i == 5'(TW - 1)) b_on <= 1'b0;
            end
            if (rx_take) begin
                b_on  <= 1'b1;
                b_i   <= 5'd0;
                b_w   <= rx;
                b_cat <= rx_cat; b_col <= rx_col; b_fx <= rx_fx;
                b_x0  <= 11'(rx_t) * 11'(TW) - 11'(fine);      // -15 .. 320
            end
        end
    end

    assign busy = (ast != A_IDLE) || rx_full || b_on;

    wire unused = &{1'b0, scrollx[15:9], scrolly[15:9], ti_q[11:2], attr[15:10], attr[7:6]};
endmodule
`default_nettype wire
