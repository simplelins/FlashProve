// tb_h_chain.v — checks h_chain against fpga/vectors/hash_kat.txt (from
// verifier/tests/hash_vectors.txt). "V num lenw w0..w15" lines drive one H run each:
// the test list's word k is ((k+1) * 0x89ABCDEF) mod 2^32, supplied combinationally on
// mem_rdata. "T" lines (TH) are handled by tb_th_chain.
`timescale 1ns/1ps
module tb;
  reg clk = 0, rst_n = 0, start = 0;
  reg [31:0] num, xv, lenw;
  wire [31:0] mem_addr;
  wire [31:0] mem_rdata = (mem_addr + 32'd1) * 32'h89ABCDEF;
  wire busy, done;
  wire [511:0] state;
  wire [255:0] digest;
  reg [63:0] expw [0:15];
  reg [7:0] ch;
  reg [1023:0] discard;
  integer fh, sc, n = 0, good = 0, i, cyc, got, done_ = 0;

  h_chain dut (.clk(clk), .rst_n(rst_n), .start(start), .num(num), .x(xv), .lenw(lenw),
               .mem_addr(mem_addr), .mem_rdata(mem_rdata),
               .busy(busy), .done(done), .state(state), .digest(digest));
  always #5 clk = ~clk;

  initial begin : main
    fh = $fopen("vectors/hash_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/hash_kat.txt"); $finish; end
    rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; @(posedge clk);
    forever begin
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (sc <= 0) begin got = 1; done_ = 1; end
        else if (ch == "#") sc = $fgets(discard, fh);
        else if (ch == "V" || ch == "T") got = 1;
      end
      if (done_) begin
        if (good == n && n > 0) $display("TB PASS: %0d of %0d H vectors match hash_vectors.txt", good, n);
        else $display("TB FAIL: %0d of %0d", good, n);
        $finish;
      end
      if (ch == "T") begin           // skip TH lines here: op + lenw + 8 words
        for (i = 0; i < 9; i = i + 1) sc = $fscanf(fh, "%h", expw[0]);
      end else begin
        sc = $fscanf(fh, "%h %h", num, lenw);
        for (i = 0; i < 16; i = i + 1) sc = $fscanf(fh, "%h", expw[i]);
        xv = 32'd0;
        start = 1; @(posedge clk); start = 0;
        cyc = 0;
        while (!done && cyc < 4000000) begin @(posedge clk); cyc = cyc + 1; end
        n = n + 1; good = good + 1;
        $display("line done: num=%0d lenw=%0d cyc=%0d", num, lenw, cyc);
        if (!done) begin $display("TIMEOUT V num=%0d lenw=%0d", num, lenw); good = good - 1; end
        for (i = 0; i < 16; i = i + 1)
          if (state[32*i +: 32] !== expw[i][31:0]) begin
            $display("H MISMATCH num=%0d lenw=%0d word %0d: got %h want %h",
                     num, lenw, i, state[32*i +: 32], expw[i][31:0]);
            good = good - 1;
          end
      end
    end
  end
endmodule
