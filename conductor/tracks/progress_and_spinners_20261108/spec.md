# Specification: Track 16 — Progress Bars, Gauges & Indeterminate Spinners (`ui_progress_bar`, `ui_gauge`, `ui_spinner`) (`progress_and_spinners_20261108`)

## Overview
Add visual progress and activity feedback components to `bifrost` to provide rich status indications for async Sleipnir actor jobs, `xitdb` bulk operations, and task pipelines:
1. `ui_progress_bar`: Continuous progress bar supporting normalized ratio (`0.0 .. 1.0`), partial sub-cell block characters (`▏▎▍▌▋▊▉█`), percentage label overlays, and dual-tone filled/unfilled styles.
2. `ui_gauge`: Block-based or compact line gauge with configurable thresholds (e.g. green < 70%, yellow 70-90%, red > 90%) and centered custom text labels.
3. `ui_spinner`: Indeterminate activity spinner cycling through animated character sets (`dots`, `line`, `pulse`, `circle`) driven by coordinator frame timestamps or tick counters.

## Reference Implementations
- `reference/ratatui` (`ratatui-widgets/src/gauge.rs`, `ratatui-widgets/src/line_gauge.rs` — partial Unicode block fill sub-cell precision)
- `reference/bubbletea` (`bubbles/spinner/spinner.go` — standard spinner presets and frame stepping)

## Functional Requirements

1. **Sub-Cell Progress Bar & Gauge (`bifrost/progress.odin`):**
   - Support ratio $r \in [0.0, 1.0]$.
   - Compute filled cells: full blocks (`█`), fractional remainder using Unicode 1/8th horizontal blocks (`▏`, `▎`, `▍`, `▌`, `▋`, `▊`, `▉`), and empty background track cells (`░` or custom background color).
   - Support text overlay (e.g., `" 68% "` or `" 45/100 MB "`) centered within the bar, automatically handling contrasting foreground colors over the filled vs unfilled sections.
   - Configurable color gradients or threshold rules (`Threshold_Color{above: 0.8, color: red}`).

2. **Indeterminate Animated Spinners (`ui_spinner` in `bifrost/progress.odin`):**
   - Provide standard spinner presets:
     - `.Dots`: `⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`, `⠦`, `⠧`, `⠇`, `⠏`
     - `.Line`: `-`, `\`, `|`, `/`
     - `.Pulse`: ` `, `▃`, `▄`, `▅`, `▆`, `▇`, `█`, `▇`, `▆`, `▅`, `▄`, `▃`
     - `.Moon`: `🌑`, `🌒`, `🌓`, `🌔`, `🌕`, `🌖`, `🌗`, `🌘`
   - Advance frame based on `tick` count or monotonic milliseconds (`time.Tick` / `now_ms`).
   - Render companion status label (e.g., `⠹ Compiling actor targets...`).

3. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Pure `@(scenario)` specs in `tests/spec_progress.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Upgrade `examples/log_monitor/main.odin` to display live throughput gauges and background actor worker spinners.

## Acceptance Criteria
- `ui_progress_bar` renders exact sub-cell block boundaries without rounding errors or terminal cursor desyncs.
- `ui_spinner` cycles smoothly with zero memory allocations per tick.
- Passes all ATDD and unit tests under `-vet -strict-style`.
