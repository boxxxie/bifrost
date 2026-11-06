package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications (Track 4: POSIX TTY & ANSI / Kitty / Mouse SGR Parser)
// =============================================================================

@(test)
@(scenario)
spec_bare_esc_timeout_disambiguation_and_split_csi_ss3_streams :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	// 1. Bare ESC ("\x1b") before timeout returns Need_More with 0 bytes consumed
	given.clean_input_stream()
	upon.parsing_raw_slice("\x1b", is_timeout = false)
	then.parse_status_is(.Need_More, expected_consumed = 0)
	then.parsed_event_count_is(0)

	// 2. Bare ESC ("\x1b") after timeout disambiguates to Key_Code.Escape (1 byte consumed)
	upon.parsing_raw_slice("\x1b", is_timeout = true)
	then.parse_status_is(.Ok, expected_consumed = 1)
	then.parsed_event_count_is(1)
	then.parsed_key_at_is(0, .Escape)

	// 3. Consecutive ESC ("\x1b\x1b") immediately emits the first Escape (1 byte) and leaves the second ESC
	given.clean_input_stream()
	upon.parsing_raw_slice("\x1b\x1b", is_timeout = false)
	then.parse_status_is(.Ok, expected_consumed = 1)
	then.parsed_key_at_is(0, .Escape)

	// 4. Alt+<ascii> ("\x1bx") and Alt+<utf8> ("\x1bλ") decode in a single pass with .Alt modifier
	given.clean_input_stream()
	upon.parsing_raw_slice("\x1bx", is_timeout = false)
	then.parse_status_is(.Ok, expected_consumed = 2)
	then.parsed_key_at_is(0, .Rune, {.Alt}, 'x')

	upon.parsing_raw_slice("\x1bλ", is_timeout = false)
	then.parse_status_is(.Ok, expected_consumed = 3)
	then.parsed_key_at_is(1, .Rune, {.Alt}, 'λ')

	// 5. Incomplete CSI ("\x1b[") and SS3 ("\x1bO") wait for Need_More before timeout,
	//    and fall back to Alt+[ and Alt+O if the escape timeout fires
	given.clean_input_stream()
	upon.parsing_raw_slice("\x1b[", is_timeout = false)
	then.parse_status_is(.Need_More, expected_consumed = 0)
	upon.parsing_raw_slice("\x1b[", is_timeout = true)
	then.parse_status_is(.Ok, expected_consumed = 2)
	then.parsed_key_at_is(0, .Rune, {.Alt}, '[')

	upon.parsing_raw_slice("\x1bO", is_timeout = false)
	then.parse_status_is(.Need_More, expected_consumed = 0)
	upon.parsing_raw_slice("\x1bO", is_timeout = true)
	then.parse_status_is(.Ok, expected_consumed = 2)
	then.parsed_key_at_is(1, .Rune, {.Alt}, 'O')

	// 6. 1-byte split read reassembly across CSI, SS3, Shift+Tab, Tilde keys, and multi-byte UTF-8
	given.clean_input_stream()
	upon.feeding_byte_by_byte("\x1b[1;5C\x1bOP\x1b[Z\x1b[5;2~🚀")
	then.parsed_event_count_is(5)
	then.parsed_key_at_is(0, .Right, {.Ctrl})
	then.parsed_key_at_is(1, .F1)
	then.parsed_key_at_is(2, .Tab, {.Shift})
	then.parsed_key_at_is(3, .Page_Up, {.Shift})
	then.parsed_key_at_is(4, .Rune, {}, '🚀')
}

@(test)
@(scenario)
spec_kitty_keyboard_protocol_csi_u_chords_releases_and_text_synthesis :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	given.clean_input_stream()

	// 1. Kitty shifted ASCII ("\x1b[97:65;2u") synthesizes uppercase text "A"
	upon.feeding_byte_by_byte("\x1b[97:65;2u")
	then.parsed_kitty_key_at_is(0, 'a', 'A', 0, {.Shift}, .Press, "A")
	then.parsed_key_at_is(0, .Rune, {.Shift}, 'A', .Press)

	// 2. Kitty base-layout chord ("\x1b[1089::99;5u" -> Cyrillic 'с' with base layout 'c' and Ctrl)
	upon.feeding_byte_by_byte("\x1b[1089::99;5u")
	then.parsed_kitty_key_at_is(1, 'с', 0, 'c', {.Ctrl}, .Press, "")

	// 3. Kitty key repeat ("\x1b[106;1:2u") and key release ("\x1b[106;1:3u")
	upon.feeding_byte_by_byte("\x1b[106;1:2u\x1b[106;1:3u")
	then.parsed_kitty_key_at_is(2, 'j', 0, 0, {}, .Repeat, "j")
	then.parsed_kitty_key_at_is(3, 'j', 0, 0, {}, .Release, "j")

	// 4. Kitty explicit multi-codepoint associated text ("\x1b[97;1;229:97u" -> "åa")
	upon.feeding_byte_by_byte("\x1b[97;1;229:97u")
	then.parsed_kitty_key_at_is(4, 'a', 0, 0, {}, .Press, "åa")

	// 5. Kitty Private Use Area functional keys (57364 = F1, 57427 = KP_Begin, 57441 = Left_Shift)
	//    and capability query response "\x1b[?29u" (ignored)
	upon.feeding_byte_by_byte("\x1b[?29u\x1b[57364;5u\x1b[57427u\x1b[57441;2u")
	then.parsed_event_count_is(8)
	then.parsed_key_at_is(5, .F1, {.Ctrl})
	then.parsed_key_at_is(6, .KP_Begin)
	then.parsed_key_at_is(7, .Left_Shift, {.Shift})
}

@(test)
@(scenario)
spec_sgr_1006_and_x10_mouse_press_drag_release_wheel_and_negative_coords :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	given.clean_input_stream()

	// 1. SGR 1006 Left press (1-based 15,8 -> 0-based 14,7), Shift+Ctrl drag (button_mask = 32|16|4 = 52), and release ('m')
	upon.feeding_byte_by_byte("\x1b[<0;15;8M\x1b[<52;22;9M\x1b[<0;22;9m")
	then.parsed_event_count_is(3)
	then.parsed_mouse_at_is(0, 14, 7, .Left, .Press)
	then.parsed_mouse_at_is(1, 21, 8, .Left, .Drag, {.Shift, .Ctrl})
	then.parsed_mouse_at_is(2, 21, 8, .Left, .Release)

	// 2. SGR 1006 Wheel_Up (64) and Wheel_Down (65), plus hover Motion (35 = 32|3)
	upon.feeding_byte_by_byte("\x1b[<64;10;20M\x1b[<65;10;20M\x1b[<35;5;6M")
	then.parsed_event_count_is(6)
	then.parsed_mouse_at_is(3, 9, 19, .Wheel_Up, .Press)
	then.parsed_mouse_at_is(4, 9, 19, .Wheel_Down, .Press)
	then.parsed_mouse_at_is(5, 4, 5, .None, .Motion)

	// 3. SGR 1006 negative out-of-window drag coordinates ("\x1b[<32;-5;-2M")
	upon.feeding_byte_by_byte("\x1b[<32;-5;-2M")
	then.parsed_mouse_at_is(6, -5, -2, .Left, .Drag)

	// 4. Legacy 6-byte X10 mouse ("\x1b[M !*" -> btn=0, x=33-32=1->0, y=42-32=10->9)
	upon.parsing_raw_slice("\x1b[M !", is_timeout = false)
	then.parse_status_is(.Need_More, expected_consumed = 0)
	upon.feeding_byte_by_byte("\x1b[M !*")
	then.parsed_mouse_at_is(7, 0, 9, .Left, .Press)
}

@(test)
@(scenario)
spec_bracketed_paste_focus_in_out_xtwinops_resize_and_malformed_recovery :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	given.clean_input_stream()

	// 1. Bracketed paste split across chunks waits until "\x1b[201~" arrives
	upon.feeding_stream_chunk("\x1b[200~hello ")
	then.parse_status_is(.Need_More)
	then.parsed_event_count_is(0)

	upon.feeding_stream_chunk("λ world\x1b[201~")
	then.parsed_event_count_is(1)
	then.parsed_paste_at_is(0, "hello λ world", .Complete)

	// 2. Focus In ("\x1b[I"), Focus Out ("\x1b[O"), and XTWINOPS resize ("\x1b[48;42;132;840;1320t")
	upon.feeding_byte_by_byte("\x1b[I\x1b[O\x1b[48;42;132;840;1320t")
	then.parsed_event_count_is(4)
	then.parsed_focus_at_is(1, true)
	then.parsed_focus_at_is(2, false)
	then.parsed_resize_at_is(3, 132, 42, 1320, 840)

	// 3. Ignored OSC ("\x1b]0;Title\x07"), DCS ("\x1bP1$r0m\x1b\\"), and interrupted CSI ("\x1b[12\x1b[A")
	//    recover cleanly and emit the valid trailing Key_Code.Up
	upon.feeding_byte_by_byte("\x1b]0;Title\x07\x1bP1$r0m\x1b\\\x1b[12\x1b[A")
	then.parsed_event_count_is(5)
	then.parsed_key_at_is(4, .Up)
}

@(test)
@(scenario)
spec_posix_sigwinch_self_pipe_and_nonblocking_terminal_poll :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	// Verify POSIX Terminal poll_next_event over real non-blocking pipes (no interactive TTY required)
	given.nonblocking_pipe_terminal()

	// 1. Write split CSI sequence across two writes and poll via poll_next_event
	upon.writing_to_terminal_pipe("\x1b[1;")
	upon.writing_to_terminal_pipe("5C")
	then.polled_terminal_key_is(50, .Right, {.Ctrl})

	// 2. Write a bare ESC ("\x1b") with no follow-up bytes: poll_next_event waits ESC_DISAMBIGUATE_TIMEOUT_MS (25ms)
	//    and disambiguates it as Key_Code.Escape
	upon.writing_to_terminal_pipe("\x1b")
	then.polled_terminal_key_is(50, .Escape)

	// 3. Verify atomic teardown sequence written on terminal_deinit
	then.terminal_deinit_emits_teardown(bifrost.CTL_TEARDOWN_SEQUENCE)

	// 4. Verify Win32 Console INPUT_RECORD translation (Window_Buffer_Size, UTF-16 surrogate pairs, VK fallback, Focus)
	given.clean_input_stream()
	upon.feeding_win32_console_record({kind = .Window_Buffer_Size, window_cols = 140, window_rows = 45})
	upon.feeding_win32_console_record({kind = .Key, key_down = true, repeat_count = 1, unicode_char = 0xD83D})
	upon.feeding_win32_console_record({kind = .Key, key_down = true, repeat_count = 1, unicode_char = 0xDE80})
	upon.feeding_win32_console_record({kind = .Key, key_down = true, repeat_count = 1, virtual_key_code = 0x26})
	upon.feeding_win32_console_record({kind = .Focus, focused = true})
	then.parsed_event_count_is(4)
	then.parsed_resize_at_is(0, 140, 45)
	then.parsed_key_at_is(1, .Rune, {}, '🚀')
	then.parsed_key_at_is(2, .Up)
	then.parsed_focus_at_is(3, true)
}

@(test)
@(scenario)
spec_end_to_end_ansi_stream_drives_bifrost_ui_text_input_and_mouse_scroll :: proc(t: ^testing.T) {
	s := scenario(t, w = 50, h = 12)

	last_slice: bifrost.Virtual_Slice

	build_ui :: proc(s: ^Suite_Ctx, out_slice: ^bifrost.Virtual_Slice, events: ..bifrost.Input_Event) {
		_ = s
		_ = out_slice
		upon.rendering_frame_with_events(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
			sc := current_scenario()
			if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
				bifrost.ui_text_input(ctx, scr, &sc.input, "filter_box", {
					width          = bifrost.grow(1),
					height         = bifrost.fixed(3),
					border         = .Rounded,
					title          = "Search",
					linked_list_id = "log_list",
				})
				vslice: bifrost.Virtual_Slice
				if bifrost.ui_virtual_list(ctx, scr, &sc.input, "log_list", 100, {
					title         = "Logs",
					border        = .Plain,
					scroll_step   = 2,
					fallback_rows = 7,
				}, &vslice) {
					for r := vslice.start_row; r < vslice.end_row; r += 1 {
						bifrost.ui_label(ctx, scr, "row", "Entry")
					}
				}
			}
		}, ..events)
	}

	// Frame 1: Mount UI and focus filter_box
	build_ui(s.ctx, &last_slice)
	then.focused_widget_is("filter_box")

	// Feed a multiplexed burst of Kitty CSI u ("A"), bracketed paste ("lpha-λ"), Ctrl+W,
	// Down arrow ("\x1b[B"), and SGR 1006 Wheel_Down ("\x1b[<65;10;6M")
	given.clean_input_stream()
	upon.feeding_byte_by_byte("\x1b[97:65;2u\x1b[200~lpha-λ beta\x1b[201~\x17\x1b[B\x1b[<65;10;6M")
	then.parsed_event_count_is(5)

	build_ui(s.ctx, &last_slice, ..s.parsed_events[:])
	// "Alpha-λ beta" followed by Ctrl+W (0x17) leaves "Alpha-λ "
	then.text_input_value_is("filter_box", "Alpha-λ ")
	// Down arrow moved selected_row from 0 -> 1, and SGR Wheel_Down scrolled offset by +2
	then.virtual_scroll_is("log_list", expected_offset = 2, expected_selected = 1)
}

