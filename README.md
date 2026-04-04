# Espressivo (Caffè Corretto)

**Apple Silicon GPU acceleration for Quantum ESPRESSO**

This project provides Metal GPU acceleration for Quantum ESPRESSO on Apple Silicon Macs, following the successful model of [q-e-gpu](https://github.com/fspiga/qe-gpu) which brought CUDA acceleration to QE.

## Overview

Espressivo integrates the [apple-bottom](https://github.com/grantdh/apple-bottom) FP64-class BLAS library to accelerate Quantum ESPRESSO's dense linear algebra operations on Apple Silicon GPUs using double-float (DD) arithmetic.

### Why "Espressivo"?

- **Espresso**: The Italian connection to Quantum ESPRESSO
- **Expressive**: The performance gains speak for themselves
- **Espressivo**: A musical term meaning "with expression" — fitting for bringing new life to QE on macOS

The alternative name "Caffè Corretto" (espresso "corrected" with a shot of spirits) playfully suggests QE enhanced with Apple Silicon acceleration.

## Status

**Phase 0: Foundation** (Current)
- Building standalone apple-bottom library
- Validating precision and performance
- Preparing for community engagement

**Phase 1: Community** (Weeks 2-8)
- Publish benchmarks and blog post
- Gather user feedback
- Multi-chip validation

**Phase 2: Integration** (Months 2-3)
- Contact QE development team
- Implement their requirements
- Submit patches upstream

## Architecture

```
Quantum ESPRESSO
      |
   LAXlib
      |
  [Espressivo]  <-- Metal acceleration layer
      |
 apple-bottom   <-- FP64-class BLAS on Metal
      |
  Apple Metal
```

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4 series)
- macOS 14+ (Sonoma) with Xcode 16+ SDK (for MTLMathModeSafe)
- Quantum ESPRESSO 7.4 or 7.5
- Xcode Command Line Tools

## Quick Start

```bash
# Clone the repository
git clone https://github.com/grantdh/Quantum-Espressivo.git
cd Quantum-Espressivo

# Set up apple-bottom dependency
./scripts/setup-apple-bottom.sh

# Apply patches to QE (coming soon)
./scripts/patch-qe.sh /path/to/qe-7.5

# Build with Metal support
./scripts/build-qe-metal.sh

# Run validation
./scripts/validate.sh
```

## Performance

Validated results on M2 Max (38-core GPU):
- DGEMM: 643 GFLOP/s (4096×4096 matrices, FP64-class via DD)
- ZGEMM: Benchmarks coming
- Si64 SCF: 1.22× speedup vs CPU BLAS

Full benchmarks and performance analysis coming soon.

## Precision

Target: ~10⁻¹⁵ relative error (Frobenius norm)
- Uses compensated summation (DD arithmetic)
- MTLMathModeSafe prevents FMA reordering
- Validated against reference BLAS

## Project Structure

```
Espressivo/
├── patches/        # QE source patches for Metal integration
├── scripts/        # Build and integration scripts
├── docs/          # Documentation and benchmarks
├── examples/      # Example QE input files
└── tests/         # Validation suite
```

## Contributing

This project follows the q-e-gpu model of external development with upstream integration. Contributions welcome!

1. Test on your Apple Silicon Mac
2. Report benchmarks and issues
3. Submit patches for additional QE modules

## Related Projects

- [apple-bottom](https://github.com/grantdh/apple-bottom): The underlying FP64-class BLAS library
- [Quantum ESPRESSO](https://www.quantum-espresso.org/): The quantum chemistry package we're accelerating
- [q-e-gpu](https://github.com/fspiga/qe-gpu): The CUDA acceleration project that inspired this approach

## License

GPL-2.0 (matching Quantum ESPRESSO's license)

## Contact

Grant Heileman

## Acknowledgments

- Filippo Spiga for the q-e-gpu model and inspiration
- The Quantum ESPRESSO development team
- Apple's Metal Performance Shaders team