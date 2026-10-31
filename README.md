# Quantum-Espressivo

**Quantum ESPRESSO on Apple Silicon, built against the apple-bottom GPU BLAS**

Quantum-Espressivo builds [Quantum ESPRESSO](https://www.quantum-espresso.org/) (QE) against [apple-bottom](https://github.com/grantdh/apple-bottom), an FP64-class BLAS that runs double-float (two-FP32) arithmetic on Apple Silicon GPUs, and benchmarks the result against Apple's Accelerate on the CPU.

## Status (October 2026)

On an M2 Max, linking apple-bottom gives QE the same answers but no speedup:

- The total energy and band energies are the same with QE's GEMMs on the CPU (`AB_MODE=cpu`) and on the GPU (`AB_MODE=gpu`).
- The default, `AB_MODE=auto`, keeps all of QE's GEMMs on Accelerate, which is faster for QE's matrix shapes on this machine. Forcing them onto the GPU is not faster.

These are apple-bottom's measurements, on QE develop with a 64-atom silicon cell: see [VAL-1](https://github.com/grantdh/apple-bottom/blob/main/tests/validation/VAL001_QE_Si64.md), and "What to expect on an M2 Max" in its [integration guide](https://github.com/grantdh/apple-bottom/blob/main/docs/INTEGRATION.md#quantum-espresso-integration), which links the data.

[Earlier versions of this README](https://github.com/grantdh/Quantum-Espressivo/blob/94209083c364e222950e208fc750c91e08ef9c8b/README.md) reported a 22% speedup with "11 decimal places" of energy agreement. That result is withdrawn, together with the April 2026 draft paper that was in `docs/`: see [docs/CORRECTIONS.md](docs/CORRECTIONS.md).

## How It Works

QE does its dense linear algebra through the standard BLAS calls `zgemm_` and `dgemm_`. When QE is linked against apple-bottom (`-lapplebottom` ahead of the system BLAS), those calls go to apple-bottom, which sends each one to the GPU or to Accelerate according to `AB_MODE` (`cpu`, `auto` or `gpu`) and a calibrated routing table. QE's source does not need to change; see apple-bottom's [integration guide](https://github.com/grantdh/apple-bottom/blob/main/docs/INTEGRATION.md#quantum-espresso-integration).

## Building

The scripts below were last run in April 2026 with apple-bottom 1.3 and have not been updated since:

- `build-qe-metal.sh` patches `KS_Solvers/Davidson/cegterg.f90` to call `ab_zgemm` in place of `ZGEMM`. apple-bottom 1.4 and later do not need the patch.
- `validate.sh` and the benchmark scripts read apple-bottom 1.3's profile format, so their GPU-call counts are wrong with 1.4 and later.
- The "GPU" runs they produced with 1.3 ran on the CPU (see [docs/CORRECTIONS.md](docs/CORRECTIONS.md)).

Until they are updated, use apple-bottom's [QE benchmark kit](https://github.com/grantdh/apple-bottom/blob/main/benchmarks/qe/README.md), which describes the QE builds behind its measurements.

### Prerequisites

- macOS 14+ (Sonoma) with Xcode 16+ SDK
- Apple Silicon (M1 or later)
- Homebrew packages: `gcc`, `open-mpi`, `openblas`, `fftw`, `scalapack`

### Build Steps

```bash
git clone https://github.com/grantdh/Quantum-Espressivo.git
cd Quantum-Espressivo

# 1. Build apple-bottom (or point APPLE_BOTTOM_DIR to an existing build)
./scripts/setup-apple-bottom.sh

# 2. Clone QE develop and build it against apple-bottom
./scripts/build-qe-metal.sh

# 3. Build the Accelerate baseline
./scripts/build-qe-accelerate.sh

# 4. Run Si64 with both builds and compare total energies
./scripts/validate.sh
```

### Benchmarking

```bash
# Quick comparison: OpenBLAS, Accelerate, and two apple-bottom routing settings
./scripts/benchmark-4way.sh

# Overnight sweep (several systems, repeated runs, statistics)
./scripts/benchmark-overnight.sh
```

Benchmark configurations and analysis scripts are in [`benchmarks/qe_yambo/`](benchmarks/qe_yambo/).

## Requirements

- **QE version**: 7.5 or later; the build scripts clone the head of `develop` (the `.bands` post-processing tool requires 7.5)
- **apple-bottom**: Built with `MTLMathModeSafe` (Xcode 16+ SDK); its accuracy is documented in its [precision envelope](https://github.com/grantdh/apple-bottom/blob/main/docs/vv/PRECISION_ENVELOPE.md)
- Do **not** use DYLD_INSERT_LIBRARIES interposition — it has been tested and abandoned due to dispatch overhead. Rebuild QE against apple-bottom as an explicit linker input.

## Repository Structure

```
Quantum-Espressivo/
├── scripts/
│   ├── setup-apple-bottom.sh      # Build apple-bottom dependency
│   ├── build-qe-metal.sh          # Clone, patch, and build QE against apple-bottom
│   ├── build-qe-accelerate.sh     # Accelerate baseline build
│   ├── build-qe-openblas.sh       # OpenBLAS baseline build
│   ├── validate.sh                # Energy agreement validation
│   ├── benchmark-4way.sh          # Quick A/B/C/D comparison
│   ├── benchmark-overnight.sh     # Full statistical benchmark suite
│   ├── benchmark-paper.sh         # Repeated-run benchmark campaign
│   ├── calibrate-omp.sh           # OMP thread tuning
│   └── rebuild-metal.sh           # Incremental rebuild
├── benchmarks/qe_yambo/           # Benchmark configs, inputs, analysis
├── benchmarks/si64_scf/           # Si64 SCF benchmark design
├── tests/                         # Integration test suite
├── docs/                          # Integration notes, design documents, corrections
├── results/                       # Benchmark output (local, gitignored)
└── deps/                          # Local apple-bottom and QE source (gitignored)
```

## Ecosystem

- [apple-bottom](https://github.com/grantdh/apple-bottom) — FP64-class BLAS on Apple Silicon GPU (the engine)
- [YAMBOrghini](https://github.com/grantdh/YAMBOrghini) — Yambo GW/BSE + Metal GPU acceleration
- [MEEPhistopheles](https://github.com/grantdh/MEEPhistopheles) — MEEP FDTD + Metal GPU acceleration
- [rainbow-connection](https://github.com/grantdh/rainbow-connection) — Multi-physics pipeline orchestrator (QE → Yambo → MEEP)

## License

GPL-2.0 (matching Quantum ESPRESSO's license)
