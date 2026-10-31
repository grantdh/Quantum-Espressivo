# QE + Yambo × apple-bottom Benchmarks

Three-way comparison driver for the full DFT → GW → BSE pipeline, using
apple-bottom's runtime `AB_MODE` knob to switch between dispatch strategies
without recompiling.

## Configurations

| Config   | `AB_MODE` | Dispatch behavior                                         |
|----------|-----------|-----------------------------------------------------------|
| baseline | `cpu`     | All ZGEMM/DGEMM pass through to Accelerate (AMX-only)     |
| gpu      | `gpu`     | Every call with all dimensions above `AB_MIN_GPU_DIM` goes to the Metal GPU (the scripts set it to 0) |
| auto     | `auto`    | apple-bottom's calibrated dispatch table; on an M2 Max it keeps QE's GEMMs on Accelerate |

These are `bench_qe.sh`'s and `bench_yambo.sh`'s modes. The NP × OMP sweep and the
`-ndiag`/`-npool`, precision and cpu-baseline scripts run `auto` with
`AB_CROSSOVER_FLOPS=100000000`, a FLOP threshold that replaces the table: GEMMs
of at least 1e8 FLOPs go to the GPU.

The same binaries (`pw.x`, `yambo`) are used for all three — selection is
purely runtime. This is what makes the comparison fair.

## Prerequisites

- apple-bottom 1.4 or later, built (`make` in its checkout; `make test` passes).
- QE linked against `libapplebottom.dylib`: `./build_qe_ab.sh` builds it
  (paths in `config.sh`).
- Yambo 5.3.0 (DP) linked against apple-bottom (`./build_yambo_ab.sh`). Unlike
  QE's build, it expects a Yambo source tree whose `mod_wrapper{,_omp}.F` call
  `ab_zgemm`/`ab_dgemm`.
- Working GaAs BSE input set in `~/Dev/yambo-build/gaas-bse/`.

## Running

```bash
./run_all.sh                 # QE Si-{8,16,32,64} + Yambo GaAs BSE, all 3 modes
./bench_qe.sh si32           # QE Si-32 only, all 3 modes
./bench_yambo.sh gaas        # Yambo GaAs GW+BSE, all 3 modes
./aggregate_results.py       # Produces results/summary.csv + plot
```

Results land in `results/<system>/<mode>/` with wall time, apple-bottom's
profile (`ab_profile.<pid>.json`, one per process, written through
`scripts/with-ab-profile.sh`; `summary.txt` has the GPU and CPU calls and the
GPU share of their time), and the canonical output file for correctness checks.
