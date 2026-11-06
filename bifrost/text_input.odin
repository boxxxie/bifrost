package bifrost

import "core:mem"
import "core:unicode/utf8"

// =============================================================================
// Single-Line UTF-8 Text Input Widget & Grapheme-Cluster Cursor Navigation
// =============================================================================

MAX_TEXT_SLOTS :: 16
MAX_TEXT_BYTES :: 256

Text_Input_Slot :: struct {
	id_hash:         u64,
	buf:             [MAX_TEXT_BYTES]byte,
	len:             int,
	cursor_byte:     int,
	sel_anchor_byte: int,  // Anchor byte offset when `has_selection == true`
	has_selection:   bool, // True when an active `[min(anchor,cursor), max(anchor,cursor))` selection exists
	scroll_col:      i32,
	inner_w:         i32,
	inner_x:         i32,
	linked_list_id:  u64, // Optional virtual list ID hash to forward Up/Down/PageUp/PageDown keys to
	placeholder:     string,
	vis_buf:         [MAX_TEXT_BYTES + 16]byte,
	vis_len:         int,
	initialized:     bool,
}

Text_Input_Config :: struct {
	placeholder:    string,
	initial_text:   string,
	linked_list_id: string, // Optional virtual list ID for Telescope-style arrow navigation while typing
	width:          Axis_Size,
	height:         Axis_Size,
	border:         Border_Kind,
	fg:             Color,
	bg:             Color,
	placeholder_fg: Color,
	border_fg:      Color,
	title:          string,
	focus_flags:    Focus_Flags,
	two_stage:      bool,
}

Visible_Utf8_Slice :: struct {
	text:       string, // Valid UTF-8 substring inside [scroll_col, scroll_col + max_cols)
	start_byte: int,
	end_byte:   int,
	lead_pad:   i32,    // 1 if a 2-column glyph straddled scroll_col on the left edge
	trail_pad:  i32,    // 1 if a 2-column glyph straddled scroll_col + max_cols on the right edge
	columns:    i32,    // Display width of `text`
}

// =============================================================================
// Grapheme-Cluster Stepping & Display-Column Viewport Slicing
// =============================================================================

// Advances forward by one extended grapheme cluster from `byte_idx` in `str`.
// Groups base runes with trailing zero-width combining marks, variation selectors (`U+FE0F`),
// and Zero-Width Joiner (`U+200D`) sequences (such as `"👩‍🚀"`).
next_grapheme_cluster :: proc "contextless" (str: string, byte_idx: int) -> (next_byte: int, cluster_width: i32, lead_rune: rune) {
	if byte_idx >= len(str) {
		return len(str), 0, 0
	}

	r, r_len := utf8.decode_rune_in_string(str[byte_idx:])
	idx := byte_idx + max(1, r_len)
	lead_rune = r
	w := i32(rune_display_width(r))

	for idx < len(str) {
		nr, nr_len := utf8.decode_rune_in_string(str[idx:])
		step := max(1, nr_len)

		// Zero-Width Joiner (U+200D): consume ZWJ AND the immediately following joined rune
		if nr == 0x200d {
			idx += step
			if idx < len(str) {
				jr, jr_len := utf8.decode_rune_in_string(str[idx:])
				idx += max(1, jr_len)
				jw := i32(rune_display_width(jr))
				if jw > w {
					w = jw
				}
			}
			continue
		}

		// Emoji Variation Selector-16 (U+FE0F) promotes preceding 1-column symbol to 2 columns
		if nr == 0xfe0f {
			idx += step
			if w < 2 {
				w = 2
			}
			continue
		}

		// Other zero-width combining marks / variation selectors attach to the current cluster
		nw := rune_display_width(nr)
		if nw == 0 && nr >= 0x0300 {
			idx += step
			continue
		}

		break
	}

	return idx, w, lead_rune
}

// Steps backward by one extended grapheme cluster from `byte_idx` in `str`.
prev_grapheme_cluster :: proc "contextless" (str: string, byte_idx: int) -> int {
	target := clamp(byte_idx, 0, len(str))
	if target <= 0 {
		return 0
	}
	prev := 0
	cur := 0
	for cur < target {
		prev = cur
		next_b, _, _ := next_grapheme_cluster(str, cur)
		if next_b >= target {
			break
		}
		cur = next_b
	}
	return prev
}

// Slices a UTF-8 string to fit within `[scroll_col, scroll_col + max_cols)` display columns
// without ever splitting multi-byte runes or wide 2-column CJK/Emoji grapheme clusters.
slice_utf8_by_display_width :: proc "contextless" (
	str: string,
	scroll_col: i32,
	max_cols: i32,
) -> Visible_Utf8_Slice {
	if max_cols <= 0 || len(str) == 0 {
		return Visible_Utf8_Slice{}
	}

	win_start := max(0, scroll_col)
	win_end   := win_start + max_cols

	cur_col: i32 = 0
	idx := 0
	start_byte := len(str)
	end_byte   := len(str)
	started    := false
	lead_pad: i32  = 0
	trail_pad: i32 = 0
	used_cols: i32 = 0

	for idx < len(str) {
		next_idx, cw, _ := next_grapheme_cluster(str, idx)
		if cw <= 0 {
			if started {
				end_byte = next_idx
			}
			idx = next_idx
			continue
		}

		cluster_start_col := cur_col
		cluster_end_col   := cur_col + cw

		if !started {
			if cluster_end_col <= win_start {
				cur_col = cluster_end_col
				idx = next_idx
				continue
			}
			if cluster_start_col < win_start && cluster_end_col > win_start {
				// A 2-column glyph straddles the left boundary: pad with 1 space and start at next_idx
				lead_pad   = cluster_end_col - win_start
				start_byte = next_idx
				end_byte   = next_idx
				started    = true
				cur_col    = cluster_end_col
				idx        = next_idx
				continue
			}
			start_byte = idx
			end_byte   = idx
			started    = true
		}

		if cluster_end_col > win_end {
			if cluster_start_col < win_end {
				trail_pad = win_end - cluster_start_col
			}
			break
		}

		end_byte  = next_idx
		used_cols += cw
		cur_col   = cluster_end_col
		idx       = next_idx
	}

	if !started || start_byte > end_byte {
		return Visible_Utf8_Slice{lead_pad = min(lead_pad, max_cols)}
	}

	return Visible_Utf8_Slice{
		text       = str[start_byte:end_byte],
		start_byte = start_byte,
		end_byte   = end_byte,
		lead_pad   = lead_pad,
		trail_pad  = trail_pad,
		columns    = used_cols,
	}
}

@(private)
is_word_rune :: proc "contextless" (r: rune) -> bool {
	if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' {
		return true
	}
	if (r >= 0x2000 && r <= 0x206f) || (r >= 0x3000 && r <= 0x303f) {
		return false
	}
	return r >= 0x80 && rune_display_width(r) > 0
}

@(private)
is_whitespace_rune :: proc "contextless" (r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == 0x3000
}

// =============================================================================
// Text Input Slot Accessors & Widget Builder
// =============================================================================

get_text_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Text_Input_Slot {
	empty_idx := -1
	for i := 0; i < MAX_TEXT_SLOTS; i += 1 {
		if inp.text_slots[i].id_hash == id_hash {
			return &inp.text_slots[i]
		}
		if empty_idx == -1 && inp.text_slots[i].id_hash == 0 {
			empty_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else 0
	inp.text_slots[idx] = Text_Input_Slot{
		id_hash = id_hash,
		inner_w = 20,
	}
	return &inp.text_slots[idx]
}

get_text :: proc(inp: ^Input_State, id: string) -> string {
	slot := get_text_slot(inp, hash_id(id))
	return string(slot.buf[:slot.len])
}

set_text :: proc(inp: ^Input_State, id: string, value: string) {
	slot := get_text_slot(inp, hash_id(id))
	n := min(len(value), MAX_TEXT_BYTES)
	for n > 0 && n < len(value) && (value[n] & 0xc0) == 0x80 {
		n -= 1
	}
	for i := 0; i < n; i += 1 {
		slot.buf[i] = value[i]
	}
	slot.len             = n
	slot.cursor_byte     = n
	slot.sel_anchor_byte = 0
	slot.has_selection   = false
	slot.scroll_col      = 0
	slot.initialized     = true
}

get_text_selection_range :: proc "contextless" (slot: ^Text_Input_Slot) -> (lo, hi: int, active: bool) {
	if !slot.has_selection {
		return slot.cursor_byte, slot.cursor_byte, false
	}
	a := clamp(slot.sel_anchor_byte, 0, slot.len)
	b := clamp(slot.cursor_byte, 0, slot.len)
	if a == b {
		return a, b, false
	}
	return min(a, b), max(a, b), true
}

get_selected_text :: proc(inp: ^Input_State, id: string) -> string {
	slot := get_text_slot(inp, hash_id(id))
	lo, hi, active := get_text_selection_range(slot)
	if !active {
		return ""
	}
	return string(slot.buf[lo:hi])
}

delete_selected_range :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) -> bool {
	lo, hi, active := get_text_selection_range(slot)
	if !active {
		slot.has_selection = false
		return false
	}
	del_len := hi - lo
	for i := lo; i < slot.len - del_len; i += 1 {
		slot.buf[i] = slot.buf[i + del_len]
	}
	slot.len            -= del_len
	slot.cursor_byte     = lo
	slot.sel_anchor_byte = lo
	slot.has_selection   = false
	inp.text_changed_id  = slot.id_hash
	return true
}

copy_selection_to_clipboard :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) -> bool {
	lo, hi, active := get_text_selection_range(slot)
	if !active {
		return false
	}
	n := min(hi - lo, len(inp.clipboard_buf))
	for i := 0; i < n; i += 1 {
		inp.clipboard_buf[i] = slot.buf[lo + i]
	}
	inp.clipboard_len = n
	inp.osc52_pending = true
	return true
}

text_input_insert_string :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot, text: string) -> bool {
	delete_selected_range(inp, slot)
	for r in text {
		if r >= 32 && r != 127 {
			text_input_insert_rune(inp, slot, r)
		}
	}
	return true
}

was_text_changed :: proc(inp: ^Input_State, id: string) -> bool {
	return inp.text_changed_id != 0 && inp.text_changed_id == hash_id(id)
}

ui_text_input :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Text_Input_Config = {},
) -> i32 {
	id_h := hash_id(id)
	slot := get_text_slot(inp, id_h)

	if !slot.initialized {
		slot.initialized = true
		if len(cfg.initial_text) > 0 {
			set_text(inp, id, cfg.initial_text)
		}
	}
	slot.placeholder = cfg.placeholder
	if len(cfg.linked_list_id) > 0 {
		slot.linked_list_id = hash_id(cfg.linked_list_id)
	}

	b_pad: i32 = 2 if cfg.border != .None else 0
	w := cfg.width if cfg.width != nil else grow(1, min = 12)
	h := cfg.height if cfg.height != nil else fixed(1 + b_pad)

	full_text := string(slot.buf[:slot.len])
	disp_text := full_text if slot.len > 0 else cfg.placeholder
	fg := cfg.fg
	if slot.len == 0 && cfg.placeholder_fg.kind != .Default {
		fg = cfg.placeholder_fg
	}

	s.paints[id_h] = Paint_Spec{
		title       = cfg.title,
		text        = disp_text,
		fg          = fg,
		bg          = cfg.bg,
		border_fg   = cfg.border_fg,
		title_style = {.Bold},
		fill_bg     = cfg.bg.kind != .Default,
	}

	flags := cfg.focus_flags
	if cfg.two_stage {
		flags += {.Focusable, .Captures_Text}
		flags -= {.Auto_Edit}
	} else if (.Captures_Text not_in flags) && (.Scope_Text_Sink not_in flags) {
		flags += {.Focusable, .Captures_Text, .Auto_Edit}
	} else {
		flags += {.Captures_Text}
	}
	is_enabled := .Disabled not_in flags
	is_focusable := (.Focusable in flags) && is_enabled

	return leaf(ctx, id, string_display_width(disp_text) + b_pad, 1 + b_pad, Box_Config{
		width       = w,
		height      = h,
		border      = cfg.border,
		focus_flags = flags,
		focusable   = is_focusable,
		clickable   = is_enabled,
		hoverable   = is_enabled,
		text_input  = true,
		cross_align = .Center,
	})
}

// Synchronizes horizontal scroll_col, visible UTF-8 slice, and block cursor column for a text input node.
sync_text_input_paint :: proc(s: ^Screen, inp: ^Input_State, node: Layout_Node) {
	slot := get_text_slot(inp, node.id_hash)
	inner_w := max(1, node.inner_rect.w)
	slot.inner_w = inner_w
	slot.inner_x = node.inner_rect.x

	full_text := string(slot.buf[:slot.len])
	slot.cursor_byte = clamp(slot.cursor_byte, 0, slot.len)

	cur_disp_col := string_display_width(full_text[:slot.cursor_byte])
	usable_cols := max(1, inner_w - 1)
	if cur_disp_col < slot.scroll_col {
		slot.scroll_col = cur_disp_col
	} else if cur_disp_col >= slot.scroll_col + usable_cols {
		slot.scroll_col = cur_disp_col - usable_cols + 1
	}
	slot.scroll_col = max(0, slot.scroll_col)

	paint, ok := s.paints[node.id_hash]
	if !ok {
		return
	}

	focused := node.id_hash == inp.focused_id
	editing := node.id_hash == inp.editing_id
	if slot.len > 0 {
		vis := slice_utf8_by_display_width(full_text, slot.scroll_col, inner_w)
		pos := 0
		for p: i32 = 0; p < vis.lead_pad && pos < len(slot.vis_buf); p += 1 {
			slot.vis_buf[pos] = ' '
			pos += 1
		}
		for b_idx := 0; b_idx < len(vis.text) && pos < len(slot.vis_buf); b_idx += 1 {
			slot.vis_buf[pos] = vis.text[b_idx]
			pos += 1
		}
		slot.vis_len = pos
		paint.text   = string(slot.vis_buf[:slot.vis_len])
		paint.style -= {.Dim}
		paint.spans  = nil

		if sel_lo, sel_hi, has_sel := get_text_selection_range(slot); has_sel {
			clamped_lo := clamp(sel_lo, vis.start_byte, vis.end_byte)
			clamped_hi := clamp(sel_hi, vis.start_byte, vis.end_byte)
			if clamped_hi > clamped_lo {
				lead := int(vis.lead_pad)
				s0 := clamp(lead + (clamped_lo - vis.start_byte), 0, slot.vis_len)
				s1 := clamp(lead + (clamped_hi - vis.start_byte), s0, slot.vis_len)
				spans := make([dynamic]Styled_Span, 0, 3, s.paints.allocator)
				if s0 > 0 {
					append(&spans, Styled_Span{text = paint.text[:s0], fg = paint.fg, bg = paint.bg})
				}
				append(&spans, Styled_Span{
					text  = paint.text[s0:s1],
					fg    = paint.fg,
					bg    = paint.bg,
					style = {.Reverse},
				})
				if s1 < slot.vis_len {
					append(&spans, Styled_Span{text = paint.text[s1:], fg = paint.fg, bg = paint.bg})
				}
				paint.spans = spans[:]
			}
		}
	} else {
		vis := slice_utf8_by_display_width(slot.placeholder, 0, inner_w)
		paint.text  = vis.text
		paint.spans = nil
		paint.style += {.Dim}
	}

	if .Disabled in node.focus_flags {
		paint.style += {.Dim}
		paint.has_cursor = false
	} else {
		if editing {
			paint.has_cursor = true
			paint.cursor_col = clamp(cur_disp_col - slot.scroll_col, 0, max(0, inner_w - 1))
		} else {
			paint.has_cursor = false
		}
		if focused || editing {
			if paint.border_fg.kind == .Default {
				paint.border_fg = rgb(255, 215, 0)
			}
		}
	}

	s.paints[node.id_hash] = paint
}

// =============================================================================
// Text Input Keyboard Editing, Word Motions & Click-to-Place Cursor
// =============================================================================

handle_text_input_key :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	node := ctx.nodes[node_idx]
	slot := get_text_slot(inp, node.id_hash)
	full_text := string(slot.buf[:slot.len])
	slot.cursor_byte = clamp(slot.cursor_byte, 0, slot.len)
	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}

	// 1. Telescope-style linked virtual list navigation (Up / Down / Page_Up / Page_Down / Ctrl+N / Ctrl+P)
	if slot.linked_list_id != 0 {
		if list_idx, ok := ctx.id_map[slot.linked_list_id]; ok && is_node_allowed(ctx, list_idx, capture_idx) {
			list_node := &ctx.nodes[list_idx]
			list_slot := get_scroll_slot(inp, slot.linked_list_id)
			page := max(1, list_slot.viewport_rows - 1)
			if eff_mods == {} {
				#partial switch ev.code {
				case .Up:
					move_virtual_selection(list_slot, -1)
					list_node.config.scroll_offset = list_slot.offset
					inp.scrolled_id = slot.linked_list_id
					return true
				case .Down:
					move_virtual_selection(list_slot, +1)
					list_node.config.scroll_offset = list_slot.offset
					inp.scrolled_id = slot.linked_list_id
					return true
				case .Page_Up:
					move_virtual_selection(list_slot, -page)
					list_node.config.scroll_offset = list_slot.offset
					inp.scrolled_id = slot.linked_list_id
					return true
				case .Page_Down:
					move_virtual_selection(list_slot, +page)
					list_node.config.scroll_offset = list_slot.offset
					inp.scrolled_id = slot.linked_list_id
					return true
				}
			} else if eff_mods == {.Ctrl} && ev.code == .Rune {
				switch ev.ch {
				case 'n', 'N':
					move_virtual_selection(list_slot, +1)
					list_node.config.scroll_offset = list_slot.offset
					inp.scrolled_id = slot.linked_list_id
					return true
				case 'p', 'P':
					move_virtual_selection(list_slot, -1)
					list_node.config.scroll_offset = list_slot.offset
					inp.scrolled_id = slot.linked_list_id
					return true
				}
			}
		}
	}

	// 2. Readline / Emacs / Clipboard Ctrl+Key and Alt+Key motions
	if .Ctrl in ev.mods && ev.code == .Rune {
		switch ev.ch {
		case 'a', 'A':
			if inp.keymap_style == .Emacs && (.Shift not_in eff_mods) {
				slot.has_selection = false
				slot.cursor_byte   = 0
				return true
			}
			slot.sel_anchor_byte = 0
			slot.cursor_byte     = slot.len
			slot.has_selection   = slot.len > 0
			return true
		case 'b', 'B':
			slot.has_selection = false
			slot.cursor_byte   = prev_grapheme_cluster(full_text, slot.cursor_byte)
			return true
		case 'f', 'F':
			slot.has_selection = false
			next_b, _, _      := next_grapheme_cluster(full_text, slot.cursor_byte)
			slot.cursor_byte   = next_b
			return true
		case 'd', 'D':
			if delete_selected_range(inp, slot) {
				return true
			}
			if slot.cursor_byte < slot.len {
				next_b, _, _ := next_grapheme_cluster(full_text, slot.cursor_byte)
				del_len := next_b - slot.cursor_byte
				for i := slot.cursor_byte; i < slot.len - del_len; i += 1 {
					slot.buf[i] = slot.buf[i + del_len]
				}
				slot.len -= del_len
				inp.text_changed_id = slot.id_hash
			}
			return true
		case 'c', 'C':
			if slot.has_selection {
				copy_selection_to_clipboard(inp, slot)
				return true
			}
		case 'x', 'X':
			if slot.has_selection {
				copy_selection_to_clipboard(inp, slot)
				delete_selected_range(inp, slot)
				return true
			}
		case 'v', 'V', 'y', 'Y':
			if inp.clipboard_len > 0 {
				return text_input_insert_string(inp, slot, string(inp.clipboard_buf[:inp.clipboard_len]))
			}
			return true
		case 'e', 'E':
			slot.has_selection = false
			slot.cursor_byte   = slot.len
			return true
		case 'u', 'U':
			slot.has_selection = false
			if slot.cursor_byte > 0 {
				kill_len := min(slot.cursor_byte, len(inp.clipboard_buf))
				for i := 0; i < kill_len; i += 1 {
					inp.clipboard_buf[i] = slot.buf[i]
				}
				inp.clipboard_len = kill_len
				inp.osc52_pending = kill_len > 0
				text_input_kill_to_start(inp, slot)
			}
			return true
		case 'k', 'K':
			slot.has_selection = false
			if slot.cursor_byte < slot.len {
				kill_len := min(slot.len - slot.cursor_byte, len(inp.clipboard_buf))
				for i := 0; i < kill_len; i += 1 {
					inp.clipboard_buf[i] = slot.buf[slot.cursor_byte + i]
				}
				inp.clipboard_len = kill_len
				inp.osc52_pending = kill_len > 0
				text_input_kill_to_end(inp, slot)
			}
			return true
		case 'w', 'W':
			if delete_selected_range(inp, slot) {
				return true
			}
			if slot.cursor_byte > 0 {
				text_input_delete_word_whitespace(inp, slot)
			}
			return true
		}
	}

	if .Alt in ev.mods && ev.code == .Rune {
		switch ev.ch {
		case 'b', 'B':
			slot.has_selection = false
			slot.cursor_byte   = text_input_move_word_left(full_text, slot.cursor_byte)
			return true
		case 'f', 'F':
			slot.has_selection = false
			slot.cursor_byte   = text_input_move_word_right(full_text, slot.cursor_byte)
			return true
		case 'd', 'D':
			if delete_selected_range(inp, slot) {
				return true
			}
			if slot.cursor_byte < slot.len {
				text_input_delete_word_after(inp, slot)
			}
			return true
		}
	}

	// 3. Standard cursor movement, Shift-selection & deletion keys
	#partial switch ev.code {
	case .Left:
		if .Shift in eff_mods {
			if !slot.has_selection {
				slot.sel_anchor_byte = slot.cursor_byte
			}
			if (.Ctrl in eff_mods) || (.Alt in eff_mods) {
				slot.cursor_byte = text_input_move_word_left(full_text, slot.cursor_byte)
			} else {
				slot.cursor_byte = prev_grapheme_cluster(full_text, slot.cursor_byte)
			}
			slot.has_selection = (slot.cursor_byte != slot.sel_anchor_byte)
			return true
		}
		if lo, _, active := get_text_selection_range(slot); active && (.Ctrl not_in eff_mods) && (.Alt not_in eff_mods) {
			slot.cursor_byte   = lo
			slot.has_selection = false
			return true
		}
		slot.has_selection = false
		if (.Ctrl in ev.mods) || (.Alt in ev.mods) {
			slot.cursor_byte = text_input_move_word_left(full_text, slot.cursor_byte)
		} else {
			slot.cursor_byte = prev_grapheme_cluster(full_text, slot.cursor_byte)
		}
		return true

	case .Right:
		if .Shift in eff_mods {
			if !slot.has_selection {
				slot.sel_anchor_byte = slot.cursor_byte
			}
			if (.Ctrl in eff_mods) || (.Alt in eff_mods) {
				slot.cursor_byte = text_input_move_word_right(full_text, slot.cursor_byte)
			} else {
				next_b, _, _ := next_grapheme_cluster(full_text, slot.cursor_byte)
				slot.cursor_byte = next_b
			}
			slot.has_selection = (slot.cursor_byte != slot.sel_anchor_byte)
			return true
		}
		if _, hi, active := get_text_selection_range(slot); active && (.Ctrl not_in eff_mods) && (.Alt not_in eff_mods) {
			slot.cursor_byte   = hi
			slot.has_selection = false
			return true
		}
		slot.has_selection = false
		if (.Ctrl in ev.mods) || (.Alt in ev.mods) {
			slot.cursor_byte = text_input_move_word_right(full_text, slot.cursor_byte)
		} else {
			next_b, _, _ := next_grapheme_cluster(full_text, slot.cursor_byte)
			slot.cursor_byte = next_b
		}
		return true

	case .Home:
		if .Shift in eff_mods {
			if !slot.has_selection {
				slot.sel_anchor_byte = slot.cursor_byte
			}
			slot.cursor_byte   = 0
			slot.has_selection = (slot.cursor_byte != slot.sel_anchor_byte)
			return true
		}
		slot.has_selection = false
		slot.cursor_byte   = 0
		return true

	case .End:
		if .Shift in eff_mods {
			if !slot.has_selection {
				slot.sel_anchor_byte = slot.cursor_byte
			}
			slot.cursor_byte   = slot.len
			slot.has_selection = (slot.cursor_byte != slot.sel_anchor_byte)
			return true
		}
		slot.has_selection = false
		slot.cursor_byte   = slot.len
		return true

	case .Backspace:
		if delete_selected_range(inp, slot) {
			return true
		}
		if (.Alt in ev.mods) || (.Ctrl in ev.mods) {
			if slot.cursor_byte > 0 {
				text_input_delete_word_boundary(inp, slot)
			}
			return true
		}
		if slot.cursor_byte > 0 {
			prev_b := prev_grapheme_cluster(full_text, slot.cursor_byte)
			del_len := slot.cursor_byte - prev_b
			for i := prev_b; i < slot.len - del_len; i += 1 {
				slot.buf[i] = slot.buf[i + del_len]
			}
			slot.len         -= del_len
			slot.cursor_byte  = prev_b
			inp.text_changed_id = slot.id_hash
		}
		return true

	case .Delete:
		if delete_selected_range(inp, slot) {
			return true
		}
		if (.Alt in ev.mods) || (.Ctrl in ev.mods) {
			if slot.cursor_byte < slot.len {
				text_input_delete_word_after(inp, slot)
			}
			return true
		}
		if slot.cursor_byte < slot.len {
			next_b, _, _ := next_grapheme_cluster(full_text, slot.cursor_byte)
			del_len := next_b - slot.cursor_byte
			for i := slot.cursor_byte; i < slot.len - del_len; i += 1 {
				slot.buf[i] = slot.buf[i + del_len]
			}
			slot.len -= del_len
			inp.text_changed_id = slot.id_hash
		}
		return true

	case .Space:
		if eff_mods - {.Shift} == {} {
			delete_selected_range(inp, slot)
			return text_input_insert_rune(inp, slot, ' ')
		}

	case .Rune:
		if (.Ctrl not_in eff_mods) && (.Alt not_in eff_mods) && ev.ch >= 32 {
			delete_selected_range(inp, slot)
			return text_input_insert_rune(inp, slot, ev.ch)
		}
	}

	return false
}

@(private)
text_input_insert_rune :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot, r: rune) -> bool {
	encoded, enc_len := utf8.encode_rune(r)
	if enc_len <= 0 || slot.len + enc_len > MAX_TEXT_BYTES {
		return true
	}
	for i := slot.len - 1; i >= slot.cursor_byte; i -= 1 {
		slot.buf[i + enc_len] = slot.buf[i]
	}
	for i := 0; i < enc_len; i += 1 {
		slot.buf[slot.cursor_byte + i] = encoded[i]
	}
	slot.len            += enc_len
	slot.cursor_byte    += enc_len
	inp.text_changed_id  = slot.id_hash
	return true
}

// Ctrl+W (unix-word-rubout): deletes backward across trailing whitespace, then deletes all non-whitespace
// characters up to the preceding whitespace boundary (e.g. "foo/bar_baz" -> "").
text_input_delete_word_whitespace :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) {
	str := string(slot.buf[:slot.len])
	pos := slot.cursor_byte
	for pos > 0 {
		prev := prev_grapheme_cluster(str, pos)
		r, _ := utf8.decode_rune_in_string(str[prev:pos])
		if !is_whitespace_rune(r) {
			break
		}
		pos = prev
	}
	for pos > 0 {
		prev := prev_grapheme_cluster(str, pos)
		r, _ := utf8.decode_rune_in_string(str[prev:pos])
		if is_whitespace_rune(r) {
			break
		}
		pos = prev
	}
	del_len := slot.cursor_byte - pos
	if del_len > 0 {
		kill_len := min(del_len, len(inp.clipboard_buf))
		for i := 0; i < kill_len; i += 1 {
			inp.clipboard_buf[i] = slot.buf[pos + i]
		}
		inp.clipboard_len = kill_len
		inp.osc52_pending = kill_len > 0
		for i := pos; i < slot.len - del_len; i += 1 {
			slot.buf[i] = slot.buf[i + del_len]
		}
		slot.len            -= del_len
		slot.cursor_byte     = pos
		inp.text_changed_id  = slot.id_hash
	}
}

// Alt+Backspace / Ctrl+Backspace: deletes backward across whitespace, then deletes either a contiguous
// punctuation run OR an alphanumeric/underscore word run (e.g. "foo/bar_baz" -> "foo/").
text_input_delete_word_boundary :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) {
	str := string(slot.buf[:slot.len])
	pos := text_input_move_word_left(str, slot.cursor_byte)
	del_len := slot.cursor_byte - pos
	if del_len > 0 {
		for i := pos; i < slot.len - del_len; i += 1 {
			slot.buf[i] = slot.buf[i + del_len]
		}
		slot.len            -= del_len
		slot.cursor_byte     = pos
		inp.text_changed_id  = slot.id_hash
	}
}

text_input_delete_word_after :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) {
	str := string(slot.buf[:slot.len])
	next_pos := text_input_move_word_right(str, slot.cursor_byte)
	del_len := next_pos - slot.cursor_byte
	if del_len > 0 {
		for i := slot.cursor_byte; i < slot.len - del_len; i += 1 {
			slot.buf[i] = slot.buf[i + del_len]
		}
		slot.len            -= del_len
		inp.text_changed_id  = slot.id_hash
	}
}

text_input_move_word_left :: proc "contextless" (str: string, cursor_byte: int) -> int {
	pos := clamp(cursor_byte, 0, len(str))
	// 1. Skip non-word runes (whitespace and punctuation delimiters)
	for pos > 0 {
		prev := prev_grapheme_cluster(str, pos)
		r, _ := utf8.decode_rune_in_string(str[prev:pos])
		if is_word_rune(r) {
			break
		}
		pos = prev
	}
	// 2. Skip contiguous word runes up to the preceding word boundary
	for pos > 0 {
		prev := prev_grapheme_cluster(str, pos)
		r, _ := utf8.decode_rune_in_string(str[prev:pos])
		if !is_word_rune(r) {
			break
		}
		pos = prev
	}
	return pos
}

text_input_move_word_right :: proc "contextless" (str: string, cursor_byte: int) -> int {
	pos := clamp(cursor_byte, 0, len(str))
	// 1. Skip non-word runes (whitespace and punctuation delimiters)
	for pos < len(str) {
		next_b, _, r := next_grapheme_cluster(str, pos)
		if is_word_rune(r) {
			break
		}
		pos = next_b
	}
	// 2. Advance across contiguous word runes
	for pos < len(str) {
		next_b, _, r := next_grapheme_cluster(str, pos)
		if !is_word_rune(r) {
			break
		}
		pos = next_b
	}
	return pos
}

text_input_kill_to_end :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) {
	if slot.cursor_byte < slot.len {
		slot.len            = slot.cursor_byte
		inp.text_changed_id = slot.id_hash
	}
}

text_input_kill_to_start :: proc "contextless" (inp: ^Input_State, slot: ^Text_Input_Slot) {
	del_len := slot.cursor_byte
	if del_len > 0 {
		for i := 0; i < slot.len - del_len; i += 1 {
			slot.buf[i] = slot.buf[i + del_len]
		}
		slot.len            -= del_len
		slot.cursor_byte     = 0
		inp.text_changed_id  = slot.id_hash
	}
}

// Places the cursor at the grapheme boundary corresponding to mouse click column `mx`.
handle_text_input_click :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	mx: i32,
) {
	node := ctx.nodes[node_idx]
	slot := get_text_slot(inp, node.id_hash)
	rel_col := max(0, mx - node.inner_rect.x) + slot.scroll_col
	full_text := string(slot.buf[:slot.len])

	cur_col: i32 = 0
	idx := 0
	for idx < len(full_text) {
		next_idx, cw, _ := next_grapheme_cluster(full_text, idx)
		if cur_col + cw > rel_col {
			break
		}
		cur_col += cw
		idx = next_idx
	}
	slot.cursor_byte   = idx
	slot.has_selection = false
}

// =============================================================================
// Real-Time xitdb Filtered Index View (Zero-Allocation Steady-State Filtering)
// =============================================================================

Xitdb_Filter_Kind :: enum u8 {
	None = 0,
	Key_Prefix,
	Key_Range,
	Substring,
}

Xitdb_Filter :: struct {
	matched_indices: [dynamic]i32,
	moment_slot:     i64,
	total_db_rows:   i32,
	active_query:    [MAX_TEXT_BYTES]byte,
	query_len:       int,
	allocator:       mem.Allocator,
	kind:            Xitdb_Filter_Kind,
	prefix:          string,
	lower_key:       string,
	upper_key:       string,
	needle:          string,
	hide_tx:         bool,
}

xitdb_filter_init :: proc(
	f: ^Xitdb_Filter,
	allocator := context.allocator,
	capacity: int = 256,
) -> mem.Allocator_Error {
	f.allocator       = allocator
	f.matched_indices = make([dynamic]i32, 0, capacity, allocator) or_return
	f.moment_slot     = -1
	f.total_db_rows   = 0
	f.query_len       = 0
	return nil
}

xitdb_filter_destroy :: proc(f: ^Xitdb_Filter) {
	delete(f.matched_indices)
	f^ = {}
}

// Reads the current search query from `input_id` in `inp`, recomputes `matched_indices` against
// `total_rows` when either the query or `moment_slot` changes, and resets `list_id` scroll/selection.
xitdb_filter_update :: proc(
	f: ^Xitdb_Filter,
	inp: ^Input_State,
	input_id: string,
	list_id: string,
	moment_slot: i64,
	total_rows: i32,
	row_text_fn: proc(db_row: i32, alloc := context.temp_allocator) -> string,
	temp_alloc := context.temp_allocator,
) -> i32 {
	query := get_text(inp, input_id) if inp != nil && len(input_id) > 0 else ""
	q_len := min(len(query), MAX_TEXT_BYTES)
	query_changed  := (q_len != f.query_len) || (string(f.active_query[:f.query_len]) != query[:q_len])
	moment_changed := (moment_slot != f.moment_slot) || (total_rows != f.total_db_rows)

	if !query_changed && !moment_changed {
		return total_rows if q_len == 0 else i32(len(f.matched_indices))
	}

	for i := 0; i < q_len; i += 1 {
		f.active_query[i] = query[i]
	}
	f.query_len     = q_len
	f.moment_slot   = moment_slot
	f.total_db_rows = max(0, total_rows)
	clear(&f.matched_indices)

	if q_len > 0 {
		q_str := query[:q_len]
		for row: i32 = 0; row < f.total_db_rows; row += 1 {
			line := row_text_fn(row, temp_alloc)
			if contains_case_insensitive(line, q_str) {
				append(&f.matched_indices, row)
			}
		}
	}

	if query_changed && inp != nil && len(list_id) > 0 {
		slot := get_scroll_slot(inp, hash_id(list_id))
		slot.offset       = 0
		slot.selected_row = 0
	}

	return f.total_db_rows if q_len == 0 else i32(len(f.matched_indices))
}

// Maps a visible row index `[0, visible_count)` from `Virtual_Slice` back to its underlying `xitdb` index.
xitdb_filter_map_row :: proc "contextless" (f: ^Xitdb_Filter, visible_row_idx: i32) -> i32 {
	if f.query_len == 0 {
		return visible_row_idx
	}
	if visible_row_idx >= 0 && int(visible_row_idx) < len(f.matched_indices) {
		return f.matched_indices[visible_row_idx]
	}
	return -1
}

contains_case_insensitive :: proc "contextless" (haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	limit := len(haystack) - len(needle)
	for i := 0; i <= limit; i += 1 {
		match := true
		for j := 0; j < len(needle); j += 1 {
			hc := haystack[i + j]
			nc := needle[j]
			if hc >= 'A' && hc <= 'Z' {
				hc += 32
			}
			if nc >= 'A' && nc <= 'Z' {
				nc += 32
			}
			if hc != nc {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
