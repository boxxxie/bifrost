# Bifrost Usage Rules (`package bifrost`)

Operational guide for developers and AI coding agents building Terminal User Interfaces (TUIs) with **Bifrost**, an immediate-mode, actor-driven TUI framework for [Odin](https://odin-lang.org/) (`dev-2026-09`+). Bifrost unifies a 6-pass Clay-style topological Flexbox layout engine, Harel statechart focus scopes (`H` / `H*`), 2D spatial cone navigation, multi-style modal keymaps (**Vim**, **Helix**, **Emacs**), double-buffered DEC Mode 2026 cell rendering, and first-class bridges to [Sleipnir (package actor)](https://www.google.com/search?q=https://github.com/boxxxie/sleipnir), [`xitdb` (`package xitdb`)](https://github.com/boxxxie/odin-xitdb), and [Heimdall (package heimdall)](https://www.google.com/search?q=https://github.com/boxxxie/heimdall).

## 1. Setup, Submodules & Compiler Flags

1. **Initialize Submodules**: Bifrost depends on git submodules under `deps/`. Always clone or initialize recursively (`git submodule update --init --recursive`).
2. **Pass Required `-custom-attribute` Flags**:
   - Compiling `bifrost` requires `-custom-attribute:telemetry_schema` (used by `deps/heimdall/heimdall`).
   - Add `ui_actions,ui_action,ui_scope` when compiling packages annotated for `tools/bifrost_gen` action codegen.
   - Add `scenario` when running `tests/` ATDD specifications, and `no_temp_lint` if suppressing `--lint-temp`.
3. **Standard Check, Test & Codegen Commands**:

```bash
# Check a consumer package or Bifrost itself with strict style & vet gates
odin check bifrost -custom-attribute:telemetry_schema -vet -strict-style -disallow-do -warnings-as-errors

# Run unit tests (Odin's tracking allocator is active automatically)
odin test bifrost -custom-attribute:telemetry_schema -vet -strict-style -vet-packages:bifrost
odin test bifrost/codegen -custom-attribute:ui_actions,ui_action,ui_scope,telemetry_schema,no_temp_lint -vet -strict-style
odin test tests -custom-attribute:scenario,telemetry_schema -vet -strict-style -vet-packages:bifrost,bifrost_tests

# Generate AST keymap dispatchers (`ui_actions_gen.odin`) or ATDD glue (`dsl_atdd_gen.odin`)
odin run tools/bifrost_gen -- <target_pkg_dir>
odin run tools/bifrost_gen -- --atdd tests

# Audit interactive loops & Sleipnir actor callbacks for temp_allocator leaks
odin run tools/bifrost_gen -- --lint-temp <target_pkg_dir>
```

4. **OLS Collections (`ols.json`)**: Map `bifrost` (`./bifrost`), `actor` (`./deps/heimdall/deps/sleipnir/actor`), `xitdb` (`./deps/xitdb/xitdb`), `heimdall` (`./deps/heimdall/heimdall`), and `odinarrow` (`./deps/heimdall/deps/OdinArrow/src`) in [OLS configuration](https://raw.githubusercontent.com/DanielGavin/ols/master/misc/ols.schema.json) so editor diagnostics match CLI builds.

## 2. Execution Modes & Mandatory 6-Step Frame Pipeline

Bifrost supports two execution models: a **synchronous immediate-mode loop** (full manual control or headless tests) and an **actor-driven coordinator** (`UI_Coordinator_State` via `Sleipnir` + `xitdb`). Both execute the exact same 6-step per-frame order.

### Mode A: Synchronous Immediate-Mode Frame Order

Execute these six steps in exact sequence on every frame:

```odin
package app

import "core:os"
import "core:strings"
import "bifrost"

run_frame :: proc(
	scr: ^bifrost.Screen,
	ctx: ^bifrost.Layout_Context,
	inp: ^bifrost.Input_State,
	store: ^bifrost.Widget_State_Store,
	ansi_out: ^strings.Builder,
	events: []bifrost.Input_Event,
) {
	// 0. Reset thread-local scratch memory once per frame tick
	defer free_all(context.temp_allocator)

	// 1. Begin Frame & Layout Pass
	strings.builder_reset(ansi_out)
	bifrost.state_store_begin_frame(store)
	bifrost.begin_frame(scr, bifrost.rgb(22, 26, 34))
	bifrost.begin_layout(ctx, scr.width, scr.height)

	// 2. Build Widget Tree (`@(deferred_in)` closes scopes/containers/tables at `}` automatically)
	if bifrost.ui_scope(ctx, scr, "root", {
		dir     = .Column,
		width   = bifrost.fixed(scr.width),
		height  = bifrost.fixed(scr.height),
		padding = bifrost.pad_all(1),
		gap     = 1,
		border  = .Rounded,
		title   = "Workspace",
	}) {
		bifrost.ui_focus_breadcrumb_bar(ctx, scr, inp, "breadcrumbs")
		bifrost.ui_text_input(ctx, scr, inp, "query", {
			placeholder = "Filter...",
			border      = .Plain,
			two_stage   = true,
			focus_flags = {.Default_Focus},
		})
		bifrost.ui_button(ctx, scr, "apply_btn", {label = "Apply"})
		bifrost.ui_key_hint_bar(ctx, scr, inp, "hints")
	}
	bifrost.ui_which_key_overlay(ctx, scr, inp)

	// 3. Solve 6-Pass Topological Layout & Z-Order
	bifrost.end_layout(ctx)

	// 4. Resolve Input, Focus History (H/H*), 2D Spatial Nav & Mouse Hit-Testing
	bifrost.resolve_input(inp, ctx, ..events)

	// 5. Sync Persistent Widget Store, Highlights & Zero-Lag Dynamic Status Bars
	bifrost.state_store_sync_from_layout(store, ctx, inp)
	bifrost.apply_input_highlights(scr, ctx, inp)

	// 6. Rasterize Back-to-Front & Emit Synchronized ANSI Diff + OSC 52 Clipboard
	bifrost.render_layout(scr, ctx)
	_ = bifrost.screen_diff_ansi(scr, ansi_out)
	_ = bifrost.flush_osc52_clipboard(inp, ansi_out)
	_, _ = os.write_string(os.stdout, strings.to_string(ansi_out^))
}
```

### Mode B: Actor-Driven Coordinator (`UI_Coordinator_State`)

When streaming background updates, database commits, or telemetry at high throughput:

- Spawn or initialize `UI_Coordinator_State` (`spawn_ui_coordinator` / `ui_coordinator_init`) with a `UI_Render_Pass_Fn` callback and optional `^Xitdb_Shared_Handle`.
- Keep all terminal state inside the single-writer UI coordinator actor; background `Xitdb_Worker_State` or producer actors commit to `xitdb` and send lightweight `UI_Msg_Commit_Notification{moment_idx = ...}` messages. The coordinator coalesces up to `DEFAULT_MAX_COALESCE_BATCH` (`2048`) messages per render pass and automatically calls `free_all(context.temp_allocator)` inside `ui_coordinator_flush_frame`.
- Wire declarative commands with `bind_actor_action` (static message, dynamic closure, or batch slice), `bind_button_action`, and `on_ui_action`.
- Issue terminal side-effects purely via `ui_cmd_copy_osc52`, `ui_cmd_set_title`, `ui_cmd_set_cursor_shape`, `ui_cmd_request_focus`, `ui_cmd_request_quit`, and `ui_set_quit_filter`.
- Persist and restore splitter ratios, `H`/`H*` focus memory, active keymap style, and custom chord overrides with `save_ui_workspace_to_xitdb` / `load_ui_workspace_from_xitdb`.

## 3. Component & Subsystem Inventory ("What Bifrost Contains")

Every widget is zero-allocation in steady state, storing state in fixed-capacity LRU slots on `Input_State` / `Widget_State_Store` and per-frame nodes on `context.temp_allocator`.

### Core Engine, Bridges & Metaprogramming

| Subsystem | Source Files | Key Public Types & Procedures | Extended Documentation |
| :--- | :--- | :--- | :--- |
| **Layout Engine** | `bifrost/layout.odin` | `Layout_Context`, `Box_Config`, `begin_layout`, `end_layout`, `container`, `leaf`, `fit`, `grow`, `fixed`, `percent`, `pad_all`, `pad_xy`, `get_rect`, `get_inner_rect`, `nav_target`, `hash_id`, `hash_local_id`, `hash_local_idi`, `current_scope_hash` | `docs/widget/primitives_and_scopes.md`, `conductor/tracks/layout_and_renderer_20261103/spec.md` |
| **Cell Renderer & Links** | `bifrost/renderer.odin` | `Screen`, `Paint_Spec`, `Styled_Span`, `screen_init`, `screen_destroy`, `screen_resize`, `begin_frame`, `render_layout`, `screen_diff_ansi`, `screen_export_html`, `rgb`, `ansi256`, `ansi16`, `ui_label`, `ui_link` (OSC 8), `ui_modal`, `surface_merge_box_cell` | `docs/widget/primitives_and_scopes.md`, `conductor/tracks/log_stream_and_table_controls_20261108/spec.md` |
| **Focus Scopes & 2D Spatial Nav** | `bifrost/focus_scope.odin`, `bifrost/spatial_nav.odin`, `bifrost/input.odin` | `Input_State`, `Widget_State_Store`, `Focus_Flags`, `ui_scope`, `resolve_input`, `apply_input_highlights`, `is_focused`, `is_editing`, `is_scope_selected`, `is_hovered`, `was_activated`, `was_clicked`, `request_focus` | `docs/NAVIGATION_AND_DSL_GUIDE.md` |
| **Keymap & Chord Engine** | `bifrost/keymap.odin` | `Keymap_Style` (`.Vim`, `.Helix`, `.Emacs`), `Action_Spec`, `Keymap_Table`, `set_keymap_style`, `cycle_keymap_style`, `register_actions_struct`, `register_action_spec`, `bind_chord`, `set_action_guard`, `rebind_action_chord`, `was_action_triggered`, `triggered_action` | `docs/NAVIGATION_AND_DSL_GUIDE.md`, `examples/keymap_workbench/main.odin` |
| **AST Codegen & Linter CLI** | `bifrost/codegen/codegen.odin`, `bifrost/codegen/atdd_codegen.odin`, `tools/bifrost_gen/main.odin` | `@(ui_actions)`, `@(ui_action="...")`, `@(ui_scope="...")`, `@(scenario)`, `@(no_temp_lint)`, `generate_directory`, `generate_atdd_directory`, `check_temp_allocator_hygiene_directory` | `docs/NAVIGATION_AND_DSL_GUIDE.md`, `conductor/tracks/keymap_chord_dsl_and_ast_gen_20261104/spec.md` |
| **Terminal & ANSI/Kitty Parser** | `bifrost/terminal.odin`, `bifrost/terminal_posix.odin`, `bifrost/terminal_windows.odin`, `bifrost/ansi_parser.odin` | `Terminal`, `Terminal_Options`, `Input_Stream_Reader`, `terminal_init`, `terminal_deinit`, `terminal_poll_event`, `terminal_winsize`, `parse_ansi_input`, `mouse_event_from_sgr_pixels` | `conductor/tracks/terminal_and_input_parser_20261103/spec.md`, `conductor/tracks/windows_terminal_and_github_actions_ci_20261106/spec.md` |
| **Sleipnir Coordinator & Effects** | `bifrost/ui_coordinator.odin`, `bifrost/ui_actions_effects.odin` | `UI_Coordinator_State`, `UI_Msg`, `UI_Side_Effect`, `spawn_ui_coordinator`, `ui_coordinator_init`, `ui_coordinator_flush_frame`, `bind_actor_action`, `on_ui_action`, `bind_button_action`, `ui_cmd_*`, `flush_osc52_clipboard` | `docs/NAVIGATION_AND_DSL_GUIDE.md`, `conductor/tracks/actor_xitdb_tui_20261103/building_an_actor_driven_odin_tui.md` |
| **`xitdb` Bridge & Persistence** | `bifrost/xitdb_bridge.odin`, `bifrost/workspace_persistence.odin` | `Xitdb_Shared_Handle`, `Xitdb_Worker_State`, `Xitdb_Worker_Msg`, `xitdb_slice_viewport`, `save_ui_workspace_to_xitdb`, `load_ui_workspace_from_xitdb` | `conductor/tracks/sleipnir_actor_action_routing_20261104/spec.md`, `examples/xitdb_explorer/main.odin` |
| **Heimdall Arrow Telemetry** | `bifrost/heimdall_bridge.odin` | `Heimdall_Segment_Store`, `Heimdall_Runtime_Metrics`, `ui_coordinator_set_recorder`, `set_thread_default_recorder`, `heimdall_store_init`, `heimdall_store_load_prefix_incremental`, `heimdall_sample_runtime_metrics` | `examples/heimdall_inspector/main.odin`, `tests/spec_heimdall_integration.odin` |

### Widget Suite Catalog

| Widget Family | Source Files | Entrypoint Procedures | Extended Documentation |
| :--- | :--- | :--- | :--- |
| **Primitives, Buttons & Modals** | `bifrost/layout.odin`, `bifrost/renderer.odin`, `bifrost/input.odin` | `container`, `leaf`, `ui_scope`, `ui_label`, `ui_link`, `ui_button`, `ui_modal` | `docs/widget/primitives_and_scopes.md` |
| **Single-Line Text Input & Filter** | `bifrost/text_input.odin` | `ui_text_input`, `get_text`, `set_text`, `was_text_changed`, `xitdb_filter_init`, `xitdb_filter_update`, `xitdb_filter_map_row` | `docs/widget/text_input.md` |
| **Multi-Line Syntax Text Editor** | `bifrost/text_area.odin` | `ui_text_area` (`.None`, `.Odin`, `.Cue`, `.Custom`), `text_area_init`, `text_area_destroy`, `get_text_area`, `set_text_area`, `get_text_area_cursor` | `docs/widget/text_area.md`, `docs/WIDGETS_GUIDE.md` |
| **2D Tables, Virtual Lists & SIMD CSV** | `bifrost/table.odin`, `bifrost/scroll.odin`, `bifrost/csv_grid.odin` | `ui_table` (`ui_virtual_table`), `ui_table_row`, `ui_table_is_col_visible`, `ui_virtual_list`, `resolve_table_columns`, `csv_grid_load_file`, `csv_grid_set_filter`, `csv_grid_set_sort`, `table_selection_init` | `docs/widget/virtual_list_and_table.md`, `conductor/tracks/table_ui_enhancements_20261109/spec.md` |
| **Virtualized Collapsible Tree** | `bifrost/tree.odin` | `ui_tree`, `get_tree_selected_node`, `get_tree_activated_node`, `is_tree_node_expanded`, `set_tree_node_expanded` | `docs/widget/tree.md`, `docs/WIDGETS_GUIDE.md` |
| **Focus-Scoped Tabs** | `bifrost/tabs.odin` | `ui_tabs`, `ui_tab_bar`, `get_active_tab`, `set_active_tab`, `was_tab_changed` | `docs/widget/tabs.md`, `docs/WIDGETS_GUIDE.md` |
| **Interactive Pane Splitters** | `bifrost/splitter.odin` | `ui_splitter`, `get_split_size`, `nudge_splitter`, `bind_splitter_key` | `docs/widget/splitter.md` |
| **Fuzzy Command Palette** | `bifrost/command_palette.odin` | `command_palette_init`, `register_command`, `ui_command_palette`, `update_command_palette` | `docs/widget/command_palette.md` |
| **Breadcrumbs, Hints & Which-Key** | `bifrost/status_bars.odin` | `ui_focus_breadcrumb_bar`, `ui_key_hint_bar`, `ui_which_key_overlay` | `docs/widget/status_bars_and_which_key.md` |
| **Braille Canvas & Sparklines** | `bifrost/canvas.odin` | `ui_canvas`, `canvas_init`, `canvas_draw_line`, `canvas_draw_rect`, `canvas_draw_series`, `ui_sparkline` | `docs/widget/canvas_and_sparkline.md`, `docs/WIDGETS_GUIDE.md` |
| **Cartesian & Categorical Charts** | `bifrost/chart.odin` | `ui_chart` (`.Braille_Line`, `.Braille_Dots`, `.Braille_Step`, `.Braille_Area`), `ui_bar_chart` (`.Vertical`, `.Horizontal`) | `conductor/tracks/charts_and_plots_20261108/spec.md`, `tests/spec_chart.odin` |
| **Form Controls** | `bifrost/form_controls.odin` | `ui_checkbox`, `ui_switch`, `ui_radio_group`, `ui_slider`, `ui_dropdown` | `conductor/tracks/form_controls_20261108/spec.md`, `tests/spec_form_controls.odin` |
| **Progress, Gauges & Spinners** | `bifrost/progress.odin` | `ui_progress_bar` (1/8th sub-cell blocks), `ui_gauge` (threshold colors), `ui_spinner` (`SPINNER_DOTS`, `SPINNER_LINE`, `SPINNER_PULSE`, `SPINNER_MOON`) | `conductor/tracks/progress_and_spinners_20261108/spec.md`, `tests/spec_progress.odin` |
| **Rich Paragraphs & Markdown** | `bifrost/paragraph.odin` | `ui_paragraph` (`[]Styled_Span` word wrapping), `ui_markdown` (headings, lists, quotes, code spans/fences, rules) | `conductor/tracks/rich_text_and_markdown_20261108/spec.md`, `tests/spec_paragraph.odin` |
| **Dialogs, Toasts & Tooltips** | `bifrost/dialogs.odin` | `ui_confirm_dialog`, `ui_alert`, `ui_prompt`, `toast_push`, `toast_update`, `toast_dismiss`, `ui_toast_stack`, `ui_tooltip` | `conductor/tracks/dialogs_toasts_tooltips_20261108/spec.md`, `tests/spec_dialogs.odin` |
| **Auto-Scrolling Log Stream** | `bifrost/log_stream.odin` | `ui_log_viewer` (`tail -f` auto-follow, unread badge, `Log_Level` filtering), `log_level_colors` | `conductor/tracks/log_stream_and_table_controls_20261108/spec.md`, `tests/spec_log_stream.odin` |

## 4. Critical Architectural Rules (`DO` & `DON'T`)

### Frame Lifecycle & `@(deferred_in)` Block Scoping

- **DO** wrap `container`, `ui_scope`, `ui_modal`, `ui_virtual_list`, `ui_table`, and `ui_tabs` inside `if ... { ... }` blocks. Each of those procedures carries `@(deferred_in = defer_end_*)`, which automatically closes the container when exiting the `if` scope.
- **DON'T** call `exit_container_node` or `defer_end_*` manually after an `if container(...)` / `if ui_scope(...)` block—doing so pops the parent stack twice and corrupts layout hierarchy.
- **DO** call `end_layout(&ctx)` *before* querying `get_rect` / `get_inner_rect` or calling `resolve_input(&inp, &ctx, ..events)`, and call `apply_input_highlights(&scr, &ctx, &inp)` *before* `render_layout(&scr, &ctx)` so focus borders and dynamic breadcrumb/hint bars render with zero frame lag.

```odin
// DO: Let @(deferred_in) close ui_scope automatically and query rects after end_layout
if bifrost.ui_scope(&ctx, &scr, "main_pane", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
	bifrost.ui_label(&ctx, &scr, "hdr", "Records")
}
bifrost.end_layout(&ctx)
rect, ok := bifrost.get_inner_rect(&ctx, "main_pane")

// DON'T: Call exit_container_node manually or read get_rect before end_layout(&ctx)
```

### Zero-Allocation Dynamic IDs & Memory Lifetimes

- **DO** generate dynamic item IDs in loops and virtualized lists with `hash_local_idi(current_scope_hash(&ctx), "row", i)` (or `hash_local_id`) passed via `id = ""` and `Box_Config{id_hash = ...}`—zero heap or temp string allocations.
- **DON'T** allocate heap strings (`fmt.aprintf`) per frame or run `fmt.tprintf` / `begin_layout` inside custom loops or Sleipnir `receive` callbacks without calling `free_all(context.temp_allocator)` once per iteration/turn.
- **DO** pair every heap-owning initializer with its destructor (`screen_init`/`screen_destroy`, `state_store_init`/`state_store_destroy`, `layout_destroy` if `layout_enable_arena` was enabled, `text_area_init`/`text_area_destroy`, `csv_grid_load_file`/`csv_grid_destroy`, `table_selection_init`/`table_selection_destroy`, `xitdb_filter_init`/`xitdb_filter_destroy`, `heimdall_store_init`/`heimdall_store_destroy`, and `ui_coordinator_init`/`ui_coordinator_destroy`).

### Focus Scopes (`H` / `H*`), Two-Stage Editing & `.Scope_Text_Sink`

- **DO** add `.Focusable` to a `ui_scope`'s `focus_flags` (e.g., `focus_flags = {.Focusable, .Loop_Spatial}`) when an empty column/pane should still be reachable by spatial navigation or `Esc` drill-up.
- **DO** distinguish `is_focused(&inp, id)` (the single active global leaf tip) from `is_scope_selected(&inp, id)` (the remembered `H*` selection inside an inactive pane or column).
- **DO** set `two_stage = true` on `Text_Input_Config` inside multi-field forms so `h/j/k/l` navigates between fields until `Enter` or mouse click enters `.Editing` mode (`Esc` exits editing before closing an enclosing modal).
- **DO** configure live filter / fuzzy-picker search boxes with `focus_flags = {.Captures_Text, .Auto_Edit, .Scope_Text_Sink}` (omitting `.Focusable`) inside the modal/scope so printable runes edit the query while `Up`/`Down`/`Enter` stay focused on the results list.

### Declarative Keymaps (`Vim` / `Helix` / `Emacs`) & Virtualized Tables

- **DO** declare keybindings via `` `bifrost:"..."` `` struct tags (`register_actions_struct`) or `@(ui_action="...")` + `tools/bifrost_gen` instead of ad-hoc `Key_Event` `switch` blocks. Wrap `desc` strings containing commas in single quotes (`desc='Save, close & exit'`).
- **DO** virtualize large tables and trees with `ui_table` (up to `MAX_TABLE_COLS :: 256`, frozen `pinned_cols`, `sortable`, `resizable`, `Table_Selection_Set`), `ui_virtual_list`, `CSV_Grid_Table`, or `ui_tree`. Emit rows strictly for `vslice.start_row ..< vslice.end_row` (and check `ui_table_is_col_visible(vslice, col_idx)` on wide tables) rather than pushing all `N` rows into `Layout_Context`.

```odin
// DO: Virtualize both rows and wide columns with ui_table
vslice: bifrost.Virtual_Slice
if bifrost.ui_table(&ctx, &scr, &inp, "grid", col_specs[:], total_rows, {
	width       = bifrost.grow(1),
	height      = bifrost.grow(1),
	border      = .Rounded,
	pinned_cols = 1,
	sortable    = true,
	resizable   = true,
	focus_flags = {.Focusable, .Default_Focus},
}, &vslice) {
	for r := vslice.start_row; r < vslice.end_row; r += 1 {
		bifrost.ui_table_row(&ctx, &scr, r, row_cells_for(r, vslice))
	}
}
```

## 5. How to Get Extended Documentation

When working on a specific widget, bridge, or subsystem, look up detailed APIs and runnable patterns in this order instead of reading the entire `bifrost/` source tree:

### Step 1: Query Exact Odin Signatures via CLI

```bash
# Inspect exported types, struct fields, and procedure signatures in package bifrost
odin doc ./bifrost -custom-attribute:telemetry_schema

# Inspect AST keymap & ATDD codegen APIs
odin doc ./bifrost/codegen -custom-attribute:ui_actions,ui_action,ui_scope,scenario,no_temp_lint
```

### Step 2: Read Curated Architectural & Per-Widget Guides (`docs/`)

- **Documentation Hub & Frame Pipeline Overview**: `docs/INDEX.md`
- **Focus Statecharts (`H`/`H*`), 2D Spatial Cone Scoring, `.Scope_Text_Sink`, Key-Chord DSL, `bifrost_gen` & Actor Sinks**: `docs/NAVIGATION_AND_DSL_GUIDE.md`
- **Track 11–14 Widget Integration Overview**: `docs/WIDGETS_GUIDE.md`
- **Dedicated Per-Widget API & Keybinding Reference (`docs/widget/`)**:
  - Layout containers, `ui_scope`, buttons, modals & backdrops: `docs/widget/primitives_and_scopes.md`
  - Single-line UTF-8 input & `Xitdb_Filter`: `docs/widget/text_input.md`
  - Multi-line UTF-8 editor & Odin/CUE highlighting: `docs/widget/text_area.md`
  - Virtualized lists, 2D table column solver & `xitdb_slice_viewport`: `docs/widget/virtual_list_and_table.md`
  - Virtualized collapsible tree: `docs/widget/tree.md`
  - Focus-scoped tabs (`H*` per-tab memory): `docs/widget/tabs.md`
  - Interactive pane splitter & `[RESIZE]` sub-mode: `docs/widget/splitter.md`
  - Fuzzy command palette: `docs/widget/command_palette.md`
  - Breadcrumb bar, contextual key-hint bar & Which-Key overlay: `docs/widget/status_bars_and_which_key.md`
  - 2×4 Unicode Braille canvas & 8-level sparklines: `docs/widget/canvas_and_sparkline.md`

### Step 3: Consult Subsystem Blueprints & Track Specs (`conductor/`)

For subsystems and newer Track 15–21 widgets that do not yet have a standalone file under `docs/widget/`, read their formal `spec.md` and `tests/spec_*.odin` files:

| Topic / Component | Specification & Design Doc | Executable Spec (`tests/`) |
| :--- | :--- | :--- |
| **Master Track Registry** | `conductor/tracks.md` | `tests/dsl_bifrost.odin` |
| **Actor-Driven TUI Architecture** | `conductor/tracks/actor_xitdb_tui_20261103/building_an_actor_driven_odin_tui.md` | `tests/spec_actor_tui_integration.odin` |
| **POSIX & Windows ConPTY Terminal + ANSI/Kitty/SGR Parser** | `conductor/tracks/terminal_and_input_parser_20261103/spec.md`, `conductor/tracks/windows_terminal_and_github_actions_ci_20261106/spec.md` | `tests/spec_ansi_parser.odin` |
| **Form Controls (`ui_checkbox`, `ui_switch`, `ui_radio_group`, `ui_slider`, `ui_dropdown`)** | `conductor/tracks/form_controls_20261108/spec.md` | `tests/spec_form_controls.odin` |
| **Progress Bars, Gauges & Spinners (`ui_progress_bar`, `ui_gauge`, `ui_spinner`)** | `conductor/tracks/progress_and_spinners_20261108/spec.md` | `tests/spec_progress.odin` |
| **Cartesian 2D & Categorical Bar Charts (`ui_chart`, `ui_bar_chart`)** | `conductor/tracks/charts_and_plots_20261108/spec.md` | `tests/spec_chart.odin` |
| **Rich Text Paragraphs & Markdown Viewer (`ui_paragraph`, `ui_markdown`)** | `conductor/tracks/rich_text_and_markdown_20261108/spec.md` | `tests/spec_paragraph.odin` |
| **Modal Dialogs, Toasts & Tooltips (`ui_confirm_dialog`, `ui_alert`, `ui_prompt`, `ui_toast_stack`, `ui_tooltip`)** | `conductor/tracks/dialogs_toasts_tooltips_20261108/spec.md` | `tests/spec_dialogs.odin` |
| **Auto-Scrolling Log Stream & OSC 8 Links (`ui_log_viewer`, `ui_link`)** | `conductor/tracks/log_stream_and_table_controls_20261108/spec.md` | `tests/spec_log_stream.odin` |
| **256-Col `ui_table`, Frozen Columns & SIMD `CSV_Grid_Table`** | `conductor/tracks/table_ui_enhancements_20261109/spec.md`, `conductor/tracks/table_ui_enhancements_20261109/ui_tables_code_example.md` | `bifrost/csv_grid_test.odin` |

### Step 4: Study & Run Reference Applications (`examples/`)

Every example runs a deterministic headless verification walkthrough by default (safe for agents and CI) and accepts `--live-tty` for interactive terminal sessions:

- `examples/widget_gallery/main.odin` — Clay flexbox sizing, splitters, virtualized tables, 4-bit box-junction merging, and theme switching.
- `examples/widget_showcase/main.odin` — `ui_text_area` (Odin/CUE syntax), `ui_tree`, `ui_tabs`, `ui_canvas`, and `ui_sparkline`.
- `examples/kanban_board/main.odin` — Drillable 4-column Harel `H`/`H*` focus scopes and `xitdb` time-travel undo/redo.
- `examples/log_monitor/main.odin` — High-throughput `Sleipnir` producer actors streaming into `xitdb` moments with burst coalescing.
- `examples/keymap_workbench/main.odin` — Live `Vim`/`Helix`/`Emacs` switching, 2-step chords, Which-Key popups, OSC 52 clipboard, and rebind persistence.
- `examples/xitdb_explorer/main.odin` & `examples/xitdb_inspector/main.odin` — Recursive `@m` moment `ui_tree`, Datalog/transaction workbench, and `diff_moments` Braille telemetry.
- `examples/heimdall_inspector/main.odin` — Zero-copy `.arrow` IPC `Heimdall_Segment_Store` studio with `@(ui_action)` codegen and live FPS/latency/memory HUD.
- `examples/csv_workbench/main.odin` — 1,000,000-row `#simd[32]u8` RFC 4180 `CSV_Grid_Table` with frozen columns, sorting, resizing, filtering, and interval selection.
