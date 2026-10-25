//------------------------------------------------------------------------------
// The ROM image's way in: the HPS download (or the fast load) arrives a byte at a time at its image offset; this module puts each
// byte at its place in the SDRAM. Everything of this board lives in the SDRAM (the CPUs read their programs through caches).
//
// The image (mra/*.mra, tools/aquarium_rom.py): MAME 0.289's regions in MAME's byte order (the ROM_LOAD16_WORD_SWAP files are
// swapped back by the MRA, so a 16-bit word's high byte is the even byte), the same layout for both sets:
//   0x000000  maincpu    512 KB  aquar3.13h / excellent_3.13h (the 68000's program, big-endian words)
//   0x080000  audiocpu   256 KB  excellent_5.10c (the Z80's program and its banks)
//   0x0C0000  oki        256 KB  excellent_4.7d's first half (the MSM6295 addresses 256 KB; the second half of the ROM is 0xFF)
//   0x100000  txt        128 KB  excellent_2.17e (8 x 8 x 4 packed, 32 bytes a tile)
//   0x120000  mid        512 KB  excellent_1.15b (16 x 16 x 4 packed, 128 bytes a tile: the low 4 bits of the 5)
//   0x1A0000  mid_hi     128 KB  excellent_6.15d (16 x 16 x 1, 32 bytes a tile: the 5th bit)
//   0x1C0000  bak        512 KB  excellent_8.14g
//   0x240000  bak_hi     128 KB  excellent_7.17g
//   0x260000  spritegen    1 MB  d23c8000.1f (16 x 16 x 4 planar, 128 bytes a tile)
//   0x360000  (end)
//
// The SDRAM (byte addresses): maincpu, audiocpu, oki and txt at their image offsets; mid at 0x200000 and bak at 0x300000 with a
// 16-byte slot per tile row (bytes 0-7 the row's 16 four-bit pens, bytes 8-9 its 16 fifth bits), so a row is one 5-word burst:
// SDRAM byte = base + tile * 256 + row * 16 + (0..7 | 8..9); the sprites at 0x400000. Byte pairs (even, odd) stay pairs, in order,
// as the SDRAM's download FIFO wants them.
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_loader (
    input  logic        clk,
    input  logic        dl_wr,                 // one clock per byte
    input  logic [21:0] dl_addr,               // image offset
    input  logic  [7:0] dl_data,
    output logic        o_wr,                  // to the SDRAM's download port
    output logic [24:0] o_addr,
    output logic  [7:0] o_data
);
    localparam logic [21:0] MID = 22'h120000, MID_HI = 22'h1A0000, BAK = 22'h1C0000, BAK_HI = 22'h240000, SPR = 22'h260000,
                            END = 22'h360000;

    wire [21:0] bm  = dl_addr - MID;
    wire [21:0] bmh = dl_addr - MID_HI;
    wire [21:0] bb  = dl_addr - BAK;
    wire [21:0] bbh = dl_addr - BAK_HI;
    wire [21:0] bs  = dl_addr - SPR;
    wire unused = &{1'b0, bm[21:19], bmh[21:17], bb[21:19], bbh[21:17], bs[21:20]};
    always_ff @(posedge clk) begin
        o_wr   <= 1'b0;
        o_data <= dl_data;
        if (dl_wr && dl_addr < END) begin
            o_wr <= 1'b1;
            if      (dl_addr < MID)    o_addr <= {3'd0, dl_addr};                                        // maincpu .. txt
            else if (dl_addr < MID_HI) o_addr <= 25'h200000 + {5'd0, bm[18:7], bm[6:3], 1'b0, bm[2:0]};    // tile, row, pens
            else if (dl_addr < BAK)    o_addr <= 25'h200000 + {5'd0, bmh[16:5], bmh[4:1], 3'b100, bmh[0]}; // tile, row, 5th bits
            else if (dl_addr < BAK_HI) o_addr <= 25'h300000 + {5'd0, bb[18:7], bb[6:3], 1'b0, bb[2:0]};
            else if (dl_addr < SPR)    o_addr <= 25'h300000 + {5'd0, bbh[16:5], bbh[4:1], 3'b100, bbh[0]};
            else                       o_addr <= 25'h400000 + {5'd0, bs[19:0]};
        end
    end
endmodule
`default_nettype wire
