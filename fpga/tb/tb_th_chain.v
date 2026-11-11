// tb_th_chain.v — checks th_chain against the "T" lines of fpga/vectors/hash_kat.txt
// (from verifier/tests/hash_vectors.txt): "T lenw w0..w7". The list's word k is
// ((k+1) * 0x89ABCDEF) mod 2^32, loaded through th_chain's write port.
`timescale 1ns/1ps
module tb;
  reg clk = 0, rst_n = 0, load_en = 0, start = 0;
  reg [31:0] load_addr, load_data, lenw;
  wire busy, done;
  wire [255:0] digest;
  reg [31:0] expw [0:7];
  reg [7:0] ch;
  reg [1023:0] discard;
  integer fh, sc, n = 0, good = 0, i, cyc, got, done_ = 0;

  th_chain dut (.clk(clk), .rst_n(rst_n), .load_en(load_en), .load_addr(load_addr),
                .load_data(load_data), .start(start), .lenw(lenw),
                .busy(busy), .done(done), .digest(digest));
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
        if (good == n && n > 0) $display("TB PASS: %0d of %0d TH vectors match hash_vectors.txt", good, n);
        else $display("TB FAIL: %0d of %0d", good, n);
        $finish;
      end
      if (ch == "V") begin           // skip H lines: num + lenw + 16 words
        for (i = 0; i < 18; i = i + 1) sc = $fscanf(fh, "%h", expw[0]);
      end else begin
        sc = $fscanf(fh, "%h", lenw);
        for (i = 0; i < 8; i = i + 1) sc = $fscanf(fh, "%h", expw[i]);
        for (i = 0; i < lenw; i = i + 1) begin
          load_en = 1; load_addr = i; load_data = (i + 32'd1) * 32'h89ABCDEF;
          @(posedge clk);
        end
        load_en = 0;
        repeat (2) @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        cyc = 0;
        while (!done && cyc < 60000000) begin @(posedge clk); cyc = cyc + 1; end
        n = n + 1; good = good + 1;
        $display("line done: lenw=%0d cyc=%0d", lenw, cyc);
        if (!done) begin $display("TIMEOUT T lenw=%0d", lenw); good = good - 1; end
        for (i = 0; i < 8; i = i + 1)
          if (digest[32*i +: 32] !== expw[i][31:0]) begin
            $display("TH MISMATCH lenw=%0d word %0d: got %h want %h",
                     lenw, i, digest[32*i +: 32], expw[i][31:0]);
            good = good - 1;
          end
      end
    end
  end
endmodule
