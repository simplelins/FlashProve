#include <cstdio>
using u64 = unsigned long long;
#include <cuda_runtime.h>
#include <vector>
#include "hash/hash.h"   // -I blocks
__global__ void k_vertex(blk::Digest *out, const blk::Digest *lr, const blk::Digest start, int count) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < count) {
    blk::Tag tag(blk::Domain::TREE_NODE, 0, start);
    out[i] = blk::vertex(tag, lr[2 * i], lr[2 * i + 1]);
  }
}
int main() {
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("device: %s sm_%d%d\n", p.name, p.major, p.minor);
  const int N = 512;
  std::vector<blk::Digest> lr(2 * N), host_out(N);
  srand(7);
  for (auto &d : lr) for (int i = 0; i < 8; i++) d.w[i] = ((u64)rand() << 32) ^ rand();
  blk::Digest start{};
  for (int i = 0; i < 8; i++) start.w[i] = ((u64)rand() << 32) ^ rand();
  // host reference
  for (int i = 0; i < N; i++) {
    blk::Tag tag(blk::Domain::TREE_NODE, 0, start);
    host_out[i] = blk::vertex(tag, lr[2 * i], lr[2 * i + 1]);
  }
  blk::Digest *dlr, *dout; blk::Digest dstart = start;
  cudaMalloc(&dlr, lr.size() * 32); cudaMalloc(&dout, (size_t)N * 32);
  cudaMemcpy(dlr, lr.data(), lr.size() * 32, cudaMemcpyHostToDevice);
  k_vertex<<<(N + 127) / 128, 128>>>(dout, dlr, dstart, N);
  cudaError_t e = cudaGetLastError();
  std::vector<blk::Digest> dev_out(N);
  cudaMemcpy(dev_out.data(), dout, (size_t)N * 32, cudaMemcpyDeviceToHost);
  int bad = 0; int first = -1;
  for (int i = 0; i < N; i++)
    for (int w = 0; w < 8; w++)
      if (dev_out[i].w[w] != host_out[i].w[w]) { bad++; if (first < 0) { first = i; printf("first mismatch at i %d word %d: dev %016llx host %016llx\n", i, w, (unsigned long long)dev_out[i].w[w], (unsigned long long)host_out[i].w[w]); } break; }
  printf("device: %s sm_%d%d — vertex mismatches: %d of %d\n", p.name, p.major, p.minor, bad, N);
  cudaFree(dlr); cudaFree(dout);
  return bad != 0;
}
