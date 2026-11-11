// gen_tree_kat.cpp — KAT generator for the FPGA Merkle builder, from the authoritative
// blocks/hash/hash.h: vertex() over a full binary tree of pseudorandom leaf digests under
// Domain::TREE_NODE with a nonzero tree start. Run from blocks/: gen_tree_kat
// (fpga/vectors/gen_tree_kat.cpp compiled with -I.).
#include "hash/hash.h"
#include <cstdio>
using namespace blk;

static u64 st = 0x243F6A8885A308D3ull;
static u64 rnd() { // splitmix64, test data only
  st += 0x9E3779B97F4A7C15ull;
  st = (st ^ (st >> 30)) * 0xBF58476D1CE4E5B9ull;
  st = (st ^ (st >> 27)) * 0x94D049BB133111EBull;
  return st ^ (st >> 31);
}
static void print_digest(const Digest &d) {
  for (int i = 0; i < 8; i++) printf("%08x ", d.w[i]);
}
int main() {
  Digest start;
  for (int i = 0; i < 8; i++) start.w[i] = (u32)rnd();
  Tag vt(Domain::TREE_NODE, 0, start);
  const int nleaf = 8;
  Digest cur[nleaf];
  printf("# Merkle KAT from hash.h vertex(): TREE_NODE=166, index 0, t=80, one F per vertex\n");
  printf("S %08x ", 166);           // the tree start, 8 u32
  print_digest(start);
  printf("\n");
  printf("L %d", nleaf);           // the 8 leaf digests
  for (int i = 0; i < nleaf; i++) {
    for (int j = 0; j < 8; j++) cur[i].w[j] = (u32)rnd();
    printf(" ");
    print_digest(cur[i]);
  }
  printf("\n");
  int n = nleaf;
  while (n > 1) {                  // one line per level, then the root
    for (int i = 0; i < n / 2; i++) cur[i] = vertex(vt, cur[2 * i], cur[2 * i + 1]);
    n /= 2;
    printf("V %d ", n);
    for (int i = 0; i < n; i++) {
      print_digest(cur[i]);
      printf("%s", i + 1 < n ? " " : "");
    }
    printf("\n");
  }
  printf("R ");
  print_digest(cur[0]);
  printf("\n");
  return 0;
}
