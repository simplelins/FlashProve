// Numerical cross-check of the native cublasLt int8 path on sm_89 for the gram shapes:
// C[i] = A[i] B[i]^T, A m x k row-major, B n x k row-major, batch, ld bytes.
#include <cstdio>
#include <cublas_v2.h>
#include <cublasLt.h>
#include <cuda_runtime.h>
#include <vector>
using u8 = unsigned char; using u64 = unsigned long long; using i8 = signed char;
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
int main(int argc, char **argv) {
  int m = argc > 1 ? atoi(argv[1]) : 192, n = argc > 2 ? atoi(argv[2]) : 128,
      k = argc > 3 ? atoi(argv[3]) : 512, batch = argc > 4 ? atoi(argv[4]) : 4;
  size_t ld = (size_t)k, step = (size_t)m * k; // A row-major m x k with ld=k; same B
  cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
  printf("device: %s sm_%d%d — m %d n %d k %d batch %d ld %zu\n", p.name, p.major, p.minor, m, n, k, batch, ld);
  std::vector<i8> A((size_t)batch * step + 256), B((size_t)batch * (size_t)n * k + 256);
  srand(11);
  for (auto &x : A) x = (i8)(rand() % 256 - 128);
  for (auto &x : B) x = (i8)(rand() % 256 - 128);
  std::vector<int> C((size_t)batch * m * n, -1), ref(C.size());
  int mx = cpu_ref(m, n, k, A, ld, B, ref, m, batch, (size_t)m * n, (size_t)m * n);
  printf("CPU reference done, max |sum| %d\n", mx);
  i8 *dA, *dB; int *dC;
  cudaMalloc(&dA, A.size()); cudaMalloc(&dB, B.size()); cudaMalloc(&dC, C.size() * 4);
  cudaMemcpy(dA, A.data(), A.size(), cudaMemcpyHostToDevice);
  cudaMemcpy(dB, B.data(), B.size(), cudaMemcpyHostToDevice);
  // cublasLt native path, zero workspace (the same as gram_products.cuh)
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
  cublasLtMatmulPreference_t pref; cublasLtMatmulPreferenceCreate(&pref);
  const uint64_t no_ws = 0;
  cublasLtMatmulPreferenceSetAttribute(pref, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES, &no_ws, sizeof no_ws);
  cublasLtMatmulHeuristicResult_t heur; int got = 0;
  cublasStatus_t hs = cublasLtMatmulAlgoGetHeuristic(lt, op, La, Lb, Lc, Lc, pref, 1, &heur, &got);
  printf("heuristic -> %d, found %d, state %d, ws %zu\n", (int)hs, got, (int)heur.state, (size_t)heur.workspaceSize);
  int32_t one = 1, zero = 0;
  cublasStatus_t ms = cublasLtMatmul(lt, op, &one, dA, La, dB, Lb, &zero, dC, Lc, dC, Lc, &heur.algo, nullptr, 0, 0);
  printf("cublasLtMatmul -> %d\n", (int)ms);
  cudaMemcpy(C.data(), dC, C.size() * 4, cudaMemcpyDeviceToHost);
  size_t bad = 0; int firstb = -1, firstw = -1, devv = 0, refv = 0;
  for (int b = 0; b < batch && bad < 3; b++)
    for (int j = 0; j < n && bad < 3; j++)
      for (int i = 0; i < m && bad < 3; i++)
        if (C[b * m * n + (size_t)j * m + i] != ref[b * m * n + (size_t)j * m + i]) {
          bad++;
          if (firstb < 0) { firstb = b; firstw = j * m + i; devv = C[b * m * n + (size_t)j * m + i]; refv = ref[b * m * n + (size_t)j * m + i]; }
        }
  printf("native cublasLt mismatches: %zu%s\n", bad, bad ? "" : " (values match CPU)");
  if (bad) printf("  first: batch %d word %d: dev %d ref %d\n", firstb, firstw, devv, refv);
  cublasLtDestroy(lt);
  return bad != 0 || ms != 0;
}
