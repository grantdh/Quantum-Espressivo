# Quantum-Espressivo

**Apple Silicon GPU acceleration for Quantum ESPRESSO**

Quantum-Espressivo integrates the [apple-bottom](https://github.com/grantdh/apple-bottom) FP64-class BLAS library into [Quantum ESPRESSO](https://www.quantum-espresso.org/) 7.5, replacing dense linear algebra hot paths with Metal GPU kernels. The result: 22% wall-time speedup and 11 decimal places of energy agreement on production DFT workloads, with no source-level changes to QE beyond six `ZGEMM` call sites.

## Validated Results

Benchmarked on M2 Max (38-core GPU, 64 GB unified memory):

| System | Configuration | Wall Time | Energy (Ry) | vs Baseline |
|--------|--------------|-----------|-------------|-------------|
| Si64 (64 atoms) | OpenBLAS 6-thread | 2:28 | -2990.44276157 | — |
| Si64 (64 atoms) | apple-bottom GPU | 2:01 | -2990.44276157 | **+22%** |

Energy agreement to 11 decimal places. 47% less CPU usage (GPU offloads ZGEMM, freeing cores for MPI communication).

## How It Works

```
Quantum ESPRESSO 7.5
    ↓ cegterg.f90: ZGEMM → ab_zgemm (6 call sites)
    ↓
apple-bottom fortran_bridge
    ↓ < 100M FLOPs → OpenBLAS (CPU)
    ↓ ≥ 100M FLOPs → Metal DD kernels (GPU, ~10⁻¹⁵ precision)
```

The integration patches `cegterg.f90` (the iterative eigensolver) and relinks against `libapplebottom.a`. No module modifications, no new Fortran dependencies — the bridge uses `EXTERNAL` declarations.

## Building

### Prerequisites

- macOS 14+ (Sonoma) with Xcode 16+ SDK
- Apple Silicon (M1/M2/M3/M4)
- Homebrew packages: `gcc`, `open-mpi`, `openblas`, `fftw`, `scalapack`

### Build Steps

```bash
git clone https://github.com/grantdh/Quantum-Espressivo.git
cd Quantum-Espressivo

# 1. Build apple-bottom (or point APPLE_BOTTOM_DIR to existing build)
./scripts/setup-apple-bottom.sh

# 2. Clone QE 7.5, apply patches, build both baseline and Metal versions
./scripts/build-qe-metal.sh

# 3. Validate energy agreement
./scripts/validate.sh
```

The build script produces two QE binaries for direct comparison: a CPU-only baseline and the Metal-accelerated version.

### Benchmarking

```bash
# Quick 4-way comparison (CPU vs GPU × OpenBLAS vs AMX)
./scripts/benchmark-4way.sh

# Full overnight sweep (multiple system sizes, thread counts, statistics)
./scripts/benchmark-overnight.sh
```

Benchmark results and analysis scripts are in [`benchmarks/qe_yambo/`](benchmarks/qe_yambo/).

## Requirements

- **QE version**: 7.5 (the `.bands` post-processing tool requires 7.5)
- **apple-bottom**: Built with `MTLMathModeSafe` (Xcode 16+ SDK) for ~10⁻¹⁵ precision
- Do **not** use DYLD_INSERT_LIBRARIES interposition — it has been tested and abandoned due to dispatch overhead. Rebuild QE against apple-bottom as an explicit linker input.

## Repository Structure

```
Quantum-Espressivo/
├── scripts/
│   ├── setup-apple-bottom.sh      # Build apple-bottom dependency
│   ├── build-qe-metal.sh          # Clone, patch, and build QE 7.5
│   ├── build-qe-openblas.sh       # CPU-only baseline build
│   ├── validate.sh                # Energy agreement validation
│   ├── benchmark-4way.sh          # Quick A/B/C/D comparison
│   ├── benchmark-overnight.sh     # Full statistical benchmark suite
│   ├── benchmark-paper.sh         # Publication-quality benchmarks
│   ├── calibrate-omp.sh           # OMP thread tuning
│   └── rebuild-metal.sh           # Incremental rebuild
├── benchmarks/qe_yambo/           # Benchmark configs, inputs, analysis
├── results/                       # Benchmark output data
├── tests/                         # Integration test suite
├── docs/                          # Integration notes and research
└── deps/                          # Local apple-bottom and QE source (gitignored)
```

## Ecosystem

- [apple-bottom](https://github.com/grantdh/apple-bottom) — FP64-class BLAS on Apple Silicon GPU (the engine)
- [YAMBOrghini](https://github.com/grantdh/YAMBOrghini) — Yambo GW/BSE + Metal GPU acceleration
- [MEEPhistopheles](https://github.com/grantdh/MEEPhistopheles) — MEEP FDTD + Metal GPU acceleration
- [rainbow-connection](https://github.com/grantdh/rainbow-connection) — Multi-physics pipeline orchestrator (QE → Yambo → MEEP)

## License

GPL-2.0 (matching Quantum ESPRESSO's license)
