package bifrost

import "core:fmt"
import "core:math"
import "core:strings"

// =============================================================================
// Track 15: Form Controls Suite (bifrost/form_controls.odin)
// =============================================================================

MAX_SLIDER_SLOTS :: 16

Slider_Slot :: struct {
	id_hash:            u64,
	value:              f64,
	min_val:            f64,
	max_val:            f64,
	step:               f64,
	track_offset:       i32,
	track_w:            i32,
	solved_w:           i32,
	last_frame_touched: u64,
	changed:            bool,
}

get_slider_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Slider_Slot {
	if inp == nil || id_hash == 0 {
		return nil
	}
	for i := 0; i < len(inp.slider_slots); i += 1 {
		if inp.slider_slots[i].id_hash == id_hash {
			inp.slider_slots[i].last_frame_touched = inp.frame_index
			return &inp.slider_slots[i]
		}
	}
	for i := 0; i < len(inp.slider_slots); i += 1 {
		if inp.slider_slots[i].id_hash == 0 {
			inp.slider_slots[i] = Slider_Slot{
				id_hash            = id_hash,
				last_frame_touched = inp.frame_index,
			}
			return &inp.slider_slots[i]
		}
	}
	// Evict least-recently-used slot when full
	lru_idx := 0
	for i := 1; i < len(inp.slider_slots); i += 1 {
		if inp.slider_slots[i].last_frame_touched < inp.slider_slots[lru_idx].last_frame_touched {
			lru_idx = i
		}
	}
	inp.slider_slots[lru_idx] = Slider_Slot{
		id_hash            = id_hash,
		last_frame_touched = inp.frame_index,
	}
	return &inp.slider_slots[lru_idx]
}

find_slider_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Slider_Slot {
	if inp == nil || id_hash == 0 {
		return nil
	}
	for i := 0; i < len(inp.slider_slots); i += 1 {
		if inp.slider_slots[i].id_hash == id_hash {
			return &inp.slider_slots[i]
		}
	}
	return nil
}

handle_slider_mouse_press :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	hit_idx: i32,
	mouse_x: i32,
) {
	if hit_idx < 0 || int(hit_idx) >= len(ctx.nodes) {
		return
	}
	if !is_node_allowed(ctx, hit_idx, capture_idx) {
		return
	}
	node := &ctx.nodes[hit_idx]
	slot := find_slider_slot(inp, node.id_hash)
	if slot == nil {
		return
	}
	inp.active_slider_id = node.id_hash

	track_w := slot.track_w if slot.track_w > 0 else max(i32(1), node.inner_rect.w)
	track_x := node.inner_rect.x + slot.track_offset
	rel_x := clamp(mouse_x - track_x, 0, max(i32(1), track_w - 1))
	ratio := f64(rel_x) / f64(max(i32(1), track_w - 1))
	new_val := slot.min_val + ratio * (slot.max_val - slot.min_val)
	if slot.step > 0 {
		new_val = math.round((new_val - slot.min_val) / slot.step) * slot.step + slot.min_val
	}
	new_val = clamp(new_val, slot.min_val, slot.max_val)
	if new_val != slot.value {
		slot.value   = new_val
		slot.changed = true
	}
}

handle_slider_mouse_drag :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	mouse_x: i32,
) {
	if inp.active_slider_id == 0 {
		return
	}
	p_idx, ok := ctx.id_map[inp.active_slider_id]
	if !ok || p_idx < 0 || int(p_idx) >= len(ctx.nodes) {
		return
	}
	node := &ctx.nodes[p_idx]
	slot := find_slider_slot(inp, inp.active_slider_id)
	if slot == nil {
		return
	}

	track_w := slot.track_w if slot.track_w > 0 else max(i32(1), node.inner_rect.w)
	track_x := node.inner_rect.x + slot.track_offset
	rel_x := clamp(mouse_x - track_x, 0, max(i32(1), track_w - 1))
	ratio := f64(rel_x) / f64(max(i32(1), track_w - 1))
	new_val := slot.min_val + ratio * (slot.max_val - slot.min_val)
	if slot.step > 0 {
		new_val = math.round((new_val - slot.min_val) / slot.step) * slot.step + slot.min_val
	}
	new_val = clamp(new_val, slot.min_val, slot.max_val)
	if new_val != slot.value {
		slot.value   = new_val
		slot.changed = true
	}
}

handle_slider_key :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	if inp.focused_id == 0 {
		return false
	}
	p_idx, ok := ctx.id_map[inp.focused_id]
	if !ok || p_idx < 0 || int(p_idx) >= len(ctx.nodes) {
		return false
	}
	if !is_node_allowed(ctx, p_idx, capture_idx) {
		return false
	}
	node := &ctx.nodes[p_idx]
	if !node.config.slider {
		return false
	}
	slot := find_slider_slot(inp, node.id_hash)
	if slot == nil {
		return false
	}

	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	if eff_mods != {} {
		return false
	}

	step := slot.step if slot.step > 0 else 1.0

	#partial switch ev.code {
	case .Left:
		new_val := clamp(slot.value - step, slot.min_val, slot.max_val)
		if new_val != slot.value {
			slot.value   = new_val
			slot.changed = true
		}
		return true
	case .Right:
		new_val := clamp(slot.value + step, slot.min_val, slot.max_val)
		if new_val != slot.value {
			slot.value   = new_val
			slot.changed = true
		}
		return true
	case .Home:
		if slot.min_val != slot.value {
			slot.value   = slot.min_val
			slot.changed = true
		}
		return true
	case .End:
		if slot.max_val != slot.value {
			slot.value   = slot.max_val
			slot.changed = true
		}
		return true
	case .Rune:
		if ev.ch == 'h' || ev.ch == '-' {
			new_val := clamp(slot.value - step, slot.min_val, slot.max_val)
			if new_val != slot.value {
				slot.value   = new_val
				slot.changed = true
			}
			return true
		} else if ev.ch == 'l' || ev.ch == '+' || ev.ch == '=' {
			new_val := clamp(slot.value + step, slot.min_val, slot.max_val)
			if new_val != slot.value {
				slot.value   = new_val
				slot.changed = true
			}
			return true
		}
	}
	return false
}

// -----------------------------------------------------------------------------
// Checkbox Widget
// -----------------------------------------------------------------------------

Checkbox_Config :: struct {
	width:           Axis_Size,
	height:          Axis_Size,
	fg:              Color,
	bg:              Color,
	checked_fg:      Color,
	focus_fg:        Color,
	hover_fg:        Color,
	border:          Border_Kind,
	focus_flags:     Focus_Flags,
	disabled:        bool,
	checked_glyph:   string,
	unchecked_glyph: string,
}

ui_checkbox :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	checked: ^bool,
	label: string,
	cfg: Checkbox_Config = {},
) -> (changed: bool) {
	id_h := hash_id(id)

	if was_activated(inp, id) && !cfg.disabled {
		checked^ = !checked^
		changed  = true
	}

	chk_mark := cfg.checked_glyph if len(cfg.checked_glyph) > 0 else "[x] "
	unchk_mark := cfg.unchecked_glyph if len(cfg.unchecked_glyph) > 0 else "[ ] "
	mark := chk_mark if checked^ else unchk_mark
	full_text := fmt.tprintf("%s%s", mark, label)
	text_w := string_display_width(full_text)

	is_foc := is_focused(inp, id)
	is_hov := is_hovered(inp, id)

	fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)
	bg := cfg.bg if cfg.bg.kind != .Default else Color{}
	if checked^ && cfg.checked_fg.kind != .Default {
		fg = cfg.checked_fg
	}
	if is_foc {
		fg = cfg.focus_fg if cfg.focus_fg.kind != .Default else rgb(255, 235, 140)
	} else if is_hov {
		fg = cfg.hover_fg if cfg.hover_fg.kind != .Default else rgb(255, 255, 255)
	}
	if cfg.disabled {
		fg = rgb(105, 115, 130)
	}

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			text    = full_text,
			fg      = fg,
			bg      = bg,
			style   = {.Bold} if is_foc else {},
			fill_bg = bg.kind != .Default,
		}
	}

	w := cfg.width if cfg.width != nil else fit(min = text_w + 1)
	h := cfg.height if cfg.height != nil else fit(min = 1)
	is_enabled := !cfg.disabled && (.Disabled not_in cfg.focus_flags)

	leaf(ctx, id, text_w, 1, Box_Config{
		dir         = .Row,
		width       = w,
		height      = h,
		border      = cfg.border,
		focus_flags = cfg.focus_flags,
		focusable   = is_enabled,
		clickable   = is_enabled,
		hoverable   = is_enabled,
	})

	return changed
}

// -----------------------------------------------------------------------------
// Switch Widget
// -----------------------------------------------------------------------------

Switch_Config :: struct {
	width:       Axis_Size,
	height:      Axis_Size,
	on_label:    string,
	off_label:   string,
	on_fg:       Color,
	off_fg:      Color,
	bg:          Color,
	focus_fg:    Color,
	border:      Border_Kind,
	focus_flags: Focus_Flags,
	disabled:    bool,
}

ui_switch :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	value: ^bool,
	label: string = "",
	cfg: Switch_Config = {},
) -> (changed: bool) {
	id_h := hash_id(id)

	if was_activated(inp, id) && !cfg.disabled {
		value^  = !value^
		changed = true
	}

	is_foc := is_focused(inp, id)
	is_hov := is_hovered(inp, id)

	on_active  := cfg.on_label  if len(cfg.on_label)  > 0 else "ON"
	on_dim     := cfg.on_label  if len(cfg.on_label)  > 0 else "on"
	off_active := cfg.off_label if len(cfg.off_label) > 0 else "OFF"
	off_dim    := cfg.off_label if len(cfg.off_label) > 0 else "off"

	switch_str := fmt.tprintf("[ %s | %s ]", on_active, off_dim) if value^ else fmt.tprintf("[ %s | %s ]", on_dim, off_active)
	full_text := fmt.tprintf("%s %s", switch_str, label) if len(label) > 0 else switch_str
	text_w := string_display_width(full_text)

	on_fg      := cfg.on_fg if cfg.on_fg.kind != .Default else rgb(120, 240, 160)
	off_fg     := cfg.off_fg if cfg.off_fg.kind != .Default else rgb(160, 170, 185)
	active_off := cfg.off_fg if cfg.off_fg.kind != .Default else rgb(230, 140, 150)
	fg := on_fg if value^ else active_off
	if is_foc {
		fg = cfg.focus_fg if cfg.focus_fg.kind != .Default else rgb(255, 235, 140)
	} else if is_hov {
		fg = rgb(255, 255, 255)
	}
	if cfg.disabled {
		fg = rgb(105, 115, 130)
	}

	bg := cfg.bg if cfg.bg.kind != .Default else Color{}
	if s != nil {
		spans := make([]Styled_Span, 6, context.temp_allocator)
		spans[0] = Styled_Span{text = "[ ", fg = fg, bg = bg, style = {.Bold} if is_foc else {}}
		spans[1] = Styled_Span{
			text  = on_active if value^ else on_dim,
			fg    = (fg if is_foc else on_fg) if value^ else off_fg,
			bg    = bg,
			style = {.Bold} if value^ else {.Dim},
		}
		spans[2] = Styled_Span{text = " | ", fg = fg, bg = bg, style = {.Bold} if is_foc else {}}
		spans[3] = Styled_Span{
			text  = off_dim if value^ else off_active,
			fg    = off_fg if value^ else (fg if is_foc else active_off),
			bg    = bg,
			style = {.Dim} if value^ else {.Bold},
		}
		spans[4] = Styled_Span{text = " ]", fg = fg, bg = bg, style = {.Bold} if is_foc else {}}
		spans[5] = Styled_Span{text = fmt.tprintf(" %s", label) if len(label) > 0 else "", fg = fg, bg = bg, style = {.Bold} if is_foc else {}}
		s.paints[id_h] = Paint_Spec{
			text    = full_text,
			spans   = spans,
			fg      = fg,
			bg      = bg,
			style   = {},
			fill_bg = bg.kind != .Default,
		}
	}

	w := cfg.width if cfg.width != nil else fit(min = text_w + 1)
	h := cfg.height if cfg.height != nil else fit(min = 1)
	is_enabled := !cfg.disabled && (.Disabled not_in cfg.focus_flags)

	leaf(ctx, id, text_w, 1, Box_Config{
		dir         = .Row,
		width       = w,
		height      = h,
		border      = cfg.border,
		focus_flags = cfg.focus_flags,
		focusable   = is_enabled,
		clickable   = is_enabled,
		hoverable   = is_enabled,
	})

	return changed
}

// -----------------------------------------------------------------------------
// Radio Group Widget
// -----------------------------------------------------------------------------

Radio_Group_Config :: struct {
	dir:         Maybe(Direction),
	horizontal:  bool,
	gap:         i32,
	fg:          Color,
	bg:          Color,
	active_fg:   Color,
	focus_fg:    Color,
	hover_fg:    Color,
	border:      Border_Kind,
	focus_flags: Focus_Flags,
	auto_select: bool,
	disabled:    bool,
}

ui_radio_group :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	selected_idx: ^int,
	options: []string,
	cfg: Radio_Group_Config = {},
) -> (changed: bool) {
	if len(options) == 0 {
		return false
	}
	sel := clamp(selected_idx^, 0, len(options) - 1)
	if sel != selected_idx^ {
		selected_idx^ = sel
		changed = true
	}

	dir: Direction = .Row if cfg.horizontal else .Column
	if d, has_dir := cfg.dir.?; has_dir {
		dir = d
	}

	// Pre-scan activations first, then auto-selection so all options render consistent state
	if !cfg.disabled {
		activated_any := false
		for _, i in options {
			opt_id := fmt.tprintf("%s_opt_%d", id, i)
			if was_activated(inp, opt_id) {
				if selected_idx^ != i {
					selected_idx^ = i
					changed       = true
				}
				activated_any = true
				break
			}
		}
		if !activated_any && cfg.auto_select {
			for _, i in options {
				opt_id := fmt.tprintf("%s_opt_%d", id, i)
				if is_focused(inp, opt_id) && selected_idx^ != i {
					selected_idx^ = i
					changed       = true
					break
				}
			}
		}
	}

	if container(ctx, id, Box_Config{
		dir         = dir,
		gap         = cfg.gap,
		border      = cfg.border,
		focus_flags = {.Focus_Scope} + cfg.focus_flags,
		focus_scope = true,
	}) {
		for opt, i in options {
			opt_id := fmt.tprintf("%s_opt_%d", id, i)
			opt_h := hash_id(opt_id)
			is_selected := (i == selected_idx^)
			is_foc := is_focused(inp, opt_id)
			is_hov := is_hovered(inp, opt_id)

			mark := "(•) " if is_selected else "( ) "
			text := fmt.tprintf("%s%s", mark, opt)
			text_w := string_display_width(text)

			fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)
			if is_selected {
				fg = cfg.active_fg if cfg.active_fg.kind != .Default else rgb(120, 215, 255)
			}
			if is_foc {
				fg = cfg.focus_fg if cfg.focus_fg.kind != .Default else rgb(255, 235, 140)
			} else if is_hov {
				fg = cfg.hover_fg if cfg.hover_fg.kind != .Default else rgb(255, 255, 255)
			}
			if cfg.disabled {
				fg = rgb(105, 115, 130)
			}

			if s != nil {
				s.paints[opt_h] = Paint_Spec{
					text    = text,
					fg      = fg,
					bg      = cfg.bg,
					style   = {.Bold} if (is_selected || is_foc) else {},
					fill_bg = cfg.bg.kind != .Default,
				}
			}

			is_enabled := !cfg.disabled && (.Disabled not_in cfg.focus_flags)
			opt_flags := cfg.focus_flags
			if is_selected {
				opt_flags += {.Default_Focus}
			}
			leaf(ctx, opt_id, text_w, 1, Box_Config{
				dir         = .Row,
				width       = fit(min = text_w + 1),
				height      = fit(min = 1),
				focusable   = is_enabled,
				clickable   = is_enabled,
				hoverable   = is_enabled,
				focus_flags = opt_flags,
			})
		}
	}
	return changed
}

// -----------------------------------------------------------------------------
// Slider Widget
// -----------------------------------------------------------------------------

Slider_Config :: struct {
	width:       Axis_Size,
	height:      Axis_Size,
	min_val:     f64,
	max_val:     f64,
	step:        f64,
	hide_value:  bool,
	label:       string,
	fg:          Color,
	fill_fg:     Color,
	thumb_fg:    Color,
	bg:          Color,
	focus_fg:    Color,
	focus_flags: Focus_Flags,
	disabled:    bool,
}

ui_slider :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	value: ^f64,
	min_val: f64 = 0.0,
	max_val: f64 = 100.0,
	step: f64 = 1.0,
	cfg: Slider_Config = {},
) -> (changed: bool) {
	id_h := hash_id(id)
	slot := get_slider_slot(inp, id_h)
	if slot == nil {
		return false
	}

	slot.min_val = min_val if cfg.min_val == 0.0 && cfg.max_val == 0.0 else cfg.min_val
	slot.max_val = max_val if cfg.min_val == 0.0 && cfg.max_val == 0.0 else cfg.max_val
	if slot.max_val <= slot.min_val {
		slot.max_val = slot.min_val + 100.0
	}
	slot.step = step if cfg.step == 0.0 else cfg.step
	if slot.step <= 0.0 {
		slot.step = 1.0
	}

	if slot.changed {
		value^       = slot.value
		changed      = true
		slot.changed = false
	} else {
		slot.value = clamp(value^, slot.min_val, slot.max_val)
	}

	is_foc := is_focused(inp, id)
	is_hov := is_hovered(inp, id)

	ratio := clamp((slot.value - slot.min_val) / (slot.max_val - slot.min_val), 0.0, 1.0)
	pct := int(math.round(ratio * 100.0))
	val_str := fmt.tprintf(" %d%%", pct)

	intrinsic_cols: i32 = 24
	if fixed_w, is_fixed := cfg.width.(Fixed); is_fixed && i32(fixed_w) > 0 {
		intrinsic_cols = i32(fixed_w)
	}
	total_cols := intrinsic_cols
	if _, is_fixed := cfg.width.(Fixed); !is_fixed && slot.solved_w > 0 {
		total_cols = slot.solved_w
	}

	prefix := fmt.tprintf("%s: [", cfg.label) if len(cfg.label) > 0 else "["
	suffix := fmt.tprintf("]%s", "" if cfg.hide_value else val_str)
	prefix_w := string_display_width(prefix)
	overhead := prefix_w + string_display_width(suffix)
	inner_track := max(i32(4), total_cols - overhead)
	intrinsic_w := prefix_w + max(i32(4), intrinsic_cols - overhead) + string_display_width(suffix)
	slot.track_offset = prefix_w
	slot.track_w      = inner_track

	thumb_idx := clamp(i32(math.round(ratio * f64(max(i32(1), inner_track - 1)))), 0, inner_track - 1)

	fill_chars := make([]rune, thumb_idx, context.temp_allocator)
	for i: i32 = 0; i < thumb_idx; i += 1 {
		fill_chars[i] = '═'
	}
	rem_len := max(i32(0), inner_track - thumb_idx - 1)
	rem_chars := make([]rune, rem_len, context.temp_allocator)
	for i: i32 = 0; i < rem_len; i += 1 {
		rem_chars[i] = '─'
	}
	fill_str := utf8_runes_to_string(fill_chars, context.temp_allocator)
	rem_str  := utf8_runes_to_string(rem_chars, context.temp_allocator)
	full_str := fmt.tprintf("%s%s●%s%s", prefix, fill_str, rem_str, suffix)

	fg := cfg.fg if cfg.fg.kind != .Default else rgb(180, 205, 230)
	if is_foc {
		fg = cfg.focus_fg if cfg.focus_fg.kind != .Default else rgb(255, 235, 140)
	} else if is_hov {
		fg = rgb(255, 255, 255)
	}
	if cfg.disabled {
		fg = rgb(105, 115, 130)
	}

	fill_fg  := cfg.fill_fg if cfg.fill_fg.kind != .Default else fg
	thumb_fg := cfg.thumb_fg if cfg.thumb_fg.kind != .Default else fg
	bg       := cfg.bg if cfg.bg.kind != .Default else Color{}
	if s != nil {
		spans := make([]Styled_Span, 4, context.temp_allocator)
		spans[0] = Styled_Span{text = prefix, fg = fg, bg = bg}
		spans[1] = Styled_Span{text = fill_str, fg = fill_fg, bg = bg}
		spans[2] = Styled_Span{text = "●", fg = thumb_fg, bg = bg, style = {.Bold}}
		spans[3] = Styled_Span{text = fmt.tprintf("%s%s", rem_str, suffix), fg = fg, bg = bg}
		s.paints[id_h] = Paint_Spec{
			text    = full_str,
			spans   = spans,
			fg      = fg,
			bg      = bg,
			style   = {.Bold} if is_foc else {},
			fill_bg = bg.kind != .Default,
		}
	}

	w := cfg.width if cfg.width != nil else fit(min = intrinsic_w)
	h := cfg.height if cfg.height != nil else fit(min = 1)
	is_enabled := !cfg.disabled && (.Disabled not_in cfg.focus_flags)

	leaf(ctx, id, intrinsic_w, 1, Box_Config{
		dir         = .Row,
		width       = w,
		height      = h,
		border      = .None,
		focus_flags = cfg.focus_flags,
		focusable   = is_enabled,
		clickable   = is_enabled,
		hoverable   = is_enabled,
		draggable   = is_enabled,
		slider      = is_enabled,
	})

	return changed
}

// Synchronizes slider track geometry and Paint_Spec spans against the solved Layout_Node width on every frame
sync_slider_paint :: proc(s: ^Screen, inp: ^Input_State, node: Layout_Node) {
	slot := find_slider_slot(inp, node.id_hash)
	if slot == nil || node.inner_rect.w <= 0 {
		return
	}
	slot.solved_w = node.inner_rect.w
	if s == nil {
		return
	}
	paint, ok := s.paints[node.id_hash]
	if !ok || len(paint.spans) != 4 {
		return
	}

	prefix := paint.spans[0].text
	prefix_w := string_display_width(prefix)
	ratio := clamp((slot.value - slot.min_val) / max(1e-9, slot.max_val - slot.min_val), 0.0, 1.0)
	pct := int(math.round(ratio * 100.0))

	// Extract suffix starting from ']' in spans[3]
	span3_text := paint.spans[3].text
	bracket_idx := strings.index_byte(span3_text, ']')
	suffix := fmt.tprintf("] %d%%", pct)
	if bracket_idx >= 0 && bracket_idx + 1 == len(span3_text) {
		suffix = "]"
	}
	overhead := prefix_w + string_display_width(suffix)
	inner_track := max(i32(4), node.inner_rect.w - overhead)
	slot.track_offset = prefix_w
	slot.track_w      = inner_track

	thumb_idx := clamp(i32(math.round(ratio * f64(max(i32(1), inner_track - 1)))), 0, inner_track - 1)
	fill_chars := make([]rune, thumb_idx, context.temp_allocator)
	for i: i32 = 0; i < thumb_idx; i += 1 {
		fill_chars[i] = '═'
	}
	rem_len := max(i32(0), inner_track - thumb_idx - 1)
	rem_chars := make([]rune, rem_len, context.temp_allocator)
	for i: i32 = 0; i < rem_len; i += 1 {
		rem_chars[i] = '─'
	}
	fill_str := utf8_runes_to_string(fill_chars, context.temp_allocator)
	rem_str  := utf8_runes_to_string(rem_chars, context.temp_allocator)

	paint.spans[1].text = fill_str
	paint.spans[3].text = fmt.tprintf("%s%s", rem_str, suffix)
	paint.text = fmt.tprintf("%s%s●%s%s", prefix, fill_str, rem_str, suffix)
	s.paints[node.id_hash] = paint
}

// -----------------------------------------------------------------------------
// Dropdown Widget
// -----------------------------------------------------------------------------

Dropdown_Config :: struct {
	width:             Axis_Size,
	max_visible_items: int,
	fg:                Color,
	bg:                Color,
	border:            Border_Kind,
	menu_fg:           Color,
	menu_bg:           Color,
	sel_fg:            Color,
	sel_bg:            Color,
	focus_flags:       Focus_Flags,
	disabled:          bool,
}

ui_dropdown :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	selected_idx: ^int,
	options: []string,
	is_open: ^bool,
	cfg: Dropdown_Config = {},
) -> (changed: bool) {
	if len(options) == 0 {
		return false
	}
	sel := clamp(selected_idx^, 0, len(options) - 1)
	if sel != selected_idx^ {
		selected_idx^ = sel
		changed = true
	}

	header_id := id
	header_h := hash_id(header_id)
	menu_id := fmt.tprintf("%s_dropdown_menu", id)
	menu_h := hash_id(menu_id)
	is_enabled := !cfg.disabled && (.Disabled not_in cfg.focus_flags)

	if is_open^ && is_enabled {
		for _, i in options {
			opt_id := fmt.tprintf("%s_item_%d", id, i)
			if was_activated(inp, opt_id) {
				changed       = (selected_idx^ != i)
				selected_idx^ = i
				is_open^      = false
				request_focus(inp, header_id)
				break
			}
		}
	}

	if was_modal_dismissed(inp, menu_id) {
		is_open^ = false
		request_focus(inp, header_id)
	}

	if was_activated(inp, header_id) && is_enabled {
		is_open^ = !is_open^
		if is_open^ && len(options) > 0 {
			sel_item := clamp(selected_idx^, 0, len(options) - 1)
			request_focus(inp, fmt.tprintf("%s_item_%d", id, sel_item))
		}
	}

	is_foc := is_focused(inp, header_id)
	is_hov := is_hovered(inp, header_id)

	sel_text := options[selected_idx^]
	arrow := " ▴" if is_open^ else " ▾"
	display_str := fmt.tprintf("[%s%s]", sel_text, arrow)
	text_w := string_display_width(display_str)

	fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 240)
	bg := cfg.bg if cfg.bg.kind != .Default else rgb(45, 50, 65)
	if is_foc {
		fg = rgb(255, 235, 140)
	} else if is_hov {
		fg = rgb(255, 255, 255)
	}
	if !is_enabled {
		fg = rgb(105, 115, 130)
	}

	if s != nil {
		s.paints[header_h] = Paint_Spec{
			text    = display_str,
			fg      = fg,
			bg      = bg,
			style   = {.Bold} if is_foc else {},
			fill_bg = true,
		}
	}

	w := cfg.width if cfg.width != nil else fit(min = text_w + 2)
	leaf(ctx, header_id, text_w, 1, Box_Config{
		dir         = .Row,
		width       = w,
		height      = fit(min = 1),
		border      = cfg.border,
		focusable   = is_enabled,
		clickable   = is_enabled,
		hoverable   = is_enabled,
		focus_flags = cfg.focus_flags,
	})

	if is_open^ {
		max_items := cfg.max_visible_items if cfg.max_visible_items > 0 else len(options)
		vis_count := min(len(options), max_items)

		max_opt_w := text_w
		for opt in options {
			ow := string_display_width(opt) + 4
			if ow > max_opt_w {
				max_opt_w = ow
			}
		}

		menu_bg := cfg.menu_bg if cfg.menu_bg.kind != .Default else rgb(30, 35, 48)
		menu_fg := cfg.menu_fg if cfg.menu_fg.kind != .Default else rgb(215, 225, 240)
		sel_bg  := cfg.sel_bg if cfg.sel_bg.kind != .Default else rgb(60, 75, 105)
		sel_fg  := cfg.sel_fg if cfg.sel_fg.kind != .Default else rgb(255, 235, 140)

		if s != nil {
			s.paints[menu_h] = Paint_Spec{
				fg        = menu_fg,
				bg        = menu_bg,
				border_fg = rgb(80, 100, 135),
				fill_bg   = true,
			}
		}

		if container(ctx, menu_id, Box_Config{
			dir              = .Column,
			floating         = true,
			anchor           = .Parent,
			anchor_parent_id = header_id,
			parent_anchor    = .Bottom_Left,
			element_anchor   = .Top_Left,
			clamp_to_screen  = true,
			z_layer          = 10,
			offset           = {0, 0},
			border           = .Plain,
			width            = fit(min = max_opt_w),
			height           = fixed(i32(vis_count) + 2),
			scrollable       = len(options) > vis_count,
			scroll_offset    = get_scroll_offset(inp, menu_id),
			capture_input    = true,
			focus_scope      = true,
			focus_flags      = {.Focus_Scope, .Trap_Focus},
		}) {
			for opt, i in options {
				opt_id := fmt.tprintf("%s_item_%d", id, i)
				opt_h := hash_id(opt_id)
				is_item_sel := (i == selected_idx^)
				is_item_foc := is_focused(inp, opt_id)
				is_item_hov := is_hovered(inp, opt_id)

				item_fg := menu_fg
				item_bg := menu_bg
				if is_item_sel || is_item_foc || is_item_hov {
					item_bg = sel_bg
					item_fg = sel_fg
				}

				mark := "✓ " if is_item_sel else "  "
				item_str := fmt.tprintf("%s%s", mark, opt)

				if s != nil {
					s.paints[opt_h] = Paint_Spec{
						text    = item_str,
						fg      = item_fg,
						bg      = item_bg,
						style   = {.Bold} if is_item_sel else {},
						fill_bg = true,
					}
				}

				leaf(ctx, opt_id, string_display_width(item_str), 1, Box_Config{
					dir       = .Row,
					width     = grow(1),
					height    = fit(min = 1),
					focusable = true,
					clickable = true,
					hoverable = true,
				})
			}
		}
	}

	return changed
}

@(private)
utf8_runes_to_string :: proc(runes: []rune, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	for r in runes {
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}
