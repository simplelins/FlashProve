// blake2b_comb.v — reference BLAKE2b compression function, purely combinational.
// Loop-based always @(*) (no per-round wire chains, no multi-driver risk); used as an
// independent cross-check next to the KATs: the pipelined/iterative core must match this
// bit for bit. Matches RFC 7693 sec 3.2 with explicit tweak halves and last flag, as the
// format's f (verifier/tests/known_answers/blake2b_f.py).
`timescale 1ns/1ps
module blake2b_comb (
    input  wire [511:0]  hin,
    input  wire [1023:0] min,
    input  wire [63:0]   t_lo,
    input  wire [63:0]   t_hi,
    input  wire          last,
    output reg  [511:0]  dout
);
  function [63:0] rotr64(input [63:0] x, input integer c);
    rotr64 = (x >> c) | (x << (64 - c));
  endfunction

  function [63:0] iv_c(input integer i);
    case (i)
      0: iv_c = 64'h6a09e667f3bcc908; 1: iv_c = 64'hbb67ae8584caa73b;
      2: iv_c = 64'h3c6ef372fe94f82b; 3: iv_c = 64'ha54ff53a5f1d36f1;
      4: iv_c = 64'h510e527fade682d1; 5: iv_c = 64'h9b05688c2b3e6c1f;
      6: iv_c = 64'h1f83d9abfb41bd6b; default: iv_c = 64'h5be0cd19137e2179;
    endcase
  endfunction

  // sigma: 12 rows x 16 entries (RFC 7693; rows 10, 11 repeat rows 0, 1)
  function [3:0] sig(input integer r, input integer j);
    case (r)
      0: sig = j[3:0];
      1: case (j) 0:sig=14;1:sig=10;2:sig=4;3:sig=8;4:sig=9;5:sig=15;6:sig=13;7:sig=6;8:sig=1;9:sig=12;10:sig=0;11:sig=2;12:sig=11;13:sig=7;14:sig=5;default:sig=3; endcase
      2: case (j) 0:sig=11;1:sig=8;2:sig=12;3:sig=0;4:sig=5;5:sig=2;6:sig=15;7:sig=13;8:sig=10;9:sig=14;10:sig=3;11:sig=6;12:sig=7;13:sig=1;14:sig=9;default:sig=4; endcase
      3: case (j) 0:sig=7;1:sig=9;2:sig=3;3:sig=1;4:sig=13;5:sig=12;6:sig=11;7:sig=14;8:sig=2;9:sig=6;10:sig=5;11:sig=10;12:sig=4;13:sig=0;14:sig=15;default:sig=8; endcase
      4: case (j) 0:sig=9;1:sig=0;2:sig=5;3:sig=7;4:sig=2;5:sig=4;6:sig=10;7:sig=15;8:sig=14;9:sig=1;10:sig=11;11:sig=12;12:sig=6;13:sig=8;14:sig=3;default:sig=13; endcase
      5: case (j) 0:sig=2;1:sig=12;2:sig=6;3:sig=10;4:sig=0;5:sig=11;6:sig=8;7:sig=3;8:sig=4;9:sig=13;10:sig=7;11:sig=5;12:sig=15;13:sig=14;14:sig=1;default:sig=9; endcase
      6: case (j) 0:sig=12;1:sig=5;2:sig=1;3:sig=15;4:sig=14;5:sig=13;6:sig=4;7:sig=10;8:sig=0;9:sig=7;10:sig=6;11:sig=3;12:sig=9;13:sig=2;14:sig=8;default:sig=11; endcase
      7: case (j) 0:sig=13;1:sig=11;2:sig=7;3:sig=14;4:sig=12;5:sig=1;6:sig=3;7:sig=9;8:sig=5;9:sig=0;10:sig=15;11:sig=4;12:sig=8;13:sig=6;14:sig=2;default:sig=10; endcase
      8: case (j) 0:sig=6;1:sig=15;2:sig=14;3:sig=9;4:sig=11;5:sig=3;6:sig=0;7:sig=8;8:sig=12;9:sig=2;10:sig=13;11:sig=7;12:sig=1;13:sig=4;14:sig=10;default:sig=5; endcase
      9: case (j) 0:sig=10;1:sig=2;2:sig=8;3:sig=4;4:sig=7;5:sig=6;6:sig=1;7:sig=5;8:sig=15;9:sig=11;10:sig=9;11:sig=14;12:sig=3;13:sig=12;14:sig=13;default:sig=0; endcase
      10: sig = j[3:0];
      default: case (j) 0:sig=14;1:sig=10;2:sig=4;3:sig=8;4:sig=9;5:sig=15;6:sig=13;7:sig=6;8:sig=1;9:sig=12;10:sig=0;11:sig=2;12:sig=11;13:sig=7;14:sig=5;default:sig=3; endcase
    endcase
  endfunction

  reg [63:0] vv [0:15];
  reg [63:0] sa, sb, sc, sd, mx, my;
  integer ii, rr, gg, qa, qb, qc, qd;

  always @(*) begin
    for (ii = 0; ii < 8; ii = ii + 1) begin
      vv[ii]   = hin[64 * ii +: 64];
      vv[8+ii] = iv_c(ii);
    end
    vv[12] = vv[12] ^ t_lo;
    vv[13] = vv[13] ^ t_hi;
    if (last) vv[14] = vv[14] ^ 64'hffffffffffffffff;
    for (rr = 0; rr < 12; rr = rr + 1) begin
      for (gg = 0; gg < 8; gg = gg + 1) begin
        if (gg < 4) begin       // columns: i, i+4, i+8, i+12
          qa = gg;      qb = gg + 4;  qc = gg + 8;   qd = gg + 12;
        end else begin          // diagonals (matrix transpose), k = gg-4:
          qa = gg - 4;  qb = 4 + ((gg + 1) % 4);  qc = 8 + ((gg + 2) % 4);
          qd = 12 + ((gg + 3) % 4);   // (0,5,10,15) (1,6,11,12) (2,7,8,13) (3,4,9,14)
        end
        qa = qa % 16; qb = qb % 16; qc = qc % 16; qd = qd % 16;
        mx = min[64 * sig(rr, 2 * gg)      +: 64];
        my = min[64 * sig(rr, 2 * gg + 1)  +: 64];
        sa = vv[qa]; sb = vv[qb]; sc = vv[qc]; sd = vv[qd];
        sa = sa + sb + mx;
        sd = rotr64(sd ^ sa, 32);
        sc = sc + sd;
        sb = rotr64(sb ^ sc, 24);
        sa = sa + sb + my;
        sd = rotr64(sd ^ sa, 16);
        sc = sc + sd;
        sb = rotr64(sb ^ sc, 63);
        vv[qa] = sa; vv[qb] = sb; vv[qc] = sc; vv[qd] = sd;
      end
    end
    for (ii = 0; ii < 8; ii = ii + 1)
      dout[64 * ii +: 64] = hin[64 * ii +: 64] ^ vv[ii] ^ vv[8 + ii];
  end
endmodule
