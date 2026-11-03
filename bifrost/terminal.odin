package bifrost

import "core:c"
import "core:strings"
import "core:sys/posix"

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
// POSIX ioctl(TIOCGWINSZ) Binding
// =============================================================================

when ODIN_OS == .Linux {
	foreign import libc "system:c"
	TIOCGWINSZ :: c.ulong(0x5413)
} else when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
	foreign import libc "system:System"
	TIOCGWINSZ :: c.ulong(0x40087468)
}

POSIX_Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

@(default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: posix.FD, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

// =============================================================================
// Terminal State & Errors
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

Terminal :: struct {
	in_fd:            posix.FD,
	out_fd:           posix.FD,
	orig_termios:     posix.termios,
	resize_pipe:      [2]posix.FD, // [0] = read end (polled by sleipnir), [1] = write end (SIGWINCH)
	opts:             Terminal_Options,
	raw_active:       bool,
	sigwinch_active:  bool,
	fallback_winsize: Resize_Event,
	read_buf:         [4096]byte,
	read_len:         int,
}

// Module-scoped write descriptor for the async-signal-safe SIGWINCH handler.
@(private)
g_sigwinch_write_fd: posix.FD = -1

@(private)
sigwinch_handler :: proc "c" (_: posix.Signal) {
	fd := g_sigwinch_write_fd
	if fd >= 0 {
		b: [1]byte = {1}
		_ = posix.write(fd, &b[0], 1)
	}
}

// Triggers the SIGWINCH self-pipe notification (used by signal handler and deterministic tests).
terminal_notify_sigwinch :: proc "contextless" (term: ^Terminal = nil) {
	if term != nil && term.resize_pipe[1] >= 0 {
		b: [1]byte = {1}
		_ = posix.write(term.resize_pipe[1], &b[0], 1)
		return
	}
	sigwinch_handler(posix.Signal(posix.SIGWINCH))
}

// =============================================================================
// Terminal Lifecycle (Init, Raw Mode, SIGWINCH Pipe, Winsize, Teardown)
// =============================================================================

terminal_init :: proc(
	term: ^Terminal,
	opts := DEFAULT_TERMINAL_OPTIONS,
	in_fd: posix.FD = posix.STDIN_FILENO,
	out_fd: posix.FD = posix.STDOUT_FILENO,
) -> Terminal_Error {
	term^ = {
		in_fd       = in_fd,
		out_fd      = out_fd,
		resize_pipe = {-1, -1},
		opts        = opts,
	}

	// 1. Enter raw termios mode
	orig, raw_err := terminal_make_raw(in_fd)
	if raw_err != .None {
		return raw_err
	}
	term.orig_termios = orig
	term.raw_active = true

	// 2. Initialize SIGWINCH self-pipe
	if pipe_err := terminal_init_sigwinch_pipe(term); pipe_err != .None {
		_ = posix.tcsetattr(in_fd, .TCSAFLUSH, &term.orig_termios)
		term.raw_active = false
		return pipe_err
	}

	// 3. Emit terminal mode activation sequences
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

terminal_deinit :: proc(term: ^Terminal) {
	if term == nil {
		return
	}

	// 1. Write full escape sequence teardown in a single atomic write
	if term.out_fd >= 0 {
		_ = write_all_fd(term.out_fd, CTL_TEARDOWN_SEQUENCE)
		term.out_fd = -1
	}

	// 2. Restore default SIGWINCH handler and close self-pipe descriptors
	if term.sigwinch_active {
		g_sigwinch_write_fd = -1
		act: posix.sigaction_t
		act.sa_handler = cast(proc "c" (posix.Signal))posix.SIG_DFL
		posix.sigemptyset(&act.sa_mask)
		_ = posix.sigaction(posix.Signal(posix.SIGWINCH), &act, nil)
		term.sigwinch_active = false
	}

	if term.resize_pipe[0] >= 0 {
		_ = posix.close(term.resize_pipe[0])
		term.resize_pipe[0] = -1
	}
	if term.resize_pipe[1] >= 0 {
		_ = posix.close(term.resize_pipe[1])
		term.resize_pipe[1] = -1
	}

	// 3. Restore original termios state with TCSAFLUSH
	if term.raw_active && term.in_fd >= 0 {
		_ = posix.tcsetattr(term.in_fd, .TCSAFLUSH, &term.orig_termios)
		term.raw_active = false
	}
}

terminal_make_raw :: proc(fd: posix.FD) -> (orig: posix.termios, err: Terminal_Error) {
	if posix.tcgetattr(fd, &orig) != .OK {
		return {}, .Termios_Get_Failed
	}

	raw := orig
	// See termios(3) and libvaxis PosixTty.makeRaw
	raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag -= {.CS6, .CS7, .PARENB}
	raw.c_cflag += {.CS8}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0

	if posix.tcsetattr(fd, .TCSAFLUSH, &raw) != .OK {
		return {}, .Termios_Set_Failed
	}
	return orig, .None
}

terminal_init_sigwinch_pipe :: proc(term: ^Terminal) -> Terminal_Error {
	if posix.pipe(&term.resize_pipe) != .OK {
		return .Pipe_Create_Failed
	}

	// Set FD_CLOEXEC and O_NONBLOCK on both pipe descriptors
	for fd in term.resize_pipe {
		if posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC)) == -1 {
			_ = posix.close(term.resize_pipe[0])
			_ = posix.close(term.resize_pipe[1])
			term.resize_pipe = {-1, -1}
			return .Fcntl_Failed
		}
		flags := posix.fcntl(fd, .GETFL)
		if flags == -1 || posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK) == -1 {
			_ = posix.close(term.resize_pipe[0])
			_ = posix.close(term.resize_pipe[1])
			term.resize_pipe = {-1, -1}
			return .Fcntl_Failed
		}
	}

	g_sigwinch_write_fd = term.resize_pipe[1]

	act: posix.sigaction_t
	act.sa_handler = sigwinch_handler
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {.RESTART}

	if posix.sigaction(posix.Signal(posix.SIGWINCH), &act, nil) != .OK {
		g_sigwinch_write_fd = -1
		_ = posix.close(term.resize_pipe[0])
		_ = posix.close(term.resize_pipe[1])
		term.resize_pipe = {-1, -1}
		return .Sigaction_Failed
	}

	term.sigwinch_active = true
	return .None
}

terminal_get_winsize :: proc(fd: posix.FD) -> (ev: Resize_Event, err: Terminal_Error) {
	ws: POSIX_Winsize
	if ioctl(fd, TIOCGWINSZ, &ws) != 0 {
		return {}, .Ioctl_Winsize_Failed
	}
	return Resize_Event{
		width   = i32(ws.ws_col),
		height  = i32(ws.ws_row),
		x_pixel = u16(ws.ws_xpixel),
		y_pixel = u16(ws.ws_ypixel),
	}, .None
}

// =============================================================================
// Sleipnir Input Actor Poll + Streaming Parse Loop
// =============================================================================

ESC_DISAMBIGUATE_TIMEOUT_MS :: 25

// Polls both STDIN_FILENO and the SIGWINCH self-pipe without busy-waiting,
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
			}
		}

		// 2. Poll both STDIN and the SIGWINCH self-pipe
		stdin_ready, resize_ready, poll_err := poll_tty_and_sigwinch(term, timeout_ms)
		if poll_err != .None {
			return nil, false, poll_err
		}

		// 3. Drain coalesced SIGWINCH notifications first
		if resize_ready {
			drain_buf: [64]byte
			for {
				n := posix.read(term.resize_pipe[0], &drain_buf[0], len(drain_buf))
				if n <= 0 {
					break
				}
			}
			ws_ev, ws_err := terminal_get_winsize(term.out_fd)
			if ws_err == .None {
				return ws_ev, true, .None
			}
			if term.fallback_winsize.width > 0 && term.fallback_winsize.height > 0 {
				return term.fallback_winsize, true, .None
			}
		}

		if !stdin_ready {
			return nil, false, .None
		}

		// 4. Read available bytes from TTY into the remaining tail of read_buf
		space := len(term.read_buf) - term.read_len
		if space == 0 {
			// Buffer overflow guard on pathological unterminated sequence
			term.read_len = 0
			space = len(term.read_buf)
		}

		n := posix.read(term.in_fd, &term.read_buf[term.read_len], uint(space))
		if n < 0 {
			errno := posix.errno()
			if errno == .EINTR || errno == .EAGAIN {
				continue
			}
			return nil, false, .Read_Failed
		}
		if n == 0 {
			return nil, false, .Read_Failed
		}
		term.read_len += int(n)
	}
}

poll_next_event :: terminal_poll_event

@(private)
poll_tty_and_sigwinch :: proc(
	term: ^Terminal,
	timeout_ms: i32,
) -> (
	stdin_ready: bool,
	resize_ready: bool,
	err: Terminal_Error,
) {
	pfds := [2]posix.pollfd{
		{fd = term.in_fd, events = {.IN}},
		{fd = term.resize_pipe[0], events = {.IN}},
	}

	rc := posix.poll(&pfds[0], 2, c.int(timeout_ms))
	if rc < 0 {
		if posix.errno() == .EINTR {
			return false, false, .None
		}
		return false, false, .Poll_Failed
	}
	if rc == 0 {
		return false, false, .None
	}

	stdin_ready = (.IN in pfds[0].revents)
	resize_ready = (.IN in pfds[1].revents)
	return stdin_ready, resize_ready, .None
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
write_all_fd :: proc(fd: posix.FD, data: string) -> Terminal_Error {
	bytes := transmute([]byte)data
	written := 0
	for written < len(bytes) {
		rem := len(bytes) - written
		n := posix.write(fd, &bytes[written], uint(rem))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return .Write_Failed
		}
		written += int(n)
	}
	return .None
}
