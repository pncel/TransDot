// Phase E micro-TB: drive INT_DP_FMADD with canned operands and observe
// product_int_dp via the FMA's DEBUG_INT_DP $display block.
// Compile with +define+DEBUG_INT_DP to get the trace lines.
// FP regression remains gated by tb_fpnew; this TB lives alongside it.

module tb_int_dp_micro;
  import fpnew_pkg::*;

  localparam int unsigned WIDTH = 32;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic [2:0][WIDTH-1:0]    operands_i;
  fpnew_pkg::roundmode_e    rnd_mode_i;
  fpnew_pkg::operation_e    op_i;
  logic                     op_mod_i;
  fpnew_pkg::fp_format_e    src_fmt_i;
  fpnew_pkg::fp_format_e    dst_fmt_i;
  fpnew_pkg::int_format_e   int_fmt_i;
  logic                     vectorial_op_i;
  logic                     simd_mask_i;  // NumLanes=1 since transdot_features.EnableVectors=0
  logic                     tag_i;
  logic                     in_valid_i;
  logic                     flush_i;
  logic                     out_ready_i;

  logic                     in_ready_o;
  logic [WIDTH-1:0]         result_o;
  fpnew_pkg::status_t       status_o;
  logic                     tag_o;
  logic                     out_valid_o;
  logic                     busy_o;

  transdot_fpu_top #(
    .EnableSIMDMask(1)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .operands_i,
    .rnd_mode_i,
    .op_i,
    .op_mod_i,
    .src_fmt_i,
    .dst_fmt_i,
    .int_fmt_i,
    .mx_enable_i (1'b0),
    .mx_scale_a_i(8'd0),
    .mx_scale_b_i(8'd0),
    .vectorial_op_i,
    .simd_mask_i,
    .tag_i,
    .in_valid_i,
    .in_ready_o,
    .flush_i,
    .result_o,
    .status_o,
    .tag_o,
    .out_valid_o,
    .out_ready_i,
    .busy_o
  );

  task automatic init_idle();
    operands_i     = '0;
    rnd_mode_i     = RNE;
    op_i           = FMADD;
    op_mod_i       = 1'b0;
    src_fmt_i      = FP32;
    dst_fmt_i      = FP32;
    int_fmt_i      = INT8;
    vectorial_op_i = 1'b0;
    simd_mask_i    = '1;
    tag_i          = 1'b0;
    in_valid_i     = 1'b0;
    flush_i        = 1'b0;
    out_ready_i    = 1'b1;
  endtask

  task automatic issue_int_dp(
      input logic [WIDTH-1:0]    a,
      input logic [WIDTH-1:0]    b,
      input logic [WIDTH-1:0]    c,
      input fpnew_pkg::int_format_e ifmt,
      input fpnew_pkg::fp_format_e  src_fmt,
      input logic                signed_op
  );
    // Set inputs THEN wait for clock edge — avoids race with DUT's always_ff sampling
    operands_i[0] = a;
    operands_i[1] = b;
    operands_i[2] = c;
    op_i          = INT_DP_FMADD;
    op_mod_i      = ~signed_op;     // op_mod=0 → signed; op_mod=1 → unsigned
    int_fmt_i     = ifmt;
    src_fmt_i     = src_fmt;
    dst_fmt_i     = FP32;
    in_valid_i    = 1'b1;
    @(posedge clk);                 // DUT samples on this edge with new values
    // NBAs so the deassertion lands in the NBA region — past the active region
    // where the DUT's always_ff also runs.
    in_valid_i   <= 1'b0;
    op_i         <= FMADD;
    // Drain enough cycles for the multiplier output to register through pipe_qq_en
    repeat (8) @(posedge clk);
  endtask

  initial begin
    init_idle();
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("\n========== [TB_MICRO] Test 1: INT8 unsigned, lane0=(5,7), lane1=(0,0) ==========");
    $display("[TB_MICRO]   Expected: |a0|*|b0| = 35 = 0x23, lane1 = 0");
    $display("[TB_MICRO]   Wrapper bit-window for INT8 lane0: pp3_addend_lane0[39:24] = 16'h0023");
    $display("[TB_MICRO]   Expected product_int_dp[49:0] = 50'h0_0000_2300_0000  (= 35 << 24)");
    issue_int_dp(32'h0000_0005, 32'h0000_0007, 32'h0000_0000, INT8, FP16, 1'b0);

    $display("\n========== [TB_MICRO] Test 2: INT8 unsigned, lane0=(0,0), lane1=(3,4) ==========");
    $display("[TB_MICRO]   Expected: lane0=0, |a1|*|b1| = 12 = 0x0C");
    $display("[TB_MICRO]   Both lanes accumulate at same window [39:24]; expected = 50'h0_0000_0C00_0000");
    issue_int_dp(32'h0000_0300, 32'h0000_0400, 32'h0000_0000, INT8, FP16, 1'b0);

    $display("\n========== [TB_MICRO] Test 3: INT8 unsigned, lane0=(2,3), lane1=(4,5) ==========");
    $display("[TB_MICRO]   Expected: 2*3 + 4*5 = 6 + 20 = 26 = 0x1A at [39:24]");
    $display("[TB_MICRO]   Expected product_int_dp = 50'h0_0000_1A00_0000");
    issue_int_dp(32'h0000_0402, 32'h0000_0503, 32'h0000_0000, INT8, FP16, 1'b0);

    $display("\n========== [TB_MICRO] Test 4: INT4 unsigned, lane0=(3,4) only ==========");
    $display("[TB_MICRO]   FP4_DP geometry: per-lane 8-bit product at pp3_addend_lane0[44:37]");
    $display("[TB_MICRO]   Expected: 3*4 = 12 = 8'h0C, lane0 only");
    $display("[TB_MICRO]   (Note: FP4 of 0x3*FP4 of 0x4 also gives 12, so this is coincidental.)");
    issue_int_dp(32'h0000_0003, 32'h0000_0004, 32'h0000_0000, INT4, FP4, 1'b0);

    $display("\n========== [TB_MICRO] Test 4b: INT4 unsigned, lane0=(7,3) — non-coincidental ==========");
    $display("[TB_MICRO]   Expected (INT): 7*3 = 21 = 8'h15");
    $display("[TB_MICRO]   FP4 e2m1 of 0x7*0x3 = 1.5*4 * 1.5*1 = 9.0 (=36 in qtr-units = 8'h24); should NOT be this");
    $display("[TB_MICRO]   At pp3_addend_lane0[44:37]: 21 → bits 41,39,37 = 1; 36 → bits 42,39 = 1");
    issue_int_dp(32'h0000_0007, 32'h0000_0003, 32'h0000_0000, INT4, FP4, 1'b0);

    $display("\n========== [TB_MICRO] Test 5: INT16 unsigned, lane0=(10,20) ==========");
    $display("[TB_MICRO]   scalar geometry, dp_enable=0");
    $display("[TB_MICRO]   Expected: 10*20 = 200 = 0xC8 at final_sum[31:0]");
    issue_int_dp(32'h0000_000A, 32'h0000_0014, 32'h0000_0000, INT16, FP32, 1'b0);

    $display("\n========== [TB_MICRO] Test 6: INT8 signed, lane0=(-5,7), lane1=(0,0) ==========");
    $display("[TB_MICRO]   |a0|*|b0| = 35; sign(prod) = 1 (a neg); expect signed 50-bit = -35");
    issue_int_dp(32'h0000_00FB, 32'h0000_0007, 32'h0000_0000, INT8, FP16, 1'b1);

    $display("\n========== [TB_MICRO] Test 7: INT8 unsigned, lane0=(5,7), c=100 ==========");
    $display("[TB_MICRO]   Expected: 35 + 100 = 135 = 8'h87");
    issue_int_dp(32'h0000_0005, 32'h0000_0007, 32'h0000_0064, INT8, FP16, 1'b0);

    $display("\n========== [TB_MICRO] Test 8: INT8 signed, lane0=(-5,7), c=-1000 ==========");
    $display("[TB_MICRO]   Expected: -35 + (-1000) = -1035 = 32'hFFFFFBF5");
    issue_int_dp(32'h0000_00FB, 32'h0000_0007, 32'hFFFF_FC18, INT8, FP16, 1'b1);

    $display("\n========== [TB_MICRO] Test 9: INT8 signed, both lanes (-128,-128) — boundary ==========");
    $display("[TB_MICRO]   Expected: 16384 + 16384 = +32768 (= 17-bit boundary, would wrap to -32768 in 16-bit)");
    issue_int_dp(32'h0000_8080, 32'h0000_8080, 32'h0000_0000, INT8, FP16, 1'b1);

    $display("\n========== [TB_MICRO] Test 10: INT8 signed, mixed signs (-50,50)+(30,-70) ==========");
    $display("[TB_MICRO]   Expected: -50*50 + 30*(-70) = -2500 + -2100 = -4600 = 32'hFFFFEE08");
    issue_int_dp(32'h0000_1ECE, 32'h0000_BA32, 32'h0000_0000, INT8, FP16, 1'b1);

    $display("\n========== [TB_MICRO] Test 11: INT8 signed, lane0=(50,50) lane1=(-30,70) ==========");
    $display("[TB_MICRO]   Expected: 50*50 + (-30)*70 = 2500 - 2100 = +400 = 32'h00000190");
    issue_int_dp(32'h0000_E232, 32'h0000_4632, 32'h0000_0000, INT8, FP16, 1'b1);

    repeat (10) @(posedge clk);
    $display("\n[TB_MICRO] DONE");
    $finish;
  end

  // result_o capture — print whenever a valid output appears on the FPU
  always_ff @(posedge clk) begin
    if (out_valid_o && rst_n) begin
      $display("[TB_RESULT] t=%0t  result_o=%0d (%h)  status=%h",
               $time, $signed(result_o), result_o, status_o);
    end
  end

  initial begin
    #50000;  // safety timeout
    $display("[TB_MICRO] TIMEOUT");
    $finish;
  end

endmodule
