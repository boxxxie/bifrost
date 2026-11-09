# Virtualized Lists & 2D Tables (`ui_table`, `ui_virtual_list`)

**Source Files:** [`bifrost/table.odin`](../../bifrost/table.odin), [`bifrost/scroll.odin`](../../bifrost/scroll.odin), [`bifrost/xitdb_bridge.odin`](../../bifrost/xitdb_bridge.odin)

Bifrost provides both a high-level declarative 2D table widget (`ui_table` / `ui_virtual_table` + `ui_table_row` in [`bifrost/table.odin`](../../bifrost/table.odin)) with pinned sticky headers, separator rules, and automatic column constraint solving, as well as the underlying `ui_virtual_list` + `resolve_table_columns` primitives for custom virtualized viewports. Both materialize only the `O(viewport_rows)` visible `Layout_Node`s each frame even over 100,000+ rows.

---

## 0. Declarative 2D Virtualized Table (`ui_table` & `ui_table_row`)

`ui_table` (aliased as `ui_virtual_table`) wraps `ui_virtual_list`, reserves a pinned 1-row sticky column header and optional 1-row horizontal separator (`─`) above the scrollable body, runs the monotonic `resolve_table_columns` solver across visible cells, registers 2D mouse hit-testing spans, and renders cell/row focus highlights during `end_layout(ctx)`.

```odin
Table_Config :: struct {
	title:            string,
	width:            Axis_Size,   // Defaults to grow(1)
	height:           Axis_Size,   // Defaults to grow(1)
	border:           Border_Kind,
	fg:               Color,
	bg:               Color,
	border_fg:        Color,
	title_fg:         Color,
	header_fg:        Color,
	header_bg:        Color,
	header_style:     Style_Flags, // Defaults to {.Bold}
	row_alt_bg:       Color,       // Optional zebra-stripe background for odd rows
	selected_row_fg:  Color,
	selected_row_bg:  Color,
	selected_cell_fg: Color,
	selected_cell_bg: Color,
	gutter_width:     i32,         // Leading selection indicator width (default 2: "▸ ")
	column_spacing:   i32,         // Gap between columns in cells (default 1)
	show_header:      bool,        // Default true when col_specs is non-empty
	header_separator: bool,        // Draws a horizontal `─` rule below headers
	scroll_step:      i32,
	scroll_padding:   i32,
	fallback_rows:    i32,
	focusable:        bool,
	focus_flags:      Focus_Flags,
}
```

### Declarative `ui_table` + `ui_table_row` Example

```odin
vslice: bifrost.Virtual_Slice
if bifrost.ui_table(ctx, scr, inp, "records_table", total_rows, col_specs[:], {
	title            = "Arrow IPC Records",
	width            = bifrost.grow(1),
	height           = bifrost.grow(1),
	border           = .Rounded,
	show_header      = true,
	header_separator = true,
	focus_flags      = {.Focusable, .Default_Focus},
}, &vslice) {
	for r := vslice.start_row; r < vslice.end_row; r += 1 {
		cells := [3]string{row_id_str(r), row_scope_str(r), row_dur_str(r)}
		bifrost.ui_table_row(ctx, r, cells[:], row_fg_color(r))
	}
}
```

---

## 1. Low-Level Virtualized List Container (`ui_virtual_list`)

`ui_virtual_list` is a `@(deferred_in = defer_end_virtual_list)` container that computes the clamped visible row window `[start_row ..< end_row]` from `Input_State.scroll_slots` (`MAX_SCROLL_SLOTS = 32`) and populates `out_slice: ^Virtual_Slice`.

```odin
Virtual_List_Config :: struct {
	title:          string,
	width:          Axis_Size,   // Defaults to grow(1)
	height:         Axis_Size,   // Defaults to grow(1)
	border:         Border_Kind,
	fg:             Color,
	bg:             Color,
	border_fg:      Color,
	title_fg:       Color,
	scroll_step:    i32,         // Mouse wheel step (default 3)
	scroll_padding: i32,         // Lookahead rows kept above/below selected_row
	fallback_rows:  i32,         // Estimated viewport height on Frame 0 (default 10)
	total_cols:     i32,         // > 1 enables 2D h/l column stepping & mouse column selection
	focusable:      bool,
	focus_flags:    Focus_Flags,
}

Virtual_Slice :: struct {
	start_row:     i32, // Inclusive start index into dataset
	end_row:       i32, // Exclusive end index into dataset
	selected_row:  i32, // Currently highlighted row index (0 ..< total_rows)
	selected_col:  i32, // Currently highlighted column index (0 ..< total_cols)
	scroll_offset: i32, // Clamped top visible row index
	viewport_rows: i32, // Solved inner_rect.h
	total_rows:    i32,
	total_cols:    i32,
}
```

### Keyboard & Mouse Navigation in `ui_virtual_list`
* **Vertical Row Stepping (`j`/`k`, `Down`/`Up`, `Ctrl+N`/`Ctrl+P`):** Moves `selected_row` by `±repeat_count` (`5j` jumps 5 rows), maintaining `scroll_padding` lookahead rows at the top and bottom of the viewport.
* **Paging (`Page_Up`, `Page_Down`, `Home`, `End`, Emacs `C-v`/`M-v`):** Pages by `max(1, viewport_rows - 1)` or jumps to row `0` / `total_rows - 1`.
* **2D Horizontal Column Stepping (`h`/`l`, `Left`/`Right`, Emacs `C-b`/`C-f`):**
  * When `total_cols > 1`, `l` and `h` step `selected_col` across `0 ..< total_cols`.
  * When `selected_col` is at column `0` and the user presses `h` (or at `total_cols - 1` and presses `l`), spatial navigation bubbles out of the table into adjacent left/right panes (unless `.Loop_Spatial`, `.Wrap_Spatial`, or `.Strict_Spatial` is set on the list).
* **Z-Aware Mouse Wheel & Click:**
  * Mouse wheel events over any descendant node bubble up to the enclosing `ui_virtual_list` (`hit_test_scrollable`).
  * Left-clicking inside the list selects `slot.offset + rel_y` and resolves `selected_col` via `select_virtual_col_at_x`.

---

## 2. Jitter-Free Table Column Solver (`resolve_table_columns`)

When virtual scrolling through variable-length data, naive auto-sizing causes columns to jitter left and right every frame. `Table_Column_Spec` prevents this with a monotonically non-decreasing `max_observed_w` high-water mark:

```odin
Column_Width_Kind :: enum u8 {
	Fixed = 0,     // Exact width in cells (value or fixed_width)
	Fill,          // Proportional share of remaining width (value or fill_weight)
	Auto_Content,  // Monotonic high-water mark: max(header_w, observed_visible_cell_w)
}

Table_Column_Spec :: struct {
	header:         string,
	kind:           Column_Width_Kind,
	value:          i32,
	fixed_width:    i32,
	fill_weight:    i32,
	min_width:      i32,
	max_width:      i32,
	max_observed_w: i32,
	align:          Column_Align, // .Left, .Center, .Right
}
```

### Column Solver Workflow
1. For each visible row in `slice.start_row ..< slice.end_row`, call `table_column_observe_cell(&col_specs[c], cell_str)` on any `.Auto_Content` column.
2. Call `resolve_table_columns(col_specs[:], spans[:], inner_rect, gutter_width, column_spacing)` to compute screen-space `Table_Column_Span`s.
3. Call `register_virtual_table_col_spans(inp, list_id, spans[:])` so mouse clicks inside the table select the exact clicked column.
4. Render aligned cells with `draw_table_cell(scr, spans[c], row_y, row_clip, cell_str, fg, bg, style)`.

---

## 3. 64-Bit Interior-Detent Scrollbar (`compute_scrollbar_metrics`)

All scrollable containers (`scrollable = true`, `ui_virtual_list`, `ui_tree`, `ui_text_area`) automatically draw a proportional vertical scrollbar (`┃` thumb over `│` track) on their right border when content exceeds `inner_rect.h`:
* `thumb_offset == 0` **if and only if** `scroll_offset <= 0` (at the exact top).
* `thumb_offset == track_avail` **if and only if** `scroll_offset >= max_scroll` (at the exact bottom).
* For all intermediate scroll positions (`0 < scroll_offset < max_scroll`), `thumb_offset` is clamped to the interior `[1, track_avail - 1]` so the user never mistakes a nearly-scrolled view for the absolute top or bottom.

---

## 4. Complete 2D Virtual Table Example

```odin
package demo

import "core:fmt"
import "../../bifrost"

render_module_table :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
	col_specs: ^[3]bifrost.Table_Column_Spec,
	out_slice: ^bifrost.Virtual_Slice,
) {
	if bifrost.ui_virtual_list(ctx, scr, inp, "mod_table", 100_000, {
		title          = "Modules (100,000 rows)",
		width          = bifrost.grow(1),
		height         = bifrost.grow(1),
		border         = .Rounded,
		scroll_padding = 1,
		fallback_rows  = 16,
		total_cols     = 3,
		focus_flags    = {.Focusable, .Default_Focus},
	}, out_slice) {
		for vis_r := out_slice.start_row; vis_r < out_slice.end_row; vis_r += 1 {
			row_id := fmt.tprintf("mod_row_%d", vis_r)
			bifrost.leaf(ctx, row_id, 20, 1, {
				width     = bifrost.grow(1),
				height    = bifrost.fixed(1),
				clickable = true,
			})
		}
	}
}
```