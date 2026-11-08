# Specification: Track 20 — Auto-Scrolling Log Stream Viewer, Table Column Controls & OSC 8 Hyperlinks (`ui_log_viewer`, OSC 8, Table Sorting) (`log_stream_and_table_controls_20261108`)

## Overview
Add professional developer tooling and terminal protocol extensions to `bifrost`:
1. `ui_log_viewer`: A streaming log viewer container featuring "tail -f" auto-scroll pinning to the bottom on new rows, automatic pause/freeze when the user manually scrolls up, and a sticky "Jump to Latest" indicator badge.
2. Interactive Table Controls: Sortable table column headers with ascending/descending indicators (`▲` / `▼`) and mouse-draggable column border dividers to resize column widths interactively.
3. OSC 8 Hyperlinks: Support for terminal emulator clickable URLs (`\x1b]8;;url\x1b\...`) inside cell rendering and ANSI diff output.

## Reference Implementations
- `bifrost/scroll.odin` (`ui_virtual_list`, `register_virtual_table_col_spans`)
- `bifrost/splitter.odin` (`ui_splitter` mouse drag boundary calculation)
- `bifrost/renderer.odin` (`screen_diff_ansi`)
- `examples/log_monitor/main.odin` (stream burst and moment pinning)

## Functional Requirements

1. **Auto-Scrolling Log Viewer (`ui_log_viewer` in `bifrost/log_stream.odin`):**
   - Manage scroll state with sticky auto-follow flag (`is_pinned_to_bottom: bool`).
   - If pinned and new rows arrive, automatically clamp viewport offset to `total_rows - visible_rows`.
   - If the user scrolls up via mouse wheel, `k`/`Up`, or page keys, unpin auto-follow and show a floating pill badge: `[ ▾ Jump to Latest (N new) ]`.
   - Clicking the badge or pressing `G` / `End` scrolls back to the latest row and re-enables auto-follow.
   - Built-in log level color highlights (`DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`).

2. **Interactive Table Column Controls (`bifrost/scroll.odin`):**
   - Column Sort Headers:
     - Header cells accept an active sort state (`sort_col: int`, `sort_dir: enum { None, Asc, Desc }`).
     - Clicking or pressing `Enter` on a column header cycles `None -> Asc -> Desc -> None` and emits a sort change event.
     - Renders subtle `▲` (ascending) or `▼` (descending) indicators in the header text.
   - Draggable Column Divider:
     - Mouse hovering over a column separator displays a resize cursor.
     - Dragging horizontally adjusts the width of the left column with min/max width constraints.

3. **OSC 8 Terminal Hyperlinks (`bifrost/renderer.odin`):**
   - Support `url` attribute on `Paint_Spec` or `Cell`.
   - In `screen_diff_ansi`, emit `\x1b]8;;<url>\x1b\` when entering a hyperlink cell span and `\x1b]8;;\x1b\` when exiting.
   - Graceful fallback: term terminals that ignore OSC 8 simply display the plain cell text.

4. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Pure `@(scenario)` specs in `tests/spec_log_stream.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Integrate `ui_log_viewer` directly into `examples/log_monitor/main.odin` and sortable columns into `examples/xitdb_explorer/main.odin`.

## Acceptance Criteria
- `ui_log_viewer` cleanly transitions between pinned auto-scroll and manual review without skipping or jumping rows.
- Table column dragging respects parent bounds and min/max constraints without flickering.
- OSC 8 sequences are properly opened and closed in the ANSI diff emitter with zero memory leaks.
