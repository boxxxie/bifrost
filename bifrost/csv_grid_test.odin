package bifrost

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_csv_grid_simd_multiline_quote_parity_and_zero_copy_slicing :: proc(t: ^testing.T) {
	raw_csv := strings.concatenate({
		"PersonID,FullName,Bio,AUM_Millions,City\n",
		"101,\"Ada Lovelace\",\"First programmer.\nWrote analytical engine notes\nand \"\"quoted\"\" algorithms.\",\"$125.5M\",London\n",
		"102,\"Alan Turing\",\"Cryptanalyst & mathematician\r\nBletchley Park\",\"$80.0M\",Manchester\n",
		"103,\"Grace Hopper\",\"Compiler pioneer\",15.25,\"New York\"\n",
		"104,\"Donald Knuth\",\"Author of TAOCP\nLine 2\nLine 3\",\"$210.0M\",Stanford\n",
	}, context.temp_allocator)

	grid: CSV_Grid_Table
	csv_grid_init_from_bytes(&grid, transmute([]u8)raw_csv, false, ',')
	defer csv_grid_destroy(&grid)

	// Despite 9 physical newline characters in the data body, SIMD quote-parity must find exactly 4 records
	testing.expect_value(t, grid.physical_row_count, i32(4))
	testing.expect_value(t, len(grid.headers), 5)
	testing.expect_value(t, grid.headers[0], "PersonID")
	testing.expect_value(t, grid.headers[2], "Bio")
	testing.expect_value(t, grid.headers[3], "AUM_Millions")

	// Numeric column detection should right-align PersonID and AUM_Millions
	testing.expect_value(t, grid.col_specs[0].align, Column_Align.Right)
	testing.expect_value(t, grid.col_specs[3].align, Column_Align.Right)
	testing.expect_value(t, grid.col_specs[1].align, Column_Align.Left)

	cells: [5]string
	cnt0 := csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, cnt0, 5)
	testing.expect_value(t, cells[0], "101")
	testing.expect_value(t, cells[1], "Ada Lovelace")
	testing.expect_value(t, cells[2], "First programmer.\nWrote analytical engine notes\nand \"quoted\" algorithms.")
	testing.expect_value(t, cells[3], "$125.5M")
	testing.expect_value(t, cells[4], "London")

	cnt3 := csv_grid_slice_row(&grid, 3, cells[:], context.temp_allocator)
	testing.expect_value(t, cnt3, 5)
	testing.expect_value(t, cells[0], "104")
	testing.expect_value(t, cells[1], "Donald Knuth")
	testing.expect_value(t, cells[4], "Stanford")

	// Test numeric-aware sorting on column 3 (AUM_Millions: 15.25 < $80.0M < $125.5M < $210.0M)
	csv_grid_set_sort(&grid, 3, .Asc)
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(4))
	_ = csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Grace Hopper")
	_ = csv_grid_slice_row(&grid, 3, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Donald Knuth")

	// Test descending sort on column 3
	csv_grid_set_sort(&grid, 3, .Desc)
	_ = csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Donald Knuth")
	_ = csv_grid_slice_row(&grid, 3, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Grace Hopper")

	// Test case-insensitive substring filtering ("bletchley")
	csv_grid_set_sort(&grid, -1, .None)
	csv_grid_set_filter(&grid, "bletchley")
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1))
	_ = csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Alan Turing")

	// Test 1,000,000-row virtual scaling
	csv_grid_set_filter(&grid, "")
	csv_grid_set_virtual_rows(&grid, 1_000_000)
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1_000_000))
	_ = csv_grid_slice_row(&grid, 999_999, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Donald Knuth")

	// Sorting in 1,000,000-row virtual mode must only allocate `O(physical_row_count)` in `row_perm` (`len(grid.row_perm) == 4`)
	csv_grid_set_sort(&grid, 3, .Asc)
	testing.expect_value(t, len(grid.row_perm), 4)
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1_000_000))
	_ = csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Grace Hopper")
	_ = csv_grid_slice_row(&grid, 999_999, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Donald Knuth")
}

@(test)
test_csv_grid_escaped_quote_headers_and_filter_edge_cases :: proc(t: ^testing.T) {
	//Header with escaped quotes `""` allocates via `unescape_csv_quotes` and must be freed cleanly by `csv_grid_destroy`
	raw_csv := strings.concatenate({
		"\"Deal \"\"Alpha\"\" ID\",\"Company\",Value\n",
		"1,\"Acme, Inc.\",100\n",
		"2,\"Beta \"\"Megapack\"\" Corp\",200\n",
	}, context.temp_allocator)

	grid: CSV_Grid_Table
	csv_grid_init_from_bytes(&grid, transmute([]u8)raw_csv, false, ',')
	defer csv_grid_destroy(&grid)

	testing.expect_value(t, len(grid.headers), 3)
	testing.expect_value(t, grid.headers[0], "Deal \"Alpha\" ID")
	testing.expect_value(t, grid.physical_row_count, i32(2))

	// 1. Whitespace-only filter must not blank out the table
	csv_grid_set_filter(&grid, "   ")
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(2))

	// 2. Mutable buffer aliasing test: mutating caller buffer in-place must not corrupt `active_filter`
	mut_buf := [4]u8{'A', 'c', 'm', 'e'}
	csv_grid_set_filter(&grid, string(mut_buf[:]))
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1))

	mut_buf = {'B', 'e', 't', 'a'}
	csv_grid_set_filter(&grid, string(mut_buf[:]))
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1))
	cells: [3]string
	_ = csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, cells[1], "Beta \"Megapack\" Corp")

	// 2b. Filter queries containing `,` or `"` must match unescaped cell values and not raw CSV delimiters/quotes
	csv_grid_set_filter(&grid, "\"Megapack\"")
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1))
	csv_grid_set_filter(&grid, ",")
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(1)) // Only "Acme, Inc." has a literal comma
	csv_grid_set_filter(&grid, "1,Acme")
	testing.expect_value(t, csv_grid_visible_row_count(&grid), i32(0)) // Cross-column delimiter should not match

	// 3. Strict numeric cell parser edge cases
	_, ok_space := parse_csv_numeric_value("12 34")
	testing.expect(t, !ok_space)
	_, ok_mid_dollar := parse_csv_numeric_value("12$34")
	testing.expect(t, !ok_mid_dollar)
	_, ok_dot_neg := parse_csv_numeric_value(".-5")
	testing.expect(t, !ok_dot_neg)
	val_curr, ok_curr := parse_csv_numeric_value("-$1,250.5K")
	testing.expect(t, ok_curr)
	testing.expect_value(t, val_curr, f64(-1_250_500.0))
}

@(test)
test_ui_table_sortable_and_resizable_flags_and_fill_user_width :: proc(t: ^testing.T) {
	ctx: Layout_Context
	s: Screen
	_ = screen_init(&s, 80, 20, context.temp_allocator)
	inp := new(Input_State, context.temp_allocator)

	cols := [2]Table_Column_Spec{
		0 = {header = "Key",   kind = .Fixed, value = 12, min_width = 6},
		1 = {header = "Value", kind = .Fill,  value = 1,  min_width = 10},
	}

	// Render a read-only table (`sortable = false`, `resizable = false`)
	begin_frame(&s)
	begin_layout(&ctx, 80, 20, context.temp_allocator)
	slice: Virtual_Slice
	if ui_table(&ctx, &s, inp, "ro_table", cols[:], 5, Table_Config{
		width     = fixed(80),
		height    = fixed(10),
		sortable  = false,
		resizable = false,
	}, &slice) {
		row := [2]string{"k1", "v1"}
		ui_table_row(&ctx, &s, 0, row[:])
	}
	end_layout(&ctx)
	inp.focused_id = hash_id("ro_table")
	sync_scroll_viewports(inp, &ctx)

	slot := get_scroll_slot(inp, hash_id("ro_table"))
	orig_w0 := slot.col_x_widths[0]
	node_idx := ctx.id_map[hash_id("ro_table")]

	// Pressing 's' or '+' when sortable/resizable are false must be ignored
	testing.expect(t, !handle_table_key_shortcut(inp, &ctx.nodes[node_idx], slot, 's'))
	testing.expect_value(t, slot.sort_dir, Table_Sort_Dir.None)
	testing.expect(t, !handle_table_key_shortcut(inp, &ctx.nodes[node_idx], slot, '+'))
	testing.expect_value(t, slot.col_user_widths[0], i16(0))
	testing.expect_value(t, slot.col_x_widths[0], orig_w0)

	// Enable sortable & resizable and resize the `.Fill` column (col 1)
	slot.sortable  = true
	slot.resizable = true
	slot.selected_col = 1
	testing.expect(t, handle_table_key_shortcut(inp, &ctx.nodes[node_idx], slot, '-'))
	testing.expect(t, slot.col_user_widths[1] > 0)

	// Verify `sync_table_highlights` propagates `col_user_widths` to `Table_Render_Entry`
	sync_table_highlights(&s, inp)
	entry := s.table_entries[hash_id("ro_table")]
	testing.expect_value(t, entry.col_user_widths[1], slot.col_user_widths[1])

	// Verify C0/DEL control bytes (`\x1b`, `\v`, `\x7f`) are sanitized to spaces in `string_display_width_bounded`
	w_ctrl, trunc_ctrl := string_display_width_bounded("a\x1bb\vc\x7fd", 16)
	testing.expect_value(t, w_ctrl, i32(7))
	testing.expect(t, !trunc_ctrl)

	// Verify Pass 2 `.Fill` column distribution deducts clamped `min_w` from remaining budget so `.Fill` columns do not overflow `avail_w`
	fill_slot: Scroll_Slot
	fill_slot.col_spec_count = 2
	fill_slot.col_spacing    = 1
	fill_slot.col_kinds[0]   = .Fill
	fill_slot.col_kinds[1]   = .Fill
	fill_slot.col_req_widths[0] = 1
	fill_slot.col_req_widths[1] = 1
	fill_slot.col_min_widths[0] = 15
	fill_slot.col_min_widths[1] = 4
	fill_slot.col_header_widths[0] = 4
	fill_slot.col_header_widths[1] = 4
	_ = resolve_slot_table_columns(&fill_slot, Rect{x = 0, y = 0, w = 20, h = 10})
	// Total available width after 1-col spacing is 19 -> col 0 takes min_w=15, col 1 takes remaining 4 (max_offset_x == 0)
	testing.expect_value(t, fill_slot.col_x_widths[0], i16(15))
	testing.expect_value(t, fill_slot.col_x_widths[1], i16(4))
	testing.expect_value(t, fill_slot.max_offset_x, i32(0))

	// Verify wide glyph (`w == 2`, e.g. '中') in `put_sanitized_text_bounded` writes continuation cell (`width == 0`)
	// when inside `clip` and replaces split wide glyphs at `clip` edge with `' '`
	_ = put_sanitized_text_bounded(&s, 2, 2, "中", 4, rgb(255, 255, 255), rgb(0, 0, 0), {}, Rect{x = 2, y = 2, w = 4, h = 1})
	testing.expect_value(t, s.back[2 * s.width + 2].ch, '中')
	testing.expect_value(t, s.back[2 * s.width + 2].width, u8(2))
	testing.expect_value(t, s.back[2 * s.width + 3].width, u8(0))
	// Split at right clip edge (`clip.w == 1` at `x = 5`) -> must paint `' '` of width 1 instead of orphaned half-wide cell
	_ = put_sanitized_text_bounded(&s, 5, 2, "中", 4, rgb(255, 255, 255), rgb(0, 0, 0), {}, Rect{x = 5, y = 2, w = 1, h = 1})
	testing.expect_value(t, s.back[2 * s.width + 5].ch, ' ')
	testing.expect_value(t, s.back[2 * s.width + 5].width, u8(1))
}

@(test)
test_table_selection_set_disjoint_intervals_and_invert :: proc(t: ^testing.T) {
	sel: Table_Selection_Set
	table_selection_init(&sel)
	defer table_selection_destroy(&sel)

	// Add two disjoint ranges and coalesce them with a bridging range
	table_selection_add_range(&sel, 10, 20)
	table_selection_add_range(&sel, 25, 30)
	testing.expect_value(t, len(sel.intervals), 2)
	testing.expect_value(t, table_selection_count(&sel, 1_000_000), i32(17))
	testing.expect(t, table_selection_contains(&sel, 15))
	testing.expect(t, !table_selection_contains(&sel, 22))

	// Bridge [20..25] -> coalesces into single [10, 30] interval
	table_selection_add_range(&sel, 21, 24)
	testing.expect_value(t, len(sel.intervals), 1)
	testing.expect_value(t, sel.intervals[0], [2]i32{10, 30})
	testing.expect_value(t, table_selection_count(&sel, 1_000_000), i32(21))

	// Punch a hole in the middle [15, 25] -> splits into [10, 14] and [26, 30]
	table_selection_remove_range(&sel, 15, 25)
	testing.expect_value(t, len(sel.intervals), 2)
	testing.expect_value(t, sel.intervals[0], [2]i32{10, 14})
	testing.expect_value(t, sel.intervals[1], [2]i32{26, 30})
	testing.expect_value(t, table_selection_count(&sel, 1_000_000), i32(10))

	// O(1) Select All over 1,000,000 rows + deselect 1 row
	table_selection_select_all(&sel)
	testing.expect_value(t, table_selection_count(&sel, 1_000_000), i32(1_000_000))
	table_selection_toggle_row(&sel, 500_000)
	testing.expect(t, !table_selection_contains(&sel, 500_000))
	testing.expect(t, table_selection_contains(&sel, 499_999))
	testing.expect_value(t, table_selection_count(&sel, 1_000_000), i32(999_999))

	// Anchor-based range extension (`table_selection_extend_to`)
	table_selection_clear(&sel)
	table_selection_toggle_row(&sel, 5)
	table_selection_extend_to(&sel, 9)
	testing.expect_value(t, table_selection_count(&sel, 100), i32(5))
	testing.expect(t, table_selection_contains(&sel, 7))
}

@(test)
test_csv_grid_real_bragi_benchmark_files_if_present :: proc(t: ^testing.T) {
	person_path := "../benchmarks/data/pitchbook/Person.csv"
	if !os.exists(person_path) {
		person_path = "benchmarks/data/pitchbook/Person.csv"
	}
	if !os.exists(person_path) {
		return
	}

	grid: CSV_Grid_Table
	ok := csv_grid_load_file(&grid, person_path)
	defer csv_grid_destroy(&grid)
	testing.expect(t, ok)

	// Person.csv has 30,351 data records (+ 1 header = 30,352 lines) and 31 columns
	testing.expect_value(t, len(grid.headers), 31)
	testing.expect_value(t, grid.physical_row_count, i32(30_351))

	cells: [31]string
	extracted := csv_grid_slice_row(&grid, 0, cells[:], context.temp_allocator)
	testing.expect_value(t, extracted, 31)
	testing.expect(t, len(cells[0]) > 0)
}
