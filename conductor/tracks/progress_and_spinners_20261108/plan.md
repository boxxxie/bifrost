# Implementation Plan: `progress_and_spinners_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [x] Task: Add `@(scenario)` executable specifications in `tests/spec_progress.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [x] Add `@(scenario)` specs for `ui_progress_bar` fractional sub-cell block calculations (`▏` through `█`).
    - [x] Add `@(scenario)` specs for centered text overlay with dual-color filled/unfilled cell splits.
    - [x] Add `@(scenario)` specs for `ui_spinner` frame index advancement across various preset styles.

## Phase 2: Progress Bars, Gauges & Spinners (`bifrost/progress.odin`)
- [x] Task: Implement `ui_progress_bar` and `ui_gauge`
    - [x] Implement mathematical sub-cell quantizer and cell fill emitter.
    - [x] Implement label overlay rasterizer with inverted/contrasted text rendering over filled portions.
    - [x] Implement threshold color evaluation.
- [x] Task: Implement `ui_spinner`
    - [x] Implement preset character animation tables (`.Dots`, `.Line`, `.Pulse`, `.Moon`).
    - [x] Implement frame evaluation and companion label drawing.

## Phase 3: Showcase & Verification
- [x] Task: Integrate progress bars and spinners into `examples/log_monitor/main.odin` and verify all test suites
    - [x] Add memory/cpu threshold gauges and active worker spinners to `examples/log_monitor/main.odin`.
    - [x] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
