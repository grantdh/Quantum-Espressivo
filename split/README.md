# Splitting QE's GEMMs between Accelerate and the GPU: a prototype

**Question.** Does splitting Quantum ESPRESSO's large GEMMs between Accelerate (the CPU's matrix units)
and apple-bottom's GPU path make `pw.x` faster than the best CPU-only configuration on an M2 Max, with
the same physics?

At the GEMM level the split is measured: one GEMM split between the two engines ran 1.5–1.9× faster
than the faster engine alone on well-scaled data, and 1.23–1.28×, or not at all faster, where
apple-bottom's exponent-range guard sent the GPU's part to its host path (apple-bottom's
[hybrid-split results](https://github.com/grantdh/apple-bottom/blob/release/v1.5.0/benchmarks/results/2026-10-28-415cb5d-hybrid-split/README.md)).
This directory measures it inside full `pw.x` runs. The results are not in yet; the measurement
plan below was fixed before any run.

## The shim

`qe_split.c` is an object file linked into `pw.x` ahead of the BLAS libraries. It defines `zgemm_` and
`dgemm_`, so QE's calls reach it without any change to QE's source.

- **Calls it splits.** A call is split when `QE_SPLIT=1`, it does at least 0.5 GFLOP, and it falls in a
  shape class with a GPU share above 0:
  - **U**, `'N','N'` with M ≥ 2048: the Davidson updates, `s_psi` and `add_vuspsi` (M = npw).
    - UN splits the columns of C (N ≥ 256).
    - UM splits its rows (N < 256).
  - **R**, `'C','N'` with K ≥ 2048: the Davidson overlaps and `calbec` (K = npw).
    - RK splits the sum. The GPU's partial product goes into a scratch array, which is added to C
      after both parts finish.
- **Other calls** go straight to Accelerate.
- **Classes and shares.** Each class name carries the routine and a size bucket:
  - U by K, `k0` < 256 ≤ `k1` < 768 ≤ `k2`;
  - R by M·N, `t0` < 2¹⁶ ≤ `t1` < 2¹⁸ ≤ `t2`;
  - for example `zUN.k2` or `zRK.t2`.

  Each class has a fixed GPU share, set in `QE_SPLIT_F`. The GPU part is cut to a multiple of 32
  columns or rows, or 64 K indices.
- **Running both parts.**
  - The CPU part runs on the calling thread with `cblas_zgemm`, the entry point apple-bottom's own CPU
    path calls.
  - The GPU part runs at the same time on a worker thread with `ab_zgemm_blas`, apple-bottom's public
    BLAS entry point, through its staged path (`AB_MODE=gpu AB_MIN_GPU_DIM=0`).
  - The method is that of apple-bottom's `benchmarks/bench_split.c`.
- **Bits.** At a fixed share, a split computes the same bits from run to run, as apple-bottom's
  GEMM-level runs checked. Its result differs from either engine alone, by the GPU path's error on the
  GPU's part; the QE runs compare energies, not bits.
- **What it records.**
  - At exit, one line per class: calls, GFLOP, the seconds of each part, the rates both engines
    reached together, and the share that would have balanced them (`QE_SPLIT_REPORT=1`).
  - Optionally, one line per split call (`QE_SPLIT_LOG`). Joined with apple-bottom's `AB_TRACE`,
    those lines say where each GPU part ran: staged, the host path, or Accelerate.

The comment at the top of `qe_split.c` lists every environment variable. `test_split.c` checks every
split shape against one cblas call: with `AB_MODE=cpu` for the split's arithmetic, and with
`AB_MODE=gpu AB_MIN_GPU_DIM=0` on the GPU.

## Files

| file | what it does |
|---|---|
| `qe_split.c` | the shim |
| `test_split.c`, `Makefile` | its test; `make AB_INC=… AB_LIB=… test` |
| `build-qe.sh` | builds QE's `pw.x` once and links it twice: `pw.x.cpu`, linked to apple-bottom as its integration guide does, and `pw.x.split`, the same objects with the shim in front; records `PROVENANCE.txt` |
| `run.sh` | runs plans of configurations alternately on AC power and writes `results.csv` (after apple-bottom's `benchmarks/qe/run_campaign.sh`) |
| `calibrate.py` | the next share per class, from the rates both engines reached in QE runs |
| `campaign.sh` | the whole measurement: build, GPU test, calibration, timing, tables |
| `analyze.py` | the tables: wall times, physics against the CPU runs, per-class statistics, where the GPU parts ran |

## Measurement plan

- **QE.** A fresh clone of QE's `develop` branch, built once (configure's `-O3`, with the edits of
  apple-bottom's 1.5.0 QE release check), with `pw.x` linked with and without the shim. Each binary is
  compared only with the other one from the same build.
- **Library.**
  - apple-bottom at 415cb5d, release/v1.5.0 when the GEMM-level split and the 1.5.0 QE release check
    were measured. 1.5.0 is not tagged yet.
  - As a second, separately calibrated configuration, the staged-path fix of apple-bottom PR #16. That
    fix keeps on the staged path the ZGEMMs that 1.5.0 sends to the host path.
  - The shim calls only the public API.
- **Inputs.** apple-bottom's si64 inputs A (500 bands) and B (160 bands), k-points 2×2×2, PAW, from its
  `benchmarks/qe/inputs/`.
- **Layouts.**
  - 8 ranks × 1 thread, `-nk 4`: the best CPU-only layout.
  - 4 ranks × 2 threads, `-nk 4`.
  - Both run with `OMP_NUM_THREADS=1`, because threaded FFTW plans make this build slow at more
    OpenMP threads. Accelerate gets `VECLIB_MAXIMUM_THREADS` threads.
- **Calibration, in QE.** The shares come from `pw.x` runs, where both engines run together for
  minutes, not from each engine's rate alone. In apple-bottom's sustained runs the split's wall power
  fell from about 127 W to 99–106 W after the first 10–20 s, and the GPU clock with it.
  - Start from the GEMM-level best shares: UN 0.51, UM 0.50, RK 0.55.
  - Per layout, run A and B. Move each class's share 70% of the way to the share that would have
    balanced the two parts at the rates measured in those runs.
  - Repeat three times, then freeze the table.
  - **Physics gate.** The first split runs must match the runs with every call on Accelerate:
    final energy within 1e-5 Ry and SCF iterations within 2. Otherwise nothing is timed.
- **Timing.**
  - Three rounds. Each round has one block per input and layout, and each block is one hold of an
    exclusive machine lock.
  - The configurations alternate inside a block, in an order that changes from round to round.
  - 8 × 1 blocks: Accelerate (`pw.x.cpu`, `AB_MODE=cpu`), the split, the split with the fix, the shim
    passing every call to Accelerate, and the library's own GPU mode.
  - 4 × 2 blocks: the same splits and Accelerate, plus Accelerate at 8 × 1.
  - Medians with ranges over the rounds.
- **Conditions.** AC power is checked inside the lock before and after every run. `pmset` and the load
  are recorded with every run, and the power every 20 s during each block.

## Running it

```bash
QE_DIR=/path/to/q-e AB_LIB=/path/to/frozen/apple-bottom AB_INC=/path/to/apple-bottom/include \
INPUTS=/path/to/apple-bottom/benchmarks/qe/inputs PSEUDO_DIR=/path/to/pseudo OUT=/path/to/out \
split/campaign.sh
```

- **Optional variables.**
  - `AB_LIB_FIX` adds the second library.
  - `LOCK_BUILD` and `LOCK_BENCH` take prefix commands for a machine lock, shared for builds and
    exclusive for benchmark blocks.
  - `REPS` and `CAL_ITERS` set the timing rounds and calibration iterations.
- **Resuming.** Rerunning the campaign continues where it stopped.
- **Tables.** They go to `$OUT/tables-*.md`.
