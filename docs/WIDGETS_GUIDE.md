# Bifrost Core Widget Suite Guide (Tracks 11–14)

This guide covers the architecture, configuration, keyboard/mouse routing, and API usage for the four core components added in Tracks 11–14:

1. **Track 11: Multi-Line UTF-8 Text Editor (`ui_text_area`)** — [`bifrost/text_area.odin`](../bifrost/text_area.odin)
2. **Track 12: Virtualized Collapsible Tree (`ui_tree`)** — [`bifrost/tree.odin`](../bifrost/tree.odin)
3. **Track 13: Focus-Scope-Integrated Tab Bar (`ui_tabs` / `ui_tab_bar`)** — [`bifrost/tabs.odin`](../bifrost/tabs.odin)
4. **Track 14: Unicode Braille Sub-Cell Canvas (`ui_canvas`) & Sparkline (`ui_sparkline`)** — [`bifrost/canvas.odin`](../bifrost/canvas.odin)

For an interactive walkthrough combining all four widgets inside a split-pane IDE workspace, see [`examples/widget_showcase/main.odin`](../examples/widget_showcase/main.odin).

---

## 1. Multi-Line UTF-8 Text Editor (`ui_text_area`)

[`ui_text_area`](../bifrost/text_area.odin) is a multi-line, grapheme- and East Asian display-width-aware text editor integrated with Bifrost's two-stage `.Navigation` vs. `.Editing` focus statechart, zero-CGO OSC 52 clipboard (`\x1b]52;c;<base64>\x07`), and proportional vertical scrollbar rendering.

### Key Architectural Invariants
- **Zero-Allocation Slot Pool vs. Optional Heap State:**
  - By default, `Input_State` manages up to `MAX_TEXT_AREA_SLOTS` (`8`) active editors using fixed `[MAX_TEXT_AREA_BYTES]u8` (`4096` B) and `[MAX_TEXT_AREA_LINES]int` (`256` lines) buffers with **zero heap allocations** and automatic `last_layout_gen` LRU eviction.
  - When larger or caller-owned buffers are needed, initialize a `Text_Area_State` via `text_area_init(&my_state, allocator, initial_text)` (`defer text_area_destroy(&my_state)`) and pass `state = &my_state` in `Text_Area_Config`. `ui_text_area` adopts `my_state.dyn_buf` in-place and synchronizes logical cursor/scroll/line metadata back to `my_state` every frame without clobbering or leaking `dyn_buf`.
  - `Screen.text_areas` stores `map[u64]^Text_Area_State` pointers into `Input_State.text_area_slots`, avoiding per-frame struct copies during layout and rendering.
- **Sticky `preferred_col` Across Vertical Motion:**
  - Moving `Up`, `Down`, `Page_Up`, or `Page_Down` preserves `slot.preferred_col` across shorter or empty intermediate lines (including 2-column CJK/emoji codepoints) and only updates `preferred_col` on horizontal cursor movement, text insertion/deletion, or mouse click.
- **Two-Stage Modal Editing (`two_stage = true`):**
  - When `two_stage = true`, focusing the editor leaves `inp.editing_id == 0` (`.Navigation` mode) so `h`/`j`/`k`/`l` and single-key global shortcuts navigate between panes. Pressing `Enter` or `i` (or left-clicking inside the editor) enters `.Editing` mode (`inp.editing_id == node.id_hash`), suppressing non-`allow_in_edit` single-key bindings (`q`, `[`/`]`, `j`/`k`) while keeping `<F2>`..`<F6>` and `<C-p>` active. Pressing `Escape` clears `has_selection` and returns to `.Navigation` mode while keeping `inp.focused_id` on the editor.
- **$O(N + M)$ Single-Pass Bulk Paste:**
  - `text_area_insert_string` (invoked by bracketed `Paste_Event` and `Ctrl+V`) normalizes `\r\n` $\rightarrow$ `\n`, `\r` $\rightarrow$ `\n`, and `\t` $\rightarrow$ `tab_width` spaces, halts cleanly at `MAX_TEXT_AREA_LINES`, shifts the buffer tail once, and rebuilds line starts in a single pass.
- **Built-In Odin, CUE & Custom Per-Line Syntax Highlighting:**
  - Setting `syntax_mode = .Odin` or `syntax_mode = .Cue` in `Text_Area_Config` activates the zero-heap-allocation lexical highlighters (`highlight_odin_line` / `highlight_cue_line`), coloring keywords, built-in types/constraints, `::` / `:=` declarations, CUE `#Schema` / `_#Hidden` definitions, field keys (`field?:` / `field!:`), strings/runes, numbers, `@(...)` attributes, `#...` directives, and `//` comments while preserving horizontal scrolling, cursor rendering, and selection range inversion.
  - Custom languages can supply `highlighter: Text_Area_Highlighter_Proc` (`proc(line: string, line_idx: i32, out_spans: ^[dynamic]Styled_Span, default_fg: Color, default_bg: Color, userdata: rawptr)`) along with `highlighter_userdata`.
- **Clean Hover Chrome (Title & Border Only):**
  - Hovering the mouse over `ui_text_area` (or any `fill_bg` container scope) underlines the border title and tints the border rather than applying `.Underline` to interior text or empty background cells.

### Keyboard & Mouse Bindings (`.Editing` Mode)

| Key / Event | Action |
| --- | --- |
| `Left` / `Right` | Step cursor by 1 UTF-8 grapheme cluster (collapses active selection if unshifted) |
| `Ctrl+Left` / `Ctrl+Right`, `Alt+B` / `Alt+F` | Jump to previous / next word boundary |
| `Up` / `Down` | Move cursor 1 line vertically, preserving sticky `preferred_col` |
| `Page_Up` / `Page_Down` | Move cursor `max(1, viewport_h - 1)` lines vertically |
| `Home` / `End`, `Ctrl+A` (non-select) / `Ctrl+E` | Jump to start / end of current line |
| `Ctrl+Home` / `Ctrl+End` | Jump to start (`0`) / end (`slot.len`) of document |
| `Shift + <Motion>` | Extend or shrink contiguous byte selection (`sel_anchor_byte .. cursor_byte`) |
| `Ctrl+A` | Select entire document (`0 .. slot.len`) |
| `Enter` | Delete selection (if any) and insert `\n` |
| `Tab` | Insert `tab_width` spaces (`1..8`, default `4`) |
| `Backspace` / `Delete` | Delete active selection or adjacent UTF-8 grapheme cluster (joins lines across `\n`) |
| `Ctrl+W` / `Ctrl+Backspace` | Delete previous word on current line (or join with previous line) |
| `Ctrl+U` / `Ctrl+K` | Kill to start / end of current line and copy killed text to clipboard (`osc52_pending = true`) |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / Cut active selection to internal + OSC 52 clipboard / Paste from clipboard |
| `Paste_Event` | Bulk-insert bracketed paste payload with `\r\n` normalization |
| `Mouse Left Click` | Focus editor, enter `.Editing` mode, and place caret at clicked `(row, display_col)` |
| `Mouse Wheel Up / Down` | Scroll viewport vertically (`scroll_row`) |
| `Escape` | Clear selection and exit `.Editing` mode back to `.Navigation` mode |

### Usage Example

```odin
package demo

import "../../bifrost"

render_notes_editor :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	bifrost.ui_text_area(ctx, scr, inp, "notes_editor", {
		title             = "Release Notes (Enter to edit, Esc to nav)",
		initial_text      = "# Bifrost v0.3.0\n- Track 11: Multi-line UTF-8 editor\n- Track 12: Virtualized tree",
		placeholder       = "Write markdown notes...",
		width             = bifrost.grow(1),
		height            = bifrost.grow(1),
		border            = .Rounded,
		two_stage         = true,
		show_line_numbers = true,
		tab_width         = 4,
		focus_flags       = {.Focusable, .Default_Focus},
	})

	if bifrost.was_text_changed(inp, "notes_editor") {
		current_text := bifrost.get_text_area(inp, "notes_editor")
		row, col, _  := bifrost.get_text_area_cursor(inp, "notes_editor")
		_ = current_text
		_ = row
		_ = col
	}
}
```

### Public API Summary (`bifrost/text_area.odin`)
- **Widget Constructor:** `ui_text_area(ctx, scr, inp, id, cfg) -> i32`
- **Optional Heap Lifecycle:** `text_area_init(state, allocator, initial_text) -> mem.Allocator_Error`, `text_area_destroy(state)`
- **State Queries & Mutators:**
  - `get_text_area(inp, id) -> string`, `set_text_area(inp, id, value)`
  - `get_text_area_cursor(inp, id) -> (row, col: i32, byte_offset: int)`
  - `get_text_area_scroll(inp, id) -> (scroll_row, scroll_col: i32)`
  - `get_text_area_selected_text(inp, id) -> string`
  - `get_text_area_line_count(inp, id) -> int`
  - `flush_osc52_clipboard(inp, escape_out) -> bool` (in [`bifrost/ui_actions_effects.odin`](../bifrost/ui_actions_effects.odin))

---

## 2. Virtualized Collapsible Tree (`ui_tree`)

[`ui_tree`](../bifrost/tree.odin) renders hierarchical data structures (file explorers, AST inspectors, module outlines) with automatic box-drawing indentation guides (`│  `, `   `, `├─ `, `╰─ `, `▾ `, `▸ `), keyboard/mouse expand/collapse, parent-node jump navigation, and **$O(\text{visible\_rows})$ layout node materialization** over 10,000+ node trees.

### Key Architectural Invariants
- **Single-Pass $O(N)$ Hierarchy Resolution + $O(\text{visible\_rows})$ Layout Budget:**
  - Callers pass a flat pre-order `[]Tree_Node` slice specifying either `depth` (`0, 1, 2, ...`) or `parent_idx`.
  - `ui_tree` resolves `parent_idx`, `first_child`, `next_sibling`, and `has_children` in a single linear pass (clamping skipped depths to `prev_depth + 1`), builds `vis_to_node` skipping descendants of collapsed branches, and only pushes `Layout_Node`s for rows inside `[start_row ..< end_row]`. A 10,000-node tree in a 12-row viewport materializes only **14 `Layout_Node`s** total.
- **`id_hash`-Keyed Expand/Collapse & Selection Persistence:**
  - `Tree_Slot` tracks branch expand/collapse overrides in an inline open-addressed hash table (`hash_keys: [512]u64`, `hash_expanded: [8]u64`) alongside a 16,384-node bitset (`expanded_bits: [256]u64`), and tracks `selected_node_hash`. Dynamically inserting or filtering nodes above an expanded/collapsed branch preserves both its expand/collapse state and the selected node across frames.
- **Collapse-Safe Ancestor Reconciliation:**
  - If an ancestor branch is collapsed while one of its descendants is selected, `rebuild_tree_visible_rows` walks up `parent_idx` to snap selection to the nearest visible ancestor.

### Keyboard & Mouse Bindings

| Key / Event | Action |
| --- | --- |
| `j` / `Down`, `k` / `Up`, `Ctrl+N` / `Ctrl+P` | Move selection through visible rows (respects Vim/Helix/Emacs repeat counts) |
| `Page_Up` / `Page_Down`, `Home` / `End` | Page or jump to first / last visible row |
| `l` / `Right` | On collapsed branch: expand in-place (`▸` $\rightarrow$ `▾`). On expanded branch: step into `first_child` |
| `h` / `Left` | On expanded branch: collapse in-place (`▾` $\rightarrow$ `▸`). On collapsed branch or leaf: **jump directly to `parent_idx`** and auto-scroll viewport |
| `Space` | Toggle expand/collapse on a branch node |
| `Enter` | Toggle expand/collapse on a branch node, or fire `activated_node_idx` (`was_activated`) on a leaf node |
| `Mouse Left Click` | Focus tree, select clicked visible row, and toggle branch or activate leaf (clicks in empty space below short trees only focus without toggling) |
| `Mouse Wheel Up / Down` | Scroll visible tree rows |

### Usage Example

```odin
package demo

import "../../bifrost"

render_file_tree :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	nodes := [?]bifrost.Tree_Node{
		{id = "root",   label = "bifrost/",       depth = 0, expanded = true, has_children = true},
		{id = "core",   label = "core/",          depth = 1, expanded = true, has_children = true},
		{id = "layout", label = "layout.odin",    depth = 2},
		{id = "render", label = "renderer.odin",  depth = 2},
		{id = "tree",   label = "tree.odin",      depth = 1},
	}

	tree_slice: bifrost.Tree_Slice
	bifrost.ui_tree(ctx, scr, inp, "project_tree", nodes[:], {
		title         = "Explorer",
		width         = bifrost.fixed(28),
		height        = bifrost.grow(1),
		border        = .Rounded,
		fallback_rows = 16,
		focus_flags   = {.Focusable, .Default_Focus},
	}, &tree_slice)

	if activated_idx := bifrost.get_tree_activated_node(inp, "project_tree"); activated_idx >= 0 {
		selected_file := nodes[activated_idx].label
		_ = selected_file
	}
}
```

### Public API Summary (`bifrost/tree.odin`)
- **Widget Constructor:** `ui_tree(ctx, scr, inp, id, nodes, cfg, out_slice) -> i32`
- **State Queries & Mutators:**
  - `get_tree_selected_node(inp, id) -> i32`
  - `get_tree_selected_vis_row(inp, id) -> i32`
  - `get_tree_activated_node(inp, id) -> i32`
  - `get_tree_visible_row_count(inp, id) -> i32`
  - `is_tree_node_expanded(inp, id, node_idx) -> bool`
  - `set_tree_node_expanded(inp, id, node_idx, expanded)`
  - `format_tree_guide_prefix(meta, node_idx, allocator) -> string`

---

## 3. Focus-Scope-Integrated Tab Bar (`ui_tabs` / `ui_tab_bar`)

[`ui_tabs`](../bifrost/tabs.odin) and [`ui_tab_bar`](../bifrost/tabs.odin) provide a declarative horizontal tab header bar and scoped tab container integrated with Bifrost's Harel statechart Shallow ($H$) and Deep ($H^*$) focus history (`Scope_Memory_Entry`).

### Key Architectural Invariants
- **Per-Tab Focus Scope Isolation & Deep History ($H^*$):**
  - Each tab index $i$ owns a dedicated body scope ID (`<id>_body_<i>`). While the user navigates inside Tab $i$, `set_focused_node` records the focused descendant leaf in `Scope_Memory_Entry` under `<id>_body_<i>`.
  - When switching from Tab $i$ to Tab $j$ (via `[` / `]`, `Alt+1..9`, clicking a tab header pill, or pressing `Down`/`Enter` from the header bar), `select_tab_in_slot` sets `inp.wants_focus_id = body_scope_hash[j]`. On the next layout pass, `reconcile_focus` resolves `<id>_body_<j>` via `resolve_scope_target(..., prefer_history = true)`, restoring the exact leaf widget previously focused in Tab $j$!
  - Furthermore, `begin_ui_tabs_internal` keeps the outer `ui_tabs` scope's Shallow History ($H$) pointed at the active tab's body scope (unless focus is currently directly on the header bar), so `F6` scope cycling or modal dismissal always returns into the active tab's $H^*$ leaf.
- **Scoped `[` / `]` & `Alt+1..9` Bubbling:**
  - `handle_tabs_key` walks `inp.focus_node_path` innermost-first (halting at `.Trap_Focus` modal boundaries) so `[` / `]` and `Alt+1..9` only switch the enclosing `ui_tabs` container and never hijack sibling panes in split layouts.
- **Disabled Tab Skipping & Wrap Navigation:**
  - `Tab_Item_Spec{disabled = true}` dims the tab pill and causes `step_tab_in_slot` (`[` / `]`, header `h` / `l`) to skip over disabled tabs automatically.

### Keyboard & Mouse Bindings

| Context | Key / Event | Action |
| --- | --- | --- |
| Inside `ui_tabs` (when `editing_id == 0`) | `[` / `]` | Step to previous / next enabled tab and restore target tab's $H^*$ body focus |
| Inside `ui_tabs` (when `editing_id == 0`) | `Alt+1` .. `Alt+9` | Jump directly to tab $0..8$ and restore target tab's $H^*$ body focus |
| Focused on `<id>_header` or `<id>_tab_<i>` | `h` / `l`, `Left` / `Right` | Step active tab relative to focused tab item while keeping focus on the header bar |
| Focused on `<id>_header` or `<id>_tab_<i>` | `j` / `Down`, `Enter`, `Space` | Enter active tab body scope and restore its $H^*$ leaf focus |
| Anywhere (unoccluded by modal) | `Mouse Left Click` on `<id>_tab_<i>` | Switch to tab $i$ (if enabled) and restore its $H^*$ body focus |

### Usage Example

```odin
package demo

import "../../bifrost"

render_workspace_tabs :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	tabs := [?]bifrost.Tab_Item_Spec{
		{label = "Editor",    badge = "3",    key_hint = "Alt+1"},
		{label = "Telemetry", badge = "LIVE", key_hint = "Alt+2"},
		{label = "Settings",                  key_hint = "Alt+3"},
		{label = "Locked",                    disabled = true},
	}

	active_tab := 0
	if bifrost.ui_tabs(ctx, scr, inp, "workspace_tabs", tabs[:], {
		body_border = .Rounded,
		body_gap    = 1,
	}, &active_tab) {
		switch active_tab {
		case 0:
			bifrost.ui_button(ctx, scr, "ed_btn_1", {label = "Format", focus_flags = {.Default_Focus}})
			bifrost.ui_button(ctx, scr, "ed_btn_2", {label = "Save"})
		case 1:
			bifrost.ui_button(ctx, scr, "tel_btn_1", {label = "Pause Stream", focus_flags = {.Default_Focus}})
		case 2:
			bifrost.ui_button(ctx, scr, "cfg_btn_1", {label = "Reset Defaults", focus_flags = {.Default_Focus}})
		}
	}
}
```

### Public API Summary (`bifrost/tabs.odin`)
- **Scoped Tab Container (`@(deferred_in)`):** `ui_tabs(ctx, scr, inp, id, labels_or_specs, cfg, out_active) -> bool`
- **Standalone Tab Header Bar:** `ui_tab_bar(ctx, scr, inp, id, labels_or_specs, cfg) -> int`
- **State Queries & Mutators:**
  - `get_active_tab(inp, id) -> int`
  - `set_active_tab(inp, id, tab_idx, restore_body_focus = true)`
  - `was_tab_changed(inp, id) -> bool`
  - `tab_header_id(id, index, alloc) -> string`
  - `tab_body_scope_id(id, index, alloc) -> string`

---

## 4. Unicode Braille Sub-Cell Canvas (`ui_canvas`) & Sparkline (`ui_sparkline`)

[`ui_canvas`](../bifrost/canvas.odin) and [`ui_sparkline`](../bifrost/canvas.odin) provide high-density terminal data visualization:
- **`ui_canvas` (`Braille_Canvas`):** Maps each terminal cell `(cx, cy)` to a **$2 \times 4$ sub-cell pixel grid** using ISO/TR 11548-1 Unicode Braille patterns (`U+2800..U+28FF`), yielding $(2 \cdot W) \times (4 \cdot H)$ virtual pixel resolution with per-cell RGB foreground tinting.
- **`ui_sparkline`:** Quantizes `[]f32` or `[]int` time-series samples into the 8 Unicode vertical block elements (`▁▂▃▄▅▆▇█`, `U+2581..U+2588`) across single-row or multi-row (`8 * inner.h` vertical sub-levels) viewports.

### ISO/TR 11548-1 $2 \times 4$ Sub-Cell Bitmask Layout

| Sub-Row (`sub_y`) | Left Column (`sub_x == 0`) | Right Column (`sub_x == 1`) |
| --- | --- | --- |
| `0` (top) | Dot 1 (`0x01`) | Dot 4 (`0x08`) |
| `1` | Dot 2 (`0x02`) | Dot 5 (`0x10`) |
| `2` | Dot 3 (`0x04`) | Dot 6 (`0x20`) |
| `3` (bottom) | Dot 7 (`0x40`) | Dot 8 (`0x80`) |

### Key Architectural Invariants
- **Solved-Geometry Callback & Retained Canvas Modes:**
  - Pass `draw_fn = proc(c: ^Braille_Canvas, userdata: rawptr)` on `Canvas_Config` to draw dynamically against the layout-solved `inner_rect.w * 2` by `inner_rect.h * 4` pixel grid (allocated on `context.temp_allocator` during `render_layout`), **or** pass a pre-rendered `canvas = &my_canvas` pointer.
- **Non-Finite (`NaN` / `±Inf`) & Overflow Resilience:**
  - `canvas_draw_series_f32`, `canvas_draw_series_f64`, and `render_sparkline_f32` guard against `NaN` and `±Inf` samples/ranges, and `canvas_draw_line` clamps extreme coordinates before computing `abs(dx)` / `abs(dy)` so Bresenham rasterization never overflows `i32` or hangs.
- **Trailing Window Slicing in `ui_sparkline`:**
  - When `len(samples) > inner_rect.w`, `ui_sparkline` automatically displays the latest `inner_rect.w` trailing samples (`samples[len(samples) - int(inner_rect.w):]`).

### Usage Example

```odin
package demo

import "core:math"
import "../../bifrost"

render_telemetry_charts :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	phase: ^f32,
) {
	// 1. 2x4 Sub-Cell Braille Canvas with dynamic `draw_fn`
	bifrost.ui_canvas(ctx, scr, "wave_canvas", {
		title       = "2x4 Sub-Cell Braille Waveform",
		width       = bifrost.grow(1),
		height      = bifrost.fixed(8),
		border      = .Rounded,
		fg          = bifrost.rgb(110, 215, 255),
		focus_flags = {.Focusable},
		userdata    = phase,
		draw_fn     = proc(c: ^bifrost.Braille_Canvas, raw: rawptr) {
			p := (^f32)(raw)^
			bifrost.canvas_draw_rect(c, 0, 0, c.pixel_w, c.pixel_h, bifrost.rgb(65, 85, 115))

			samples := make([]f32, int(max(2, c.pixel_w)), context.temp_allocator)
			for i in 0 ..< len(samples) {
				t := f32(i) / f32(max(1, len(samples) - 1))
				samples[i] = math.sin_f32(t * 6.28318 + p)
			}
			bifrost.canvas_draw_series(c, samples, -1.2, 1.2, bifrost.rgb(120, 240, 175))
		},
	})

	// 2. 8-Level Vertical Block Sparkline (`▁▂▃▄▅▆▇█`)
	latencies := [?]f32{12, 18, 25, 42, 30, 55, 80, 64, 48, 35, 22, 19}
	bifrost.ui_sparkline(ctx, scr, "latency_spark", latencies[:], {
		title   = "Frame Time (us)",
		width   = bifrost.grow(1),
		height  = bifrost.fixed(3), // 1 interior row + 2 border rows (or height=fixed(4) for 2-row tall bars)
		border  = .Rounded,
		min_val = 0,
		max_val = 100,
		fg      = bifrost.rgb(255, 200, 95),
	})
}
```

### Public API Summary (`bifrost/canvas.odin`)
- **Widget Constructors:**
  - `ui_canvas(ctx, scr, id, cfg) -> i32`
  - `ui_sparkline(ctx, scr, id, samples_f32_or_int, cfg) -> i32`
- **Braille Primitives:**
  - `canvas_init(c, cell_w, cell_h, alloc) -> bool`, `canvas_clear(c)`
  - `canvas_set_point(c, px, py, fg)`, `canvas_unset_point(c, px, py)`, `canvas_get_point(c, px, py) -> bool`
  - `canvas_draw_line(c, x0, y0, x1, y1, fg)`
  - `canvas_draw_rect(c, x, y, w, h, fg)`
  - `canvas_draw_series(c, samples_f32_or_f64, min_val, max_val, fg)`
  - `braille_dot_bit(sub_x, sub_y) -> u8`, `braille_rune_from_mask(mask) -> rune`
- **Sparkline Helper:**
  - `sparkline_level_rune(norm: f32) -> rune`
