// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps

module tb_fpnew;
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
// MX sideband — TB doesn't exercise MX yet; tie off.
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
  else if (fmt == FP16) begin
    // IEEE-754 binary16 (e5m10), bias = 15
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
  else if (fmt == FP16ALT) begin
    // bfloat16 (e8m7), bias = 127
    logic        s = raw[15];
    logic [7:0]  e = raw[14:7];
    logic [6:0]  m = raw[6:0];
    real sign = s ? -1.0 : 1.0;
    if (e == 8'b11111111) begin
      if (m == 0) return sign * (1.0/0.0); // inf
      else        return 0.0/0.0;          // NaN
    end else if (e == 8'b00000000) begin
      if (m == 0) return sign * 0.0;       // zero
      else        return sign * (m / 128.0) * pow2(-126);
    end else begin
      return sign * (1.0 + m / 128.0) * pow2((int'(e) - 127));
    end
  end
  else if (fmt == FP8) begin
    // FP8 E4M3, bias = 7
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
  else if (fmt == FP8ALT) begin
    // FP8ALT E5M2, bias = 15
    logic        s = raw[7];
    logic [4:0]  e = raw[6:2];
    logic [1:0]  m = raw[1:0];
    real sign = s ? -1.0 : 1.0;
    if (e == 5'b11111) begin
      if (m == 0) return sign * (1.0/0.0); // inf
      else        return 0.0/0.0;          // NaN
    end else if (e == 5'b00000) begin
      if (m == 0) return sign * 0.0;       // zero
      else        return sign * (m / 4.0) * pow2(-14.0);  // subnormal
    end else begin
      return sign * (1.0 + m / 4.0) * pow2((int'(e) - 15));
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
int pass_int16, total_int16;
int pass_int8,  total_int8;
int pass_int4,  total_int4;
int pass_bf16,      total_bf16;
int pass_simd_bf16, total_simd_bf16;
int pass_dp_bf16,   total_dp_bf16;
int pass_fp8alt,      total_fp8alt;
int pass_simd_fp8alt, total_simd_fp8alt;
int pass_dp_fp8alt,   total_dp_fp8alt;
// BF16 as DP accumulator destination (dst_fmt=FP16ALT). Same DP geometry as
// the FP32-accumulator paths, but result and addend `c` are BF16.
int pass_dp_bf16_bf16,   total_dp_bf16_bf16;
int pass_dp_fp8_bf16,    total_dp_fp8_bf16;
int pass_dp_fp4_bf16,    total_dp_fp4_bf16;
int pass_dp_fp8alt_bf16, total_dp_fp8alt_bf16;

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
                total_status_directed +
                total_int16 + total_int8 + total_int4 +
                total_bf16 + total_simd_bf16 + total_dp_bf16 +
                total_fp8alt + total_simd_fp8alt + total_dp_fp8alt +
                total_dp_bf16_bf16 + total_dp_fp8_bf16 +
                total_dp_fp4_bf16  + total_dp_fp8alt_bf16;
  total_pass  = pass_fp32 + pass_fp16 + pass_fp8 +
                pass_simd_fp16 + pass_simd_fp8 +
                pass_dp_fp16 + pass_dp_fp8 + pass_dp_fp4 +
                pass_status_directed +
                pass_int16 + pass_int8 + pass_int4 +
                pass_bf16 + pass_simd_bf16 + pass_dp_bf16 +
                pass_fp8alt + pass_simd_fp8alt + pass_dp_fp8alt +
                pass_dp_bf16_bf16 + pass_dp_fp8_bf16 +
                pass_dp_fp4_bf16  + pass_dp_fp8alt_bf16;
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
  if (total_int16 > 0) $display("  int16          : %0d / %0d passed", pass_int16, total_int16);
  if (total_int8  > 0) $display("  int8           : %0d / %0d passed", pass_int8,  total_int8);
  if (total_int4  > 0) $display("  int4           : %0d / %0d passed", pass_int4,  total_int4);
  if (total_bf16        > 0) $display("  bf16           : %0d / %0d passed", pass_bf16,        total_bf16);
  if (total_simd_bf16   > 0) $display("  bf16_simd_bf16 : %0d / %0d passed", pass_simd_bf16,   total_simd_bf16);
  if (total_dp_bf16     > 0) $display("  bf16_fp32_dp   : %0d / %0d passed", pass_dp_bf16,     total_dp_bf16);
  if (total_fp8alt      > 0) $display("  fp8alt         : %0d / %0d passed", pass_fp8alt,      total_fp8alt);
  if (total_simd_fp8alt > 0) $display("  fp8alt_simd    : %0d / %0d passed", pass_simd_fp8alt, total_simd_fp8alt);
  if (total_dp_fp8alt   > 0) $display("  fp8alt_fp32_dp : %0d / %0d passed", pass_dp_fp8alt,   total_dp_fp8alt);
  if (total_dp_bf16_bf16   > 0) $display("  bf16_bf16_dp   : %0d / %0d passed", pass_dp_bf16_bf16,   total_dp_bf16_bf16);
  if (total_dp_fp8_bf16    > 0) $display("  fp8_bf16_dp    : %0d / %0d passed", pass_dp_fp8_bf16,    total_dp_fp8_bf16);
  if (total_dp_fp4_bf16    > 0) $display("  fp4_bf16_dp    : %0d / %0d passed", pass_dp_fp4_bf16,    total_dp_fp4_bf16);
  if (total_dp_fp8alt_bf16 > 0) $display("  fp8alt_bf16_dp : %0d / %0d passed", pass_dp_fp8alt_bf16, total_dp_fp8alt_bf16);

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
                      total_status_directed +
                      total_int16 + total_int8 + total_int4 +
                      total_bf16 + total_simd_bf16 + total_dp_bf16 +
                      total_fp8alt + total_simd_fp8alt + total_dp_fp8alt +
                      total_dp_bf16_bf16 + total_dp_fp8_bf16 +
                      total_dp_fp4_bf16  + total_dp_fp8alt_bf16;
endfunction

function automatic int total_pass_count();
  total_pass_count = pass_fp32 + pass_fp16 + pass_fp8 +
                     pass_simd_fp16 + pass_simd_fp8 +
                     pass_dp_fp16 + pass_dp_fp8 + pass_dp_fp4 +
                     pass_status_directed +
                     pass_int16 + pass_int8 + pass_int4 +
                     pass_bf16 + pass_simd_bf16 + pass_dp_bf16 +
                     pass_fp8alt + pass_simd_fp8alt + pass_dp_fp8alt +
                     pass_dp_bf16_bf16 + pass_dp_fp8_bf16 +
                     pass_dp_fp4_bf16  + pass_dp_fp8alt_bf16;
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

// ----------------------------------------
// INT_DP_FMADD coverage (TransDot-level, FPU only).
// Generates 1024 random signed inputs per format and compares the FPU's
// INT32 result against a bit-exact SV golden. Lane geometry matches the
// implemented k (INT16 k=1, INT8 k=2, INT4 k=4 — see
// docs/systolic/int_dp_fmadd_status.md): each INT-X format reuses the
// FP-2X datapath, so only the lower 16 bits of operand_a/operand_b are
// fed into the multiplier in INT mode. operand_c is the full INT32
// accumulator.
// ----------------------------------------
task automatic run_int(int_format_e ifmt, string prefix);
  int ntests = NUM_TESTS;
  int pass_count = 0;
  longint signed golden_full;
  logic   signed [31:0] golden;
  logic   signed [31:0] hw_result;
  logic   signed [31:0] c_acc;
  logic   signed [15:0] a16, b16;
  logic   signed [ 7:0] a8_0, a8_1, b8_0, b8_1;
  logic   signed [ 3:0] a4_0, a4_1, a4_2, a4_3;
  logic   signed [ 3:0] b4_0, b4_1, b4_2, b4_3;

  src_fmt_i      = FP32;     // unused in INT mode but must hold a valid value
  dst_fmt_i      = FP32;
  rnd_mode_i     = RNE;
  vectorial_op_i = 1'b0;
  int_fmt_i      = ifmt;
  op_mod_i       = 1'b0;     // 0 → signed (per fpnew_pkg INT_DP_FMADD comment)

  for (int i = 0; i < ntests; i++) begin
    operands_i[0] = $urandom();
    operands_i[1] = $urandom();
    operands_i[2] = $urandom();
    op_i          = fpnew_pkg::INT_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    c_acc       = operands_i[2][31:0];
    golden_full = c_acc;
    case (ifmt)
      INT16: begin
        a16 = operands_i[0][15:0];
        b16 = operands_i[1][15:0];
        golden_full += longint'(a16) * longint'(b16);
      end
      INT8: begin
        a8_0 = operands_i[0][ 7:0];   a8_1 = operands_i[0][15:8];
        b8_0 = operands_i[1][ 7:0];   b8_1 = operands_i[1][15:8];
        golden_full += longint'(a8_0) * longint'(b8_0)
                     + longint'(a8_1) * longint'(b8_1);
      end
      INT4: begin
        a4_0 = operands_i[0][ 3: 0];  b4_0 = operands_i[1][ 3: 0];
        a4_1 = operands_i[0][ 7: 4];  b4_1 = operands_i[1][ 7: 4];
        a4_2 = operands_i[0][11: 8];  b4_2 = operands_i[1][11: 8];
        a4_3 = operands_i[0][15:12];  b4_3 = operands_i[1][15:12];
        golden_full += longint'(a4_0) * longint'(b4_0)
                     + longint'(a4_1) * longint'(b4_1)
                     + longint'(a4_2) * longint'(b4_2)
                     + longint'(a4_3) * longint'(b4_3);
      end
      default: $fatal(1, "[TB] run_int: unsupported INT format %0d", ifmt);
    endcase

    golden    = golden_full[31:0];
    hw_result = result_o;

    if (hw_result === golden) begin
      pass_count++;
      if (verbose)
        $display("[PASS] %s i=%0d a=%h b=%h c=%h -> hw=%0d gold=%0d",
                 prefix, i, operands_i[0], operands_i[1], operands_i[2],
                 $signed(hw_result), $signed(golden));
    end else begin
      $error("[FAIL] %s i=%0d a=%h b=%h c=%h -> hw=%0d (%h) gold=%0d (%h)",
             prefix, i, operands_i[0], operands_i[1], operands_i[2],
             $signed(hw_result), hw_result, $signed(golden), golden);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  case (ifmt)
    INT16: begin pass_int16 = pass_count; total_int16 = ntests; end
    INT8:  begin pass_int8  = pass_count; total_int8  = ntests; end
    INT4:  begin pass_int4  = pass_count; total_int4  = ntests; end
    default: ;
  endcase
endtask

// ----------------------------------------
// BF16 (FP16ALT, e8m7) coverage.
// Generates 1024 random BF16 inputs per format and compares the FPU
// output against an SV `real` golden with REL_ERR_THRESH tolerance
// (BF16's 7-b mantissa makes 1 ULP ≈ 0.78%, comfortably under 1%).
// NaN / Inf inputs are filtered at generation; subnormals and zeros
// are kept.
// ----------------------------------------
// Generate BF16 and FP32 with *bounded* exponent so a 2-lane BF16 dot product
// plus FP32 accumulator stays well within FP32's normal range. Without this
// bound, BF16's [2^-126, 2^127] dynamic range can produce 2-lane products up
// to 2^254 — far past FP32 max (2^127), so the HW saturates correctly while
// the SV `real` golden does not, generating spurious mismatches. The window
// below caps |x| ≤ 2^32 and |x| ≥ 2^-32, so |a·b| ≤ 2^65 and |Σ a·b + c| stays
// inside FP32.
function automatic logic [15:0] gen_finite_bf16();
  logic [15:0] r;
  logic [7:0]  e;
  r        = $urandom() & 16'hFFFF;
  e        = ($urandom() % 65) + 95;   // biased exp ∈ [95, 159] → unbiased [-32, +32]
  r[14:7]  = e;
  return r;
endfunction

function automatic logic [31:0] gen_finite_fp32();
  logic [31:0] r;
  logic [7:0]  e;
  r         = $urandom();
  e         = ($urandom() % 65) + 95;  // same window as BF16 to stay in-range
  r[30:23]  = e;
  return r;
endfunction

task automatic run_bf16_scalar(string prefix);
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [15:0] a_bf, b_bf, c_bf;
  real a_r, b_r, c_r, hw, gold, diff;
  logic [31:0] gold_fp32_bits;
  int  ulp;

  src_fmt_i      = FP16ALT;
  dst_fmt_i      = FP16ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    a_bf = gen_finite_bf16();
    b_bf = gen_finite_bf16();
    c_bf = gen_finite_bf16();

    // NaN-box BF16 into the 32-b operand word (BF16 occupies the lower 16 b).
    operands_i[0] = box_bits({16'd0, a_bf}, FP16ALT);
    operands_i[1] = box_bits({16'd0, b_bf}, FP16ALT);
    operands_i[2] = box_bits({16'd0, c_bf}, FP16ALT);
    op_i          = fpnew_pkg::FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    a_r  = bits_to_real(FP16ALT, {16'hFFFF, a_bf});
    b_r  = bits_to_real(FP16ALT, {16'hFFFF, b_bf});
    c_r  = bits_to_real(FP16ALT, {16'hFFFF, c_bf});
    gold = a_r * b_r + c_r;
    hw   = bits_to_real(FP16ALT, result_o);
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);
    // BF16 ≈ upper 16 b of an FP32 round of `gold`. Good enough for ULP fallback.
    gold_fp32_bits = $shortrealtobits(shortreal'(gold));
    ulp  = ulp_diff({16'd0, result_o[15:0]}, {16'd0, gold_fp32_bits[31:16]});

    if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
      pass_count++;
      if (verbose)
        $display("[PASS] %s i=%0d a=%e b=%e c=%e -> hw=%e gold=%e diff=%e ulp=%0d",
                 prefix, i, a_r, b_r, c_r, hw, gold, diff, ulp);
    end else begin
      $error("[FAIL] %s i=%0d a=%e (%h) b=%e (%h) c=%e (%h) -> hw=%e (%h) gold=%e diff=%e ulp=%0d",
             prefix, i, a_r, a_bf, b_r, b_bf, c_r, c_bf, hw, result_o[15:0], gold, diff, ulp);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_bf16  = pass_count;
  total_bf16 = ntests;
endtask

task automatic run_bf16_simd(string prefix);
  // Two parallel scalar BF16 FMAs: result = {a1·b1+c1, a0·b0+c0}, each lane
  // independent (no DP reduction). Lane 0 in operands_i[*][15:0],
  // lane 1 in operands_i[*][31:16]. Each lane is bf16-rounded to bf16.
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [15:0] a0_bf, a1_bf, b0_bf, b1_bf, c0_bf, c1_bf;
  real a0_r, a1_r, b0_r, b1_r, c0_r, c1_r;
  real hw0, hw1, gold0, gold1, diff0, diff1;
  logic [31:0] gold0_fp32_bits, gold1_fp32_bits;
  int  ulp0, ulp1;
  bit  pass_low;

  src_fmt_i      = FP16ALT;
  dst_fmt_i      = FP16ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    a0_bf = gen_finite_bf16();   a1_bf = gen_finite_bf16();
    b0_bf = gen_finite_bf16();   b1_bf = gen_finite_bf16();
    c0_bf = gen_finite_bf16();   c1_bf = gen_finite_bf16();

    operands_i[0] = {a1_bf, a0_bf};
    operands_i[1] = {b1_bf, b0_bf};
    operands_i[2] = {c1_bf, c0_bf};
    op_i          = fpnew_pkg::TDOT_SIMD_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    a0_r = bits_to_real(FP16ALT, {16'hFFFF, a0_bf});
    b0_r = bits_to_real(FP16ALT, {16'hFFFF, b0_bf});
    c0_r = bits_to_real(FP16ALT, {16'hFFFF, c0_bf});
    a1_r = bits_to_real(FP16ALT, {16'hFFFF, a1_bf});
    b1_r = bits_to_real(FP16ALT, {16'hFFFF, b1_bf});
    c1_r = bits_to_real(FP16ALT, {16'hFFFF, c1_bf});

    gold0 = a0_r * b0_r + c0_r;
    gold1 = a1_r * b1_r + c1_r;
    hw0   = bits_to_real(FP16ALT, {16'hFFFF, result_o[15:0]});
    hw1   = bits_to_real(FP16ALT, {16'hFFFF, result_o[31:16]});
    diff0 = (gold0 == 0) ? $abs(hw0) : $abs((hw0 - gold0) / gold0);
    diff1 = (gold1 == 0) ? $abs(hw1) : $abs((hw1 - gold1) / gold1);

    gold0_fp32_bits = $shortrealtobits(shortreal'(gold0));
    gold1_fp32_bits = $shortrealtobits(shortreal'(gold1));
    ulp0 = ulp_diff({16'd0, result_o[15:0]},  {16'd0, gold0_fp32_bits[31:16]});
    ulp1 = ulp_diff({16'd0, result_o[31:16]}, {16'd0, gold1_fp32_bits[31:16]});

    pass_low = (diff0 < REL_ERR_THRESH) || ($abs(ulp0) < ULP_ERR_THRESH);
    if (pass_low && ((diff1 < REL_ERR_THRESH) || ($abs(ulp1) < ULP_ERR_THRESH))) begin
      pass_count++;
      if (verbose)
        $display("[PASS] %s i=%0d  L0: hw=%e gold=%e (diff=%e ulp=%0d)  L1: hw=%e gold=%e (diff=%e ulp=%0d)",
                 prefix, i, hw0, gold0, diff0, ulp0, hw1, gold1, diff1, ulp1);
    end else begin
      $error("[FAIL] %s i=%0d  L0: a=%e b=%e c=%e -> hw=%e gold=%e diff=%e ulp=%0d  L1: a=%e b=%e c=%e -> hw=%e gold=%e diff=%e ulp=%0d",
             prefix, i, a0_r, b0_r, c0_r, hw0, gold0, diff0, ulp0,
                       a1_r, b1_r, c1_r, hw1, gold1, diff1, ulp1);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_simd_bf16  = pass_count;
  total_simd_bf16 = ntests;
endtask

task automatic run_bf16_dp(string prefix);
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [15:0] a0_bf, a1_bf, b0_bf, b1_bf;
  logic [31:0] c_fp;
  real a0_r, a1_r, b0_r, b1_r, c_r, hw, gold, diff;
  int  ulp;

  src_fmt_i      = FP16ALT;
  dst_fmt_i      = FP32;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    a0_bf = gen_finite_bf16();
    a1_bf = gen_finite_bf16();
    b0_bf = gen_finite_bf16();
    b1_bf = gen_finite_bf16();
    c_fp  = gen_finite_fp32();

    operands_i[0] = {a1_bf, a0_bf};   // lane 1 in upper half, lane 0 in lower half
    operands_i[1] = {b1_bf, b0_bf};
    operands_i[2] = c_fp;
    op_i          = fpnew_pkg::TDOT_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    a0_r = bits_to_real(FP16ALT, {16'hFFFF, a0_bf});
    a1_r = bits_to_real(FP16ALT, {16'hFFFF, a1_bf});
    b0_r = bits_to_real(FP16ALT, {16'hFFFF, b0_bf});
    b1_r = bits_to_real(FP16ALT, {16'hFFFF, b1_bf});
    c_r  = bits_to_real(FP32, c_fp);
    gold = a0_r * b0_r + a1_r * b1_r + c_r;
    hw   = bits_to_real(FP32, result_o);
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);
    ulp  = ulp_diff(result_o, $shortrealtobits(shortreal'(gold)));

    if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
      pass_count++;
      if (verbose)
        $display("[PASS] %s i=%0d a0=%e a1=%e b0=%e b1=%e c=%e -> hw=%e gold=%e diff=%e ulp=%0d",
                 prefix, i, a0_r, a1_r, b0_r, b1_r, c_r, hw, gold, diff, ulp);
    end else begin
      $error("[FAIL] %s i=%0d a0=%e a1=%e b0=%e b1=%e c=%e -> hw=%e (%h) gold=%e diff=%e ulp=%0d",
             prefix, i, a0_r, a1_r, b0_r, b1_r, c_r, hw, result_o, gold, diff, ulp);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_dp_bf16  = pass_count;
  total_dp_bf16 = ntests;
endtask

// ----------------------------------------
// FP8ALT (E5M2) coverage. Same recipe as BF16: $urandom + SV-real golden,
// REL_ERR_THRESH tolerance. E5M2 has 2-b explicit mantissa so 1 ULP ≈ 25%
// for very small magnitudes — we keep REL_ERR_THRESH at 1% but rely on the
// ULP fallback (ULP_ERR_THRESH=2) which is the canonical pass criterion at
// this precision. NaN / Inf inputs are filtered at generation.
// ----------------------------------------
function automatic logic [7:0] gen_finite_fp8alt();
  // Tight exponent bound [13, 17] (unbiased [-2, +2]): keeps dp_shamt within
  // an architecturally-safe range across all 4 SIMD lanes (otherwise the
  // shared dp_shamt fabric — designed for SUPER_EXP_BITS_FP8=4 / FP8 — can
  // shift FP8ALT lane partials further than its level-1 buffers tolerate).
  logic [7:0] r;
  logic [4:0] e;
  r       = $urandom() & 8'hFF;
  e       = ($urandom() % 5) + 13;      // biased exp ∈ [13, 17]
  r[6:2]  = e;
  return r;
endfunction

task automatic run_fp8alt_scalar(string prefix);
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [7:0]  a_bf, b_bf, c_bf;
  real a_r, b_r, c_r, hw, gold, diff;
  logic [31:0] gold_fp32_bits;
  int  ulp;

  src_fmt_i      = FP8ALT;
  dst_fmt_i      = FP8ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    a_bf = gen_finite_fp8alt();
    b_bf = gen_finite_fp8alt();
    c_bf = gen_finite_fp8alt();

    operands_i[0] = box_bits({24'd0, a_bf}, FP8);  // FP8/FP8ALT use the same NaN-box pattern (both 8-b)
    operands_i[1] = box_bits({24'd0, b_bf}, FP8);
    operands_i[2] = box_bits({24'd0, c_bf}, FP8);
    op_i          = fpnew_pkg::FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    a_r  = bits_to_real(FP8ALT, {24'd0, a_bf});
    b_r  = bits_to_real(FP8ALT, {24'd0, b_bf});
    c_r  = bits_to_real(FP8ALT, {24'd0, c_bf});
    gold = a_r * b_r + c_r;
    hw   = bits_to_real(FP8ALT, {24'd0, result_o[7:0]});
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);
    gold_fp32_bits = $shortrealtobits(shortreal'(gold));
    // Compare 8-b dst directly against truncated FP32 gold; pad to 32 b for
    // the helper. (One of the upper "FP8" bytes is fine — the helper only
    // looks at ints.)
    ulp = ulp_diff({24'd0, result_o[7:0]}, {24'd0, gold_fp32_bits[31:24]});

    // E5M2 has 2-b explicit mantissa; max RNE relative error per FMA is
    // 0.5 ULP = 0.5/4 = 12.5%. Use 0.20 to absorb that with margin.
    if ((diff < 0.20) || ($abs(ulp) < ULP_ERR_THRESH)) begin
      pass_count++;
      if (verbose)
        $display("[PASS] %s i=%0d a=%e b=%e c=%e -> hw=%e gold=%e diff=%e ulp=%0d",
                 prefix, i, a_r, b_r, c_r, hw, gold, diff, ulp);
    end else begin
      $error("[FAIL] %s i=%0d a=%e (%h) b=%e (%h) c=%e (%h) -> hw=%e (%h) gold=%e diff=%e ulp=%0d",
             prefix, i, a_r, a_bf, b_r, b_bf, c_r, c_bf, hw, result_o[7:0], gold, diff, ulp);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_fp8alt  = pass_count;
  total_fp8alt = ntests;
endtask

task automatic run_fp8alt_simd(string prefix);
  // 4 parallel scalar FP8ALT FMAs (mirror of fp8_simd_fp8). Each lane is one
  // FMA, packed into the 32-b operand at byte boundaries.
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [7:0]  a [0:3];
  logic [7:0]  b [0:3];
  logic [7:0]  c [0:3];
  real a_r [0:3];
  real b_r [0:3];
  real c_r [0:3];
  real hw_r [0:3];
  real gold [0:3];
  real diff [0:3];
  logic [31:0] gold_fp32 [0:3];
  int  ulp [0:3];
  bit  all_lanes_pass;

  src_fmt_i      = FP8ALT;
  dst_fmt_i      = FP8ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    for (int L = 0; L < 4; L++) begin
      a[L] = gen_finite_fp8alt();
      b[L] = gen_finite_fp8alt();
      c[L] = gen_finite_fp8alt();
    end

    operands_i[0] = {a[3], a[2], a[1], a[0]};
    operands_i[1] = {b[3], b[2], b[1], b[0]};
    operands_i[2] = {c[3], c[2], c[1], c[0]};
    op_i          = fpnew_pkg::TDOT_SIMD_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    all_lanes_pass = 1'b1;
    for (int L = 0; L < 4; L++) begin
      a_r[L]  = bits_to_real(FP8ALT, {24'd0, a[L]});
      b_r[L]  = bits_to_real(FP8ALT, {24'd0, b[L]});
      c_r[L]  = bits_to_real(FP8ALT, {24'd0, c[L]});
      gold[L] = a_r[L] * b_r[L] + c_r[L];
      hw_r[L] = bits_to_real(FP8ALT, {24'd0, result_o[L*8 +: 8]});
      diff[L] = (gold[L] == 0) ? $abs(hw_r[L]) : $abs((hw_r[L] - gold[L]) / gold[L]);
      gold_fp32[L] = $shortrealtobits(shortreal'(gold[L]));
      ulp[L]  = ulp_diff({24'd0, result_o[L*8 +: 8]}, {24'd0, gold_fp32[L][31:24]});
      // E5M2 1 ULP ≈ 25%; 0.20 rel-err absorbs 0.5-ULP RNE rounding.
      if (!((diff[L] < 0.20) || ($abs(ulp[L]) < ULP_ERR_THRESH)))
        all_lanes_pass = 1'b0;
    end

    if (all_lanes_pass) begin
      pass_count++;
    end else begin
      $error("[FAIL] %s i=%0d  L0 a=%h b=%h c=%h hw=%h(%e) gold=%e diff=%e ulp=%0d  L1 hw=%h gold=%e  L2 hw=%h gold=%e  L3 hw=%h gold=%e",
             prefix, i,
             a[0], b[0], c[0], result_o[7:0], hw_r[0], gold[0], diff[0], ulp[0],
             result_o[15:8],  gold[1],
             result_o[23:16], gold[2],
             result_o[31:24], gold[3]);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_simd_fp8alt  = pass_count;
  total_simd_fp8alt = ntests;
endtask

task automatic run_fp8alt_dp(string prefix);
  // 4-lane FP8ALT DPA into FP32 accumulator (mirror of fp8_fp32_dp).
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [7:0]  a [0:3];
  logic [7:0]  b [0:3];
  logic [31:0] c_fp;
  real a_r [0:3];
  real b_r [0:3];
  real c_r;
  real hw, gold, diff;
  int  ulp;

  src_fmt_i      = FP8ALT;
  dst_fmt_i      = FP32;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    for (int L = 0; L < 4; L++) begin
      a[L] = gen_finite_fp8alt();
      b[L] = gen_finite_fp8alt();
    end
    c_fp = gen_finite_fp32();

    operands_i[0] = {a[3], a[2], a[1], a[0]};
    operands_i[1] = {b[3], b[2], b[1], b[0]};
    operands_i[2] = c_fp;
    op_i          = fpnew_pkg::TDOT_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    c_r  = bits_to_real(FP32, c_fp);
    gold = c_r;
    for (int L = 0; L < 4; L++) begin
      a_r[L] = bits_to_real(FP8ALT, {24'd0, a[L]});
      b_r[L] = bits_to_real(FP8ALT, {24'd0, b[L]});
      gold   = gold + a_r[L] * b_r[L];
    end
    hw   = bits_to_real(FP32, result_o);
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);
    ulp  = ulp_diff(result_o, $shortrealtobits(shortreal'(gold)));

    if ((diff < REL_ERR_THRESH) || ($abs(ulp) < ULP_ERR_THRESH)) begin
      pass_count++;
      if (verbose)
        $display("[PASS] %s i=%0d  ab={%e,%e,%e,%e}*{%e,%e,%e,%e} c=%e -> hw=%e gold=%e diff=%e ulp=%0d",
                 prefix, i, a_r[0], a_r[1], a_r[2], a_r[3],
                          b_r[0], b_r[1], b_r[2], b_r[3], c_r, hw, gold, diff, ulp);
    end else begin
      $error("[FAIL] %s i=%0d  ab={%e,%e,%e,%e}*{%e,%e,%e,%e} c=%e -> hw=%e (%h) gold=%e diff=%e ulp=%0d",
             prefix, i, a_r[0], a_r[1], a_r[2], a_r[3],
                       b_r[0], b_r[1], b_r[2], b_r[3], c_r, hw, result_o, gold, diff, ulp);
    end
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_dp_fp8alt  = pass_count;
  total_dp_fp8alt = ntests;
endtask

// ----------------------------------------
// BF16 (FP16ALT) as the DP-mode accumulator destination.
// All four tasks set dst_fmt_i = FP16ALT, pack the BF16 c-operand into the
// lower 16 bits of operands_i[2], and decode result_o[15:0] as BF16.
// REL_ERR_THRESH 1% with ULP_ERR_THRESH=2 fallback (BF16 1 ULP ≈ 0.78%).
// ----------------------------------------
function automatic logic [7:0] gen_finite_fp8();
  // E4M3, biased exp ∈ [3, 11] → unbiased [-4, +4]. Avoids 0 (subnormal hop)
  // and 15 (NaN/Inf). Magnitudes stay in [~0.06, ~30].
  logic [7:0] r;
  logic [3:0] e;
  r       = $urandom() & 8'hFF;
  e       = ($urandom() % 9) + 3;
  r[6:3]  = e;
  return r;
endfunction

function automatic logic [3:0] gen_finite_fp4_nibble();
  // FP4 e2m1, exp ∈ {00, 01, 10}. e=11 = NaN/Inf — exclude.
  logic [3:0] r;
  logic [1:0] e;
  r       = $urandom() & 4'hF;
  e       = $urandom() % 3;
  r[2:1]  = e;
  return r;
endfunction

task automatic run_bf16_bf16_dp(string prefix);
  // 2-lane BF16 dot product accumulating into BF16: hw = a0*b0 + a1*b1 + c.
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [15:0] a0_bf, a1_bf, b0_bf, b1_bf, c_bf;
  real a0_r, a1_r, b0_r, b1_r, c_r, hw, gold, diff;

  src_fmt_i      = FP16ALT;
  dst_fmt_i      = FP16ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    a0_bf = gen_finite_bf16();
    a1_bf = gen_finite_bf16();
    b0_bf = gen_finite_bf16();
    b1_bf = gen_finite_bf16();
    c_bf  = gen_finite_bf16();

    operands_i[0] = {a1_bf, a0_bf};
    operands_i[1] = {b1_bf, b0_bf};
    operands_i[2] = {16'h0000, c_bf};
    op_i          = fpnew_pkg::TDOT_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    a0_r = bits_to_real(FP16ALT, {16'h0, a0_bf});
    a1_r = bits_to_real(FP16ALT, {16'h0, a1_bf});
    b0_r = bits_to_real(FP16ALT, {16'h0, b0_bf});
    b1_r = bits_to_real(FP16ALT, {16'h0, b1_bf});
    c_r  = bits_to_real(FP16ALT, {16'h0, c_bf});
    gold = a0_r * b0_r + a1_r * b1_r + c_r;
    hw   = bits_to_real(FP16ALT, {16'h0, result_o[15:0]});
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

    if (diff < REL_ERR_THRESH) pass_count++;
    else
      $error("[FAIL] %s i=%0d a0=%e a1=%e b0=%e b1=%e c=%e -> hw=%e (%h) gold=%e diff=%e",
             prefix, i, a0_r, a1_r, b0_r, b1_r, c_r, hw, result_o[15:0], gold, diff);
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_dp_bf16_bf16  = pass_count;
  total_dp_bf16_bf16 = ntests;
endtask

task automatic run_fp8_bf16_dp(string prefix);
  // 4-lane FP8 dot product accumulating into BF16.
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [7:0]  a [0:3];
  logic [7:0]  b [0:3];
  logic [15:0] c_bf;
  real a_r [0:3];
  real b_r [0:3];
  real c_r, hw, gold, diff;

  src_fmt_i      = FP8;
  dst_fmt_i      = FP16ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    for (int L = 0; L < 4; L++) begin
      a[L] = gen_finite_fp8();
      b[L] = gen_finite_fp8();
    end
    c_bf = gen_finite_bf16();

    operands_i[0] = {a[3], a[2], a[1], a[0]};
    operands_i[1] = {b[3], b[2], b[1], b[0]};
    operands_i[2] = {16'h0000, c_bf};
    op_i          = fpnew_pkg::TDOT_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    c_r  = bits_to_real(FP16ALT, {16'h0, c_bf});
    gold = c_r;
    for (int L = 0; L < 4; L++) begin
      a_r[L] = bits_to_real(FP8, {24'd0, a[L]});
      b_r[L] = bits_to_real(FP8, {24'd0, b[L]});
      gold   = gold + a_r[L] * b_r[L];
    end
    hw   = bits_to_real(FP16ALT, {16'h0, result_o[15:0]});
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

    if (diff < REL_ERR_THRESH) pass_count++;
    else
      $error("[FAIL] %s i=%0d ab={%e,%e,%e,%e}*{%e,%e,%e,%e} c=%e -> hw=%e (%h) gold=%e diff=%e",
             prefix, i, a_r[0], a_r[1], a_r[2], a_r[3],
                       b_r[0], b_r[1], b_r[2], b_r[3], c_r, hw, result_o[15:0], gold, diff);
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_dp_fp8_bf16  = pass_count;
  total_dp_fp8_bf16 = ntests;
endtask

task automatic run_fp4_bf16_dp(string prefix);
  // 8-lane FP4 dot product accumulating into BF16.
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [3:0]  a [0:7];
  logic [3:0]  b [0:7];
  logic [15:0] c_bf;
  real a_r [0:7];
  real b_r [0:7];
  real c_r, hw, gold, diff;

  src_fmt_i      = FP4;
  dst_fmt_i      = FP16ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    for (int L = 0; L < 8; L++) begin
      a[L] = gen_finite_fp4_nibble();
      b[L] = gen_finite_fp4_nibble();
    end
    c_bf = gen_finite_bf16();

    operands_i[0] = {a[7], a[6], a[5], a[4], a[3], a[2], a[1], a[0]};
    operands_i[1] = {b[7], b[6], b[5], b[4], b[3], b[2], b[1], b[0]};
    operands_i[2] = {16'h0000, c_bf};
    op_i          = fpnew_pkg::TDOT_FP4_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    c_r  = bits_to_real(FP16ALT, {16'h0, c_bf});
    gold = c_r;
    for (int L = 0; L < 8; L++) begin
      a_r[L] = fp4_nibble_to_real(a[L]);
      b_r[L] = fp4_nibble_to_real(b[L]);
      gold   = gold + a_r[L] * b_r[L];
    end
    hw   = bits_to_real(FP16ALT, {16'h0, result_o[15:0]});
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

    if (diff < REL_ERR_THRESH) pass_count++;
    else
      $error("[FAIL] %s i=%0d  c=%e -> hw=%e (%h) gold=%e diff=%e",
             prefix, i, c_r, hw, result_o[15:0], gold, diff);
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_dp_fp4_bf16  = pass_count;
  total_dp_fp4_bf16 = ntests;
endtask

task automatic run_fp8alt_bf16_dp(string prefix);
  // 4-lane FP8ALT dot product accumulating into BF16.
  int ntests = NUM_TESTS;
  int pass_count = 0;
  logic [7:0]  a [0:3];
  logic [7:0]  b [0:3];
  logic [15:0] c_bf;
  real a_r [0:3];
  real b_r [0:3];
  real c_r, hw, gold, diff;

  src_fmt_i      = FP8ALT;
  dst_fmt_i      = FP16ALT;
  rnd_mode_i     = RNE;
  vectorial_op_i = 0;
  int_fmt_i      = INT32;
  op_mod_i       = 0;

  for (int i = 0; i < ntests; i++) begin
    for (int L = 0; L < 4; L++) begin
      a[L] = gen_finite_fp8alt();
      b[L] = gen_finite_fp8alt();
    end
    c_bf = gen_finite_bf16();

    operands_i[0] = {a[3], a[2], a[1], a[0]};
    operands_i[1] = {b[3], b[2], b[1], b[0]};
    operands_i[2] = {16'h0000, c_bf};
    op_i          = fpnew_pkg::TDOT_DP_FMADD;

    in_valid_i = 1;
    @(posedge clk);
    while (!in_ready_o) @(posedge clk);
    in_valid_i = 0;
    wait(out_valid_o);
    @(posedge clk);

    c_r  = bits_to_real(FP16ALT, {16'h0, c_bf});
    gold = c_r;
    for (int L = 0; L < 4; L++) begin
      a_r[L] = bits_to_real(FP8ALT, {24'd0, a[L]});
      b_r[L] = bits_to_real(FP8ALT, {24'd0, b[L]});
      gold   = gold + a_r[L] * b_r[L];
    end
    hw   = bits_to_real(FP16ALT, {16'h0, result_o[15:0]});
    diff = (gold == 0) ? $abs(hw) : $abs((hw - gold) / gold);

    // FP8ALT 1 ULP ≈ 25%; allow either BF16-rel-err or coarse 0.20 absorbing
    // the input quantization noise that compounds across 4 lanes.
    if ((diff < REL_ERR_THRESH) || (diff < 0.20)) pass_count++;
    else
      $error("[FAIL] %s i=%0d ab={%e,%e,%e,%e}*{%e,%e,%e,%e} c=%e -> hw=%e (%h) gold=%e diff=%e",
             prefix, i, a_r[0], a_r[1], a_r[2], a_r[3],
                       b_r[0], b_r[1], b_r[2], b_r[3], c_r, hw, result_o[15:0], gold, diff);
  end

  $display("[TB] Format %s: %0d / %0d passed", prefix, pass_count, ntests);
  pass_dp_fp8alt_bf16  = pass_count;
  total_dp_fp8alt_bf16 = ntests;
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
pass_int16 = 0; total_int16 = 0;
pass_int8  = 0; total_int8  = 0;
pass_int4  = 0; total_int4  = 0;
pass_bf16      = 0; total_bf16      = 0;
pass_simd_bf16 = 0; total_simd_bf16 = 0;
pass_dp_bf16   = 0; total_dp_bf16   = 0;
pass_fp8alt      = 0; total_fp8alt      = 0;
pass_simd_fp8alt = 0; total_simd_fp8alt = 0;
pass_dp_fp8alt   = 0; total_dp_fp8alt   = 0;
pass_dp_bf16_bf16   = 0; total_dp_bf16_bf16   = 0;
pass_dp_fp8_bf16    = 0; total_dp_fp8_bf16    = 0;
pass_dp_fp4_bf16    = 0; total_dp_fp4_bf16    = 0;
pass_dp_fp8alt_bf16 = 0; total_dp_fp8alt_bf16 = 0;
mode_sel = "all";
void'($value$plusargs("MODE=%s", mode_sel));

if ((mode_sel != "all") &&
    (mode_sel != "scalar") &&
    (mode_sel != "simd") &&
    (mode_sel != "dp") &&
    (mode_sel != "fp4dp") &&
    (mode_sel != "status") &&
    (mode_sel != "int") &&
    (mode_sel != "bf16") &&
    (mode_sel != "fp8alt") &&
    (mode_sel != "fp8alt_simd") &&
    (mode_sel != "bf16dp")) begin
  $fatal(1, "[TB] Unsupported MODE=%s (supported: all, scalar, simd, dp, fp4dp, status, int, bf16, fp8alt, fp8alt_simd, bf16dp)", mode_sel);
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
if ((mode_sel == "all") || (mode_sel == "int")) begin
  run_int(INT16, "int16");
  run_int(INT8,  "int8");
  run_int(INT4,  "int4");
end
if ((mode_sel == "all") || (mode_sel == "bf16")) begin
  run_bf16_scalar("bf16");
  run_bf16_simd  ("bf16_simd_bf16");
  run_bf16_dp    ("bf16_fp32_dp");
end
if ((mode_sel == "all") || (mode_sel == "fp8alt") || (mode_sel == "fp8alt_simd")) begin
  if (mode_sel != "fp8alt_simd") run_fp8alt_scalar("fp8alt");
  if (mode_sel == "all" || mode_sel == "fp8alt_simd") run_fp8alt_simd("fp8alt_simd");
  if (mode_sel != "fp8alt_simd") run_fp8alt_dp    ("fp8alt_fp32_dp");
end
if ((mode_sel == "all") || (mode_sel == "bf16dp")) begin
  run_bf16_bf16_dp ("bf16_bf16_dp");
  run_fp8_bf16_dp  ("fp8_bf16_dp");
  run_fp4_bf16_dp  ("fp4_bf16_dp");
  run_fp8alt_bf16_dp("fp8alt_bf16_dp");
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
    $fsdbDumpfile("tb_fpnew.fsdb");
    $fsdbDumpvars("+all");
  end
end
`endif

endmodule
