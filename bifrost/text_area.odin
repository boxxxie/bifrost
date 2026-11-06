package bifrost

import "core:mem"
import "core:unicode/utf8"

// =============================================================================
// Track 11: Multi-Line Text Editor (`ui_text_area`)
// =============================================================================

MAX_TEXT_AREA_SLOTS :: 8
MAX_TEXT_AREA_BYTES :: 4096
MAX_TEXT_AREA_LINES :: 256

Text_Area_State :: struct {
	id_hash:           u64,
	buf:               [MAX_TEXT_AREA_BYTES]u8,
	dyn_buf:           [dynamic]u8,
	use_dyn:           bool,
	len:               int,
	line_starts:       [MAX_TEXT_AREA_LINES]int,
	line_count:        int,
	cursor_byte:       int,
	cursor_row:        i32,
	cursor_col:        i32, // Display column of cursor on `cursor_row`
	preferred_col:     i32, // Sticky horizontal display column preserved across vertical motion
	sel_anchor_byte:   int,
	has_selection:     bool,
	scroll_row:        i32,
	scroll_col:        i32,
	viewport_w:        i32,
	viewport_h:        i32,
	gutter_w:          i32,
	show_line_numbers: bool,
	tab_width:         i32,
	placeholder:       string,
	placeholder_fg:    Color,
	gutter_fg:         Color,
	state_ptr:         ^Text_Area_State,
	last_layout_gen:   u64,
	exited_edit:       bool,
	initialized:       bool,
}

Text_Area_Slot :: Text_Area_State

Text_Area_Config :: struct {
	placeholder:       string,
	initial_text:      string,
	width:             Axis_Size,
	height:            Axis_Size,
	border:            Border_Kind,
	fg:                Color,
	bg:                Color,
	placeholder_fg:    Color,
	border_fg:         Color,
	gutter_fg:         Color,
	title:             string,
	focus_flags:       Focus_Flags,
	two_stage:         bool,
	show_line_numbers: bool,
	tab_width:         i32,
	state:             ^Text_Area_State,
}

// =============================================================================
// Lifecycle & State Accessors
// =============================================================================

// Initializes an optional dynamic UTF-8 buffer for a standalone `Text_Area_State`.
// Note: Immediate-mode `ui_text_area` slots stored in `Input_State` use the zero-allocation
// fixed `[MAX_TEXT_AREA_BYTES]u8` buffer automatically without requiring `text_area_init`.
text_area_init :: proc(
	state: ^Text_Area_State,
	allocator := context.allocator,
	initial_text: string = "",
) -> mem.Allocator_Error {
	if state == nil {
		return nil
	}
	state^ = {}
	init_cap := max(MAX_TEXT_AREA_BYTES, len(initial_text) + 256)
	state.dyn_buf     = make([dynamic]u8, init_cap, allocator) or_return
	state.use_dyn     = true
	state.tab_width   = 4
	state.initialized = true
	text_area_set_string(state, initial_text)
	return nil
}

// Frees any dynamic buffer owned by `state`. Safe to call on zero-allocation static slots.
text_area_destroy :: proc(state: ^Text_Area_State) {
	if state == nil {
		return
	}
	if state.use_dyn {
		delete(state.dyn_buf)
	}
	state^ = {}
}

get_text_area_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Text_Area_State {
	empty_idx := -1
	lru_idx   := 0
	lru_gen   := max(u64)
	for i := 0; i < MAX_TEXT_AREA_SLOTS; i += 1 {
		if inp.text_area_slots[i].id_hash == id_hash {
			return &inp.text_area_slots[i]
		}
		if empty_idx == -1 && inp.text_area_slots[i].id_hash == 0 {
			empty_idx = i
		}
		if inp.text_area_slots[i].last_layout_gen < lru_gen {
			lru_gen = inp.text_area_slots[i].last_layout_gen
			lru_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else lru_idx
	inp.text_area_slots[idx] = Text_Area_State{
		id_hash    = id_hash,
		tab_width  = 4,
		line_count = 1,
		viewport_w = 32,
		viewport_h = 6,
	}
	return &inp.text_area_slots[idx]
}

get_text_area_state :: proc(inp: ^Input_State, id: string) -> ^Text_Area_State {
	return get_text_area_slot(inp, hash_id(id))
}

set_text_area :: proc(inp: ^Input_State, id: string, value: string) {
	slot := get_text_area_slot(inp, hash_id(id))
	slot.initialized = true
	text_area_set_string(slot, value)
}

get_text_area :: proc(inp: ^Input_State, id: string) -> string {
	slot := get_text_area_slot(inp, hash_id(id))
	return text_area_string(slot)
}

get_text_area_cursor :: proc(inp: ^Input_State, id: string) -> (row, col: i32, byte_offset: int) {
	slot := get_text_area_slot(inp, hash_id(id))
	return slot.cursor_row, slot.cursor_col, slot.cursor_byte
}

get_text_area_scroll :: proc(inp: ^Input_State, id: string) -> (scroll_row, scroll_col: i32) {
	slot := get_text_area_slot(inp, hash_id(id))
	return slot.scroll_row, slot.scroll_col
}

get_text_area_selected_text :: proc(inp: ^Input_State, id: string) -> string {
	slot := get_text_area_slot(inp, hash_id(id))
	lo, hi, ok := text_area_selection_range(slot)
	if !ok {
		return ""
	}
	raw := text_area_bytes(slot)
	return string(raw[lo:hi])
}

get_text_area_line_count :: proc(inp: ^Input_State, id: string) -> int {
	slot := get_text_area_slot(inp, hash_id(id))
	return max(1, slot.line_count)
}

// =============================================================================
// Buffer Helpers & Line-Start Offset Index (`\n` Boundaries)
// =============================================================================

@(private)
text_area_bytes :: #force_inline proc "contextless" (slot: ^Text_Area_State) -> []u8 {
	if slot.use_dyn {
		return slot.dyn_buf[:slot.len]
	}
	return slot.buf[:slot.len]
}

@(private)
text_area_string :: #force_inline proc "contextless" (slot: ^Text_Area_State) -> string {
	return string(text_area_bytes(slot))
}

@(private)
text_area_capacity :: #force_inline proc "contextless" (slot: ^Text_Area_State) -> int {
	if slot.use_dyn {
		return len(slot.dyn_buf)
	}
	return MAX_TEXT_AREA_BYTES
}

text_area_set_string :: proc "contextless" (slot: ^Text_Area_State, value: string) {
	if slot == nil {
		return
	}
	cap_bytes := text_area_capacity(slot)
	raw_dst := slot.dyn_buf[:] if slot.use_dyn else slot.buf[:]
	n, _ := copy_string_to_buf(raw_dst[:cap_bytes], value)
	// Cap at the 256th newline (MAX_TEXT_AREA_LINES lines) so line 255 never spans raw '\n' bytes
	nl_count := 0
	for i := 0; i < n; i += 1 {
		if raw_dst[i] == '\n' {
			nl_count += 1
			if nl_count >= MAX_TEXT_AREA_LINES {
				n = i
				break
			}
		}
	}
	slot.len             = n
	slot.cursor_byte     = n
	slot.sel_anchor_byte = 0
	slot.has_selection   = false
	slot.scroll_row      = 0
	slot.scroll_col      = 0
	text_area_rebuild_lines(slot)
	slot.preferred_col   = slot.cursor_col
}

// Recomputes `line_starts` from `\n` byte offsets and derives `(cursor_row, cursor_col)` from `cursor_byte`.
text_area_rebuild_lines :: proc "contextless" (slot: ^Text_Area_State) {
	if slot == nil {
		return
	}
	raw := text_area_bytes(slot)
	slot.cursor_byte = clamp(slot.cursor_byte, 0, len(raw))

	slot.line_starts[0] = 0
	count := 1
	for i := 0; i < len(raw); i += 1 {
		if raw[i] == '\n' && count < MAX_TEXT_AREA_LINES {
			slot.line_starts[count] = i + 1
			count += 1
		}
	}
	slot.line_count = count

	// Binary or linear search for the line containing `cursor_byte`
	c_row := 0
	for r := count - 1; r >= 0; r -= 1 {
		if slot.cursor_byte >= slot.line_starts[r] {
			c_row = r
			break
		}
	}
	slot.cursor_row = i32(c_row)
	line_start := slot.line_starts[c_row]
	prefix := string(raw[line_start:slot.cursor_byte])
	slot.cursor_col = string_display_width(prefix)
}

// Returns `[start_byte, end_byte)` for logical line `row`, excluding any trailing `\n`.
text_area_line_range :: proc "contextless" (slot: ^Text_Area_State, row: i32) -> (start_byte, end_byte: int) {
	if slot == nil || slot.line_count <= 0 {
		return 0, 0
	}
	r := clamp(int(row), 0, slot.line_count - 1)
	start_byte = slot.line_starts[r]
	if r + 1 < slot.line_count {
		end_byte = max(start_byte, slot.line_starts[r + 1] - 1)
	} else {
		end_byte = slot.len
		raw := text_area_bytes(slot)
		for i := start_byte; i < len(raw); i += 1 {
			if raw[i] == '\n' {
				end_byte = i
				break
			}
		}
	}
	return start_byte, end_byte
}

// Resolves a target display column `target_col` on `row` to the nearest grapheme-cluster
// byte offset `<= target_col` without splitting multi-byte UTF-8 or 2-column CJK/Emoji clusters.
text_area_byte_for_row_col :: proc "contextless" (
	slot: ^Text_Area_State,
	row: i32,
	target_col: i32,
) -> (byte_idx: int, actual_col: i32) {
	start_b, end_b := text_area_line_range(slot, row)
	if target_col <= 0 || end_b <= start_b {
		return start_b, 0
	}
	raw := text_area_bytes(slot)
	line_str := string(raw[start_b:end_b])
	rel_idx := 0
	col: i32 = 0
	for rel_idx < len(line_str) {
		next_idx, cw, _ := next_grapheme_cluster(line_str, rel_idx)
		if col + cw > target_col {
			break
		}
		col += cw
		rel_idx = next_idx
		if col == target_col {
			break
		}
	}
	return start_b + rel_idx, col
}

@(private)
text_area_count_digits :: proc "contextless" (n: int) -> i32 {
	v := max(1, n)
	digits: i32 = 0
	for v > 0 {
		digits += 1
		v /= 10
	}
	return digits
}

@(private)
text_area_gutter_width :: proc "contextless" (slot: ^Text_Area_State) -> i32 {
	if slot == nil || !slot.show_line_numbers {
		return 0
	}
	digits := max(2, text_area_count_digits(slot.line_count))
	return digits + 2 // e.g. " 1 │" -> 4 cols for 1..99 lines
}

// =============================================================================
// Immediate-Mode Widget Constructor & Paint/Viewport Synchronization
// =============================================================================

@(private)
sync_external_text_area_state :: proc "contextless" (dst: ^Text_Area_State, src: ^Text_Area_State) {
	if dst == nil || src == nil || dst == src {
		return
	}
	raw_src := text_area_bytes(src)
	if dst.use_dyn && len(dst.dyn_buf) > 0 {
		n := min(len(raw_src), len(dst.dyn_buf))
		if src.use_dyn && len(src.dyn_buf) > 0 && &dst.dyn_buf[0] == &src.dyn_buf[0] {
			dst.len = n
		} else {
			for i := 0; i < n; i += 1 {
				dst.dyn_buf[i] = raw_src[i]
			}
			dst.len = n
		}
	} else {
		n := min(len(raw_src), MAX_TEXT_AREA_BYTES)
		for i := 0; i < n; i += 1 {
			dst.buf[i] = raw_src[i]
		}
		dst.len = n
	}
	dst.id_hash           = src.id_hash
	dst.line_starts       = src.line_starts
	dst.line_count        = src.line_count
	dst.cursor_byte       = clamp(src.cursor_byte, 0, dst.len)
	dst.cursor_row        = src.cursor_row
	dst.cursor_col        = src.cursor_col
	dst.preferred_col     = src.preferred_col
	dst.sel_anchor_byte   = clamp(src.sel_anchor_byte, 0, dst.len)
	dst.has_selection     = src.has_selection
	dst.scroll_row        = src.scroll_row
	dst.scroll_col        = src.scroll_col
	dst.viewport_w        = src.viewport_w
	dst.viewport_h        = src.viewport_h
	dst.gutter_w          = src.gutter_w
	dst.show_line_numbers = src.show_line_numbers
	dst.tab_width         = src.tab_width
	dst.placeholder       = src.placeholder
	dst.placeholder_fg    = src.placeholder_fg
	dst.gutter_fg         = src.gutter_fg
	dst.last_layout_gen   = src.last_layout_gen
	dst.exited_edit       = src.exited_edit
	dst.initialized       = true
}

ui_text_area :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Text_Area_Config = {},
) -> i32 {
	id_h := hash_id(id)
	slot := get_text_area_slot(inp, id_h)
	slot.last_layout_gen = ctx.layout_gen
	slot.state_ptr       = cfg.state

	if cfg.state != nil {
		if cfg.state.use_dyn && len(cfg.state.dyn_buf) > 0 {
			slot.dyn_buf = cfg.state.dyn_buf
			slot.use_dyn = true
		}
		if !slot.initialized && cfg.state.len > 0 {
			text_area_set_string(slot, text_area_string(cfg.state))
		}
	}
	if !slot.initialized {
		slot.initialized = true
		if len(cfg.initial_text) > 0 {
			text_area_set_string(slot, cfg.initial_text)
		} else {
			text_area_rebuild_lines(slot)
		}
	}

	slot.placeholder       = cfg.placeholder
	slot.placeholder_fg    = cfg.placeholder_fg
	slot.gutter_fg         = cfg.gutter_fg
	slot.show_line_numbers = cfg.show_line_numbers
	slot.tab_width         = cfg.tab_width if cfg.tab_width > 0 else 4
	slot.gutter_w          = text_area_gutter_width(slot)

	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(6)

	s.paints[id_h] = Paint_Spec{
		title       = cfg.title,
		fg          = cfg.fg,
		bg          = cfg.bg,
		border_fg   = cfg.border_fg,
		title_style = {.Bold},
		fill_bg     = cfg.bg.kind != .Default,
	}

	flags := cfg.focus_flags + {.Focusable, .Captures_Text}
	if cfg.two_stage || slot.exited_edit {
		flags -= {.Auto_Edit}
	} else if (.Captures_Text not_in cfg.focus_flags) && (.Scope_Text_Sink not_in cfg.focus_flags) {
		flags += {.Auto_Edit}
	}

	idx := leaf(ctx, id, 24, 4, Box_Config{
		width       = w,
		height      = h,
		border      = cfg.border,
		padding     = {left = 0, right = 0, top = 0, bottom = 0},
		focus_flags = flags,
		focusable   = .Disabled not_in flags,
		clickable   = .Disabled not_in flags,
		hoverable   = .Disabled not_in flags,
		text_area   = true,
	})

	if cfg.state != nil {
		sync_external_text_area_state(cfg.state, slot)
	}
	return idx
}

sync_text_area_paint :: proc(s: ^Screen, inp: ^Input_State, node: Layout_Node) {
	slot := get_text_area_slot(inp, node.id_hash)
	text_area_rebuild_lines(slot)
	slot.gutter_w = text_area_gutter_width(slot)

	// Reset exited_edit flag when focus moves away from this text area
	if inp.focused_id != node.id_hash {
		slot.exited_edit = false
	}

	viewport_h := max(1, node.inner_rect.h)
	viewport_w := max(1, node.inner_rect.w)
	text_w     := max(1, viewport_w - slot.gutter_w)

	slot.viewport_h = viewport_h
	slot.viewport_w = text_w

	// Keep cursor_row visible inside [scroll_row, scroll_row + viewport_h)
	if slot.cursor_row < slot.scroll_row {
		slot.scroll_row = slot.cursor_row
	} else if slot.cursor_row >= slot.scroll_row + viewport_h {
		slot.scroll_row = slot.cursor_row - viewport_h + 1
	}
	max_scroll_row := max(0, i32(slot.line_count) - viewport_h)
	slot.scroll_row = clamp(slot.scroll_row, 0, max_scroll_row)

	// Keep cursor_col visible inside [scroll_col, scroll_col + max(1, text_w - 1))
	usable_cols := max(1, text_w - 1)
	if slot.cursor_col < slot.scroll_col {
		slot.scroll_col = slot.cursor_col
	} else if slot.cursor_col >= slot.scroll_col + usable_cols {
		slot.scroll_col = slot.cursor_col - usable_cols + 1
	}
	slot.scroll_col = max(0, slot.scroll_col)

	paint := s.paints[node.id_hash]
	focused := (node.id_hash == inp.focused_id)
	editing := (node.id_hash == inp.editing_id) && (.Disabled not_in node.focus_flags)

	if .Disabled in node.focus_flags {
		paint.style += {.Dim}
		paint.has_cursor = false
		s.paints[node.id_hash] = paint
		return
	}

	if editing {
		if paint.border_fg.kind == .Default {
			paint.border_fg = rgb(255, 215, 0)
		}
		paint.title_style += {.Bold, .Reverse}
		paint.has_cursor   = true
	} else if focused {
		if paint.border_fg.kind == .Default {
			paint.border_fg = rgb(100, 180, 255)
		}
		paint.title_style += {.Bold, .Underline}
		paint.has_cursor   = false
	} else {
		if node.id_hash == inp.hovered_id {
			paint.style += {.Underline}
		}
		paint.has_cursor = false
	}

	if slot.state_ptr != nil {
		sync_external_text_area_state(slot.state_ptr, slot)
	}
	s.paints[node.id_hash]     = paint
	s.text_areas[node.id_hash] = slot
}

// Renders a multi-line `text_area` node inside `render_layout`:
// 1. Optional 1-based line-number gutter (`show_line_numbers`)
// 2. Horizontally & vertically scrolled UTF-8 lines with multi-line selection (`{.Reverse}`)
// 3. Block cursor (`{.Reverse, .Bold}`) at `(cursor_row - scroll_row, gutter_w + cursor_col - scroll_col)`
// 4. Proportional vertical scrollbar on right border when `line_count > inner_rect.h`
render_text_area_node :: proc(s: ^Screen, node: Layout_Node, paint: Paint_Spec, inner_clip: Rect, node_clip: Rect) {
	slot, ok := s.text_areas[node.id_hash]
	if !ok || slot == nil {
		return
	}
	if inner_clip.w <= 0 || inner_clip.h <= 0 {
		return
	}

	raw := slot.dyn_buf[:slot.len] if slot.use_dyn else slot.buf[:slot.len]
	gutter_w := slot.gutter_w
	text_x   := node.inner_rect.x + gutter_w
	text_w   := max(0, node.inner_rect.w - gutter_w)

	gutter_fg := slot.gutter_fg if slot.gutter_fg.kind != .Default else (paint.border_fg if paint.border_fg.kind != .Default else paint.fg)
	gutter_style := paint.style + {.Dim}

	sel_lo, sel_hi, has_sel := text_area_selection_range(slot)
	digits := max(2, text_area_count_digits(slot.line_count))

	// Render each visible row in viewport
	for vis_r: i32 = 0; vis_r < node.inner_rect.h; vis_r += 1 {
		ty := node.inner_rect.y + vis_r
		if ty < inner_clip.y || ty >= inner_clip.y + inner_clip.h {
			continue
		}
		doc_row := slot.scroll_row + vis_r

		// 1. Render optional left line-number gutter
		if slot.show_line_numbers && gutter_w > 0 {
			var_gbuf: [16]u8
			g_pos := 0
			if int(doc_row) < slot.line_count {
				num := int(doc_row + 1)
				num_digits := int(text_area_count_digits(num))
				pad_spaces := max(0, int(digits) - num_digits)
				for p := 0; p < pad_spaces && g_pos < len(var_gbuf); p += 1 {
					var_gbuf[g_pos] = ' '
					g_pos += 1
				}
				var_dbuf: [12]u8
				d_len := 0
				tmp := num
				for tmp > 0 && d_len < len(var_dbuf) {
					var_dbuf[d_len] = u8('0' + (tmp % 10))
					d_len += 1
					tmp /= 10
				}
				for d := d_len - 1; d >= 0 && g_pos < len(var_gbuf); d -= 1 {
					var_gbuf[g_pos] = var_dbuf[d]
					g_pos += 1
				}
			} else {
				pad_spaces := max(0, int(digits) - 1)
				for p := 0; p < pad_spaces && g_pos < len(var_gbuf); p += 1 {
					var_gbuf[g_pos] = ' '
					g_pos += 1
				}
				if g_pos < len(var_gbuf) {
					var_gbuf[g_pos] = '~'
					g_pos += 1
				}
			}
			sep := " │"
			for b_idx := 0; b_idx < len(sep) && g_pos < len(var_gbuf); b_idx += 1 {
				var_gbuf[g_pos] = sep[b_idx]
				g_pos += 1
			}
			g_str := string(var_gbuf[:g_pos])
			gutter_clip := rect_intersect(inner_clip, Rect{
				x = node.inner_rect.x,
				y = ty,
				w = gutter_w,
				h = 1,
			})
			put_text_clipped(s, node.inner_rect.x, ty, g_str, gutter_fg, paint.bg, gutter_style, gutter_clip)
		}

		if text_w <= 0 {
			continue
		}
		line_clip := rect_intersect(inner_clip, Rect{
			x = text_x,
			y = ty,
			w = text_w,
			h = 1,
		})
		if line_clip.w <= 0 {
			continue
		}

		// Empty buffer placeholder on row 0 when not actively editing
		if slot.len == 0 && !paint.has_cursor && vis_r == 0 && len(slot.placeholder) > 0 {
			p_fg := slot.placeholder_fg if slot.placeholder_fg.kind != .Default else paint.fg
			vis_ph := slice_utf8_by_display_width(slot.placeholder, 0, text_w)
			put_text_clipped(s, text_x, ty, vis_ph.text, p_fg, paint.bg, paint.style + {.Dim}, line_clip)
			continue
		}

		if int(doc_row) >= slot.line_count {
			continue
		}

		line_start, line_end := text_area_line_range(slot, doc_row)
		line_str := string(raw[line_start:line_end])
		vis := slice_utf8_by_display_width(line_str, slot.scroll_col, text_w)
		vis_str := vis.text
		abs_vis_start := line_start + vis.start_byte
		abs_vis_end   := line_start + vis.end_byte

		cur_x := text_x
		for p: i32 = 0; p < vis.lead_pad; p += 1 {
			put_cell_clipped(s, cur_x, ty, Cell{ch = ' ', fg = paint.fg, bg = paint.bg, style = paint.style, width = 1}, line_clip)
			cur_x += 1
		}

		if has_sel && sel_lo < line_end + 1 && sel_hi > line_start {
			// Line has active selection overlap
			ov_lo := clamp(sel_lo, abs_vis_start, abs_vis_end) - abs_vis_start
			ov_hi := clamp(sel_hi, abs_vis_start, abs_vis_end) - abs_vis_start
			if ov_lo > 0 {
				cur_x += put_text_clipped(s, cur_x, ty, vis_str[:ov_lo], paint.fg, paint.bg, paint.style, line_clip)
			}
			if ov_hi > ov_lo {
				cur_x += put_text_clipped(s, cur_x, ty, vis_str[ov_lo:ov_hi], paint.fg, paint.bg, paint.style + {.Reverse}, line_clip)
			}
			if ov_hi < len(vis_str) {
				cur_x += put_text_clipped(s, cur_x, ty, vis_str[ov_hi:], paint.fg, paint.bg, paint.style, line_clip)
			}
			// Highlight trailing newline marker when selection spans past this line's `\n`
			if int(doc_row) + 1 < slot.line_count && abs_vis_end == line_end && sel_lo <= line_end && sel_hi > line_end && cur_x < text_x + text_w {
				put_cell_clipped(s, cur_x, ty, Cell{
					ch    = ' ',
					fg    = paint.fg,
					bg    = paint.bg,
					style = paint.style + {.Reverse},
					width = 1,
				}, line_clip)
			}
		} else if len(vis_str) > 0 {
			put_text_clipped(s, cur_x, ty, vis_str, paint.fg, paint.bg, paint.style, line_clip)
		}
	}

	// 2. Invert block cursor cell when active in `.Editing` mode
	if paint.has_cursor {
		vis_row := slot.cursor_row - slot.scroll_row
		vis_col := clamp(slot.cursor_col - slot.scroll_col, 0, max(0, text_w - 1))
		cx := text_x + vis_col
		cy := node.inner_rect.y + vis_row
		if vis_row >= 0 && vis_row < node.inner_rect.h &&
		   point_in_rect(cx, cy, inner_clip) &&
		   cx >= 0 && cx < s.width && cy >= 0 && cy < s.height {
			c_idx := int(cy * s.width + cx)
			cur_cell := s.back[c_idx]
			if cur_cell.width == 0 {
				heal_overwrite_at(s, cx, cy)
				cur_cell = s.back[c_idx]
				cur_cell.ch    = ' '
				cur_cell.width = 1
			}
			cur_cell.fg = paint.fg if paint.fg.kind != .Default else cur_cell.fg
			cur_cell.style += {.Reverse, .Bold}
			s.back[c_idx] = cur_cell
			if cur_cell.width == 2 && cx + 1 < s.width {
				s.back[c_idx + 1].fg    = cur_cell.fg
				s.back[c_idx + 1].style = cur_cell.style
			}
		}
	}

	// 3. Draw proportional vertical scrollbar when line_count exceeds viewport height
	if i32(slot.line_count) > node.inner_rect.h {
		sb_fg := paint.border_fg if paint.border_fg.kind != .Default else paint.fg
		draw_vertical_scrollbar(
			s,
			node.rect,
			node.inner_rect,
			node_clip,
			slot.scroll_row,
			i32(slot.line_count),
			sb_fg,
			paint.bg,
		)
	}
}

// =============================================================================
// Selection, Editing, Clipboard & 2D Caret Navigation
// =============================================================================

text_area_selection_range :: proc "contextless" (slot: ^Text_Area_State) -> (lo, hi: int, active: bool) {
	if slot == nil || !slot.has_selection || slot.sel_anchor_byte == slot.cursor_byte {
		return 0, 0, false
	}
	lo = clamp(min(slot.sel_anchor_byte, slot.cursor_byte), 0, slot.len)
	hi = clamp(max(slot.sel_anchor_byte, slot.cursor_byte), 0, slot.len)
	return lo, hi, hi > lo
}

text_area_delete_range :: proc "contextless" (inp: ^Input_State, slot: ^Text_Area_State, start_b, end_b: int) -> bool {
	lo := clamp(min(start_b, end_b), 0, slot.len)
	hi := clamp(max(start_b, end_b), 0, slot.len)
	if hi <= lo {
		slot.has_selection = false
		return false
	}
	raw := slot.dyn_buf[:] if slot.use_dyn else slot.buf[:]
	rem := slot.len - hi
	for i := 0; i < rem; i += 1 {
		raw[lo + i] = raw[hi + i]
	}
	slot.len             = lo + rem
	slot.cursor_byte     = lo
	slot.sel_anchor_byte = lo
	slot.has_selection   = false
	text_area_rebuild_lines(slot)
	slot.preferred_col   = slot.cursor_col
	if inp != nil {
		inp.text_changed_id = slot.id_hash
	}
	return true
}

text_area_delete_selection :: proc "contextless" (inp: ^Input_State, slot: ^Text_Area_State) -> bool {
	lo, hi, active := text_area_selection_range(slot)
	if !active {
		slot.has_selection = false
		return false
	}
	return text_area_delete_range(inp, slot, lo, hi)
}

text_area_copy_to_clipboard :: proc "contextless" (inp: ^Input_State, text: string) {
	if inp == nil || len(text) == 0 {
		return
	}
	n, _ := copy_string_to_buf(inp.clipboard_buf[:], text)
	inp.clipboard_len = n
	inp.osc52_pending = n > 0
}

text_area_insert_raw_bytes :: proc "contextless" (inp: ^Input_State, slot: ^Text_Area_State, data: []u8) -> bool {
	if len(data) == 0 {
		return false
	}
	cap_bytes := text_area_capacity(slot)
	avail := cap_bytes - slot.len
	if avail <= 0 {
		return false
	}
	ins_len := min(len(data), avail)
	// Avoid splitting a multi-byte UTF-8 codepoint at capacity boundary
	for ins_len > 0 && ins_len < len(data) && (data[ins_len] & 0xC0) == 0x80 {
		ins_len -= 1
	}
	if ins_len <= 0 {
		return false
	}

	raw := slot.dyn_buf[:] if slot.use_dyn else slot.buf[:]
	for i := slot.len - 1; i >= slot.cursor_byte; i -= 1 {
		raw[i + ins_len] = raw[i]
	}
	for i := 0; i < ins_len; i += 1 {
		raw[slot.cursor_byte + i] = data[i]
	}
	slot.len         += ins_len
	slot.cursor_byte += ins_len
	text_area_rebuild_lines(slot)
	slot.preferred_col = slot.cursor_col
	if inp != nil {
		inp.text_changed_id = slot.id_hash
	}
	return true
}

text_area_insert_rune :: proc "contextless" (inp: ^Input_State, slot: ^Text_Area_State, r: rune) -> bool {
	if r == '\n' {
		_ = text_area_delete_selection(inp, slot)
		if slot.line_count >= MAX_TEXT_AREA_LINES {
			return false
		}
		nl := [1]u8{'\n'}
		return text_area_insert_raw_bytes(inp, slot, nl[:])
	}
	if r == '\t' {
		_ = text_area_delete_selection(inp, slot)
		tw := clamp(int(slot.tab_width if slot.tab_width > 0 else 4), 1, 8)
		spaces := [8]u8{' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
		return text_area_insert_raw_bytes(inp, slot, spaces[:tw])
	}
	if r < 32 || r == 127 {
		return false
	}
	_ = text_area_delete_selection(inp, slot)
	encoded, rune_len := utf8.encode_rune(r)
	return text_area_insert_raw_bytes(inp, slot, encoded[:rune_len])
}

// Inserts a single-line or multi-line string (preserving `\n`, normalizing `\r\n` -> `\n`,
// and expanding `\t` into `tab_width` spaces) at the current cursor position in O(N + M) time.
text_area_insert_string :: proc "contextless" (inp: ^Input_State, slot: ^Text_Area_State, text: string) -> bool {
	if slot == nil {
		return false
	}
	changed := text_area_delete_selection(inp, slot)
	if len(text) == 0 {
		return changed
	}

	cap_bytes := text_area_capacity(slot)
	avail := cap_bytes - slot.len
	if avail <= 0 {
		return changed
	}

	tw := clamp(int(slot.tab_width if slot.tab_width > 0 else 4), 1, 8)
	cur_lines := max(1, slot.line_count)

	// Pass 1: compute the exact normalized byte count (`ins_len`) and stopping index (`stop_idx`),
	// halting immediately if a newline would exceed `MAX_TEXT_AREA_LINES` or if `avail` is reached.
	ins_len  := 0
	stop_idx := len(text)
	idx      := 0
	for idx < len(text) {
		if text[idx] == '\r' {
			step := 2 if (idx + 1 < len(text) && text[idx + 1] == '\n') else 1
			if cur_lines >= MAX_TEXT_AREA_LINES || ins_len + 1 > avail {
				stop_idx = idx
				break
			}
			ins_len   += 1
			cur_lines += 1
			idx       += step
			continue
		}
		if text[idx] == '\n' {
			if cur_lines >= MAX_TEXT_AREA_LINES || ins_len + 1 > avail {
				stop_idx = idx
				break
			}
			ins_len   += 1
			cur_lines += 1
			idx       += 1
			continue
		}
		if text[idx] == '\t' {
			n_sp := min(tw, avail - ins_len)
			if n_sp <= 0 {
				stop_idx = idx
				break
			}
			ins_len += n_sp
			idx     += 1
			if ins_len >= avail {
				stop_idx = idx
				break
			}
			continue
		}
		r, rw := utf8.decode_rune_in_string(text[idx:])
		step := max(1, rw)
		if r >= 32 && r != 127 {
			_, rune_len := utf8.encode_rune(r)
			if ins_len + rune_len > avail {
				stop_idx = idx
				break
			}
			ins_len += rune_len
		}
		idx += step
	}

	if ins_len <= 0 {
		return changed
	}

	// Pass 2: shift tail `raw[cursor_byte : len]` once by `ins_len`, then write normalized bytes in a single pass.
	raw := slot.dyn_buf[:] if slot.use_dyn else slot.buf[:]
	for i := slot.len - 1; i >= slot.cursor_byte; i -= 1 {
		raw[i + ins_len] = raw[i]
	}

	write_pos := slot.cursor_byte
	idx = 0
	for idx < stop_idx && write_pos < slot.cursor_byte + ins_len {
		if text[idx] == '\r' {
			step := 2 if (idx + 1 < stop_idx && text[idx + 1] == '\n') else 1
			raw[write_pos] = '\n'
			write_pos += 1
			idx       += step
			continue
		}
		if text[idx] == '\n' {
			raw[write_pos] = '\n'
			write_pos += 1
			idx       += 1
			continue
		}
		if text[idx] == '\t' {
			n_sp := min(tw, (slot.cursor_byte + ins_len) - write_pos)
			for s_i := 0; s_i < n_sp; s_i += 1 {
				raw[write_pos] = ' '
				write_pos += 1
			}
			idx += 1
			continue
		}
		r, rw := utf8.decode_rune_in_string(text[idx:])
		step := max(1, rw)
		if r >= 32 && r != 127 {
			encoded, rune_len := utf8.encode_rune(r)
			for b_i := 0; b_i < rune_len; b_i += 1 {
				raw[write_pos] = encoded[b_i]
				write_pos += 1
			}
		}
		idx += step
	}

	slot.len         += ins_len
	slot.cursor_byte += ins_len
	text_area_rebuild_lines(slot)
	slot.preferred_col = slot.cursor_col
	if inp != nil {
		inp.text_changed_id = slot.id_hash
	}
	return true
}

@(private)
text_area_move_cursor_horizontal :: proc "contextless" (slot: ^Text_Area_State, new_byte: int, extend_selection: bool) {
	target := clamp(new_byte, 0, slot.len)
	if extend_selection {
		if !slot.has_selection {
			slot.sel_anchor_byte = slot.cursor_byte
			slot.has_selection   = true
		}
		slot.cursor_byte = target
		if slot.cursor_byte == slot.sel_anchor_byte {
			slot.has_selection = false
		}
	} else {
		slot.cursor_byte   = target
		slot.has_selection = false
	}
	text_area_rebuild_lines(slot)
	slot.preferred_col = slot.cursor_col
}

// Moves the caret vertically by `row_delta` lines while strictly preserving `slot.preferred_col`!
@(private)
text_area_move_cursor_vertical :: proc "contextless" (slot: ^Text_Area_State, row_delta: i32, extend_selection: bool) {
	if slot.line_count <= 0 {
		text_area_rebuild_lines(slot)
	}
	saved_preferred := slot.preferred_col
	target_row := clamp(slot.cursor_row + row_delta, 0, i32(max(0, slot.line_count - 1)))
	new_byte, _ := text_area_byte_for_row_col(slot, target_row, saved_preferred)

	if extend_selection {
		if !slot.has_selection {
			slot.sel_anchor_byte = slot.cursor_byte
			slot.has_selection   = true
		}
		slot.cursor_byte = new_byte
		if slot.cursor_byte == slot.sel_anchor_byte {
			slot.has_selection = false
		}
	} else {
		slot.cursor_byte   = new_byte
		slot.has_selection = false
	}
	text_area_rebuild_lines(slot)
	slot.preferred_col = saved_preferred
}

@(private)
text_area_prev_word_boundary :: proc "contextless" (slot: ^Text_Area_State) -> int {
	cur := clamp(slot.cursor_byte, 0, slot.len)
	if cur <= 0 {
		return 0
	}
	str := text_area_string(slot)
	if str[cur - 1] == '\n' {
		return cur - 1
	}
	line_start, _ := text_area_line_range(slot, slot.cursor_row)
	rel := text_input_move_word_left(str[line_start:cur], cur - line_start)
	return line_start + rel
}

@(private)
text_area_next_word_boundary :: proc "contextless" (slot: ^Text_Area_State) -> int {
	cur := clamp(slot.cursor_byte, 0, slot.len)
	if cur >= slot.len {
		return slot.len
	}
	str := text_area_string(slot)
	if str[cur] == '\n' {
		return cur + 1
	}
	_, line_end := text_area_line_range(slot, slot.cursor_row)
	rel := text_input_move_word_right(str[cur:line_end], 0)
	return cur + rel
}

handle_text_area_key :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	_ = capture_idx
	node := ctx.nodes[node_idx]
	slot := get_text_area_slot(inp, node.id_hash)
	text_area_rebuild_lines(slot)

	shift := .Shift in ev.mods
	ctrl  := .Ctrl  in ev.mods
	alt   := .Alt   in ev.mods
	super := .Super in ev.mods

	// 1. Ctrl / Alt / Super editing & navigation shortcuts
	if ctrl && !alt && !super && ev.code == .Rune {
		switch ev.ch {
		case 'a', 'A':
			if inp.keymap_style == .Emacs && !shift {
				line_start, _ := text_area_line_range(slot, slot.cursor_row)
				text_area_move_cursor_horizontal(slot, line_start, false)
				return true
			}
			if slot.len > 0 {
				slot.sel_anchor_byte = 0
				slot.cursor_byte     = slot.len
				slot.has_selection   = true
				text_area_rebuild_lines(slot)
				slot.preferred_col   = slot.cursor_col
			}
			return true
		case 'e', 'E':
			_, line_end := text_area_line_range(slot, slot.cursor_row)
			text_area_move_cursor_horizontal(slot, line_end, shift)
			return true
		case 'b', 'B':
			str := text_area_string(slot)
			prev_b := prev_grapheme_cluster(str, slot.cursor_byte)
			text_area_move_cursor_horizontal(slot, prev_b, shift)
			return true
		case 'f', 'F':
			str := text_area_string(slot)
			next_b, _, _ := next_grapheme_cluster(str, slot.cursor_byte)
			text_area_move_cursor_horizontal(slot, next_b, shift)
			return true
		case 'p', 'P':
			if inp.keymap_style == .Emacs {
				text_area_move_cursor_vertical(slot, -1, shift)
				return true
			}
		case 'n', 'N':
			if inp.keymap_style == .Emacs {
				text_area_move_cursor_vertical(slot, +1, shift)
				return true
			}
		case 'd', 'D':
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte < slot.len {
				str := text_area_string(slot)
				next_b, _, _ := next_grapheme_cluster(str, slot.cursor_byte)
				_ = text_area_delete_range(inp, slot, slot.cursor_byte, next_b)
			}
			return true
		case 'h', 'H':
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte > 0 {
				str := text_area_string(slot)
				prev_b := prev_grapheme_cluster(str, slot.cursor_byte)
				_ = text_area_delete_range(inp, slot, prev_b, slot.cursor_byte)
			}
			return true
		case 'w', 'W':
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte > 0 {
				wb := text_area_prev_word_boundary(slot)
				raw := text_area_bytes(slot)
				text_area_copy_to_clipboard(inp, string(raw[wb:slot.cursor_byte]))
				_ = text_area_delete_range(inp, slot, wb, slot.cursor_byte)
			}
			return true
		case 'u', 'U':
			if !text_area_delete_selection(inp, slot) {
				line_start, _ := text_area_line_range(slot, slot.cursor_row)
				if slot.cursor_byte > line_start {
					raw := text_area_bytes(slot)
					text_area_copy_to_clipboard(inp, string(raw[line_start:slot.cursor_byte]))
					_ = text_area_delete_range(inp, slot, line_start, slot.cursor_byte)
				}
			}
			return true
		case 'k', 'K':
			if !text_area_delete_selection(inp, slot) {
				_, line_end := text_area_line_range(slot, slot.cursor_row)
				if slot.cursor_byte < line_end {
					raw := text_area_bytes(slot)
					text_area_copy_to_clipboard(inp, string(raw[slot.cursor_byte:line_end]))
					_ = text_area_delete_range(inp, slot, slot.cursor_byte, line_end)
				} else if slot.cursor_byte < slot.len {
					// At end of line: delete the newline to join next line
					_ = text_area_delete_range(inp, slot, slot.cursor_byte, slot.cursor_byte + 1)
				}
			}
			return true
		case 'c', 'C':
			if lo, hi, active := text_area_selection_range(slot); active {
				raw := text_area_bytes(slot)
				text_area_copy_to_clipboard(inp, string(raw[lo:hi]))
			}
			return true
		case 'x', 'X':
			if lo, hi, active := text_area_selection_range(slot); active {
				raw := text_area_bytes(slot)
				text_area_copy_to_clipboard(inp, string(raw[lo:hi]))
				_ = text_area_delete_range(inp, slot, lo, hi)
			}
			return true
		case 'v', 'V', 'y', 'Y':
			if inp.clipboard_len > 0 {
				clip_str := string(inp.clipboard_buf[:inp.clipboard_len])
				_ = text_area_insert_string(inp, slot, clip_str)
			}
			return true
		}
	}

	// Alt+B / Alt+F / Alt+D word navigation & deletion
	if alt && !ctrl && !super && ev.code == .Rune {
		switch ev.ch {
		case 'b', 'B':
			text_area_move_cursor_horizontal(slot, text_area_prev_word_boundary(slot), shift)
			return true
		case 'f', 'F':
			text_area_move_cursor_horizontal(slot, text_area_next_word_boundary(slot), shift)
			return true
		case 'd', 'D':
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte < slot.len {
				nb := text_area_next_word_boundary(slot)
				raw := text_area_bytes(slot)
				text_area_copy_to_clipboard(inp, string(raw[slot.cursor_byte:nb]))
				_ = text_area_delete_range(inp, slot, slot.cursor_byte, nb)
			}
			return true
		}
	}

	// 2. Functional keys (`Enter`, `Tab`, `Backspace`, `Delete`, 2D Arrows, `Home`/`End`, `Page_Up`/`Page_Down`)
	#partial switch ev.code {
	case .Enter, .KP_Enter:
		if !ctrl && !alt && !super {
			_ = text_area_insert_rune(inp, slot, '\n')
			return true
		}

	case .Tab:
		if !ctrl && !alt && !super && !shift {
			_ = text_area_insert_rune(inp, slot, '\t')
			return true
		}

	case .Backspace:
		if ctrl || alt {
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte > 0 {
				wb := text_area_prev_word_boundary(slot)
				_ = text_area_delete_range(inp, slot, wb, slot.cursor_byte)
			}
		} else {
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte > 0 {
				str := text_area_string(slot)
				prev_b := prev_grapheme_cluster(str, slot.cursor_byte)
				_ = text_area_delete_range(inp, slot, prev_b, slot.cursor_byte)
			}
		}
		return true

	case .Delete, .KP_Delete:
		if ctrl || alt {
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte < slot.len {
				nb := text_area_next_word_boundary(slot)
				_ = text_area_delete_range(inp, slot, slot.cursor_byte, nb)
			}
		} else {
			if !text_area_delete_selection(inp, slot) && slot.cursor_byte < slot.len {
				str := text_area_string(slot)
				next_b, _, _ := next_grapheme_cluster(str, slot.cursor_byte)
				_ = text_area_delete_range(inp, slot, slot.cursor_byte, next_b)
			}
		}
		return true

	case .Left, .KP_Left:
		if ctrl || alt {
			text_area_move_cursor_horizontal(slot, text_area_prev_word_boundary(slot), shift)
		} else if !shift && slot.has_selection {
			lo, _, _ := text_area_selection_range(slot)
			text_area_move_cursor_horizontal(slot, lo, false)
		} else if slot.cursor_byte > 0 {
			str := text_area_string(slot)
			prev_b := prev_grapheme_cluster(str, slot.cursor_byte)
			text_area_move_cursor_horizontal(slot, prev_b, shift)
		}
		return true

	case .Right, .KP_Right:
		if ctrl || alt {
			text_area_move_cursor_horizontal(slot, text_area_next_word_boundary(slot), shift)
		} else if !shift && slot.has_selection {
			_, hi, _ := text_area_selection_range(slot)
			text_area_move_cursor_horizontal(slot, hi, false)
		} else if slot.cursor_byte < slot.len {
			str := text_area_string(slot)
			next_b, _, _ := next_grapheme_cluster(str, slot.cursor_byte)
			text_area_move_cursor_horizontal(slot, next_b, shift)
		}
		return true

	case .Up, .KP_Up:
		text_area_move_cursor_vertical(slot, -1, shift)
		return true

	case .Down, .KP_Down:
		text_area_move_cursor_vertical(slot, +1, shift)
		return true

	case .Page_Up, .KP_Page_Up:
		page := max(1, slot.viewport_h - 1)
		text_area_move_cursor_vertical(slot, -page, shift)
		return true

	case .Page_Down, .KP_Page_Down:
		page := max(1, slot.viewport_h - 1)
		text_area_move_cursor_vertical(slot, +page, shift)
		return true

	case .Home, .KP_Home:
		if ctrl {
			text_area_move_cursor_horizontal(slot, 0, shift)
		} else {
			line_start, _ := text_area_line_range(slot, slot.cursor_row)
			text_area_move_cursor_horizontal(slot, line_start, shift)
		}
		return true

	case .End, .KP_End:
		if ctrl {
			text_area_move_cursor_horizontal(slot, slot.len, shift)
		} else {
			_, line_end := text_area_line_range(slot, slot.cursor_row)
			text_area_move_cursor_horizontal(slot, line_end, shift)
		}
		return true

	case .Space:
		if !ctrl && !alt && !super {
			_ = text_area_insert_rune(inp, slot, ' ')
			return true
		}

	case .Multicodepoint:
		if !ctrl && !alt && !super && ev.text_len > 0 {
			local_ev := ev
			_ = text_area_insert_string(inp, slot, string(local_ev.text_buf[:local_ev.text_len]))
			return true
		}

	case .Rune:
		if !ctrl && !alt && !super {
			if ev.text_len > 0 {
				local_ev := ev
				_ = text_area_insert_string(inp, slot, string(local_ev.text_buf[:local_ev.text_len]))
			} else {
				_ = text_area_insert_rune(inp, slot, ev.ch)
			}
			return true
		}
	}

	return false
}

handle_text_area_click :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	mx, my: i32,
) {
	node := ctx.nodes[node_idx]
	slot := get_text_area_slot(inp, node.id_hash)
	text_area_rebuild_lines(slot)
	slot.gutter_w = text_area_gutter_width(slot)

	rel_y := max(0, my - node.inner_rect.y)
	target_row := clamp(slot.scroll_row + rel_y, 0, i32(max(0, slot.line_count - 1)))

	rel_x := max(0, mx - (node.inner_rect.x + slot.gutter_w))
	target_col := slot.scroll_col + rel_x

	new_byte, actual_col := text_area_byte_for_row_col(slot, target_row, target_col)
	slot.cursor_byte   = new_byte
	slot.has_selection = false
	text_area_rebuild_lines(slot)
	slot.preferred_col = actual_col
}
