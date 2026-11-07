#include <cstdio>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <vector>
static void probe(int m, int n, int k, size_t lda, size_t ldb, size_t ldc, const char *tag) {
  std::vector<int8_t> A((size_t)m * lda + 64), B((size_t)n * ldb + 64), C((size_t)m * ldc + 64, 7);
  int8_t *dA, *dB; int *dC;
  if (cudaMalloc(&dA, A.size()) || cudaMalloc(&dB, B.size()) || cudaMalloc(&dC, C.size() * 4)) { printf("%-34s -> cudaMalloc FAILED\n", tag); return; }
  cudaMemcpy(dA, A.data(), A.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dB, B.data(), B.size(), cudaMemcpyHostToDevice);
  int times = 1, beta = 0;
  cublasHandle_t h; cublasCreate(&h);
  cublasStatus_t s = cublasGemmEx(h, CUBLAS_OP_T, CUBLAS_OP_N, m, n, k, &times, dA, CUDA_R_8I, (int)lda,
      dB, CUDA_R_8I, (int)ldb, &beta, dC, CUDA_R_32I, (int)ldc, CUBLAS_COMPUTE_32I, CUBLAS_GEMM_DEFAULT);
  printf("%-40s -> %d\n", tag, (int)s);
  cudaFree(dA); cudaFree(dB); cudaFree(dC); cublasDestroy(h);
}
int main() {
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("device: %s sm_%d%d\n", p.name, p.major, p.minor);
  probe(400, 2048, 16, 16, 16, 408, "m400 n2048 k16 ldc408 (%16=8)");
  probe(408, 2048, 16, 16, 16, 416, "m408 n2048 k16 ldc416 (%16=0)");
  probe(400, 2048, 16, 16, 16, 400, "m400 n2048 k16 ldc400 (control)");
  probe(408, 2048, 16, 16, 16, 408, "m408 n2048 k16 ldc408 (cp_commit shape)");
  probe(400, 2048, 16, 16, 16, 410, "m400 n2048 k16 ldc410 (%16=10)");
  return 0;
}
