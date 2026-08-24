// SPDX-License-Identifier: SHL-0.51
module transdot_fpu_top#(
    parameter int unsigned EnableSIMDMask = 1,
    localparam fpnew_pkg::fpu_features_t       Features       = fpnew_pkg::transdot_features,
    localparam fpnew_pkg::fpu_implementation_t Implementation = fpnew_pkg::ADDMUL_ONLY_PIPE3,
    localparam fpnew_pkg::divsqrt_unit_t       DivSqrtSel     = fpnew_pkg::THMULTI,
    localparam int unsigned                    TrueSIMDClass  = 0,
    localparam int unsigned                    NumLanes       = fpnew_pkg::max_num_lanes(Features.Width, Features.FpFmtMask, Features.EnableVectors),
    localparam int unsigned                    WIDTH          = Features.Width,
    localparam int unsigned                    NUM_OPERANDS   = 3
)
(
  input logic                               clk_i,
  input logic                               rst_ni,
  // Input signals
  // NVFP4 block-scale significand product, forwarded to the FP4 lanes.
  // 8'd64 == 1.0; tying it to 64 removes the scaling logic entirely.
  input logic [7:0]                               fp4_scale_mu_i = 8'd64,
  input logic [NUM_OPERANDS-1:0][WIDTH-1:0] operands_i,
  input fpnew_pkg::roundmode_e              rnd_mode_i,
  input fpnew_pkg::operation_e              op_i,
  input logic                               op_mod_i,
  input fpnew_pkg::fp_format_e              src_fmt_i,
  input fpnew_pkg::fp_format_e              dst_fmt_i,
  input fpnew_pkg::int_format_e             int_fmt_i,
  input logic                               vectorial_op_i,
  input logic                               tag_i,
  input logic [NumLanes-1:0]                simd_mask_i,
  // Input Handshake
  input  logic                              in_valid_i,
  output logic                              in_ready_o,
  input  logic                              flush_i,
  // Output signals
  output logic [WIDTH-1:0]                  result_o,
  output fpnew_pkg::status_t                status_o,
  output logic                              tag_o,
  // Output handshake
  output logic                              out_valid_o,
  input  logic                              out_ready_i,
  // Indication of valid data in flight
  output logic                              busy_o
);
// FPU instance
fpnew_top #(
  .Features       (Features),
  .Implementation (Implementation),
  .TagType        (logic),
  .DivSqrtSel     (DivSqrtSel),
  .TrueSIMDClass(TrueSIMDClass),
  .EnableSIMDMask(EnableSIMDMask)
) i_fpnew_top (
  .clk_i,
  .rst_ni,
  .fp4_scale_mu_i,
  .operands_i,
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
  .status_o,
  .tag_o,
  .out_valid_o,
  .out_ready_i,
  .busy_o
);
endmodule
