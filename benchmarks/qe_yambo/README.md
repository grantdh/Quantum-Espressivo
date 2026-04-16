# QE + Yambo × apple-bottom Benchmarks

Three-way comparison driver for the full DFT → GW → BSE pipeline, using
apple-bottom's runtime `AB_MODE` knob to switch between dispatch strategies
without recompiling.

## Configurations

| Config   | `AB_MODE` | Dispatch behavior                                         |
|----------|-----------|-----------------------------------------------------------|
| baseline | `cpu`     | All ZGEMM/DGEMM pass through to Accelerate (AMX-only)     |
| gpu      | `gpu`     | Every call above `MIN_GPU_DIM=32` goes to Metal GPU       |
| hybrid   | `auto`    | Heterogeneous heuristic: AMX for small, GPU for large     |

The same binaries (`pw.x`, `yambo`) are used for all three — selection is
purely runtime. This is what makes the comparison fair.

## Prerequisites

- apple-bottom built with `AB_MODE` support: `make clean && make test`
  should report 56/56 passing.
- QE 7.4.1 linked against `libapplebottom.dylib` in `~/qe-test/builds/mpi-gpu/`.
- Yambo 5.3.0 (DP) linked similarly in `~/yambo-build/builds/dp-mpi-gpu/`.
- Working GaAs BSE input set in `~/Dev/yambo-build/gaas-bse/`.

## Running

```bash
./run_all.sh                 # QE Si-{8,16,32,64} + Yambo GaAs BSE, all 3 modes
./bench_qe.sh si32           # QE Si-32 only, all 3 modes
./bench_yambo.sh gaas        # Yambo GaAs GW+BSE, all 3 modes
./aggregate_results.py       # Produces results/summary.csv + plot
```

Results land in `results/<system>/<mode>/` with wall time, GEMM profile
(`AB_PROFILE_FILE`), and the canonical output file for correctness checks.
