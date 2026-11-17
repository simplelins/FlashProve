// tb_fold_round.v — checks fold_round_comb against fpga/vectors/fold_kat.txt.
// The fold is sequential: all R lines (rounds 0..3: g, main x3, q x3) are collected first,
// then ALL inputs are driven and every round's q plus the end message are compared.
`timescale 1ns/1ps
module tb;
  reg [63:0] eps, kept0;
  reg [(2*4+1)*64-1:0] w;
  reg [(1<<2)*8*64-1:0] d, mu;
  reg [4*64-1:0] g4;
  reg [4*3*64-1:0] mainp;
  wire [4*3*64-1:0] q;
  wire [8*64-1:0] emu;
  reg [63:0] exp_g [0:3], exp_m [0:3][0:2], exp_q [0:3][0:2];
  reg [63:0] exp_e [0:7];
  reg [63:0] tmp;
  reg [7:0] ch;
  reg [1023:0] discard;
  integer fh, sc, i, t, got, eof = 0, bad = 0, n = 0, ridx = 0;

  fold_round_comb #(.K(4), .H(2), .LENZK(8)) dut (
      .eps(eps), .kept0(kept0), .w(w), .d(d), .mu(mu), .g(g4), .main(mainp), .q(q), .emu(emu));

  task rd64(output [63:0] x);
    begin sc = $fscanf(fh, "%h", x); end
  endtask

  initial begin : main_blk
    fh = $fopen("vectors/fold_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/fold_kat.txt"); $finish; end
    forever begin
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (sc <= 0) begin got = 1; eof = 1; end
        else if (ch == "#") sc = $fgets(discard, fh);
        else if (ch == "S" || ch == "D" || ch == "M" || ch == "R" || ch == "E") got = 1;
      end
      if (eof) begin
        if (bad == 0) $display("TB PASS: fold_round_comb matches fold_kat.txt (%0d rounds + end)", n);
        else $display("TB FAIL: %0d mismatches", bad);
        $finish;
      end
      if (ch == "S") begin
        rd64(tmp); rd64(tmp); rd64(tmp); // k, h, lenzk
        rd64(eps);
        rd64(kept0);
        for (i = 0; i < 9; i = i + 1) begin rd64(tmp); w[64*i +: 64] = tmp; end
      end else if (ch == "D") begin
        for (i = 0; i < 32; i = i + 1) begin rd64(tmp); d[64*i +: 64] = tmp; end
      end else if (ch == "M") begin
        for (i = 0; i < 32; i = i + 1) begin rd64(tmp); mu[64*i +: 64] = tmp; end
      end else if (ch == "R") begin
        rd64(exp_g[ridx]);
        for (t = 0; t < 3; t = t + 1) begin rd64(exp_m[ridx][t]); end
        for (t = 0; t < 3; t = t + 1) begin rd64(exp_q[ridx][t]); end
        ridx = ridx + 1;
      end else begin // E: all inputs are known — drive and compare everything
        for (i = 0; i < 8; i = i + 1) rd64(exp_e[i]);
        for (i = 0; i < 4; i = i + 1) begin
          g4[64*i +: 64] = exp_g[i];
          for (t = 0; t < 3; t = t + 1) mainp[64*(3*i + t) +: 64] = exp_m[i][t];
        end
        #1;
        for (i = 0; i < 4; i = i + 1)
          for (t = 0; t < 3; t = t + 1)
            if (q[64*(3*i + t) +: 64] !== exp_q[i][t]) begin
              $display("Q MISMATCH round %0d coeff %0d: got %h want %h",
                       i, t, q[64*(3*i + t) +: 64], exp_q[i][t]);
              bad = bad + 1;
            end
        for (i = 0; i < 8; i = i + 1)
          if (emu[64*i +: 64] !== exp_e[i]) begin
            $display("E MISMATCH limb %0d: got %h want %h", i, emu[64*i +: 64], exp_e[i]);
            bad = bad + 1;
          end
        n = ridx;
      end
    end
  end
endmodule
