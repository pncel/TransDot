// Copyright 2019 ETH Zurich and University of Bologna.
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Mach <smach@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module transdot_fp4_fp8_fp16_fp32_fma #(
  parameter fpnew_pkg::fmt_logic_t   FpFmtConfig = '1,
  parameter int unsigned             NumPipeRegs = 0,
  parameter fpnew_pkg::pipe_config_t PipeConfig  = fpnew_pkg::BEFORE,
  parameter type                     TagType     = logic,
  parameter type                     AuxType     = logic,
  // Do not change
  localparam int unsigned WIDTH       = fpnew_pkg::max_fp_width(FpFmtConfig),
  localparam int unsigned NUM_FORMATS = fpnew_pkg::NUM_FP_FORMATS,
  localparam int unsigned ExtRegEnaWidth = NumPipeRegs == 0 ? 1 : NumPipeRegs
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  // Input signals
  input  logic [2:0][WIDTH-1:0]       operands_i, // 3 operands
  input  logic [NUM_FORMATS-1:0][2:0] is_boxed_i, // 3 operands
  input  fpnew_pkg::roundmode_e       rnd_mode_i,
  input  fpnew_pkg::operation_e       op_i,
  input  logic                        op_mod_i,
  input  fpnew_pkg::fp_format_e       src_fmt_i,  // format of the multiplicands
  input  fpnew_pkg::fp_format_e       src2_fmt_i, // format of the addend
  input  fpnew_pkg::fp_format_e       dst_fmt_i,  // format of the result
  input  fpnew_pkg::int_format_e      int_fmt_i,  // INT lane width when op_i == INT_DP_FMADD
  input  TagType                      tag_i,
  input  logic                        mask_i,
  input  AuxType                      aux_i,

  input  logic                        dp_enable_i,
  input  logic                        simd_enable_i,
  input  logic                        fp4_enable_i,
  // Input Handshake a
  input  logic                        in_valid_i,
  output logic                        in_ready_o,
  input  logic                        flush_i,
  // Output signals
  output logic [WIDTH-1:0]            result_o,
  output fpnew_pkg::status_t          status_o,
  output logic                        extension_bit_o,
  output TagType                      tag_o,
  output logic                        mask_o,
  output AuxType                      aux_o,
  // Output handshake
  output logic                        out_valid_o,
  input  logic                        out_ready_i,
  // Indication of valid data in flight
  output logic                        busy_o,
  // External register enable override
  input  logic [ExtRegEnaWidth-1:0]   reg_ena_i
);

  // ----------
  // Constants
  // ----------
  // The super-format that can hold all formats
  localparam fpnew_pkg::fp_encoding_t SUPER_FORMAT = fpnew_pkg::super_format(FpFmtConfig);

  localparam int unsigned SUPER_EXP_BITS = SUPER_FORMAT.exp_bits; //8
  localparam int unsigned SUPER_MAN_BITS = SUPER_FORMAT.man_bits; //23

  // SIMD-lane (lane 1 of the FP16-DP geometry) operand-decode widths.
  // Sized for FP16 / BF16 — exp_bits is 8 (BF16) so that a single SIMD
  // lane holds either an FP16 (5b exp) or BF16 (8b exp) exponent without
  // truncation. Mantissa stays at 10b since BF16's 7b mantissa fits.
  localparam int unsigned SUPER_EXP_BITS_SIMD = 8;
  localparam int unsigned SUPER_MAN_BITS_SIMD = 10;

  // FP8 lane (fp8_1 / fp8_2 — lanes 2/3 of the FP8-DP geometry) operand-decode
  // widths. Sized for the larger of E4M3 (4-b exp) and E5M2 (5-b exp); mantissa
  // stays at 3 b since E4M3's 3-b mantissa is the larger of the two and E5M2's
  // 2-b mantissa fits with one zero pad bit.
  localparam int unsigned SUPER_EXP_BITS_FP8 = 5;
  localparam int unsigned SUPER_MAN_BITS_FP8 = 3;

  // Precision bits 'p' include the implicit bit
  localparam int unsigned PRECISION_BITS = SUPER_MAN_BITS + 1; //24
  localparam int unsigned PRECISION_BITS_SIMD = SUPER_MAN_BITS_SIMD + 1; //11
  localparam int unsigned PRECISION_BITS_FP8 = SUPER_MAN_BITS_FP8 + 1; //4
  // The lower 2p+3 bits of the internal FMA result will be needed for leading-zero detection
  localparam int unsigned LOWER_SUM_WIDTH  = 2 * PRECISION_BITS + 3; //51
  localparam int unsigned LZC_RESULT_WIDTH = $clog2(LOWER_SUM_WIDTH); //6
  localparam int unsigned LOWER_SUM_WIDTH_SIMD  = 2 * PRECISION_BITS_SIMD + 3; //25
  localparam int unsigned LZC_RESULT_WIDTH_SIMD = $clog2(LOWER_SUM_WIDTH_SIMD); //5
  localparam int unsigned LOWER_SUM_WIDTH_FP8  = 2 * PRECISION_BITS_FP8 + 3; //11
  localparam int unsigned LZC_RESULT_WIDTH_FP8 = $clog2(LOWER_SUM_WIDTH_FP8); //4
  // Internal exponent width of FMA must accomodate all meaningful exponent values in order to avoid
  // datapath leakage. This is either given by the exponent bits or the width of the LZC result.
  // In most reasonable FP formats the internal exponent will be wider than the LZC result.
  localparam int unsigned EXP_WIDTH = fpnew_pkg::maximum(SUPER_EXP_BITS + 2, LZC_RESULT_WIDTH); //10
  localparam int unsigned EXP_WIDTH_SIMD = fpnew_pkg::maximum(SUPER_EXP_BITS_SIMD + 2, LZC_RESULT_WIDTH_SIMD); //10
  localparam int unsigned EXP_WIDTH_FP8 = fpnew_pkg::maximum(SUPER_EXP_BITS_FP8 + 2, LZC_RESULT_WIDTH_FP8); //10
  // Shift amount width: maximum internal mantissa size is 3p+4 bits
  localparam int unsigned SHIFT_AMOUNT_WIDTH = $clog2(3 * PRECISION_BITS + 5); //24*3+5=77 -> 7 bits
  localparam int unsigned SHIFT_AMOUNT_WIDTH_SIMD = $clog2(3 * PRECISION_BITS_SIMD + 5); //11*3+5=38 -> 6 bits
  localparam int unsigned SHIFT_AMOUNT_WIDTH_FP8 = $clog2(3 * PRECISION_BITS_FP8 + 5); //4*3+5=17 -> 5 bits
  // Pipelines
  localparam bit DIST_FRONT_MID_POST_PIPE4 = PipeConfig == fpnew_pkg::DISTRIBUTED && NumPipeRegs == 4;
  localparam int unsigned NUM_POST_NORM_REGS = DIST_FRONT_MID_POST_PIPE4 ? 1 : 0;
  localparam NUM_INP_REGS = PipeConfig == fpnew_pkg::BEFORE
                            ? NumPipeRegs
                            : (DIST_FRONT_MID_POST_PIPE4
                               ? 1
                               : (PipeConfig == fpnew_pkg::DISTRIBUTED
                                  ? ((NumPipeRegs + 1) / 3)
                                  : 0)); // no regs here otherwise
  localparam NUM_MID_REGS = PipeConfig == fpnew_pkg::INSIDE
                          ? NumPipeRegs
                          : (DIST_FRONT_MID_POST_PIPE4
                             ? 1
                             : (PipeConfig == fpnew_pkg::DISTRIBUTED
                                ? ((NumPipeRegs + 2) / 3)
                                : 0)); // no regs here otherwise
  localparam NUM_OUT_REGS = PipeConfig == fpnew_pkg::AFTER
                            ? NumPipeRegs
                            : (DIST_FRONT_MID_POST_PIPE4
                               ? 0
                               : (PipeConfig == fpnew_pkg::DISTRIBUTED
                                  ? (NumPipeRegs / 3)
                                  : 0)); // no regs here otherwise

  // ----------------
  // Type definition
  // ----------------
  typedef struct packed {
    logic                      sign;
    logic [SUPER_EXP_BITS-1:0] exponent;
    logic [SUPER_MAN_BITS-1:0] mantissa;
  } fp_t;

  typedef struct packed {
    logic                      sign;
    logic [SUPER_EXP_BITS_SIMD-1:0] exponent;
    logic [SUPER_MAN_BITS_SIMD-1:0] mantissa;
  } fp_t_simd;

  typedef struct packed {
    logic                      sign;
    logic [SUPER_EXP_BITS_FP8-1:0] exponent;
    logic [SUPER_MAN_BITS_FP8-1:0] mantissa;
  } fp_t_fp8;

  // ---------------
  // Input pipeline
  // ---------------
  // Selected pipeline output signals as non-arrays
  logic [2:0][WIDTH-1:0] operands_q;
  fpnew_pkg::fp_format_e src_fmt_q;
  fpnew_pkg::fp_format_e src2_fmt_q;
  fpnew_pkg::fp_format_e dst_fmt_q;

  // Input pipeline signals, index i holds signal after i register stages
  logic                  [NUM_FORMATS-1:0][2:0] inp_pipe_is_boxed_q;
  fpnew_pkg::roundmode_e                        inp_pipe_rnd_mode_q;
  fpnew_pkg::operation_e                        inp_pipe_op_q;
  logic                                        inp_pipe_op_mod_q;
  TagType                                       inp_pipe_tag_q;
  logic                                         inp_pipe_mask_q;
  AuxType                                       inp_pipe_aux_q;
  logic                                         inp_pipe_valid_q;
  logic                                         inp_pipe_simd_enable_q;
  logic                                         inp_pipe_dp_enable_q;
  logic                                         inp_pipe_fp4_enable_q;
  fpnew_pkg::int_format_e                       inp_pipe_int_fmt_q;
  // Forward-declared so the DEBUG_INT_DP $display block (further down) can
  // reference them. Drivers and wrapper output connection live near the
  // multiplier instantiation below.
  logic [49:0]            product_int_dp;
  logic                   int_op_qq;
  fpnew_pkg::int_format_e int_fmt_qq;
  logic [3:0]             int_prod_sign_qq;
  logic                   src_is_fp8_qq;
  // Phase F: INT result staging — bit-extracted product, c addend (registered to
  // align with product_int_dp), signed sum, and the registered post-norm result.
  logic [31:0]            operand_c_int_qq;
  logic signed [31:0]     int_dp_extracted_qq;
  logic signed [31:0]     int_after_mul_qq;
  // Post-norm-stage INT signals (driven by the post_norm always_ff/comb below)
  logic                   post_norm_int_op_q;
  logic signed [31:0]     post_norm_int_result_q;

  logic mid_pipe_ready_0;
  logic ready_for_mid_pipe_qq;
  generate
    if (NUM_INP_REGS == 0) begin : gen_input_pipeline_bypass
      transdot_input_pipeline_skip #(
        .WIDTH(WIDTH),
        .NUM_INP_REGS(NUM_INP_REGS),
        .NUM_PIPE_REGS(NumPipeRegs),
        .NUM_FORMATS(NUM_FORMATS),
        .TagType(TagType),
        .AuxType(AuxType)
      ) i_input_pipeline (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .operands_i(operands_i),
        .is_boxed_i(is_boxed_i),
        .rnd_mode_i(rnd_mode_i),
        .op_i(op_i),
        .op_mod_i(op_mod_i),
        .src_fmt_i(src_fmt_i),
        .src2_fmt_i(src2_fmt_i),
        .dst_fmt_i(dst_fmt_i),
        .int_fmt_i(int_fmt_i),
        .tag_i(tag_i),
        .mask_i(mask_i),
        .simd_enable_i(simd_enable_i),
        .dp_enable_i(dp_enable_i),
        .fp4_enable_i(fp4_enable_i),
        .aux_i(aux_i),
        .in_valid_i(in_valid_i),
        .in_ready_o(in_ready_o),
        .reg_ena_i(reg_ena_i),
        .down_ready_i(ready_for_mid_pipe_qq),
        .operands_o(operands_q),
        .is_boxed_o(inp_pipe_is_boxed_q),
        .src_fmt_o(src_fmt_q),
        .src2_fmt_o(src2_fmt_q),
        .dst_fmt_o(dst_fmt_q),
        .int_fmt_o(inp_pipe_int_fmt_q),
        .rnd_mode_o(inp_pipe_rnd_mode_q),
        .op_o(inp_pipe_op_q),
        .op_mod_o(inp_pipe_op_mod_q),
        .tag_o(inp_pipe_tag_q),
        .mask_o(inp_pipe_mask_q),
        .simd_enable_o(inp_pipe_simd_enable_q),
        .dp_enable_o(inp_pipe_dp_enable_q),
        .fp4_enable_o(inp_pipe_fp4_enable_q),
        .aux_o(inp_pipe_aux_q),
        .valid_o(inp_pipe_valid_q)
      );
    end else begin : gen_input_pipeline_regs
      transdot_input_pipeline #(
        .WIDTH(WIDTH),
        .NUM_INP_REGS(NUM_INP_REGS),
        .NUM_PIPE_REGS(NumPipeRegs),
        .NUM_FORMATS(NUM_FORMATS),
        .TagType(TagType),
        .AuxType(AuxType)
      ) i_input_pipeline (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .operands_i(operands_i),
        .is_boxed_i(is_boxed_i),
        .rnd_mode_i(rnd_mode_i),
        .op_i(op_i),
        .op_mod_i(op_mod_i),
        .src_fmt_i(src_fmt_i),
        .src2_fmt_i(src2_fmt_i),
        .dst_fmt_i(dst_fmt_i),
        .int_fmt_i(int_fmt_i),
        .tag_i(tag_i),
        .mask_i(mask_i),
        .simd_enable_i(simd_enable_i),
        .dp_enable_i(dp_enable_i),
        .fp4_enable_i(fp4_enable_i),
        .aux_i(aux_i),
        .in_valid_i(in_valid_i),
        .in_ready_o(in_ready_o),
        .reg_ena_i(reg_ena_i),
        .down_ready_i(ready_for_mid_pipe_qq),
        .operands_o(operands_q),
        .is_boxed_o(inp_pipe_is_boxed_q),
        .src_fmt_o(src_fmt_q),
        .src2_fmt_o(src2_fmt_q),
        .dst_fmt_o(dst_fmt_q),
        .int_fmt_o(inp_pipe_int_fmt_q),
        .rnd_mode_o(inp_pipe_rnd_mode_q),
        .op_o(inp_pipe_op_q),
        .op_mod_o(inp_pipe_op_mod_q),
        .tag_o(inp_pipe_tag_q),
        .mask_o(inp_pipe_mask_q),
        .simd_enable_o(inp_pipe_simd_enable_q),
        .dp_enable_o(inp_pipe_dp_enable_q),
        .fp4_enable_o(inp_pipe_fp4_enable_q),
        .aux_o(inp_pipe_aux_q),
        .valid_o(inp_pipe_valid_q)
      );
    end
  endgenerate
  logic src_is_fp8;
  // FP8 (E4M3), FP8ALT (E5M2), and FP4 all use the 8-b/4-b mantissa-multiplier shape.
  assign src_is_fp8 = (src_fmt_q == fpnew_pkg::FP8) || (src_fmt_q == fpnew_pkg::FP8ALT) || (src_fmt_q == fpnew_pkg::FP4);

  // =========================================================================
  // INT_DP_FMADD operand pre-processing (Phase D — declared, not muxed yet)
  // =========================================================================
  // sign-magnitude extraction per-lane and packing into the FP-mode mantissa
  // input slots. Reuses the wrapper's existing slot geometry (FP8-DP for INT4,
  // FP16-DP for INT8, scalar for INT16). Phase E will mux these into the
  // wrapper inputs gated on int_op_inp.
  logic int_op_inp;
  assign int_op_inp = (inp_pipe_op_q == fpnew_pkg::INT_DP_FMADD);

  // op_mod_i==0 → signed, op_mod_i==1 → unsigned (matches existing INT helper sidecar)
  logic int_signed;
  assign int_signed = ~inp_pipe_op_mod_q;

  // Per-lane sign bits sourced from operand MSBs (for signed); 0 for unsigned.
  // For INT16, only lane 0 is meaningful; for INT8 lanes 0..1; for INT4 lanes 0..3.
  logic [3:0] int_a_sign, int_b_sign;
  always_comb begin
    int_a_sign = '0;
    int_b_sign = '0;
    unique case (inp_pipe_int_fmt_q)
      fpnew_pkg::INT16: begin
        int_a_sign[0] = int_signed & operands_q[0][15];
        int_b_sign[0] = int_signed & operands_q[1][15];
      end
      fpnew_pkg::INT8: begin
        int_a_sign[0] = int_signed & operands_q[0][7];
        int_b_sign[0] = int_signed & operands_q[1][7];
        int_a_sign[1] = int_signed & operands_q[0][15];
        int_b_sign[1] = int_signed & operands_q[1][15];
      end
      fpnew_pkg::INT4: begin
        int_a_sign[0] = int_signed & operands_q[0][3];
        int_b_sign[0] = int_signed & operands_q[1][3];
        int_a_sign[1] = int_signed & operands_q[0][7];
        int_b_sign[1] = int_signed & operands_q[1][7];
        int_a_sign[2] = int_signed & operands_q[0][11];
        int_b_sign[2] = int_signed & operands_q[1][11];
        int_a_sign[3] = int_signed & operands_q[0][15];
        int_b_sign[3] = int_signed & operands_q[1][15];
      end
      default: begin
        int_a_sign = '0;
        int_b_sign = '0;
      end
    endcase
  end

  // Per-lane magnitudes: ~op + 1 if signed-and-negative, else op. The MIN_VAL
  // bit pattern (e.g. 8'h80) reinterpreted as N-bit unsigned is numerically
  // |MIN_VAL|, so no width extension is needed.
  logic [15:0] int16_a_mag, int16_b_mag;
  logic [7:0]  int8_a_mag  [0:1];
  logic [7:0]  int8_b_mag  [0:1];
  logic [3:0]  int4_a_mag  [0:3];
  logic [3:0]  int4_b_mag  [0:3];

  assign int16_a_mag = int_a_sign[0] ? (~operands_q[0][15:0] + 16'd1) : operands_q[0][15:0];
  assign int16_b_mag = int_b_sign[0] ? (~operands_q[1][15:0] + 16'd1) : operands_q[1][15:0];

  for (genvar L = 0; L < 2; L++) begin : g_int8_mag
    assign int8_a_mag[L] = int_a_sign[L] ? (~operands_q[0][L*8 +: 8] + 8'd1)
                                          :  operands_q[0][L*8 +: 8];
    assign int8_b_mag[L] = int_b_sign[L] ? (~operands_q[1][L*8 +: 8] + 8'd1)
                                          :  operands_q[1][L*8 +: 8];
  end

  for (genvar L = 0; L < 4; L++) begin : g_int4_mag
    assign int4_a_mag[L] = int_a_sign[L] ? (~operands_q[0][L*4 +: 4] + 4'd1)
                                          :  operands_q[0][L*4 +: 4];
    assign int4_b_mag[L] = int_b_sign[L] ? (~operands_q[1][L*4 +: 4] + 4'd1)
                                          :  operands_q[1][L*4 +: 4];
  end

  // Per-lane product sign (XOR of operand signs)
  logic [3:0] int_prod_sign;
  for (genvar L = 0; L < 4; L++) begin : g_int_prod_sign
    assign int_prod_sign[L] = int_a_sign[L] ^ int_b_sign[L];
  end

  // INT4 lane magnitude products — replace FP4 path's y_mag in INT mode.
  // (FP4 path computes e2m1 arithmetic in quarter-units; for INT4 we feed the
  //  raw 8-bit unsigned product.)
  // Width-extend operands to 8-bit so the multiply is computed at 8-bit; a
  // 4-bit×4-bit multiply inside a concat context truncates to 4 bits.
  logic [7:0] int4_prod_8b [0:3];
  logic [8:0] int4_y_mag   [0:3];
  for (genvar L = 0; L < 4; L++) begin : g_int4_y_mag
    assign int4_prod_8b[L] = {4'b0, int4_a_mag[L]} * {4'b0, int4_b_mag[L]};
    assign int4_y_mag[L]   = {1'b0, int4_prod_8b[L]};
  end

  // INT-mode mantissa packing — values that would feed the wrapper's mantissa
  // inputs in Phase E. Slots determined by transdot_decomp_multiplier line ~1245:
  //   FP8-DP (INT4): mantissa_a_i[23:20], mantissa_a_simd_i[10:7],
  //                  mantissa_a_fp8_1_i[3:0], mantissa_a_fp8_2_i[3:0]
  //   FP16-DP (INT8): mantissa_a_i[23:13] (11-bit lane 0),
  //                   mantissa_a_simd_i[10:0] (11-bit lane 1)
  //   scalar (INT16): full mantissa_a_i[23:0]
  logic [PRECISION_BITS-1:0]      mantissa_a_int, mantissa_b_int;          // 24-bit
  logic [PRECISION_BITS_SIMD-1:0] mantissa_a_simd_int, mantissa_b_simd_int; // 11-bit
  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_1_int, mantissa_b_fp8_1_int; // 4-bit
  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_2_int, mantissa_b_fp8_2_int; // 4-bit

  always_comb begin
    mantissa_a_int       = '0;
    mantissa_b_int       = '0;
    mantissa_a_simd_int  = '0;
    mantissa_b_simd_int  = '0;
    mantissa_a_fp8_1_int = '0;
    mantissa_b_fp8_1_int = '0;
    mantissa_a_fp8_2_int = '0;
    mantissa_b_fp8_2_int = '0;
    unique case (inp_pipe_int_fmt_q)
      fpnew_pkg::INT16: begin
        mantissa_a_int[15:0] = int16_a_mag;
        mantissa_b_int[15:0] = int16_b_mag;
      end
      fpnew_pkg::INT8: begin
        // lane 0 → mantissa_a_i[23:13] (11-bit slot, 8-bit mag in low 8)
        mantissa_a_int[20:13] = int8_a_mag[0];
        mantissa_b_int[20:13] = int8_b_mag[0];
        // lane 1 → mantissa_a_simd_i[10:0] (11-bit slot)
        mantissa_a_simd_int[7:0] = int8_a_mag[1];
        mantissa_b_simd_int[7:0] = int8_b_mag[1];
      end
      fpnew_pkg::INT4: begin
        // lane 0 → mantissa_a_i[23:20] (4-bit slot)
        mantissa_a_int[23:20] = int4_a_mag[0];
        mantissa_b_int[23:20] = int4_b_mag[0];
        // lane 1 → mantissa_a_simd_i[10:7] (4-bit slot)
        mantissa_a_simd_int[10:7] = int4_a_mag[1];
        mantissa_b_simd_int[10:7] = int4_b_mag[1];
        // lane 2 → mantissa_a_fp8_1_i[3:0] (4-bit slot)
        mantissa_a_fp8_1_int = int4_a_mag[2];
        mantissa_b_fp8_1_int = int4_b_mag[2];
        // lane 3 → mantissa_a_fp8_2_i[3:0] (4-bit slot)
        mantissa_a_fp8_2_int = int4_a_mag[3];
        mantissa_b_fp8_2_int = int4_b_mag[3];
      end
      default: ;  // leave all '0
    endcase
  end

`ifdef DEBUG_INT_DP
  // Verification harness: dumps INT_DP_FMADD-relevant signals as they propagate.
  // The list grows as Phase E/F adds product_int_dp_q / int_after_mul.
  always_ff @(posedge clk_i) begin
    if (inp_pipe_valid_q && int_op_inp) begin
      $display("[DBG_INT_DP] t=%0t  op=%s  src_fmt=%s  int_fmt=%s  dp_en=%0b  fp4_en=%0b  signed=%0b",
               $time, inp_pipe_op_q.name(), src_fmt_q.name(), inp_pipe_int_fmt_q.name(),
               inp_pipe_dp_enable_q, inp_pipe_fp4_enable_q, int_signed);
      $display("[DBG_INT_DP]   operands_q[0]=%h operands_q[1]=%h operands_q[2]=%h",
               operands_q[0], operands_q[1], operands_q[2]);
      $display("[DBG_INT_DP]   a_sign=%b b_sign=%b prod_sign=%b",
               int_a_sign, int_b_sign, int_prod_sign);
      $display("[DBG_INT_DP]   int16: a_mag=%h b_mag=%h",
               int16_a_mag, int16_b_mag);
      $display("[DBG_INT_DP]   int8:  a_mag={%h,%h}  b_mag={%h,%h}",
               int8_a_mag[1], int8_a_mag[0], int8_b_mag[1], int8_b_mag[0]);
      $display("[DBG_INT_DP]   int4:  a_mag={%h,%h,%h,%h}  b_mag={%h,%h,%h,%h}",
               int4_a_mag[3], int4_a_mag[2], int4_a_mag[1], int4_a_mag[0],
               int4_b_mag[3], int4_b_mag[2], int4_b_mag[1], int4_b_mag[0]);
      $display("[DBG_INT_DP]   pack a: m_a=%h m_a_simd=%h m_a_fp8_1=%h m_a_fp8_2=%h",
               mantissa_a_int, mantissa_a_simd_int, mantissa_a_fp8_1_int, mantissa_a_fp8_2_int);
      $display("[DBG_INT_DP]   pack b: m_b=%h m_b_simd=%h m_b_fp8_1=%h m_b_fp8_2=%h",
               mantissa_b_int, mantissa_b_simd_int, mantissa_b_fp8_1_int, mantissa_b_fp8_2_int);
    end
    if (int_op_qq) begin
      $display("[DBG_INT_DP_QQ] t=%0t  int_fmt=%s  prod_sign=%b  src_is_fp8=%0b  product_int_dp=%h",
               $time, int_fmt_qq.name(), int_prod_sign_qq, src_is_fp8_qq, product_int_dp);
      $display("[DBG_INT_DP_QQ]   extracted=%0d (%h)  c=%0d (%h)  after_mul=%0d (%h)",
               int_dp_extracted_qq, int_dp_extracted_qq,
               $signed(operand_c_int_qq), operand_c_int_qq,
               int_after_mul_qq, int_after_mul_qq);
    end
    if (post_norm_int_op_q) begin
      $display("[DBG_INT_DP_POST] t=%0t  post_norm_int_result=%0d (%h)",
               $time, post_norm_int_result_q, post_norm_int_result_q);
    end
  end
`endif

  // -----------------
  // Input processing
  // -----------------
  logic        [NUM_FORMATS-1:0][2:0]                     fmt_sign;
  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS-1:0] fmt_exponent; //e8
  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS-1:0] fmt_mantissa; //m23

  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0][2:0] info_q;

  // FP Input initialization
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : fmt_init_inputs
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      localparam fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::fp_format_e'(fmt);
      logic [2:0][FP_WIDTH-1:0] trimmed_ops;

      // Classify input
      fpnew_classifier #(
        .FpFormat    ( FpFormat ),
        .NumOperands ( 3        )
      ) i_fpnew_classifier (
        .operands_i ( trimmed_ops                            ),
        .is_boxed_i ( '1 ),
        .info_o     ( info_q[fmt]                            )
      );
      for (genvar op = 0; op < 3; op++) begin : gen_operands
        assign trimmed_ops[op]       = operands_q[op][FP_WIDTH-1:0];
        assign fmt_sign[fmt][op]     = operands_q[op][FP_WIDTH-1];
        assign fmt_exponent[fmt][op] = signed'({1'b0, operands_q[op][MAN_BITS+:EXP_BITS]});
        if (fmt == fpnew_pkg::FP8ALT) begin : g_man_fp8alt_pad
          // FP8ALT (E5M2) shares FP8 (E4M3)'s downstream bit layout — pad the
          // 2-b explicit mantissa with one trailing 0 so it occupies the same
          // bit positions as E4M3's 3-b mantissa. No information loss; just
          // means the LSB of the 3-b "effective" mantissa is always 0.
          assign fmt_mantissa[fmt][op] = {info_q[fmt][op].is_normal, operands_q[op][MAN_BITS-1:0], 1'b0} <<
                                         (SUPER_MAN_BITS - MAN_BITS - 1);
        end else begin : g_man_default
          assign fmt_mantissa[fmt][op] = {info_q[fmt][op].is_normal, operands_q[op][MAN_BITS-1:0]} <<
                                         (SUPER_MAN_BITS - MAN_BITS); // move to left of mantissa
        end
      end
    end else begin : inactive_format
      assign info_q[fmt]                 = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  // Start ---  SIMD lane 1 datapath ---
  logic        [2:0][WIDTH/2-1:0] operands_q_simd;
  assign operands_q_simd[0] = operands_q[0][WIDTH-1:WIDTH/2];
  assign operands_q_simd[1] = operands_q[1][WIDTH-1:WIDTH/2];
  assign operands_q_simd[2] = operands_q[2][WIDTH-1:WIDTH/2];

  logic        [NUM_FORMATS-1:0][2:0]      fmt_sign_simd;
  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS_SIMD-1:0] fmt_exponent_simd; //e5
  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS_SIMD-1:0] fmt_mantissa_simd; //m10

  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0][2:0] info_q_simd;

  // FP Input initialization
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : fmt_init_inputs_simd
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (fmt==fpnew_pkg::FP16 || fmt==fpnew_pkg::FP8 || fmt==fpnew_pkg::FP16ALT || fmt==fpnew_pkg::FP8ALT) begin : active_format // FP16 / BF16 / FP8 (E4M3) / FP8ALT (E5M2) ride this SIMD-lane decode
      localparam fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::fp_format_e'(fmt);
      logic [2:0][FP_WIDTH-1:0] trimmed_ops;

      // Classify input
      fpnew_classifier #(
        .FpFormat    ( FpFormat ),
        .NumOperands ( 3        )
      ) i_fpnew_classifier_simd (
        .operands_i ( trimmed_ops                            ),
        .is_boxed_i ( '1 ),
        .info_o     ( info_q_simd[fmt]                            )
      );
      for (genvar op = 0; op < 3; op++) begin : gen_operands
        assign trimmed_ops[op]       = operands_q_simd[op][FP_WIDTH-1:0];
        assign fmt_sign_simd[fmt][op]     = operands_q_simd[op][FP_WIDTH-1];
        assign fmt_exponent_simd[fmt][op] = signed'({1'b0, operands_q_simd[op][MAN_BITS+:EXP_BITS]});
        if (fmt == fpnew_pkg::FP8ALT) begin : g_man_fp8alt_pad
          // E5M2 → pad to FP8 (E4M3) layout in this lane.
          assign fmt_mantissa_simd[fmt][op] = {info_q_simd[fmt][op].is_normal, operands_q_simd[op][MAN_BITS-1:0], 1'b0} <<
                                              (SUPER_MAN_BITS_SIMD - MAN_BITS - 1);
        end else begin : g_man_default
          assign fmt_mantissa_simd[fmt][op] = {info_q_simd[fmt][op].is_normal, operands_q_simd[op][MAN_BITS-1:0]} <<
                                              (SUPER_MAN_BITS_SIMD - MAN_BITS); // move to left of mantissa
        end
      end
    end else begin : inactive_format
      assign info_q_simd[fmt]                 = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign_simd[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent_simd[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa_simd[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end
  // End --- SIMD lane 1 datapath ---

  // Start ---  SIMD lane 2 datapath ---
  logic        [2:0][WIDTH/4-1:0] operands_q_fp8_1;
  assign operands_q_fp8_1[0] = operands_q[0][WIDTH/2-1:WIDTH/4];
  assign operands_q_fp8_1[1] = operands_q[1][WIDTH/2-1:WIDTH/4];
  assign operands_q_fp8_1[2] = operands_q[2][WIDTH/2-1:WIDTH/4];

  logic        [NUM_FORMATS-1:0][2:0]      fmt_sign_fp8_1;
  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS_FP8-1:0] fmt_exponent_fp8_1; //e5
  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS_FP8-1:0] fmt_mantissa_fp8_1; //m3

  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0][2:0] info_q_fp8_1;

  // FP Input initialization
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : fmt_init_inputsfp8_1
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (fmt==fpnew_pkg::FP8 || fmt==fpnew_pkg::FP8ALT) begin : active_format // FP8 (E4M3) and FP8ALT (E5M2) ride this FP8-DP lane decode
      localparam fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::fp_format_e'(fmt);
      logic [2:0][FP_WIDTH-1:0] trimmed_ops;

      // Classify input
      fpnew_classifier #(
        .FpFormat    ( FpFormat ),
        .NumOperands ( 3        )
      ) i_fpnew_classifier_fp8_1 (
        .operands_i ( trimmed_ops                            ),
        .is_boxed_i ( '1 ),
        .info_o     ( info_q_fp8_1[fmt]                            )
      );
      for (genvar op = 0; op < 3; op++) begin : gen_operands
        assign trimmed_ops[op]       = operands_q_fp8_1[op][FP_WIDTH-1:0];
        assign fmt_sign_fp8_1[fmt][op]     = operands_q_fp8_1[op][FP_WIDTH-1];
        assign fmt_exponent_fp8_1[fmt][op] = signed'({1'b0, operands_q_fp8_1[op][MAN_BITS+:EXP_BITS]});
        if (fmt == fpnew_pkg::FP8ALT) begin : g_man_fp8alt_pad
          // E5M2 → pad to FP8 (E4M3) layout in this fp8_1 lane.
          assign fmt_mantissa_fp8_1[fmt][op] = {info_q_fp8_1[fmt][op].is_normal, operands_q_fp8_1[op][MAN_BITS-1:0], 1'b0} <<
                                               (SUPER_MAN_BITS_FP8 - MAN_BITS - 1);
        end else begin : g_man_default
          assign fmt_mantissa_fp8_1[fmt][op] = {info_q_fp8_1[fmt][op].is_normal, operands_q_fp8_1[op][MAN_BITS-1:0]} <<
                                               (SUPER_MAN_BITS_FP8 - MAN_BITS); // move to left of mantissa
        end
      end
    end else begin : inactive_format
      assign info_q_fp8_1[fmt]                 = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign_fp8_1[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent_fp8_1[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa_fp8_1[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  // Start ---  SIMD lane 3 datapath ---
  logic        [2:0][WIDTH/4-1:0] operands_q_fp8_2;
  assign operands_q_fp8_2[0] = operands_q[0][WIDTH-1:WIDTH/4*3];
  assign operands_q_fp8_2[1] = operands_q[1][WIDTH-1:WIDTH/4*3];
  assign operands_q_fp8_2[2] = operands_q[2][WIDTH-1:WIDTH/4*3];

  logic        [NUM_FORMATS-1:0][2:0]      fmt_sign_fp8_2;
  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS_FP8-1:0] fmt_exponent_fp8_2; //e5
  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS_FP8-1:0] fmt_mantissa_fp8_2; //m3

  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0][2:0] info_q_fp8_2;

  // FP Input initialization
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : fmt_init_inputs_fp8_2
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (fmt==fpnew_pkg::FP8 || fmt==fpnew_pkg::FP8ALT) begin : active_format // FP8 (E4M3) and FP8ALT (E5M2) ride this FP8-DP lane decode
      localparam fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::fp_format_e'(fmt);
      logic [2:0][FP_WIDTH-1:0] trimmed_ops;

      // Classify input
      fpnew_classifier #(
        .FpFormat    ( FpFormat ),
        .NumOperands ( 3        )
      ) i_fpnew_classifier_fp8_2 (
        .operands_i ( trimmed_ops                            ),
        .is_boxed_i ( '1 ),
        .info_o     ( info_q_fp8_2[fmt]                            )
      );
      for (genvar op = 0; op < 3; op++) begin : gen_operands
        assign trimmed_ops[op]       = operands_q_fp8_2[op][FP_WIDTH-1:0];
        assign fmt_sign_fp8_2[fmt][op]     = operands_q_fp8_2[op][FP_WIDTH-1];
        assign fmt_exponent_fp8_2[fmt][op] = signed'({1'b0, operands_q_fp8_2[op][MAN_BITS+:EXP_BITS]});
        if (fmt == fpnew_pkg::FP8ALT) begin : g_man_fp8alt_pad
          // E5M2 → pad to FP8 (E4M3) layout in this fp8_2 lane.
          assign fmt_mantissa_fp8_2[fmt][op] = {info_q_fp8_2[fmt][op].is_normal, operands_q_fp8_2[op][MAN_BITS-1:0], 1'b0} <<
                                               (SUPER_MAN_BITS_FP8 - MAN_BITS - 1);
        end else begin : g_man_default
          assign fmt_mantissa_fp8_2[fmt][op] = {info_q_fp8_2[fmt][op].is_normal, operands_q_fp8_2[op][MAN_BITS-1:0]} <<
                                               (SUPER_MAN_BITS_FP8 - MAN_BITS); // move to left of mantissa
        end
      end
    end else begin : inactive_format
      assign info_q_fp8_2[fmt]                 = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign_fp8_2[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent_fp8_2[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa_fp8_2[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  // End ---  SIMD lane 3 datapath --- 
  


  fp_t                 operand_a, operand_b, operand_c;
  fpnew_pkg::fp_info_t info_a,    info_b,    info_c;
 
  fpnew_op_select #(
    .NUM_FORMATS(NUM_FORMATS),
    .SUPER_EXP_BITS(SUPER_EXP_BITS),
    .SUPER_MAN_BITS(SUPER_MAN_BITS)
  ) i_op_select (
    .fmt_sign_i     (fmt_sign),
    .fmt_exponent_i (fmt_exponent),
    .fmt_mantissa_i (fmt_mantissa),
    .info_i         (info_q),

    .src_fmt_i      (src_fmt_q),
    .src2_fmt_i     (src2_fmt_q),
    .op_i           (inp_pipe_op_q),
    .op_mod_i       (inp_pipe_op_mod_q),
    .rnd_mode_i     (inp_pipe_rnd_mode_q),

    .sign_a_o       (operand_a.sign),
    .exp_a_o        (operand_a.exponent),
    .man_a_o        (operand_a.mantissa),
    .sign_b_o       (operand_b.sign),
    .exp_b_o        (operand_b.exponent),
    .man_b_o        (operand_b.mantissa),
    .sign_c_o       (operand_c.sign),
    .exp_c_o        (operand_c.exponent),
    .man_c_o        (operand_c.mantissa),
    .info_a_o       (info_a),
    .info_b_o       (info_b),
    .info_c_o       (info_c)
  );

  // Start ---  SIMD lane 1 datapath ---
  fp_t_simd                 operand_a_simd, operand_b_simd, operand_c_simd;
  fpnew_pkg::fp_info_t info_a_simd,    info_b_simd,    info_c_simd;

  fpnew_op_select #(
    .NUM_FORMATS(NUM_FORMATS),
    .SUPER_EXP_BITS(SUPER_EXP_BITS_SIMD),
    .SUPER_MAN_BITS(SUPER_MAN_BITS_SIMD)
  ) i_op_select_simd (
    .fmt_sign_i     (fmt_sign_simd),
    .fmt_exponent_i (fmt_exponent_simd),
    .fmt_mantissa_i (fmt_mantissa_simd),
    .info_i         (info_q_simd),

    .src_fmt_i      (src_fmt_q),
    .src2_fmt_i     (src2_fmt_q),
    .op_i           (inp_pipe_op_q),
    .op_mod_i       (inp_pipe_op_mod_q),
    .rnd_mode_i     (inp_pipe_rnd_mode_q),

    .sign_a_o       (operand_a_simd.sign),
    .exp_a_o        (operand_a_simd.exponent),
    .man_a_o        (operand_a_simd.mantissa),
    .sign_b_o       (operand_b_simd.sign),
    .exp_b_o        (operand_b_simd.exponent),
    .man_b_o        (operand_b_simd.mantissa),
    .sign_c_o       (operand_c_simd.sign),
    .exp_c_o        (operand_c_simd.exponent),
    .man_c_o        (operand_c_simd.mantissa),
    .info_a_o       (info_a_simd),
    .info_b_o       (info_b_simd),
    .info_c_o       (info_c_simd)
  );

  // Start ---  SIMD lane 2 datapath ---
  fp_t_fp8                 operand_a_fp8_1, operand_b_fp8_1, operand_c_fp8_1;
  fpnew_pkg::fp_info_t info_a_fp8_1,    info_b_fp8_1,    info_c_fp8_1;

  fpnew_op_select #(
    .NUM_FORMATS(NUM_FORMATS),
    .SUPER_EXP_BITS(SUPER_EXP_BITS_FP8),
    .SUPER_MAN_BITS(SUPER_MAN_BITS_FP8)
  ) i_op_select_fp8_1 (
    .fmt_sign_i     (fmt_sign_fp8_1),
    .fmt_exponent_i (fmt_exponent_fp8_1),
    .fmt_mantissa_i (fmt_mantissa_fp8_1),
    .info_i         (info_q_fp8_1),

    .src_fmt_i      (src_fmt_q),
    .src2_fmt_i     (src2_fmt_q),
    .op_i           (inp_pipe_op_q),
    .op_mod_i       (inp_pipe_op_mod_q),
    .rnd_mode_i     (inp_pipe_rnd_mode_q),

    .sign_a_o       (operand_a_fp8_1.sign),
    .exp_a_o        (operand_a_fp8_1.exponent),
    .man_a_o        (operand_a_fp8_1.mantissa),
    .sign_b_o       (operand_b_fp8_1.sign),
    .exp_b_o        (operand_b_fp8_1.exponent),
    .man_b_o        (operand_b_fp8_1.mantissa),
    .sign_c_o       (operand_c_fp8_1.sign),
    .exp_c_o        (operand_c_fp8_1.exponent),
    .man_c_o        (operand_c_fp8_1.mantissa),
    .info_a_o       (info_a_fp8_1),
    .info_b_o       (info_b_fp8_1),
    .info_c_o       (info_c_fp8_1)
  );

  // Start ---  SIMD lane 3 datapath ---
  fp_t_fp8                 operand_a_fp8_2, operand_b_fp8_2, operand_c_fp8_2;
  fpnew_pkg::fp_info_t info_a_fp8_2,    info_b_fp8_2,    info_c_fp8_2;

  fpnew_op_select #(
    .NUM_FORMATS(NUM_FORMATS),
    .SUPER_EXP_BITS(SUPER_EXP_BITS_FP8),
    .SUPER_MAN_BITS(SUPER_MAN_BITS_FP8)
  ) i_op_select_fp8_2 (
    .fmt_sign_i     (fmt_sign_fp8_2),
    .fmt_exponent_i (fmt_exponent_fp8_2),
    .fmt_mantissa_i (fmt_mantissa_fp8_2),
    .info_i         (info_q_fp8_2),

    .src_fmt_i      (src_fmt_q),
    .src2_fmt_i     (src2_fmt_q),
    .op_i           (inp_pipe_op_q),
    .op_mod_i       (inp_pipe_op_mod_q),
    .rnd_mode_i     (inp_pipe_rnd_mode_q),

    .sign_a_o       (operand_a_fp8_2.sign),
    .exp_a_o        (operand_a_fp8_2.exponent),
    .man_a_o        (operand_a_fp8_2.mantissa),
    .sign_b_o       (operand_b_fp8_2.sign),
    .exp_b_o        (operand_b_fp8_2.exponent),
    .man_b_o        (operand_b_fp8_2.mantissa),
    .sign_c_o       (operand_c_fp8_2.sign),
    .exp_c_o        (operand_c_fp8_2.exponent),
    .man_c_o        (operand_c_fp8_2.mantissa),
    .info_a_o       (info_a_fp8_2),
    .info_b_o       (info_b_fp8_2),
    .info_c_o       (info_c_fp8_2)
  );
  // End --- SIMD lane 3 datapath ---

  // ---------------------
  // Input classification
  // ---------------------
  logic any_operand_inf;
  logic any_operand_nan;
  logic signalling_nan;
  logic effective_subtraction;
  logic tentative_sign;

  fpnew_input_classify #(
    .SUPER_EXP_BITS(SUPER_EXP_BITS),
    .SUPER_MAN_BITS(SUPER_MAN_BITS)
  ) i_input_classify (
    .sign_a_i(operand_a.sign),
    .sign_b_i(operand_b.sign),
    .sign_c_i(operand_c.sign),
    .info_a_i(info_a),
    .info_b_i(info_b),
    .info_c_i(info_c),

    .any_operand_inf_o(any_operand_inf),
    .any_operand_nan_o(any_operand_nan),
    .signalling_nan_o(signalling_nan),
    .effective_subtraction_o(effective_subtraction),
    .tentative_sign_o(tentative_sign)
  );

  // Start --- SIMD lane 1 datapath ---
  logic any_operand_inf_simd;
  logic any_operand_nan_simd;
  logic signalling_nan_simd;
  logic effective_subtraction_simd;
  logic tentative_sign_simd;

  fpnew_input_classify #(
    .SUPER_EXP_BITS(SUPER_EXP_BITS_SIMD),
    .SUPER_MAN_BITS(SUPER_MAN_BITS_SIMD)
  ) i_input_classify_simd (
    .sign_a_i(operand_a_simd.sign),
    .sign_b_i(operand_b_simd.sign),
    .sign_c_i(operand_c_simd.sign),
    .info_a_i(info_a_simd),
    .info_b_i(info_b_simd),
    .info_c_i(info_c_simd),

    .any_operand_inf_o(any_operand_inf_simd),
    .any_operand_nan_o(any_operand_nan_simd),
    .signalling_nan_o(signalling_nan_simd),
    .effective_subtraction_o(effective_subtraction_simd),
    .tentative_sign_o(tentative_sign_simd)
  );
  // End --- SIMD lane 1 datapath ---

  // Start --- SIMD lane 2 datapath ---
  logic any_operand_inf_fp8_1;
  logic any_operand_nan_fp8_1;
  logic signalling_nan_fp8_1;
  logic effective_subtraction_fp8_1;
  logic tentative_sign_fp8_1;
  fpnew_input_classify #(
    .SUPER_EXP_BITS(SUPER_EXP_BITS_FP8),
    .SUPER_MAN_BITS(SUPER_MAN_BITS_FP8)
  ) i_input_classify_fp8_1 (
    .sign_a_i(operand_a_fp8_1.sign),
    .sign_b_i(operand_b_fp8_1.sign),
    .sign_c_i(operand_c_fp8_1.sign),
    .info_a_i(info_a_fp8_1),
    .info_b_i(info_b_fp8_1),
    .info_c_i(info_c_fp8_1),

    .any_operand_inf_o(any_operand_inf_fp8_1),
    .any_operand_nan_o(any_operand_nan_fp8_1),
    .signalling_nan_o(signalling_nan_fp8_1),
    .effective_subtraction_o(effective_subtraction_fp8_1),
    .tentative_sign_o(tentative_sign_fp8_1)
  );
  // End --- SIMD lane 2 datapath ---

  // Start --- SIMD lane 3 datapath ---
  logic any_operand_inf_fp8_2;
  logic any_operand_nan_fp8_2;
  logic signalling_nan_fp8_2;
  logic effective_subtraction_fp8_2;
  logic tentative_sign_fp8_2;
  fpnew_input_classify #(
    .SUPER_EXP_BITS(SUPER_EXP_BITS_FP8),
    .SUPER_MAN_BITS(SUPER_MAN_BITS_FP8)
  ) i_input_classify_fp8_2 (
    .sign_a_i(operand_a_fp8_2.sign),
    .sign_b_i(operand_b_fp8_2.sign),
    .sign_c_i(operand_c_fp8_2.sign),
    .info_a_i(info_a_fp8_2),
    .info_b_i(info_b_fp8_2),
    .info_c_i(info_c_fp8_2),

    .any_operand_inf_o(any_operand_inf_fp8_2),
    .any_operand_nan_o(any_operand_nan_fp8_2),
    .signalling_nan_o(signalling_nan_fp8_2),
    .effective_subtraction_o(effective_subtraction_fp8_2),
    .tentative_sign_o(tentative_sign_fp8_2)
  );
  // End --- SIMD lane 3 datapath ---


  // ----------------------
  // Special case handling
  // ----------------------
  logic [WIDTH-1:0]   special_result;
  fpnew_pkg::status_t special_status;
  logic               result_is_special_non_fp4, result_is_special;
  assign result_is_special = inp_pipe_fp4_enable_q ? 1'b0 : result_is_special_non_fp4;

  fpnew_special_results #(
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig)
  ) i_special_results (
    .dst_fmt_i               (dst_fmt_q),

    .sign_a_i                (operand_a.sign),
    .sign_b_i                (operand_b.sign),
    .sign_c_i                (operand_c.sign),

    .info_a_i                (info_a),
    .info_b_i                (info_b),
    .info_c_i                (info_c),

    .any_operand_inf_i       (any_operand_inf),
    .any_operand_nan_i       (any_operand_nan),
    .signalling_nan_i        (signalling_nan),
    .effective_subtraction_i (effective_subtraction),

    .special_result_o        (special_result),
    .special_status_o        (special_status),
    .result_is_special_o     (result_is_special_non_fp4)
  );

  // Start --- SIMD lane 1 datapath ---
  logic [WIDTH-1:0]   special_result_simd;
  fpnew_pkg::status_t special_status_simd;
  logic               result_is_special_simd;

  fpnew_special_results #(
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig)
  ) i_special_results_simd (
    .dst_fmt_i               (dst_fmt_q),

    .sign_a_i                (operand_a_simd.sign),
    .sign_b_i                (operand_b_simd.sign),
    .sign_c_i                (operand_c_simd.sign),

    .info_a_i                (info_a_simd),
    .info_b_i                (info_b_simd),
    .info_c_i                (info_c_simd),
    .any_operand_inf_i       (any_operand_inf_simd),
    .any_operand_nan_i       (any_operand_nan_simd),
    .signalling_nan_i        (signalling_nan_simd),
    .effective_subtraction_i (effective_subtraction_simd),

    .special_result_o        (special_result_simd),
    .special_status_o        (special_status_simd),
    .result_is_special_o     (result_is_special_simd)
  );
  // End --- SIMD lane 1 datapath ---

  // Start --- SIMD lane 2 datapath ---
  logic [WIDTH-1:0]   special_result_fp8_1;
  fpnew_pkg::status_t special_status_fp8_1;
  logic               result_is_special_fp8_1;

  fpnew_special_results #(
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig)
  ) i_special_results_fp8_1 (
    .dst_fmt_i               (dst_fmt_q),

    .sign_a_i                (operand_a_fp8_1.sign),
    .sign_b_i                (operand_b_fp8_1.sign),
    .sign_c_i                (operand_c_fp8_1.sign),

    .info_a_i                (info_a_fp8_1),
    .info_b_i                (info_b_fp8_1),
    .info_c_i                (info_c_fp8_1),
    .any_operand_inf_i       (any_operand_inf_fp8_1),
    .any_operand_nan_i       (any_operand_nan_fp8_1),
    .signalling_nan_i        (signalling_nan_fp8_1),
    .effective_subtraction_i (effective_subtraction_fp8_1),

    .special_result_o        (special_result_fp8_1),
    .special_status_o        (special_status_fp8_1),
    .result_is_special_o     (result_is_special_fp8_1)
  );
  // End --- SIMD lane 2 datapath ---

  // Start --- SIMD lane 3 datapath ---
  logic [WIDTH-1:0]   special_result_fp8_2;
  fpnew_pkg::status_t special_status_fp8_2;
  logic               result_is_special_fp8_2;

  fpnew_special_results #(
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig)
  ) i_special_results_fp8_2 (
    .dst_fmt_i               (dst_fmt_q),

    .sign_a_i                (operand_a_fp8_2.sign),
    .sign_b_i                (operand_b_fp8_2.sign),
    .sign_c_i                (operand_c_fp8_2.sign),

    .info_a_i                (info_a_fp8_2),
    .info_b_i                (info_b_fp8_2),
    .info_c_i                (info_c_fp8_2),
    .any_operand_inf_i       (any_operand_inf_fp8_2),
    .any_operand_nan_i       (any_operand_nan_fp8_2),
    .signalling_nan_i        (signalling_nan_fp8_2),
    .effective_subtraction_i (effective_subtraction_fp8_2),

    .special_result_o        (special_result_fp8_2),
    .special_status_o        (special_status_fp8_2),
    .result_is_special_o     (result_is_special_fp8_2)
  );
  // End --- SIMD lane 3 datapath ---

  // ---------------------------
  // Initial exponent data path
  // ---------------------------
  logic signed [EXP_WIDTH-1:0] exponent_addend, exponent_product, exponent_difference;
  logic signed [EXP_WIDTH-1:0] tentative_exponent_no_dp, tentative_exponent_dp, tentative_exponent;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt,addend_shamt_large,addend_shamt_small;
  logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_normalize_shamt;

  logic signed [EXP_WIDTH_SIMD-1:0] exponent_addend_simd, exponent_product_simd, exponent_difference_simd;
  logic signed [EXP_WIDTH_SIMD-1:0] tentative_exponent_simd;
  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd,addend_shamt_small_simd;
  logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_normalize_shamt_simd;


  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] dp_shamt0, dp_shamt1;


  logic signed [EXP_WIDTH_FP8-1:0] exponent_addend_fp8_1, exponent_product_fp8_1, exponent_difference_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0] tentative_exponent_fp8_1;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_1;
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_1;

  logic signed [EXP_WIDTH_FP8-1:0] exponent_addend_fp8_2, exponent_product_fp8_2, exponent_difference_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0] tentative_exponent_fp8_2;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_2;
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_2;

  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] dp_shamt2, dp_shamt3;


  transdot_decomp_exponent_datapath_fp8 #(
    .EXP_WIDTH(EXP_WIDTH),  // internal exponent width
    .SUPER_EXP_BITS(SUPER_EXP_BITS),  // exponent width of superformat
    .SUPER_MAN_BITS(SUPER_MAN_BITS),  // mantissa width of superformat
    .PRECISION_BITS(PRECISION_BITS),  // mantissa precision bits (e.g., FP64)
    .SHIFT_AMOUNT_WIDTH(SHIFT_AMOUNT_WIDTH),  // must hold up to 3*PRECISION_BITS+4
    .EXP_WIDTH_SIMD(EXP_WIDTH_SIMD),  // internal exponent width
    .SUPER_EXP_BITS_SIMD(SUPER_EXP_BITS_SIMD),  // exponent width of superformat
    .SUPER_MAN_BITS_SIMD(SUPER_MAN_BITS_SIMD),  // mantissa width of superformat
    .PRECISION_BITS_SIMD(PRECISION_BITS_SIMD),  // mantissa precision bits (e.g., FP64)
    .SHIFT_AMOUNT_WIDTH_SIMD(SHIFT_AMOUNT_WIDTH_SIMD),  // must hold up to 3*PRECISION_BITS+4
    .EXP_WIDTH_FP8(EXP_WIDTH_FP8),  // internal exponent width
    .SUPER_EXP_BITS_FP8(SUPER_EXP_BITS_FP8),  // exponent width of superformat
    .SUPER_MAN_BITS_FP8(SUPER_MAN_BITS_FP8),  // mantissa width of superformat
    .PRECISION_BITS_FP8(PRECISION_BITS_FP8),  // mantissa precision
    .SHIFT_AMOUNT_WIDTH_FP8(SHIFT_AMOUNT_WIDTH_FP8)  // must hold up to 3*PRECISION_BITS+4
  ) i_transdot_exponent_datapath(
    .exponent_a_i(operand_a.exponent),
    .exponent_b_i(operand_b.exponent),
    .exponent_c_i(operand_c.exponent),
    .mantissa_c_i(operand_c.mantissa),
    .exponent_a_simd_i(operand_a_simd.exponent),
    .exponent_b_simd_i(operand_b_simd.exponent),
    .exponent_c_simd_i(operand_c_simd.exponent),
    .mantissa_c_simd_i(operand_c_simd.mantissa),
    .exponent_a_fp8_1_i(operand_a_fp8_1.exponent),
    .exponent_b_fp8_1_i(operand_b_fp8_1.exponent),
    .exponent_c_fp8_1_i(operand_c_fp8_1.exponent),
    .mantissa_c_fp8_1_i(operand_c_fp8_1.mantissa),
    .exponent_a_fp8_2_i(operand_a_fp8_2.exponent),
    .exponent_b_fp8_2_i(operand_b_fp8_2.exponent),
    .exponent_c_fp8_2_i(operand_c_fp8_2.exponent),
    .mantissa_c_fp8_2_i(operand_c_fp8_2.mantissa),
    .info_a_i(info_a),
    .info_b_i(info_b),
    .info_c_i(info_c),
    .info_a_simd_i(info_a_simd),
    .info_b_simd_i(info_b_simd),
    .info_c_simd_i(info_c_simd),
    .info_a_fp8_1_i(info_a_fp8_1),
    .info_b_fp8_1_i(info_b_fp8_1),
    .info_c_fp8_1_i(info_c_fp8_1),
    .info_a_fp8_2_i(info_a_fp8_2),
    .info_b_fp8_2_i(info_b_fp8_2),
    .info_c_fp8_2_i(info_c_fp8_2),
    .src_fmt_i(src_fmt_q),
    .src2_fmt_i(src2_fmt_q),
    .dst_fmt_i(dst_fmt_q),
    .dp_enable_i     ( inp_pipe_dp_enable_q ),
    .simd_enable_i   ( inp_pipe_simd_enable_q ),
    .fp4_enable_i   ( inp_pipe_fp4_enable_q ),

    .exponent_addend_o(exponent_addend),
    .exponent_product_o(exponent_product),
    .exponent_difference_o(exponent_difference),
    .tentative_exponent_o(tentative_exponent),
    .addend_shamt_o(addend_shamt),
    .addend_shamt_large_o(addend_shamt_large),
    .addend_shamt_small_o(addend_shamt_small),
    .addend_normalize_shamt_o(addend_normalize_shamt),

    .exponent_addend_simd_o(exponent_addend_simd),
    .exponent_product_simd_o(exponent_product_simd),
    .exponent_difference_simd_o(exponent_difference_simd),
    .tentative_exponent_simd_o(tentative_exponent_simd),
    .addend_shamt_simd_o(addend_shamt_simd),
    .addend_shamt_small_simd_o(addend_shamt_small_simd),
    .addend_normalize_shamt_simd_o(addend_normalize_shamt_simd),

    .exponent_addend_fp8_1_o(exponent_addend_fp8_1),
    .exponent_product_fp8_1_o(exponent_product_fp8_1),
    .exponent_difference_fp8_1_o(exponent_difference_fp8_1),
    .tentative_exponent_fp8_1_o(tentative_exponent_fp8_1),
    .addend_shamt_fp8_1_o(addend_shamt_fp8_1),
    .addend_normalize_shamt_fp8_1_o(addend_normalize_shamt_fp8_1),

    .exponent_addend_fp8_2_o(exponent_addend_fp8_2),
    .exponent_product_fp8_2_o(exponent_product_fp8_2),
    .exponent_difference_fp8_2_o(exponent_difference_fp8_2),
    .tentative_exponent_fp8_2_o(tentative_exponent_fp8_2),
    .addend_shamt_fp8_2_o(addend_shamt_fp8_2),
    .addend_normalize_shamt_fp8_2_o(addend_normalize_shamt_fp8_2),

    .dp_shamt0_o(dp_shamt0),
    .dp_shamt1_o(dp_shamt1),
    .dp_shamt2_o(dp_shamt2),
    .dp_shamt3_o(dp_shamt3)
  );
  // End --- SIMD lane 0123 datapath ---

  


  // ------------------
  // Product data path
  // ------------------
  logic [PRECISION_BITS-1:0]   mantissa_a, mantissa_b, mantissa_c;
  logic [2*PRECISION_BITS-1:0] product;             // the p*p product is 2p bits wide
  logic [3*PRECISION_BITS+3:0] product_shifted_no_dp;
  logic [3*PRECISION_BITS+3:0] product_shifted;     // addends are 3p+4 bit wide (including G/R)
  logic pipe_qq_en;

  // Add implicit bits to mantissae
  assign mantissa_a = {info_a.is_normal, operand_a.mantissa};
  assign mantissa_b = {info_b.is_normal, operand_b.mantissa};
  assign mantissa_c = {info_c.is_normal, operand_c.mantissa};

  // Start --- SIMD lane 1 datapath ---
  logic [PRECISION_BITS_SIMD-1:0]   mantissa_a_simd, mantissa_b_simd, mantissa_c_simd;
  logic [2*PRECISION_BITS_SIMD-1:0] product_simd;             // the p*p product is 2p bits wide
  logic [3*PRECISION_BITS_SIMD+3:0] product_shifted_simd;     // addends are 3p+4 bit wide (including G/R)

  assign mantissa_a_simd = {info_a_simd.is_normal, operand_a_simd.mantissa};
  assign mantissa_b_simd = {info_b_simd.is_normal, operand_b_simd.mantissa};
  assign mantissa_c_simd = {info_c_simd.is_normal, operand_c_simd.mantissa};

  // Start --- SIMD lane 2 datapath ---
  logic [PRECISION_BITS_FP8-1:0]   mantissa_a_fp8_1, mantissa_b_fp8_1, mantissa_c_fp8_1;
  logic [2*PRECISION_BITS_FP8-1:0] product_fp8_1;             // the p*p product is 2p bits wide
  logic [3*PRECISION_BITS_FP8+3:0] product_shifted_fp8_1;     // addends are 3p+4 bit wide (including G/R)

  assign mantissa_a_fp8_1 = {info_a_fp8_1.is_normal, operand_a_fp8_1.mantissa};
  assign mantissa_b_fp8_1 = {info_b_fp8_1.is_normal, operand_b_fp8_1.mantissa};
  assign mantissa_c_fp8_1 = {info_c_fp8_1.is_normal, operand_c_fp8_1.mantissa};

  // Start --- SIMD lane 3 datapath ---
  logic [PRECISION_BITS_FP8-1:0]   mantissa_a_fp8_2, mantissa_b_fp8_2, mantissa_c_fp8_2;
  logic [2*PRECISION_BITS_FP8-1:0] product_fp8_2;             // the p*p product is 2p bits wide
  logic [3*PRECISION_BITS_FP8+3:0] product_shifted_fp8_2;     // addends are 3p+4 bit wide (including G/R)
  // DP-specific product/sign helpers are consumed later unconditionally.
  // Provide declarations here so both FPNew and TransDot multiplier builds compile.
  logic [2*PRECISION_BITS-1:0] product_comb;
  logic [2*PRECISION_BITS-1:0] product_dp_comb;
  logic [2*PRECISION_BITS_SIMD+4:0] product_shifted_dp_post;
  logic [47:0] product_shifted_dp_fp4;
  logic tentative_sign_dp;

  assign mantissa_a_fp8_2 = {info_a_fp8_2.is_normal, operand_a_fp8_2.mantissa};
  assign mantissa_b_fp8_2 = {info_b_fp8_2.is_normal, operand_b_fp8_2.mantissa};
  assign mantissa_c_fp8_2 = {info_c_fp8_2.is_normal, operand_c_fp8_2.mantissa};

  // True C6: combined multiplier + DP datapath.
  logic [8:0] y_mag [0:3];
  logic [3:0] y_sign;
  logic tentative_sign_lane0, tentative_sign_lane1, tentative_sign_lane2, tentative_sign_lane3;

  // Drive FP4 lanes from the post-input-pipeline operands_q (NOT operands_i)
  // so the FP4 path takes the same NumPipeRegs of input-side latency as every
  // other format. Tapping operands_i bypassed the input pipeline and made the
  // FP4 data path 1 cycle shorter, which (since the OBSR scale_pipe and the
  // row skew are sized for the canonical depth) misaligned the OBSR scale
  // cascade by 1 cycle in MX builds.
  transdot_fp4_dp_qtr10 fp4_2_term_dp_lane0 (
    .a0(operands_q[0][3:0]),
    .b0(operands_q[1][3:0]),
    .a1(operands_q[0][7:4]),
    .b1(operands_q[1][7:4]),
    .y_sign(y_sign[0]),
    .y_mag(y_mag[0])  // exact: value = y_mag * 0.25
  );
  transdot_fp4_dp_qtr10 fp4_2_term_dp_lane1 (
    .a0(operands_q[0][11:8]),
    .b0(operands_q[1][11:8]),
    .a1(operands_q[0][15:12]),
    .b1(operands_q[1][15:12]),
    .y_sign(y_sign[1]),
    .y_mag(y_mag[1])  // exact: value = y_mag * 0.25
  );
  transdot_fp4_dp_qtr10 fp4_2_term_dp_lane2 (
    .a0(operands_q[0][19:16]),
    .b0(operands_q[1][19:16]),
    .a1(operands_q[0][23:20]),
    .b1(operands_q[1][23:20]),
    .y_sign(y_sign[2]),
    .y_mag(y_mag[2])  // exact: value = y_mag * 0.25
  );
  transdot_fp4_dp_qtr10 fp4_2_term_dp_lane3 (
    .a0(operands_q[0][27:24]),
    .b0(operands_q[1][27:24]),
    .a1(operands_q[0][31:28]),
    .b1(operands_q[1][31:28]),
    .y_sign(y_sign[3]),
    .y_mag(y_mag[3])  // exact: value = y_mag * 0.25
  );

  assign tentative_sign_lane0 = inp_pipe_fp4_enable_q ? y_sign[0] : tentative_sign;
  assign tentative_sign_lane1 = inp_pipe_fp4_enable_q ? y_sign[1] : tentative_sign_simd;
  assign tentative_sign_lane2 = inp_pipe_fp4_enable_q ? y_sign[2] : tentative_sign_fp8_1;
  assign tentative_sign_lane3 = inp_pipe_fp4_enable_q ? y_sign[3] : tentative_sign_fp8_2;

  // Phase E: per-input mux selects INT operand packing when int_op_inp is set,
  // else passes the FP-path signals through unchanged. shamts forced to zero
  // for INT (no exponent shift). product_int_dp_o (registered via pipe_qq_en
  // inside the wrapper) is exposed as product_int_dp for Phase F.
  // (declarations of product_int_dp / int_*_qq are at the top of the module)

  transdot_decomp_multiplier_w6_direct_outputs #(
    .PRECISION_BITS      ( PRECISION_BITS ),
    .PRECISION_BITS_SIMD ( PRECISION_BITS_SIMD ),
    .PRECISION_BITS_FP8  ( PRECISION_BITS_FP8 )
  ) i_transdot_multiply_dp_combined (
    .clk_i                 ( clk_i ),
    .pipe_en               ( pipe_qq_en ),
    .dp_enable_i           ( inp_pipe_dp_enable_q ),
    .simd_enable_i         ( inp_pipe_simd_enable_q ),
    .fp4_enable_i          ( inp_pipe_fp4_enable_q ),
    .src_is_fp8_i          ( src_is_fp8 ),
    .shamt_lane0_i         ( int_op_inp ? 6'd0 : dp_shamt0[5:0] ),
    .shamt_lane1_i         ( int_op_inp ? 6'd0 : dp_shamt1[5:0] ),
    .shamt_lane2_i         ( int_op_inp ? 5'd0 : dp_shamt2[4:0] ),
    .shamt_lane3_i         ( int_op_inp ? 5'd0 : dp_shamt3[4:0] ),
    .tentative_sign_lane0_i( int_op_inp ? int_prod_sign[0] : tentative_sign_lane0 ),
    .tentative_sign_lane1_i( int_op_inp ? int_prod_sign[1] : tentative_sign_lane1 ),
    .tentative_sign_lane2_i( int_op_inp ? int_prod_sign[2] : tentative_sign_lane2 ),
    .tentative_sign_lane3_i( int_op_inp ? int_prod_sign[3] : tentative_sign_lane3 ),
    .fp4_y_mag0_i          ( int_op_inp ? int4_y_mag[0] : y_mag[0] ),
    .fp4_y_mag1_i          ( int_op_inp ? int4_y_mag[1] : y_mag[1] ),
    .fp4_y_mag2_i          ( int_op_inp ? int4_y_mag[2] : y_mag[2] ),
    .fp4_y_mag3_i          ( int_op_inp ? int4_y_mag[3] : y_mag[3] ),
    .mantissa_a_i          ( int_op_inp ? mantissa_a_int       : mantissa_a ),
    .mantissa_b_i          ( int_op_inp ? mantissa_b_int       : mantissa_b ),
    .mantissa_a_simd_i     ( int_op_inp ? mantissa_a_simd_int  : mantissa_a_simd ),
    .mantissa_b_simd_i     ( int_op_inp ? mantissa_b_simd_int  : mantissa_b_simd ),
    .mantissa_a_fp8_1_i    ( int_op_inp ? mantissa_a_fp8_1_int : mantissa_a_fp8_1 ),
    .mantissa_b_fp8_1_i    ( int_op_inp ? mantissa_b_fp8_1_int : mantissa_b_fp8_1 ),
    .mantissa_a_fp8_2_i    ( int_op_inp ? mantissa_a_fp8_2_int : mantissa_a_fp8_2 ),
    .mantissa_b_fp8_2_i    ( int_op_inp ? mantissa_b_fp8_2_int : mantissa_b_fp8_2 ),
    .product_comb_o        ( product_comb ),
    .product_dp_o          ( product_dp_comb ),
    .tentative_sign_dp_o   ( tentative_sign_dp ),
    .product_int_dp_o      ( product_int_dp )
  );

  // Registered (qq-stage) snapshots for the harness — aligned with product_int_dp.
  always_ff @(posedge clk_i) begin
    if (pipe_qq_en) begin
      int_op_qq        <= int_op_inp;
      int_fmt_qq       <= inp_pipe_int_fmt_q;
      int_prod_sign_qq <= int_prod_sign;
      src_is_fp8_qq    <= src_is_fp8;
      operand_c_int_qq <= operands_q[2];   // INT32 accumulator passes through unchanged
    end
  end

  // Bit-extract the per-format INT product from the wrapper's signed 50-bit
  // final_sum. The window must be wide enough to hold the sum-across-lanes
  // *plus one bit* — for INT8 with 2 lanes max abs sum is +32768, which is
  // 17-bit signed (16-bit signed range only reaches +32767).
  //   INT8  → 17-bit signed at [40:24] (2 lanes)
  //   INT4  → 11-bit signed at [47:37] (4 lanes — max sum ±256 fits)
  //   INT16 → 32-bit unsigned at [31:0]; sign applied externally
  always_comb begin
    unique case (int_fmt_qq)
      fpnew_pkg::INT16: int_dp_extracted_qq = int_prod_sign_qq[0]
                                              ? -$signed({1'b0, product_int_dp[31:0]})
                                              :  $signed({1'b0, product_int_dp[31:0]});
      fpnew_pkg::INT8:  int_dp_extracted_qq = $signed({{15{product_int_dp[40]}},
                                                       product_int_dp[40:24]});
      fpnew_pkg::INT4:  int_dp_extracted_qq = $signed({{21{product_int_dp[47]}},
                                                       product_int_dp[47:37]});
      default:          int_dp_extracted_qq = '0;
    endcase
  end

  assign int_after_mul_qq = int_dp_extracted_qq + $signed(operand_c_int_qq);

  logic signed [EXP_WIDTH-1:0] large_exp_product;
  assign large_exp_product = exponent_product;
  
    // Product is placed into a 3p+4 bit wide vector, padded with 2 bits for round and sticky:
  // | 000...000 | product | RS |
  //  <-  p+2  -> <-  2p -> < 2>
  // End --- SIMD lane 1 datapath ---

  // -----------------
  // Addend data path
  // -----------------
  logic [3*PRECISION_BITS+3:0] addend_after_shift;  // upper 3p+4 bits are needed to go on
  logic [PRECISION_BITS-1:0]   addend_sticky_bits;  // up to p bit of shifted addend are sticky
  logic                        sticky_before_add;   // they are compressed into a single sticky bit
  logic [3*PRECISION_BITS+3:0] addend_shifted;      // addends are 3p+4 bit wide (including G/R)
  logic                        inject_carry_in;     // inject carry for subtractions if needed


  // In parallel, the addend is right-shifted according to the exponent difference. Up to p bits are
  // shifted out and compressed into a sticky bit.
  // BEFORE THE SHIFT:
  // | mantissa_c | 000..000 |
  //  <-    p   -> <- 3p+4 ->
  // AFTER THE SHIFT:
  // | 000..........000 | mantissa_c | 000...............0GR |  sticky bits  |
  //  <- addend_shamt -> <-    p   -> <- 2p+4-addend_shamt -> <-  up to p  ->

  // ------
  // Adder
  // ------
  logic [3*PRECISION_BITS+4:0] sum_pos, sum_neg; // added one bit for the carry
  logic                        sum_carry;        // observe carry bit from positive sum for sign fixing
  logic [3*PRECISION_BITS+3:0] sum;              // discard carry as sum won't overflow
  logic                        final_sign;
  logic tentative_sign_new;
  logic effective_subtraction_new;

  logic tentative_sign_qq;
  logic effective_subtraction_qq;
  logic operand_c_sign_qq;
  always_ff @(posedge clk_i) begin
      tentative_sign_qq <= tentative_sign;
      effective_subtraction_qq <= effective_subtraction;
      operand_c_sign_qq <= operand_c.sign;
  end
  assign tentative_sign_new = inp_pipe_dp_enable_q ? tentative_sign_dp : tentative_sign_qq; 
  assign effective_subtraction_new = inp_pipe_dp_enable_q ? tentative_sign_dp ^ operand_c_sign_qq : effective_subtraction_qq;


  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_dp;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_new;
  logic [EXP_WIDTH-1:0] exponent_difference_new;

  assign addend_shamt_new = addend_shamt;
  assign exponent_difference_new = exponent_difference;

  logic [3*PRECISION_BITS_SIMD+4:0] sum_pos_simd, sum_neg_simd; // added one bit for the carry
  logic                        sum_carry_simd;        // observe carry bit from positive sum for sign fixing
  logic [3*PRECISION_BITS_SIMD+3:0] sum_simd;              // discard carry as sum won't overflow
  logic                        final_sign_simd;

    // Start --- SIMD lane 2 datapath ---
  logic [3*PRECISION_BITS_FP8+4:0] sum_pos_fp8_1, sum_neg_fp8_1; // added one bit for the carry
  logic                        sum_carry_fp8_1;        // observe carry bit from positive sum for sign fixing
  logic [3*PRECISION_BITS_FP8+3:0] sum_fp8_1;              // discard carry as sum won't overflow
  logic                        final_sign_fp8_1;

  // Start --- SIMD lane 3 datapath ---
  logic [3*PRECISION_BITS_FP8+4:0] sum_pos_fp8_2, sum_neg_fp8_2; // added one bit for the carry
  logic                        sum_carry_fp8_2;        // observe carry bit from positive sum for sign fixing
  logic [3*PRECISION_BITS_FP8+3:0] sum_fp8_2;              // discard carry as sum won't overflow
  logic                        final_sign_fp8_2;

  transdot_decomp_addend_datapath_piped_combined_product_dp #(
    .SUPER_MAN_BITS(SUPER_MAN_BITS),
    .PRECISION_BITS(PRECISION_BITS),
    .SHIFT_AMOUNT_WIDTH(SHIFT_AMOUNT_WIDTH),
    .SUPER_MAN_BITS_SIMD(SUPER_MAN_BITS_SIMD),
    .PRECISION_BITS_SIMD(PRECISION_BITS_SIMD),
    .SHIFT_AMOUNT_WIDTH_SIMD(SHIFT_AMOUNT_WIDTH_SIMD),
    .SUPER_MAN_BITS_FP8(SUPER_MAN_BITS_FP8),
    .PRECISION_BITS_FP8(PRECISION_BITS_FP8),
    .SHIFT_AMOUNT_WIDTH_FP8(SHIFT_AMOUNT_WIDTH_FP8)
  ) i_decomp_addend_datapath (
    .clk_i                   ( clk_i ),
    .pipe_en                 ( pipe_qq_en ),
    .dp_enable_i             ( inp_pipe_dp_enable_q ),
    .mantissa_c_i            (mantissa_c),
    .product_comb_i          (product_comb),
    .product_dp_i            (product_dp_comb),
    .addend_shamt_i          (addend_shamt_new),
    .effective_subtraction_i (effective_subtraction_new),
    .tentative_sign_i        (tentative_sign_new),
    .sticky_before_add_o     (sticky_before_add),
    .sum_o                   (sum),
    .final_sign_o            (final_sign),

    .simd_enable_i           (inp_pipe_simd_enable_q),
    .is_fp8                  (src_is_fp8),

    .mantissa_c_simd_i            (mantissa_c_simd),
    .addend_shamt_simd_i          (addend_shamt_simd),
    .effective_subtraction_simd_i (effective_subtraction_simd),
    .tentative_sign_simd_i        (tentative_sign_simd),
    .sticky_before_add_simd_o     (sticky_before_add_simd),
    .sum_simd_o                   (sum_simd),
    .final_sign_simd_o            (final_sign_simd),

    .mantissa_c_fp8_1_i            (mantissa_c_fp8_1),
    .addend_shamt_fp8_1_i          (addend_shamt_fp8_1),
    .effective_subtraction_fp8_1_i (effective_subtraction_fp8_1),
    .tentative_sign_fp8_1_i        (tentative_sign_fp8_1),
    .sticky_before_add_fp8_1_o     (sticky_before_add_fp8_1),
    .sum_fp8_1_o                   (sum_fp8_1),
    .final_sign_fp8_1_o            (final_sign_fp8_1),

    .mantissa_c_fp8_2_i            (mantissa_c_fp8_2),
    .addend_shamt_fp8_2_i          (addend_shamt_fp8_2),
    .effective_subtraction_fp8_2_i (effective_subtraction_fp8_2),
    .tentative_sign_fp8_2_i        (tentative_sign_fp8_2),
    .sticky_before_add_fp8_2_o     (sticky_before_add_fp8_2),
    .sum_fp8_2_o                   (sum_fp8_2),
    .final_sign_fp8_2_o            (final_sign_fp8_2)
  );


  logic [EXP_WIDTH-1:0] exponent_product_qq;
  logic [EXP_WIDTH-1:0] exponent_difference_qq;
  logic [EXP_WIDTH-1:0] tentative_exponent_qq;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_normalize_shamt_qq;
  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_normalize_shamt_simd_qq;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_1_qq;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_2_qq;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shift_amount_large_qq;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shift_amount_small_qq;
  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shift_amount_small_simd_qq;
  fpnew_pkg::fp_format_e dst_fmt_qq;
  fpnew_pkg::roundmode_e rnd_mode_qq;
  logic result_is_special_qq;
  fp_t special_result_qq;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_qq;
  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_qq;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_1_qq;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_2_qq;
  fpnew_pkg::status_t special_status_qq;
  logic simd_enable_qq;
  TagType tag_qq;
  logic mask_qq;
  AuxType aux_qq;

  logic [EXP_WIDTH_SIMD-1:0] exponent_product_simd_qq;
  logic [EXP_WIDTH_SIMD-1:0] exponent_difference_simd_qq;
  logic [EXP_WIDTH_SIMD-1:0] tentative_exponent_simd_qq;
  logic result_is_special_simd_qq;
  fp_t special_result_simd_qq;
  fpnew_pkg::status_t special_status_simd_qq;

  logic [EXP_WIDTH_FP8-1:0] exponent_product_fp8_1_qq;
  logic [EXP_WIDTH_FP8-1:0] exponent_difference_fp8_1_qq;
  logic [EXP_WIDTH_FP8-1:0] tentative_exponent_fp8_1_qq;
  logic result_is_special_fp8_1_qq;
  fp_t special_result_fp8_1_qq;
  fpnew_pkg::status_t special_status_fp8_1_qq;

  logic [EXP_WIDTH_FP8-1:0] exponent_product_fp8_2_qq;
  logic [EXP_WIDTH_FP8-1:0] exponent_difference_fp8_2_qq;
  logic [EXP_WIDTH_FP8-1:0] tentative_exponent_fp8_2_qq;
  logic result_is_special_fp8_2_qq;
  fp_t special_result_fp8_2_qq;
  fpnew_pkg::status_t special_status_fp8_2_qq;

  logic inp_pipe_valid_qq;
  
  assign ready_for_mid_pipe_qq = mid_pipe_ready_0 | ~inp_pipe_valid_qq;
  assign pipe_qq_en = inp_pipe_valid_q && ready_for_mid_pipe_qq;

  always_ff@(posedge clk_i) begin
    if (!rst_ni) begin
      exponent_product_qq       <= '0;
      exponent_difference_qq    <= '0;
      tentative_exponent_qq     <= '0;
      dst_fmt_qq                <= fpnew_pkg::fp_format_e'(0);
      rnd_mode_qq               <= fpnew_pkg::roundmode_e'(0);
      result_is_special_qq      <= 1'b0;
      special_result_qq         <= '0;
      special_status_qq         <= '0;
      simd_enable_qq            <= 1'b0;
      tag_qq                    <= TagType'('0);
      mask_qq                   <= 1'b0;
      aux_qq                    <= AuxType'('0);

      exponent_product_simd_qq       <= '0;
      exponent_difference_simd_qq    <= '0;
      tentative_exponent_simd_qq     <= '0;

      exponent_product_fp8_1_qq       <= '0;
      exponent_difference_fp8_1_qq    <= '0;
      tentative_exponent_fp8_1_qq     <= '0;

      exponent_product_fp8_2_qq       <= '0;
      exponent_difference_fp8_2_qq    <= '0;
      tentative_exponent_fp8_2_qq     <= '0;
      addend_normalize_shamt_qq <= '0;
      addend_normalize_shamt_simd_qq <= '0;
      addend_normalize_shamt_fp8_1_qq <= '0;
      addend_normalize_shamt_fp8_2_qq <= '0;
      addend_shift_amount_large_qq <= '0;
      addend_shift_amount_small_qq <= '0;
      addend_shift_amount_small_simd_qq <= '0;


      addend_shamt_qq <= '0;
      addend_shamt_simd_qq <= '0;
      addend_shamt_fp8_1_qq <= '0;
      addend_shamt_fp8_2_qq <= '0;
    end else if (pipe_qq_en) begin
      exponent_product_qq       <= large_exp_product;
      exponent_difference_qq    <= exponent_difference_new;
      tentative_exponent_qq     <= tentative_exponent;
      dst_fmt_qq                <= dst_fmt_q;
      rnd_mode_qq               <= inp_pipe_rnd_mode_q;
      result_is_special_qq      <= result_is_special;
      special_result_qq         <= special_result;
      special_status_qq         <= special_status;
      simd_enable_qq            <= inp_pipe_simd_enable_q;
      tag_qq                    <= inp_pipe_tag_q;
      mask_qq                   <= inp_pipe_mask_q;
      aux_qq                    <= inp_pipe_aux_q;

      exponent_product_simd_qq       <= exponent_product_simd;
      exponent_difference_simd_qq    <= exponent_difference_simd;
      tentative_exponent_simd_qq     <= tentative_exponent_simd;
      result_is_special_simd_qq      <= result_is_special_simd;
      special_result_simd_qq         <= special_result_simd;
      special_status_simd_qq         <= special_status_simd;

      exponent_product_fp8_1_qq       <= exponent_product_fp8_1;
      exponent_difference_fp8_1_qq    <= exponent_difference_fp8_1;
      tentative_exponent_fp8_1_qq     <= tentative_exponent_fp8_1;
      result_is_special_fp8_1_qq      <= result_is_special_fp8_1;
      special_result_fp8_1_qq         <= special_result_fp8_1;
      special_status_fp8_1_qq         <= special_status_fp8_1;

      exponent_product_fp8_2_qq       <= exponent_product_fp8_2;
      exponent_difference_fp8_2_qq    <= exponent_difference_fp8_2;
      tentative_exponent_fp8_2_qq     <= tentative_exponent_fp8_2;
      result_is_special_fp8_2_qq      <= result_is_special_fp8_2;
      special_result_fp8_2_qq         <= special_result_fp8_2;
      special_status_fp8_2_qq         <= special_status_fp8_2;

      addend_normalize_shamt_qq <= addend_normalize_shamt;
      addend_normalize_shamt_simd_qq <= addend_normalize_shamt_simd;
      addend_normalize_shamt_fp8_1_qq <= addend_normalize_shamt_fp8_1;
      addend_normalize_shamt_fp8_2_qq <= addend_normalize_shamt_fp8_2;

      addend_shift_amount_large_qq <= addend_shamt_large;
      addend_shift_amount_small_qq <= addend_shamt_small;
      addend_shift_amount_small_simd_qq <= addend_shamt_small_simd;

      addend_shamt_qq <= addend_shamt_new;
      addend_shamt_simd_qq <= addend_shamt_simd;
      addend_shamt_fp8_1_qq <= addend_shamt_fp8_1;
      addend_shamt_fp8_2_qq <= addend_shamt_fp8_2;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      inp_pipe_valid_qq <= 1'b0;
    end else if (flush_i) begin
      inp_pipe_valid_qq <= 1'b0;
    end else if (ready_for_mid_pipe_qq) begin
      inp_pipe_valid_qq <= inp_pipe_valid_q;
    end
  end

  // ---------------
  // Internal pipeline
  // ---------------
  // Pipeline output signals as non-arrays
  logic                          effective_subtraction_q;
  logic signed [EXP_WIDTH-1:0]   exponent_product_q;
  logic signed [EXP_WIDTH-1:0]   exponent_difference_q;
  logic signed [EXP_WIDTH-1:0]   tentative_exponent_q;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_q;
  logic                          sticky_before_add_q;
  logic [3*PRECISION_BITS+3:0]   sum_q;
  logic                          final_sign_q;
  fpnew_pkg::fp_format_e         dst_fmt_q2;
  fpnew_pkg::roundmode_e         rnd_mode_q;
  logic                          simd_enable_q;
  logic                          result_is_special_q;
  fp_t                           special_result_q;
  fpnew_pkg::status_t            special_status_q;               
  // Internal pipeline signals, index i holds signal after i register stages
  logic                  [0:NUM_MID_REGS]                         mid_pipe_eff_sub_q;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH-1:0]          mid_pipe_exp_prod_q;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH-1:0]          mid_pipe_exp_diff_q;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH-1:0]          mid_pipe_tent_exp_q;
  logic                  [0:NUM_MID_REGS][SHIFT_AMOUNT_WIDTH-1:0] mid_pipe_add_shamt_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_sticky_q;
  logic                  [0:NUM_MID_REGS][3*PRECISION_BITS+3:0]   mid_pipe_sum_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_final_sign_q;
  fpnew_pkg::roundmode_e [0:NUM_MID_REGS]                         mid_pipe_rnd_mode_q;
  fpnew_pkg::fp_format_e [0:NUM_MID_REGS]                         mid_pipe_dst_fmt_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_res_is_spec_q;
  fp_t                   [0:NUM_MID_REGS]                         mid_pipe_spec_res_q;
  fpnew_pkg::status_t    [0:NUM_MID_REGS]                         mid_pipe_spec_stat_q;
  TagType                [0:NUM_MID_REGS]                         mid_pipe_tag_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_mask_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_simd_enable_q;
  AuxType                [0:NUM_MID_REGS]                         mid_pipe_aux_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_valid_q;
  // INT path mid_pipe (Phase F)
  logic                  [0:NUM_MID_REGS]                         mid_pipe_int_op_q;
  logic signed           [0:NUM_MID_REGS][31:0]                   mid_pipe_int_result_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_MID_REGS] mid_pipe_ready;

  // Input stage: First element of pipeline is taken from upstream logic
  assign mid_pipe_eff_sub_q[0]     = effective_subtraction_new;
  assign mid_pipe_exp_prod_q[0]    = exponent_product_qq;
  assign mid_pipe_exp_diff_q[0]    = exponent_difference_qq;
  assign mid_pipe_tent_exp_q[0]    = tentative_exponent_qq;
  assign mid_pipe_add_shamt_q[0]   = addend_shamt_qq + addend_normalize_shamt_qq;
  assign mid_pipe_sticky_q[0]      = sticky_before_add;
  assign mid_pipe_sum_q[0]         = sum;
  assign mid_pipe_final_sign_q[0]  = final_sign;
  assign mid_pipe_rnd_mode_q[0]    = rnd_mode_qq;
  assign mid_pipe_dst_fmt_q[0]     = dst_fmt_qq;
  assign mid_pipe_res_is_spec_q[0] = result_is_special_qq;
  assign mid_pipe_spec_res_q[0]    = special_result_qq;
  assign mid_pipe_spec_stat_q[0]   = special_status_qq;
  assign mid_pipe_tag_q[0]         = tag_qq;
  assign mid_pipe_mask_q[0]        = mask_qq;
  assign mid_pipe_simd_enable_q[0] = simd_enable_qq;
  assign mid_pipe_aux_q[0]         = aux_qq;
  assign mid_pipe_valid_q[0]       = inp_pipe_valid_qq;
  assign mid_pipe_int_op_q[0]      = int_op_qq;
  assign mid_pipe_int_result_q[0]  = int_after_mul_qq;
  // Input stage: Propagate pipeline ready signal to input pipe
  assign mid_pipe_ready_0 = mid_pipe_ready[0];
  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin : gen_inside_pipeline
    // Internal register enable for this stage
    logic reg_ena;
    // Determine the ready signal of the current stage - advance the pipeline:
    // 1. if the next stage is ready for our data
    // 2. if the next stage only holds a bubble (not valid) -> we can pop it
    assign mid_pipe_ready[i] = mid_pipe_ready[i+1] | ~mid_pipe_valid_q[i+1];
    // Valid: enabled by ready signal, synchronous clear with the flush signal
    `FFLARNC(mid_pipe_valid_q[i+1], mid_pipe_valid_q[i], mid_pipe_ready[i], flush_i, 1'b0, clk_i, rst_ni)
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (mid_pipe_ready[i] & mid_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(mid_pipe_eff_sub_q[i+1],     mid_pipe_eff_sub_q[i],     reg_ena, '0)
    `FFL(mid_pipe_exp_prod_q[i+1],    mid_pipe_exp_prod_q[i],    reg_ena, '0)
    `FFL(mid_pipe_exp_diff_q[i+1],    mid_pipe_exp_diff_q[i],    reg_ena, '0)
    `FFL(mid_pipe_tent_exp_q[i+1],    mid_pipe_tent_exp_q[i],    reg_ena, '0)
    `FFL(mid_pipe_add_shamt_q[i+1],   mid_pipe_add_shamt_q[i],   reg_ena, '0)
    `FFL(mid_pipe_sticky_q[i+1],      mid_pipe_sticky_q[i],      reg_ena, '0)
    `FFL(mid_pipe_sum_q[i+1],         mid_pipe_sum_q[i],         reg_ena, '0)
    `FFL(mid_pipe_final_sign_q[i+1],  mid_pipe_final_sign_q[i],  reg_ena, '0)
    `FFL(mid_pipe_rnd_mode_q[i+1],    mid_pipe_rnd_mode_q[i],    reg_ena, fpnew_pkg::RNE)
    `FFL(mid_pipe_dst_fmt_q[i+1],     mid_pipe_dst_fmt_q[i],     reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(mid_pipe_res_is_spec_q[i+1], mid_pipe_res_is_spec_q[i], reg_ena, '0)
    `FFL(mid_pipe_spec_res_q[i+1],    mid_pipe_spec_res_q[i],    reg_ena, '0)
    `FFL(mid_pipe_spec_stat_q[i+1],   mid_pipe_spec_stat_q[i],   reg_ena, '0)
    `FFL(mid_pipe_tag_q[i+1],         mid_pipe_tag_q[i],         reg_ena, TagType'('0))
    `FFL(mid_pipe_mask_q[i+1],        mid_pipe_mask_q[i],        reg_ena, '0)
    `FFL(mid_pipe_simd_enable_q[i+1], mid_pipe_simd_enable_q[i], reg_ena, '0)
    `FFL(mid_pipe_aux_q[i+1],         mid_pipe_aux_q[i],         reg_ena, AuxType'('0))
    `FFL(mid_pipe_int_op_q[i+1],      mid_pipe_int_op_q[i],      reg_ena, 1'b0)
    `FFL(mid_pipe_int_result_q[i+1],  mid_pipe_int_result_q[i],  reg_ena, '0)
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign effective_subtraction_q = mid_pipe_eff_sub_q[NUM_MID_REGS];
  assign exponent_product_q      = mid_pipe_exp_prod_q[NUM_MID_REGS];
  assign exponent_difference_q   = mid_pipe_exp_diff_q[NUM_MID_REGS];
  assign tentative_exponent_q    = mid_pipe_tent_exp_q[NUM_MID_REGS];
  assign addend_shamt_q          = mid_pipe_add_shamt_q[NUM_MID_REGS];
  assign sticky_before_add_q     = mid_pipe_sticky_q[NUM_MID_REGS];
  assign sum_q                   = mid_pipe_sum_q[NUM_MID_REGS];
  assign final_sign_q            = mid_pipe_final_sign_q[NUM_MID_REGS];
  assign rnd_mode_q              = mid_pipe_rnd_mode_q[NUM_MID_REGS];
  assign simd_enable_q           = mid_pipe_simd_enable_q[NUM_MID_REGS];
  assign dst_fmt_q2              = mid_pipe_dst_fmt_q[NUM_MID_REGS];
  assign result_is_special_q     = mid_pipe_res_is_spec_q[NUM_MID_REGS];
  assign special_result_q        = mid_pipe_spec_res_q[NUM_MID_REGS];
  assign special_status_q        = mid_pipe_spec_stat_q[NUM_MID_REGS];
  logic dst_is_fp8;
  // Start --- SIMD lane 1 datapath ---
  logic                          effective_subtraction_q_simd;
  logic signed [EXP_WIDTH_SIMD-1:0]   exponent_product_q_simd;
  logic signed [EXP_WIDTH_SIMD-1:0]   exponent_difference_q_simd;
  logic signed [EXP_WIDTH_SIMD-1:0]   tentative_exponent_q_simd;
  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_q_simd;
  logic                          sticky_before_add_q_simd;
  logic [3*PRECISION_BITS_SIMD+3:0]   sum_q_simd;
  logic                          final_sign_q_simd;
  logic                          result_is_special_q_simd;
  fp_t                           special_result_q_simd;
  fpnew_pkg::status_t            special_status_q_simd;

  logic                  [0:NUM_MID_REGS]                         mid_pipe_eff_sub_q_simd;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_SIMD-1:0]          mid_pipe_exp_prod_q_simd;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_SIMD-1:0]          mid_pipe_exp_diff_q_simd;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_SIMD-1:0]          mid_pipe_tent_exp_q_simd;
  logic                  [0:NUM_MID_REGS][SHIFT_AMOUNT_WIDTH_SIMD-1:0] mid_pipe_add_shamt_q_simd;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_sticky_q_simd;
  logic                  [0:NUM_MID_REGS][3*PRECISION_BITS_SIMD+3:0]   mid_pipe_sum_q_simd;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_final_sign_q_simd;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_res_is_spec_q_simd;
  fp_t                   [0:NUM_MID_REGS]                         mid_pipe_spec_res_q_simd;
  fpnew_pkg::status_t    [0:NUM_MID_REGS]                         mid_pipe_spec_stat_q_simd;

  assign mid_pipe_eff_sub_q_simd[0]     = effective_subtraction_simd;
  assign mid_pipe_exp_prod_q_simd[0]    = exponent_product_simd_qq;
  assign mid_pipe_exp_diff_q_simd[0]    = exponent_difference_simd_qq;
  assign mid_pipe_tent_exp_q_simd[0]    = tentative_exponent_simd_qq;
  assign mid_pipe_add_shamt_q_simd[0]   = addend_shamt_simd_qq + addend_normalize_shamt_simd_qq;
  assign mid_pipe_sticky_q_simd[0]      = sticky_before_add_simd;
  assign mid_pipe_sum_q_simd[0]         = sum_simd;
  assign mid_pipe_final_sign_q_simd[0]  = final_sign_simd;
  assign mid_pipe_res_is_spec_q_simd[0] = result_is_special_simd_qq;
  assign mid_pipe_spec_res_q_simd[0]    = special_result_simd_qq;
  assign mid_pipe_spec_stat_q_simd[0]   = special_status_simd_qq;

  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin : gen_inside_pipeline_simd
    // Internal register enable for this stage
    logic reg_ena;
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (mid_pipe_ready[i] & mid_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(mid_pipe_eff_sub_q_simd[i+1],     mid_pipe_eff_sub_q_simd[i],     reg_ena, '0)
    `FFL(mid_pipe_exp_prod_q_simd[i+1],    mid_pipe_exp_prod_q_simd[i],    reg_ena, '0)
    `FFL(mid_pipe_exp_diff_q_simd[i+1],    mid_pipe_exp_diff_q_simd[i],    reg_ena, '0)
    `FFL(mid_pipe_tent_exp_q_simd[i+1],    mid_pipe_tent_exp_q_simd[i],    reg_ena, '0)
    `FFL(mid_pipe_add_shamt_q_simd[i+1],   mid_pipe_add_shamt_q_simd[i],   reg_ena, '0)
    `FFL(mid_pipe_sticky_q_simd[i+1],      mid_pipe_sticky_q_simd[i],      reg_ena, '0)
    `FFL(mid_pipe_sum_q_simd[i+1],         mid_pipe_sum_q_simd[i],         reg_ena, '0)
    `FFL(mid_pipe_final_sign_q_simd[i+1],  mid_pipe_final_sign_q_simd[i],  reg_ena, '0)
    `FFL(mid_pipe_res_is_spec_q_simd[i+1], mid_pipe_res_is_spec_q_simd[i], reg_ena, '0)
    `FFL(mid_pipe_spec_res_q_simd[i+1],    mid_pipe_spec_res_q_simd[i],    reg_ena, '0)
    `FFL(mid_pipe_spec_stat_q_simd[i+1],   mid_pipe_spec_stat_q_simd[i],   reg_ena, '0)
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign effective_subtraction_q_simd = mid_pipe_eff_sub_q_simd[NUM_MID_REGS];
  assign exponent_product_q_simd      = mid_pipe_exp_prod_q_simd[NUM_MID_REGS];
  assign exponent_difference_q_simd   = mid_pipe_exp_diff_q_simd[NUM_MID_REGS];
  assign tentative_exponent_q_simd    = mid_pipe_tent_exp_q_simd[NUM_MID_REGS];
  assign addend_shamt_q_simd          = mid_pipe_add_shamt_q_simd[NUM_MID_REGS];
  assign sticky_before_add_q_simd     = mid_pipe_sticky_q_simd[NUM_MID_REGS];
  assign sum_q_simd                   = mid_pipe_sum_q_simd[NUM_MID_REGS];
  assign final_sign_q_simd            = mid_pipe_final_sign_q_simd[NUM_MID_REGS];
  assign result_is_special_q_simd     = mid_pipe_res_is_spec_q_simd[NUM_MID_REGS];
  assign special_result_q_simd        = mid_pipe_spec_res_q_simd[NUM_MID_REGS];
  assign special_status_q_simd        = mid_pipe_spec_stat_q_simd[NUM_MID_REGS];

  // Start --- SIMD lane 2 datapath ---
  logic                          effective_subtraction_q_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0]   exponent_product_q_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0]   exponent_difference_q_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0]   tentative_exponent_q_fp8_1;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_q_fp8_1;
  logic                          sticky_before_add_q_fp8_1;
  logic [3*PRECISION_BITS_FP8+3:0]   sum_q_fp8_1;
  logic                          final_sign_q_fp8_1;
  logic                          result_is_special_q_fp8_1;
  fp_t                           special_result_q_fp8_1;
  fpnew_pkg::status_t            special_status_q_fp8_1;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_eff_sub_q_fp8_1;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_FP8-1:0]          mid_pipe_exp_prod_q_fp8_1;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_FP8-1:0]          mid_pipe_exp_diff_q_fp8_1;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_FP8-1:0]          mid_pipe_tent_exp_q_fp8_1;
  logic                  [0:NUM_MID_REGS][SHIFT_AMOUNT_WIDTH_FP8-1:0] mid_pipe_add_shamt_q_fp8_1;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_sticky_q_fp8_1;
  logic                  [0:NUM_MID_REGS][3*PRECISION_BITS_FP8+3:0]   mid_pipe_sum_q_fp8_1;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_final_sign_q_fp8_1;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_res_is_spec_q_fp8_1;
  fp_t                   [0:NUM_MID_REGS]                         mid_pipe_spec_res_q_fp8_1;
  fpnew_pkg::status_t    [0:NUM_MID_REGS]                         mid_pipe_spec_stat_q_fp8_1;

  assign mid_pipe_eff_sub_q_fp8_1[0]     = effective_subtraction_fp8_1;
  assign mid_pipe_exp_prod_q_fp8_1[0]    = exponent_product_fp8_1_qq;
  assign mid_pipe_exp_diff_q_fp8_1[0]    = exponent_difference_fp8_1_qq;
  assign mid_pipe_tent_exp_q_fp8_1[0]    = tentative_exponent_fp8_1_qq;
  assign mid_pipe_add_shamt_q_fp8_1[0]   = addend_shamt_fp8_1_qq + addend_normalize_shamt_fp8_1_qq;
  assign mid_pipe_sticky_q_fp8_1[0]      = sticky_before_add_fp8_1;
  assign mid_pipe_sum_q_fp8_1[0]         = sum_fp8_1;
  assign mid_pipe_final_sign_q_fp8_1[0]  = final_sign_fp8_1;
  assign mid_pipe_res_is_spec_q_fp8_1[0] = result_is_special_fp8_1_qq;
  assign mid_pipe_spec_res_q_fp8_1[0]    = special_result_fp8_1_qq;
  assign mid_pipe_spec_stat_q_fp8_1[0]   = special_status_fp8_1_qq;

  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin : gen_inside_pipeline_fp8_1
    // Internal register enable for this stage
    logic reg_ena;
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (mid_pipe_ready[i] & mid_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(mid_pipe_eff_sub_q_fp8_1[i+1],     mid_pipe_eff_sub_q_fp8_1[i],     reg_ena, '0)
    `FFL(mid_pipe_exp_prod_q_fp8_1[i+1],    mid_pipe_exp_prod_q_fp8_1[i],    reg_ena, '0)
    `FFL(mid_pipe_exp_diff_q_fp8_1[i+1],    mid_pipe_exp_diff_q_fp8_1[i],    reg_ena, '0)
    `FFL(mid_pipe_tent_exp_q_fp8_1[i+1],    mid_pipe_tent_exp_q_fp8_1[i],    reg_ena, '0)
    `FFL(mid_pipe_add_shamt_q_fp8_1[i+1],   mid_pipe_add_shamt_q_fp8_1[i],   reg_ena, '0)
    `FFL(mid_pipe_sticky_q_fp8_1[i+1],      mid_pipe_sticky_q_fp8_1[i],      reg_ena, '0)
    `FFL(mid_pipe_sum_q_fp8_1[i+1],         mid_pipe_sum_q_fp8_1[i],         reg_ena, '0)
    `FFL(mid_pipe_final_sign_q_fp8_1[i+1],  mid_pipe_final_sign_q_fp8_1[i],  reg_ena, '0)
    `FFL(mid_pipe_res_is_spec_q_fp8_1[i+1], mid_pipe_res_is_spec_q_fp8_1[i], reg_ena, '0)
    `FFL(mid_pipe_spec_res_q_fp8_1[i+1],    mid_pipe_spec_res_q_fp8_1[i],    reg_ena, '0)
    `FFL(mid_pipe_spec_stat_q_fp8_1[i+1],   mid_pipe_spec_stat_q_fp8_1[i],   reg_ena, '0)
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign effective_subtraction_q_fp8_1 = mid_pipe_eff_sub_q_fp8_1[NUM_MID_REGS];
  assign exponent_product_q_fp8_1      = mid_pipe_exp_prod_q_fp8_1[NUM_MID_REGS];
  assign exponent_difference_q_fp8_1   = mid_pipe_exp_diff_q_fp8_1[NUM_MID_REGS];
  assign tentative_exponent_q_fp8_1    = mid_pipe_tent_exp_q_fp8_1[NUM_MID_REGS];
  assign addend_shamt_q_fp8_1          = mid_pipe_add_shamt_q_fp8_1[NUM_MID_REGS];
  assign sticky_before_add_q_fp8_1     = mid_pipe_sticky_q_fp8_1[NUM_MID_REGS];
  assign sum_q_fp8_1                   = mid_pipe_sum_q_fp8_1[NUM_MID_REGS];
  assign final_sign_q_fp8_1            = mid_pipe_final_sign_q_fp8_1[NUM_MID_REGS];
  assign result_is_special_q_fp8_1     = mid_pipe_res_is_spec_q_fp8_1[NUM_MID_REGS];
  assign special_result_q_fp8_1        = mid_pipe_spec_res_q_fp8_1[NUM_MID_REGS];
  assign special_status_q_fp8_1        = mid_pipe_spec_stat_q_fp8_1[NUM_MID_REGS];


  // Start --- SIMD lane 3 datapath ---
  logic                          effective_subtraction_q_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0]   exponent_product_q_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0]   exponent_difference_q_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0]   tentative_exponent_q_fp8_2;
  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_q_fp8_2;
  logic                          sticky_before_add_q_fp8_2;
  logic [3*PRECISION_BITS_FP8+3:0]   sum_q_fp8_2;
  logic                          final_sign_q_fp8_2;
  logic                          result_is_special_q_fp8_2;
  fp_t                           special_result_q_fp8_2;
  fpnew_pkg::status_t            special_status_q_fp8_2;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_eff_sub_q_fp8_2;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_FP8-1:0]          mid_pipe_exp_prod_q_fp8_2;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_FP8-1:0]          mid_pipe_exp_diff_q_fp8_2;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH_FP8-1:0]          mid_pipe_tent_exp_q_fp8_2;
  logic                  [0:NUM_MID_REGS][SHIFT_AMOUNT_WIDTH_FP8-1:0] mid_pipe_add_shamt_q_fp8_2;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_sticky_q_fp8_2;
  logic                  [0:NUM_MID_REGS][3*PRECISION_BITS_FP8+3:0]   mid_pipe_sum_q_fp8_2;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_final_sign_q_fp8_2;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_res_is_spec_q_fp8_2;
  fp_t                   [0:NUM_MID_REGS]                         mid_pipe_spec_res_q_fp8_2;
  fpnew_pkg::status_t    [0:NUM_MID_REGS]                         mid_pipe_spec_stat_q_fp8_2;

  assign mid_pipe_eff_sub_q_fp8_2[0]     = effective_subtraction_fp8_2;
  assign mid_pipe_exp_prod_q_fp8_2[0]    = exponent_product_fp8_2_qq;
  assign mid_pipe_exp_diff_q_fp8_2[0]    = exponent_difference_fp8_2_qq;
  assign mid_pipe_tent_exp_q_fp8_2[0]    = tentative_exponent_fp8_2_qq;
  assign mid_pipe_add_shamt_q_fp8_2[0]   = addend_shamt_fp8_2_qq + addend_normalize_shamt_fp8_2_qq;
  assign mid_pipe_sticky_q_fp8_2[0]      = sticky_before_add_fp8_2;
  assign mid_pipe_sum_q_fp8_2[0]         = sum_fp8_2;
  assign mid_pipe_final_sign_q_fp8_2[0]  = final_sign_fp8_2;
  assign mid_pipe_res_is_spec_q_fp8_2[0] = result_is_special_fp8_2_qq;
  assign mid_pipe_spec_res_q_fp8_2[0]    = special_result_fp8_2_qq;
  assign mid_pipe_spec_stat_q_fp8_2[0]   = special_status_fp8_2_qq;

  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin : gen_inside_pipeline_fp8_2
    // Internal register enable for this stage
    logic reg_ena;
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (mid_pipe_ready[i] & mid_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(mid_pipe_eff_sub_q_fp8_2[i+1],     mid_pipe_eff_sub_q_fp8_2[i],     reg_ena, '0)
    `FFL(mid_pipe_exp_prod_q_fp8_2[i+1],    mid_pipe_exp_prod_q_fp8_2[i],    reg_ena, '0)
    `FFL(mid_pipe_exp_diff_q_fp8_2[i+1],    mid_pipe_exp_diff_q_fp8_2[i],    reg_ena, '0)
    `FFL(mid_pipe_tent_exp_q_fp8_2[i+1],    mid_pipe_tent_exp_q_fp8_2[i],    reg_ena, '0)
    `FFL(mid_pipe_add_shamt_q_fp8_2[i+1],   mid_pipe_add_shamt_q_fp8_2[i],   reg_ena, '0)
    `FFL(mid_pipe_sticky_q_fp8_2[i+1],      mid_pipe_sticky_q_fp8_2[i],      reg_ena, '0)
    `FFL(mid_pipe_sum_q_fp8_2[i+1],         mid_pipe_sum_q_fp8_2[i],         reg_ena, '0)
    `FFL(mid_pipe_final_sign_q_fp8_2[i+1],  mid_pipe_final_sign_q_fp8_2[i],  reg_ena, '0)
    `FFL(mid_pipe_res_is_spec_q_fp8_2[i+1], mid_pipe_res_is_spec_q_fp8_2[i], reg_ena, '0)
    `FFL(mid_pipe_spec_res_q_fp8_2[i+1],    mid_pipe_spec_res_q_fp8_2[i],    reg_ena, '0)
    `FFL(mid_pipe_spec_stat_q_fp8_2[i+1],   mid_pipe_spec_stat_q_fp8_2[i],   reg_ena, '0)
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign effective_subtraction_q_fp8_2 = mid_pipe_eff_sub_q_fp8_2[NUM_MID_REGS];
  assign exponent_product_q_fp8_2      = mid_pipe_exp_prod_q_fp8_2[NUM_MID_REGS];
  assign exponent_difference_q_fp8_2   = mid_pipe_exp_diff_q_fp8_2[NUM_MID_REGS];
  assign tentative_exponent_q_fp8_2    = mid_pipe_tent_exp_q_fp8_2[NUM_MID_REGS];
  assign addend_shamt_q_fp8_2          = mid_pipe_add_shamt_q_fp8_2[NUM_MID_REGS];
  assign sticky_before_add_q_fp8_2     = mid_pipe_sticky_q_fp8_2[NUM_MID_REGS];
  assign sum_q_fp8_2                   = mid_pipe_sum_q_fp8_2[NUM_MID_REGS];
  assign final_sign_q_fp8_2            = mid_pipe_final_sign_q_fp8_2[NUM_MID_REGS];
  assign result_is_special_q_fp8_2     = mid_pipe_res_is_spec_q_fp8_2[NUM_MID_REGS];
  assign special_result_q_fp8_2        = mid_pipe_spec_res_q_fp8_2[NUM_MID_REGS];
  assign special_status_q_fp8_2        = mid_pipe_spec_stat_q_fp8_2[NUM_MID_REGS];

  // --------------
  // Normalization
  // --------------

  logic        [SHIFT_AMOUNT_WIDTH-1:0] norm_shamt; // Normalization shift amount
  logic signed [EXP_WIDTH-1:0]          normalized_exponent;

  logic [PRECISION_BITS:0]     final_mantissa;    // final mantissa before rounding with round bit
  logic [2*PRECISION_BITS+2:0] sum_sticky_bits;   // remaining 2p+3 sticky bits after normalization
  logic                        sticky_after_norm; // sticky bit after normalization

  logic signed [EXP_WIDTH-1:0] final_exponent;

  // Start --- SIMD lane 1 datapath ---
  logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] norm_shamt_simd; // Normalization shift amount
  logic signed [EXP_WIDTH_SIMD-1:0]          normalized_exponent_simd;
  logic [PRECISION_BITS_SIMD:0]     final_mantissa_simd;    // final mantissa before rounding with round bit
  logic [2*PRECISION_BITS_SIMD+2:0] sum_sticky_bits_simd;   // remaining 2p+3 sticky bits after normalization
  logic                        sticky_after_norm_simd; // sticky bit after normalization
  logic signed [EXP_WIDTH_SIMD-1:0] final_exponent_simd;

  // Start --- SIMD lane 2 datapath ---
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] norm_shamt_fp8_1; // Normalization shift amount
  logic signed [EXP_WIDTH_FP8-1:0]          normalized_exponent_fp8_1;
  logic [PRECISION_BITS_FP8:0]     final_mantissa_fp8_1;    // final mantissa before rounding with round bit
  logic [2*PRECISION_BITS_FP8+2:0] sum_sticky_bits_fp8_1;   // remaining 2p+3 sticky bits after normalization
  logic                        sticky_after_norm_fp8_1; // sticky bit after normalization
  logic signed [EXP_WIDTH_FP8-1:0] final_exponent_fp8_1;

  // Start --- SIMD lane 3 datapath ---
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] norm_shamt_fp8_2; // Normalization shift amount
  logic signed [EXP_WIDTH_FP8-1:0]          normalized_exponent_fp8_2;
  logic [PRECISION_BITS_FP8:0]     final_mantissa_fp8_2;    // final mantissa before rounding with round bit
  logic [2*PRECISION_BITS_FP8+2:0] sum_sticky_bits_fp8_2;   // remaining 2p+3 sticky bits after normalization
  logic                        sticky_after_norm_fp8_2; // sticky bit after normalization
  logic signed [EXP_WIDTH_FP8-1:0] final_exponent_fp8_2;
  transdot_decomp_normalize_datapath #(
    .EXP_WIDTH(EXP_WIDTH),
    .PRECISION_BITS(PRECISION_BITS),
    .LOWER_SUM_WIDTH(2*PRECISION_BITS + 3),
    .SHIFT_AMOUNT_WIDTH(SHIFT_AMOUNT_WIDTH),
    .EXP_WIDTH_SIMD(EXP_WIDTH_SIMD),
    .PRECISION_BITS_SIMD(PRECISION_BITS_SIMD),
    .LOWER_SUM_WIDTH_SIMD(2*PRECISION_BITS_SIMD + 3),
    .SHIFT_AMOUNT_WIDTH_SIMD(SHIFT_AMOUNT_WIDTH_SIMD),
    .EXP_WIDTH_FP8(EXP_WIDTH_FP8),
    .PRECISION_BITS_FP8(PRECISION_BITS_FP8),
    .LOWER_SUM_WIDTH_FP8(2*PRECISION_BITS_FP8 + 3),
    .SHIFT_AMOUNT_WIDTH_FP8(SHIFT_AMOUNT_WIDTH_FP8)
  ) i_transdot_normalization_stage (
    .simd_enable_i         (simd_enable_q),
    .is_fp8                ((dst_fmt_q2 == fpnew_pkg::FP8) || (dst_fmt_q2 == fpnew_pkg::FP8ALT)),
    .sum_i                 (sum_q),
    .exponent_product_i    (exponent_product_q),
    .exponent_difference_i (exponent_difference_q),
    .tentative_exponent_i  (tentative_exponent_q),
    .addend_shamt_i        (addend_shamt_q),
    .effective_subtraction_i (effective_subtraction_q),
    .sticky_before_add_i   (sticky_before_add_q),

    .sum_simd_i                 (sum_q_simd),
    .exponent_product_simd_i    (exponent_product_q_simd),
    .exponent_difference_simd_i (exponent_difference_q_simd),
    .tentative_exponent_simd_i  (tentative_exponent_q_simd),
    .addend_shamt_simd_i        (addend_shamt_q_simd),
    .effective_subtraction_simd_i (effective_subtraction_q_simd),
    .sticky_before_add_simd_i   (sticky_before_add_q_simd),

    .sum_fp8_1_i                 (sum_q_fp8_1),
    .exponent_product_fp8_1_i    (exponent_product_q_fp8_1),
    .exponent_difference_fp8_1_i (exponent_difference_q_fp8_1),
    .tentative_exponent_fp8_1_i  (tentative_exponent_q_fp8_1),
    .addend_shamt_fp8_1_i        (addend_shamt_q_fp8_1),
    .effective_subtraction_fp8_1_i (effective_subtraction_q_fp8_1),
    .sticky_before_add_fp8_1_i   (sticky_before_add_q_fp8_1),

    .sum_fp8_2_i                 (sum_q_fp8_2),
    .exponent_product_fp8_2_i    (exponent_product_q_fp8_2),
    .exponent_difference_fp8_2_i (exponent_difference_q_fp8_2),
    .tentative_exponent_fp8_2_i  (tentative_exponent_q_fp8_2),
    .addend_shamt_fp8_2_i        (addend_shamt_q_fp8_2),
    .effective_subtraction_fp8_2_i (effective_subtraction_q_fp8_2),
    .sticky_before_add_fp8_2_i   (sticky_before_add_q_fp8_2),

    .final_mantissa_o      (final_mantissa),
    .final_exponent_o      (final_exponent),
    .sticky_after_norm_o   (sticky_after_norm),
    .norm_shamt_o          (norm_shamt),
    .normalized_exponent_o (normalized_exponent),
    .sum_sticky_bits_o     (sum_sticky_bits),

    .final_mantissa_simd_o      (final_mantissa_simd),
    .final_exponent_simd_o      (final_exponent_simd),
    .sticky_after_norm_simd_o   (sticky_after_norm_simd),
    .norm_shamt_simd_o          (norm_shamt_simd),
    .normalized_exponent_simd_o (normalized_exponent_simd),
    .sum_sticky_bits_simd_o     (sum_sticky_bits_simd),

    .final_mantissa_fp8_1_o      (final_mantissa_fp8_1),
    .final_exponent_fp8_1_o      (final_exponent_fp8_1),
    .sticky_after_norm_fp8_1_o   (sticky_after_norm_fp8_1),
    .norm_shamt_fp8_1_o          (norm_shamt_fp8_1),
    .normalized_exponent_fp8_1_o (normalized_exponent_fp8_1),
    .sum_sticky_bits_fp8_1_o     (sum_sticky_bits_fp8_1),

    .final_mantissa_fp8_2_o      (final_mantissa_fp8_2),
    .final_exponent_fp8_2_o      (final_exponent_fp8_2),
    .sticky_after_norm_fp8_2_o   (sticky_after_norm_fp8_2),
    .norm_shamt_fp8_2_o          (norm_shamt_fp8_2),
    .normalized_exponent_fp8_2_o (normalized_exponent_fp8_2),
    .sum_sticky_bits_fp8_2_o     (sum_sticky_bits_fp8_2)
  );
  // End --- SIMD lane 1 datapath ---

  logic [PRECISION_BITS:0]     final_mantissa_post_q;
  logic [2*PRECISION_BITS+2:0] sum_sticky_bits_post_q;
  logic signed [EXP_WIDTH-1:0] final_exponent_post_q;
  logic                        sticky_after_norm_post_q;
  logic                        final_sign_post_q;
  logic                        effective_subtraction_post_q;
  fpnew_pkg::roundmode_e       rnd_mode_post_q;
  fpnew_pkg::fp_format_e       dst_fmt_post_q;
  logic                        simd_enable_post_q;
  logic                        result_is_special_post_q;
  fp_t                         special_result_post_q;
  fpnew_pkg::status_t          special_status_post_q;
  // (post_norm_int_op_q / post_norm_int_result_q forward-declared at module top.)

  logic [PRECISION_BITS_SIMD:0]     final_mantissa_post_q_simd;
  logic [2*PRECISION_BITS_SIMD+2:0] sum_sticky_bits_post_q_simd;
  logic signed [EXP_WIDTH_SIMD-1:0] final_exponent_post_q_simd;
  logic                             sticky_after_norm_post_q_simd;
  logic                             final_sign_post_q_simd;
  logic                             effective_subtraction_post_q_simd;
  logic                             result_is_special_post_q_simd;
  fp_t                              special_result_post_q_simd;
  fpnew_pkg::status_t               special_status_post_q_simd;

  logic [PRECISION_BITS_FP8:0]     final_mantissa_post_q_fp8_1;
  logic [2*PRECISION_BITS_FP8+2:0] sum_sticky_bits_post_q_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0] final_exponent_post_q_fp8_1;
  logic                            sticky_after_norm_post_q_fp8_1;
  logic                            final_sign_post_q_fp8_1;
  logic                            effective_subtraction_post_q_fp8_1;
  logic                            result_is_special_post_q_fp8_1;
  fp_t                             special_result_post_q_fp8_1;
  fpnew_pkg::status_t              special_status_post_q_fp8_1;

  logic [PRECISION_BITS_FP8:0]     final_mantissa_post_q_fp8_2;
  logic [2*PRECISION_BITS_FP8+2:0] sum_sticky_bits_post_q_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0] final_exponent_post_q_fp8_2;
  logic                            sticky_after_norm_post_q_fp8_2;
  logic                            final_sign_post_q_fp8_2;
  logic                            effective_subtraction_post_q_fp8_2;
  logic                            result_is_special_post_q_fp8_2;
  fp_t                             special_result_post_q_fp8_2;
  fpnew_pkg::status_t              special_status_post_q_fp8_2;

  TagType post_norm_tag_q;
  logic   post_norm_mask_q;
  AuxType post_norm_aux_q;
  logic   post_norm_valid_q;
  logic   post_norm_pipe_en;
  logic   ready_for_post_norm_pipe;
  logic   out_pipe_ready_0;

  generate
    if (NUM_POST_NORM_REGS > 0) begin : gen_post_norm_pipe
      assign ready_for_post_norm_pipe = out_pipe_ready_0 | ~post_norm_valid_q;
      assign post_norm_pipe_en = mid_pipe_valid_q[NUM_MID_REGS] && ready_for_post_norm_pipe;

      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          final_mantissa_post_q          <= '0;
          sum_sticky_bits_post_q         <= '0;
          final_exponent_post_q          <= '0;
          sticky_after_norm_post_q       <= 1'b0;
          final_sign_post_q              <= 1'b0;
          effective_subtraction_post_q   <= 1'b0;
          rnd_mode_post_q                <= fpnew_pkg::roundmode_e'(0);
          dst_fmt_post_q                 <= fpnew_pkg::fp_format_e'(0);
          simd_enable_post_q             <= 1'b0;
          result_is_special_post_q       <= 1'b0;
          special_result_post_q          <= '0;
          special_status_post_q          <= '0;

          final_mantissa_post_q_simd        <= '0;
          sum_sticky_bits_post_q_simd       <= '0;
          final_exponent_post_q_simd        <= '0;
          sticky_after_norm_post_q_simd     <= 1'b0;
          final_sign_post_q_simd            <= 1'b0;
          effective_subtraction_post_q_simd <= 1'b0;
          result_is_special_post_q_simd     <= 1'b0;
          special_result_post_q_simd        <= '0;
          special_status_post_q_simd        <= '0;

          final_mantissa_post_q_fp8_1        <= '0;
          sum_sticky_bits_post_q_fp8_1       <= '0;
          final_exponent_post_q_fp8_1        <= '0;
          sticky_after_norm_post_q_fp8_1     <= 1'b0;
          final_sign_post_q_fp8_1            <= 1'b0;
          effective_subtraction_post_q_fp8_1 <= 1'b0;
          result_is_special_post_q_fp8_1     <= 1'b0;
          special_result_post_q_fp8_1        <= '0;
          special_status_post_q_fp8_1        <= '0;

          final_mantissa_post_q_fp8_2        <= '0;
          sum_sticky_bits_post_q_fp8_2       <= '0;
          final_exponent_post_q_fp8_2        <= '0;
          sticky_after_norm_post_q_fp8_2     <= 1'b0;
          final_sign_post_q_fp8_2            <= 1'b0;
          effective_subtraction_post_q_fp8_2 <= 1'b0;
          result_is_special_post_q_fp8_2     <= 1'b0;
          special_result_post_q_fp8_2        <= '0;
          special_status_post_q_fp8_2        <= '0;

          post_norm_tag_q                 <= TagType'('0);
          post_norm_mask_q                <= 1'b0;
          post_norm_aux_q                 <= AuxType'('0);
          post_norm_int_op_q              <= 1'b0;
          post_norm_int_result_q          <= '0;
        end else if (post_norm_pipe_en) begin
          final_mantissa_post_q          <= final_mantissa;
          sum_sticky_bits_post_q         <= sum_sticky_bits;
          final_exponent_post_q          <= final_exponent;
          sticky_after_norm_post_q       <= sticky_after_norm;
          final_sign_post_q              <= final_sign_q;
          effective_subtraction_post_q   <= effective_subtraction_q;
          rnd_mode_post_q                <= rnd_mode_q;
          dst_fmt_post_q                 <= dst_fmt_q2;
          simd_enable_post_q             <= simd_enable_q;
          result_is_special_post_q       <= result_is_special_q;
          special_result_post_q          <= special_result_q;
          special_status_post_q          <= special_status_q;

          final_mantissa_post_q_simd        <= final_mantissa_simd;
          sum_sticky_bits_post_q_simd       <= sum_sticky_bits_simd;
          final_exponent_post_q_simd        <= final_exponent_simd;
          sticky_after_norm_post_q_simd     <= sticky_after_norm_simd;
          final_sign_post_q_simd            <= final_sign_q_simd;
          effective_subtraction_post_q_simd <= effective_subtraction_q_simd;
          result_is_special_post_q_simd     <= result_is_special_q_simd;
          special_result_post_q_simd        <= special_result_q_simd;
          special_status_post_q_simd        <= special_status_q_simd;

          final_mantissa_post_q_fp8_1        <= final_mantissa_fp8_1;
          sum_sticky_bits_post_q_fp8_1       <= sum_sticky_bits_fp8_1;
          final_exponent_post_q_fp8_1        <= final_exponent_fp8_1;
          sticky_after_norm_post_q_fp8_1     <= sticky_after_norm_fp8_1;
          final_sign_post_q_fp8_1            <= final_sign_q_fp8_1;
          effective_subtraction_post_q_fp8_1 <= effective_subtraction_q_fp8_1;
          result_is_special_post_q_fp8_1     <= result_is_special_q_fp8_1;
          special_result_post_q_fp8_1        <= special_result_q_fp8_1;
          special_status_post_q_fp8_1        <= special_status_q_fp8_1;

          final_mantissa_post_q_fp8_2        <= final_mantissa_fp8_2;
          sum_sticky_bits_post_q_fp8_2       <= sum_sticky_bits_fp8_2;
          final_exponent_post_q_fp8_2        <= final_exponent_fp8_2;
          sticky_after_norm_post_q_fp8_2     <= sticky_after_norm_fp8_2;
          final_sign_post_q_fp8_2            <= final_sign_q_fp8_2;
          effective_subtraction_post_q_fp8_2 <= effective_subtraction_q_fp8_2;
          result_is_special_post_q_fp8_2     <= result_is_special_q_fp8_2;
          special_result_post_q_fp8_2        <= special_result_q_fp8_2;
          special_status_post_q_fp8_2        <= special_status_q_fp8_2;

          post_norm_tag_q                 <= mid_pipe_tag_q[NUM_MID_REGS];
          post_norm_mask_q                <= mid_pipe_mask_q[NUM_MID_REGS];
          post_norm_aux_q                 <= mid_pipe_aux_q[NUM_MID_REGS];
          post_norm_int_op_q              <= mid_pipe_int_op_q[NUM_MID_REGS];
          post_norm_int_result_q          <= mid_pipe_int_result_q[NUM_MID_REGS];
        end
      end

      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          post_norm_valid_q <= 1'b0;
        end else if (flush_i) begin
          post_norm_valid_q <= 1'b0;
        end else if (ready_for_post_norm_pipe) begin
          post_norm_valid_q <= mid_pipe_valid_q[NUM_MID_REGS];
        end
      end
    end else begin : gen_post_norm_bypass
      assign ready_for_post_norm_pipe = out_pipe_ready_0;
      assign post_norm_pipe_en = 1'b0;

      always_comb begin
        final_mantissa_post_q          = final_mantissa;
        sum_sticky_bits_post_q         = sum_sticky_bits;
        final_exponent_post_q          = final_exponent;
        sticky_after_norm_post_q       = sticky_after_norm;
        final_sign_post_q              = final_sign_q;
        effective_subtraction_post_q   = effective_subtraction_q;
        rnd_mode_post_q                = rnd_mode_q;
        dst_fmt_post_q                 = dst_fmt_q2;
        simd_enable_post_q             = simd_enable_q;
        result_is_special_post_q       = result_is_special_q;
        special_result_post_q          = special_result_q;
        special_status_post_q          = special_status_q;

        final_mantissa_post_q_simd        = final_mantissa_simd;
        sum_sticky_bits_post_q_simd       = sum_sticky_bits_simd;
        final_exponent_post_q_simd        = final_exponent_simd;
        sticky_after_norm_post_q_simd     = sticky_after_norm_simd;
        final_sign_post_q_simd            = final_sign_q_simd;
        effective_subtraction_post_q_simd = effective_subtraction_q_simd;
        result_is_special_post_q_simd     = result_is_special_q_simd;
        special_result_post_q_simd        = special_result_q_simd;
        special_status_post_q_simd        = special_status_q_simd;

        final_mantissa_post_q_fp8_1        = final_mantissa_fp8_1;
        sum_sticky_bits_post_q_fp8_1       = sum_sticky_bits_fp8_1;
        final_exponent_post_q_fp8_1        = final_exponent_fp8_1;
        sticky_after_norm_post_q_fp8_1     = sticky_after_norm_fp8_1;
        final_sign_post_q_fp8_1            = final_sign_q_fp8_1;
        effective_subtraction_post_q_fp8_1 = effective_subtraction_q_fp8_1;
        result_is_special_post_q_fp8_1     = result_is_special_q_fp8_1;
        special_result_post_q_fp8_1        = special_result_q_fp8_1;
        special_status_post_q_fp8_1        = special_status_q_fp8_1;

        final_mantissa_post_q_fp8_2        = final_mantissa_fp8_2;
        sum_sticky_bits_post_q_fp8_2       = sum_sticky_bits_fp8_2;
        final_exponent_post_q_fp8_2        = final_exponent_fp8_2;
        sticky_after_norm_post_q_fp8_2     = sticky_after_norm_fp8_2;
        final_sign_post_q_fp8_2            = final_sign_q_fp8_2;
        effective_subtraction_post_q_fp8_2 = effective_subtraction_q_fp8_2;
        result_is_special_post_q_fp8_2     = result_is_special_q_fp8_2;
        special_result_post_q_fp8_2        = special_result_q_fp8_2;
        special_status_post_q_fp8_2        = special_status_q_fp8_2;

        post_norm_tag_q          = mid_pipe_tag_q[NUM_MID_REGS];
        post_norm_mask_q         = mid_pipe_mask_q[NUM_MID_REGS];
        post_norm_aux_q          = mid_pipe_aux_q[NUM_MID_REGS];
        post_norm_valid_q        = mid_pipe_valid_q[NUM_MID_REGS];
        post_norm_int_op_q       = mid_pipe_int_op_q[NUM_MID_REGS];
        post_norm_int_result_q   = mid_pipe_int_result_q[NUM_MID_REGS];
      end
    end
  endgenerate

  // 8-b destination shape for the SIMD/DP combine path. Both FP8 (E4M3) and
  // FP8ALT (E5M2) pack 4 lanes of 8-b into the 32-b output word.
  assign dst_is_fp8 = (dst_fmt_post_q == fpnew_pkg::FP8) || (dst_fmt_post_q == fpnew_pkg::FP8ALT);

  // ----------------------------
  // Rounding and classification
  // ----------------------------
  logic [1:0]                               round_sticky_bits;

  logic of_before_round, of_after_round; // overflow
  logic uf_before_round, uf_after_round; // underflow

  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_result;

  fpnew_round_classify_stage #(
    .WIDTH(WIDTH),
    .EXP_WIDTH(EXP_WIDTH),
    .PRECISION_BITS(PRECISION_BITS),
    .SUPER_EXP_BITS(SUPER_EXP_BITS),
    .SUPER_MAN_BITS(SUPER_MAN_BITS),
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig)
  ) i_round_classify_stage (
    .final_exponent_i       (final_exponent_post_q),
    .final_mantissa_i       (final_mantissa_post_q),
    .final_sign_i           (final_sign_post_q),
    .sticky_after_norm_i    (sticky_after_norm_post_q),
    .dst_fmt_i              (dst_fmt_post_q),
    .rnd_mode_i             (rnd_mode_post_q),
    .effective_subtraction_i(effective_subtraction_post_q),
    .sum_sticky_bits_i      (sum_sticky_bits_post_q),
    .fmt_result_o           (fmt_result),
    .of_before_round_o      (of_before_round),
    .uf_before_round_o      (uf_before_round),
    .of_after_round_o       (of_after_round),
    .uf_after_round_o       (uf_after_round),
    .round_sticky_bits_o   (round_sticky_bits)
  );

  // Start --- SIMD lane 1 datapath ---
  logic [1:0]                               round_sticky_bits_simd;
  logic of_before_round_simd, of_after_round_simd; // overflow
  logic uf_before_round_simd, uf_after_round_simd; // underflow
  logic [NUM_FORMATS-1:0][WIDTH/2-1:0] fmt_result_simd; 
  fpnew_round_classify_stage #(
    .WIDTH(WIDTH/2),
    .EXP_WIDTH(EXP_WIDTH_SIMD),
    .PRECISION_BITS(PRECISION_BITS_SIMD),
    .SUPER_EXP_BITS(SUPER_EXP_BITS_SIMD), 
    .SUPER_MAN_BITS(SUPER_MAN_BITS_SIMD),
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig & (7'b0011101))   // SIMD lane: FP16 + FP8 + FP16ALT (BF16) + FP8ALT (E5M2)
  ) i_round_classify_stage_simd (
    .final_exponent_i       (final_exponent_post_q_simd),
    .final_mantissa_i       (final_mantissa_post_q_simd),
    .final_sign_i           (final_sign_post_q_simd),
    .sticky_after_norm_i    (sticky_after_norm_post_q_simd),
    .dst_fmt_i              (dst_fmt_post_q),
    .rnd_mode_i             (rnd_mode_post_q),
    .effective_subtraction_i(effective_subtraction_post_q_simd),
    .sum_sticky_bits_i      (sum_sticky_bits_post_q_simd),
    .fmt_result_o           (fmt_result_simd),
    .of_before_round_o      (of_before_round_simd),
    .uf_before_round_o      (uf_before_round_simd),
    .of_after_round_o       (of_after_round_simd),
    .uf_after_round_o       (uf_after_round_simd),
    .round_sticky_bits_o   (round_sticky_bits_simd)
  );
  // End --- SIMD lane 1 datapath ---

    // Start --- SIMD lane 2 datapath ---
  logic [1:0]                               round_sticky_bits_fp8_1;
  logic of_before_round_fp8_1, of_after_round_fp8_1; // overflow
  logic uf_before_round_fp8_1, uf_after_round_fp8_1; // underflow
  logic [NUM_FORMATS-1:0][WIDTH/4-1:0] fmt_result_fp8_1; 
  fpnew_round_classify_stage #(
    .WIDTH(WIDTH/4),
    .EXP_WIDTH(EXP_WIDTH_FP8),
    .PRECISION_BITS(PRECISION_BITS_FP8),
    .SUPER_EXP_BITS(SUPER_EXP_BITS_FP8), 
    .SUPER_MAN_BITS(SUPER_MAN_BITS_FP8),
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig & (7'b0001001))   // FP8-DP lane: FP8 + FP8ALT
  ) i_round_classify_stage_fp8_1 (
    .final_exponent_i       (final_exponent_post_q_fp8_1),
    .final_mantissa_i       (final_mantissa_post_q_fp8_1),
    .final_sign_i           (final_sign_post_q_fp8_1),
    .sticky_after_norm_i    (sticky_after_norm_post_q_fp8_1),
    .dst_fmt_i              (dst_fmt_post_q),
    .rnd_mode_i             (rnd_mode_post_q),
    .effective_subtraction_i(effective_subtraction_post_q_fp8_1),
    .sum_sticky_bits_i      (sum_sticky_bits_post_q_fp8_1),
    .fmt_result_o           (fmt_result_fp8_1),
    .of_before_round_o      (of_before_round_fp8_1),
    .uf_before_round_o      (uf_before_round_fp8_1),
    .of_after_round_o       (of_after_round_fp8_1),
    .uf_after_round_o       (uf_after_round_fp8_1),
    .round_sticky_bits_o   (round_sticky_bits_fp8_1)
  );
  // End --- SIMD lane 2 datapath ---

    // Start --- SIMD lane 3 datapath ---
  logic [1:0]                               round_sticky_bits_fp8_2;
  logic of_before_round_fp8_2, of_after_round_fp8_2; // overflow
  logic uf_before_round_fp8_2, uf_after_round_fp8_2; // underflow
  logic [NUM_FORMATS-1:0][WIDTH/4-1:0] fmt_result_fp8_2; 
  fpnew_round_classify_stage #(
    .WIDTH(WIDTH/4),
    .EXP_WIDTH(EXP_WIDTH_FP8),
    .PRECISION_BITS(PRECISION_BITS_FP8),
    .SUPER_EXP_BITS(SUPER_EXP_BITS_FP8), 
    .SUPER_MAN_BITS(SUPER_MAN_BITS_FP8),
    .NUM_FORMATS(NUM_FORMATS),
    .FpFmtConfig(FpFmtConfig & (7'b0001001))   // FP8-DP lane: FP8 + FP8ALT
  ) i_round_classify_stage_fp8_2 (
    .final_exponent_i       (final_exponent_post_q_fp8_2),
    .final_mantissa_i       (final_mantissa_post_q_fp8_2),
    .final_sign_i           (final_sign_post_q_fp8_2),
    .sticky_after_norm_i    (sticky_after_norm_post_q_fp8_2),
    .dst_fmt_i              (dst_fmt_post_q),
    .rnd_mode_i             (rnd_mode_post_q),
    .effective_subtraction_i(effective_subtraction_post_q_fp8_2),
    .sum_sticky_bits_i      (sum_sticky_bits_post_q_fp8_2),
    .fmt_result_o           (fmt_result_fp8_2),
    .of_before_round_o      (of_before_round_fp8_2),
    .uf_before_round_o      (uf_before_round_fp8_2),
    .of_after_round_o       (of_after_round_fp8_2),
    .uf_after_round_o       (uf_after_round_fp8_2),
    .round_sticky_bits_o   (round_sticky_bits_fp8_2)
  );
  // End --- SIMD lane 3 datapath ---

  // -----------------
  // Result selection
  // -----------------
  logic [WIDTH-1:0]     regular_result;
  fpnew_pkg::status_t   regular_status;

  // Assemble regular result
  assign regular_result = fmt_result[dst_fmt_post_q];
  assign regular_status.NV = 1'b0; // only valid cases are handled in regular path
  assign regular_status.DZ = 1'b0; // no divisions
  assign regular_status.OF = of_before_round | of_after_round;   // rounding can introduce overflow
  assign regular_status.UF = uf_after_round & regular_status.NX; // only inexact results raise UF
  assign regular_status.NX = (| round_sticky_bits) | of_before_round | of_after_round;

  // Final results for output pipeline
  logic [WIDTH-1:0]   result_d_normal;
  fpnew_pkg::status_t status_d_normal;
  // Select output depending on special case detection
  assign result_d_normal = result_is_special_post_q ? special_result_post_q : regular_result;
  assign status_d_normal = result_is_special_post_q ? special_status_post_q : regular_status;

  // Start --- SIMD lane 1 datapath ---
  logic [WIDTH/2-1:0]     regular_result_simd;
  fpnew_pkg::status_t   regular_status_simd;
  // Assemble regular result
  assign regular_result_simd = fmt_result_simd[dst_fmt_post_q];
  assign regular_status_simd.NV = 1'b0; // only valid cases are handled in regular path
  assign regular_status_simd.DZ = 1'b0; // no divisions
  assign regular_status_simd.OF = of_before_round_simd | of_after_round_simd;   // rounding can introduce overflow
  assign regular_status_simd.UF = uf_after_round_simd & regular_status_simd.NX; // only inexact results raise UF
  assign regular_status_simd.NX = (| round_sticky_bits_simd) | of_before_round_simd | of_after_round_simd;

  // Start --- SIMD lane 2 datapath ---
  logic [WIDTH/4-1:0]     regular_result_fp8_1;
  fpnew_pkg::status_t   regular_status_fp8_1;
  // Assemble regular result
  assign regular_result_fp8_1 = fmt_result_fp8_1[dst_fmt_post_q];
  assign regular_status_fp8_1.NV = 1'b0; // only valid cases are handled in regular path
  assign regular_status_fp8_1.DZ = 1'b0; // no divisions
  assign regular_status_fp8_1.OF = of_before_round_fp8_1 | of_after_round_fp8_1;   // rounding can introduce overflow
  assign regular_status_fp8_1.UF = uf_after_round_fp8_1 & regular_status_fp8_1.NX; // only inexact results raise UF
  assign regular_status_fp8_1.NX = (| round_sticky_bits_fp8_1) | of_before_round_fp8_1 | of_after_round_fp8_1;

  // Start --- SIMD lane 3 datapath ---
  logic [WIDTH/4-1:0]     regular_result_fp8_2;
  fpnew_pkg::status_t   regular_status_fp8_2;
  // Assemble regular result
  assign regular_result_fp8_2 = fmt_result_fp8_2[dst_fmt_post_q];
  assign regular_status_fp8_2.NV = 1'b0; // only valid cases are handled in regular path
  assign regular_status_fp8_2.DZ = 1'b0; // no divisions
  assign regular_status_fp8_2.OF = of_before_round_fp8_2 | of_after_round_fp8_2;   // rounding can introduce overflow
  assign regular_status_fp8_2.UF = uf_after_round_fp8_2 & regular_status_fp8_2.NX; // only inexact results raise UF
  assign regular_status_fp8_2.NX = (| round_sticky_bits_fp8_2) | of_before_round_fp8_2 | of_after_round_fp8_2;

  // Final results for output pipeline
  logic [WIDTH/2-1:0]   result_d_simd;
  fpnew_pkg::status_t status_d_simd;
  // Select output depending on special case detection
  assign result_d_simd = result_is_special_post_q_simd ? special_result_post_q_simd : regular_result_simd;
  assign status_d_simd = result_is_special_post_q_simd ? special_status_post_q_simd : regular_status_simd;
  // End --- SIMD lane 1 datapath ---

  logic [WIDTH/4-1:0]   result_d_fp8_1;
  fpnew_pkg::status_t status_d_fp8_1;
  // Select output depending on special case detection
  assign result_d_fp8_1 = result_is_special_post_q_fp8_1 ? special_result_post_q_fp8_1 : regular_result_fp8_1;
  assign status_d_fp8_1 = result_is_special_post_q_fp8_1 ? special_status_post_q_fp8_1 : regular_status_fp8_1;
  // End --- SIMD lane 2 datapath ---

  logic [WIDTH/4-1:0]   result_d_fp8_2;
  fpnew_pkg::status_t status_d_fp8_2;
  // Select output depending on special case detection
  assign result_d_fp8_2 = result_is_special_post_q_fp8_2 ? special_result_post_q_fp8_2 : regular_result_fp8_2;
  assign status_d_fp8_2 = result_is_special_post_q_fp8_2 ? special_status_post_q_fp8_2 : regular_status_fp8_2;
  // End --- SIMD lane 3 datapath ---
  
  logic [WIDTH-1:0]   result_d;
  fpnew_pkg::status_t status_d;
  fpnew_pkg::status_t status_d_simd_merged;

  // Phase F: INT result overrides FP result_d when post_norm_int_op_q is set.
  logic [WIDTH-1:0] result_d_fp;
  assign result_d_fp = simd_enable_post_q ? (dst_is_fp8? {result_d_fp8_2, result_d_simd[0+: WIDTH/4],result_d_fp8_1,result_d_normal[0+: WIDTH/4]} :{result_d_simd, result_d_normal[0 +: WIDTH/2]}) : result_d_normal;
  assign result_d = post_norm_int_op_q ? post_norm_int_result_q : result_d_fp;
  assign status_d_simd_merged = dst_is_fp8
      ? (status_d_fp8_2 | status_d_simd | status_d_fp8_1 | status_d_normal)
      : (status_d_simd | status_d_normal);
  assign status_d = post_norm_mask_q
      ? (simd_enable_post_q ? status_d_simd_merged : status_d_normal)
      : '0;

  // ----------------
  // Output Pipeline
  // ----------------
  // Output pipeline signals, index i holds signal after i register stages
  logic               [0:NUM_OUT_REGS][WIDTH-1:0] out_pipe_result_q;
  fpnew_pkg::status_t [0:NUM_OUT_REGS]            out_pipe_status_q;
  TagType             [0:NUM_OUT_REGS]            out_pipe_tag_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_mask_q;
  AuxType             [0:NUM_OUT_REGS]            out_pipe_aux_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_OUT_REGS] out_pipe_ready;

  // Input stage: First element of pipeline is taken from inputs
  assign out_pipe_result_q[0] = result_d;
  assign out_pipe_status_q[0] = status_d;
  assign out_pipe_tag_q[0]    = post_norm_tag_q;
  assign out_pipe_mask_q[0]   = post_norm_mask_q;
  assign out_pipe_aux_q[0]    = post_norm_aux_q;
  assign out_pipe_valid_q[0]  = post_norm_valid_q;
  // Input stage: Propagate pipeline ready signal to inside pipe
  assign out_pipe_ready_0 = out_pipe_ready[0];
  assign mid_pipe_ready[NUM_MID_REGS] = ready_for_post_norm_pipe;
  // Generate the register stages
  for (genvar i = 0; i < NUM_OUT_REGS; i++) begin : gen_output_pipeline
    // Internal register enable for this stage
    logic reg_ena;
    // Determine the ready signal of the current stage - advance the pipeline:
    // 1. if the next stage is ready for our data
    // 2. if the next stage only holds a bubble (not valid) -> we can pop it
    assign out_pipe_ready[i] = out_pipe_ready[i+1] | ~out_pipe_valid_q[i+1];
    // Valid: enabled by ready signal, synchronous clear with the flush signal
    `FFLARNC(out_pipe_valid_q[i+1], out_pipe_valid_q[i], out_pipe_ready[i], flush_i, 1'b0, clk_i, rst_ni)
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (out_pipe_ready[i] & out_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + NUM_MID_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(out_pipe_result_q[i+1], out_pipe_result_q[i], reg_ena, '0)
    `FFL(out_pipe_status_q[i+1], out_pipe_status_q[i], reg_ena, '0)
    `FFL(out_pipe_tag_q[i+1],    out_pipe_tag_q[i],    reg_ena, TagType'('0))
    `FFL(out_pipe_mask_q[i+1],   out_pipe_mask_q[i],   reg_ena, '0)
    `FFL(out_pipe_aux_q[i+1],    out_pipe_aux_q[i],    reg_ena, AuxType'('0))
  end
  // Output stage: Ready travels backwards from output side, driven by downstream circuitry
  assign out_pipe_ready[NUM_OUT_REGS] = out_ready_i;
  // Output stage: assign module outputs
  assign result_o        = out_pipe_result_q[NUM_OUT_REGS];
  assign status_o        = out_pipe_status_q[NUM_OUT_REGS];
  assign extension_bit_o = 1'b1; // always NaN-Box result
  assign tag_o           = out_pipe_tag_q[NUM_OUT_REGS];
  assign mask_o          = out_pipe_mask_q[NUM_OUT_REGS];
  assign aux_o           = out_pipe_aux_q[NUM_OUT_REGS];
  assign out_valid_o     = out_pipe_valid_q[NUM_OUT_REGS];
  assign busy_o          = (| {inp_pipe_valid_q, mid_pipe_valid_q, out_pipe_valid_q});
endmodule



module multiplier_unsigned #(
  parameter int PRECISION_BITS = 24 // mantissa bits of the floating-point format
) (
  input  logic [PRECISION_BITS-1:0] a_i, // including implicit bit
  input  logic [PRECISION_BITS-1:0] b_i,   // including implicit bit
  output logic [2*PRECISION_BITS-1:0] product_o     // including implicit bit
);
  // Simple combinatorial multiplier
  assign product_o = a_i * b_i;
endmodule


module adder_unsigned #(
  parameter int IN_WIDTH = 10, // width of the adder
  parameter int OUT_WIDTH = 11  // width of the sum output
) (
  input  logic [IN_WIDTH-1:0] a_i,
  input  logic [IN_WIDTH-1:0] b_i,
  input  logic               carry_in_i,
  output logic [OUT_WIDTH-1:0] sum_o
);
  // Simple combinatorial adder
  assign sum_o = a_i + b_i + carry_in_i;
endmodule

// ============================================================================
// Floating-Point Input Pipeline Stage
// Derived from FPNew FMA slice input pipeline logic
// ============================================================================

module transdot_input_pipeline_skip #(
  parameter int unsigned WIDTH         = 32,
  parameter int unsigned NUM_INP_REGS  = 2,
  parameter int unsigned NUM_PIPE_REGS  = 2,
  parameter int unsigned NUM_FORMATS     = fpnew_pkg::NUM_FP_FORMATS,
  parameter type TagType               = logic,
  parameter type AuxType               = logic
)(
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          flush_i,

  // ---------------- Input ----------------
  input  logic [2:0][WIDTH-1:0]         operands_i,
  input  logic [NUM_FORMATS-1:0][2:0]   is_boxed_i,
  input  fpnew_pkg::roundmode_e         rnd_mode_i,
  input  fpnew_pkg::operation_e         op_i,
  input  logic                          op_mod_i,
  input  fpnew_pkg::fp_format_e         src_fmt_i,
  input  fpnew_pkg::fp_format_e         src2_fmt_i,
  input  fpnew_pkg::fp_format_e         dst_fmt_i,
  input  fpnew_pkg::int_format_e        int_fmt_i,
  input  TagType                        tag_i,
  input  logic                          mask_i,
  input  logic                          simd_enable_i,
  input  logic                          dp_enable_i,
  input  logic                          fp4_enable_i,
  input  AuxType                        aux_i,
  input  logic                          in_valid_i,
  output logic                          in_ready_o,

  // Optional external register enable override
  input  logic [NUM_PIPE_REGS-1:0]       reg_ena_i,

  // Downstream handshake (ready from next stage)
  input  logic                          down_ready_i,

  // ---------------- Output ----------------
  output logic [2:0][WIDTH-1:0]         operands_o,
  output logic [NUM_FORMATS-1:0][2:0]   is_boxed_o,     // <— added
  output fpnew_pkg::fp_format_e         src_fmt_o,
  output fpnew_pkg::fp_format_e         src2_fmt_o,
  output fpnew_pkg::fp_format_e         dst_fmt_o,
  output fpnew_pkg::int_format_e        int_fmt_o,
  output fpnew_pkg::roundmode_e         rnd_mode_o,
  output fpnew_pkg::operation_e         op_o,
  output logic                          op_mod_o,
  output TagType                        tag_o,
  output logic                          mask_o,
  output logic                          simd_enable_o,
  output logic                          dp_enable_o,
  output logic                          fp4_enable_o,
  output AuxType                        aux_o,
  output logic                          valid_o
);

  assign operands_o = operands_i; // bypass operands directly
  assign is_boxed_o = is_boxed_i; // bypass is_boxed directly
  assign src_fmt_o  = src_fmt_i;
  assign src2_fmt_o = src2_fmt_i;
  assign dst_fmt_o  = dst_fmt_i;
  assign int_fmt_o  = int_fmt_i;
  assign rnd_mode_o = rnd_mode_i;
  assign op_o       = op_i;
  assign op_mod_o   = op_mod_i;
  assign tag_o      = tag_i;
  assign mask_o     = mask_i;
  assign simd_enable_o = simd_enable_i;
  assign dp_enable_o = dp_enable_i;
  assign fp4_enable_o = fp4_enable_i;
  assign aux_o      = aux_i;
  assign valid_o    = in_valid_i;
  assign in_ready_o = down_ready_i; // bypass ready directly

endmodule

module transdot_input_pipeline #(
  parameter int unsigned WIDTH         = 32,
  parameter int unsigned NUM_INP_REGS  = 2,
  parameter int unsigned NUM_PIPE_REGS  = 2,
  parameter int unsigned NUM_FORMATS     = fpnew_pkg::NUM_FP_FORMATS,
  parameter type TagType               = logic,
  parameter type AuxType               = logic
)(
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          flush_i,

  // ---------------- Input ----------------
  input  logic [2:0][WIDTH-1:0]         operands_i,
  input  logic [NUM_FORMATS-1:0][2:0]   is_boxed_i,
  input  fpnew_pkg::roundmode_e         rnd_mode_i,
  input  fpnew_pkg::operation_e         op_i,
  input  logic                          op_mod_i,
  input  fpnew_pkg::fp_format_e         src_fmt_i,
  input  fpnew_pkg::fp_format_e         src2_fmt_i,
  input  fpnew_pkg::fp_format_e         dst_fmt_i,
  input  fpnew_pkg::int_format_e        int_fmt_i,
  input  TagType                        tag_i,
  input  logic                          mask_i,
  input  logic                          simd_enable_i,
  input  logic                          dp_enable_i,
  input  logic                          fp4_enable_i,
  input  AuxType                        aux_i,
  input  logic                          in_valid_i,
  output logic                          in_ready_o,

  // Optional external register enable override
  input  logic [NUM_PIPE_REGS-1:0]       reg_ena_i,

  // Downstream handshake (ready from next stage)
  input  logic                          down_ready_i,

  // ---------------- Output ----------------
  output logic [2:0][WIDTH-1:0]         operands_o,
  output logic [NUM_FORMATS-1:0][2:0]   is_boxed_o,     // <— added
  output fpnew_pkg::fp_format_e         src_fmt_o,
  output fpnew_pkg::fp_format_e         src2_fmt_o,
  output fpnew_pkg::fp_format_e         dst_fmt_o,
  output fpnew_pkg::int_format_e        int_fmt_o,
  output fpnew_pkg::roundmode_e         rnd_mode_o,
  output fpnew_pkg::operation_e         op_o,
  output logic                          op_mod_o,
  output TagType                        tag_o,
  output logic                          mask_o,
  output logic                          simd_enable_o,
  output logic                          dp_enable_o,
  output logic                          fp4_enable_o,
  output AuxType                        aux_o,
  output logic                          valid_o
);

  // --------------------------------------------------------------------------
  // Internal pipeline signals
  // --------------------------------------------------------------------------
  logic                  [0:NUM_INP_REGS][2:0][WIDTH-1:0]       inp_pipe_operands_q;
  logic                  [0:NUM_INP_REGS][NUM_FORMATS-1:0][2:0] inp_pipe_is_boxed_q;
  fpnew_pkg::roundmode_e [0:NUM_INP_REGS]                       inp_pipe_rnd_mode_q;
  fpnew_pkg::operation_e [0:NUM_INP_REGS]                       inp_pipe_op_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_op_mod_q;
  fpnew_pkg::fp_format_e [0:NUM_INP_REGS]                       inp_pipe_src_fmt_q;
  fpnew_pkg::fp_format_e [0:NUM_INP_REGS]                       inp_pipe_src2_fmt_q;
  fpnew_pkg::fp_format_e [0:NUM_INP_REGS]                       inp_pipe_dst_fmt_q;
  fpnew_pkg::int_format_e [0:NUM_INP_REGS]                      inp_pipe_int_fmt_q;
  TagType                [0:NUM_INP_REGS]                       inp_pipe_tag_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_mask_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_simd_enable_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_dp_enable_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_fp4_enable_q;
  AuxType                [0:NUM_INP_REGS]                       inp_pipe_aux_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_valid_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_ready;

  // Input stage assignment
  assign inp_pipe_operands_q[0] = operands_i;
  assign inp_pipe_is_boxed_q[0] = is_boxed_i;
  assign inp_pipe_rnd_mode_q[0] = rnd_mode_i;
  assign inp_pipe_op_q[0]       = op_i;
  assign inp_pipe_op_mod_q[0]   = op_mod_i;
  assign inp_pipe_src_fmt_q[0]  = src_fmt_i;
  assign inp_pipe_src2_fmt_q[0] = src2_fmt_i;
  assign inp_pipe_dst_fmt_q[0]  = dst_fmt_i;
  assign inp_pipe_int_fmt_q[0]  = int_fmt_i;
  assign inp_pipe_tag_q[0]      = tag_i;
  assign inp_pipe_mask_q[0]     = mask_i;
  assign inp_pipe_simd_enable_q[0] = simd_enable_i;
  assign inp_pipe_dp_enable_q[0] = dp_enable_i;
  assign inp_pipe_fp4_enable_q[0] = fp4_enable_i;

  assign inp_pipe_aux_q[0]      = aux_i;
  assign inp_pipe_valid_q[0]    = in_valid_i;

  // Terminal ready from downstream
  assign inp_pipe_ready[NUM_INP_REGS] = down_ready_i;

  // Ready to upstream
  assign in_ready_o = inp_pipe_ready[0];

  // --------------------------------------------------------------------------
  // Generate pipeline register stages
  // --------------------------------------------------------------------------
  for (genvar i = 0; i < NUM_INP_REGS; i++) begin : gen_input_pipeline
    logic reg_ena;
    // Advance pipeline if next stage ready or bubble
    assign inp_pipe_ready[i] = inp_pipe_ready[i+1] | ~inp_pipe_valid_q[i+1];

    // Valid flag propagation with flush
    `FFLARNC(inp_pipe_valid_q[i+1], inp_pipe_valid_q[i],
             inp_pipe_ready[i], flush_i, 1'b0, clk_i, rst_ni)

    // Enable when data valid or external enable
    assign reg_ena = (inp_pipe_ready[i] & inp_pipe_valid_q[i]) | reg_ena_i[i];

    // Register data fields
    `FFL(inp_pipe_operands_q[i+1], inp_pipe_operands_q[i], reg_ena, '0)
    `FFL(inp_pipe_is_boxed_q[i+1], inp_pipe_is_boxed_q[i], reg_ena, '0)
    `FFL(inp_pipe_rnd_mode_q[i+1], inp_pipe_rnd_mode_q[i], reg_ena, fpnew_pkg::RNE)
    `FFL(inp_pipe_op_q[i+1],       inp_pipe_op_q[i],       reg_ena, fpnew_pkg::FMADD)
    `FFL(inp_pipe_op_mod_q[i+1],   inp_pipe_op_mod_q[i],   reg_ena, '0)
    `FFL(inp_pipe_src_fmt_q[i+1],  inp_pipe_src_fmt_q[i],  reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_src2_fmt_q[i+1], inp_pipe_src2_fmt_q[i], reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_dst_fmt_q[i+1],  inp_pipe_dst_fmt_q[i],  reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_int_fmt_q[i+1],  inp_pipe_int_fmt_q[i],  reg_ena, fpnew_pkg::int_format_e'(0))
    `FFL(inp_pipe_tag_q[i+1],      inp_pipe_tag_q[i],      reg_ena, TagType'('0))
    `FFL(inp_pipe_mask_q[i+1],     inp_pipe_mask_q[i],     reg_ena, '0)
    `FFL(inp_pipe_simd_enable_q[i+1], inp_pipe_simd_enable_q[i], reg_ena, 1'b0)
    `FFL(inp_pipe_dp_enable_q[i+1], inp_pipe_dp_enable_q[i], reg_ena, 1'b0)
    `FFL(inp_pipe_fp4_enable_q[i+1], inp_pipe_fp4_enable_q[i], reg_ena, 1'b0)
    `FFL(inp_pipe_aux_q[i+1],      inp_pipe_aux_q[i],      reg_ena, AuxType'('0))
  end

  // --------------------------------------------------------------------------
  // Outputs (after final stage)
  // --------------------------------------------------------------------------
  assign operands_o = inp_pipe_operands_q[NUM_INP_REGS];
  assign is_boxed_o = inp_pipe_is_boxed_q[NUM_INP_REGS];  // <— added
  assign src_fmt_o  = inp_pipe_src_fmt_q[NUM_INP_REGS];
  assign src2_fmt_o = inp_pipe_src2_fmt_q[NUM_INP_REGS];
  assign dst_fmt_o  = inp_pipe_dst_fmt_q[NUM_INP_REGS];
  assign int_fmt_o  = inp_pipe_int_fmt_q[NUM_INP_REGS];
  assign rnd_mode_o = inp_pipe_rnd_mode_q[NUM_INP_REGS];
  assign op_o       = inp_pipe_op_q[NUM_INP_REGS];
  assign op_mod_o   = inp_pipe_op_mod_q[NUM_INP_REGS];
  assign tag_o      = inp_pipe_tag_q[NUM_INP_REGS];
  assign mask_o     = inp_pipe_mask_q[NUM_INP_REGS];
  assign simd_enable_o = inp_pipe_simd_enable_q[NUM_INP_REGS];
  assign dp_enable_o = inp_pipe_dp_enable_q[NUM_INP_REGS];
  assign fp4_enable_o = inp_pipe_fp4_enable_q[NUM_INP_REGS];
  assign aux_o      = inp_pipe_aux_q[NUM_INP_REGS];
  assign valid_o    = inp_pipe_valid_q[NUM_INP_REGS];

endmodule

// ============================================================================
// Floating-Point Operation Selection and Operand Adjustment
// -----------------------------------------------------------------------------
// This stage builds operand_a/b/c and their associated info structures based
// on the source formats, operation type, and rounding mode.
// ============================================================================

module fpnew_op_select #(
  parameter int unsigned NUM_FORMATS     = fpnew_pkg::NUM_FP_FORMATS,
  parameter int unsigned SUPER_EXP_BITS  = 15,
  parameter int unsigned SUPER_MAN_BITS  = 64
)(
  // ---------------- Inputs ----------------
  input  logic        [NUM_FORMATS-1:0][2:0]                     fmt_sign_i,
  input  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS-1:0] fmt_exponent_i,
  input  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS-1:0] fmt_mantissa_i,
  input  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0][2:0]             info_i,

  input  fpnew_pkg::fp_format_e  src_fmt_i,
  input  fpnew_pkg::fp_format_e  src2_fmt_i,
  input  fpnew_pkg::operation_e  op_i,
  input  logic                   op_mod_i,
  input  fpnew_pkg::roundmode_e  rnd_mode_i,

  // ---------------- Outputs ----------------
  output logic                        [SUPER_EXP_BITS-1:0] exp_a_o,
  output logic                        [SUPER_EXP_BITS-1:0] exp_b_o,
  output logic                        [SUPER_EXP_BITS-1:0] exp_c_o,
  output logic                        [SUPER_MAN_BITS-1:0] man_a_o,
  output logic                        [SUPER_MAN_BITS-1:0] man_b_o,
  output logic                        [SUPER_MAN_BITS-1:0] man_c_o,
  output logic                                            sign_a_o,
  output logic                                            sign_b_o,
  output logic                                            sign_c_o,
  output fpnew_pkg::fp_info_t                             info_a_o,
  output fpnew_pkg::fp_info_t                             info_b_o,
  output fpnew_pkg::fp_info_t                             info_c_o
);

  // --------------------------------------------------------------------------
  // Local FP struct definition
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic                      sign;
    logic [SUPER_EXP_BITS-1:0] exponent;
    logic [SUPER_MAN_BITS-1:0] mantissa;
  } fp_t;

  // --------------------------------------------------------------------------
  // Local temporaries
  // --------------------------------------------------------------------------
  fp_t      operand_a, operand_b, operand_c;
  fpnew_pkg::fp_info_t info_a, info_b, info_c;

  // --------------------------------------------------------------------------
  // Operand selection and adjustment
  // --------------------------------------------------------------------------
  always_comb begin : op_select
    // Default selection: map operand fields by format
    operand_a = '{ sign:     fmt_sign_i[src_fmt_i][0],
                   exponent: fmt_exponent_i[src_fmt_i][0],
                   mantissa: fmt_mantissa_i[src_fmt_i][0] };
    operand_b = '{ sign:     fmt_sign_i[src_fmt_i][1],
                   exponent: fmt_exponent_i[src_fmt_i][1],
                   mantissa: fmt_mantissa_i[src_fmt_i][1] };
    operand_c = '{ sign:     fmt_sign_i[src2_fmt_i][2],
                   exponent: fmt_exponent_i[src2_fmt_i][2],
                   mantissa: fmt_mantissa_i[src2_fmt_i][2] };

    info_a = info_i[src_fmt_i][0];
    info_b = info_i[src_fmt_i][1];
    info_c = info_i[src2_fmt_i][2];

    // op_mod_i always flips the sign of operand C (add/sub distinction)
    operand_c.sign = operand_c.sign ^ op_mod_i;

    // Apply per-operation behavior
    unique case (op_i)
      fpnew_pkg::FMADD,
      fpnew_pkg::TDOT_SIMD_FMADD,
      fpnew_pkg::TDOT_DP_FMADD,
      fpnew_pkg::TDOT_FP4_DP_FMADD: ; // do nothing

      fpnew_pkg::FNMSUB: begin
        // negate multiplicand A
        operand_a.sign = ~operand_a.sign;
      end

      fpnew_pkg::ADD,
      fpnew_pkg::ADDS: begin
        // replace A with +1.0
        operand_a = '{ sign: 1'b0,
                       exponent: fpnew_pkg::bias(src_fmt_i),
                       mantissa: '0 };
        info_a = '{ is_normal: 1'b1, is_boxed: 1'b1, default: 1'b0 };
      end

      fpnew_pkg::MUL: begin
        // replace C with +0 or -0 depending on rounding mode
        if (rnd_mode_i == fpnew_pkg::RDN)
          operand_c = '{ sign: 1'b0, exponent: '0, mantissa: '0 };
        else
          operand_c = '{ sign: 1'b1, exponent: '0, mantissa: '0 };
        info_c = '{ is_zero: 1'b1, is_boxed: 1'b1, default: 1'b0 };
      end

      default: begin
        operand_a = '{ default: '0 };
        operand_b = '{ default: '0 };
        operand_c = '{ default: '0 };
        info_a    = '{ default: fpnew_pkg::DONT_CARE };
        info_b    = '{ default: fpnew_pkg::DONT_CARE };
        info_c    = '{ default: fpnew_pkg::DONT_CARE };
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // Output field assignments (flattened for downstream units)
  // --------------------------------------------------------------------------
  assign sign_a_o = operand_a.sign;
  assign exp_a_o  = operand_a.exponent;
  assign man_a_o  = operand_a.mantissa;

  assign sign_b_o = operand_b.sign;
  assign exp_b_o  = operand_b.exponent;
  assign man_b_o  = operand_b.mantissa;

  assign sign_c_o = operand_c.sign;
  assign exp_c_o  = operand_c.exponent;
  assign man_c_o  = operand_c.mantissa;

  assign info_a_o = info_a;
  assign info_b_o = info_b;
  assign info_c_o = info_c;

endmodule

// ============================================================================
// Floating-Point Input Classification Stage
// -----------------------------------------------------------------------------
// Detects special operand conditions and determines FMA sign relationships.
// ============================================================================

module fpnew_input_classify #(
  parameter int unsigned SUPER_EXP_BITS = 15,
  parameter int unsigned SUPER_MAN_BITS = 64
)(
  // ---------------- Inputs ----------------
  // Three input operands (unified super-format)
  input  logic                      sign_a_i,
  input  logic                      sign_b_i,
  input  logic                      sign_c_i,

  // Operand classification info from fpnew_pkg
  input  fpnew_pkg::fp_info_t info_a_i,
  input  fpnew_pkg::fp_info_t info_b_i,
  input  fpnew_pkg::fp_info_t info_c_i,

  // ---------------- Outputs ----------------
  output logic any_operand_inf_o,
  output logic any_operand_nan_o,
  output logic signalling_nan_o,
  output logic effective_subtraction_o,
  output logic tentative_sign_o
);

  // --------------------------------------------------------------------------
  // Classification and sign relationship logic
  // --------------------------------------------------------------------------
  always_comb begin : classify
    // Special-value reductions
    any_operand_inf_o = (| {info_a_i.is_inf, info_b_i.is_inf, info_c_i.is_inf});
    any_operand_nan_o = (| {info_a_i.is_nan, info_b_i.is_nan, info_c_i.is_nan});
    signalling_nan_o  = (| {info_a_i.is_signalling, info_b_i.is_signalling, info_c_i.is_signalling});

    // Sign relationships
    // Effective subtraction in FMA occurs when product and addend signs differ
    effective_subtraction_o = sign_a_i ^ sign_b_i ^ sign_c_i;

    // Tentative result sign equals product sign
    tentative_sign_o = sign_a_i ^ sign_b_i;
  end

endmodule

// ============================================================================
// FP special-case handling (qNaN / Inf rules, NaN-boxing)
// - Selects canonical qNaN / Inf result and status when a special case applies
// - Works across multiple FP formats; output chosen by dst_fmt_i
// - Preserves NaN-boxing by filling upper bits with 1's for narrower formats
// ============================================================================

module fpnew_special_results #(
  parameter int unsigned NUM_FORMATS     = fpnew_pkg::NUM_FP_FORMATS,          // number of supported formats
  parameter fpnew_pkg::fmt_logic_t FpFmtConfig = 7'b1011010, // enable mask per format
  localparam int unsigned WIDTH       = fpnew_pkg::max_fp_width(FpFmtConfig)
)(
  // ---------------- Inputs ----------------
  input  fpnew_pkg::fp_format_e  dst_fmt_i,

  // Operand signs only (needed for sign rules)
  input  logic                   sign_a_i,
  input  logic                   sign_b_i,
  input  logic                   sign_c_i,

  // Operand classification info
  input  fpnew_pkg::fp_info_t    info_a_i,
  input  fpnew_pkg::fp_info_t    info_b_i,
  input  fpnew_pkg::fp_info_t    info_c_i,

  // Precomputed flags (from your classify stage)
  input  logic                   any_operand_inf_i,
  input  logic                   any_operand_nan_i,
  input  logic                   signalling_nan_i,
  input  logic                   effective_subtraction_i,

  // ---------------- Outputs ----------------
  output logic        [WIDTH-1:0]    special_result_o,     // NaN-boxed to WIDTH
  output fpnew_pkg::status_t         special_status_o,     // NV etc.
  output logic                       result_is_special_o   // bypass main FMA datapath
);

  // Per-format results/status (internal)
  logic        [NUM_FORMATS-1:0][WIDTH-1:0]    fmt_special_result;
  fpnew_pkg::status_t [NUM_FORMATS-1:0]        fmt_special_status;
  logic        [NUM_FORMATS-1:0]               fmt_result_is_special;

  // --------------------------------------------------------------------------
  // Per-format special-case construction
  // --------------------------------------------------------------------------
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_special_results
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      logic [FP_WIDTH-1:0] special_res;
      logic                product_sign;

      // Canonical encodings
      localparam logic [EXP_BITS-1:0] QNAN_EXPONENT = '1;
      localparam logic [MAN_BITS-1:0] QNAN_MANTISSA = {{1'b1},{MAN_BITS-1{1'b0}}};
      localparam logic [MAN_BITS-1:0] ZERO_MANTISSA = '0;

      assign product_sign = sign_a_i ^ sign_b_i;

      always_comb begin : special_results
        special_res                = {1'b0, QNAN_EXPONENT, QNAN_MANTISSA};
        fmt_special_status[fmt]    = '0;
        fmt_result_is_special[fmt] = 1'b0;

        // (inf*0)+(…)
        if ((info_a_i.is_inf && info_b_i.is_zero) || (info_a_i.is_zero && info_b_i.is_inf)) begin
          fmt_result_is_special[fmt] = 1'b1;
          fmt_special_status[fmt].NV = 1'b1;

        end else if (any_operand_nan_i) begin
          fmt_result_is_special[fmt] = 1'b1;
          fmt_special_status[fmt].NV = signalling_nan_i;

        end else if (any_operand_inf_i) begin
          fmt_result_is_special[fmt] = 1'b1;

          if ((info_a_i.is_inf || info_b_i.is_inf) && info_c_i.is_inf && effective_subtraction_i) begin
            fmt_special_status[fmt].NV = 1'b1;

          end else if (info_a_i.is_inf || info_b_i.is_inf) begin
            special_res = {product_sign, QNAN_EXPONENT, ZERO_MANTISSA};

          end else if (info_c_i.is_inf) begin
            special_res = {sign_c_i, QNAN_EXPONENT, ZERO_MANTISSA};
          end
        end

        // --- Safe NaN-boxing without OOB indexing ---
        fmt_special_result[fmt]            = '1;
        fmt_special_result[fmt][FP_WIDTH-1:0] = special_res[FP_WIDTH-1:0];
      end
    end else begin : inactive_format
      assign fmt_special_result[fmt]    = '{default: fpnew_pkg::DONT_CARE};
      assign fmt_special_status[fmt]    = '0;
      assign fmt_result_is_special[fmt] = 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Pick result per destination format
  // I2F casts don't produce special results in this block, so just mux dst
  // --------------------------------------------------------------------------
  assign result_is_special_o = fmt_result_is_special[dst_fmt_i]; // all formats compute consistently
  assign special_status_o    = fmt_special_status[dst_fmt_i];
  assign special_result_o    = fmt_special_result[dst_fmt_i];

endmodule

// ============================================================================
// Floating-Point Initial Exponent Datapath
// -----------------------------------------------------------------------------
// Computes internal exponents for the product and addend operands,
// determines normalization shifts for subnormals, and selects the
// tentative exponent for the FMA operation.
// ============================================================================

module fpnew_exponent_datapath #(
  parameter int unsigned EXP_WIDTH           = 15,  // internal exponent width
  parameter int unsigned SUPER_EXP_BITS      = 8,  // exponent width of superformat
  parameter int unsigned SUPER_MAN_BITS      = 64,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS      = 52,  // mantissa precision bits (e.g., FP64)
  parameter int unsigned SHIFT_AMOUNT_WIDTH  = 10   // must hold up to 3*PRECISION_BITS+4
)(
  // ---------------- Inputs ----------------
  // Operands
  input  logic [SUPER_EXP_BITS-1:0]               exponent_a_i,
  input  logic [SUPER_EXP_BITS-1:0]               exponent_b_i,
  input  logic [SUPER_EXP_BITS-1:0]               exponent_c_i,
  input  logic [SUPER_MAN_BITS-1:0]          mantissa_c_i,

  // Classification info
  input  fpnew_pkg::fp_info_t                info_a_i,
  input  fpnew_pkg::fp_info_t                info_b_i,
  input  fpnew_pkg::fp_info_t                info_c_i,

  // Format indices
  input  fpnew_pkg::fp_format_e              src_fmt_i,
  input  fpnew_pkg::fp_format_e              src2_fmt_i,
  input  fpnew_pkg::fp_format_e              dst_fmt_i,

  // ---------------- Outputs ----------------
  output logic signed [EXP_WIDTH-1:0]        exponent_addend_o,
  output logic signed [EXP_WIDTH-1:0]        exponent_product_o,
  output logic signed [EXP_WIDTH-1:0]        exponent_difference_o,
  output logic signed [EXP_WIDTH-1:0]        tentative_exponent_o,
  output logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_o,
  output logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_normalize_shamt_o
);

  // --------------------------------------------------------------------------
  // Local variables
  // --------------------------------------------------------------------------
  logic signed [EXP_WIDTH-1:0] exponent_a, exponent_b, exponent_c;
  logic signed [EXP_WIDTH-1:0] exponent_addend, exponent_product, exponent_difference;
  logic signed [EXP_WIDTH-1:0] tentative_exponent;
  logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt;
  logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_normalize_shamt;

  // Leading zero counter signals
  logic [$clog2(SUPER_MAN_BITS)-1:0] addend_lzc_count;
  logic [$clog2(SUPER_MAN_BITS)  :0] addend_lzc_count_sgn;

  // --------------------------------------------------------------------------
  // Exponent preprocessing (zero-extend into signed)
  // --------------------------------------------------------------------------
  assign exponent_a = signed'({1'b0, exponent_a_i});
  assign exponent_b = signed'({1'b0, exponent_b_i});
  assign exponent_c = signed'({1'b0, exponent_c_i});

  // --------------------------------------------------------------------------
  // Compute internal biased exponents
  // --------------------------------------------------------------------------

  // Addend exponent rebias
  assign exponent_addend =
    info_c_i.is_zero
      ? 1
      : signed'(exponent_c
                + $signed({1'b0, ~info_c_i.is_normal}) // 0 if normal, 1 if subnormal
                - signed'(fpnew_pkg::bias(src2_fmt_i))
                + signed'(fpnew_pkg::bias(dst_fmt_i)));

  // Product exponent rebias
  assign exponent_product =
    (info_a_i.is_zero || info_b_i.is_zero)
      ? 2 - signed'(fpnew_pkg::bias(dst_fmt_i))
      : signed'(exponent_a + info_a_i.is_subnormal
                + exponent_b + info_b_i.is_subnormal
                - 2 * signed'(fpnew_pkg::bias(src_fmt_i))
                + signed'(fpnew_pkg::bias(dst_fmt_i)));

  // Difference
  assign exponent_difference = exponent_addend - exponent_product;

  // --------------------------------------------------------------------------
  // Addend shift amount computation (alignment)
  // --------------------------------------------------------------------------
  always_comb begin : addend_shift_amount
    if (exponent_difference <= signed'(-2 * PRECISION_BITS - 1))
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt = 3 * PRECISION_BITS + 4;
    else if (exponent_difference <= signed'(PRECISION_BITS + 2))
      // overlapping exponents: partial alignment
      addend_shamt = unsigned'(signed'(PRECISION_BITS) + 3 - exponent_difference);
    else
      // addend larger: no shift needed
      addend_shamt = 0;
  end

  // --------------------------------------------------------------------------
  // Leading zero count (for addend normalization)
  // --------------------------------------------------------------------------
  lzc #(
    .WIDTH ( SUPER_MAN_BITS ),
    .MODE  ( 1 ) // 1 = leading zero count
  ) i_addend_lzc (
    .in_i    ( mantissa_c_i ),
    .cnt_o   ( addend_lzc_count ),
    .empty_o ( )
  );

  assign addend_lzc_count_sgn = signed'({1'b0, addend_lzc_count});

  // --------------------------------------------------------------------------
  // Addend normalization shift amount
  // --------------------------------------------------------------------------
  always_comb begin : addend_norm_shamt
    if (info_c_i.is_normal || info_c_i.is_zero)
      addend_normalize_shamt = 0;
    else if (exponent_addend <= 1)
      addend_normalize_shamt = 0;
    else if (addend_lzc_count_sgn + 1 < exponent_addend)
      addend_normalize_shamt = addend_lzc_count + 1;
    else
      addend_normalize_shamt = exponent_addend - 1;
  end

  // --------------------------------------------------------------------------
  // Tentative exponent selection
  // --------------------------------------------------------------------------
  assign tentative_exponent =
    (exponent_difference > 0)
      ? exponent_addend - addend_normalize_shamt
      : exponent_product;

  // --------------------------------------------------------------------------
  // Output assignment
  // --------------------------------------------------------------------------
  assign exponent_addend_o        = exponent_addend;
  assign exponent_product_o       = exponent_product;
  assign exponent_difference_o    = exponent_difference;
  assign tentative_exponent_o     = tentative_exponent;
  assign addend_shamt_o           = addend_shamt;
  assign addend_normalize_shamt_o = addend_normalize_shamt;

endmodule

module fpnew_addend_datapath #(
  parameter int unsigned SUPER_MAN_BITS     = 64,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS     = 53,  // mantissa precision bits (FP64: 53, FP32: 24)
  parameter int unsigned SHIFT_AMOUNT_WIDTH = 10   // shift amount bit width
)(
  // ---------------- Inputs ----------------
  input  logic [PRECISION_BITS-1:0]          mantissa_c_i,         // raw mantissa of operand C
  input  logic [3*PRECISION_BITS+3:0]        product_shifted_i,    // shifted product mantissa
  input  logic [SHIFT_AMOUNT_WIDTH-1:0]      addend_shamt_i,       // exponent diff shift
  input  logic                               effective_subtraction_i,
  input  logic                               tentative_sign_i,

  // ---------------- Outputs ----------------
  output logic                               sticky_before_add_o,
  output logic [3*PRECISION_BITS+3:0]        sum_o,
  output logic                               final_sign_o
);

  // --------------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------------
  localparam int unsigned STICKY_WIDTH = PRECISION_BITS;

  logic [STICKY_WIDTH-1:0]     addend_sticky_bits;
  logic                        sticky_before_add;
  logic [3*PRECISION_BITS+4-1:0] addend_after_shift;
  logic [3*PRECISION_BITS+4-1:0] addend_shifted;
  logic                        inject_carry_in;

  logic [3*PRECISION_BITS+5-1:0] sum_pos, sum_neg;
  logic                        sum_carry;
  logic [3*PRECISION_BITS+4-1:0] sum;
  logic                        final_sign;

  // --------------------------------------------------------------------------
  // Addend right-shift alignment with sticky-bit compression
  // --------------------------------------------------------------------------
  // BEFORE: mantissa_c | zeros(3p+4)
  // AFTER:  right-shifted with sticky bits captured in low p bits
  assign {addend_after_shift, addend_sticky_bits} =
      (mantissa_c_i << (3 * PRECISION_BITS + 4)) >> addend_shamt_i;

  assign sticky_before_add = (| addend_sticky_bits);

  // --------------------------------------------------------------------------
  // Handle subtraction (invert addend if subtraction)
  // --------------------------------------------------------------------------
  assign addend_shifted  = (effective_subtraction_i)
                           ? ~addend_after_shift
                           :  addend_after_shift;

  // Inject carry only when subtraction and no sticky (two’s complement negation)
  assign inject_carry_in = effective_subtraction_i & ~sticky_before_add;

  // --------------------------------------------------------------------------
  // Mantissa adder (unsigned)
  // --------------------------------------------------------------------------
  adder_unsigned #(
    .IN_WIDTH  (3*PRECISION_BITS + 4),
    .OUT_WIDTH (3*PRECISION_BITS + 5)
  ) i_mantissa_adder (
    .a_i        (product_shifted_i),
    .b_i        (addend_shifted),
    .carry_in_i (inject_carry_in),
    .sum_o      (sum_pos)
  );

  assign sum_carry = sum_pos[3*PRECISION_BITS+4];

  // --------------------------------------------------------------------------
  // Negative sum computation (for subtraction cases)
  // --------------------------------------------------------------------------
  assign sum_neg = addend_after_shift - product_shifted_i;

  // Select proper sum result
  assign sum = (effective_subtraction_i && ~sum_carry)
               ? sum_neg[3*PRECISION_BITS+3:0]
               : sum_pos[3*PRECISION_BITS+3:0];

  // --------------------------------------------------------------------------
  // Final sign determination
  // --------------------------------------------------------------------------
  assign final_sign =
    (effective_subtraction_i && (sum_carry == tentative_sign_i))
      ? 1'b1
      : (effective_subtraction_i ? 1'b0 : tentative_sign_i);

  // --------------------------------------------------------------------------
  // Output assignment
  // --------------------------------------------------------------------------
  assign sticky_before_add_o  = sticky_before_add;
  assign sum_o                = sum;
  assign final_sign_o         = final_sign;

endmodule


// ============================================================================
// Floating-Point Normalization Stage
// -----------------------------------------------------------------------------
// Performs post-addition normalization: detects leading zeros,
// shifts the mantissa accordingly, and adjusts the exponent.
// Also updates sticky bit and final mantissa for rounding.
// ============================================================================

module fpnew_normalization_stage #(
  parameter int unsigned EXP_WIDTH           = 15,
  parameter int unsigned PRECISION_BITS      = 52,
  parameter int unsigned LOWER_SUM_WIDTH     = 2*PRECISION_BITS + 3,
  parameter int unsigned SHIFT_AMOUNT_WIDTH  = 10,
  parameter int unsigned LZC_RESULT_WIDTH    = $clog2(LOWER_SUM_WIDTH)
)(
  // ---------------- Inputs ----------------
  input  logic [3*PRECISION_BITS+4-1:0]  sum_i,                   // sum (3p+4 bits)
  input  logic signed [EXP_WIDTH-1:0]  exponent_product_i,
  input  logic signed [EXP_WIDTH-1:0]  exponent_difference_i,
  input  logic signed [EXP_WIDTH-1:0]  tentative_exponent_i,
  input  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_i,
  input  logic                         effective_subtraction_i,
  input  logic                         sticky_before_add_i,

  // ---------------- Outputs ----------------
  output logic [PRECISION_BITS:0]      final_mantissa_o,       // mantissa before rounding
  output logic signed [EXP_WIDTH-1:0]  final_exponent_o,
  output logic                         sticky_after_norm_o,
  output logic [SHIFT_AMOUNT_WIDTH-1:0] norm_shamt_o,
  output logic signed [EXP_WIDTH-1:0]  normalized_exponent_o,
  output logic [2*PRECISION_BITS+2:0]  sum_sticky_bits_o
);

  // --------------------------------------------------------------------------
  // Local signals
  // --------------------------------------------------------------------------
  logic [LOWER_SUM_WIDTH-1:0]  sum_lower;
  logic [LZC_RESULT_WIDTH-1:0] leading_zero_count;
  logic signed [LZC_RESULT_WIDTH:0] leading_zero_count_sgn;
  logic                        lzc_zeroes;

  logic [SHIFT_AMOUNT_WIDTH-1:0] norm_shamt;
  logic signed [EXP_WIDTH-1:0]   normalized_exponent;

  logic [3*PRECISION_BITS+4:0] sum_shifted;
  logic [PRECISION_BITS:0]     final_mantissa;
  logic [2*PRECISION_BITS+2:0] sum_sticky_bits;
  logic                        sticky_after_norm;
  logic signed [EXP_WIDTH-1:0] final_exponent;

  // --------------------------------------------------------------------------
  // Leading-zero counter
  // --------------------------------------------------------------------------
  assign sum_lower = sum_i[LOWER_SUM_WIDTH-1:0];

  lzc #(
    .WIDTH ( LOWER_SUM_WIDTH ),
    .MODE  ( 1 )  // count leading zeros
  ) i_lzc (
    .in_i    ( sum_lower ),
    .cnt_o   ( leading_zero_count ),
    .empty_o ( lzc_zeroes )
  );

  assign leading_zero_count_sgn = signed'({1'b0, leading_zero_count});

  // --------------------------------------------------------------------------
  // Normalization shift amount calculation
  // --------------------------------------------------------------------------
  always_comb begin : norm_shift_amount
    if ((exponent_difference_i <= 0) ||
        (effective_subtraction_i && (exponent_difference_i <= 2))) begin
      // --- Product-anchored case or cancellation ---
      if ((exponent_product_i - leading_zero_count_sgn + 1 >= 0) && !lzc_zeroes) begin
        // Normal result
        norm_shamt          = PRECISION_BITS + 2 + leading_zero_count;
        normalized_exponent = exponent_product_i - leading_zero_count_sgn + 1;
      end else begin
        // Subnormal result (shift until exponent = 0)
        norm_shamt          = unsigned'(signed'(PRECISION_BITS + 2 + exponent_product_i));
        normalized_exponent = 0;
      end
    end else begin
      // --- Addend-anchored case ---
      norm_shamt          = addend_shamt_i;
      normalized_exponent = tentative_exponent_i;
    end
  end

  // --------------------------------------------------------------------------
  // Large normalization shift
  // --------------------------------------------------------------------------
  shifter_unsigned #(
    .WIDTH      ( 3*PRECISION_BITS + 4 ),
    .SHIFT_WIDTH ( SHIFT_AMOUNT_WIDTH )
  ) i_large_norm_shift (
    .in_i   ( sum_i ),
    .shift_amount_i  ( norm_shamt ),
    .out_o   ( sum_shifted )
  );

  // --------------------------------------------------------------------------
  // Small normalization (1-bit correction around MSB)
  // --------------------------------------------------------------------------
  always_comb begin : small_norm
    {final_mantissa, sum_sticky_bits} = sum_shifted;
    final_exponent                    = normalized_exponent;

    // Overflow → shift right and increment exponent
    if (sum_shifted[3*PRECISION_BITS+4]) begin
      {final_mantissa, sum_sticky_bits} = sum_shifted >> 1;
      final_exponent                    = normalized_exponent + 1;

    // Normalized case → do nothing
    end else if (sum_shifted[3*PRECISION_BITS+3]) begin
      // nothing

    // Still denormal but not true subnormal → shift left once and decrement exponent
    end else if (normalized_exponent > 1) begin
      {final_mantissa, sum_sticky_bits} = sum_shifted << 1;
      final_exponent                    = normalized_exponent - 1;

    // Truly subnormal result
    end else begin
      final_exponent = '0;
    end
  end

  // --------------------------------------------------------------------------
  // Sticky update
  // --------------------------------------------------------------------------
  assign sticky_after_norm = (| sum_sticky_bits) | sticky_before_add_i;

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  assign final_mantissa_o       = final_mantissa;
  assign final_exponent_o       = final_exponent;
  assign sticky_after_norm_o    = sticky_after_norm;
  assign norm_shamt_o           = norm_shamt;
  assign normalized_exponent_o  = normalized_exponent;
  assign sum_sticky_bits_o      = sum_sticky_bits;

endmodule

// ============================================================================
// Floating-Point Rounding and Classification Stage
// -----------------------------------------------------------------------------
// Performs per-format rounding preparation, overflow/underflow detection,
// invokes the rounding module, and produces the final packed result.
// ============================================================================

module fpnew_round_classify_stage #(
  parameter int unsigned WIDTH           = 32,
  parameter int unsigned EXP_WIDTH       = 10,   // width of final_exponent_i
  parameter int unsigned PRECISION_BITS  = 24,   // width of final_mantissa_i minus 1
  parameter int unsigned SUPER_EXP_BITS  = 15,   // full pipeline exponent width
  parameter int unsigned SUPER_MAN_BITS  = 64,   // full pipeline mantissa width
  parameter int unsigned NUM_FORMATS     = fpnew_pkg::NUM_FP_FORMATS,
  parameter fpnew_pkg::fmt_logic_t      FpFmtConfig = 7'b1011010
)(
  // ---------------- Inputs ----------------
  input  logic signed [EXP_WIDTH-1:0]    final_exponent_i,
  input  logic [PRECISION_BITS:0]        final_mantissa_i,
  input  logic                           final_sign_i,
  input  logic                           sticky_after_norm_i,
  input  fpnew_pkg::fp_format_e          dst_fmt_i,
  input  fpnew_pkg::roundmode_e          rnd_mode_i,
  input  logic                           effective_subtraction_i,
  input  logic [2*PRECISION_BITS+2:0]   sum_sticky_bits_i,

  // ---------------- Outputs ----------------
  output logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_result_o,
  output logic                              of_before_round_o,
  output logic                              uf_before_round_o,
  output logic                              of_after_round_o,
  output logic                              uf_after_round_o,
  output logic [1:0]                        round_sticky_bits_o
);

  import fpnew_pkg::*;

  logic [SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] pre_round_abs;
  logic [1:0]                               round_sticky_bits;
  // --------------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------------
  logic [NUM_FORMATS-1:0][SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] fmt_pre_round_abs; // per format
  logic [NUM_FORMATS-1:0][1:0]                               fmt_round_sticky_bits;

  logic [NUM_FORMATS-1:0]                                    fmt_of_after_round;
  logic [NUM_FORMATS-1:0]                                    fmt_uf_after_round;

  logic                                     rounded_sign;
  logic [SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] rounded_abs; // absolute value of result after rounding
  logic                                     result_zero;

  // --------------------------------------------------------------------------
  // Overflow/Underflow before rounding
  // --------------------------------------------------------------------------
// Classification before round. RISC-V mandates checking underflow AFTER rounding!
  assign of_before_round_o = final_exponent_i >= 2**(fpnew_pkg::exp_bits(dst_fmt_i))-1; // infinity exponent is all ones
  assign uf_before_round_o = final_exponent_i == 0;               // exponent for subnormals capped to 0


  // --------------------------------------------------------------------------
  // Pre-round per format
  // --------------------------------------------------------------------------
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_res_assemble
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    logic [EXP_BITS-1:0] pre_round_exponent;
    logic [MAN_BITS-1:0] pre_round_mantissa;

    if (FpFmtConfig[fmt]) begin : active_format

      if (EXP_BITS <= EXP_WIDTH) begin : exp_slice_fit
        assign pre_round_exponent = of_before_round_o ? (2**EXP_BITS - 2)
                                                      : final_exponent_i[EXP_BITS-1:0];
      end else begin : exp_slice_extend
        assign pre_round_exponent = of_before_round_o ? (2**EXP_BITS - 2)
                                                      : {{(EXP_BITS-EXP_WIDTH){1'b0}}, final_exponent_i};
      end
      assign pre_round_mantissa = (of_before_round_o)? '1: final_mantissa_i[SUPER_MAN_BITS-:MAN_BITS];

      // Pack exponent + mantissa
      assign fmt_pre_round_abs[fmt] = {pre_round_exponent, pre_round_mantissa};

      // Round bit is after mantissa (1 in case of overflow for rounding)
      assign fmt_round_sticky_bits[fmt][1] = final_mantissa_i[SUPER_MAN_BITS-MAN_BITS] |
                                             of_before_round_o;

      // remaining bits in mantissa to sticky (1 in case of overflow for rounding)
      if (MAN_BITS < SUPER_MAN_BITS) begin : narrow_sticky
        assign fmt_round_sticky_bits[fmt][0] = (| final_mantissa_i[SUPER_MAN_BITS-MAN_BITS-1:0]) |
                                               sticky_after_norm_i | of_before_round_o;
      end else begin : normal_sticky
        assign fmt_round_sticky_bits[fmt][0] = sticky_after_norm_i | of_before_round_o;
      end
    end else begin : inactive_format
      assign fmt_pre_round_abs[fmt]     = '{default: fpnew_pkg::DONT_CARE};
      assign fmt_round_sticky_bits[fmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // --------------------------------------------------------------------------
  // Select target format for rounding
  // --------------------------------------------------------------------------

  // Assemble result before rounding. In case of overflow, the largest normal value is set.
  assign pre_round_abs      = fmt_pre_round_abs[dst_fmt_i];

  // In case of overflow, the round and sticky bits are set for proper rounding
  assign round_sticky_bits  = fmt_round_sticky_bits[dst_fmt_i];

  // --------------------------------------------------------------------------
  // Rounding
  // --------------------------------------------------------------------------
  fpnew_rounding #(
    .AbsWidth(SUPER_EXP_BITS + SUPER_MAN_BITS)
  ) i_fpnew_rounding (
    .abs_value_i             (pre_round_abs),
    .sign_i                  (final_sign_i),
    .round_sticky_bits_i     (round_sticky_bits),
    .rnd_mode_i              (rnd_mode_i),
    .effective_subtraction_i (effective_subtraction_i),
    .abs_rounded_o           (rounded_abs),
    .sign_o                  (rounded_sign),
    .exact_zero_o            (result_zero)
  );

  
  // --------------------------------------------------------------------------
  // Post-round classification and final packing
  // --------------------------------------------------------------------------
  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_result;

  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_sign_inject
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      always_comb begin : post_process
        // detect of / uf        
        fmt_uf_after_round[fmt] = (rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) // denormal
        || ((pre_round_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) && (rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == 1) &&
              ((round_sticky_bits != 2'b11) || (!sum_sticky_bits_i[MAN_BITS*2 + 4] && ((rnd_mode_i == fpnew_pkg::RNE) || (rnd_mode_i == fpnew_pkg::RMM)))));
        fmt_of_after_round[fmt] = rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '1; // inf exp.

        // Assemble regular result, nan box short ones.
        fmt_result[fmt]               = '1;
        fmt_result[fmt][FP_WIDTH-1:0] = {rounded_sign, rounded_abs[EXP_BITS+MAN_BITS-1:0]};
      end
    end else begin : inactive_format
      assign fmt_uf_after_round[fmt] = fpnew_pkg::DONT_CARE;
      assign fmt_of_after_round[fmt] = fpnew_pkg::DONT_CARE;
      assign fmt_result[fmt]         = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // --------------------------------------------------------------------------
  // Select destination format results
  // --------------------------------------------------------------------------
  assign uf_after_round_o = fmt_uf_after_round[dst_fmt_i];
  assign of_after_round_o = fmt_of_after_round[dst_fmt_i];
  assign fmt_result_o     = fmt_result;
  assign round_sticky_bits_o = round_sticky_bits;
endmodule


module shifter_unsigned #(
  parameter int unsigned WIDTH = 64,
  parameter int unsigned SHIFT_WIDTH = 10
)(
  input  logic [WIDTH-1:0]         in_i,
  input  logic [SHIFT_WIDTH-1:0]   shift_amount_i,
  output logic [WIDTH:0]        out_o
);

  always_comb begin : shift_logic
    out_o = in_i << shift_amount_i;
  end
endmodule
