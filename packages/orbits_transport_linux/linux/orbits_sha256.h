#ifndef ORBITS_SHA256_H_
#define ORBITS_SHA256_H_

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct orbits_sha256_ctx {
  uint32_t state[8];
  uint64_t bitcount;
  uint8_t buffer[64];
  size_t buffer_len;
} orbits_sha256_ctx;

static uint32_t orbits_rotr32(uint32_t x, uint32_t n) {
  return (x >> n) | (x << (32 - n));
}

static void orbits_sha256_transform(orbits_sha256_ctx* ctx, const uint8_t data[64]) {
  static const uint32_t k[64] = {
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
  uint32_t w[64];
  for (int i = 0; i < 16; i++) {
    w[i] = ((uint32_t)data[i * 4] << 24) | ((uint32_t)data[i * 4 + 1] << 16) |
           ((uint32_t)data[i * 4 + 2] << 8) | ((uint32_t)data[i * 4 + 3]);
  }
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = orbits_rotr32(w[i - 15], 7) ^ orbits_rotr32(w[i - 15], 18) ^
                  (w[i - 15] >> 3);
    uint32_t s1 = orbits_rotr32(w[i - 2], 17) ^ orbits_rotr32(w[i - 2], 19) ^
                  (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = ctx->state[0], b = ctx->state[1], c = ctx->state[2],
           d = ctx->state[3], e = ctx->state[4], f = ctx->state[5],
           g = ctx->state[6], h = ctx->state[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = orbits_rotr32(e, 6) ^ orbits_rotr32(e, 11) ^ orbits_rotr32(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    uint32_t t1 = h + S1 + ch + k[i] + w[i];
    uint32_t S0 = orbits_rotr32(a, 2) ^ orbits_rotr32(a, 13) ^ orbits_rotr32(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = S0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  ctx->state[0] += a;
  ctx->state[1] += b;
  ctx->state[2] += c;
  ctx->state[3] += d;
  ctx->state[4] += e;
  ctx->state[5] += f;
  ctx->state[6] += g;
  ctx->state[7] += h;
}

static void orbits_sha256_init(orbits_sha256_ctx* ctx) {
  memset(ctx, 0, sizeof(*ctx));
  ctx->state[0] = 0x6a09e667;
  ctx->state[1] = 0xbb67ae85;
  ctx->state[2] = 0x3c6ef372;
  ctx->state[3] = 0xa54ff53a;
  ctx->state[4] = 0x510e527f;
  ctx->state[5] = 0x9b05688c;
  ctx->state[6] = 0x1f83d9ab;
  ctx->state[7] = 0x5be0cd19;
}

static void orbits_sha256_update(orbits_sha256_ctx* ctx, const void* data,
                                 size_t len) {
  const uint8_t* p = (const uint8_t*)data;
  ctx->bitcount += (uint64_t)len * 8;
  while (len > 0) {
    size_t room = 64 - ctx->buffer_len;
    size_t n = len < room ? len : room;
    memcpy(ctx->buffer + ctx->buffer_len, p, n);
    ctx->buffer_len += n;
    p += n;
    len -= n;
    if (ctx->buffer_len == 64) {
      orbits_sha256_transform(ctx, ctx->buffer);
      ctx->buffer_len = 0;
    }
  }
}

static void orbits_sha256_final(orbits_sha256_ctx* ctx, uint8_t out[32]) {
  uint64_t bits = ctx->bitcount;
  uint8_t pad[64];
  memset(pad, 0, sizeof(pad));
  pad[0] = 0x80;
  size_t pad_len = (ctx->buffer_len < 56) ? (56 - ctx->buffer_len)
                                          : (120 - ctx->buffer_len);
  uint64_t saved = ctx->bitcount;
  orbits_sha256_update(ctx, pad, pad_len);
  ctx->bitcount = saved;
  uint8_t lenb[8];
  for (int i = 7; i >= 0; i--) {
    lenb[i] = (uint8_t)(bits & 0xff);
    bits >>= 8;
  }
  orbits_sha256_update(ctx, lenb, 8);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (uint8_t)(ctx->state[i] >> 24);
    out[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
    out[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
    out[i * 4 + 3] = (uint8_t)ctx->state[i];
  }
}

static void orbits_sha256_hex(const uint8_t digest[32], char hex[65]) {
  static const char* digits = "0123456789abcdef";
  for (int i = 0; i < 32; i++) {
    hex[i * 2] = digits[digest[i] >> 4];
    hex[i * 2 + 1] = digits[digest[i] & 0xf];
  }
  hex[64] = '\0';
}

#ifdef __cplusplus
}
#endif

#endif  // ORBITS_SHA256_H_
