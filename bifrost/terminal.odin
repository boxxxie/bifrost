package bifrost

import "core:strings"
import "core:unicode/utf8"

// =============================================================================
// Control Sequences (Ported from libvaxis ctlseqs.zig)
// =============================================================================

CTL_ENTER_ALT_SCREEN      :: "\x1b[?1049h"
CTL_EXIT_ALT_SCREEN       :: "\x1b[?1049l"
CTL_HIDE_CURSOR           :: "\x1b[?25l"
CTL_SHOW_CURSOR           :: "\x1b[?25h"
CTL_SGR_RESET             :: "\x1b[m"
CTL_HOME                  :: "\x1b[H"
CTL_ERASE_BELOW_CURSOR    :: "\x1b[J"

CTL_MOUSE_SET             :: "\x1b[?1000;1002;1003;1006h"
CTL_MOUSE_RESET           :: "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l"

CTL_BRACKETED_PASTE_SET   :: "\x1b[?2004h"
CTL_BRACKETED_PASTE_RESET :: "\x1b[?2004l"

CTL_FOCUS_SET             :: "\x1b[?1004h"
CTL_FOCUS_RESET           :: "\x1b[?1004l"

// Kitty Keyboard Protocol: flags = 29 (disambiguate=1 | alternate=4 | all_ctl=8 | text=16)
CTL_KITTY_KBD_PUSH        :: "\x1b[>29u"
CTL_KITTY_KBD_POP         :: "\x1b[<u"

CTL_SYNC_SET              :: "\x1b[?2026h"
CTL_SYNC_RESET            :: "\x1b[?2026l"

// Complete deterministic setup sequence when all default options are enabled
CTL_SETUP_SEQUENCE ::
	"\x1b[?1049h" +
	"\x1b[?25l" +
	"\x1b[?2004h" +
	"\x1b[?1004h" +
	"\x1b[?1000;1002;1003;1006h" +
	"\x1b[>29u"

// Complete deterministic teardown sequence
CTL_TEARDOWN_SEQUENCE ::
	"\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l" +
	"\x1b[?2004l" +
	"\x1b[?1004l" +
	"\x1b[<u" +
	"\x1b[m" +
	"\x1b[?25h" +
	"\x1b[?1049l"

// =============================================================================
// Terminal Options & Errors
// =============================================================================

Terminal_Error :: enum u8 {
	None = 0,
	Termios_Get_Failed,
	Termios_Set_Failed,
	Pipe_Create_Failed,
	Fcntl_Failed,
	Sigaction_Failed,
	Ioctl_Winsize_Failed,
	Write_Failed,
	Poll_Failed,
	Read_Failed,
}

Terminal_Options :: struct {
	alt_screen:      bool,
	mouse:           bool,
	bracketed_paste: bool,
	focus_events:    bool,
	kitty_keyboard:  bool,
	hide_cursor:     bool,
}

DEFAULT_TERMINAL_OPTIONS :: Terminal_Options{
	alt_screen      = true,
	mouse           = true,
	bracketed_paste = true,
	focus_events    = true,
	kitty_keyboard  = true,
	hide_cursor     = true,
}

ESC_DISAMBIGUATE_TIMEOUT_MS :: 25

// Unified window size query overload accepting either `^Terminal` or `Terminal_FD`.
terminal_winsize_from_term :: proc(term: ^Terminal) -> (ev: Resize_Event, err: Terminal_Error) {
	if term == nil {
		return {}, .Ioctl_Winsize_Failed
	}
	ev, err = terminal_get_winsize(term.out_fd)
	if err != .None && term.fallback_winsize.width > 0 && term.fallback_winsize.height > 0 {
		return term.fallback_winsize, .None
	}
	return ev, err
}

terminal_winsize :: proc {
	terminal_winsize_from_term,
	terminal_get_winsize,
}

// =============================================================================
// Sleipnir Input Actor Poll + Streaming Parse Loop
// =============================================================================

// Polls both STDIN and the resize notification channel without busy-waiting,
// feeding bytes into parse_ansi_input and handling bare ESC disambiguation.
terminal_poll_event :: proc(
	term: ^Terminal,
	timeout_ms: i32 = -1,
) -> (
	event: Input_Event,
	has_event: bool,
	err: Terminal_Error,
) {
	for {
		// 1. Attempt to parse any bytes already buffered from a previous read
		if term.read_len > 0 {
			ev, consumed, status := parse_ansi_input(term.read_buf[:term.read_len], false)
			switch status {
			case .Ok:
				if paste, is_paste := ev.(Paste_Event); is_paste && len(paste.text) > 0 {
					paste.text = strings.clone(paste.text, context.temp_allocator)
					ev = paste
				}
				consume_buffer_prefix(term, consumed)
				return ev, true, .None
			case .Ignored, .Malformed:
				consume_buffer_prefix(term, max(consumed, 1))
				continue
			case .Need_More:
				// Wait up to ESC_DISAMBIGUATE_TIMEOUT_MS for continuation bytes
				ready, _, poll_err := poll_tty_and_sigwinch(term, ESC_DISAMBIGUATE_TIMEOUT_MS)
				if poll_err != .None {
					return nil, false, poll_err
				}
				if !ready {
					// Timeout expired with no continuation bytes: disambiguate bare ESC
					ev_to, consumed_to, status_to := parse_ansi_input(term.read_buf[:term.read_len], true)
					consume_buffer_prefix(term, max(consumed_to, 1))
					if status_to == .Ok {
						return ev_to, true, .None
					}
					continue
				}
				read_err := read_tty_into_buffer(term)
				if read_err != .None {
					return nil, false, read_err
				}
				continue
			}
		}

		// 2. Poll both STDIN and the resize channel
		stdin_ready, resize_ready, poll_err := poll_tty_and_sigwinch(term, timeout_ms)
		if poll_err != .None {
			return nil, false, poll_err
		}

		// 3. Drain coalesced resize notifications first
		if resize_ready {
			ws_ev, has_ws := drain_resize_notification(term)
			if has_ws {
				return ws_ev, true, .None
			}
		}

		if !stdin_ready {
			return nil, false, .None
		}

		// 4. Read available bytes from TTY into the remaining tail of read_buf
		read_err := read_tty_into_buffer(term)
		if read_err != .None {
			return nil, false, read_err
		}
	}
}

poll_next_event :: terminal_poll_event

// =============================================================================
// Windows Console INPUT_RECORD Translation (Cross-Platform Testable)
// =============================================================================

Win32_Console_Event_Kind :: enum u16 {
	None               = 0,
	Key                = 0x0001,
	Mouse              = 0x0002,
	Window_Buffer_Size = 0x0004,
	Menu               = 0x0008,
	Focus              = 0x0010,
}

Win32_Console_Record :: struct {
	kind:              Win32_Console_Event_Kind,
	key_down:          bool,
	repeat_count:      u16,
	virtual_key_code:  u16,
	unicode_char:      u16,
	control_key_state: u32,
	window_cols:       i16,
	window_rows:       i16,
	focused:           bool,
}

// Feeds a decoded Win32 Console INPUT_RECORD into `term.read_buf` or returns a `Resize_Event`.
terminal_feed_win32_console_record :: proc(
	term: ^Terminal,
	rec: Win32_Console_Record,
) -> (
	resize_ev: Resize_Event,
	has_resize: bool,
) {
	if term == nil {
		return {}, false
	}

	#partial switch rec.kind {
	case .Window_Buffer_Size:
		ws_ev, ws_err := terminal_get_winsize(term.out_fd)
		if ws_err == .None {
			return ws_ev, true
		}
		if rec.window_cols > 0 && rec.window_rows > 0 {
			return Resize_Event{
				width  = i32(rec.window_cols),
				height = i32(rec.window_rows),
			}, true
		}
		if term.fallback_winsize.width > 0 && term.fallback_winsize.height > 0 {
			return term.fallback_winsize, true
		}
		return {}, false

	case .Focus:
		seq := "\x1b[I" if rec.focused else "\x1b[O"
		append_bytes_to_read_buf(term, transmute([]byte)seq)
		return {}, false

	case .Key:
		if !rec.key_down {
			return {}, false
		}
		u := rec.unicode_char
		// UTF-16 high surrogate (0xD800..0xDBFF)
		if u >= 0xD800 && u <= 0xDBFF {
			term.utf16_high_surrogate = u
			return {}, false
		}
		// UTF-16 low surrogate (0xDC00..0xDFFF)
		if u >= 0xDC00 && u <= 0xDFFF {
			high := term.utf16_high_surrogate
			term.utf16_high_surrogate = 0
			if high >= 0xD800 && high <= 0xDBFF {
				cp := rune(0x10000 + ((u32(high) - 0xD800) << 10) + (u32(u) - 0xDC00))
				encoded, n := utf8.encode_rune(cp)
				append_bytes_to_read_buf(term, encoded[:n])
			}
			return {}, false
		}

		term.utf16_high_surrogate = 0
		if u != 0 {
			encoded, n := utf8.encode_rune(rune(u))
			reps := max(1, int(rec.repeat_count))
			if u == 0x1b {
				reps = 1
			}
			for _ in 0 ..< reps {
				append_bytes_to_read_buf(term, encoded[:n])
			}
			return {}, false
		}

		// Fallback Win32 Virtual-Key translation when UnicodeChar == 0
		vk_seq := win32_vk_to_ansi(rec.virtual_key_code)
		if len(vk_seq) > 0 {
			append_bytes_to_read_buf(term, transmute([]byte)vk_seq)
		}
		return {}, false
	}

	return {}, false
}

@(private)
win32_vk_to_ansi :: proc "contextless" (vk: u16) -> string {
	switch vk {
	case 0x26: return "\x1b[A"  // VK_UP
	case 0x28: return "\x1b[B"  // VK_DOWN
	case 0x27: return "\x1b[C"  // VK_RIGHT
	case 0x25: return "\x1b[D"  // VK_LEFT
	case 0x24: return "\x1b[H"  // VK_HOME
	case 0x23: return "\x1b[F"  // VK_END
	case 0x21: return "\x1b[5~" // VK_PRIOR (Page Up)
	case 0x22: return "\x1b[6~" // VK_NEXT (Page Down)
	case 0x2D: return "\x1b[2~" // VK_INSERT
	case 0x2E: return "\x1b[3~" // VK_DELETE
	case 0x70: return "\x1bOP"  // VK_F1
	case 0x71: return "\x1bOQ"  // VK_F2
	case 0x72: return "\x1bOR"  // VK_F3
	case 0x73: return "\x1bOS"  // VK_F4
	case 0x74: return "\x1b[15~" // VK_F5
	case 0x75: return "\x1b[17~" // VK_F6
	case 0x76: return "\x1b[18~" // VK_F7
	case 0x77: return "\x1b[19~" // VK_F8
	case 0x78: return "\x1b[20~" // VK_F9
	case 0x79: return "\x1b[21~" // VK_F10
	case 0x7A: return "\x1b[23~" // VK_F11
	case 0x7B: return "\x1b[24~" // VK_F12
	}
	return ""
}

@(private)
append_bytes_to_read_buf :: proc "contextless" (term: ^Terminal, data: []byte) {
	if len(data) == 0 {
		return
	}
	space := len(term.read_buf) - term.read_len
	if len(data) > space {
		term.read_len = 0
		space = len(term.read_buf)
	}
	n := min(len(data), space)
	copy(term.read_buf[term.read_len:term.read_len + n], data[:n])
	term.read_len += n
}

@(private)
consume_buffer_prefix :: proc "contextless" (term: ^Terminal, count: int) {
	if count >= term.read_len {
		term.read_len = 0
		return
	}
	remaining := term.read_len - count
	copy(term.read_buf[:remaining], term.read_buf[count:term.read_len])
	term.read_len = remaining
}

@(private)
emit_terminal_setup_sequences :: proc(out_fd: Terminal_FD, opts: Terminal_Options) -> Terminal_Error {
	if opts.alt_screen {
		write_all_fd(out_fd, CTL_ENTER_ALT_SCREEN) or_return
	}
	if opts.hide_cursor {
		write_all_fd(out_fd, CTL_HIDE_CURSOR) or_return
	}
	if opts.bracketed_paste {
		write_all_fd(out_fd, CTL_BRACKETED_PASTE_SET) or_return
	}
	if opts.focus_events {
		write_all_fd(out_fd, CTL_FOCUS_SET) or_return
	}
	if opts.mouse {
		write_all_fd(out_fd, CTL_MOUSE_SET) or_return
	}
	if opts.kitty_keyboard {
		write_all_fd(out_fd, CTL_KITTY_KBD_PUSH) or_return
	}
	return .None
}
