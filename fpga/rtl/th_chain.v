// th_chain.v — the format's TH tree hash (format_hash.py: th()): level 0 hashes the
// list's 128-word (512-byte) pieces under number 10, then each level of 8-word digests
// under 11, until one digest remains. Two memory regions swap roles per level; the
// initial list arrives through a write port. One h_chain instance does the F-chaining.
`timescale 1ns/1ps
module th_chain (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         load_en,      // initial list write port
    input  wire [31:0]  load_addr,
    input  wire [31:0]  load_data,
    input  wire         start,        // pulse after the list is loaded; lenw = words
    input  wire [31:0]  lenw,
    output reg          busy,
    output reg          done,         // one-cycle pulse; digest valid after it
    output reg  [255:0] digest        // 8 u32, narrow order
);
  localparam [2:0] S_IDLE = 0, S_RUN = 1, S_NEXT = 2, S_LEVEL = 3, S_DONE = 4;

  localparam [31:0] OUT_BASE = 32'h00100000;   // out region base (in region at 0)

  reg [31:0] mem [0:32'h1FFFFF];               // 2 x 2^20 words of scratch
  reg [31:0] in_len;                           // words in the in-region list
  reg [31:0] in_base;                          // region the current level reads (0 or OUT_BASE)
  reg [31:0] num;                              // 10 first level, then 11
  reg [31:0] base;                             // word offset of the current chunk
  reg [31:0] out_off;                          // words written to the out region
  reg [31:0] nchunks;
  reg [2:0]  st;

  wire [31:0] chunk_len = (in_len - base) < 32'd128 ? (in_len - base) : 32'd128;

  wire        h_busy, h_done;
  wire [31:0] h_addr;
  wire [511:0] h_state;
  wire [31:0] out_base = in_base ^ OUT_BASE;   // writes always go to the other region
  wire [31:0] h_rdata = mem[in_base + base + h_addr];  // combinational read of the in region

  h_chain hc (
      .clk(clk), .rst_n(rst_n), .start(h_start), .num(num), .x(32'd0), .lenw(chunk_len),
      .mem_addr(h_addr), .mem_rdata(h_rdata),
      .busy(h_busy), .done(h_done), .state(h_state), .digest());
  reg h_start;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; h_start <= 1'b0;
    end else begin
      done <= 1'b0;
      h_start <= 1'b0;
      if (load_en) mem[load_addr] <= load_data;
      case (st)
        S_IDLE: if (start) begin
          in_len <= lenw; num <= 32'd10; base <= 32'd0; out_off <= 32'd0; in_base <= 32'd0;
          nchunks <= (lenw + 32'd127) >> 7;
          busy <= 1'b1; st <= S_RUN;
        end
        S_RUN: begin
          if (!h_busy && !h_start) begin
            h_start <= 1'b1;                  // pulse start of the next chunk
            st <= S_NEXT;
          end
        end
        S_NEXT: begin
          if (h_done) begin
            for (integer j = 0; j < 8; j = j + 1)
              mem[out_base + out_off + j] <= h_state[32*j +: 32];
            out_off <= out_off + 32'd8;
            base <= base + 32'd128;
            nchunks <= nchunks - 32'd1;
            st <= S_LEVEL;
          end
        end
        S_LEVEL: begin
          if (nchunks == 32'd0) begin
            if (out_off == 32'd8) begin
              for (integer j = 0; j < 8; j = j + 1) digest[32*j +: 32] <= mem[out_base + j];
              done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
            end else begin
              in_len <= out_off; num <= 32'd11; base <= 32'd0; out_off <= 32'd0;
              in_base <= out_base;               // the digests become the next level's input
              nchunks <= (out_off + 32'd127) >> 7;
              st <= S_RUN;
            end
          end else begin
            st <= S_RUN;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
