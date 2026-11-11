// tb_gf_alu.v — drives gf_add64/gf_sub64/gf_mul64/gf3_mul from fpga/vectors/gf_kat.txt.
// Lines: "M a b c" | "A a b c" | "S a b c" (u64 hex, c = expected) and
// "E a1 a2 a3 b1 b2 b3 c1 c2 c3" (extension multiply; component i at bits [64*i +: 64]).
// '#' lines are comments. Token-based $fscanf: %h skips whitespace, %c does not, so the
// op character comes from a skip loop. (Icarus's $sscanf caps conversions below 9, which
// is why E lines are not parsed with it.)
`timescale 1ns/1ps
module tb;
  reg [63:0] a, b, exp1;
  wire [63:0] sa, sb, sm;
  reg [191:0] ea, eb;
  wire [191:0] em;
  reg [63:0] f [0:8];
  reg [7:0] ch;
  reg [1023:0] discard;
  integer fh, sc, n = 0, good = 0, i, got, done = 0;

  gf_add64 ua (.a(a), .b(b), .c(sa));
  gf_sub64 us (.a(a), .b(b), .c(sb));
  gf_mul64 um (.a(a), .b(b), .c(sm));
  gf3_mul  u3 (.a(ea), .b(eb), .c(em));

  initial begin : main
    fh = $fopen("vectors/gf_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/gf_kat.txt"); $finish; end
    forever begin
      // next op character, skipping whitespace; '#' discards a comment line
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (sc <= 0) begin got = 1; done = 1; end
        else if (ch == "#") sc = $fgets(discard, fh);
        else if (ch == "M" || ch == "A" || ch == "S" || ch == "E") got = 1;
      end
      if (done) begin
        if (good == n && n > 0) $display("TB PASS: %0d of %0d vectors", good, n);
        else $display("TB FAIL: %0d of %0d", good, n);
        disable main;
      end
      if (ch == "E") begin
        for (i = 0; i < 9; i = i + 1) begin
          sc = $fscanf(fh, "%h", f[i]);
          if (sc <= 0) begin $display("TB FAIL: E line field %0d", i); $finish; end
        end
        for (i = 0; i < 3; i = i + 1) begin
          ea[64*i +: 64] = f[i];
          eb[64*i +: 64] = f[3 + i];
        end
        #1;
        n = n + 1; good = good + 1;
        for (i = 0; i < 3; i = i + 1)
          if (em[64*i +: 64] !== f[6 + i]) begin
            $display("E MISMATCH comp %0d: got %h want %h", i, em[64*i +: 64], f[6 + i]);
            good = good - 1;
          end
      end else begin
        sc = $fscanf(fh, "%h %h %h", a, b, exp1);
        if (sc != 3) begin $display("TB FAIL: %c line fields", ch); $finish; end
        #1;
        n = n + 1; good = good + 1;
        case (ch)
          "M": if (sm !== exp1) begin $display("M MISMATCH: %h*%h got %h want %h", a, b, sm, exp1); good = good - 1; end
          "A": if (sa !== exp1) begin $display("A MISMATCH: %h+%h got %h want %h", a, b, sa, exp1); good = good - 1; end
          "S": if (sb !== exp1) begin $display("S MISMATCH: %h-%h got %h want %h", a, b, sb, exp1); good = good - 1; end
        endcase
      end
    end
  end
endmodule
