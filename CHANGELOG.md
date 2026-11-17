# Changelog

All notable changes to **Bifrost** (`package bifrost`) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [0.1.0] - 2026-11-17

Initial release of **Bifrost** (`package bifrost`), an immediate-mode, actor-driven Terminal User Interface (TUI) framework for Odin covering Tracks 1–21.

### Added
- **Multi-Pass Topological Layout & Cell Diff Renderer (`bifrost/layout.odin`, `bifrost/renderer.odin`):**
  - Clay-inspired linear non-recursive Flexbox layout solver supporting `Fit`, `Grow` (weighted + freeze-clamped remainder distribution), `Fixed`, `Percent`, word/newline wrapping, and 9-point anchored `z_layer` overlays.
  - Double-buffered cell renderer with wide-glyph (CJK / Emoji) split healing, 4-bit box-drawing junction merging (`surface_merge_box_cell`), 50% RGB / ANSI-256 backdrop dimming, OSC 8 hyperlinks, and DEC Mode 2026 Synchronized Output (`\x1b[?2026h ... \x1b[?2026l`).
- **Cross-Platform Terminal Backend & Input Parser (`bifrost/terminal*.odin`, `bifrost/ansi_parser.odin`):**
  - Zero-CGO POSIX (`termios`, `SIGWINCH`, `poll`) and Windows ConPTY / Console VT terminal backends.
  - ANSI, Kitty keyboard protocol, bracketed paste, focus reporting, and SGR / SGR-Pixels mouse parser.
- **Harel Focus Scopes, 2D Spatial Navigation & Modal Keymaps (`bifrost/focus_scope.odin`, `bifrost/spatial_nav.odin`, `bifrost/keymap.odin`, `bifrost/input.odin`):**
  - Hierarchical `ui_scope` containers with Shallow (`H`) and Deep (`H*`) history, `.Trap_Focus` modal shields, and floating window MRU z-promotion.
  - Integer 2D directional cone navigation with sticky orthogonal lane memory, `.Loop_Spatial` / `.Wrap_Spatial`, `nav_overrides`, and zero-lag `scroll_node_into_view`.
  - Declarative 1- and 2-step key-chord engine with runtime switching between **Vim**, **Helix**, and **Emacs** modal styles, action guards, and contextual `ui_focus_breadcrumb_bar`, `ui_key_hint_bar`, and `ui_which_key_overlay` (`bifrost/status_bars.odin`).
- **Actor Concurrency, Persistent State & Columnar Telemetry (`bifrost/ui_coordinator.odin`, `bifrost/ui_actions_effects.odin`, `bifrost/xitdb_bridge.odin`, `bifrost/workspace_persistence.odin`, `bifrost/heimdall_bridge.odin`):**
  - Single-owner `UI_Coordinator_State` driven over Sleipnir lock-free MPSC/SPSC mailboxes with up to `2048`-message burst coalescing, declarative action sinks, and pure `UI_Side_Effect` emissions (including zero-CGO OSC 52 clipboard).
  - Background `Xitdb_Worker_State` transactions, `O(log16 N)` virtualized viewport slicing (`xitdb_slice_viewport`), and persistent workspace snapshots (`save_ui_workspace_to_xitdb` / `load_ui_workspace_from_xitdb`).
  - Built-in Heimdall span/metric instrumentation across coordinator, layout, input, renderer, and xitdb paths, plus zero-copy `Heimdall_Segment_Store` Arrow IPC segment inspection.
- **Zero-Allocation Widget Suite:**
  - Core primitives (`container`, `leaf`, `ui_scope`, `ui_label`, `ui_button`, `ui_modal`) and fuzzy `ui_command_palette`.
  - Single-line `ui_text_input` (`bifrost/text_input.odin`) and multi-line `ui_text_area` (`bifrost/text_area.odin`) with grapheme stepping, 2D selection, OSC 52 clipboard, and Odin/CUE syntax highlighting.
  - Virtualized 2D `ui_table` / `ui_virtual_list` (`bifrost/table.odin`, `bifrost/scroll.odin`) and SIMD RFC 4180 `CSV_Grid_Table` (`bifrost/csv_grid.odin`) with frozen `pinned_cols`, sorting, column resizing, and interval multi-row selection.
  - Collapsible `ui_tree` (`bifrost/tree.odin`), H*-restored `ui_tabs` / `ui_tab_bar` (`bifrost/tabs.odin`), interactive `ui_splitter` (`bifrost/splitter.odin`), 2x4 Braille `ui_canvas` & `ui_sparkline` (`bifrost/canvas.odin`), form controls (`ui_checkbox`, `ui_switch`, `ui_radio_group`, `ui_slider`, `ui_dropdown` in `bifrost/form_controls.odin`), progress/gauges/spinners (`ui_progress_bar`, `ui_gauge`, `ui_spinner` in `bifrost/progress.odin`), 2D/bar charts (`ui_chart`, `ui_bar_chart` in `bifrost/chart.odin`), rich-text & Markdown (`ui_paragraph`, `ui_markdown` in `bifrost/paragraph.odin`), modal dialogs/toasts/tooltips (`ui_confirm_dialog`, `ui_alert`, `ui_prompt`, `ui_toast_stack`, `ui_tooltip` in `bifrost/dialogs.odin`), and `ui_log_viewer` (`bifrost/log_stream.odin`).
- **AST Metaprogramming Tooling & 4-Layer ATDD Suite (`bifrost/codegen/`, `tools/bifrost_gen/`, `tests/`):**
  - `bifrost_gen` CLI for key-chord & ATDD DSL code generation (`--atdd`) and `temp_allocator` hygiene linting (`--lint-temp`).
  - `150` verified tests (`56` unit tests in `bifrost`, `6` codegen tests in `bifrost/codegen`, `88` 4-layer ATDD specs in `tests`) with zero-leak tracking-allocator verification.
- **Examples, Documentation & Cross-Platform CI (`examples/`, `docs/`, `README.md`, `usage_rules.md`, `.github/workflows/`):**
  - `9` deterministic headless + `--live-tty` example applications (`widget_gallery`, `widget_showcase`, `kanban_board`, `log_monitor`, `xitdb_inspector`, `xitdb_explorer`, `keymap_workbench`, `heimdall_inspector`, `csv_workbench`).
  - GitHub Actions CI matrix across `ubuntu-latest`, `macos-latest`, and `windows-latest` plus automated tag release workflow (`.github/workflows/release.yml`).

### Dependencies
- **Sleipnir:** `v1.1.3` (`deps/sleipnir`)
- **xitdb:** `v2.0.0` (`deps/xitdb`)
- **Heimdall:** `v0.1.0` (`deps/heimdall`)

[Unreleased]: https://github.com/boxxxie/bifrost/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/boxxxie/bifrost/releases/tag/v0.1.0
