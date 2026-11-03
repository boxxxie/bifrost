package bifrost_tests

import "core:c"
import "core:sys/posix"
import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications (Track 4: POSIX TTY & ANSI / Kitty / Mouse SGR Parser)
// =============================================================================

@(test)
spec_bare_esc_timeout_disambiguation_and_split_csi_ss3_streams :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	// 1. Bare ESC ("\x1b") before timeout returns Need_More with 0 bytes consumed
	given_clean_input_stream(&s)
	upon_parsing_raw_slice(&s, "\x1b", is_timeout = false)
	then_parse_status_is(&s, .Need_More, expected_consumed = 0)
	then_parsed_event_count_is(&s, 0)

	// 2. Bare ESC ("\x1b") after timeout disambiguates to Key_Code.Escape (1 byte consumed)
	upon_parsing_raw_slice(&s, "\x1b", is_timeout = true)
	then_parse_status_is(&s, .Ok, expected_consumed = 1)
	then_parsed_event_count_is(&s, 1)
	then_parsed_key_at_is(&s, 0, .Escape)

	// 3. Consecutive ESC ("\x1b\x1b") immediately emits the first Escape (1 byte) and leaves the second ESC
	given_clean_input_stream(&s)
	upon_parsing_raw_slice(&s, "\x1b\x1b", is_timeout = false)
	then_parse_status_is(&s, .Ok, expected_consumed = 1)
	then_parsed_key_at_is(&s, 0, .Escape)

	// 4. Alt+<ascii> ("\x1bx") and Alt+<utf8> ("\x1bλ") decode in a single pass with .Alt modifier
	given_clean_input_stream(&s)
	upon_parsing_raw_slice(&s, "\x1bx", is_timeout = false)
	then_parse_status_is(&s, .Ok, expected_consumed = 2)
	then_parsed_key_at_is(&s, 0, .Rune, {.Alt}, 'x')

	upon_parsing_raw_slice(&s, "\x1bλ", is_timeout = false)
	then_parse_status_is(&s, .Ok, expected_consumed = 3)
	then_parsed_key_at_is(&s, 1, .Rune, {.Alt}, 'λ')

	// 5. Incomplete CSI ("\x1b[") and SS3 ("\x1bO") wait for Need_More before timeout,
	//    and fall back to Alt+[ and Alt+O if the escape timeout fires
	given_clean_input_stream(&s)
	upon_parsing_raw_slice(&s, "\x1b[", is_timeout = false)
	then_parse_status_is(&s, .Need_More, expected_consumed = 0)
	upon_parsing_raw_slice(&s, "\x1b[", is_timeout = true)
	then_parse_status_is(&s, .Ok, expected_consumed = 2)
	then_parsed_key_at_is(&s, 0, .Rune, {.Alt}, '[')

	upon_parsing_raw_slice(&s, "\x1bO", is_timeout = false)
	then_parse_status_is(&s, .Need_More, expected_consumed = 0)
	upon_parsing_raw_slice(&s, "\x1bO", is_timeout = true)
	then_parse_status_is(&s, .Ok, expected_consumed = 2)
	then_parsed_key_at_is(&s, 1, .Rune, {.Alt}, 'O')

	// 6. 1-byte split read reassembly across CSI, SS3, Shift+Tab, Tilde keys, and multi-byte UTF-8
	given_clean_input_stream(&s)
	upon_feeding_byte_by_byte(&s, "\x1b[1;5C\x1bOP\x1b[Z\x1b[5;2~🚀")
	then_parsed_event_count_is(&s, 5)
	then_parsed_key_at_is(&s, 0, .Right, {.Ctrl})
	then_parsed_key_at_is(&s, 1, .F1)
	then_parsed_key_at_is(&s, 2, .Tab, {.Shift})
	then_parsed_key_at_is(&s, 3, .Page_Up, {.Shift})
	then_parsed_key_at_is(&s, 4, .Rune, {}, '🚀')
}

@(test)
spec_kitty_keyboard_protocol_csi_u_chords_releases_and_text_synthesis :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	given_clean_input_stream(&s)

	// 1. Kitty shifted ASCII ("\x1b[97:65;2u") synthesizes uppercase text "A"
	upon_feeding_byte_by_byte(&s, "\x1b[97:65;2u")
	then_parsed_kitty_key_at_is(&s, 0, 'a', 'A', 0, {.Shift}, .Press, "A")
	then_parsed_key_at_is(&s, 0, .Rune, {.Shift}, 'A', .Press)

	// 2. Kitty base-layout chord ("\x1b[1089::99;5u" -> Cyrillic 'с' with base layout 'c' and Ctrl)
	upon_feeding_byte_by_byte(&s, "\x1b[1089::99;5u")
	then_parsed_kitty_key_at_is(&s, 1, 'с', 0, 'c', {.Ctrl}, .Press, "")

	// 3. Kitty key repeat ("\x1b[106;1:2u") and key release ("\x1b[106;1:3u")
	upon_feeding_byte_by_byte(&s, "\x1b[106;1:2u\x1b[106;1:3u")
	then_parsed_kitty_key_at_is(&s, 2, 'j', 0, 0, {}, .Repeat, "j")
	then_parsed_kitty_key_at_is(&s, 3, 'j', 0, 0, {}, .Release, "j")

	// 4. Kitty explicit multi-codepoint associated text ("\x1b[97;1;229:97u" -> "åa")
	upon_feeding_byte_by_byte(&s, "\x1b[97;1;229:97u")
	then_parsed_kitty_key_at_is(&s, 4, 'a', 0, 0, {}, .Press, "åa")

	// 5. Kitty Private Use Area functional keys (57364 = F1, 57427 = KP_Begin, 57441 = Left_Shift)
	//    and capability query response "\x1b[?29u" (ignored)
	upon_feeding_byte_by_byte(&s, "\x1b[?29u\x1b[57364;5u\x1b[57427u\x1b[57441;2u")
	then_parsed_event_count_is(&s, 8)
	then_parsed_key_at_is(&s, 5, .F1, {.Ctrl})
	then_parsed_key_at_is(&s, 6, .KP_Begin)
	then_parsed_key_at_is(&s, 7, .Left_Shift, {.Shift})
}

@(test)
spec_sgr_1006_and_x10_mouse_press_drag_release_wheel_and_negative_coords :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	given_clean_input_stream(&s)

	// 1. SGR 1006 Left press (1-based 15,8 -> 0-based 14,7), Shift+Ctrl drag (button_mask = 32|16|4 = 52), and release ('m')
	upon_feeding_byte_by_byte(&s, "\x1b[<0;15;8M\x1b[<52;22;9M\x1b[<0;22;9m")
	then_parsed_event_count_is(&s, 3)
	then_parsed_mouse_at_is(&s, 0, 14, 7, .Left, .Press)
	then_parsed_mouse_at_is(&s, 1, 21, 8, .Left, .Drag, {.Shift, .Ctrl})
	then_parsed_mouse_at_is(&s, 2, 21, 8, .Left, .Release)

	// 2. SGR 1006 Wheel_Up (64) and Wheel_Down (65), plus hover Motion (35 = 32|3)
	upon_feeding_byte_by_byte(&s, "\x1b[<64;10;20M\x1b[<65;10;20M\x1b[<35;5;6M")
	then_parsed_event_count_is(&s, 6)
	then_parsed_mouse_at_is(&s, 3, 9, 19, .Wheel_Up, .Press)
	then_parsed_mouse_at_is(&s, 4, 9, 19, .Wheel_Down, .Press)
	then_parsed_mouse_at_is(&s, 5, 4, 5, .None, .Motion)

	// 3. SGR 1006 negative out-of-window drag coordinates ("\x1b[<32;-5;-2M")
	upon_feeding_byte_by_byte(&s, "\x1b[<32;-5;-2M")
	then_parsed_mouse_at_is(&s, 6, -5, -2, .Left, .Drag)

	// 4. Legacy 6-byte X10 mouse ("\x1b[M !*" -> btn=0, x=33-32=1->0, y=42-32=10->9)
	upon_parsing_raw_slice(&s, "\x1b[M !", is_timeout = false)
	then_parse_status_is(&s, .Need_More, expected_consumed = 0)
	upon_feeding_byte_by_byte(&s, "\x1b[M !*")
	then_parsed_mouse_at_is(&s, 7, 0, 9, .Left, .Press)
}

@(test)
spec_bracketed_paste_focus_in_out_xtwinops_resize_and_malformed_recovery :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	given_clean_input_stream(&s)

	// 1. Bracketed paste split across chunks waits until "\x1b[201~" arrives
	upon_feeding_stream_chunk(&s, "\x1b[200~hello ")
	then_parse_status_is(&s, .Need_More)
	then_parsed_event_count_is(&s, 0)

	upon_feeding_stream_chunk(&s, "λ world\x1b[201~")
	then_parsed_event_count_is(&s, 1)
	then_parsed_paste_at_is(&s, 0, "hello λ world", .Complete)

	// 2. Focus In ("\x1b[I"), Focus Out ("\x1b[O"), and XTWINOPS resize ("\x1b[48;42;132;840;1320t")
	upon_feeding_byte_by_byte(&s, "\x1b[I\x1b[O\x1b[48;42;132;840;1320t")
	then_parsed_event_count_is(&s, 4)
	then_parsed_focus_at_is(&s, 1, true)
	then_parsed_focus_at_is(&s, 2, false)
	then_parsed_resize_at_is(&s, 3, 132, 42, 1320, 840)

	// 3. Ignored OSC ("\x1b]0;Title\x07"), DCS ("\x1bP1$r0m\x1b\\"), and interrupted CSI ("\x1b[12\x1b[A")
	//    recover cleanly and emit the valid trailing Key_Code.Up
	upon_feeding_byte_by_byte(&s, "\x1b]0;Title\x07\x1bP1$r0m\x1b\\\x1b[12\x1b[A")
	then_parsed_event_count_is(&s, 5)
	then_parsed_key_at_is(&s, 4, .Up)
}

@(test)
spec_posix_sigwinch_self_pipe_and_nonblocking_terminal_poll :: proc(t: ^testing.T) {
	// Verify POSIX Terminal poll_next_event over real non-blocking pipes (no interactive TTY required)
	in_pipe: [2]posix.FD
	out_pipe: [2]posix.FD
	testing.expect_value(t, posix.pipe(&in_pipe), posix.result.OK)
	defer {
		_ = posix.close(in_pipe[0])
		_ = posix.close(in_pipe[1])
	}
	testing.expect_value(t, posix.pipe(&out_pipe), posix.result.OK)
	defer {
		_ = posix.close(out_pipe[0])
		_ = posix.close(out_pipe[1])
	}

	term: bifrost.Terminal = {
		in_fd       = in_pipe[0],
		out_fd      = out_pipe[1],
		resize_pipe = {-1, -1},
	}
	pipe_err := bifrost.terminal_init_sigwinch_pipe(&term)
	testing.expect_value(t, pipe_err, bifrost.Terminal_Error.None)
	defer bifrost.terminal_deinit(&term)

	// 1. Write split CSI sequence across two writes and poll via poll_next_event
	part1 := "\x1b[1;"
	_ = posix.write(in_pipe[1], raw_data(part1), len(part1))
	part2 := "5C"
	_ = posix.write(in_pipe[1], raw_data(part2), len(part2))

	ev1, has1, err1 := bifrost.poll_next_event(&term, 50)
	testing.expect_value(t, err1, bifrost.Terminal_Error.None)
	testing.expect(t, has1, "Expected Ctrl+Right event from split pipe writes")
	key1 := ev1.(bifrost.Key_Event)
	testing.expect_value(t, key1.code, bifrost.Key_Code.Right)
	testing.expect_value(t, key1.mods, bifrost.Mod_Flags{.Ctrl})

	// 2. Write a bare ESC ("\x1b") with no follow-up bytes: poll_next_event waits ESC_DISAMBIGUATE_TIMEOUT_MS (25ms)
	//    and disambiguates it as Key_Code.Escape
	esc_byte := "\x1b"
	_ = posix.write(in_pipe[1], raw_data(esc_byte), 1)
	ev2, has2, err2 := bifrost.poll_next_event(&term, 50)
	testing.expect_value(t, err2, bifrost.Terminal_Error.None)
	testing.expect(t, has2, "Expected bare ESC to disambiguate after timeout")
	testing.expect_value(t, ev2.(bifrost.Key_Event).code, bifrost.Key_Code.Escape)

	// 3. Verify atomic teardown sequence written on terminal_deinit
	bifrost.terminal_deinit(&term)
	out_buf: [256]byte
	n_out := posix.read(out_pipe[0], &out_buf[0], len(out_buf))
	testing.expect_value(t, string(out_buf[:max(0, int(n_out))]), bifrost.CTL_TEARDOWN_SEQUENCE)
	_ = c.int(0)
}

@(test)
spec_end_to_end_ansi_stream_drives_bifrost_ui_text_input_and_mouse_scroll :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 50, h = 12)
	defer driver_destroy(&s)

	last_slice: bifrost.Virtual_Slice

	build_ui :: proc(s: ^Suite_Ctx, out_slice: ^bifrost.Virtual_Slice, events: ..bifrost.Input_Event) {
		driver_begin_frame(s, bifrost.rgb(18, 22, 28))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_text_input(&s.layout_ctx, &s.screen, &s.input, "filter_box", {
				width          = bifrost.grow(1),
				height         = bifrost.fixed(3),
				border         = .Rounded,
				title          = "Search",
				linked_list_id = "log_list",
			})
			if bifrost.ui_virtual_list(&s.layout_ctx, &s.screen, &s.input, "log_list", 100, {
				title         = "Logs",
				border        = .Plain,
				scroll_step   = 2,
				fallback_rows = 7,
			}, out_slice) {
				for r := out_slice.start_row; r < out_slice.end_row; r += 1 {
					bifrost.ui_label(&s.layout_ctx, &s.screen, "row", "Entry")
				}
			}
		}
		driver_end_frame(s, ..events)
	}

	// Frame 1: Mount UI and focus filter_box
	build_ui(&s, &last_slice)
	then_focused_widget_is(&s, "filter_box")

	// Feed a multiplexed burst of Kitty CSI u ("A"), bracketed paste ("lpha-λ"), Ctrl+W,
	// Down arrow ("\x1b[B"), and SGR 1006 Wheel_Down ("\x1b[<65;10;6M")
	given_clean_input_stream(&s)
	upon_feeding_byte_by_byte(&s, "\x1b[97:65;2u\x1b[200~lpha-λ beta\x1b[201~\x17\x1b[B\x1b[<65;10;6M")
	then_parsed_event_count_is(&s, 5)

	build_ui(&s, &last_slice, ..s.parsed_events[:])
	// "Alpha-λ beta" followed by Ctrl+W (0x17) leaves "Alpha-λ "
	then_text_input_value_is(&s, "filter_box", "Alpha-λ ")
	// Down arrow moved selected_row from 0 -> 1, and SGR Wheel_Down scrolled offset by +2
	then_virtual_scroll_is(&s, "log_list", expected_offset = 2, expected_selected = 1)
}

