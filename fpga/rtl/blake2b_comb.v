// blake2b_comb.v — fully combinational BLAKE2b compression function.
// No FSM, no clock — pure combinational. Used for verification (WP1.1) before
// the pipelined version (which must match this exactly).
// Matches RFC 7693 sec 3.2 with explicit tweak halves, as the format's f.
`timescale 1ns/1ps
module blake2b_comb (
    input  wire [511:0]  hin,
    input  wire [1023:0] min,
    input  wire [63:0]   t_lo,
    input  wire [63:0]   t_hi,
    input  wire          last,
    output wire [511:0]  dout
);
  function [63:0] rotr64(input [63:0] x, input integer c);
    rotr64 = (x >> c) | (x << (64 - c));
  endfunction

  function [63:0] iv_c(input integer i);
    case (i)
      0: iv_c = 64'h6a09e667f3bcc908; 1: iv_c = 64'hbb67ae8584caa73b;
      2: iv_c = 64'h3c6ef372fe94f82b; 3: iv_c = 64'a54ff53a5f1d36f1;
      4: iv_c = 64'h510e527fade682d1; 5: iv_c = 64'h9b05688c2b3e6c1f;
      6: iv_c = 64'h1f83d9abfb41bd6b; default: iv_c = 64'h5be0cd19137e2179;
    endcase
  endfunction

  // sigma: 12 rows x 16 entries, flattened
  function [3:0] sig(input integer r, input integer j);
    case (r)
      0: sig = j < 16 ? j[3:0] : 4'd0;
      1: case (j) 0:sig=14;1:sig=10;2:sig=4;3:sig=8;4:sig=9;5:sig=15;6:sig=13;7:sig=6;8:sig=1;9:sig=12;10:sig=0;11:sig=2;12:sig=11;13:sig=7;14:sig=5;default:sig=3; endcase
      2: case (j) 0:sig=11;1:sig=8;2:sig=12;3:sig=0;4:sig=5;5:sig=2;6:sig=15;7:sig=13;8:sig=10;9:sig=14;10:sig=3;11:sig=6;12:sig=7;13:sig=1;14:sig=9;default:sig=4; endcase
      3: case (j) 0:sig=7;1:sig=9;2:sig=3;3:sig=1;4:sig=13;5:sig=12;6:sig=11;7:sig=14;8:sig=2;9:sig=6;10:sig=5;11:sig=10;12:sig=4;13:sig=0;14:sig=15;default:sig=8; endcase
      4: case (j) 0:sig=9;1:sig=0;2:sig=5;3:sig=7;4:sig=2;5:sig=4;6:sig=10;7:sig=15;8:sig=14;9:sig=1;10:sig=11;11:sig=12;12:sig=6;13:sig=8;14:sig=3;default:sig=13; endcase
      5: case (j) 0:sig=2;1:sig=12;2:sig=6;3:sig=10;4:sig=0;5:sig=11;6:sig=8;7:sig=3;8:sig=4;9:sig=13;10:sig=7;11:sig=5;12:sig=15;13:sig=14;14:sig=1;default:sig=9; endcase
      6: case (j) 0:sig=12;1:sig=5;2:sig=1;3:sig=15;4:sig=14;5:sig=13;6:sig=4;7:sig=10;8:sig=0;9:sig=7;10:sig=6;11:sig=3;12:sig=9;13:sig=2;14:sig=8;default:sig=11; endcase
      7: case (j) 0:sig=13;1:sig=11;2:sig=7;3:sig=14;4:sig=12;5:sig=1;6:sig=3;7:sig=9;8:sig=5;9:sig=0;10:sig=15;11:sig=4;12:sig=8;13:sig=6;14:sig=2;default:sig=10; endcase
      8: case (j) 0:sig=6;1:sig=15;2:sig=14;3:sig=9;4:sig=11;5:sig=3;6:sig=0;7:sig=8;8:sig=12;9:sig=2;10:sig=13;11:sig=7;12:sig=1;13:sig=4;14:sig=10;default:sig=5; endcase
      9: case (j) 0:sig=10;1:sig=2;2:sig=8;3:sig=4;4:sig=7;5:sig=6;6:sig=1;7:sig=5;8:sig=15;9:sig=11;10:sig=9;11:sig=14;12:sig=3;13:sig=12;14:sig=13;default:sig=0; endcase
      10: sig = j[3:0];
      11: case (j) 0:sig=14;1:sig=10;2:sig=4;3:sig=8;4:sig=9;5:sig=15;6:sig=13;7:sig=6;8:sig=1;9:sig=12;10:sig=0;11:sig=2;12:sig=11;13:sig=7;14:sig=5;default:sig=3; endcase
      default: sig = 4'd0;
    endcase
  endfunction

  // G function: operates on 4 state words, returns updated values
  // All combinational — one G = 8 arithmetic steps
  task G_step;
    inout [63:0] a; inout [63:0] b; inout [63:0] c; inout [63:0] d;
    input [63:0] x; input [63:0] y;
    begin
      a = (a + b + x);
      d = rotr64(d ^ a, 32);
      c = (c + d);
      b = rotr64(b ^ c, 24);
      a = (a + b + y);
      d = rotr64(d ^ a, 16);
      c = (c + d);
      b = rotr64(b ^ c, 63);
    end
  endtask

  // State wires
  wire [63:0] s [0:15];
  // Message words
  wire [63:0] mw [0:15];

  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : init_h
      assign s[g] = hin[64 * g +: 64];
    end
    for (g = 0; g < 8; g = g + 1) begin : init_iv
      assign s[8 + g] = iv_c(g) ^ (g == 4 ? t_lo : g == 5 ? t_hi : g == 6 ? (last ? 64'hffffffffffffffff : 64'h0) : 64'h0);
    end
    for (g = 0; g < 16; g = g + 1) begin : init_m
      assign mw[g] = min[64 * g +: 64];
    end
  endgenerate

  // 12 rounds, 8 G calls each — all combinational via intermediate wires
  // Using a sequence of intermediate wire arrays
  wire [63:0] r0 [0:15]; wire [63:0] r1 [0:15]; wire [63:0] r2 [0:15];
  wire [63:0] r3 [0:15]; wire [63:0] r4 [0:15]; wire [63:0] r5 [0:15];
  wire [63:0] r6 [0:15]; wire [63:0] r7 [0:15]; wire [63:0] r8 [0:15];
  wire [63:0] r9 [0:15]; wire [63:0] r10 [0:15]; wire [63:0] r11 [0:15];

  // Helper to generate one G call assignment
  // Round macro: assigns from `from` to `to` using sigma[r]
`define G_CALL(from, to, r, a_i, b_i, c_i, d_i, g_i) \
  assign to[a_i] = from[a_i] + from[b_i] + mw[sig(r, 2*g_i)]; \
  assign to[d_i] = rotr64(from[d_i] ^ to[a_i], 32); \
  assign to[c_i] = from[c_i] + to[d_i]; \
  assign to[b_i] = rotr64(from[b_i] ^ to[c_i], 24); \
  assign to[a_i] = to[a_i] + to[b_i] + mw[sig(r, 2*g_i+1)]; \
  assign to[d_i] = rotr64(from[d_i] ^ to[a_i], 16); \
  assign to[c_i] = to[c_i] + to[d_i]; \
  assign to[b_i] = rotr64(from[b_i] ^ to[c_i], 63);

  // Round 0: from s to r0
  `G_CALL(s, r0, 0, 0, 4, 8, 12, 0)
  `G_CALL(s, r0, 0, 1, 5, 9, 13, 1)
  `G_CALL(s, r0, 0, 2, 6, 10, 14, 2)
  `G_CALL(s, r0, 0, 3, 7, 11, 15, 3)
  `G_CALL(s, r0, 0, 0, 5, 10, 15, 4)
  `G_CALL(s, r0, 0, 1, 6, 11, 12, 5)
  `G_CALL(s, r0, 0, 2, 7, 8, 13, 6)
  `G_CALL(s, r0, 0, 3, 4, 9, 14, 7)

  // Rounds 1-10: chain each from the previous
  `G_CALL(r0, r1, 1, 0, 4, 8, 12, 0)
  `G_CALL(r0, r1, 1, 1, 5, 9, 13, 1)
  `G_CALL(r0, r1, 1, 2, 6, 10, 14, 2)
  `G_CALL(r0, r1, 1, 3, 7, 11, 15, 3)
  `G_CALL(r0, r1, 1, 0, 5, 10, 15, 4)
  `G_CALL(r0, r1, 1, 1, 6, 11, 12, 5)
  `G_CALL(r0, r1, 1, 2, 7, 8, 13, 6)
  `G_CALL(r0, r1, 1, 3, 4, 9, 14, 7)

  `G_CALL(r1, r2, 2, 0, 4, 8, 12, 0)
  `G_CALL(r0, r2, 2, 1, 5, 9, 13, 1)
  `G_CALL(r1, r2, 2, 2, 6, 10, 14, 2)
  `G_CALL(r1, r2, 2, 3, 7, 11, 15, 3)
  `G_CALL(r1, r2, 2, 0, 5, 10, 15, 4)
  `G_CALL(r1, r2, 2, 1, 6, 11, 12, 5)
  `G_CALL(r1, r2, 2, 2, 7, 8, 13, 6)
  `G_CALL(r1, r2, 2, 3, 4, 9, 14, 7)

  `G_CALL(r2, r3, 3, 0, 4, 8, 12, 0)
  `G_CALL(r2, r3, 3, 1, 5, 9, 13, 1)
  `G_CALL(r2, r3, 3, 2, 6, 10, 14, 2)
  `G_CALL(r2, r3, 3, 3, 7, 11, 15, 3)
  `G_CALL(r2, r3, 3, 0, 5, 10, 15, 4)
  `G_CALL(r2, r3, 3, 1, 6, 11, 12, 5)
  `G_CALL(r2, r3, 3, 2, 7, 8, 13, 6)
  `G_CALL(r2, r3, 3, 3, 4, 9, 14, 7)

  `G_CALL(r3, r4, 4, 0, 4, 8, 12, 0)
  `G_CALL(r3, r4, 4, 1, 5, 9, 13, 1)
  `G_CALL(r3, r4, 4, 2, 6, 10, 14, 2)
  `G_CALL(r3, r4, 4, 3, 7, 11, 15, 3)
  `G_CALL(r3, r4, 4, 0, 5, 10, 15, 4)
  `G_CALL(r3, r4, 4, 1, 6, 11, 12, 5)
  `G_CALL(r3, r4, 4, 2, 7, 8, 13, 6)
  `G_CALL(r3, r4, 4, 3, 4, 9, 14, 7)

  `G_CALL(r4, r5, 5, 0, 4, 8, 12, 0)
  `G_CALL(r4, r5, 5, 1, 5, 9, 13, 1)
  `G_CALL(r4, r5, 5, 2, 6, 10, 14, 2)
  `G_CALL(r4, r5, 5, 3, 7, 11, 15, 3)
  `G_CALL(r4, r5, 5, 0, 5, 10, 15, 4)
  `G_CALL(r4, r5, 5, 1, 6, 11, 12, 5)
  `G_CALL(r4, r5, 5, 2, 7, 8, 13, 6)
  `G_CALL(r4, r5, 5, 3, 4, 9, 14, 7)

  `G_CALL(r5, r6, 6, 0, 4, 8, 12, 0)
  `G_CALL(r5, r6, 6, 1, 5, 9, 13, 1)
  `G_CALL(r5, r6, 6, 2, 6, 10, 14, 2)
  `G_CALL(r5, r6, 6, 3, 7, 11, 15, 3)
  `G_CALL(r5, r6, 6, 0, 5, 10, 15, 4)
  `G_CALL(r5, r6, 6, 1, 6, 11, 12, 5)
  `G_CALL(r5, r6, 6, 2, 7, 8, 13, 6)
  `G_CALL(r5, r6, 6, 3, 4, 9, 14, 7)

  `G_CALL(r6, r7, 7, 0, 4, 8, 12, 0)
  `G_CALL(r6, r7, 7, 1, 5, 9, 13, 1)
  `G_CALL(r6, r7, 7, 2, 6, 10, 14, 2)
  `G_CALL(r6, r7, 7, 3, 7, 11, 15, 3)
  `G_CALL(r6, r7, 7, 0, 5, 10, 15, 4)
  `G_CALL(r6, r7, 7, 1, 6, 11, 12, 5)
  `G_CALL(r6, r7, 7, 2, 7, 8, 13, 6)
  `G_CALL(r6, r7, 7, 3, 4, 9, 14, 7)

  `G_CALL(r7, r8, 8, 0, 4, 8, 12, 0)
  `G_CALL(r7, r8, 8, 1, 5, 9, 13, 1)
  `G_CALL(r7, r8, 8, 2, 6, 10, 14, 2)
  `G_CALL(r7, r8, 8, 3, 7, 11, 15, 3)
  `G_CALL(r7, r8, 8, 0, 5, 10, 15, 4)
  `G_CALL(r7, r8, 8, 1, 6, 11, 12, 5)
  `G_CALL(r7, r8, 8, 2, 7, 8, 13, 6)
  `G_CALL(r7, r8, 8, 3, 4, 9, 14, 7)

  `G_CALL(r8, r9, 9, 0, 4, 8, 12, 0)
  `G_CALL(r8, r9, 9, 1, 5, 9, 13, 1)
  `G_CALL(r8, r9, 9, 2, 6, 10, 14, 2)
  `G_CALL(r8, r9, 9, 3, 7, 11, 15, 3)
  `G_CALL(r8, r9, 9, 0, 5, 10, 15, 4)
  `G_CALL(r8, r9, 9, 1, 6, 11, 12, 5)
  `G_CALL(r8, r9, 9, 2, 7, 8, 13, 6)
  `G_CALL(r8, r9, 9, 3, 4, 9, 14, 7)

  `G_CALL(r9, r10, 10, 0, 4, 8, 12, 0)
  `G_CALL(r9, r10, 10, 1, 5, 9, 13, 1)
  `G_CALL(r9, r10, 10, 2, 6, 10, 14, 2)
  `G_CALL(r9, r10, 10, 3, 7, 11, 15, 3)
  `G_CALL(r9, r10, 10, 0, 5, 10, 15, 4)
  `G_CALL(r9, r10, 10, 1, 6, 11, 12, 5)
  `G_CALL(r9, r10, 10, 2, 7, 8, 13, 6)
  `G_CALL(r9, r10, 10, 3, 4, 9, 14, 7)

  `G_CALL(r10, r11, 11, 0, 4, 8, 12, 0)
  `G_CALL(r10, r11, 11, 1, 5, 9, 13, 1)
  `G_CALL(r10, r11, 11, 2, 6, 10, 14, 2)
  `G_CALL(r10, r11, 11, 3, 7, 11, 15, 3)
  `G_CALL(r10, r11, 11, 0, 5, 10, 15, 4)
  `G_CALL(r10, r11, 11, 1, 6, 11, 12, 5)
  `G_CALL(r10, r11, 11, 2, 7, 8, 13, 6)
  `G_CALL(r10, r11, 11, 3, 4, 9, 14, 7)

  // Final XOR: dout[i] = hin[i] ^ r11[i] ^ r11[i+8]
  genvar fj;
  generate
    for (fj = 0; fj < 8; fj = fj + 1) begin : final_xor
      assign dout[64 * fj +: 64] = hin[64 * fj +: 64] ^ r11[fj] ^ r11[fj + 8];
    end
  endgenerate
endmodule
