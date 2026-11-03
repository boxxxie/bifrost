package bifrost_tests

import "core:fmt"
import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications (Track 3: Virtualized xitdb Widgets & Palette)
// =============================================================================

@(private)
mock_xitdb_log_line :: proc(db_row: i32, alloc := context.temp_allocator) -> string {
	_ = alloc
	switch db_row % 4 {
	case 0:
		return fmt.tprintf("INFO [actor-%d] Heartbeat OK", db_row)
	case 1:
		return fmt.tprintf("WARN [actor-%d] High mailbox latency", db_row)
	case 2:
		return fmt.tprintf("ERROR [actor-%d] λ-worker crashed on slot", db_row)
	case 3:
		return fmt.tprintf("DEBUG [actor-%d] xitdb snapshot committed", db_row)
	}
	return ""
}

@(test)
spec_virtual_xitdb_100k_list_o1_node_budget_and_interior_detent_scrollbar :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 50, h = 22)
	defer driver_destroy(&s)

	total_rows :: i32(100_000)
	last_slice: bifrost.Virtual_Slice

	build_100k_list_ui :: proc(
		s: ^Suite_Ctx,
		total_db_rows: i32,
		show_modal: bool,
		out_slice: ^bifrost.Virtual_Slice,
	) {
		driver_begin_frame(s, bifrost.rgb(18, 22, 28))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			// Outer height = 22, Plain border (1+1) -> inner_rect.h = 20 visible rows (max_scroll = 99,980)
			if bifrost.ui_virtual_list(&s.layout_ctx, &s.screen, &s.input, "xitdb_logs", total_db_rows, {
				title          = "xitdb Logs (100k)",
				border         = .Plain,
				border_fg      = bifrost.rgb(90, 170, 250),
				scroll_step    = 1,
				scroll_padding = 1,
				fallback_rows  = 20,
			}, out_slice) {
				for row_idx := out_slice.start_row; row_idx < out_slice.end_row; row_idx += 1 {
					row_id := fmt.tprintf("log_row_%d", row_idx)
					line := fmt.tprintf("[Moment #%06d] Committed slot", row_idx)
					fg := bifrost.rgb(255, 230, 100) if row_idx == out_slice.selected_row else bifrost.rgb(190, 200, 210)
					st := bifrost.Style_Flags{.Bold, .Reverse} if row_idx == out_slice.selected_row else bifrost.Style_Flags{}
					bifrost.ui_label(&s.layout_ctx, &s.screen, row_id, line, fg, st)
				}
			}

			if show_modal {
				if bifrost.ui_modal(&s.layout_ctx, &s.screen, "compact_modal", {
					title     = "Modal Active",
					z_layer   = 20,
					width     = bifrost.fixed(26),
					height    = bifrost.fixed(5),
					border    = .Double,
					bg        = bifrost.rgb(35, 35, 55),
					border_fg = bifrost.rgb(255, 200, 0),
					backdrop  = .Dim_Screen,
				}) {
					bifrost.ui_button(&s.layout_ctx, &s.screen, "modal_ok", {label = "OK"})
				}
			}
		}
		driver_end_frame(s)
	}

	// 1. Frame 1: Initial render at scroll_offset = 0
	// O(1) node budget: 1 root + 1 virtual_list + 20 visible row leaves = 22 nodes for 100,000 rows!
	build_100k_list_ui(&s, total_rows, false, &last_slice)
	then_layout_node_count_is(&s, 22)
	testing.expect_value(t, last_slice.start_row, 0)
	testing.expect_value(t, last_slice.end_row, 20)
	// Scrollbar thumb '┃' at top cell (x = 49, y = 1) and track '│' below
	then_cell_at_is(&s, 49, 1, '┃')
	then_cell_at_is(&s, 49, 2, '│')
	then_cell_at_is(&s, 49, 20, '│')

	// 2. Scroll wheel down by 1 row (scroll_offset = 1):
	// Interior-detent clamping immediately moves thumb off top cell 0 -> cell 1 (y = 2)
	upon_mouse_scroll(&s, 5, 2, .Scroll_Down)
	build_100k_list_ui(&s, total_rows, false, &last_slice)
	then_virtual_scroll_is(&s, "xitdb_logs", expected_offset = 1, expected_selected = 0)
	then_cell_at_is(&s, 49, 1, '│')
	then_cell_at_is(&s, 49, 2, '┃')

	// 3. Jump to End (scroll_offset = 99,980, selected_row = 99,999), then scroll wheel Up 1 row to 99,979 (max_scroll - 1)
	upon_pressing_key(&s, .End)
	build_100k_list_ui(&s, total_rows, false, &last_slice)
	then_virtual_scroll_is(&s, "xitdb_logs", expected_offset = 99_980, expected_selected = 99_999)
	then_cell_at_is(&s, 49, 19, '│')
	then_cell_at_is(&s, 49, 20, '┃')

	// Scroll Up 1 row to scroll_offset = 99,979 (max_scroll - 1):
	// Thumb MUST sit at interior detent y = 19 (offset 18), leaving y = 20 as track '│'
	upon_mouse_scroll(&s, 5, 2, .Scroll_Up)
	build_100k_list_ui(&s, total_rows, false, &last_slice)
	then_virtual_scroll_is(&s, "xitdb_logs", expected_offset = 99_979, expected_selected = 99_999)
	then_cell_at_is(&s, 49, 19, '┃')
	then_cell_at_is(&s, 49, 20, '│')

	// 4. Modal opens: wheel events and Home key are blocked from scrolling the background virtual list
	build_100k_list_ui(&s, total_rows, true, &last_slice)
	upon_mouse_scroll(&s, 2, 1, .Scroll_Up)
	upon_pressing_key(&s, .Home)
	then_virtual_scroll_is(&s, "xitdb_logs", expected_offset = 99_979, expected_selected = 99_999)
}

@(test)
spec_grapheme_utf8_text_input_word_motions_and_realtime_xitdb_filter :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 48, h = 10)
	defer driver_destroy(&s)

	filter: bifrost.Xitdb_Filter
	bifrost.xitdb_filter_init(&filter, s.alloc)
	defer bifrost.xitdb_filter_destroy(&filter)

	total_rows :: i32(1_000)
	last_slice: bifrost.Virtual_Slice
	filtered_count: i32 = 0

	build_filter_ui :: proc(
		s: ^Suite_Ctx,
		filter: ^bifrost.Xitdb_Filter,
		moment_slot: i64,
		total_db_rows: i32,
		out_slice: ^bifrost.Virtual_Slice,
	) -> i32 {
		driver_begin_frame(s, bifrost.rgb(16, 20, 26))
		matched := bifrost.xitdb_filter_update(
			filter,
			&s.input,
			"search_box",
			"xitdb_logs",
			moment_slot,
			total_db_rows,
			mock_xitdb_log_line,
		)
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_text_input(&s.layout_ctx, &s.screen, &s.input, "search_box", {
				width          = bifrost.fixed(20),
				height         = bifrost.fixed(3),
				border         = .Rounded,
				title          = "Filter",
				placeholder    = "Search logs...",
				linked_list_id = "xitdb_logs",
			})
			if bifrost.ui_virtual_list(&s.layout_ctx, &s.screen, &s.input, "xitdb_logs", matched, {
				title         = "Logs",
				border        = .Plain,
				fallback_rows = 5,
			}, out_slice) {
				for v_row := out_slice.start_row; v_row < out_slice.end_row; v_row += 1 {
					real_idx := bifrost.xitdb_filter_map_row(filter, v_row)
					row_id := fmt.tprintf("row_%d", v_row)
					line := mock_xitdb_log_line(real_idx)
					fg := bifrost.rgb(255, 220, 90) if v_row == out_slice.selected_row else bifrost.rgb(190, 200, 210)
					bifrost.ui_label(&s.layout_ctx, &s.screen, row_id, line, fg)
				}
			}
		}
		driver_end_frame(s)
		return matched
	}

	// 1. Initial frame: empty filter exposes all 1,000 rows and focuses search_box
	filtered_count = build_filter_ui(&s, &filter, 1, total_rows, &last_slice)
	testing.expect_value(t, filtered_count, 1_000)
	then_focused_widget_is(&s, "search_box")
	then_cell_style_at_has(&s, 1, 1, .Reverse)

	// 2. Grapheme-cluster navigation and deletion over ZWJ emoji ("👩‍🚀"), VS16 emoji ("⌨️"), and CJK ("称")
	bifrost.set_text(&s.input, "search_box", "a👩‍🚀⌨️称b")
	upon_pressing_key(&s, .Left) // Step left over 'b'
	upon_pressing_key(&s, .Left) // Step left over '称'
	upon_pressing_key(&s, .Left) // Step left over 6-byte VS16 '⌨️' in 1 keystroke
	upon_pressing_key(&s, .Backspace) // Delete 11-byte ZWJ '👩‍🚀' in 1 Backspace
	then_text_input_value_is(&s, "search_box", "a⌨️称b")
	upon_pressing_key(&s, .Delete) // Delete 6-byte VS16 '⌨️' in 1 Delete
	then_text_input_value_is(&s, "search_box", "a称b")

	// 3. Distinct word deletion motions: Ctrl+W (whitespace) vs Alt+Backspace (word/punctuation boundary)
	bifrost.set_text(&s.input, "search_box", "hello-world foo.bar")
	upon_pressing_key(&s, .Rune, {.Ctrl}, 'w')
	then_text_input_value_is(&s, "search_box", "hello-world ")
	upon_pressing_key(&s, .Backspace, {.Alt})
	then_text_input_value_is(&s, "search_box", "hello-")
	upon_pressing_key(&s, .Backspace, {.Alt})
	then_text_input_value_is(&s, "search_box", "")

	// 4. Type multi-byte UTF-8 query "λ-work" and filter 1,000 xitdb rows -> 250 matching rows
	upon_typing_text(&s, "λ-work")
	then_text_input_value_is(&s, "search_box", "λ-work")
	filtered_count = build_filter_ui(&s, &filter, 1, total_rows, &last_slice)
	testing.expect_value(t, filtered_count, 250)
	testing.expect_value(t, bifrost.xitdb_filter_map_row(&filter, 0), 2)
	testing.expect_value(t, bifrost.xitdb_filter_map_row(&filter, 1), 6)

	// 5. Telescope-style Down arrow forwards navigation to linked "xitdb_logs" while keeping focus in "search_box"
	upon_pressing_key(&s, .Down)
	upon_pressing_key(&s, .Down)
	then_focused_widget_is(&s, "search_box")
	then_virtual_scroll_is(&s, "xitdb_logs", expected_offset = 0, expected_selected = 2)

	// 6. CJK 2-column display-width horizontal scrolling inside the 18-column inner viewport
	bifrost.set_text(&s.input, "search_box", "称号コンピュータABCD")
	_ = build_filter_ui(&s, &filter, 1, total_rows, &last_slice)
	// Right border at x = 19, y = 1 must remain intact ('│'), never overwritten by wide CJK bleed
	then_cell_at_is(&s, 19, 1, '│', 1)
}

@(test)
spec_jitter_free_virtual_table_columns_and_box_junction_merging :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 40, h = 10)
	defer driver_destroy(&s)

	specs := [3]bifrost.Table_Column_Spec{
		{header = "ID",     kind = .Auto_Content, min_width = 4, max_width = 12, align = .Left},
		{header = "Name",   kind = .Fill,         value = 1,     min_width = 6,  align = .Left},
		{header = "Status", kind = .Fixed,        value = 8,                     align = .Right},
	}
	spans: [3]bifrost.Table_Column_Span

	// Page 1: short ID "101" -> clamps to min_width = 4
	bifrost.table_column_observe_cell(&specs[0], "101")
	bifrost.resolve_table_columns(specs[:], spans[:], {x = 0, y = 0, w = 40, h = 10}, gutter_width = 2, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 4)

	// Page 2: wider ID "xit-98412" -> expands monotonically to 9
	bifrost.table_column_observe_cell(&specs[0], "xit-98412")
	bifrost.resolve_table_columns(specs[:], spans[:], {x = 0, y = 0, w = 40, h = 10}, gutter_width = 2, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 9)

	// Page 3: short ID "7" -> stays at 9 (zero horizontal shrinkage jitter)
	bifrost.table_column_observe_cell(&specs[0], "7")
	bifrost.resolve_table_columns(specs[:], spans[:], {x = 0, y = 0, w = 40, h = 10}, gutter_width = 2, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 9)

	// Box-drawing junction merging on Screen surface
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "box", {width = bifrost.fixed(10), height = bifrost.fixed(5), border = .Rounded}) {
			bifrost.set_paint(scr, "box", {fg = bifrost.rgb(200, 200, 200)})
		}
	})
	// Merge vertical divider at x = 5 with top (y = 0) and bottom (y = 4) horizontal border cells
	bifrost.surface_merge_box_cell(&s.screen, 5, 0, '│', bifrost.ROUNDED_BORDER, bifrost.rgb(200, 200, 200))
	bifrost.surface_merge_box_cell(&s.screen, 5, 4, '│', bifrost.ROUNDED_BORDER, bifrost.rgb(200, 200, 200))
	// Merge horizontal divider at y = 2 with left (x = 0), middle (x = 5), and right (x = 9) vertical cells
	bifrost.surface_merge_box_cell(&s.screen, 0, 2, '─', bifrost.ROUNDED_BORDER, bifrost.rgb(200, 200, 200))
	bifrost.surface_merge_box_cell(&s.screen, 9, 2, '─', bifrost.ROUNDED_BORDER, bifrost.rgb(200, 200, 200))
	bifrost.surface_merge_box_cell(&s.screen, 5, 2, '│', bifrost.ROUNDED_BORDER, bifrost.rgb(200, 200, 200))
	bifrost.surface_merge_box_cell(&s.screen, 5, 2, '─', bifrost.ROUNDED_BORDER, bifrost.rgb(200, 200, 200))

	then_cell_at_is(&s, 5, 0, '┬')
	then_cell_at_is(&s, 5, 4, '┴')
	then_cell_at_is(&s, 0, 2, '├')
	then_cell_at_is(&s, 9, 2, '┤')
	then_cell_at_is(&s, 5, 2, '┼')
}

@(test)
spec_interactive_splitter_same_frame_resize_and_three_tier_keymap :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 20)
	defer driver_destroy(&s)

	bifrost.bind_key(&s.input, {code = .Rune, ch = 'q'}, "quit_app", .Root_And_Scopes)
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'p', mods = {.Ctrl}}, "open_palette", .Root_And_Scopes, "", {.Allow_In_Text_Input})
	bifrost.bind_splitter_key(&s.input, {code = .Left, mods = {.Ctrl}}, "main_split", -5)
	bifrost.bind_splitter_key(&s.input, {code = .Right, mods = {.Ctrl}}, "main_split", +5)
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'y'}, "modal_confirmed", .Scope_Only, "confirm_modal")
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'q', mods = {.Ctrl}}, "force_quit", .Global_Always, "", {.Allow_In_Text_Input})

	build_split_ui :: proc(s: ^Suite_Ctx, show_modal: bool, events: ..bifrost.Input_Event) {
		driver_begin_frame(s, bifrost.rgb(16, 20, 26))
		sidebar_w := bifrost.get_split_size(&s.input, "main_split", default_size = 20, min_size = 12, max_size = 36)
		if bifrost.container(&s.layout_ctx, "workspace", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(&s.layout_ctx, "sidebar", {
				dir         = .Column,
				width       = bifrost.fixed(sidebar_w),
				height      = bifrost.grow(1),
				border      = .Plain,
				focus_scope = true,
			}) {
				bifrost.ui_text_input(&s.layout_ctx, &s.screen, &s.input, "search_box", {
					width       = bifrost.grow(1),
					height      = bifrost.fixed(3),
					border      = .Rounded,
					title       = "Filter",
					placeholder = "Type query...",
				})
			}

			bifrost.ui_splitter(&s.layout_ctx, &s.screen, &s.input, "main_split", {
				dir          = .Row,
				default_size = 20,
				min_size     = 12,
				max_size     = 36,
				step         = 2,
			})

			if bifrost.container(&s.layout_ctx, "main_pane", {
				dir         = .Column,
				width       = bifrost.grow(1),
				height      = bifrost.grow(1),
				border      = .Plain,
				focus_scope = true,
			}) {
				bifrost.ui_button(&s.layout_ctx, &s.screen, "run_btn", {label = "Run Query"})
			}

			if show_modal {
				if bifrost.ui_modal(&s.layout_ctx, &s.screen, "confirm_modal", {
					title   = "Confirm Action",
					z_layer = 20,
					width   = bifrost.fixed(28),
					height  = bifrost.fixed(6),
					border  = .Double,
				}) {
					bifrost.ui_button(&s.layout_ctx, &s.screen, "modal_ok", {label = "OK (y)"})
				}
			}
		}
		driver_end_frame(s, ..events)
	}

	// 1. Frame 1: Initial split layout (20 + 1 + 59 = 80) and idle '│' splitter glyph
	build_split_ui(&s, false)
	then_node_rect_is(&s, "sidebar", {x = 0, y = 0, w = 20, h = 20})
	then_node_rect_is(&s, "main_split", {x = 20, y = 0, w = 1, h = 20})
	then_node_rect_is(&s, "main_pane", {x = 21, y = 0, w = 59, h = 20})
	then_cell_at_is(&s, 20, 5, '│')

	// 2. Frame 2: Same-frame mouse drag from x = 20 to x = 28 -> immediately resizes panes and upgrades bar to '┃'
	build_split_ui(
		&s,
		false,
		bifrost.Mouse_Event{x = 20, y = 5, action = .Press, button = .Left},
		bifrost.Mouse_Event{x = 28, y = 5, action = .Move, button = .Left},
	)
	then_split_size_is(&s, "main_split", 28)
	then_node_rect_is(&s, "sidebar", {x = 0, y = 0, w = 28, h = 20})
	then_node_rect_is(&s, "main_split", {x = 28, y = 0, w = 1, h = 20})
	then_node_rect_is(&s, "main_pane", {x = 29, y = 0, w = 51, h = 20})
	then_cell_at_is(&s, 28, 5, '┃')

	// Drag past max_size = 36 (to x = 65) and release -> clamped to 36
	upon_input_events(
		&s,
		bifrost.Mouse_Event{x = 65, y = 5, action = .Move, button = .Left},
		bifrost.Mouse_Event{x = 65, y = 5, action = .Release, button = .Left},
	)
	then_split_size_is(&s, "main_split", 36)

	// 3. Frame 3: Text-input shielding vs .Allow_In_Text_Input global chords
	build_split_ui(&s, false)
	upon_mouse_click(&s, 3, 2)
	then_focused_widget_is(&s, "search_box")

	// Typing 'q' inside search_box inserts 'q' and does NOT fire "quit_app"
	upon_pressing_key(&s, .Rune, {}, 'q')
	then_text_input_value_is(&s, "search_box", "q")
	then_action_triggered_is(&s, "quit_app", false)

	// Pressing Ctrl+Left shrinks "main_split" from 36 -> 31 while keeping focus in "search_box"
	upon_pressing_key(&s, .Left, {.Ctrl})
	then_split_size_is(&s, "main_split", 31)
	then_focused_widget_is(&s, "search_box")

	// Pressing Ctrl+P fires "open_palette" even inside search_box
	upon_pressing_key(&s, .Rune, {.Ctrl}, 'p')
	then_action_triggered_is(&s, "open_palette", true)

	// 4. Frame 4: Modal capture blocks Root_And_Scopes & background splitters, allows Scope_Only & Global_Always
	build_split_ui(&s, true)
	upon_pressing_key(&s, .Left, {.Ctrl})
	then_split_size_is(&s, "main_split", 31)

	upon_pressing_key(&s, .Rune, {}, 'y')
	then_action_triggered_is(&s, "modal_confirmed", true)

	upon_pressing_key(&s, .Rune, {.Ctrl}, 'q')
	then_action_triggered_is(&s, "force_quit", true)
}

@(test)
spec_ctrl_p_fuzzy_command_palette_and_shortcut_discovery :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	palette: bifrost.Command_Palette
	bifrost.command_palette_init(&palette, &s.input)

	bifrost.bind_key(&s.input, {code = .Rune, ch = 'k', mods = {.Ctrl}}, "compact_xitdb", .Root_And_Scopes)
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'r', mods = {.Ctrl}}, "rollback_moment", .Root_And_Scopes)
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'q'}, "quit_app", .Root_And_Scopes)

	bifrost.register_command(&palette, "compact_xitdb", "Compact History Buffer", "xitdb")
	bifrost.register_command(&palette, "rollback_moment", "Rollback to Previous Slot", "xitdb")
	bifrost.register_command(&palette, "clear_filter", "Clear Log Search Filter", "View")
	bifrost.register_command(&palette, "quit_app", "Quit Application", "App")

	testing.expect_value(t, bifrost.lookup_action_shortcut(&s.input, "compact_xitdb"), "Ctrl+K")
	testing.expect_value(t, bifrost.lookup_action_shortcut(&s.input, "rollback_moment"), "Ctrl+R")

	build_palette_ui :: proc(s: ^Suite_Ctx, palette: ^bifrost.Command_Palette) {
		driver_begin_frame(s, bifrost.rgb(16, 20, 26))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1), focus_scope = true}) {
			bifrost.ui_button(&s.layout_ctx, &s.screen, "workspace_btn", {label = "Query xitdb"})
			bifrost.ui_command_palette(&s.layout_ctx, &s.screen, &s.input, palette)
		}
		driver_end_frame(s)
		bifrost.update_command_palette(palette, &s.input)
	}

	// 1. Frame 1: Palette closed, focus on workspace_btn
	build_palette_ui(&s, &palette)
	testing.expect(t, !palette.is_open)
	then_focused_widget_is(&s, "workspace_btn")

	// 2. Press Ctrl+P -> opens palette and traps focus in "cmd_palette_input"
	upon_pressing_key(&s, .Rune, {.Ctrl}, 'p')
	bifrost.update_command_palette(&palette, &s.input)
	testing.expect(t, palette.is_open)

	build_palette_ui(&s, &palette)
	then_focused_widget_is(&s, "cmd_palette_input")
	testing.expect_value(t, palette.match_count, 4)

	// 3. Type multi-token fuzzy query "xit slot" -> ranks "Rollback to Previous Slot" #1
	upon_typing_text(&s, "xit slot")
	bifrost.update_command_palette(&palette, &s.input)
	build_palette_ui(&s, &palette)

	then_text_input_value_is(&s, "cmd_palette_input", "xit slot")
	testing.expect_value(t, palette.match_count, 1)
	testing.expect_value(t, palette.commands[palette.matches[0].item_idx].action, "rollback_moment")

	// 4. Press Enter -> dispatches "rollback_moment", closes palette, and restores focus to "workspace_btn"
	upon_pressing_key(&s, .Enter)
	bifrost.update_command_palette(&palette, &s.input)
	testing.expect(t, !palette.is_open)
	then_action_triggered_is(&s, "rollback_moment", true)

	build_palette_ui(&s, &palette)
	then_focused_widget_is(&s, "workspace_btn")
}
