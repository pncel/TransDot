module transdot_decomp_adder_w4 #(
  parameter int unsigned QUARTER_N = 38,
  localparam int unsigned N = 4*QUARTER_N
)(
  input  logic                 simd_enable_i,
  input  logic                 is_fp8,

  input  logic                 lane3_cin,
  input  logic                 lane2_cin,
  input  logic                 lane1_cin,
  input  logic                 lane0_cin,
  input  logic [N-1:0]         a_i,
  input  logic [N-1:0]         b_i,

  output logic [N+1:0]         sum_o
);
  assign sum_o = ({1'b0,a_i} + {1'b0,b_i} + lane0_cin + ((lane1_cin&simd_enable_i&is_fp8)<<QUARTER_N) + ((lane2_cin&simd_enable_i)<<QUARTER_N*2) + ((lane3_cin&simd_enable_i&is_fp8)<<QUARTER_N*3));
endmodule
