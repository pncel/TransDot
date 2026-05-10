module transdot_decomp_addend_datapath_piped #(
  parameter int unsigned SUPER_MAN_BITS     = 23,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS     = SUPER_MAN_BITS + 1,  // mantissa precision bits (FP32: 24)
  parameter int unsigned SHIFT_AMOUNT_WIDTH = $clog2(3 * PRECISION_BITS + 5),   // shift amount bit width (for FP32: log2(77)=7)
   // ------------
   // SIMD lane 1 parameters
  parameter int unsigned SUPER_MAN_BITS_SIMD     = 10,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS_SIMD     = SUPER_MAN_BITS_SIMD + 1,  // mantissa precision bits (FP16: 11)
  parameter int unsigned SHIFT_AMOUNT_WIDTH_SIMD = $clog2(3 * PRECISION_BITS_SIMD + 5),   // shift amount bit width (for FP16: log2(38)=6)

     // SIMD lane 2/3 parameters
  parameter int unsigned SUPER_MAN_BITS_FP8     = 4,  // mantissa width of superformat
  parameter int unsigned PRECISION_BITS_FP8     = SUPER_MAN_BITS_FP8 + 1,  // mantissa precision bits (FP8: 11)
  parameter int unsigned SHIFT_AMOUNT_WIDTH_FP8 = $clog2(3 * PRECISION_BITS_FP8 + 5)   // shift amount bit width (for FP8: log2(38)=6)

)(
  // ---------------- Inputs ----------------
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               pipe_en,

  // ---------------- Main lane Inputs ----------------
  input  logic [PRECISION_BITS-1:0]          mantissa_c_i,         // raw mantissa of operand C
  input  logic [3*PRECISION_BITS+3:0]        product_shifted_i,    // shifted product mantissa //76-bit
  input  logic [SHIFT_AMOUNT_WIDTH-1:0]      addend_shamt_i,       // exponent diff shift
  input  logic                               effective_subtraction_i,
  input  logic                               tentative_sign_i,

  // ---------------- Outputs ----------------
  output logic                               sticky_before_add_o,
  output logic [3*PRECISION_BITS+3:0]        sum_o,
  output logic                               final_sign_o,

  //mode select for SIMD
  input  logic                               simd_enable_i,
  input  logic                               is_fp8,

    // ---------------- SIMD lane 1 Inputs ----------------
  input  logic [PRECISION_BITS_SIMD-1:0]          mantissa_c_simd_i,         // raw mantissa of operand C
  input  logic [3*PRECISION_BITS_SIMD+3:0]        product_shifted_simd_i,    // shifted product mantissa //37-bit
  input  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0]      addend_shamt_simd_i,       // exponent diff shift
  input  logic                               effective_subtraction_simd_i,
  input  logic                               tentative_sign_simd_i,
  // ---------------- SIMD lane 1 Outputs ----------------
  output logic                               sticky_before_add_simd_o,
  output logic [3*PRECISION_BITS_SIMD+3:0]        sum_simd_o,
  output logic                               final_sign_simd_o,

      // ---------------- SIMD lane 2 Inputs ----------------
  input  logic [PRECISION_BITS_FP8-1:0]          mantissa_c_fp8_1_i,         // raw mantissa of operand C
  input  logic [3*PRECISION_BITS_FP8+3:0]        product_shifted_fp8_1_i,    // shifted product mantissa //37-bit
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]      addend_shamt_fp8_1_i,       // exponent diff shift
  input  logic                               effective_subtraction_fp8_1_i,
  input  logic                               tentative_sign_fp8_1_i,
  // ---------------- SIMD lane 2 Outputs ----------------
  output logic                               sticky_before_add_fp8_1_o,
  output logic [3*PRECISION_BITS_FP8+3:0]        sum_fp8_1_o,
  output logic                               final_sign_fp8_1_o,

      // ---------------- SIMD lane 3 Inputs ----------------
  input  logic [PRECISION_BITS_FP8-1:0]          mantissa_c_fp8_2_i,         // raw mantissa of operand C
  input  logic [3*PRECISION_BITS_FP8+3:0]        product_shifted_fp8_2_i,    // shifted product mantissa //37-bit
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]      addend_shamt_fp8_2_i,       // exponent diff shift
  input  logic                               effective_subtraction_fp8_2_i,
  input  logic                               tentative_sign_fp8_2_i,
  // ---------------- SIMD lane 3 Outputs ----------------
  output logic                               sticky_before_add_fp8_2_o,
  output logic [3*PRECISION_BITS_FP8+3:0]        sum_fp8_2_o,
  output logic                               final_sign_fp8_2_o
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

  // ------------
  // SIMD lane 1
  localparam int unsigned STICKY_WIDTH_SIMD = PRECISION_BITS_SIMD;

  logic [STICKY_WIDTH_SIMD-1:0]     addend_sticky_bits_simd;
  logic                        sticky_before_add_simd;
  logic [3*PRECISION_BITS_SIMD+4-1:0] addend_after_shift_simd;
  logic [3*PRECISION_BITS_SIMD+4-1:0] addend_shifted_simd;
  logic                        inject_carry_in_simd;
  logic [3*PRECISION_BITS_SIMD+5-1:0] sum_pos_simd, sum_neg_simd;
  logic                        sum_carry_simd;
  logic [3*PRECISION_BITS_SIMD+4-1:0] sum_simd;
  logic                        final_sign_simd;

  // ------------
  // SIMD lane 2
  localparam int unsigned STICKY_WIDTH_FP8 = PRECISION_BITS_FP8;

  logic [STICKY_WIDTH_FP8-1:0]     addend_sticky_bits_fp8_1;
  logic                        sticky_before_add_fp8_1;
  logic [3*PRECISION_BITS_FP8+4-1:0] addend_after_shift_fp8_1;
  logic [3*PRECISION_BITS_FP8+4-1:0] addend_shifted_fp8_1;
  logic                        inject_carry_in_fp8_1;
  logic [3*PRECISION_BITS_FP8+5-1:0] sum_pos_fp8_1, sum_neg_fp8_1;
  logic                        sum_carry_fp8_1;
  logic [3*PRECISION_BITS_FP8+4-1:0] sum_fp8_1;
  logic                        final_sign_fp8_1;


  // ------------
  // SIMD lane 3
  logic [STICKY_WIDTH_FP8-1:0]     addend_sticky_bits_fp8_2;
  logic                        sticky_before_add_fp8_2;
  logic [3*PRECISION_BITS_FP8+4-1:0] addend_after_shift_fp8_2;
  logic [3*PRECISION_BITS_FP8+4-1:0] addend_shifted_fp8_2;
  logic                        inject_carry_in_fp8_2;
  logic [3*PRECISION_BITS_FP8+5-1:0] sum_pos_fp8_2, sum_neg_fp8_2;
  logic                        sum_carry_fp8_2;
  logic [3*PRECISION_BITS_FP8+4-1:0] sum_fp8_2;
  logic                        final_sign_fp8_2;

  localparam int unsigned SHIFT_TOTAL_W = 4 * PRECISION_BITS + 4; //100
  localparam int unsigned SHIFT_HALF_W = SHIFT_TOTAL_W/2; //50
  localparam int unsigned SHIFT_QUARTER_W = SHIFT_TOTAL_W/4; //25
  localparam int unsigned SHIFT_SIMD_W = 4 * PRECISION_BITS_SIMD + 4; //48
  localparam int unsigned SHIFT_FP8_W = 4 * PRECISION_BITS_FP8 + 4; //20
  //assert(SHIFT_HALF_W >= SHIFT_SIMD_W);

  // --------------------------------------------------------------------------
  // Addend right-shift alignment with sticky-bit compression
  // --------------------------------------------------------------------------
  // BEFORE: mantissa_c | zeros(3p+4)
  // AFTER:  right-shifted with sticky bits captured in low p bits
  // 4*PRECISION_BITS+4   = 24*4+4 = 100 bit total bits shifter
  //assign {addend_after_shift, addend_sticky_bits} = (mantissa_c_i << (3 * PRECISION_BITS + 4)) >> addend_shamt_i;
  // 11*4+4 = 48 bit total bits shifter
  //assign {addend_after_shift_simd, addend_sticky_bits_simd} = (mantissa_c_simd_i << (3 * PRECISION_BITS_SIMD + 4)) >> addend_shamt_simd_i;
  logic [99:0] preshift_mantissa,addend_shift_full,addend_shift_full_d;
  assign preshift_mantissa = simd_enable_i ? 
                  is_fp8? {mantissa_c_i[23:20], {(21){1'b0}},mantissa_c_fp8_1_i, {(21){1'b0}}, mantissa_c_simd_i[10:7], {(21){1'b0}}, mantissa_c_fp8_2_i, {(21){1'b0}}}
                : {mantissa_c_i[23:13], {(39){1'b0}},mantissa_c_simd_i, {(39){1'b0}}} 
                : {mantissa_c_i, {(76){1'b0}}};
  //in normal mode, the simd lane1 is not used.
  
  //transdot_decomp_shifter #(
  //  .Half_N (SHIFT_HALF_W)
  //) i_addend_shifter (
  //  .dp_enable_i (simd_enable_i),
  //  .data_i      (preshift_mantissa),
  //  .shamt0_i    (addend_shamt_i),
  //  .shamt1_i    (addend_shamt_simd_i),
  //  .data_o      (addend_shift_full)
  //);

 transdot_decomp_shifter_w4 #(
  .QUARTER_N(25)
 ) i_decomp_addend_shifter (
  // 00: 1x N shifter
  // 01: 2x HALF_N shifters
  // 10: 4x QUARTER_N shifters
  // 11: invalid
  .mode_i(simd_enable_i? (is_fp8? 2'b10:2'b01) : 2'b00),

  .data_i (preshift_mantissa),

  .shamt3_i (addend_shamt_i),
  .shamt2_i (addend_shamt_fp8_1_i),
  .shamt1_i (addend_shamt_simd_i ),
  .shamt0_i (addend_shamt_fp8_2_i ),

  .data_o (addend_shift_full_d)
);

`ifdef COMBINATIONAL
  assign addend_shift_full = addend_shift_full_d;
`else
 always_ff @(posedge clk_i or negedge rst_ni) begin
   if (!rst_ni) begin
     addend_shift_full <= '0;
   end else if (pipe_en) begin
     addend_shift_full <= addend_shift_full_d;
   end
 end
`endif
  
  assign addend_after_shift = simd_enable_i? is_fp8?
        {'0,addend_shift_full[99:84]} //put to original 3P+4 position
        :{'0,addend_shift_full[99:63]} //put to original 4P+4 position
        : addend_shift_full[99:24]; //The higher 3*PRECISION_BITS+4 bits
  assign addend_sticky_bits = simd_enable_i? is_fp8?
                   {addend_shift_full[83:80]} 
                  :{addend_shift_full[62:52]} 
                  : addend_shift_full[23:0];

  //assign {addend_after_shift_simd, addend_sticky_bits_simd} = addend_shift_full[49:2];
  assign addend_after_shift_simd = is_fp8? {'0,addend_shift_full[49:34]} : addend_shift_full[49:13]; //put to original 3P+4 position
  assign addend_sticky_bits_simd = is_fp8? {addend_shift_full[33:30]} : {addend_shift_full[12:2]};

  assign sticky_before_add = (| addend_sticky_bits);
  // ------------
  // SIMD lane 1
  assign sticky_before_add_simd = (| addend_sticky_bits_simd);

   // ------------
  // SIMD lane 2
  assign {addend_after_shift_fp8_1, addend_sticky_bits_fp8_1} = addend_shift_full[74:55];
  assign sticky_before_add_fp8_1 = (| addend_sticky_bits_fp8_1);

   // ------------
  // SIMD lane 3
  assign {addend_after_shift_fp8_2, addend_sticky_bits_fp8_2} = addend_shift_full[24: 5];
  assign sticky_before_add_fp8_2 = (| addend_sticky_bits_fp8_2);

  // --------------------------------------------------------------------------
  // Handle subtraction (invert addend if subtraction)
  // --------------------------------------------------------------------------
  assign addend_shifted  = (effective_subtraction_i)
                           ? ~addend_after_shift
                           :  addend_after_shift;

  // Inject carry only when subtraction and no sticky (two’s complement negation)
  assign inject_carry_in = effective_subtraction_i & ~sticky_before_add;

  // ------------
  // SIMD lane 1
  assign addend_shifted_simd  = (effective_subtraction_simd_i)
                           ? ~addend_after_shift_simd
                           :  addend_after_shift_simd;

  assign inject_carry_in_simd = effective_subtraction_simd_i & ~sticky_before_add_simd;

  // ------------
  // SIMD lane 2
  assign addend_shifted_fp8_1  = (effective_subtraction_fp8_1_i)
                           ? ~addend_after_shift_fp8_1
                           :  addend_after_shift_fp8_1;

  assign inject_carry_in_fp8_1 = effective_subtraction_fp8_1_i & ~sticky_before_add_fp8_1;

  // ------------
  // SIMD lane 3
  assign addend_shifted_fp8_2  = (effective_subtraction_fp8_2_i)
                           ? ~addend_after_shift_fp8_2
                           :  addend_after_shift_fp8_2;
  assign inject_carry_in_fp8_2 = effective_subtraction_fp8_2_i & ~sticky_before_add_fp8_2;

  // --------------------------------------------------------------------------

  // --------------------------------------------------------------------------
  // Mantissa adder (unsigned)
  // --------------------------------------------------------------------------
  //adder_unsigned #(
  //  .IN_WIDTH  (3*PRECISION_BITS + 4),
  //  .OUT_WIDTH (3*PRECISION_BITS + 5)
  //) i_mantissa_adder (
  //  .a_i        (product_shifted_i),
  //  .b_i        (addend_shifted),
  //  .carry_in_i (inject_carry_in),
  //  .sum_o      (sum_pos)
  //);
  //adder_unsigned #(
  //  .IN_WIDTH  (3*PRECISION_BITS_SIMD + 4),
  //  .OUT_WIDTH (3*PRECISION_BITS_SIMD + 5)
  //) i_mantissa_adder_simd (
  //  .a_i        (product_shifted_simd_i),
  //  .b_i        (addend_shifted_simd),
  //  .carry_in_i (inject_carry_in_simd),
  //  .sum_o      (sum_pos_simd)
  //);
  logic [75:0] product_shifted_merge,product_shifted_merge_neg,addend_shifted_merge;
  localparam logic [75:0] FP8_NEG_CLEAR_MASK = {1'b1, 18'b0, 1'b1, 18'b0, 1'b1, 18'b0, 1'b1, 18'b0};

  assign product_shifted_merge = simd_enable_i ? is_fp8?
        {3'd0,product_shifted_fp8_2_i[15:0], 3'd0,product_shifted_simd_i[29:14],3'd0,product_shifted_fp8_1_i[15:0],3'd0,product_shifted_i[55:40]}
        :{1'b0,product_shifted_simd_i[36:0],1'b0,product_shifted_i[62:26]}
        : product_shifted_i ; //extend 1 bit for uniform width

  // Reuse the already-built mode-merged operand, then apply the FP8 lane-mask
  // fixup (clear lane-MSB complement bits) to match the original encoding.
  assign product_shifted_merge_neg = (simd_enable_i && is_fp8)
        ? ((~product_shifted_merge) & ~FP8_NEG_CLEAR_MASK)
        :  (~product_shifted_merge);

  assign addend_shifted_merge = simd_enable_i ? is_fp8?
        {3'd0,addend_shifted_fp8_2[15:0], 3'd0, addend_shifted_simd[15:0] ,3'd0,addend_shifted_fp8_1[15:0],3'd0,addend_shifted[15:0]}
        :{1'b0,addend_shifted_simd[36:0], 1'b0,addend_shifted[36:0]} 
        : addend_shifted ; //extend 1 bit for uniform width


  logic [77:0] sum_pos_merge;

  transdot_decomp_adder_w4 #(
    .QUARTER_N  (19) //3*24+4=76, in simd mode, it will be 38bit+38bit. {1'b0,37bit product_shifted_simd_i, 1'b0,37bit product_shifted_i}
  ) i_mantissa_adder_pos (
    .simd_enable_i (simd_enable_i),
    .is_fp8       (is_fp8),
    .a_i        (product_shifted_merge),
    .b_i        (addend_shifted_merge),
    .lane0_cin     (inject_carry_in),
    .lane1_cin     (inject_carry_in_fp8_1),
    .lane2_cin     (inject_carry_in_simd),
    .lane3_cin     (inject_carry_in_fp8_2),
    .sum_o      (sum_pos_merge)
  );

  assign sum_pos = simd_enable_i ? (is_fp8?
        {'0,sum_pos_merge[16:0],{40{1'b0}}} //put to original 4P+4 position
        :{'0,sum_pos_merge[37:0],{26{1'b0}}}) //put to original 3P+4 position
        : sum_pos_merge[76:0]; //The higher 3*PRECISION_BITS+5 bits

  assign sum_pos_simd = is_fp8?
          {'0,sum_pos_merge[54: 38],{14{1'b0}}}
          :sum_pos_merge[75:38];

  assign sum_pos_fp8_1 = sum_pos_merge[35:19];
  assign sum_pos_fp8_2 = sum_pos_merge[73:57];

  assign sum_carry = simd_enable_i ? (is_fp8?  sum_pos_merge[16]:sum_pos_merge[37]) :sum_pos_merge[76];

  assign sum_carry_simd = is_fp8?  sum_pos_merge[54]:sum_pos_merge[75];

  assign sum_carry_fp8_1 = sum_pos_merge[35];
  assign sum_carry_fp8_2 = sum_pos_merge[73];


  // --------------------------------------------------------------------------
  // Negative sum computation (for subtraction cases)
  // --------------------------------------------------------------------------
  logic [3*PRECISION_BITS+4-1:0] addend_after_shift_merge;
  logic [77:0] sum_neg_merge;
  assign addend_after_shift_merge = simd_enable_i ? is_fp8?
        {3'd0,addend_after_shift_fp8_2[15:0], 3'd0,addend_after_shift_simd[15:0] ,3'd0,addend_after_shift_fp8_1[15:0],3'd0,addend_after_shift[15:0]}
        :{1'b0,addend_after_shift_simd[36:0], 1'b0,addend_after_shift[36:0]}
        : addend_after_shift ; //extend 1 bit for uniform width
  transdot_decomp_adder_w4 #(
    .QUARTER_N  (19) //3*24+4=76, in simd mode, it will be 38bit+38bit. {1'b0,37bit product_shifted_simd_i, 1'b0,37bit product_shifted_i}
    ) i_mantissa_adder_neg (
    .simd_enable_i (simd_enable_i),
    .is_fp8       (is_fp8),
    .a_i        (addend_after_shift_merge),
    .b_i        (product_shifted_merge_neg),
    .lane0_cin     (1'd1),
    .lane1_cin     (1'd1),
    .lane2_cin     (1'd1),
    .lane3_cin     (1'd1),
    .sum_o      (sum_neg_merge)
  );

  assign sum_neg = simd_enable_i? is_fp8? 
                  $signed({sum_neg_merge[16:0],{40{1'b0}}})
                  :$signed({sum_neg_merge[37:0],{26{1'b0}}})
                  :sum_neg_merge;

  assign sum_neg_simd = is_fp8? 
           {sum_neg_merge[54: 38],{14{1'b0}}}
          :sum_neg_merge[75: 38];

  assign sum_neg_fp8_1 = sum_neg_merge[35:19];
  assign sum_neg_fp8_2 = sum_neg_merge[73:57];


  //assign sum_neg = simd_enable_i? ({'0,addend_after_shift,{(2*PRECISION_BITS-2*PRECISION_BITS_SIMD){1'b0}}} - product_shifted_i):(addend_after_shift - product_shifted_i);
  //assign sum_neg_simd = addend_after_shift_simd - product_shifted_simd_i;

  // Select proper sum result
  assign sum = (effective_subtraction_i && ~sum_carry)
               ? sum_neg[3*PRECISION_BITS+3:0]
               : sum_pos[3*PRECISION_BITS+3:0];

  // Select proper sum result
  assign sum_simd = (effective_subtraction_simd_i && ~sum_carry_simd)
               ? sum_neg_simd[3*PRECISION_BITS_SIMD+3:0]
               : sum_pos_simd[3*PRECISION_BITS_SIMD+3:0];

  assign sum_fp8_1 = (effective_subtraction_fp8_1_i && ~sum_carry_fp8_1)
               ? sum_neg_fp8_1[3*PRECISION_BITS_FP8+3:0]
               : sum_pos_fp8_1[3*PRECISION_BITS_FP8+3:0];
  
  assign sum_fp8_2 = (effective_subtraction_fp8_2_i && ~sum_carry_fp8_2)
               ? sum_neg_fp8_2[3*PRECISION_BITS_FP8+3:0]
               : sum_pos_fp8_2[3*PRECISION_BITS_FP8+3:0];
  // --------------------------------------------------------------------------
  // Final sign determination
  // --------------------------------------------------------------------------

  assign final_sign =
    (effective_subtraction_i && (sum_carry == tentative_sign_i))
      ? 1'b1
      : (effective_subtraction_i ? 1'b0 : tentative_sign_i);
    // ------------
    // SIMD lane 1
    assign final_sign_simd =
    (effective_subtraction_simd_i && (sum_carry_simd == tentative_sign_simd_i))
      ? 1'b1
      : (effective_subtraction_simd_i ? 1'b0 : tentative_sign_simd_i);


    // ------------
    // SIMD lane 2
    assign final_sign_fp8_1 =
    (effective_subtraction_fp8_1_i && (sum_carry_fp8_1 == tentative_sign_fp8_1_i))
      ? 1'b1
      : (effective_subtraction_fp8_1_i ? 1'b0 : tentative_sign_fp8_1_i);

    // ------------
    // SIMD lane 3
    assign final_sign_fp8_2 =
    (effective_subtraction_fp8_2_i && (sum_carry_fp8_2 == tentative_sign_fp8_2_i))
      ? 1'b1
      : (effective_subtraction_fp8_2_i ? 1'b0 : tentative_sign_fp8_2_i);

  // --------------------------------------------------------------------------
  // Output assignment
  // --------------------------------------------------------------------------
  assign sticky_before_add_o  = sticky_before_add;
  assign sum_o                = sum;
  assign final_sign_o         = final_sign;

  assign sticky_before_add_simd_o  = sticky_before_add_simd;
  assign sum_simd_o                = sum_simd;
  assign final_sign_simd_o         = final_sign_simd;

  assign sticky_before_add_fp8_1_o  = sticky_before_add_fp8_1;
  assign sum_fp8_1_o                = sum_fp8_1;
  assign final_sign_fp8_1_o         = final_sign_fp8_1;

  assign sticky_before_add_fp8_2_o  = sticky_before_add_fp8_2;
  assign sum_fp8_2_o                = sum_fp8_2;
  assign final_sign_fp8_2_o         = final_sign_fp8_2;
endmodule


module transdot_decomp_addend_datapath_piped_packed_product #(
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
  input  logic                               clk_i,
  input  logic                               pipe_en,

  input  logic [PRECISION_BITS-1:0]          mantissa_c_i,
  input  logic [3*PRECISION_BITS+3:0]        product_shifted_i,
  input  logic [2*PRECISION_BITS-1:0]        product_comb_i,
  input  logic [SHIFT_AMOUNT_WIDTH-1:0]      addend_shamt_i,
  input  logic                               effective_subtraction_i,
  input  logic                               tentative_sign_i,

  output logic                               sticky_before_add_o,
  output logic [3*PRECISION_BITS+3:0]        sum_o,
  output logic                               final_sign_o,

  input  logic                               simd_enable_i,
  input  logic                               is_fp8,

  input  logic [PRECISION_BITS_SIMD-1:0]     mantissa_c_simd_i,
  input  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_i,
  input  logic                               effective_subtraction_simd_i,
  input  logic                               tentative_sign_simd_i,
  output logic                               sticky_before_add_simd_o,
  output logic [3*PRECISION_BITS_SIMD+3:0]   sum_simd_o,
  output logic                               final_sign_simd_o,

  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_1_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_1_i,
  input  logic                               effective_subtraction_fp8_1_i,
  input  logic                               tentative_sign_fp8_1_i,
  output logic                               sticky_before_add_fp8_1_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_1_o,
  output logic                               final_sign_fp8_1_o,

  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_2_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_2_i,
  input  logic                               effective_subtraction_fp8_2_i,
  input  logic                               tentative_sign_fp8_2_i,
  output logic                               sticky_before_add_fp8_2_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_2_o,
  output logic                               final_sign_fp8_2_o
);

  logic [3*PRECISION_BITS_SIMD+3:0] product_shifted_simd_from_packed;
  logic [3*PRECISION_BITS_FP8+3:0]  product_shifted_fp8_1_from_packed;
  logic [3*PRECISION_BITS_FP8+3:0]  product_shifted_fp8_2_from_packed;

  // Reconstruct the non-DP SIMD/FP8 lane products locally from the packed
  // multiplier output so the top level no longer has to fan out three extra
  // shifted-product buses into this addend merge stage.
  assign product_shifted_simd_from_packed = is_fp8
      ? {{(3*PRECISION_BITS_SIMD+4-25){1'b0}}, 1'b0, product_comb_i[19:12], 16'd0}
      : {{(3*PRECISION_BITS_SIMD+4-25){1'b0}}, 1'b0,
         product_comb_i[2*PRECISION_BITS-3-:2*PRECISION_BITS_SIMD], 2'b00};
  assign product_shifted_fp8_1_from_packed =
      {{(3*PRECISION_BITS_FP8+4-11){1'b0}}, 1'b0, product_comb_i[31:24], 2'b00};
  assign product_shifted_fp8_2_from_packed =
      {{(3*PRECISION_BITS_FP8+4-11){1'b0}}, 1'b0, product_comb_i[43:36], 2'b00};

  transdot_decomp_addend_datapath_piped #(
    .SUPER_MAN_BITS         ( SUPER_MAN_BITS ),
    .PRECISION_BITS         ( PRECISION_BITS ),
    .SHIFT_AMOUNT_WIDTH     ( SHIFT_AMOUNT_WIDTH ),
    .SUPER_MAN_BITS_SIMD    ( SUPER_MAN_BITS_SIMD ),
    .PRECISION_BITS_SIMD    ( PRECISION_BITS_SIMD ),
    .SHIFT_AMOUNT_WIDTH_SIMD( SHIFT_AMOUNT_WIDTH_SIMD ),
    .SUPER_MAN_BITS_FP8     ( SUPER_MAN_BITS_FP8 ),
    .PRECISION_BITS_FP8     ( PRECISION_BITS_FP8 ),
    .SHIFT_AMOUNT_WIDTH_FP8 ( SHIFT_AMOUNT_WIDTH_FP8 )
  ) i_decomp_addend_datapath_packed (
    .clk_i                   ( clk_i ),
    .pipe_en                 ( pipe_en ),
    .mantissa_c_i            ( mantissa_c_i ),
    .product_shifted_i       ( product_shifted_i ),
    .addend_shamt_i          ( addend_shamt_i ),
    .effective_subtraction_i ( effective_subtraction_i ),
    .tentative_sign_i        ( tentative_sign_i ),
    .sticky_before_add_o     ( sticky_before_add_o ),
    .sum_o                   ( sum_o ),
    .final_sign_o            ( final_sign_o ),
    .simd_enable_i           ( simd_enable_i ),
    .is_fp8                  ( is_fp8 ),
    .mantissa_c_simd_i            ( mantissa_c_simd_i ),
    .product_shifted_simd_i       ( product_shifted_simd_from_packed ),
    .addend_shamt_simd_i          ( addend_shamt_simd_i ),
    .effective_subtraction_simd_i ( effective_subtraction_simd_i ),
    .tentative_sign_simd_i        ( tentative_sign_simd_i ),
    .sticky_before_add_simd_o     ( sticky_before_add_simd_o ),
    .sum_simd_o                   ( sum_simd_o ),
    .final_sign_simd_o            ( final_sign_simd_o ),
    .mantissa_c_fp8_1_i            ( mantissa_c_fp8_1_i ),
    .product_shifted_fp8_1_i       ( product_shifted_fp8_1_from_packed ),
    .addend_shamt_fp8_1_i          ( addend_shamt_fp8_1_i ),
    .effective_subtraction_fp8_1_i ( effective_subtraction_fp8_1_i ),
    .tentative_sign_fp8_1_i        ( tentative_sign_fp8_1_i ),
    .sticky_before_add_fp8_1_o     ( sticky_before_add_fp8_1_o ),
    .sum_fp8_1_o                   ( sum_fp8_1_o ),
    .final_sign_fp8_1_o            ( final_sign_fp8_1_o ),
    .mantissa_c_fp8_2_i            ( mantissa_c_fp8_2_i ),
    .product_shifted_fp8_2_i       ( product_shifted_fp8_2_from_packed ),
    .addend_shamt_fp8_2_i          ( addend_shamt_fp8_2_i ),
    .effective_subtraction_fp8_2_i ( effective_subtraction_fp8_2_i ),
    .tentative_sign_fp8_2_i        ( tentative_sign_fp8_2_i ),
    .sticky_before_add_fp8_2_o     ( sticky_before_add_fp8_2_o ),
    .sum_fp8_2_o                   ( sum_fp8_2_o ),
    .final_sign_fp8_2_o            ( final_sign_fp8_2_o )
  );
endmodule

module transdot_decomp_addend_datapath_piped_packed_product_dp #(
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
  input  logic                               clk_i,
  input  logic                               pipe_en,
  input  logic                               dp_enable_i,
  input  logic                               fp4_enable_i,

  input  logic [PRECISION_BITS-1:0]          mantissa_c_i,
  input  logic [2*PRECISION_BITS-1:0]        product_comb_i,
  input  logic [2*PRECISION_BITS_SIMD+4:0]   product_shifted_dp_post_i,
  input  logic [47:0]                        product_shifted_dp_fp4_i,
  input  logic [SHIFT_AMOUNT_WIDTH-1:0]      addend_shamt_i,
  input  logic                               effective_subtraction_i,
  input  logic                               tentative_sign_i,

  output logic                               sticky_before_add_o,
  output logic [3*PRECISION_BITS+3:0]        sum_o,
  output logic                               final_sign_o,

  input  logic                               simd_enable_i,
  input  logic                               is_fp8,

  input  logic [PRECISION_BITS_SIMD-1:0]     mantissa_c_simd_i,
  input  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_i,
  input  logic                               effective_subtraction_simd_i,
  input  logic                               tentative_sign_simd_i,
  output logic                               sticky_before_add_simd_o,
  output logic [3*PRECISION_BITS_SIMD+3:0]   sum_simd_o,
  output logic                               final_sign_simd_o,

  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_1_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_1_i,
  input  logic                               effective_subtraction_fp8_1_i,
  input  logic                               tentative_sign_fp8_1_i,
  output logic                               sticky_before_add_fp8_1_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_1_o,
  output logic                               final_sign_fp8_1_o,

  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_2_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_2_i,
  input  logic                               effective_subtraction_fp8_2_i,
  input  logic                               tentative_sign_fp8_2_i,
  output logic                               sticky_before_add_fp8_2_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_2_o,
  output logic                               final_sign_fp8_2_o
);

  logic [3*PRECISION_BITS+3:0]     product_shifted_selected;
  logic [3*PRECISION_BITS_SIMD+3:0] product_shifted_simd_from_packed;
  logic [3*PRECISION_BITS_FP8+3:0]  product_shifted_fp8_1_from_packed;
  logic [3*PRECISION_BITS_FP8+3:0]  product_shifted_fp8_2_from_packed;

  always_comb begin
    if (dp_enable_i) begin
      product_shifted_selected = fp4_enable_i
          ? {'0, product_shifted_dp_fp4_i, 4'd0}
          : {'0, product_shifted_dp_post_i, {(2*PRECISION_BITS-2*PRECISION_BITS_SIMD){1'b0}}};
    end else if (!simd_enable_i) begin
      product_shifted_selected = {'0, product_comb_i, 2'b00};
    end else if (is_fp8) begin
      product_shifted_selected = {
        {(3*PRECISION_BITS+4-(2*PRECISION_BITS+3)){1'b0}},
        1'b0,
        product_comb_i[2*PRECISION_BITS_FP8-1:0],
        {(2*PRECISION_BITS-2*PRECISION_BITS_FP8){1'b0}},
        2'b00
      };
    end else begin
      product_shifted_selected = {
        {(3*PRECISION_BITS+4-(2*PRECISION_BITS+3)){1'b0}},
        1'b0,
        product_comb_i[PRECISION_BITS-3-:2*PRECISION_BITS_SIMD],
        {(2*PRECISION_BITS-2*PRECISION_BITS_SIMD){1'b0}},
        2'b00
      };
    end
  end

  assign product_shifted_simd_from_packed = is_fp8
      ? {{(3*PRECISION_BITS_SIMD+4-25){1'b0}}, 1'b0, product_comb_i[19:12], 16'd0}
      : {{(3*PRECISION_BITS_SIMD+4-25){1'b0}}, 1'b0,
         product_comb_i[2*PRECISION_BITS-3-:2*PRECISION_BITS_SIMD], 2'b00};
  assign product_shifted_fp8_1_from_packed =
      {{(3*PRECISION_BITS_FP8+4-11){1'b0}}, 1'b0, product_comb_i[31:24], 2'b00};
  assign product_shifted_fp8_2_from_packed =
      {{(3*PRECISION_BITS_FP8+4-11){1'b0}}, 1'b0, product_comb_i[43:36], 2'b00};

  transdot_decomp_addend_datapath_piped #(
    .SUPER_MAN_BITS         ( SUPER_MAN_BITS ),
    .PRECISION_BITS         ( PRECISION_BITS ),
    .SHIFT_AMOUNT_WIDTH     ( SHIFT_AMOUNT_WIDTH ),
    .SUPER_MAN_BITS_SIMD    ( SUPER_MAN_BITS_SIMD ),
    .PRECISION_BITS_SIMD    ( PRECISION_BITS_SIMD ),
    .SHIFT_AMOUNT_WIDTH_SIMD( SHIFT_AMOUNT_WIDTH_SIMD ),
    .SUPER_MAN_BITS_FP8     ( SUPER_MAN_BITS_FP8 ),
    .PRECISION_BITS_FP8     ( PRECISION_BITS_FP8 ),
    .SHIFT_AMOUNT_WIDTH_FP8 ( SHIFT_AMOUNT_WIDTH_FP8 )
  ) i_decomp_addend_datapath_packed_dp (
    .clk_i                   ( clk_i ),
    .pipe_en                 ( pipe_en ),
    .mantissa_c_i            ( mantissa_c_i ),
    .product_shifted_i       ( product_shifted_selected ),
    .addend_shamt_i          ( addend_shamt_i ),
    .effective_subtraction_i ( effective_subtraction_i ),
    .tentative_sign_i        ( tentative_sign_i ),
    .sticky_before_add_o     ( sticky_before_add_o ),
    .sum_o                   ( sum_o ),
    .final_sign_o            ( final_sign_o ),
    .simd_enable_i           ( simd_enable_i ),
    .is_fp8                  ( is_fp8 ),
    .mantissa_c_simd_i            ( mantissa_c_simd_i ),
    .product_shifted_simd_i       ( product_shifted_simd_from_packed ),
    .addend_shamt_simd_i          ( addend_shamt_simd_i ),
    .effective_subtraction_simd_i ( effective_subtraction_simd_i ),
    .tentative_sign_simd_i        ( tentative_sign_simd_i ),
    .sticky_before_add_simd_o     ( sticky_before_add_simd_o ),
    .sum_simd_o                   ( sum_simd_o ),
    .final_sign_simd_o            ( final_sign_simd_o ),
    .mantissa_c_fp8_1_i            ( mantissa_c_fp8_1_i ),
    .product_shifted_fp8_1_i       ( product_shifted_fp8_1_from_packed ),
    .addend_shamt_fp8_1_i          ( addend_shamt_fp8_1_i ),
    .effective_subtraction_fp8_1_i ( effective_subtraction_fp8_1_i ),
    .tentative_sign_fp8_1_i        ( tentative_sign_fp8_1_i ),
    .sticky_before_add_fp8_1_o     ( sticky_before_add_fp8_1_o ),
    .sum_fp8_1_o                   ( sum_fp8_1_o ),
    .final_sign_fp8_1_o            ( final_sign_fp8_1_o ),
    .mantissa_c_fp8_2_i            ( mantissa_c_fp8_2_i ),
    .product_shifted_fp8_2_i       ( product_shifted_fp8_2_from_packed ),
    .addend_shamt_fp8_2_i          ( addend_shamt_fp8_2_i ),
    .effective_subtraction_fp8_2_i ( effective_subtraction_fp8_2_i ),
    .tentative_sign_fp8_2_i        ( tentative_sign_fp8_2_i ),
    .sticky_before_add_fp8_2_o     ( sticky_before_add_fp8_2_o ),
    .sum_fp8_2_o                   ( sum_fp8_2_o ),
    .final_sign_fp8_2_o            ( final_sign_fp8_2_o )
  );
endmodule

module transdot_decomp_addend_datapath_piped_combined_product_dp #(
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
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               pipe_en,
  input  logic                               dp_enable_i,
  // fp4_enable_i selects the FP4 8-lane DP path. FP4 uses a fixed
  // anchor (10'sd132) in transdot_decomp_exponent_datapath_fp8 that
  // already accounts for log2(8)=3 bits of lane-sum growth, so its
  // product padding stays at the original 4'd0. Only the FP8/FP16
  // 2/4-lane DP path needs the +2 anchor + 3'd0 compensation.
  input  logic                               fp4_enable_i,

  input  logic [PRECISION_BITS-1:0]          mantissa_c_i,
  input  logic [2*PRECISION_BITS-1:0]        product_comb_i,
  input  logic [2*PRECISION_BITS-1:0]        product_dp_i,
  input  logic [SHIFT_AMOUNT_WIDTH-1:0]      addend_shamt_i,
  input  logic                               effective_subtraction_i,
  input  logic                               tentative_sign_i,

  output logic                               sticky_before_add_o,
  output logic [3*PRECISION_BITS+3:0]        sum_o,
  output logic                               final_sign_o,

  input  logic                               simd_enable_i,
  input  logic                               is_fp8,

  input  logic [PRECISION_BITS_SIMD-1:0]     mantissa_c_simd_i,
  input  logic [SHIFT_AMOUNT_WIDTH_SIMD-1:0] addend_shamt_simd_i,
  input  logic                               effective_subtraction_simd_i,
  input  logic                               tentative_sign_simd_i,
  output logic                               sticky_before_add_simd_o,
  output logic [3*PRECISION_BITS_SIMD+3:0]   sum_simd_o,
  output logic                               final_sign_simd_o,

  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_1_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_1_i,
  input  logic                               effective_subtraction_fp8_1_i,
  input  logic                               tentative_sign_fp8_1_i,
  output logic                               sticky_before_add_fp8_1_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_1_o,
  output logic                               final_sign_fp8_1_o,

  input  logic [PRECISION_BITS_FP8-1:0]      mantissa_c_fp8_2_i,
  input  logic [SHIFT_AMOUNT_WIDTH_FP8-1:0]  addend_shamt_fp8_2_i,
  input  logic                               effective_subtraction_fp8_2_i,
  input  logic                               tentative_sign_fp8_2_i,
  output logic                               sticky_before_add_fp8_2_o,
  output logic [3*PRECISION_BITS_FP8+3:0]    sum_fp8_2_o,
  output logic                               final_sign_fp8_2_o
);

  logic [3*PRECISION_BITS+3:0]      product_shifted_selected;
  logic [3*PRECISION_BITS_SIMD+3:0] product_shifted_simd_from_packed;
  logic [3*PRECISION_BITS_FP8+3:0]  product_shifted_fp8_1_from_packed;
  logic [3*PRECISION_BITS_FP8+3:0]  product_shifted_fp8_2_from_packed;

  always_comb begin
    if (dp_enable_i) begin
      // FP4 path uses fixed anchor +132 sized for 8-lane growth → keep
      // 4'd0. FP8/FP16 2/4-lane DP path uses anchor +2 in the exp
      // datapath → use 3'd0 to keep the represented value invariant.
      product_shifted_selected = fp4_enable_i ? {'0, product_dp_i, 4'd0}
                                              : {'0, product_dp_i, 3'd0};
    end else if (!simd_enable_i) begin
      product_shifted_selected = {'0, product_comb_i, 2'b00};
    end else if (is_fp8) begin
      product_shifted_selected = {
        {(3*PRECISION_BITS+4-(2*PRECISION_BITS+3)){1'b0}},
        1'b0,
        product_comb_i[2*PRECISION_BITS_FP8-1:0],
        {(2*PRECISION_BITS-2*PRECISION_BITS_FP8){1'b0}},
        2'b00
      };
    end else begin
      product_shifted_selected = {
        {(3*PRECISION_BITS+4-(2*PRECISION_BITS+3)){1'b0}},
        1'b0,
        product_comb_i[PRECISION_BITS-3-:2*PRECISION_BITS_SIMD],
        {(2*PRECISION_BITS-2*PRECISION_BITS_SIMD){1'b0}},
        2'b00
      };
    end
  end

  assign product_shifted_simd_from_packed = is_fp8
      ? {{(3*PRECISION_BITS_SIMD+4-25){1'b0}}, 1'b0, product_comb_i[19:12], 16'd0}
      : {{(3*PRECISION_BITS_SIMD+4-25){1'b0}}, 1'b0,
         product_comb_i[2*PRECISION_BITS-3-:2*PRECISION_BITS_SIMD], 2'b00};
  assign product_shifted_fp8_1_from_packed =
      {{(3*PRECISION_BITS_FP8+4-11){1'b0}}, 1'b0, product_comb_i[31:24], 2'b00};
  assign product_shifted_fp8_2_from_packed =
      {{(3*PRECISION_BITS_FP8+4-11){1'b0}}, 1'b0, product_comb_i[43:36], 2'b00};

  transdot_decomp_addend_datapath_piped #(
    .SUPER_MAN_BITS         ( SUPER_MAN_BITS ),
    .PRECISION_BITS         ( PRECISION_BITS ),
    .SHIFT_AMOUNT_WIDTH     ( SHIFT_AMOUNT_WIDTH ),
    .SUPER_MAN_BITS_SIMD    ( SUPER_MAN_BITS_SIMD ),
    .PRECISION_BITS_SIMD    ( PRECISION_BITS_SIMD ),
    .SHIFT_AMOUNT_WIDTH_SIMD( SHIFT_AMOUNT_WIDTH_SIMD ),
    .SUPER_MAN_BITS_FP8     ( SUPER_MAN_BITS_FP8 ),
    .PRECISION_BITS_FP8     ( PRECISION_BITS_FP8 ),
    .SHIFT_AMOUNT_WIDTH_FP8 ( SHIFT_AMOUNT_WIDTH_FP8 )
  ) i_decomp_addend_datapath_combined_dp (
    .clk_i                   ( clk_i ),
    .rst_ni                  ( rst_ni ),
    .pipe_en                 ( pipe_en ),
    .mantissa_c_i            ( mantissa_c_i ),
    .product_shifted_i       ( product_shifted_selected ),
    .addend_shamt_i          ( addend_shamt_i ),
    .effective_subtraction_i ( effective_subtraction_i ),
    .tentative_sign_i        ( tentative_sign_i ),
    .sticky_before_add_o     ( sticky_before_add_o ),
    .sum_o                   ( sum_o ),
    .final_sign_o            ( final_sign_o ),
    .simd_enable_i           ( simd_enable_i ),
    .is_fp8                  ( is_fp8 ),
    .mantissa_c_simd_i            ( mantissa_c_simd_i ),
    .product_shifted_simd_i       ( product_shifted_simd_from_packed ),
    .addend_shamt_simd_i          ( addend_shamt_simd_i ),
    .effective_subtraction_simd_i ( effective_subtraction_simd_i ),
    .tentative_sign_simd_i        ( tentative_sign_simd_i ),
    .sticky_before_add_simd_o     ( sticky_before_add_simd_o ),
    .sum_simd_o                   ( sum_simd_o ),
    .final_sign_simd_o            ( final_sign_simd_o ),
    .mantissa_c_fp8_1_i            ( mantissa_c_fp8_1_i ),
    .product_shifted_fp8_1_i       ( product_shifted_fp8_1_from_packed ),
    .addend_shamt_fp8_1_i          ( addend_shamt_fp8_1_i ),
    .effective_subtraction_fp8_1_i ( effective_subtraction_fp8_1_i ),
    .tentative_sign_fp8_1_i        ( tentative_sign_fp8_1_i ),
    .sticky_before_add_fp8_1_o     ( sticky_before_add_fp8_1_o ),
    .sum_fp8_1_o                   ( sum_fp8_1_o ),
    .final_sign_fp8_1_o            ( final_sign_fp8_1_o ),
    .mantissa_c_fp8_2_i            ( mantissa_c_fp8_2_i ),
    .product_shifted_fp8_2_i       ( product_shifted_fp8_2_from_packed ),
    .addend_shamt_fp8_2_i          ( addend_shamt_fp8_2_i ),
    .effective_subtraction_fp8_2_i ( effective_subtraction_fp8_2_i ),
    .tentative_sign_fp8_2_i        ( tentative_sign_fp8_2_i ),
    .sticky_before_add_fp8_2_o     ( sticky_before_add_fp8_2_o ),
    .sum_fp8_2_o                   ( sum_fp8_2_o ),
    .final_sign_fp8_2_o            ( final_sign_fp8_2_o )
  );
endmodule
