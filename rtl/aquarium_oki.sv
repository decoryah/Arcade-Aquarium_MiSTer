//------------------------------------------------------------------------------
// OKI MSM6295: four ADPCM voices from a 256 KB ROM, written from MAME 0.289's okim6295.cpp / okiadpcm.cpp. The owner's Hexion core's
// hexion_oki.sv, with the status read added (MAME's read(): 0xf0 with bit i set while voice i plays), which Aquarium's Z80 uses.
//
// The command port: a byte with bit 7 set picks the phrase (its 8-byte entry in the ROM's table: start and end address, 3 bytes
// each, big-endian, 18 bits); the next byte starts it on the voices of bits 7:4 that are not playing, at the volume of bits 3:0
// (MAME's table 0x20, 0x16, 0x10, 0x0b, 0x08, 0x06, 0x04, 0x03, 0x02 / 0x20, then silence), when start < end; any other byte
// stops the voices of its bits 6:3. A voice plays 2 * (end - start + 1) nibbles, the high nibble of a byte first.
//
// One output sample per tick (the chip's clock / 132 with pin 7 high, / 165 low): each playing voice decodes its next nibble
// (signal += the step's difference, clamped to -2048..2047; the step index moves by -1, -1, -1, -1, 2, 4, 6, 8, clamped to 0..48)
// and adds trunc(signal * volume / 32): MAME's add_int(signal * volume, 2048), the float product converted to an integer. The
// output is the sum of the four voices (MAME's sample is it / 2048).
//
// The ROM is read through the SDRAM (a word at a time; the bytes of a word are big-endian: the even byte in bits 15:8). A command
// and a tick are handled one after the other in the order they came; a tick's work (at most four reads) and a command's (one 3-word
// read) take a few dozen clocks of the 12,000 between samples. In MAME a command is instant: a voice started by a command before a
// tick plays its first nibble at that tick, as here.
//------------------------------------------------------------------------------
`default_nettype none

module aquarium_oki #(
    parameter logic [23:0] ROM_W = 24'h040000      // the ROM's word address in the SDRAM
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        tick,           // one output sample
    input  logic        wr,             // one clock per command byte
    input  logic  [7:0] din,

    output logic        r_req,
    output logic [23:0] r_addr,
    output logic  [4:0] r_len,
    input  logic        r_ack,
    input  logic        r_valid,
    input  logic [15:0] r_rdata,

    output logic  [7:0] status,         // MAME's read(): 0xf0 | the voices playing
    output logic signed [13:0] sample
);
    // ------------------------------------------------------------------ tables
    function automatic logic [10:0] stepval(input logic [5:0] s);
        case (s)
            6'd0: stepval = 11'd16;    6'd1: stepval = 11'd17;    6'd2: stepval = 11'd19;    6'd3: stepval = 11'd21;
            6'd4: stepval = 11'd23;    6'd5: stepval = 11'd25;    6'd6: stepval = 11'd28;    6'd7: stepval = 11'd31;
            6'd8: stepval = 11'd34;    6'd9: stepval = 11'd37;    6'd10: stepval = 11'd41;   6'd11: stepval = 11'd45;
            6'd12: stepval = 11'd50;   6'd13: stepval = 11'd55;   6'd14: stepval = 11'd60;   6'd15: stepval = 11'd66;
            6'd16: stepval = 11'd73;   6'd17: stepval = 11'd80;   6'd18: stepval = 11'd88;   6'd19: stepval = 11'd97;
            6'd20: stepval = 11'd107;  6'd21: stepval = 11'd118;  6'd22: stepval = 11'd130;  6'd23: stepval = 11'd143;
            6'd24: stepval = 11'd157;  6'd25: stepval = 11'd173;  6'd26: stepval = 11'd190;  6'd27: stepval = 11'd209;
            6'd28: stepval = 11'd230;  6'd29: stepval = 11'd253;  6'd30: stepval = 11'd279;  6'd31: stepval = 11'd307;
            6'd32: stepval = 11'd337;  6'd33: stepval = 11'd371;  6'd34: stepval = 11'd408;  6'd35: stepval = 11'd449;
            6'd36: stepval = 11'd494;  6'd37: stepval = 11'd544;  6'd38: stepval = 11'd598;  6'd39: stepval = 11'd658;
            6'd40: stepval = 11'd724;  6'd41: stepval = 11'd796;  6'd42: stepval = 11'd876;  6'd43: stepval = 11'd963;
            6'd44: stepval = 11'd1060; 6'd45: stepval = 11'd1166; 6'd46: stepval = 11'd1282; 6'd47: stepval = 11'd1411;
            default: stepval = 11'd1552;
        endcase
    endfunction

    function automatic logic [5:0] voltab(input logic [3:0] i);
        case (i)
            4'd0: voltab = 6'd32; 4'd1: voltab = 6'd22; 4'd2: voltab = 6'd16; 4'd3: voltab = 6'd11; 4'd4: voltab = 6'd8;
            4'd5: voltab = 6'd6;  4'd6: voltab = 6'd4;  4'd7: voltab = 6'd3;  4'd8: voltab = 6'd2;  default: voltab = 6'd0;
        endcase
    endfunction

    // ------------------------------------------------------------------ voices
    logic        playing [4];
    logic [17:0] base    [4];
    logic [19:0] idx     [4];           // MAME's m_sample: the nibble count
    logic [19:0] count   [4];
    logic signed [11:0] signal [4];
    logic  [5:0] step    [4];
    logic  [5:0] vol     [4];

    logic        cmd_on;                // MAME's m_command != -1
    logic  [6:0] cmd;

    assign status = {4'hf, playing[3], playing[2], playing[1], playing[0]};

    // ------------------------------------------------------------------ the engine
    typedef enum logic [3:0] { E_IDLE, E_HDR, E_HDRW, E_VOICE, E_VREQ, E_VW, E_DONE, E_S1, E_S2, E_S3, E_S4 } est_e;
    est_e        st;
    logic        pend_cmd, pend_tick;
    logic  [7:0] pend_data;
    logic  [7:0] cdata;                 // the command byte being handled
    logic [47:0] hdr;
    logic  [1:0] hw;                    // header words received
    logic  [1:0] v;
    logic signed [13:0] acc;
    logic        lowbyte;

    wire  [17:0] vaddr = base[v] + 18'(idx[v][19:1]);
    wire  [17:0] h_start = hdr[41:24];
    wire  [17:0] h_stop  = hdr[17:0];
    wire         hdr_unused = &{1'b0, hdr[47:42], hdr[23:18]};

    // the ADPCM step of voice v, over four clocks (E_S1 .. E_S4): the nibble and the step's size; the new signal and step index; the
    // signal times the volume; the voice's share, truncated toward zero, into the sum
    logic  [7:0] rbyte;
    logic  [3:0] nib;
    logic [11:0] sv12;
    logic signed [11:0] s_c;
    logic signed [18:0] prod;
    wire  [11:0] mag = (nib[2] ? sv12 : 12'd0) + (nib[1] ? (sv12 >> 1) : 12'd0) + (nib[0] ? (sv12 >> 2) : 12'd0) + (sv12 >> 3);
    wire signed [13:0] s_new = $signed({{2{signal[v][11]}}, signal[v]}) + (nib[3] ? -$signed({2'b00, mag}) : $signed({2'b00, mag}));
    wire signed [11:0] s_clamp = (s_new > 14'sd2047) ? 12'sd2047 : (s_new < -14'sd2048) ? $signed(12'h800) : s_new[11:0];
    wire signed [7:0] st_new = $signed({2'b00, step[v]}) + (nib[2] ? $signed({4'd0, nib[1:0], 1'b0}) + 8'sd2 : -8'sd1);
    wire  [5:0] st_clamp = (st_new > 8'sd48) ? 6'd48 : (st_new < 8'sd0) ? 6'd0 : st_new[5:0];
    wire signed [13:0] contrib = 14'(prod[18] ? -((-prod) >>> 5) : (prod >>> 5));

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 4; i++) begin
                playing[i] <= 1'b0; idx[i] <= 20'd0; count[i] <= 20'd0; signal[i] <= 12'sd0; step[i] <= 6'd0; vol[i] <= 6'd0; base[i] <= 18'd0;
            end
            cmd_on <= 1'b0; st <= E_IDLE; pend_cmd <= 1'b0; pend_tick <= 1'b0; r_req <= 1'b0; sample <= 14'sd0;
        end else begin
            if (wr)   begin pend_cmd <= 1'b1; pend_data <= din; end
            if (tick) pend_tick <= 1'b1;

            case (st)
                E_IDLE:
                    // the command first when both wait: it came before the tick, or in the same clock (MAME: the stream
                    // update at the write generates the samples up to it with the voices as they were)
                    if (pend_cmd) begin
                        pend_cmd <= wr;             // (a new byte in this very clock is kept)
                        cdata <= pend_data;
                        if (cmd_on) begin
                            cmd_on <= 1'b0;
                            // the phrase's table entry is read when a voice of the mask is free
                            if ((pend_data[7] && !playing[3]) || (pend_data[6] && !playing[2]) ||
                                (pend_data[5] && !playing[1]) || (pend_data[4] && !playing[0])) begin
                                r_req <= 1'b1; r_addr <= ROM_W + {14'd0, cmd, 2'b00}; r_len <= 5'd3;
                                hw <= 2'd0;
                                st <= E_HDR;
                            end
                        end else if (pend_data[7]) begin
                            cmd_on <= 1'b1; cmd <= pend_data[6:0];
                        end else begin
                            for (int i = 0; i < 4; i++) if (pend_data[3 + i]) playing[i] <= 1'b0;
                        end
                    end else if (pend_tick) begin
                        pend_tick <= tick;
                        v <= 2'd0; acc <= 14'sd0;
                        st <= E_VOICE;
                    end
                E_HDR: if (r_ack) begin r_req <= 1'b0; st <= E_HDRW; end
                E_HDRW:
                    if (r_valid) begin
                        hdr <= {hdr[31:0], r_rdata};
                        hw  <= hw + 2'd1;
                        if (hw == 2'd2) st <= E_DONE;
                    end
                E_DONE: begin
                    // start the free voices of the mask on the phrase (hdr: start = bytes 0-2, end = bytes 3-5)
                    if (h_start < h_stop)
                        for (int i = 0; i < 4; i++)
                            if (cdata[4 + i] && !playing[i]) begin
                                playing[i] <= 1'b1;
                                base[i]    <= h_start;
                                idx[i]     <= 20'd0;
                                count[i]   <= {{1'b0, h_stop - h_start} + 19'd1, 1'b0};
                                signal[i]  <= 12'sd0;
                                step[i]    <= 6'd0;
                                vol[i]     <= voltab(cdata[3:0]);
                            end
                    st <= E_IDLE;
                end
                E_VOICE:
                    if (playing[v]) begin
                        r_req <= 1'b1; r_addr <= ROM_W + {7'd0, vaddr[17:1]}; r_len <= 5'd1;
                        lowbyte <= vaddr[0];
                        st <= E_VREQ;
                    end else if (v == 2'd3) begin
                        sample <= acc; st <= E_IDLE;
                    end else
                        v <= v + 2'd1;
                E_VREQ: if (r_ack) begin r_req <= 1'b0; st <= E_VW; end
                E_VW:
                    if (r_valid) begin
                        rbyte <= lowbyte ? r_rdata[7:0] : r_rdata[15:8];
                        st <= E_S1;
                    end
                E_S1: begin
                    nib  <= idx[v][0] ? rbyte[3:0] : rbyte[7:4];
                    sv12 <= {1'b0, stepval(step[v])};
                    st   <= E_S2;
                end
                E_S2: begin
                    signal[v] <= s_clamp;
                    step[v]   <= st_clamp;
                    s_c       <= s_clamp;
                    st        <= E_S3;
                end
                E_S3: begin
                    prod <= s_c * $signed({1'b0, vol[v]});
                    st   <= E_S4;
                end
                E_S4: begin                     // the voice's share; the next voice
                    acc <= acc + contrib;
                    if (idx[v] + 20'd1 >= count[v]) playing[v] <= 1'b0;
                    idx[v] <= idx[v] + 20'd1;
                    if (v == 2'd3) begin
                        sample <= acc + contrib; st <= E_IDLE;
                    end else begin
                        v <= v + 2'd1; st <= E_VOICE;
                    end
                end
                default: st <= E_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
