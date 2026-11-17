// fold_round_comb.v — the FOLD prover's rounds, purely combinational
// (blocks/iop/fold_rounds.h FoldProverRounds + fold_algebra.h + hp.h HidingPolynomial).
// A fold of k = 4 variables with h = 2 mask-fold rounds over tables of 2^h rows x LENZK = 8
// base-field coefficients (column-major: entry c of row b at [64*(b + 2^H*c) +: 64]).
// Per round j: q_j[t] = q_U,t + eps*(main_j[t] + mask_j[t]) (+ eps*kept on t=0, - eps*kept on t=1),
// where
//   q_U,0 = (last ? w_{k,0} : 0) + after_j;  q_U,1 = w_{j,1} + before;  q_U,2 = w_{j,2}
//           (hp.h HidingPolynomial; psi_j = X, so before enters only the linear coefficient)
//   mask_j = pair_products(d, m folded so far)   for j < H
//          = folded_inner * later                for j >= H (the inner product, computed once)
// and bind: the tables fold (v'[i] = v[2i] + g*(v[2i+1] - v[2i]), the interleaved fold),
//   before = before*g + w_j(g), kept *= (1-g), later *= g (j >= H).
// The end message: the folded mu row * eps*later. KATs: fpga/vectors/fold_kat.txt
// (gen_fold_kat.cpp, from the authoritative blocks/iop).
`timescale 1ns/1ps
module fold_round_comb #(
    parameter integer K = 4,       // variables
    parameter integer H = 2,       // mask-fold rounds (h <= k)
    parameter integer LENZK = 8    // the tables' row length
) (
    input  wire [63:0] eps,
    input  wire [63:0] kept0,
    input  wire [(2*K+1)*64-1:0] w,           // hp_place order: w_{j,1} w_{j,2} .., the last also w_{k,0};
                                              // entry n at bits [64*n +: 64]
    input  wire [(1<<H)*LENZK*64-1:0] d,      // entry (b, c) at [64*(b + (1<<H)*c) +: 64]
    input  wire [(1<<H)*LENZK*64-1:0] mu,
    input  wire [K*64-1:0] g,                 // the challenges, in round order
    input  wire [K*3*64-1:0] main,            // the main rows' quadratic, per round: [64*(3*j+t) +: 64]
    output reg  [K*3*64-1:0] q,               // the round polynomials, lowest first
    output reg  [LENZK*64-1:0] emu            // the end message: the folded mu * eps*later
);
  // ---- base field ----
  function [63:0] gf_add(input [63:0] a, input [63:0] b);
    reg [64:0] s;
    begin
      s = {1'b0, a} + {1'b0, b};
      gf_add = (s[64] || s[63:0] >= 64'hffffffff00000001) ? s[63:0] - 64'hffffffff00000001 : s[63:0];
    end
  endfunction
  function [63:0] gf_neg(input [63:0] a);
    gf_neg = a == 64'd0 ? 64'd0 : 64'hffffffff00000001 - a;
  endfunction
  function [63:0] gf_mul(input [63:0] a, input [63:0] b);
    reg [127:0] pr;
    reg [63:0] lo, hi, r;
    reg [31:0] h0, h1;
    reg [64:0] t;
    reg [32:0] s;
    reg [65:0] v0, v1;
    reg [64:0] v, w;
    begin
      pr = a * b;
      lo = pr[63:0]; hi = pr[127:64];
      h0 = hi[31:0]; h1 = hi[63:32];
      t = {1'b0, lo} + ({1'b0, h0} << 32);
      s = {1'b0, h0} + {1'b0, h1};
      v0 = {1'b0, t} - {1'b0, s};
      v1 = v0[65] ? v0 + {2'b00, 64'hffffffff00000001} : v0;
      v = v1[64:0];
      w = {1'b0, v[63:0]} + (v[64] ? 65'd4294967295 : 65'd0);
      r = (w[64] || w[63:0] >= 64'hffffffff00000001) ? w[63:0] - 64'hffffffff00000001 : w[63:0];
      gf_mul = r;
    end
  endfunction

  integer j, t, i, c;
  reg [63:0] dm  [0:(1<<H)*LENZK-1];   // the d table, folded in place
  reg [63:0] mm  [0:(1<<H)*LENZK-1];   // the mu table
  reg [63:0] af  [0:K-1];              // after_[i] (hp.h)
  reg [63:0] before, kept, later, finner;
  reg [63:0] qu  [0:2];                // the U round polynomial
  reg [63:0] qm  [0:2];                // the mask part
  reg [63:0] a0, a1, m0, m1;
  reg [63:0] wd [0:2*K];               // the unpacked w (2k+1 entries)
  reg [63:0] gd [0:K-1];               // the unpacked challenges
  reg [63:0] mn [0:K-1][0:2];          // the unpacked main
  reg [63:0] du [0:(1<<H)*LENZK-1];    // the unpacked d
  reg [63:0] muu [0:(1<<H)*LENZK-1];   // the unpacked mu
  reg finner_known;

  // Explicit sensitivity: Icarus's @(*) misses reads inside functions.
  always @(eps or kept0 or w or d or mu or g or main) begin
    // unpack the packed inputs
    for (i = 0; i < 2*K+1; i = i + 1) wd[i] = w[64*i +: 64];
    for (i = 0; i < K; i = i + 1) begin
      gd[i] = g[64*i +: 64];
      for (t = 0; t < 3; t = t + 1) mn[i][t] = main[64*(3*i + t) +: 64];
    end
    for (i = 0; i < (1 << H) * LENZK; i = i + 1) begin
      du[i] = d[64*i +: 64];
      muu[i] = mu[64*i +: 64];
    end
    // after_[i] = phi(w_{i+1}) + after_[i+1] with the plain moments (1,1,1); after_{k-1} = 0
    af[K-1] = 64'd0;
    // phi(w) = 2*w_0 + w_1 + w_2 (the plain moments are (2, 1, 1): phi(X^0) = 0^0 + 1^0 = 2),
    // and of_one() = moment[0] = 2 multiplies the after-recursion (hp.h).
    // The wd slots DIFFER by variable: a non-last variable's coefficients are at wd[2l], wd[2l+1]
    // (no t=0 slot), the last variable's at wd[2(k-1)], wd[2(k-1)+1], wd[2(k-1)+2].
    for (i = K - 2; i >= 0; i = i - 1) begin
      if (i + 1 == K - 1)
        af[i] = gf_add(gf_add(gf_mul(64'd2, wd[2*(K-1)]), wd[2*(K-1)+1]),
                       gf_add(wd[2*(K-1)+2], gf_mul(64'd2, af[i+1])));
      else
        af[i] = gf_add(gf_add(wd[2*(i+1)], wd[2*(i+1)+1]), gf_mul(64'd2, af[i+1]));
    end
    before = 64'd0;
    kept = kept0;
    later = 64'd1;
    finner = 64'd0;
    finner_known = 1'b0;
    for (i = 0; i < (1 << H) * LENZK; i = i + 1) begin
      dm[i] = du[i];
      mm[i] = muu[i];
    end
    for (j = 0; j < K; j = j + 1) begin
      // ---- the U round polynomial (hp.h: q = w_i + before*psi_i + after_i; psi = X) ----
      qu[0] = gf_add(j == K-1 ? wd[2*j] : 64'd0, af[j]);
      qu[1] = gf_add(j == K-1 ? wd[2*j+1] : wd[2*j], before);
      qu[2] = j == K-1 ? wd[2*j+2] : wd[2*j+1];
      // ---- the mask part ----
      if (j < H) begin
        qm[0] = 64'd0; qm[1] = 64'd0; qm[2] = 64'd0;
        // the interleaved layout: the flat pairs (2i, 2i+1) are rows 2b, 2b+1 of one column
        for (i = 0; i < (1 << (H - j)) * LENZK; i = i + 2) begin
          a0 = dm[i];
          a1 = gf_add(dm[i+1], gf_neg(dm[i]));
          m0 = mm[i];
          m1 = gf_add(mm[i+1], gf_neg(mm[i]));
          qm[0] = gf_add(qm[0], gf_mul(a0, m0));
          qm[1] = gf_add(gf_add(qm[1], gf_mul(a0, m1)), gf_mul(a1, m0));
          qm[2] = gf_add(qm[2], gf_mul(a1, m1));
        end
      end else begin
        if (!finner_known) begin
          finner = 64'd0;
          for (i = 0; i < LENZK; i = i + 1) finner = gf_add(finner, gf_mul(dm[i], mm[i]));
          finner_known = 1'b1;
        end
        qm[0] = 64'd0;
        qm[1] = gf_mul(finner, later);
        qm[2] = 64'd0;
      end
      // ---- q = q_U + eps*(main + mask), and the kept terms on t = 0, 1 ----
      for (t = 0; t < 3; t = t + 1)
        q[64*(3*j + t) +: 64] = gf_add(qu[t], gf_mul(eps, gf_add(mn[j][t], qm[t])));
      q[64*3*j +: 64] = gf_add(q[64*3*j +: 64], gf_mul(eps, kept));
      q[64*(3*j+1) +: 64] = gf_add(q[64*(3*j+1) +: 64], gf_neg(gf_mul(eps, kept)));
      // ---- bind ----
      // poly_at(w_j, g) = w_{j,0} + w_{j,1}*g + w_{j,2}*g^2, where a non-last variable's
      // coefficients live at wd[2j], wd[2j+1] (w_{j,0} = 0) and the last variable's at
      // wd[2(K-1)], wd[2(K-1)+1], wd[2(K-1)+2].
      before = gf_add(gf_mul(before, gd[j]),
                      gf_add(j == K-1 ? wd[2*j] : 64'd0,
                             gf_add(gf_mul(j == K-1 ? wd[2*j+1] : wd[2*j], gd[j]),
                                    gf_mul(j == K-1 ? wd[2*j+2] : wd[2*j+1], gf_mul(gd[j], gd[j])))));
      if (j < H) begin
        for (i = 0; i < (1 << (H - j - 1)) * LENZK; i = i + 1) begin
          dm[i] = gf_add(dm[2*i], gf_mul(gd[j], gf_add(dm[2*i+1], gf_neg(dm[2*i]))));
          mm[i] = gf_add(mm[2*i], gf_mul(gd[j], gf_add(mm[2*i+1], gf_neg(mm[2*i]))));
        end
      end else begin
        later = gf_mul(later, gd[j]);
      end
      kept = gf_mul(kept, gf_add(64'd1, gf_neg(gd[j])));
    end
    // ---- the end message: the folded mu row, UNSCALED (the C++ scales e.d, not e.mu) ----
    for (c = 0; c < LENZK; c = c + 1) emu[64*c +: 64] = mm[c];
  end
endmodule
