# Implementation Plan: `log_stream_and_table_controls_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_log_stream.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for `ui_log_viewer` pinned auto-scroll and unpin-on-scroll-up state transitions.
    - [ ] Add `@(scenario)` specs for table column header click sorting (`Asc`/`Desc` cycling).
    - [ ] Add `@(scenario)` specs for draggable table column divider width resizing.
    - [ ] Add `@(scenario)` specs for OSC 8 escape code emission in `screen_diff_ansi`.

## Phase 2: Log Stream & Table Controls Implementation (`bifrost/log_stream.odin`, `bifrost/scroll.odin`, `bifrost/renderer.odin`)
- [ ] Task: Implement `ui_log_viewer`
    - [ ] Implement auto-scroll pinning logic and scroll-up detection.
    - [ ] Implement floating "Jump to Latest" indicator badge with mouse click / keybinding handler.
    - [ ] Implement log level colorizer.
- [ ] Task: Implement Table Column Sorting and Draggable Dividers (`bifrost/scroll.odin`)
    - [ ] Implement sort indicator rendering (`▲` / `▼`) and header click toggle.
    - [ ] Implement column boundary hit-testing and mouse drag delta application.
- [ ] Task: Implement OSC 8 Hyperlinks in Renderer (`bifrost/renderer.odin`)
    - [ ] Add URL link tracking in cell diff emitter and output `\x1b]8;;url\x1b\` sequences.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate log viewer and table controls into `examples/log_monitor/main.odin` and `examples/xitdb_explorer/main.odin`
    - [ ] Modernize `examples/log_monitor/main.odin` with the new `ui_log_viewer`.
    - [ ] Enable sortable/resizable columns in `examples/xitdb_explorer/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
