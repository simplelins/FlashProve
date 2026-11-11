// h_chain.v — the format's H (and hp) hashing engine: F-chaining over 128-byte blocks
// (verifier/tests/known_answers/format_hash.py: h(), hp(); first state = BLAKE2b-512's
// IV with h[0] xor 0x01010040). Per block: t_lo = 4·L on the last block else 128·(b+1),
// with the vertex index x OR-ed into t_lo bits 32..63 (hp; x = 0 for plain H);
// t_hi = {L, num}; last flag on the final block. Input: the list's 32-bit words through
// a combinational read bus (mem_rdata must follow mem_addr in the same cycle); words at
// offsets >= lenw read as zero (the padding). Verified against hash_vectors.txt.
`timescale 1ns/1ps
module h_chain (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,        // pulse with num/x/lenw held
    input  wire [31:0]  num,          // H: domain number; hp: tree_f(num, t) pre-combined
    input  wire [31:0]  x,            // hp vertex index (0 for plain H)
    input  wire [31:0]  lenw,         // list length in 32-bit words
    output wire [31:0]  mem_addr,     // word offset 0 .. 31 within the current block
    input  wire [31:0]  mem_rdata,
    output reg          busy,
    output reg          done,         // one-cycle pulse; state/digest valid after it
    output reg  [511:0] state,        // 16 u32, narrow() order: u32[2i] = cv[i][31:0]
    output wire [255:0] digest        // first 8 u32 of the state
);
  function [63:0] iv_a(input integer i);
    case (i)
      0: iv_a = 64'h6a09e667f3bcc908; 1: iv_a = 64'hbb67ae8584caa73b;
      2: iv_a = 64'h3c6ef372fe94f82b; 3: iv_a = 64'ha54ff53a5f1d36f1;
      4: iv_a = 64'h510e527fade682d1; 5: iv_a = 64'h9b05688c2b3e6c1f;
      6: iv_a = 64'h1f83d9abfb41bd6b; default: iv_a = 64'h5be0cd19137e2179;
    endcase
  endfunction

  localparam [2:0] S_IDLE = 0, S_LOAD = 1, S_FWAIT = 2, S_NEXT = 3;

  reg  [2:0]   st;
  reg  [63:0]  cv [0:7];
  reg  [63:0]  m  [0:15];
  reg  [31:0]  m_lo_latch;
  reg  [5:0]   rd;                    // next 32-bit word to fetch within the block
  reg  [31:0]  b;                     // block index
  reg  [31:0]  blocks;                // max(1, ceil(lenw/32))
  reg          f_start;
  reg  [511:0] f_hin;
  reg  [1023:0] f_min;
  wire         f_busy, f_done;
  wire [511:0] f_dout;

  wire is_last = b == blocks - 32'd1;
  wire [63:0]  c0   = is_last ? {2'b00, lenw, 2'b00}                       // 4·L bytes
                              : ({33'd0, 8'd128} * {32'd0, b + 32'd1});    // 128·(b+1)
  wire [63:0]  t_lo = c0 | ({32'd0, x} << 32);
  wire [63:0]  t_hi = {lenw, num};
  wire [31:0]  wdat = (mem_addr < lenw) ? mem_rdata : 32'd0;               // zero padding

  // global word offset: block b starts at word b*32 (rd[4:0], not the 6-bit rd — its
  // drain value 32 must never enter the address)
  assign mem_addr = (st == S_LOAD && rd < 32) ? {b[26:0], rd[4:0]} : 32'd0;
  assign digest = state[255:0];

  blake2b_f fcore (
      .clk(clk), .rst_n(rst_n), .start(f_start),
      .hin(f_hin), .min(f_min), .t_lo(t_lo), .t_hi(t_hi), .last(is_last),
      .busy(f_busy), .done(f_done), .dout(f_dout));

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; b <= 32'd0; rd <= 6'd0;
      f_start <= 1'b0;
    end else begin
      done <= 1'b0;
      f_start <= 1'b0;
      case (st)
        S_IDLE: if (start) begin
          for (integer i = 0; i < 8; i = i + 1)
            cv[i] <= i == 0 ? iv_a(0) ^ 64'h0000000001010040 : iv_a(i);
          blocks <= (lenw + 32'd31) >> 5;
          if (lenw == 32'd0) blocks <= 32'd1;
          b <= 32'd0; rd <= 6'd0; busy <= 1'b1; st <= S_LOAD;
        end
        S_LOAD: begin
          if (rd < 6'd32) begin
            if (rd[0]) m[rd[4:1]] <= {wdat, m_lo_latch};
            else       m_lo_latch <= wdat;
            rd <= rd + 6'd1;
          end else begin
            // rd == 32: every m[] settled (m[15] at the rd = 31 edge)
            f_hin <= {cv[7], cv[6], cv[5], cv[4], cv[3], cv[2], cv[1], cv[0]};
            f_min <= {m[15], m[14], m[13], m[12], m[11], m[10], m[9], m[8],
                      m[7],  m[6],  m[5],  m[4],  m[3],  m[2],  m[1],  m[0]};
            f_start <= 1'b1;
            st <= S_FWAIT;
          end
        end
        S_FWAIT: if (f_done) begin
          for (integer i = 0; i < 8; i = i + 1) cv[i] <= f_dout[64*i +: 64];
          st <= S_NEXT;
        end
        S_NEXT: begin
          if (is_last) begin
            for (integer i = 0; i < 8; i = i + 1) state[64*i +: 64] <= cv[i];
            done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
          end else begin
            b <= b + 32'd1; rd <= 6'd0; st <= S_LOAD;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
