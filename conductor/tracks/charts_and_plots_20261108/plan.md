# Implementation Plan: `charts_and_plots_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_chart.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for coordinate mapping from world coordinates `[min, max]` to inner sub-cell canvas pixels.
    - [ ] Add `@(scenario)` specs for X and Y axis border, tick placement, and label alignment.
    - [ ] Add `@(scenario)` specs for `ui_bar_chart` categorical bar scaling and horizontal/vertical orientations.

## Phase 2: Charts and Bar Charts Implementation (`bifrost/chart.odin`)
- [ ] Task: Implement 2D Cartesian Coordinate Chart (`ui_chart`)
    - [ ] Implement axis geometry layout solver (calculating label widths and inner plot margins).
    - [ ] Implement axis border and grid line rasterizer.
    - [ ] Implement multi-dataset mapper and Braille sub-cell renderer.
    - [ ] Implement dataset legend renderer.
- [ ] Task: Implement Categorical Bar Chart (`ui_bar_chart`)
    - [ ] Implement vertical bar chart layout with auto-scaled column bars and base labels.
    - [ ] Implement horizontal bar chart layout with row labels and value indicators.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate charts into `examples/widget_showcase/main.odin` and verify all test suites
    - [ ] Add interactive multi-series telemetry charts to `examples/widget_showcase/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
