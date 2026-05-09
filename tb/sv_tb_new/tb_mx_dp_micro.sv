// Phase C micro-TB for OCP MX (microscaling) FP4 / FP8 dot-product paths.
//
// Drives transdot_fpu_top with mx_enable_i set and various E8M0 scale pairs.
// Compile with +define+DEBUG_MX_DP to get the trace lines from the FMA.
//
// PRE-PHASE-D STATUS: the FMA does not yet consume mx_scale_*; only the
// identity-scale (127,127) tests are expected to PASS at this point. The
// non-identity tests are marked EXPECTED_FAIL_PRE_PHASE_D and will turn green
// once the exponent-datapath injection in Phase D lands.
//
// Mathematical contract (per OCP MX v1.0):
//   result = (2^(s_A - 127)) * (2^(s_B - 127)) * sum_i(a_i * b_i) + c
//          = 2^(s_A + s_B - 254) * fp_dot + c
//
// FP4 (E2M1) lane layout used by transdot_fp4_dp_qtr10:
//   lane 0: operand[3:0]*operand[3:0] + operand[7:4]*operand[7:4]
//   lane 1: [11:8]*[11:8] + [15:12]*[15:12]
//   lane 2: [19:16]*[19:16] + [23:20]*[23:20]
//   lane 3: [27:24]*[27:24] + [31:28]*[31:28]

module tb_mx_dp_micro;
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
  logic                     mx_enable_i;
  logic [7:0]               mx_scale_a_i;
  logic [7:0]               mx_scale_b_i;
  logic                     vectorial_op_i;
  logic                     simd_mask_i;
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

  // Pass/fail tracking
  int unsigned pass_count = 0;
  int unsigned fail_count = 0;
  int unsigned expected_fail_count = 0;

  // Capture the most recent valid result. last_result_valid_q is driven only
  // by this always_ff; consumers in initial blocks read it (no concurrent
  // procedural assign — VCS strict-driver rule).
  logic [WIDTH-1:0] last_result_q;
  logic             last_result_valid_q;
  logic             consume_result;  // pulse from check_result to clear valid
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      last_result_valid_q <= 1'b0;
      last_result_q       <= '0;
    end else begin
      if (out_valid_o) begin
        last_result_q       <= result_o;
        last_result_valid_q <= 1'b1;
      end else if (consume_result) begin
        last_result_valid_q <= 1'b0;
      end
    end
  end

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
    .mx_enable_i,
    .mx_scale_a_i,
    .mx_scale_b_i,
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
    mx_enable_i    = 1'b0;
    mx_scale_a_i   = 8'd0;
    mx_scale_b_i   = 8'd0;
    vectorial_op_i = 1'b0;
    simd_mask_i    = '1;
    tag_i          = 1'b0;
    in_valid_i     = 1'b0;
    flush_i        = 1'b0;
    out_ready_i    = 1'b1;
    consume_result = 1'b0;
  endtask

  // Issue one MX FP4 DP FMADD: a/b = packed FP4 ×8, c = FP32, scales = E8M0.
  task automatic issue_mx_fp4_dp(
      input logic [WIDTH-1:0] a_pack,
      input logic [WIDTH-1:0] b_pack,
      input logic [WIDTH-1:0] c_fp32,
      input logic [7:0]       scale_a,
      input logic [7:0]       scale_b
  );
    operands_i[0] = a_pack;
    operands_i[1] = b_pack;
    operands_i[2] = c_fp32;
    op_i          = TDOT_FP4_DP_FMADD;
    op_mod_i      = 1'b0;
    src_fmt_i     = FP4;
    dst_fmt_i     = FP32;
    int_fmt_i     = INT8;       // don't-care for FP4 DP
    mx_enable_i   = 1'b1;
    mx_scale_a_i  = scale_a;
    mx_scale_b_i  = scale_b;
    in_valid_i    = 1'b1;
    @(posedge clk);
    in_valid_i   <= 1'b0;
    op_i         <= FMADD;
    mx_enable_i  <= 1'b0;
    mx_scale_a_i <= 8'd0;
    mx_scale_b_i <= 8'd0;
    repeat (12) @(posedge clk);
  endtask

  // FP4 (E2M1) decode helper: 4-bit nibble → real value.
  function automatic real fp4_to_real(input logic [3:0] x);
    logic       s;
    logic [1:0] e;
    logic       m;
    real        v;
    s = x[3]; e = x[2:1]; m = x[0];
    if (e == 2'b00 && m == 1'b0) v = 0.0;
    else if (e == 2'b00)         v = 0.5;            // subnormal: 0.b1 = 0.5
    else                         v = (1.0 + (m ? 0.5 : 0.0)) * (2.0 ** (int'(e) - 1));
    return s ? -v : v;
  endfunction

  // Compute golden FP32 bits for an MX FP4 DP FMADD case.
  function automatic logic [31:0] golden_mx_fp4_dp(
      input logic [31:0] a_pack,
      input logic [31:0] b_pack,
      input logic [31:0] c_fp32,
      input logic [7:0]  scale_a,
      input logic [7:0]  scale_b
  );
    real dot, scale, c_r, total;
    int unsigned i;
    dot = 0.0;
    for (i = 0; i < 8; i++) begin
      dot += fp4_to_real(a_pack[4*i +: 4]) * fp4_to_real(b_pack[4*i +: 4]);
    end
    scale = (2.0 ** (int'(scale_a) - 127)) * (2.0 ** (int'(scale_b) - 127));
    c_r = $bitstoshortreal(c_fp32);
    total = scale * dot + c_r;
    return $shortrealtobits(total);
  endfunction

  task automatic check_result(
      input string             tag_str,
      input logic [31:0]       expected,
      input bit                expected_to_fail_pre_phase_d
  );
    logic ok;
    ok = last_result_valid_q && (last_result_q == expected);
    if (ok) begin
      $display("[TB_MX] PASS  %s  result=%h  expected=%h",
               tag_str, last_result_q, expected);
      pass_count++;
    end else if (expected_to_fail_pre_phase_d) begin
      $display("[TB_MX] EXPECTED_FAIL_PRE_PHASE_D  %s  result=%h  expected=%h  (will pass after Phase D)",
               tag_str, last_result_q, expected);
      expected_fail_count++;
    end else begin
      $display("[TB_MX] FAIL  %s  result=%h  expected=%h",
               tag_str, last_result_q, expected);
      fail_count++;
    end
    // Pulse consume so the always_ff clears last_result_valid_q for next test
    consume_result <= 1'b1;
    @(posedge clk);
    consume_result <= 1'b0;
  endtask

  initial begin
    string  test_name;
    logic [31:0] gold;
    logic [31:0] a, b, c;
    logic [7:0]  sa, sb;

    init_idle();
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ----------------------------------------------------------------------
    // Test 1 — Zero block. scale doesn't matter when dot=0.
    // ----------------------------------------------------------------------
    test_name = "T1: zero-block (scale=127,127)";
    a = 32'h0000_0000; b = 32'h0000_0000; c = 32'h0000_0000;
    sa = 8'd127; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b0);

    // ----------------------------------------------------------------------
    // Test 2 — Identity scale (127,127). Lane 0 = (1.0, 1.0)*(1.0, 1.0) = 2.0.
    //   FP4 0x2 = +1.0. Pack a=0x...00_22, b=0x...00_22.
    //   dot = 1*1 + 1*1 = 2.0; scale_factor = 2^0 = 1.
    //   Should match plain FMA — passes pre-Phase-D.
    // ----------------------------------------------------------------------
    test_name = "T2: lane0 (1,1)*(1,1) identity-scale";
    a = 32'h0000_0022; b = 32'h0000_0022; c = 32'h0000_0000;
    sa = 8'd127; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b0);

    // ----------------------------------------------------------------------
    // Test 3 — Identity scale, all 4 lanes active. Each lane sums 2.0,
    //   total = 8.0. Pre-Phase-D: passes.
    // ----------------------------------------------------------------------
    test_name = "T3: all-lanes (1,1)*(1,1) identity-scale";
    a = 32'h2222_2222; b = 32'h2222_2222; c = 32'h0000_0000;
    sa = 8'd127; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b0);

    // ----------------------------------------------------------------------
    // Test 4 — Identity scale, mixed-sign (1.5, -1.0)·(2.0, -1.0).
    //   FP4: 0x3=+1.5, 0xA=-1.0, 0x4=+2.0.
    //   Lane0: 1.5*2.0 + (-1.0)*(-1.0) = 3.0 + 1.0 = 4.0.
    //   Pre-Phase-D: passes.
    // ----------------------------------------------------------------------
    test_name = "T4: mixed-sign (1.5,-1)·(2,-1) identity-scale";
    a = 32'h0000_00A3; b = 32'h0000_00A4; c = 32'h0000_0000;
    sa = 8'd127; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b0);

    // ----------------------------------------------------------------------
    // Test 5 — Non-coincidental: (1.5, 0.5)·(3.0, 1.0) with addend.
    //   FP4: 0x3=+1.5, 0x1=+0.5 (subnorm), 0x5=+3.0, 0x2=+1.0.
    //   Lane0: 1.5*3.0 + 0.5*1.0 = 4.5 + 0.5 = 5.0.
    //   c = 1.0 (FP32) → result = 6.0. Identity scale. Pre-Phase-D: passes.
    // ----------------------------------------------------------------------
    test_name = "T5: non-coincidental (1.5,0.5)·(3,1)+1.0";
    a = 32'h0000_0013; b = 32'h0000_0025; c = 32'h3F80_0000; // 1.0
    sa = 8'd127; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b0);

    // ----------------------------------------------------------------------
    // Test 6 — Non-identity scale: (128, 128) → 2^(1+1)=4. Same operands as T2.
    //   Expected: 4 * 2.0 = 8.0. Pre-Phase-D: WILL FAIL (FMA ignores mx).
    // ----------------------------------------------------------------------
    test_name = "T6: lane0 (1,1)*(1,1) scale=(128,128) → 4× ";
    a = 32'h0000_0022; b = 32'h0000_0022; c = 32'h0000_0000;
    sa = 8'd128; sb = 8'd128;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b1);

    // ----------------------------------------------------------------------
    // Test 7 — Asymmetric scales: scale_a=130 (2^3=8), scale_b=125 (2^-2=0.25).
    //   Combined: 2^1 = 2. Same operands as T2, expect 2 * 2.0 = 4.0.
    //   Pre-Phase-D: WILL FAIL.
    // ----------------------------------------------------------------------
    test_name = "T7: asymmetric scale (130,125) → 2×";
    a = 32'h0000_0022; b = 32'h0000_0022; c = 32'h0000_0000;
    sa = 8'd130; sb = 8'd125;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b1);

    // ----------------------------------------------------------------------
    // Test 8 — Down-scale: scale=(125,125) → 2^(-2-2)=2^-4=0.0625.
    //   T3 dot=8.0, expect 0.5. Pre-Phase-D: WILL FAIL.
    // ----------------------------------------------------------------------
    test_name = "T8: down-scale (125,125) all-lanes → 0.5";
    a = 32'h2222_2222; b = 32'h2222_2222; c = 32'h0000_0000;
    sa = 8'd125; sb = 8'd125;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b1);

    // ----------------------------------------------------------------------
    // Test 9 — Single non-zero lane, scale=(128,127) → 2× of lane2.
    //   Lane2: (1.5, 1.0)·(2.0, 0.5) = 3.0 + 0.5 = 3.5. Expected 7.0.
    //   Pre-Phase-D: WILL FAIL.
    // ----------------------------------------------------------------------
    test_name = "T9: single-lane2, scale=(128,127) → 2×";
    a = 32'h0023_0000; b = 32'h0024_0000; c = 32'h0000_0000;
    // Wait — lane 2 is bits [19:16]+[23:20] in operands. So the bytes
    // need to be at byte positions 2 (=bits [23:16]). a[19:16]=0x3 (1.5),
    // a[23:20]=0x2 (1.0). b[19:16]=0x4 (2.0), b[23:20]=0x1 (0.5).
    a = 32'h0023_0000; b = 32'h0014_0000;
    sa = 8'd128; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b1);

    // ----------------------------------------------------------------------
    // Test 10 — With non-zero c addend: dot+c form.
    //   Same as T6 but c = 1.0 (FP32). Expected 4 * 2.0 + 1.0 = 9.0.
    //   Pre-Phase-D: WILL FAIL (different reason than addend; scale not applied).
    // ----------------------------------------------------------------------
    test_name = "T10: scale=(128,128) + c=1.0";
    a = 32'h0000_0022; b = 32'h0000_0022; c = 32'h3F80_0000; // 1.0
    sa = 8'd128; sb = 8'd128;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b1);

    // ----------------------------------------------------------------------
    // T11 — Reproduces the failing systolic PE(3,0) input from seed=7 GEMM:
    //   act=0x111994a2, wgt=0x41999199, c=0x40c80000 (=6.25), scales=(127,127).
    //   Expected: 8-elem dot = 2.5; 2.5 + 6.25 = 8.75 = 0x41080000.
    // ----------------------------------------------------------------------
    test_name = "T11: systolic PE(3,0) repro (dot=2.5, c=6.25 → 8.75)";
    a = 32'h1119_94a2; b = 32'h4199_9199; c = 32'h40c8_0000;
    sa = 8'd127; sb = 8'd127;
    gold = golden_mx_fp4_dp(a, b, c, sa, sb);
    issue_mx_fp4_dp(a, b, c, sa, sb);
    check_result(test_name, gold, 1'b0);

    // ----------------------------------------------------------------------
    repeat (10) @(posedge clk);
    $display("");
    $display("[TB_MX] ============ SUMMARY ============");
    $display("[TB_MX]   PASS:                  %0d", pass_count);
    $display("[TB_MX]   FAIL (real):           %0d", fail_count);
    $display("[TB_MX]   EXPECTED_FAIL_PRE_PHASE_D: %0d", expected_fail_count);
    $display("[TB_MX] =================================");
    if (fail_count != 0) begin
      $display("[TB_MX] OVERALL: REAL FAILURES — investigate");
    end else if (expected_fail_count == 0) begin
      $display("[TB_MX] OVERALL: ALL PASS (Phase D is in)");
    end else begin
      $display("[TB_MX] OVERALL: identity-scale tests PASS; non-identity tests pending Phase D");
    end
    $finish;
  end

  initial begin
    #50000;
    $display("[TB_MX] TIMEOUT");
    $finish;
  end

endmodule
