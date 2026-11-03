package bifrost_tests

import "core:strings"
import "core:testing"
import "../bifrost"

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

