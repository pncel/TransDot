// Clean no-DP addend datapath with separate per-lane adders/subtractors.
// No internal pipeline register (pipeline handled by FMA's mid/out stages).
// Shared barrel shifter for addend alignment; per-lane native-width arithmetic.
module transdot_decomp_addend_datapath_no_dp #(
  parameter int unsigned SUPER_MAN_BITS     = 23,
  parameter int unsigned PRECISION_BITS     = SUPER_MAN_BITS + 1,
  parameter int unsigned SHIFT_AMOUNT_WIDTH = $clog2(3 * PRECISION_BITS + 5),
  parameter int unsigned SUPER_MAN_BITS_SIMD     = 10,
  parameter int unsigned PRECISION_BITS_SIMD     = SUPER_MAN_BITS_SIMD + 1,
  parameter int unsigned SHIFT_AMOUNT_WIDTH_SIMD = $clog2(3 * PRECISION_BITS_SIMD + 5),
  parameter int unsigned SUPER_MAN_BITS_FP8     = 4,
  parameter int unsigned PRECISION_BITS_FP8     = SUPER_MAN_BITS_FP8 + 1,
  parameter int unsigned SHIFT_AMOUNT_WIDTH_FP8 = $clog2(3 * PRECISION_BITS_FP8 + 5)
)(
  // Lane 0 (FP32 scalar / FP16-scalar / FP8-scalar)
  input  logic [PRECISION_BITS-1:0]          mantissa_c_i,
  input  logic [3*PRECISION_BITS+3:0]        product_shifted_i,
  input  logic [SHIFT_AMOUNT_WIDTH-1:0]      addend_shamt_i,
  input  logic                               effective_subtraction_i,
  input  logic                               tentative_sign_i,
  output logic                               sticky_before_add_o,
  output logic [3*PRECISION_BITS+3:0]        sum_o,
  output logic                               final_sign_o,

  // Mode select
  input  logic                               simd_enable_i,
  input  logic                               is_fp8,

  // Lane 2 (FP16-SIMD / FP8-SIMD)
  input  logic [PRECISION_BITS_SIMD-1:0]     mantissa_c_simd_i,
  input  logic [3*PRECISION_BITS_SIMD+3:0]   product_shifted_simd_i,
  input  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_i,
  input  logic                               effective_subtraction_simd_i,
  input  logic                               tentative_sign_simd_i,
  output logic                               sticky_before_add_simd_o,
  output logic [3*PRECISION_BITS_SIMD+3:0]   sum_simd_o,
  output logic                               final_sign_simd_o,

  // Lane 1 (FP8 lane 1)
  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_1_i,
  input  logic [3*PRECISION_BITS_FP8+3:0]    product_shifted_fp8_1_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_1_i,
  input  logic                               effective_subtraction_fp8_1_i,
  input  logic                               tentative_sign_fp8_1_i,
  output logic                               sticky_before_add_fp8_1_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_1_o,
  output logic                               final_sign_fp8_1_o,

  // Lane 3 (FP8 lane 2)
  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_2_i,
  input  logic [3*PRECISION_BITS_FP8+3:0]    product_shifted_fp8_2_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_2_i,
  input  logic                               effective_subtraction_fp8_2_i,
  input  logic                               tentative_sign_fp8_2_i,
  output logic                               sticky_before_add_fp8_2_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_2_o,
  output logic                               final_sign_fp8_2_o
);

  // ==========================================================================
  // Internal signals
  // ==========================================================================
  // Lane 0
  logic [PRECISION_BITS-1:0]        addend_sticky_bits;
  logic                             sticky_before_add;
  logic [3*PRECISION_BITS+3:0]      addend_after_shift;
  logic [3*PRECISION_BITS+3:0]      addend_shifted;
  logic                             inject_carry_in;
  logic [3*PRECISION_BITS+4:0]      sum_pos, sum_neg;
  logic                             sum_carry;
  logic [3*PRECISION_BITS+3:0]      sum;
  logic                             final_sign;
  logic [3*PRECISION_BITS+3:0]      product_lane0;

  // Lane 2 (SIMD)
  logic [PRECISION_BITS_SIMD-1:0]   addend_sticky_bits_simd;
  logic                             sticky_before_add_simd;
  logic [3*PRECISION_BITS_SIMD+3:0] addend_after_shift_simd;
  logic [3*PRECISION_BITS_SIMD+3:0] addend_shifted_simd;
  logic                             inject_carry_in_simd;
  logic [3*PRECISION_BITS_SIMD+4:0] sum_pos_simd, sum_neg_simd;
  logic                             sum_carry_simd;
  logic [3*PRECISION_BITS_SIMD+3:0] sum_simd;
  logic                             final_sign_simd;
  logic [3*PRECISION_BITS_SIMD+3:0] product_lane2;

  // Lane 1 (FP8_1)
  logic [PRECISION_BITS_FP8-1:0]    addend_sticky_bits_fp8_1;
  logic                             sticky_before_add_fp8_1;
  logic [3*PRECISION_BITS_FP8+3:0]  addend_after_shift_fp8_1;
  logic [3*PRECISION_BITS_FP8+3:0]  addend_shifted_fp8_1;
  logic                             inject_carry_in_fp8_1;
  logic [3*PRECISION_BITS_FP8+4:0]  sum_pos_fp8_1, sum_neg_fp8_1;
  logic                             sum_carry_fp8_1;
  logic [3*PRECISION_BITS_FP8+3:0]  sum_fp8_1;
  logic                             final_sign_fp8_1;

  // Lane 3 (FP8_2)
  logic [PRECISION_BITS_FP8-1:0]    addend_sticky_bits_fp8_2;
  logic                             sticky_before_add_fp8_2;
  logic [3*PRECISION_BITS_FP8+3:0]  addend_after_shift_fp8_2;
  logic [3*PRECISION_BITS_FP8+3:0]  addend_shifted_fp8_2;
  logic                             inject_carry_in_fp8_2;
  logic [3*PRECISION_BITS_FP8+4:0]  sum_pos_fp8_2, sum_neg_fp8_2;
  logic                             sum_carry_fp8_2;
  logic [3*PRECISION_BITS_FP8+3:0]  sum_fp8_2;
  logic                             final_sign_fp8_2;

  // ==========================================================================
  // Shared addend alignment barrel shifter
  // ==========================================================================
  logic [99:0] preshift_mantissa, addend_shift_full;

  assign preshift_mantissa = simd_enable_i ?
      is_fp8 ? {mantissa_c_i[23:20], {21{1'b0}}, mantissa_c_fp8_1_i, {21{1'b0}},
                mantissa_c_simd_i[10:7], {21{1'b0}}, mantissa_c_fp8_2_i, {21{1'b0}}}
             : {mantissa_c_i[23:13], {39{1'b0}}, mantissa_c_simd_i, {39{1'b0}}}
      : {mantissa_c_i, {76{1'b0}}};

  transdot_decomp_shifter_w4 #(
    .QUARTER_N(25)
  ) i_decomp_addend_shifter (
    .mode_i(simd_enable_i ? (is_fp8 ? 2'b10 : 2'b01) : 2'b00),
    .data_i(preshift_mantissa),
    .shamt3_i(addend_shamt_i),
    .shamt2_i(addend_shamt_fp8_1_i),
    .shamt1_i(addend_shamt_simd_i),
    .shamt0_i(addend_shamt_fp8_2_i),
    .data_o(addend_shift_full)
  );

  // ==========================================================================
  // Extract per-lane addend_after_shift and sticky bits from shifter output
  // ==========================================================================
  // Lane 0
  assign addend_after_shift = simd_enable_i ? is_fp8 ?
      {'0, addend_shift_full[99:84]}
      : {'0, addend_shift_full[99:63]}
      : addend_shift_full[99:24];
  assign addend_sticky_bits = simd_enable_i ? is_fp8 ?
      {addend_shift_full[83:80]}
      : {addend_shift_full[62:52]}
      : addend_shift_full[23:0];
  assign sticky_before_add = (|addend_sticky_bits);

  // Lane 2 (SIMD)
  assign addend_after_shift_simd = is_fp8 ?
      {'0, addend_shift_full[49:34]} : addend_shift_full[49:13];
  assign addend_sticky_bits_simd = is_fp8 ?
      {addend_shift_full[33:30]} : {addend_shift_full[12:2]};
  assign sticky_before_add_simd = (|addend_sticky_bits_simd);

  // Lane 1 (FP8_1)
  assign {addend_after_shift_fp8_1, addend_sticky_bits_fp8_1} = addend_shift_full[74:55];
  assign sticky_before_add_fp8_1 = (|addend_sticky_bits_fp8_1);

  // Lane 3 (FP8_2)
  assign {addend_after_shift_fp8_2, addend_sticky_bits_fp8_2} = addend_shift_full[24:5];
  assign sticky_before_add_fp8_2 = (|addend_sticky_bits_fp8_2);

  // ==========================================================================
  // Per-lane subtraction handling + carry injection
  // ==========================================================================
  assign inject_carry_in       = effective_subtraction_i       & ~sticky_before_add;
  assign inject_carry_in_simd  = effective_subtraction_simd_i  & ~sticky_before_add_simd;
  assign inject_carry_in_fp8_1 = effective_subtraction_fp8_1_i & ~sticky_before_add_fp8_1;
  assign inject_carry_in_fp8_2 = effective_subtraction_fp8_2_i & ~sticky_before_add_fp8_2;

  // Lane 0: invert only active data bits (width depends on mode)
  always_comb begin
    if (simd_enable_i && is_fp8)
      addend_shifted = {'0, effective_subtraction_i ? ~addend_after_shift[3*PRECISION_BITS_FP8+3:0]
                                                    :  addend_after_shift[3*PRECISION_BITS_FP8+3:0]};
    else if (simd_enable_i)
      addend_shifted = {'0, effective_subtraction_i ? ~addend_after_shift[3*PRECISION_BITS_SIMD+3:0]
                                                    :  addend_after_shift[3*PRECISION_BITS_SIMD+3:0]};
    else
      addend_shifted = effective_subtraction_i ? ~addend_after_shift : addend_after_shift;
  end

  // Lane 2: in FP8 mode only lower 16 bits are active
  always_comb begin
    if (is_fp8)
      addend_shifted_simd = {'0, effective_subtraction_simd_i ? ~addend_after_shift_simd[3*PRECISION_BITS_FP8+3:0]
                                                              :  addend_after_shift_simd[3*PRECISION_BITS_FP8+3:0]};
    else
      addend_shifted_simd = effective_subtraction_simd_i ? ~addend_after_shift_simd : addend_after_shift_simd;
  end

  // Lanes 1, 3: native FP8 width, no zero-padding issue
  assign addend_shifted_fp8_1 = effective_subtraction_fp8_1_i ? ~addend_after_shift_fp8_1 : addend_after_shift_fp8_1;
  assign addend_shifted_fp8_2 = effective_subtraction_fp8_2_i ? ~addend_after_shift_fp8_2 : addend_after_shift_fp8_2;

  // ==========================================================================
  // Per-lane product input selection
  // ==========================================================================
  always_comb begin
    if (simd_enable_i && is_fp8)
      product_lane0 = {'0, product_shifted_i[55:40]};
    else if (simd_enable_i)
      product_lane0 = {'0, product_shifted_i[62:26]};
    else
      product_lane0 = product_shifted_i;
  end

  always_comb begin
    if (is_fp8)
      product_lane2 = {'0, product_shifted_simd_i[29:14]};
    else
      product_lane2 = product_shifted_simd_i;
  end

  // ==========================================================================
  // Separate per-lane adders (positive sum)
  // ==========================================================================
  logic [3*PRECISION_BITS+4:0] sum_pos_raw;
  assign sum_pos_raw = {1'b0, product_lane0} + {1'b0, addend_shifted} + inject_carry_in;

  // Carry from raw result (position depends on active width)
  assign sum_carry = simd_enable_i ? (is_fp8 ? sum_pos_raw[3*PRECISION_BITS_FP8+4]
                                              : sum_pos_raw[3*PRECISION_BITS_SIMD+4])
                                    : sum_pos_raw[3*PRECISION_BITS+4];

  // Left-align at superformat position (FP16 offset=26, FP8 offset=40)
  always_comb begin
    if (simd_enable_i && is_fp8)
      sum_pos = {'0, sum_pos_raw[3*PRECISION_BITS_FP8+4:0], {40{1'b0}}};
    else if (simd_enable_i)
      sum_pos = {'0, sum_pos_raw[3*PRECISION_BITS_SIMD+4:0], {26{1'b0}}};
    else
      sum_pos = sum_pos_raw;
  end

  // Lane 2: FP8 result left-aligned (offset=14 within 38-bit signal)
  logic [3*PRECISION_BITS_SIMD+4:0] sum_pos_simd_raw;
  assign sum_pos_simd_raw = {1'b0, product_lane2} + {1'b0, addend_shifted_simd} + inject_carry_in_simd;

  always_comb begin
    if (is_fp8) begin
      sum_pos_simd  = {'0, sum_pos_simd_raw[3*PRECISION_BITS_FP8+4:0], {14{1'b0}}};
      sum_carry_simd = sum_pos_simd_raw[3*PRECISION_BITS_FP8+4];
    end else begin
      sum_pos_simd  = sum_pos_simd_raw;
      sum_carry_simd = sum_pos_simd_raw[3*PRECISION_BITS_SIMD+4];
    end
  end

  // Lanes 1, 3: native width
  assign sum_pos_fp8_1   = {1'b0, product_shifted_fp8_1_i} + {1'b0, addend_shifted_fp8_1} + inject_carry_in_fp8_1;
  assign sum_carry_fp8_1 = sum_pos_fp8_1[3*PRECISION_BITS_FP8+4];

  assign sum_pos_fp8_2   = {1'b0, product_shifted_fp8_2_i} + {1'b0, addend_shifted_fp8_2} + inject_carry_in_fp8_2;
  assign sum_carry_fp8_2 = sum_pos_fp8_2[3*PRECISION_BITS_FP8+4];

  // ==========================================================================
  // Separate per-lane subtractors (negative sum: addend - product)
  // ==========================================================================
  // Lane 0: operate at active width, left-align at superformat position
  always_comb begin
    if (simd_enable_i && is_fp8)
      sum_neg = $signed({addend_after_shift[3*PRECISION_BITS_FP8+3:0] - product_lane0[3*PRECISION_BITS_FP8+3:0],
                         {40{1'b0}}});
    else if (simd_enable_i)
      sum_neg = $signed({addend_after_shift[3*PRECISION_BITS_SIMD+3:0] - product_lane0[3*PRECISION_BITS_SIMD+3:0],
                         {26{1'b0}}});
    else
      sum_neg = addend_after_shift - product_lane0;
  end

  // Lane 2
  always_comb begin
    if (is_fp8)
      sum_neg_simd = {addend_after_shift_simd[3*PRECISION_BITS_FP8+3:0] - product_lane2[3*PRECISION_BITS_FP8+3:0],
                      {14{1'b0}}};
    else
      sum_neg_simd = addend_after_shift_simd - product_lane2;
  end

  // Lanes 1, 3
  assign sum_neg_fp8_1 = addend_after_shift_fp8_1 - product_shifted_fp8_1_i;
  assign sum_neg_fp8_2 = addend_after_shift_fp8_2 - product_shifted_fp8_2_i;

  // ==========================================================================
  // Sum selection and final sign (per-lane)
  // ==========================================================================
  assign sum = (effective_subtraction_i && ~sum_carry)
               ? sum_neg[3*PRECISION_BITS+3:0]
               : sum_pos[3*PRECISION_BITS+3:0];

  assign sum_simd = (effective_subtraction_simd_i && ~sum_carry_simd)
               ? sum_neg_simd[3*PRECISION_BITS_SIMD+3:0]
               : sum_pos_simd[3*PRECISION_BITS_SIMD+3:0];

  assign sum_fp8_1 = (effective_subtraction_fp8_1_i && ~sum_carry_fp8_1)
               ? sum_neg_fp8_1[3*PRECISION_BITS_FP8+3:0]
               : sum_pos_fp8_1[3*PRECISION_BITS_FP8+3:0];

  assign sum_fp8_2 = (effective_subtraction_fp8_2_i && ~sum_carry_fp8_2)
               ? sum_neg_fp8_2[3*PRECISION_BITS_FP8+3:0]
               : sum_pos_fp8_2[3*PRECISION_BITS_FP8+3:0];

  // Final sign determination
  assign final_sign = (effective_subtraction_i && (sum_carry == tentative_sign_i))
      ? 1'b1 : (effective_subtraction_i ? 1'b0 : tentative_sign_i);

  assign final_sign_simd = (effective_subtraction_simd_i && (sum_carry_simd == tentative_sign_simd_i))
      ? 1'b1 : (effective_subtraction_simd_i ? 1'b0 : tentative_sign_simd_i);

  assign final_sign_fp8_1 = (effective_subtraction_fp8_1_i && (sum_carry_fp8_1 == tentative_sign_fp8_1_i))
      ? 1'b1 : (effective_subtraction_fp8_1_i ? 1'b0 : tentative_sign_fp8_1_i);

  assign final_sign_fp8_2 = (effective_subtraction_fp8_2_i && (sum_carry_fp8_2 == tentative_sign_fp8_2_i))
      ? 1'b1 : (effective_subtraction_fp8_2_i ? 1'b0 : tentative_sign_fp8_2_i);

  // ==========================================================================
  // Output assignment
  // ==========================================================================
  assign sticky_before_add_o      = sticky_before_add;
  assign sum_o                    = sum;
  assign final_sign_o             = final_sign;

  assign sticky_before_add_simd_o = sticky_before_add_simd;
  assign sum_simd_o               = sum_simd;
  assign final_sign_simd_o        = final_sign_simd;

  assign sticky_before_add_fp8_1_o = sticky_before_add_fp8_1;
  assign sum_fp8_1_o               = sum_fp8_1;
  assign final_sign_fp8_1_o        = final_sign_fp8_1;

  assign sticky_before_add_fp8_2_o = sticky_before_add_fp8_2;
  assign sum_fp8_2_o               = sum_fp8_2;
  assign final_sign_fp8_2_o        = final_sign_fp8_2;

endmodule
