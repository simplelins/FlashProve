#include <cstdio>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <vector>
int main() {
  cublasHandle_t h; cublasCreate(&h);
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("device: %s sm_%d%d\n", p.name, p.major, p.minor);
  std::vector<int8_t> A(416 * 64 + 256), B(4096 * 64 + 256), C((size_t)416 * 4096 + 256, 7);
  int8_t *dA, *dB; int *dC;
  cudaMalloc(&dA, A.size()); cudaMalloc(&dB, B.size()); cudaMalloc(&dC, C.size() * 4);
  int times = 1, beta = 0;
  auto run = [&](int m, int n, int k) {
    cublasStatus_t s = cublasGemmEx(h, CUBLAS_OP_T, CUBLAS_OP_N, m, n, k, &times,
        dA, CUDA_R_8I, k, dB, CUDA_R_8I, k, &beta, dC, CUDA_R_32I, m,
        CUBLAS_COMPUTE_32I, CUBLAS_GEMM_DEFAULT);
    printf("m%-4d n%-3d k%-3d -> %d\n", m, n, k, (int)s);
  };
  run(400, 2048, 408);   // ldc=408 (%16=8), m=400: predicts FAIL if ldc is the cause
  run(408, 2048, 416);   // ldc=416 (%16=0), m=408: predicts OK if ldc is the cause
  run(400, 2048, 400);
  run(408, 2048, 408);
  cublasDestroy(h);
  return 0;
}
