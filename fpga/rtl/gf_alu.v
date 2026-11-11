// gf_alu.v — Goldilocks base field F_p, p = 2^64 - 2^32 + 1, plus the challenge-field
// cubic extension E = F_p[x]/(x^3 - 2) (verifier/src/vf_common.h:380-384, CE = 3).
// All combinational, pure IEEE 1364-2005; inputs must be canonical (< p), outputs are.
// Matches fadd/fsub/fmul and Ex operator* (KATs: fpga/vectors/gf_kat.txt).
`timescale 1ns/1ps

// (a + b) mod p for a, b < p: the sum is < 2p, so one conditional subtract.
module gf_add64 (
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] c
);
  localparam [63:0] P = 64'hffffffff00000001;
  wire [64:0] s  = {1'b0, a} + {1'b0, b};
  wire        ge = s[64] || s[63:0] >= P;
  wire [64:0] r  = s - {1'b0, P};
  assign c = ge ? r[63:0] : s[63:0];
endmodule

// (a - b) mod p for a, b < p, via a + (p - b).
module gf_sub64 (
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] c
);
  localparam [63:0] P = 64'hffffffff00000001;
  wire [63:0] pb = P - b;                       // b < p, so pb in [1, p]
  wire [64:0] s  = {1'b0, a} + {1'b0, pb};
  wire        ge = s[64] || s[63:0] >= P;       // a + p - b >= p  <=>  a >= b
  wire [64:0] r  = s - {1'b0, P};
  assign c = ge ? r[63:0] : s[63:0];
endmodule

// (a * b) mod p for a, b < p. With P = a·b = lo + hi·2^64 and hi = h1·2^32 + h0:
//   a·b ≡ lo + (h0<<32) - h0 - h1  (mod p),  because 2^64 ≡ 2^32 - 1 and 2^96 ≡ -1.
// That lies in [-(2^32-1), 2^65): lift a negative with +p (magnitude < p), then fold the
// 2^64 term (v_hi in {0,1}: v ≡ v_lo + v_hi·(2^32-1), < 2^64 + 2^32 - 1 < 2p) and
// conditionally subtract p once.
module gf_mul64 (
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] c
);
  localparam [63:0] P = 64'hffffffff00000001;
  wire [127:0] pr = a * b;
  wire [63:0]  lo = pr[63:0];
  wire [63:0]  hi = pr[127:64];
  wire [31:0]  h0 = hi[31:0];
  wire [31:0]  h1 = hi[63:32];
  wire [64:0]  t  = {1'b0, lo} + ({1'b0, h0} << 32);      // lo + h0·2^32 < 2^65
  wire [32:0]  s  = {1'b0, h0} + {1'b0, h1};              // h0 + h1 < 2^33
  wire [65:0]  v0 = {1'b0, t} - {1'b0, s};                // two's complement, may go negative
  wire         neg = v0[65];
  wire [65:0]  v1 = neg ? v0 + {2'b00, P} : v0;           // +p: now in [0, 2^65)
  wire [64:0]  v  = v1[64:0];
  wire [64:0]  w  = {1'b0, v[63:0]} + (v[64] ? 65'd4294967295 : 65'd0);  // + v_hi·(2^32-1)
  wire         ge = w[64] || w[63:0] >= P;
  wire [64:0]  r  = ge ? w - {1'b0, P} : w;
  assign c = r[63:0];
endmodule

// Elements of E as components (c0, c1, c2) = c0 + c1·x + c2·x², x³ = 2; packed with
// component i at bits [64*i +: 64]:
//   (a0,a1,a2)(b0,b1,b2) = (a0b0 + 2(a1b2 + a2b1), a0b1 + a1b0 + 2·a2b2, a0b2 + a1b1 + a2b0).
module gf3_mul (
    input  wire [191:0] a,
    input  wire [191:0] b,
    output wire [191:0] c
);
  wire [63:0] a0 = a[64*0 +: 64], a1 = a[64*1 +: 64], a2 = a[64*2 +: 64];
  wire [63:0] b0 = b[64*0 +: 64], b1 = b[64*1 +: 64], b2 = b[64*2 +: 64];
  wire [63:0] a0b0, a1b2, a2b1, a0b1, a1b0, a2b2, a0b2, a1b1, a2b0;
  gf_mul64 m00 (.a(a0), .b(b0), .c(a0b0));
  gf_mul64 m12 (.a(a1), .b(b2), .c(a1b2));
  gf_mul64 m21 (.a(a2), .b(b1), .c(a2b1));
  gf_mul64 m01 (.a(a0), .b(b1), .c(a0b1));
  gf_mul64 m10 (.a(a1), .b(b0), .c(a1b0));
  gf_mul64 m22 (.a(a2), .b(b2), .c(a2b2));
  gf_mul64 m02 (.a(a0), .b(b2), .c(a0b2));
  gf_mul64 m11 (.a(a1), .b(b1), .c(a1b1));
  gf_mul64 m20 (.a(a2), .b(b0), .c(a2b0));
  wire [63:0] t0, d0, t1, d1, t2, r0, r1, r2;
  gf_add64 e0a (.a(a1b2), .b(a2b1), .c(t0));  gf_add64 e0b (.a(t0), .b(t0), .c(d0));
  gf_add64 e0c (.a(a0b0), .b(d0),   .c(r0));
  gf_add64 e1a (.a(a0b1), .b(a1b0), .c(t1));  gf_add64 e1b (.a(a2b2), .b(a2b2), .c(d1));
  gf_add64 e1c (.a(t1),   .b(d1),   .c(r1));
  gf_add64 e2a (.a(a0b2), .b(a1b1), .c(t2));  gf_add64 e2b (.a(t2), .b(a2b0), .c(r2));
  assign c = {r2, r1, r0};
endmodule
