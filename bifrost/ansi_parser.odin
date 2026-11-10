package bifrost

import "core:unicode/utf8"

// =============================================================================
// Parser Status, Kitty Flags & Streaming Input Reader State
// =============================================================================

Parse_Status :: enum u8 {
	Ok,
	Need_More,
	Ignored,
	Malformed,
}

Kitty_Flag :: enum u8 {
	Disambiguate           = 0,
	Report_Events          = 1,
	Report_Alternate_Keys  = 2,
	Report_All_As_Ctl_Seqs = 3,
	Report_Text            = 4,
}

Kitty_Flags :: distinct bit_set[Kitty_Flag; u8]

DEFAULT_KITTY_FLAGS :: Kitty_Flags{.Disambiguate, .Report_Alternate_Keys, .Report_All_As_Ctl_Seqs, .Report_Text}

INPUT_STREAM_BUF_SIZE :: 4096

Input_Stream_Reader :: struct {
	buf:       [INPUT_STREAM_BUF_SIZE]byte,
	head:      int,
	len:       int,
	sgr_pixel: bool,
	cell_w:    f32,
	cell_h:    f32,
}

// Helper to retrieve the slice of UTF-8 text stored inline on a Key_Event.
key_event_text :: proc "contextless" (ev: ^Key_Event) -> string {
	return string(ev.text_buf[:ev.text_len])
}

input_stream_reset :: proc "contextless" (reader: ^Input_Stream_Reader) {
	if reader != nil {
		reader.head = 0
		reader.len  = 0
	}
}

input_stream_feed :: proc "contextless" (reader: ^Input_Stream_Reader, data: []byte) -> int {
	if reader == nil || len(data) == 0 {
		return 0
	}
	space := len(reader.buf) - reader.len
	if space < len(data) && reader.head > 0 {
		rem := reader.len - reader.head
		if rem > 0 {
			copy(reader.buf[:rem], reader.buf[reader.head:reader.len])
		}
		reader.head = 0
		reader.len  = rem
		space = len(reader.buf) - reader.len
	}
	if space <= 0 {
		reader.head = 0
		reader.len  = 0
		space = len(reader.buf)
	}
	n := min(len(data), space)
	copy(reader.buf[reader.len : reader.len + n], data[:n])
	reader.len += n
	return n
}

input_stream_feed_string :: proc "contextless" (reader: ^Input_Stream_Reader, s: string) -> int {
	return input_stream_feed(reader, transmute([]byte)s)
}

input_stream_consume :: proc "contextless" (reader: ^Input_Stream_Reader, count: int) {
	if reader == nil || count <= 0 {
		return
	}
	reader.head = min(reader.len, reader.head + count)
}

// Advances through buffered bytes, skipping .Ignored and .Malformed prefixes until
// a complete Input_Event (.Ok) is decoded or .Need_More is reached.
input_stream_next :: proc(
	reader: ^Input_Stream_Reader,
	is_timeout: bool = false,
) -> (
	event: Input_Event,
	status: Parse_Status,
) {
	if reader == nil {
		return nil, .Need_More
	}
	for reader.head < reader.len {
		ev, consumed, st := parse_ansi_input(
			reader.buf[reader.head:reader.len],
			is_timeout,
			reader.sgr_pixel,
			reader.cell_w,
			reader.cell_h,
		)
		switch st {
		case .Ok:
			input_stream_consume(reader, consumed)
			return ev, .Ok
		case .Ignored, .Malformed:
			input_stream_consume(reader, max(consumed, 1))
		case .Need_More:
			return nil, .Need_More
		}
	}
	return nil, .Need_More
}

// =============================================================================
// Pure Zero-Allocation Streaming ANSI / Kitty / SGR Mouse Input Parser
// =============================================================================

MOUSE_BIT_MOTION  :: u16(0b0010_0000)
MOUSE_BIT_BUTTONS :: u16(0b1100_0011)
MOUSE_BIT_SHIFT   :: u16(0b0000_0100)
MOUSE_BIT_ALT     :: u16(0b0000_1000)
MOUSE_BIT_CTRL    :: u16(0b0001_0000)
MOUSE_BIT_LEAVE   :: u16(0b1_0000_0000)

BRACKETED_PASTE_START :: "\x1b[200~"
BRACKETED_PASTE_END   :: "\x1b[201~"

@(private)
classify_codepoint_key :: proc "contextless" (cp: rune) -> (code: Key_Code, ch: rune) {
	switch cp {
	case 0x09:
		return .Tab, cp
	case 0x0D:
		return .Enter, cp
	case 0x1B:
		return .Escape, cp
	case 0x20:
		return .Space, ' '
	case 0x7F:
		return .Backspace, cp
	case 57348 ..= 57454, 0x110001:
		return Key_Code(cp), cp
	}
	return .Rune, cp
}

parse_ansi_input :: proc(
	buf: []byte,
	is_timeout: bool = false,
	sgr_pixel_mode: bool = false,
	cell_w: f32 = 10.0,
	cell_h: f32 = 20.0,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
	if len(buf) == 0 {
		return nil, 0, .Need_More
	}

	if buf[0] == 0x1b {
		if len(buf) == 1 {
			if is_timeout {
				return Key_Event{
					code      = .Escape,
					ch        = rune(Key_Code.Escape),
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
			return parse_csi(buf, is_timeout, sgr_pixel_mode, cell_w, cell_h)
		case ']': // 0x5D - OSC
			return parse_osc(buf, is_timeout)
		case:
			// Consecutive ESC: emit first ESC and leave second ESC in buffer
			if buf[1] == 0x1b {
				return Key_Event{
					code      = .Escape,
					ch        = rune(Key_Code.Escape),
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
			code, ch := classify_codepoint_key(rune(buf[1]))
			return Key_Event{
				code      = code,
				ch        = ch,
				codepoint = rune(buf[1]),
				mods      = {.Alt},
				action    = .Press,
			}, 2, .Ok
		}
	}

	return parse_ground(buf, is_timeout)
}

// =============================================================================
// Ground State (C0 Controls, ASCII, UTF-8)
// =============================================================================

@(private)
parse_ground :: proc(
	buf: []byte,
	is_timeout: bool,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
	b := buf[0]

	switch b {
	case 0x00:
		return Key_Event{
			code      = .Rune,
			ch        = '@',
			codepoint = '@',
			mods      = {.Ctrl},
			action    = .Press,
		}, 1, .Ok
	case 0x08, 0x7F:
		return Key_Event{
			code      = .Backspace,
			ch        = rune(Key_Code.Backspace),
			codepoint = rune(Key_Code.Backspace),
			action    = .Press,
		}, 1, .Ok
	case 0x09:
		return Key_Event{
			code      = .Tab,
			ch        = rune(Key_Code.Tab),
			codepoint = rune(Key_Code.Tab),
			action    = .Press,
		}, 1, .Ok
	case 0x0A:
		return Key_Event{
			code      = .Rune,
			ch        = 'j',
			codepoint = 'j',
			mods      = {.Ctrl},
			action    = .Press,
		}, 1, .Ok
	case 0x0D:
		return Key_Event{
			code      = .Enter,
			ch        = rune(Key_Code.Enter),
			codepoint = rune(Key_Code.Enter),
			action    = .Press,
		}, 1, .Ok
	case 0x01 ..= 0x07, 0x0B ..= 0x0C, 0x0E ..= 0x1A:
		cp := rune(b + 0x60)
		return Key_Event{
			code      = .Rune,
			ch        = cp,
			codepoint = cp,
			mods      = {.Ctrl},
			action    = .Press,
		}, 1, .Ok
	case 0x1B:
		return Key_Event{
			code      = .Escape,
			ch        = rune(Key_Code.Escape),
			codepoint = rune(Key_Code.Escape),
			action    = .Press,
		}, 1, .Ok
	}

	// Printable ASCII fast-path
	if b < 0x80 {
		code, ch := classify_codepoint_key(rune(b))
		ev := Key_Event{
			code      = code,
			ch        = ch,
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

	code, ch := classify_codepoint_key(r)
	ev := Key_Event{
		code      = code,
		ch        = ch,
		codepoint = r,
		action    = .Press,
		text_len  = u8(width),
	}
	copy(ev.text_buf[:width], buf[:width])
	return ev, width, .Ok
}

@(private)
utf8_sequence_length :: proc "contextless" (lead: byte) -> int {
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

// =============================================================================
// SS3, DCS/SOS/PM/APC, and OSC Parsers
// =============================================================================

@(private)
parse_ss3 :: proc(
	buf: []byte,
	is_timeout: bool,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
	if len(buf) < 3 {
		if is_timeout {
			// Disambiguate timed-out "\x1bO" as Alt+O
			return Key_Event{
				code      = .Rune,
				ch        = 'O',
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
		ch        = rune(code),
		codepoint = rune(code),
		action    = .Press,
	}, 3, .Ok
}

@(private)
skip_until_st :: proc(
	buf: []byte,
	is_timeout: bool,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
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
parse_osc :: proc(
	buf: []byte,
	is_timeout: bool,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
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

// =============================================================================
// CSI Parser (Legacy Keys, Bracketed Paste, Focus, XTWINOPS, Kitty CSI u, SGR Mouse)
// =============================================================================

@(private)
parse_csi :: proc(
	buf: []byte,
	is_timeout: bool,
	sgr_pixel_mode: bool = false,
	cell_w: f32 = 10.0,
	cell_h: f32 = 20.0,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
	if len(buf) < 3 {
		if is_timeout {
			return Key_Event{
				code      = .Rune,
				ch        = '[',
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
			ch        = rune(Key_Code.Tab),
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
		return parse_mouse(seq, buf, is_timeout, sgr_pixel_mode, cell_w, cell_h)
	case 't':
		return parse_xtwinops(seq)
	case 'u':
		return parse_kitty_csi_u(seq)
	case:
		return nil, len(seq), .Ignored
	}
}

@(private)
parse_csi_legacy_letter :: proc(
	seq: []byte,
	final: byte,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
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
		ch        = rune(code),
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
parse_csi_tilde :: proc(
	full_buf: []byte,
	seq: []byte,
	is_timeout: bool,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
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
		ch        = rune(code),
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

// =============================================================================
// Kitty Keyboard Protocol (CSI u)
// =============================================================================

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

	code, ch := classify_codepoint_key(rune(cp_u32))
	key := Key_Event{
		code      = code,
		ch        = ch,
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

	// Promote shifted codepoint for printable runes when Shift is the only active modifier,
	// and synthesize text_buf when no explicit text field was reported.
	non_lock_mods := key.mods - {.Caps_Lock, .Num_Lock}
	if non_lock_mods == {.Shift} && ((key.codepoint >= 0x20 && key.codepoint <= 0x7E) || key.shifted_codepoint != 0) {
		upper := key.shifted_codepoint
		if upper == 0 {
			upper = ascii_to_upper(key.codepoint)
			key.shifted_codepoint = upper
		}
		if key.code == .Rune && upper != 0 {
			key.ch = upper
		}
		if !has_text_field && upper != 0 {
			encoded, w := utf8.encode_rune(upper)
			copy(key.text_buf[:w], encoded[:w])
			key.text_len = u8(w)
		}
	} else if !has_text_field && non_lock_mods == {} && key.codepoint >= 0x20 && key.codepoint <= 0x7E {
		key.text_buf[0] = byte(key.codepoint)
		key.text_len = 1
	}

	return key, len(seq), .Ok
}

// =============================================================================
// SGR 1006 & X10 Mouse Parser
// =============================================================================

@(private)
parse_mouse :: proc(
	seq: []byte,
	full_buf: []byte,
	is_timeout: bool,
	sgr_pixel_mode: bool = false,
	cell_w: f32 = 10.0,
	cell_h: f32 = 20.0,
) -> (
	event: Input_Event,
	bytes_consumed: int,
	status: Parse_Status,
) {
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
		// SGR 1006 / 1016 mouse: \x1b [ < Pb ; Px ; Py {M|m}
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

		if sgr_pixel_mode {
			if (button_mask & MOUSE_BIT_LEAVE) != 0 {
				return Mouse_Event{
					action = .Leave,
					button = .None,
				}, consumed, .Ok
			}
			px_i32, px_ok32 := parse_i32_default(f2, 1)
			py_i32, py_ok32 := parse_i32_default(f3, 1)
			if !px_ok32 || !py_ok32 {
				return nil, len(seq), .Ignored
			}
			released := seq[len(seq) - 1] == 'm'
			if mouse_ev, ok := mouse_event_from_sgr_pixels(i32(b_val), px_i32, py_i32, released, cell_w, cell_h); ok {
				return mouse_ev, consumed, .Ok
			}
			return nil, len(seq), .Ignored
		}

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

	mods: Mod_Flags
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
	col := (px - 1) if px > 0 else px
	row := (py - 1) if py > 0 else py

	return Mouse_Event{
		x      = i32(col),
		y      = i32(row),
		col    = col,
		row    = row,
		button = btn,
		mods   = mods,
		action = action,
	}, consumed, .Ok
}

// =============================================================================
// In-Band Resize (XTWINOPS CSI 48 ; height ; width ; height_pix ; width_pix t)
// =============================================================================

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
		width   = i32(cols),
		height  = i32(rows),
		x_pixel = u16(x_pix),
		y_pixel = u16(y_pix),
	}, len(seq), .Ok
}

// =============================================================================
// Zero-Allocation Numeric & String Helpers
// =============================================================================

@(private)
parse_modifier_and_action :: proc "contextless" (field: []byte) -> (mods: Mod_Flags, action: Key_Action, ok: bool) {
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
	mods = transmute(Mod_Flags)bits
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
split_byte :: proc "contextless" (s: []byte, sep: byte) -> (head: []byte, tail: []byte, found: bool) {
	for b, i in s {
		if b == sep {
			return s[:i], s[i + 1:], true
		}
	}
	return s, nil, false
}

@(private)
index_of_slice :: proc "contextless" (haystack: []byte, needle: []byte) -> int {
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
parse_u32 :: proc "contextless" (buf: []byte) -> (val: u32, ok: bool) {
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
parse_i32_default :: proc "contextless" (buf: []byte, default_val: i32) -> (val: i32, ok: bool) {
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
	acc: i64 = 0
	for b in s {
		if b < '0' || b > '9' {
			return 0, false
		}
		acc = acc * 10 + i64(b - '0')
		if acc > 0x7FFF_FFFF {
			return 0, false
		}
	}
	res := -acc if neg else acc
	return i32(res), true
}

@(private)
parse_i16_default :: proc "contextless" (buf: []byte, default_val: i16) -> (val: i16, ok: bool) {
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
ascii_to_upper :: proc "contextless" (r: rune) -> rune {
	if r >= 'a' && r <= 'z' {
		return r - 32
	}
	return r
}
