# Bifrost (`package bifrost`)

An immediate-mode, actor-driven Terminal User Interface (TUI) framework for [Odin](https://odin-lang.org/), designed to bridge [**Sleipnir (`package actor`)**](deps/sleipnir) and [**xitdb (`package xitdb`)**](deps/xitdb).

---

## Architectural Highlights

- **Subsystem Actor Concurrency (`ui_coordinator.odin`, `ui_actions_effects.odin`, `terminal.odin`):** Dedicated input, timer, and background worker actors communicate via lock-free `sleipnir` mailboxes with a single-writer UI coordinator actor, typed actor command sinks (`bind_action_actor_sink`), and declarative one-shot side effects (`UI_Effect`).
- **Zero-Copy Persistent State & Workspace Persistence (`xitdb_bridge.odin`, `workspace_persistence.odin`):** Worker actors commit transactions to `xitdb` and send lightweight $O(1)$ moment indices (`i64`) to the UI actor, which slices virtualized viewports (`Linked_Array_List`, `Sorted_Map`, `Array_List`) directly on `context.temp_allocator` and persists workspace layout, split ratios, focus history, and user keymap overrides (`save_workspace_state` / `load_workspace_state`).
- **Clay-Style Two-Pass Topological Layout (`layout.odin`):** `Fit` (shrink-wrap), `Grow` (weighted flex with `min`/`max` freeze clamping and exact integer remainder distribution), `Fixed`, and out-of-flow `z_layer` overlays in two linear array passes with zero recursion.
- **Notcurses-Inspired Z-Layers & 50% RGB Backdrop Dimming (`renderer.odin`):** Inline `ui_modal` and floating overlays with automatic in-place 50% RGB bit-shift dimming (`Dim_Screen`, `Dim_Rect`) and DEC Mode 2026 synchronized ANSI diff output (`\x1b[?2026h ... \x1b[?2026l`).
- **Hierarchical Focus Scope Tree & 2D Spatial Navigation (`focus_scope.odin`, `spatial_nav.odin`, `input.odin`):**
  - Reverse `z_order` mouse hit-testing, modal input capture, Harel statechart shallow/deep focus history (`H` / `H*`), and two-stage `.Navigation` vs. `.Editing` sub-modes (`Enter`/`i` to edit, `Esc` to exit to scope navigation).
  - 2D directional navigation (`Left`/`Right`/`Up`/`Down`) using orthogonal projection-overlap cone scoring, bottom-up scope boundary bubbling, and explicit `nav_overrides` (`Node_Nav_Override`) for irregular HUDs.
- **Declarative Key-Chord Engine, Multi-Style Modal Editing & AST Codegen (`keymap.odin`, `status_bars.odin`, `bifrost/codegen`):**
  - 1- and 2-step key chords (`g g`, `C-x C-f`, `<leader> f`), transient sub-modes (`.Resize`), compile-time + runtime chord conflict detection, and zero-overhead FNV-1a dispatch tables generated via struct tags (`tools/bifrost_gen`).
  - Live runtime switching (`set_keymap_style`, `<F2>` cycle or `<F3>`/`<F4>`/`<F5>`) between **Vim** (`h/j/k/l`, `gg`/`G`, `5j` prefix counts), **Helix** (`h/j/k/l`, `gg`/`ge`, `j5` post-fix repeat counts), and **Emacs** (`C-n`/`C-p`/`C-f`/`C-b`, `M-<`/`M->`, `C-v`/`M-v`, `C-u` universal argument $4^n$ multiplier, and `M-x` command palette).
  - Auto-populating Which-Key floating popup (`ui_which_key_overlay`) on pending chord prefixes, plus contextual focus breadcrumb (`ui_focus_breadcrumb_bar`) and key hint bars (`ui_key_hint_bar`).
- **Virtualized 2D Viewports, UTF-8 Selection, OSC 52 Clipboard & Command Palette (`scroll.odin`, `text_input.odin`, `splitter.odin`, `command_palette.odin`):**
  - Virtualized `ui_virtual_list` and `ui_virtual_table` rendering 100,000+ `xitdb` rows in $O(1)$ layout nodes with vertical (`offset`) and horizontal (`offset_x`) scrolling, mouse click column selection, and z-aware mouse-wheel bubbling.
  - Byte-exact UTF-8 `ui_text_input` with visual selection (`Shift+Left/Right/Home/End`), zero-CGO OSC 52 terminal clipboard copy/cut (`Ctrl+C`/`Ctrl+X`), Telescope-style `linked_list_id` forwarding, and cached `Xitdb_Filter`.
  - Interactive 1-cell `ui_splitter` dividers and a reusable `Ctrl+P` / `M-x` fuzzy `ui_command_palette`.
- **Multi-Line Editor, Collapsible Tree, Focus-Scoped Tabs & Braille/Sparkline Data-Viz (`text_area.odin`, `tree.odin`, `tabs.odin`, `canvas.odin`):**
  - **Multi-Line UTF-8 Editor (`ui_text_area`):** 2D caret navigation with sticky `preferred_col`, optional dynamic line-number gutter, `Shift+Arrow`/`Ctrl+A` multi-line selection, `Ctrl+C`/`Ctrl+X`/`Ctrl+V` + bracketed paste + OSC 52 clipboard (`flush_osc52_clipboard`), and two-stage `.Navigation`/`.Editing` sub-modes.
  - **Virtualized Collapsible Tree (`ui_tree`):** $O(\text{visible\_rows})$ layout node materialization over 10,000+ hierarchical nodes with box-drawing guides (`├─ `, `╰─ `, `│  `, `▾ `, `▸ `), `h`/`l` expand/collapse and parent-node jump, and `id_hash`-persistent branch state.
  - **Focus-Scope-Integrated Tab Bar (`ui_tabs` / `ui_tab_bar`):** Per-tab `Focus_Scope` isolation (`<id>_body_<i>`) with automatic Deep History ($H^*$) restoration across `[` / `]`, `Alt+1..9`, header `h`/`l`, and mouse clicks.
  - **Unicode Braille Canvas & Sparklines (`ui_canvas` / `ui_sparkline`):** ISO/TR 11548-1 $2 \times 4$ sub-cell Braille dot-matrix canvas (`U+2800..U+28FF`) with integer Bresenham lines, rects, and auto-scaled time-series polylines, plus 8-level vertical block sparklines (`▁▂▃▄▅▆▇█`).

---

## Running Tests & Codegen

```bash
# Unit & verification suites (layout, renderer, focus scopes, 2D spatial nav, keymaps, widgets, actors)
odin test bifrost -vet -strict-style -vet-packages:bifrost

# AST keymap code generator tests
odin test bifrost/codegen -vet -strict-style

# 4-layer ATDD executable specifications (51 scenario tests + 41 package unit tests)
odin test tests -custom-attribute:scenario -vet -strict-style -vet-packages:bifrost,bifrost_tests

# Standalone AST keymap code generator CLI
odin run tools/bifrost_gen -- <target_dir>
```

---

## Example TUIs (`examples/`)

Each example runs a deterministic, zero-leak headless verification walkthrough by default (printing the rendered Unicode frame buffer) and supports `--live-tty` for interactive raw-terminal execution:

```bash
# 1. Widget & Layout Gallery (Flexbox sizing, splitters, UTF-8 selection + OSC 52, 2D virtual table, Which-Key, Vim/Helix/Emacs styles)
odin run examples/widget_gallery -vet -strict-style -vet-packages:bifrost,main
odin run examples/widget_gallery -- --live-tty

# 2. Kanban & Task Tracker (4-column focus scopes, F6 cycling, word-wrapped cards, xitdb time-travel undo/redo)
odin run examples/kanban_board -vet -strict-style -vet-packages:bifrost,main
odin run examples/kanban_board -- --live-tty

# 3. Actor-Driven Log & Metrics Monitor (Sleipnir producer actors streaming into xitdb, Datalog & moment diffs)
odin run examples/log_monitor -vet -strict-style -vet-packages:bifrost,main
odin run examples/log_monitor -- --live-tty

# 4. Sleipnir + xitdb Inspector (Time-travel database inspector with 1,000-message burst coalescing)
odin run examples/xitdb_inspector -vet -strict-style -vet-packages:bifrost,main
odin run examples/xitdb_inspector -- --live-tty

# 5. Interactive Keymap, Which-Key & Clipboard Workbench (Vim/Helix/Emacs modes, Which-Key popup, N-count prefix/suffix/C-u, 2D table scroll, OSC 52, live rebind + xitdb persistence)
odin run examples/keymap_workbench -vet -strict-style -vet-packages:bifrost,main
odin run examples/keymap_workbench -- --live-tty

# 6. Core Widget Suite Showcase — Tracks 11-14 (Multi-line `ui_text_area`, virtualized `ui_tree`, `H*` focus-scoped `ui_tabs`, and 2x4 Braille `ui_canvas` + 8-level `ui_sparkline`)
odin run examples/widget_showcase -vet -strict-style -vet-packages:bifrost,main
odin run examples/widget_showcase -- --live-tty
```

---

## Conductor Tracks & Documentation

- **Master Track Index:** [`conductor/tracks.md`](conductor/tracks.md)
- **Core Widget Suite Guide (Tracks 11–14: `ui_text_area`, `ui_tree`, `ui_tabs`, `ui_canvas`, `ui_sparkline`):** [`docs/WIDGETS_GUIDE.md`](docs/WIDGETS_GUIDE.md)
- **Navigation, Focus Scopes & Key-Chord DSL Guide:** [`docs/NAVIGATION_AND_DSL_GUIDE.md`](docs/NAVIGATION_AND_DSL_GUIDE.md)
- **Core Actor-Driven TUI Blueprint:** [`conductor/tracks/actor_xitdb_tui_20261103/building_an_actor_driven_odin_tui.md`](conductor/tracks/actor_xitdb_tui_20261103/building_an_actor_driven_odin_tui.md)
