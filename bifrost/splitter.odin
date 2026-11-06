package bifrost

// =============================================================================
// Interactive Pane Splitters & 3-Tier Scoped/Global Keybinding Router
// =============================================================================

MAX_SPLITTER_SLOTS :: 16

Splitter_Submode :: enum u8 {
	Navigate = 0, // Default spatial-passthrough focus state (Enter enters Resize)
	Resize   = 1, // Active keyboard resize sub-mode (h/j/k/l or Arrows resize, = resets, Enter/Esc exits)
}

Splitter_Slot :: struct {
	id_hash:         u64,
	dir:             Direction, // .Row = vertical divider (resizes width), .Column = horizontal divider (resizes height)
	size:            i32,       // Current first-pane width or height in cells
	default_size:    i32,
	min_first:       i32,
	max_first:       i32,       // Explicit max_size if > 0
	min_second:      i32,
	step:            i32,
	parent_span:     i32,       // Solved parent inner span along split axis
	drag_anchor_pos: i32,
	drag_start_size: i32,
	initialized:     bool,
}

Splitter_Config :: struct {
	dir:          Direction, // Parent container axis (.Row for left/right split, .Column for top/bottom split)
	default_size: i32,
	min_size:     i32,
	max_size:     i32,
	min_first:    i32,
	min_second:   i32,
	step:         i32,
	fg:           Color,
	bg:           Color,
	active_fg:    Color,
}

// =============================================================================
// Splitter Slot Accessors, Widget Builder & Same-Frame Resize
// =============================================================================

get_splitter_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Splitter_Slot {
	empty_idx := -1
	for i := 0; i < MAX_SPLITTER_SLOTS; i += 1 {
		if inp.splitter_slots[i].id_hash == id_hash {
			return &inp.splitter_slots[i]
		}
		if empty_idx == -1 && inp.splitter_slots[i].id_hash == 0 {
			empty_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else 0
	inp.splitter_slots[idx] = Splitter_Slot{
		id_hash      = id_hash,
		size         = 24,
		default_size = 24,
		min_first    = 8,
		min_second   = 8,
		step         = 2,
	}
	return &inp.splitter_slots[idx]
}

@(private)
compute_splitter_max_first :: proc "contextless" (slot: ^Splitter_Slot) -> i32 {
	limit := slot.max_first if slot.max_first > 0 else MAX_DIM
	if slot.parent_span > 0 {
		parent_limit := max(slot.min_first, slot.parent_span - 1 - slot.min_second)
		limit = min(limit, parent_limit)
	}
	return max(slot.min_first, limit)
}

// Returns the current clamped size (width or height) for the pane preceding splitter `id`.
get_split_size :: proc(
	inp: ^Input_State,
	id: string,
	default_size: i32 = 24,
	min_size: i32 = 8,
	max_size: i32 = 0,
) -> i32 {
	slot := get_splitter_slot(inp, hash_id(id))
	if !slot.initialized {
		slot.initialized  = true
		slot.size         = default_size
		slot.default_size = default_size
		slot.min_first    = max(1, min_size)
		slot.max_first    = max_size
	}
	max_f := compute_splitter_max_first(slot)
	slot.size = clamp(slot.size, slot.min_first, max_f)
	return slot.size
}

ui_splitter :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Splitter_Config = {},
) -> i32 {
	id_h := hash_id(id)
	slot := get_splitter_slot(inp, id_h)

	def_sz := cfg.default_size if cfg.default_size > 0 else 24
	min_1  := cfg.min_size if cfg.min_size > 0 else (cfg.min_first if cfg.min_first > 0 else 8)
	min_2  := cfg.min_second if cfg.min_second > 0 else 8
	step   := cfg.step if cfg.step > 0 else 2

	if !slot.initialized {
		slot.initialized  = true
		slot.size         = max(min_1, def_sz)
		slot.default_size = max(min_1, def_sz)
	}
	slot.dir          = cfg.dir
	slot.default_size = max(min_1, def_sz)
	slot.min_first    = min_1
	slot.max_first    = cfg.max_size
	slot.min_second   = min_2
	slot.step         = step

	max_first := compute_splitter_max_first(slot)
	slot.size = clamp(slot.size, slot.min_first, max_first)

	is_row := cfg.dir == .Row
	w := fixed(1) if is_row else grow(1)
	h := grow(1) if is_row else fixed(1)
	fill_ch := '│' if is_row else '─'

	fg := cfg.fg if cfg.fg.kind != .Default else rgb(110, 130, 155)
	s.paints[id_h] = Paint_Spec{
		fg        = fg,
		bg        = cfg.bg,
		border_fg = cfg.active_fg if cfg.active_fg.kind != .Default else rgb(255, 215, 0),
		fill_bg   = true,
		fill_char = fill_ch,
	}

	return leaf(ctx, id, 1, 1, Box_Config{
		width     = w,
		height    = h,
		focusable = true,
		clickable = true,
		hoverable = true,
		draggable = true,
		splitter  = true,
	})
}

sync_splitter_paint :: proc(s: ^Screen, inp: ^Input_State, node: Layout_Node) {
	slot := get_splitter_slot(inp, node.id_hash)
	paint, ok := s.paints[node.id_hash]
	if !ok {
		return
	}
	is_row := slot.dir == .Row
	resizing := get_scope_submode_by_hash(inp, node.id_hash) == u8(Splitter_Submode.Resize)
	active := (node.id_hash == inp.focused_id) || (node.id_hash == inp.active_splitter_id)
	hovered := node.id_hash == inp.hovered_id

	if resizing {
		paint.fill_char = '║' if is_row else '═'
		if paint.border_fg.kind != .Default {
			paint.fg = paint.border_fg
		}
		paint.style += {.Bold, .Reverse}
	} else if active {
		paint.fill_char = '┃' if is_row else '━'
		if paint.border_fg.kind != .Default {
			paint.fg = paint.border_fg
		}
		paint.style += {.Bold}
	} else if hovered {
		paint.fill_char = '┃' if is_row else '━'
	} else {
		paint.fill_char = '│' if is_row else '─'
	}
	s.paints[node.id_hash] = paint
}

@(private)
find_splitter_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Splitter_Slot {
	for i := 0; i < MAX_SPLITTER_SLOTS; i += 1 {
		if inp.splitter_slots[i].id_hash == id_hash && inp.splitter_slots[i].initialized {
			return &inp.splitter_slots[i]
		}
	}
	return nil
}

// Synchronizes parent container inner spans with mounted splitter slots and clamps split sizes
// after terminal resize or initial layout solve.
sync_splitters :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context) {
	for i := 0; i < len(ctx.nodes); i += 1 {
		node := ctx.nodes[i]
		if !node.config.splitter || node.parent_idx < 0 {
			continue
		}
		slot := find_splitter_slot(inp, node.id_hash)
		if slot == nil {
			continue
		}
		parent := ctx.nodes[node.parent_idx]
		axis := 0 if slot.dir == .Row else 1
		avail := parent.inner_rect.w if axis == 0 else parent.inner_rect.h
		slot.parent_span = avail

		max_first := compute_splitter_max_first(slot)
		new_size  := clamp(slot.size, slot.min_first, max_first)
		if new_size != slot.size {
			apply_splitter_size_immediate(ctx, i32(i), slot, new_size)
		}
	}
}

begin_splitter_drag :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context, node_idx: i32, mx, my: i32) {
	node := ctx.nodes[node_idx]
	slot := find_splitter_slot(inp, node.id_hash)
	if slot == nil {
		return
	}
	inp.active_splitter_id = node.id_hash
	slot.drag_anchor_pos   = mx if slot.dir == .Row else my
	slot.drag_start_size   = slot.size
}

handle_splitter_drag :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context, mx, my: i32) {
	if inp.active_splitter_id == 0 {
		return
	}
	node_idx, exists := ctx.id_map[inp.active_splitter_id]
	if !exists {
		inp.active_splitter_id = 0
		return
	}
	slot := get_splitter_slot(inp, inp.active_splitter_id)
	cur_pos := mx if slot.dir == .Row else my
	delta := cur_pos - slot.drag_anchor_pos
	max_first := compute_splitter_max_first(slot)
	target_size := clamp(slot.drag_start_size + delta, slot.min_first, max_first)
	apply_splitter_size_immediate(ctx, node_idx, slot, target_size)
}

handle_splitter_key :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	ev: Key_Event,
) -> bool {
	node := ctx.nodes[node_idx]
	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	submode := Splitter_Submode(get_scope_submode_by_hash(inp, node.id_hash))

	if submode == .Navigate {
		if ev.code == .Enter && eff_mods == {} {
			set_scope_submode_by_hash(inp, node.id_hash, u8(Splitter_Submode.Resize))
			return true
		}
		return false
	}

	// Splitter_Submode.Resize: h/j/k/l, Arrows, or Emacs C-b/C-f/C-p/C-n resize; =/0/Home resets; Enter/Escape exits
	if (ev.code == .Enter || ev.code == .Escape) && eff_mods == {} {
		clear_repeat_count(inp)
		set_scope_submode_by_hash(inp, node.id_hash, 0)
		return true
	}

	slot := get_splitter_slot(inp, node.id_hash)
	unit_step := max(1, slot.step)
	max_first := compute_splitter_max_first(slot)

	if eff_mods == {} && ev.code == .Rune && ev.ch >= '0' && ev.ch <= '9' {
		digit := i32(ev.ch - '0')
		if inp.keymap_style == .Helix && inp.has_last_motion && (digit > 0 || inp.suffix_count > 0) {
			new_suffix := min(9999, inp.suffix_count * 10 + digit)
			inp.suffix_count = new_suffix
			delta := new_suffix - inp.last_motion_applied
			if delta > 0 {
				sign: i32 = 1 if (inp.last_motion_dir == .Right || inp.last_motion_dir == .Down) else -1
				apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size + sign * delta * unit_step, slot.min_first, max_first))
				inp.last_motion_applied = new_suffix
			}
			return true
		}
		if (ev.ch >= '1' && ev.ch <= '9') || (ev.ch == '0' && (inp.repeat_count > 0 || inp.emacs_universal_arg)) {
			if inp.keymap_style == .Emacs && inp.emacs_universal_arg && !inp.emacs_arg_digits {
				inp.emacs_arg_digits = true
				inp.repeat_count     = digit
			} else {
				inp.repeat_count = min(9999, inp.repeat_count * 10 + digit)
			}
			return true
		}
	}

	mult := consume_repeat_count(inp)
	step := unit_step * mult

	if ev.code == .Home || (eff_mods == {} && ev.code == .Rune && (ev.ch == '=' || ev.ch == '0')) {
		clear_repeat_count(inp)
		apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.default_size, slot.min_first, max_first))
		return true
	}

	if slot.dir == .Row {
		is_left := ev.code == .Left ||
			(eff_mods == {} && inp.keymap_style != .Emacs && ev.code == .Rune && (ev.ch == 'h' || ev.ch == 'H')) ||
			(eff_mods == {.Ctrl} && inp.keymap_style == .Emacs && ev.code == .Rune && (ev.ch == 'b' || ev.ch == 'B'))
		is_right := ev.code == .Right ||
			(eff_mods == {} && inp.keymap_style != .Emacs && ev.code == .Rune && (ev.ch == 'l' || ev.ch == 'L')) ||
			(eff_mods == {.Ctrl} && inp.keymap_style == .Emacs && ev.code == .Rune && (ev.ch == 'f' || ev.ch == 'F'))
		if is_left {
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size - step, slot.min_first, max_first))
			if inp.keymap_style == .Helix {
				inp.has_last_motion     = true
				inp.last_motion_dir     = .Left
				inp.last_motion_applied = mult
				inp.suffix_count        = 0
			}
			return true
		}
		if is_right {
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size + step, slot.min_first, max_first))
			if inp.keymap_style == .Helix {
				inp.has_last_motion     = true
				inp.last_motion_dir     = .Right
				inp.last_motion_applied = mult
				inp.suffix_count        = 0
			}
			return true
		}
	} else {
		is_up := ev.code == .Up ||
			(eff_mods == {} && inp.keymap_style != .Emacs && ev.code == .Rune && (ev.ch == 'k' || ev.ch == 'K')) ||
			(eff_mods == {.Ctrl} && inp.keymap_style == .Emacs && ev.code == .Rune && (ev.ch == 'p' || ev.ch == 'P'))
		is_down := ev.code == .Down ||
			(eff_mods == {} && inp.keymap_style != .Emacs && ev.code == .Rune && (ev.ch == 'j' || ev.ch == 'J')) ||
			(eff_mods == {.Ctrl} && inp.keymap_style == .Emacs && ev.code == .Rune && (ev.ch == 'n' || ev.ch == 'N'))
		if is_up {
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size - step, slot.min_first, max_first))
			if inp.keymap_style == .Helix {
				inp.has_last_motion     = true
				inp.last_motion_dir     = .Up
				inp.last_motion_applied = mult
				inp.suffix_count        = 0
			}
			return true
		}
		if is_down {
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size + step, slot.min_first, max_first))
			if inp.keymap_style == .Helix {
				inp.has_last_motion     = true
				inp.last_motion_dir     = .Down
				inp.last_motion_applied = mult
				inp.suffix_count        = 0
			}
			return true
		}
	}
	return false
}

reset_splitter_to_default :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context, node_idx: i32) {
	node := ctx.nodes[node_idx]
	slot := get_splitter_slot(inp, node.id_hash)
	max_first := compute_splitter_max_first(slot)
	target := clamp(slot.default_size, slot.min_first, max_first)
	apply_splitter_size_immediate(ctx, node_idx, slot, target)
}

// Programmatically nudges a splitter by `delta` cells and updates solved sibling rects in the current frame.
nudge_splitter :: proc(inp: ^Input_State, ctx: ^Layout_Context, id: string, delta: i32) {
	id_h := hash_id(id)
	nudge_splitter_by_hash(inp, ctx, id_h, delta)
}

nudge_splitter_by_hash :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context, id_h: u64, delta: i32) {
	slot := get_splitter_slot(inp, id_h)
	max_first := compute_splitter_max_first(slot)
	target := clamp(slot.size + delta, slot.min_first, max_first)
	if node_idx, exists := ctx.id_map[id_h]; exists {
		apply_splitter_size_immediate(ctx, node_idx, slot, target)
	} else {
		slot.size = target
	}
}

// Updates `slot.size` and immediately adjusts the preceding pane, splitter node, and following pane
// rectangles/clips in `ctx.nodes` so that `render_layout` reflects the resize in the exact same frame.
apply_splitter_size_immediate :: proc "contextless" (
	ctx: ^Layout_Context,
	splitter_idx: i32,
	slot: ^Splitter_Slot,
	new_size: i32,
) {
	old_size := slot.size
	slot.size = new_size
	if splitter_idx < 0 || int(splitter_idx) >= len(ctx.nodes) {
		return
	}
	splitter_node := &ctx.nodes[splitter_idx]
	if splitter_node.parent_idx < 0 {
		return
	}
	parent := ctx.nodes[splitter_node.parent_idx]

	prev_idx := i32(-1)
	for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
		if c == splitter_idx {
			break
		}
		prev_idx = c
	}
	next_idx := splitter_node.next_sibling

	delta := new_size - old_size
	if delta == 0 && (prev_idx < 0 || (slot.dir == .Row && ctx.nodes[prev_idx].rect.w == new_size) || (slot.dir == .Column && ctx.nodes[prev_idx].rect.h == new_size)) {
		return
	}

	if slot.dir == .Row {
		if prev_idx >= 0 {
			actual_delta := new_size - ctx.nodes[prev_idx].rect.w
			ctx.nodes[prev_idx].rect.w       = new_size
			ctx.nodes[prev_idx].inner_rect.w = max(0, ctx.nodes[prev_idx].inner_rect.w + actual_delta)
			recompute_subtree_clips(ctx, prev_idx, parent.inner_clip)

			splitter_node.rect.x       = ctx.nodes[prev_idx].rect.x + new_size
			splitter_node.inner_rect.x = splitter_node.rect.x
			recompute_subtree_clips(ctx, splitter_idx, parent.inner_clip)

			if next_idx >= 0 {
				old_next_x := ctx.nodes[next_idx].rect.x
				new_next_x := splitter_node.rect.x + splitter_node.rect.w
				dx := new_next_x - old_next_x
				ctx.nodes[next_idx].rect.x       = new_next_x
				ctx.nodes[next_idx].rect.w       = max(0, (parent.inner_rect.x + parent.inner_rect.w) - new_next_x)
				ctx.nodes[next_idx].inner_rect.x += dx
				ctx.nodes[next_idx].inner_rect.w = max(0, ctx.nodes[next_idx].inner_rect.w - dx)
				shift_children_x(ctx, next_idx, dx)
				recompute_subtree_clips(ctx, next_idx, parent.inner_clip)
			}
		}
	} else {
		if prev_idx >= 0 {
			actual_delta := new_size - ctx.nodes[prev_idx].rect.h
			ctx.nodes[prev_idx].rect.h       = new_size
			ctx.nodes[prev_idx].inner_rect.h = max(0, ctx.nodes[prev_idx].inner_rect.h + actual_delta)
			recompute_subtree_clips(ctx, prev_idx, parent.inner_clip)

			splitter_node.rect.y       = ctx.nodes[prev_idx].rect.y + new_size
			splitter_node.inner_rect.y = splitter_node.rect.y
			recompute_subtree_clips(ctx, splitter_idx, parent.inner_clip)

			if next_idx >= 0 {
				old_next_y := ctx.nodes[next_idx].rect.y
				new_next_y := splitter_node.rect.y + splitter_node.rect.h
				dy := new_next_y - old_next_y
				ctx.nodes[next_idx].rect.y       = new_next_y
				ctx.nodes[next_idx].rect.h       = max(0, (parent.inner_rect.y + parent.inner_rect.h) - new_next_y)
				ctx.nodes[next_idx].inner_rect.y += dy
				ctx.nodes[next_idx].inner_rect.h = max(0, ctx.nodes[next_idx].inner_rect.h - dy)
				shift_descendants_y(ctx, next_idx, dy, parent.inner_clip)
				recompute_subtree_clips(ctx, next_idx, parent.inner_clip)
			}
		}
	}
}

@(private)
shift_children_x :: proc "contextless" (ctx: ^Layout_Context, parent_idx: i32, dx: i32) {
	if dx == 0 {
		return
	}
	for c := ctx.nodes[parent_idx].first_child; c != -1; c = ctx.nodes[c].next_sibling {
		child := &ctx.nodes[c]
		if child.out_of_flow {
			continue
		}
		child.rect.x       += dx
		child.inner_rect.x += dx
		if child.child_count > 0 {
			shift_children_x(ctx, c, dx)
		}
	}
}

@(private)
recompute_subtree_clips :: proc "contextless" (ctx: ^Layout_Context, idx: i32, parent_clip: Rect) {
	node := &ctx.nodes[idx]
	node.node_clip  = rect_intersect(parent_clip, node.rect)
	node.inner_clip = rect_intersect(node.node_clip, node.inner_rect)
	for c := node.first_child; c != -1; c = ctx.nodes[c].next_sibling {
		if !ctx.nodes[c].out_of_flow {
			recompute_subtree_clips(ctx, c, node.inner_clip)
		}
	}
}

