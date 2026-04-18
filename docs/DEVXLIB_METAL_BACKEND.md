# DevXlib — Metal Backend Design & apple-bottom Device ABI

**Author:** Grant Heileman (audit companion doc)
**Date:** 2026-04-15
**Scope:** The MaX Centre DevXlib library (vendored at `deps/qe-7.5/external/devxlib/`) and the apple-bottom second API surface that implements its backend contract.
**Purpose:** Lock the exact function signatures, compilation model, and source-patch surface needed to upstream a Metal backend to `gitlab.com/max-centre/components/devicexlib`.
**Companion to:** `HANDLE_RESIDENCY_AUDIT.md`

---

## 1. Major Architectural Finding

**DevXlib does not provide a GEMM abstraction.** This was the key expectation to verify, and the answer changes the backend design materially.

`src/device_linalg.f90` contains only memcpy / memset / conjugation utilities — no `zgemm`/`dgemm` wrappers. When QE code does `CALL ZGEMM(...)` inside a `!$acc host_data use_device(...)` region, the `zgemm` symbol is resolved at *link time* — to cuBLAS when built with nvfortran+cublas, or to host BLAS otherwise. DevXlib is deliberately out of the BLAS dispatch loop.

This splits our backend work cleanly into two independent contributions:

1. **DevXlib Metal backend** — buffer-pool and memcpy primitives only. Contributed to `gitlab.com/max-centre/components/devicexlib` as a new `__METAL` conditional-compilation arm alongside `__CUDA` and `__OPENACC`.
2. **apple-bottom device-BLAS API** — the device-pointer `ab_dev_zgemm` / `ab_dev_dgemm` entry points. Resolved at link time just like cuBLAS; Espressivo's `__METAL` QE patches arrange for `zgemm` to bind to `ab_dev_zgemm` when the arguments are Metal buffer handles.

---

## 2. DevXlib Build Model (the pattern we must match)

### 2.1 Preprocessor guards

From `include/device_macros.h`:

```c
#if defined(__CUDA) || defined(__OPENACC) || defined(__OPENMP5)
#  define __HAVE_DEVICE
#endif
```

`__HAVE_DEVICE` is the umbrella symbol that toggles on the device-aware code paths. Every device primitive has the structure:

```fortran
#if defined(__HAVE_DEVICE)
subroutine dp_memcpy_h2d_c2d(array_out, array_in, ...)
#if defined(__CUDA)
    attributes(device) :: array_out
    ierr = cudaMemcpy2D(...)
#else
    array_out(...) = array_in(...)          ! host-only fallback
#endif
end subroutine
#endif
```

The `__CUDA` block is the only "real" device path today. `__OPENACC` and `__OPENMP5` exist as umbrella flags that let DevXlib compile in device-aware mode without mandating a specific device backend — the actual data movement then happens via OpenACC / OpenMP 5 target directives elsewhere in the caller.

### 2.2 Naming-convention macros

From `include/dev_defs.h`:

```c
#ifdef _CUDA
#  define DEV_SUBNAME(x)        CAT(x,_gpu)
#  define DEV_VARNAME(x)        CAT(x,_d)
#  define DEV_ATTRIBUTE         , device
#else
#  define DEV_SUBNAME(x)        x
#  define DEV_VARNAME(x)        x
#  define DEV_ATTRIBUTE
#endif
```

`DEV_SUBNAME(foo)` yields `foo_gpu` under CUDA and `foo` under CPU. `DEV_ATTRIBUTE` injects the `, device` attribute on declarations so that Fortran arrays can be device-resident when built with nvfortran. These are the hooks the Metal backend must extend.

### 2.3 Code-generation pipeline

DevXlib is largely auto-generated. `src_generator/*.jf90` are Jinja2 templates that produce the 9297-line `device_memcpy.f90` and the 3080-line `device_fbuff.f90`. Adding a backend means:

1. Edit the `.jf90` templates to emit Metal-specific arms.
2. Re-run the Python generator scripts (`generate_memcpy.py`, `generate_fbuff.py`, `generate_auxfunc.py`).
3. Check in both the templates and the regenerated `.f90` — DevXlib's convention is to commit the generated output alongside the templates.

This is the maintainer-approved upstream pattern; any Metal MR has to follow it.

---

## 3. DevXlib Primitive Inventory

The three modules that must grow a `__METAL` arm.

### 3.1 `device_fbuff.f90` — buffer pool (3080 lines generated)

Public API (from the template at `src_generator/device_fbuff.jf90:31-77`):

| Procedure | Purpose | Metal semantics |
|---|---|---|
| `fbuff%init(info, verbose)` | initialize buffer pool | allocate MTLHeap or leave lazy |
| `fbuff%lock_buffer(p, size, info)` | get a buffer, optionally reused from pool | allocate or find-free MTLBuffer |
| `fbuff%release_buffer(p, info)` | return buffer to pool (but don't free) | mark free in pool |
| `fbuff%prepare_buffer(p, size, info)` | ensure a buffer of ≥size exists, unlocked | allocate if needed, leave unlocked |
| `fbuff%dealloc()` | free all buffers | release every MTLBuffer |
| `fbuff%reinit(info)` | same as dealloc | same |
| `fbuff%dump_status(unit)` | diagnostic | iterate MTLBuffer list |
| `fbuff%print_report()` | diagnostic | same |

The buffer type is a linked list of `Node` records, each holding a `BYTE, POINTER :: space(:)` under CUDA decorated with `attributes(device)`. Under `__METAL` we can't use the `attributes(device)` mechanism (gfortran doesn't have it), so the right move is:

```fortran
#if defined(__CUDA)
    BYTE, POINTER, device :: space(:)
#elif defined(__METAL)
    type(c_ptr) :: metal_buffer          ! opaque handle to apple-bottom MTLBuffer
    integer(kind=c_size_t) :: nbytes
#else
    BYTE, POINTER :: space(:)
#endif
```

Allocation becomes:

```fortran
#if defined(__CUDA)
    ALLOCATE(good%space(d), stat=info)                            ! CUF-managed
#elif defined(__METAL)
    good%metal_buffer = ab_dev_malloc(int(d, c_size_t))
    good%nbytes       = d
    info = merge(0, -1, c_associated(good%metal_buffer))
#else
    ALLOCATE(good%space(d), stat=info)                            ! host
#endif
```

Release becomes:

```fortran
#if defined(__METAL)
    CALL ab_dev_free(head%metal_buffer)
    head%metal_buffer = c_null_ptr
#endif
```

### 3.2 `device_memcpy.f90` — data movement (9297 lines generated)

Every primitive exists in both a directional form (`_h2d`, `_d2h`, `_h2h`, `_h2d_async`, `_d2h_async`) and a variant for each (type × kind × rank) combination. Types covered: real, complex; kinds: SP (selected_real_kind(6,37)), DP (selected_real_kind(14,200)); ranks: 1–4.

Representative primitives:

| Name | Signature | Metal semantics |
|---|---|---|
| `dp_memcpy_h2d_c2d` | `(out: device, in: host, range, lbound)` | `ab_dev_memcpy_h2d(dev_ptr, host_ptr, bytes)` |
| `dp_memcpy_d2h_c2d` | `(out: host, in: device, range, lbound)` | `ab_dev_memcpy_d2h(host_ptr, dev_ptr, bytes)` |
| `dp_dev_memcpy_c2d` | `(out: device, in: device, range, lbound)` | `ab_dev_memcpy_d2d(dev_a, dev_b, bytes)` |
| `dp_dev_memset_c2d` | `(out: device, val, range, lbound)` | `ab_dev_memset(dev_a, pattern, bytes)` |
| `dp_memcpy_h2d_async_c2d` | add `stream` arg | Metal has no streams in the CUDA sense; see §5.4 |
| `dev_stream_sync(stream)` | barrier | no-op or `[commandBuffer waitUntilCompleted]` |

The pattern to emit under `__METAL` for every one of these: given Fortran arrays decorated with `attributes(device)` (or under `__METAL`, wrapped in DevXlib's `metal_buffer` opaque handle), compute byte counts from the range/lbound arguments, and call the appropriate `ab_dev_memcpy_*` primitive.

**Strided copies.** CUDA handles rank-2 copies via `cudaMemcpy2D(dst, dst_ld, src, src_ld, width, height)`. Metal's `blitCommandEncoder copyFromBuffer:...` supports the same concept. For ranks ≥3 DevXlib today falls back to a Fortran array assignment (see `jf90:265-267`); under `__METAL` we'd likely do the same (flush device→host, assign, push back) or iterate dim-2 blits.

### 3.3 `device_auxfunc.f90` — elementwise utilities (2582 lines generated)

Contents: `dp_dev_conjg_c[1-4]d`, `dp_dev_vec_upd_*`, `dev_mem_addr_*`, etc. These are kernels, not data movement. Under `__CUDA` they're implemented via `!$cuf kernel do` (implicit CUDA kernel generation). Under `__METAL` we have three choices:

(a) Ship hand-written Metal kernels for each — exact performance parity.
(b) Flush to host, run on CPU, push back — correctness only.
(c) Hybrid: native Metal kernels for the hot ones (elementwise multiply, conjugation), host-fallback for the rare ones.

For the first production cut, option (b) is acceptable for every auxfunc primitive (none of them are hot-loop material for Davidson). Upgrade to (c) in month 5 when we have performance data.

---

## 4. apple-bottom Second API Surface

This is the public header that the DevXlib Metal backend consumes. It sits alongside today's BLAS-compatible `ab_zgemm_` in `libapplebottom.dylib` — same library, two symbol sets.

Recommended location: `apple-bottom/include/apple_bottom_device.h`.

```c
/* apple_bottom_device.h — device-pointer API for DevXlib backend integration.
 * This header is ABI-stable and backward-compatible with the BLAS-compatible
 * API in apple_bottom.h.  Any caller that uses ab_dev_* must not also touch
 * the matrix's host pointer except through the provided memcpy primitives.
 */
#ifndef APPLE_BOTTOM_DEVICE_H
#define APPLE_BOTTOM_DEVICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Opaque handles --- */

typedef struct ab_dev_buffer*  ab_dev_buffer_t;   /* wraps MTLBuffer */
typedef struct ab_dev_stream*  ab_dev_stream_t;   /* wraps MTLCommandQueue */

/* --- Buffer lifecycle --- */

ab_dev_buffer_t ab_dev_malloc(size_t nbytes);
void            ab_dev_free(ab_dev_buffer_t buf);
size_t          ab_dev_buffer_size(ab_dev_buffer_t buf);

/* --- Data movement (synchronous) --- */

void ab_dev_memcpy_h2d(ab_dev_buffer_t dst, const void* src,
                       size_t nbytes);
void ab_dev_memcpy_d2h(void* dst, ab_dev_buffer_t src,
                       size_t nbytes);
void ab_dev_memcpy_d2d(ab_dev_buffer_t dst, ab_dev_buffer_t src,
                       size_t nbytes);
void ab_dev_memcpy_h2d_strided(ab_dev_buffer_t dst, size_t dst_pitch_bytes,
                               const void* src, size_t src_pitch_bytes,
                               size_t width_bytes, size_t height);
void ab_dev_memcpy_d2h_strided(void* dst, size_t dst_pitch_bytes,
                               ab_dev_buffer_t src, size_t src_pitch_bytes,
                               size_t width_bytes, size_t height);
void ab_dev_memset(ab_dev_buffer_t buf, int pattern, size_t nbytes);

/* --- Data movement (asynchronous) --- */

ab_dev_stream_t ab_dev_stream_create(void);
void            ab_dev_stream_destroy(ab_dev_stream_t s);
void            ab_dev_stream_sync(ab_dev_stream_t s);

void ab_dev_memcpy_h2d_async(ab_dev_buffer_t dst, const void* src,
                             size_t nbytes, ab_dev_stream_t s);
void ab_dev_memcpy_d2h_async(void* dst, ab_dev_buffer_t src,
                             size_t nbytes, ab_dev_stream_t s);

/* --- Device BLAS on handles (DD-accelerated) --- */

/* Enums identical to CBLAS / CUBLAS semantics */
typedef enum { AB_OP_N = 111, AB_OP_T = 112, AB_OP_C = 113 } ab_op_t;

void ab_dev_dgemm(ab_op_t transa, ab_op_t transb,
                  int m, int n, int k,
                  double alpha,
                  ab_dev_buffer_t A, int lda,
                  ab_dev_buffer_t B, int ldb,
                  double beta,
                  ab_dev_buffer_t C, int ldc);

void ab_dev_zgemm(ab_op_t transa, ab_op_t transb,
                  int m, int n, int k,
                  const double _Complex* alpha,
                  ab_dev_buffer_t A, int lda,
                  ab_dev_buffer_t B, int ldb,
                  const double _Complex* beta,
                  ab_dev_buffer_t C, int ldc);

/* Offsets into buffers for sub-matrix dispatch (e.g. hpsi(1,n_start)) */
void ab_dev_zgemm_offset(ab_op_t transa, ab_op_t transb,
                         int m, int n, int k,
                         const double _Complex* alpha,
                         ab_dev_buffer_t A, size_t a_offset_elems, int lda,
                         ab_dev_buffer_t B, size_t b_offset_elems, int ldb,
                         const double _Complex* beta,
                         ab_dev_buffer_t C, size_t c_offset_elems, int ldc);

/* --- Device-pointer elementwise utilities (for device_auxfunc) --- */

void ab_dev_conjg_c(ab_dev_buffer_t buf, size_t count);
void ab_dev_scale_z(ab_dev_buffer_t buf, const double _Complex* alpha,
                    size_t count);
void ab_dev_axpy_z(ab_dev_buffer_t y, const double _Complex* alpha,
                   ab_dev_buffer_t x, size_t count);

/* --- Introspection / diagnostics --- */

void   ab_dev_device_info(char* name, size_t namebuf_len,
                          size_t* total_bytes, size_t* free_bytes);
size_t ab_dev_peak_buffer_count(void);

#ifdef __cplusplus
}
#endif
#endif /* APPLE_BOTTOM_DEVICE_H */
```

### 4.1 `ab_dev_zgemm_offset` — the reason this API exists

The BLAS-compatible `ab_zgemm_` today accepts pointer arithmetic from Fortran — `hpsi(1, n_start)` becomes a pointer into the middle of the hpsi array. With opaque device handles we cannot do pointer arithmetic (`MTLBuffer + offset` is not a valid pointer), so the offset must be an explicit argument.

Every cegterg.f90 call site uses offset semantics (see audit §2.1). All 12 sites map to `ab_dev_zgemm_offset`, not `ab_dev_zgemm`.

### 4.2 `ab_dev_stream_t` and Metal's async model

Metal doesn't have CUDA-style streams; the closest equivalent is `MTLCommandBuffer` plus `MTLCommandQueue`. An `ab_dev_stream_t` wraps a `MTLCommandQueue`; every `*_async` call encodes a `MTLCommandBuffer` on that queue and `commits` without waiting. `ab_dev_stream_sync` calls `[lastBuffer waitUntilCompleted]`. This is enough to satisfy DevXlib's contract because DevXlib itself only uses `dev_stream_sync` for completion barriers; it never does stream-to-stream dependency tracking (see `jf90:416-429`).

---

## 5. Mapping Table — DevXlib Primitive → apple-bottom Call

| DevXlib primitive | apple-bottom implementation | Notes |
|---|---|---|
| `fbuff%init` | lazy — nothing to do | MTLDevice already init'd by libapplebottom |
| `fbuff%lock_buffer(p, n)` | `p = ab_dev_malloc(n)` or pool reuse | pool logic identical to CUDA path |
| `fbuff%release_buffer(p)` | mark free in DevXlib pool; don't free | same |
| `fbuff%dealloc` | `ab_dev_free(p)` for each node | same |
| `dp_memcpy_h2d_c2d(out, in, range, lbound)` | `ab_dev_memcpy_h2d_strided(out_handle, ld*16, &in(d1s,d2s), ld*16, d1_size*16, d2_size)` | complex DP is 16 bytes; 2D strided |
| `dp_memcpy_d2h_c2d` | `ab_dev_memcpy_d2h_strided(...)` | mirror |
| `dp_dev_memcpy_c2d` | `ab_dev_memcpy_d2d(...)` | fully device-side |
| `dp_dev_memset_c2d` | `ab_dev_memset(buf, 0, n)` for val=0; elementwise Metal kernel for val≠0 | Metal `fillBuffer:range:value:` only supports bytes; ≠0 real/complex needs a tiny shader |
| `dp_memcpy_h2d_async_c2d` | `ab_dev_memcpy_h2d_async` | stream maps to MTLCommandQueue |
| `dev_stream_sync(stream)` | `ab_dev_stream_sync(stream)` | `[commandBuffer waitUntilCompleted]` |
| `dp_dev_conjg_c2d` | `ab_dev_conjg_c` | small Metal shader |
| (none — QE calls direct) `ZGEMM` under `host_data use_device` | link-time resolution of `zgemm_` → `ab_dev_zgemm_offset` shim | requires `__METAL` source edits in QE |

---

## 6. Backend-Selection Mechanism

**DevXlib uses conditional compilation only** — there is no runtime backend-dispatch table. This was the second key thing to verify. The implication: adding Metal is a preprocessor-arm addition, not a runtime plugin registration. Every `#if defined(__CUDA)` block must grow an `#elif defined(__METAL)` sibling in both the `.jf90` templates and the regenerated `.f90`.

The `__HAVE_DEVICE` umbrella already exists; we extend it:

```c
/* include/device_macros.h, upstream-facing diff */
-#if defined(__CUDA) || defined(__OPENACC) || defined(__OPENMP5)
+#if defined(__CUDA) || defined(__OPENACC) || defined(__OPENMP5) || defined(__METAL)
 #  define __HAVE_DEVICE
 #endif
```

And the naming-convention macros:

```c
/* include/dev_defs.h */
-#ifdef _CUDA
+#if defined(_CUDA)
 #  define DEV_SUBNAME(x)        CAT(x,_gpu)
 #  define DEV_VARNAME(x)        CAT(x,_d)
 #  define DEV_ATTRIBUTE         , device
+#elif defined(__METAL)
+#  define DEV_SUBNAME(x)        CAT(x,_metal)
+#  define DEV_VARNAME(x)        CAT(x,_m)
+#  define DEV_ATTRIBUTE
 #else
 #  define DEV_SUBNAME(x)        x
 #  define DEV_VARNAME(x)        x
 #  define DEV_ATTRIBUTE
 #endif
```

### 6.1 Build system

DevXlib's `configure` script selects backend via env vars `F90=nvfortran ENABLE_CUDA=yes`. Upstream-facing addition: `ENABLE_METAL=yes` which sets `-D__METAL` in the Fortran preprocessor flags and appends `-lapplebottom -framework Metal -framework Foundation` to the link line. QE's CMake side already has a `QE_ENABLE_CUDA` option; we mirror with `QE_ENABLE_METAL`.

---

## 7. QE Source-Patch Surface (Espressivo Side)

This is the work that happens in Espressivo, not in the DevXlib or apple-bottom MRs.

Three classes of edits to QE hot-path files under `__METAL`:

**(a) BLAS call-site bindings.** Replace `CALL ZGEMM(...)` with a macro that expands to either `zgemm_` (CPU) or the device-pointer shim (METAL):

```fortran
#include <device_macros.h>

#if defined(__METAL)
#  define AB_ZGEMM(...) CALL ab_dev_zgemm_offset(__VA_ARGS__)
#else
#  define AB_ZGEMM(...) CALL ab_zgemm(__VA_ARGS__)
#endif
```

The existing `ab_zgemm` rename (from the HPEC draft) maps 1:1 to `AB_ZGEMM` — the preprocessor expansion differs per backend. Maintenance cost: unchanged.

**(b) Fortran array handling under `host_data use_device`.** On `__METAL` we can't use `host_data` because gfortran's OpenACC emits no-ops. Replace each such region with explicit buffer-handle retrieval:

```fortran
#if defined(__CUDA) || defined(__OPENACC)
   !$acc host_data use_device(psi, hpsi, hc)
   CALL AB_ZGEMM('C','N', nbase, my_n, kdim, ONE, psi, kdmx, hpsi(1,n_start), kdmx, ZERO, hc(1,n_start), nvecx)
   !$acc end host_data
#elif defined(__METAL)
   CALL ab_dev_zgemm_offset(AB_OP_C, AB_OP_N, nbase, my_n, kdim, ONE, &
                             psi_handle,  0,                    kdmx, &
                             hpsi_handle, (n_start-1)*kdmx,     kdmx, ZERO, &
                             hc_handle,   (n_start-1)*nvecx,    nvecx)
#else
   CALL ZGEMM('C','N', nbase, my_n, kdim, ONE, psi, kdmx, hpsi(1,n_start), kdmx, ZERO, hc(1,n_start), nvecx)
#endif
```

Where `psi_handle`, `hpsi_handle`, `hc_handle` are DevXlib buffer handles populated at the `enter data create` equivalent (step (c)).

**(c) Allocator substitution.** Where QE does `ALLOCATE(psi(npwx*npol, nvecx))` and then `!$acc enter data create(psi)`, under `__METAL` we do:

```fortran
#if defined(__METAL)
   CALL dev_fbuff%lock_buffer(psi_handle, npwx*npol*nvecx*16_c_size_t, info)
#else
   ALLOCATE(psi(npwx*npol, nvecx), STAT=ierr)
   !$acc enter data create(psi)
#endif
```

The complex-DP size constant `16` comes from `2 * selected_real_kind(14,200)` bytes.

### 7.1 Estimated edit counts

| File | Edits | Reason |
|---|---|---|
| `KS_Solvers/Davidson/cegterg.f90` | ~40 lines | 12 ZGEMM sites + 7 allocators + 8 acc regions |
| `KS_Solvers/Davidson/regterg.f90` | ~40 lines | analogous, DGEMM |
| `PW/src/h_psi.f90` | ~15 lines | 4 host_data regions + 3 update pairs |
| `PW/src/s_psi.f90` | ~25 lines | more GEMM-internal regions |
| `PW/src/c_bands.f90` | ~10 lines | evc allocator substitution |
| Total | ~130 lines | under `__METAL` guards only |

These are additive edits — the existing `__CUDA` / non-device code paths are untouched, so there is zero risk to production NVIDIA QE builds. This is critical for upstream acceptance.

---

## 8. Identified Gaps Between CUDA and Metal Semantics

Enumerated for completeness; none are blockers.

| Gap | CUDA | Metal | Resolution |
|---|---|---|---|
| Streams vs. command queues | `cudaStream_t` is lightweight, many per context | `MTLCommandQueue` is heavyweight, ideally one per thread | Pool a single queue internally; each `ab_dev_stream_t` is a logical stream tracked by the last-submitted command buffer |
| `attributes(device)` | first-class Fortran attribute | no equivalent in gfortran | Use `type(c_ptr)` handle wrapping at the Fortran API surface |
| `cudaMallocHost` (pinned host memory) | DMA-friendly | shared/managed memory on unified memory is already pinned equivalent | Ignore; always use shared-storage `MTLBuffer` on Apple Silicon |
| CUF kernel auto-gen | `!$cuf kernel do` generates kernels | no equivalent | Hand-write Metal shaders for hot auxfunc primitives; host-fallback for cold ones |
| `cudaMemcpy2D` strided | direct API | `blitCommandEncoder copyFromBuffer:...:sourceBytesPerRow:...` | Direct equivalent; exposed as `ab_dev_memcpy_*_strided` |
| 3D / higher strided | falls back to Fortran assign | same | No loss |
| `cudaGetErrorString` | error messages | MTLCommandBuffer error codes | Thin translation helper in apple-bottom |

---

## 9. Compile-Time Tests the Metal Arm Must Satisfy

Before any upstream MR, the Espressivo branch must build and pass these on macOS with gfortran + apple-bottom:

1. `make depend` in `external/devxlib/src/` succeeds with `-D__METAL` set.
2. `test_fbuff.f90` produces pass with `__METAL` backend (creates 100 MTLBuffers, releases, verifies pool reuse).
3. `test_memcpy.f90` passes for rank-1 and rank-2 c/r variants with `__METAL`.
4. `test_memcpy_async.f90` passes — requires the stream-to-command-buffer mapping.
5. `pw.x` links cleanly against the patched QE with `-D__METAL` and apple-bottom on the link line.
6. si64 SCF to 10⁻⁸ Ry energy match against CPU baseline.

---

## 10. Upstream Contribution Strategy

Two MRs, in order:

**MR #1 — MaX Centre `devicexlib` repo.**
Branch name: `metal-backend`.
Scope: additive `__METAL` arm in `device_macros.h`, `dev_defs.h`, all three `.jf90` templates and regenerated `.f90` files, plus `configure` ENABLE_METAL flag and build rules. Depends on `libapplebottom.dylib` being findable at link time (pkg-config or plain `-lapplebottom`).
Reviewers: MaX Centre DevXlib maintainers (Pietro Bonfà, A. Ferretti).
Risk: low — zero impact on existing CUDA / OpenACC / OpenMP5 builds.

**MR #2 — QEF `q-e` repo.**
Branch name: `metal-backend`.
Scope: ~130 lines of `#if defined(__METAL)` guards in cegterg, regterg, h_psi, s_psi, c_bands. CMake `QE_ENABLE_METAL` option wiring. Updated devxlib submodule pin to include MR #1.
Reviewers: QE team + F. Spiga (precedent from q-e-gpu).
Risk: low, as above.

Neither MR touches apple-bottom itself. apple-bottom stays a standalone library with its own release cadence.

---

## 11. Revised Month-1 Plan (supersedes audit §6 Month 1)

The DevXlib investigation changes which Week-1 questions matter. Updated Month-1 breakdown:

- **Week 1**: Prototype `apple_bottom_device.h` + `ab_dev_malloc` / `ab_dev_free` / `ab_dev_memcpy_h2d` / `ab_dev_memcpy_d2h` / `ab_dev_memcpy_d2d` in apple-bottom as a new `src/device_api.m`. Unit tests only — no DevXlib integration yet. Deliverable: 56/56 apple-bottom tests still pass + new tests for the device API. The audit's original Week-1 (gfortran OpenACC runtime behavior) is *dropped* — we no longer care whether gfortran emits OpenACC stubs because we won't depend on them.

- **Week 2**: Prototype `ab_dev_zgemm` and `ab_dev_zgemm_offset`. Validate bit-identical output against the existing BLAS-compatible `ab_zgemm` on a 1024×1024×1024 complex matrix. Benchmark: 100 sequential calls with shared buffers vs. 100 calls through today's upload-download path. Measure the residency speedup in isolation.

- **Week 3**: Patch the DevXlib `.jf90` templates with a prototype `__METAL` arm for `fbuff` and the `_h2d`/`_d2h`/`_d2d` memcpy primitives. Build the patched DevXlib standalone (outside QE) and run `test_fbuff.f90` + `test_memcpy.f90`.

- **Week 4**: Integrate: in `Espressivo/deps/qe-7.5/src-metal/`, add `__METAL` preprocessor arms to a single hot path in cegterg.f90 (ZGEMM site #1, L207). Build pw.x. Validate si64 NP=1 AB_MODE=auto produces bit-identical energy to current branch. First end-to-end residency proof.

---

## 12. Open Questions Deferred to Month 2+

- Stream/command-queue pooling model under high MPI rank counts (each rank has its own queue — do we serialize them via a shared queue or let them proceed independently?). Benchmark when we get there.
- ELPA vs. ScaLAPACK for Month 5 ndiag-bypass work. ELPA has `useGPU` mode that calls standard `zgemm_`; ScaLAPACK's `pzheevd` internal GEMMs bypass DevXlib entirely. ELPA is the upstream-cleaner path.
- `__OPENMP5` interaction — if a user tries to set both `__METAL` and `__OPENMP5`, which wins? Likely need a compile-time error in `device_macros.h`.

---

*End of companion doc. Ready for Week-1 implementation start — the first deliverable is `apple_bottom_device.h` and its unit tests, independent of DevXlib.*
