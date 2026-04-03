# QE 7.5 Upgrade & Upstream Merge Plan

**Author:** Grant Heileman
**Date:** April 3, 2026
**apple-bottom version:** 1.3.0-dev (metal-algos @ main, 90 commits)
**Baseline:** QE 7.4.1 validated (Si64, 11-decimal energy match, 1.22x speedup)

---

## Executive Summary

Upgrade the apple-bottom + Quantum ESPRESSO integration from QE 7.4.1 to QE 7.5, validate correctness and performance, then prepare an upstream merge request to the QE project introducing Metal GPU acceleration as a first-class backend alongside the existing CUDA path.

The existing integration touches only 2 files (cegterg.f90 + make.inc, 15 lines total). The upstream merge formalizes this via `__METAL` preprocessor guards following the `__CUDA` precedent, plus a new CMake module.

---

## Current State of apple-bottom

- **Library:** libapplebottom.a (static, 79 KB), MIT licensed
- **BLAS ops:** DGEMM, ZGEMM, ZGEMM_EX, DSYRK, DTRSM + utilities
- **Performance:** 618 GFLOP/s peak (DGEMM 4096x4096 on M2 Max)
- **Precision:** ~10^-15 Frobenius relative error via DD arithmetic
- **Tests:** 48/48 passing (6 precision + 42 correctness)
- **Fortran bridge:** `fortran_bridge.c` (81 LOC) provides `ab_dgemm_` and `ab_zgemm_` with FLOP-based GPU/CPU routing at 100M FLOP crossover
- **Known limitations:** beta != 0 falls back to CPU; rectangular matrices with aspect ratio > 10:1 have correctness issues (fix in progress on `fix/rectangular-gemm` branch)
- **Uncommitted work:** CHANGELOG, Makefile, README, header version bump to 1.3.0-dev, plus new files (docs/COMPARISON.md, python/, scripts/)

### QE 7.4.1 Validation Results (VAL-001)

| Metric | Accelerate (CPU) | apple-bottom (GPU) |
|--------|-------------------|---------------------|
| Wall time | 2m28s | 2m01s (1.22x faster) |
| CPU usage | 600% (6 threads) | 320% (47% reduction) |
| Total energy | -2990.44276157 Ry | -2990.44276157 Ry |
| SCF iterations | 14 | 14 |
| ZGEMM calls | 931 total | 791 GPU / 140 CPU |

---

## Phase 0: Pre-work (Before Touching QE 7.5)

### 0A. Stabilize apple-bottom 1.3.0

The current tree has uncommitted changes. Before starting the QE 7.5 effort:

1. **Commit or stash** the pending changes (CHANGELOG, Makefile, README, header, python/, docs/COMPARISON.md, scripts/)
2. **Run full validation:** `make clean && make test` -- confirm 48/48 pass
3. **Tag v1.3.0** if all tests pass, or keep as `-dev` if rectangular fix is outstanding
4. **Rebuild library:** ensure `build/libapplebottom.a` is current

### 0B. Update test_qe_integration.sh for QE 7.5

The existing script hardcodes `q-e-qe-7.4.1` paths. Parameterize it:

```bash
QE=${QE_DIR:-~/qe-test/q-e-qe-7.5}   # was hardcoded to 7.4.1
```

Also update the expected energy if QE 7.5 produces a slightly different reference (unlikely for Si64 PBE, but verify).

### 0C. Verify symlink

```bash
ls -la ~/apple-bottom
# Must point to ~/Dev/arm/metal-algos
# If not: ln -sf ~/Dev/arm/metal-algos ~/apple-bottom
```

---

## Phase 1: Download, Build, and Baseline QE 7.5

### 1A. Download QE 7.5 source

```bash
cd ~/Dev/QE-7_5
wget https://gitlab.com/QEF/q-e/-/archive/qe-7.5/q-e-qe-7.5.tar.gz
tar xzf q-e-qe-7.5.tar.gz
cd q-e-qe-7.5
```

Alternatively, clone from GitLab:
```bash
cd ~/Dev/QE-7_5
git clone --branch qe-7.5 --depth 1 https://gitlab.com/QEF/q-e.git q-e-qe-7.5
```

### 1B. Build clean baseline (Accelerate only, no apple-bottom)

**CMake approach (preferred):**
```bash
cd ~/Dev/QE-7_5/q-e-qe-7.5
mkdir build-baseline && cd build-baseline
cmake .. \
  -DCMAKE_Fortran_COMPILER=gfortran \
  -DCMAKE_C_COMPILER=gcc-14 \
  -DBLA_VENDOR=Apple \
  -DQE_ENABLE_OPENMP=ON \
  -DQE_DEVICEXLIB_INTERNAL=ON \
  -DCMAKE_BUILD_TYPE=Release
make -j8 pw
```

**Autoconf fallback (if CMake fails):**
```bash
./configure --enable-openmp FC=gfortran CC=gcc-14 \
  BLAS_LIBS="-framework Accelerate" LAPACK_LIBS="-framework Accelerate"
make -j8 pw
```

**Verification:**
```bash
./bin/pw.x --version   # Should report 7.5
```

### 1C. Run baseline Si64 benchmark

```bash
cd ~/qe-test/benchmark
# Use existing si64.in from QE 7.4.1 validation
OMP_NUM_THREADS=4 mpirun -np 2 ~/Dev/QE-7_5/q-e-qe-7.5/bin/pw.x < si64.in > si64_baseline_75.out 2>&1
grep '!' si64_baseline_75.out
```

**Record:** wall time, total energy, SCF iteration count. This is the 7.5 baseline.

**Expected outcome:** Energy should be -2990.44276157 Ry (or within ~10^-8 if pseudopotentials or algorithms changed).

### 1D. Diff cegterg.f90 between 7.4.1 and 7.5

This is the critical compatibility check:

```bash
diff ~/qe-test/q-e-qe-7.4.1/KS_Solvers/Davidson/cegterg.f90 \
     ~/Dev/QE-7_5/q-e-qe-7.5/KS_Solvers/Davidson/cegterg.f90
```

**What to look for:**

- **ZGEMM call signatures unchanged?** If yes, the existing 13-line patch applies directly.
- **New ZGEMM calls added?** Need to add corresponding `ab_zgemm` replacements.
- **ZGEMM calls removed or refactored?** Reduce the patch accordingly.
- **New subroutine structure?** May need to add EXTERNAL declaration in new scoping units.
- **MYZGEMM wrapper changes?** Check if QE 7.5 added an intermediary.

Also scan for broader BLAS changes:
```bash
grep -rn "CALL ZGEMM\|CALL DGEMM\|CALL ZHERK\|CALL DSYRK" \
  ~/Dev/QE-7_5/q-e-qe-7.5/KS_Solvers/ \
  ~/Dev/QE-7_5/q-e-qe-7.5/LAXlib/ | head -50
```

**DECISION POINT:** If cegterg.f90 has significant structural changes, the patch strategy must be adapted before proceeding. Stop here and assess.

### 1E. Apply apple-bottom interposition

Assuming ZGEMM calls are compatible:

**In `KS_Solvers/Davidson/cegterg.f90`**, after `IMPLICIT NONE` in each subroutine:
```fortran
      EXTERNAL :: ab_zgemm
```

Replace all `CALL ZGEMM(` with `CALL ab_zgemm(` (expect 12 instances across `cegterg` and `pcegterg` subroutines).

**In `make.inc`** (autoconf) or **CMakeLists.txt** (cmake):
```makefile
DFLAGS = ... -D__APPLE_BOTTOM__
BLAS_LIBS = -L~/Dev/arm/metal-algos/build -lapplebottom \
            -framework Accelerate -framework Metal -framework Foundation -lc++
```

**Critical:** `-lapplebottom` MUST precede `-framework Accelerate` for symbol resolution.

Rebuild only the affected target:
```bash
make clean -C KS_Solvers/Davidson
make -j8 pw
```

Verify linking:
```bash
nm bin/pw.x | grep ab_zgemm
# Should show: _ab_zgemm_ (T = text/code symbol from fortran_bridge.c)
```

### 1F. Run apple-bottom Si64 on QE 7.5

```bash
cd ~/qe-test/benchmark
rm -rf tmp && mkdir -p tmp
AB_PROFILE_FILE=ab_profile.log \
OMP_NUM_THREADS=4 mpirun -np 2 ~/Dev/QE-7_5/q-e-qe-7.5/bin/pw.x < si64.in > si64_gpu_75.out 2>&1

# Check results
grep '!' si64_gpu_75.out
grep 'WALL' si64_gpu_75.out | tail -1
cat ab_profile.log | awk '{print $6}' | sort | uniq -c  # GPU vs CPU routing
```

**Acceptance criteria:**

| Check | Requirement |
|-------|-------------|
| Energy match | Agree with baseline to >= 10 decimal places |
| SCF convergence | Same iteration count as baseline |
| Wall time | Faster than baseline (expect 1.1-1.3x) |
| No crashes | Clean exit, no segfaults |
| Profile log | Shows GPU routing for large ZGEMM calls |

**GATE:** Do not proceed to Phase 2 until 1F passes all acceptance criteria.

---

## Phase 2: Harden for Upstream Contribution

### 2A. Study QE's CUDA integration pattern

Before writing any code, understand how QE handles its existing GPU backend:

```bash
# Find all __CUDA guards in hot paths
grep -rn "__CUDA" ~/Dev/QE-7_5/q-e-qe-7.5/LAXlib/ | head -30
grep -rn "__CUDA" ~/Dev/QE-7_5/q-e-qe-7.5/KS_Solvers/ | head -30

# CMake GPU configuration
grep -rn "CUDA\|GPU\|DEVICE" ~/Dev/QE-7_5/q-e-qe-7.5/cmake/*.cmake | head -30

# DeviceXlib GPU dispatch
ls ~/Dev/QE-7_5/q-e-qe-7.5/external/devxlib/src/
```

**Document:**
1. CMake variable names (`QE_ENABLE_CUDA`, `QE_GPU_BACKEND`, etc.)
2. Which Fortran files have `__CUDA` guards
3. How devxlib dispatches between CPU/GPU BLAS
4. The `#if defined(__CUDA)` ... `#else` ... `#endif` pattern in Fortran

### 2B. Implement `__METAL` preprocessor guards

Following the `__CUDA` precedent, create conditional compilation:

**New file: `cmake/QEMetal.cmake`**
```cmake
option(QE_ENABLE_METAL "Enable Metal GPU acceleration via apple-bottom" OFF)

if(QE_ENABLE_METAL)
  if(NOT APPLE)
    message(FATAL_ERROR "Metal backend requires macOS with Apple Silicon")
  endif()

  find_library(METAL_FRAMEWORK Metal REQUIRED)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)

  # Find apple-bottom library
  find_library(APPLE_BOTTOM_LIB applebottom
    PATHS /usr/local/lib
          $ENV{APPLE_BOTTOM_ROOT}/build
          ${APPLE_BOTTOM_ROOT}/build)
  if(NOT APPLE_BOTTOM_LIB)
    message(FATAL_ERROR
      "apple-bottom library not found. Install it or set APPLE_BOTTOM_ROOT.")
  endif()

  message(STATUS "Metal GPU backend enabled via apple-bottom")
  add_definitions(-D__METAL)
endif()
```

**Modified: `KS_Solvers/Davidson/cegterg.f90`**
```fortran
#if defined(__METAL)
      EXTERNAL :: ab_zgemm
#endif
      ...
#if defined(__METAL)
      CALL ab_zgemm( ... )
#else
      CALL ZGEMM( ... )
#endif
```

**Design constraints:**
- Guards ONLY in cegterg.f90 initially (the validated hot path)
- The Fortran bridge handles all routing logic -- the guard just switches the entry symbol
- No changes to call signatures, argument order, or data layout
- Must compile cleanly with `__METAL` undefined (zero impact on non-Apple platforms)

### 2C. Validate the guarded build

Build QE 7.5 three ways and verify all produce correct results:

1. **Without Metal:** `cmake .. ` (no `-DQE_ENABLE_METAL`) -- must match clean baseline exactly
2. **With Metal:** `cmake .. -DQE_ENABLE_METAL=ON -DAPPLE_BOTTOM_ROOT=~/Dev/arm/metal-algos` -- must match baseline to 10+ decimal places
3. **Autoconf path:** Verify the `make.inc` approach still works for users who don't use CMake

### 2D. Build the benchmark matrix

The QE team will want evidence across system sizes. Create benchmarks for:

| System | Atoms | k-points | Config A (CPU) | Config B (GPU) |
|--------|-------|----------|----------------|----------------|
| Si8 | 8 | 1 | Accelerate | apple-bottom |
| Si16 | 16 | 1 | Accelerate | apple-bottom |
| Si32 | 32 | 1 | Accelerate | apple-bottom |
| Si64 | 64 | 1 | Accelerate | apple-bottom |
| Si128 | 128 | 1 | Accelerate | apple-bottom |

For each, record: wall time, energy, SCF iterations, GPU routing fraction, speedup.

**Expected pattern:** Speedup increases with system size (larger matrices = more GPU benefit). Si8/Si16 may show no speedup or slight slowdown (below FLOP threshold).

### 2E. Address known limitations before merge

The merge proposal should be transparent about current scope:

| Limitation | Status | Plan |
|------------|--------|------|
| Single k-point only validated | Known | Document; multi-k testing in Phase 3 |
| Spin-unpolarized only | Known | Document; spin-polarized doubles ZGEMM count |
| beta != 0 falls back to CPU | By design | Document as feature (hybrid routing) |
| Rectangular aspect > 10:1 | Bug | Fix on `fix/rectangular-gemm` branch before merge |
| M2 Max only tested | Known | Request community testing on M1/M3/M4 |
| cegterg.f90 only | Intentional | Start conservative; expand after acceptance |

---

## Phase 3: Prepare and Submit the Merge Request

### 3A. Pre-submission: Email the QE developers list

**Before writing any merge request code,** send an introductory email to `developers@lists.quantum-espresso.org`. The QE community expects discussion before code.

Draft subject: "Proposal: Metal GPU backend for Apple Silicon via double-float BLAS"

Key points to cover:
- What: DD arithmetic achieves FP64-class precision on Apple GPU (no native FP64)
- Results: 1.22x speedup on Si64, 11-decimal energy agreement, 47% CPU reduction
- Approach: Follows `__CUDA` precedent with `__METAL` guards, minimal footprint (1 file + CMake module)
- Library: MIT licensed, NASA-STD-7009A V&V documentation, 48/48 tests passing
- Ask: Does this align with QE GPU strategy? Which routines beyond cegterg would benefit most?

**GATE:** Do not proceed to 3B until you receive feedback (or 2 weeks pass with no objection).

### 3B. Fork and branch

```bash
git clone https://gitlab.com/QEF/q-e.git ~/Dev/qe-upstream
cd ~/Dev/qe-upstream
git checkout develop
git checkout -b feature/metal-gpu-backend
```

### 3C. Files to create/modify in the merge request

| File | Action | Description |
|------|--------|-------------|
| `cmake/QEMetal.cmake` | **Create** | Metal/apple-bottom detection module |
| `CMakeLists.txt` | **Modify** | Add `include(cmake/QEMetal.cmake)`, link targets |
| `KS_Solvers/Davidson/cegterg.f90` | **Modify** | Add `__METAL` guards around 12 ZGEMM calls |
| `install/make.inc.in` | **Modify** | Add Metal BLAS_LIBS template |
| `Doc/user_guide/` | **Modify** | Add Metal build instructions section |
| `README_GPU.md` | **Modify** | Add Apple Silicon / Metal section |

### 3D. QE Fortran style compliance

All Fortran changes must follow QE conventions:
- CAPS for keywords (`CALL`, `SUBROUTINE`, `IF`, `END`)
- lowercase for variables
- 3-space indent
- `IMPLICIT NONE` in every routine
- Max 132 characters per line
- `!` for comments

### 3E. Submit GitLab merge request

Target branch: `develop` (NOT `main`)
Title: "Add Metal GPU backend for Apple Silicon (apple-bottom BLAS)"

MR body should include:
- Summary of approach and results
- Link to apple-bottom repo (https://github.com/grantdh/apple-bottom)
- Link to V&V report and benchmark data
- Build instructions for reviewers
- Note that CI will pass (compile-only; no Metal GPU on runners)

### 3F. Parallel track: apple-bottom repo preparation

For the merge to succeed, apple-bottom itself needs:

1. **Stable release:** Tag v1.3.0 (or v2.0.0 if breaking changes)
2. **Installation docs:** `make install` and CMake `find_package` support (already in CMakeLists.txt)
3. **Homebrew formula:** Enable `brew install apple-bottom` for easy adoption
4. **CI badges:** Show test status in README
5. **CITATION.cff:** Already present, verify DOI if available

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| cegterg.f90 restructured in 7.5 | High | Low | Diff check in Phase 1D; adapt patch |
| QE 7.5 adds new ZGEMM calls | Medium | Medium | grep scan; add guards to new calls |
| QE team rejects Metal approach | High | Medium | Pre-discussion email (Phase 3A) |
| Precision regression on 7.5 | High | Low | Si64 energy match validation |
| Build system incompatibility | Medium | Medium | Test both CMake and autoconf paths |
| Rectangular matrix bug hits QE | Medium | Low | Fix branch before merge; document limitation |
| Community lacks M-series hardware for review | Medium | High | Provide detailed benchmark data; offer to run tests |

---

## Timeline Estimate

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 0: Pre-work | 1-2 hours | Commit pending changes, rebuild |
| Phase 1: Build + validate QE 7.5 | 2-4 hours | QE 7.5 download, Si64 input files |
| Phase 2: Harden | 1-2 days | Phase 1 gate passed |
| Phase 3: Merge prep | 1-2 weeks | Developer list feedback |
| Review cycle | 2-6 weeks | QE maintainer availability |

---

## Quick Reference: Key Paths

| Resource | Path |
|----------|------|
| apple-bottom source | `~/Dev/arm/metal-algos/src/` |
| Built library | `~/Dev/arm/metal-algos/build/libapplebottom.a` |
| Fortran bridge | `~/Dev/arm/metal-algos/src/fortran_bridge.c` |
| QE 7.5 source | `~/Dev/QE-7_5/q-e-qe-7.5/` (to be downloaded) |
| QE 7.4.1 reference | `~/qe-test/q-e-qe-7.4.1/` |
| Si64 benchmark | `~/qe-test/benchmark/si64.in` |
| Integration test | `~/Dev/arm/metal-algos/tests/test_qe_integration.sh` |
| V&V report | `~/Dev/arm/metal-algos/docs/vv/VV_REPORT.md` |
| Existing merge plan | `~/Dev/arm/metal-algos/.claude/commands/qe-75-merge.md` |

## Quick Reference: Validation Commands

```bash
# apple-bottom unit tests (must pass before any QE work)
cd ~/Dev/arm/metal-algos && make clean && make test

# QE integration check (update QE_DIR first)
QE_DIR=~/Dev/QE-7_5/q-e-qe-7.5 ./tests/test_qe_integration.sh

# Si64 benchmark (GPU)
cd ~/qe-test/benchmark && rm -rf tmp && mkdir -p tmp
AB_PROFILE_FILE=ab_profile.log \
OMP_NUM_THREADS=4 mpirun -np 2 ~/Dev/QE-7_5/q-e-qe-7.5/bin/pw.x < si64.in > out.log 2>&1
grep '!' out.log && grep 'WALL' out.log | tail -1

# Symbol verification
nm ~/Dev/QE-7_5/q-e-qe-7.5/bin/pw.x | grep ab_zgemm
```
