# Implementation Plan: `charts_and_plots_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [x] Task: Add `@(scenario)` executable specifications in `tests/spec_chart.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [x] Add `@(scenario)` specs for coordinate mapping from world coordinates `[min, max]` to inner sub-cell canvas pixels.
    - [x] Add `@(scenario)` specs for X and Y axis border, tick placement, and label alignment.
    - [x] Add `@(scenario)` specs for `ui_bar_chart` categorical bar scaling and horizontal/vertical orientations.

## Phase 2: Charts and Bar Charts Implementation (`bifrost/chart.odin`)
- [x] Task: Implement 2D Cartesian Coordinate Chart (`ui_chart`)
    - [x] Implement axis geometry layout solver (calculating label widths and inner plot margins).
    - [x] Implement axis border and grid line rasterizer.
    - [x] Implement multi-dataset mapper and Braille sub-cell renderer.
    - [x] Implement dataset legend renderer.
- [x] Task: Implement Categorical Bar Chart (`ui_bar_chart`)
    - [x] Implement vertical bar chart layout with auto-scaled column bars and base labels.
    - [x] Implement horizontal bar chart layout with row labels and value indicators.

## Phase 3: Showcase & Verification
- [x] Task: Integrate charts into `examples/widget_showcase/main.odin` and verify all test suites
    - [x] Add interactive multi-series telemetry charts to `examples/widget_showcase/main.odin`.
    - [x] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
