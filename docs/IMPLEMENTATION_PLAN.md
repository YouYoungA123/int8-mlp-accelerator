# FPGA-fit implementation plan

The checked-in RTL is the verified 32×32 reference architecture. It synthesizes but exceeds the resources of `xczu2cg-sfvc784-1-e`.

## Planned progression

1. Define a 16×8 physical PE array (128 multipliers), with 8×8 as the fallback.
2. Split each logical 32×32 tile into physical sub-tiles.
3. Verify one logical tile against the current 32×32 reference result.
4. Integrate sub-tile counters and partial-sum addressing into the wrapper.
5. Re-run Batch 1, 4, and 5 regression tests and the handshake test.
6. Confirm DSP inference and resource use below 100%.
7. Run implementation and require post-route setup/hold slack ≥ 0.
8. Generate the bitstream and connect the host/board data path.

At each step, preserve the current A/B/S data lifetime and batch-level weight reuse unless a verified interface change is intentional.

