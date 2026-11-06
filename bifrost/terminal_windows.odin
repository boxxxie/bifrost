#+build windows
package bifrost

import win32 "core:sys/windows"

// =============================================================================
// Windows Console VT Terminal Backend (SetConsoleMode, ReadConsoleInputW, Pipes)
// =============================================================================

Terminal_FD         :: win32.HANDLE
INVALID_TERMINAL_FD :: win32.INVALID_HANDLE_VALUE

WIN32_ENABLE_EXTENDED_FLAGS :: win32.DWORD(0x0080)
WIN32_UTF8_CODEPAGE         :: win32.CODEPAGE(65001)

Terminal :: struct {
	in_fd:                Terminal_FD,
	out_fd:               Terminal_FD,
	orig_in_mode:         win32.DWORD,
	orig_out_mode:        win32.DWORD,
	orig_in_cp:           win32.CODEPAGE,
	orig_out_cp:          win32.CODEPAGE,
	resize_pipe:          [2]Terminal_FD, // [0] = read end, [1] = write end
	opts:                 Terminal_Options,
	raw_active:           bool,
	sigwinch_active:      bool,
	has_pending_resize:   bool,
	pending_resize:       Resize_Event,
	fallback_winsize:     Resize_Event,
	utf16_high_surrogate: u16,
	read_buf:             [4096]byte,
	read_len:             int,
}

@(private)
g_sigwinch_write_fd: Terminal_FD = INVALID_TERMINAL_FD

@(private)
is_valid_handle :: #force_inline proc "contextless" (h: Terminal_FD) -> bool {
	return h != nil && h != win32.INVALID_HANDLE_VALUE
}

// Triggers the resize pipe notification (used by deterministic tests and resize callbacks).
terminal_notify_sigwinch :: proc "contextless" (term: ^Terminal = nil) {
	target := g_sigwinch_write_fd
	if term != nil && is_valid_handle(term.resize_pipe[1]) {
		target = term.resize_pipe[1]
	}
	if is_valid_handle(target) {
		b: [1]byte = {1}
		written: win32.DWORD
		_ = win32.WriteFile(target, &b[0], 1, &written, nil)
	}
}

terminal_init :: proc(
	term: ^Terminal,
	opts := DEFAULT_TERMINAL_OPTIONS,
	in_fd: Terminal_FD = INVALID_TERMINAL_FD,
	out_fd: Terminal_FD = INVALID_TERMINAL_FD,
) -> Terminal_Error {
	actual_in := in_fd
	if !is_valid_handle(actual_in) {
		actual_in = win32.GetStdHandle(win32.STD_INPUT_HANDLE)
	}
	actual_out := out_fd
	if !is_valid_handle(actual_out) {
		actual_out = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)
	}

	term^ = {
		in_fd       = actual_in,
		out_fd      = actual_out,
		resize_pipe = {INVALID_TERMINAL_FD, INVALID_TERMINAL_FD},
		opts        = opts,
	}

	if !is_valid_handle(actual_in) || !is_valid_handle(actual_out) {
		return .Termios_Get_Failed
	}

	// 1. Save original console modes and codepages
	if !win32.GetConsoleMode(actual_in, &term.orig_in_mode) {
		return .Termios_Get_Failed
	}
	if !win32.GetConsoleMode(actual_out, &term.orig_out_mode) {
		return .Termios_Get_Failed
	}
	term.orig_in_cp  = win32.GetConsoleCP()
	term.orig_out_cp = win32.GetConsoleOutputCP()

	// 2. Enable UTF-8 codepages and Console Virtual Terminal Processing / Input
	_ = win32.SetConsoleCP(WIN32_UTF8_CODEPAGE)
	_ = win32.SetConsoleOutputCP(WIN32_UTF8_CODEPAGE)

	raw_in_mode := win32.ENABLE_VIRTUAL_TERMINAL_INPUT | win32.ENABLE_WINDOW_INPUT | WIN32_ENABLE_EXTENDED_FLAGS
	if opts.mouse {
		raw_in_mode |= win32.ENABLE_MOUSE_INPUT
	}
	if !win32.SetConsoleMode(actual_in, raw_in_mode) {
		_ = win32.SetConsoleCP(term.orig_in_cp)
		_ = win32.SetConsoleOutputCP(term.orig_out_cp)
		return .Termios_Set_Failed
	}

	raw_out_mode := term.orig_out_mode |
		win32.ENABLE_PROCESSED_OUTPUT |
		win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
		win32.DISABLE_NEWLINE_AUTO_RETURN
	if !win32.SetConsoleMode(actual_out, raw_out_mode) {
		_ = win32.SetConsoleMode(actual_in, term.orig_in_mode)
		_ = win32.SetConsoleCP(term.orig_in_cp)
		_ = win32.SetConsoleOutputCP(term.orig_out_cp)
		return .Termios_Set_Failed
	}
	term.raw_active = true

	// 3. Initialize resize notification pipe
	if pipe_err := terminal_init_sigwinch_pipe(term); pipe_err != .None {
		terminal_deinit(term)
		return pipe_err
	}

	// 4. Emit terminal mode activation sequences
	if setup_err := emit_terminal_setup_sequences(actual_out, opts); setup_err != .None {
		terminal_deinit(term)
		return setup_err
	}

	return .None
}

terminal_deinit :: proc(term: ^Terminal) {
	if term == nil {
		return
	}

	saved_out_fd := term.out_fd

	// 1. Write full escape sequence teardown in a single atomic write
	if is_valid_handle(term.out_fd) {
		_ = write_all_fd(term.out_fd, CTL_TEARDOWN_SEQUENCE)
		term.out_fd = INVALID_TERMINAL_FD
	}

	// 2. Close resize notification pipe handles
	if term.sigwinch_active {
		g_sigwinch_write_fd = INVALID_TERMINAL_FD
		term.sigwinch_active = false
	}

	if is_valid_handle(term.resize_pipe[0]) {
		_ = win32.CloseHandle(term.resize_pipe[0])
		term.resize_pipe[0] = INVALID_TERMINAL_FD
	}
	if is_valid_handle(term.resize_pipe[1]) {
		_ = win32.CloseHandle(term.resize_pipe[1])
		term.resize_pipe[1] = INVALID_TERMINAL_FD
	}

	// 3. Restore original console modes and codepages
	if term.raw_active {
		if is_valid_handle(term.in_fd) {
			_ = win32.SetConsoleMode(term.in_fd, term.orig_in_mode)
		}
		if is_valid_handle(saved_out_fd) {
			_ = win32.SetConsoleMode(saved_out_fd, term.orig_out_mode)
		}
		if term.orig_in_cp != win32.CODEPAGE(0) {
			_ = win32.SetConsoleCP(term.orig_in_cp)
		}
		if term.orig_out_cp != win32.CODEPAGE(0) {
			_ = win32.SetConsoleOutputCP(term.orig_out_cp)
		}
		term.raw_active = false
	}
}

terminal_init_sigwinch_pipe :: proc(term: ^Terminal) -> Terminal_Error {
	if !win32.CreatePipe(&term.resize_pipe[0], &term.resize_pipe[1], nil, 0) {
		term.resize_pipe = {INVALID_TERMINAL_FD, INVALID_TERMINAL_FD}
		return .Pipe_Create_Failed
	}
	g_sigwinch_write_fd = term.resize_pipe[1]
	term.sigwinch_active = true
	return .None
}

terminal_get_winsize :: proc(fd: Terminal_FD) -> (ev: Resize_Event, err: Terminal_Error) {
	if !is_valid_handle(fd) {
		return {}, .Ioctl_Winsize_Failed
	}
	info: win32.CONSOLE_SCREEN_BUFFER_INFO
	if !win32.GetConsoleScreenBufferInfo(fd, &info) {
		return {}, .Ioctl_Winsize_Failed
	}
	w := i32(info.srWindow.Right - info.srWindow.Left + 1)
	h := i32(info.srWindow.Bottom - info.srWindow.Top + 1)
	if w <= 0 || h <= 0 {
		return {}, .Ioctl_Winsize_Failed
	}
	return Resize_Event{
		width   = w,
		height  = h,
		x_pixel = 0,
		y_pixel = 0,
	}, .None
}

@(private)
peek_pipe_avail :: proc(h: Terminal_FD) -> u32 {
	if !is_valid_handle(h) {
		return 0
	}
	avail: u32 = 0
	if !win32.PeekNamedPipe(h, nil, 0, nil, &avail, nil) {
		return 0
	}
	return avail
}

@(private)
poll_tty_and_sigwinch :: proc(
	term: ^Terminal,
	timeout_ms: i32,
) -> (
	stdin_ready: bool,
	resize_ready: bool,
	err: Terminal_Error,
) {
	if term.has_pending_resize || peek_pipe_avail(term.resize_pipe[0]) > 0 {
		resize_ready = true
	}

	mode: win32.DWORD
	is_console := is_valid_handle(term.in_fd) && bool(win32.GetConsoleMode(term.in_fd, &mode))

	if !is_console {
		// Anonymous pipe or redirected handle polling via PeekNamedPipe
		if peek_pipe_avail(term.in_fd) > 0 {
			stdin_ready = true
		}
		if stdin_ready || resize_ready || timeout_ms == 0 {
			return stdin_ready, resize_ready, .None
		}

		elapsed: i32 = 0
		for timeout_ms < 0 || elapsed < timeout_ms {
			win32.Sleep(1)
			elapsed += 1
			if peek_pipe_avail(term.resize_pipe[0]) > 0 {
				resize_ready = true
			}
			if peek_pipe_avail(term.in_fd) > 0 {
				stdin_ready = true
			}
			if stdin_ready || resize_ready {
				return stdin_ready, resize_ready, .None
			}
		}
		return false, false, .None
	}

	// Real Win32 Console input handle polling via WaitForSingleObject + ReadConsoleInputW
	if resize_ready {
		return false, true, .None
	}

	remaining_ms := timeout_ms
	for {
		dw_timeout := win32.INFINITE if remaining_ms < 0 else win32.DWORD(remaining_ms)
		wait_rc := win32.WaitForSingleObject(term.in_fd, dw_timeout)
		if wait_rc == win32.WAIT_TIMEOUT {
			if peek_pipe_avail(term.resize_pipe[0]) > 0 {
				return false, true, .None
			}
			return false, false, .None
		}
		if wait_rc != win32.WAIT_OBJECT_0 {
			return false, false, .Poll_Failed
		}

		// Drain available Console INPUT_RECORDs
		num_events: win32.DWORD = 0
		if !win32.GetNumberOfConsoleInputEvents(term.in_fd, &num_events) {
			return false, false, .Read_Failed
		}

		prev_len := term.read_len
		for i: win32.DWORD = 0; i < num_events; i += 1 {
			raw_rec: win32.INPUT_RECORD
			events_read: win32.DWORD = 0
			if !win32.ReadConsoleInputW(term.in_fd, &raw_rec, 1, &events_read) || events_read == 0 {
				break
			}

			rec := Win32_Console_Record{
				kind = Win32_Console_Event_Kind(u16(raw_rec.EventType)),
			}
			#partial switch raw_rec.EventType {
			case .KEY_EVENT:
				ke := raw_rec.Event.KeyEvent
				rec.key_down          = bool(ke.bKeyDown)
				rec.repeat_count      = u16(ke.wRepeatCount)
				rec.virtual_key_code  = u16(ke.wVirtualKeyCode)
				rec.unicode_char      = u16(ke.uChar.UnicodeChar)
				rec.control_key_state = transmute(u32)ke.dwControlKeyState
			case .WINDOW_BUFFER_SIZE_EVENT:
				we := raw_rec.Event.WindowBufferSizeEvent
				rec.window_cols = i16(we.dwSize.X)
				rec.window_rows = i16(we.dwSize.Y)
			case .FOCUS_EVENT:
				fe := raw_rec.Event.FocusEvent
				rec.focused = bool(fe.bSetFocus)
			}

			rsz_ev, has_rsz := terminal_feed_win32_console_record(term, rec)
			if has_rsz {
				term.pending_resize     = rsz_ev
				term.has_pending_resize = true
				resize_ready            = true
			}
		}

		stdin_ready = (term.read_len > prev_len)
		if stdin_ready || resize_ready || remaining_ms == 0 {
			return stdin_ready, resize_ready, .None
		}
		if remaining_ms > 0 {
			remaining_ms = 0
		}
	}
}

@(private)
drain_resize_notification :: proc(term: ^Terminal) -> (ev: Resize_Event, has_ev: bool) {
	if is_valid_handle(term.resize_pipe[0]) {
		drain_buf: [64]byte
		for {
			avail := peek_pipe_avail(term.resize_pipe[0])
			if avail == 0 {
				break
			}
			to_read := min(avail, u32(len(drain_buf)))
			n_read: win32.DWORD = 0
			if !win32.ReadFile(term.resize_pipe[0], &drain_buf[0], to_read, &n_read, nil) || n_read == 0 {
				break
			}
		}
	}

	if term.has_pending_resize {
		term.has_pending_resize = false
		return term.pending_resize, true
	}

	ws_ev, ws_err := terminal_get_winsize(term.out_fd)
	if ws_err == .None {
		return ws_ev, true
	}
	if term.fallback_winsize.width > 0 && term.fallback_winsize.height > 0 {
		return term.fallback_winsize, true
	}
	return {}, false
}

@(private)
read_tty_into_buffer :: proc(term: ^Terminal) -> Terminal_Error {
	mode: win32.DWORD
	if is_valid_handle(term.in_fd) && bool(win32.GetConsoleMode(term.in_fd, &mode)) {
		// Console records were already translated into term.read_buf by poll_tty_and_sigwinch
		return .None
	}

	avail := peek_pipe_avail(term.in_fd)
	if avail == 0 {
		return .None
	}

	space := len(term.read_buf) - term.read_len
	if space == 0 {
		term.read_len = 0
		space = len(term.read_buf)
	}

	to_read := min(avail, u32(space))
	n_read: win32.DWORD = 0
	if !win32.ReadFile(term.in_fd, &term.read_buf[term.read_len], to_read, &n_read, nil) {
		return .Read_Failed
	}
	if n_read == 0 {
		return .Read_Failed
	}
	term.read_len += int(n_read)
	return .None
}

@(private)
write_all_fd :: proc(fd: Terminal_FD, data: string) -> Terminal_Error {
	if !is_valid_handle(fd) {
		return .Write_Failed
	}
	bytes := transmute([]byte)data
	written := 0
	for written < len(bytes) {
		rem := win32.DWORD(len(bytes) - written)
		n_written: win32.DWORD = 0
		if !win32.WriteFile(fd, &bytes[written], rem, &n_written, nil) {
			return .Write_Failed
		}
		written += int(n_written)
	}
	return .None
}

// =============================================================================
// Cross-Platform Pipe Helpers (Used by Headless Non-Blocking Pipe Poll Specs)
// =============================================================================

terminal_pipe_open :: proc() -> (fds: [2]Terminal_FD, err: Terminal_Error) {
	if !win32.CreatePipe(&fds[0], &fds[1], nil, 0) {
		return {INVALID_TERMINAL_FD, INVALID_TERMINAL_FD}, .Pipe_Create_Failed
	}
	return fds, .None
}

terminal_pipe_close :: proc(fds: ^[2]Terminal_FD) {
	if fds == nil {
		return
	}
	if is_valid_handle(fds[0]) {
		_ = win32.CloseHandle(fds[0])
		fds[0] = INVALID_TERMINAL_FD
	}
	if is_valid_handle(fds[1]) {
		_ = win32.CloseHandle(fds[1])
		fds[1] = INVALID_TERMINAL_FD
	}
}

terminal_fd_write :: proc(fd: Terminal_FD, data: []byte) -> (int, Terminal_Error) {
	if len(data) == 0 {
		return 0, .None
	}
	if !is_valid_handle(fd) {
		return 0, .Write_Failed
	}
	written: win32.DWORD = 0
	if !win32.WriteFile(fd, &data[0], win32.DWORD(len(data)), &written, nil) {
		return 0, .Write_Failed
	}
	return int(written), .None
}

terminal_fd_read :: proc(fd: Terminal_FD, buf: []byte) -> (int, Terminal_Error) {
	if len(buf) == 0 {
		return 0, .None
	}
	if !is_valid_handle(fd) {
		return 0, .Read_Failed
	}
	n_read: win32.DWORD = 0
	if !win32.ReadFile(fd, &buf[0], win32.DWORD(len(buf)), &n_read, nil) {
		return 0, .Read_Failed
	}
	return int(n_read), .None
}
