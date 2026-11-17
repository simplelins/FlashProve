// gen_fold_kat.cpp — KAT generator for the FPGA FOLD round engine, from the authoritative
// blocks/iop (fold_algebra.h + fold_rounds.h + hp.h). A small fold: k = 4 variables, h = 2
// mask-fold rounds, tables of 2^h rows x LENZK = 8 coefficients (base field, column-major:
// entry c of row b at index b + 2^h c). Dumps the inputs and each round's 3 coefficients.
// Run from blocks/: gen_fold_kat (compiled with -DBLK_FIELD=2 -I.).
#include "field/field.h"
#include "iop/fold_algebra.h"
#include "iop/fold_rounds.h"
#include "iop/hp.h"
#include <cstdio>
#include <vector>
using namespace blk;
using K = blk::F;

static u64 st = 0x243F6A8885A308D3ull;
static u64 rnd() {
  st += 0x9E3779B97F4A7C15ull;
  st = (st ^ (st >> 30)) * 0xBF58476D1CE4E5B9ull;
  st = (st ^ (st >> 27)) * 0x94D049BB133111EBull;
  return st ^ (st >> 31);
}
static K rk() { return K{(rnd() >> 32) % 0xffff000000000000ull + 1ull}; }
static void pk(const K &x) { printf("%016llx ", (unsigned long long)x.v); }

int main() {
  const unsigned k = 4, h = 2, LENZK = 8;
  const K eps = rk(), kept0 = rk();
  const std::vector<Weight<K>> vars = fold_mask_variables<K>(k);
  std::vector<K> w(hp_entries(vars));
  for (K &x : w) x = rk();
  std::vector<K> d((size_t(1) << h) * LENZK), mu(d.size());
  for (K &x : d) x = rk();
  for (K &x : mu) x = rk();
  std::vector<K> fresh(d.size());  // folds too; it does not enter the round messages
  for (K &x : fresh) x = rk();

  printf("# FOLD round KATs from blocks/iop (fold_rounds.h + fold_algebra.h + hp.h), base field\n");
  printf("S %d %d %d ", k, h, LENZK);
  pk(eps); pk(kept0);
  for (const K &x : w) pk(x);
  printf("\n");
  printf("D ");
  for (const K &x : d) pk(x);
  printf("\nM ");
  for (const K &x : mu) pk(x);
  printf("\n");

  HidingPolynomial<K> hp(fold_mask_variables<K>(k), w);
  FoldProverRounds<K> prover(k, h, LENZK, w, d, mu, kept0);
  prover.start(eps);
  K kept = kept0, later = K::one();
  std::vector<K> dm = d, mm = mu;
  for (unsigned j = 0; j < k; j++) {
    const std::vector<K> main_part = {rk(), rk(), rk()};
    const std::vector<K> q = prover.round(main_part);
    const K g = rk();
    std::vector<K> msk(3, K::zero());
    if (j < h) msk = pair_products(dm, mm);
    else {
      K inner = K::zero();
      for (size_t i = 0; i < LENZK; i++) inner = inner + dm[i] * mm[i];
      msk[1] = inner * later;
    }
    printf("X ");
    for (const K &x : msk) pk(x);
    printf("\n");
    printf("R ");
    pk(g);
    for (const K &x : main_part) pk(x);
    for (const K &x : q) pk(x);
    printf("\n");
    prover.bind(g);
    if (j < h) {
      fold_low_once(dm, g);
      fold_low_once(mm, g);
      fold_low_once(fresh, g);
      printf("F ");
      printf("%zu ", dm.size());
      for (const K &x : dm) pk(x);
      printf("\nG ");
      printf("%zu ", mm.size());
      for (const K &x : mm) pk(x);
      printf("\n");
    } else {
      later = later * g;
    }
    kept = kept * (K::one() - g);
    (void)later;
  }
  const FoldMaskEnd<K> e = prover.end();
  printf("E ");
  for (const K &x : e.mu) pk(x);
  printf("\n");
  return 0;
}
