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

module fpnew_fma_multi #(
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
  input  TagType                      tag_i,
  input  logic                        mask_i,
  input  AuxType                      aux_i,
  // Input Handshake
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

  // Precision bits 'p' include the implicit bit
  localparam int unsigned PRECISION_BITS = SUPER_MAN_BITS + 1; //24
  // The lower 2p+3 bits of the internal FMA result will be needed for leading-zero detection
  localparam int unsigned LOWER_SUM_WIDTH  = 2 * PRECISION_BITS + 3; //51
  localparam int unsigned LZC_RESULT_WIDTH = $clog2(LOWER_SUM_WIDTH); //6
  // Internal exponent width of FMA must accomodate all meaningful exponent values in order to avoid
  // datapath leakage. This is either given by the exponent bits or the width of the LZC result.
  // In most reasonable FP formats the internal exponent will be wider than the LZC result.
  localparam int unsigned EXP_WIDTH = fpnew_pkg::maximum(SUPER_EXP_BITS + 2, LZC_RESULT_WIDTH); //10
  // Shift amount width: maximum internal mantissa size is 3p+4 bits
  localparam int unsigned SHIFT_AMOUNT_WIDTH = $clog2(3 * PRECISION_BITS + 5); //24*3+5=77 -> 7 bits
  // Pipelines
  localparam NUM_INP_REGS = PipeConfig == fpnew_pkg::BEFORE
                            ? NumPipeRegs
                            : (PipeConfig == fpnew_pkg::DISTRIBUTED
                               ? ((NumPipeRegs + 1) / 3) // Second to get distributed regs
                               : 0); // no regs here otherwise
  localparam NUM_MID_REGS = PipeConfig == fpnew_pkg::INSIDE
                          ? NumPipeRegs
                          : (PipeConfig == fpnew_pkg::DISTRIBUTED
                             ? ((NumPipeRegs + 2) / 3) // First to get distributed regs
                             : 0); // no regs here otherwise
  localparam NUM_OUT_REGS = PipeConfig == fpnew_pkg::AFTER
                            ? NumPipeRegs
                            : (PipeConfig == fpnew_pkg::DISTRIBUTED
                               ? (NumPipeRegs / 3) // Last to get distributed regs
                               : 0); // no regs here otherwise

  // ----------------
  // Type definition
  // ----------------
  typedef struct packed {
    logic                      sign;
    logic [SUPER_EXP_BITS-1:0] exponent;
    logic [SUPER_MAN_BITS-1:0] mantissa;
  } fp_t;

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

  logic mid_pipe_ready_0;
  fpnew_input_pipeline #(
    .WIDTH(WIDTH),
    .NUM_INP_REGS(NUM_INP_REGS),
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
    .tag_i(tag_i), .mask_i(mask_i), 
    .aux_i(aux_i),
    .in_valid_i(in_valid_i),
    .in_ready_o(in_ready_o),
    .reg_ena_i(reg_ena_i),
    .down_ready_i(mid_pipe_ready_0), // connect to downstream ready
    .operands_o(operands_q),
    .is_boxed_o(inp_pipe_is_boxed_q),         // <— now available
    .src_fmt_o(src_fmt_q),
    .src2_fmt_o(src2_fmt_q),
    .dst_fmt_o(dst_fmt_q),
    .rnd_mode_o(inp_pipe_rnd_mode_q),
    .op_o(inp_pipe_op_q), 
    .op_mod_o(inp_pipe_op_mod_q),
    .tag_o(inp_pipe_tag_q), 
    .mask_o(inp_pipe_mask_q), 
    .aux_o(inp_pipe_aux_q),
    .valid_o(inp_pipe_valid_q)
  );
  // -----------------
  // Input processing
  // -----------------
  logic        [NUM_FORMATS-1:0][2:0]                     fmt_sign;
  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS-1:0] fmt_exponent;
  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS-1:0] fmt_mantissa;

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
        .is_boxed_i ( inp_pipe_is_boxed_q[fmt] ),
        .info_o     ( info_q[fmt]                            )
      );
      for (genvar op = 0; op < 3; op++) begin : gen_operands
        assign trimmed_ops[op]       = operands_q[op][FP_WIDTH-1:0];
        assign fmt_sign[fmt][op]     = operands_q[op][FP_WIDTH-1];
        assign fmt_exponent[fmt][op] = signed'({1'b0, operands_q[op][MAN_BITS+:EXP_BITS]});
        assign fmt_mantissa[fmt][op] = {info_q[fmt][op].is_normal, operands_q[op][MAN_BITS-1:0]} <<
                                       (SUPER_MAN_BITS - MAN_BITS); // move to left of mantissa
      end
    end else begin : inactive_format
      assign info_q[fmt]                 = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  fp_t                 operand_a, operand_b, operand_c;
  fpnew_pkg::fp_info_t info_a,    info_b,    info_c;

  // Operation selection and operand adjustment
  // | \c op_q  | \c op_mod_q | Operation Adjustment
  // |:--------:|:-----------:|---------------------
  // | FMADD    | \c 0        | FMADD: none
  // | FMADD    | \c 1        | FMSUB: Invert sign of operand C
  // | FNMSUB   | \c 0        | FNMSUB: Invert sign of operand A
  // | FNMSUB   | \c 1        | FNMADD: Invert sign of operands A and C
  // | ADD/ADDS | \c 0        | ADD: Set operand A to +1.0
  // | ADD/ADDS | \c 1        | SUB: Set operand A to +1.0, invert sign of operand C
  // | MUL      | \c 0        | MUL: Set operand C to +0.0 or -0.0 depending on the rounding mode
  // | *others* | \c -        | *invalid*
  // \note \c op_mod_q always inverts the sign of the addend.
 
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
  // ---------------------
  // Input classification
  // ---------------------
  logic any_operand_inf;
  logic any_operand_nan;
  logic signalling_nan;
  logic effective_subtraction;
  logic tentative_sign;

  //// Reduction for special case handling
  //assign any_operand_inf = (| {info_a.is_inf,        info_b.is_inf,        info_c.is_inf});
  //assign any_operand_nan = (| {info_a.is_nan,        info_b.is_nan,        info_c.is_nan});
  //assign signalling_nan  = (| {info_a.is_signalling, info_b.is_signalling, info_c.is_signalling});
  //// Effective subtraction in FMA occurs when product and addend signs differ
  //assign effective_subtraction = operand_a.sign ^ operand_b.sign ^ operand_c.sign;
  //// The tentative sign of the FMA shall be the sign of the product
  //assign tentative_sign = operand_a.sign ^ operand_b.sign;
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
  // ----------------------
  // Special case handling
  // ----------------------
  logic [WIDTH-1:0]   special_result;
  fpnew_pkg::status_t special_status;
  logic               result_is_special;


  // Detect special case from source format, I2F casts don't produce a special result
  //assign result_is_special = fmt_result_is_special[dst_fmt_q]; // they're all the same
  // Signalling input NaNs raise invalid flag, otherwise no flags set
  //assign special_status = fmt_special_status[dst_fmt_q];
  // Assemble result according to destination format
  //assign special_result = fmt_special_result[dst_fmt_q]; // destination format
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
    .result_is_special_o     (result_is_special)
  );
  // ---------------------------
  // Initial exponent data path
  // ---------------------------
  logic signed [EXP_WIDTH-1:0] exponent_addend, exponent_product, exponent_difference;
  logic signed [EXP_WIDTH-1:0] tentative_exponent;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt;
  logic        [SHIFT_AMOUNT_WIDTH    -1:0] addend_normalize_shamt;

  fpnew_exponent_datapath #(
    .EXP_WIDTH(EXP_WIDTH),
    .SUPER_EXP_BITS(SUPER_EXP_BITS),
    .SUPER_MAN_BITS(SUPER_MAN_BITS),
    .PRECISION_BITS(PRECISION_BITS),
    .SHIFT_AMOUNT_WIDTH(SHIFT_AMOUNT_WIDTH)
  ) i_exponent_datapath (
    .exponent_a_i(operand_a.exponent),
    .exponent_b_i(operand_b.exponent),
    .exponent_c_i(operand_c.exponent),
    .mantissa_c_i(operand_c.mantissa),

    .info_a_i(info_a),
    .info_b_i(info_b),
    .info_c_i(info_c),

    .src_fmt_i(src_fmt_q),
    .src2_fmt_i(src2_fmt_q),
    .dst_fmt_i(dst_fmt_q),

    .exponent_addend_o(exponent_addend),
    .exponent_product_o(exponent_product),
    .exponent_difference_o(exponent_difference),
    .tentative_exponent_o(tentative_exponent),
    .addend_shamt_o(addend_shamt),
    .addend_normalize_shamt_o(addend_normalize_shamt)
  );

  // ------------------
  // Product data path
  // ------------------
  logic [PRECISION_BITS-1:0]   mantissa_a, mantissa_b, mantissa_c;
  logic [2*PRECISION_BITS-1:0] product;             // the p*p product is 2p bits wide
  logic [3*PRECISION_BITS+3:0] product_shifted;     // addends are 3p+4 bit wide (including G/R)

  // Add implicit bits to mantissae
  assign mantissa_a = {info_a.is_normal, operand_a.mantissa};
  assign mantissa_b = {info_b.is_normal, operand_b.mantissa};
  assign mantissa_c = {info_c.is_normal, operand_c.mantissa};

  // Mantissa multiplier (a*b)
  //assign product = mantissa_a * mantissa_b;
  multiplier_unsigned #(
    .PRECISION_BITS ( PRECISION_BITS )
  ) i_mantissa_multiply (
    .a_i     ( mantissa_a ),
    .b_i     ( mantissa_b ),
    .product_o ( product   )
  );

  // Product is placed into a 3p+4 bit wide vector, padded with 2 bits for round and sticky:
  // | 000...000 | product | RS |
  //  <-  p+2  -> <-  2p -> < 2>
  assign product_shifted = product << 2; // constant shift

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
  //assign {addend_after_shift, addend_sticky_bits} =
  //    (mantissa_c << (3 * PRECISION_BITS + 4)) >> addend_shamt;

  //assign sticky_before_add     = (| addend_sticky_bits);

  // In case of a subtraction, the addend is inverted
  //assign addend_shifted = (effective_subtraction) ? ~addend_after_shift : addend_after_shift;
  //assign inject_carry_in = effective_subtraction & ~sticky_before_add;

  // ------
  // Adder
  // ------
  logic [3*PRECISION_BITS+4:0] sum_pos, sum_neg; // added one bit for the carry
  logic                        sum_carry;        // observe carry bit from positive sum for sign fixing
  logic [3*PRECISION_BITS+3:0] sum;              // discard carry as sum won't overflow
  logic                        final_sign;

  fpnew_addend_datapath #(
    .SUPER_MAN_BITS(SUPER_MAN_BITS),
    .PRECISION_BITS(PRECISION_BITS),
    .SHIFT_AMOUNT_WIDTH(SHIFT_AMOUNT_WIDTH)
  ) i_addend_datapath (
    .mantissa_c_i            (mantissa_c),
    .product_shifted_i       (product_shifted),
    .addend_shamt_i          (addend_shamt),
    .effective_subtraction_i (effective_subtraction),
    .tentative_sign_i        (tentative_sign),
    .sticky_before_add_o     (sticky_before_add),
    .sum_o                   (sum),
    .final_sign_o            (final_sign)
  );
  //Mantissa adder (ab+c). In normal addition, it cannot overflow.
  //assign sum_pos = product_shifted + addend_shifted + inject_carry_in;
  //adder_unsigned #(
  //  .IN_WIDTH ( 3*PRECISION_BITS + 4 ),
  //  .OUT_WIDTH( 3*PRECISION_BITS + 5 )
  //) i_mantissa_adder (
  //  .a_i     ( product_shifted   ),
  //  .b_i     ( addend_shifted    ),
  //  .carry_in_i ( inject_carry_in ),
  //  .sum_o   ( sum_pos           )
  //);

  //assign sum_carry = sum_pos[3*PRECISION_BITS+4];

  // Parallel adder for negative sum (only used for effective subtractions).
  // Note: inject_carry_in is used to complete the negation of the addend in the positive sum but
  // for the negative sum the addend is not negated, so no carry needs to be injected.
  //assign sum_neg = addend_after_shift - product_shifted;

  // Complement negative sum (can only happen in subtraction -> overflows for positive results)
  //assign sum        = (effective_subtraction && ~sum_carry) ? sum_neg : sum_pos;

  // In case of a mispredicted subtraction result, do a sign flip
  //assign final_sign = (effective_subtraction && (sum_carry == tentative_sign))
  //                    ? 1'b1
  //                    : (effective_subtraction ? 1'b0 : tentative_sign);

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
  AuxType                [0:NUM_MID_REGS]                         mid_pipe_aux_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_MID_REGS] mid_pipe_ready;

  // Input stage: First element of pipeline is taken from upstream logic
  assign mid_pipe_eff_sub_q[0]     = effective_subtraction;
  assign mid_pipe_exp_prod_q[0]    = exponent_product;
  assign mid_pipe_exp_diff_q[0]    = exponent_difference;
  assign mid_pipe_tent_exp_q[0]    = tentative_exponent;
  assign mid_pipe_add_shamt_q[0]   = addend_shamt + addend_normalize_shamt;
  assign mid_pipe_sticky_q[0]      = sticky_before_add;
  assign mid_pipe_sum_q[0]         = sum;
  assign mid_pipe_final_sign_q[0]  = final_sign;
  assign mid_pipe_rnd_mode_q[0]    = inp_pipe_rnd_mode_q;
  assign mid_pipe_dst_fmt_q[0]     = dst_fmt_q;
  assign mid_pipe_res_is_spec_q[0] = result_is_special;
  assign mid_pipe_spec_res_q[0]    = special_result;
  assign mid_pipe_spec_stat_q[0]   = special_status;
  assign mid_pipe_tag_q[0]         = inp_pipe_tag_q;
  assign mid_pipe_mask_q[0]        = inp_pipe_mask_q;
  assign mid_pipe_aux_q[0]         = inp_pipe_aux_q;
  assign mid_pipe_valid_q[0]       = inp_pipe_valid_q;
  // Input stage: Propagate pipeline ready signal to input pipe
  //assign inp_pipe_ready[NUM_INP_REGS] = mid_pipe_ready[0];
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
    `FFL(mid_pipe_aux_q[i+1],         mid_pipe_aux_q[i],         reg_ena, AuxType'('0))
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
  assign dst_fmt_q2              = mid_pipe_dst_fmt_q[NUM_MID_REGS];
  assign result_is_special_q     = mid_pipe_res_is_spec_q[NUM_MID_REGS];
  assign special_result_q        = mid_pipe_spec_res_q[NUM_MID_REGS];
  assign special_status_q        = mid_pipe_spec_stat_q[NUM_MID_REGS];

  // --------------
  // Normalization
  // --------------
  //logic        [LOWER_SUM_WIDTH-1:0]  sum_lower;              // lower 2p+3 bits of sum are searched
  //logic        [LZC_RESULT_WIDTH-1:0] leading_zero_count;     // the number of leading zeroes
  //logic signed [LZC_RESULT_WIDTH:0]   leading_zero_count_sgn; // signed leading-zero count
  //logic                               lzc_zeroes;             // in case only zeroes found

  logic        [SHIFT_AMOUNT_WIDTH-1:0] norm_shamt; // Normalization shift amount
  logic signed [EXP_WIDTH-1:0]          normalized_exponent;

  //logic [3*PRECISION_BITS+4:0] sum_shifted;       // result after first normalization shift
  logic [PRECISION_BITS:0]     final_mantissa;    // final mantissa before rounding with round bit
  logic [2*PRECISION_BITS+2:0] sum_sticky_bits;   // remaining 2p+3 sticky bits after normalization
  logic                        sticky_after_norm; // sticky bit after normalization

  logic signed [EXP_WIDTH-1:0] final_exponent;

  fpnew_normalization_stage #(
    .EXP_WIDTH(EXP_WIDTH),
    .PRECISION_BITS(PRECISION_BITS),
    .LOWER_SUM_WIDTH(2*PRECISION_BITS + 3),
    .SHIFT_AMOUNT_WIDTH(SHIFT_AMOUNT_WIDTH)
  ) i_normalization_stage (
    .sum_i                 (sum_q),
    .exponent_product_i    (exponent_product_q),
    .exponent_difference_i (exponent_difference_q),
    .tentative_exponent_i  (tentative_exponent_q),
    .addend_shamt_i        (addend_shamt_q),
    .effective_subtraction_i (effective_subtraction_q),
    .sticky_before_add_i   (sticky_before_add_q),

    .final_mantissa_o      (final_mantissa),
    .final_exponent_o      (final_exponent),
    .sticky_after_norm_o   (sticky_after_norm),
    .norm_shamt_o          (norm_shamt),
    .normalized_exponent_o (normalized_exponent),
    .sum_sticky_bits_o     (sum_sticky_bits)
  );

  // ----------------------------
  // Rounding and classification
  // ----------------------------
  //logic                                     pre_round_sign;
  //logic [SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] pre_round_abs; // absolute value of result before rounding
  logic [1:0]                               round_sticky_bits;

  logic of_before_round, of_after_round; // overflow
  logic uf_before_round, uf_after_round; // underflow

  //logic [NUM_FORMATS-1:0][SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] fmt_pre_round_abs; // per format
  //logic [NUM_FORMATS-1:0][1:0]                               fmt_round_sticky_bits;

  //logic [NUM_FORMATS-1:0]                                    fmt_of_after_round;
  //logic [NUM_FORMATS-1:0]                                    fmt_uf_after_round;

  //logic                                     rounded_sign;
  //logic [SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] rounded_abs; // absolute value of result after rounding
  //logic                                     result_zero;

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
    .final_exponent_i       (final_exponent),
    .final_mantissa_i       (final_mantissa),
    .final_sign_i           (final_sign_q),
    .sticky_after_norm_i    (sticky_after_norm),
    .dst_fmt_i              (dst_fmt_q2),
    .rnd_mode_i             (rnd_mode_q),
    .effective_subtraction_i(effective_subtraction_q),
    .sum_sticky_bits_i      (sum_sticky_bits),
    .fmt_result_o           (fmt_result),
    .of_before_round_o      (of_before_round),
    .uf_before_round_o      (uf_before_round),
    .of_after_round_o       (of_after_round),
    .uf_after_round_o       (uf_after_round),
    .round_sticky_bits_o   (round_sticky_bits)
  );

  // -----------------
  // Result selection
  // -----------------
  logic [WIDTH-1:0]     regular_result;
  fpnew_pkg::status_t   regular_status;

  // Assemble regular result
  assign regular_result = fmt_result[dst_fmt_q2];
  assign regular_status.NV = 1'b0; // only valid cases are handled in regular path
  assign regular_status.DZ = 1'b0; // no divisions
  assign regular_status.OF = of_before_round | of_after_round;   // rounding can introduce overflow
  assign regular_status.UF = uf_after_round & regular_status.NX; // only inexact results raise UF
  assign regular_status.NX = (| round_sticky_bits) | of_before_round | of_after_round;

  // Final results for output pipeline
  logic [WIDTH-1:0]   result_d;
  fpnew_pkg::status_t status_d;

  // Select output depending on special case detection
  assign result_d = result_is_special_q ? special_result_q : regular_result;
  assign status_d = result_is_special_q ? special_status_q : regular_status;

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
  assign out_pipe_tag_q[0]    = mid_pipe_tag_q[NUM_MID_REGS];
  assign out_pipe_mask_q[0]   = mid_pipe_mask_q[NUM_MID_REGS];
  assign out_pipe_aux_q[0]    = mid_pipe_aux_q[NUM_MID_REGS];
  assign out_pipe_valid_q[0]  = mid_pipe_valid_q[NUM_MID_REGS];
  // Input stage: Propagate pipeline ready signal to inside pipe
  assign mid_pipe_ready[NUM_MID_REGS] = out_pipe_ready[0];
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

module fpnew_input_pipeline #(
  parameter int unsigned WIDTH         = 32,
  parameter int unsigned NUM_INP_REGS  = 2,
  parameter int unsigned NUM_FORMATS   = 5,
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
  input  TagType                        tag_i,
  input  logic                          mask_i,
  input  AuxType                        aux_i,
  input  logic                          in_valid_i,
  output logic                          in_ready_o,

  // Optional external register enable override
  input  logic [NUM_INP_REGS-1:0]       reg_ena_i,

  // Downstream handshake (ready from next stage)
  input  logic                          down_ready_i,

  // ---------------- Output ----------------
  output logic [2:0][WIDTH-1:0]         operands_o,
  output logic [NUM_FORMATS-1:0][2:0]   is_boxed_o,     // <— added
  output fpnew_pkg::fp_format_e         src_fmt_o,
  output fpnew_pkg::fp_format_e         src2_fmt_o,
  output fpnew_pkg::fp_format_e         dst_fmt_o,
  output fpnew_pkg::roundmode_e         rnd_mode_o,
  output fpnew_pkg::operation_e         op_o,
  output logic                          op_mod_o,
  output TagType                        tag_o,
  output logic                          mask_o,
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
  TagType                [0:NUM_INP_REGS]                       inp_pipe_tag_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_mask_q;
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
  assign inp_pipe_tag_q[0]      = tag_i;
  assign inp_pipe_mask_q[0]     = mask_i;
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
    `FFL(inp_pipe_tag_q[i+1],      inp_pipe_tag_q[i],      reg_ena, TagType'('0))
    `FFL(inp_pipe_mask_q[i+1],     inp_pipe_mask_q[i],     reg_ena, '0)
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
  assign rnd_mode_o = inp_pipe_rnd_mode_q[NUM_INP_REGS];
  assign op_o       = inp_pipe_op_q[NUM_INP_REGS];
  assign op_mod_o   = inp_pipe_op_mod_q[NUM_INP_REGS];
  assign tag_o      = inp_pipe_tag_q[NUM_INP_REGS];
  assign mask_o     = inp_pipe_mask_q[NUM_INP_REGS];
  assign aux_o      = inp_pipe_aux_q[NUM_INP_REGS];
  assign valid_o    = inp_pipe_valid_q[NUM_INP_REGS];

endmodule

module fpnew_input_pipeline_skip #(
  parameter int unsigned WIDTH         = 32,
  parameter int unsigned NUM_INP_REGS  = 2,
  parameter int unsigned NUM_FORMATS   = 5,
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
  input  TagType                        tag_i,
  input  logic                          mask_i,
  input  AuxType                        aux_i,
  input  logic                          in_valid_i,
  output logic                          in_ready_o,

  // Optional external register enable override
  input  logic [NUM_INP_REGS-1:0]       reg_ena_i,

  // Downstream handshake (ready from next stage)
  input  logic                          down_ready_i,

  // ---------------- Output ----------------
  output logic [2:0][WIDTH-1:0]         operands_o,
  output logic [NUM_FORMATS-1:0][2:0]   is_boxed_o,     // <— added
  output fpnew_pkg::fp_format_e         src_fmt_o,
  output fpnew_pkg::fp_format_e         src2_fmt_o,
  output fpnew_pkg::fp_format_e         dst_fmt_o,
  output fpnew_pkg::roundmode_e         rnd_mode_o,
  output fpnew_pkg::operation_e         op_o,
  output logic                          op_mod_o,
  output TagType                        tag_o,
  output logic                          mask_o,
  output AuxType                        aux_o,
  output logic                          valid_o
);

  // --------------------------------------------------------------------------
  // Outputs (after final stage)
  // --------------------------------------------------------------------------
  assign operands_o = operands_i;
  assign is_boxed_o = is_boxed_i;  // <— added
  assign src_fmt_o  = src_fmt_i;
  assign src2_fmt_o = src2_fmt_i;
  assign dst_fmt_o  = dst_fmt_i;
  assign rnd_mode_o = rnd_mode_i;
  assign op_o       = op_i;
  assign op_mod_o   = op_mod_i;
  assign tag_o      = tag_i;
  assign mask_o     = mask_i;
  assign aux_o      = aux_i;
  assign valid_o    = in_valid_i;
  assign in_ready_o  = down_ready_i;
endmodule

// ============================================================================
// Floating-Point Operation Selection and Operand Adjustment
// -----------------------------------------------------------------------------
// This stage builds operand_a/b/c and their associated info structures based
// on the source formats, operation type, and rounding mode.
// ============================================================================

module fpnew_op_select #(
  parameter int unsigned NUM_FORMATS     = 5,
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
      fpnew_pkg::FMADD: ; // do nothing

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
  parameter int unsigned NUM_FORMATS   = 5,          // number of supported formats
  parameter fpnew_pkg::fmt_logic_t FpFmtConfig = 5'b10110, // enable mask per format
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


// ============================================================================
// Floating-Point Addend Datapath and Mantissa Adder
// -----------------------------------------------------------------------------
// Performs alignment of the addend mantissa based on exponent difference,
// computes sticky bits, handles effective subtraction inversion,
// and performs the mantissa addition (product + addend).
// Outputs include sticky_before_add for rounding logic.
// ============================================================================

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
  logic [99:0] temporaries;
  assign temporaries = {mantissa_c_i, {(3*PRECISION_BITS+4){1'b0}}};
  
  right_shifter_unsigned #(
    .WIDTH       ( PRECISION_BITS + 3*PRECISION_BITS + 4 ),
    .SHIFT_WIDTH ( SHIFT_AMOUNT_WIDTH )
  ) i_addend_shifter (
    .in_i           ( temporaries ),
    .shift_amount_i ( addend_shamt_i ),
    .out_o          ( {addend_after_shift, addend_sticky_bits} )
  );

  // Removed redundant assignment since right_shifter_unsigned module handles shifting
  // assign {addend_after_shift, addend_sticky_bits} =
  //     (mantissa_c_i << (3 * PRECISION_BITS + 4)) >> addend_shamt_i;

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


module right_shifter_unsigned #(
  parameter int unsigned WIDTH       = 100,
  parameter int unsigned SHIFT_WIDTH = 10
)(
  // ---------------- Inputs ----------------
  input  logic [WIDTH-1:0]           in_i,
  input  logic [SHIFT_WIDTH-1:0]     shift_amount_i,

  // ---------------- Outputs ----------------
  output logic [WIDTH-1:0]          out_o
);

  // --------------------------------------------------------------------------
  // Right shifter implementation
  // --------------------------------------------------------------------------
  always_comb begin : right_shifter
    out_o = in_i >> shift_amount_i;
  end
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
  // assign sum_shifted = sum_i << norm_shamt;

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
  parameter int unsigned NUM_FORMATS     = 5,
  parameter fpnew_pkg::fmt_logic_t      FpFmtConfig = 5'b10110
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

      assign pre_round_exponent = (of_before_round_o)? (2**EXP_BITS - 2): final_exponent_i[EXP_BITS-1:0];
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