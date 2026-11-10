// blake2b_f.v — BLAKE2b compression function F, iterative (WP1.1).
// 96 sub-steps per block (12 rounds x 8 G calls), one G per clock; init and final-XOR
// take one clock each. Matches RFC 7693 sec 3.2 with explicit tweak halves and last flag,
// as the format's f (verifier/tests/known_answers/blake2b_f.py). Verified against
// fpga/vectors/f_kat.txt (512 vectors generated from that same file).
// Pure IEEE 1364-2005. Handshake: pulse start with inputs held; done pulses after ~98
// cycles; dout = new chaining value h[0..7] (word i at [64*i+:64]).
`timescale 1ns/1ps
module blake2b_f (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [511:0] hin,
    input  wire [1023:0] min,
    input  wire [63:0]  t_lo,
    input  wire [63:0]  t_hi,
    input  wire         last,
    output reg          busy,
    output reg          done,
    output reg  [511:0] dout
);
  function [63:0] rotr64_w;
    input [63:0] x;
    input integer c;
    begin
      rotr64_w = (x >> c) | (x << (64 - c));
    end
  endfunction

  function [63:0] iv_a;
    input integer i;
    begin
      case (i)
        0: iv_a = 64'h6a09e667f3bcc908; 1: iv_a = 64'hbb67ae8584caa73b;
        2: iv_a = 64'h3c6ef372fe94f82b; 3: iv_a = 64'ha54ff53a5f1d36f1;
        4: iv_a = 64'h510e527fade682d1; 5: iv_a = 64'h9b05688c2b3e6c1f;
        6: iv_a = 64'h1f83d9abfb41bd6b; default: iv_a = 64'h5be0cd19137e2179;
      endcase
    end
  endfunction

  // sigma table: sel[r] holds 16 nibbles, nibble j (0..15) at bits 4*(15-j)
  reg [63:0] sel [0:11];
  initial begin
    sel[0]  = 64'h0123456789ABCDEF;
    sel[1]  = 64'hEA489FD61C02B753;
    sel[2]  = 64'hB8C052FDAE367194;
    sel[3]  = 64'h7931DCBE265A40F8;
    sel[4]  = 64'h905724FAE1BC683D;
    sel[5]  = 64'h2C6A0B834D75FE19;
    sel[6]  = 64'hC51FED4A0763928B;
    sel[7]  = 64'hDB7EC13950F4862A;
    sel[8]  = 64'h6FE9B308C2D714A5;
    sel[9]  = 64'hA2847615FB9E3CD0;
    sel[10] = 64'h0123456789ABCDEF;
    sel[11] = 64'hEA489FD61C02B753;
  end

  function [3:0] sig_at;
    input integer r;
    input integer j;
    begin
      sig_at = sel[r] >> (4 * (15 - j));
    end
  endfunction

  reg [63:0] v [0:15];
  reg [6:0]  cnt;
  reg        phase;
  reg        do_xor;

  integer i;

  wire [2:0] sub  = cnt[2:0];
  wire [3:0] rnd  = cnt[6:3];
  wire       diag = sub[2];
  wire [2:0] s4   = diag ? sub - 3'd4 : sub;
  // position arithmetic in 5 bits, mod 16 = low 4 bits (a 3-bit sum would truncate:
  // e.g. 4+5=9 wraps to 1 in 3 bits — the bug that showed as every-8th-word mismatches)
  wire [4:0] ja5 = {2'b00, s4};
  wire [4:0] jb5 = diag ? ({2'b00, s4} + 5)  : ({2'b00, s4} + 4);
  wire [4:0] jc5 = diag ? ({2'b00, s4} + 10) : ({2'b00, s4} + 8);
  wire [4:0] jd5 = diag ? ({2'b00, s4} + 15) : ({2'b00, s4} + 12);
  wire [3:0] ja = ja5[3:0];
  wire [3:0] jb = jb5[3:0];
  wire [3:0] jc = jc5[3:0];
  wire [3:0] jd = jd5[3:0];
  wire [3:0] m0i = sig_at(rnd, 2 * s4);
  wire [3:0] m1i = sig_at(rnd, 2 * s4 + 1);

  wire [63:0] va = v[ja], vb = v[jb], vc = v[jc], vd = v[jd];
  wire [63:0] mv0 = min[64 * m0i +: 64], mv1 = min[64 * m1i +: 64];

  wire [63:0] ga  = va + vb + mv0;
  wire [63:0] gd  = rotr64_w(vd ^ ga, 32);
  wire [63:0] gc  = vc + gd;
  wire [63:0] gb  = rotr64_w(vb ^ gc, 24);
  wire [63:0] ga2 = ga + gb + mv1;
  wire [63:0] gd2 = rotr64_w(gd ^ ga2, 16);
  wire [63:0] gc2 = gc + gd2;
  wire [63:0] gb2 = rotr64_w(gb ^ gc2, 63);
`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (busy && phase && cnt == 0)
      $display("DBG sub0: va=%h vb=%h vc=%h vd=%h mv0=%h mv1=%h m0i=%0d m1i=%0d ja=%0d jb=%0d jc=%0d jd=%0d ga=%h gd=%h gc=%h gb=%h ga2=%h gd2=%h gc2=%h gb2=%h",
               va, vb, vc, vd, mv0, mv1, m0i, m1i, ja, jb, jc, jd, ga, gd, gc, gb, ga2, gd2, gc2, gb2);
    if (busy && phase && cnt == 1)
      $display("DBG sub1: ja=%0d jb=%0d jc=%0d jd=%0d m0i=%0d m1i=%0d va=%h vb=%h", ja, jb, jc, jd, m0i, m1i, va, vb);
  end
`endif

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; done <= 1'b0; phase <= 1'b0; cnt <= 7'd0; do_xor <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        for (i = 0; i < 8; i = i + 1) v[i] <= hin[64 * i +: 64];
        v[8]  <= iv_a(0); v[9]  <= iv_a(1); v[10] <= iv_a(2); v[11] <= iv_a(3);
        v[12] <= iv_a(4) ^ t_lo;
        v[13] <= iv_a(5) ^ t_hi;
        v[14] <= iv_a(6) ^ (last ? 64'hffffffffffffffff : 64'h0);
        v[15] <= iv_a(7);
        cnt <= 7'd0; phase <= 1'b1; busy <= 1'b1;
      end else if (busy && phase) begin
        v[ja] <= ga2;
        v[jb] <= gb2;
        v[jc] <= gc2;
        v[jd] <= gd2;
        if (cnt == 7'd95) begin
          do_xor <= 1'b1; // sub-step 95's NBA lands this edge; XOR next cycle
        end else begin
          cnt <= cnt + 7'd1;
        end
        if (do_xor) begin
          for (i = 0; i < 8; i = i + 1) dout[64 * i +: 64] <= hin[64 * i +: 64] ^ v[i] ^ v[i + 8];
          done <= 1'b1; busy <= 1'b0; phase <= 1'b0; do_xor <= 1'b0;
        end
      end
    end
  end
endmodule
