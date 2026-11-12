// tb_hp_form.v — checks hp_form_comb against fpga/vectors/hp_kat.txt. Lines:
//   C <nv> <d_0 .. d_{nv-1}> <pl_0 .. pl_{nv-1}>     the variables' degrees and psi lengths
//   G <gamma_0 .. gamma_{nv-1}>                      challenges: 3 u64 limbs each, low limb first
//   P <psi_0[0..pl_0-1] ...>                         psi coefficients: 3 limbs each
//   O <nout> <nout entries, 3 limbs each>            the expected form
`timescale 1ns/1ps
module tb;
  reg [2:0] nv;
  reg [11:0] dl_flat, pl_flat;
  reg [4*192-1:0] gamma_flat;
  reg [4*4*192-1:0] psi_flat;
  wire [4*4*192-1:0] out_flat;
  wire [5:0] nout;
  integer fh, sc, i, j, k, got, eof = 0, status = 2, n = 0;
  reg [63:0] w;
  reg [7:0] ch;
  reg [1023:0] discard;
  reg [191:0] exp;

  hp_form_comb #(.NV(4), .DMAX(4)) dut (
      .nv(nv), .dl(dl_flat), .pl(pl_flat), .gamma(gamma_flat), .psi(psi_flat),
      .out(out_flat), .nout(nout));

  // reads one E element (3 u64 limbs) into the 192-bit register given by the caller
  task read_e(output [191:0] e);
    integer t;
    begin
      for (t = 0; t < 3; t = t + 1) begin
        sc = $fscanf(fh, "%h", w);
        e[64*t +: 64] = w;
      end
    end
  endtask

  initial begin : main
    fh = $fopen("vectors/hp_kat.txt", "r");
    if (!fh) begin $display("TB FAIL: cannot open vectors/hp_kat.txt"); $finish; end
    forever begin
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (sc <= 0) begin got = 1; eof = 1; end
        else if (ch == "#") sc = $fgets(discard, fh);
        else if (ch == "C") got = 1;
      end
      if (eof) begin
        if (status == 2) $display("TB PASS: %0d of %0d hp_form cases match hp_kat.txt", n, n);
        else $display("TB FAIL: %0d of %0d cases", 2 - status, n);
        $finish;
      end
      sc = $fscanf(fh, "%d", i);
      nv = i[2:0];
      for (j = 0; j < nv; j = j + 1) begin
        sc = $fscanf(fh, "%d", i); dl_flat[3*j +: 3] = i[2:0];
      end
      for (j = 0; j < nv; j = j + 1) begin
        sc = $fscanf(fh, "%d", i); pl_flat[3*j +: 3] = i[2:0];
      end
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (ch == "G") got = 1;
        else if (ch == "#") sc = $fgets(discard, fh);
      end
      for (j = 0; j < nv; j = j + 1) begin
        read_e(exp);
        gamma_flat[192*j +: 192] = exp;
      end
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (ch == "P") got = 1;
        else if (ch == "#") sc = $fgets(discard, fh);
      end
      for (j = 0; j < nv; j = j + 1)
        for (k = 0; k < pl_flat[3*j +: 3]; k = k + 1) begin
          read_e(exp);
          psi_flat[192*(j*4 + k) +: 192] = exp;
        end
      got = 0;
      while (!got) begin
        sc = $fscanf(fh, "%c", ch);
        if (ch == "O") got = 1;
        else if (ch == "#") sc = $fgets(discard, fh);
      end
      sc = $fscanf(fh, "%d", i);
      #1;
      n = n + 1;
      if (nout !== i[6:0]) begin
        $display("C MISMATCH case %0d: nout got %0d want %0d", n, nout, i);
        status = 1;
      end
      for (k = 0; k < i; k = k + 1) begin
        read_e(exp);
        for (j = 0; j < 3; j = j + 1)
          if (out_flat[192*k + 64*j +: 64] !== exp[64*j +: 64]) begin
            $display("O MISMATCH case %0d entry %0d limb %0d: got %h want %h",
                     n, k, j, out_flat[192*k + 64*j +: 64], exp[64*j +: 64]);
            status = 1;
          end
      end
    end
  end
endmodule
