package bifrost

import "core:mem"
import "core:testing"

@(test)
test_grapheme_clusters_and_display_width_slicing :: proc(t: ^testing.T) {
	// 1. Display widths across ASCII, CJK, ZWJ emoji, VS16 emoji, and halfwidth dakuten
	testing.expect_value(t, string_display_width("hello"), 5)
	testing.expect_value(t, string_display_width("称号コン"), 8)
	testing.expect_value(t, string_display_width("👩‍🚀"), 2)
	testing.expect_value(t, string_display_width("⌨️"), 2)
	testing.expect_value(t, string_display_width("ｶﾞｷﾞ"), 4)
	testing.expect_value(t, string_display_width("a🦀b"), 4)

	// 2. Extended grapheme cluster stepping (next_grapheme_cluster / prev_grapheme_cluster)
	mixed := "a👩‍🚀⌨️称b"
	testing.expect_value(t, string_display_width(mixed), 8)

	b0, w0, r0 := next_grapheme_cluster(mixed, 0)
	testing.expect_value(t, r0, 'a')
	testing.expect_value(t, w0, 1)
	testing.expect_value(t, b0, 1)

	b1, w1, _ := next_grapheme_cluster(mixed, b0) // 11-byte ZWJ astronaut "👩‍🚀"
	testing.expect_value(t, w1, 2)
	testing.expect_value(t, b1 - b0, 11)

	b2, w2, _ := next_grapheme_cluster(mixed, b1) // 6-byte VS16 keyboard "⌨️"
	testing.expect_value(t, w2, 2)
	testing.expect_value(t, b2 - b1, 6)

	b3, w3, r3 := next_grapheme_cluster(mixed, b2) // 3-byte CJK "称"
	testing.expect_value(t, r3, '称')
	testing.expect_value(t, w3, 2)
	testing.expect_value(t, b3 - b2, 3)

	testing.expect_value(t, prev_grapheme_cluster(mixed, b3), b2)
	testing.expect_value(t, prev_grapheme_cluster(mixed, b2), b1)
	testing.expect_value(t, prev_grapheme_cluster(mixed, b1), b0)
	testing.expect_value(t, prev_grapheme_cluster(mixed, b0), 0)

	// 3. Display-column viewport slicing across 2-column CJK boundaries
	cjk := "称号コン" // 4 wide runes = 8 display columns (0..2, 2..4, 4..6, 6..8)

	aligned := slice_utf8_by_display_width(cjk, 2, 4)
	testing.expect_value(t, aligned.text, "号コ")
	testing.expect_value(t, aligned.lead_pad, 0)
	testing.expect_value(t, aligned.trail_pad, 0)
	testing.expect_value(t, aligned.columns, 4)

	// Odd left boundary (scroll_col = 1, max_cols = 5 -> cols [1..6)):
	// '称' (0..2) straddles col 1 -> lead_pad = 1, text = "号コ" (cols 2..6), trail_pad = 0
	left_straddle := slice_utf8_by_display_width(cjk, 1, 5)
	testing.expect_value(t, left_straddle.text, "号コ")
	testing.expect_value(t, left_straddle.lead_pad, 1)
	testing.expect_value(t, left_straddle.trail_pad, 0)
	testing.expect_value(t, left_straddle.columns, 4)

	// Odd right boundary (scroll_col = 0, max_cols = 5 -> cols [0..5)):
	// Fits "称号" (4 cols), 'コ' (cols 4..6) straddles right edge -> trail_pad = 1
	right_straddle := slice_utf8_by_display_width(cjk, 0, 5)
	testing.expect_value(t, right_straddle.text, "称号")
	testing.expect_value(t, right_straddle.lead_pad, 0)
	testing.expect_value(t, right_straddle.trail_pad, 1)
	testing.expect_value(t, right_straddle.columns, 4)
}

@(test)
test_text_input_word_motions_and_xitdb_filter :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer {
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	inp: Input_State
	slot := get_text_slot(&inp, hash_id("query"))

	// 1. Ctrl+W (whitespace-delimited) vs Alt+Backspace (word/punctuation boundary)
	set_text(&inp, "query", "alpha\u3000beta\u2014gamma")
	text_input_delete_word_boundary(&inp, slot)
	testing.expect_value(t, get_text(&inp, "query"), "alpha\u3000beta\u2014")
	testing.expect(t, was_text_changed(&inp, "query"))

	text_input_delete_word_whitespace(&inp, slot)
	testing.expect_value(t, get_text(&inp, "query"), "alpha\u3000")

	// 2. Word movement & Ctrl+K / Ctrl+U / Alt+D kills
	set_text(&inp, "query", "one two three")
	slot.cursor_byte = text_input_move_word_left(get_text(&inp, "query"), slot.cursor_byte)
	testing.expect_value(t, get_text(&inp, "query")[:slot.cursor_byte], "one two ")

	text_input_kill_to_end(&inp, slot)
	testing.expect_value(t, get_text(&inp, "query"), "one two ")

	slot.cursor_byte = text_input_move_word_left(get_text(&inp, "query"), slot.cursor_byte)
	text_input_kill_to_start(&inp, slot)
	testing.expect_value(t, get_text(&inp, "query"), "two ")
	testing.expect_value(t, slot.cursor_byte, 0)

	text_input_delete_word_after(&inp, slot)
	testing.expect_value(t, get_text(&inp, "query"), " ")

	// 3. Real-time Xitdb_Filter index mapping and zero-allocation steady state
	filter: Xitdb_Filter
	err := xitdb_filter_init(&filter, alloc)
	testing.expect_value(t, err, nil)
	defer xitdb_filter_destroy(&filter)

	row_fn :: proc(db_row: i32, a := context.temp_allocator) -> string {
		_ = a
		return "MATCH_ROW" if (db_row % 2 == 0) else "OTHER_ROW"
	}

	set_text(&inp, "query", "match")
	count := xitdb_filter_update(&filter, &inp, "query", "list", 1, 10, row_fn)
	testing.expect_value(t, count, 5)
	testing.expect_value(t, xitdb_filter_map_row(&filter, 0), 0)
	testing.expect_value(t, xitdb_filter_map_row(&filter, 1), 2)
	testing.expect_value(t, xitdb_filter_map_row(&filter, 4), 8)
}

@(test)
test_scrollbar_100k_interior_detents_and_table_columns :: proc(t: ^testing.T) {
	// 1. 100k rows inside 20-row track (max_scroll = 99,980)
	m_top := compute_scrollbar_metrics(20, 100_000, 0)
	testing.expect_value(t, m_top.visible, true)
	testing.expect_value(t, m_top.thumb_height, 1)
	testing.expect_value(t, m_top.thumb_offset, 0)

	m_one := compute_scrollbar_metrics(20, 100_000, 1)
	testing.expect_value(t, m_one.thumb_offset, 1)

	m_almost_bot := compute_scrollbar_metrics(20, 100_000, 99_979)
	testing.expect_value(t, m_almost_bot.thumb_offset, 18)

	m_bot := compute_scrollbar_metrics(20, 100_000, 99_980)
	testing.expect_value(t, m_bot.thumb_offset, 19)

	// 2. Large thumb near bottom never overruns track_height (Ratatui #2582 invariant)
	m_large := compute_scrollbar_metrics(22, 25, 3)
	testing.expect(t, m_large.thumb_offset + m_large.thumb_height <= 22)
	testing.expect_value(t, m_large.thumb_offset + m_large.thumb_height, 22)

	// 3. Jitter-free virtual table column solver
	specs := [3]Table_Column_Spec{
		{header = "ID",   kind = .Auto_Content, min_width = 4, max_width = 10, align = .Left},
		{header = "Body", kind = .Fill,         value = 2,     min_width = 8,  align = .Left},
		{header = "Time", kind = .Fixed,        value = 6,                     align = .Right},
	}
	spans: [3]Table_Column_Span

	table_column_observe_cell(&specs[0], "42")
	resolve_table_columns(specs[:], spans[:], Rect{x = 0, y = 0, w = 30, h = 5}, gutter_width = 1, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 4)

	table_column_observe_cell(&specs[0], "id-12345")
	resolve_table_columns(specs[:], spans[:], Rect{x = 0, y = 0, w = 30, h = 5}, gutter_width = 1, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 8)

	table_column_observe_cell(&specs[0], "1")
	resolve_table_columns(specs[:], spans[:], Rect{x = 0, y = 0, w = 30, h = 5}, gutter_width = 1, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 8)
}

@(test)
test_fuzzy_command_palette_scoring_and_shortcut_formatting :: proc(t: ^testing.T) {
	inp: Input_State
	cp: Command_Palette
	command_palette_init(&cp, &inp)

	bind_key(&inp, Key_Event{code = .F6}, "cycle_pane")
	bind_key(&inp, Key_Event{code = .Rune, ch = 's', mods = {.Ctrl, .Shift}}, "save_snapshot")

	testing.expect_value(t, lookup_action_shortcut(&inp, "cycle_pane"), "F6")
	testing.expect_value(t, lookup_action_shortcut(&inp, "save_snapshot"), "Ctrl+Shift+S")

	register_command(&cp, "cycle_pane", "Cycle Focus Pane", "Window")
	register_command(&cp, "save_snapshot", "Save xitdb Snapshot", "Database")
	register_command(&cp, "inspect_btree", "Inspect B-Tree Root", "Database")

	update_palette_matches(&cp, &inp, "db root")
	testing.expect_value(t, cp.match_count, 1)
	testing.expect_value(t, cp.commands[cp.matches[0].item_idx].action, "inspect_btree")
}
