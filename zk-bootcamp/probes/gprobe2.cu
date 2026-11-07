#include <cstdio>
#include <cublas_v2.h>
#include <cublasLt.h>
#include <cuda_runtime.h>
#include <vector>
using i8 = signed char;
static int cpu_ref(int m, int n, int k, const std::vector<i8> &A, size_t ld, const std::vector<i8> &B,
                   std::vector<int> &C, size_t ldc, int batch, size_t step, size_t cstep) {
  int mx = 0;
  for (int b = 0; b < batch; b++)
    for (int j = 0; j < n; j++)
      for (int i = 0; i < m; i++) {
        long long s = 0;
        for (int c = 0; c < k; c++)
          s += (long long)A[b * step + (size_t)i * ld + c] * B[b * step + (size_t)j * ld + c];
        C[b * cstep + (size_t)j * ldc + i] = (int)s;
        if (s > mx) mx = (int)s; if (-s > mx) mx = (int)-s;
      }
  return mx;
}
static bool verify(const std::vector<int> &C, const std::vector<int> &ref, int batch, int m, int n, size_t ldc) {
  size_t bad = 0;
  for (int b = 0; b < batch; b++)
    for (int j = 0; j < n; j++)
      for (int i = 0; i < m; i++)
        if (C[b * m * n + (size_t)j * m + i] != ref[b * m * n + (size_t)j * m + i]) bad++;
  printf("   -> mismatches %zu\n", bad);
  return bad == 0;
}
int main() {
  const int m = 192, n = 128, k = 512, batch = 4;
  size_t ld = (size_t)k, step = (size_t)m * k;
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("device: %s sm_%d%d — m %d n %d k %d batch %d\n", p.name, p.major, p.minor, m, n, k, batch);
  std::vector<i8> A((size_t)batch * step + 256), B((size_t)batch * (size_t)n * k + 256);
  srand(11);
  for (auto &x : A) x = (i8)(rand() % 256 - 128);
  for (auto &x : B) x = (i8)(rand() % 256 - 128);
  std::vector<int> C((size_t)batch * m * n), ref(C.size());
  cpu_ref(m, n, k, A, ld, B, ref, m, batch, step, (size_t)m * n);
  i8 *dA, *dB; int *dC;
  cudaMalloc(&dA, A.size()); cudaMalloc(&dB, B.size()); cudaMalloc(&dC, C.size() * 4);
  cudaMemcpy(dA, A.data(), A.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dB, B.data(), B.size(), cudaMemcpyHostToDevice);
  void *ws; cudaMalloc(&ws, 64u << 20);
  cublasLtHandle_t lt; cublasLtCreate(&lt);
  cublasLtMatmulDesc_t op; cublasOperation_t trT = CUBLAS_OP_T, no = CUBLAS_OP_N;
  cublasLtMatmulDescCreate(&op, CUBLAS_COMPUTE_32I, CUDA_R_32I);
  cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSA, &trT, sizeof trT);
  cublasLtMatmulDescSetAttribute(op, CUBLASLT_MATMUL_DESC_TRANSB, &no, sizeof no);
  cublasLtMatrixLayout_t La, Lb, Lc;
  cublasLtMatrixLayoutCreate(&La, CUDA_R_8I, k, m, ld);
  cublasLtMatrixLayoutCreate(&Lb, CUDA_R_8I, k, n, ld);
  cublasLtMatrixLayoutCreate(&Lc, CUDA_R_32I, m, n, m);
  const int32_t bc = batch; const int64_t sa = (int64_t)step, sc = (int64_t)m * n;
  for (cublasLtMatrixLayout_t y : {La, Lb, Lc})
    cublasLtMatrixLayoutSetAttribute(y, CUBLASLT_MATRIX_LAYOUT_BATCH_COUNT, &bc, sizeof bc);
  cublasLtMatrixLayoutSetAttribute(La, CUBLASLT_MATRIX_LAYOUT_STRIDED_BATCH_OFFSET, &sa, sizeof sa);
  cublasLtMatrixLayoutSetAttribute(Lb, CUBLASLT_MATRIX_LAYOUT_STRIDED_BATCH_OFFSET, &sa, sizeof sa);
  cublasLtMatrixLayoutSetAttribute(Lc, CUBLASLT_MATRIX_LAYOUT_STRIDED_BATCH_OFFSET, &sc, sizeof sc);
  int32_t one = 1, zero = 0;
  // 1. zero-workspace heuristic (the failing configuration)
  cublasLtMatmulPreference_t pref; cublasLtMatmulPreferenceCreate(&pref);
  const uint64_t no_ws = 0;
  cublasLtMatmulPreferenceSetAttribute(pref, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES, &no_ws, sizeof no_ws);
  cublasLtMatmulHeuristicResult_t heur; int got = 0;
  cublasLtMatmulAlgoGetHeuristic(lt, op, La, Lb, Lc, Lc, pref, 1, &heur, &got);
  cublasLtMatmul(lt, op, &one, dA, La, dB, Lb, &zero, dC, Lc, dC, Lc, &heur.algo, nullptr, 0, 0);
  cudaMemcpy(C.data(), dC, C.size() * 4, cudaMemcpyDeviceToHost);
  printf("[1] zero-ws heuristic:"); verify(C, ref, batch, m, n, m);
  // 2. heuristic with 64 MiB workspace
  const uint64_t ws64 = 64u << 20;
  cublasLtMatmulPreferenceSetAttribute(pref, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES, &ws64, sizeof ws64);
  cublasLtMatmulAlgoGetHeuristic(lt, op, La, Lb, Lc, Lc, pref, 1, &heur, &got);
  printf("[2] 64MiB-ws heuristic: found %d, ws %zu\n", got, (size_t)heur.workspaceSize);
  cublasLtMatmul(lt, op, &one, dA, La, dB, Lb, &zero, dC, Lc, dC, Lc, &heur.algo, ws, 64u << 20, 0);
  cudaMemcpy(C.data(), dC, C.size() * 4, cudaMemcpyDeviceToHost);
  printf("[2] 64MiB-ws heuristic:"); verify(C, ref, batch, m, n, m);
  // 3. top-8 zero-ws algorithms, verified one by one
  cublasLtMatmulHeuristicResult_t hs[8]; int got8 = 0;
  cublasLtMatmulAlgoGetHeuristic(lt, op, La, Lb, Lc, Lc, pref, 8, hs, &got8);
  printf("[3] top-8 zero-ws: found %d\n", got8);
  for (int i = 0; i < got8; i++) {
    cublasLtMatmul(lt, op, &one, dA, La, dB, Lb, &zero, dC, Lc, dC, Lc, &hs[i].algo, nullptr, 0, 0);
    cudaMemcpy(C.data(), dC, C.size() * 4, cudaMemcpyDeviceToHost);
    printf("   algo#%d (ws %zu):", i, (size_t)hs[i].workspaceSize);
    if (!verify(C, ref, batch, m, n, m)) break;
  }
  // 4. cublasGemmEx classic path
  cublasHandle_t h; cublasCreate(&h);
  cublasStatus_t s4 = cublasGemmEx(h, CUBLAS_OP_T, CUBLAS_OP_N, m, n, k, &one, dA, CUDA_R_8I, k,
      dB, CUDA_R_8I, k, &zero, dC, CUDA_R_32I, m, CUBLAS_COMPUTE_32I, CUBLAS_GEMM_DEFAULT);
  cudaMemcpy(C.data(), dC, C.size() * 4, cudaMemcpyDeviceToHost);
  printf("[4] cublasGemmEx -> %d:", (int)s4);
  size_t bad0 = 0;
  for (int j = 0; j < n; j++) for (int i = 0; i < m; i++)
    if (C[(size_t)j * m + i] != ref[(size_t)j * m + i]) bad0++;
  printf("   b0 mismatches %zu / %d\n", bad0, m * n);
  cublasLtDestroy(lt); cublasDestroy(h);
  return 0;
}
