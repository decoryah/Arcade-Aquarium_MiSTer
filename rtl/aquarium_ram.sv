//------------------------------------------------------------------------------
// Block RAMs of the Aquarium core, written in the forms Quartus infers as M10K (registered address, registered output).
//   aquarium_spram: one port, read and write
//   aquarium_dpram: port A read and write, port B read only
//   aquarium_bram:  NB byte lanes (each its own aquarium_dpram), port A read and write with a byte enable per lane, port B read
//                   only: the 68000's memories (a 16-bit word with its UDS / LDS lanes) and the video's 64-bit wide ones
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_spram #(
    parameter int AW = 13,
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic [AW-1:0] addr,
    input  logic [DW-1:0] wdata,
    input  logic          we,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [1 << AW];
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        q <= mem[addr];
    end
endmodule

module aquarium_dpram #(
    parameter int AW = 11,
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic [DW-1:0] a_wdata,
    input  logic          a_we,
    output logic [DW-1:0] a_q,
    input  logic [AW-1:0] b_addr,
    output logic [DW-1:0] b_q
);
    logic [DW-1:0] mem [1 << AW];
`ifdef VERILATOR
    initial for (int i = 0; i < (1 << AW); i++) mem[i] = '0;     // the bench's (a block RAM powers up 0, as MAME's memory)
`endif
    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_q <= mem[a_addr];
    end
    always_ff @(posedge clk) b_q <= mem[b_addr];
endmodule

module aquarium_bram #(
    parameter int AW = 9,
    parameter int NB = 8                // byte lanes: lane i is bits 8i+7:8i
) (
    input  logic            clk,
    input  logic [AW-1:0]   a_addr,
    input  logic [NB*8-1:0] a_wdata,
    input  logic [NB-1:0]   a_be,       // the lanes written (with a_we)
    input  logic            a_we,
    output logic [NB*8-1:0] a_q,
    input  logic [AW-1:0]   b_addr,
    output logic [NB*8-1:0] b_q
);
    genvar i;
    generate
        for (i = 0; i < NB; i++) begin : g_lane
            aquarium_dpram #(.AW(AW), .DW(8)) u_l (
                .clk(clk), .a_addr(a_addr), .a_wdata(a_wdata[i*8 +: 8]), .a_we(a_we && a_be[i]), .a_q(a_q[i*8 +: 8]),
                .b_addr(b_addr), .b_q(b_q[i*8 +: 8])
            );
        end
    endgenerate
endmodule
`default_nettype wire
