`timescale 1ns/1ps

module tb_transdot_decomp_shifter;

  // ----------------------------
  // Parameters (match DUT)
  // ----------------------------
  localparam int unsigned Half_N = 32;
  localparam int unsigned N      = 2*Half_N;
  localparam int unsigned SHAMT_N = (N <= 1) ? 1 : $clog2(N);
  localparam int unsigned HALF_SHAMT_N = (Half_N <= 1) ? 1 : $clog2(Half_N);

  // ----------------------------
  // DUT signals
  // ----------------------------
  logic                    dp_enable_i;
  logic [N-1:0]            data_i;
  logic [SHAMT_N-1:0]      shamt0_i;
  logic [HALF_SHAMT_N-1:0] shamt1_i;
  logic [N-1:0]            data_o;

  // ----------------------------
  // Instantiate DUT
  // ----------------------------
  transdot_decomp_shifter #(
    .Half_N(Half_N)
  ) dut (
    .dp_enable_i(dp_enable_i),
    .data_i     (data_i),
    .shamt0_i   (shamt0_i),
    .shamt1_i   (shamt1_i),
    .data_o     (data_o)
  );

  // ----------------------------
  // Golden model function
  // ----------------------------
  function automatic logic [N-1:0] golden(
    input logic                    dp,
    input logic [N-1:0]            din,
    input logic [SHAMT_N-1:0]      s0,
    input logic [HALF_SHAMT_N-1:0] s1
  );
    logic [N-1:0] y;
    logic [Half_N-1:0] lo, hi;
    int unsigned s0_full;
    int unsigned s0_lo;
    int unsigned s1_hi;
    begin
      y = '0;
      lo = din[Half_N-1:0];
      hi = din[N-1:Half_N];

      s0_full = s0; // 0..(2^SHAMT_N-1)
      s0_lo   = s0[HALF_SHAMT_N-1:0]; // low-half shift amount in dp mode
      s1_hi   = s1;

      if (!dp) begin
        // FULL mode: logical right shift of entire N-bit word.
        // If s0_full >= N, output should be zero (logical shift).
        if (s0_full >= N)
          y = '0;
        else
          y = (din >> s0_full);
      end else begin
        // DP mode: independent logical right shifts per half, no cross-half data.
        if (s0_lo >= Half_N) y[Half_N-1:0] = '0;
        else                y[Half_N-1:0] = (lo >> s0_lo);

        if (s1_hi >= Half_N) y[N-1:Half_N] = '0;
        else                 y[N-1:Half_N] = (hi >> s1_hi);
      end

      return y;
    end
  endfunction

  // ----------------------------
  // Helper: run one check
  // ----------------------------
  task automatic run_one(
    input logic                    dp,
    input logic [N-1:0]            din,
    input logic [SHAMT_N-1:0]      s0,
    input logic [HALF_SHAMT_N-1:0] s1
  );
    logic [N-1:0] exp;
    begin
      dp_enable_i = dp;
      data_i      = din;
      shamt0_i    = s0;
      shamt1_i    = s1;
      #1; // allow combinational settle

      exp = golden(dp, din, s0, s1);

      if (data_o !== exp) begin
        $display("ERROR mismatch!");
        $display("  dp=%0d", dp);
        $display("  data_i   = 0x%0h", din);
        $display("  shamt0_i = %0d (0x%0h)", s0, s0);
        $display("  shamt1_i = %0d (0x%0h)", s1, s1);
        $display("  DUT      = 0x%0h", data_o);
        $display("  EXP      = 0x%0h", exp);
        $fatal(1);
      end
    end
  endtask

  // ----------------------------
  // Random generation
  // ----------------------------
  function automatic logic [N-1:0] rand_vec();
    logic [N-1:0] r;
    int unsigned j;
    begin
      r = '0;
      for (j = 0; j < (N+31)/32; j++) begin
        r[j*32 +: 32] = $urandom();
      end
      return r;
    end
  endfunction

  // ----------------------------
  // Test sequence
  // ----------------------------
  int unsigned NUM;

  initial begin
    $display("TB start: Half_N=%0d N=%0d", Half_N, N);

    // Directed tests: basic sanity
    run_one(1'b0, '0, 0, '0);
    run_one(1'b1, '0, 0, 0);

    run_one(1'b0, {N{1'b1}}, 0, '0);
    run_one(1'b0, {N{1'b1}}, 1, '0);
    run_one(1'b0, {N{1'b1}}, N-1, '0);

    // Check boundaries around Half_N in FULL mode
    run_one(1'b0, rand_vec(), Half_N-1, '0);
    run_one(1'b0, rand_vec(), Half_N,   '0);
    run_one(1'b0, rand_vec(), Half_N+1, '0);

    // DP mode: ensure no cross-half leakage
    // Put a single 1 at MSB of high half and see it never appears in low half for any shift.
    begin
      logic [N-1:0] onehot;
      onehot = '0;
      onehot[N-1] = 1'b1;
      for (int s = 0; s < Half_N; s++) begin
        run_one(1'b1, onehot, s[SHAMT_N-1:0], s[HALF_SHAMT_N-1:0]);
      end
    end

    // Exhaustive-ish small sweep on shifts for a few patterns
    begin
      logic [N-1:0] pat0, pat1;
      pat0 = { {Half_N{1'b0}}, {Half_N{1'b1}} }; // low=all1, high=all0
      pat1 = { {Half_N{1'b1}}, {Half_N{1'b1}} }; // high=all1, low=all0
      for (int s = 0; s < N; s++) begin
        run_one(1'b0, pat0, s[SHAMT_N-1:0], '0);
        run_one(1'b0, pat1, s[SHAMT_N-1:0], '0);
      end
      for (int s0 = 0; s0 < Half_N; s0++) begin
        for (int s1 = 0; s1 < Half_N; s1++) begin
          run_one(1'b1, pat0, s0[SHAMT_N-1:0], s1[HALF_SHAMT_N-1:0]);
          run_one(1'b1, pat1, s0[SHAMT_N-1:0], s1[HALF_SHAMT_N-1:0]);
        end
      end
    end

    // Random tests
    NUM = 10;
    for (int t = 0; t < NUM; t++) begin
      logic dp;
      logic [N-1:0] din;
      logic [SHAMT_N-1:0] s0;
      logic [HALF_SHAMT_N-1:0] s1;

      dp  = $urandom_range(0,1);
      din = rand_vec();
      s0  = $urandom(); // will be truncated to SHAMT_N bits
      s1  = $urandom(); // truncated

      run_one(dp, din, s0, s1);
    end

    $display("TB PASS ✅");
    $finish;
  end

  initial begin
    $fsdbDumpfile("tb_shifter.fsdb");
    $fsdbDumpvars("+all");
  end

endmodule
