#+build !windows
package bifrost

import "core:c"
import "core:sys/posix"

// =============================================================================
// POSIX Terminal Backend (termios, ioctl TIOCGWINSZ, SIGWINCH Self-Pipe)
// =============================================================================

Terminal_FD         :: posix.FD
INVALID_TERMINAL_FD :: posix.FD(-1)

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

Terminal :: struct {
	in_fd:                Terminal_FD,
	out_fd:               Terminal_FD,
	orig_termios:         posix.termios,
	resize_pipe:          [2]Terminal_FD, // [0] = read end (polled by sleipnir), [1] = write end (SIGWINCH)
	opts:                 Terminal_Options,
	raw_active:           bool,
	sigwinch_active:      bool,
	fallback_winsize:     Resize_Event,
	utf16_high_surrogate: u16,
	read_buf:             [4096]byte,
	read_len:             int,
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

terminal_init :: proc(
	term: ^Terminal,
	opts := DEFAULT_TERMINAL_OPTIONS,
	in_fd: Terminal_FD = posix.STDIN_FILENO,
	out_fd: Terminal_FD = posix.STDOUT_FILENO,
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
	if setup_err := emit_terminal_setup_sequences(out_fd, opts); setup_err != .None {
		terminal_deinit(term)
		return setup_err
	}

	return .None
}

terminal_deinit :: proc(term: ^Terminal) {
	if term == nil {
		return
	}

	// 1. Write full escape sequence teardown in a single atomic write
	if term.out_fd >= 0 {
		if term.opts.sgr_pixels {
			_ = write_all_fd(term.out_fd, SGR_PIXEL_MOUSE_DISABLE)
		}
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

terminal_get_winsize :: proc(fd: Terminal_FD) -> (ev: Resize_Event, err: Terminal_Error) {
	if fd < 0 {
		return {}, .Ioctl_Winsize_Failed
	}
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
drain_resize_notification :: proc(term: ^Terminal) -> (ev: Resize_Event, has_ev: bool) {
	if term.resize_pipe[0] >= 0 {
		drain_buf: [64]byte
		for {
			n := posix.read(term.resize_pipe[0], &drain_buf[0], len(drain_buf))
			if n <= 0 {
				break
			}
		}
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
	space := len(term.read_buf) - term.read_len
	if space == 0 {
		// Buffer overflow guard on pathological unterminated sequence
		term.read_len = 0
		space = len(term.read_buf)
	}

	for {
		n := posix.read(term.in_fd, &term.read_buf[term.read_len], uint(space))
		if n < 0 {
			errno := posix.errno()
			if errno == .EINTR {
				continue
			}
			if errno == .EAGAIN {
				return .None
			}
			return .Read_Failed
		}
		if n == 0 {
			return .Read_Failed
		}
		term.read_len += int(n)
		return .None
	}
}

@(private)
write_all_fd :: proc(fd: Terminal_FD, data: string) -> Terminal_Error {
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

// =============================================================================
// Cross-Platform Pipe Helpers (Used by Headless Non-Blocking Pipe Poll Specs)
// =============================================================================

terminal_pipe_open :: proc() -> (fds: [2]Terminal_FD, err: Terminal_Error) {
	if posix.pipe(&fds) != .OK {
		return {-1, -1}, .Pipe_Create_Failed
	}
	return fds, .None
}

terminal_pipe_close :: proc(fds: ^[2]Terminal_FD) {
	if fds == nil {
		return
	}
	if fds[0] >= 0 {
		_ = posix.close(fds[0])
		fds[0] = -1
	}
	if fds[1] >= 0 {
		_ = posix.close(fds[1])
		fds[1] = -1
	}
}

terminal_fd_write :: proc(fd: Terminal_FD, data: []byte) -> (int, Terminal_Error) {
	if len(data) == 0 {
		return 0, .None
	}
	n := posix.write(fd, &data[0], uint(len(data)))
	if n < 0 {
		return 0, .Write_Failed
	}
	return int(n), .None
}

terminal_fd_read :: proc(fd: Terminal_FD, buf: []byte) -> (int, Terminal_Error) {
	if len(buf) == 0 {
		return 0, .None
	}
	n := posix.read(fd, &buf[0], uint(len(buf)))
	if n < 0 {
		return 0, .Read_Failed
	}
	return int(n), .None
}
