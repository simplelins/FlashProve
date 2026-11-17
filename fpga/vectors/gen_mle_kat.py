import random
random.seed(20261118)
P = 2**64 - 2**32 + 1
# E = F_p[x]/(x^3 - 2): the elements as (c0, c1, c2)
def e_mul(a, b):
    a0,a1,a2 = a; b0,b1,b2 = b
    return ((a0*b0 + 2*(a1*b2 + a2*b1)) % P,
            (a0*b1 + a1*b0 + 2*a2*b2) % P,
            (a0*b2 + a1*b1 + a2*b0) % P)
def e_add(a, b): return tuple((x+y) % P for x, y in zip(a, b))
def e_sub(a, b): return tuple((x-y) % P for x, y in zip(a, b))
E0, E1 = (0,0,0), (1,0,0)
def mle_eval(a, z):
    # z[0] belongs to the top bit of the index (verifier/tests topFirst)
    for c in z:
        half = len(a) // 2
        for x in range(half):
            a[x] = e_add(a[x], e_mul(c, e_sub(a[x+half], a[x])))
        a = a[:half]
    return a[0]
lines = ["# MLE evaluation KATs over E=x^3-2 (verifier's topFirst): a table of 2^N entries,",
         "# the challenges z[0..N-1] with z[0] at the top bit; per round a[x] += z_r*(a[x+half]-a[x])"]
for case, N in [(0, 3), (1, 4), (2, 6)]:
    table = [tuple(random.randrange(P) for _ in range(3)) for _ in range(1 << N)]
    z = [tuple(random.randrange(P) for _ in range(3)) for _ in range(N)]
    a = list(table)
    for c in z:
        half = len(a) // 2
        for x in range(half):
            a[x] = e_add(a[x], e_mul(c, e_sub(a[x+half], a[x])))
        a = a[:half]
    val = a[0]
    lines.append("C %d" % N)
    lines.append("T " + " ".join("%016x %016x %016x" % t for t in table))
    lines.append("Z " + " ".join("%016x %016x %016x" % c for c in z))
    lines.append("V %016x %016x %016x" % val)
open("/home/lww/project/06_zkp/FlashProve/fpga/vectors/mle_kat.txt", "w").write("\n".join(lines) + "\n")
print("wrote 3 cases (2^3, 2^4, 2^6)")
