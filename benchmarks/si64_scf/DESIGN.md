# Si64 SCF Benchmark — Design

**Status:** design, pending review before implementation.
**Location:** `Espressivo/benchmarks/si64_scf/` (canonical). An earlier draft
under `apple-bottom/benchmarks/si64_scf/DESIGN.md` is the source material for
this document and is deleted once this file lands (repo-boundary per
`CLAUDE.md` §1b: apple-bottom holds no QE inputs, pseudos, or results).
**Owner:** Quantum-Espressivo paper (HPEC 2026 "ULP Fiction"), reviewer
comment #1 response.
**Purpose:** Produce the Si64 SCF wall-clock numbers that anchor the paper's
apple-bottom-vs-stock-Accelerate claim, with enough provenance and variance
characterization to survive a reviewer audit.

---

## §1. Scope and non-goals

**In scope.** One workload — Si64 bulk silicon SCF — run under three BLAS
dispatch configurations, each repeated 10 times, producing:

- Paper Table 3: wall time (median, bootstrap 95% CI, min, max), total
  energy, SCF iteration count, speedup ratios across configs A/B/C.
- Paper Table Y: per-BLAS-routine call counts, GPU dispatch fractions, and
  wall time from apple-bottom's `profile.jsonl` for configuration C (and,
  informationally, B).
- Per-run provenance manifest: binary SHA, apple-bottom commit pin, QE
  version, compiler versions, thermal state, timestamps.

**Explicitly out of scope.** NSCF, phonons (covered by EPW-track sessions
per `docs/QE75_INTEGRATION.md`), Yambo, alternative supercells, k-grid
convergence scans, MPI-rank scans, OMP-thread scans, multi-chip validation
(M1/M3/M4 deferred to Phase 1 of `docs/MERGE_STRATEGY.md`). Anything that
introduces a second degree of freedom beyond BLAS-dispatch choice.

**Configuration rationale — OMP=4, np=2.** This is the production-representative
configuration Espressivo's integration targets. It matches the `VAL-001`
validation row in `docs/QE75_INTEGRATION.md` (22% wall speedup, 11-decimal
energy agreement), matches `scripts/benchmark-4way.sh` and every other script
in the repo, and matches the GaN EPW regression baseline. An earlier draft
of this document specified OMP=1, np=1 on the rationale that single-confound
isolation would provide the cleanest BLAS-layer comparison. That draft was
revised to OMP=4, np=2 after auditing the Espressivo repository's actual
production configuration and concluding that a configuration no real user
runs is a weaker measurement for the paper's claim than a configuration that
matches documented production. The price is that the comparison carries
OpenMP and MPI-collective overhead inside each config — which is fine,
because those effects apply identically to A, B, and C (same ranks, same
threads, same communication pattern), so they cancel in the ratios the
paper actually reports.

---

## §2. Build provenance

### §2.1 Binaries required

| Label | Binary path                                | Linkage requirement                                  |
|-------|--------------------------------------------|------------------------------------------------------|
| A     | `~/qe-test/builds/mpi/pw.x`                | **must not** reference `libapplebottom` in `otool -L` |
| C     | `~/qe-test/builds/mpi-gpu/pw.x`            | **must** reference `libapplebottom` in `otool -L`     |
| B     | (same binary as C)                         | AB_MODE env toggle — no separate build                |

`run.sh` verifies both otool invariants on every invocation (pattern from
`benchmarks/qe_yambo/bench_qe.sh` lines 50-61). A silently-swapped binary
voids the comparison.

### §2.2 Build recipe

Both binaries are built per `docs/QE75_INTEGRATION.md` (QE 7.5 on M2 Max,
gcc-15 / gfortran-15 / OpenMPI). A separates by omitting the apple-bottom
link line; C adds `-lapplebottom` per the integration doc's Phase 1E.

**No separate BUILD_MACOS.md is authored in this session.** QE75_INTEGRATION.md
covers the CMake and autoconf paths; this DESIGN.md cross-references it
rather than duplicating. If a standalone BUILD_MACOS.md is wanted as a
public-facing artifact for the paper's artifact-evaluation appendix, that's
a follow-up deliverable — flagged, not in this session's scope.

### §2.3 Commit pinning

Before any measurement run, `run.sh` records into each run's provenance
manifest (§7):

- `apple-bottom` HEAD SHA, `git status --short` (must be clean)
- `libapplebottom.dylib` SHA256 and mtime
- `pw.x` SHA256 and mtime (both A and C binaries)
- QE source HEAD SHA under `deps/qe-7.5/` (must be clean)

Any dirty tree aborts the run. Reviewer audit trail requires that the
binaries match a specific, reproducible source state.

### §2.4 Rebuild gotcha — `blas_wrapper.c`

Per `CLAUDE.md §3` (apple-bottom root) and recurring experience: after
`make clean` in apple-bottom, `blas_wrapper.c` sometimes fails to pick up
`AB_MODE` changes until manually recompiled. `run.sh` does **not** rebuild;
rebuilds are operator-driven and gated separately. The build-validation
smoke test (§3.5) catches a stale wrapper before Si64 time is burned.

### §2.5 Concurrency — benign-race analysis of the dispatch-cache initializers

`apple-bottom/src/blas_wrapper.c:37–77` lazily initializes four file-scope
caches (`_ab_mode`, `_ab_min_dim`, `_ab_cross_z`, `_ab_cross_d`) on first
call to the corresponding `ab_get_*` accessor. Each accessor checks a
sentinel value and, if uninitialized, reads an environment variable, parses
it, and writes the result to the cache. There is no `pthread_once`, no
mutex, no atomic, no memory barrier.

Under OMP=4 (this DESIGN's runtime), multiple OpenMP worker threads can
race through the slow path simultaneously. Per the C11 memory model this
is a formal data race on the cache variables — technically undefined
behavior. In practice on this target it is benign for three concrete
reasons, which are the load-bearing argument and not handwaving:

1. **Idempotent computation.** Each accessor is a deterministic function
   of an environment variable that does not mutate during process lifetime
   (no `setenv` after start). `getenv` is POSIX-thread-safe for read-only
   access; `atoi` and `strtoull` are pure. Every racing thread computes
   the **same** value and writes the **same** value. Read-after-write
   races resolve to identical results.
2. **ARM64 atomic-aligned-int memory access.** The cache variables are
   naturally-aligned 4- and 8-byte scalars. Aligned loads and stores at
   these widths are atomic at the hardware level on ARM64 (no torn reads).
   A racing reader sees either the sentinel or the final value; never a
   partially-written intermediate.
3. **Fast-path dominance after first-per-thread call.** The slow path
   executes at most ~4 times per pw.x invocation (once per worker that
   wins the race to be first). Every subsequent BLAS call hits the
   sentinel-passes branch and returns directly. Race exposure is bounded
   to a handful of accesses out of the millions the campaign performs.

ThreadSanitizer would flag the writes; `-O2` production builds do not
exhibit observable misbehavior. The campaign relies on this analysis for
correctness *and* on the operational verification provided by §6 Gate 6
(Config B must show zero GPU dispatches across all four OMP workers — any
race to a stale-but-not-CPU value would violate this).

**Scope.** This analysis applies to worker-thread concurrency within a
single process. Multi-process MPI ranks have per-process caches and are
independent by construction. Future use cases involving cross-process
shared state would require separate analysis.

---

## §3. Environment

### §3.1 QE parameters

| Parameter         | Value      | Rationale                                                             |
|-------------------|------------|-----------------------------------------------------------------------|
| supercell         | Si64, 2×2×2 of 8-atom conventional diamond | paper anchor; matches VAL-001 |
| lattice           | 10.264 Bohr (experimental Si) | standard Si benchmark value                          |
| pseudopotential   | `Si_ONCV_PBE-1.2.upf` (SG15) | norm-conserving, EPW-compatible, triangulable vs external data |
| `ecutwfc`         | 40 Ry      | ONCV Si PBE converged to ~1 meV/atom                                  |
| `ecutrho`         | 160 Ry     | 4× `ecutwfc`, ONCV default                                            |
| k-grid            | 2×2×2 MP   | 4 irreducible k-points; exercises complex cegterg (ab_zgemm path)      |
| `occupations`     | `'fixed'`  | insulating Si; no smearing perturbation                               |
| `conv_thr`        | `1.0d-8`   | tight enough that DD~10⁻¹⁵ vs FP64~10⁻¹⁶ delta cannot mask            |
| `diagonalization` | `'david'`  | Davidson → cegterg.f90 → `ab_zgemm` patch site (QE75_INTEGRATION §1E)  |
| `mixing_beta`     | 0.4        | QE insulator default                                                   |
| `nbnd`            | default    | let pw.x pick                                                          |

### §3.2 Runtime

| Variable              | Value     | Rationale                                                  |
|-----------------------|-----------|------------------------------------------------------------|
| `OMP_NUM_THREADS`     | 4         | production-representative; matches VAL-001, 4-way, benchmark-paper |
| MPI ranks             | 2         | same                                                       |
| `AB_CROSSOVER_FLOPS`  | 100000000 | compiled-in default — documents the production threshold    |

Per-config env additions listed in §4.

### §3.3 Pseudopotentials

Located at `~/pseudo/Si_ONCV_PBE-1.2.upf` (user-global per top-level
`CLAUDE.md`). `run.sh` symlinks at run start; not committed (copyright
fence, `CLAUDE.md` §1b). `benchmarks/si64_scf/pseudos/README.md`
documents the source URL and SHA256 without embedding the file.

### §3.4 Thermal hygiene

- 60 s cooldown between runs within a config (pattern from
  `scripts/benchmark-4way.sh`).
- 120 s cooldown between configs (longer because config transitions load a
  different binary and a cold dyld cache affects the first run).
- Each run records `pmset -g thermlog | tail -1` (thermal state) into its
  provenance manifest. A run whose thermal state shows "Throttled" is
  flagged; we do not discard automatically, but the gate analysis (§6) can
  stratify.
- Run ordering: all 10 A-runs, then all 10 B-runs, then all 10 C-runs.
  Alternative block-randomized ordering was considered; within-config
  serial is preferred because it lets each config warm the dyld cache
  identically across its runs, which reduces *within-config* variance (the
  denominator of Gate 4) at the cost of slightly higher *between-config*
  thermal drift (which Gates 1-3 do not use directly). Serial
  within-config ordering biases later configs toward higher thermal load.
  This is conservative for the A-vs-C speedup claim: if C is measurably
  slower due to thermal drift, the true C performance is at most what we
  report, so the reported speedup is a lower bound on the true kernel
  speedup.

### §3.5 Si2 smoke test — mandatory pre-Si64 gate

Before any Si64 run, `run_smoke.sh` runs a 2-atom Si cell through the same
three configurations and verifies:

1. All three configs converge.
2. Total energies agree across configs to ≥ 6 decimal places (tighter than
   Si64's 10⁻⁵ Ry gate because Si2 is cheap and any DD-level disagreement
   shows up here first).
3. C's `profile.jsonl` exists and is non-empty (catches a stale `blas_wrapper.c`
   that would silently produce an empty profile at Si64 scale, wasting
   hours).
4. **B's `profile.jsonl` shows zero GPU dispatches across all four OMP
   workers.** This is the operational verification of the §2.5 benign-race
   analysis: any worker that races to a stale-but-not-CPU value for
   `_ab_mode` would route at least one BLAS call to GPU, and the assertion
   would fail. This requirement is also enforced for the Si64 campaign by
   Gate 6 (§6).

Wall time: seconds per config. Output lives in `results/si2_smoke/<date>/`.
The smoke harness is committed as a reusable build-validation artifact,
independent of whether Si64 runs to completion this session.

---

## §4. Three configurations

| Label | Binary        | `AB_MODE` | Measures                                                          |
|-------|---------------|-----------|-------------------------------------------------------------------|
| A     | mpi/pw.x      | (unset)   | stock Accelerate/AMX baseline; no apple-bottom linkage             |
| B     | mpi-gpu/pw.x  | `cpu`     | dispatcher passthrough — same binary as C, `ab_use_gpu*()` returns false, every BLAS routes to cblas. Isolates the cost of going through the dispatcher. |
| C     | mpi-gpu/pw.x  | `auto`    | production routing — DGEMM/ZGEMM to GPU above crossover, DSYRK/ZHERK stay on AMX. Paper headline. |

### §4.1 Interpretation

- **Dispatcher overhead** = `(median(t_B) − median(t_A)) / median(t_A)`.
  Pre-committed threshold: ≤ 5 % (Gate 3). If B > A + 5 %, the C-vs-A
  comparison conflates dispatcher cost with GPU benefit.
- **apple-bottom end-to-end speedup** = `median(t_A) / median(t_C)`.
  Headline.
- **GPU-kernel speedup over dispatcher-cpu** =
  `median(t_B) / median(t_C)`. Secondary; larger than headline when
  dispatcher overhead is non-zero.

### §4.2 Pre-v1.3.0 4-way campaign (superseded)

`results/benchmark_4way/` (dates ~2026-04-05/06) contains an earlier
4-configuration campaign: `openblas`, `amx`, `gpu_amx`, `gpu_all`. That
campaign is archived in place but **not used for paper Table 3**. It is
superseded for three reasons:

1. The `mpi-gpu/pw.x` binary used was built 2026-03-28, predating the
   entire v1.3.0 apple-bottom sprint: Morton Z-order fix (94df0cf), the
   AB_MODE runtime knob itself (d5ca60e), the BLAS profiler (a68907b),
   BUG-8 ARC fix, DWTimesDW3 variant, Week-2 device API. None of the
   campaign's wall times represent current apple-bottom performance.
2. The 4-way design has no dispatcher-passthrough B-equivalent (no build
   uses the v1.3.0 patched binary forced to cblas). The dispatcher-overhead
   gate (§6 Gate 3) is unanswerable from that data.
3. `profile.jsonl` — the input to Table Y — did not exist in the codebase
   at 4-way time. Only the first-generation `AB_PROFILE_FILE` text format
   was available, and it doesn't carry per-routine call counts at the
   granularity Table Y reports.

---

## §5. Reference energy

### §5.1 Primary gate — A/B/C self-consistency

For each run index `i ∈ {1..10}`, the three total energies
`(E_A^i, E_B^i, E_C^i)` must agree pairwise to within 10⁻⁵ Ry. This is the
physics-parity gate; any disagreement falsifies "apple-bottom does not
perturb SCF results" and invalidates the timing comparison for that
run index.

This is the *primary* gate because it is independent of QE version. QE
7.4.1 and QE 7.5 may produce slightly different Si64 total energies
(Davidson internal changes, updated symmetry handling, default grid shifts),
but within any single QE version the three BLAS-dispatch paths must agree.

### §5.2 Secondary check — QE 7.4.1 VAL-001 reference (informational)

`docs/QE75_INTEGRATION.md` VAL-001 records the QE 7.4.1 Si64 energy as
**−2990.44276157 Ry** with these same parameters. This DESIGN targets QE
7.5. Two informational checks:

- Compute median(E_C) − (−2990.44276157) and report in Table 3's footer.
- If |Δ| > 10⁻⁴ Ry (an order of magnitude looser than gate 1), flag in the
  table footer as "QE 7.5 reference drift" and investigate whether the
  difference is a QE-version algorithmic change (expected; acceptable) or
  a pseudopotential / lattice-constant inconsistency (would invalidate the
  whole run).

The 10⁻⁴ Ry "drift" threshold is explicitly looser than Gate 2 (10⁻⁵ Ry)
to accommodate legitimate version-to-version QE numerics without failing
admissibility on a non-bug.

---

## §6. Admissibility gates

All gates pre-committed. Thresholds are fixed in this document and cited
by reference in `run.sh` and `parse_timings.py`; parse_timings.py must not
recompute them heuristically.

| # | Gate                          | Condition                                                       | On fail |
|---|-------------------------------|-----------------------------------------------------------------|---------|
| 1 | Convergence (per run)         | every run reaches `convergence has been achieved` within `electron_maxstep` | run excluded; if ≥ 2 failures in any config, campaign fails |
| 2 | Energy self-consistency       | for every run index i, max pairwise \|E_X^i − E_Y^i\| ≤ 10⁻⁵ Ry across A/B/C | run index excluded; if ≥ 2 failures, campaign fails — correctness regression, escalate to apple-bottom V&V |
| 3 | Dispatcher overhead           | \|median(t_B) − median(t_A)\| / median(t_A) ≤ 0.05               | paper must caveat C-vs-A or dispatcher must be optimized before submission |
| 4 | Reproducibility (per config)  | bootstrap-95-CI half-width / median ≤ 0.02 for X ∈ {A, B, C}     | machine thermally unstable or config under-specified; do not submit |
| 5 | Smoke test pre-gate           | §3.5 smoke test passed this session                              | Phase 1 (Si64 campaign) does not execute                     |
| 6 | Config B GPU-dispatch invariant | Config B's `profile.jsonl` shows **zero** GPU dispatches summed across all 10 runs and all 4 OMP workers per run | halt campaign, diagnose AB_MODE propagation under OMP=4, exclude B data from Table 3 — without B the dispatcher-overhead claim cannot be made and the paper text must reflect that |
| 7 | Manifest integrity (per run)  | Config A manifests have null `libapplebottom_*` and null `ab_mode`; Config B/C manifests have non-null both; all SHA256/mtime fields present and non-empty | run excluded with `status=MANIFEST_FAIL`; if ≥ 1 failure, investigate before treating campaign as admissible |

Informational (reported, not gated):

- QE 7.5 vs QE 7.4.1 reference drift (§5.2).
- ZHERK share of `electrons` wall in config C (§8 Table Y rationale).
- Thermal-state histogram across the 30 runs.

### §6.1 Provenance of the 5 % dispatcher-overhead threshold (Gate 3)

The 5 % budget is **inherited from `benchmarks/qe_yambo/bench_baseline_check.sh`**
as a community-convention "negligible-overhead" budget for systems-perf
work. It is not separately derived from a noise-floor measurement on this
machine, and it is not justified from first principles. Two honest
characterizations:

- It is loose enough that current dispatcher implementations comfortably
  pass without active tuning, which is why earlier sessions adopted it.
- It is strict enough that a regression introducing a per-call malloc or
  a redundant env-var lookup would be caught.

Future work could replace it with a measured threshold: 3× the bootstrap
CI half-width on `(t_B − t_A)/t_A` from this very campaign, which would
make the budget self-calibrating against measured machine variance. That
revision is deliberately deferred — adopting a measured threshold *after*
seeing the data would be a post-hoc fit, which is the failure mode the
pre-commitment discipline exists to prevent.

### §6.2 Sample-size rationale and statistical framing

Ten runs per config, nonparametric throughout. Three-run campaigns are
dominated by a single thermal outlier; ten gives stable estimates.

**Why nonparametric.** Wall-time distributions under thermal load are
typically right-skewed (long tail from throttling events, hard floor at
the no-overhead minimum), and may be bimodal if a throttle event lands
inside the sample. Parametric Student-t CIs assume approximate normality;
on n=10 with right-skewed contamination, the t-CI can substantially
under-cover. Median ± bootstrap CI sidesteps the assumption entirely:

- **Estimator:** median (per config, per metric).
- **CI method:** percentile bootstrap, 10⁴ resamples, 95% interval (2.5
  and 97.5 percentiles of the resample-median distribution).
- **Efficiency note:** under approximately normal data the bootstrap CI
  on the median is about 1.25× wider than the parametric CI on the mean
  (asymptotic relative efficiency of the median is 2/π ≈ 0.64). On
  contaminated data the bootstrap CI is genuinely robust; the parametric
  CI is not.
- **Speedup ratios:** ratio of medians, with bootstrap CI on the ratio
  (resample paired runs jointly to preserve any per-run correlation, then
  compute the ratio of medians on each resample).
- **Cost:** 10⁴ resamples on n=10 is microseconds in NumPy; computational
  cost is ignorable.

The campaign is 30 total pw.x invocations, expected wall ≈ 90 minutes per
the VAL-001 timing baseline (2 min/run × 30 + cooldowns). That is
acceptable session-time investment for paper-reviewer-proof variance
characterization that does not rely on a normality assumption a careful
reviewer could pick at.

---

## §7. Provenance manifest schema

Every run emits a `manifest.json` alongside `scf.out` and (for B/C)
`profile.jsonl`. `parse_timings.py` reads manifests as authoritative — it
does not re-derive any field it could have read from the manifest.

```json
{
  "schema_version": 1,
  "run_id": "<config>_<index>_<ISO8601_UTC>",
  "config": {
    "label": "A" | "B" | "C",
    "pw_binary_path": "/Users/.../pw.x",
    "pw_binary_sha256": "…",
    "pw_binary_mtime_utc": "2026-04-…",
    "ab_mode": null | "cpu" | "auto",
    "ab_crossover_flops": 100000000,
    "omp_num_threads": 4,
    "mpi_ranks": 2
  },
  "source_state": {
    "apple_bottom_commit": null | "…",
    "apple_bottom_dirty": null | false,
    "libapplebottom_sha256": null | "…",
    "libapplebottom_mtime_utc": null | "…",
    "qe_commit_or_version_string": "QE-7.5 …",
    "espressivo_commit": "…"
  },
  "toolchain": {
    "clang_version": "…",
    "gcc_version": "gcc-15 …",
    "gfortran_version": "gfortran-15 …",
    "mpirun_version": "mpirun (Open MPI) …",
    "openmp_runtime": "libomp / libgomp version"
  },
  "host": {
    "hw_model": "Mac14,6",
    "hw_memsize_bytes": 103079215104,
    "cpu_brand": "Apple M2 Max",
    "os_product_version": "15.x.x",
    "os_build_version": "…",
    "hostname": "…"
  },
  "thermal": {
    "pre_run_pmset_thermlog": "CPU_Scheduler_Limit=100 …",
    "post_run_pmset_thermlog": "…",
    "thermal_state_pre": "Nominal" | "Throttled" | "…",
    "thermal_state_post": "…"
  },
  "timing": {
    "start_utc": "…",
    "end_utc": "…",
    "wall_seconds_wallclock": 121.4
  },
  "scf": {
    "converged": true,
    "iterations": 12,
    "total_energy_ry": -2990.44276157,
    "wall_total_s": 121.0,
    "wall_electrons_s": 118.0,
    "wall_cegterg_s": 95.0,
    "wall_h_psi_s": 78.0,
    "wall_vloc_psi_s": 45.0,
    "wall_calbec_s": 12.0,
    "wall_ortho_s": 9.0
  },
  "status": "OK" | "FAIL_CONVERGENCE" | "FAIL_CRASH" | "FAIL_ENERGY" | "MANIFEST_FAIL"
}
```

### §7.1 Per-config manifest invariants (Gate 7)

These invariants are checked by `parse_timings.py` on every manifest
ingest. Any violation sets `status=MANIFEST_FAIL` for that run and feeds
into Gate 7.

- **Config A:** `config.ab_mode == null`,
  `source_state.apple_bottom_commit == null`,
  `source_state.libapplebottom_sha256 == null`,
  `source_state.libapplebottom_mtime_utc == null`. Config A's pw.x has no
  apple-bottom linkage; recording a non-null library identity for it would
  indicate either an otool check that misfired or a misconfigured run.
- **Config B and C:** all four of the above must be **non-null and
  non-empty strings**. A null library identity for B or C means the
  apple-bottom state was not captured at run time and the result is not
  reproducible.
- **All configs:** every SHA256 and mtime field that the schema lists as a
  string must be present and non-empty. `qe_commit_or_version_string`,
  `espressivo_commit`, and toolchain version strings are required for all
  configs.

### §7.2 parse_timings.py contract

- Reads `manifest.json` + `scf.out` + (optionally) `profile.jsonl`.
- Validates each manifest against §7.1 invariants; emits
  `status=MANIFEST_FAIL` on violation.
- **Manifest validation runs before timing extraction; a MANIFEST_FAIL
  run contributes no timing data to aggregates.**
- **Gate 2 (energy self-consistency) operates on per-run-index triples
  `(A_i, B_i, C_i)`. On failure, the offending run index is excluded from
  all three configs for the purposes of paired-bootstrap analysis (speedup
  ratios, dispatcher-overhead CI). Unpaired per-config statistics still
  use all surviving runs from that config.**
- **All per-config aggregates are computed on surviving runs only.
  Bootstrap resamples operate at the surviving n; there is no padding or
  imputation.**
- Emits `results/<date>/results.json` with per-run records and per-config
  aggregates: for each (config, metric) combination, computes
  `n`, `median_wall_s`, `bootstrap_ci_95_lower_s`,
  `bootstrap_ci_95_upper_s`, `min_wall_s`, `max_wall_s`. Bootstrap is
  10⁴ percentile resamples with a fixed seed (recorded in the output) so
  the CI is deterministic across re-runs of the parser.
- Emits `results/<date>/table3.csv` and `results/<date>/tableY.csv` in the
  schemas of §8.
- Applies gates §6 on the aggregated data, emits `results/<date>/gates.json`
  with pass/fail per gate and a top-level `campaign_admissible` boolean.
- Never fabricates a field it cannot read; missing fields → null, not
  heuristic.

---

## §8. Paper table schemas

### §8.1 Table 3 — wall time and speedup

| Config                           | n  | wall median (s) | wall 95% CI (s) | wall min (s) | wall max (s) | E (Ry, median) | SCF its (mode) | Speedup vs A                |
|----------------------------------|----|------------------|-----------------|--------------|--------------|------------------|----------------|-----------------------------|
| A. stock Accelerate              | 10 | t̃_A             | [L_A, U_A]      | …            | …            | −2990.442762…    | N_A            | 1.00× (definitionally)      |
| B. apple-bottom, AB_MODE=cpu     | 10 | t̃_B             | [L_B, U_B]      | …            | …            | −2990.442762…    | N_A            | t̃_A/t̃_B [CI]               |
| C. apple-bottom, AB_MODE=auto    | 10 | t̃_C             | [L_C, U_C]      | …            | …            | −2990.442762…    | N_A            | **t̃_A/t̃_C [CI]**           |

CI columns are 95% percentile bootstrap (10⁴ resamples, fixed seed).
Speedup-vs-A CIs are computed by paired bootstrap on the ratio of
medians, not by ratio of independent CIs.

Footer fields:
- QE 7.5 vs QE 7.4.1 VAL-001 reference drift: Δ = median(E_C) − (−2990.44276157).
- Dispatcher overhead: (t̃_B − t̃_A) / t̃_A with bootstrap CI.
- Gate results: 1-7 pass/fail.
- Hardware: M2 Max, 96 GB, macOS build. apple-bottom commit: …
- Bootstrap seed used for CIs.

### §8.2 Table Y — per-BLAS breakdown (config C)

| Routine | Calls (median) | GPU frac (median) | Wall median (s) | Wall 95% CI (s) | % of electrons (median) |
|---------|----------------|-------------------|-----------------|-----------------|--------------------------|
| DGEMM   | …              | …                 | …               | […, …]          | …                        |
| ZGEMM   | …              | …                 | …               | […, …]          | …                        |
| DSYRK   | …              | 0                 | …               | […, …]          | …                        |
| ZHERK   | …              | 0                 | …               | […, …]          | …                        |

Sourced from `profile.jsonl` via the apple-bottom profiler schema
(`src/profiling/blas_profiler.c`). `parse_timings.py` accepts that schema
as authoritative; no heuristic re-parsing. Same nonparametric framing as
Table 3: median across the 10 config-C runs, percentile bootstrap CI.

**ZHERK share — reported, not gated.** Whatever the measured share is, one
of three paper narratives applies:

- Consistent with earlier ~10 %: corroborates the ZHERK-deferral argument
  and strengthens the v1.3 scope rationale.
- Lower than earlier: the deferral argument is stronger; GPU-native ZHERK
  is lower-leverage than prior profiling suggested.
- Higher than earlier: the deferral argument is weaker, and the paper tells
  an interesting story about why GPU-native ZHERK is higher-priority than
  previously thought.

All three are publishable. The Si64 measurement updates the prior; it does
not need to confirm it.

---

## §9. Historical note — pre-v1.3.0 4-way campaign

`results/benchmark_4way/` is archived as a historical baseline and
**superseded** for paper Table 3. The three reasons are detailed in §4.2;
in summary: stale binary (Mar 28, pre-v1.3.0 sprint), no B-equivalent
configuration, incompatible profile schema. A
`results/benchmark_4way/README.md` is added at commit time recording the
execution date, the 2026-03-28 binary build date, the supersession
pointer to this DESIGN.md, and the profile-schema incompatibility note.

---

## §10. Open questions deferred to implementation

1. Whether to capture Table Y for configuration B as well. Likely yes —
   cheap, and makes dispatcher-overhead analysis more granular. Final call
   after A/B/C capture.
2. Whether to measure and report wall time *excluding* the first run of
   each config (to strip dyld-cache warm-up). Leaning no: "first run cold"
   is also what a real user experiences. Revisit if Gate 4 fails and the
   first run is demonstrably the outlier.
3. Whether to include `pmset` thermal state in the admissibility gate (fail
   run if "Throttled"). Leaning no — reporting is sufficient, gating would
   discard data rather than explain it.
4. Whether the eventual paper-artifact appendix needs a standalone
   `BUILD_MACOS.md` or can cross-reference `docs/QE75_INTEGRATION.md`.
   Follow-up session.
5. Whether a fourth row "C with AB_MIN_GPU_DIM lowered" should be added to
   stress the GPU path further. Reviewer-adjacent, not required for initial
   submission.
6. **Optional: ThreadSanitizer belt-and-suspenders.** The §2.5 benign-race
   analysis is theoretically sound and operationally verified by Gate 6,
   but a one-time TSan run of the smoke test before paper submission would
   catch any future regression that introduces a *non-idempotent* write to
   the dispatch-cache initializers (e.g., someone adding telemetry that
   increments a counter without atomicity). Deferred; not blocking.

---

## Deliverable manifest (for later implementation)

Under `benchmarks/si64_scf/`:

- `DESIGN.md` — this file.
- `scf.in.template` — QE input with `${PSEUDO_DIR}`, `${OUTDIR}`, `${PREFIX}` markers.
- `smoke/` — Si2 smoke harness (§3.5): `scf.in`, `run_smoke.sh`.
- `run_config.sh` — single-configuration, single-run driver. Records manifest per §7.
- `run_all.sh` — orchestrates 3 configs × 10 runs with cooldowns per §3.4.
- `parse_timings.py` — extraction, manifest validation, bootstrap aggregation, and gating per §6–§8.
- `pseudos/README.md` — source URL, SHA256; no `.upf` committed.
- `results/<date>/…` — per-session results; `scf.out`, `manifest.json`,
  `profile.jsonl`, `results.json`, `table3.csv`, `tableY.csv`, `gates.json`,
  `summary.md`.

Not committed: `.upf`, `.save/` directories, `.wfc*`, any `.tex`/`.pdf`
paper drafts.

Not authored in this session: `docs/BUILD_MACOS.md` (deferred to follow-up;
`docs/QE75_INTEGRATION.md` is the current canonical build recipe).
