module transdot_decomp_shifter_w4 #(
  parameter int unsigned QUARTER_N = 25,
  localparam int unsigned HALF_N   = 2*QUARTER_N,
  localparam int unsigned N        = 2*HALF_N,

  localparam int unsigned SHAMT_N         = (N <= 1) ? 1 : $clog2(N),
  localparam int unsigned HALF_SHAMT_N    = (HALF_N <= 1) ? 1 : $clog2(HALF_N),
  localparam int unsigned QUARTER_SHAMT_N = (QUARTER_N <= 1) ? 1 : $clog2(QUARTER_N)
)(
  // 00: 1x N shifter
  // 01: 2x HALF_N shifters
  // 10: 4x QUARTER_N shifters
  // 11: invalid
  input  logic [1:0]                 mode_i,

  input  logic [N-1:0]               data_i,

  input  logic [QUARTER_SHAMT_N-1:0]   shamt0_i,
  input  logic [HALF_SHAMT_N-1:0]      shamt1_i,
  input  logic [QUARTER_SHAMT_N-1:0]   shamt2_i,
  input  logic [SHAMT_N-1:0]           shamt3_i,

  output logic [N-1:0]               data_o
);

  // --------------------------------------------------------------------------
  // Pad to power-of-two width (clean barrel stages)
  // --------------------------------------------------------------------------
  localparam int unsigned N_POW2          = 1 << SHAMT_N;     // >= N
  localparam int unsigned HALF_N_POW2     = N_POW2 >> 1;      // = N_POW2/2
  localparam int unsigned QUARTER_N_POW2  = N_POW2 >> 2;      // = N_POW2/4 (assumes SHAMT_N>=2)

  logic [N_POW2-1:0] data_i_ext;
  assign data_i_ext = { {(N_POW2-N){1'b0}}, data_i };

  logic [N_POW2-1:0] stage [0:SHAMT_N];
  assign stage[0] = data_i_ext;

  // --------------------------------------------------------------------------
  // Build per-segment shift select vectors (all widened to SHAMT_N)
  //   seg0 = lowest bits, seg3 = highest bits (for quarter mode)
  // --------------------------------------------------------------------------
  logic [SHAMT_N-1:0] sel_seg0, sel_seg1, sel_seg2, sel_seg3;

  always_comb begin
    // defaults
    sel_seg0 = '0;
    sel_seg1 = '0;
    sel_seg2 = '0;
    sel_seg3 = '0;

    unique case (mode_i)
      2'b00: begin
        // whole vector uses shamt0_i
        sel_seg0 = shamt3_i;
        sel_seg1 = shamt3_i;
        sel_seg2 = shamt3_i;
        sel_seg3 = shamt3_i;
      end

      2'b01: begin
        // 2 halves: force MSB select to 0 so shift < HALF_N_POW2
        sel_seg0 = {1'b0, shamt3_i[HALF_SHAMT_N-1:0]};                          // low half
        sel_seg1 = {1'b0, shamt1_i};         // high half
        // unused in this mode
        sel_seg2 = sel_seg1;
        sel_seg3 = sel_seg1;
      end

      2'b10: begin
        // 4 quarters: force top 2 select bits to 0 so shift < QUARTER_N_POW2
        sel_seg0 = {2'b0, shamt3_i[QUARTER_SHAMT_N-1:0]};      // quarter0
        sel_seg1 = {2'b0, shamt2_i};      // quarter1
        sel_seg2 = {2'b0, shamt1_i[QUARTER_SHAMT_N-1:0]};                           // quarter2
        sel_seg3 = {2'b0, shamt0_i};                           // quarter3
      end

      default: begin
        // invalid -> keep zeros
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // Barrel stages
  // --------------------------------------------------------------------------
  genvar k, i;
  generate
    for (k = 0; k < SHAMT_N; k++) begin : gen_stage
      localparam int unsigned SHIFT = (1 << k);

      for (i = 0; i < N_POW2; i++) begin : gen_bit
        // If this is padding beyond real N, keep it 0 always.
        if (i >= N) begin : gen_pad
          assign stage[k+1][i] = 1'b0;
        end else begin : gen_real

          // Quarter index based on REAL QUARTER_N (25), not QUARTER_N_POW2 (32)
          localparam int unsigned QIDX_REAL = i / QUARTER_N;

          // Position within the REAL quarter (constant because i is genvar)
          localparam int unsigned POS_IN_Q_REAL = i - (QIDX_REAL * QUARTER_N);

          // Select bit per mode/segment (same as before, but use QIDX_REAL for quarter mode)
          wire shamt_bit =
            (mode_i == 2'b00) ? shamt3_i[k] :
            (mode_i == 2'b01) ? ((i < HALF_N) ? sel_seg1[k] : sel_seg0[k]) :
            (mode_i == 2'b10) ? ((QIDX_REAL == 0) ? sel_seg3[k] :
                                (QIDX_REAL == 1) ? sel_seg2[k] :
                                (QIDX_REAL == 2) ? sel_seg1[k] :
                                                   sel_seg0[k]) :
                                1'b0;

          // Safe shifted_from (still against N_POW2)
          wire shifted_from;
          if ((i + SHIFT) < N_POW2) begin : gen_in_range
            assign shifted_from = stage[k][i + SHIFT];
          end else begin : gen_oob
            assign shifted_from = 1'b0;
          end

          // Cross-quarter blocking using REAL 25-bit quarter boundary
          wire crosses_quarter_real = (mode_i == 2'b10) && ((POS_IN_Q_REAL + SHIFT) >= QUARTER_N);

          // Cross-half blocking using REAL HALF_N boundary (50)
          localparam int unsigned POS_IN_H_REAL = i - ((i / HALF_N) * HALF_N);
          wire crosses_half_real = (mode_i == 2'b01) && ((POS_IN_H_REAL + SHIFT) >= HALF_N);

          wire shifted_bit = (crosses_half_real || crosses_quarter_real) ? 1'b0 : shifted_from;

          assign stage[k+1][i] = shamt_bit ? shifted_bit : stage[k][i];

        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Output: low N bits (original width); invalid mode -> 0
  // --------------------------------------------------------------------------
  always_comb begin
      data_o = stage[SHAMT_N][N-1:0];
  end

endmodule

module transdot_decomp_shifter_left_w4 #(
  parameter int unsigned QUARTER_N = 25,
  localparam int unsigned HALF_N   = 2*QUARTER_N,
  localparam int unsigned N        = 2*HALF_N,

  localparam int unsigned SHAMT_N         = (N <= 1) ? 1 : $clog2(N),
  localparam int unsigned HALF_SHAMT_N    = (HALF_N <= 1) ? 1 : $clog2(HALF_N),
  localparam int unsigned QUARTER_SHAMT_N = (QUARTER_N <= 1) ? 1 : $clog2(QUARTER_N)
)(
  // 00: 1x N shifter
  // 01: 2x HALF_N shifters
  // 10: 4x QUARTER_N shifters
  // 11: invalid
  input  logic [1:0]                  mode_i,

  input  logic [N-1:0]                data_i,

  input  logic [QUARTER_SHAMT_N-1:0]  shamt0_i,
  input  logic [HALF_SHAMT_N-1:0]     shamt1_i,
  input  logic [QUARTER_SHAMT_N-1:0]  shamt2_i,
  input  logic [SHAMT_N-1:0]          shamt3_i,

  output logic [N-1:0]                data_o
);

  // --------------------------------------------------------------------------
  // Pad to power-of-two width (clean barrel stages)
  // --------------------------------------------------------------------------
  localparam int unsigned N_POW2          = 1 << SHAMT_N;     // >= N
  localparam int unsigned HALF_N_POW2     = N_POW2 >> 1;      // = N_POW2/2
  localparam int unsigned QUARTER_N_POW2  = N_POW2 >> 2;      // = N_POW2/4 (assumes SHAMT_N>=2)

  logic [N_POW2-1:0] data_i_ext;
  assign data_i_ext = { {(N_POW2-N){1'b0}}, data_i };

  logic [N_POW2-1:0] stage [0:SHAMT_N];
  assign stage[0] = data_i_ext;

  // --------------------------------------------------------------------------
  // Build per-segment shift select vectors (all widened to SHAMT_N)
  //   seg0 = lowest bits, seg3 = highest bits (for quarter mode)
  // --------------------------------------------------------------------------
  logic [SHAMT_N-1:0] sel_seg0, sel_seg1, sel_seg2, sel_seg3;

  always_comb begin
    sel_seg0 = '0;
    sel_seg1 = '0;
    sel_seg2 = '0;
    sel_seg3 = '0;

    unique case (mode_i)
      2'b00: begin
        // whole vector uses shamt3_i
        sel_seg0 = shamt3_i;
        sel_seg1 = shamt3_i;
        sel_seg2 = shamt3_i;
        sel_seg3 = shamt3_i;
      end

      2'b01: begin
        // 2 halves: force MSB select to 0 so shift < HALF_N_POW2
        sel_seg0 = {1'b0, shamt3_i[HALF_SHAMT_N-1:0]}; // low half
        sel_seg1 = {1'b0, shamt1_i};                   // high half
        sel_seg2 = sel_seg1;
        sel_seg3 = sel_seg1;
      end

      2'b10: begin
        // 4 quarters: force top 2 select bits to 0 so shift < QUARTER_N_POW2
        sel_seg0 = {2'b0, shamt3_i[QUARTER_SHAMT_N-1:0]}; // quarter0
        sel_seg1 = {2'b0, shamt2_i};                      // quarter1
        sel_seg2 = {2'b0, shamt1_i[QUARTER_SHAMT_N-1:0]};  // quarter2
        sel_seg3 = {2'b0, shamt0_i};                      // quarter3
      end

      default: begin
        // invalid -> keep zeros
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // Barrel stages (LEFT SHIFT)
  // --------------------------------------------------------------------------
  genvar k, i;
  generate
    for (k = 0; k < SHAMT_N; k++) begin : gen_stage
      localparam int unsigned SHIFT = (1 << k);

      for (i = 0; i < N_POW2; i++) begin : gen_bit
        // If this is padding beyond real N, keep it 0 always.
        if (i >= N) begin : gen_pad
          assign stage[k+1][i] = 1'b0;
        end else begin : gen_real

          // Quarter index based on REAL QUARTER_N (25), not QUARTER_N_POW2 (32)
          localparam int unsigned QIDX_REAL = i / QUARTER_N;
          localparam int unsigned POS_IN_Q_REAL = i - (QIDX_REAL * QUARTER_N);

          // Select bit per mode/segment
          wire shamt_bit =
            (mode_i == 2'b00) ? shamt3_i[k] :
            (mode_i == 2'b01) ? ((i < HALF_N) ? sel_seg1[k] : sel_seg0[k]) :
            (mode_i == 2'b10) ? ((QIDX_REAL == 0) ? sel_seg3[k] :
                                (QIDX_REAL == 1) ? sel_seg2[k] :
                                (QIDX_REAL == 2) ? sel_seg1[k] :
                                                   sel_seg0[k]) :
                                1'b0;

          // LEFT shift source: i - SHIFT
          wire shifted_from;
          if (i >= SHIFT) begin : gen_in_range
            assign shifted_from = stage[k][i - SHIFT];
          end else begin : gen_oob
            assign shifted_from = 1'b0;
          end

          // Cross-quarter blocking (LEFT): would borrow from previous quarter if POS < SHIFT
          wire crosses_quarter_real =
            (mode_i == 2'b10) && (POS_IN_Q_REAL < SHIFT);

          // Cross-half blocking (LEFT): would borrow from previous half if POS < SHIFT
          localparam int unsigned POS_IN_H_REAL = i - ((i / HALF_N) * HALF_N);
          wire crosses_half_real =
            (mode_i == 2'b01) && (POS_IN_H_REAL < SHIFT);

          wire shifted_bit =
            (crosses_half_real || crosses_quarter_real) ? 1'b0 : shifted_from;

          assign stage[k+1][i] = shamt_bit ? shifted_bit : stage[k][i];

        end
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Output: low N bits (original width); invalid mode -> 0 (same behavior as before)
  // --------------------------------------------------------------------------
  always_comb begin
    data_o = stage[SHAMT_N][N-1:0];
  end

endmodule
