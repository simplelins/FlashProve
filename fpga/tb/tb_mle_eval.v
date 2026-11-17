// tb_mle_eval.v — checks mle_eval_comb against fpga/vectors/mle_kat.txt.
// Lines: "C N", "T table (2^N entries x 3 limbs)", "Z z (N x 3 limbs)", "V value (3 limbs)".
`timescale 1ns/1ps
module tb;
  reg [63:0] tmp;
  reg [191:0] expv;
  reg [191:0] curv;

  reg [7:0] ch;
  reg [1023:0] discard;
  integer fh, sc, n = 0, bad = 0, i, j, got, eof = 0;
  integer curN = 6;

  // one module per size would waste space; drive the largest and zero-mask the unused
  // rounds by replaying per-case: the module takes N as a port, so instantiate NMAX and
  // feed a table of 1<<NMAX with the tail entries arbitrary only when N == NMAX. For
  // smaller N the TB drives the module port of that size via generate (below).
  wire [191:0] v3, v4, v6;
  reg [(1<<3)*192-1:0] t3; reg [3*192-1:0] z3;
  reg [(1<<4)*192-1:0] t4; reg [4*192-1:0] z4;
  reg [(1<<6)*192-1:0] t6; reg [6*192-1:0] z6;
  mle_eval_comb #(.N(3)) u3 (.tbl(t3), .zp(z3), .value(v3));
  mle_eval_comb #(.N(4)) u4 (.tbl(t4), .zp(z4), .value(v4));
  mle_eval_comb #(.N(6)) u6 (.tbl(t6), .zp(z6), .value(v6));

  task rdE(output [191:0] e);
    begin sc = $fscanf(fh, "%h", tmp); e[63:0] = tmp;
          sc = $fscanf(fh, "%h", tmp); e[127:64] = tmp;
          sc = $fscanf(fh, "%h", tmp); e[191:128] = tmp; end
  endtask

  initial begin : main
    fh = $fopen("vectors/mle_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/mle_kat.txt"); $finish; end
    forever begin
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (sc <= 0) begin got = 1; eof = 1; end
        else if (ch == "#") sc = $fgets(discard, fh);
        else if (ch == "C") got = 1;
      end
      if (eof) begin
        if (bad == 0) $display("TB PASS: mle_eval_comb matches mle_kat.txt (3 cases)");
        else $display("TB FAIL: %0d mismatches", bad);
        $finish;
      end
      sc = $fscanf(fh, "%d", curN);
      if (curN == 3) begin
        for (i = 0; i < 8; i = i + 1) begin
          rdE(tmp); t3[192*i +: 192] = tmp;
        end
        for (i = 0; i < 3; i = i + 1) begin
          rdE(tmp); z3[192*i +: 192] = tmp;
        end
      end else if (curN == 4) begin
        for (i = 0; i < 16; i = i + 1) begin
          rdE(tmp); t4[192*i +: 192] = tmp;
        end
        for (i = 0; i < 4; i = i + 1) begin
          rdE(tmp); z4[192*i +: 192] = tmp;
        end
      end else begin
        for (i = 0; i < 64; i = i + 1) begin
          rdE(tmp); t6[192*i +: 192] = tmp;
        end
        for (i = 0; i < 6; i = i + 1) begin
          rdE(tmp); z6[192*i +: 192] = tmp;
        end
      end

      #1;
      curv = (curN == 3) ? v3 : (curN == 4) ? v4 : v6;
      for (i = 0; i < 3; i = i + 1) begin
        rdE(expv);
        if (curv[64*i +: 64] !== expv[64*i +: 64]) begin
          $display("V MISMATCH case N=%0d limb %0d: got %h want %h",
                   curN, i, curv[64*i +: 64], expv[64*i +: 64]);
          bad = bad + 1;
        end
      end
      n = n + 1;
    end
  end
endmodule
