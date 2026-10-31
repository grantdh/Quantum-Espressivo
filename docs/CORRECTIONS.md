# Corrections

Results this repository used to report that have since been withdrawn, and why. The withdrawn files and
text remain in the git history. These documents are kept for the record with a dated status note:
`docs/QE75_INTEGRATION.md`, `docs/MERGE_STRATEGY.md`, `docs/HANDLE_RESIDENCY_AUDIT.md` and
`benchmarks/si64_scf/DESIGN.md`.

## October 2026: Si64 "22% faster, 11 decimal places, 47% less CPU" (withdrawn)

Since April 2026 the
[README](https://github.com/grantdh/Quantum-Espressivo/blob/94209083c364e222950e208fc750c91e08ef9c8b/README.md)
had reported a 64-atom silicon SCF run taking 2:01 with apple-bottom against 2:28 with 6-thread OpenBLAS,
with total energies agreeing to 11 decimal places and 47% less CPU use. The same figures appeared in
`docs/QE75_INTEGRATION.md`, `docs/MERGE_STRATEGY.md` and `benchmarks/si64_scf/DESIGN.md`.

Neither run used the GPU. apple-bottom 1.0–1.3 set up the GPU only in `ab_init()`, which no QE build
called, so every GEMM ran on the CPU while the library's profiler still counted the calls as GPU calls.
The timing difference came from comparing a serial QE build with an MPI build. apple-bottom has withdrawn
the same result and repeated the validation with builds that do use the GPU: see
[VAL-1](https://github.com/grantdh/apple-bottom/blob/main/tests/validation/VAL001_QE_Si64.md). The README
now points to those measurements.

## October 2026: "ULP Fiction" draft paper (withdrawn; never submitted)

[`docs/ulp-fiction-hpec2026.tex`](https://github.com/grantdh/Quantum-Espressivo/blob/0fa8850a615d7a9ff4cdac05f81cf5bde1710dd9/docs/ulp-fiction-hpec2026.tex)
and
[`docs/ulp-fiction-hpec2026.pdf`](https://github.com/grantdh/Quantum-Espressivo/blob/0fa8850a615d7a9ff4cdac05f81cf5bde1710dd9/docs/ulp-fiction-hpec2026.pdf),
added on 18 April 2026 in commit
[`0fa8850`](https://github.com/grantdh/Quantum-Espressivo/commit/0fa8850a615d7a9ff4cdac05f81cf5bde1710dd9),
were a draft for HPEC 2026. They were removed from the tree for these reasons:

- **QE result.** The draft reported a 1.06× speedup on Si64 "on an Apple M2 Pro" (457.9 s against
  430.5 s). The runs were made on an M2 Max with apple-bottom 1.3 and no `ab_init()` call, so, as above,
  both builds ran on the CPU. Neither timing appears in the benchmark output we kept.
- **DGEMM.** "643 GFLOP/s, 23% faster than Accelerate" is more than the draft's own table shows (at most
  1.20×). apple-bottom withdrew the 643 GFLOP/s headline in 1.4.0 (see its
  [corrected claims](https://github.com/grantdh/apple-bottom/blob/v1.4.0/CHANGELOG.md#corrected-claims)).
  The measurement it published with 1.4.0
  ([data](https://github.com/grantdh/apple-bottom/tree/v1.4.0/benchmarks/results/2026-10-14-3253a22-bench-paper)),
  with the matrices already on the GPU, gives 1.04–1.16× for N = 1536–4096 and is slower than Accelerate
  below that.
- **ZGEMM.** The "43% speedup over AMX" held only with the matrices already on the GPU (1.12–1.39× for
  N = 1024–3072 in the same measurement). Through the BLAS interface that QE uses, apple-bottom 1.4.0's
  ZGEMM was slower than Accelerate for QE's shapes.
- **metal-float64.** The "27× throughput advantage" compares against an unfinished library that has no
  GEMM. apple-bottom withdrew the same comparison in 1.4.0 (same list).
- **Persistent matrices.** "24% net speedup after just 7 iterations" was computed from single-call
  timings, not measured. Seven iterations is the computed break-even point, and 24% the limit after many
  iterations.
- **Accuracy.** "Relative errors below 10⁻¹⁵" is not borne out by that 1.4.0 measurement, which gives
  normwise relative errors of 1.8×10⁻¹⁴ to 5.1×10⁻¹⁴ for N = 512–4096.
- **Error threshold.** The threshold formula in the draft's Section 7 rejects the case it was introduced
  to accept.
- **PDF.** The PDF was built from an earlier version of the source. It is dated 5 April and states a
  different error bound for double-float multiplication from the one in the `.tex`.

Later measurements of the library are in apple-bottom's
[README](https://github.com/grantdh/apple-bottom#performance).
