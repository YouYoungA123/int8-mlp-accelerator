# INT8 MLP Accelerator with Batch-Level Weight Reuse

RTL implementation and verification environment for a three-layer INT8 MLP accelerator using a weight-stationary 32×32 PE array, A/B/S buffers, batch tiling, and batch-level weight reuse.

## Architecture

- Network: `800 → 128 → 64 → 32`
- Arithmetic: signed INT8 activation/weight, INT32 accumulation
- Post-processing: bias, arithmetic shift, ReLU, INT8 saturation
- Dataflow:
  - L1: active A/B bank → S buffer
  - L2: S buffer → active A/B bank
  - L3: active A/B bank → output SRAM
- Scheduling: `Batch tile → Layer → Output group → Input group → Batch in tile`
- Weight reuse: each 32×32 weight tile is loaded once and reused across the samples in the active batch tile

## Verified results

For the same Batch 4 condition:

| Metric | Baseline | Weight-reuse RTL | Improvement |
|---|---:|---:|---:|
| Total cycles | 118,613 | 76,600 | 35.42% reduction |
| Cycles/inference | 29,653.25 | 19,150.00 | 1.548× speedup |
| Weight-tile loads | 440 | 110 | 75% reduction |
| Final outputs | 128 | 128 | 0 errors |
| Intermediate activations | 192 | 192 | 0 errors |

Regression cases cover Batch 1, 4, 5, 7, and 8, incomplete final tiles, DRAM stalls, restart behavior, intermediate activations, and final outputs. The Batch-4 restart case also passes two consecutive inferences without resetting the DUT. A separate waveform-oriented test checks DMA request/response bursts and A/B buffer ownership transfer.

## Synthesis status

Vivado 2022.2 synthesis completed for `xczu2cg-sfvc784-1-e`, but the current fully parallel 32×32 design does not fit:

| Resource | Utilization |
|---|---:|
| CLB LUT | 196.15% |
| CARRY8 | 128.22% |
| Registers | 23.22% |
| Block RAM | 21.67% |
| DSP | 0 / 240 |

The next hardware-targeted revision will reduce the physical PE array and time-multiplex the logical 32×32 tile while enabling DSP inference.

## Repository layout

```text
rtl/                    RTL modules
tb/                     functional, regression, and handshake testbenches
scripts/                Vivado simulation scripts
constraints/            target clock/device constraints
verification/generated/ test vectors and golden data
reports/                representative simulation and synthesis reports
vivado/                  reproducible project creation script
docs/                    implementation notes
```

## Create the Vivado project

From the Vivado Tcl shell:

```tcl
cd <repository-root>
source vivado/create_project.tcl
```

This creates a local project in `build/adventure_dma8`. Generated project files are intentionally ignored by Git.

## Run verification

After opening the generated project, run all regression cases:

```tcl
source scripts/run_regression.tcl
```

Run the waveform-oriented DMA/buffer ownership test:

```tcl
source scripts/run_handshake_wave.tcl
```

Passing cases print:

```text
REGRESSION TEST PASS
HANDSHAKE WAVE TEST PASS
```

## Scope

This repository captures the functionally verified 32×32 architecture before the FPGA-fit redesign. Synthesis success does not imply implementation feasibility; place-and-route and bitstream generation require the planned reduced physical PE array.
