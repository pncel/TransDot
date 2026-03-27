// SPDX-License-Identifier: SHL-0.51
#include "flexfloat.h"
#include <iostream>
#include <fstream>
#include <iomanip>
#include <filesystem>
#include <random>
#include <cstring>
#include <bitset>
#include <cmath>
#include <cstdlib>
#include <cstdint>

using namespace std;

enum vector_op_id : int {
  OPID_ADD               = 0,
  OPID_MUL               = 1,
  OPID_FMADD             = 2,
  OPID_TDOT_SIMD_FMADD   = 16,
  OPID_TDOT_DP_FMADD     = 17,
  OPID_TDOT_FP4_DP_FMADD = 18
};

// ------------------ bitstring helpers ------------------
static string u32_to_bits(uint32_t v) { return bitset<32>(v).to_string(); }
static string u16_to_bits(uint16_t v) { return bitset<16>(v).to_string(); }
static string u8_to_bits (uint8_t  v) { return bitset<8>(v ).to_string();  }

static uint32_t float_to_u32(float v) {
  uint32_t b; memcpy(&b, &v, sizeof(b)); return b;
}
static bool is_finite(double x) { return std::isfinite(x); }

static double urand(std::mt19937 &gen, double lo, double hi) {
  std::uniform_real_distribution<double> d(lo, hi);
  return d(gen);
}

// Simple IEEE754 float -> fp16 pack (round-to-nearest-ties-to-even).
// Good enough for our test ranges.
// Simple IEEE754 float -> fp16 pack (round-to-nearest-ties-to-even).
// Matches the usual half format enough for testing.
static inline uint16_t pack_fp16(double x) {
  float f = (float)x;
  uint32_t u = float_to_u32(f);
  uint32_t sign = (u >> 31) & 1u;
  int32_t  exp  = (int32_t)((u >> 23) & 0xFF) - 127;
  uint32_t frac = u & 0x7FFFFFu;

  if ((u & 0x7FFFFFFFu) == 0) {
    return (uint16_t)(sign << 15); // zero
  }

  // clamp to half range (exp in [-14, +15])
  if (exp > 15) { // overflow -> max finite
    return (uint16_t)((sign << 15) | (0x1E << 10) | 0x3FF);
  }
  if (exp < -24) { // too tiny -> zero
    return (uint16_t)(sign << 15);
  }

  // subnormals and normals (approx; our ranges mostly avoid extreme subnormals)
  uint32_t mant = frac | 0x800000u; // add hidden 1
  int shift = 23 - 10;
  int exp_half = exp + 15;

  if (exp_half <= 0) {
    // subnormal: shift right (1 - exp_half) extra
    int rshift = shift + (1 - exp_half);
    uint32_t val = mant >> rshift;
    return (uint16_t)((sign << 15) | (val & 0x3FF));
  } else {
    uint32_t val = mant >> shift;
    return (uint16_t)((sign << 15) | ((exp_half & 0x1F) << 10) | (val & 0x3FF));
  }
}

// IEEE754 half -> float32
static inline float fp16_to_float(uint16_t h) {
  uint32_t sign = (h >> 15) & 0x1;
  uint32_t exp  = (h >> 10) & 0x1F;
  uint32_t frac = h & 0x3FF;

  if (exp == 0) {
    if (frac == 0) {
      // ±0
      uint32_t u = (sign << 31);
      float f; memcpy(&f, &u, sizeof(f));
      return f;
    } else {
      // subnormal: frac / 2^10 * 2^(1 - bias) with bias=15
      // value = frac * 2^-24
      float mant = (float)frac / 1024.0f; // in (0,1)
      float val  = std::ldexp(mant, -14);
      return sign ? -val : val;
    }
  } else if (exp == 0x1F) {
    // Inf / NaN -> just map to float32 Inf/NaN
    uint32_t f_sign = sign << 31;
    uint32_t f_exp  = 0xFF;
    uint32_t f_frac = (frac ? 0x7FFFFF : 0); // simple quiet NaN for any payload
    uint32_t u = f_sign | (f_exp << 23) | f_frac;
    float f; memcpy(&f, &u, sizeof(f));
    return f;
  } else {
    // normal
    int32_t e = (int32_t)exp - 15 + 127; // re-bias from 15 to 127
    uint32_t f_sign = sign << 31;
    uint32_t f_exp  = ((uint32_t)e & 0xFF) << 23;
    uint32_t f_frac = frac << 13;
    uint32_t u = f_sign | f_exp | f_frac;
    float f; memcpy(&f, &u, sizeof(f));
    return f;
  }
}

// ------------------ FP8 (E5M2) pack + boxing ------------------
// E5M2: sign(1) | exp(5) | mant(2), bias = 15. Range ±57344, resolution ≈ 0.25.
// We avoid NaN/Inf for simplicity (saturate to max finite value).
static inline uint8_t pack_e5m2(double x) {
  if (x == 0.0) return 0;

  uint8_t sign = (x < 0) ? 0x80 : 0x00;
  double ax = std::fabs(x);

  constexpr int bias = 15;
  constexpr double min_norm = std::ldexp(1.0, -14); // 2^-14
  constexpr double max_norm = std::ldexp(1.75, 16); // ~114688.0, limited by exp=30,mant=3

  if (ax < min_norm) return sign; // flush to zero
  if (ax > max_norm) ax = max_norm; // saturate

  int exp2 = (int)std::floor(std::log2(ax));
  double s = std::ldexp(1.0, exp2);
  double frac = ax / s - 1.0;
  int mant = (int)std::floor(frac * 4.0 + 0.5); // 2 mant bits
  if (mant >= 4) { mant = 0; exp2 += 1; }

  int exp_field = exp2 + bias;
  if (exp_field < 1) return sign; // underflow
  if (exp_field > 30) exp_field = 30, mant = 3; // saturate to max finite

  uint8_t bits = (uint8_t)((sign) | ((exp_field & 0x1F) << 2) | (mant & 0x03));
  return bits;
}

// Flush tiny magnitudes to zero to avoid subnormals in our FP8 datasets.
static inline double clamp_fp8_small(double x) {
  double ax = std::fabs(x);
  constexpr double min_norm = std::ldexp(1.0, -6); // 2^-6
  return (ax < min_norm) ? std::copysign(0.0, x) : x;
}

// Decode FP8 E4M3 into float (handles zero/subnormal/normal; no NaN/Inf expected).
static inline float fp8_e4m3_to_float(uint8_t h);

// ------------------ FP8 (E4M3) pack + boxing ------------------
// E4M3: sign(1) | exp(4) | mant(3), bias = 7.
// This keeps the original normal-number quantization behavior and adds subnormal support.
static inline uint8_t pack_e4m3(double x) {
  if (std::isnan(x)) return 0x7F; // quiet NaN
  if (x == 0.0) return std::signbit(x) ? 0x80 : 0x00;

  uint8_t sign = (x < 0) ? 0x80 : 0x00;
  double ax = std::fabs(x);

  // E4M3: min normal is 2^-6, subnormal quantum is 2^-9.
  constexpr int bias = 7;
  constexpr double min_norm = std::ldexp(1.0, -6);  // 2^-6
  constexpr double sub_q    = std::ldexp(1.0, -9);  // 2^-9

  if (!std::isfinite(ax)) return sign | 0x77; // signed max finite

  // Subnormal/zero region: value = mant * 2^-9, mant in [1..7]
  if (ax < min_norm) {
    int mant = (int)std::floor(ax / sub_q + 0.5); // nearest
    if (mant <= 0) return sign;                   // signed zero
    if (mant >= 8) return sign | 0x08;            // rounds to min normal
    return sign | (uint8_t)(mant & 0x07);
  }

  // Normal numbers (original behavior)
  int exp2 = (int)std::floor(std::log2(ax));
  double s   = std::ldexp(1.0, exp2);            // 2^exp2
  double frac = ax / s - 1.0;
  int mant = (int)std::floor(frac * 8.0 + 0.5); // nearest
  if (mant >= 8) { mant = 0; exp2 += 1; }

  int exp_field = exp2 + bias;
  if (exp_field < 1) return sign | 0x08;
  if (exp_field > 14) exp_field = 14, mant = 7;

  return (uint8_t)(sign | ((exp_field & 0x0F) << 3) | (mant & 0x07));
}

// Decode FP8 E4M3 into float (handles zero/subnormal/normal; no NaN/Inf expected).
static inline float fp8_e4m3_to_float(uint8_t h) {
  uint32_t sign = (h >> 7) & 0x1u;
  uint32_t exp  = (h >> 3) & 0x0Fu;
  uint32_t mant = h & 0x7u;
  if (exp == 0) {
    if (mant == 0) return sign ? -0.0f : 0.0f;
    float m = (float)mant / 8.0f;
    float val = std::ldexp(m, -6);
    return sign ? -val : val;
  }
  if (exp == 0x0F) {
    return sign ? -INFINITY : INFINITY;
  }
  float m = 1.0f + (float)mant / 8.0f;
  int e = (int)exp - 7;
  float val = std::ldexp(m, e);
  return sign ? -val : val;
}

// ------------------ FP4 (E2M1) pack + decode ------------------
// E2M1: sign(1) | exp(2) | mant(1), bias = 1.
// We emit only normal/zero values (flush tiny magnitudes to zero).
static inline uint8_t pack_e2m1(double x) {
  if (x == 0.0) return 0;

  uint8_t sign = (x < 0) ? 0x8 : 0x0;
  double ax = std::fabs(x);

  constexpr int bias = 1;
  constexpr double min_norm = std::ldexp(1.0, 0); // 2^(1-bias) = 1.0
  constexpr double max_norm = std::ldexp(1.5, 1); // max finite: (1.5)*2^1 = 3.0

  if (ax < min_norm) return sign; // flush to signed zero
  if (ax > max_norm) ax = max_norm; // saturate

  int exp2 = (int)std::floor(std::log2(ax));
  double s = std::ldexp(1.0, exp2);
  double frac = ax / s - 1.0;
  int mant = (int)std::floor(frac * 2.0 + 0.5); // 1 mant bit
  if (mant >= 2) { mant = 0; exp2 += 1; }

  int exp_field = exp2 + bias;
  if (exp_field < 1) return sign;
  if (exp_field > 2) exp_field = 2, mant = 1; // clamp to max finite

  uint8_t bits = (uint8_t)(sign | ((exp_field & 0x3) << 1) | (mant & 0x1));
  return bits;
}

// Decode FP4 E2M1 into float (handles zero/subnormal/normal).
static inline float fp4_e2m1_to_float(uint8_t h) {
  uint8_t raw = h & 0xF;
  uint32_t sign = (raw >> 3) & 0x1u;
  uint32_t exp  = (raw >> 1) & 0x3u;
  uint32_t mant = raw & 0x1u;

  if (exp == 0) {
    if (mant == 0) return sign ? -0.0f : 0.0f;
    float val = 0.5f; // subnormal (mant=1)
    return sign ? -val : val;
  }
  if (exp == 0x3u) {
    return sign ? -INFINITY : INFINITY;
  }

  float m = 1.0f + (float)mant / 2.0f;
  int e = (int)exp - 1;
  float val = std::ldexp(m, e);
  return sign ? -val : val;
}

// NaN-box an 8-bit FP8 into 32 bits: upper 24 bits = 1, low 8 bits = fp8
static inline uint32_t box32_from_fp8(uint8_t fp8_bits) {
  return 0xFFFFFF00u | (uint32_t)fp8_bits;
}

// ------------------ FP16 boxing (already good) ------------------
static inline uint32_t box32_from_fp16(uint16_t fp16_bits) {
  return 0xFFFF0000u | (uint32_t)fp16_bits;  // 16 ones + 16 payload
}

// ------------------ write helpers ------------------
static void write_txt_line_32(ofstream &f, uint32_t a, uint32_t b, uint32_t c, int op) {
  f << u32_to_bits(a) << " " << u32_to_bits(b) << " "
    << u32_to_bits(c) << " " << op << "\n";
}
static void write_gold_32(ofstream &f, uint32_t g) {
  f << u32_to_bits(g) << "\n";
}
static void write_vec_line(ofstream &f, const string& prefix, int op,
                           double a, double b, double c, double g) {
  const char* opname = (op==0) ? "ADD" : (op==1) ? "MUL" : "FMADD";
  f << prefix << "  " << opname
    << "  A=" << scientific << setprecision(8) << a
    << "  B=" << b << "  C=" << c
    << "  ->  GOLDEN=" << g << "\n";
}

static void write_vec_line_dp(ofstream &f, const string& prefix,
                              double a0, double b0,
                              double a1, double b1,
                              double c,  double g) {
  f << prefix << "  DP16x2_FMADD  "
    << "A0=" << scientific << setprecision(8) << a0
    << "  B0=" << b0
    << "  A1=" << a1
    << "  B1=" << b1
    << "  C="  << c
    << "  ->  GOLDEN=" << g << "\n";
}

// Perform the op with flexfloat rounding to a given desc, returning a double
static double do_ff_op_double(int op, const flexfloat_desc_t &desc,
                              double a, double b, double c) {
  flexfloat_t A, B, C, OUT, TMP;
  ff_init(&A, desc); ff_init(&B, desc); ff_init(&C, desc);
  ff_init(&OUT, desc); ff_init(&TMP, desc);
  ff_init_double(&A, a, desc);
  ff_init_double(&B, b, desc);
  ff_init_double(&C, c, desc);

  switch (op) {
    case 0: ff_add(&OUT, &B, &C); break;         // ADD = B + C
    case 1: ff_mul(&OUT, &A, &B); break;         // MUL = A * B
    case 2: ff_mul(&TMP, &A, &B); ff_add(&OUT, &TMP, &C); break; // FMADD
    default: ff_add(&OUT, &B, &C); break;
  }
  return ff_get_double(&OUT);
}

// DP16x2 with FP32 accumulation:
//   a0,b0,a1,b1 are already quantized to FP16 domain by the caller.
//   c is already quantized to FP32 domain.
//   Semantics:
//     - treat a0,b0,a1,b1 as FP16 values
//     - compute products in high precision (double)
//     - convert products and c to FP32
//     - accumulate in FP32: ((p0 + p1) + c)
static double do_ff_op_double_dp(const flexfloat_desc_t &desc_fp16,
                                 const flexfloat_desc_t &desc_fp32,
                                 double a0, double b0,
                                 double a1, double b1,
                                 double c)
{
  // 1) Re-quantize inputs to FP16 (idempotent if they already came from desc_fp16)
  flexfloat_t A0_f16, B0_f16, A1_f16, B1_f16;
  ff_init_double(&A0_f16, a0, desc_fp16);
  ff_init_double(&B0_f16, b0, desc_fp16);
  ff_init_double(&A1_f16, a1, desc_fp16);
  ff_init_double(&B1_f16, b1, desc_fp16);

  // 2) Interpret these FP16 values as real numbers
  double a0q = ff_get_double(&A0_f16);
  double b0q = ff_get_double(&B0_f16);
  double a1q = ff_get_double(&A1_f16);
  double b1q = ff_get_double(&B1_f16);

  // 3) High-precision products (conceptually "FP32 multiply" with FP16 inputs)
  double p0 = a0q * b0q;
  double p1 = a1q * b1q;

  // 4) Convert products and c into FP32 domain
  flexfloat_t P0_f32, P1_f32, C_f32, OUT_f32;
  ff_init_double(&P0_f32, p0, desc_fp32);
  ff_init_double(&P1_f32, p1, desc_fp32);
  ff_init_double(&C_f32,  c,  desc_fp32);

  // 5) FP32 accumulation: ((p0 + p1) + c)
  ff_add(&OUT_f32, &P0_f32, &P1_f32);
  ff_add(&OUT_f32, &OUT_f32, &C_f32);

  return ff_get_double(&OUT_f32);
}

// Quantize a,b,c into desc; return as doubles
static void quantize_abc(const flexfloat_desc_t &desc,
                         double a, double b, double c,
                         double &aq, double &bq, double &cq)
{
  flexfloat_t A, B, C;
  ff_init_double(&A, a, desc);
  ff_init_double(&B, b, desc);
  ff_init_double(&C, c, desc);
  aq = ff_get_double(&A);
  bq = ff_get_double(&B);
  cq = ff_get_double(&C);
}

// Quantize (a0,b0,a1,b1) to desc0 (FP16), and c to desc1 (FP32)
static void quantize_2a2bc(const flexfloat_desc_t &desc0,
                           const flexfloat_desc_t &desc1,
                           double a0, double b0,
                           double a1, double b1,
                           double c,
                           double &a0q, double &b0q,
                           double &a1q, double &b1q,
                           double &cq)
{
  flexfloat_t A0, B0, A1, B1, C;

  ff_init_double(&A0, a0, desc0);
  ff_init_double(&B0, b0, desc0);
  ff_init_double(&A1, a1, desc0);
  ff_init_double(&B1, b1, desc0);
  ff_init_double(&C,  c,  desc1);

  a0q = ff_get_double(&A0);
  b0q = ff_get_double(&B0);
  a1q = ff_get_double(&A1);
  b1q = ff_get_double(&B1);
  cq  = ff_get_double(&C);
}

// ------------------ core generator ------------------
static void generate_for_format(const string &prefix,
                                const flexfloat_desc_t &desc,
                                int num_tests,
                                double R,
                                std::mt19937 &gen)
{
  std::filesystem::create_directories("generated");

  ofstream fin ("generated/" + prefix + "_input.txt");            // human-readable 0/1
  ofstream fgold("generated/" + prefix + "_golden_output.txt");   // human-readable 0/1
  ofstream fvec ("generated/" + prefix + "_vectors.txt");         // readable floats
  if (!fin || !fgold || !fvec) {
    cerr << "Error: cannot open output files for " << prefix << endl;
    return;
  }

  std::uniform_int_distribution<int> op_dist(OPID_ADD, OPID_FMADD); // 0=ADD,1=MUL,2=FMADD
  const double k = 0.95; // margin

  int produced = 0;
  int attempts = 0;
  const int ATTEMPT_LIMIT = num_tests * 200;

  // helpers for fp-size
  bool is_fp32 = (desc.exp_bits == 8 && desc.frac_bits == 23);
  bool is_fp16 = (desc.exp_bits == 5 && desc.frac_bits == 10);
  bool is_fp8  = (desc.exp_bits == 4 && desc.frac_bits == 3) || (desc.exp_bits == 5 && desc.frac_bits == 2);

  while (produced < num_tests && attempts < ATTEMPT_LIMIT) {
    attempts++;
    int op = op_dist(gen);

    double a=0, b=0, c=0, g=0;
    // Choose ranges so result stays within [-R, R]
    if (op == 0) {                      // ADD -> B + C
      double Abound = 0.5 * R * k;
      a = urand(gen, -Abound, Abound);
      b = urand(gen, -Abound, Abound);
      c = urand(gen, -Abound, Abound);
    } else if (op == 1) {               // MUL -> A * B
      double Abound = std::sqrt(R) * k;
      a = urand(gen, -Abound, Abound);
      b = urand(gen, -Abound, Abound);
      c = urand(gen, -0.5*R, 0.5*R);  // unused but deterministic
    } else {                            // FMADD -> A*B + C
      double Abound = std::sqrt(R/2.0) * k;
      a = urand(gen, -Abound, Abound);
      b = urand(gen, -Abound, Abound);
      double prod = a*b;
      double lo = std::max(-R, -R - prod);
      double hi = std::min( R,  R - prod);
      if (lo > hi) continue;
      c = urand(gen, lo, hi);
    }

    // Quantize to the target format (flexfloat rounding)
    double aq, bq, cq;
    quantize_abc(desc, a, b, c, aq, bq, cq);

    // Match RTL FMADD semantics for FP16: fused multiply-add with a single
    // final FP16 rounding.
    if (is_fp16 && op == OPID_FMADD) {
      uint16_t Ah = pack_fp16(aq);
      uint16_t Bh = pack_fp16(bq);
      uint16_t Ch = pack_fp16(cq);
      float af = fp16_to_float(Ah);
      float bf = fp16_to_float(Bh);
      float cf = fp16_to_float(Ch);
      float gf = std::fma(af, bf, cf);
      g = static_cast<double>(fp16_to_float(pack_fp16(gf)));
    } else {
      g = do_ff_op_double(op, desc, aq, bq, cq);
    }
    if (!is_finite(g) || std::fabs(g) > R) continue;

    // Emit per format
    if (is_fp32) {
      uint32_t A = float_to_u32((float)aq);
      uint32_t B = float_to_u32((float)bq);
      uint32_t C = float_to_u32((float)cq);
      uint32_t G = float_to_u32((float)g);
      write_txt_line_32(fin, A, B, C, op);
      write_gold_32(fgold, G);
      write_vec_line(fvec, prefix, op, aq, bq, cq, g);
    } else if (is_fp16) {
      uint16_t Ah = pack_fp16(aq);
      uint16_t Bh = pack_fp16(bq);
      uint16_t Ch = pack_fp16(cq);
      uint16_t Gh = pack_fp16(g);

      uint32_t A = box32_from_fp16(Ah);
      uint32_t B = box32_from_fp16(Bh);
      uint32_t C = box32_from_fp16(Ch);
      uint32_t G = box32_from_fp16(Gh);

      write_txt_line_32(fin, A, B, C, op);
      write_gold_32(fgold, G);
      write_vec_line(fvec, prefix, op, aq, bq, cq, g);
    } else if (is_fp8) {
      // *** FP8 E4M3 pack + NaN-box to 32b ***
      // Inputs are pre-clamped to avoid extreme tiny operands.
      double aqc = clamp_fp8_small(aq), bqc = clamp_fp8_small(bq), cqc = clamp_fp8_small(cq);
      uint8_t a8 = pack_e4m3(aqc);
      uint8_t b8 = pack_e4m3(bqc);
      uint8_t c8 = pack_e4m3(cqc);
      double af = static_cast<double>(fp8_e4m3_to_float(a8));
      double bf = static_cast<double>(fp8_e4m3_to_float(b8));
      double cf = static_cast<double>(fp8_e4m3_to_float(c8));

      // Match RTL datapath semantics:
      //   ADD uses B + C
      //   MUL uses A * B
      //   FMADD is fused (single final rounding to FP8)
      double gf = 0.0;
      if (op == OPID_ADD) {
        gf = bf + cf;
      } else if (op == OPID_MUL) {
        gf = af * bf;
      } else {
        gf = std::fma(af, bf, cf);
      }
      uint8_t g8 = pack_e4m3(gf);
      double gqf = static_cast<double>(fp8_e4m3_to_float(g8));

      uint32_t A = box32_from_fp8(a8);
      uint32_t B = box32_from_fp8(b8);
      uint32_t C = box32_from_fp8(c8);
      uint32_t G = box32_from_fp8(g8);

      write_txt_line_32(fin, A, B, C, op);
      write_gold_32(fgold, G);
      write_vec_line(fvec, prefix, op, af, bf, cf, gqf);
    } else {
      // Unknown desc — skip.
      continue;
    }

    produced++;
  }

  cout << "[Generated] " << prefix << " : " << produced << "/" << num_tests
       << " tests (R=" << R << ", attempts=" << attempts << ")\n";
}

// ------------------ DP16x2 → FP32 generator ------------------
static void generate_for_format_dp(const string &prefix,
                                   const flexfloat_desc_t &fp16_desc, // unused, but keep signature
                                   int num_tests,
                                   double R,
                                   std::mt19937 &gen)
{
  std::filesystem::create_directories("generated");

  ofstream fin  ("generated/" + prefix + "_dp_input.txt");          // 32b bitstrings + op
  ofstream fgold("generated/" + prefix + "_dp_golden_output.txt");  // 32b golden FP32 bits
  ofstream fvec ("generated/" + prefix + "_dp_vectors.txt");        // readable floats
  if (!fin || !fgold || !fvec) {
    cerr << "Error: cannot open DP output files for " << prefix << endl;
    return;
  }

  const double k = 0.95; // margin
  int produced      = 0;
  int attempts      = 0;
  const int ATTEMPT_LIMIT = num_tests * 200;

  while (produced < num_tests && attempts < ATTEMPT_LIMIT) {
    attempts++;

    // Only DP FMADD op (=2) is meaningful here
    int op = OPID_TDOT_DP_FMADD;

    double a0 = 0, b0 = 0, a1 = 0, b1 = 0, c = 0;

    // Choose ranges similar to scalar FMADD, but for 2 terms
    double Abound = std::sqrt(R / 2.0) * k;
    a0 = urand(gen, -Abound, Abound);
    b0 = urand(gen, -Abound, Abound);
    a1 = urand(gen, -Abound, Abound);
    b1 = urand(gen, -Abound, Abound);

    double prod0 = a0 * b0;
    double prod1 = a1 * b1;
    double prod  = prod0 + prod1;

    double lo = std::max(-R, -R - prod);
    double hi = std::min( R,  R - prod);
    if (lo > hi) continue;
    c = urand(gen, lo, hi);

    // ---- Quantize to FP16 for inputs (A0,B0,A1,B1) and FP32 for C ----
    uint16_t A0h = pack_fp16(a0);
    uint16_t B0h = pack_fp16(b0);
    uint16_t A1h = pack_fp16(a1);
    uint16_t B1h = pack_fp16(b1);

    float a0f = fp16_to_float(A0h);
    float b0f = fp16_to_float(B0h);
    float a1f = fp16_to_float(A1h);
    float b1f = fp16_to_float(B1h);

    float cf  = (float)c; // FP32 quantize C

    // For printing, show the quantized values (what HW really sees)
    double a0q = (double)a0f;
    double b0q = (double)b0f;
    double a1q = (double)a1f;
    double b1q = (double)b1f;
    double cq  = (double)cf;

    // ---- Golden FP32 accumulation: (a0*b0 + a1*b1) + c, all in float ----
    float p0f = a0f * b0f;
    float p1f = a1f * b1f;
    float gf  = (p0f + p1f) + cf;

    if (!std::isfinite(gf) || std::fabs((double)gf) > R) continue;

    uint32_t A = (uint32_t(A1h) << 16) | uint32_t(A0h);
    uint32_t B = (uint32_t(B1h) << 16) | uint32_t(B0h);
    uint32_t C = float_to_u32(cf);
    uint32_t G = float_to_u32(gf);

    // bit-pattern IO files
    write_txt_line_32(fin, A, B, C, op);
    write_gold_32(fgold, G);

    // human-readable
    fvec << prefix << "  DP16x2_FMADD"
         << "  A0=" << scientific << setprecision(8) << a0q
         << "  B0=" << b0q
         << "  A1=" << a1q
         << "  B1=" << b1q
         << "  C="  << cq
         << "  ->  GOLDEN=" << (double)gf
         << "\n";

    produced++;
  }

  cout << "[Generated DP] " << prefix << " : " << produced << "/" << num_tests
       << " tests (R=" << R << ", attempts=" << attempts << ")\n";
}

static void generate_for_format_simd_fp16(const string &prefix,
                                   const flexfloat_desc_t &fp16_desc, // unused, but keep signature
                                   int num_tests,
                                   double R,
                                   std::mt19937 &gen)
{
  std::filesystem::create_directories("generated");

  ofstream fin  ("generated/" + prefix + "_simd_fp16_input.txt");          // 32b bitstrings + op
  ofstream fgold("generated/" + prefix + "_simd_fp16_golden_output.txt");  // 32b golden FP32 bits
  ofstream fvec ("generated/" + prefix + "_simd_fp16_vectors.txt");        // readable floats
  if (!fin || !fgold || !fvec) {
    cerr << "Error: cannot open SIMD FP16 output files for " << prefix << endl;
    return;
  }

  const double k = 0.95; // margin
  int produced      = 0;
  int attempts      = 0;
  const int ATTEMPT_LIMIT = num_tests * 200;

  while (produced < num_tests && attempts < ATTEMPT_LIMIT) {
    attempts++;

    // Only DP FMADD op (=2) is meaningful here
    int op = OPID_TDOT_SIMD_FMADD;

    double a0 = 0, b0 = 0, a1 = 0, b1 = 0, c0 = 0, c1 = 0;

    // Choose ranges similar to scalar FMADD, but for 2 terms
    double Abound = std::sqrt(R / 2.0) * k;
    a0 = urand(gen, -Abound, Abound);
    b0 = urand(gen, -Abound, Abound);
    a1 = urand(gen, -Abound, Abound);
    b1 = urand(gen, -Abound, Abound);
    c0 = urand(gen, -Abound, Abound);
    c1 = urand(gen, -Abound, Abound);

    double prod0 = a0 * b0;
    double prod1 = a1 * b1;

    double lo_0 = std::max(-R, -R - prod0);
    double hi_0 = std::min( R,  R - prod0);
    if (lo_0 > hi_0) continue;
    c0 = urand(gen, lo_0, hi_0);

    double lo_1 = std::max(-R, -R - prod1);
    double hi_1 = std::min( R,  R - prod1);
    if (lo_1 > hi_1) continue;
    c1 = urand(gen, lo_1, hi_1);

    // ---- Quantize to FP16 for inputs (A0,B0,A1,B1) and FP32 for C ----
    uint16_t A0h = pack_fp16(a0);
    uint16_t B0h = pack_fp16(b0);
    uint16_t A1h = pack_fp16(a1);
    uint16_t B1h = pack_fp16(b1);
    uint16_t C0h = pack_fp16(c0);
    uint16_t C1h = pack_fp16(c1);

    float a0f = fp16_to_float(A0h);
    float b0f = fp16_to_float(B0h);
    float a1f = fp16_to_float(A1h);
    float b1f = fp16_to_float(B1h);
    float c0f = fp16_to_float(C0h);
    float c1f = fp16_to_float(C1h);


    // For printing, show the quantized values (what HW really sees)
    double a0q = (double)a0f;
    double b0q = (double)b0f;
    double a1q = (double)a1f;
    double b1q = (double)b1f;
    double c0q = (double)c0f;
    double c1q = (double)c1f;

    // ---- Golden FP32 accumulation: (a0*b0 + a1*b1) + c, all in float ----
    float p0f = a0f * b0f;
    float g0f = (p0f) + c0f;

    float p1f = a1f * b1f;
    float g1f = (p1f) + c1f;

    uint16_t G0h = pack_fp16(g0f);
    uint16_t G1h = pack_fp16(g1f);

    if (!std::isfinite(g0f) || std::fabs((double)g0f) > R) continue;
    if (!std::isfinite(g1f) || std::fabs((double)g1f) > R) continue;

    uint32_t A = (uint32_t(A1h) << 16) | uint32_t(A0h);
    uint32_t B = (uint32_t(B1h) << 16) | uint32_t(B0h);
    uint32_t C = (uint32_t(C1h) << 16) | uint32_t(C0h);
    uint32_t G = (uint32_t(G1h) << 16) | uint32_t(G0h);

    // bit-pattern IO files
    write_txt_line_32(fin, A, B, C, op);
    write_gold_32(fgold, G);

    // human-readable
    fvec << prefix << "  DP16x2_FMADD"
         << "  A0=" << scientific << setprecision(8) << a0q
         << "  B0=" << b0q
         << "  C0="  << c0q
         << "  ->  GOLDEN0=" << (double)g0f
         << "  A1=" << a1q
         << "  B1=" << b1q
         << "  C1="  << c1q
         << "  ->  GOLDEN1=" << (double)g1f
         << "\n";

    produced++;
  }

  cout << "[Generated SIMD FP16x2] " << prefix << " : " << produced << "/" << num_tests
       << " tests (R=" << R << ", attempts=" << attempts << ")\n";
}

// ------------------ SIMD FP8x4 generator ------------------
static void generate_for_format_simd_fp8(const string &prefix,
                                         int num_tests,
                                         double R,
                                         std::mt19937 &gen)
{
  std::filesystem::create_directories("generated");

  ofstream fin  ("generated/" + prefix + "_simd_fp8_input.txt");          // 32b bitstrings + op
  ofstream fgold("generated/" + prefix + "_simd_fp8_golden_output.txt");  // 32b golden FP8x4 bits
  ofstream fvec ("generated/" + prefix + "_simd_fp8_vectors.txt");        // readable floats
  if (!fin || !fgold || !fvec) {
    cerr << "Error: cannot open SIMD FP8 output files for " << prefix << endl;
    return;
  }

  const double k = 0.95; // margin
  int produced      = 0;
  int attempts      = 0;
  const int ATTEMPT_LIMIT = num_tests * 200;

  while (produced < num_tests && attempts < ATTEMPT_LIMIT) {
    attempts++;

    // Only FMADD op (=2) is meaningful here
    int op = OPID_TDOT_SIMD_FMADD;

    double a[4] = {0}, b[4] = {0}, c[4] = {0};
    float  af[4], bf[4], cf[4], gf[4], gqf[4];
    uint8_t a8[4], b8[4], c8[4], g8[4];

    bool ok = true;
    double Abound = std::sqrt(R / 2.0) * k;
    for (int i = 0; i < 4; i++) {
      a[i] = urand(gen, -Abound, Abound);
      b[i] = urand(gen, -Abound, Abound);
      double prod = a[i] * b[i];
      double lo = std::max(-R, -R - prod);
      double hi = std::min( R,  R - prod);
      if (lo > hi) { ok = false; break; }
      c[i] = urand(gen, lo, hi);
    }
    if (!ok) continue;

    for (int i = 0; i < 4; i++) {
      a8[i] = pack_e4m3(clamp_fp8_small(a[i]));
      b8[i] = pack_e4m3(clamp_fp8_small(b[i]));
      c8[i] = pack_e4m3(clamp_fp8_small(c[i]));
      af[i] = fp8_e4m3_to_float(a8[i]);
      bf[i] = fp8_e4m3_to_float(b8[i]);
      cf[i] = fp8_e4m3_to_float(c8[i]);
      gf[i] = (af[i] * bf[i]) + cf[i];
      if (!std::isfinite(gf[i]) || std::fabs((double)gf[i]) > R) { ok = false; break; }
      g8[i] = pack_e4m3((double)gf[i]);
      gqf[i] = fp8_e4m3_to_float(g8[i]);
    }
    if (!ok) continue;

    uint32_t A = (uint32_t(a8[3]) << 24) | (uint32_t(a8[2]) << 16) |
                 (uint32_t(a8[1]) <<  8) |  uint32_t(a8[0]);
    uint32_t B = (uint32_t(b8[3]) << 24) | (uint32_t(b8[2]) << 16) |
                 (uint32_t(b8[1]) <<  8) |  uint32_t(b8[0]);
    uint32_t C = (uint32_t(c8[3]) << 24) | (uint32_t(c8[2]) << 16) |
                 (uint32_t(c8[1]) <<  8) |  uint32_t(c8[0]);
    uint32_t G = (uint32_t(g8[3]) << 24) | (uint32_t(g8[2]) << 16) |
                 (uint32_t(g8[1]) <<  8) |  uint32_t(g8[0]);

    write_txt_line_32(fin, A, B, C, op);
    write_gold_32(fgold, G);

    fvec << prefix << "  SIMD4xFP8_FMADD"
         << "  A0=" << scientific << setprecision(8) << (double)af[0]
         << "  B0=" << bf[0]
         << "  C0=" << cf[0]
         << "  ->  GOLDEN0=" << (double)gqf[0]
         << "  A1=" << af[1]
         << "  B1=" << bf[1]
         << "  C1=" << cf[1]
         << "  ->  GOLDEN1=" << (double)gqf[1]
         << "  A2=" << af[2]
         << "  B2=" << bf[2]
         << "  C2=" << cf[2]
         << "  ->  GOLDEN2=" << (double)gqf[2]
         << "  A3=" << af[3]
         << "  B3=" << bf[3]
         << "  C3=" << cf[3]
         << "  ->  GOLDEN3=" << (double)gqf[3]
         << "\n";

    produced++;
  }

  cout << "[Generated SIMD FP8x4] " << prefix << " : " << produced << "/" << num_tests
       << " tests (R=" << R << ", attempts=" << attempts << ")\n";
}

// ------------------ DP FP8x4 → FP32 generator ------------------
static void generate_for_format_dp_fp8(const string &prefix,
                                       int num_tests,
                                       double R,
                                       std::mt19937 &gen)
{
  std::filesystem::create_directories("generated");

  ofstream fin  ("generated/" + prefix + "_dp_input.txt");          // 32b bitstrings + op
  ofstream fgold("generated/" + prefix + "_dp_golden_output.txt");  // 32b golden FP32 bits
  ofstream fvec ("generated/" + prefix + "_dp_vectors.txt");        // readable floats
  if (!fin || !fgold || !fvec) {
    cerr << "Error: cannot open FP8 DP output files for " << prefix << endl;
    return;
  }

  const double k = 0.95; // margin
  int produced      = 0;
  int attempts      = 0;
  const int ATTEMPT_LIMIT = num_tests * 200;

  while (produced < num_tests && attempts < ATTEMPT_LIMIT) {
    attempts++;

    // Only DP FMADD op (=2) is meaningful here
    int op = OPID_TDOT_DP_FMADD;

    double a[4] = {0}, b[4] = {0}, c = 0;
    double Abound = std::sqrt(R / 4.0) * k;
    for (int i = 0; i < 4; i++) {
      a[i] = urand(gen, -Abound, Abound);
      b[i] = urand(gen, -Abound, Abound);
    }

    double prod_sum = 0.0;
    for (int i = 0; i < 4; i++) prod_sum += a[i] * b[i];

    double lo = std::max(-R, -R - prod_sum);
    double hi = std::min( R,  R - prod_sum);
    if (lo > hi) continue;
    c = urand(gen, lo, hi);

    uint8_t a8[4], b8[4];
    float af[4], bf[4];
    for (int i = 0; i < 4; i++) {
      a8[i] = pack_e4m3(clamp_fp8_small(a[i]));
      b8[i] = pack_e4m3(clamp_fp8_small(b[i]));
      af[i] = fp8_e4m3_to_float(a8[i]);
      bf[i] = fp8_e4m3_to_float(b8[i]);
    }

    float cf = (float)c; // FP32 quantize C
    float p0 = af[0] * bf[0];
    float p1 = af[1] * bf[1];
    float p2 = af[2] * bf[2];
    float p3 = af[3] * bf[3];
    float gf = ((p0 + p1) + (p2 + p3)) + cf;

    if (!std::isfinite(gf) || std::fabs((double)gf) > R) continue;

    uint32_t A = (uint32_t(a8[3]) << 24) | (uint32_t(a8[2]) << 16) |
                 (uint32_t(a8[1]) <<  8) |  uint32_t(a8[0]);
    uint32_t B = (uint32_t(b8[3]) << 24) | (uint32_t(b8[2]) << 16) |
                 (uint32_t(b8[1]) <<  8) |  uint32_t(b8[0]);
    uint32_t C = float_to_u32(cf);
    uint32_t G = float_to_u32(gf);

    write_txt_line_32(fin, A, B, C, op);
    write_gold_32(fgold, G);

    fvec << prefix << "  DP8x4_FMADD"
         << "  A0=" << scientific << setprecision(8) << (double)af[0]
         << "  B0=" << bf[0]
         << "  A1=" << af[1]
         << "  B1=" << bf[1]
         << "  A2=" << af[2]
         << "  B2=" << bf[2]
         << "  A3=" << af[3]
         << "  B3=" << bf[3]
         << "  C="  << (double)cf
         << "  ->  GOLDEN=" << (double)gf
         << "\n";

    produced++;
  }

  cout << "[Generated DP FP8x4] " << prefix << " : " << produced << "/" << num_tests
       << " tests (R=" << R << ", attempts=" << attempts << ")\n";
}

// ------------------ DP FP4x8 → FP32 generator ------------------
static void generate_for_format_dp_fp4(const string &prefix,
                                       int num_tests,
                                       double R,
                                       std::mt19937 &gen)
{
  std::filesystem::create_directories("generated");

  ofstream fin  ("generated/" + prefix + "_dp_input.txt");
  ofstream fgold("generated/" + prefix + "_dp_golden_output.txt");
  ofstream fvec ("generated/" + prefix + "_dp_vectors.txt");
  if (!fin || !fgold || !fvec) {
    cerr << "Error: cannot open FP4 DP output files for " << prefix << endl;
    return;
  }

  const double k = 0.95;
  int produced      = 0;
  int attempts      = 0;
  const int ATTEMPT_LIMIT = num_tests * 200;

  while (produced < num_tests && attempts < ATTEMPT_LIMIT) {
    attempts++;

    int op = OPID_TDOT_FP4_DP_FMADD;

    double a[8] = {0}, b[8] = {0}, c = 0;
    double Abound = std::sqrt(R / 8.0) * k;
    for (int i = 0; i < 8; i++) {
      a[i] = urand(gen, -Abound, Abound);
      b[i] = urand(gen, -Abound, Abound);
    }

    double prod_sum = 0.0;
    for (int i = 0; i < 8; i++) prod_sum += a[i] * b[i];

    double lo = std::max(-R, -R - prod_sum);
    double hi = std::min( R,  R - prod_sum);
    if (lo > hi) continue;
    c = urand(gen, lo, hi);

    uint8_t a4[8], b4[8];
    float af[8], bf[8];
    for (int i = 0; i < 8; i++) {
      a4[i] = pack_e2m1(a[i]);
      b4[i] = pack_e2m1(b[i]);
      af[i] = fp4_e2m1_to_float(a4[i]);
      bf[i] = fp4_e2m1_to_float(b4[i]);
    }

    float cf = (float)c;
    float gf = 0.0f;
    for (int i = 0; i < 8; i++) gf += af[i] * bf[i];
    gf += cf;

    if (!std::isfinite(gf) || std::fabs((double)gf) > R) continue;

    uint32_t A = (uint32_t(a4[7]) << 28) | (uint32_t(a4[6]) << 24) |
                 (uint32_t(a4[5]) << 20) | (uint32_t(a4[4]) << 16) |
                 (uint32_t(a4[3]) << 12) | (uint32_t(a4[2]) <<  8) |
                 (uint32_t(a4[1]) <<  4) |  uint32_t(a4[0]);
    uint32_t B = (uint32_t(b4[7]) << 28) | (uint32_t(b4[6]) << 24) |
                 (uint32_t(b4[5]) << 20) | (uint32_t(b4[4]) << 16) |
                 (uint32_t(b4[3]) << 12) | (uint32_t(b4[2]) <<  8) |
                 (uint32_t(b4[1]) <<  4) |  uint32_t(b4[0]);
    uint32_t C = float_to_u32(cf);
    uint32_t G = float_to_u32(gf);

    write_txt_line_32(fin, A, B, C, op);
    write_gold_32(fgold, G);

    fvec << prefix << "  DP4x8_FMADD"
         << "  A0=" << scientific << setprecision(8) << (double)af[0]
         << "  B0=" << bf[0]
         << "  A1=" << af[1]
         << "  B1=" << bf[1]
         << "  A2=" << af[2]
         << "  B2=" << bf[2]
         << "  A3=" << af[3]
         << "  B3=" << bf[3]
         << "  A4=" << af[4]
         << "  B4=" << bf[4]
         << "  A5=" << af[5]
         << "  B5=" << bf[5]
         << "  A6=" << af[6]
         << "  B6=" << bf[6]
         << "  A7=" << af[7]
         << "  B7=" << bf[7]
         << "  C="  << (double)cf
         << "  ->  GOLDEN=" << (double)gf
         << "\n";

    produced++;
  }

  cout << "[Generated DP FP4x8] " << prefix << " : " << produced << "/" << num_tests
       << " tests (R=" << R << ", attempts=" << attempts << ")\n";
}

// ------------------ main ------------------
int main(int argc, char **argv) {
  int num_tests = (argc > 1) ? atoi(argv[1]) : 256;
  if (num_tests <= 0) num_tests = 256;

  unsigned seed = (argc > 2) ? (unsigned)strtoul(argv[2], nullptr, 10) : 12345u;
  std::mt19937 gen(seed);
  cout << "[DataGen] Seed = " << seed << "\n";

  // flexfloat descriptors
  flexfloat_desc_t fp32 = {8, 23};
  flexfloat_desc_t fp16 = {5, 10}; // e5m10
  flexfloat_desc_t fp8  = {4, 3};  // e4m3

  // safe ranges to avoid NaN/Inf (and subnormals for fp8)
  double R32 = 1e10;
  double R16 = 1e3;
  double R8  = 8.0;
  double R4  = 64.0;

  cout << "[DataGen] Generating " << num_tests << " tests per format...\n";
  std::filesystem::create_directories("generated");

  generate_for_format("fp32", fp32, num_tests, R32, gen);
  generate_for_format("fp16", fp16, num_tests, R16, gen);
  generate_for_format("fp8",  fp8,  num_tests, R8,  gen);
  generate_for_format_simd_fp16("fp16", fp16, num_tests, R16, gen);
  generate_for_format_simd_fp8("fp8", num_tests, R8, gen);
  generate_for_format_dp("fp16_fp32", fp16, num_tests, R16, gen);
  generate_for_format_dp_fp8("fp8_fp32", num_tests, R8, gen);
  generate_for_format_dp_fp4("fp4_fp32", num_tests, R4, gen);

  cout << "[Done] All formats generated in ./generated/\n";
  return 0;
}
