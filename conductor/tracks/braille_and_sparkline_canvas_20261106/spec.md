# Specification: Track 14 — Braille & Sparkline Data-Viz Canvas (`ui_canvas`, `ui_sparkline`) (`braille_and_sparkline_canvas_20261106`)

## Overview
Add zero-allocation terminal data-visualization primitives (`ui_canvas`, `ui_sparkline`) to `bifrost`:
1. `ui_canvas`: An immediate-mode sub-cell canvas mapping $(2W) \times (4H)$ virtual pixels into `Screen` cells via Unicode Braille patterns (`U+2800..U+28FF`), supporting points, Bresenham lines, rectangles, and time-series polylines with per-cell RGB foreground coloring.
2. `ui_sparkline`: A compact 1-row or multi-row vertical block bar chart (`▁▂▃▄▅▆▇█`) for real-time actor telemetry and `xitdb` metrics.

## Reference Implementations
- `reference/ftxui` (`src/ftxui/dom/canvas.cpp` — $2\times 4$ Braille dot matrix encoding `U+2800` + bitmask and Bresenham line rasterization)

## Functional Requirements

1. **Unicode Braille Sub-Cell Canvas (`bifrost/canvas.odin`):**
   - Map virtual sub-cell coordinates $(px, py) \in [0, 2W) \times [0, 4H)$ to cell $(px / 2, py / 4)$ and set the corresponding ISO/TR 11548-1 Braille dot bit:
     - Left column ($px \bmod 2 = 0$): rows $0..3 \to$ bits `0x01`, `0x02`, `0x04`, `0x40`
     - Right column ($px \bmod 2 = 1$): rows $0..3 \to$ bits `0x08`, `0x10`, `0x20`, `0x80`
   - Provide drawing primitives: `canvas_set_point`, `canvas_draw_line` (integer Bresenham), `canvas_draw_rect`, and `canvas_draw_series` (connected polyline from `[]f32` or `[]f64` samples) with per-cell foreground color.

2. **Vertical Block Sparkline (`ui_sparkline` in `bifrost/canvas.odin`):**
   - Render a slice of numeric samples (`[]f32` / `[]int`) across the widget width using the 8-level Unicode block glyphs (`▁`, `▂`, `▃`, `▄`, `▅`, `▆`, `▇`, `█`, `U+2581..U+2588`), supporting auto-scaling or explicit `[min_val, max_val]` bounds.

3. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Add pure `@(scenario)` specifications in `tests/spec_canvas.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Showcase `ui_canvas` and `ui_sparkline` in `examples/log_monitor/main.odin` and `examples/widget_gallery/main.odin`.

## Acceptance Criteria
- `ui_canvas` and `ui_sparkline` pass `odin run tools/bifrost_gen -- --atdd tests`, unit tests, and `@(scenario)` ATDD tests with zero per-frame heap leaks and full `vt_cells` ANSI diff equivalence.
