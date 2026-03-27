// tb_transdot_decomp_shifter_w4.sv
`timescale 1ns/1ps

module tb_transdot_decomp_shifter_w4;

  localparam int unsigned QUARTER_N = 25;
  localparam int unsigned HALF_N    = 2*QUARTER_N; // 50
  localparam int unsigned N         = 2*HALF_N;    // 100

  localparam int unsigned SHAMT_N         = (N <= 1) ? 1 : $clog2(N);
  localparam int unsigned HALF_SHAMT_N    = (HALF_N <= 1) ? 1 : $clog2(HALF_N);
  localparam int unsigned QUARTER_SHAMT_N = (QUARTER_N <= 1) ? 1 : $clog2(QUARTER_N);

  logic [1:0]                 mode_i;
  logic [N-1:0]               data_i;
  logic [SHAMT_N-1:0]         shamt0_i;
  logic [HALF_SHAMT_N-1:0]    shamt1_i;
  logic [QUARTER_SHAMT_N-1:0] shamt2_i;
  logic [QUARTER_SHAMT_N-1:0] shamt3_i;
  logic [N-1:0]               data_o;

  transdot_decomp_shifter_w4 #(
    .QUARTER_N(QUARTER_N)
  ) dut (
    .mode_i   (mode_i),
    .data_i   (data_i),
    .shamt0_i (shamt0_i),
    .shamt1_i (shamt1_i),
    .shamt2_i (shamt2_i),
    .shamt3_i (shamt3_i),
    .data_o   (data_o)
  );

  // ----------------------------
  // Reference model
  // ----------------------------
  function automatic int unsigned get_shift_for_bit(
    input logic [1:0] mode,
    input int unsigned bit_idx,
    input logic [SHAMT_N-1:0]         s0,
    input logic [HALF_SHAMT_N-1:0]    s1,
    input logic [QUARTER_SHAMT_N-1:0] s2,
    input logic [QUARTER_SHAMT_N-1:0] s3
  );
    int unsigned qid;
    begin
      unique case (mode)
        2'b00: get_shift_for_bit = int'(s0);

        2'b01: begin
          if (bit_idx < HALF_N) get_shift_for_bit = int'(s1);
          else                  get_shift_for_bit = int'(s0[HALF_SHAMT_N-1:0]);
        end

        2'b10: begin
          qid = bit_idx / QUARTER_N;
          unique case (qid)
            0: get_shift_for_bit = int'(s0[QUARTER_SHAMT_N-1:0]);
            1: get_shift_for_bit = int'(s1[QUARTER_SHAMT_N-1:0]);
            2: get_shift_for_bit = int'(s2);
            default: get_shift_for_bit = int'(s3);
          endcase
        end

        default: get_shift_for_bit = 0;
      endcase
    end
  endfunction

  function automatic int unsigned seg_end_for_bit(input logic [1:0] mode, input int unsigned bit_idx);
    int unsigned qid;
    begin
      unique case (mode)
        2'b00: seg_end_for_bit = N;

        2'b01: seg_end_for_bit = (bit_idx < HALF_N) ? HALF_N : N;

        2'b10: begin
          qid = bit_idx / QUARTER_N;
          seg_end_for_bit = (qid+1) * QUARTER_N;
        end

        default: seg_end_for_bit = N;
      endcase
    end
  endfunction

  function automatic logic [N-1:0] ref_model(
    input logic [1:0] mode,
    input logic [N-1:0] d,
    input logic [SHAMT_N-1:0]         s0,
    input logic [HALF_SHAMT_N-1:0]    s1,
    input logic [QUARTER_SHAMT_N-1:0] s2,
    input logic [QUARTER_SHAMT_N-1:0] s3
  );
    logic [N-1:0] out;
    int unsigned b;
    int unsigned sh;
    int unsigned seg_end;
    begin
      out = '0;

      if (mode == 2'b11) begin
        ref_model = '0;
        return;
      end

      for (b = 0; b < N; b++) begin
        sh      = get_shift_for_bit(mode, b, s0, s1, s2, s3);
        seg_end = seg_end_for_bit(mode, b);

        if ((b + sh) < seg_end)
          out[b] = d[b + sh];
        else
          out[b] = 1'b0;
      end

      ref_model = out;
    end
  endfunction

  // ----------------------------
  // Randomize wide vectors safely (no variable part-select widths)
  // ----------------------------
  task automatic rand_vec(output logic [N-1:0] v);
    int unsigned i;
    begin
      v = '0;
      for (i = 0; i < N; i++) begin
        v[i] = $urandom_range(0, 1);
      end
    end
  endtask

  task automatic run_one(input logic [1:0] mode);
    logic [N-1:0] exp;
    begin
      mode_i = mode;

      rand_vec(data_i);

      shamt0_i = $urandom();
      shamt1_i = $urandom();
      shamt2_i = $urandom();
      shamt3_i = $urandom();

      #1;

      exp = ref_model(mode_i, data_i, shamt0_i, shamt1_i, shamt2_i, shamt3_i);

      if (data_o !== exp) begin
        $display("MISMATCH!");
        $display("  mode      = %b", mode_i);
        $display("  data_i    = 0x%0h", data_i);
        $display("  shamt0_i  = %0d (0x%0h)", int'(shamt0_i), shamt0_i);
        $display("  shamt1_i  = %0d (0x%0h)", int'(shamt1_i), shamt1_i);
        $display("  shamt2_i  = %0d (0x%0h)", int'(shamt2_i), shamt2_i);
        $display("  shamt3_i  = %0d (0x%0h)", int'(shamt3_i), shamt3_i);
        $display("  dut data_o= 0x%0h", data_o);
        $display("  exp       = 0x%0h", exp);

        for (int b = 0; b < N; b++) begin
          if (data_o[b] !== exp[b]) begin
            $display("  First diff at bit %0d: dut=%b exp=%b", b, data_o[b], exp[b]);
            break;
          end
        end

        $fatal(1);
      end
    end
  endtask

  task automatic directed_tests;
    logic [N-1:0] exp;
    begin
      // Fill each 25-bit quarter with distinct pattern
      data_i = '0;
      for (int q = 0; q < 4; q++) begin
        for (int b = 0; b < QUARTER_N; b++) begin
          data_i[q*QUARTER_N + b] = ((b % 2) ^ (q % 2));
        end
      end

      // Quarter mode: different shifts per quarter
      mode_i   = 2'b10;

      shamt0_i = '0;
      shamt0_i[QUARTER_SHAMT_N-1:0] = QUARTER_SHAMT_N'(5);   // q0 shift 5

      shamt1_i = '0;
      shamt1_i[QUARTER_SHAMT_N-1:0] = QUARTER_SHAMT_N'(24);  // q1 shift 24 (edge)

      shamt2_i = QUARTER_SHAMT_N'(3);                        // q2 shift 3

      shamt3_i = QUARTER_SHAMT_N'(31);                       // q3 shift "big" (likely >24)

      #1;
      exp = ref_model(mode_i, data_i, shamt0_i, shamt1_i, shamt2_i, shamt3_i);
      if (data_o !== exp) begin
        $display("DIRECTED MISMATCH (quarter mode)!");
        $display("dut  = 0x%0h", data_o);
        $display("exp  = 0x%0h", exp);
        $fatal(1);
      end

      // Half mode: shift low half big, high half 0
      mode_i   = 2'b01;
      shamt1_i = HALF_SHAMT_N'(HALF_N-1);  // 49
      shamt0_i = '0;
      shamt2_i = '0;
      shamt3_i = '0;

      #1;
      exp = ref_model(mode_i, data_i, shamt0_i, shamt1_i, shamt2_i, shamt3_i);
      if (data_o !== exp) begin
        $display("DIRECTED MISMATCH (half mode)!");
        $fatal(1);
      end

    end
  endtask

  initial begin
    $display("TB start: QUARTER_N=%0d HALF_N=%0d N=%0d (N is %s power-of-two)",
             QUARTER_N, HALF_N, N, ((N & (N-1))==0) ? "a" : "NOT a");

    directed_tests();

    for (int t = 0; t < 20; t++) begin
      run_one(2'b00);
      run_one(2'b01);
      run_one(2'b10);
      //run_one(2'b11);
    end

    $display("All tests PASSED.");
    $finish;
  end

endmodule
