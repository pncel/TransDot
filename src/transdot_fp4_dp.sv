module transdot_fp4_dp_qtr10 (
  input  logic [3:0] a0,
  input  logic [3:0] b0,
  input  logic [3:0] a1,
  input  logic [3:0] b1,
  output logic        y_sign,
  output logic [8:0]  y_mag   // raw positive integer in quarter-units (value = (+/-) y_mag * 0.25)
);

  // FP4 e2m1 layout: {sign, exp[1:0], mant[0]}, bias=1
  typedef struct packed {
    logic       sign;
    logic       is_zero;
    logic [1:0] exp_unb;  // unbiased exponent for normals: 0..2 ; subnorm uses 0
    logic [1:0] sig_q1;   // Q1 significand with 1 fractional bit: 0.0/0.5/1.0/1.5 encoded as 0..3
  } fp4_u_t;

  function automatic fp4_u_t unpack_fp4(input logic [3:0] x);
    fp4_u_t u;
    logic s;
    logic [1:0] e;
    logic m;
    begin
      s = x[3];
      e = x[2:1];
      m = x[0];

      u.sign    = s;
      u.is_zero = (e == 2'b00) && (m == 1'b0);

      if (u.is_zero) begin
        u.exp_unb = 2'd0;
        u.sig_q1  = 2'b00;
      end else if (e == 2'b00) begin
        // subnormal: only 0.5 exists => sig=0.5, exponent effectively 0
        u.exp_unb = 2'd0;
        u.sig_q1  = {1'b0, m}; // 0.1 = 0.5
      end else begin
        // normal: (1.m) * 2^(e-1)
        u.exp_unb = e - 2'd1;  // 0..2
        u.sig_q1  = {1'b1, m}; // 1.0 or 1.5
      end
      return u;
    end
  endfunction

  // Return signed integer in quarter units (LSB=0.25):
  //   a*b in quarter units = (sigA*sigB) * 2^(expA+expB)
  function automatic logic signed [9:0] mul_qtr10(fp4_u_t ua, fp4_u_t ub);
    logic [3:0] mag_q2;     // 0..9
    logic [2:0] e_sum;      // 0..4
    logic [9:0] mag_shift;  // <= 9<<4 = 144
    logic signp;
    begin
      if (ua.is_zero || ub.is_zero || (ua.sig_q1 == 0) || (ub.sig_q1 == 0)) begin
        return 10'sd0;
      end

      mag_q2    = ua.sig_q1 * ub.sig_q1;     // exact
      e_sum     = ua.exp_unb + ub.exp_unb;   // exact
      mag_shift = (10'(mag_q2)) <<< e_sum;   // exact scaling in quarter-units

      signp = ua.sign ^ ub.sign;
      return signp ? -$signed(mag_shift) : $signed(mag_shift);
    end
  endfunction

  fp4_u_t ua0, ub0, ua1, ub1;
  logic signed [9:0] p0_qtr, p1_qtr;
  logic signed [10:0] sum_qtr_wide; // one extra bit for safe add
  logic signed [9:0]  sum_qtr;
  logic [9:0] abs_qtr;

  always_comb begin
    ua0 = unpack_fp4(a0);
    ub0 = unpack_fp4(b0);
    ua1 = unpack_fp4(a1);
    ub1 = unpack_fp4(b1);

    p0_qtr = mul_qtr10(ua0, ub0);
    p1_qtr = mul_qtr10(ua1, ub1);

    // exact dot product in quarter units (still fits in +/-288)
    sum_qtr_wide = $signed({p0_qtr[9], p0_qtr}) + $signed({p1_qtr[9], p1_qtr});
    sum_qtr      = sum_qtr_wide[9:0];

    if (sum_qtr == 10'sd0) begin
      y_sign = 1'b0;
      y_mag  = 9'd0;
    end else if (sum_qtr[9]) begin
      // negative
      y_sign = 1'b1;
      abs_qtr = -sum_qtr;   // two's complement abs
      y_mag  = abs_qtr[8:0];
    end else begin
      // positive
      y_sign = 1'b0;
      y_mag  = sum_qtr[8:0];
    end
  end

endmodule