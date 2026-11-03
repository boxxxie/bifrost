`libvaxis` separates stateless byte-slice decoding (`Parser.zig`) from OS read/poll buffering (`Loop.zig` and `tty.zig`), making it straightforward to port into a zero-allocation, deterministic Odin architecture for `bifrost`.

---

### 1. Streaming Byte-Slice Parser & Bare `ESC` Disambiguation (`Parser.zig`, `Loop.zig`)

* **Partial Escape Sequences Across `read` Boundaries:**
In `Parser.zig`, `Parser.parse(input, paste_allocator)` never blocks or performs I/O; instead, it inspects `input` and returns `Result{ .event: ?Event, .n: usize }`:


* If a sequence is incomplete, `parse` returns `.{ .event = null, .n = 0 }`:


* **SS3 (`\x1bO`):** Returns `.n = 0` when `input.len < 3`.


* **CSI (`\x1b[`):** Scans `input[2..]` for a final byte in `0x40..=0xFF`; if `input.len < 3` or no final byte has arrived yet (or X10 mouse `\x1b[M` has `full_input.len < 6`), it returns `.n = 0`.


* **OSC (`\x1b]`):** Scans `input[2..]` for `BEL` (`0x07`) or `ST` (`\x1b\`). If neither terminator is present—or if the slice ends in a trailing `\x1b` (`i + 1 >= input.len`) that could become `\x1b\` on the next read—it returns `.n = 0`. If a bare `\x1b` is followed by anything other than `\` (`0x5c`), it consumes the malformed OSC prefix up to `i` (`.n = i, .event = null`) so the next call parses the new escape sequence.


* **DCS/SOS/PM/APC (`\x1bP`, `\x1bX`, `\x1b^`, `\x1b_`):** Searches for `\x1b\` and returns `.n = 0` until both bytes of `ST` are in the buffer.




* In `Loop.zig` (`_ttyRun`), when `result.n == 0`, the caller shifts the unconsumed tail `buf[seq_start..n]` to `buf[0..read_start]` and calls `tty.read(buf[read_start..])` to append the next kernel chunk.




* **Disambiguating Bare `ESC` (`\x1b`) vs. `Alt+<key>` vs. `\x1b[...`:**
* Inside `Parser.zig`, `parse` checks `if (input[0] == 0x1b and input.len > 1)`. If `input.len > 1` and `input[1]` is not `O`, `P`, `X`, `[`, `]`, `^`, or `_`, it emits `Key{ .codepoint = input[1], .mods = .{ .alt = true } }` and consumes `n = 2` bytes.


* If `input.len == 1` and `input[0] == 0x1b`, `Parser.zig` falls through to `parseGround(input)` and emits `Key.escape` (`n = 1`).


* Because `Parser.zig` treats a 1-byte `\x1b` as an immediate `Escape`, `Loop.zig` (`_ttyRun`) guards the call with `std.posix.poll(&poll_fds, 0)`: if `n - seq_start == 1 and buf[seq_start] == 0x1b` and `POLL.IN` is ready on the TTY fd, `Loop.zig` moves `\x1b` to `buf[0]`, sets `read_start = 1`, and reads continuation bytes before calling `parser.parse`.




* **Pure, Headless Odin Translation (`parse_ansi_input`):**
Moving the timeout/poll boundary into the `is_timeout: bool` parameter makes `parse_ansi_input(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status)` 100% pure and deterministic:
* When `buf` is `"\x1b"` (`len(buf) == 1`) and `!is_timeout`, it returns `{}, 0, .Need_More`.
* When `buf` is `"\x1b"` and `is_timeout == true`, it returns `Key_Event{ code = .Escape, action = .Press }, 1, .Ok`.
* When an incomplete CSI/SS3/OSC/Paste sequence is in `buf` and `!is_timeout`, it returns `{}, 0, .Need_More`. If `is_timeout == true` (the escape timeout expired without continuation bytes), a 2-byte `\x1b<c>` falls back to `Alt+<c>` (`2, .Ok`), and stalled incomplete prefixes are flushed as `.Malformed`.



---

### 2. Kitty Keyboard Protocol & SGR Mouse Encodings (`Key.zig`, `Mouse.zig`, `Parser.zig`)

* **Modifier Bitmask (`Key.Modifiers`):**
`Key.zig` packs 8 modifier flags into a `u8` bitmask (`shift = 1`, `alt = 2`, `ctrl = 4`, `super = 8`, `hyper = 16`, `meta = 32`, `caps_lock = 64`, `num_lock = 128`). Both legacy CSI and Kitty `CSI u` transmit `1 + bitmask` in field 2 (`modifier_mask:event_type`), decoded via saturating subtraction `modifier_mask -| 1`.


* **Ground C0, SS3, Legacy CSI, and Kitty `CSI u` Tables:**
* **Ground C0 (`0x00..=0x1F`, `0x7F`):** `0x00` -> `Ctrl+@`; `0x08` / `0x7F` -> `Backspace`; `0x09` -> `Tab`; `0x0A` -> `Ctrl+j`; `0x0D` -> `Enter`; `0x01..=0x07`, `0x0B..=0x0C`, `0x0E..=0x1A` -> `Ctrl + (b + 0x60)` (`'a'..'z'`); `0x1B` -> `Escape`.


* **SS3 (`\x1bO<final>`) & Legacy CSI (`\x1b[...<final>`):** `'A'` (`Up`), `'B'` (`Down`), `'C'` (`Right`), `'D'` (`Left`), `'E'` (`KP_Begin`), `'F'` (`End`), `'H'` (`Home`), `'P'` (`F1`), `'Q'` (`F2`), `'R'` (`F3`), `'S'` (`F4`), plus CSI `'Z'` (`Shift+Tab`).


* **CSI Tilde (`\x1b[<number>;<mods>~`):** `1, 7` (`Home`), `2` (`Insert`), `3` (`Delete`), `4, 8` (`End`), `5` (`Page_Up`), `6` (`Page_Down`), `11..=15` (`F1..=F5`), `17..=21` (`F6..=F10`), `23..=24` (`F11..=F12`), `200` (`paste_start`), `201` (`paste_end`), `57427` (`KP_Begin`).


* **Kitty `CSI u` (`\x1b[<cp>:<shifted>:<base>;<mods>:<event>;<text>u`):** Decodes field 1 (`codepoint`, optional `shifted_codepoint`, optional `base_layout_codepoint`), field 2 (`mods = mask -| 1`, `event_type == 3` -> `.Release`, `2` -> `.Repeat`, else `.Press`), field 3 (`:`-delimited UTF-8 codepoints), and synthesizes uppercase text when only `Shift` (plus optional lock bits) is active on a printable ASCII codepoint without field 3 (e.g., `\x1b[32;2u` for `Shift+Space`). Maps Kitty PUA codepoints `57348..=57454` (`Insert` through `ISO_Level_5_Shift`).




* **SGR 1006 & X10 Mouse (`Mouse.zig`, `Parser.zig`):**
* Parses SGR `\x1b[<<Pb>;<Px>;<Py>{M|m}` and 6-byte X10 `\x1b[M<b+32><x+32><y+32>`.


* Applies `mouse_bits` to `Pb`:
* `buttons = 0b11000011` (`0xC3`): `0` = `Left`, `1` = `Middle`, `2` = `Right`, `3` = `None`, `64` = `Wheel_Up`, `65` = `Wheel_Down`, `66` = `Wheel_Right`, `67` = `Wheel_Left`, `128..=131` = `Button_8..=Button_11`.


* `shift = 0x04`, `alt = 0x08`, `ctrl = 0x10`, `motion = 0x20`, `leave = 0x100`.


* Event type: if `motion` and `button != .None` -> `.Drag`; if `motion` and `button == .None` -> `.Motion`; if final `'m'` (or X10 `button == .None`) -> `.Release`; else `.Press`.


* Coordinates convert from 1-based terminal cells to 0-based signed `i16` (`col = px - 1`, `row = py - 1`, saturating at `0` for positive coordinates while preserving negative SGR out-of-window coordinates).







---

### 3. POSIX TTY, `SIGWINCH` Self-Pipe, and Teardown Lifecycle (`tty.zig`, `Vaxis.zig`, `ctlseqs.zig`)

* **Raw `termios` Setup (`PosixTty.makeRaw`):**
Saves original `termios` via `posix.tcgetattr(fd, &orig)`, clears `IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON` on `c_iflag`, clears `OPOST` on `c_oflag`, clears `ECHO | ECHONL | ICANON | ISIG | IEXTEN` on `c_lflag`, clears `CS6 | CS7 | PARENB` and sets `CS8` on `c_cflag`, sets `c_cc[.VMIN] = 1` and `c_cc[.VTIME] = 0`, and applies with `posix.tcsetattr(fd, .TCSAFLUSH, &raw)`.


* **`ioctl(TIOCGWINSZ)` Window Size Query (`PosixTty.getWinsize`):**
Queries `ioctl(fd, TIOCGWINSZ, &ws)` (`0x5413` on Linux, `0x40087468` on Darwin/BSD) to read `ws_col`, `ws_row`, `ws_xpixel`, and `ws_ypixel`.


* **`SIGWINCH` Self-Pipe & `poll()` Multiplexing (`PosixTty.startSignalThread` / `handleWinch`):**
Creates a pipe via `posix.pipe(&fds)`, sets `FD_CLOEXEC` on both ends and `O_NONBLOCK` on the write end (`fds[1]`), and installs an async-signal-safe `proc "c"` handler via `posix.sigaction(.SIGWINCH, &act, nil)` that writes a single byte to `fds[1]`. The `sleipnir` input actor passes a 2-element `[2]posix.pollfd` array (`STDIN_FILENO` / TTY fd + `resize_pipe[0]`) to `posix.poll(&pfds[0], 2, timeout_ms)`, draining `resize_pipe[0]` and querying `TIOCGWINSZ` whenever `SIGWINCH` fires without busy-waiting.


* **Terminal Teardown Sequence:**
Restores mouse tracking (`\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l`), bracketed paste (`\x1b[?2004l`), focus reporting (`\x1b[?1004l`), Kitty keyboard protocol (`\x1b[<u`), SGR attributes (`\x1b[m`), cursor visibility (`\x1b[?25h`), alternate screen (`\x1b[?1049l`), `SIGWINCH` (`SIG_DFL`), and `termios` (`TCSAFLUSH`).



---

### `bifrost/ansi_parser.odin`

```odin
package bifrost

import "core:unicode/utf8"

// ============================================================================
// Parser Status & Input Event Types
// ============================================================================

Parse_Status :: enum u8 {
	Ok,
	Need_More,
	Ignored,
	Malformed,
}

Modifier_Flag :: enum u8 {
	Shift     = 0,
	Alt       = 1,
	Ctrl      = 2,
	Super     = 3,
	Hyper     = 4,
	Meta      = 5,
	Caps_Lock = 6,
	Num_Lock  = 7,
}

Modifiers :: distinct bit_set[Modifier_Flag; u8]

Kitty_Flag :: enum u8 {
	Disambiguate            = 0,
	Report_Events           = 1,
	Report_Alternate_Keys   = 2,
	Report_All_As_Ctl_Seqs  = 3,
	Report_Text             = 4,
}

Kitty_Flags :: distinct bit_set[Kitty_Flag; u8]

DEFAULT_KITTY_FLAGS :: Kitty_Flags{.Disambiguate, .Report_Alternate_Keys, .Report_All_As_Ctl_Seqs, .Report_Text}

// Key_Code reuses ASCII/Unicode values for standard keys and Kitty's Private
// Use Area (57348..=57454) for functional keys, matching libvaxis Key.zig.
Key_Code :: enum rune {
	None              = 0,
	Tab               = 0x09,
	Enter             = 0x0D,
	Escape            = 0x1B,
	Space             = 0x20,
	Backspace         = 0x7F,

	Insert            = 57348,
	Delete            = 57349,
	Left              = 57350,
	Right             = 57351,
	Up                = 57352,
	Down              = 57353,
	Page_Up           = 57354,
	Page_Down         = 57355,
	Home              = 57356,
	End               = 57357,
	Caps_Lock         = 57358,
	Scroll_Lock       = 57359,
	Num_Lock          = 57360,
	Print_Screen      = 57361,
	Pause             = 57362,
	Menu              = 57363,
	F1                = 57364,
	F2                = 57365,
	F3                = 57366,
	F4                = 57367,
	F5                = 57368,
	F6                = 57369,
	F7                = 57370,
	F8                = 57371,
	F9                = 57372,
	F10               = 57373,
	F11               = 57374,
	F12               = 57375,
	F13               = 57376,
	F14               = 57377,
	F15               = 57378,
	F16               = 57379,
	F17               = 57380,
	F18               = 57381,
	F19               = 57382,
	F20               = 57383,
	F21               = 57384,
	F22               = 57385,
	F23               = 57386,
	F24               = 57387,
	F25               = 57388,
	F26               = 57389,
	F27               = 57390,
	F28               = 57391,
	F29               = 57392,
	F30               = 57393,
	F31               = 57394,
	F32               = 57395,
	F33               = 57396,
	F34               = 57397,
	F35               = 57398,
	KP_0              = 57399,
	KP_1              = 57400,
	KP_2              = 57401,
	KP_3              = 57402,
	KP_4              = 57403,
	KP_5              = 57404,
	KP_6              = 57405,
	KP_7              = 57406,
	KP_8              = 57407,
	KP_9              = 57408,
	KP_Decimal        = 57409,
	KP_Divide         = 57410,
	KP_Multiply       = 57411,
	KP_Subtract       = 57412,
	KP_Add            = 57413,
	KP_Enter          = 57414,
	KP_Equal          = 57415,
	KP_Separator      = 57416,
	KP_Left           = 57417,
	KP_Right          = 57418,
	KP_Up             = 57419,
	KP_Down           = 57420,
	KP_Page_Up        = 57421,
	KP_Page_Down      = 57422,
	KP_Home           = 57423,
	KP_End            = 57424,
	KP_Insert         = 57425,
	KP_Delete         = 57426,
	KP_Begin          = 57427,
	Media_Play        = 57428,
	Media_Pause       = 57429,
	Media_Play_Pause  = 57430,
	Media_Reverse     = 57431,
	Media_Stop        = 57432,
	Media_Fast_Fwd    = 57433,
	Media_Rewind      = 57434,
	Media_Track_Next  = 57435,
	Media_Track_Prev  = 57436,
	Media_Record      = 57437,
	Lower_Volume      = 57438,
	Raise_Volume      = 57439,
	Mute_Volume       = 57440,
	Left_Shift        = 57441,
	Left_Control      = 57442,
	Left_Alt          = 57443,
	Left_Super        = 57444,
	Left_Hyper        = 57445,
	Left_Meta         = 57446,
	Right_Shift       = 57447,
	Right_Control     = 57448,
	Right_Alt         = 57449,
	Right_Super       = 57450,
	Right_Hyper       = 57451,
	Right_Meta        = 57452,
	ISO_Level_3_Shift = 57453,
	ISO_Level_5_Shift = 57454,
	Multicodepoint    = 0x110001,
}

Key_Action :: enum u8 {
	Press   = 0,
	Repeat  = 1,
	Release = 2,
}

Key_Event :: struct {
	code:                  Key_Code,
	codepoint:             rune,
	shifted_codepoint:     rune,
	base_layout_codepoint: rune,
	mods:                  Modifiers,
	action:                Key_Action,
	text_buf:              [64]u8,
	text_len:              u8,
}

Mouse_Button :: enum u8 {
	Left        = 0,
	Middle      = 1,
	Right       = 2,
	None        = 3,
	Wheel_Up    = 64,
	Wheel_Down  = 65,
	Wheel_Right = 66,
	Wheel_Left  = 67,
	Button_8    = 128,
	Button_9    = 129,
	Button_10   = 130,
	Button_11   = 131,
}

Mouse_Action :: enum u8 {
	Press   = 0,
	Release = 1,
	Motion  = 2,
	Drag    = 3,
	Leave   = 4,
}

Mouse_Event :: struct {
	col:      i16,
	row:      i16,
	x_offset: u16,
	y_offset: u16,
	button:   Mouse_Button,
	mods:     Modifiers,
	action:   Mouse_Action,
}

Resize_Event :: struct {
	width:   u16,
	height:  u16,
	x_pixel: u16,
	y_pixel: u16,
}

Paste_Kind :: enum u8 {
	Complete = 0,
	Start    = 1,
	End      = 2,
}

Paste_Event :: struct {
	text: string,
	kind: Paste_Kind,
}

Focus_Event :: struct {
	focused: bool,
}

Input_Event :: union {
	Key_Event,
	Mouse_Event,
	Resize_Event,
	Paste_Event,
	Focus_Event,
}

// Helper to retrieve the slice of UTF-8 text stored inline on a Key_Event.
key_event_text :: proc(ev: ^Key_Event) -> string {
	return string(ev.text_buf[:ev.text_len])
}

// ============================================================================
// Pure Streaming ANSI Input Parser
// ============================================================================

MOUSE_BIT_MOTION  :: u16(0b0010_0000)
MOUSE_BIT_BUTTONS :: u16(0b1100_0011)
MOUSE_BIT_SHIFT   :: u16(0b0000_0100)
MOUSE_BIT_ALT     :: u16(0b0000_1000)
MOUSE_BIT_CTRL    :: u16(0b0001_0000)
MOUSE_BIT_LEAVE   :: u16(0b1_0000_0000)

BRACKETED_PASTE_START :: "\x1b[200~"
BRACKETED_PASTE_END   :: "\x1b[201~"

parse_ansi_input :: proc(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	if len(buf) == 0 {
		return nil, 0, .Need_More
	}

	if buf[0] == 0x1b {
		if len(buf) == 1 {
			if is_timeout {
				return Key_Event{
					code      = .Escape,
					codepoint = rune(Key_Code.Escape),
					action    = .Press,
				}, 1, .Ok
			}
			return nil, 0, .Need_More
		}

		switch buf[1] {
		case 'O': // 0x4F - SS3
			return parse_ss3(buf, is_timeout)
		case 'P', 'X', '^', '_': // 0x50 DCS, 0x58 SOS, 0x5E PM, 0x5F APC
			return skip_until_st(buf, is_timeout)
		case '[': // 0x5B - CSI
			return parse_csi(buf, is_timeout)
		case ']': // 0x5D - OSC
			return parse_osc(buf, is_timeout)
		case:
			// Alt + <char/utf8-codepoint>
			if buf[1] == 0x1b {
				// Consecutive ESC: emit first ESC and leave second ESC in buffer
				return Key_Event{
					code      = .Escape,
					codepoint = rune(Key_Code.Escape),
					action    = .Press,
				}, 1, .Ok
			}
			sub_ev, sub_n, sub_status := parse_ground(buf[1:], is_timeout)
			if sub_status == .Ok {
				if key, ok := sub_ev.(Key_Event); ok {
					key.mods += {.Alt}
					return key, 1 + sub_n, .Ok
				}
			}
			if sub_status == .Need_More && !is_timeout {
				return nil, 0, .Need_More
			}
			return Key_Event{
				code      = Key_Code(rune(buf[1])),
				codepoint = rune(buf[1]),
				mods      = {.Alt},
				action    = .Press,
			}, 2, .Ok
		}
	}

	return parse_ground(buf, is_timeout)
}

// ============================================================================
// Ground State (C0 Controls, ASCII, UTF-8)
// ============================================================================

@(private)
parse_ground :: proc(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	b := buf[0]

	switch b {
	case 0x00:
		return Key_Event{
			code      = Key_Code('@'),
			codepoint = '@',
			mods      = {.Ctrl},
			action    = .Press,
		}, 1, .Ok
	case 0x08, 0x7F:
		return Key_Event{
			code      = .Backspace,
			codepoint = rune(Key_Code.Backspace),
			action    = .Press,
		}, 1, .Ok
	case 0x09:
		return Key_Event{
			code      = .Tab,
			codepoint = rune(Key_Code.Tab),
			action    = .Press,
		}, 1, .Ok
	case 0x0A:
		return Key_Event{
			code      = Key_Code('j'),
			codepoint = 'j',
			mods      = {.Ctrl},
			action    = .Press,
		}, 1, .Ok
	case 0x0D:
		return Key_Event{
			code      = .Enter,
			codepoint = rune(Key_Code.Enter),
			action    = .Press,
		}, 1, .Ok
	case 0x01 ..= 0x07, 0x0B ..= 0x0C, 0x0E ..= 0x1A:
		cp := rune(b + 0x60)
		return Key_Event{
			code      = Key_Code(cp),
			codepoint = cp,
			mods      = {.Ctrl},
			action    = .Press,
		}, 1, .Ok
	case 0x1B:
		return Key_Event{
			code      = .Escape,
			codepoint = rune(Key_Code.Escape),
			action    = .Press,
		}, 1, .Ok
	}

	// Printable ASCII fast-path
	if b < 0x80 {
		ev := Key_Event{
			code      = Key_Code(rune(b)),
			codepoint = rune(b),
			action    = .Press,
			text_len  = 1,
		}
		ev.text_buf[0] = b
		return ev, 1, .Ok
	}

	// Multi-byte UTF-8 decoding
	expected_len := utf8_sequence_length(b)
	if expected_len == 0 {
		return nil, 1, .Malformed
	}
	if len(buf) < expected_len {
		if is_timeout {
			return nil, len(buf), .Malformed
		}
		return nil, 0, .Need_More
	}

	r, width := utf8.decode_rune_in_bytes(buf[:expected_len])
	if r == utf8.RUNE_ERROR && width <= 1 {
		return nil, 1, .Malformed
	}

	ev := Key_Event{
		code      = Key_Code(r),
		codepoint = r,
		action    = .Press,
		text_len  = u8(width),
	}
	copy(ev.text_buf[:width], buf[:width])
	return ev, width, .Ok
}

@(private)
utf8_sequence_length :: proc(lead: byte) -> int {
	if lead < 0x80 {
		return 1
	} else if (lead & 0xE0) == 0xC0 {
		return 2
	} else if (lead & 0xF0) == 0xE0 {
		return 3
	} else if (lead & 0xF8) == 0xF0 {
		return 4
	}
	return 0
}

// ============================================================================
// SS3, DCS/SOS/PM/APC, and OSC Parsers
// ============================================================================

@(private)
parse_ss3 :: proc(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	if len(buf) < 3 {
		if is_timeout {
			// Disambiguate timed-out "\x1bO" as Alt+O
			return Key_Event{
				code      = Key_Code('O'),
				codepoint = 'O',
				mods      = {.Alt},
				action    = .Press,
			}, 2, .Ok
		}
		return nil, 0, .Need_More
	}

	if buf[2] == 0x1b {
		// Interrupted SS3: consume "\x1bO" and leave the new ESC for next call
		return nil, 2, .Ignored
	}

	code: Key_Code
	switch buf[2] {
	case 'A': code = .Up
	case 'B': code = .Down
	case 'C': code = .Right
	case 'D': code = .Left
	case 'E': code = .KP_Begin
	case 'F': code = .End
	case 'H': code = .Home
	case 'P': code = .F1
	case 'Q': code = .F2
	case 'R': code = .F3
	case 'S': code = .F4
	case:
		return nil, 3, .Ignored
	}

	return Key_Event{
		code      = code,
		codepoint = rune(code),
		action    = .Press,
	}, 3, .Ok
}

@(private)
skip_until_st :: proc(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	if len(buf) < 3 {
		if is_timeout {
			return nil, len(buf), .Malformed
		}
		return nil, 0, .Need_More
	}

	for i := 2; i < len(buf); i += 1 {
		if buf[i] == 0x1b {
			if i + 1 >= len(buf) {
				if is_timeout {
					return nil, len(buf), .Malformed
				}
				return nil, 0, .Need_More
			}
			if buf[i + 1] == '\\' {
				return nil, i + 2, .Ignored
			}
			// Bare ESC not followed by '\' aborts the sequence up to ESC
			return nil, i, .Ignored
		}
	}

	if is_timeout {
		return nil, len(buf), .Malformed
	}
	return nil, 0, .Need_More
}

@(private)
parse_osc :: proc(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	if len(buf) < 3 {
		if is_timeout {
			return nil, len(buf), .Malformed
		}
		return nil, 0, .Need_More
	}

	for i := 2; i < len(buf); i += 1 {
		switch buf[i] {
		case 0x07: // BEL terminator
			return nil, i + 1, .Ignored
		case 0x1b:
			if i + 1 >= len(buf) {
				if is_timeout {
					return nil, len(buf), .Malformed
				}
				return nil, 0, .Need_More
			}
			if buf[i + 1] == '\\' { // ST (ESC \) terminator
				return nil, i + 2, .Ignored
			}
			// ESC not followed by '\': malformed OSC prefix, leave ESC for next call
			return nil, i, .Ignored
		}
	}

	if is_timeout {
		return nil, len(buf), .Malformed
	}
	return nil, 0, .Need_More
}

// ============================================================================
// CSI Parser (Legacy Keys, Bracketed Paste, Focus, XTWINOPS, Kitty CSI u, SGR Mouse)
// ============================================================================

@(private)
parse_csi :: proc(buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	if len(buf) < 3 {
		if is_timeout {
			return Key_Event{
				code      = Key_Code('['),
				codepoint = '[',
				mods      = {.Alt},
				action    = .Press,
			}, 2, .Ok
		}
		return nil, 0, .Need_More
	}

	// Locate CSI final byte (0x40..=0xFF) starting at index 2
	final_idx := -1
	for i := 2; i < len(buf); i += 1 {
		if buf[i] == 0x1b {
			// Interrupted CSI sequence: discard malformed prefix up to new ESC
			return nil, i, .Malformed
		}
		if buf[i] >= 0x40 && buf[i] <= 0xFF {
			final_idx = i
			break
		}
	}

	if final_idx < 0 {
		if is_timeout {
			return nil, len(buf), .Malformed
		}
		return nil, 0, .Need_More
	}

	seq := buf[:final_idx + 1]
	final := seq[len(seq) - 1]

	switch final {
	case 'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'R', 'S':
		return parse_csi_legacy_letter(seq, final)
	case 'Z':
		return Key_Event{
			code      = .Tab,
			codepoint = rune(Key_Code.Tab),
			mods      = {.Shift},
			action    = .Press,
		}, len(seq), .Ok
	case '~':
		return parse_csi_tilde(buf, seq, is_timeout)
	case 'I':
		return Focus_Event{focused = true}, len(seq), .Ok
	case 'O':
		return Focus_Event{focused = false}, len(seq), .Ok
	case 'M', 'm':
		return parse_mouse(seq, buf, is_timeout)
	case 't':
		return parse_xtwinops(seq)
	case 'u':
		return parse_kitty_csi_u(seq)
	case:
		return nil, len(seq), .Ignored
	}
}

@(private)
parse_csi_legacy_letter :: proc(seq: []byte, final: byte) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	code: Key_Code
	switch final {
	case 'A': code = .Up
	case 'B': code = .Down
	case 'C': code = .Right
	case 'D': code = .Left
	case 'E': code = .KP_Begin
	case 'F': code = .End
	case 'H': code = .Home
	case 'P': code = .F1
	case 'Q': code = .F2
	case 'R': code = .F3
	case 'S': code = .F4
	case:
		return nil, len(seq), .Ignored
	}

	key := Key_Event{
		code      = code,
		codepoint = rune(code),
		action    = .Press,
	}

	params := seq[2 : len(seq) - 1]
	if len(params) > 0 {
		f1, rest1, _ := split_byte(params, ';')
		_ = f1
		if rest1 != nil {
			f2, rest2, _ := split_byte(rest1, ';')
			mods, action, ok := parse_modifier_and_action(f2)
			if !ok {
				return nil, len(seq), .Ignored
			}
			key.mods = mods
			key.action = action

			if rest2 != nil {
				if !decode_text_codepoints(rest2, &key) {
					return nil, len(seq), .Ignored
				}
			}
		}
	}

	return key, len(seq), .Ok
}

@(private)
parse_csi_tilde :: proc(full_buf: []byte, seq: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	params := seq[2 : len(seq) - 1]
	f1, rest1, _ := split_byte(params, ';')
	num, ok := parse_u32(f1)
	if !ok {
		return nil, len(seq), .Ignored
	}

	// Bracketed Paste (\x1b[200~ ... \x1b[201~)
	if num == 200 {
		payload_after := full_buf[len(seq):]
		if end_rel := index_of_slice(payload_after, transmute([]byte)string(BRACKETED_PASTE_END)); end_rel >= 0 {
			text := string(payload_after[:end_rel])
			total := len(seq) + end_rel + len(BRACKETED_PASTE_END)
			return Paste_Event{text = text, kind = .Complete}, total, .Ok
		}
		if !is_timeout {
			return nil, 0, .Need_More
		}
		// Timeout fallback if end marker never arrived
		return Paste_Event{text = string(payload_after), kind = .Start}, len(full_buf), .Ok
	}
	if num == 201 {
		return Paste_Event{text = "", kind = .End}, len(seq), .Ok
	}

	code: Key_Code
	switch num {
	case 1, 7:  code = .Home
	case 2:     code = .Insert
	case 3:     code = .Delete
	case 4, 8:  code = .End
	case 5:     code = .Page_Up
	case 6:     code = .Page_Down
	case 11:    code = .F1
	case 12:    code = .F2
	case 13:    code = .F3
	case 14:    code = .F4
	case 15:    code = .F5
	case 17:    code = .F6
	case 18:    code = .F7
	case 19:    code = .F8
	case 20:    code = .F9
	case 21:    code = .F10
	case 23:    code = .F11
	case 24:    code = .F12
	case 57427: code = .KP_Begin
	case:
		return nil, len(seq), .Ignored
	}

	key := Key_Event{
		code      = code,
		codepoint = rune(code),
		action    = .Press,
	}

	if rest1 != nil {
		f2, rest2, _ := split_byte(rest1, ';')
		mods, action, mod_ok := parse_modifier_and_action(f2)
		if !mod_ok {
			return nil, len(seq), .Ignored
		}
		key.mods = mods
		key.action = action

		if rest2 != nil {
			if !decode_text_codepoints(rest2, &key) {
				return nil, len(seq), .Ignored
			}
		}
	}

	return key, len(seq), .Ok
}

// ============================================================================
// Kitty Keyboard Protocol (CSI u)
// ============================================================================

@(private)
parse_kitty_csi_u :: proc(seq: []byte) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	if len(seq) > 3 && seq[2] == '?' {
		// Kitty capability response: CSI ? flags u
		return nil, len(seq), .Ignored
	}

	params := seq[2 : len(seq) - 1]
	f1, rest1, _ := split_byte(params, ';')

	// Field 1: unicode-key-code[:shifted_codepoint[:base_layout_codepoint]]
	cp_buf, cp_rest1, _ := split_byte(f1, ':')
	cp_u32, cp_ok := parse_u32(cp_buf)
	if !cp_ok {
		return nil, len(seq), .Ignored
	}

	key := Key_Event{
		code      = Key_Code(rune(cp_u32)),
		codepoint = rune(cp_u32),
		action    = .Press,
	}

	if cp_rest1 != nil {
		shifted_buf, base_buf, _ := split_byte(cp_rest1, ':')
		if len(shifted_buf) > 0 {
			if shifted_val, s_ok := parse_u32(shifted_buf); s_ok {
				key.shifted_codepoint = rune(shifted_val)
			}
		}
		if base_buf != nil && len(base_buf) > 0 {
			if base_val, b_ok := parse_u32(base_buf); b_ok {
				key.base_layout_codepoint = rune(base_val)
			}
		}
	}

	has_text_field := false

	// Field 2: modifier_mask[:event_type]
	if rest1 != nil {
		f2, rest2, _ := split_byte(rest1, ';')
		if len(f2) > 0 {
			mods, action, mod_ok := parse_modifier_and_action(f2)
			if !mod_ok {
				return nil, len(seq), .Ignored
			}
			key.mods = mods
			key.action = action
		}

		// Field 3: text_as_codepoint[:text_as_codepoint]
		if rest2 != nil {
			has_text_field = true
			if !decode_text_codepoints(rest2, &key) {
				return nil, len(seq), .Ignored
			}
		}
	}

	// Synthesize text when disambiguated printable ASCII is pressed with only Shift
	// (or no modifiers) and no explicit text field was reported.
	if !has_text_field && key.codepoint >= 0x20 && key.codepoint <= 0x7E {
		non_lock_mods := key.mods - {.Caps_Lock, .Num_Lock}
		if non_lock_mods == {.Shift} {
			upper := key.shifted_codepoint
			if upper == 0 {
				upper = ascii_to_upper(key.codepoint)
				key.shifted_codepoint = upper
			}
			encoded, w := utf8.encode_rune(upper)
			copy(key.text_buf[:w], encoded[:w])
			key.text_len = u8(w)
		} else if non_lock_mods == {} {
			key.text_buf[0] = byte(key.codepoint)
			key.text_len = 1
		}
	}

	return key, len(seq), .Ok
}

// ============================================================================
// SGR 1006 & X10 Mouse Parser
// ============================================================================

@(private)
parse_mouse :: proc(seq: []byte, full_buf: []byte, is_timeout: bool) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	button_mask: u16
	px: i16
	py: i16
	xterm := false
	consumed := len(seq)

	if len(seq) == 3 && seq[2] == 'M' {
		// Legacy X10 mouse: \x1b [ M <btn+32> <x+32> <y+32> (6 bytes total)
		if len(full_buf) < 6 {
			if is_timeout {
				return nil, len(full_buf), .Malformed
			}
			return nil, 0, .Need_More
		}
		xterm = true
		consumed = 6
		if full_buf[3] < 32 || full_buf[4] < 32 || full_buf[5] < 32 {
			return nil, 6, .Malformed
		}
		button_mask = u16(full_buf[3] - 32)
		px = i16(full_buf[4] - 32)
		py = i16(full_buf[5] - 32)
	} else if len(seq) >= 4 && seq[2] == '<' {
		// SGR 1006 mouse: \x1b [ < Pb ; Px ; Py {M|m}
		body := seq[3 : len(seq) - 1]
		f1, rest1, ok1 := split_byte(body, ';')
		if !ok1 {
			return nil, len(seq), .Ignored
		}
		f2, f3, ok2 := split_byte(rest1, ';')
		if !ok2 {
			return nil, len(seq), .Ignored
		}

		b_val, b_ok := parse_u32(f1)
		if !b_ok || b_val > 0xFFFF {
			return nil, len(seq), .Ignored
		}
		button_mask = u16(b_val)

		px_ok, py_ok: bool
		px, px_ok = parse_i16_default(f2, 1)
		py, py_ok = parse_i16_default(f3, 1)
		if !px_ok || !py_ok {
			return nil, len(seq), .Ignored
		}
	} else {
		return nil, len(seq), .Ignored
	}

	if (button_mask & MOUSE_BIT_LEAVE) != 0 {
		return Mouse_Event{
			action = .Leave,
			button = .None,
		}, consumed, .Ok
	}

	btn := Mouse_Button(u8(button_mask & MOUSE_BIT_BUTTONS))
	motion := (button_mask & MOUSE_BIT_MOTION) != 0

	mods: Modifiers
	if (button_mask & MOUSE_BIT_SHIFT) != 0 {
		mods += {.Shift}
	}
	if (button_mask & MOUSE_BIT_ALT) != 0 {
		mods += {.Alt}
	}
	if (button_mask & MOUSE_BIT_CTRL) != 0 {
		mods += {.Ctrl}
	}

	action: Mouse_Action
	if motion && btn != .None {
		action = .Drag
	} else if motion && btn == .None {
		action = .Motion
	} else if xterm {
		action = .Release if btn == .None else .Press
	} else {
		action = .Release if seq[len(seq) - 1] == 'm' else .Press
	}

	// Convert 1-based terminal cell coordinates to 0-based (matching libvaxis px -| 1
	// for positive coords while preserving negative SGR coordinates).
	col := (px - 1) if px != 0 else 0
	row := (py - 1) if py != 0 else 0

	return Mouse_Event{
		col    = col,
		row    = row,
		button = btn,
		mods   = mods,
		action = action,
	}, consumed, .Ok
}

// ============================================================================
// In-Band Resize (XTWINOPS CSI 48 ; height ; width ; height_pix ; width_pix t)
// ============================================================================

@(private)
parse_xtwinops :: proc(seq: []byte) -> (event: Input_Event, bytes_consumed: int, status: Parse_Status) {
	body := seq[2 : len(seq) - 1]
	ps, rest1, ok1 := split_byte(body, ';')
	if !ok1 || string(ps) != "48" {
		return nil, len(seq), .Ignored
	}

	h_buf, rest2, ok2 := split_byte(rest1, ';')
	if !ok2 {
		return nil, len(seq), .Ignored
	}
	w_buf, rest3, _ := split_byte(rest2, ';')

	rows, r_ok := parse_u32(h_buf)
	cols, c_ok := parse_u32(w_buf)
	if !r_ok || !c_ok || rows > 0xFFFF || cols > 0xFFFF {
		return nil, len(seq), .Ignored
	}

	y_pix: u32 = 0
	x_pix: u32 = 0
	if rest3 != nil {
		hp_buf, wp_buf, _ := split_byte(rest3, ';')
		if len(hp_buf) > 0 {
			hp, hp_ok := parse_u32(hp_buf)
			if !hp_ok || hp > 0xFFFF {
				return nil, len(seq), .Ignored
			}
			y_pix = hp
		}
		if wp_buf != nil && len(wp_buf) > 0 {
			wp, wp_ok := parse_u32(wp_buf)
			if !wp_ok || wp > 0xFFFF {
				return nil, len(seq), .Ignored
			}
			x_pix = wp
		}
	}

	return Resize_Event{
		width   = u16(cols),
		height  = u16(rows),
		x_pixel = u16(x_pix),
		y_pixel = u16(y_pix),
	}, len(seq), .Ok
}

// ============================================================================
// Zero-Allocation Numeric & String Helpers
// ============================================================================

@(private)
parse_modifier_and_action :: proc(field: []byte) -> (mods: Modifiers, action: Key_Action, ok: bool) {
	mod_buf, evt_buf, _ := split_byte(field, ':')
	mask: u32 = 1
	if len(mod_buf) > 0 {
		m, m_ok := parse_u32(mod_buf)
		if !m_ok || m > 256 {
			return {}, .Press, false
		}
		mask = m
	}

	// libvaxis: modifier_mask -| 1
	bits := u8(mask - 1) if mask > 0 else 0
	mods = transmute(Modifiers)bits
	action = .Press

	if evt_buf != nil && len(evt_buf) > 0 {
		evt_type, e_ok := parse_u32(evt_buf)
		if !e_ok {
			return {}, .Press, false
		}
		switch evt_type {
		case 2: action = .Repeat
		case 3: action = .Release
		case:   action = .Press
		}
	}

	return mods, action, true
}

@(private)
decode_text_codepoints :: proc(field: []byte, key: ^Key_Event) -> bool {
	rem := field
	total := 0
	for rem != nil {
		cp_buf: []byte
		cp_buf, rem, _ = split_byte(rem, ':')
		if len(cp_buf) == 0 {
			continue
		}
		cp_val, ok := parse_u32(cp_buf)
		if !ok || cp_val > 0x10FFFF {
			return false
		}
		encoded, w := utf8.encode_rune(rune(cp_val))
		if w == 0 || total + w > len(key.text_buf) {
			return false
		}
		copy(key.text_buf[total : total + w], encoded[:w])
		total += w
	}
	key.text_len = u8(total)
	return true
}

@(private)
split_byte :: proc(s: []byte, sep: byte) -> (head: []byte, tail: []byte, found: bool) {
	for b, i in s {
		if b == sep {
			return s[:i], s[i + 1:], true
		}
	}
	return s, nil, false
}

@(private)
index_of_slice :: proc(haystack: []byte, needle: []byte) -> int {
	if len(needle) == 0 || len(haystack) < len(needle) {
		return -1
	}
	limit := len(haystack) - len(needle)
	outer: for i := 0; i <= limit; i += 1 {
		for j := 0; j < len(needle); j += 1 {
			if haystack[i + j] != needle[j] {
				continue outer
			}
		}
		return i
	}
	return -1
}

@(private)
parse_u32 :: proc(buf: []byte) -> (val: u32, ok: bool) {
	if len(buf) == 0 {
		return 0, false
	}
	acc: u64 = 0
	for b in buf {
		if b < '0' || b > '9' {
			return 0, false
		}
		acc = acc * 10 + u64(b - '0')
		if acc > 0xFFFF_FFFF {
			return 0, false
		}
	}
	return u32(acc), true
}

@(private)
parse_i16_default :: proc(buf: []byte, default_val: i16) -> (val: i16, ok: bool) {
	if len(buf) == 0 {
		return default_val, true
	}
	neg := false
	s := buf
	if s[0] == '-' {
		neg = true
		s = s[1:]
	}
	if len(s) == 0 {
		return 0, false
	}
	acc: i32 = 0
	for b in s {
		if b < '0' || b > '9' {
			return 0, false
		}
		acc = acc * 10 + i32(b - '0')
		if acc > 32767 {
			return 0, false
		}
	}
	res := -acc if neg else acc
	return i16(res), true
}

@(private)
ascii_to_upper :: proc(r: rune) -> rune {
	if r >= 'a' && r <= 'z' {
		return r - 32
	}
	return r
}

```

---

### `bifrost/terminal.odin`

```odin
package bifrost

import "core:c"
import "core:sys/posix"

// ============================================================================
// Control Sequences (Ported from libvaxis ctlseqs.zig)
// ============================================================================

CTL_ENTER_ALT_SCREEN    :: "\x1b[?1049h"
CTL_EXIT_ALT_SCREEN     :: "\x1b[?1049l"
CTL_HIDE_CURSOR         :: "\x1b[?25l"
CTL_SHOW_CURSOR         :: "\x1b[?25h"
CTL_SGR_RESET           :: "\x1b[m"
CTL_HOME                :: "\x1b[H"
CTL_ERASE_BELOW_CURSOR  :: "\x1b[J"

CTL_MOUSE_SET           :: "\x1b[?1000;1002;1003;1006h"
CTL_MOUSE_RESET         :: "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l"

CTL_BRACKETED_PASTE_SET   :: "\x1b[?2004h"
CTL_BRACKETED_PASTE_RESET :: "\x1b[?2004l"

CTL_FOCUS_SET           :: "\x1b[?1004h"
CTL_FOCUS_RESET         :: "\x1b[?1004l"

// Kitty Keyboard Protocol: flags = 29 (disambiguate=1 | alternate=4 | all_ctl=8 | text=16)
CTL_KITTY_KBD_PUSH      :: "\x1b[>29u"
CTL_KITTY_KBD_POP       :: "\x1b[<u"

CTL_SYNC_SET            :: "\x1b[?2026h"
CTL_SYNC_RESET          :: "\x1b[?2026l"

// Complete deterministic teardown sequence
CTL_TEARDOWN_SEQUENCE ::
	"\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l" +
	"\x1b[?2004l" +
	"\x1b[?1004l" +
	"\x1b[<u" +
	"\x1b[m" +
	"\x1b[?25h" +
	"\x1b[?1049l"

// ============================================================================
// POSIX ioctl(TIOCGWINSZ) Binding
// ============================================================================

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

// ============================================================================
// Terminal State & Errors
// ============================================================================

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
	in_fd:           posix.FD,
	out_fd:          posix.FD,
	orig_termios:    posix.termios,
	resize_pipe:     [2]posix.FD, // [0] = read end (polled by sleipnir), [1] = write end (SIGWINCH)
	opts:            Terminal_Options,
	raw_active:      bool,
	sigwinch_active: bool,
	read_buf:        [1024]byte,
	read_len:        int,
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

// ============================================================================
// Terminal Lifecycle (Init, Raw Mode, SIGWINCH Pipe, Winsize, Teardown)
// ============================================================================

terminal_init :: proc(
	term: ^Terminal,
	opts := DEFAULT_TERMINAL_OPTIONS,
	in_fd := posix.STDIN_FILENO,
	out_fd := posix.STDOUT_FILENO,
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
	}

	// 2. Restore default SIGWINCH handler and close self-pipe descriptors
	if term.sigwinch_active {
		g_sigwinch_write_fd = -1
		act: posix.sigaction_t
		act.sa_handler = cast(proc "c" (posix.Signal))posix.SIG_DFL
		posix.sigemptyset(&act.sa_mask)
		_ = posix.sigaction(.SIGWINCH, &act, nil)
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

	// Set FD_CLOEXEC on both pipe descriptors and O_NONBLOCK on both ends
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

	if posix.sigaction(.SIGWINCH, &act, nil) != .OK {
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
		width   = u16(ws.ws_col),
		height  = u16(ws.ws_row),
		x_pixel = u16(ws.ws_xpixel),
		y_pixel = u16(ws.ws_ypixel),
	}, .None
}

// ============================================================================
// Sleipnir Input Actor Poll + Streaming Parse Loop
// ============================================================================

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
consume_buffer_prefix :: proc(term: ^Terminal, count: int) {
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
		n := posix.write(fd, &bytes[written], uint(len(bytes) - written))
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

```

---

### Headless Verification Pattern (`tests/spec_ansi_parser.odin`)

Because `parse_ansi_input` is a pure function over `(buf: []byte, is_timeout: bool)`, `tests/spec_ansi_parser.odin` can test split reads, bare `ESC` vs. `Alt+<key>`, Kitty `CSI u`, and SGR 1006 mouse events without opening a TTY:

```odin
package tests

import "core:testing"
import "../bifrost"

@(test)
test_bare_esc_and_split_csi :: proc(t: ^testing.T) {
	// 1. Bare ESC before timeout -> Need_More (0 bytes consumed)
	_, n0, s0 := bifrost.parse_ansi_input(transmute([]byte)string("\x1b"), false)
	testing.expect_value(t, s0, bifrost.Parse_Status.Need_More)
	testing.expect_value(t, n0, 0)

	// 2. Bare ESC after timeout -> Key_Code.Escape (1 byte consumed)
	ev1, n1, s1 := bifrost.parse_ansi_input(transmute([]byte)string("\x1b"), true)
	testing.expect_value(t, s1, bifrost.Parse_Status.Ok)
	testing.expect_value(t, n1, 1)
	testing.expect_value(t, ev1.(bifrost.Key_Event).code, bifrost.Key_Code.Escape)

	// 3. Partial CSI "\x1b[1;2" -> Need_More, then completed "\x1b[1;2A" -> Shift+Up
	_, n2, s2 := bifrost.parse_ansi_input(transmute([]byte)string("\x1b[1;2"), false)
	testing.expect_value(t, s2, bifrost.Parse_Status.Need_More)
	testing.expect_value(t, n2, 0)

	ev3, n3, s3 := bifrost.parse_ansi_input(transmute([]byte)string("\x1b[1;2A"), false)
	testing.expect_value(t, s3, bifrost.Parse_Status.Ok)
	testing.expect_value(t, n3, 6)
	key3 := ev3.(bifrost.Key_Event)
	testing.expect_value(t, key3.code, bifrost.Key_Code.Up)
	testing.expect_value(t, key3.mods, bifrost.Modifiers{.Shift})

	// 4. Kitty CSI u Shift+A ("\x1b[97:65;2u") and SGR 1006 wheel up ("\x1b[<64;10;20M")
	ev4, n4, s4 := bifrost.parse_ansi_input(transmute([]byte)string("\x1b[97:65;2u"), false)
	testing.expect_value(t, s4, bifrost.Parse_Status.Ok)
	testing.expect_value(t, n4, 10)
	key4 := ev4.(bifrost.Key_Event)
	testing.expect_value(t, key4.codepoint, 'a')
	testing.expect_value(t, key4.shifted_codepoint, 'A')
	testing.expect_value(t, bifrost.key_event_text(&key4), "A")

	ev5, n5, s5 := bifrost.parse_ansi_input(transmute([]byte)string("\x1b[<64;10;20M"), false)
	testing.expect_value(t, s5, bifrost.Parse_Status.Ok)
	testing.expect_value(t, n5, 12)
	mouse5 := ev5.(bifrost.Mouse_Event)
	testing.expect_value(t, mouse5.button, bifrost.Mouse_Button.Wheel_Up)
	testing.expect_value(t, mouse5.col, i16(9))
	testing.expect_value(t, mouse5.row, i16(19))
}

```
