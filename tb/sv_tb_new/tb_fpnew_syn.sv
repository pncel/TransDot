// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps

module tb_fpnew_syn;
import fpnew_pkg::*;

localparam int WIDTH     = 32;
localparam int NUM_OPS   = 3;
localparam int NUM_TESTS = 1024;
localparam string input_dir = "../test_data_generate/generated/";
localparam real REL_ERR_THRESH = 1e-2;
localparam int  ULP_ERR_THRESH = 2;

// ----------------------------------------
// DUT signals
// ----------------------------------------
logic clk, rst_n;
logic [NUM_OPS-1:0][WIDTH-1:0] operands_i;
logic [31:0] operand_a_fp32;
logic [31:0] operand_b_fp32;
logic [31:0] operand_c_fp32;

assign operand_a_fp32 = operands_i[0][31:0];
assign operand_b_fp32 = operands_i[1][31:0];
assign operand_c_fp32 = operands_i[2][31:0];

logic [15:0] operand_a_fp16;
logic [15:0] operand_b_fp16;
logic [15:0] operand_c_fp16;
assign operand_a_fp16 = operands_i[0][15:0];
assign operand_b_fp16 = operands_i[1][15:0];
assign operand_c_fp16 = operands_i[2][15:0];

logic [7:0] operand_a_fp8;
logic [7:0] operand_b_fp8;
logic [7:0] operand_c_fp8;
assign operand_a_fp8 = operands_i[0][7:0];
assign operand_b_fp8 = operands_i[1][7:0];
assign operand_c_fp8 = operands_i[2][7:0];

roundmode_e rnd_mode_i;
operation_e op_i;
logic op_mod_i;
fp_format_e src_fmt_i, dst_fmt_i;
int_format_e int_fmt_i;
logic vectorial_op_i;
logic [WIDTH-1:0] result_o;
logic [7:0] results_fp8;
logic [15:0] results_fp16;
logic [31:0] results_fp32;

assign results_fp32 = result_o[31:0];
assign results_fp16 = result_o[15:0];
assign results_fp8  = result_o[7:0];

status_t status_o;
logic in_valid_i, in_ready_o;
logic flush_i;
logic out_valid_o, out_ready_i;
logic busy_o;
logic tag_i, tag_o;
localparam int NumLanes = 1;
logic [NumLanes-1:0] simd_mask_i;
bit verbose;

// ----------------------------------------
// Clock and Reset
// ----------------------------------------
initial clk = 0;
always #5 clk = ~clk;

task automatic reset_dut();
rst_n = 0;
in_valid_i = 0;
flush_i = 0;
out_ready_i = 1;
simd_mask_i = '1;
repeat (10) @(posedge clk);
rst_n = 1;
repeat (5) @(posedge clk);
endtask

// ----------------------------------------
// DUT instantiation
// ----------------------------------------
transdot_fpu_top dut (
.clk_i(clk),
.rst_ni(rst_n),
.\operands_i[0] (operands_i[0]),
.\operands_i[1] (operands_i[1]),
.\operands_i[2] (operands_i[2]),
.rnd_mode_i,
.op_i,
.op_mod_i,
.src_fmt_i,
.dst_fmt_i,
.int_fmt_i,
.vectorial_op_i,
.simd_mask_i,
.tag_i,
.in_valid_i,
.in_ready_o,
.flush_i,
.result_o,
.\status_o[NX] (status_o.NX),
.\status_o[UF] (status_o.UF),
.\status_o[OF] (status_o.OF),
.\status_o[DZ] (status_o.DZ),
.\status_o[NV] (status_o.NV),
.tag_o,
.out_valid_o,
.out_ready_i,
.busy_o
);

// ----------------------------------------
// Helper functions
// ----------------------------------------
// Simple 2^exp helper for real exponents (integer exp)
function automatic real pow2(input int exp);
  real result = 1.0;
  if (exp > 0) begin
    for (int i = 0; i < exp; i++) result *= 2.0;
  end else if (exp < 0) begin
    for (int i = 0; i < -exp; i++) result /= 2.0;
  end
  return result;
endfunction

// Convert "0101..." token to a 32-bit value (supports 8/16/32 bits).
function automatic logic [31:0] parse_bin_token(string tok);
  int ok;
  int unsigned tmp;
  ok = $sscanf(tok, "%b", tmp);
  if (ok != 1) $fatal(1, "[TB] Failed to parse binary token: '%s'", tok);
  return logic'(tmp[31:0]);
endfunction

// NaN-box per format. For FP16 -> {16'hFFFF, half}; FP8 -> {24'hFFFFFF, byte}.
function automatic logic [31:0] box_bits(logic [31:0] raw, fp_format_e fmt);
  case (fmt)
    FP32   : return raw;
    FP16,
    FP16ALT: return {16'hFFFF, raw[15:0]};
    FP8    : return {24'hFFFFFF, raw[7:0]};
    default: return raw;
  endcase
endfunction

// Unbox (strip NaN-box) for printing/ULP compute.
function automatic logic [31:0] unbox_bits(logic [31:0] boxed, fp_format_e fmt);
  case (fmt)
    FP32   : return boxed;
    FP16,
    FP16ALT: return {16'b0, boxed[15:0]}; // keep in LSBs
    FP8    : return {24'b0, boxed[7:0]};
    default: return boxed;
  endcase
endfunction

function automatic operation_e decode_op_id(input int unsigned op_id, input operation_e fallback_op);
  case (op_id)
    0 : return fpnew_pkg::ADD;
    1 : return fpnew_pkg::MUL;
    2 : return fpnew_pkg::FMADD;
    16: return fpnew_pkg::TDOT_SIMD_FMADD;
    17: return fpnew_pkg::TDOT_DP_FMADD;
    18: return fpnew_pkg::TDOT_FP4_DP_FMADD;
    default: return fallback_op;
  endcase
endfunction

function automatic int ulp_diff(logic [31:0] a_bits, logic [31:0] b_bits);
int ai, bi;
ai = a_bits;
bi = b_bits;
if (ai < 0) ai = 32'h8000_0000 - ai;
if (bi < 0) bi = 32'h8000_0000 - bi;
return (ai > bi) ? (ai - bi) : (bi - ai);
endfunction

// Minimal numeric decode for printing (not bit-exact rounding).
function automatic real bits_to_real(input fp_format_e fmt, input logic [31:0] boxed_bits);
  logic [31:0] raw = unbox_bits(boxed_bits, fmt);

  if (fmt == FP32) begin
    return $bitstoshortreal(raw);
  end
  else if (fmt == FP16 || fmt == FP16ALT) begin
    // Decode IEEE-754 binary16 (e5m10)
    logic        s = raw[15];
    logic [4:0]  e = raw[14:10];
    logic [9:0]  m = raw[9:0];
    real sign = s ? -1.0 : 1.0;
    if (e == 5'b11111) begin
      if (m == 0) return sign * (1.0/0.0); // inf
      else        return 0.0/0.0;          // NaN
    end else if (e == 5'b00000) begin
      if (m == 0) return sign * 0.0;       // zero
      else        return sign * (m / 1024.0) * pow2(-14.0);
    end else begin
      return sign * (1.0 + m / 1024.0) * pow2((int'(e) - 15));
    end
  end
  else if (src_fmt_i == FP8) begin
    // Decode a simple FP8 e4m3 (no subnormal handling nuance)
    logic        s = raw[7];
    logic [3:0]  e = raw[6:3];
    logic [2:0]  m = raw[2:0];
    real sign = s ? -1.0 : 1.0;
    if (e == 4'b1111) begin
      if (m == 0) return sign * (1.0/0.0); // inf
      else        return 0.0/0.0;          // NaN
    end else if (e == 4'b0000) begin
      if (m == 0) return sign * 0.0;
      else        return sign * (m / 8.0) * pow2(-6.0);
    end else begin
      return sign * (1.0 + m / 8.0) * pow2( (int'(e) - 7));
    end
  end

  return 0.0;
endfunction

function automatic real fp4_nibble_to_real(input logic [3:0] raw);
  logic        s = raw[3];
  logic [1:0]  e = raw[2:1];
  logic        m = raw[0];
  real sign = s ? -1.0 : 1.0;
  if (e == 2'b00) begin
    if (m == 1'b0) return sign * 0.0;
    else           return sign * 0.5;
  end else if (e == 2'b11) begin
    return sign * (1.0/0.0);
  end else begin
    return sign * (1.0 + m / 2.0) * pow2((int'(e) - 1));
  end
endfunction

typedef struct packed {
logic [31:0] a, b, c;
int unsigned op;
} test_vec_t;

test_vec_t test_vectors   [NUM_TESTS];
logic [31:0] golden_output[NUM_TESTS];

int pass_fp32, total_fp32;
int pass_fp16, total_fp16;
int pass_fp8, total_fp8;
int pass_simd_fp16, total_simd_fp16;
int pass_simd_fp8, total_simd_fp8;
int pass_dp_fp16, total_dp_fp16;
int pass_dp_fp8, total_dp_fp8;
int pass_dp_fp4, total_dp_fp4;
int pass_status_directed, total_status_directed;

initial begin
  verbose = $test$plusargs("VERBOSE");
end

// ----------------------------------------
// Read test data (.txt with %b)
// ----------------------------------------
task automatic read_test_data(string prefix, output int num_loaded);
string input_txt, golden_txt;
int f_in, f_gold, rc;
input_txt  = {input_dir, prefix, "_input.txt"};
golden_txt = {input_dir, prefix, "_golden_output.txt"};


f_in   = $fopen(input_txt,  "r");
f_gold = $fopen(golden_txt, "r");
if (!f_in || !f_gold)
  $fatal("Failed to open text files for %s", prefix);

num_loaded = 0;
while ((num_loaded < NUM_TESTS) && !$feof(f_in) && !$feof(f_gold)) begin
  rc = $fscanf(f_in, "%b %b %b %d\n",
               test_vectors[num_loaded].a,
               test_vectors[num_loaded].b,
               test_vectors[num_loaded].c,
               test_vectors[num_loaded].op);
  rc += $fscanf(f_gold, "%b\n", golden_output[num_loaded]);
  if (rc == 5) num_loaded++;
  else break;
end
$fclose(f_in);
$fclose(f_gold);
$display("[TB] Loaded %0d text vectors for %s", num_loaded, prefix);
if (num_loaded == 0) begin
  $fatal(1, "[TB] No vectors loaded for %s", prefix);
end


endtask

task automatic print_summary();
  int total_tests;
  int total_pass;
  int total_fail;

  total_tests = total_fp32 + total_fp16 + total_fp8 +
                total_simd_fp16 + total_simd_fp8 +
                total_dp_fp16 + total_dp_fp8 + total_dp_fp4 +
                total_status_directed;
  total_pass  = pass_fp32 + pass_fp16 + pass_fp8 +
                pass_simd_fp16 + pass_simd_fp8 +
                pass_dp_fp16 + pass_dp_fp8 + pass_dp_fp4 +
                pass_status_directed;
  total_fail  = total_tests - total_pass;

  $display("\n[SUMMARY]");
  if (total_fp32 > 0) $display("  fp32           : %0d / %0d passed", pass_fp32, total_fp32);
  if (total_fp16 > 0) $display("  fp16           : %0d / %0d passed", pass_fp16, total_fp16);
  if (total_fp8  > 0) $display("  fp8            : %0d / %0d passed", pass_fp8,  total_fp8);
  if (total_simd_fp16 > 0) $display("  fp16_simd_fp16 : %0d / %0d passed", pass_simd_fp16, total_simd_fp16);
  if (total_simd_fp8  > 0) $display("  fp8_simd_fp8   : %0d / %0d passed", pass_simd_fp8,  total_simd_fp8);
  if (total_dp_fp16 > 0) $display("  fp16_fp32_dp   : %0d / %0d passed", pass_dp_fp16, total_dp_fp16);
  if (total_dp_fp8  > 0) $display("  fp8_fp32_dp    : %0d / %0d passed", pass_dp_fp8,  total_dp_fp8);
  if (total_dp_fp4  > 0) $display("  fp4_fp32_dp    : %0d / %0d passed", pass_dp_fp4,  total_dp_fp4);
  if (total_status_directed > 0) $display("  status_directed: %0d / %0d passed", pass_status_directed, total_status_directed);

  if (total_fail == 0) begin
    $display("      ");
    $display("      ");
    $display("########     ###      ######    ######     ##   ##   ##");
    $display("##     ##   ## ##    ##    ##  ##    ##    ##   ##   ##");
    $display("##     ##  ##   ##   ##        ##          ##   ##   ##");
    $display("########  ##     ##   ######    ######     ##   ##   ##");
    $display("##        #########        ##        ##    ##   ##   ##");
    $display("##        ##     ##  ##    ##  ##    ##                ");
    $display("##        ##     ##   ######    ######     ##   ##   ##");
    $display("      ");
    $display("      ");
  end else begin
    $display("      ");
    $display("      ");
    $display("########    ###       ####    ##          ##   ##   ##");
    $display("##         ## ##       ##     ##          ##   ##   ##");
    $display("##        ##   ##      ##     ##          ##   ##   ##");
    $display("######   ##     ##     ##     ##          ##   ##   ##");
    $display("##       #########     ##     ##          ##   ##   ##");
    $display("##       ##     ##     ##     ##                      ");
    $display("##       ##     ##    ####    ########    ##   ##   ##");
    $display("      ");
    $display("      ");
  end
endtask

function automatic int total_tests_count();
  total_tests_count = total_fp32 + total_fp16 + total_fp8 +
                      total_simd_fp16 + total_simd_fp8 +
                      total_dp_fp16 + total_dp_fp8 + total_dp_fp4 +
                      total_status_directed;
endfunction

function automatic int total_pass_count();
  total_pass_count = pass_fp32 + pass_fp16 + pass_fp8 +
                     pass_simd_fp16 + pass_simd_fp8 +
                     pass_dp_fp16 + pass_dp_fp8 + pass_dp_fp4 +
                     pass_status_directed;
endfunction

function automatic int total_fail_count();
  total_fail_count = total_tests_count() - total_pass_count();
endfunction

// ----------------------------------------
// Run one format
// ----------------------------------------
task automatic run_format(fp_format_e fmt, string prefix);
int ntests;
int pass_count = 0;
real hw, gold, diff;
int ulp;


read_test_data(prefix, ntests);

src_fmt_i = fmt;
dst_fmt_i = fmt;
rnd_mode_i = RNE;
vectorial_op_i = 0;
int_fmt_i = INT32;
op_mod_i = 0;

for (int i = 0; i < ntests; i++) begin
  operands_i[0] = test_vectors[i].a;
  operands_i[1] = test_vectors[i].b;
  operands_i[2] = test_vectors[i].c;

  op_i = decode_op_id(test_vectors[i].op, fpnew_pkg::FMADD);

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  hw   = bits_to_real(fmt, result_o);
  gold = bits_to_real(fmt,golden_output[i]);
  ulp  = ulp_diff(result_o, golden_output[i]);
  diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

  if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
    pass_count++;
    if (verbose)
      $display("[PASS] %s op=%0d A=%e B=%e C=%e -> HW=%e SW=%e (diff=%e, ULP=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(fmt, test_vectors[i].a),
               bits_to_real(fmt, test_vectors[i].b),
               bits_to_real(fmt, test_vectors[i].c),
               hw, gold, diff, ulp);
  end else begin
    $error("[FAIL] %s op=%0d A=%e B=%e C=%e -> HW=%e SW=%e (diff=%e, ULP=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(fmt, test_vectors[i].a),
           bits_to_real(fmt, test_vectors[i].b),
           bits_to_real(fmt, test_vectors[i].c),
           hw, gold, diff, ulp);
  end
end

$display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);

if (prefix == "fp32") begin
  pass_fp32 = pass_count;
  total_fp32 = ntests;
end else if (prefix == "fp16") begin
  pass_fp16 = pass_count;
  total_fp16 = ntests;
end else if (prefix == "fp8") begin
  pass_fp8 = pass_count;
  total_fp8 = ntests;
end


endtask


// ----------------------------------------
// Run one format
// ----------------------------------------
task automatic run_simd_fp16(fp_format_e fmt, string prefix);
int ntests;
int pass_count = 0;
real hw0, gold0, diff0;
real hw1, gold1, diff1;
int ulp1;
int ulp0;
bit pass_low;


read_test_data(prefix, ntests);

src_fmt_i = fmt;
dst_fmt_i = fmt;
rnd_mode_i = RNE;
vectorial_op_i = 0;
int_fmt_i = INT32;
op_mod_i = 0;
for (int i = 0; i < ntests; i++) begin
  operands_i[0] = test_vectors[i].a;
  operands_i[1] = test_vectors[i].b;
  operands_i[2] = test_vectors[i].c;

  op_i = (test_vectors[i].op == 2)
      ? fpnew_pkg::TDOT_SIMD_FMADD
      : decode_op_id(test_vectors[i].op, fpnew_pkg::TDOT_SIMD_FMADD);

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  hw0   = bits_to_real(fmt, result_o[15:0]);
  gold0 = bits_to_real(fmt, golden_output[i][15:0]);
  ulp0  = ulp_diff(result_o[15:0], golden_output[i][15:0]);
  diff0 = (gold0 == 0) ? $abs(hw0) : $abs((hw0 - gold0) / gold0);

  hw1   = bits_to_real(fmt, result_o[31:16]);
  gold1 = bits_to_real(fmt, golden_output[i][31:16]);
  ulp1  = ulp_diff(result_o[31:16], golden_output[i][31:16]);
  diff1 = (gold1 == 0) ? $abs(hw1) : $abs((hw1 - gold1) / gold1);
  pass_low = 0;
  if ((diff0 < REL_ERR_THRESH) || ($abs(ulp0) < ULP_ERR_THRESH)) begin
    pass_low = 1;
    if (verbose)
      $display("[PASS lane0] %s op=%0d A0=%e B0=%e C0=%e -> HW0=%e SW0=%e (diff0=%e, ULP0=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP16,test_vectors[i].a[15:0]),
               bits_to_real(FP16,test_vectors[i].b[15:0]),
               bits_to_real(FP16, test_vectors[i].c[15:0]),
               hw0, gold0, diff0, ulp0);
  end else begin
    pass_low = 0;
    $error("[FAIL lane0] %s op=%0d A0=%e B0=%e C0=%e -> HW0=%e SW0=%e (diff0=%e, ULP0=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP16,test_vectors[i].a[15:0]),
           bits_to_real(FP16,test_vectors[i].b[15:0]),
           bits_to_real(FP16, test_vectors[i].c[15:0]),
           hw0, gold0, diff0, ulp0);
  end

  if ((diff1 < REL_ERR_THRESH) || ($abs(ulp1) < ULP_ERR_THRESH)) begin
    if(pass_low) pass_count++;
    if (verbose)
      $display("[PASS lane1] %s op=%0d A1=%e B1=%e C1=%e -> HW1=%e SW1=%e (diff1=%e, ULP1=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP16,test_vectors[i].a[31:16]),
               bits_to_real(FP16,test_vectors[i].b[31:16]),
               bits_to_real(FP16, test_vectors[i].c[31:16]),
               hw1, gold1, diff1, ulp1);
  end else begin
    $error("[FAIL lane1] %s op=%0d A1=%e B1=%e C1=%e -> HW1=%e SW1=%e (diff1=%e, ULP1=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP16,test_vectors[i].a[31:16]),
           bits_to_real(FP16,test_vectors[i].b[31:16]),
           bits_to_real(FP16, test_vectors[i].c[31:16]),
           hw1, gold1, diff1, ulp1);
  end
end

$display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);

pass_simd_fp16 = pass_count;
total_simd_fp16 = ntests;


endtask

task automatic run_simd_fp8(fp_format_e fmt, string prefix);
int ntests;
int pass_count = 0;
real hw0, gold0, diff0;
real hw1, gold1, diff1;
real hw2, gold2, diff2;
real hw3, gold3, diff3;
int ulp3;
int ulp2;
int ulp1;
int ulp0;
bit pass_low;


read_test_data(prefix, ntests);

src_fmt_i = fmt;
dst_fmt_i = fmt;
rnd_mode_i = RNE;
vectorial_op_i = 0;
int_fmt_i = INT32;
op_mod_i = 0;
for (int i = 0; i < ntests; i++) begin
  operands_i[0] = test_vectors[i].a;
  operands_i[1] = test_vectors[i].b;
  operands_i[2] = test_vectors[i].c;

  op_i = (test_vectors[i].op == 2)
      ? fpnew_pkg::TDOT_SIMD_FMADD
      : decode_op_id(test_vectors[i].op, fpnew_pkg::TDOT_SIMD_FMADD);

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  hw0   = bits_to_real(fmt, result_o[7:0]);
  gold0 = bits_to_real(fmt, golden_output[i][7:0]);
  ulp0  = ulp_diff(result_o[7:0], golden_output[i][7:0]);
  diff0 = (gold0 == 0) ? $abs(hw0) : $abs((hw0 - gold0) / gold0);

  hw1   = bits_to_real(fmt, result_o[15:8]);
  gold1 = bits_to_real(fmt, golden_output[i][15:8]);
  ulp1  = ulp_diff(result_o[15:8], golden_output[i][15:8]);
  diff1 = (gold1 == 0) ? $abs(hw1) : $abs((hw1 - gold1) / gold1);

  hw2   = bits_to_real(fmt, result_o[23:16]);
  gold2 = bits_to_real(fmt, golden_output[i][23:16]);
  ulp2  = ulp_diff(result_o[23:16], golden_output[i][23:16]);
  diff2 = (gold2 == 0) ? $abs(hw2) : $abs((hw2 - gold2) / gold2);

  hw3   = bits_to_real(fmt, result_o[31:24]);
  gold3 = bits_to_real(fmt, golden_output[i][31:24]);
  ulp3  = ulp_diff(result_o[31:24], golden_output[i][31:24]);
  diff3 = (gold3 == 0) ? $abs(hw3) : $abs((hw3 - gold3) / gold3);

  pass_low = 1;
  if ((diff0 < REL_ERR_THRESH) || ($abs(ulp0) < ULP_ERR_THRESH)) begin
    if (verbose)
      $display("[PASS lane0] %s op=%0d A0=%e B0=%e C0=%e -> HW0=%e SW0=%e (diff0=%e, ULP0=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP8,test_vectors[i].a[7:0]),
               bits_to_real(FP8,test_vectors[i].b[7:0]),
               bits_to_real(FP8, test_vectors[i].c[7:0]),
               hw0, gold0, diff0, ulp0);
  end else begin
    pass_low = 0;
    $error("[FAIL lane0] %s op=%0d A0=%e B0=%e C0=%e -> HW0=%e SW0=%e (diff0=%e, ULP0=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP8,test_vectors[i].a[7:0]),
           bits_to_real(FP8,test_vectors[i].b[7:0]),
           bits_to_real(FP8, test_vectors[i].c[7:0]),
           hw0, gold0, diff0, ulp0);
  end

  if ((diff1 < REL_ERR_THRESH) || ($abs(ulp1) < ULP_ERR_THRESH)) begin
    //if(pass_low) pass_count++;
    if (verbose)
      $display("[PASS lane1] %s op=%0d A1=%e B1=%e C1=%e -> HW1=%e SW1=%e (diff1=%e, ULP1=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP8,test_vectors[i].a[15:8]),
               bits_to_real(FP8,test_vectors[i].b[15:8]),
               bits_to_real(FP8, test_vectors[i].c[15:8]),
               hw1, gold1, diff1, ulp1);
  end else begin
    pass_low = 0;
    $error("[FAIL lane1] %s op=%0d A1=%e B1=%e C1=%e -> HW1=%e SW1=%e (diff1=%e, ULP1=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP8,test_vectors[i].a[15:8]),
           bits_to_real(FP8,test_vectors[i].b[15:8]),
           bits_to_real(FP8, test_vectors[i].c[15:8]),
           hw1, gold1, diff1, ulp1);
  end

  if ((diff2 < REL_ERR_THRESH) || ($abs(ulp2) < ULP_ERR_THRESH)) begin
    //if(pass_low) pass_count++;
    if (verbose)
      $display("[PASS lane2] %s op=%0d A2=%e B2=%e C2=%e -> HW2=%e SW2=%e (diff2=%e, ULP2=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP8,test_vectors[i].a[23:16]),
               bits_to_real(FP8,test_vectors[i].b[23:16]),
               bits_to_real(FP8, test_vectors[i].c[23:16]),
               hw2, gold2, diff2, ulp2);
  end else begin
    pass_low = 0;
    $error("[FAIL lane2] %s op=%0d A2=%e B2=%e C2=%e -> HW2=%e SW2=%e (diff2=%e, ULP2=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP8,test_vectors[i].a[23:16]),
           bits_to_real(FP8,test_vectors[i].b[23:16]),
           bits_to_real(FP8, test_vectors[i].c[23:16]),
           hw2, gold2, diff2, ulp2);
  end

  if ((diff3 < REL_ERR_THRESH) || ($abs(ulp3) < ULP_ERR_THRESH)) begin
    if(pass_low) pass_count++;
    if (verbose)
      $display("[PASS lane3] %s op=%0d A3=%e B3=%e C3=%e -> HW3=%e SW3=%e (diff3=%e, ULP3=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP8,test_vectors[i].a[31:24]),
               bits_to_real(FP8,test_vectors[i].b[31:24]),
               bits_to_real(FP8, test_vectors[i].c[31:24]),
               hw3, gold3, diff3, ulp3);
  end else begin
    //pass_low = 0;
    $error("[FAIL lane3] %s op=%0d A3=%e B3=%e C3=%e -> HW3=%e SW3=%e (diff3=%e, ULP3=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP8,test_vectors[i].a[31:24]),
           bits_to_real(FP8,test_vectors[i].b[31:24]),
           bits_to_real(FP8, test_vectors[i].c[31:24]),
           hw3, gold3, diff3, ulp3);
  end
end

$display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);

pass_simd_fp8 = pass_count;
total_simd_fp8 = ntests;


endtask

// ----------------------------------------
// Run one format
// ----------------------------------------
task automatic run_dp(fp_format_e fmt, string prefix);
int ntests;
int pass_count = 0;
real hw, gold, diff;
int ulp;


read_test_data(prefix, ntests);

src_fmt_i = fmt;
dst_fmt_i = FP32;
rnd_mode_i = RNE;
vectorial_op_i = 0;
int_fmt_i = INT32;
op_mod_i = 0;
for (int i = 0; i < ntests; i++) begin
  operands_i[0] = test_vectors[i].a;
  operands_i[1] = test_vectors[i].b;
  operands_i[2] = test_vectors[i].c;

  op_i = (test_vectors[i].op == 2)
      ? fpnew_pkg::TDOT_DP_FMADD
      : decode_op_id(test_vectors[i].op, fpnew_pkg::TDOT_DP_FMADD);

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  hw   = bits_to_real(FP32, result_o);
  gold = bits_to_real(FP32, golden_output[i]);
  ulp  = ulp_diff(result_o, golden_output[i]);
  diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

  if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
    pass_count++;
    if (verbose)
      $display("[PASS] %s op=%0d A0=%e B0=%e A1=%e B1=%e C=%e -> HW=%e SW=%e (diff=%e, ULP=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP16,test_vectors[i].a[15:0]),
               bits_to_real(FP16,test_vectors[i].b[15:0]),
               bits_to_real(FP16,test_vectors[i].a[31:16]),
               bits_to_real(FP16,test_vectors[i].b[31:16]),
               bits_to_real(FP32, test_vectors[i].c),
               hw, gold, diff, ulp);
  end else begin
    $error("[FAIL] %s op=%0d A0=%e B0=%e A1=%e B1=%e C=%e -> HW=%e SW=%e (diff=%e, ULP=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP16,test_vectors[i].a[15:0]),
           bits_to_real(FP16,test_vectors[i].b[15:0]),
           bits_to_real(FP16,test_vectors[i].a[31:16]),
           bits_to_real(FP16,test_vectors[i].b[31:16]),
           bits_to_real(FP32, test_vectors[i].c),
           hw, gold, diff, ulp);
  end
end

$display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);

pass_dp_fp16 = pass_count;
total_dp_fp16 = ntests;


endtask

task automatic run_dp_fp8(fp_format_e fmt, string prefix);
int ntests;
int pass_count = 0;
real hw, gold, diff;
int ulp;


read_test_data(prefix, ntests);

src_fmt_i = fmt;
dst_fmt_i = FP32;
rnd_mode_i = RNE;
vectorial_op_i = 0;
int_fmt_i = INT32;
op_mod_i = 0;
for (int i = 0; i < ntests; i++) begin
  operands_i[0] = test_vectors[i].a;
  operands_i[1] = test_vectors[i].b;
  operands_i[2] = test_vectors[i].c;

  op_i = (test_vectors[i].op == 2)
      ? fpnew_pkg::TDOT_DP_FMADD
      : decode_op_id(test_vectors[i].op, fpnew_pkg::TDOT_DP_FMADD);

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  hw   = bits_to_real(FP32, result_o);
  gold = bits_to_real(FP32, golden_output[i]);
  ulp  = ulp_diff(result_o, golden_output[i]);
  diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

  if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
    pass_count++;
    if (verbose)
      $display("[PASS] %s op=%0d A0=%e B0=%e A1=%e B1=%e A2=%e B2=%e A3=%e B3=%e C=%e -> HW=%e SW=%e (diff=%e, ULP=%0d)",
               prefix, test_vectors[i].op,
               bits_to_real(FP8,test_vectors[i].a[7:0]),
               bits_to_real(FP8,test_vectors[i].b[7:0]),
               bits_to_real(FP8,test_vectors[i].a[15:8]),
               bits_to_real(FP8,test_vectors[i].b[15:8]),
               bits_to_real(FP8,test_vectors[i].a[23:16]),
               bits_to_real(FP8,test_vectors[i].b[23:16]),
               bits_to_real(FP8,test_vectors[i].a[31:24]),
               bits_to_real(FP8,test_vectors[i].b[31:24]),
               bits_to_real(FP32, test_vectors[i].c),
               hw, gold, diff, ulp);
  end else begin
    $error("[FAIL] %s op=%0d A0=%e B0=%e A1=%e B1=%e A2=%e B2=%e A3=%e B3=%e C=%e -> HW=%e SW=%e (diff=%e, ULP=%0d)",
           prefix, test_vectors[i].op,
           bits_to_real(FP8,test_vectors[i].a[7:0]),
           bits_to_real(FP8,test_vectors[i].b[7:0]),
           bits_to_real(FP8,test_vectors[i].a[15:8]),
           bits_to_real(FP8,test_vectors[i].b[15:8]),
           bits_to_real(FP8,test_vectors[i].a[23:16]),
           bits_to_real(FP8,test_vectors[i].b[23:16]),
           bits_to_real(FP8,test_vectors[i].a[31:24]),
           bits_to_real(FP8,test_vectors[i].b[31:24]),
           bits_to_real(FP32, test_vectors[i].c),
           hw, gold, diff, ulp);
  end
end

$display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);

pass_dp_fp8 = pass_count;
total_dp_fp8 = ntests;


endtask

task automatic run_dp_fp4(fp_format_e fmt, string prefix);
int ntests;
int pass_count = 0;
real hw, gold, diff;
int ulp;

read_test_data(prefix, ntests);

src_fmt_i = FP4;
dst_fmt_i = FP32;
rnd_mode_i = RNE;
vectorial_op_i = 0;
int_fmt_i = INT32;
op_mod_i = 0;
for (int i = 0; i < ntests; i++) begin
  operands_i[0] = test_vectors[i].a;
  operands_i[1] = test_vectors[i].b;
  operands_i[2] = test_vectors[i].c;

  op_i = (test_vectors[i].op == 2)
      ? fpnew_pkg::TDOT_FP4_DP_FMADD
      : decode_op_id(test_vectors[i].op, fpnew_pkg::TDOT_FP4_DP_FMADD);

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  hw   = bits_to_real(FP32, result_o);
  gold = bits_to_real(FP32, golden_output[i]);
  ulp  = ulp_diff(result_o, golden_output[i]);
  diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

  if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
    pass_count++;
    if (verbose)
      $display("[PASS] %s op=%0d A0=%e B0=%e A1=%e B1=%e A2=%e B2=%e A3=%e B3=%e \n A4=%e B4=%e A5=%e B5=%e A6=%e B6=%e A7=%e B7=%e \n C=%e  \n -> HW=%e SW=%e (diff=%e, ULP=%0d)",
               prefix, test_vectors[i].op,
               fp4_nibble_to_real(test_vectors[i].a[3:0]),
               fp4_nibble_to_real(test_vectors[i].b[3:0]),
               fp4_nibble_to_real(test_vectors[i].a[7:4]),
               fp4_nibble_to_real(test_vectors[i].b[7:4]),
               fp4_nibble_to_real(test_vectors[i].a[11:8]),
               fp4_nibble_to_real(test_vectors[i].b[11:8]),
               fp4_nibble_to_real(test_vectors[i].a[15:12]),
               fp4_nibble_to_real(test_vectors[i].b[15:12]),
               fp4_nibble_to_real(test_vectors[i].a[19:16]),
               fp4_nibble_to_real(test_vectors[i].b[19:16]),
               fp4_nibble_to_real(test_vectors[i].a[23:20]),
               fp4_nibble_to_real(test_vectors[i].b[23:20]),
               fp4_nibble_to_real(test_vectors[i].a[27:24]),
               fp4_nibble_to_real(test_vectors[i].b[27:24]),
               fp4_nibble_to_real(test_vectors[i].a[31:28]),
               fp4_nibble_to_real(test_vectors[i].b[31:28]),
               bits_to_real(FP32, test_vectors[i].c),
               hw, gold, diff, ulp);
  end else begin
    $error("[FAIL] %s op=%0d A0=%e B0=%e A1=%e B1=%e A2=%e B2=%e A3=%e B3=%e \n A4=%e B4=%e A5=%e B5=%e A6=%e B6=%e A7=%e B7=%e \n C=%e  \n -> HW=%e SW=%e (diff=%e, ULP=%0d)",
           prefix, test_vectors[i].op,
           fp4_nibble_to_real(test_vectors[i].a[3:0]),
           fp4_nibble_to_real(test_vectors[i].b[3:0]),
           fp4_nibble_to_real(test_vectors[i].a[7:4]),
           fp4_nibble_to_real(test_vectors[i].b[7:4]),
           fp4_nibble_to_real(test_vectors[i].a[11:8]),
           fp4_nibble_to_real(test_vectors[i].b[11:8]),
           fp4_nibble_to_real(test_vectors[i].a[15:12]),
           fp4_nibble_to_real(test_vectors[i].b[15:12]),
           fp4_nibble_to_real(test_vectors[i].a[19:16]),
           fp4_nibble_to_real(test_vectors[i].b[19:16]),
           fp4_nibble_to_real(test_vectors[i].a[23:20]),
           fp4_nibble_to_real(test_vectors[i].b[23:20]),
           fp4_nibble_to_real(test_vectors[i].a[27:24]),
           fp4_nibble_to_real(test_vectors[i].b[27:24]),
           fp4_nibble_to_real(test_vectors[i].a[31:28]),
           fp4_nibble_to_real(test_vectors[i].b[31:28]),
           bits_to_real(FP32, test_vectors[i].c),
           hw, gold, diff, ulp);
  end
end

$display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);

pass_dp_fp4 = pass_count;
total_dp_fp4 = ntests;

endtask

task automatic issue_and_check_status(
  input string test_name,
  input operation_e op_sel,
  input fp_format_e src_fmt_sel,
  input fp_format_e dst_fmt_sel,
  input logic [31:0] op_a,
  input logic [31:0] op_b,
  input logic [31:0] op_c,
  input logic [NumLanes-1:0] lane_mask,
  input status_t expected_status,
  input status_t check_mask
);
status_t masked_diff;

  src_fmt_i = src_fmt_sel;
  dst_fmt_i = dst_fmt_sel;
  rnd_mode_i = RNE;
  vectorial_op_i = 0;
  int_fmt_i = INT32;
  op_mod_i = 0;
  op_i = op_sel;
  operands_i[0] = op_a;
  operands_i[1] = op_b;
  operands_i[2] = op_c;
  simd_mask_i = lane_mask;

  in_valid_i = 1;
  @(posedge clk);
  while (!in_ready_o) @(posedge clk);
  in_valid_i = 0;

  wait(out_valid_o);
  @(posedge clk);

  masked_diff = (status_o ^ expected_status) & check_mask;
  total_status_directed++;
  if (masked_diff == '0) begin
    pass_status_directed++;
    if (verbose)
      $display("[PASS][STATUS] %s op=%0d src=%0d dst=%0d mask=%b status=%b",
               test_name, op_sel, src_fmt_sel, dst_fmt_sel, lane_mask, status_o);
  end else begin
    $error("[FAIL][STATUS] %s op=%0d src=%0d dst=%0d mask=%b status=%b expected=%b check_mask=%b diff=%b",
           test_name, op_sel, src_fmt_sel, dst_fmt_sel, lane_mask,
           status_o, expected_status, check_mask, masked_diff);
  end

  simd_mask_i = '1;
endtask

task automatic run_status_directed();
status_t expected_status;
status_t check_mask;

  expected_status = '0;
  check_mask = '0;
  expected_status.NV = 1'b1;
  check_mask.NV = 1'b1;
  issue_and_check_status("scalar_fp32_invalid_nv",
                         fpnew_pkg::FMADD, FP32, FP32,
                         32'h7F80_0000, 32'h0000_0000, 32'h0000_0000,
                         {NumLanes{1'b1}},
                         expected_status, check_mask);

  expected_status = '0;
  check_mask = '0;
  expected_status.NV = 1'b1;
  check_mask.NV = 1'b1;
  issue_and_check_status("simd_fp16_lane_or_nv",
                         fpnew_pkg::TDOT_SIMD_FMADD, FP16, FP16,
                         {16'h7C00, 16'h3C00}, {16'h0000, 16'h3C00}, 32'h0000_0000,
                         {NumLanes{1'b1}},
                         expected_status, check_mask);

  expected_status = '0;
  check_mask = '1;
  issue_and_check_status("simd_fp16_masked_status_zero",
                         fpnew_pkg::TDOT_SIMD_FMADD, FP16, FP16,
                         {16'h7C00, 16'h3C00}, {16'h0000, 16'h3C00}, 32'h0000_0000,
                         {NumLanes{1'b0}},
                         expected_status, check_mask);

  expected_status = '0;
  check_mask = '0;
  expected_status.NV = 1'b1;
  check_mask.NV = 1'b1;
  issue_and_check_status("dp_fp16_invalid_nv",
                         fpnew_pkg::TDOT_DP_FMADD, FP16, FP32,
                         {16'h3C00, 16'h7C00}, {16'h3C00, 16'h0000}, 32'h0000_0000,
                         {NumLanes{1'b1}},
                         expected_status, check_mask);

  expected_status = '0;
  check_mask = '1;
  issue_and_check_status("fp4_dp_clean_status_zero",
                         fpnew_pkg::TDOT_FP4_DP_FMADD, FP4, FP32,
                         32'h0000_0002, 32'h0000_0002, 32'h0000_0000,
                         {NumLanes{1'b1}},
                         expected_status, check_mask);

  expected_status = '0;
  check_mask = '1;
  issue_and_check_status("fp4_dp_masked_status_zero",
                         fpnew_pkg::TDOT_FP4_DP_FMADD, FP4, FP32,
                         32'h0000_0006, 32'h0000_0000, 32'h0000_0000,
                         {NumLanes{1'b0}},
                         expected_status, check_mask);

  $display("[TB] Directed status tests: %0d / %0d passed", pass_status_directed, total_status_directed);
endtask

// ----------------------------------------
// Main
// ----------------------------------------
initial begin
string mode_sel;

pass_fp32 = 0; total_fp32 = 0;
pass_fp16 = 0; total_fp16 = 0;
pass_fp8 = 0; total_fp8 = 0;
pass_simd_fp16 = 0; total_simd_fp16 = 0;
pass_simd_fp8 = 0; total_simd_fp8 = 0;
pass_dp_fp16 = 0; total_dp_fp16 = 0;
pass_dp_fp8 = 0; total_dp_fp8 = 0;
pass_dp_fp4 = 0; total_dp_fp4 = 0;
pass_status_directed = 0; total_status_directed = 0;
mode_sel = "all";
void'($value$plusargs("MODE=%s", mode_sel));

if ((mode_sel != "all") &&
    (mode_sel != "scalar") &&
    (mode_sel != "simd") &&
    (mode_sel != "dp") &&
    (mode_sel != "fp4dp") &&
    (mode_sel != "status")) begin
  $fatal(1, "[TB] Unsupported MODE=%s (supported: all, scalar, simd, dp, fp4dp, status)", mode_sel);
end

$display("[TB] MODE=%s", mode_sel);

reset_dut();

if ((mode_sel == "all") || (mode_sel == "scalar")) begin
  run_format(FP32, "fp32");
  run_format(FP16, "fp16");
  run_format(FP8,  "fp8");
end
if ((mode_sel == "all") || (mode_sel == "simd")) begin
  run_simd_fp16(FP16, "fp16_simd_fp16");
  run_simd_fp8(FP8, "fp8_simd_fp8");
end
if ((mode_sel == "all") || (mode_sel == "dp")) begin
  run_dp(FP16,  "fp16_fp32_dp");
  run_dp_fp8(FP8,  "fp8_fp32_dp");
end
if ((mode_sel == "all") || (mode_sel == "fp4dp")) begin
  run_dp_fp4(FP8, "fp4_fp32_dp");
end
if ((mode_sel == "all") || (mode_sel == "status")) begin
  run_status_directed();
end

$display("\n");
print_summary();
$display("\nAll file-based tests completed! total_pass=%0d total_tests=%0d", total_pass_count(), total_tests_count());
if (total_fail_count() != 0) begin
  $fatal(1, "[TB] Regression FAILED with %0d mismatches", total_fail_count());
end
$display("[TB] Regression PASSED");
$finish;
end

`ifdef FSDB
initial begin
  if ($test$plusargs("WAVES")) begin
    $fsdbDumpfile("tb_fpnew_syn.fsdb");
    $fsdbDumpvars("+all");
  end
end
`endif

endmodule
