# Virtualized Lists, 2D Tables & SIMD CSV Grids (`ui_table`, `ui_virtual_list`, `CSV_Grid_Table`)

**Source Files:** [`bifrost/table.odin`](../../bifrost/table.odin), [`bifrost/scroll.odin`](../../bifrost/scroll.odin), [`bifrost/csv_grid.odin`](../../bifrost/csv_grid.odin), [`bifrost/xitdb_bridge.odin`](../../bifrost/xitdb_bridge.odin)

Bifrost provides both a high-level declarative 2D table widget (`ui_table` / `ui_virtual_table` + `ui_table_row` in [`bifrost/table.odin`](../../bifrost/table.odin)) with pinned sticky headers, frozen left columns (`pinned_cols`), 2D horizontal + vertical viewport virtualization (`MAX_TABLE_COLS :: 256`), interactive sorting and resizing, and single-glyph `…` (`U+2026`) cell truncation, as well as the underlying `ui_virtual_list` + `resolve_table_columns` primitives and the zero-copy SIMD RFC 4180 CSV grid engine (`CSV_Grid_Table` in [`bifrost/csv_grid.odin`](../../bifrost/csv_grid.odin)). Both materialize only the `O(viewport_rows)` visible `Layout_Node`s each frame even over `1,000,000+` rows and `200+` columns.

---

## 0. Declarative 2D Virtualized Table (`ui_table` & `ui_table_row`)

`ui_table` (aliased as `ui_virtual_table`) wraps `ui_virtual_list`, reserves a pinned 1-row sticky column header and optional 1-row horizontal separator (`─`) above the scrollable body, runs the monotonic `resolve_slot_table_columns` solver across up to `MAX_TABLE_COLS :: 256` columns, clips frozen left columns (`0 ..< pinned_cols`, separated by `║` / `╫`) independently from horizontally scrolled right-quadrant columns (`start_col ..< end_col`), registers 2D mouse hit-testing spans, and renders cell/row/multi-selection focus highlights during `end_layout(ctx)`.

```odin
Table_Sort_Dir :: enum u8 {
	None = 0,
	Asc,
	Desc,
}

Table_Config :: struct {
	title:            string,
	width:            Axis_Size,               // Defaults to grow(1)
	height:           Axis_Size,              // Defaults to grow(1)
	border:           Border_Kind,
	fg:               Color,
	bg:               Color,
	border_fg:        Color,
	title_fg:         Color,
	header_fg:        Color,
	header_bg:        Color,
	header_style:     Style_Flags,             // Defaults to {.Bold}
	row_alt_bg:       Color,                   // Optional zebra-stripe background for odd rows
	selected_row_fg:  Color,
	selected_row_bg:  Color,
	selected_cell_fg: Color,
	selected_cell_bg: Color,
	gutter_width:     i32,                     // Leading selection indicator width (default 2: "▸ ")
	column_spacing:   i32,                     // Gap between columns in cells (default 1)
	show_header:      bool,                    // Default true when col_specs is non-empty
	header_separator: bool,                    // Draws a horizontal `─` rule below headers
	column_dividers:  bool,                    // Draws vertical `│` dividers between columns
	pinned_cols:      i32,                     // Frozen left columns (0 ..< pinned_cols) with `║` / `╫` divider
	sortable:         bool,                    // Click header or press `s` to cycle None -> Asc (▲) -> Desc (▼)
	resizable:        bool,                    // Drag header divider or press `+` / `-` / `0` to resize / reset column
	show_row_numbers: bool,                    // Renders 1-based row numbers in the leading gutter
	follow_tail:      bool,                    // Auto-pins scroll_offset to bottom until scrolled up manually
	selection:        ^Table_Selection_Set,    // Optional O(1)-per-interval disjoint multi-row selection set
	scroll_step:      i32,
	scroll_padding:   i32,
	fallback_rows:    i32,
	focusable:        bool,
	focus_flags:      Focus_Flags,
}
```

### Declarative `ui_table` + `ui_table_row` + `ui_table_is_col_visible` Example

For wide tables (e.g. `100–256` columns), use `ui_table_is_col_visible(&vslice, col_idx)` to skip formatting off-screen columns outside `[0 ..< pinned_cols)` and `[vslice.start_col ..< vslice.end_col)`:

```odin
vslice: bifrost.Virtual_Slice
if bifrost.ui_table(ctx, scr, inp, "records_table", col_specs[:], total_rows, {
	title            = "Wide Dataset (1,000,000 rows x 190 cols)",
	width            = bifrost.grow(1),
	height           = bifrost.grow(1),
	border           = .Rounded,
	show_header      = true,
	header_separator = true,
	column_dividers  = true,
	pinned_cols      = 1,
	sortable         = true,
	resizable        = true,
	show_row_numbers = true,
	selection        = &selection_set,
	focus_flags      = {.Focusable, .Default_Focus},
}, &vslice) {
	cells := make([]string, len(col_specs), context.temp_allocator)
	for r := vslice.start_row; r < vslice.end_row; r += 1 {
		for c := 0; c < len(col_specs); c += 1 {
			if bifrost.ui_table_is_col_visible(&vslice, c) {
				cells[c] = format_cell(r, c)
			}
		}
		bifrost.ui_table_row(ctx, scr, r, cells)
	}
}
```

---

## 1. Low-Level Virtualized List Container (`ui_virtual_list`)

`ui_virtual_list` is a `@(deferred_in = defer_end_virtual_list)` container that computes the clamped visible 2D window (`[start_row ..< end_row]` and `[start_col ..< end_col]`) from `Input_State.scroll_slots` (`MAX_SCROLL_SLOTS = 32`, `MAX_TABLE_COLS = 256`) and populates `out_slice: ^Virtual_Slice`.

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
	pinned_cols:    i32,         // Frozen left columns (0 ..< pinned_cols)
	sortable:       bool,
	resizable:      bool,
	follow_tail:    bool,
	focusable:      bool,
	focus_flags:    Focus_Flags,
}

Virtual_Slice :: struct {
	start_row:       i32, // Inclusive start row index into dataset
	end_row:         i32, // Exclusive end row index into dataset
	selected_row:    i32, // Currently highlighted row index (0 ..< total_rows)
	selected_col:    i32, // Currently highlighted column index (0 ..< total_cols)
	scroll_offset:   i32, // Clamped top visible row index
	scroll_offset_x: i32, // Clamped horizontal scroll offset in terminal cells (for unpinned columns)
	viewport_rows:   i32, // Solved inner_rect.h
	viewport_cols:   i32, // Solved inner_rect.w
	total_rows:      i32,
	total_cols:      i32,
	pinned_cols:     i32, // Number of frozen left columns (0 ..< pinned_cols)
	start_col:       i32, // First visible unpinned column index (>= pinned_cols)
	end_col:         i32, // Exclusive end visible unpinned column index (<= total_cols)
	sort_col:        i32, // Currently sorted column index (-1 when unsorted)
	sort_dir:        Table_Sort_Dir,
	sort_changed:    bool, // True on the frame the user clicked a sortable header or pressed `s`
}
```

### Keyboard & Mouse Navigation in `ui_table` / `ui_virtual_list`
* **Vertical Row Stepping (`j`/`k`, `Down`/`Up`, `Ctrl+N`/`Ctrl+P`):** Moves `selected_row` by `±repeat_count` (`5j` jumps 5 rows), maintaining `scroll_padding` lookahead rows at the top and bottom of the viewport.
* **Paging (`Page_Up`, `Page_Down`, `Home`/`g g`, `End`/`G`, Emacs `C-v`/`M-v`):** Pages by `max(1, viewport_rows - 1)` or jumps to row `0` / `total_rows - 1`. When `follow_tail = true`, scrolling up unpins `tail_pinned` and reaching the bottom re-pins it automatically.
* **2D Horizontal Column Stepping & Auto-Pan (`h`/`l`, `Left`/`Right`, `0`/`^`, `$`, Emacs `C-b`/`C-f`):**
  * When `total_cols > 1`, `l` and `h` step `selected_col` across `0 ..< total_cols` and automatically adjust `scroll_offset_x` (`ensure_virtual_col_visible`) so `selected_col` stays visible inside the unpinned right quadrant.
  * `^` jumps to column `0` (`scroll_offset_x = 0`) and `$` jumps to `total_cols - 1`.
  * When `selected_col` is at column `0` and the user presses `h` (or at `total_cols - 1` and presses `l`), spatial navigation bubbles out of the table into adjacent left/right panes.
* **Interactive Column Sorting & Resizing:**
  * Pressing `s` or left-clicking a column header when `sortable = true` cycles `sort_dir` (`None -> Asc ▲ -> Desc ▼ -> None`) and sets `vslice.sort_changed = true`.
  * Pressing `+` / `=` or `-` when `resizable = true` widens or narrows `selected_col` by `±2` cells (`0` resets user width overrides back to `.Auto_Content`). Dragging a header divider with the mouse resizes the column live.
* **Clickable & Draggable 2D Scrollbars:**
  * Clicking or dragging the right-border vertical scrollbar (`┃` over `│`) or bottom-border horizontal scrollbar (`━` over `─`) scrubs `scroll_offset` or `scroll_offset_x` proportionally across `1,000,000+` rows or wide column spans using 64-bit integer ratio arithmetic.

---

## 2. Jitter-Free Table Column Solver & Bounded Sanitization (`resolve_table_columns`, `draw_table_cell`)

When virtual scrolling through variable-length data, naive auto-sizing causes columns to jitter left and right every frame. `Table_Column_Spec` prevents this with a monotonically non-decreasing `max_observed_w` high-water mark and `O(max_cols)` bounded width measurement (`string_display_width_bounded`):

* **Bounded Cell Measurement (`string_display_width_bounded`):** Stops decoding UTF-8 runes as soon as `max_cols` is reached, preventing `O(len(str))` stalls on multi-kilobyte text blobs.
* **Control-Character Sanitization & Single-Glyph Ellipsis (`draw_table_cell`):** Embedded `\n`, `\r`, `\t`, and C0/C1 control characters are sanitized to single spaces in-flight so multi-line CSV fields never corrupt terminal row geometry, and overflowing cells terminate with `…` (`U+2026`).

---

## 3. Zero-Copy SIMD CSV Grid Engine (`bifrost/csv_grid.odin`)

`CSV_Grid_Table` provides an instant-load, zero-copy tabular engine for multi-megabyte RFC 4180 CSV files and `1,000,000+`-row virtual datasets:

* **`build_csv_sparse_row_index` (`#simd[32]u8`):** Scans 32 bytes per iteration with carry-less quote-parity tracking across `"` quotes (`\n` inside quoted multiline fields is ignored) and records a sparse `u64` byte offset every `64` rows (`~125 KB` index for `1,000,000` rows).
* **Zero-Copy Viewport Slicing (`csv_grid_slice_row`):** Resolves any physical row in `O(1)` amortized time via a 256-slot L1 ring cache and slices `[]string` views directly into `raw_data` (allocating onto `context.temp_allocator` only when RFC 4180 `""` unescaping is needed).
* **Single-Pass `O(N)` Sort Key Extraction (`csv_grid_sort_by_column`):** Pre-extracts a 16-byte `CSV_Sort_Key` (`f64` primary key + 8-byte inline prefix + `u32` row index) in one linear pass and sorts `row_perm` with zero per-comparison CSV parsing.
* **Disjoint-Interval Multi-Row Selection (`Table_Selection_Set`):** Tracks arbitrary range selections (`[start_row, end_row]`), single-row toggles (`table_selection_toggle_row`), and `O(1)` `Ctrl+A` select-all / invert across `1,000,000` rows.

---

## 4. Complete 2D Virtual Table Example (`examples/csv_workbench`)

Run the flagship 1,000,000-row SIMD CSV workbench (`examples/csv_workbench`) to test real PitchBook and Attio CSV benchmarks (`74,356` rows, `190` columns, and `1,000,000`-row virtual scaling):

```bash
odin run examples/csv_workbench -custom-attribute:telemetry_schema -vet -strict-style -vet-packages:bifrost,main
odin run examples/csv_workbench -custom-attribute:telemetry_schema -- --live-tty
```
