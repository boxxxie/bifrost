package bifrost_tests

import "core:strings"
import "core:testing"
import "../bifrost"
import actor "../deps/sleipnir/actor"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// Layer 2: Domain-Specific Language (Composable BDD Steps for Layout & Render)
// =============================================================================

given_terminal :: proc(s: ^Suite_Ctx, t: ^testing.T, w: i32 = 80, h: i32 = 24) {
	driver_init(s, t, w, h)
}

upon_rendering_frame :: proc(s: ^Suite_Ctx, build_ui: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen), default_bg: bifrost.Color = {}) {
	driver_begin_frame(s, default_bg)
	build_ui(&s.layout_ctx, &s.screen)
	driver_end_frame(s)
}

upon_rendering_frame_with_events :: proc(
	s: ^Suite_Ctx,
	build_ui: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen),
	events: ..bifrost.Input_Event,
) {
	driver_begin_frame(s)
	build_ui(&s.layout_ctx, &s.screen)
	driver_end_frame(s, ..events)
}

upon_dimming_rect_backdrop :: proc(s: ^Suite_Ctx, rect: bifrost.Rect) {
	bifrost.dim_rect_backdrop(&s.screen, rect)
}

then_node_rect_is :: proc(s: ^Suite_Ctx, id: string, expected: bifrost.Rect, loc := #caller_location) {
	rect, ok := bifrost.get_rect(&s.layout_ctx, id)
	testing.expect(s.t, ok, "Expected layout node to exist", loc = loc)
	testing.expect_value(s.t, rect, expected, loc = loc)
}

then_node_inner_rect_is :: proc(s: ^Suite_Ctx, id: string, expected: bifrost.Rect, loc := #caller_location) {
	rect, ok := bifrost.get_inner_rect(&s.layout_ctx, id)
	testing.expect(s.t, ok, "Expected layout node to exist", loc = loc)
	testing.expect_value(s.t, rect, expected, loc = loc)
}

then_cell_at_is :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	expected_ch: rune,
	expected_width: u8 = 1,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	cell := s.screen.back[idx]
	testing.expect_value(s.t, cell.ch, expected_ch, loc = loc)
	testing.expect_value(s.t, cell.width, expected_width, loc = loc)
}

then_cell_colors_at_are :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	expected_fg: bifrost.Color,
	expected_bg: bifrost.Color,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	cell := s.screen.back[idx]
	testing.expect_value(s.t, cell.fg, expected_fg, loc = loc)
	testing.expect_value(s.t, cell.bg, expected_bg, loc = loc)
}

then_cell_style_at_has :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	flag: bifrost.Style_Flag,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	cell := s.screen.back[idx]
	testing.expect(s.t, flag in cell.style, "Expected style flag on cell", loc = loc)
}

then_diff_bytes_equal :: proc(s: ^Suite_Ctx, expected_bytes: int, loc := #caller_location) {
	testing.expect_value(s.t, s.last_diff_bytes, expected_bytes, loc = loc)
}

then_diff_ansi_equals :: proc(s: ^Suite_Ctx, expected_ansi: string, loc := #caller_location) {
	testing.expect_value(s.t, s.last_ansi_str, expected_ansi, loc = loc)
}

then_diff_ansi_contains :: proc(s: ^Suite_Ctx, substr: string, loc := #caller_location) {
	testing.expect(s.t, strings.contains(s.last_ansi_str, substr), "Expected ANSI diff to contain substring", loc = loc)
}

then_vt_contains_text :: proc(s: ^Suite_Ctx, needle: string, expected: bool = true, loc := #caller_location) {
	found := false
	w := int(s.vt_w)
	h := int(s.vt_h)
	for r := 0; r < h; r += 1 {
		b := strings.builder_make(0, w, context.temp_allocator)
		for x := 0; x < w; x += 1 {
			ch := s.vt_cells[r * w + x].ch
			if ch != 0 {
				strings.write_rune(&b, ch)
			}
		}
		if strings.contains(strings.to_string(b), needle) {
			found = true
			break
		}
	}
	testing.expect_value(s.t, found, expected, loc = loc)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Focus, 3-Phase Input Routing & Hit-Testing)
// =============================================================================

given_focused_widget :: proc(s: ^Suite_Ctx, id: string) {
	s.input.focused_id = bifrost.hash_id(id)
}

given_widget_consumes_at :: proc(s: ^Suite_Ctx, id: string, phase: bifrost.Event_Phase) {
	s.consume_id = bifrost.hash_id(id)
	s.consume_phase = phase
	s.has_consumer = true
}

upon_input_events :: proc(s: ^Suite_Ctx, events: ..bifrost.Input_Event) {
	clear(&s.dispatch_steps)
	s.input.event_handler = driver_event_recorder
	s.input.event_userdata = s
	bifrost.resolve_input(&s.input, &s.layout_ctx, ..events)
	bifrost.state_store_sync_from_layout(&s.state_store, &s.layout_ctx, &s.input)
}

upon_pressing_key :: proc(s: ^Suite_Ctx, code: bifrost.Key_Code, mods: bifrost.Mod_Flags = {}, ch: rune = 0) {
	upon_input_events(s, bifrost.Key_Event{code = code, ch = ch, mods = mods})
}

upon_pressing_key_rune :: proc(s: ^Suite_Ctx, ch: rune, mods: bifrost.Mod_Flags = {}) {
	upon_pressing_key(s, .Rune, mods, ch)
}

upon_mouse_move :: proc(s: ^Suite_Ctx, x, y: i32) {
	upon_input_events(s, bifrost.Mouse_Event{x = x, y = y, action = .Move, button = .None})
}

upon_mouse_press :: proc(s: ^Suite_Ctx, x, y: i32, button: bifrost.Mouse_Button = .Left) {
	upon_input_events(s, bifrost.Mouse_Event{x = x, y = y, action = .Press, button = button})
}

upon_mouse_drag :: proc(s: ^Suite_Ctx, x, y: i32, button: bifrost.Mouse_Button = .Left) {
	upon_input_events(s, bifrost.Mouse_Event{x = x, y = y, action = .Drag, button = button})
}

upon_mouse_release :: proc(s: ^Suite_Ctx, x, y: i32, button: bifrost.Mouse_Button = .Left) {
	upon_input_events(s, bifrost.Mouse_Event{x = x, y = y, action = .Release, button = button})
}

upon_mouse_click :: proc(s: ^Suite_Ctx, x, y: i32, button: bifrost.Mouse_Button = .Left) {
	upon_input_events(
		s,
		bifrost.Mouse_Event{x = x, y = y, action = .Press, button = button},
		bifrost.Mouse_Event{x = x, y = y, action = .Release, button = button},
	)
}

upon_mouse_scroll :: proc(s: ^Suite_Ctx, x, y: i32, action: bifrost.Mouse_Action) {
	upon_input_events(s, bifrost.Mouse_Event{x = x, y = y, action = action, button = .None})
}

then_focused_widget_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	if len(id) == 0 {
		testing.expect_value(s.t, s.input.focused_id, u64(0), loc = loc)
	} else {
		testing.expect(s.t, bifrost.is_focused(&s.input, id), "Expected widget to have focus", loc = loc)
	}
}

then_editing_widget_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	if len(id) == 0 {
		testing.expect_value(s.t, s.input.editing_id, u64(0), loc = loc)
	} else {
		testing.expect(s.t, bifrost.is_editing(&s.input, id), "Expected widget to own editing_id", loc = loc)
	}
}

then_scope_selected_is :: proc(s: ^Suite_Ctx, id: string, expected: bool, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.is_scope_selected(&s.input, id), expected, loc = loc)
}

then_hovered_widget_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	if len(id) == 0 {
		testing.expect_value(s.t, s.input.hovered_id, u64(0), loc = loc)
	} else {
		testing.expect(s.t, bifrost.is_hovered(&s.input, id), "Expected widget to be hovered", loc = loc)
	}
}

then_active_press_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	expected := bifrost.hash_id(id) if len(id) > 0 else u64(0)
	testing.expect_value(s.t, s.input.active_press_id, expected, loc = loc)
}

then_activated_widget_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	expected := bifrost.hash_id(id) if len(id) > 0 else u64(0)
	testing.expect_value(s.t, s.input.activated_id, expected, loc = loc)
}

then_drag_delta_is :: proc(s: ^Suite_Ctx, dx, dy: i32, loc := #caller_location) {
	testing.expect_value(s.t, s.input.drag_delta, [2]i32{dx, dy}, loc = loc)
}

then_modal_dismissed_is :: proc(s: ^Suite_Ctx, modal_id: string, expected: bool, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.was_modal_dismissed(&s.input, modal_id), expected, loc = loc)
}

then_hover_transition_is :: proc(
	s: ^Suite_Ctx,
	hovered_id: string,
	entered_id: string,
	left_id: string,
	loc := #caller_location,
) {
	then_hovered_widget_is(s, hovered_id, loc)
	if len(entered_id) > 0 {
		testing.expect(s.t, bifrost.did_mouse_enter(&s.input, entered_id), "Expected did_mouse_enter", loc = loc)
	}
	if len(left_id) > 0 {
		testing.expect(s.t, bifrost.did_mouse_leave(&s.input, left_id), "Expected did_mouse_leave", loc = loc)
	}
}

then_dispatch_steps_are :: proc(
	s: ^Suite_Ctx,
	expected: []bifrost.Dispatch_Step,
	loc := #caller_location,
) {
	testing.expect_value(s.t, len(s.dispatch_steps), len(expected), loc = loc)
	if len(s.dispatch_steps) == len(expected) {
		for i in 0 ..< len(expected) {
			testing.expect_value(s.t, s.dispatch_steps[i].id, expected[i].id, loc = loc)
			testing.expect_value(s.t, s.dispatch_steps[i].phase, expected[i].phase, loc = loc)
		}
	}
}

then_node_clip_is :: proc(s: ^Suite_Ctx, id: string, expected: bifrost.Rect, loc := #caller_location) {
	clip, ok := bifrost.get_node_clip(&s.layout_ctx, id)
	testing.expect(s.t, ok, "Expected layout node to exist", loc = loc)
	testing.expect_value(s.t, clip, expected, loc = loc)
}

then_persisted_scroll_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	offset_y, max_y: i32,
	loc := #caller_location,
) {
	entry, ok := s.state_store.scroll_states[bifrost.hash_id(id)]
	testing.expect(s.t, ok, "Expected scroll state in Widget_State_Store", loc = loc)
	if ok {
		testing.expect_value(s.t, entry.scroll_offset[1], offset_y, loc = loc)
		testing.expect_value(s.t, entry.scroll_max[1], max_y, loc = loc)
	}
}

then_state_store_contains :: proc(s: ^Suite_Ctx, id: string, expected: bool, loc := #caller_location) {
	_, ok := s.state_store.scroll_states[bifrost.hash_id(id)]
	testing.expect_value(s.t, ok, expected, loc = loc)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 3: Virtual Lists, Text Input, Splitters & Palette)
// =============================================================================

upon_typing_text :: proc(s: ^Suite_Ctx, text: string) {
	events := make([dynamic]bifrost.Input_Event, 0, len(text), context.temp_allocator)
	for ch in text {
		if ch == ' ' {
			append(&events, bifrost.Key_Event{code = .Space, ch = ' '})
		} else {
			append(&events, bifrost.Key_Event{code = .Rune, ch = ch})
		}
	}
	upon_input_events(s, ..events[:])
}

then_layout_node_count_is :: proc(s: ^Suite_Ctx, expected: int, loc := #caller_location) {
	testing.expect_value(s.t, len(s.layout_ctx.nodes), expected, loc = loc)
}

then_virtual_scroll_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_offset: i32,
	expected_selected: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_scroll_offset(&s.input, id), expected_offset, loc = loc)
	testing.expect_value(s.t, bifrost.get_selected_row(&s.input, id), expected_selected, loc = loc)
}

then_text_input_value_is :: proc(s: ^Suite_Ctx, id: string, expected: string, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.get_text(&s.input, id), expected, loc = loc)
}

then_split_size_is :: proc(s: ^Suite_Ctx, id: string, expected: i32, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.get_split_size(&s.input, id), expected, loc = loc)
}

then_action_triggered_is :: proc(s: ^Suite_Ctx, action: string, expected: bool, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.was_action_triggered(&s.input, action), expected, loc = loc)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 4: ANSI / Kitty / Mouse SGR Parser)
// =============================================================================

given_clean_input_stream :: proc(s: ^Suite_Ctx) {
	bifrost.input_stream_reset(&s.stream_reader)
	clear(&s.parsed_events)
	s.last_parse_stat = .Ok
	s.last_consumed   = 0
}

upon_parsing_raw_slice :: proc(s: ^Suite_Ctx, raw: string, is_timeout: bool = false) {
	ev, n, status := bifrost.parse_ansi_input(transmute([]byte)raw, is_timeout)
	s.last_parse_stat = status
	s.last_consumed   = n
	if status == .Ok {
		append(&s.parsed_events, ev)
	}
}

upon_feeding_stream_chunk :: proc(s: ^Suite_Ctx, chunk: string, is_timeout: bool = false) {
	bifrost.input_stream_feed_string(&s.stream_reader, chunk)
	for {
		ev, status := bifrost.input_stream_next(&s.stream_reader, is_timeout)
		s.last_parse_stat = status
		if status == .Ok {
			append(&s.parsed_events, ev)
			if is_timeout && s.stream_reader.head >= s.stream_reader.len {
				break
			}
			continue
		}
		break
	}
}

upon_feeding_byte_by_byte :: proc(s: ^Suite_Ctx, stream: string) {
	for i := 0; i < len(stream); i += 1 {
		upon_feeding_stream_chunk(s, stream[i : i + 1], false)
	}
}

then_parse_status_is :: proc(
	s: ^Suite_Ctx,
	expected_status: bifrost.Parse_Status,
	expected_consumed: int = -1,
	loc := #caller_location,
) {
	testing.expect_value(s.t, s.last_parse_stat, expected_status, loc = loc)
	if expected_consumed >= 0 {
		testing.expect_value(s.t, s.last_consumed, expected_consumed, loc = loc)
	}
}

then_parsed_event_count_is :: proc(s: ^Suite_Ctx, expected: int, loc := #caller_location) {
	testing.expect_value(s.t, len(s.parsed_events), expected, loc = loc)
}

then_parsed_key_at_is :: proc(
	s: ^Suite_Ctx,
	idx: int,
	expected_code: bifrost.Key_Code,
	expected_mods: bifrost.Mod_Flags = {},
	expected_ch: rune = 0,
	expected_action: bifrost.Key_Action = .Press,
	loc := #caller_location,
) {
	testing.expect(s.t, idx >= 0 && idx < len(s.parsed_events), "Event index out of bounds", loc = loc)
	if idx >= 0 && idx < len(s.parsed_events) {
		key, ok := s.parsed_events[idx].(bifrost.Key_Event)
		testing.expect(s.t, ok, "Expected Key_Event at index", loc = loc)
		if ok {
			testing.expect_value(s.t, key.code, expected_code, loc = loc)
			testing.expect_value(s.t, key.mods, expected_mods, loc = loc)
			testing.expect_value(s.t, key.action, expected_action, loc = loc)
			if expected_ch != 0 {
				testing.expect_value(s.t, key.ch, expected_ch, loc = loc)
			}
		}
	}
}

then_parsed_kitty_key_at_is :: proc(
	s: ^Suite_Ctx,
	idx: int,
	expected_cp: rune,
	expected_shifted: rune,
	expected_base: rune,
	expected_mods: bifrost.Mod_Flags,
	expected_action: bifrost.Key_Action,
	expected_text: string,
	loc := #caller_location,
) {
	testing.expect(s.t, idx >= 0 && idx < len(s.parsed_events), "Event index out of bounds", loc = loc)
	if idx >= 0 && idx < len(s.parsed_events) {
		key, ok := s.parsed_events[idx].(bifrost.Key_Event)
		testing.expect(s.t, ok, "Expected Key_Event at index", loc = loc)
		if ok {
			testing.expect_value(s.t, key.codepoint, expected_cp, loc = loc)
			testing.expect_value(s.t, key.shifted_codepoint, expected_shifted, loc = loc)
			testing.expect_value(s.t, key.base_layout_codepoint, expected_base, loc = loc)
			testing.expect_value(s.t, key.mods, expected_mods, loc = loc)
			testing.expect_value(s.t, key.action, expected_action, loc = loc)
			testing.expect_value(s.t, bifrost.key_event_text(&key), expected_text, loc = loc)
		}
	}
}

then_parsed_mouse_at_is :: proc(
	s: ^Suite_Ctx,
	idx: int,
	expected_col: i16,
	expected_row: i16,
	expected_button: bifrost.Mouse_Button,
	expected_action: bifrost.Mouse_Action,
	expected_mods: bifrost.Mod_Flags = {},
	loc := #caller_location,
) {
	testing.expect(s.t, idx >= 0 && idx < len(s.parsed_events), "Event index out of bounds", loc = loc)
	if idx >= 0 && idx < len(s.parsed_events) {
		mouse, ok := s.parsed_events[idx].(bifrost.Mouse_Event)
		testing.expect(s.t, ok, "Expected Mouse_Event at index", loc = loc)
		if ok {
			testing.expect_value(s.t, mouse.col, expected_col, loc = loc)
			testing.expect_value(s.t, mouse.row, expected_row, loc = loc)
			testing.expect_value(s.t, mouse.x, i32(expected_col), loc = loc)
			testing.expect_value(s.t, mouse.y, i32(expected_row), loc = loc)
			testing.expect_value(s.t, mouse.button, expected_button, loc = loc)
			testing.expect_value(s.t, mouse.action, expected_action, loc = loc)
			testing.expect_value(s.t, mouse.mods, expected_mods, loc = loc)
		}
	}
}

then_parsed_paste_at_is :: proc(
	s: ^Suite_Ctx,
	idx: int,
	expected_text: string,
	expected_kind: bifrost.Paste_Kind = .Complete,
	loc := #caller_location,
) {
	testing.expect(s.t, idx >= 0 && idx < len(s.parsed_events), "Event index out of bounds", loc = loc)
	if idx >= 0 && idx < len(s.parsed_events) {
		paste, ok := s.parsed_events[idx].(bifrost.Paste_Event)
		testing.expect(s.t, ok, "Expected Paste_Event at index", loc = loc)
		if ok {
			testing.expect_value(s.t, paste.text, expected_text, loc = loc)
			testing.expect_value(s.t, paste.kind, expected_kind, loc = loc)
		}
	}
}

then_parsed_focus_at_is :: proc(
	s: ^Suite_Ctx,
	idx: int,
	expected_focused: bool,
	loc := #caller_location,
) {
	testing.expect(s.t, idx >= 0 && idx < len(s.parsed_events), "Event index out of bounds", loc = loc)
	if idx >= 0 && idx < len(s.parsed_events) {
		focus, ok := s.parsed_events[idx].(bifrost.Focus_Event)
		testing.expect(s.t, ok, "Expected Focus_Event at index", loc = loc)
		if ok {
			testing.expect_value(s.t, focus.focused, expected_focused, loc = loc)
		}
	}
}

then_parsed_resize_at_is :: proc(
	s: ^Suite_Ctx,
	idx: int,
	expected_w: i32,
	expected_h: i32,
	expected_x_pix: u16 = 0,
	expected_y_pix: u16 = 0,
	loc := #caller_location,
) {
	testing.expect(s.t, idx >= 0 && idx < len(s.parsed_events), "Event index out of bounds", loc = loc)
	if idx >= 0 && idx < len(s.parsed_events) {
		rsz, ok := s.parsed_events[idx].(bifrost.Resize_Event)
		testing.expect(s.t, ok, "Expected Resize_Event at index", loc = loc)
		if ok {
			testing.expect_value(s.t, rsz.width, expected_w, loc = loc)
			testing.expect_value(s.t, rsz.height, expected_h, loc = loc)
			testing.expect_value(s.t, rsz.x_pixel, expected_x_pix, loc = loc)
			testing.expect_value(s.t, rsz.y_pixel, expected_y_pix, loc = loc)
		}
	}
}

// =============================================================================
// Layer 2: Domain-Specific Language (Sleipnir Actor Runtime + xitdb Inspector)
// =============================================================================

given_actor_xitdb_inspector :: proc(
	s: ^Suite_Ctx,
	t: ^testing.T,
	w: i32 = 80,
	h: i32 = 24,
	num_workers: int = 2,
	active_collection: string = "",
) {
	driver_actor_xitdb_init(s, t, w, h, num_workers, active_collection)
}

upon_worker_transacting_script :: proc(s: ^Suite_Ctx, script: string, tag_name: string = "") {
	actor.send(&s.sched, s.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Transact_Script{
		script   = script,
		tag_name = tag_name,
	}))
}

upon_worker_committing_batch :: proc(
	s: ^Suite_Ctx,
	map_name: string,
	key_prefix: string,
	start_id: int,
	count: int,
	sorted: bool = true,
	tag_name: string = "",
) {
	actor.send(&s.sched, s.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
		map_name   = map_name,
		key_prefix = key_prefix,
		start_id   = start_id,
		count      = count,
		sorted     = sorted,
		tag_name   = tag_name,
	}))
}

upon_worker_running_datalog :: proc(s: ^Suite_Ctx, query_source: string) {
	actor.send(&s.sched, s.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
		query_source = query_source,
	}))
}

upon_worker_diffing_moments :: proc(s: ^Suite_Ctx, moment_a, moment_b: i64) {
	actor.send(&s.sched, s.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
		moment_a = moment_a,
		moment_b = moment_b,
	}))
}

upon_sending_commit_burst :: proc(s: ^Suite_Ctx, count: int) {
	for i := 0; i < count; i += 1 {
		actor.send(&s.sched, s.ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
			moment_idx = i64(i),
			slot_ptr   = i64(i * 64),
			tx_id      = i64(i + 1),
			tag_name   = "burst",
		}))
	}
}

upon_sending_ui_msg :: proc(s: ^Suite_Ctx, msg: bifrost.UI_Msg) {
	actor.send(&s.sched, s.ui_pid, msg)
}

upon_ticking_ui_frame :: proc(s: ^Suite_Ctx, tick_ns: i64 = 1) {
	actor.scheduler_wait_idle(&s.sched)
	actor.send(&s.sched, s.ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = tick_ns}))
	actor.scheduler_wait_idle(&s.sched)
	actor.scheduler_wait_idle(&s.sched)
}

then_ui_coordinator_metrics_are :: proc(
	s: ^Suite_Ctx,
	expected_coalesced_commits: int,
	expected_total_frames: int,
	loc := #caller_location,
) {
	testing.expect_value(s.t, s.ui_actor.state.coalesced_commits, expected_coalesced_commits, loc = loc)
	testing.expect_value(s.t, s.ui_actor.state.total_frames, expected_total_frames, loc = loc)
}

then_ui_active_moment_is :: proc(
	s: ^Suite_Ctx,
	expected_active: i64,
	expected_latest: i64,
	expected_pinned: bool,
	loc := #caller_location,
) {
	testing.expect_value(s.t, s.ui_actor.state.active_moment_idx, expected_active, loc = loc)
	testing.expect_value(s.t, s.ui_actor.state.latest_moment_idx, expected_latest, loc = loc)
	testing.expect_value(s.t, s.ui_actor.state.pinned_moment, expected_pinned, loc = loc)
}

then_ui_screen_contains_text :: proc(s: ^Suite_Ctx, needle: string, loc := #caller_location) {
	found := false
	for r := 0; r < s.ui_actor.state.rows; r += 1 {
		line := driver_actor_row_text(s, r)
		if strings.contains(line, needle) {
			found = true
			break
		}
	}
	testing.expectf(
		s.t,
		found,
		"Expected UI coordinator screen to contain %q (diff=%v, datalog=%q)",
		needle,
		s.ui_actor.state.last_diff_summary,
		s.ui_actor.state.last_datalog_summary,
		loc = loc,
	)
}

then_worker_ping_count_is :: proc(s: ^Suite_Ctx, expected_moments: i64, loc := #caller_location) {
	cnt := actor.call(&s.sched, s.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Ping_Count{}), i64)
	testing.expect_value(s.t, cnt, expected_moments, loc = loc)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 8: Key-Chord DSL, Sub-Modes & Hint Bar)
// =============================================================================

upon_requesting_focus :: proc(s: ^Suite_Ctx, id: string) {
	s.input.wants_focus_id = bifrost.hash_id(id) if len(id) > 0 else 0
}

upon_clicking_widget :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	rect, ok := bifrost.get_rect(&s.layout_ctx, id)
	testing.expect(s.t, ok, "Expected widget rect for click", loc = loc)
	if ok {
		upon_mouse_click(s, rect.x + 1, rect.y)
	}
}

then_virtual_table_cell_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_row: i32,
	expected_col: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_selected_row(&s.input, id), expected_row, loc = loc)
	testing.expect_value(s.t, bifrost.get_selected_col(&s.input, id), expected_col, loc = loc)
}

given_actions_struct_registered_ctx :: proc(s: ^Suite_Ctx, cp: ^bifrost.Command_Palette, inst: $T, loc := #caller_location) {
	ok := bifrost.register_actions_struct(&s.input, cp, inst)
	testing.expect(s.t, ok, "Expected register_actions_struct to succeed", loc = loc)
}

given_chord_bound :: proc(
	s: ^Suite_Ctx,
	chord_spec: string,
	action_name: string,
	policy: bifrost.Key_Scope_Policy = .Root_And_Scopes,
	scope_id: string = "",
	loc := #caller_location,
) {
	ok := bifrost.bind_chord(&s.input, chord_spec, action_name, policy, scope_id)
	testing.expect(s.t, ok, "Expected bind_chord to succeed", loc = loc)
}

given_action_guard :: proc(
	s: ^Suite_Ctx,
	action_name: string,
	guard: bifrost.Action_Guard_Proc,
	userdata: rawptr = nil,
) {
	bifrost.set_action_guard(&s.input, action_name, guard, userdata)
}

given_action_availability :: proc(
	s: ^Suite_Ctx,
	action_name: string,
	avail: bifrost.Action_Availability,
	avail_proc: bifrost.Action_Avail_Proc = nil,
	userdata: rawptr = nil,
) {
	bifrost.set_action_availability(&s.input, action_name, avail, avail_proc, userdata)
}

then_disabled_action_reason_is :: proc(s: ^Suite_Ctx, expected_reason: string, loc := #caller_location) {
	testing.expect_value(s.t, s.input.last_disabled_reason, expected_reason, loc = loc)
}

then_typed_action_triggered_is_ctx :: proc(s: ^Suite_Ctx, expected_val: $E, loc := #caller_location) {
	act, ok := bifrost.triggered_action(&s.input, E)
	testing.expect(s.t, ok, "Expected typed action enum to be triggered", loc = loc)
	testing.expect_value(s.t, act, expected_val, loc = loc)
}

then_paint_has_dimmed_span :: proc(s: ^Suite_Ctx, id: string, snippet: string, expected: bool, loc := #caller_location) {
	paint := s.screen.paints[bifrost.hash_id(id)]
	found := false
	for sp in paint.spans {
		if strings.contains(sp.text, snippet) && (.Dim in sp.style) {
			found = true
			break
		}
	}
	testing.expect_value(s.t, found, expected, loc = loc)
}

then_pending_chord_is :: proc(
	s: ^Suite_Ctx,
	expected_active: bool,
	expected_prefix: string = "",
	loc := #caller_location,
) {
	testing.expect_value(s.t, s.input.pending_chord.active, expected_active, loc = loc)
	if expected_active && len(expected_prefix) > 0 {
		testing.expect_value(s.t, bifrost.pending_chord_prefix(&s.input), expected_prefix, loc = loc)
	}
}

then_splitter_submode_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected: bifrost.Splitter_Submode,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_scope_submode_typed(&s.input, id, bifrost.Splitter_Submode), expected, loc = loc)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 9: Actor Bridge Isolation, Action Sinks & Persistence)
// =============================================================================

given_actor_action_bound_static :: proc(
	s: ^Suite_Ctx,
	action_name: string,
	payload: bifrost.Xitdb_Worker_Msg,
	loc := #caller_location,
) {
	ok := bifrost.bind_actor_action(&s.ui_actor.state, action_name, s.worker_pid, payload)
	testing.expect(s.t, ok, "Expected static bind_actor_action to succeed", loc = loc)
}

given_actor_action_bound_dynamic :: proc(
	s: ^Suite_Ctx,
	action_name: string,
	builder_fn: proc(coord: ^bifrost.UI_Coordinator_State, userdata: rawptr) -> (bifrost.Xitdb_Worker_Msg, bool),
	userdata: rawptr = nil,
	loc := #caller_location,
) {
	ok := bifrost.bind_actor_action(&s.ui_actor.state, action_name, s.worker_pid, builder_fn, userdata)
	testing.expect(s.t, ok, "Expected dynamic bind_actor_action to succeed", loc = loc)
}

given_ui_quit_filter :: proc(
	s: ^Suite_Ctx,
	filter_fn: bifrost.UI_Quit_Filter_Fn,
	user_ptr: rawptr = nil,
) {
	bifrost.ui_set_quit_filter(&s.ui_actor.state, filter_fn, user_ptr)
}

upon_sending_ui_key :: proc(
	s: ^Suite_Ctx,
	code: bifrost.Key_Code,
	ch: rune = 0,
	ctrl: bool = false,
	alt: bool = false,
	shift: bool = false,
) {
	upon_sending_ui_msg(s, bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code  = code,
		ch    = ch,
		ctrl  = ctrl,
		alt   = alt,
		shift = shift,
	}))
}

upon_typing_ui_keys :: proc(s: ^Suite_Ctx, text: string) {
	for ch in text {
		if ch == ' ' {
			upon_sending_ui_key(s, .Space, ' ')
		} else {
			upon_sending_ui_key(s, .Rune, ch)
		}
	}
}

upon_issuing_ui_side_effects :: proc(
	s: ^Suite_Ctx,
	focus_id: string,
	osc52_text: string,
	title: string,
	cursor_shape: bifrost.Cursor_Shape,
	request_quit: bool,
) {
	if len(focus_id) > 0 {
		bifrost.ui_cmd_request_focus(&s.ui_actor.state, focus_id)
	}
	if len(osc52_text) > 0 {
		bifrost.ui_cmd_copy_osc52(&s.ui_actor.state, osc52_text)
	}
	if len(title) > 0 {
		bifrost.ui_cmd_set_title(&s.ui_actor.state, title)
	}
	bifrost.ui_cmd_set_cursor_shape(&s.ui_actor.state, cursor_shape)
	if request_quit {
		bifrost.ui_cmd_request_quit(&s.ui_actor.state)
	}
}

upon_pressing_mouse_on_ui_widget :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	rect, ok := bifrost.get_rect(&s.ui_actor.state.layout_ctx, id)
	testing.expect(s.t, ok, "Expected UI coordinator widget rect to exist", loc = loc)
	if ok {
		upon_sending_ui_msg(s, bifrost.UI_Msg(bifrost.UI_Msg_Mouse{
			x      = rect.x,
			y      = rect.y + 1,
			button = 1,
			action = .Press,
		}))
	}
}

upon_sending_ui_focus_event :: proc(s: ^Suite_Ctx, focused: bool) {
	upon_sending_ui_msg(s, bifrost.UI_Msg(bifrost.UI_Msg_Input{
		event = bifrost.Focus_Event{focused = focused},
	}))
}

upon_customizing_ui_workspace :: proc(
	s: ^Suite_Ctx,
	splitter_id: string,
	split_size: i32,
	scope_id: string,
	child_id: string,
	leaf_id: string,
) {
	slot := bifrost.get_splitter_slot(&s.ui_actor.state.input, bifrost.hash_id(splitter_id))
	slot.size = split_size
	bifrost.upsert_scope_memory(
		&s.ui_actor.state.input,
		bifrost.hash_id(scope_id),
		bifrost.hash_id(child_id),
		bifrost.hash_id(leaf_id),
	)
}

upon_saving_ui_workspace :: proc(s: ^Suite_Ctx, workspace_id: string, loc := #caller_location) {
	ok := bifrost.save_ui_workspace_to_xitdb(&s.shared_db, &s.ui_actor.state, workspace_id)
	testing.expect(s.t, ok, "Expected save_ui_workspace_to_xitdb to succeed", loc = loc)
}

then_restored_ui_workspace_matches :: proc(
	s: ^Suite_Ctx,
	workspace_id: string,
	splitter_id: string,
	expected_split: i32,
	expected_collection: string,
	expected_pinned: bool,
	expected_moment: i64,
	scope_id: string,
	expected_leaf_id: string,
	loc := #caller_location,
) {
	restored: bifrost.UI_Coordinator_State
	testing.expect(s.t, bifrost.ui_coordinator_init(&restored, 110, 24, &s.shared_db, nil, s.alloc), loc = loc)
	defer bifrost.ui_coordinator_destroy(&restored)

	testing.expect(s.t, bifrost.load_ui_workspace_from_xitdb(&s.shared_db, &restored, workspace_id), loc = loc)
	testing.expect_value(s.t, bifrost.get_split_size(&restored.input, splitter_id, 25, 12, 60), expected_split, loc = loc)
	testing.expect_value(s.t, restored.active_collection, expected_collection, loc = loc)
	testing.expect_value(s.t, restored.pinned_moment, expected_pinned, loc = loc)
	testing.expect_value(s.t, restored.active_moment_idx, expected_moment, loc = loc)

	mem_entry := bifrost.get_scope_memory(&restored.input, bifrost.hash_id(scope_id))
	testing.expect(s.t, mem_entry != nil, "Expected restored scope memory entry", loc = loc)
	if mem_entry != nil {
		testing.expect_value(s.t, mem_entry.last_leaf_hash, bifrost.hash_id(expected_leaf_id), loc = loc)
	}
}

then_ui_palette_open_is :: proc(s: ^Suite_Ctx, expected: bool, loc := #caller_location) {
	testing.expect_value(s.t, s.ui_actor.state.palette_open, expected, loc = loc)
}

then_ui_ansi_output_contains :: proc(s: ^Suite_Ctx, needle: string, loc := #caller_location) {
	ansi_str := strings.to_string(s.ui_actor.state.ansi_builder)
	testing.expectf(
		s.t,
		strings.contains(ansi_str, needle),
		"Expected UI coordinator ANSI stream to contain %q, got %q",
		needle,
		ansi_str,
		loc = loc,
	)
}

then_ui_pointer_capture_is :: proc(
	s: ^Suite_Ctx,
	expected_press_id: string,
	expected_splitter_id: string,
	loc := #caller_location,
) {
	exp_press := bifrost.hash_id(expected_press_id) if len(expected_press_id) > 0 else u64(0)
	exp_split := bifrost.hash_id(expected_splitter_id) if len(expected_splitter_id) > 0 else u64(0)
	testing.expect_value(s.t, s.ui_actor.state.input.active_press_id, exp_press, loc = loc)
	testing.expect_value(s.t, s.ui_actor.state.input.active_splitter_id, exp_split, loc = loc)
}

then_ui_focused_widget_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	if len(id) == 0 {
		testing.expect_value(s.t, s.ui_actor.state.input.focused_id, u64(0), loc = loc)
	} else {
		testing.expect(s.t, bifrost.is_focused(&s.ui_actor.state.input, id), "Expected UI coordinator widget to hold focus", loc = loc)
	}
}

then_ui_editing_widget_is :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {
	if len(id) == 0 {
		testing.expect_value(s.t, s.ui_actor.state.input.editing_id, u64(0), loc = loc)
	} else {
		testing.expect(s.t, bifrost.is_editing(&s.ui_actor.state.input, id), "Expected UI coordinator widget to own editing_id", loc = loc)
	}
}

then_ui_text_value_is :: proc(s: ^Suite_Ctx, id: string, expected: string, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.get_text(&s.ui_actor.state.input, id), expected, loc = loc)
}

then_ui_vlist_row_is :: proc(s: ^Suite_Ctx, expected_row: int, loc := #caller_location) {
	testing.expect_value(s.t, s.ui_actor.state.vlist.selected_row, expected_row, loc = loc)
}

then_ui_quit_requested_is :: proc(s: ^Suite_Ctx, expected: bool, loc := #caller_location) {
	testing.expect_value(s.t, s.ui_actor.state.quit_requested, expected, loc = loc)
}

given_xitdb_array_list_populated :: proc(
	s: ^Suite_Ctx,
	list_name: string,
	count: int,
	step_multiplier: i64 = 10,
	expected_moment: i64 = 0,
	loc := #caller_location,
) {
	tx := xitdb.tx_init(&s.db, -1, false, context.temp_allocator)
	step := [1]xitdb.Path_Step{xitdb.hm(list_name)}
	for i := 0; i < count; i += 1 {
		xitdb.tx_append_steps(&tx, step[:], i64(i) * step_multiplier)
	}
	report, err := xitdb.tx_commit(&tx)
	testing.expect_value(s.t, err, nil, loc = loc)
	testing.expect_value(s.t, report.moment_index, expected_moment, loc = loc)
	free_all(context.temp_allocator)
}

then_xitdb_viewport_slice_is :: proc(
	s: ^Suite_Ctx,
	moment_idx: i64,
	path: string,
	start_row: i64,
	max_rows: i64,
	expected_total: i64,
	expected_count: int,
	expected_first_idx: i64,
	expected_first_val: string,
	expected_last_idx: i64,
	loc := #caller_location,
) {
	slice, s_err := bifrost.xitdb_slice_viewport(
		&s.db,
		moment_idx,
		path,
		start_row,
		max_rows,
		{},
		context.temp_allocator,
	)
	testing.expect_value(s.t, s_err, nil, loc = loc)
	testing.expect_value(s.t, slice.total_rows, expected_total, loc = loc)
	testing.expect_value(s.t, len(slice.rows), expected_count, loc = loc)
	if len(slice.rows) > 0 {
		testing.expect_value(s.t, slice.rows[0].logical_index, expected_first_idx, loc = loc)
		testing.expect_value(s.t, slice.rows[0].val_text, expected_first_val, loc = loc)
		testing.expect_value(s.t, slice.rows[len(slice.rows) - 1].logical_index, expected_last_idx, loc = loc)
	}
}

given_nonblocking_pipe_terminal :: proc(s: ^Suite_Ctx, loc := #caller_location) {
	in_pipe, in_err := bifrost.terminal_pipe_open()
	testing.expect_value(s.t, in_err, bifrost.Terminal_Error.None, loc = loc)
	out_pipe, out_err := bifrost.terminal_pipe_open()
	testing.expect_value(s.t, out_err, bifrost.Terminal_Error.None, loc = loc)
	s.in_pipe  = in_pipe
	s.out_pipe = out_pipe
	s.pipe_term = bifrost.Terminal{
		in_fd       = s.in_pipe[0],
		out_fd      = s.out_pipe[1],
		resize_pipe = {bifrost.INVALID_TERMINAL_FD, bifrost.INVALID_TERMINAL_FD},
	}
	pipe_err := bifrost.terminal_init_sigwinch_pipe(&s.pipe_term)
	testing.expect_value(s.t, pipe_err, bifrost.Terminal_Error.None, loc = loc)
	s.pipe_term_active = true
}

upon_writing_to_terminal_pipe :: proc(s: ^Suite_Ctx, data: string) {
	if len(data) > 0 {
		_, _ = bifrost.terminal_fd_write(s.in_pipe[1], transmute([]byte)data)
	}
}

then_polled_terminal_key_is :: proc(
	s: ^Suite_Ctx,
	timeout_ms: i32,
	expected_code: bifrost.Key_Code,
	expected_mods: bifrost.Mod_Flags = {},
	loc := #caller_location,
) {
	ev, has_ev, err := bifrost.poll_next_event(&s.pipe_term, timeout_ms)
	testing.expect_value(s.t, err, bifrost.Terminal_Error.None, loc = loc)
	testing.expect(s.t, has_ev, "Expected event from poll_next_event", loc = loc)
	if has_ev {
		key, ok := ev.(bifrost.Key_Event)
		testing.expect(s.t, ok, "Expected Key_Event from poll_next_event", loc = loc)
		if ok {
			testing.expect_value(s.t, key.code, expected_code, loc = loc)
			testing.expect_value(s.t, key.mods, expected_mods, loc = loc)
		}
	}
}

then_terminal_deinit_emits_teardown :: proc(
	s: ^Suite_Ctx,
	expected_seq: string,
	loc := #caller_location,
) {
	bifrost.terminal_deinit(&s.pipe_term)
	out_buf: [256]byte
	n_out, _ := bifrost.terminal_fd_read(s.out_pipe[0], out_buf[:])
	testing.expect_value(s.t, string(out_buf[:max(0, n_out)]), expected_seq, loc = loc)
}

upon_feeding_win32_console_record :: proc(s: ^Suite_Ctx, rec: bifrost.Win32_Console_Record) {
	rsz_ev, has_rsz := bifrost.terminal_feed_win32_console_record(&s.pipe_term, rec)
	if has_rsz {
		append(&s.parsed_events, rsz_ev)
	}
	for s.pipe_term.read_len > 0 {
		ev, consumed, status := bifrost.parse_ansi_input(s.pipe_term.read_buf[:s.pipe_term.read_len], false)
		s.last_parse_stat = status
		s.last_consumed   = consumed
		if status == .Ok {
			append(&s.parsed_events, ev)
			n := max(consumed, 1)
			rem := s.pipe_term.read_len - n
			if rem > 0 {
				copy(s.pipe_term.read_buf[:rem], s.pipe_term.read_buf[n:s.pipe_term.read_len])
			}
			s.pipe_term.read_len = max(0, rem)
			continue
		}
		break
	}
}

then_virtual_slice_range_is :: proc(
	s: ^Suite_Ctx,
	slice: bifrost.Virtual_Slice,
	expected_start: i32,
	expected_end: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, slice.start_row, expected_start, loc = loc)
	testing.expect_value(s.t, slice.end_row, expected_end, loc = loc)
}

then_filtered_row_count_is :: proc(
	s: ^Suite_Ctx,
	actual_count: i32,
	expected_count: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, actual_count, expected_count, loc = loc)
}

then_filter_mapped_row_is :: proc(
	s: ^Suite_Ctx,
	filter: ^bifrost.Xitdb_Filter,
	virtual_row: i32,
	expected_db_row: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.xitdb_filter_map_row(filter, virtual_row), expected_db_row, loc = loc)
}

then_table_column_width_is :: proc(
	s: ^Suite_Ctx,
	span: bifrost.Table_Column_Span,
	expected_width: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, span.width, expected_width, loc = loc)
}

then_action_shortcut_is :: proc(
	s: ^Suite_Ctx,
	action: string,
	expected_shortcut: string,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.lookup_action_shortcut(&s.input, action), expected_shortcut, loc = loc)
}

then_command_palette_open_is :: proc(
	s: ^Suite_Ctx,
	palette: ^bifrost.Command_Palette,
	expected_open: bool,
	loc := #caller_location,
) {
	testing.expect_value(s.t, palette.is_open, expected_open, loc = loc)
}

then_command_palette_match_count_is :: proc(
	s: ^Suite_Ctx,
	palette: ^bifrost.Command_Palette,
	expected_count: int,
	loc := #caller_location,
) {
	testing.expect_value(s.t, palette.match_count, expected_count, loc = loc)
}

then_command_palette_top_match_is :: proc(
	s: ^Suite_Ctx,
	palette: ^bifrost.Command_Palette,
	expected_action: string,
	loc := #caller_location,
) {
	testing.expect(s.t, palette.match_count > 0, "Expected command palette to have at least 1 match", loc = loc)
	if palette.match_count > 0 {
		testing.expect_value(s.t, palette.commands[palette.matches[0].item_idx].action, expected_action, loc = loc)
	}
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 11: Multi-Line Text Editor)
// =============================================================================

given_text_area_text :: proc(s: ^Suite_Ctx, id: string, text: string) {
	bifrost.set_text_area(&s.input, id, text)
}

upon_pasting_text :: proc(s: ^Suite_Ctx, text: string) {
	upon_input_events(s, bifrost.Paste_Event{text = text, kind = .Complete})
}

then_text_area_value_is :: proc(s: ^Suite_Ctx, id: string, expected: string, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.get_text_area(&s.input, id), expected, loc = loc)
}

then_text_area_cursor_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_row: i32,
	expected_col: i32,
	loc := #caller_location,
) {
	row, col, _ := bifrost.get_text_area_cursor(&s.input, id)
	testing.expect_value(s.t, row, expected_row, loc = loc)
	testing.expect_value(s.t, col, expected_col, loc = loc)
}

then_text_area_preferred_col_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_preferred_col: i32,
	loc := #caller_location,
) {
	slot := bifrost.get_text_area_state(&s.input, id)
	testing.expect_value(s.t, slot.preferred_col, expected_preferred_col, loc = loc)
}

then_text_area_scroll_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_scroll_row: i32,
	expected_scroll_col: i32,
	loc := #caller_location,
) {
	scroll_row, scroll_col := bifrost.get_text_area_scroll(&s.input, id)
	testing.expect_value(s.t, scroll_row, expected_scroll_row, loc = loc)
	testing.expect_value(s.t, scroll_col, expected_scroll_col, loc = loc)
}

then_text_area_selection_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected: string,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_text_area_selected_text(&s.input, id), expected, loc = loc)
}

then_text_area_line_count_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_lines: int,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_text_area_line_count(&s.input, id), expected_lines, loc = loc)
}

then_text_area_line_length_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	line_idx: int,
	expected_len: int,
	loc := #caller_location,
) {
	slot := bifrost.get_text_area_state(&s.input, id)
	l_start, l_end := bifrost.text_area_line_range(slot, i32(line_idx))
	testing.expect_value(s.t, l_end - l_start, expected_len, loc = loc)
}

then_text_area_dynamic_state_is :: proc(
	s: ^Suite_Ctx,
	st: ^bifrost.Text_Area_State,
	expected_text: string,
	loc := #caller_location,
) {
	testing.expect_value(s.t, st.use_dyn, true, loc = loc)
	testing.expect(s.t, len(st.dyn_buf) > 0, "Expected dyn_buf to remain allocated", loc = loc)
	if len(st.dyn_buf) >= st.len {
		testing.expect_value(s.t, string(st.dyn_buf[:st.len]), expected_text, loc = loc)
	}
}

then_clipboard_text_is :: proc(
	s: ^Suite_Ctx,
	expected: string,
	expected_osc52: bool = true,
	loc := #caller_location,
) {
	actual := string(s.input.clipboard_buf[:s.input.clipboard_len])
	testing.expect_value(s.t, actual, expected, loc = loc)
	testing.expect_value(s.t, s.input.osc52_pending, expected_osc52, loc = loc)
}

then_osc52_flushed_is :: proc(
	s: ^Suite_Ctx,
	expected_substr: string,
	loc := #caller_location,
) {
	b := strings.builder_make(0, 128, context.temp_allocator)
	flushed := bifrost.flush_osc52_clipboard(&s.input, &b)
	testing.expect_value(s.t, flushed, true, loc = loc)
	testing.expect_value(s.t, s.input.osc52_pending, false, loc = loc)
	testing.expect(s.t, strings.contains(strings.to_string(b), expected_substr), "Expected OSC 52 sequence to contain base64 substring", loc = loc)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 12: Virtualized Collapsible Tree)
// =============================================================================

then_tree_selection_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_node_idx: i32,
	expected_vis_row: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_tree_selected_node(&s.input, id), expected_node_idx, loc = loc)
	testing.expect_value(s.t, bifrost.get_tree_selected_vis_row(&s.input, id), expected_vis_row, loc = loc)
}

then_tree_node_expanded_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	node_idx: i32,
	expected: bool,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.is_tree_node_expanded(&s.input, id, node_idx), expected, loc = loc)
}

then_tree_visible_count_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_visible_rows: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_tree_visible_row_count(&s.input, id), expected_visible_rows, loc = loc)
}

then_tree_activated_node_is :: proc(
	s: ^Suite_Ctx,
	id: string,
	expected_node_idx: i32,
	loc := #caller_location,
) {
	testing.expect_value(s.t, bifrost.get_tree_activated_node(&s.input, id), expected_node_idx, loc = loc)
}

then_vt_row_contains_text :: proc(
	s: ^Suite_Ctx,
	row: i32,
	needle: string,
	expected: bool = true,
	loc := #caller_location,
) {
	w := int(s.vt_w)
	h := int(s.vt_h)
	r := int(row)
	if r < 0 || r >= h {
		testing.expectf(s.t, false, "Row %d out of VT bounds [0 ..< %d]", row, h, loc = loc)
		return
	}
	b := strings.builder_make(0, w, context.temp_allocator)
	for x := 0; x < w; x += 1 {
		ch := s.vt_cells[r * w + x].ch
		if ch != 0 {
			strings.write_rune(&b, ch)
		}
	}
	row_str := strings.to_string(b)
	testing.expectf(
		s.t,
		strings.contains(row_str, needle) == expected,
		"Row %d: expected contains(%q) == %v, got %q",
		row,
		needle,
		expected,
		row_str,
		loc = loc,
	)
}

// =============================================================================
// Layer 2: Domain-Specific Language (Track 13: Focus-Scope-Integrated Tab Bar)
// =============================================================================

given_active_tab :: proc(s: ^Suite_Ctx, id: string, tab_idx: int, restore_body_focus: bool = true) {
	bifrost.set_active_tab(&s.input, id, tab_idx, restore_body_focus)
}

upon_clicking_tab :: proc(s: ^Suite_Ctx, id: string, tab_idx: int, loc := #caller_location) {
	tab_id := bifrost.tab_header_id(id, tab_idx)
	upon_clicking_widget(s, tab_id, loc)
}

then_active_tab_is :: proc(s: ^Suite_Ctx, id: string, expected_tab: int, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.get_active_tab(&s.input, id), expected_tab, loc = loc)
}

then_tab_changed_is :: proc(s: ^Suite_Ctx, id: string, expected: bool, loc := #caller_location) {
	testing.expect_value(s.t, bifrost.was_tab_changed(&s.input, id), expected, loc = loc)
}

then_cell_style_has :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	expected_flag: bifrost.Style_Flag,
	expected_present: bool,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	testing.expect(s.t, idx >= 0 && idx < len(s.screen.back), "Expected screen cell in bounds", loc = loc)
	if idx >= 0 && idx < len(s.screen.back) {
		actual := expected_flag in s.screen.back[idx].style
		testing.expect_value(s.t, actual, expected_present, loc = loc)
	}
}

