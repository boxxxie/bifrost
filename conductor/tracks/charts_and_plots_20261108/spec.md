# Specification: Track 17 — Cartesian 2D Coordinate Charts & Categorical Bar Charts (`ui_chart`, `ui_bar_chart`) (`charts_and_plots_20261108`)

## Overview
Add full-featured Cartesian charts and categorical bar charts to `bifrost`, building upon the sub-cell Braille foundation of `ui_canvas` to provide publication-grade telemetry and scientific visualization in the terminal:
1. `ui_chart`: A 2D Cartesian coordinate chart widget featuring labeled X and Y axes, configurable tick marks, coordinate bounds (`[x_min..x_max]`, `[y_min..y_max]`), grid lines, legends, and multi-dataset rendering (scatter points, continuous lines, step lines).
2. `ui_bar_chart`: Categorical vertical and horizontal multi-bar charts with value labels, auto-scaling, customizable bar widths, and group gaps.

## Reference Implementations
- `reference/ratatui` (`ratatui-widgets/src/chart.rs`, `ratatui-widgets/src/barchart.rs` — coordinate transformation, axis layout, and tick formatting)
- `bifrost/canvas.odin` (`ui_canvas`, `canvas_draw_line`, `canvas_draw_series`)

## Functional Requirements

1. **Cartesian Coordinate Chart (`ui_chart` in `bifrost/chart.odin`):**
   - Axis Configuration (`Axis_Config`):
     - `title`: Axis title string.
     - `bounds`: `[2]f64` representing `[min, max]`.
     - `labels`: Slice of formatted tick strings placed along the axis.
     - `style`: Foreground/background/modifier styling for axis lines and labels.
   - Drawing Area:
     - Reserve cells for Y-axis labels on the left and X-axis labels on the bottom.
     - Render axis box lines (`┌`, `└`, `┼`, `│`, `─`) and optional dotted grid lines (`·` / `┼`).
     - Map floating-point data points $(x, y) \in [x_{\min}, x_{\max}] \times [y_{\min}, y_{\max}]$ to the inner canvas sub-cell coordinates $(px, py)$.
   - Multi-Dataset Support:
     - Each `Dataset` specifies `name`, `data: [][2]f64`, marker style (`.Braille_Line`, `.Braille_Dots`, or `.Cell_Points`), and series color.
   - Legend Box:
     - Auto-positioned legend showing series names with colored sample indicators.

2. **Categorical Bar Chart (`ui_bar_chart` in `bifrost/chart.odin`):**
   - Direction: Vertical (`.Vertical`) or Horizontal (`.Horizontal`).
   - Data items: `[]Bar_Data{label: string, value: u64, color: Color}`.
   - Layout:
     - Compute maximum value across items to auto-scale bar lengths.
     - Draw solid or shaded bars (`█`, `▓`, `▒`, `░`) with category labels and exact numeric values rendered at the tip or base.

3. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Pure `@(scenario)` specs in `tests/spec_chart.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Add a telemetry analysis dashboard tab in `examples/widget_showcase/main.odin` showcasing both multi-line Cartesian charts and categorical resource bar charts.

## Acceptance Criteria
- `ui_chart` accurately projects data points into sub-cell coordinates without out-of-bounds clipping crashes.
- Axis labels and tick marks align precisely with grid intersection points.
- Passes all ATDD and unit tests under `-vet -strict-style`.
