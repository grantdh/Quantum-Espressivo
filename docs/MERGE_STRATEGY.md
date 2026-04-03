# Quantum ESPRESSO Merge Strategy

This document lays out a realistic path to getting apple-bottom merged into Quantum ESPRESSO as a Metal GPU backend. It's based on how the CUDA backend actually got merged (spoiler: it took years and went through a separate repo first) and the current state of QE's contribution process.

## How the CUDA Backend Got Merged — And What That Means For Us

The QE GPU story is instructive. NVIDIA GPU support didn't start as a merge request. It started as **a completely separate project** (`q-e-gpu` by Filippo Spiga, later maintained at `gitlab.com/QEF/q-e-gpu`) that ran alongside the main codebase for years. The GPU code was gradually merged into mainline QE starting around 2020-2021, and `q-e-gpu` was eventually archived.

The architecture that survived uses OpenACC directives and CUDA Fortran, with calls routed through DeviceXlib (`devxlib`) — an abstraction layer that dispatches to cuBLAS, cuFFT, and cuSOLVER on GPU or standard BLAS/LAPACK/FFTW on CPU. The conditional compilation uses `__CUDA` preprocessor guards in Fortran files, enabled by `-DQE_ENABLE_CUDA=ON` at CMake time.

Key takeaway: **the QE team accepted NVIDIA GPU support because it was already proven in production by external users over multiple years before the merge**. They didn't merge speculative code. The same approach applies to us.

## Our Position

**Strengths:**
- Working library with 48/48 tests
- Production validation on real science (QE Si64 DFT, 11-digit energy match)
- NASA-STD-7009A V&V documentation (nobody else in this space has this)
- Minimal integration footprint (15 lines changed across 2 QE files)
- MIT license (compatible with QE's GPL)

**Weaknesses:**
- No contact with QE team yet
- Only validated on one hardware config (M2 Max)
- Only validated with pw.x (not cp.x, turboTDDFT, PHonon, etc.)
- Rectangular matrix correctness issues unresolved
- Not IEEE 754 FP64 — DD arithmetic has ~48-bit mantissa, not 53-bit
- Alpha/beta constraints (GPU path requires alpha=1, beta=0)
- Single developer project

## The Realistic Timeline

Getting merged into QE mainline is not a weeks-long effort. Here's what the path actually looks like:

### Phase 0: Make apple-bottom Independently Useful (Now — 2 weeks)
**Goal:** A polished, installable library that scientists can use TODAY without waiting for a QE merge.

This is where we are. The library works, the docs are good, the tests pass. What's left:
- Push all v1.3 changes
- Create GitHub Release
- Fix rectangular matrices
- Validate on M1, M3, M4 (borrow hardware or use GitHub Codespaces)
- Get the repo indexed by GitHub search (stars, topics, activity)

**Why this matters for QE:** When you email the developers list, they'll look at the repo. A polished, well-documented, well-tested library with users and stars is vastly more convincing than a promising prototype.

### Phase 1: Community Traction (2 weeks — 2 months)
**Goal:** External users running apple-bottom, reporting issues, confirming results on their hardware.

- Publish the HN/Reddit blog post
- Get listed on awesome-metal / awesome-apple-silicon
- Python bindings let non-Fortran users try it
- Respond to issues, iterate on usability
- Collect user reports from different M-series chips

**Why this matters for QE:** The SISSA team doesn't want to maintain code that only one person uses. External validation from the community de-risks the merge for them.

### Phase 2: First Contact with QE Team (Month 2-3)
**Goal:** Get the QE developers' attention and preliminary feedback.

**DO:** Email `developers@lists.quantum-espresso.org` with:
- Concrete results (energy agreement, speedup numbers)
- Link to the repo (which by now has stars, issues, and user reports)
- A specific, minimal proposal (just cegterg.f90, not the whole codebase)
- An honest statement of limitations (not IEEE 754, alpha/beta constraints)
- A question: "Would you consider a Metal backend? What would you need to see?"

**DON'T:**
- Submit a merge request before getting feedback
- Propose changes to files you haven't studied deeply
- Claim this replaces CUDA GPU support
- Overpromise on performance (be specific about where it wins and loses)

The response will likely be one of:
1. "Interesting, show us more benchmarks on X" → Great, you have a path
2. "We'd prefer you implement this via DeviceXlib" → Harder but doable
3. "Not interested right now" → Keep building community, try again later
4. No response → Follow up in 2 weeks, try again

### Phase 3: Formal Proposal (Month 3-6)
**Goal:** A merge request that the QE team can evaluate.

Based on feedback from Phase 2, implement what they asked for. The likely options:

**Option A: Minimal EXTERNAL approach (what we have now)**
- `__METAL` guards in cegterg.f90
- CMake `-DQE_ENABLE_METAL=ON` option
- Link against external `libapplebottom.a`
- Simplest to maintain, easiest to review, most likely to get merged

**Option B: DeviceXlib integration**
- Add Metal as a backend alongside CUDA in DeviceXlib
- Route through the existing GPU abstraction layer
- More work, but aligns with QE's architecture
- Would be the "right" approach long-term

**Option C: Plugin / external library approach**
- apple-bottom stays external
- QE documents how to link it (like how they document OpenBLAS setup)
- No source changes to QE at all
- Lowest friction, but also lowest integration

### Phase 4: Review and Iteration (Month 6-12)
Merge requests in academic projects take time. Expect multiple review rounds, requests for additional benchmarks, and possibly architecture changes. The QE team releases roughly annually, so timing your MR to align with a release cycle matters.

## What to Include in the Merge Request

When you do submit, the MR should contain:

1. **Changes to QE source** (minimal):
   - `cmake/QEMetal.cmake` — Find apple-bottom, set `__METAL` flag
   - `KS_Solvers/Davidson/cegterg.f90` — `__METAL` guards around ZGEMM calls
   - `CMakeLists.txt` — Include QEMetal.cmake option

2. **Tests** (in `test-suite/`):
   - A pw.x test case that validates energy with Metal backend
   - Should match existing CPU reference outputs

3. **Documentation**:
   - Build instructions for macOS + Metal
   - Performance characteristics (where Metal helps, where it doesn't)
   - Hardware requirements

4. **What NOT to include**:
   - The apple-bottom source code itself (it's an external dependency, like OpenBLAS)
   - Changes to files you don't understand deeply
   - Speculative features

## Technical Requirements for QE Compatibility

Before submitting, apple-bottom needs to handle these cases that QE actually exercises:

### Already handled:
- `ZGEMM('N', 'N', ...)` — standard multiply
- `ZGEMM('C', 'N', ...)` — conjugate transpose (calbec overlap)
- FLOP-based routing to CPU for small calls

### Need to verify on QE 7.5:
- Whether cegterg.f90 BLAS signatures changed from 7.4.1
- Whether h_psi.f90 ZGEMM calls matter (may be below crossover)
- Whether new solvers (RMM-DIIS, MR #1498) have different BLAS patterns

### Need to fix:
- Alpha/beta constraint: GPU path requires alpha=1.0, beta=0.0. QE sometimes passes other values. The Fortran bridge should fall back to CPU for non-standard alpha/beta (partially handled but needs validation)
- Rectangular matrices: QE's hot calls are rectangular (M=18277, N=150, K=300). These MUST work correctly.

### Nice to have for the proposal:
- Multi-chip validation (M1, M3, M4)
- ph.x / cp.x testing (not just pw.x)
- Memory usage comparison vs CPU
- Scaling study across system sizes (si8 through si256)

## The Email Template

```
Subject: Proposal: Metal GPU backend for Apple Silicon

Dear QE developers,

I've developed a BLAS library that provides FP64-class precision on
Apple Silicon GPUs via double-float arithmetic on Metal compute shaders.
I'd like to discuss whether this could be useful as a Metal backend
for Quantum ESPRESSO.

Validation results (QE 7.4.1, pw.x, Si64, PBE, 50 Ry, M2 Max):
  - Energy: -2990.44276157 Ry (matches 6-thread OpenBLAS to 11 digits)
  - Wall time: 2m01s vs 2m28s (22% faster)
  - CPU usage: 340% vs 530% (47% reduction)

The integration modifies 15 lines in cegterg.f90 (EXTERNAL declaration
+ CALL substitutions). A Fortran bridge auto-routes small calls to CPU
BLAS and large calls to Metal GPU.

Precision: ~10^{-15} relative error via double-float (DD) arithmetic.
Not IEEE 754 compliant (48-bit effective mantissa vs 53-bit FP64), but
sufficient for SCF convergence as demonstrated by the energy agreement.

Library and V&V documentation: https://github.com/grantdh/apple-bottom

I'd welcome any feedback, particularly on:
  1. Whether this aligns with QE's GPU acceleration strategy
  2. If DeviceXlib integration would be preferred over the EXTERNAL approach
  3. Testing requirements for merge consideration

Grant Heileman
University of New Mexico, ECE
```

## Key People

- **Paolo Giannozzi** (U. Udine) — QE project lead, final say on merges
- **Ivan Carnimeo** (SISSA) — GPU porting lead, most relevant reviewer
- **Pietro Delugas** (SISSA) — Active QE developer, DeviceXlib work
- **Filippo Spiga** — Original q-e-gpu author (now at NVIDIA, may not be active)

Read their recent papers before emailing. Citing their work in your communications shows you've done your homework.
