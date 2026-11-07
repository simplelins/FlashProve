// tb_blake2b_f.v — reads fpga/vectors/f_kat.txt: one comment line, then 512 data lines of
// 35 hex fields (h[0..7] m[0..15] t_lo t_hi last digest[0..7], 64-bit words).
`timescale 1ns/1ps
module tb;
  reg clk = 0, rst_n = 0, start = 0, last = 0;
  reg [511:0] hin;
  reg [1023:0] min;
  reg [63:0] t_lo, t_hi;
  wire busy, done;
  wire [511:0] dout;
  integer cycle = 0, vec = 0, good = 0, fh, code, i;
  reg [63:0] w [0:34];
  reg [1023:0] discard;

  blake2b_f dut (.clk(clk), .rst_n(rst_n), .start(start), .hin(hin), .min(min),
                 .t_lo(t_lo), .t_hi(t_hi), .last(last), .busy(busy), .done(done), .dout(dout));
  always #5 clk = ~clk;

  initial begin
    if ($test$plusargs("rounds")) begin
      // deep debug: vector 0, state after each round (8 sub-steps), NBA settled with #1
      rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; @(posedge clk);
      hin = 512'h0; min = 1024'h0; t_lo = 0; t_hi = 0; last = 0;
      // real vector-0 inputs are loaded by the main loop below; here we debug the main loop
    end
    rst_n = 0;
    repeat (2) @(posedge clk);
    rst_n = 1; @(posedge clk);
    fh = $fopen("vectors/f_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/f_kat.txt"); $finish; end
    code = $fgets(discard, fh); // the comment line
    for (vec = 0; vec < 512; vec = vec + 1) begin
      for (i = 0; i < 35; i = i + 1) begin
        code = $fscanf(fh, "%h", w[i]);
        if (code <= 0) begin
          $display("TB FAIL: vector %0d field %0d unread", vec, i);
          $finish;
        end
      end
      for (i = 0; i < 8; i = i + 1) hin[64 * i +: 64] = w[i];
      for (i = 0; i < 16; i = i + 1) min[64 * i +: 64] = w[8 + i];
      t_lo = w[24]; t_hi = w[25]; last = |w[26];
      start = 1; cycle = 0;
      @(posedge clk); start = 0;
      if (vec == 0 && $test$plusargs("substeps")) begin
        for (i = 0; i < 24; i = i + 1) begin
          @(posedge clk); #1;
          $display("RTLSUB %0d: %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h ja=%0d jb=%0d jc=%0d jd=%0d cnt=%0d phase=%0d",
                   i, dut.v[0], dut.v[1], dut.v[2], dut.v[3],
                   dut.v[4], dut.v[5], dut.v[6], dut.v[7], dut.v[8], dut.v[9],
                   dut.v[10], dut.v[11], dut.v[12], dut.v[13], dut.v[14], dut.v[15],
                   dut.ja, dut.jb, dut.jc, dut.jd, dut.cnt, dut.phase);
        end
      end else
      while (!done && cycle < 200) begin @(posedge clk); cycle = cycle + 1; end
      good = good + 1;
      for (i = 0; i < 8; i = i + 1)
        if (dout[64 * i +: 64] !== w[27 + i]) begin
          $display("MISMATCH vec %0d word %0d: got %h want %h", vec, i,
                   dout[64 * i +: 64], w[27 + i]);
          good = good - 1;
        end
`ifdef ROUND_DEBUG
      if (vec == 0)
        for (i = 0; i < 16; i = i + 1)
          $display("RTL R%0d w%02d: %h", i < 8 ? 12 : i - 8, i % 8, dut.v[i]);
`endif
    end
    if (good == 512) $display("TB PASS: 512 of 512 vectors match blake2b_f.py");
    else $display("TB FAIL: %0d of 512 passed", good);
    $finish;
  end
endmodule
