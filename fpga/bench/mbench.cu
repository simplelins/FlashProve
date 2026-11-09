// mbench.cu — M-a (BLAKE2b throughput) + M-b (Goldilocks field mul throughput) on 4090.
// Minimal microbenchmarks: pure kernel throughput, no tree structure, no dependencies.
#include <cstdio>
#include <cuda_runtime.h>
#include <vector>
using u64 = unsigned long long; using u32 = unsigned;
__global__ void k_blake2b(u64 *out, const u64 *in, int n) {
  // Simplified BLAKE2b round: measures the G-function arithmetic (adds, rotates, XORs)
  // not a complete implementation — the goal is an upper bound on the GPU's throughput
  // for the same instruction mix as one compression (12 rounds x 8 G x ~10 ops).
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  u64 v[16];
  for (int j = 0; j < 16; j++) v[j] = in[(size_t)i * 16 + j];
  u64 x = 0;
  for (int r = 0; r < 12; r++) {
    for (int s = 0; s < 8; s++) {
      // G-function instruction mix (one G = ~10 arithmetic ops on 4 lanes)
      int a = s, b = s + 4, c = s + 8, d = s + 12;
      v[a] += v[b] + in[(size_t)i * 16 + (r * 8 + s) % 16]; x ^= v[a];
      v[d] = (v[d] ^ v[a]) >> 32 | (v[d] ^ v[a]) << 32; x += v[d];
      v[c] += v[d]; x ^= v[c];
      v[b] = (v[b] ^ v[c]) >> 24 | (v[b] ^ v[c]) << 40; x += v[b];
      v[a] += v[b] + in[(size_t)i * 16 + (r * 8 + s + 1) % 16]; x ^= v[a];
      v[d] = (v[d] ^ v[a]) >> 16 | (v[d] ^ v[a]) << 48; x += v[d];
      v[c] += v[d]; x ^= v[c];
      v[b] = (v[b] ^ v[c]) >> 63 | (v[b] ^ v[c]) << 1; x += v[b];
    }
  }
  out[i] = x;
}
__global__ void k_fieldmul(u64 *out, const u64 *a, const u64 *b, int n) {
  // Goldilocks p = 2^64 - 2^32 + 1: 128-bit product with special reduction
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  u64 x = a[i], y = b[i];
  // split into 32-bit halves for 64x64->128
  u64 x_lo = x & 0xFFFFFFFF, x_hi = x >> 32;
  u64 y_lo = y & 0xFFFFFFFF, y_hi = y >> 32;
  u64 ll = x_lo * y_lo, lh = x_lo * y_hi, hl = x_hi * y_lo, hh = x_hi * y_hi;
  // Goldilocks reduction: p = 2^64 - 2^32 + 1, so 2^64 ≡ 2^32 - 1
  u64 mid = lh + hl; if (mid < lh) mid += (1ULL << 32); // carry
  u64 result = ll + (mid << 32) - mid + hh * 4294967295ULL; // hh * (2^32 - 1)
  // additional reduction passes
  while (result >= 18446744069414584321ULL) result -= 18446744069414584321ULL;
  out[i] = result;
}
int main() {
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("device: %s sm_%d%d, %d SMs\n", p.name, p.major, p.minor, p.multiProcessorCount);
  const int N = 1 << 24; // 16M elements
  u64 *d_in, *d_out, *d_a, *d_b, *d_c;
  cudaMalloc(&d_in, (size_t)N * 16 * 8); cudaMalloc(&d_out, (size_t)N * 8);
  cudaMalloc(&d_a, (size_t)N * 8); cudaMalloc(&d_b, (size_t)N * 8); cudaMalloc(&d_c, (size_t)N * 8);
  cudaMemset(d_in, 0x42, (size_t)N * 16 * 8);
  cudaMemset(d_a, 0x42, (size_t)N * 8); cudaMemset(d_b, 0x43, (size_t)N * 8);
  cudaEvent_t t0, t1; cudaEventCreate(&t0); cudaEventCreate(&t1);
  int blocks = (N + 255) / 256;
  // warm-up
  k_blake2b<<<blocks, 256>>>(d_out, d_in, N);
  k_fieldmul<<<blocks, 256>>>(d_c, d_a, d_b, N);
  cudaDeviceSynchronize();
  // M-a: BLAKE2b instruction mix
  cudaEventRecord(t0);
  for (int r = 0; r < 10; r++) k_blake2b<<<blocks, 256>>>(d_out, d_in, N);
  cudaEventRecord(t1); cudaDeviceSynchronize();
  float ms_b; cudaEventElapsedTime(&ms_b, t0, t1);
  double bytes_b = (double)N * 128 * 10; // 128B block per element
  printf("M-a BLAKE2b mix: %.1f ms/10iter, throughput %.1f GB/s, %.1f M compress-equiv/s\n",
         ms_b, bytes_b / ms_b / 1e6, (double)N * 10 / ms_b / 1e3);
  // M-b: Goldilocks field mul
  cudaEventRecord(t0);
  for (int r = 0; r < 100; r++) k_fieldmul<<<blocks, 256>>>(d_c, d_a, d_b, N);
  cudaEventRecord(t1); cudaDeviceSynchronize();
  float ms_f; cudaEventElapsedTime(&ms_f, t0, t1);
  double ops_f = (double)N * 100;
  printf("M-b Goldilocks mul: %.1f ms/100iter, throughput %.1f G ops/s\n",
         ms_f, ops_f / ms_f / 1e6);
  printf("\nASIC sizing inputs:\n");
  printf("  commit hash: 2.75e11 compressions; at GPU rate = %.0f s; at 10x ASIC = %.0f s\n",
         2.75e11 / (N * 10 / ms_b / 1e3), 2.75e11 / (N * 10 / ms_b / 1e3 * 10));
  printf("  sumcheck field ops: ~12 GB data * ~3 ops/byte = 3.6e10; at GPU rate = %.0f s\n",
         3.6e10 / (ops_f / ms_f / 1e3));
  cudaFree(d_in); cudaFree(d_out); cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
  return 0;
}
