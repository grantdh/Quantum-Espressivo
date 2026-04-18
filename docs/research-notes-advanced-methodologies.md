# Advanced Architectural and Algorithmic Methodologies for Accelerating Multi-Word Arithmetic on Apple Silicon GPUs

> Research notes supporting the HPEC 2026 paper "ULP Fiction: Double-Float BLAS on Apple Silicon GPUs for Density Functional Theory"

## 1. Microarchitectural Evolution and Exploitation of Apple Silicon

### 1.1 ALU Layout, Instruction Latency, and Register Pressure Dynamics

The foundational processing block of the Apple GPU (spanning the Apple 7 to Apple 10 architectural families) features a highly parallel ALU layout. Each core contains approximately 128 ALUs governed by four distinct schedulers per core. Each scheduler dispatches one instruction from a single SIMD-group (32 threads) per cycle.

FP32 operations including FMA carry a baseline 4-cycle latency. The architecture utilizes dynamic dispatching modes: single-dispatching from 3 SIMDs at low ILP, dual-dispatching from 2 SIMDs preferred for full saturation.

Apple GPU cores feature ~208 KB register file per core with ~60 KB shared memory. The design strongly favors over-allocating registers to maintain ALU utilization rather than prioritizing high warp occupancy. This supports up to 1024 threads per core without steep performance cliffs, allowing aggressive loop unrolling and register blocking.

### 1.2 Nested FMA: Halving Latency and Tightening Error Bounds

Standard DD multiplication cross-terms require 4 operations and 4 intermediate roundings, with error bound 5u²–13u². By restructuring via nested FMA — `fma(a.hi, b.lo, fma(a.lo, b.hi, e))` — the pipeline dependencies compress to 2 cycles total, and the theoretical error bound tightens to ≤2u² (Joldes et al. 2017).

### 1.3 The M5 Fusion Architecture and the "VRAM Cliff"

The M5 uses TSMC N3P with SoIC-mH 2.5D packaging (solder-free hybrid bonding). Scales to 18-core CPU, 40-core GPU. UMA resolves the "VRAM Cliff" — up to 128 GB shared LPDDR5X at 546–614 GB/s. Tensors loaded for GPU are immediately available to all compute engines without explicit copies.

### 1.4 GPU Neural Accelerators: A Tensor Core Paradigm

The M5 integrates Neural Accelerators in every GPU core — dedicated MMA hardware analogous to NVIDIA Tensor Cores. Each core performs 1,024 FP16 fused multiply-accumulate ops per cycle. At 40 cores: ~70 TFLOPS FP16.

## 2. Advanced Algorithmic Emulation: The Ozaki Scheme II

### 2.1 Limitations of Scalar Multi-Word Arithmetic

Scalar DD scales linearly with ALU count. Extension to triple-word or quad-word requires exponentially more instructions. The `a.lo × b.lo` cross-term (~u⁴ ≈ 10⁻³⁰) can be safely dropped.

### 2.2 Error-Free Transformation via the Ozaki Scheme

Ozaki Scheme I decomposes high-precision matrices into FP16/FP32 bit-plane slices, computes cross-products on matrix engines, reconstructs via scalar reduction. Requires O(S²) slice multiplications.

### 2.3 The Chinese Remainder Theorem and Ozaki Scheme II

Ozaki Scheme II uses integer modular arithmetic via CRT:
1. Scale and truncate to exact integer matrices
2. Decompose modulo pairwise coprime integers p₁, p₂, ..., pₙ
3. Multiply modular matrices on INT8 matrix engines
4. Reconstruct via CRT, reapply exponents

### 2.4 Hardware Benchmarks

| Hardware | Native FP64 | Ozaki II (INT8) Emulated FP64 |
|----------|-------------|-------------------------------|
| RTX 4090 | 1.3 TFLOPS | 7.4–9.8 TFLOPS |
| GH200 | ~34 TFLOPS | 56.6–80.2 TFLOPS |
| M5 Max (Est.) | N/A | TBD (~70 TFLOPS INT8/FP16 base) |

## 3. Metal 4, TensorOps, and Memory Hierarchy Orchestration

### 3.1 mpp::tensor_ops API

Optimal M5 configuration: 2×2 tile of simdgroups per threadgroup, simdgroup tile size Sₘ = Sₙ = 32.

### 3.2 Morton Ordering for Cache Locality

Z-order space-filling curve mapping of threadgroup positions maximizes SLC hit rate. Deinterleaving via fast bitwise operations at kernel start.

### 3.3 Epilogue Predication and BLAS-3 Compliance

Fusing α/β into the K-loop causes catastrophic register bloat. Solution: pure dot product in K-loop, α/β scaling applied once in epilogue. Zero overhead in O(N³) loop.

## 4. Accumulation Drift and Probabilistic Error Analysis

### 4.1 Wilkinson's Probabilistic Walk

| K Dimension | Theoretical Avg. Drift | Measured Error | vs. Static 10⁻¹³ |
|-------------|----------------------|----------------|-------------------|
| K=10 | 1.12×10⁻¹⁴ | 8.31×10⁻¹⁵ | Passed |
| K=100 | 3.55×10⁻¹⁴ | 2.02×10⁻¹⁴ | Passed |
| K=10000 | 3.55×10⁻¹³ | 1.38×10⁻¹³ | Failed |

The K=10000 "failure" was a false positive — the kernel beat the theoretical bound.

### 4.2 Dynamic Scaling and Compensated Summation

Block-wise accumulation: sloppy DD accumulation in inner loop, Kahan-style normalization every 128–256 iterations. Preserves quadruple-dispatch capability while truncating random walk drift.

## 5. Asymmetric Tiling and Occupancy Optimization

### 5.1 The Quantum ESPRESSO Topology Problem

Hot path: M=18277, N=150, K=300. Standard 32×32 tiles waste ~31% ALU cycles on boundary.

### 5.2 Asymmetric Tiling Strategy

Tile config: M_tile=128, N_tile=16. For N=150: 9 full + 1 partial tile (6 elements). Boundary waste drops from ~30% to <5%.

## 6. Mixed-Precision Iterative Refinement for Triangular Solves

Explicit inversion bounds error by κ(A)², destroying precision. MPIR pipeline:
1. Factor A in FP32 (or FP16 on M5) — bulk O(N³) at max throughput
2. Initial solve X₀ from FP32 factors
3. Residual R = B - AX₀ via DD-DGEMM (10⁻¹⁵ fidelity)
4. Correction ΔX from FP32 factors
5. Update X_new = X₀ + ΔX in DD
6. Iterate (converges in 1–3 iterations for well-conditioned systems)

## 7. Concurrent Execution: AMX Coprocessor

### 7.1 AMX Architecture

32×32 compute grid attached to CPU P-cores. Fed from L1/L2 caches — bypasses Metal command buffer latency (5–15 μs per command).

### 7.2 Heterogeneous Dispatch

- GPU: Large dense matrices (dim > 128)
- AMX: Small, irregular, or batched GEMMs (< ~10⁷ FLOPs)
- Zero-copy sync via MTLSharedEvent on UMA

## 8. QE Integration and Future Outlook

- Wannier interpolation of e-ph matrix elements as key optimization target
- Pathway: asymmetric tiling + MPIR for complete solver stack
- Ozaki II on M5 Neural Accelerators: potential multi-TFLOP FP64-equivalent throughput

## References

- Joldes, Muller, Popescu (2017). Tight and rigorous error bounds for basic building blocks of double-word arithmetic. ACM TOMS.
- Higham (2002). Accuracy and Stability of Numerical Algorithms. SIAM.
- Higham, Mary (2022). Mixed precision algorithms in numerical linear algebra.
- Ozaki et al. (2025). Ozaki Scheme II: Faster DGEMM via CRT-based tensor core utilization.
