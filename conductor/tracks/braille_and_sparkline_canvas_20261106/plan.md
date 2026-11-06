# Implementation Plan: `braille_and_sparkline_canvas_20261106`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [x] Task: Add `@(scenario)` executable specifications in `tests/spec_canvas.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [x] Add `@(scenario)` specs for $2\times 4$ Unicode Braille bitmask mapping (`U+2800..U+28FF`), Bresenham line drawing, and polyline series rasterization.
    - [x] Add `@(scenario)` specs for `ui_sparkline` (`▁▂▃▄▅▆▇█`) sample normalization and cell output.

## Phase 2: Braille & Sparkline Canvas (`bifrost/canvas.odin`)
- [x] Task: Implement `ui_canvas` and `ui_sparkline`
    - [x] Implement $2\times 4$ Unicode Braille dot buffer, `canvas_set_point`, `canvas_draw_line`, `canvas_draw_rect`, `canvas_draw_series`, and `ui_canvas` custom draw hook.
    - [x] Implement `ui_sparkline` 8-level block bar renderer (`▁▂▃▄▅▆▇█`).

## Phase 3: Showcase & Verification
- [x] Task: Integrate `ui_canvas` and `ui_sparkline` into `examples/log_monitor/main.odin` and `examples/widget_gallery/main.odin`
    - [x] Add live throughput sparklines and Braille telemetry charts to `examples/log_monitor/main.odin` and `examples/widget_gallery/main.odin`.
    - [x] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
