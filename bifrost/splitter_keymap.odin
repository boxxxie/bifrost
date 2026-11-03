package bifrost

// =============================================================================
// Interactive Pane Splitters & 3-Tier Scoped/Global Keybinding Router
// =============================================================================

MAX_SPLITTER_SLOTS :: 16
MAX_KEYBINDINGS    :: 64

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
	active := (node.id_hash == inp.focused_id) || (node.id_hash == inp.active_splitter_id)
	hovered := node.id_hash == inp.hovered_id

	if active {
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
	slot := get_splitter_slot(inp, node.id_hash)
	step := max(1, slot.step)
	max_first := compute_splitter_max_first(slot)

	if slot.dir == .Row {
		#partial switch ev.code {
		case .Left:
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size - step, slot.min_first, max_first))
			return true
		case .Right:
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size + step, slot.min_first, max_first))
			return true
		case .Home, .Enter:
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.default_size, slot.min_first, max_first))
			return true
		}
	} else {
		#partial switch ev.code {
		case .Up:
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size - step, slot.min_first, max_first))
			return true
		case .Down:
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.size + step, slot.min_first, max_first))
			return true
		case .Home, .Enter:
			apply_splitter_size_immediate(ctx, node_idx, slot, clamp(slot.default_size, slot.min_first, max_first))
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

// =============================================================================
// 3-Tier Scoped & Global Keybinding Table (OpenCode / Television Priority Model)
// =============================================================================

Key_Scope_Policy :: enum u8 {
	Root_And_Scopes = 0, // Active on root layout and focus scopes, suppressed when an overlay modal captures input
	Scope_Only,          // Active ONLY when `active_scope_id == scope_id` (and not blocked by higher modal)
	Global_Always,       // Active globally even when a capturing modal is open (e.g. Ctrl+P palette toggle)
}

Keybinding_Flag :: enum u8 {
	Allow_In_Text_Input, // Fires even when a text_input widget is focused (default for Ctrl+key & F-keys)
}

Keybinding_Flags :: bit_set[Keybinding_Flag; u8]

Keybinding :: struct {
	key:               Key_Event,
	scope_id:          u64,
	policy:            Key_Scope_Policy,
	flags:             Keybinding_Flags,
	action_id:         u64,
	action_name:       string,
	nudge_splitter_id: u64,
	nudge_delta:       i32,
}

clear_keybindings :: proc "contextless" (inp: ^Input_State) {
	inp.keybinding_count = 0
}

bind_key :: proc(
	inp: ^Input_State,
	key: Key_Event,
	action_name: string,
	policy: Key_Scope_Policy = .Root_And_Scopes,
	scope_id: string = "",
	flags: Keybinding_Flags = {},
) {
	if inp.keybinding_count >= MAX_KEYBINDINGS {
		return
	}
	scope_h := hash_id(scope_id) if len(scope_id) > 0 else 0
	eff_policy := policy
	if scope_h != 0 && eff_policy == .Root_And_Scopes {
		eff_policy = .Scope_Only
	}
	inp.keybindings[inp.keybinding_count] = Keybinding{
		key         = key,
		scope_id    = scope_h,
		policy      = eff_policy,
		flags       = flags,
		action_id   = hash_id(action_name),
		action_name = action_name,
	}
	inp.keybinding_count += 1
}

// Binds a keyboard shortcut that also nudges a splitter by `delta` cells in the same frame when triggered.
bind_splitter_key :: proc(
	inp: ^Input_State,
	key: Key_Event,
	splitter_id: string,
	delta: i32,
	action_name: string = "",
	policy: Key_Scope_Policy = .Root_And_Scopes,
	scope_id: string = "",
	flags: Keybinding_Flags = {.Allow_In_Text_Input},
) {
	if inp.keybinding_count >= MAX_KEYBINDINGS {
		return
	}
	scope_h := hash_id(scope_id) if len(scope_id) > 0 else 0
	eff_policy := policy
	if scope_h != 0 && eff_policy == .Root_And_Scopes {
		eff_policy = .Scope_Only
	}
	act_name := action_name if len(action_name) > 0 else splitter_id
	inp.keybindings[inp.keybinding_count] = Keybinding{
		key               = key,
		scope_id          = scope_h,
		policy            = eff_policy,
		flags             = flags,
		action_id         = hash_id(act_name),
		action_name       = act_name,
		nudge_splitter_id = hash_id(splitter_id),
		nudge_delta       = delta,
	}
	inp.keybinding_count += 1
}

was_action_triggered :: proc(inp: ^Input_State, action_name: string) -> bool {
	return inp.triggered_action_id != 0 && inp.triggered_action_id == hash_id(action_name)
}

// Evaluates registered keybindings in 3 priority tiers:
// Tier 1: `.Scope_Only` matching `inp.active_scope_id` (when allowed by active modal shield)
// Tier 2: `.Root_And_Scopes` (when no capturing modal shield is active)
// Tier 3: `.Global_Always` (active even when a capturing modal is open)
// Single-character printable keys without `.Ctrl` are suppressed while a `text_input` is focused
// unless `.Allow_In_Text_Input` is explicitly set.
dispatch_keybindings :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	if inp.keybinding_count == 0 {
		return false
	}

	text_input_focused := false
	if inp.focused_id != 0 {
		if f_idx, ok := ctx.id_map[inp.focused_id]; ok {
			text_input_focused = ctx.nodes[f_idx].config.text_input
		}
	}

	// Tier 1: Scope_Only bindings matching active_scope_id
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.policy != .Scope_Only || kb.scope_id != inp.active_scope_id {
			continue
		}
		if capture_idx >= 0 {
			if s_idx, ok := ctx.id_map[kb.scope_id]; !ok || !is_node_allowed(ctx, s_idx, capture_idx) {
				continue
			}
		}
		if match_and_fire_binding(inp, ctx, kb, ev, text_input_focused) {
			return true
		}
	}

	// Tier 2: Root_And_Scopes bindings (suppressed when a capturing modal is open)
	if capture_idx < 0 {
		for i := 0; i < inp.keybinding_count; i += 1 {
			kb := inp.keybindings[i]
			if kb.policy != .Root_And_Scopes {
				continue
			}
			if match_and_fire_binding(inp, ctx, kb, ev, text_input_focused) {
				return true
			}
		}
	}

	// Tier 3: Global_Always bindings
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.policy != .Global_Always {
			continue
		}
		if match_and_fire_binding(inp, ctx, kb, ev, text_input_focused) {
			return true
		}
	}

	return false
}

@(private)
match_and_fire_binding :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	kb: Keybinding,
	ev: Key_Event,
	text_input_focused: bool,
) -> bool {
	if kb.key.code != ev.code || kb.key.mods != ev.mods {
		return false
	}
	if kb.key.code == .Rune {
		kc := kb.key.ch
		ec := ev.ch
		if kc >= 'A' && kc <= 'Z' {
			kc += 32
		}
		if ec >= 'A' && ec <= 'Z' {
			ec += 32
		}
		if kc != ec {
			return false
		}
	}

	// Suppress plain printable / Backspace / Left / Right shortcuts when typing inside a text_input
	if text_input_focused && (.Allow_In_Text_Input not_in kb.flags) {
		is_plain_typing := (.Ctrl not_in ev.mods) && (ev.code == .Rune || ev.code == .Space || ev.code == .Backspace || ev.code == .Delete || ev.code == .Left || ev.code == .Right || ev.code == .Home || ev.code == .End)
		if is_plain_typing {
			return false
		}
	}

	inp.triggered_action_id   = kb.action_id
	inp.triggered_action_name = kb.action_name
	if kb.nudge_splitter_id != 0 && kb.nudge_delta != 0 {
		nudge_splitter_by_hash(inp, ctx, kb.nudge_splitter_id, kb.nudge_delta)
	}
	return true
}
