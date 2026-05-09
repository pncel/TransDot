module transdot_decomp_exponent_datapath_fp8 #(
  parameter int unsigned EXP_WIDTH           = 10,  // internal exponent width
  parameter int unsigned SUPER_EXP_BITS      = 8,  // exponent width of superformat
  parameter int unsigned SUPER_MAN_BITS      = 23,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS      = 24,  // mantissa precision bits (e.g., FP64)
  parameter int unsigned SHIFT_AMOUNT_WIDTH  = 7,   // must hold up to 3*PRECISION_BITS+4
  parameter int unsigned EXP_WIDTH_SIMD           = 7,  // internal exponent width
  parameter int unsigned SUPER_EXP_BITS_SIMD      = 5,  // exponent width of superformat
  parameter int unsigned SUPER_MAN_BITS_SIMD      = 10,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS_SIMD      = 11,  // mantissa precision bits (e.g., FP64)
  parameter int unsigned SHIFT_AMOUNT_WIDTH_SIMD  = 6,   // must hold up to 3*PRECISION_BITS+4
  parameter int unsigned EXP_WIDTH_FP8           = 6,  // internal exponent width
  parameter int unsigned SUPER_EXP_BITS_FP8      = 4,  // exponent width of superformat
  parameter int unsigned SUPER_MAN_BITS_FP8      = 3,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS_FP8      = 4,  // mantissa precision bits (e.g., FP64)
  parameter int unsigned SHIFT_AMOUNT_WIDTH_FP8  = 5   // must hold up to 3*PRECISION_BITS+4
   
)(
  // ---------------- Inputs ----------------
  // Operands
  input  logic [SUPER_EXP_BITS-1:0]               exponent_a_i,
  input  logic [SUPER_EXP_BITS-1:0]               exponent_b_i,
  input  logic [SUPER_EXP_BITS-1:0]               exponent_c_i,
  input  logic [SUPER_MAN_BITS-1:0]          mantissa_c_i,

  // Operands_SIMD
  input  logic [SUPER_EXP_BITS_SIMD-1:0]               exponent_a_simd_i,
  input  logic [SUPER_EXP_BITS_SIMD-1:0]               exponent_b_simd_i,
  input  logic [SUPER_EXP_BITS_SIMD-1:0]               exponent_c_simd_i,
  input  logic [SUPER_MAN_BITS_SIMD-1:0]          mantissa_c_simd_i,

  //Operands lane 2
  input  logic [SUPER_EXP_BITS_FP8-1:0]               exponent_a_fp8_1_i,
  input  logic [SUPER_EXP_BITS_FP8-1:0]               exponent_b_fp8_1_i,
  input  logic [SUPER_EXP_BITS_FP8-1:0]               exponent_c_fp8_1_i,
  input  logic [SUPER_MAN_BITS_FP8-1:0]          mantissa_c_fp8_1_i,

  //operands lane 3
  input  logic [SUPER_EXP_BITS_FP8-1:0]               exponent_a_fp8_2_i,
  input  logic [SUPER_EXP_BITS_FP8-1:0]               exponent_b_fp8_2_i,
  input  logic [SUPER_EXP_BITS_FP8-1:0]               exponent_c_fp8_2_i,
  input  logic [SUPER_MAN_BITS_FP8-1:0]          mantissa_c_fp8_2_i,

  // Classification info
  input  fpnew_pkg::fp_info_t                info_a_i,
  input  fpnew_pkg::fp_info_t                info_b_i,
  input  fpnew_pkg::fp_info_t                info_c_i,
  // Classification info
  input  fpnew_pkg::fp_info_t                info_a_simd_i,
  input  fpnew_pkg::fp_info_t                info_b_simd_i,
  input  fpnew_pkg::fp_info_t                info_c_simd_i,
  // Classification info lane 2
  input  fpnew_pkg::fp_info_t                info_a_fp8_1_i,
  input  fpnew_pkg::fp_info_t                info_b_fp8_1_i,
  input  fpnew_pkg::fp_info_t                info_c_fp8_1_i,
  // Classification info lane 3
  input  fpnew_pkg::fp_info_t                info_a_fp8_2_i,
  input  fpnew_pkg::fp_info_t                info_b_fp8_2_i,
  input  fpnew_pkg::fp_info_t                info_c_fp8_2_i,

  // Format indices
  input  fpnew_pkg::fp_format_e              src_fmt_i,
  input  fpnew_pkg::fp_format_e              src2_fmt_i,
  input  fpnew_pkg::fp_format_e              dst_fmt_i,

  //mode
  input  logic                               dp_enable_i,
  input  logic                               simd_enable_i,
  input  logic                               fp4_enable_i,

  // OCP MX (microscaling) sideband. When mx_enable_i=1, the per-block scale
  // pair (mx_scale_a_i, mx_scale_b_i) is added into exp_product_lane0 as
  // (s_A + s_B - 254). Both scales are E8M0 (unsigned 8-bit, biased 127).
  // Active only when dp_enable_i=1 (FP4-DP / FP8-DP / FP16-DP geometry).
  input  logic                               mx_enable_i,
  input  logic [7:0]                         mx_scale_a_i,
  input  logic [7:0]                         mx_scale_b_i,

  // ---------------- Outputs ----------------
  output logic signed [EXP_WIDTH-1:0]        exponent_addend_o,
  output logic signed [EXP_WIDTH-1:0]        exponent_product_o,
  output logic signed [EXP_WIDTH-1:0]        exponent_difference_o,
  output logic signed [EXP_WIDTH-1:0]        tentative_exponent_o,
  output logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_o,
  output logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_large_o,
  output logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_small_o,
  output logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_normalize_shamt_o,

  output logic signed [EXP_WIDTH_SIMD-1:0]        exponent_addend_simd_o,
  output logic signed [EXP_WIDTH_SIMD-1:0]        exponent_product_simd_o,
  output logic signed [EXP_WIDTH_SIMD-1:0]        exponent_difference_simd_o,
  output logic signed [EXP_WIDTH_SIMD-1:0]        tentative_exponent_simd_o,
  output logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_o,
  output logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_small_simd_o,
  output logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_normalize_shamt_simd_o,

  output logic signed [EXP_WIDTH_FP8-1:0]        exponent_addend_fp8_1_o,
  output logic signed [EXP_WIDTH_FP8-1:0]        exponent_product_fp8_1_o,
  output logic signed [EXP_WIDTH_FP8-1:0]        exponent_difference_fp8_1_o,
  output logic signed [EXP_WIDTH_FP8-1:0]        tentative_exponent_fp8_1_o,
  output logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_1_o,
  output logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_1_o,

  output logic signed [EXP_WIDTH_FP8-1:0]        exponent_addend_fp8_2_o,
  output logic signed [EXP_WIDTH_FP8-1:0]        exponent_product_fp8_2_o,
  output logic signed [EXP_WIDTH_FP8-1:0]        exponent_difference_fp8_2_o,
  output logic signed [EXP_WIDTH_FP8-1:0]        tentative_exponent_fp8_2_o,
  output logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_2_o,
  output logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_2_o,


  output logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] dp_shamt0_o,
  output logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] dp_shamt1_o,
  output logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] dp_shamt2_o,
  output logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] dp_shamt3_o
);

  // --------------------------------------------------------------------------
  // Local variables
  // --------------------------------------------------------------------------
  logic signed [EXP_WIDTH-1:0] exponent_a, exponent_b, exponent_c;
  logic signed [EXP_WIDTH-1:0] exponent_addend, exponent_product, exponent_difference;
  logic signed [EXP_WIDTH-1:0] tentative_exponent;
  logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt,addend_shamt_super_small_precision,addend_shamt_small_precision,addend_shamt_large_precision;
  logic        [SHIFT_AMOUNT_WIDTH-1:0] addend_normalize_shamt;

  logic signed [EXP_WIDTH-1:0] exponent_a_simd, exponent_b_simd, exponent_c_simd;
  logic signed [EXP_WIDTH-1:0] exponent_addend_simd, exponent_product_simd, exponent_difference_simd;
  logic signed [EXP_WIDTH-1:0] tentative_exponent_simd;
  logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd, addend_shamt_super_small_precision_simd, addend_shamt_small_precision_simd;
  logic        [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_normalize_shamt_simd;

  logic signed [EXP_WIDTH-1:0] exponent_a_fp8_1, exponent_b_fp8_1, exponent_c_fp8_1;
  logic signed [EXP_WIDTH-1:0] exponent_addend_fp8_1, exponent_product_fp8_1, exponent_difference_fp8_1;
  logic signed [EXP_WIDTH-1:0] tentative_exponent_fp8_1;
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_1;
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_1;

  logic signed [EXP_WIDTH-1:0] exponent_a_fp8_2, exponent_b_fp8_2, exponent_c_fp8_2;
  logic signed [EXP_WIDTH-1:0] exponent_addend_fp8_2, exponent_product_fp8_2, exponent_difference_fp8_2;
  logic signed [EXP_WIDTH-1:0] tentative_exponent_fp8_2;
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_shamt_fp8_2;
  logic        [SHIFT_AMOUNT_WIDTH_FP8-1:0] addend_normalize_shamt_fp8_2;
  // Leading zero counter signals
  logic [$clog2(SUPER_MAN_BITS)-1:0] addend_lzc_count;
  logic [$clog2(SUPER_MAN_BITS)  :0] addend_lzc_count_sgn;

  logic [$clog2(SUPER_MAN_BITS_SIMD)-1:0] addend_lzc_count_simd;
  logic [$clog2(SUPER_MAN_BITS_SIMD)  :0] addend_lzc_count_sgn_simd;

  logic [$clog2(SUPER_MAN_BITS_FP8)-1:0] addend_lzc_count_fp8_1;
  logic [$clog2(SUPER_MAN_BITS_FP8)  :0] addend_lzc_count_sgn_fp8_1;

  logic [$clog2(SUPER_MAN_BITS_FP8)-1:0] addend_lzc_count_fp8_2;
  logic [$clog2(SUPER_MAN_BITS_FP8)  :0] addend_lzc_count_sgn_fp8_2;

  // --------------------------------------------------------------------------
  // Exponent preprocessing (zero-extend into signed)
  // --------------------------------------------------------------------------
  assign exponent_a = signed'({1'b0, exponent_a_i});
  assign exponent_b = signed'({1'b0, exponent_b_i});
  assign exponent_c = signed'({1'b0, exponent_c_i});

  assign exponent_a_simd = {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_SIMD){1'b0}},exponent_a_simd_i};
  assign exponent_b_simd = {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_SIMD){1'b0}},exponent_b_simd_i};
  assign exponent_c_simd = dp_enable_i ? exponent_c : {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_SIMD){1'b0}},exponent_c_simd_i}; 

  assign exponent_a_fp8_1 = {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_FP8){1'b0}},exponent_a_fp8_1_i};
  assign exponent_b_fp8_1 = {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_FP8){1'b0}},exponent_b_fp8_1_i};
  assign exponent_c_fp8_1 = dp_enable_i ? exponent_c : {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_FP8){1'b0}},exponent_c_fp8_1_i};

  assign exponent_a_fp8_2 = {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_FP8){1'b0}},exponent_a_fp8_2_i};
  assign exponent_b_fp8_2 = {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_FP8){1'b0}},exponent_b_fp8_2_i};
  assign exponent_c_fp8_2 = dp_enable_i ? exponent_c : {{(1+SUPER_EXP_BITS-SUPER_EXP_BITS_FP8){1'b0}},exponent_c_fp8_2_i};



  fpnew_pkg::fp_info_t                info_c_lane1, info_c_lane2, info_c_lane3;
  assign info_c_lane1 = dp_enable_i ? info_c_i : info_c_simd_i;
  assign info_c_lane2 = dp_enable_i ? info_c_i : info_c_fp8_1_i;
  assign info_c_lane3 = dp_enable_i ? info_c_i : info_c_fp8_2_i;
  // --------------------------------------------------------------------------
  // Compute internal biased exponents
  // --------------------------------------------------------------------------
  logic signed [EXP_WIDTH-1:0] exponent_addend_bias_offset, exponent_product_bias_offset, exponent_product_subnormal;
  assign exponent_addend_bias_offset = signed'(fpnew_pkg::bias(dst_fmt_i)) - signed'(fpnew_pkg::bias(src2_fmt_i));
  assign exponent_product_bias_offset = signed'(fpnew_pkg::bias(dst_fmt_i)) - 2 * signed'(fpnew_pkg::bias(src_fmt_i));
  assign exponent_product_subnormal = 2 - signed'(fpnew_pkg::bias(dst_fmt_i));
  // Addend exponent rebias
  assign exponent_addend = info_c_i.is_zero ? 1 : signed'(exponent_c
                + $signed({1'b0, ~info_c_i.is_normal}) // 0 if normal, 1 if subnormal
                + exponent_addend_bias_offset);

  assign exponent_addend_simd = info_c_lane1.is_zero ? 1 : signed'(exponent_c_simd
                + $signed({1'b0, ~info_c_lane1.is_normal}) // 0 if normal, 1 if subnormal
                + exponent_addend_bias_offset);

  assign exponent_addend_fp8_1 = info_c_lane2.is_zero ? 1 : signed'(exponent_c_fp8_1
                + $signed({1'b0, ~info_c_lane2.is_normal}) // 0 if normal, 1 if subnormal
                + exponent_addend_bias_offset);

  assign exponent_addend_fp8_2 = info_c_lane3.is_zero ? 1 : signed'(exponent_c_fp8_2
                + $signed({1'b0, ~info_c_lane3.is_normal}) // 0 if normal, 1 if subnormal
                + exponent_addend_bias_offset);

  // Product exponent rebias
  assign exponent_product = (info_a_i.is_zero || info_b_i.is_zero) ? exponent_product_subnormal
      : signed'(exponent_a + info_a_i.is_subnormal
                + exponent_b + info_b_i.is_subnormal
                + exponent_product_bias_offset);

  assign exponent_product_simd =
    (info_a_simd_i.is_zero || info_b_simd_i.is_zero) ? exponent_product_subnormal 
      : signed'(exponent_a_simd + info_a_simd_i.is_subnormal
                + exponent_b_simd + info_b_simd_i.is_subnormal
                + exponent_product_bias_offset);

  assign exponent_product_fp8_1 =
    (info_a_fp8_1_i.is_zero || info_b_fp8_1_i.is_zero) ? exponent_product_subnormal 
      : signed'(exponent_a_fp8_1 + info_a_fp8_1_i.is_subnormal
                + exponent_b_fp8_1 + info_b_fp8_1_i.is_subnormal
                + exponent_product_bias_offset);  

  assign exponent_product_fp8_2 =
    (info_a_fp8_2_i.is_zero || info_b_fp8_2_i.is_zero) ? exponent_product_subnormal 
      : signed'(exponent_a_fp8_2 + info_a_fp8_2_i.is_subnormal
                + exponent_b_fp8_2 + info_b_fp8_2_i.is_subnormal
                + exponent_product_bias_offset);

  // in dp mode, check which exponent is larger
  // Lane 0/1 carry FP16-DP / BF16-DP (8-bit biased exp; sum needs 9 b).
  // Lane 2/3 carry FP8-DP only (4-bit biased exp; sum fits in 5 b — leave 6).
  // The 6-b truncation that worked for FP16 (5-b biased exp) breaks BF16's
  // 8-b biased exp, so widen the lane-0/1 reduced sums to SUPER_EXP_BITS+1.
  localparam int unsigned RED_EXP_W_01  = SUPER_EXP_BITS + 1;       // 9 for SUPER_EXP_BITS=8
  localparam int unsigned RED_EXP_W_23  = 6;
  logic [RED_EXP_W_01-1:0] reduced_exponent_product_lane0, reduced_exponent_product_lane1;
  logic [RED_EXP_W_23-1:0] reduced_exponent_product_lane2, reduced_exponent_product_lane3;
  assign reduced_exponent_product_lane0 = (info_a_i.is_zero || info_b_i.is_zero)             ? '0 : exponent_a[SUPER_EXP_BITS-1:0]         + exponent_b[SUPER_EXP_BITS-1:0];
  assign reduced_exponent_product_lane1 = (info_a_simd_i.is_zero || info_b_simd_i.is_zero)   ? '0 : exponent_a_simd[SUPER_EXP_BITS-1:0]    + exponent_b_simd[SUPER_EXP_BITS-1:0];
  assign reduced_exponent_product_lane2 = (info_a_fp8_1_i.is_zero || info_b_fp8_1_i.is_zero) ? '0 : exponent_a_fp8_1[4:0]                  + exponent_b_fp8_1[4:0];
  assign reduced_exponent_product_lane3 = (info_a_fp8_2_i.is_zero || info_b_fp8_2_i.is_zero) ? '0 : exponent_a_fp8_2[4:0]                  + exponent_b_fp8_2[4:0];

  logic larger_exp_product_flag_0_1;
  assign larger_exp_product_flag_0_1 = (reduced_exponent_product_lane0 > reduced_exponent_product_lane1) ? 1'b1 : 1'b0;
  logic larger_exp_product_flag_2_3;
  assign larger_exp_product_flag_2_3 = (reduced_exponent_product_lane2 > reduced_exponent_product_lane3) ? 1'b1 : 1'b0;


  logic signed [EXP_WIDTH-1:0] exp_product_lane0;
  logic [RED_EXP_W_01-1:0] large_exp_product_0_1;
  logic [RED_EXP_W_23-1:0] large_exp_product_2_3;
  logic [RED_EXP_W_01-1:0] reduced_large_exp_product;
  assign large_exp_product_0_1 = larger_exp_product_flag_0_1? reduced_exponent_product_lane0 : reduced_exponent_product_lane1;
  assign large_exp_product_2_3 = larger_exp_product_flag_2_3? reduced_exponent_product_lane2 : reduced_exponent_product_lane3;

  logic larger_exp_product_flag_group_0_1;
  // For FP16 / BF16 (FP16ALT) the FP8-DP lanes 2/3 are inactive (their
  // fp8_1/fp8_2 decoders gate on fmt==FP8 only), so their reduced exponents
  // are don't-cares and must not influence selection — force group 0_1.
  assign larger_exp_product_flag_group_0_1 = (src_fmt_i == fpnew_pkg::FP16 || src_fmt_i == fpnew_pkg::FP16ALT) ? 1'b1 : ((large_exp_product_0_1 > large_exp_product_2_3) ? 1'b1 : 1'b0);
  //get the larger exp_product among 4 lanes
  assign reduced_large_exp_product = (larger_exp_product_flag_group_0_1) ? large_exp_product_0_1 : large_exp_product_2_3;
  
  logic [1:0] larger_exp_sel;
  assign larger_exp_sel[1] =  larger_exp_product_flag_group_0_1;
  assign larger_exp_sel[0] =  larger_exp_product_flag_group_0_1? larger_exp_product_flag_0_1 : larger_exp_product_flag_2_3;
  //real exp_product lane0, do not use reduced one
  logic signed [EXP_WIDTH-1:0] exp_product_largest;
  assign exp_product_largest = larger_exp_sel==2'b11 ? exponent_product :
                              (larger_exp_sel==2'b10 ? exponent_product_simd :
                              (larger_exp_sel==2'b01 ? exponent_product_fp8_1 : exponent_product_fp8_2));

  // DP path uses a 1-bit normalized mantissa sum in the multiplier.
  // OCP MX: when mx_enable_i=1, fold the shared block scale into the product
  // exponent: result *= 2^(s_A + s_B - 254). Range of the scale shift is
  // [-254, +256], easily within signed EXP_WIDTH=10. mx_enable=0 leaves
  // exp_product_lane0 bit-exact to the pre-MX behavior.
  logic signed [EXP_WIDTH-1:0] mx_scale_shift;
  assign mx_scale_shift = mx_enable_i
                          ? signed'({2'b00, mx_scale_a_i})
                            + signed'({2'b00, mx_scale_b_i})
                            - 10'sd254
                          : 10'sd0;

  assign exp_product_lane0 = dp_enable_i ? (fp4_enable_i ? (10'sd132 + mx_scale_shift)
                                                         : (exp_product_largest + 10'sd1 + mx_scale_shift))
                                         : exponent_product;

  // Lane-0/1 diffs widened to RED_EXP_W_01 to hold BF16's 8-b exp range
  // (sum-of-two-biased-exps up to 510); FP16's 5-b case still fits.
  // Lane-2/3 diffs widened to 7 b (signed) to hold FP8ALT's 5-b exp range
  // (sum up to 60, diff up to ~60); FP8's 4-b exp case still fits.
  logic signed [RED_EXP_W_01:0] dp_e_diff0_s, dp_e_diff1_s;
  logic signed [6:0]            dp_e_diff2_s, dp_e_diff3_s;
  assign dp_e_diff0_s = $signed({1'b0, reduced_large_exp_product}) - $signed({1'b0, reduced_exponent_product_lane0}); // >= 0
  assign dp_e_diff1_s = $signed({1'b0, reduced_large_exp_product}) - $signed({1'b0, reduced_exponent_product_lane1}); // >= 0
  assign dp_e_diff2_s = $signed({1'b0, reduced_large_exp_product[5:0]}) - $signed({1'b0, reduced_exponent_product_lane2}); // >= 0
  assign dp_e_diff3_s = $signed({1'b0, reduced_large_exp_product[5:0]}) - $signed({1'b0, reduced_exponent_product_lane3}); // >= 0

  // Max useful shift for each path — once the lagging product is shifted past
  // this, it has been entirely shifted into sticky and contributes 0. Saturate
  // here so wrap-around in the narrower shamt field cannot produce a small
  // shift that aliases the smaller lane's product back into the partial sum.
  localparam int unsigned MAX_DP_SHAMT_SIMD = 3 * PRECISION_BITS_SIMD + 4;
  localparam int unsigned MAX_DP_SHAMT_FP8  = 3 * PRECISION_BITS_FP8  + 4;

  always_comb begin
      dp_shamt0_o = (dp_e_diff0_s > $signed(MAX_DP_SHAMT_SIMD))
                      ? MAX_DP_SHAMT_SIMD[SHIFT_AMOUNT_WIDTH_SIMD-1:0]
                      : dp_e_diff0_s[SHIFT_AMOUNT_WIDTH_SIMD-1:0];
      dp_shamt1_o = (dp_e_diff1_s > $signed(MAX_DP_SHAMT_SIMD))
                      ? MAX_DP_SHAMT_SIMD[SHIFT_AMOUNT_WIDTH_SIMD-1:0]
                      : dp_e_diff1_s[SHIFT_AMOUNT_WIDTH_SIMD-1:0];
      dp_shamt2_o = (dp_e_diff2_s > $signed(MAX_DP_SHAMT_FP8))
                      ? MAX_DP_SHAMT_FP8[SHIFT_AMOUNT_WIDTH_FP8-1:0]
                      : dp_e_diff2_s[SHIFT_AMOUNT_WIDTH_FP8-1:0];
      dp_shamt3_o = (dp_e_diff3_s > $signed(MAX_DP_SHAMT_FP8))
                      ? MAX_DP_SHAMT_FP8[SHIFT_AMOUNT_WIDTH_FP8-1:0]
                      : dp_e_diff3_s[SHIFT_AMOUNT_WIDTH_FP8-1:0];
  end
  
  // Difference in SIMD mode
  assign exponent_difference = exponent_addend - exp_product_lane0; // 8 bit exp, max is 255
  assign exponent_difference_simd = exponent_addend_simd - exponent_product_simd; // 5bit exp, max is +-31
  assign exponent_difference_fp8_1 = exponent_addend_fp8_1 - exponent_product_fp8_1; // 4bit exp, max is +-15
  assign exponent_difference_fp8_2 = exponent_addend_fp8_2 - exponent_product_fp8_2; // 4bit exp, max is +-15
  // --------------------------------------------------------------------------
  // Addend shift amount computation (alignment)
  // --------------------------------------------------------------------------
  always_comb begin : addend_shift_amount
    if (exponent_difference <= signed'(-2 * PRECISION_BITS - 1))
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_large_precision = 3 * PRECISION_BITS + 4;
    else if (exponent_difference <= signed'(PRECISION_BITS + 2))
      // overlapping exponents: partial alignment
      addend_shamt_large_precision = unsigned'(signed'(PRECISION_BITS) + 3 - exponent_difference);
    else
      // addend larger: no shift needed
      addend_shamt_large_precision = 0;
  end

  always_comb begin : addend_shift_shamt_small_precision
    if (exponent_difference <= signed'(-2 * PRECISION_BITS_SIMD - 1))
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_small_precision = 3 * PRECISION_BITS_SIMD + 4;
    else if (exponent_difference <= signed'(PRECISION_BITS_SIMD + 2))
      // overlapping exponents: partial alignment
      addend_shamt_small_precision = unsigned'(signed'(PRECISION_BITS_SIMD) + 3 - exponent_difference);
    else
      // addend larger: no shift needed
      addend_shamt_small_precision = 0;
  end

  always_comb begin : addend_shift_shamt_super_small_precision
    if (exponent_difference <= signed'(-2 * PRECISION_BITS_FP8 - 1))
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_super_small_precision = 3 * PRECISION_BITS_FP8 + 4;
    else if (exponent_difference <= signed'(PRECISION_BITS_FP8 + 2))
      // overlapping exponents: partial alignment
      addend_shamt_super_small_precision = unsigned'(signed'(PRECISION_BITS_FP8) + 3 - exponent_difference);
    else
      // addend larger: no shift needed
      addend_shamt_super_small_precision = 0;
  end

  // In SIMD k=4 mode, byte0 (this main lane) hosts an FP8-precision FMA when
  // src_fmt is any FP8 variant (E4M3 or FP8ALT/E5M2 — both share the FP8 4-b
  // mantissa-multiplier shape). Use the FP8 (super-small) shift width for both.
  assign addend_shamt = simd_enable_i ? ((src_fmt_i==fpnew_pkg::FP8 || src_fmt_i==fpnew_pkg::FP8ALT) ? addend_shamt_super_small_precision : addend_shamt_small_precision) : addend_shamt_large_precision;

  always_comb begin : addend_shift_amount_simd
    if (exponent_difference_simd <= signed'(-2 * PRECISION_BITS_SIMD - 1)) //smaller than -23
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_small_precision_simd = 3 * PRECISION_BITS_SIMD + 4;
    else if (exponent_difference_simd <= signed'(PRECISION_BITS_SIMD + 2)) //smaller than 13
      // overlapping exponents: partial alignment
      addend_shamt_small_precision_simd = unsigned'(signed'(PRECISION_BITS_SIMD) + 3 - exponent_difference_simd);
    else
      // addend larger: no shift needed
      addend_shamt_small_precision_simd = 0;
  end

  always_comb begin : addend_shift_amount_super_small_precision_simd
    if (exponent_difference_simd <= signed'(-2 * PRECISION_BITS_FP8 - 1))
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_super_small_precision_simd = 3 * PRECISION_BITS_FP8 + 4;
    else if (exponent_difference_simd <= signed'(PRECISION_BITS_FP8 + 2))
      // overlapping exponents: partial alignment
      addend_shamt_super_small_precision_simd = unsigned'(signed'(PRECISION_BITS_FP8) + 3 - exponent_difference_simd);
    else
      // addend larger: no shift needed
      addend_shamt_super_small_precision_simd = 0;
  end
  // Same rule for byte2 (this SIMD lane): FP8 or FP8ALT both pick the FP8 shift width.
  assign addend_shamt_simd = ((src_fmt_i==fpnew_pkg::FP8) || (src_fmt_i==fpnew_pkg::FP8ALT)) ? addend_shamt_super_small_precision_simd : addend_shamt_small_precision_simd;

  always_comb begin : addend_shift_amount_fp8_1
    if (exponent_difference_fp8_1 <= signed'(-2 * PRECISION_BITS_FP8 - 1))
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_fp8_1 = 3 * PRECISION_BITS_FP8 + 4;
    else if (exponent_difference_fp8_1 <= signed'(PRECISION_BITS_FP8 + 2))
      // overlapping exponents: partial alignment
      addend_shamt_fp8_1 = unsigned'(signed'(PRECISION_BITS_FP8) + 3 - exponent_difference_fp8_1);
    else
      // addend larger: no shift needed
      addend_shamt_fp8_1 = 0;
  end

  always_comb begin : addend_shift_amount_fp8_2
    if (exponent_difference_fp8_2 <= signed'(-2 * PRECISION_BITS_FP8 - 1)) //smaller than -9
      // addend extremely smaller: fully right-shifted into sticky
      addend_shamt_fp8_2 = 3 * PRECISION_BITS_FP8 + 4;
    else if (exponent_difference_fp8_2 <= signed'(PRECISION_BITS_FP8 + 2)) //smaller than 6
      // overlapping exponents: partial alignment
      addend_shamt_fp8_2 = unsigned'(signed'(PRECISION_BITS_FP8) + 3 - exponent_difference_fp8_2);
    else
      // addend larger: no shift needed
      addend_shamt_fp8_2 = 0;
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

  lzc #(
    .WIDTH ( SUPER_MAN_BITS_SIMD),
    .MODE  ( 1 ) // 1 = leading zero count
  ) i_addend_lzc_simd (
    .in_i    ( mantissa_c_simd_i ),
    .cnt_o   ( addend_lzc_count_simd ),
    .empty_o ( )
  );

    assign addend_lzc_count_sgn_simd = signed'({1'b0, addend_lzc_count_simd});

  lzc #(
    .WIDTH ( SUPER_MAN_BITS_FP8),
    .MODE  ( 1 ) // 1 = leading zero count
  ) i_addend_lzc_fp8_1 (
    .in_i    ( mantissa_c_fp8_1_i ),
    .cnt_o   ( addend_lzc_count_fp8_1 ),
    .empty_o ( )
  );

    assign addend_lzc_count_sgn_fp8_1 = signed'({1'b0, addend_lzc_count_fp8_1});

  lzc #(
    .WIDTH ( SUPER_MAN_BITS_FP8),
    .MODE  ( 1 ) // 1 = leading zero count
  ) i_addend_lzc_fp8_2 (
    .in_i    ( mantissa_c_fp8_2_i ),
    .cnt_o   ( addend_lzc_count_fp8_2 ),
    .empty_o ( )
  );

    assign addend_lzc_count_sgn_fp8_2 = signed'({1'b0, addend_lzc_count_fp8_2});
  

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

  always_comb begin : addend_norm_shamt_simd
    if (info_c_simd_i.is_normal || info_c_simd_i.is_zero)
      addend_normalize_shamt_simd = 0;
    else if (exponent_addend_simd <= 1)
      addend_normalize_shamt_simd = 0;
    else if (addend_lzc_count_sgn_simd + 1 < exponent_addend_simd)
      addend_normalize_shamt_simd = addend_lzc_count_simd + 1;
    else
      addend_normalize_shamt_simd = exponent_addend_simd - 1;
  end

  always_comb begin : addend_norm_shamt_fp8_1
    if (info_c_fp8_1_i.is_normal || info_c_fp8_1_i.is_zero)
      addend_normalize_shamt_fp8_1 = 0;
    else if (exponent_addend_fp8_1 <= 1)
      addend_normalize_shamt_fp8_1 = 0;
    else if (addend_lzc_count_sgn_fp8_1 + 1 < exponent_addend_fp8_1)
      addend_normalize_shamt_fp8_1 = addend_lzc_count_fp8_1 + 1;
    else
      addend_normalize_shamt_fp8_1 = exponent_addend_fp8_1 - 1;
  end

  always_comb begin : addend_norm_shamt_fp8_2
    if (info_c_fp8_2_i.is_normal || info_c_fp8_2_i.is_zero)
      addend_normalize_shamt_fp8_2 = 0;
    else if (exponent_addend_fp8_2 <= 1)
      addend_normalize_shamt_fp8_2 = 0;
    else if (addend_lzc_count_sgn_fp8_2 + 1 < exponent_addend_fp8_2)
      addend_normalize_shamt_fp8_2 = addend_lzc_count_fp8_2 + 1;
    else
      addend_normalize_shamt_fp8_2 = exponent_addend_fp8_2 - 1;
  end

  // --------------------------------------------------------------------------
  // Tentative exponent selection
  // --------------------------------------------------------------------------
  assign tentative_exponent =
    (exponent_difference > 0)
      ? exponent_addend - addend_normalize_shamt
      : exp_product_lane0;

  assign tentative_exponent_simd =
    (exponent_difference_simd > 0)
      ? exponent_addend_simd - addend_normalize_shamt_simd
      : exponent_product_simd;

  assign tentative_exponent_fp8_1 =
    (exponent_difference_fp8_1 > 0)
      ? exponent_addend_fp8_1 - addend_normalize_shamt_fp8_1
      : exponent_product_fp8_1;

  assign tentative_exponent_fp8_2 =
    (exponent_difference_fp8_2 > 0)
      ? exponent_addend_fp8_2 - addend_normalize_shamt_fp8_2
      : exponent_product_fp8_2;

  // --------------------------------------------------------------------------
  // Output assignment
  // --------------------------------------------------------------------------
  assign exponent_addend_o        = exponent_addend;
  assign exponent_product_o       = exp_product_lane0;
  assign exponent_difference_o    = exponent_difference;
  assign tentative_exponent_o     = tentative_exponent;
  assign addend_shamt_o           = addend_shamt;
  assign addend_shamt_large_o   = addend_shamt_large_precision;
  assign addend_shamt_small_o   = addend_shamt_small_precision;
  assign addend_normalize_shamt_o = addend_normalize_shamt;

  assign exponent_addend_simd_o        = $signed(exponent_addend_simd);
  assign exponent_product_simd_o       = $signed(exponent_product_simd);
  assign exponent_difference_simd_o    = $signed(exponent_difference_simd);
  assign tentative_exponent_simd_o     = $signed(tentative_exponent_simd);
  assign addend_shamt_simd_o           = addend_shamt_simd;
  assign addend_shamt_small_simd_o   = addend_shamt_small_precision_simd;
  assign addend_normalize_shamt_simd_o = addend_normalize_shamt_simd;

  assign exponent_addend_fp8_1_o        = $signed(exponent_addend_fp8_1);
  assign exponent_product_fp8_1_o       = $signed(exponent_product_fp8_1);
  assign exponent_difference_fp8_1_o    = $signed(exponent_difference_fp8_1);
  assign tentative_exponent_fp8_1_o     = $signed(tentative_exponent_fp8_1);
  assign addend_shamt_fp8_1_o           = addend_shamt_fp8_1;
  assign addend_normalize_shamt_fp8_1_o = addend_normalize_shamt_fp8_1;

  assign exponent_addend_fp8_2_o        = $signed(exponent_addend_fp8_2);
  assign exponent_product_fp8_2_o       = $signed(exponent_product_fp8_2);
  assign exponent_difference_fp8_2_o    = $signed(exponent_difference_fp8_2);
  assign tentative_exponent_fp8_2_o     = $signed(tentative_exponent_fp8_2);
  assign addend_shamt_fp8_2_o           = addend_shamt_fp8_2;
  assign addend_normalize_shamt_fp8_2_o = addend_normalize_shamt_fp8_2; 
endmodule
