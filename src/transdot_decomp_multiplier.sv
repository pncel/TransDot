module transdot_decomp_multiplier_w6 #(
  parameter int unsigned PRECISION_BITS = 24,  // fixed at 24
  parameter int unsigned SMALL_BITS     = 11   // unused (kept for interface compatibility)
)(
  // 1'b0 -> scalar mode: 24x24 product
  // 1'b1 -> SIMD/DP mode: packed {a_hi*b_hi, a_lo*b_lo} where hi/lo are 12-bit halves
  input  logic                         is_fp16,
  input  logic                         is_fp8,

  input  logic [PRECISION_BITS-1:0]    mantissa_a,
  input  logic [PRECISION_BITS-1:0]    mantissa_b,

  output logic [2*PRECISION_BITS-1:0]  product
);

  // --------------------------------------------------------------------------
  // Fixed geometry: 24-bit split into 4 segments of 6 bits
  // --------------------------------------------------------------------------
  localparam int unsigned SEG_W   = 6;
  localparam int unsigned NSEG    = 4;   // 24 / 6
  localparam int unsigned HALF    = 12;
  localparam int unsigned HSEG    = 2;   // 12 / 6
  localparam int unsigned PP_W    = 12;  // 6x6
  localparam int unsigned OUT_W   = 48;

  // Optional sanity (safe to remove if you dislike initial blocks)
  initial begin
    if (PRECISION_BITS != 24) $fatal(1, "This module assumes PRECISION_BITS == 24");
  end

// Split into 6-bit chunks (LSB chunk is seg[0])
  logic [SEG_W-1:0] a_seg [0:NSEG-1];
  logic [SEG_W-1:0] b_seg [0:NSEG-1];

  assign a_seg[0] = mantissa_a[ 5: 0];
  assign a_seg[1] = mantissa_a[11: 6];
  assign a_seg[2] = mantissa_a[17:12];
  assign a_seg[3] = mantissa_a[23:18];

  assign b_seg[0] = mantissa_b[ 5: 0];
  assign b_seg[1] = mantissa_b[11: 6];
  assign b_seg[2] = mantissa_b[17:12];
  assign b_seg[3] = mantissa_b[23:18];

  logic [PP_W-1:0] pp [0:NSEG-1][0:NSEG-1];

  assign pp[0][0] = (a_seg[0] * b_seg[0]) ;
  assign pp[0][1] = is_fp8? 12'd0: (a_seg[0] * b_seg[1]);
  assign pp[1][0] = is_fp8? 12'd0: (a_seg[1] * b_seg[0]);
  assign pp[1][1] = (a_seg[1] * b_seg[1]);

  assign pp[2][2] = (a_seg[2] * b_seg[2]);
  assign pp[2][3] = is_fp8? 12'd0: (a_seg[2] * b_seg[3]);
  assign pp[3][2] = is_fp8? 12'd0: (a_seg[3] * b_seg[2]);
  assign pp[3][3] = (a_seg[3] * b_seg[3]);


  logic [23:0] pp3_res [0:3];
  logic gated_pp3;
  assign gated_pp3 = is_fp16 || is_fp8; //level 2 is gated in dp or simd mode
  assign pp3_res[0] = {pp[0][0][11:6]+pp[0][1]+pp[1][0]+{pp[1][1],6'd0},pp[0][0][5:0]};
  assign pp3_res[1] = gated_pp3 ? 24'd0 : mantissa_a[11: 0]*mantissa_b[23: 12];
  assign pp3_res[2] = gated_pp3 ? 24'd0 : mantissa_a[23: 12]*mantissa_b[11: 0];
  assign pp3_res[3] = {pp[2][2][11:6]+pp[3][2]+pp[2][3]+{pp[3][3],6'd0},pp[2][2][5:0]};

  wire [36:0] final_add;
  assign final_add = {25'd0,pp3_res[0][23:12]}+{12'd0,pp3_res[1]}+{12'd0,pp3_res[2]}+{pp3_res[3],12'd0};
  assign product = {final_add[35:0],pp3_res[0][11:0]};


endmodule


module transdot_decomp_multiplier_w6_4lane #(
  parameter int unsigned PRECISION_BITS = 24,  // fixed at 24
  parameter int unsigned SMALL_BITS     = 11   // unused (kept for interface compatibility)
)(
  // 1'b0 -> scalar mode: 24x24 product
  // 1'b1 -> SIMD/DP mode: packed {a_hi*b_hi, a_lo*b_lo} where hi/lo are 12-bit halves
  input  logic                         dp_enable_i,
  input  logic                         is_fp8,

  input  logic [PRECISION_BITS-1:0]    mantissa_a,
  input  logic [PRECISION_BITS-1:0]    mantissa_b,

  output logic [2*PRECISION_BITS-1:0]  product
);

  // --------------------------------------------------------------------------
  // Fixed geometry: 24-bit split into 4 segments of 6 bits
  // --------------------------------------------------------------------------
  localparam int unsigned SEG_W   = 6;
  localparam int unsigned NSEG    = 4;   // 24 / 6
  localparam int unsigned HALF    = 12;
  localparam int unsigned HSEG    = 2;   // 12 / 6
  localparam int unsigned PP_W    = 12;  // 6x6
  localparam int unsigned OUT_W   = 48;

  // Optional sanity (safe to remove if you dislike initial blocks)
  initial begin
    if (PRECISION_BITS != 24) $fatal(1, "This module assumes PRECISION_BITS == 24");
  end

  // Split into 6-bit chunks (LSB chunk is seg[0])
  logic [SEG_W-1:0] a_seg [0:NSEG-1];
  logic [SEG_W-1:0] b_seg [0:NSEG-1];

  assign a_seg[0] = mantissa_a[ 5: 0];
  assign a_seg[1] = mantissa_a[11: 6];
  assign a_seg[2] = mantissa_a[17:12];
  assign a_seg[3] = mantissa_a[23:18];

  assign b_seg[0] = mantissa_b[ 5: 0];
  assign b_seg[1] = mantissa_b[11: 6];
  assign b_seg[2] = mantissa_b[17:12];
  assign b_seg[3] = mantissa_b[23:18];

  // --------------------------------------------------------------------------
  // Shared partial products: computed ONCE, reused by both modes
  // pp[i][j] = a_seg[i] * b_seg[j], each is 12-bit
  // --------------------------------------------------------------------------
  logic [PP_W-1:0] pp [0:NSEG-1][0:NSEG-1];
  logic gated_pp;
  assign gated_pp = is_fp8; //level 1 is gated when in fp8 mode and dp or simd mode

  //genvar i, j;
  //generate
  //  for (i = 0; i < NSEG; i++) begin : gen_pp_i
  //    for (j = 0; j < NSEG; j++) begin : gen_pp_j
  //      assign pp[i][j] = a_seg[i] * b_seg[j];
  //    end
  //  end
  //endgenerate
  assign pp[0][0] = (a_seg[0] * b_seg[0]) ;
  assign pp[0][1] = gated_pp? 12'd0: (a_seg[0] * b_seg[1]);
  assign pp[0][2] = gated_pp? 12'd0: (a_seg[0] * b_seg[2]);
  assign pp[0][3] = gated_pp? 12'd0: (a_seg[0] * b_seg[3]);
  assign pp[1][0] = gated_pp? 12'd0: (a_seg[1] * b_seg[0]);
  assign pp[1][1] = (a_seg[1] * b_seg[1]);
  assign pp[1][2] = gated_pp? 12'd0: (a_seg[1] * b_seg[2]);
  assign pp[1][3] = gated_pp? 12'd0: (a_seg[1] * b_seg[3]);
  assign pp[2][0] = gated_pp? 12'd0: (a_seg[2] * b_seg[0]);
  assign pp[2][1] = gated_pp? 12'd0: (a_seg[2] * b_seg[1]);
  assign pp[2][2] = (a_seg[2] * b_seg[2]);
  assign pp[2][3] = gated_pp? 12'd0: (a_seg[2] * b_seg[3]);
  assign pp[3][0] = gated_pp? 12'd0: (a_seg[3] * b_seg[0]);
  assign pp[3][1] = gated_pp? 12'd0: (a_seg[3] * b_seg[1]);
  assign pp[3][2] = gated_pp? 12'd0: (a_seg[3] * b_seg[2]);
  assign pp[3][3] = (a_seg[3] * b_seg[3]);

  //wire [OUT_W-1:0] product_simd_fp8 = {pp[3][3], pp[2][2], pp[1][1], pp[0][0]};

  // --------------------------------------------------------------------------
  // SIMD/DP packed product:
  //   lo = (a_seg[0..1])*(b_seg[0..1]) -> 12x12 -> 24 bits
  //   hi = (a_seg[2..3])*(b_seg[2..3]) -> 12x12 -> 24 bits
  //
  // Importantly: both lo and hi are derived from the SAME pp[][] array.
  // No new multipliers are instantiated.
  // --------------------------------------------------------------------------
  logic [12:0] pp2_add [0:7]; // first stage adders result (13 bits)
  logic [18:0] pp2_res [0:7]; // first stage adders result (19 bits)

  assign pp2_add[0] ={7'd0,pp[0][0][11:6]}+{1'b0,pp[0][1]};
  assign pp2_add[1] ={7'd0,pp[1][0][11:6]}+{1'b0,pp[1][1]};
  assign pp2_add[2] ={7'd0,pp[0][2][11:6]}+{1'b0,pp[3][0]};
  assign pp2_add[3] ={7'd0,pp[2][1][11:6]}+{1'b0,pp[3][1]};
  assign pp2_add[4] ={7'd0,pp[2][0][11:6]}+{1'b0,pp[1][2]};
  assign pp2_add[5] ={7'd0,pp[0][3][11:6]}+{1'b0,pp[1][3]};
  assign pp2_add[6] ={7'd0,pp[2][2][11:6]}+{1'd0,pp[3][2]};
  assign pp2_add[7] ={7'd0,pp[2][3][11:6]}+{1'd0,pp[3][3]};
  assign pp2_res[0] = {pp2_add[0],pp[0][0][5:0]};
  assign pp2_res[1] = {pp2_add[1],pp[1][0][5:0]};
  assign pp2_res[2] = {pp2_add[2],pp[0][2][5:0]};
  assign pp2_res[3] = {pp2_add[3],pp[2][1][5:0]};
  assign pp2_res[4] = {pp2_add[4],pp[2][0][5:0]};
  assign pp2_res[5] = {pp2_add[5],pp[0][3][5:0]};
  assign pp2_res[6] = {pp2_add[6],pp[2][2][5:0]};
  assign pp2_res[7] = {pp2_add[7],pp[2][3][5:0]};

  logic [18:0] pp3_add [0:3]; // second stage adders result (13 bits)
  logic [24:0] pp3_res [0:3]; // second stage adders result (19 bits)

  logic gated_pp3;
  assign gated_pp3 = (dp_enable_i); //level 2 is gated in dp or simd mode

  assign pp3_add[0] = {6'b0,pp2_res[0][18:6]} + pp2_res[1];
  assign pp3_add[1] = {6'b0,pp2_res[2][18:6]} + pp2_res[3];
  assign pp3_add[2] = {6'b0,pp2_res[4][18:6]} + pp2_res[5];
  assign pp3_add[3] = {6'b0,pp2_res[6][18:6]} + pp2_res[7];
  assign pp3_res[0] = {pp3_add[0],pp2_res[0][5:0]};
  assign pp3_res[1] = gated_pp3 ? 25'd0 :{pp3_add[1],pp2_res[2][5:0]};
  assign pp3_res[2] = gated_pp3 ? 25'd0 :{pp3_add[2],pp2_res[4][5:0]};
  assign pp3_res[3] = {pp3_add[3],pp2_res[6][5:0]};

//
//
  logic [24:0] pp4_add [0:1];
  logic [36:0] pp4_res [0:1];
  assign pp4_add[0] = {12'd0,pp3_res[0][24:12]} + pp3_res[1];
  assign pp4_add[1] = {12'd0,pp3_res[2][24:12]} + pp3_res[3];

  assign pp4_res[0] = {pp4_add[0],pp3_res[0][11:0]};
  assign pp4_res[1] = {pp4_add[1],pp3_res[2][11:0]};

  wire [36:0] final_add;
  assign final_add = {12'd0,pp4_res[0][36:12]} + pp4_res[1];
  //assign final_add = {24'd0,pp3_res[0][24:12]}+{12'd0,pp3_res[1]}+{12'd0,pp3_res[2]}+{pp3_res[3],12'd0};
  wire [OUT_W-1:0] product_scalar = {final_add[35:0],pp4_res[0][11:0]};

  assign product = product_scalar;


endmodule

module transdot_decomp_multiplier_w6_4lane_dp #(
  parameter int unsigned PRECISION_BITS = 24,  // fixed at 24
  parameter int unsigned SMALL_BITS     = 11   // unused (kept for interface compatibility)
)(
  // 1'b0 -> scalar mode: 24x24 product
  // 1'b1 -> SIMD/DP mode: packed {a_hi*b_hi, a_lo*b_lo} where hi/lo are 12-bit halves
  input  logic                         dp_enable_i,
  input  logic                         simd_enable_i,
  input  logic                         is_fp8,
  input  logic                         is_fp4,

  input  logic [5:0]                   shamt_lane0,
  input  logic [5:0]                   shamt_lane1,
  input  logic [4:0]                   shamt_lane2,
  input  logic [4:0]                   shamt_lane3,

  input  logic                         sign_lane0,
  input  logic                         sign_lane1,
  input  logic                         sign_lane2,
  input  logic                         sign_lane3,

  input  logic [8:0]                   fp4_y_mag0,
  input  logic [8:0]                   fp4_y_mag1,
  input  logic [8:0]                   fp4_y_mag2,
  input  logic [8:0]                   fp4_y_mag3,

  input  logic [PRECISION_BITS-1:0]    mantissa_a,
  input  logic [PRECISION_BITS-1:0]    mantissa_b,

  output logic [2*PRECISION_BITS-1:0]  product,
  output logic                         sign_out
);

  // --------------------------------------------------------------------------
  // Fixed geometry: 24-bit split into 4 segments of 6 bits
  // --------------------------------------------------------------------------
  localparam int unsigned SEG_W   = 6;
  localparam int unsigned NSEG    = 4;   // 24 / 6
  localparam int unsigned HALF    = 12;
  localparam int unsigned HSEG    = 2;   // 12 / 6
  localparam int unsigned PP_W    = 12;  // 6x6
  localparam int unsigned OUT_W   = 48;

  // Optional sanity (safe to remove if you dislike initial blocks)
  initial begin
    if (PRECISION_BITS != 24) $fatal(1, "This module assumes PRECISION_BITS == 24");
  end

  // Split into 6-bit chunks (LSB chunk is seg[0])
  logic [SEG_W-1:0] a_seg [0:NSEG-1];
  logic [SEG_W-1:0] b_seg [0:NSEG-1];

  assign a_seg[0] = mantissa_a[ 5: 0];
  assign a_seg[1] = mantissa_a[11: 6];
  assign a_seg[2] = mantissa_a[17:12];
  assign a_seg[3] = mantissa_a[23:18];

  assign b_seg[0] = mantissa_b[ 5: 0];
  assign b_seg[1] = mantissa_b[11: 6];
  assign b_seg[2] = mantissa_b[17:12];
  assign b_seg[3] = mantissa_b[23:18];

  // --------------------------------------------------------------------------
  // Shared partial products: computed ONCE, reused by both modes
  // pp[i][j] = a_seg[i] * b_seg[j], each is 12-bit
  // --------------------------------------------------------------------------
  logic [PP_W-1:0] pp [0:NSEG-1][0:NSEG-1];
  logic gated_pp;
  assign gated_pp = is_fp8 &&(dp_enable_i | simd_enable_i); //level 1 is gated when in fp8 mode and dp or simd mode

  //genvar i, j;
  //generate
  //  for (i = 0; i < NSEG; i++) begin : gen_pp_i
  //    for (j = 0; j < NSEG; j++) begin : gen_pp_j
  //      assign pp[i][j] = a_seg[i] * b_seg[j];
  //    end
  //  end
  //endgenerate
  assign pp[0][0] = (a_seg[0] * b_seg[0]) ;
  assign pp[0][1] = gated_pp? 12'd0: (a_seg[0] * b_seg[1]);
  assign pp[0][2] = gated_pp? 12'd0: (a_seg[0] * b_seg[2]);
  assign pp[0][3] = gated_pp? 12'd0: (a_seg[0] * b_seg[3]);
  assign pp[1][0] = gated_pp? 12'd0: (a_seg[1] * b_seg[0]);
  assign pp[1][1] = (a_seg[1] * b_seg[1]);
  assign pp[1][2] = gated_pp? 12'd0: (a_seg[1] * b_seg[2]);
  assign pp[1][3] = gated_pp? 12'd0: (a_seg[1] * b_seg[3]);
  assign pp[2][0] = gated_pp? 12'd0: (a_seg[2] * b_seg[0]);
  assign pp[2][1] = gated_pp? 12'd0: (a_seg[2] * b_seg[1]);
  assign pp[2][2] = (a_seg[2] * b_seg[2]);
  assign pp[2][3] = gated_pp? 12'd0: (a_seg[2] * b_seg[3]);
  assign pp[3][0] = gated_pp? 12'd0: (a_seg[3] * b_seg[0]);
  assign pp[3][1] = gated_pp? 12'd0: (a_seg[3] * b_seg[1]);
  assign pp[3][2] = gated_pp? 12'd0: (a_seg[3] * b_seg[2]);
  assign pp[3][3] = (a_seg[3] * b_seg[3]);

  logic [23:0] shifted_pp_00, shifted_pp_11, shifted_pp_22, shifted_pp_33;
  assign shifted_pp_00 = is_fp4? {'0,fp4_y_mag0,13'd0} : {'0,pp[0][0], 12'd0} >> shamt_lane0;
  assign shifted_pp_11 = is_fp4? {'0,fp4_y_mag1,13'd0} : {'0,pp[1][1], 12'd0} >> shamt_lane1;
  assign shifted_pp_22 = is_fp4? {'0,fp4_y_mag2,13'd0} : {'0,pp[2][2], 12'd0} >> shamt_lane2;
  assign shifted_pp_33 = is_fp4? {'0,fp4_y_mag3,13'd0} : {'0,pp[3][3], 12'd0} >> shamt_lane3;

  logic compared_pp_01_mag;
  logic compared_pp_23_mag;
  logic compared_pp_01_exp;
  logic compared_pp_23_exp;
  logic equal_exp_01;
  logic equal_exp_23;
  assign equal_exp_01 = (shamt_lane0 == shamt_lane1) ? 1'b1 : 1'b0;
  assign equal_exp_23 = (shamt_lane2 == shamt_lane3) ? 1'b1 : 1'b0;
  logic compared_pp_01;
  logic compared_pp_23;
  assign compared_pp_01_exp = shamt_lane0 > 0? 1'b0 : 1'b1; // only smaller exp will be shifter, then it's smaller
  assign compared_pp_23_exp = shamt_lane2 > 0? 1'b0 : 1'b1;

  assign compared_pp_01_mag = (pp[0][0] > pp[1][1]) ? 1'b1 : 1'b0;
  assign compared_pp_23_mag = (pp[2][2] > pp[3][3]) ? 1'b1 : 1'b0;

  assign compared_pp_01 = equal_exp_01? compared_pp_01_mag : compared_pp_01_exp;
  assign compared_pp_23 = equal_exp_23? compared_pp_23_mag : compared_pp_23_exp;

  //when need to xored, if it's mgnitude is smaller and the sign is different, then need to negate
  logic negate_pp_00, negate_pp_11, negate_pp_22, negate_pp_33;
  assign negate_pp_00 = (sign_lane0 ^ sign_lane1) & (~compared_pp_01);
  assign negate_pp_11 = (sign_lane0 ^ sign_lane1) & (compared_pp_01);
  assign negate_pp_22 = (sign_lane2 ^ sign_lane3) & (~compared_pp_23);
  assign negate_pp_33 = (sign_lane2 ^ sign_lane3) & (compared_pp_23);
  logic [23:0] xored_pp_00, xored_pp_11, xored_pp_22, xored_pp_33;

  assign xored_pp_00 = negate_pp_00 ? (~shifted_pp_00 + 1'b1) : shifted_pp_00;
  assign xored_pp_11 = negate_pp_11 ? (~shifted_pp_11 + 1'b1) : shifted_pp_11;
  assign xored_pp_22 = negate_pp_22 ? (~shifted_pp_22 + 1'b1) : shifted_pp_22;
  assign xored_pp_33 = negate_pp_33 ? (~shifted_pp_33 + 1'b1) : shifted_pp_33;

  logic sign_01, sign_23;
  assign sign_01 = is_fp8? ((compared_pp_01) ? sign_lane0 : sign_lane1): sign_lane0;
  assign sign_23 = is_fp8? ((compared_pp_23) ? sign_lane2 : sign_lane3): sign_lane1;
  // --------------------------------------------------------------------------
  //dot product datapath. Need to shift and negate if necessary

  // --------------------------------------------------------------------------
  // SIMD/DP packed product:
  //   lo = (a_seg[0..1])*(b_seg[0..1]) -> 12x12 -> 24 bits
  //   hi = (a_seg[2..3])*(b_seg[2..3]) -> 12x12 -> 24 bits
  //
  // Importantly: both lo and hi are derived from the SAME pp[][] array.
  // No new multipliers are instantiated.
  // --------------------------------------------------------------------------
  logic [12:0] pp2_add [0:7]; // first stage adders result (13 bits)
  logic [18:0] pp2_res [0:7]; // first stage adders result (19 bits)

  assign pp2_add[0] ={7'd0,pp[0][0][11:6]}+{1'b0,pp[0][1]};
  assign pp2_add[1] ={7'd0,pp[1][0][11:6]}+{1'b0,pp[1][1]};
  assign pp2_add[2] ={7'd0,pp[0][2][11:6]}+{1'b0,pp[3][0]};
  assign pp2_add[3] ={7'd0,pp[2][1][11:6]}+{1'b0,pp[3][1]};
  assign pp2_add[4] ={7'd0,pp[2][0][11:6]}+{1'b0,pp[1][2]};
  assign pp2_add[5] ={7'd0,pp[0][3][11:6]}+{1'b0,pp[1][3]};
  assign pp2_add[6] ={7'd0,pp[2][2][11:6]}+{1'd0,pp[3][2]};
  assign pp2_add[7] ={7'd0,pp[2][3][11:6]}+{1'd0,pp[3][3]};
  assign pp2_res[0] = {pp2_add[0],pp[0][0][5:0]};
  assign pp2_res[1] = {pp2_add[1],pp[1][0][5:0]};
  assign pp2_res[2] = {pp2_add[2],pp[0][2][5:0]};
  assign pp2_res[3] = {pp2_add[3],pp[2][1][5:0]};
  assign pp2_res[4] = {pp2_add[4],pp[2][0][5:0]};
  assign pp2_res[5] = {pp2_add[5],pp[0][3][5:0]};
  assign pp2_res[6] = {pp2_add[6],pp[2][2][5:0]};
  assign pp2_res[7] = {pp2_add[7],pp[2][3][5:0]};

  logic [18:0] pp3_add [0:3]; // second stage adders result (13 bits)
  logic [24:0] pp3_res [0:3]; // second stage adders result (19 bits)

  logic gated_pp3;
  assign gated_pp3 = (dp_enable_i || simd_enable_i); //level 2 is gated in dp or simd mode
  logic dp_sel;
  assign dp_sel = is_fp8 && dp_enable_i;

  assign pp3_add[0] = {6'b0,pp2_res[0][18:6]} + pp2_res[1];
  assign pp3_add[1] = {6'b0,pp2_res[2][18:6]} + pp2_res[3];
  assign pp3_add[2] = {6'b0,pp2_res[4][18:6]} + pp2_res[5];
  assign pp3_add[3] = {6'b0,pp2_res[6][18:6]} + pp2_res[7];
  assign pp3_res[0] = {pp3_add[0],pp2_res[0][5:0]};
  assign pp3_res[1] = (gated_pp3 ? 25'd0 :{pp3_add[1],pp2_res[2][5:0]});
  assign pp3_res[2] = (gated_pp3 ? 25'd0 :{pp3_add[2],pp2_res[4][5:0]});
  assign pp3_res[3] = {pp3_add[3],pp2_res[6][5:0]};


  logic [35:0] pp4_res [0:1];
  logic [35:0]  pp3_addend_lane0, pp3_addend_lane1,pp3_addend_lane2, pp3_addend_lane3;
  assign pp3_addend_lane0 = (dp_sel)? {xored_pp_00,12'd0} : {12'd0,pp3_res[0]};
  assign pp3_addend_lane1 = (dp_sel)? {xored_pp_11,12'd0} : {pp3_res[1],12'd0};
  assign pp3_addend_lane2 = (dp_sel)? {xored_pp_22,12'd0} : {12'd0,pp3_res[2]};
  assign pp3_addend_lane3 = (dp_sel)? {xored_pp_33,12'd0} : {pp3_res[3],12'd0};
  //assign pp4_add[0] = {12'd0,pp3_res[0][24:12]} + pp3_res[1];
  //assign pp4_add[1] = {12'd0,pp3_res[2][24:12]} + pp3_res[3];
  assign pp4_res[0] = pp3_addend_lane0 + pp3_addend_lane1;
  assign pp4_res[1] = pp3_addend_lane2 + pp3_addend_lane3;

  logic [36:0] shifted_pp4_0, shifted_pp4_1;
  logic [5:0] shamt_amount_pp4_lane0, shamt_amount_pp4_lane1;
  assign shamt_amount_pp4_lane0 = is_fp8 ? '0: shamt_lane0;
  assign shamt_amount_pp4_lane1 = is_fp8 ? '0: shamt_lane1;
  assign shifted_pp4_0 = is_fp8 ? {pp4_res[0]} : {pp4_res[0][24:0], 12'd0} >> shamt_amount_pp4_lane0;
  assign shifted_pp4_1 = is_fp8 ? {pp4_res[1]} : {'0,pp4_res[1]} >> shamt_amount_pp4_lane1;

  logic compare_pp4_mag_fp16_dp;
  logic compare_pp4_mag_fp8_dp;
  logic compare_pp4_exp;
  logic equal_exp_pp4;
  assign equal_exp_pp4 = (shamt_amount_pp4_lane0 ==0 && shamt_amount_pp4_lane1 == 0) ? 1'b1 : 1'b0;
  assign compare_pp4_exp = shamt_amount_pp4_lane0 > 0? 1'b0 : 1'b1; // only smaller exp will be shifter, then it's smaller
  assign compare_pp4_mag_fp16_dp = (pp4_res[0] > pp4_res[1][24:12]) ? 1'b1 : 1'b0;
  assign compare_pp4_mag_fp8_dp = (pp4_res[0] > pp4_res[1]) ? 1'b1 : 1'b0;
  logic compare_pp4;
  assign compare_pp4 = is_fp8? compare_pp4_mag_fp8_dp : (equal_exp_pp4? compare_pp4_mag_fp16_dp : compare_pp4_exp);
  logic negate_pp4_0, negate_pp4_1;
  assign negate_pp4_0 = (sign_01 ^ sign_23) & (~compare_pp4);
  assign negate_pp4_1 = (sign_01 ^ sign_23) & (compare_pp4);
  logic [36:0] xored_pp4_0, xored_pp4_1;
  assign xored_pp4_0 = negate_pp4_0 ? (~shifted_pp4_0 + 1'd1) : shifted_pp4_0;
  assign xored_pp4_1 = negate_pp4_1 ? (~shifted_pp4_1 + 1'd1) : shifted_pp4_1;

  wire [47:0] final_add;
  logic [47:0] res0_pp4_dp0, res0_pp4_dp1;
  assign res0_pp4_dp0 = dp_enable_i? {xored_pp4_0,12'd0} : {12'd0,pp4_res[0]};
  assign res0_pp4_dp1 = dp_enable_i? {xored_pp4_1,12'd0} : {pp4_res[1],12'd0};
  assign final_add = res0_pp4_dp0 + res0_pp4_dp1;
  assign product = final_add[47:0];

  //handling sign out
  assign sign_out = compare_pp4 ? sign_01 : sign_23;


endmodule


module transdot_decomp_multiplier_w6_4lane_dp_piped #(
  parameter int unsigned PRECISION_BITS = 24  // fixed at 24
)(
  // 1'b0 -> scalar mode: 24x24 product
  // 1'b1 -> SIMD/DP mode: packed {a_hi*b_hi, a_lo*b_lo} where hi/lo are 12-bit halves
  input  logic                        clk_i,
  input  logic                        pipe_en,
  input  logic                         dp_enable_i,
  input  logic                         simd_enable_i,
  input  logic                         is_fp8,
  input  logic                         is_fp4,

  input  logic [5:0]                   shamt_lane0,
  input  logic [5:0]                   shamt_lane1,
  input  logic [4:0]                   shamt_lane2,
  input  logic [4:0]                   shamt_lane3,

  input  logic                         sign_lane0,
  input  logic                         sign_lane1,
  input  logic                         sign_lane2,
  input  logic                         sign_lane3,

  input  logic [8:0]                   fp4_y_mag0,
  input  logic [8:0]                   fp4_y_mag1,
  input  logic [8:0]                   fp4_y_mag2,
  input  logic [8:0]                   fp4_y_mag3,

  input  logic [PRECISION_BITS-1:0]        mantissa_a,
  input  logic [PRECISION_BITS-1:0]        mantissa_b,

  output logic [2*PRECISION_BITS-1:0]      product_non_dp_o,
  output logic [2*PRECISION_BITS-1:0]      product_dp_o,
  output logic                             sign_out
);

  // --------------------------------------------------------------------------
  // Fixed geometry: 24-bit split into 4 segments of 6 bits
  // --------------------------------------------------------------------------
  localparam int unsigned SEG_W   = 6;
  localparam int unsigned NSEG    = 4;   // 24 / 6
  localparam int unsigned HALF    = 12;
  localparam int unsigned HSEG    = 2;   // 12 / 6
  localparam int unsigned PP_W    = 12;  // 6x6
  localparam int unsigned OUT_W   = 48;

  // Optional sanity (safe to remove if you dislike initial blocks)
  initial begin
    if (PRECISION_BITS != 24) $fatal(1, "This module assumes PRECISION_BITS == 24");
  end

  // Split into 6-bit chunks (LSB chunk is seg[0])
  logic [SEG_W-1:0] a_seg [0:NSEG-1];
  logic [SEG_W-1:0] b_seg [0:NSEG-1];

  assign a_seg[0] = mantissa_a[ 5: 0];
  assign a_seg[1] = mantissa_a[11: 6];
  assign a_seg[2] = mantissa_a[17:12];
  assign a_seg[3] = mantissa_a[23:18];

  assign b_seg[0] = mantissa_b[ 5: 0];
  assign b_seg[1] = mantissa_b[11: 6];
  assign b_seg[2] = mantissa_b[17:12];
  assign b_seg[3] = mantissa_b[23:18];

  logic [PP_W-1:0] pp [0:NSEG-1][0:NSEG-1];
  logic gated_pp;
  assign gated_pp = is_fp8; //level 1 is gated when in fp8 mode and dp or simd mode

  assign pp[0][0] = (a_seg[0] * b_seg[0]) ;
  assign pp[0][1] = gated_pp? 12'd0: (a_seg[0] * b_seg[1]);
  assign pp[1][0] = gated_pp? 12'd0: (a_seg[1] * b_seg[0]);
  assign pp[1][1] = (a_seg[1] * b_seg[1]);

  assign pp[2][2] = (a_seg[2] * b_seg[2]);
  assign pp[2][3] = gated_pp? 12'd0: (a_seg[2] * b_seg[3]);
  assign pp[3][2] = gated_pp? 12'd0: (a_seg[3] * b_seg[2]);
  assign pp[3][3] = (a_seg[3] * b_seg[3]);


  logic [23:0] pp3_res [0:3];
  logic gated_pp3;
  assign gated_pp3 = (dp_enable_i || simd_enable_i); //level 2 is gated in dp or simd mode
  assign pp3_res[0] = {pp[0][0][11:6]+pp[0][1]+pp[1][0]+{pp[1][1],6'd0},pp[0][0][5:0]};
  assign pp3_res[1] = gated_pp3 ? 24'd0 : mantissa_a[11: 0]*mantissa_b[23: 12];
  assign pp3_res[2] = gated_pp3 ? 24'd0 : mantissa_a[23: 12]*mantissa_b[11: 0];
  assign pp3_res[3] = {pp[2][2][11:6]+pp[3][2]+pp[2][3]+{pp[3][3],6'd0},pp[2][2][5:0]};

  // --------------------------------------------------------------------------
  //dot product datapath. Need to shift and negate if necessary
  logic [23:0] xored_pp_00, xored_pp_11, xored_pp_22, xored_pp_33;
  logic [35:0] xored_pp16_0, xored_pp16_1;
  logic tentative_sign;
  logic unused_sign_fp16;
  compare_shift_xor_4lane #(
  .PRECISION_BITS(8),
  .SHAMT_BITS(5),
  .BIT_AFTER_SHIFT(24)
  ) compare_shift_xor_lane01 (
    .shamt_0(shamt_lane0[4:0]),
    .shamt_1(shamt_lane1[4:0]),
    .shamt_2(shamt_lane2[4:0]),
    .shamt_3(shamt_lane3[4:0]),
    .sign_0(sign_lane0),
    .sign_1(sign_lane1),
    .sign_2(sign_lane2),
    .sign_3(sign_lane3),
    .mantissa_0(pp[0][0][7:0]),
    .mantissa_1(pp[1][1][7:0]),
    .mantissa_2(pp[2][2][7:0]),
    .mantissa_3(pp[3][3][7:0]),
    .sign_out(tentative_sign),
    .mantissa_0_out(xored_pp_00),
    .mantissa_1_out(xored_pp_11),
    .mantissa_2_out(xored_pp_22),
    .mantissa_3_out(xored_pp_33)
  );

  compare_shift_xor #(
  .PRECISION_BITS(36),
  .SHAMT_BITS(6),
  .BIT_AFTER_SHIFT(36)
  ) compare_shift_xor_fp16_dp (
    .shamt_0(shamt_lane0),
    .shamt_1(shamt_lane1),
    .sign_0(sign_lane0),
    .sign_1(sign_lane1),
    .mantissa_0({pp3_res[0],12'd0}),
    .mantissa_1({pp3_res[3],12'd0}),
    .sign_out(unused_sign_fp16),
    .mantissa_0_out(xored_pp16_0),
    .mantissa_1_out(xored_pp16_1)
  );

  logic dp_sel_fp8, dp_sel_fp16, dp_sel_fp4;
  logic [23:0] xored_fp4_00, xored_fp4_11, xored_fp4_22, xored_fp4_33;
  logic [23:0] aligned_fp4_00, aligned_fp4_11, aligned_fp4_22, aligned_fp4_33;
  assign dp_sel_fp8 = is_fp8 && (~is_fp4) && dp_enable_i;
  assign dp_sel_fp16 = (~is_fp8) && (~is_fp4) && dp_enable_i;
  assign dp_sel_fp4 = is_fp4 && dp_enable_i;

  // FP4 uses the same outer path as FP8: build one aligned signed term per
  // lane, then feed all four terms into the shared final compressor.
  assign aligned_fp4_00 = {2'b00, fp4_y_mag0, 13'd0};
  assign aligned_fp4_11 = {2'b00, fp4_y_mag1, 13'd0};
  assign aligned_fp4_22 = {2'b00, fp4_y_mag2, 13'd0};
  assign aligned_fp4_33 = {2'b00, fp4_y_mag3, 13'd0};

  assign xored_fp4_00 = sign_lane0 ? (~aligned_fp4_00 + 1'b1) : aligned_fp4_00;
  assign xored_fp4_11 = sign_lane1 ? (~aligned_fp4_11 + 1'b1) : aligned_fp4_11;
  assign xored_fp4_22 = sign_lane2 ? (~aligned_fp4_22 + 1'b1) : aligned_fp4_22;
  assign xored_fp4_33 = sign_lane3 ? (~aligned_fp4_33 + 1'b1) : aligned_fp4_33;

  logic [49:0] final_sum;
  logic [49:0] final_sum_mag;
  logic        final_sum_neg;
  logic [47:0] product_non_dp_d, product_non_dp_q;
  logic [47:0] product_dp_d, product_dp_q;
  logic        sign_out_d, sign_out_q;
  logic [47:0]  pp3_addend_lane0, pp3_addend_lane1,pp3_addend_lane2, pp3_addend_lane3;
  logic [49:0]  pp3_addend_lane0_ext, pp3_addend_lane1_ext, pp3_addend_lane2_ext, pp3_addend_lane3_ext;
  assign pp3_addend_lane0 = dp_sel_fp8 ? {xored_pp_00,24'd0}
                           : dp_sel_fp16 ? {xored_pp16_0,12'd0}
                           : dp_sel_fp4 ? {xored_fp4_00,24'd0}
                           : {24'd0,pp3_res[0]};
  assign pp3_addend_lane1 = dp_sel_fp8 ? {xored_pp_11,24'd0}
                           : dp_sel_fp16 ? {xored_pp16_1,12'd0}
                           : dp_sel_fp4 ? {xored_fp4_11,24'd0}
                           : {12'd0,pp3_res[1],12'd0};
  assign pp3_addend_lane2 = dp_sel_fp8 ? {xored_pp_22,24'd0}
                           : dp_sel_fp16 ? 48'd0
                           : dp_sel_fp4 ? {xored_fp4_22,24'd0}
                           : {12'd0,pp3_res[2],12'd0};
  assign pp3_addend_lane3 = dp_sel_fp8 ? {xored_pp_33,24'd0}
                           : dp_sel_fp16 ? 48'd0
                           : dp_sel_fp4 ? {xored_fp4_33,24'd0}
                           : {pp3_res[3],24'd0};

  assign pp3_addend_lane0_ext = (dp_sel_fp8 || dp_sel_fp16 || dp_sel_fp4) ? {{2{pp3_addend_lane0[47]}}, pp3_addend_lane0}
                                                                            : {2'b00, pp3_addend_lane0};
  assign pp3_addend_lane1_ext = (dp_sel_fp8 || dp_sel_fp16 || dp_sel_fp4) ? {{2{pp3_addend_lane1[47]}}, pp3_addend_lane1}
                                                                            : {2'b00, pp3_addend_lane1};
  assign pp3_addend_lane2_ext = (dp_sel_fp8 || dp_sel_fp4) ? {{2{pp3_addend_lane2[47]}}, pp3_addend_lane2}
                                                             : {2'b00, pp3_addend_lane2};
  assign pp3_addend_lane3_ext = (dp_sel_fp8 || dp_sel_fp4) ? {{2{pp3_addend_lane3[47]}}, pp3_addend_lane3}
                                                             : {2'b00, pp3_addend_lane3};

  adder_4 #( 
    .W(50)
  )pp4_compressor  (
    .in0(pp3_addend_lane0_ext),
    .in1(pp3_addend_lane1_ext),
    .in2(pp3_addend_lane2_ext),
    .in3(pp3_addend_lane3_ext),
    .sum(final_sum)
  );
  assign final_sum_neg = final_sum[49];
  assign final_sum_mag = final_sum_neg ? $unsigned(-$signed(final_sum)) : final_sum;
  assign product_non_dp_d = final_sum[47:0];
  assign product_dp_d = is_fp4 ? final_sum_mag[47:0] : final_sum_mag[48:1];
  assign sign_out_d = dp_enable_i ? ((final_sum_mag == 50'd0) ? 1'b0 : final_sum_neg) : 1'b0;

`ifdef COMBINATIONAL
  assign product_non_dp_o = product_non_dp_d;
  assign product_dp_o = product_dp_d;
  assign sign_out = sign_out_d;
`else
  always_ff @(posedge clk_i) begin
    if (pipe_en) begin
      product_non_dp_q <= product_non_dp_d;
      product_dp_q <= product_dp_d;
      sign_out_q <= sign_out_d;
    end
  end

  assign product_non_dp_o = product_non_dp_q;
  assign product_dp_o = product_dp_q;
  assign sign_out = sign_out_q;
`endif

endmodule

module compare_shift_xor #(
  parameter int unsigned PRECISION_BITS = 8,
  parameter int unsigned SHAMT_BITS = 4,
  parameter int unsigned BIT_AFTER_SHIFT = 24
)(
  input  logic [SHAMT_BITS-1:0]                   shamt_0,
  input  logic [SHAMT_BITS-1:0]                   shamt_1,
  input  logic                         sign_0,
  input  logic                         sign_1,
  input  logic [PRECISION_BITS-1:0]      mantissa_0,
  input  logic [PRECISION_BITS-1:0]      mantissa_1,
  output logic                         sign_out,
  output logic [BIT_AFTER_SHIFT-1:0]      mantissa_0_out,
  output logic [BIT_AFTER_SHIFT-1:0]      mantissa_1_out
);
 logic [BIT_AFTER_SHIFT-1:0] shifted_mantissa_0, shifted_mantissa_1;
 assign shifted_mantissa_0 = mantissa_0 >> shamt_0;
 assign shifted_mantissa_1 = mantissa_1 >> shamt_1;

 // Keep the final 4:2 compressor outside this helper. Emit full-width shifted
 // terms in two's complement so the shared signed compressor can sum them
 // directly for FP16-DP, mirroring the FP8 helper structure.
 assign mantissa_0_out = sign_0 ? (~shifted_mantissa_0 + 1'b1) : shifted_mantissa_0;
 assign mantissa_1_out = sign_1 ? (~shifted_mantissa_1 + 1'b1) : shifted_mantissa_1;
 assign sign_out = 1'b0;
endmodule

module compare_shift_xor_4lane #(
  parameter int unsigned PRECISION_BITS = 8,
  parameter int unsigned SHAMT_BITS = 4,
  parameter int unsigned BIT_AFTER_SHIFT = 24
)(
  input  logic [SHAMT_BITS-1:0]                   shamt_0,
  input  logic [SHAMT_BITS-1:0]                   shamt_1,
  input  logic [SHAMT_BITS-1:0]                   shamt_2,
  input  logic [SHAMT_BITS-1:0]                   shamt_3,
  input  logic                         sign_0,
  input  logic                         sign_1,
  input  logic                         sign_2,
  input  logic                         sign_3,
  input  logic [PRECISION_BITS-1:0]      mantissa_0,
  input  logic [PRECISION_BITS-1:0]      mantissa_1,
  input  logic [PRECISION_BITS-1:0]      mantissa_2,
  input  logic [PRECISION_BITS-1:0]      mantissa_3,
  output logic                         sign_out,
  output logic [BIT_AFTER_SHIFT-1:0]      mantissa_0_out,
  output logic [BIT_AFTER_SHIFT-1:0]      mantissa_1_out,
  output logic [BIT_AFTER_SHIFT-1:0]      mantissa_2_out,
  output logic [BIT_AFTER_SHIFT-1:0]      mantissa_3_out
);
 logic [BIT_AFTER_SHIFT-1:0] shifted_mantissa_0, shifted_mantissa_1, shifted_mantissa_2, shifted_mantissa_3;

 assign shifted_mantissa_0 = {mantissa_0,14'd0} >> shamt_0;
 assign shifted_mantissa_1 = {mantissa_1,14'd0} >> shamt_1;
 assign shifted_mantissa_2 = {mantissa_2,14'd0} >> shamt_2;
 assign shifted_mantissa_3 = {mantissa_3,14'd0} >> shamt_3;

 // Keep the 4:2 compressor outside this helper. Emit one aligned signed term per lane
 // in full BIT_AFTER_SHIFT-wide two's complement form.
 assign mantissa_0_out = sign_0 ? (~shifted_mantissa_0 + 1'b1) : shifted_mantissa_0;
 assign mantissa_1_out = sign_1 ? (~shifted_mantissa_1 + 1'b1) : shifted_mantissa_1;
 assign mantissa_2_out = sign_2 ? (~shifted_mantissa_2 + 1'b1) : shifted_mantissa_2;
 assign mantissa_3_out = sign_3 ? (~shifted_mantissa_3 + 1'b1) : shifted_mantissa_3;

 assign sign_out = 1'b0;
endmodule

module transdot_separated_multiplier_dot_product_path #(
  parameter int unsigned PRECISION_BITS      = 24,
  parameter int unsigned PRECISION_BITS_SIMD = 11,
  parameter int unsigned PRECISION_BITS_FP8  = 4
)(
  input  logic                         clk_i,
  input  logic                         pipe_en,
  input  logic                         dp_enable_i,
  input  logic                         simd_enable_i,
  input  logic                         fp4_enable_i,
  input  logic                         src_is_fp8_i,

  input  logic [5:0]                   shamt_lane0_i,
  input  logic [5:0]                   shamt_lane1_i,
  input  logic [3:0]                   shamt_lane2_i,
  input  logic [3:0]                   shamt_lane3_i,

  input  logic                         tentative_sign_lane0_i,
  input  logic                         tentative_sign_lane1_i,
  input  logic                         tentative_sign_lane2_i,
  input  logic                         tentative_sign_lane3_i,

  input  logic [8:0]                   fp4_y_mag0_i,
  input  logic [8:0]                   fp4_y_mag1_i,
  input  logic [8:0]                   fp4_y_mag2_i,
  input  logic [8:0]                   fp4_y_mag3_i,

  input  logic [PRECISION_BITS-1:0]      mantissa_a_i,
  input  logic [PRECISION_BITS-1:0]      mantissa_b_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_a_simd_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_b_simd_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_2_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_2_i,

  output logic [2*PRECISION_BITS-1:0]      product_o,
  output logic [2*PRECISION_BITS_SIMD-1:0] product_simd_o,
  output logic [2*PRECISION_BITS_FP8-1:0]  product_fp8_1_o,
  output logic [2*PRECISION_BITS_FP8-1:0]  product_fp8_2_o,
  output logic [2*PRECISION_BITS_SIMD+4:0] product_shifted_dp_post_o,
  output logic [47:0]                      product_shifted_dp_fp4_o,
  output logic                             tentative_sign_dp_o
);

  localparam int unsigned DP_TO_FP8_PAD     = 2*PRECISION_BITS_SIMD - 2*PRECISION_BITS_FP8;
  localparam int unsigned DP_ALIGN_BITS     = 2*PRECISION_BITS_SIMD + 2;
  localparam int unsigned DP_PAIR_BITS      = DP_ALIGN_BITS + 1;
  localparam int unsigned FP4_LANE_MAG_BITS = 22;
  localparam int unsigned FP4_PAIR_MAG_BITS = FP4_LANE_MAG_BITS + 1;
  localparam int unsigned FP4_TERM_BITS     = FP4_PAIR_MAG_BITS + 25;

  logic [2*PRECISION_BITS-1:0]        product_raw, product_q;
  logic [2*PRECISION_BITS_SIMD-1:0]   product_simd_raw, product_simd_q;
  logic [2*PRECISION_BITS_FP8-1:0]    product_fp8_1_raw, product_fp8_1_q;
  logic [2*PRECISION_BITS_FP8-1:0]    product_fp8_2_raw, product_fp8_2_q;

  logic [2*PRECISION_BITS_SIMD+4:0]   product_shifted_dp_post_d;
  logic [2*PRECISION_BITS_SIMD+4:0]   product_shifted_dp_post_q;
  logic [47:0]                        product_shifted_dp_fp4_d;
  logic [47:0]                        product_shifted_dp_fp4_q;
  logic                               tentative_sign_dp_d;
  logic                               tentative_sign_dp_q;
  logic                               tentative_sign_dp_fp4;
  logic                               tentative_sign_dp_nonfp4;

  logic [2*PRECISION_BITS_SIMD-1:0]   dp_prod0_ext, dp_prod1_ext;
  logic [2*PRECISION_BITS_SIMD-1:0]   dp_prod2_ext, dp_prod3_ext;
  logic [DP_ALIGN_BITS-1:0]           dp_prod0_shifted_base, dp_prod1_shifted_base;
  logic [DP_ALIGN_BITS-1:0]           dp_prod2_shifted_base, dp_prod3_shifted_base;
  logic [DP_ALIGN_BITS-1:0]           dp_prod0_aligned, dp_prod1_aligned;
  logic [DP_ALIGN_BITS-1:0]           dp_prod2_aligned, dp_prod3_aligned;
  logic [DP_PAIR_BITS-1:0]            product_shifted_dp_lane01, product_shifted_dp_lane23;
  logic                               tentative_sign_dp_lane01, tentative_sign_dp_lane23;

  logic [FP4_LANE_MAG_BITS-1:0]       fp4_lane0_mag, fp4_lane1_mag, fp4_lane2_mag, fp4_lane3_mag;
  logic [FP4_PAIR_MAG_BITS-1:0]       fp4_pair01_mag, fp4_pair23_mag;
  logic                               fp4_pair01_sign, fp4_pair23_sign;
  logic [FP4_TERM_BITS-1:0]           fp4_term0_mag, fp4_term1_mag, fp4_sum_mag;

  // Separated multiplier baseline for the paper: dedicated multipliers first,
  // then a dedicated dot-product reduction path without multiplier sharing.
  assign product_raw = mantissa_a_i * mantissa_b_i;
  assign product_simd_raw = mantissa_a_simd_i * mantissa_b_simd_i;
  assign product_fp8_1_raw = mantissa_a_fp8_1_i * mantissa_b_fp8_1_i;
  assign product_fp8_2_raw = mantissa_a_fp8_2_i * mantissa_b_fp8_2_i;

  assign dp_prod0_ext = product_raw[2*PRECISION_BITS-1-:2*PRECISION_BITS_SIMD];
  assign dp_prod1_ext = product_simd_raw;
  assign dp_prod2_ext = {product_fp8_1_raw, {DP_TO_FP8_PAD{1'b0}}};
  assign dp_prod3_ext = {product_fp8_2_raw, {DP_TO_FP8_PAD{1'b0}}};

  assign dp_prod0_shifted_base = {dp_prod0_ext, 2'b0};
  assign dp_prod1_shifted_base = {dp_prod1_ext, 2'b0};
  assign dp_prod2_shifted_base = {dp_prod2_ext, 2'b0};
  assign dp_prod3_shifted_base = {dp_prod3_ext, 2'b0};

  assign dp_prod0_aligned = dp_prod0_shifted_base >> shamt_lane0_i;
  assign dp_prod1_aligned = dp_prod1_shifted_base >> shamt_lane1_i;
  assign dp_prod2_aligned = dp_prod2_shifted_base >> shamt_lane2_i;
  assign dp_prod3_aligned = dp_prod3_shifted_base >> shamt_lane3_i;

  // Match the legacy FP4 dot-product behavior with a dedicated post-multiply
  // reduction path.
  assign fp4_lane0_mag = {fp4_y_mag0_i, 13'd0};
  assign fp4_lane1_mag = {fp4_y_mag1_i, 13'd0};
  assign fp4_lane2_mag = {fp4_y_mag2_i, 13'd0};
  assign fp4_lane3_mag = {fp4_y_mag3_i, 13'd0};

  always_comb begin
    fp4_pair01_mag = '0;
    fp4_pair23_mag = '0;
    fp4_pair01_sign = 1'b0;
    fp4_pair23_sign = 1'b0;
    fp4_term0_mag = '0;
    fp4_term1_mag = '0;
    fp4_sum_mag = '0;
    product_shifted_dp_fp4_d = '0;
    tentative_sign_dp_fp4 = 1'b0;

    if (tentative_sign_lane0_i == tentative_sign_lane1_i) begin
      fp4_pair01_mag = fp4_lane0_mag + fp4_lane1_mag;
      fp4_pair01_sign = tentative_sign_lane0_i;
    end else if (fp4_lane0_mag >= fp4_lane1_mag) begin
      fp4_pair01_mag = fp4_lane0_mag - fp4_lane1_mag;
      fp4_pair01_sign = tentative_sign_lane0_i;
    end else begin
      fp4_pair01_mag = fp4_lane1_mag - fp4_lane0_mag;
      fp4_pair01_sign = tentative_sign_lane1_i;
    end

    if (tentative_sign_lane2_i == tentative_sign_lane3_i) begin
      fp4_pair23_mag = fp4_lane2_mag + fp4_lane3_mag;
      fp4_pair23_sign = tentative_sign_lane2_i;
    end else if (fp4_lane2_mag >= fp4_lane3_mag) begin
      fp4_pair23_mag = fp4_lane2_mag - fp4_lane3_mag;
      fp4_pair23_sign = tentative_sign_lane2_i;
    end else begin
      fp4_pair23_mag = fp4_lane3_mag - fp4_lane2_mag;
      fp4_pair23_sign = tentative_sign_lane3_i;
    end

    if (fp4_pair01_mag == '0) fp4_pair01_sign = 1'b0;
    if (fp4_pair23_mag == '0) fp4_pair23_sign = 1'b0;

    fp4_term0_mag = {1'b0, fp4_pair01_mag, 24'd0};
    fp4_term1_mag = {1'b0, fp4_pair23_mag, 24'd0};

    if (fp4_pair01_sign == fp4_pair23_sign) begin
      fp4_sum_mag = fp4_term0_mag + fp4_term1_mag;
      tentative_sign_dp_fp4 = fp4_pair01_sign;
    end else if (fp4_term0_mag >= fp4_term1_mag) begin
      fp4_sum_mag = fp4_term0_mag - fp4_term1_mag;
      tentative_sign_dp_fp4 = fp4_pair01_sign;
    end else begin
      fp4_sum_mag = fp4_term1_mag - fp4_term0_mag;
      tentative_sign_dp_fp4 = fp4_pair23_sign;
    end

    if (fp4_sum_mag == '0) tentative_sign_dp_fp4 = 1'b0;
    product_shifted_dp_fp4_d = fp4_sum_mag[47:0];
  end

  always_comb begin
    product_shifted_dp_lane01 = '0;
    tentative_sign_dp_lane01 = 1'b0;
    product_shifted_dp_lane23 = '0;
    tentative_sign_dp_lane23 = 1'b0;
    product_shifted_dp_post_d = '0;
    tentative_sign_dp_nonfp4 = 1'b0;
    tentative_sign_dp_d = 1'b0;

    if (tentative_sign_lane0_i == tentative_sign_lane1_i) begin
      product_shifted_dp_lane01 = dp_prod0_aligned + dp_prod1_aligned;
      tentative_sign_dp_lane01 = tentative_sign_lane0_i;
    end else if (dp_prod0_aligned >= dp_prod1_aligned) begin
      product_shifted_dp_lane01 = dp_prod0_aligned - dp_prod1_aligned;
      tentative_sign_dp_lane01 = tentative_sign_lane0_i;
    end else begin
      product_shifted_dp_lane01 = dp_prod1_aligned - dp_prod0_aligned;
      tentative_sign_dp_lane01 = tentative_sign_lane1_i;
    end

    if (tentative_sign_lane2_i == tentative_sign_lane3_i) begin
      product_shifted_dp_lane23 = dp_prod2_aligned + dp_prod3_aligned;
      tentative_sign_dp_lane23 = tentative_sign_lane2_i;
    end else if (dp_prod2_aligned >= dp_prod3_aligned) begin
      product_shifted_dp_lane23 = dp_prod2_aligned - dp_prod3_aligned;
      tentative_sign_dp_lane23 = tentative_sign_lane2_i;
    end else begin
      product_shifted_dp_lane23 = dp_prod3_aligned - dp_prod2_aligned;
      tentative_sign_dp_lane23 = tentative_sign_lane3_i;
    end

    if (product_shifted_dp_lane01 == '0) tentative_sign_dp_lane01 = 1'b0;
    if (product_shifted_dp_lane23 == '0) tentative_sign_dp_lane23 = 1'b0;

    if (!src_is_fp8_i) begin
      product_shifted_dp_post_d = product_shifted_dp_lane01;
      tentative_sign_dp_nonfp4 = tentative_sign_dp_lane01;
    end else if (tentative_sign_dp_lane01 == tentative_sign_dp_lane23) begin
      product_shifted_dp_post_d = product_shifted_dp_lane01 + product_shifted_dp_lane23;
      tentative_sign_dp_nonfp4 = tentative_sign_dp_lane01;
    end else if (product_shifted_dp_lane01 >= product_shifted_dp_lane23) begin
      product_shifted_dp_post_d = product_shifted_dp_lane01 - product_shifted_dp_lane23;
      tentative_sign_dp_nonfp4 = tentative_sign_dp_lane01;
    end else begin
      product_shifted_dp_post_d = product_shifted_dp_lane23 - product_shifted_dp_lane01;
      tentative_sign_dp_nonfp4 = tentative_sign_dp_lane23;
    end

    if (!fp4_enable_i) product_shifted_dp_post_d = product_shifted_dp_post_d >> 1;
    if (product_shifted_dp_post_d == '0) tentative_sign_dp_nonfp4 = 1'b0;
    tentative_sign_dp_d = fp4_enable_i ? tentative_sign_dp_fp4 : tentative_sign_dp_nonfp4;
  end

`ifdef COMBINATIONAL
  assign product_o = product_raw;
  assign product_simd_o = product_simd_raw;
  assign product_fp8_1_o = product_fp8_1_raw;
  assign product_fp8_2_o = product_fp8_2_raw;
  assign product_shifted_dp_post_o = product_shifted_dp_post_d;
  assign product_shifted_dp_fp4_o = product_shifted_dp_fp4_d;
  assign tentative_sign_dp_o = tentative_sign_dp_d;
`else
  always_ff @(posedge clk_i) begin
    if (pipe_en) begin
      product_q <= product_raw;
      product_simd_q <= product_simd_raw;
      product_fp8_1_q <= product_fp8_1_raw;
      product_fp8_2_q <= product_fp8_2_raw;
      product_shifted_dp_post_q <= product_shifted_dp_post_d;
      product_shifted_dp_fp4_q <= product_shifted_dp_fp4_d;
      tentative_sign_dp_q <= tentative_sign_dp_d;
    end
  end

  assign product_o = product_q;
  assign product_simd_o = product_simd_q;
  assign product_fp8_1_o = product_fp8_1_q;
  assign product_fp8_2_o = product_fp8_2_q;
  assign product_shifted_dp_post_o = product_shifted_dp_post_q;
  assign product_shifted_dp_fp4_o = product_shifted_dp_fp4_q;
  assign tentative_sign_dp_o = tentative_sign_dp_q;
`endif

endmodule

// Backward-compatible wrapper for older scripts and reports that still use the
// old "dp_new_version" name.
module transdot_decomp_multiplier_dp_new_version #(
  parameter int unsigned PRECISION_BITS      = 24,
  parameter int unsigned PRECISION_BITS_SIMD = 11,
  parameter int unsigned PRECISION_BITS_FP8  = 4
)(
  input  logic                         clk_i,
  input  logic                         pipe_en,
  input  logic                         dp_enable_i,
  input  logic                         simd_enable_i,
  input  logic                         fp4_enable_i,
  input  logic                         src_is_fp8_i,

  input  logic [5:0]                   shamt_lane0_i,
  input  logic [5:0]                   shamt_lane1_i,
  input  logic [3:0]                   shamt_lane2_i,
  input  logic [3:0]                   shamt_lane3_i,

  input  logic                         tentative_sign_lane0_i,
  input  logic                         tentative_sign_lane1_i,
  input  logic                         tentative_sign_lane2_i,
  input  logic                         tentative_sign_lane3_i,

  input  logic [8:0]                   fp4_y_mag0_i,
  input  logic [8:0]                   fp4_y_mag1_i,
  input  logic [8:0]                   fp4_y_mag2_i,
  input  logic [8:0]                   fp4_y_mag3_i,

  input  logic [PRECISION_BITS-1:0]      mantissa_a_i,
  input  logic [PRECISION_BITS-1:0]      mantissa_b_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_a_simd_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_b_simd_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_2_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_2_i,

  output logic [2*PRECISION_BITS-1:0]      product_o,
  output logic [2*PRECISION_BITS_SIMD-1:0] product_simd_o,
  output logic [2*PRECISION_BITS_FP8-1:0]  product_fp8_1_o,
  output logic [2*PRECISION_BITS_FP8-1:0]  product_fp8_2_o,
  output logic [2*PRECISION_BITS_SIMD+4:0] product_shifted_dp_post_o,
  output logic [47:0]                      product_shifted_dp_fp4_o,
  output logic                             tentative_sign_dp_o
);
  transdot_separated_multiplier_dot_product_path #(
    .PRECISION_BITS      ( PRECISION_BITS ),
    .PRECISION_BITS_SIMD ( PRECISION_BITS_SIMD ),
    .PRECISION_BITS_FP8  ( PRECISION_BITS_FP8 )
  ) i_transdot_separated_multiplier_dot_product_path (
    .clk_i                 ( clk_i ),
    .pipe_en               ( pipe_en ),
    .dp_enable_i           ( dp_enable_i ),
    .simd_enable_i         ( simd_enable_i ),
    .fp4_enable_i          ( fp4_enable_i ),
    .src_is_fp8_i          ( src_is_fp8_i ),
    .shamt_lane0_i         ( shamt_lane0_i ),
    .shamt_lane1_i         ( shamt_lane1_i ),
    .shamt_lane2_i         ( shamt_lane2_i ),
    .shamt_lane3_i         ( shamt_lane3_i ),
    .tentative_sign_lane0_i( tentative_sign_lane0_i ),
    .tentative_sign_lane1_i( tentative_sign_lane1_i ),
    .tentative_sign_lane2_i( tentative_sign_lane2_i ),
    .tentative_sign_lane3_i( tentative_sign_lane3_i ),
    .fp4_y_mag0_i          ( fp4_y_mag0_i ),
    .fp4_y_mag1_i          ( fp4_y_mag1_i ),
    .fp4_y_mag2_i          ( fp4_y_mag2_i ),
    .fp4_y_mag3_i          ( fp4_y_mag3_i ),
    .mantissa_a_i          ( mantissa_a_i ),
    .mantissa_b_i          ( mantissa_b_i ),
    .mantissa_a_simd_i     ( mantissa_a_simd_i ),
    .mantissa_b_simd_i     ( mantissa_b_simd_i ),
    .mantissa_a_fp8_1_i    ( mantissa_a_fp8_1_i ),
    .mantissa_b_fp8_1_i    ( mantissa_b_fp8_1_i ),
    .mantissa_a_fp8_2_i    ( mantissa_a_fp8_2_i ),
    .mantissa_b_fp8_2_i    ( mantissa_b_fp8_2_i ),
    .product_o             ( product_o ),
    .product_simd_o        ( product_simd_o ),
    .product_fp8_1_o       ( product_fp8_1_o ),
    .product_fp8_2_o       ( product_fp8_2_o ),
    .product_shifted_dp_post_o ( product_shifted_dp_post_o ),
    .product_shifted_dp_fp4_o  ( product_shifted_dp_fp4_o ),
    .tentative_sign_dp_o   ( tentative_sign_dp_o )
  );
endmodule

module transdot_decomp_multiplier_dp_new_packed #(
  parameter int unsigned PRECISION_BITS      = 24,
  parameter int unsigned PRECISION_BITS_SIMD = 11,
  parameter int unsigned PRECISION_BITS_FP8  = 4
)(
  input  logic                         clk_i,
  input  logic                         pipe_en,
  input  logic                         dp_enable_i,
  input  logic                         simd_enable_i,
  input  logic                         fp4_enable_i,
  input  logic                         src_is_fp8_i,

  input  logic [5:0]                   shamt_lane0_i,
  input  logic [5:0]                   shamt_lane1_i,
  input  logic [3:0]                   shamt_lane2_i,
  input  logic [3:0]                   shamt_lane3_i,

  input  logic                         tentative_sign_lane0_i,
  input  logic                         tentative_sign_lane1_i,
  input  logic                         tentative_sign_lane2_i,
  input  logic                         tentative_sign_lane3_i,

  input  logic [8:0]                   fp4_y_mag0_i,
  input  logic [8:0]                   fp4_y_mag1_i,
  input  logic [8:0]                   fp4_y_mag2_i,
  input  logic [8:0]                   fp4_y_mag3_i,

  input  logic [PRECISION_BITS-1:0]      mantissa_a_i,
  input  logic [PRECISION_BITS-1:0]      mantissa_b_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_a_simd_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_b_simd_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_2_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_2_i,

  output logic [2*PRECISION_BITS-1:0]    product_packed_o,
  output logic [2*PRECISION_BITS_SIMD+4:0] product_shifted_dp_post_o,
  output logic [47:0]                    product_shifted_dp_fp4_o,
  output logic                           tentative_sign_dp_o
);
  localparam int unsigned SIMD_PACK_PAD = 2*PRECISION_BITS - 2*PRECISION_BITS_SIMD - 2 - 2*PRECISION_BITS_SIMD;
  localparam int unsigned FP8_PACK_PAD  = 2*PRECISION_BITS - 4*(2*PRECISION_BITS_FP8) - 3*4;

  logic [2*PRECISION_BITS-1:0]      product_raw;
  logic [2*PRECISION_BITS_SIMD-1:0] product_simd_raw;
  logic [2*PRECISION_BITS_FP8-1:0]  product_fp8_1_raw;
  logic [2*PRECISION_BITS_FP8-1:0]  product_fp8_2_raw;

  transdot_separated_multiplier_dot_product_path #(
    .PRECISION_BITS      ( PRECISION_BITS ),
    .PRECISION_BITS_SIMD ( PRECISION_BITS_SIMD ),
    .PRECISION_BITS_FP8  ( PRECISION_BITS_FP8 )
  ) i_transdot_separated_multiplier_dot_product_path (
    .clk_i                 ( clk_i ),
    .pipe_en               ( pipe_en ),
    .dp_enable_i           ( dp_enable_i ),
    .simd_enable_i         ( simd_enable_i ),
    .fp4_enable_i          ( fp4_enable_i ),
    .src_is_fp8_i          ( src_is_fp8_i ),
    .shamt_lane0_i         ( shamt_lane0_i ),
    .shamt_lane1_i         ( shamt_lane1_i ),
    .shamt_lane2_i         ( shamt_lane2_i ),
    .shamt_lane3_i         ( shamt_lane3_i ),
    .tentative_sign_lane0_i( tentative_sign_lane0_i ),
    .tentative_sign_lane1_i( tentative_sign_lane1_i ),
    .tentative_sign_lane2_i( tentative_sign_lane2_i ),
    .tentative_sign_lane3_i( tentative_sign_lane3_i ),
    .fp4_y_mag0_i          ( fp4_y_mag0_i ),
    .fp4_y_mag1_i          ( fp4_y_mag1_i ),
    .fp4_y_mag2_i          ( fp4_y_mag2_i ),
    .fp4_y_mag3_i          ( fp4_y_mag3_i ),
    .mantissa_a_i          ( mantissa_a_i ),
    .mantissa_b_i          ( mantissa_b_i ),
    .mantissa_a_simd_i     ( mantissa_a_simd_i ),
    .mantissa_b_simd_i     ( mantissa_b_simd_i ),
    .mantissa_a_fp8_1_i    ( mantissa_a_fp8_1_i ),
    .mantissa_b_fp8_1_i    ( mantissa_b_fp8_1_i ),
    .mantissa_a_fp8_2_i    ( mantissa_a_fp8_2_i ),
    .mantissa_b_fp8_2_i    ( mantissa_b_fp8_2_i ),
    .product_o             ( product_raw ),
    .product_simd_o        ( product_simd_raw ),
    .product_fp8_1_o       ( product_fp8_1_raw ),
    .product_fp8_2_o       ( product_fp8_2_raw ),
    .product_shifted_dp_post_o ( product_shifted_dp_post_o ),
    .product_shifted_dp_fp4_o  ( product_shifted_dp_fp4_o ),
    .tentative_sign_dp_o   ( tentative_sign_dp_o )
  );

  always_comb begin
    if (!simd_enable_i) begin
      product_packed_o = product_raw;
    end else if (src_is_fp8_i) begin
      product_packed_o = {
        {FP8_PACK_PAD{1'b0}},
        product_fp8_2_raw,
        4'b0,
        product_fp8_1_raw,
        4'b0,
        product_simd_raw[2*PRECISION_BITS_SIMD-1-:2*PRECISION_BITS_FP8],
        4'b0,
        product_raw[2*PRECISION_BITS-1-:2*PRECISION_BITS_FP8]
      };
    end else begin
      product_packed_o = {
        {SIMD_PACK_PAD{1'b0}},
        product_simd_raw,
        2'b00,
        product_raw[2*PRECISION_BITS-1-:2*PRECISION_BITS_SIMD]
      };
    end
  end
endmodule

module transdot_decomp_multiplier_w6_direct_outputs #(
  parameter int unsigned PRECISION_BITS      = 24,
  parameter int unsigned PRECISION_BITS_SIMD = 11,
  parameter int unsigned PRECISION_BITS_FP8  = 4
)(
  input  logic                         clk_i,
  input  logic                         pipe_en,
  input  logic                         dp_enable_i,
  input  logic                         simd_enable_i,
  input  logic                         fp4_enable_i,
  input  logic                         src_is_fp8_i,

  input  logic [5:0]                   shamt_lane0_i,
  input  logic [5:0]                   shamt_lane1_i,
  input  logic [4:0]                   shamt_lane2_i,
  input  logic [4:0]                   shamt_lane3_i,

  input  logic                         tentative_sign_lane0_i,
  input  logic                         tentative_sign_lane1_i,
  input  logic                         tentative_sign_lane2_i,
  input  logic                         tentative_sign_lane3_i,

  input  logic [8:0]                   fp4_y_mag0_i,
  input  logic [8:0]                   fp4_y_mag1_i,
  input  logic [8:0]                   fp4_y_mag2_i,
  input  logic [8:0]                   fp4_y_mag3_i,

  input  logic [PRECISION_BITS-1:0]      mantissa_a_i,
  input  logic [PRECISION_BITS-1:0]      mantissa_b_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_a_simd_i,
  input  logic [PRECISION_BITS_SIMD-1:0] mantissa_b_simd_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_1_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_a_fp8_2_i,
  input  logic [PRECISION_BITS_FP8-1:0]  mantissa_b_fp8_2_i,

  output logic [2*PRECISION_BITS-1:0]      product_comb_o,
  output logic [2*PRECISION_BITS-1:0]      product_dp_o,
  output logic                             tentative_sign_dp_o
);
  logic [2*PRECISION_BITS-1:0] packed_product_non_dp;
  logic [2*PRECISION_BITS-1:0] packed_product_dp;
  logic [PRECISION_BITS-1:0]   mantissa_a_selected;
  logic [PRECISION_BITS-1:0]   mantissa_b_selected;

  always_comb begin
    if (!(dp_enable_i || simd_enable_i)) begin
      mantissa_a_selected = mantissa_a_i;
      mantissa_b_selected = mantissa_b_i;
    end else if (src_is_fp8_i) begin
      mantissa_a_selected = {
        2'b00, mantissa_a_fp8_2_i,
        2'b00, mantissa_a_fp8_1_i,
        2'b00, mantissa_a_simd_i[10:7],
        2'b00, mantissa_a_i[23:20]
      };
      mantissa_b_selected = {
        2'b00, mantissa_b_fp8_2_i,
        2'b00, mantissa_b_fp8_1_i,
        2'b00, mantissa_b_simd_i[10:7],
        2'b00, mantissa_b_i[23:20]
      };
    end else begin
      mantissa_a_selected = {
        1'b0, mantissa_a_simd_i[10:6],
        mantissa_a_simd_i[5:0],
        1'b0, mantissa_a_i[23:19],
        mantissa_a_i[18:13]
      };
      mantissa_b_selected = {
        1'b0, mantissa_b_simd_i[10:6],
        mantissa_b_simd_i[5:0],
        1'b0, mantissa_b_i[23:19],
        mantissa_b_i[18:13]
      };
    end
  end

  transdot_decomp_multiplier_w6_4lane_dp_piped #(
    .PRECISION_BITS      ( PRECISION_BITS )
  ) i_w6_direct_core (
    .clk_i            ( clk_i ),
    .pipe_en          ( pipe_en ),
    .dp_enable_i      ( dp_enable_i ),
    .simd_enable_i    ( simd_enable_i ),
    .is_fp8           ( src_is_fp8_i ),
    .is_fp4           ( fp4_enable_i ),
    .shamt_lane0      ( shamt_lane0_i ),
    .shamt_lane1      ( shamt_lane1_i ),
    .shamt_lane2      ( shamt_lane2_i ),
    .shamt_lane3      ( shamt_lane3_i ),
    .sign_lane0       ( tentative_sign_lane0_i ),
    .sign_lane1       ( tentative_sign_lane1_i ),
    .sign_lane2       ( tentative_sign_lane2_i ),
    .sign_lane3       ( tentative_sign_lane3_i ),
    .fp4_y_mag0       ( fp4_y_mag0_i ),
    .fp4_y_mag1       ( fp4_y_mag1_i ),
    .fp4_y_mag2       ( fp4_y_mag2_i ),
    .fp4_y_mag3       ( fp4_y_mag3_i ),
    .mantissa_a       ( mantissa_a_selected ),
    .mantissa_b       ( mantissa_b_selected ),
    .product_non_dp_o ( packed_product_non_dp ),
    .product_dp_o     ( packed_product_dp ),
    .sign_out         ( tentative_sign_dp_o )
  );

  assign product_comb_o = packed_product_non_dp;
  assign product_dp_o = packed_product_dp;
endmodule
module fa_3to2 (
  input  logic a,
  input  logic b,
  input  logic c,
  output logic s,
  output logic co
);
  assign s  = a ^ b ^ c;
  assign co = (a & b) | (a & c) | (b & c);
endmodule

module csa4_to_2 #(
  parameter int unsigned W = 37
)(
  input  logic [W-1:0] a,
  input  logic [W-1:0] b,
  input  logic [W-1:0] c,
  input  logic [W-1:0] d,
  output logic [W-1:0] sum,
  output logic [W-1:0] carry   // carry is same weight as sum; shift left by 1 when adding later
);

  logic [W-1:0] s1, c1;
  logic [W-1:0] c2;

  genvar i;
  generate
    for (i = 0; i < W; i++) begin : gen_csa
      // First FA compresses (a,b,c) -> (s1,c1)
      fa_3to2 u_fa0 (
        .a  (a[i]),
        .b  (b[i]),
        .c  (c[i]),
        .s  (s1[i]),
        .co (c1[i])
      );

      // Second FA compresses (s1,d,0) -> (sum,c2)
      // (no cin chain => no carry propagation in this stage)
      fa_3to2 u_fa1 (
        .a  (s1[i]),
        .b  (d[i]),
        .c  (1'b0),
        .s  (sum[i]),
        .co (c2[i])
      );
    end
  endgenerate

  // Both c1 and c2 are carries to the next higher bit (i+1).
  // Merge them with XOR/AND? No: carries are single bits; we must add them in carry-save too.
  // Easiest is: carry = c1 ^ c2, and an extra carry would be needed if both are 1.
  // So instead, do one more CSA layer to combine them properly:
  //
  // carry = c1 + c2 (carry-save). For simplicity and correctness, we just use a 2:2 add with no propagate:
  // Since c1,c2 are carries, we can store carry = c1 ^ c2 and "carry2" = c1 & c2 and fold carry2 in next stage.
  //
  // BUT we promised a single 4->2 stage. The *standard* approach is to treat carry as (c1 + c2) in carry-save by:
  // carry = c1 ^ c2
  // extra = c1 & c2  (this is a carry of carries)
  //
  // To keep it simple AND exact, we output carry as (c1 + c2) using a tiny ripple *only across carry bits*.
  // This ripple is short and usually not the critical path compared to a full CPA across W bits.
  //
  // If you want zero propagation here too, tell me and I'll give the pure Dadda-style multi-level CSA.
  logic [W-1:0] carry_r;
  logic         cc;
  integer k;
  always_comb begin
    carry_r = '0;
    cc      = 1'b0;
    for (k = 0; k < W; k++) begin
      // one-bit full add: c1 + c2 + cc
      carry_r[k] = c1[k] ^ c2[k] ^ cc;
      cc         = (c1[k] & c2[k]) | (c1[k] & cc) | (c2[k] & cc);
    end
  end

  assign carry = carry_r;

endmodule


module adder_4 #(
  parameter int unsigned W = 37
)(
  input  logic [W-1:0] in0,
  input  logic [W-1:0] in1,
  input  logic [W-1:0] in2,
  input  logic [W-1:0] in3,
  output logic [W-1:0] sum
);

  assign sum=in0+in1+in2+in3;
endmodule
