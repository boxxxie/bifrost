# Implementation Plan: `progress_and_spinners_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_progress.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for `ui_progress_bar` fractional sub-cell block calculations (`▏` through `█`).
    - [ ] Add `@(scenario)` specs for centered text overlay with dual-color filled/unfilled cell splits.
    - [ ] Add `@(scenario)` specs for `ui_spinner` frame index advancement across various preset styles.

## Phase 2: Progress Bars, Gauges & Spinners (`bifrost/progress.odin`)
- [ ] Task: Implement `ui_progress_bar` and `ui_gauge`
    - [ ] Implement mathematical sub-cell quantizer and cell fill emitter.
    - [ ] Implement label overlay rasterizer with inverted/contrasted text rendering over filled portions.
    - [ ] Implement threshold color evaluation.
- [ ] Task: Implement `ui_spinner`
    - [ ] Implement preset character animation tables (`.Dots`, `.Line`, `.Pulse`, `.Moon`).
    - [ ] Implement frame evaluation and companion label drawing.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate progress bars and spinners into `examples/log_monitor/main.odin` and verify all test suites
    - [ ] Add memory/cpu threshold gauges and active worker spinners to `examples/log_monitor/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
