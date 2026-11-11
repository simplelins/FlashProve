// tb_str_hash.v — checks str_hash against fpga/vectors/mode_kat.txt (mode_vectors.txt).
// String word j (bytes 8j..8j+7 LE): b<16 label; 16<=b<16+ncnt pattern (7(b-16)+3)%251;
// salt_at<=b<total pattern (5(b-salt_at)+1)%251; else 0 (fill).
`timescale 1ns/1ps
module tb;
  reg clk = 0, rst_n = 0, start = 0;
  reg [63:0] tagword, index;
  reg [255:0] startw;
  reg [31:0] total, ncnt, salt_at;
  reg [6:0] dlen;
  wire [31:0] waddr;
  wire [63:0] wrdata;
  wire busy, done;
  wire [511:0] digest;
  reg [31:0] expw [0:15];
  reg [7:0] ch;
  reg [1023:0] discard;
  integer fh, sc, n = 0, good = 0, i, cyc, got, done_ = 0, dw;
  reg [63:0] bytev;

  // byte b of the string
  function [7:0] sbyte(input integer b);
    begin
      if (b < 16) sbyte = b < 8 ? tagword[8*b +: 8] : index[8*(b-8) +: 8];
      else if (b < 16 + ncnt) sbyte = (7 * (b - 16) + 3) % 251;
      else if (b >= salt_at && b < total) sbyte = (5 * (b - salt_at) + 1) % 251;
      else sbyte = 8'd0;
    end
  endfunction

  // 64-bit word waddr of the string
  reg [63:0] sword;
  integer k;
  // explicit sensitivity: Icarus's @(*) does not see signals read only inside sbyte()
  always @(waddr or tagword or index or ncnt or salt_at or total) begin
    sword = 64'd0;
    for (k = 0; k < 8; k = k + 1) sword[8*k +: 8] = sbyte(waddr * 8 + k);
  end
  assign wrdata = sword;

  str_hash dut (.clk(clk), .rst_n(rst_n), .start(start), .tagword(tagword), .index(index),
                .startw(startw), .total(total), .dlen(dlen), .waddr(waddr), .wrdata(wrdata),
                .busy(busy), .done(done), .digest(digest));
  always #5 clk = ~clk;

  initial begin : main
    fh = $fopen("vectors/mode_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/mode_kat.txt"); $finish; end
    rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; @(posedge clk);
    forever begin
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (sc <= 0) begin got = 1; done_ = 1; end
        else if (ch == "#") sc = $fgets(discard, fh);
        else if (ch == "S") got = 1;
      end
      if (done_) begin
        if (good == n && n > 0) $display("TB PASS: %0d of %0d mode vectors match mode_vectors.txt", good, n);
        else $display("TB FAIL: %0d of %0d", good, n);
        $finish;
      end
      sc = $fscanf(fh, "%h %h", tagword, index);
      for (i = 0; i < 8; i = i + 1) begin
        sc = $fscanf(fh, "%h", bytev);
        startw[32*i +: 32] = bytev[31:0];
      end
      sc = $fscanf(fh, "%h %h %h %h", total, ncnt, salt_at, dlen);
      dw = dlen / 4;
      for (i = 0; i < 8; i = i + 1) expw[i] = 32'd0;
      for (i = 0; i < dw; i = i + 1) sc = $fscanf(fh, "%h", expw[i]);
      start = 1; @(posedge clk); start = 0;
      cyc = 0;
      while (!done && cyc < 100000) begin @(posedge clk); cyc = cyc + 1; end
      n = n + 1; good = good + 1;
      if (!done) begin $display("TIMEOUT total=%0d", total); good = good - 1; end
      for (i = 0; i < dw; i = i + 1)
        if (digest[32*i +: 32] !== expw[i][31:0]) begin
          $display("S MISMATCH tag=%h total=%0d word %0d: got %h want %h",
                   tagword, total, i, digest[32*i +: 32], expw[i][31:0]);
          good = good - 1;
        end
    end
  end
endmodule
