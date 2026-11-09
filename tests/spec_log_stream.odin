package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Track 20: Auto-Scrolling Log Stream Viewer, Table Controls & OSC 8 Links
// =============================================================================

@(private="file")
s_log_entries: [dynamic]bifrost.Log_Entry

@(private="file")
s_log_state: bifrost.Log_Viewer_State

@(private="file")
s_sort_state: bifrost.Table_Sort_State

@(private="file")
s_sort_changed: bool

@(private="file")
s_header_specs: [2]bifrost.Table_Column_Spec

@(private="file")
s_table_specs: [2]bifrost.Table_Column_Spec

@(test)
@(scenario)
spec_log_viewer_auto_scroll_pinning_and_manual_unpin :: proc(t: ^testing.T) {
	_ = scenario(t, w = 55, h = 10)

	s_log_state = bifrost.Log_Viewer_State{is_following = true}
	s_log_entries = make([dynamic]bifrost.Log_Entry, context.allocator)
	defer delete(s_log_entries)

	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:01", level = .Info,  target = "net", message = "Connection established"})
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:02", level = .Debug, target = "msg", message = "Handshake packet parsed"})
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:03", level = .Warn,  target = "mem", message = "Buffer pool above 75%"})

	build_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			_ = bifrost.ui_log_viewer(ctx, scr, &sc.input, "log_view", s_log_entries[:], &s_log_state, bifrost.Log_Viewer_Config{
				title           = "Activity Stream",
				show_timestamps = true,
				show_badge      = true,
				fallback_rows   = 5,
			})
		}
	}

	// 1. Initial render: following is true, entries visible
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, true)
	then.vt_contains_text("Connection established", true)
	then.vt_contains_text("Buffer pool above 75%", true)

	// 2. Add 4 more entries (total 7): following automatically keeps pinned at bottom
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:04", level = .Info,  target = "db",  message = "Snapshot flushed to disk"})
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:05", level = .Error, target = "rpc", message = "Endpoint timed out (504)"})
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:06", level = .Info,  target = "sub", message = "Worker node joined cluster"})
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:07", level = .Info,  target = "net", message = "Heartbeat acknowledged"})

	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, true)
	then.vt_contains_text("Heartbeat acknowledged", true)
	then.focused_widget_is("log_view")

	// 3. User navigates upward with Up key: unpins auto-follow
	upon.pressing_key(.Up)
	upon.pressing_key(.Up)
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, false)

	// 4. New entry arrives while unpinned: unread count increments and pill badge appears
	append(&s_log_entries, bifrost.Log_Entry{timestamp = "10:00:08", level = .Warn, target = "mem", message = "Garbage collection cycle took 12ms"})
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, false)
	then.log_viewer_unread_is(s_log_state.new_unread_count, 1)
	then.vt_contains_text("Follow", true)

	// 4b. User activates the floating "Follow" badge via keyboard: auto-follow re-engages, unread count resets to 0, and focus returns to log_view
	bifrost.request_focus(&current_scenario().input, "log_view_badge")
	upon.rendering_frame(build_ui)
	then.focused_widget_is("log_view_badge")
	upon.pressing_key(.Enter)
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, true)
	then.log_viewer_unread_is(s_log_state.new_unread_count, 0)
	then.focused_widget_is("log_view")

	// 5. Severity filtering pre-filters entries before virtual list slicing (no blank rows or inflated total)
	s_log_state = bifrost.Log_Viewer_State{is_following = true, filter_level = .Error}
	upon.rendering_frame(build_ui)
	then.vt_contains_text("Endpoint timed out (504)", true)
	then.vt_contains_text("Heartbeat acknowledged", false)

	// 6. Frame 0 -> Frame 1 layout expansion where solved viewport height > fallback_rows and total_entries > fallback_rows:
	//    is_following must remain true across Frame 1 without false unpinning
	s_log_state = bifrost.Log_Viewer_State{is_following = true, filter_level = .Debug}
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, true)
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, true)

	// 7. Shrinking / clearing entries preserves is_following = true
	resize(&s_log_entries, 2)
	upon.rendering_frame(build_ui)
	then.log_viewer_following_is(s_log_state.is_following, true)
}

@(test)
@(scenario)
spec_table_column_header_sorting_cycle :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 8)

	s_sort_state = bifrost.Table_Sort_State{column = 0, direction = .None}
	s_header_specs = [2]bifrost.Table_Column_Spec{
		{header = "Package", kind = .Fixed, fixed_width = 18},
		{header = "Status",  kind = .Fixed, fixed_width = 14},
	}

	build_header_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			s_sort_changed = bifrost.ui_table_header(ctx, scr, &sc.input, "tbl_hdr", s_header_specs[:], &s_sort_state, bifrost.Table_Header_Config{
				allow_sort = true,
			})
		}
	}

	// 1. Initial mount: None direction, plain header labels visible
	upon.rendering_frame(build_header_ui)
	then.table_sort_is(s_sort_state.column, s_sort_state.direction, 0, .None)
	then.vt_contains_text("Package", true)
	then.vt_contains_text("Status", true)

	// 2. Click Package column (col 0): cycles to Asc (▲)
	upon.mouse_click(4, 0)
	upon.rendering_frame(build_header_ui)
	then.table_sort_is(s_sort_state.column, s_sort_state.direction, 0, .Asc)
	then.vt_contains_text("Package ▲", true)

	// 3. Click Package column again: cycles to Desc (▼)
	upon.mouse_click(4, 0)
	upon.rendering_frame(build_header_ui)
	then.table_sort_is(s_sort_state.column, s_sort_state.direction, 0, .Desc)
	then.vt_contains_text("Package ▼", true)

	// 4. Click Package column again: cycles back to None
	upon.mouse_click(4, 0)
	upon.rendering_frame(build_header_ui)
	then.table_sort_is(s_sort_state.column, s_sort_state.direction, 0, .None)
	then.vt_contains_text("Package", true)
}

@(test)
@(scenario)
spec_table_column_divider_drag_resize :: proc(t: ^testing.T) {
	_ = scenario(t, w = 60, h = 8)

	s_table_specs[0] = bifrost.Table_Column_Spec{header = "Service", kind = .Fixed, fixed_width = 16, min_width = 8, max_width = 30}
	s_table_specs[1] = bifrost.Table_Column_Spec{header = "Latency", kind = .Fixed, fixed_width = 14, min_width = 6, max_width = 25}

	build_resizable_header :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			_ = bifrost.ui_table_header(ctx, scr, &sc.input, "tbl_res", s_table_specs[:], nil, bifrost.Table_Header_Config{
				allow_resize = true,
			})
		}
	}

	// 1. Initial mount: width is 16
	upon.rendering_frame(build_resizable_header)
	then.column_width_is(s_table_specs[0].fixed_width, 16)
	then.vt_contains_text("Service", true)

	// 2. Drag the divider handle at x=16 to x=22 (+6 cells)
	upon.mouse_press(16, 0)
	upon.mouse_drag(22, 0)
	upon.mouse_release(22, 0)
	upon.rendering_frame(build_resizable_header)
	then.column_width_is(s_table_specs[0].fixed_width, 22)
}

@(test)
@(scenario)
spec_osc8_terminal_hyperlink_emission :: proc(t: ^testing.T) {
	_ = scenario(t, w = 40, h = 5)

	build_link_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_link(ctx, scr, "lnk_repo", "Bifrost Engine", "https://github.com/odin-lang/bifrost")
		}
	}

	// 1. Render frame: screen contains link text, ANSI output contains OSC 8 sequence
	upon.rendering_frame(build_link_ui)
	then.vt_contains_text("Bifrost Engine", true)
	then.ansi_contains_osc8_link("https://github.com/odin-lang/bifrost", "Bifrost Engine")
}
