// SPDX-License-Identifier: SHL-0.51
module transdot_fpu_top#(
    // FPU configuration
    parameter fpnew_pkg::fpu_features_t       Features       = fpnew_pkg::transdot_features_bf16_fp8_fp4_fp8alt,
    parameter fpnew_pkg::fpu_implementation_t Implementation = fpnew_pkg::ADDMUL_ONLY,
    // DivSqrtSel chooses among PULP, TH32, or THMULTI (see documentation and fpnew_pkg.sv for further details)
    parameter fpnew_pkg::divsqrt_unit_t       DivSqrtSel     = fpnew_pkg::THMULTI,
    parameter type                            TagType        = logic,
    parameter int unsigned                    TrueSIMDClass  = 0,
    parameter int unsigned                    EnableSIMDMask = 0,
    // Do not change
    localparam int unsigned NumLanes     = fpnew_pkg::max_num_lanes(Features.Width, Features.FpFmtMask, Features.EnableVectors),
    localparam type         MaskType     = logic [NumLanes-1:0],
    localparam int unsigned WIDTH        = Features.Width,
    localparam int unsigned NUM_OPERANDS = 3
)
(
  input logic                               clk_i,
  input logic                               rst_ni,
  // Input signals
  input logic [NUM_OPERANDS-1:0][WIDTH-1:0] operands_i,
  input fpnew_pkg::roundmode_e              rnd_mode_i,
  input fpnew_pkg::operation_e              op_i,
  input logic                               op_mod_i,
  input fpnew_pkg::fp_format_e              src_fmt_i,
  input fpnew_pkg::fp_format_e              dst_fmt_i,
  input fpnew_pkg::int_format_e             int_fmt_i,
  input logic                               vectorial_op_i,
  input TagType                             tag_i,
  input MaskType                            simd_mask_i,
  // Input Handshake
  input  logic                              in_valid_i,
  output logic                              in_ready_o,
  input  logic                              flush_i,
  // Output signals
  output logic [WIDTH-1:0]                  result_o,
  output fpnew_pkg::status_t                status_o,
  output TagType                            tag_o,
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
  .TagType        (TagType),
  .DivSqrtSel     (DivSqrtSel),
  .TrueSIMDClass(TrueSIMDClass),
  .EnableSIMDMask(EnableSIMDMask)
) i_fpnew_top (
  .clk_i,
  .rst_ni,
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