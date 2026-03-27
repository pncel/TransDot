module transdot_decomp_normalize_datapath #(
  parameter int unsigned EXP_WIDTH           = 10,
  parameter int unsigned PRECISION_BITS      = 24,
  parameter int unsigned LOWER_SUM_WIDTH     = 2*PRECISION_BITS + 3,
  parameter int unsigned SHIFT_AMOUNT_WIDTH  = 6,
  parameter int unsigned LZC_RESULT_WIDTH    = $clog2(LOWER_SUM_WIDTH),

  parameter int unsigned EXP_WIDTH_SIMD           = 7,
  parameter int unsigned PRECISION_BITS_SIMD      = 11,
  parameter int unsigned LOWER_SUM_WIDTH_SIMD     = 2*PRECISION_BITS_SIMD + 3,
  parameter int unsigned SHIFT_AMOUNT_WIDTH_SIMD  = 5,
  parameter int unsigned LZC_RESULT_WIDTH_SIMD    = $clog2(LOWER_SUM_WIDTH_SIMD),

  parameter int unsigned EXP_WIDTH_FP8           = 5,
  parameter int unsigned PRECISION_BITS_FP8      = 4,
  parameter int unsigned LOWER_SUM_WIDTH_FP8     = 2*PRECISION_BITS_FP8 + 3,
  parameter int unsigned SHIFT_AMOUNT_WIDTH_FP8  = 4,
  parameter int unsigned LZC_RESULT_WIDTH_FP8    = $clog2(LOWER_SUM_WIDTH_FP8)
)(
  // ---------------- Inputs ----------------
  input  logic                        simd_enable_i,
  input  logic                        is_fp8,

  input  logic [3*PRECISION_BITS+4-1:0]  sum_i,                   // sum (3p+4 bits)
  input  logic signed [EXP_WIDTH-1:0]  exponent_product_i,
  input  logic signed [EXP_WIDTH-1:0]  exponent_difference_i,
  input  logic signed [EXP_WIDTH-1:0]  tentative_exponent_i,
  input  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_i,
  input  logic                         effective_subtraction_i,
  input  logic                         sticky_before_add_i,

  //simd lane 1
  input  logic [3*PRECISION_BITS_SIMD+4-1:0]  sum_simd_i,                   // sum (3p+4 bits)
  input  logic signed [EXP_WIDTH_SIMD-1:0]  exponent_product_simd_i,
  input  logic signed [EXP_WIDTH_SIMD-1:0]  exponent_difference_simd_i,
  input  logic signed [EXP_WIDTH_SIMD-1:0]  tentative_exponent_simd_i,
  input  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_i,
  input  logic                         effective_subtraction_simd_i,
  input  logic                         sticky_before_add_simd_i,

  //simd lane 2
  input  logic [3*PRECISION_BITS_FP8+4-1:0]  sum_fp8_1_i,                   // sum (3p+4 bits)
  input  logic signed [EXP_WIDTH_FP8-1:0]  exponent_product_fp8_1_i,
  input  logic signed [EXP_WIDTH_FP8-1:0]  exponent_difference_fp8_1_i,
  input  logic signed [EXP_WIDTH_FP8-1:0]  tentative_exponent_fp8_1_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_1_i,
  input  logic                         effective_subtraction_fp8_1_i,
  input  logic                         sticky_before_add_fp8_1_i,

  //simd lane 3
  input  logic [3*PRECISION_BITS_FP8+4-1:0]  sum_fp8_2_i,                   // sum (3p+4 bits)
  input  logic signed [EXP_WIDTH_FP8-1:0]  exponent_product_fp8_2_i,
  input  logic signed [EXP_WIDTH_FP8-1:0]  exponent_difference_fp8_2_i,
  input  logic signed [EXP_WIDTH_FP8-1:0]  tentative_exponent_fp8_2_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_2_i,
  input  logic                         effective_subtraction_fp8_2_i,
  input  logic                         sticky_before_add_fp8_2_i,

  // ---------------- Outputs ----------------
  output logic [PRECISION_BITS:0]      final_mantissa_o,       // mantissa before rounding
  output logic signed [EXP_WIDTH-1:0]  final_exponent_o,
  output logic                         sticky_after_norm_o,
  output logic [SHIFT_AMOUNT_WIDTH-1:0] norm_shamt_o,
  output logic signed [EXP_WIDTH-1:0]  normalized_exponent_o,
  output logic [2*PRECISION_BITS+2:0]  sum_sticky_bits_o,

  //simd lane 1
  output logic [PRECISION_BITS_SIMD:0]      final_mantissa_simd_o,       // mantissa before rounding
  output logic signed [EXP_WIDTH_SIMD-1:0]  final_exponent_simd_o,
  output logic                         sticky_after_norm_simd_o,
  output logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] norm_shamt_simd_o,
  output logic signed [EXP_WIDTH_SIMD-1:0]  normalized_exponent_simd_o,
  output logic [2*PRECISION_BITS_SIMD+2:0]  sum_sticky_bits_simd_o,

    //simd lane 2
  output logic [PRECISION_BITS_FP8:0]      final_mantissa_fp8_1_o,       // mantissa before rounding
  output logic signed [EXP_WIDTH_FP8-1:0]  final_exponent_fp8_1_o,
  output logic                         sticky_after_norm_fp8_1_o,
  output logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] norm_shamt_fp8_1_o,
  output logic signed [EXP_WIDTH_FP8-1:0]  normalized_exponent_fp8_1_o,
  output logic [2*PRECISION_BITS_FP8+2:0]  sum_sticky_bits_fp8_1_o,
    //simd lane 3
  output logic [PRECISION_BITS_FP8:0]      final_mantissa_fp8_2_o,       // mantissa before rounding
  output logic signed [EXP_WIDTH_FP8-1:0]  final_exponent_fp8_2_o,
  output logic                         sticky_after_norm_fp8_2_o,
  output logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] norm_shamt_fp8_2_o,
  output logic signed [EXP_WIDTH_FP8-1:0]  normalized_exponent_fp8_2_o,
  output logic [2*PRECISION_BITS_FP8+2:0]  sum_sticky_bits_fp8_2_o
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

    //simd lane 1
  logic [LOWER_SUM_WIDTH_SIMD-1:0]  sum_lower_simd;
  logic [LZC_RESULT_WIDTH_SIMD-1:0] leading_zero_count_simd;
  logic signed [LZC_RESULT_WIDTH_SIMD:0] leading_zero_count_sgn_simd;
  logic                        lzc_zeroes_simd;

  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] norm_shamt_simd;
  logic signed [EXP_WIDTH_SIMD-1:0]   normalized_exponent_simd;

  logic [3*PRECISION_BITS_SIMD+4:0] sum_shifted_simd;
  logic [PRECISION_BITS_SIMD:0]     final_mantissa_simd;
  logic [2*PRECISION_BITS_SIMD+2:0] sum_sticky_bits_simd;
  logic                        sticky_after_norm_simd;
  logic signed [EXP_WIDTH_SIMD-1:0] final_exponent_simd;

  //simd lane 2
  logic [LOWER_SUM_WIDTH_FP8-1:0]  sum_lower_fp8_1;
  logic [LZC_RESULT_WIDTH_FP8-1:0] leading_zero_count_fp8_1;
  logic signed [LZC_RESULT_WIDTH_FP8:0] leading_zero_count_sgn_fp8_1;
  logic                        lzc_zeroes_fp8_1;

  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] norm_shamt_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0]   normalized_exponent_fp8_1;

  logic [3*PRECISION_BITS_FP8+4:0] sum_shifted_fp8_1;
  logic [PRECISION_BITS_FP8:0]     final_mantissa_fp8_1;
  logic [2*PRECISION_BITS_FP8+2:0] sum_sticky_bits_fp8_1;
  logic                        sticky_after_norm_fp8_1;
  logic signed [EXP_WIDTH_FP8-1:0] final_exponent_fp8_1;

  //simd lane 3
  logic [LOWER_SUM_WIDTH_FP8-1:0]  sum_lower_fp8_2;
  logic [LZC_RESULT_WIDTH_FP8-1:0] leading_zero_count_fp8_2;
  logic signed [LZC_RESULT_WIDTH_FP8:0] leading_zero_count_sgn_fp8_2;
  logic                        lzc_zeroes_fp8_2;

  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0] norm_shamt_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0]   normalized_exponent_fp8_2;
  logic [3*PRECISION_BITS_FP8+4:0] sum_shifted_fp8_2;
  logic [PRECISION_BITS_FP8:0]     final_mantissa_fp8_2;
  logic [2*PRECISION_BITS_FP8+2:0] sum_sticky_bits_fp8_2;
  logic                        sticky_after_norm_fp8_2;
  logic signed [EXP_WIDTH_FP8-1:0] final_exponent_fp8_2;

  // --------------------------------------------------------------------------
  // Leading-zero counter
  // --------------------------------------------------------------------------
  //assign sum_lower = simd_enable_i ? {sum_i[2*PRECISION_BITS-2*PRECISION_BITS_SIMD+:LOWER_SUM_WIDTH_SIMD],{LOWER_SUM_WIDTH-LOWER_SUM_WIDTH_SIMD{1'b0}}} : sum_i[LOWER_SUM_WIDTH-1:0];
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

  //simd lane 1
  assign sum_lower_simd = sum_simd_i[LOWER_SUM_WIDTH_SIMD-1:0];
  lzc #(
    .WIDTH ( LOWER_SUM_WIDTH_SIMD ),
    .MODE  ( 1 )  // count leading zeros
  ) i_lzc_simd (
    .in_i    ( sum_lower_simd ),
    .cnt_o   ( leading_zero_count_simd ),
    .empty_o ( lzc_zeroes_simd )
  );

  assign leading_zero_count_sgn_simd = signed'({1'b0, leading_zero_count_simd});

  //simd lane 2
  assign sum_lower_fp8_1 = sum_fp8_1_i[LOWER_SUM_WIDTH_FP8-1:0];
  lzc #(
    .WIDTH ( LOWER_SUM_WIDTH_FP8 ),
    .MODE  ( 1 )  // count leading zeros
  ) i_lzc_fp8_1 (
    .in_i    ( sum_lower_fp8_1 ),
    .cnt_o   ( leading_zero_count_fp8_1 ),
    .empty_o ( lzc_zeroes_fp8_1 )
  );

  assign leading_zero_count_sgn_fp8_1 = signed'({1'b0, leading_zero_count_fp8_1});

  //simd lane 3
  assign sum_lower_fp8_2 = sum_fp8_2_i[LOWER_SUM_WIDTH_FP8-1:0];
  lzc #(
    .WIDTH ( LOWER_SUM_WIDTH_FP8 ),
    .MODE  ( 1 )  // count leading zeros
  ) i_lzc_fp8_2 (
    .in_i    ( sum_lower_fp8_2 ),
    .cnt_o   ( leading_zero_count_fp8_2 ),
    .empty_o ( lzc_zeroes_fp8_2 )
  );

  assign leading_zero_count_sgn_fp8_2 = signed'({1'b0, leading_zero_count_fp8_2});

  // --------------------------------------------------------------------------
  // Normalization shift amount calculation
  // --------------------------------------------------------------------------
  always_comb begin : norm_shift_amount
    if ((exponent_difference_i <= 0) ||
        (effective_subtraction_i && (exponent_difference_i <= 2))) begin
      // --- Product-anchored case or cancellation ---
      if ((exponent_product_i - leading_zero_count_sgn + 1 >= 0) && !lzc_zeroes) begin
        // Normal result
        norm_shamt          = simd_enable_i? (is_fp8? (PRECISION_BITS_FP8 + 2 + leading_zero_count) : (PRECISION_BITS_SIMD + 2 + leading_zero_count)) : (PRECISION_BITS + 2 + leading_zero_count);
        normalized_exponent = exponent_product_i - leading_zero_count_sgn + 1;
      end else begin
        // Subnormal result (shift until exponent = 0)
        //norm_shamt          = simd_enable_i? unsigned'(signed'(PRECISION_BITS_SIMD + 2 + exponent_product_i)): unsigned'(signed'(PRECISION_BITS + 2 + exponent_product_i));
        norm_shamt          = simd_enable_i? (is_fp8? unsigned'(signed'(PRECISION_BITS_FP8 + 2 + exponent_product_i)) : unsigned'(signed'(PRECISION_BITS_SIMD + 2 + exponent_product_i))) : unsigned'(signed'(PRECISION_BITS + 2 + exponent_product_i));
        normalized_exponent = 0;
      end
    end else begin
      // --- Addend-anchored case ---
      norm_shamt          = addend_shamt_i;
      normalized_exponent = tentative_exponent_i;
    end
  end


  //simd lane 1
    always_comb begin : norm_shift_amount_simd
      if ((exponent_difference_simd_i <= 0) ||
          (effective_subtraction_simd_i && (exponent_difference_simd_i <= 2))) begin
        // --- Product-anchored case or cancellation ---
        if ((exponent_product_simd_i - leading_zero_count_sgn_simd + 1 >= 0) && !lzc_zeroes_simd) begin
          // Normal result
          norm_shamt_simd          = is_fp8? PRECISION_BITS_FP8 + 2 + leading_zero_count_simd : PRECISION_BITS_SIMD + 2 + leading_zero_count_simd;
          normalized_exponent_simd = exponent_product_simd_i - leading_zero_count_sgn_simd + 1;
        end else begin
          // Subnormal result (shift until exponent = 0)
          norm_shamt_simd          = is_fp8? unsigned'(signed'(PRECISION_BITS_FP8 + 2 + exponent_product_simd_i)) : unsigned'(signed'(PRECISION_BITS_SIMD + 2 + exponent_product_simd_i));
          normalized_exponent_simd = 0;
        end
      end else begin
        // --- Addend-anchored case ---
        norm_shamt_simd          = addend_shamt_simd_i;
        normalized_exponent_simd = tentative_exponent_simd_i;
      end
    end 

  //simd lane 2
  always_comb begin : norm_shift_amount_fp8_1
    if ((exponent_difference_fp8_1_i <= 0) ||
        (effective_subtraction_fp8_1_i && (exponent_difference_fp8_1_i <= 2))) begin
      // --- Product-anchored case or cancellation ---
      if ((exponent_product_fp8_1_i - leading_zero_count_sgn_fp8_1 + 1 >= 0) && !lzc_zeroes_fp8_1) begin
        // Normal result
        norm_shamt_fp8_1          = PRECISION_BITS_FP8 + 2 + leading_zero_count_fp8_1;
        normalized_exponent_fp8_1 = exponent_product_fp8_1_i - leading_zero_count_sgn_fp8_1 + 1;
      end else begin
        // Subnormal result (shift until exponent = 0)
        norm_shamt_fp8_1          = unsigned'(signed'(PRECISION_BITS_FP8 + 2 + exponent_product_fp8_1_i));
        normalized_exponent_fp8_1 = 0;
      end
    end else begin
      // --- Addend-anchored case ---
      norm_shamt_fp8_1          = addend_shamt_fp8_1_i;
      normalized_exponent_fp8_1 = tentative_exponent_fp8_1_i;
    end
  end 

  //simd lane 3
  always_comb begin : norm_shift_amount_fp8_2
    if ((exponent_difference_fp8_2_i <= 0) ||
        (effective_subtraction_fp8_2_i && (exponent_difference_fp8_2_i <= 2))) begin
      // --- Product-anchored case or cancellation ---
      if ((exponent_product_fp8_2_i - leading_zero_count_sgn_fp8_2 + 1 >= 0) && !lzc_zeroes_fp8_2) begin
        // Normal result
        norm_shamt_fp8_2          = PRECISION_BITS_FP8 + 2 + leading_zero_count_fp8_2;
        normalized_exponent_fp8_2 = exponent_product_fp8_2_i - leading_zero_count_sgn_fp8_2 + 1;
      end else begin
        // Subnormal result (shift until exponent = 0)
        norm_shamt_fp8_2          = unsigned'(signed'(PRECISION_BITS_FP8 + 2 + exponent_product_fp8_2_i));
        normalized_exponent_fp8_2 = 0;
      end
    end else begin
      // --- Addend-anchored case ---
      norm_shamt_fp8_2          = addend_shamt_fp8_2_i;
      normalized_exponent_fp8_2 = tentative_exponent_fp8_2_i;
    end
  end 
  // --------------------------------------------------------------------------
  // Large normalization shift
  // --------------------------------------------------------------------------
  //shifter_unsigned #(
  //  .WIDTH      ( 3*PRECISION_BITS + 4 ),
  //  .SHIFT_WIDTH ( SHIFT_AMOUNT_WIDTH )
  //) i_large_norm_shift (
  //  .in_i   ( sum_i ),
  //  .shift_amount_i  ( norm_shamt ),
  //  .out_o   ( sum_shifted )
  //);
  //shifter_unsigned #(
  //  .WIDTH      ( 3*PRECISION_BITS_SIMD + 4 ),
  //  .SHIFT_WIDTH ( SHIFT_AMOUNT_WIDTH_SIMD )
  //) i_large_norm_shift_simd (
  //  .in_i   ( sum_simd_i ),
  //  .shift_amount_i  ( norm_shamt_simd ),
  //  .out_o   ( sum_shifted_simd )
  //);

  //assign sum_shifted = sum_i << norm_shamt;
  //assign sum_shifted_simd = sum_simd_i << norm_shamt_simd;

  localparam int unsigned HALF_N = 40;//40
  logic [79:0] sum_i_merged; //40 bit
  logic [79:0] sum_shifted_merged; //40 bit
  assign sum_i_merged = simd_enable_i ? is_fp8?
        {4'd0,sum_i[55:40],4'd0, sum_fp8_1_i,4'd0,sum_simd_i[29:14], 4'd0, sum_fp8_2_i}
        : {3'd0,sum_i[62:26],3'd0,sum_simd_i[36:0]}
        : {'0,sum_i}; //extend 1 bit for uniform width
  transdot_decomp_shifter_left_w4 #(
    .QUARTER_N( 20 )
  ) i_large_norm_shift_comb (
    .mode_i(simd_enable_i? (is_fp8? 2'b10:2'b01) : 2'b00),
    .data_i          ( sum_i_merged ),
    .shamt3_i         ( norm_shamt ),
    .shamt2_i         ( norm_shamt_fp8_1 ),
    .shamt1_i         ( norm_shamt_simd ),
    .shamt0_i         ( norm_shamt_fp8_2 ),
    .data_o          ( sum_shifted_merged )
  );

  
  assign sum_shifted = simd_enable_i ? is_fp8?
                      {'0,sum_shifted_merged[76:60],60'd0}
                      :{'0,sum_shifted_merged[77:40],39'd0} 
                      : sum_shifted_merged[76:0];
  assign sum_shifted_simd = is_fp8? {'0,sum_shifted_merged[36:20], 21'd0}: sum_shifted_merged[37:0];

  assign sum_shifted_fp8_1 = sum_shifted_merged[56:40];
  assign sum_shifted_fp8_2 = sum_shifted_merged[16:0];

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

  //simd lane 1
    always_comb begin : small_norm_simd
      {final_mantissa_simd, sum_sticky_bits_simd} = sum_shifted_simd;
      final_exponent_simd                    = normalized_exponent_simd;

      // Overflow → shift right and increment exponent
      if (sum_shifted_simd[3*PRECISION_BITS_SIMD+4]) begin
        {final_mantissa_simd, sum_sticky_bits_simd} = sum_shifted_simd >> 1;
        final_exponent_simd                    = normalized_exponent_simd + 1;

      // Normalized case → do nothing
      end else if (sum_shifted_simd[3*PRECISION_BITS_SIMD+3]) begin
        // nothing

      // Still denormal but not true subnormal → shift left once and decrement exponent
      end else if (normalized_exponent_simd > 1) begin
        {final_mantissa_simd, sum_sticky_bits_simd} = sum_shifted_simd << 1;
        final_exponent_simd                    = normalized_exponent_simd - 1;

      // Truly subnormal result
      end else begin
        final_exponent_simd = '0;
      end
    end

    //simd lane 1
    always_comb begin : small_norm_fp8_1
      {final_mantissa_fp8_1, sum_sticky_bits_fp8_1} = sum_shifted_fp8_1;
      final_exponent_fp8_1                    = normalized_exponent_fp8_1;

      // Overflow → shift right and increment exponent
      if (sum_shifted_fp8_1[3*PRECISION_BITS_FP8+4]) begin
        {final_mantissa_fp8_1, sum_sticky_bits_fp8_1} = sum_shifted_fp8_1 >> 1;
        final_exponent_fp8_1                    = normalized_exponent_fp8_1 + 1;

      // Normalized case → do nothing
      end else if (sum_shifted_fp8_1[3*PRECISION_BITS_FP8+3]) begin
        // nothing

      // Still denormal but not true subnormal → shift left once and decrement exponent
      end else if (normalized_exponent_fp8_1 > 1) begin
        {final_mantissa_fp8_1, sum_sticky_bits_fp8_1} = sum_shifted_fp8_1 << 1;
        final_exponent_fp8_1                    = normalized_exponent_fp8_1 - 1;

      // Truly subnormal result
      end else begin
        final_exponent_fp8_1 = '0;
      end
    end

    //simd lane 1
    always_comb begin : small_norm_fp8_2
          {final_mantissa_fp8_2, sum_sticky_bits_fp8_2} = sum_shifted_fp8_2;
          final_exponent_fp8_2                    = normalized_exponent_fp8_2;

      // Overflow → shift right and increment exponent
      if (sum_shifted_fp8_2[3*PRECISION_BITS_FP8+4]) begin
        {final_mantissa_fp8_2, sum_sticky_bits_fp8_2} = sum_shifted_fp8_2 >> 1;
        final_exponent_fp8_2                    = normalized_exponent_fp8_2 + 1;

      // Normalized case → do nothing
      end else if (sum_shifted_fp8_2[3*PRECISION_BITS_FP8+3]) begin
        // nothing

      // Still denormal but not true subnormal → shift left once and decrement exponent
      end else if (normalized_exponent_fp8_2 > 1) begin
        {final_mantissa_fp8_2, sum_sticky_bits_fp8_2} = sum_shifted_fp8_2 << 1;
        final_exponent_fp8_2                    = normalized_exponent_fp8_2 - 1;

      // Truly subnormal result
      end else begin
        final_exponent_fp8_2 = '0;
      end
    end

  // --------------------------------------------------------------------------
  // Sticky update
  // --------------------------------------------------------------------------
  assign sticky_after_norm = (| sum_sticky_bits) | sticky_before_add_i;
    //simd lane 1
  assign sticky_after_norm_simd = (| sum_sticky_bits_simd) | sticky_before_add_simd_i;
  //simd lane 2
  assign sticky_after_norm_fp8_1 = (| sum_sticky_bits_fp8_1) | sticky_before_add_fp8_1_i;
  //simd lane 3
  assign sticky_after_norm_fp8_2 = (| sum_sticky_bits_fp8_2) | sticky_before_add_fp8_2_i;

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  assign final_mantissa_o       = final_mantissa;
  assign final_exponent_o       = final_exponent;
  assign sticky_after_norm_o    = sticky_after_norm;
  assign norm_shamt_o           = norm_shamt;
  assign normalized_exponent_o  = normalized_exponent;
  assign sum_sticky_bits_o      = sum_sticky_bits;

  //simd lane 1
  assign final_mantissa_simd_o       = final_mantissa_simd;
  assign final_exponent_simd_o       = final_exponent_simd;
  assign sticky_after_norm_simd_o    = sticky_after_norm_simd;
  assign norm_shamt_simd_o           = norm_shamt_simd;
  assign normalized_exponent_simd_o  = normalized_exponent_simd;
  assign sum_sticky_bits_simd_o      = sum_sticky_bits_simd;

  //simd lane 2
  assign final_mantissa_fp8_1_o       = final_mantissa_fp8_1;
  assign final_exponent_fp8_1_o       = final_exponent_fp8_1;
  assign sticky_after_norm_fp8_1_o    = sticky_after_norm_fp8_1;
  assign norm_shamt_fp8_1_o           = norm_shamt_fp8_1;
  assign normalized_exponent_fp8_1_o  = normalized_exponent_fp8_1;
  assign sum_sticky_bits_fp8_1_o      = sum_sticky_bits_fp8_1;

  //simd lane 3
  assign final_mantissa_fp8_2_o       = final_mantissa_fp8_2;
  assign final_exponent_fp8_2_o       = final_exponent_fp8_2;
  assign sticky_after_norm_fp8_2_o    = sticky_after_norm_fp8_2;
  assign norm_shamt_fp8_2_o           = norm_shamt_fp8_2;
  assign normalized_exponent_fp8_2_o  = normalized_exponent_fp8_2;
  assign sum_sticky_bits_fp8_2_o      = sum_sticky_bits_fp8_2;  

endmodule