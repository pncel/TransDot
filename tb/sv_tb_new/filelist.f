# SPDX-License-Identifier: SHL-0.51
+define+TRANSDOT_ENABLE+SIMULATION
+incdir+${FPNEW_HOME}/src/common_cells/include
+incdir+${FPNEW_HOME}/src
+incdir+${FPNEW_HOME}/src/common_cells/src

# FPnew base
${FPNEW_HOME}/src/fpnew_pkg.sv
${FPNEW_HOME}/src/fpnew_cast_multi.sv
${FPNEW_HOME}/src/fpnew_classifier.sv
${FPNEW_HOME}/src/fpnew_fma.sv
${FPNEW_HOME}/src/fpnew_noncomp.sv
${FPNEW_HOME}/src/fpnew_opgroup_block.sv
${FPNEW_HOME}/src/fpnew_opgroup_fmt_slice.sv
${FPNEW_HOME}/src/fpnew_opgroup_multifmt_slice.sv
${FPNEW_HOME}/src/fpnew_rounding.sv
${FPNEW_HOME}/src/fpnew_top.sv

# DivSqrt (T-Head E906 + C910)
${FPNEW_HOME}/src/fpnew_divsqrt_th_32.sv
${FPNEW_HOME}/src/fpnew_divsqrt_th_64_multi.sv
${FPNEW_HOME}/src/fpnew_divsqrt_multi.sv
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v
${FPNEW_HOME}/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ctrl.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_double.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ff1.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_pack.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_prepare.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_round.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_scalar_dp.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_bound_table.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_with_sqrt.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt.v
${FPNEW_HOME}/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_top.v

# TransDot FMA and decomposed datapaths
${FPNEW_HOME}/src/transdot_fp4_fp8_fp16_fp32_fma.sv
${FPNEW_HOME}/src/transdot_fp4_dp.sv
${FPNEW_HOME}/src/transdot_decomp_multiplier.sv
${FPNEW_HOME}/src/transdot_decomp_adder.sv
${FPNEW_HOME}/src/transdot_decomp_shifter.sv
${FPNEW_HOME}/src/transdot_decomp_exponent_datapath_fp8.sv
${FPNEW_HOME}/src/transdot_decomp_addend_datapath.sv
${FPNEW_HOME}/src/transdot_decomp_normalize_datapath.sv

# Common cells
${FPNEW_HOME}/src/common_cells/src/cf_math_pkg.sv
${FPNEW_HOME}/src/common_cells/src/ecc_pkg.sv
${FPNEW_HOME}/src/common_cells/src/lzc.sv
${FPNEW_HOME}/src/common_cells/src/rr_arb_tree.sv

# Top wrapper and testbench
${FPNEW_HOME}/instances/transdot_fpu_top.sv
${FPNEW_HOME}/tb/sv_tb_new/tb_fpnew.sv
