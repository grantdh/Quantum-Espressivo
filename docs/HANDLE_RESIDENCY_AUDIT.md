# Espressivo — GPU-Resident Handle Audit

**Author:** Grant Heileman (with audit assistance)
**Date:** 2026-04-15
**Scope:** QE 7.5 hot path (Davidson diagonalizer + h_psi + s_psi)
**Goal:** Eliminate per-call FP64↔DD conversion in the Fortran bridge by holding DD-format Metal buffers across Davidson iterations and SCF cycles.

---

## 1. Executive Summary

**The single most important finding of this audit:** QE 7.5 already contains a complete, well-designed GPU-residency scaffolding in the form of OpenACC directives. The `psi`, `hpsi`, `spsi`, `hc`, `sc`, `vc`, and `ew` arrays are all annotated with `!$acc declare device_resident` or `!$acc enter data create`, every BLAS region is wrapped in `!$acc host_data use_device(...)`, and every CPU↔GPU synchronization point is explicit via `!$acc update host` / `!$acc update device`.

On an NVIDIA target compiled with nvfortran, these directives produce real CUDA residency. On macOS with gfortran (the current Espressivo build), the directives compile as no-ops. The host_data region simply returns host pointers, which flow into `ab_zgemm_`, which uploads, computes, and downloads — incurring O(M·K + K·N + M·N) memory traffic per call, 867 times per SCF, ~14 SCFs per run.

The quickest, cleanest path to "super fast" Espressivo is therefore **not** to invent a parallel handle-based API from scratch, but to **implement the OpenACC directives that QE already has in place** against a Metal backend. This gives us GPU residency with zero additional source edits to QE beyond what is already patched (the `ZGEMM → ab_zgemm` rename).

Estimated end-to-end impact at NP=1 on si216: the 263 GPU-routed ZGEMMs currently incur ~263 × (upload + download) transfer overhead. At typical Davidson sizes (kdim ≈ 3500, nvec ≈ 500, kdmx = npwx·npol ≈ 7500), each upload is ~30 MB and each download ~2 MB for the output alone. Total eliminated traffic per SCF: ≈ 8 GB. On 400 GB/s unified memory this is ≈ 20 ms/SCF hidden today — small individually, but coupled with the command-buffer encoding cost and the avoided DD re-expansion on every call, we estimate 2–4× speedup on the `auto` dispatch path once residency is wired in.

---

## 2. QE 7.5 Hot-Path Call-Site Inventory

All line numbers reference the pristine (un-patched) QE 7.5 sources under `deps/qe-7.5/`.

### 2.1 `KS_Solvers/Davidson/cegterg.f90` — 12 ZGEMM sites

| # | Line | Role | Phase | A | B | C | m×n×k shape (typical si216) |
|---|-----:|---|---|---|---|---|---|
| 1 | 207 | `hc = psiᴴ · hpsi` | init, build H subspace | `psi` | `hpsi` | `hc` | nbase × my_n × kdim |
| 2 | 220 | `sc = psiᴴ · spsi` (uspp) | init, build S subspace | `psi` | `spsi` | `sc` | nbase × my_n × kdim |
| 3 | 226 | `sc = psiᴴ · psi` (norm-conserving) | init, build S subspace | `psi` | `psi` | `sc` | nbase × my_n × kdim |
| 4 | 351 | subspace rotation of `spsi` | correction vector | `spsi` | `vc` | tmp | kdim × notcnv × my_n |
| 5 | 357 | subspace rotation of `psi` (nc) | correction vector | `psi` | `vc` | tmp | kdim × notcnv × my_n |
| 6 | 392 | subspace rotation of `hpsi` | residual computation | `hpsi` | `vc` | tmp | kdim × notcnv × my_n |
| 7 | 476 | `hc = hpsi(nb1)ᴴ · psi` | add new columns to H | `hpsi` | `psi` | `hc` | notcnv × my_n × kdim |
| 8 | 491 | `sc = spsi(nb1)ᴴ · psi` (uspp) | add new columns to S | `spsi` | `psi` | `sc` | notcnv × my_n × kdim |
| 9 | 496 | `sc = psi(nb1)ᴴ · psi` (nc) | add new columns to S | `psi` | `psi` | `sc` | notcnv × my_n × kdim |
| 10 | 586 | final `evc = psi · vc` | extract converged eigenvectors | `psi` | `vc` | `evc` | kdim × nvec × my_n |
| 11 | 620 | final `spsi = spsi · vc` | update overlap basis | `spsi` | `vc` | out | kdim × nvec × my_n |
| 12 | 629 | final `hpsi = hpsi · vc` | update H basis | `hpsi` | `vc` | out | kdim × nvec × my_n |

Every one of these is already patched to `ab_zgemm` in `src-metal/KS_Solvers/Davidson/cegterg.f90`.

### 2.2 `PW/src/h_psi.f90` — 19 `!$acc` directives, no direct ZGEMM

`h_psi` calls internal kernels (`vloc_psi`, `add_vuspsi`) and relies on `!$acc host_data use_device(hpsi)` at L61, L68, L293, L301. CPU-side work on psi/hpsi is bracketed by `!$acc update host/device` at L282–327.

### 2.3 `PW/src/s_psi.f90` — 60 `!$acc` directives, 1 internal `ZGEMM`

The internal `ZGEMM` at ≈L310 (inside `s_psi_k`) is already wrapped by `!$acc host_data use_device(vkb, ps, spsi)` at L254, L259. The `ps` / `becp` workspaces are declared `device_resident` at L210, L286.

### 2.4 `KS_Solvers/Davidson/regterg.f90` — real (non-complex) variant

70 OpenACC directives, analogous ZGEMM→DGEMM sites. Lower priority than `cegterg.f90` because complex PW runs dominate production.

---

## 3. Matrix Lifetime Table

**Legend:** `SCF-persistent` = allocated once in `c_bands.f90`, reused across Davidson entries. `Davidson-persistent` = allocated at cegterg entry, reused across inner iterations. `Inner-persistent` = reused across one Davidson step.

| Matrix | Size (elements) | Lifetime | Allocator | Current `!$acc` | CPU writes during GPU life? |
|---|---|---|---|---|---|
| `evc` | `npwx·npol × nbnd` | SCF-persistent | `wfc_gpu` (outside cegterg) | pre-existing `host_data` at L183, L201, L585, L614 | yes — `davcio` I/O, `diag_bands` swapping |
| `psi` | `npwx·npol × nvecx` | Davidson-persistent | L146 | `enter data create` L152, `exit delete` L683 | yes — see §4 |
| `hpsi` | `npwx·npol × nvecx` | Davidson-persistent | L149 | `enter data create` L152, `exit delete` L683 | rarely — inside `h_psi` via `update host` at L282 |
| `spsi` | `npwx·npol × nvecx` | Davidson-persistent (uspp only) | L155 | `enter data create` L158, `exit delete` L679 | rarely |
| `hc`, `sc` | `nvecx × nvecx` | Davidson-persistent | L161, L164 | `device_resident` at L86 | **yes** — `mp_sum` at L211/213/481/483 (MPI) |
| `vc` | `nvecx × nvecx` | Davidson-persistent | L167 | `device_resident` at L86 | **yes** — populated by `cdiaghg` on CPU path, `mp_bcast` at L291/546 |
| `ew` | `nvecx` | Davidson-persistent | L170 | `enter data create` L173, `exit delete` L672 | yes — `mp_sum` at L433 |
| `conv` | `nvec` (logical) | Davidson-persistent | L174 | CPU-resident; `copy(conv)` at L554 | n/a |

### 3.1 Allocation / deallocation sites (cegterg)

Allocate (`psi`, `hpsi`, `spsi`, `hc`, `sc`, `vc`, `ew`, `conv`): L146–174
Deallocate: L669–685

These are the exact source-line targets where Espressivo's Metal backend must intercept OpenACC entry/exit to allocate `MTLBuffer`s in DD layout.

### 3.2 `evc` — the one true SCF-persistent matrix

Allocated in `PW/src/wvfct.f90` (module `wvfct`, name `et`/`wg`/`etot`) and populated in `PW/src/c_bands.f90`. Lifetime spans the entire SCF cycle (14 iterations for si216). The `davcio` I/O checkpoint reads/writes `evc` to disk between k-points at certain nk3s values — this is a mandatory `update host` point.

Cross-iteration persistence of `evc` in DD form on the GPU is the single biggest potential win, because `evc` is the input to the next SCF's Davidson call (at L183 via `dev_memcpy(psi, evc, ...)`). Today every SCF does a full FP64→DD re-expansion on entry and a DD→FP64 re-compression on exit. DD-persistent `evc` eliminates both.

---

## 4. Dependency Hazards (things that break naïve residency)

These are the places where CPU code genuinely touches device-resident data and must drive an `update host` / `update device` pair, or where the residency invariant crosses a module boundary. Getting these right is the entire correctness burden of the project.

| # | Hazard | File:Line | Why it matters |
|---|---|---|---|
| H1 | `mp_sum(hc)`, `mp_sum(sc)` after subspace build | cegterg.f90:211/213/233/235/481/483/503/505 | MPI reductions require host pointers under Open MPI; must `update host → mp_sum → update device` |
| H2 | `cdiaghg` / `pcdiaghg` diagonalization | called at ~L253–298 | Produces eigenvectors `vc` and eigenvalues `ew`. CPU-path `cdiaghg` runs in host memory; ScaLAPACK path `pcdiaghg` already has its own GPU hooks. |
| H3 | `mp_bcast(vc)`, `mp_bcast(ew)` | L291–292, L546–547 | Same as H1 — round trip through host |
| H4 | `h_psi_ptr(psi, hpsi)` call | L190, L463 | Enters `h_psi.f90` which does its own residency dance (update host at L282 for certain code paths). Must not assume psi/hpsi stay resident through the whole call. |
| H5 | `s_psi_ptr(psi, spsi)` call | L194, L465 | Same pattern as H4 |
| H6 | `g_psi_ptr(psi(:,nb1), ew)` call | L405 | Precondition-filter; currently relies on host access |
| H7 | `mp_sum(psi(:,nb1:nbase+notcnv), inter_bgrp_comm)` | L394 | Inter-band-group reduction of new psi columns after residual scaling |
| H8 | `mp_sum(ew)` | L433 | Reduction of correction-vector norms |
| H9 | `mp_sum(evc)`, `mp_sum(spsi)`, `mp_sum(hpsi)` (final) | L588, L625, L634 | Final inter-band-group reductions before cegterg exits |
| H10 | `dev_memcpy(psi, evc, ...)` | L184, L615 | Depends on whether both sides are device-resident. If `evc` is GPU-resident and `psi` is GPU-resident, this should be a device-to-device copy, NOT a round trip through host. |
| H11 | `!$acc parallel loop` sections on hc/sc/vc at L242–260, L324, L332, L365–373, L413–430, L437, L516–536, L554, L646–661 | cegterg.f90 | These are small kernels that QE runs on the GPU via OpenACC. On macOS with gfortran they currently run on the CPU; Espressivo's Metal OpenACC backend must either (a) emit Metal kernels for these, or (b) flush to host, run on CPU, push back — acceptable for correctness, suboptimal for perf. |
| H12 | `davcio` I/O checkpoint on `evc` | `PW/src/c_bands.f90` | Filesystem I/O requires host pointer; mandatory full sync |

**H11 is the one architectural constraint that could force a Metal-kernel compiler.** However, inspection shows these `!$acc parallel loop` regions are all small: O(nvecx) or O(nbnd) elementwise operations. For the first production cut, flushing hc/sc/vc/ew back to host for these loops is acceptable (~1 ms per SCF overhead on si216). A later optimization would hand-write Metal kernels for them.

---

## 5. Recommended Architecture (Espressivo Production Design)

### 5.1 Top-level decision

**Do not invent a new handle-based Fortran API.** QE 7.5's OpenACC directives *are* the handle-based API. Implement them in Metal.

### 5.2 Three-layer stack

```
+--------------------------------------------------------+
|  QE 7.5 (cegterg, h_psi, s_psi) — unchanged source     |
|  except the existing ZGEMM → ab_zgemm patches          |
+--------------------------------------------------------+
|  libespressivo_acc.dylib — Espressivo residency layer  |
|   - intercepts !$acc enter data / exit data            |
|   - maintains an address→MTLBuffer registry            |
|   - implements !$acc update host / update device       |
|   - implements !$acc host_data use_device(...)         |
|     by returning a "fat pointer" that ab_zgemm         |
|     recognizes                                          |
+--------------------------------------------------------+
|  libapplebottom.dylib — extended Fortran bridge         |
|   - ab_zgemm_ / ab_dgemm_ check fat-pointer tags       |
|   - fast path: buffers already resident + DD-expanded; |
|     enqueue kernel, no upload, no download             |
|   - slow path: today's upload-compute-download         |
+--------------------------------------------------------+
|  Metal (unchanged kernels, DD-DGEMM / DD-ZGEMM)         |
+--------------------------------------------------------+
```

### 5.3 How the OpenACC → Metal interception works

Two implementation strategies, in order of preference:

**Strategy A — OpenACC runtime library shim (recommended).** Most compilers that recognize `!$acc` directives without a real OpenACC target compile them as calls to a runtime library (`__pgi_uacc_*`, `acc_malloc`, `acc_memcpy_to/from_device`, `acc_map_data`). Build `libespressivo_acc.dylib` that exports the OpenACC runtime ABI. Link QE against it *instead of* letting gfortran elide the directives. Every directive becomes a call into our runtime, which manages Metal buffers. **No QE source changes beyond the existing patches.**

Risk: gfortran on macOS may not emit any runtime calls for `!$acc`; it may simply discard them at parse time (need to verify with `-fdump-tree-gimple` or equivalent). If so, fall back to Strategy B.

**Strategy B — Explicit Espressivo directives (`!$ab`).** Add a small Fortran module `espressivo_residency` with routines:

```fortran
CALL ab_enter_data_create(psi, size)        ! allocate MTLBuffer
CALL ab_exit_data_delete(psi)               ! free MTLBuffer
CALL ab_host_data_use_device(psi, dev_ptr)  ! look up MTLBuffer
CALL ab_update_host(psi)                    ! DD→FP64 pull
CALL ab_update_device(psi)                  ! FP64→DD push
CALL ab_dev_memcpy(dst, src, ...)           ! GPU-to-GPU
```

Source-patch QE to mirror every `!$acc` directive with an `ab_*` call. One-time cost: ~60 lines touched in cegterg.f90, ~30 in h_psi.f90, ~40 in s_psi.f90. Maintenance cost: when QE updates these files, re-apply `ab_*` patches. Acceptable because Espressivo already tracks QE versions.

### 5.4 Fat-pointer protocol for `ab_zgemm`

Extend the Fortran bridge to recognize device-resident matrices without changing its Fortran-visible signature (callers still pass `ab_zgemm` the same array). Use a two-level lookup:

1. On entry, `ab_zgemm_` checks whether `A` (and `B`, `C`) lie inside a registered host address range in the residency registry.
2. If yes, `A` is device-resident: fetch the `MTLBuffer` handle and flag "no upload needed."
3. If every operand is resident, enqueue the DD-ZGEMM kernel with device pointers only.
4. If `C` is resident, skip the download.
5. Result stays on the device.

The registry is hit a handful of times per SCF (once at `enter data create`, once at `exit data delete`), so lookup cost is amortized over thousands of `ab_zgemm_` calls. A perfect hash of `(address / PAGE_SIZE)` gives O(1) lookup with negligible overhead.

### 5.5 DD layout decision

Keep DD-expanded (2× memory) layout on the device for everything that participates in a GPU ZGEMM. `evc` in DD is 2× size but still tiny (e.g. si216: 500 × 7500 × 16 B × 2 ≈ 120 MB). Memory is plentiful on M2 Max (96 GB unified); we're not memory-bound here.

On `update host` we collapse DD → FP64 during the download. On `update device` we expand FP64 → DD during the upload. Today's bridge already does this per call; the new bridge does it per *lifetime boundary*, which for Davidson matrices is once per Davidson entry, not once per ZGEMM.

---

## 6. Prioritized Integration Roadmap (6-month production horizon)

### Month 1 — Foundation (weeks 1–4)

- **Week 1**: Verify whether gfortran+libgomp emits any callable OpenACC runtime stubs on macOS. If yes, Strategy A; if no, Strategy B. Deliverable: `docs/OPENACC_ON_MACOS.md` with the decision.
- **Week 2**: Implement the address→MTLBuffer registry in apple-bottom. Extend `ab_zgemm_` with fat-pointer fast path. All existing tests must still pass (56/56 → 56/56). New test: bench a 1024×1024×1024 ZGEMM called 100× with pre-registered buffers vs. 100× with cold buffers — measure upload/download savings.
- **Week 3**: Implement `ab_enter_data_create` / `ab_exit_data_delete` / `ab_update_host` / `ab_update_device` as C primitives. Unit tests with a minimal Fortran driver.
- **Week 4**: Wire up the Davidson `psi` and `hpsi` matrices through the new API on a toy branch. Validate Si64 at NP=1 produces bit-identical energy to baseline.

### Month 2 — Davidson coverage (weeks 5–8)

- Extend to `spsi`, `hc`, `sc`, `vc`, `ew`.
- Handle H1–H3 MPI reduction hazards explicitly.
- Handle H4–H6 h_psi/s_psi/g_psi boundaries: because `h_psi.f90` has its own `!$acc` directives, the semantics should compose — verify carefully.
- H11: for now, flush hc/sc/vc to host for the elementwise `!$acc parallel loop` regions. Measure overhead; budget is ≤5% of SCF time.
- Target milestone: si216 NP=1 `AB_MODE=auto` runs with all Davidson matrices DD-resident for the full inner iteration. Expected speedup: 1.5–2.5× over current 1240 s.

### Month 3 — SCF-level persistence (weeks 9–12)

- Extend residency to `evc`, crossing the cegterg ↔ c_bands boundary.
- Handle H12 (`davcio`): flush `evc` to host at checkpoint boundaries only.
- Eliminate per-SCF `dev_memcpy(psi, evc, ...)` round-trip (H10) — direct Metal blit.
- Target milestone: end-to-end si216 SCF with DD-persistent `evc` across iterations. Expected additional 10–20% win.

### Month 4 — regterg + non-cegterg paths (weeks 13–16)

- Port everything to `regterg.f90` (real-arithmetic Davidson, DGEMM).
- Investigate RMM-DIIS solver (KS_Solvers/RMM) — if hot enough, repeat the exercise.
- Handle `s_psi_k` / `s_psi_gamma` internal ZGEMM at s_psi.f90:310.

### Month 5 — ScaLAPACK boundary (weeks 17–20)

- This is where we address the N_P ≥ 4 ndiag bypass identified in the CPiC paper.
- Option 1: patch ScaLAPACK's internal `zgemm_` call sites to `ab_zgemm_` (clone scalapack-2.2.x, rebuild, re-link). Intercept at the same fat-pointer level.
- Option 2: replace ScaLAPACK with ELPA as documented in §2 of QE's README_GPU.md; ELPA uses standard `zgemm_` symbol resolution and links directly against apple-bottom.
- Deliverable: production NP=4 / NP=8 benchmarks with `ab_zgemm_` dispatched count ≠ 0.

### Month 6 — hardening, upstream patches, paper (weeks 21–24)

- Soak tests: si64_500b, si216, si512 (new system) — 24 h uninterrupted.
- `__METAL` preprocessor guards per §3 of `docs/QE75_INTEGRATION.md`.
- Open PR against QE 7.5 master with the `__METAL` backend.
- Write follow-up paper: "GPU-resident DD-BLAS for Quantum ESPRESSO via OpenACC-to-Metal residency."

---

## 7. Open Questions to Resolve Before Week 2

1. Does gfortran on macOS (14.2 at time of writing) emit runtime calls for `!$acc`, or silently ignore the directives? Check via `-fopenacc -fdump-tree-original`. If silently ignored, Strategy A is dead and we take the explicit-`ab_*` Strategy B route from day one.
2. What is the actual DD-buffer registration cost vs. Metal buffer allocation cost for a Davidson-sized matrix (e.g. 7500 × 500)? Benchmark before committing to the fat-pointer design.
3. Does ScaLAPACK's `pzheevd` internally call `zgemm_` or a vendor-specific entry point? If vendor-specific, ELPA migration is the right Month 5 plan; if standard `zgemm_`, we can stay on ScaLAPACK and just relink.
4. `dev_memcpy` (cegterg.f90:184, 615) — is this a QE-internal routine that we can redirect to `ab_dev_memcpy`, or does it already dispatch via OpenACC? Check `Modules/cuda_util.f90` or the equivalent.

---

## 8. File / Symbol Checklist for Implementers

Everything below is a concrete target for Month 1 work.

### apple-bottom

- `src/fortran_bridge.c:17-60` — extend `ab_dgemm_` / `ab_zgemm_` with fat-pointer check
- `src/core/apple_bottom.h:18-40` — existing opaque handle API is fine as-is
- `src/residency.c` — new file; address→MTLBuffer registry
- `include/espressivo.h` — new public header for Strategy-B directives

### Espressivo

- `scripts/patch-qe.sh` — add mirror-`!$acc`→`!$ab` pass (Strategy B) OR `acc_runtime` shim link (Strategy A)
- `deps/qe-7.5/src-metal/KS_Solvers/Davidson/cegterg.f90:146-174` — annotate allocators
- `deps/qe-7.5/src-metal/KS_Solvers/Davidson/cegterg.f90:669-685` — annotate deallocators
- `deps/qe-7.5/src-metal/PW/src/h_psi.f90:282-327` — respect existing `update host/device` pattern
- `deps/qe-7.5/src-metal/PW/src/s_psi.f90:210-267` — analogous

### Tests

- `tests/test_qe_integration.sh` — extend with `AB_RESIDENCY=on/off` comparison
- new: `tests/test_residency_unit.c` — registry correctness
- new: `tests/test_davidson_residency.f90` — end-to-end Fortran driver that mimics cegterg's matrix lifecycle on a small problem

---

## Appendix A — Per-site data-flow for cegterg.f90 ZGEMM #1 (illustrative)

```
Line 183:  !$acc host_data use_device(evc, psi)
Line 184:    dev_memcpy(psi ← evc)               [DEVICE-TO-DEVICE]
Line 186:  !$acc end host_data

Line 190:    h_psi_ptr(psi, hpsi)                [hpsi filled on device]

Line 201:  !$acc host_data use_device(evc, psi, hpsi, spsi, hc, sc)
Line 207:    CALL ab_zgemm('C','N', nbase, my_n, kdim,
                          ONE, psi,  kdmx,
                               hpsi, kdmx,
                          ZERO, hc,   nvecx)
           [TODAY:     uploads psi(npwx·npol × nvecx) + hpsi(same) ≈ 240 MB,
                      computes, downloads hc(nvecx²) ≈ 2 MB per call]
           [RESIDENCY: all three resident; enqueue kernel, return immediately]

Line 211:  CALL mp_sum( hc, ..., intra_bgrp_comm )
           [HAZARD H1: hc is device-resident but MPI needs host pointer.
                       update host(hc) → mp_sum → update device(hc)]

Line 238:  !$acc end host_data
```

Savings on this single site (si216 scale): ~240 MB upload eliminated. Happens once per Davidson entry (≈ 14 SCF iterations, 1 cegterg call each). Site 10 (L586) saves twice that on the final evc construction.

---

*End of audit. Next action: answer Open Questions #1 and #2 this week to select Strategy A vs. Strategy B.*
