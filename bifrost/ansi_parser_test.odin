package bifrost

import "core:testing"

@(test)
test_bare_esc_and_ground_c0_controls :: proc(t: ^testing.T) {
	// 1. Bare ESC before timeout -> Need_More (0 bytes consumed)
	_, n0, s0 := parse_ansi_input(transmute([]byte)string("\x1b"), false)
	testing.expect_value(t, s0, Parse_Status.Need_More)
	testing.expect_value(t, n0, 0)

	// 2. Bare ESC after timeout -> Key_Code.Escape (1 byte consumed)
	ev1, n1, s1 := parse_ansi_input(transmute([]byte)string("\x1b"), true)
	testing.expect_value(t, s1, Parse_Status.Ok)
	testing.expect_value(t, n1, 1)
	testing.expect_value(t, ev1.(Key_Event).code, Key_Code.Escape)

	// 3. Ground C0 controls: Ctrl+@ (0x00), Ctrl+C (0x03), Tab (0x09), Ctrl+J (0x0A), Enter (0x0D), Backspace (0x7F)
	ev_nul, _, _ := parse_ansi_input([]byte{0x00}, false)
	testing.expect_value(t, ev_nul.(Key_Event).ch, '@')
	testing.expect_value(t, ev_nul.(Key_Event).mods, Mod_Flags{.Ctrl})

	ev_ctrl_c, _, _ := parse_ansi_input([]byte{0x03}, false)
	testing.expect_value(t, ev_ctrl_c.(Key_Event).ch, 'c')
	testing.expect_value(t, ev_ctrl_c.(Key_Event).mods, Mod_Flags{.Ctrl})

	ev_tab, _, _ := parse_ansi_input([]byte{0x09}, false)
	testing.expect_value(t, ev_tab.(Key_Event).code, Key_Code.Tab)

	ev_enter, _, _ := parse_ansi_input([]byte{0x0D}, false)
	testing.expect_value(t, ev_enter.(Key_Event).code, Key_Code.Enter)

	ev_bs, _, _ := parse_ansi_input([]byte{0x7F}, false)
	testing.expect_value(t, ev_bs.(Key_Event).code, Key_Code.Backspace)
}

@(test)
test_kitty_csi_u_and_sgr_mouse :: proc(t: ^testing.T) {
	// 1. Kitty CSI u Shift+A ("\x1b[97:65;2u")
	ev4, n4, s4 := parse_ansi_input(transmute([]byte)string("\x1b[97:65;2u"), false)
	testing.expect_value(t, s4, Parse_Status.Ok)
	testing.expect_value(t, n4, 10)
	key4 := ev4.(Key_Event)
	testing.expect_value(t, key4.codepoint, 'a')
	testing.expect_value(t, key4.shifted_codepoint, 'A')
	testing.expect_value(t, key4.mods, Mod_Flags{.Shift})
	testing.expect_value(t, key_event_text(&key4), "A")

	// 2. SGR 1006 wheel up ("\x1b[<64;10;20M")
	ev5, n5, s5 := parse_ansi_input(transmute([]byte)string("\x1b[<64;10;20M"), false)
	testing.expect_value(t, s5, Parse_Status.Ok)
	testing.expect_value(t, n5, 12)
	mouse5 := ev5.(Mouse_Event)
	testing.expect_value(t, mouse5.button, Mouse_Button.Wheel_Up)
	testing.expect_value(t, mouse5.col, i16(9))
	testing.expect_value(t, mouse5.row, i16(19))

	// 3. Mouse leave bit (0x100 = 256 -> "\x1b[<256;1;1M")
	ev_leave, _, s_leave := parse_ansi_input(transmute([]byte)string("\x1b[<256;1;1M"), false)
	testing.expect_value(t, s_leave, Parse_Status.Ok)
	testing.expect_value(t, ev_leave.(Mouse_Event).action, Mouse_Action.Leave)
}

@(test)
test_terminal_sigwinch_self_pipe_coalescing :: proc(t: ^testing.T) {
	in_pipe, in_err := terminal_pipe_open()
	testing.expect_value(t, in_err, Terminal_Error.None)
	defer terminal_pipe_close(&in_pipe)

	out_pipe, out_err := terminal_pipe_open()
	testing.expect_value(t, out_err, Terminal_Error.None)
	defer terminal_pipe_close(&out_pipe)

	term := Terminal{
		in_fd            = in_pipe[0],
		out_fd           = out_pipe[1],
		resize_pipe      = {INVALID_TERMINAL_FD, INVALID_TERMINAL_FD},
		fallback_winsize = Resize_Event{width = 120, height = 40},
	}
	err := terminal_init_sigwinch_pipe(&term)
	testing.expect_value(t, err, Terminal_Error.None)
	defer terminal_deinit(&term)

	// Fire 5 rapid SIGWINCH notifications -> coalesced into a single Resize_Event on poll_next_event
	for _ in 0 ..< 5 {
		terminal_notify_sigwinch(&term)
	}

	ev, has_ev, poll_err := poll_next_event(&term, 50)
	testing.expect_value(t, poll_err, Terminal_Error.None)
	testing.expect(t, has_ev)
	rsz := ev.(Resize_Event)
	testing.expect_value(t, rsz.width, 120)
	testing.expect_value(t, rsz.height, 40)
}

@(test)
test_win32_console_record_translation_vt_surrogates_vk_and_resize :: proc(t: ^testing.T) {
	term := Terminal{
		in_fd            = INVALID_TERMINAL_FD,
		out_fd           = INVALID_TERMINAL_FD,
		resize_pipe      = {INVALID_TERMINAL_FD, INVALID_TERMINAL_FD},
		fallback_winsize = Resize_Event{width = 100, height = 30},
	}

	// 1. Window_Buffer_Size record emits Resize_Event from record cols/rows
	rsz_ev, has_rsz := terminal_feed_win32_console_record(&term, Win32_Console_Record{
		kind        = .Window_Buffer_Size,
		window_cols = 132,
		window_rows = 44,
	})
	testing.expect(t, has_rsz)
	testing.expect_value(t, rsz_ev.width, 132)
	testing.expect_value(t, rsz_ev.height, 44)

	// 2. UTF-16 surrogate pair for '🚀' (U+1F680 -> 0xD83D, 0xDE80)
	_, _ = terminal_feed_win32_console_record(&term, Win32_Console_Record{
		kind         = .Key,
		key_down     = true,
		repeat_count = 1,
		unicode_char = 0xD83D,
	})
	testing.expect_value(t, term.read_len, 0)
	_, _ = terminal_feed_win32_console_record(&term, Win32_Console_Record{
		kind         = .Key,
		key_down     = true,
		repeat_count = 1,
		unicode_char = 0xDE80,
	})
	ev_rocket, consumed_rocket, stat_rocket := parse_ansi_input(term.read_buf[:term.read_len], false)
	testing.expect_value(t, stat_rocket, Parse_Status.Ok)
	testing.expect_value(t, ev_rocket.(Key_Event).ch, '🚀')
	consume_buffer_prefix(&term, consumed_rocket)

	// 3. Fallback VK_UP (0x26) when UnicodeChar == 0 and Focus record
	_, _ = terminal_feed_win32_console_record(&term, Win32_Console_Record{
		kind             = .Key,
		key_down         = true,
		repeat_count     = 1,
		virtual_key_code = 0x26,
	})
	_, _ = terminal_feed_win32_console_record(&term, Win32_Console_Record{
		kind    = .Focus,
		focused = false,
	})

	ev_up, consumed_up, stat_up := parse_ansi_input(term.read_buf[:term.read_len], false)
	testing.expect_value(t, stat_up, Parse_Status.Ok)
	testing.expect_value(t, ev_up.(Key_Event).code, Key_Code.Up)
	consume_buffer_prefix(&term, consumed_up)

	ev_foc, consumed_foc, stat_foc := parse_ansi_input(term.read_buf[:term.read_len], false)
	testing.expect_value(t, stat_foc, Parse_Status.Ok)
	testing.expect_value(t, ev_foc.(Focus_Event).focused, false)
	consume_buffer_prefix(&term, consumed_foc)
	testing.expect_value(t, term.read_len, 0)
}
