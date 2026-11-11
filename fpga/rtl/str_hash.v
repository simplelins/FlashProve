// str_hash.v — the hashed-string engine of blocks/hash/hash.h: a string of `total` bytes
// (label ‖ data ‖ fill ‖ salt, assembled by the caller's byte bus) hashed from
// begin64(start, dlen): h = IV, h[0] ^= 0x01010000|dlen, h[4+i] ^= start.w[i] — the same
// slots hashlib's salt/person parameters fill, as mode_vectors.py mirrors. Per block:
// t_lo = total on the last block else 128·(b+1), t_hi = 0, last flag on the final block.
// The domain number lives in the label bytes, not in t. Words arrive 64 bits at a time
// (bytes 8w..8w+7 little-endian); words past the string's end must read 0.
// KATs: fpga/vectors/mode_kat.txt (from mode_vectors.txt, all 58 cases).
`timescale 1ns/1ps
module str_hash (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,        // pulse with all inputs held
    input  wire [63:0]  tagword,      // label word 0 (little-endian bytes 0..7)
    input  wire [63:0]  index,        // label word 1 (bytes 8..15)
    input  wire [255:0] startw,       // 8 u32: the hash's Start (words w[i] = startw[32*i +: 32])
    input  wire [31:0]  total,        // string length in bytes
    input  wire [6:0]   dlen,         // digest bytes: 32 or 64
    output wire [31:0]  waddr,        // 64-bit word offset of the string
    input  wire [63:0]  wrdata,
    output reg          busy,
    output reg          done,         // one-cycle pulse; digest valid after it
    output reg  [511:0] digest        // 16 u32, narrow order (upper words 0 for dlen=32)
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
  reg  [4:0]   rd;                    // next 64-bit word to fetch within the block (0..16)
  reg  [31:0]  b;                     // block index
  reg  [31:0]  blocks;                // max(1, ceil(total/128))
  reg          f_start;
  reg  [511:0] f_hin;
  reg  [1023:0] f_min;
  wire         f_busy, f_done;
  wire [511:0] f_dout;

  wire        is_last = b == blocks - 32'd1;
  wire [63:0] t_lo = is_last ? {32'd0, total} : ({39'd0, 8'd128} * {32'd0, b + 32'd1});

  assign waddr = (st == S_LOAD && rd < 16) ? {b[27:0], rd[3:0]} : 32'd0;

  blake2b_f fcore (
      .clk(clk), .rst_n(rst_n), .start(f_start),
      .hin(f_hin), .min(f_min), .t_lo(t_lo), .t_hi(64'd0), .last(is_last),
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
          // begin64: IV, h[0] ^= 0x01010000|dlen, h[4+i] ^= start.w[2i] | start.w[2i+1]<<32
          for (integer i = 0; i < 8; i = i + 1) begin
            cv[i] <= i == 0 ? iv_a(0) ^ {32'd0, 32'h01010000 | {25'd0, dlen}}
                            : (i < 4 ? iv_a(i) : iv_a(i) ^ startw[64*(i-4) +: 64]);
          end
          blocks <= (total + 32'd127) >> 7;
          if (total == 32'd0) blocks <= 32'd1;
          b <= 32'd0; rd <= 6'd0; busy <= 1'b1; st <= S_LOAD;
        end
        S_LOAD: begin
          if (rd < 5'd16) begin
            m[rd[3:0]] <= wrdata;          // one 64-bit bus word = one block word
            rd <= rd + 5'd1;
          end else begin
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
            for (integer i = 0; i < 8; i = i + 1) digest[64*i +: 64] <= cv[i];
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
