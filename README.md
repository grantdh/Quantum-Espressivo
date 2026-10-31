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

The scripts fetch apple-bottom 1.4.0 and one commit of QE's `develop` branch (`b6615c50`, 2026-10-30, which reports version 8.0dev), so that a build can be repeated. [`scripts/common.sh`](scripts/common.sh) holds these pins; `APPLE_BOTTOM_COMMIT` or `QE_COMMIT` in the environment overrides them. Each QE build records what it was made from in `PROVENANCE.txt`, next to its `bin/`.

### Prerequisites

- macOS 14+ (Sonoma) with Xcode 16+ SDK
- Apple Silicon (M1 or later)
- Homebrew packages: `gcc`, `open-mpi`, `openblas`, `fftw`, `scalapack`, `cmake`

### Build Steps

```bash
git clone https://github.com/grantdh/Quantum-Espressivo.git
cd Quantum-Espressivo

# 1. Fetch and build apple-bottom, and run its tests (or set APPLE_BOTTOM_DIR to a built checkout)
./scripts/setup-apple-bottom.sh

# 2. Fetch QE and build pw.x linked against apple-bottom; QE's source is not changed
./scripts/build-qe-metal.sh

# 3. Run that pw.x with AB_MODE=cpu and with AB_MODE=gpu, and compare the results
./scripts/validate.sh

# Optional: the Accelerate-only build that the benchmarks compare against
./scripts/build-qe-accelerate.sh
```

`validate.sh` passes when the two runs converge in the same number of SCF iterations to the same total energy (within 10⁻⁶ Ry) and the gpu run computed GEMMs on the GPU. It reports both runs' energies, apple-bottom's GPU and CPU calls, and the GPU share of their time. Its default input, an 8-atom silicon cell, runs in seconds; `--input` takes any pw.x input.

### Benchmarking

```bash
# Quick comparison: OpenBLAS, Accelerate, and the apple-bottom build with AB_MODE=auto and AB_MODE=gpu
./scripts/benchmark-4way.sh

# Overnight sweep (several systems, repeated runs, statistics)
./scripts/benchmark-overnight.sh
```

The runs of apple-bottom builds go through [`scripts/with-ab-profile.sh`](scripts/with-ab-profile.sh), so that each process (each MPI rank) writes apple-bottom's profile, and [`scripts/ab_profile.py`](scripts/ab_profile.py) adds them up. Benchmark configurations and analysis scripts are in [`benchmarks/qe_yambo/`](benchmarks/qe_yambo/).

## Requirements

- **QE version**: 7.5 or later (the `.bands` post-processing tool requires 7.5); the build scripts fetch the `develop` commit pinned in `scripts/common.sh`
- **apple-bottom**: 1.4 or later, built with `MTLMathModeSafe` (Xcode 16+ SDK); its accuracy is documented in its [precision envelope](https://github.com/grantdh/apple-bottom/blob/main/docs/vv/PRECISION_ENVELOPE.md)
- Do **not** use DYLD_INSERT_LIBRARIES interposition — it has been tested and abandoned due to dispatch overhead. Rebuild QE against apple-bottom as an explicit linker input.

## Repository Structure

```
Quantum-Espressivo/
├── scripts/
│   ├── common.sh                  # Pinned versions and paths, shared by the scripts
│   ├── setup-apple-bottom.sh      # Fetch and build apple-bottom
│   ├── build-qe-metal.sh          # Fetch QE and build it against apple-bottom
│   ├── build-qe-accelerate.sh     # Accelerate baseline build
│   ├── build-qe-openblas.sh       # OpenBLAS baseline build
│   ├── validate.sh                # AB_MODE=cpu against AB_MODE=gpu, same pw.x
│   ├── benchmark-4way.sh          # Quick A/B/C/D comparison
│   ├── benchmark-overnight.sh     # Full statistical benchmark suite
│   ├── benchmark-paper.sh         # Repeated-run benchmark campaign
│   ├── calibrate-omp.sh           # OMP thread tuning
│   ├── rebuild-metal.sh           # Rebuild apple-bottom and relink pw.x
│   ├── with-ab-profile.sh         # Run a program with apple-bottom's profile, one file per process
│   └── ab_profile.py              # Add up a run's apple-bottom profiles
├── benchmarks/qe_yambo/           # Benchmark configs, inputs, analysis
├── benchmarks/si64_scf/           # Si64 SCF benchmark design
├── tests/                         # Integration test and validate.sh's input
├── docs/                          # Integration notes, design documents, corrections
├── results/                       # Benchmark output (local, gitignored)
└── deps/                          # apple-bottom and QE sources and builds (gitignored)
```

## Ecosystem

- [apple-bottom](https://github.com/grantdh/apple-bottom) — FP64-class BLAS on Apple Silicon GPU (the engine)
- [YAMBOrghini](https://github.com/grantdh/YAMBOrghini) — Yambo GW/BSE + Metal GPU acceleration
- [MEEPhistopheles](https://github.com/grantdh/MEEPhistopheles) — MEEP FDTD + Metal GPU acceleration
- [rainbow-connection](https://github.com/grantdh/rainbow-connection) — Multi-physics pipeline orchestrator (QE → Yambo → MEEP)

## License

GPL-2.0 (matching Quantum ESPRESSO's license)
