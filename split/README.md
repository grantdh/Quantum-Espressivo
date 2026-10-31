# Splitting QE's GEMMs between Accelerate and the GPU: a prototype

**Question.** Does splitting Quantum ESPRESSO's large GEMMs between Accelerate (the CPU's matrix units)
and apple-bottom's GPU path make `pw.x` faster than the best CPU-only configuration on an M2 Max, with
the same physics?

**Answer, for the two inputs measured: yes.** At 8 ranks × 1 thread, the best CPU-only layout, the split
made `pw.x` 1.17–1.20× faster with apple-bottom at 415cb5d and 1.21–1.25× faster with apple-bottom
1.5.0's library (medians of three rounds; at that layout every split run beat every Accelerate run).
1.5.0 gains more because it keeps on its staged path GPU parts that 415cb5d sends to its slower host
path. Every run printed the same energies, SCF iterations and band energies as the Accelerate run with
the same layout. At 4 ranks × 2 threads the split beat Accelerate at 4 × 2 (1.09–1.14×) but not at
8 × 1 (0.91–0.98×). apple-bottom's GPU mode on its own (415cb5d) ran at 0.85–0.86× Accelerate's speed.

At the GEMM level the split was measured before: one GEMM split between the two engines ran 1.5–1.9×
faster than the faster engine alone on well-scaled data, and 1.23–1.28×, or not at all faster, where
apple-bottom's exponent-range guard sent the GPU's part to its host path (apple-bottom's
[hybrid-split results](https://github.com/grantdh/apple-bottom/blob/v1.5.0/benchmarks/results/2026-10-28-415cb5d-hybrid-split/README.md)).
Those runs used apple-bottom at 415cb5d and were not repeated with 1.5.0. This directory measures the
split inside full `pw.x` runs, by a plan written before any run. One thing changed since: which build
of the second library the runs used (see **Libraries**).

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
- **Other calls** go straight to Accelerate, and so do DGEMMs unless `QE_SPLIT_DGEMM=1`; the runs
  below did not set it.
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
  - apple-bottom's staged path converts the operands to double-float on the GPU. Calls the library
    does not keep on it go to its host path, which converts them on the CPU and is slower, or, when
    its exponent-range guard refuses them, to Accelerate.
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
| `build-qe.sh` | builds QE's `pw.x` once and links it twice: `pw.x.cpu`, linked to apple-bottom as its integration guide does, and `pw.x.split`, the same objects with the shim in front; with `AB_LIB_FIX`, also `pw.x.fix`, `pw.x.split` with its rpath pointed at that library; records `PROVENANCE.txt` |
| `run.sh` | runs plans of configurations alternately on AC power and writes `results.csv` (after apple-bottom's `benchmarks/qe/run_campaign.sh`) |
| `calibrate.py` | the next share per class, from the rates both engines reached in QE runs |
| `campaign.sh` | the whole measurement: build, GPU test, calibration, timing, tables |
| `analyze.py` | the tables: wall times, physics against the CPU runs, per-class statistics, where the GPU parts ran |
| `data/2026-10-31/` | the measurement below: `analyze.py`'s tables (`tables-*.md`), the timing runs' rows of `results.csv` (`results-time.csv`), the calibrated shares (`shares-*.txt`), the build record (`PROVENANCE.txt`) and the GPU test (`gpu-test.txt`); local paths are replaced by the scripts' variable names or placeholders |

## Measurement plan

- **QE.** A fresh clone of QE's `develop` branch, built once (configure's `-O3`, with the edits of
  apple-bottom's 1.5.0 QE release check), with `pw.x` linked with and without the shim. Each binary is
  compared only with the other one from the same build.
- **Libraries.** Two, each calibrated on its own:
  - apple-bottom at 415cb5d, where the GEMM-level split and the 1.5.0 QE release check were measured.
  - apple-bottom 1.5.0's library (its build is under **Provenance**). It carries the fix of
    apple-bottom [PR #16](https://github.com/grantdh/apple-bottom/pull/16), which keeps scaled lines
    and 4M ZGEMMs on the staged path; 415cb5d sends them to the host path.
  - The plan named PR #16's fix before 1.5.0 was tagged, and the campaign first used it as first
    committed (351d56c). It moved to 1.5.0's library when 1.5.0 was tagged, after the first library's
    calibration and before any measurement with the second.
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
  - 8 × 1 blocks: Accelerate (`pw.x.cpu`, `AB_MODE=cpu`), the split with each library, the shim
    passing every call to Accelerate, and 415cb5d's own GPU mode.
  - 4 × 2 blocks: the same splits and Accelerate, plus Accelerate at 8 × 1.
  - Medians with ranges over the rounds.
- **Conditions.** AC power is checked inside the lock before and after every run. `pmset` and the load
  are recorded with every run, and the power source every 20 s during each block.

## Results

Measured on 2026-10-31 by `campaign.sh` from this directory at d5b4e41. All 28 calibration runs and 54
timing runs ended normally, and none was redone. One more calibration run, with 351d56c, was stopped
after 27 s when that library was replaced. The files in `data/2026-10-31/` use `campaign.sh`'s
configuration names (its header lists them): `split` is the split with 415cb5d, `fix` the split with
1.5.0's library. The run directories (QE output, traces, logs) are not in the repository, so the
tables cannot be regenerated from those files.

### Wall time

Seconds, median [min–max] of three runs, and the speedup: the Accelerate runs' median over this
configuration's.

8 × 1 blocks:

| input | Accelerate | split, 415cb5d | split, 1.5.0 | shim, every call on Accelerate | GPU mode, 415cb5d |
|---|---|---|---|---|---|
| A, 500 bands | 105.60 [99.82–107.49] | 88.10 [86.31–92.00], 1.20× | 84.19 [83.57–84.58], 1.25× | 103.12 [101.26–105.54], 1.02× | 122.14 [119.20–125.28], 0.86× |
| B, 160 bands | 55.21 [54.88–59.55] | 47.22 [45.31–47.93], 1.17× | 45.68 [45.13–46.81], 1.21× | 55.65 [54.45–57.77], 0.99× | 64.91 [64.88–66.51], 0.85× |

4 × 2 blocks, with speedups over Accelerate at 4 × 2 and at 8 × 1:

| input | Accelerate, 8 × 1 | Accelerate, 4 × 2 | split, 415cb5d | split, 1.5.0 |
|---|---|---|---|---|
| A, 500 bands | 99.45 [97.27–105.27] | 115.92 [115.66–119.81] | 106.65 [105.67–107.65], 1.09×, 0.93× | 101.69 [100.91–102.65], 1.14×, 0.98× |
| B, 160 bands | 56.23 [55.65–56.49] | 68.58 [68.41–69.28] | 61.73 [61.59–62.20], 1.11×, 0.91× | 61.15 [60.95–62.59], 1.12×, 0.92× |

- Accelerate at 8 × 1 varied most from run to run: 97.27–107.49 s over its six runs of A. The slowest
  split run at 8 × 1 still beat the fastest of them, by 6% (415cb5d, A) to 17% (1.5.0, B).
- The shim itself costs nothing measurable: with every call on Accelerate it stayed within the
  Accelerate runs' spread.
- The split leaves the FFTs alone. QE's `fftw` timer read about 28 s (A) and 12 s (B) in every 8 × 1
  configuration, a third of the 1.5.0 split's wall time on A.
- At 4 × 2 only Accelerate uses the second thread; the FFTs run on four single-threaded ranks. On A
  they took 37 s, against 27 s for Accelerate at 8 × 1 in the same blocks: most of the 16 s that
  Accelerate loses from 8 × 1 to 4 × 2.

### Physics

- Every timing run printed the same final energy, the same total energy and accuracy estimate at every
  SCF iteration, the same number of iterations (A 7, B 9), and the same band energies (2000 for A, 640
  for B) and HOMO/LUMO levels as the first Accelerate run with the same layout. Whatever the GPU's
  parts changed stayed below QE's printed precision: 1e-8 Ry for energies, 0.1 meV for band energies.
- For scale, the layout changes more. Accelerate at 8 × 1 and at 4 × 2 differ by 1.0e-8 Ry (A) and
  2.6e-7 Ry (B) in the final energy, and in 106 of 2000 (A) and 259 of 640 (B) band energies, by up to
  1.0 and 3.5 meV. Both inputs converge to `conv_thr = 1e-6` Ry.
- The physics gate passed for both libraries at both layouts before any timing, again with no printed
  digit different.

### Where the GEMM time went

Seconds per run in each class's calls at 8 × 1, summed over the 8 ranks, from the shim's report. Only
runs through the shim report per class, so the baseline here is the shim with every call on
Accelerate. A class's calls under 0.5 GFLOP stay on Accelerate and are included. From `AB_TRACE`, over
the three runs: the share of the class's GPU parts that 415cb5d computed on its host path, and the
share that 1.5.0 computed with 4M on its staged path (none of 1.5.0's took the host path). Left out:
ZGEMMs outside every class (under 0.6 s) and DGEMMs (0.6 s on A, about 2.3 s on B).

| input | class | GFLOP | all on Accelerate | split, 415cb5d | host path, 415cb5d | split, 1.5.0 | 4M, 1.5.0 |
|---|---|---|---|---|---|---|---|
| A | zUN.k1 | 9435 | 81.5 | 55.4 | 33% | 46.0 | 33% |
| A | zUN.k2 | 8115 | 51.3 | 34.2 | 25% | 26.7 | 25% |
| A | zRK.t1 | 7602 | 77.1 | 41.1 | 9% | 41.9 | 9% |
| A | zRK.t2 | 5563 | 47.5 | 21.4 | 0 | 22.5 | 0 |
| A | zUM.k1 | 1360 | 11.4 | 9.0 | 7% | 8.5 | 8% |
| A | zRK.t0 | 529 | 8.3 | 6.8 | 0 | 6.6 | 0 |
| A | zUM.k2 | 187 | 1.5 | 1.0 | 2% | 1.0 | 2% |
| A | all | 32791 | 278.6 | 168.9 | | 153.2 | |
| B | zUM.k2 | 5990 | 60.1 | 36.3 | 12% | 33.4 | 12% |
| B | zRK.t1 | 3804 | 45.4 | 24.5 | 4% | 25.3 | 3% |
| B | zRK.t0 | 1606 | 17.6 | 12.9 | 0 | 14.2 | 0 |
| B | zUM.k1 | 1379 | 11.9 | 9.3 | 42% | 7.2 | 43% |
| B | zUM.k0 | 647 | 6.3 | 8.3 | 68% | 5.8 | 71% |
| B | zUN.k2 | 338 | 3.0 | 2.3 | 25% | 1.7 | 25% |
| B | zRK.t2 | 169 | 2.4 | 3.8 | 62% | 3.0 | 62% |
| B | all | 13933 | 146.7 | 97.2 | | 90.7 | |

- On average per rank, the split saved 13.7 s (415cb5d) and 15.7 s (1.5.0) of GEMM time on A and 6.2
  and 7.0 s on B: 70–91% of the wall time it saved against the shim with every call on Accelerate.
- 1.5.0's gain over 415cb5d is in the classes where 415cb5d used its host path most: zUN on A,
  89.6 s → 72.7 s, and zUM on B, 53.8 s → 46.5 s. The two shares match closely, as they should if the
  GPU parts 415cb5d sent to its host path are the 4M ones.
- With 415cb5d, the median GPU part on the host path took 2.7–4.9 times as long as the median staged
  one in the same class (1.0 times in B's zRK.t1).
- Two small classes of B ran slower split than on Accelerate alone: zRK.t2, whose GPU parts were range
  fallbacks or 4M, and, with 415cb5d, zUM.k0, whose GPU parts mostly took the host path.
- **Range fallbacks**, with either library: in the timing runs the guard sent one GPU part per run of A
  (zRK.t1) and one (4 × 2) or three (8 × 1) per run of B (zRK.t2) to Accelerate.
- **GPU failures.** Four of 1.5.0's staged GPU parts reported `gpu_failed`, all at 4 × 2 on A in zRK.t2
  (`'C','N'` ZGEMMs with M ≈ 500, N ≈ 1000 and K ≈ 9300–9700): two in the timing runs, two in one
  calibration run. apple-bottom recomputed each on its host path, on the GPU, and no printed result
  changed.

### Calibrated shares

GPU shares as frozen for the timing runs. dRK.t0, a DGEMM class, kept its starting 0.55 and was never
split.

| class | 415cb5d, 8 × 1 | 1.5.0, 8 × 1 | 415cb5d, 4 × 2 | 1.5.0, 4 × 2 |
|---|---|---|---|---|
| zUN.k1 | 0.41 | 0.44 | 0.39 | 0.45 |
| zUN.k2 | 0.45 | 0.47 | 0.39 | 0.47 |
| zUM.k0 | 0.44 | 0.60 | 0.23 | 0.39 |
| zUM.k1 | 0.42 | 0.47 | 0.34 | 0.44 |
| zUM.k2 | 0.53 | 0.53 | 0.51 | 0.54 |
| zRK.t0 | 0.50 | 0.46 | 0.50 | 0.48 |
| zRK.t1 | 0.53 | 0.52 | 0.51 | 0.51 |
| zRK.t2 | 0.53 | 0.50 | 0.52 | 0.51 |

- With 415cb5d, the classes whose GPU parts often took the host path settled lower, most of all at
  4 × 2.
- zRK.t2 did not settle. On A at 8 × 1 its GPU parts took 0.06–0.08 s (median) at shares 0.50–0.53 and
  0.12–0.14 s at 0.55–0.60, and the iterations swung across that step: 0.55, 0.51, 0.57, 0.50 with
  1.5.0, and 0.55, 0.51, 0.60, 0.53 with 415cb5d. In the 8 × 1 timing runs its GPU parts on A took
  about half as long as its CPU parts; the balancing share was 0.66.

### Conditions

- Every run started and ended on AC power, and all 410 power-source samples taken during the blocks
  read AC. `pmset` reported no thermal or performance warning at the start or end of any run.
- Each block's lock was taken once the 1-minute load average was below 5.
- Only the split runs wrote apple-bottom's `AB_TRACE` and the shim's per-call log.

## What these runs do not show

- **Other systems.** Only the two si64 inputs. Smaller systems have smaller GEMMs and less to split,
  and the FFTs stay on the CPU.
- **Shares for another input.** The shares were calibrated on the same inputs and layouts that were
  then timed. Another input would start from them or need its own calibration.
- **The best shares.** Three damped iterations did not settle every class (zRK.t2 above), so the
  timings are for these shares, not the best ones.
- **Other CPU-only configurations.** Only 8 × 1 and 4 × 2, both with `-nk 4`, were timed here.
- **Energy.** Power draw was not measured. The split keeps both engines busy; whether it saves energy
  per run is open.
- **Other machines.** One M2 Max. The shares follow the ratio of the GPU's rate to Accelerate's, which
  differs from chip to chip.
- **1.5.0's GPU mode** was not timed.
- **The four `gpu_failed` outcomes** were not investigated.

## Provenance

- **Machine.** Mac14,6: M2 Max with 8 performance and 4 efficiency cores, a 38-core GPU and 64 GB;
  macOS 27.0.1 (26A434).
- **QE.** `develop` at b6615c50b (2026-10-30), version 8.0dev, built as planned. Homebrew GCC 15.2.0,
  Open MPI 5.0.9, OpenBLAS 0.3.31, ScaLAPACK 2.2.2, FFTW 3.3.10.
- **Libraries.**
  - 415cb5d reports "1.4.0 (415cb5d4d888)".
  - 1.5.0's library was built from 8ebe73c, an unpublished commit whose `src/` and `include/` are those
    of 935e74d, PR #16's last commit to change the library. v1.5.0's `src/` is the same, and its header
    differs only in the version macros and comments, so the build reports "1.4.0 (8ebe73ccf822-dirty)";
    "dirty" is an edited results README in its build tree.
- **Inputs.** A and B from apple-bottom's `benchmarks/qe/inputs/` at 2ea4077 (the same at v1.5.0), with
  `ecutwfc` 25 Ry and pslibrary 1.0.0's Si PAW pseudopotentials: `Si.pbe-nl-kjpaw_psl.1.0.0.UPF` for A,
  `Si.pbe-n-kjpaw_psl.1.0.0.UPF` for B.
- **The shim's GPU test.** `test_split.c` with `AB_MODE=gpu AB_MIN_GPU_DIM=0`: 0 of 14 cases failed with
  either library.

| file | sha256 |
|---|---|
| `pw.x.cpu` | d3ace84fa8044303a01b64acff6678b8b078746d0625ef6f9cd72c869208436e |
| `pw.x.split` | 7499f88e8ccd4d870e0eb0eb73665c2bda446bece7813d4c8b1d566ec6c9ac87 |
| `pw.x.fix` | 871ec24a67d27ea05210fcf331bdf091980fb13bfa40e280396b14019d236b94 |
| `libapplebottom.dylib`, 415cb5d | 755a46613bf25b34c32dad6217d07730b17c21261ffbaf314d6d6f3165847122 |
| `libapplebottom.dylib`, 1.5.0's library | 3ead2d56bc84485486447d764ad6e3ee2afaf81fa71b0c229267dc5626dbe08b |
| `qe_split.c` | 33c3593dde7052d88d57f8a93d9f955520cf9b4967dfac76f013c9acb83c19a3 |

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
