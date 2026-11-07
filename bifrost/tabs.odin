package bifrost

import "core:fmt"

// =============================================================================
// Focus-Scope-Integrated Tab Bar & Tabbed Container (`ui_tabs` / `ui_tab_bar`)
// =============================================================================

MAX_TABS_SLOTS :: 16
MAX_TAB_ITEMS  :: 16

Tab_Item_Spec :: struct {
	label:    string,
	badge:    string,
	key_hint: string,
	disabled: bool,
}

Tabs_State :: struct {
	active_tab:  int,
	tab_count:   int,
	initialized: bool,
}

Tabs_Slot :: struct {
	id_hash:         u64,
	active_tab:      i32,
	tab_count:       i32,
	wrap_navigation: bool,
	has_body_scope:  bool,
	header_hash:     u64,
	body_scope_hash: [MAX_TAB_ITEMS]u64,
	tab_item_hash:   [MAX_TAB_ITEMS]u64,
	tab_disabled:    [MAX_TAB_ITEMS]bool,
	state_ptr:       ^Tabs_State,
	initialized:     bool,
	last_layout_gen: u64,
}

Tabs_Config :: struct {
	default_tab:       int,
	width:             Axis_Size,
	height:            Axis_Size,
	body_dir:          Direction,
	body_row:          bool,
	body_padding:      Padding,
	body_gap:          i32,
	body_border:       Border_Kind,
	header_border:     Border_Kind,
	fg:                Color,
	bg:                Color,
	header_bg:         Color,
	active_fg:         Color,
	active_bg:         Color,
	inactive_fg:       Color,
	inactive_bg:       Color,
	badge_fg:          Color,
	sep_fg:            Color,
	border_fg:         Color,
	title_fg:          Color,
	title:             string,
	show_index_hints:  bool,
	no_wrap:           bool,
	focus_flags:       Focus_Flags,
	body_focus_flags:  Focus_Flags,
	state:             ^Tabs_State,
}

// =============================================================================
// Tabs Slot Accessors & Immediate-Mode State Queries
// =============================================================================

get_tabs_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Tabs_Slot {
	empty_idx := -1
	lru_idx   := 0
	lru_gen   := max(u64)
	for i := 0; i < MAX_TABS_SLOTS; i += 1 {
		if inp.tabs_slots[i].id_hash == id_hash {
			return &inp.tabs_slots[i]
		}
		if empty_idx == -1 && inp.tabs_slots[i].id_hash == 0 {
			empty_idx = i
		}
		if inp.tabs_slots[i].last_layout_gen < lru_gen {
			lru_gen = inp.tabs_slots[i].last_layout_gen
			lru_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else lru_idx
	inp.tabs_slots[idx] = Tabs_Slot{
		id_hash         = id_hash,
		wrap_navigation = true,
	}
	return &inp.tabs_slots[idx]
}

@(private)
find_tabs_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Tabs_Slot {
	if id_hash == 0 {
		return nil
	}
	for i := 0; i < MAX_TABS_SLOTS; i += 1 {
		if inp.tabs_slots[i].id_hash == id_hash && inp.tabs_slots[i].initialized {
			return &inp.tabs_slots[i]
		}
	}
	return nil
}

@(private)
find_tabs_slot_by_header_or_item :: proc "contextless" (inp: ^Input_State, target_hash: u64) -> (slot: ^Tabs_Slot, item_idx: i32, is_header: bool) {
	if target_hash == 0 {
		return nil, -1, false
	}
	for i := 0; i < MAX_TABS_SLOTS; i += 1 {
		s := &inp.tabs_slots[i]
		if !s.initialized || s.id_hash == 0 {
			continue
		}
		if s.header_hash == target_hash {
			return s, -1, true
		}
		for t: i32 = 0; t < s.tab_count && t < MAX_TAB_ITEMS; t += 1 {
			if s.tab_item_hash[t] == target_hash {
				return s, t, false
			}
		}
	}
	return nil, -1, false
}

get_active_tab :: proc(inp: ^Input_State, id: string) -> int {
	if inp == nil || len(id) == 0 {
		return 0
	}
	slot := get_tabs_slot(inp, hash_id(id))
	if slot.state_ptr != nil && slot.state_ptr.initialized {
		return int(clamp(i32(slot.state_ptr.active_tab), 0, max(0, slot.tab_count - 1)))
	}
	return int(max(0, slot.active_tab))
}

set_active_tab :: proc(inp: ^Input_State, id: string, tab_idx: int, restore_body_focus: bool = true) {
	if inp == nil || len(id) == 0 {
		return
	}
	slot := get_tabs_slot(inp, hash_id(id))
	count := max(i32(1), slot.tab_count)
	clamped := clamp(i32(tab_idx), 0, count - 1)
	if !slot.initialized {
		slot.initialized = true
		slot.tab_count   = max(slot.tab_count, i32(tab_idx + 1))
	}
	slot.active_tab = clamped
	if slot.state_ptr != nil {
		slot.state_ptr.active_tab  = int(clamped)
		slot.state_ptr.initialized = true
	}
	if restore_body_focus && clamped >= 0 && clamped < MAX_TAB_ITEMS {
		body_h := slot.body_scope_hash[clamped]
		if body_h == 0 && (!slot.initialized || slot.has_body_scope) {
			body_h = tab_body_scope_hash(id, int(clamped))
		}
		if body_h != 0 {
			inp.wants_focus_id = body_h
		}
	}
}

was_tab_changed :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp != nil && inp.tab_changed_id != 0 && inp.tab_changed_id == hash_id(id)
}

tab_header_id :: proc(id: string, index: int, alloc := context.temp_allocator) -> string {
	return fmt.aprintf("%s_tab_%d", id, index, allocator = alloc)
}

tab_body_scope_id :: proc(id: string, index: int, alloc := context.temp_allocator) -> string {
	return fmt.aprintf("%s_body_%d", id, index, allocator = alloc)
}

tab_body_scope_hash :: proc(id: string, index: int) -> u64 {
	return hash_id(fmt.tprintf("%s_body_%d", id, index))
}

// =============================================================================
// Declarative Tab Header Bar (`ui_tab_bar`) & Scoped Container (`ui_tabs`)
// =============================================================================

ui_tab_bar :: proc {
	ui_tab_bar_strings,
	ui_tab_bar_specs,
}

ui_tab_bar_strings :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	labels: []string,
	cfg: Tabs_Config = {},
) -> int {
	specs: [MAX_TAB_ITEMS]Tab_Item_Spec
	cnt := min(len(labels), MAX_TAB_ITEMS)
	for i := 0; i < cnt; i += 1 {
		specs[i] = Tab_Item_Spec{label = labels[i]}
	}
	return ui_tab_bar_specs(ctx, s, inp, id, specs[:cnt], cfg)
}

ui_tab_bar_specs :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	items: []Tab_Item_Spec,
	cfg: Tabs_Config = {},
) -> int {
	id_h := hash_id(id)
	slot := get_tabs_slot(inp, id_h)

	count := i32(min(len(items), MAX_TAB_ITEMS))
	slot.tab_count       = max(0, count)
	slot.wrap_navigation = !cfg.no_wrap
	slot.state_ptr       = cfg.state
	slot.last_layout_gen = ctx.layout_gen

	if !slot.initialized {
		slot.initialized = true
		init_idx := i32(cfg.default_tab)
		if cfg.state != nil && cfg.state.initialized {
			init_idx = i32(cfg.state.active_tab)
		}
		slot.active_tab = clamp(init_idx, 0, max(0, count - 1))
	} else if cfg.state != nil && cfg.state.initialized {
		slot.active_tab = clamp(i32(cfg.state.active_tab), 0, max(0, count - 1))
	} else {
		slot.active_tab = clamp(slot.active_tab, 0, max(0, count - 1))
	}

	// Ensure active_tab does not rest on a disabled tab if an enabled tab exists
	if count > 0 && slot.active_tab >= 0 && slot.active_tab < count && items[slot.active_tab].disabled {
		for step: i32 = 0; step < count; step += 1 {
			cand := (slot.active_tab + step) % count
			if !items[cand].disabled {
				slot.active_tab = cand
				break
			}
		}
	}

	if cfg.state != nil {
		cfg.state.active_tab  = int(slot.active_tab)
		cfg.state.tab_count   = int(count)
		cfg.state.initialized = true
	}

	header_id := fmt.tprintf("%s_header", id)
	header_h  := hash_id(header_id)
	slot.header_hash = header_h

	for i: i32 = 0; i < count; i += 1 {
		item_id := fmt.tprintf("%s_tab_%d", id, i)
		slot.tab_item_hash[i] = hash_id(item_id)
		slot.tab_disabled[i]  = items[i].disabled
	}

	header_bg   := cfg.header_bg   if cfg.header_bg.kind   != .Default else (cfg.bg if cfg.bg.kind != .Default else rgb(30, 36, 48))
	active_fg   := cfg.active_fg   if cfg.active_fg.kind   != .Default else rgb(255, 220, 110)
	active_bg   := cfg.active_bg   if cfg.active_bg.kind   != .Default else rgb(55, 68, 92)
	inactive_fg := cfg.inactive_fg if cfg.inactive_fg.kind != .Default else (cfg.fg if cfg.fg.kind != .Default else rgb(170, 182, 202))
	inactive_bg := cfg.inactive_bg if cfg.inactive_bg.kind != .Default else header_bg
	badge_fg    := cfg.badge_fg    if cfg.badge_fg.kind    != .Default else rgb(125, 210, 255)
	sep_fg      := cfg.sep_fg      if cfg.sep_fg.kind      != .Default else rgb(90, 104, 126)

	if s != nil {
		s.paints[header_h] = Paint_Spec{
			fg        = inactive_fg,
			bg        = header_bg,
			border_fg = cfg.border_fg,
			fill_bg   = true,
		}
	}

	bar_h: i32 = 3 if cfg.header_border != .None else 1
	if container(ctx, header_id, Box_Config{
		dir         = .Row,
		width       = cfg.width if cfg.width != nil else grow(1),
		height      = fixed(bar_h),
		border      = cfg.header_border,
		focus_flags = {.Focus_Scope, .Focusable, .Loop_Spatial},
		focus_scope = true,
		focusable   = true,
	}) {
		for i: i32 = 0; i < count; i += 1 {
			if i > 0 {
				sep_id := fmt.tprintf("%s_sep_%d", id, i)
				if s != nil {
					s.paints[hash_id(sep_id)] = Paint_Spec{
						text    = "│",
						fg      = sep_fg,
						bg      = header_bg,
						fill_bg = true,
					}
				}
				leaf(ctx, sep_id, 1, 1, Box_Config{
					width  = fixed(1),
					height = fixed(1),
					text   = "│",
				})
			}

			spec := items[i]
			is_active := (i == slot.active_tab)
			item_id := fmt.tprintf("%s_tab_%d", id, i)
			item_h  := slot.tab_item_hash[i]

			hint_str := spec.key_hint
			if len(hint_str) == 0 && cfg.show_index_hints && i < 9 {
				hint_str = fmt.tprintf("%d:", i + 1)
			}

			tab_fg := active_fg if is_active else inactive_fg
			tab_bg := active_bg if is_active else inactive_bg
			tab_st := Style_Flags{.Bold} if is_active else Style_Flags{}
			if spec.disabled {
				tab_st += {.Dim}
			}

			spans := make([dynamic]Styled_Span, 0, 5, context.temp_allocator)
			append(&spans, Styled_Span{
				text  = "[ " if is_active else "  ",
				fg    = tab_fg,
				bg    = tab_bg,
				style = tab_st,
			})
			if len(hint_str) > 0 {
				append(&spans, Styled_Span{
					text  = fmt.tprintf("%s", hint_str),
					fg    = badge_fg if !is_active else active_fg,
					bg    = tab_bg,
					style = tab_st,
				})
			}
			append(&spans, Styled_Span{
				text  = spec.label,
				fg    = tab_fg,
				bg    = tab_bg,
				style = tab_st,
			})
			if len(spec.badge) > 0 {
				append(&spans, Styled_Span{
					text  = fmt.tprintf(" (%s)", spec.badge),
					fg    = badge_fg,
					bg    = tab_bg,
					style = tab_st,
				})
			}
			append(&spans, Styled_Span{
				text  = " ]" if is_active else "  ",
				fg    = tab_fg,
				bg    = tab_bg,
				style = tab_st,
			})

			full_text := concat_spans_temp(spans[:])
			disp_w := max(1, string_display_width(full_text))

			if s != nil {
				s.paints[item_h] = Paint_Spec{
					text    = full_text,
					spans   = spans[:],
					fg      = tab_fg,
					bg      = tab_bg,
					style   = tab_st,
					fill_bg = true,
				}
			}

			item_flags: Focus_Flags = {.Focusable}
			if is_active {
				item_flags += {.Default_Focus}
			}
			if spec.disabled {
				item_flags += {.Disabled}
			}
			enabled := !spec.disabled

			leaf(ctx, item_id, disp_w, 1, Box_Config{
				dir         = .Row,
				width       = fit(min = 1),
				height      = fixed(1),
				main_align  = .Center,
				cross_align = .Center,
				focus_flags = item_flags,
				focusable   = enabled,
				clickable   = enabled,
				hoverable   = enabled,
			})
		}
	}

	return int(slot.active_tab)
}

@(deferred_in = defer_end_ui_tabs_strings)
ui_tabs_strings :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	labels: []string,
	cfg: Tabs_Config = {},
	out_active_tab: ^int = nil,
) -> bool {
	specs: [MAX_TAB_ITEMS]Tab_Item_Spec
	cnt := min(len(labels), MAX_TAB_ITEMS)
	for i := 0; i < cnt; i += 1 {
		specs[i] = Tab_Item_Spec{label = labels[i]}
	}
	return begin_ui_tabs_internal(ctx, s, inp, id, specs[:cnt], cfg, out_active_tab)
}

defer_end_ui_tabs_strings :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	labels: []string,
	cfg: Tabs_Config = {},
	out_active_tab: ^int = nil,
) {
	_ = s
	_ = inp
	_ = id
	_ = labels
	_ = cfg
	_ = out_active_tab
	exit_container_node(ctx) // exit active tab body scope (`<id>_body_<active>`)
	exit_container_node(ctx) // exit outer tabs scope (`<id>`)
}

@(deferred_in = defer_end_ui_tabs_specs)
ui_tabs_specs :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	items: []Tab_Item_Spec,
	cfg: Tabs_Config = {},
	out_active_tab: ^int = nil,
) -> bool {
	return begin_ui_tabs_internal(ctx, s, inp, id, items, cfg, out_active_tab)
}

defer_end_ui_tabs_specs :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	items: []Tab_Item_Spec,
	cfg: Tabs_Config = {},
	out_active_tab: ^int = nil,
) {
	_ = s
	_ = inp
	_ = id
	_ = items
	_ = cfg
	_ = out_active_tab
	exit_container_node(ctx) // exit active tab body scope (`<id>_body_<active>`)
	exit_container_node(ctx) // exit outer tabs scope (`<id>`)
}

ui_tabs :: proc {
	ui_tabs_strings,
	ui_tabs_specs,
}

@(private)
begin_ui_tabs_internal :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	items: []Tab_Item_Spec,
	cfg: Tabs_Config,
	out_active_tab: ^int,
) -> bool {
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else grow(1)
	outer_flags := cfg.focus_flags + {.Focus_Scope}

	outer_idx := push_node(ctx, id, Box_Config{
		dir         = .Column,
		width       = w,
		height      = h,
		focus_flags = outer_flags,
		focus_scope = true,
		focusable   = .Focusable in outer_flags,
	}, {0, 0})
	enter_container_node(ctx, outer_idx)

	bar_cfg := cfg
	bar_cfg.width = grow(1)
	active_idx := ui_tab_bar_specs(ctx, s, inp, id, items, bar_cfg)
	if out_active_tab != nil {
		out_active_tab^ = active_idx
	}

	body_id := fmt.tprintf("%s_body_%d", id, active_idx)
	body_h  := hash_id(body_id)
	slot := get_tabs_slot(inp, hash_id(id))
	slot.has_body_scope = true
	cnt := min(len(items), MAX_TAB_ITEMS)
	for i := 0; i < cnt; i += 1 {
		slot.body_scope_hash[i] = hash_id(fmt.tprintf("%s_body_%d", id, i))
	}
	if active_idx >= 0 && active_idx < MAX_TAB_ITEMS {
		slot.body_scope_hash[active_idx] = body_h
	}

	// Keep the outer `ui_tabs` scope's Shallow History (H) pointed at the currently active tab's body scope
	// so `F6` scope cycling or Fresh Mount resolution into `id` always enters the active tab body's H* leaf
	// rather than stopping at the header bar — UNLESS focus is currently directly on the tab header bar!
	on_this_header := false
	if inp != nil && inp.focused_id != 0 {
		if s_hdr, _, _ := find_tabs_slot_by_header_or_item(inp, inp.focused_id); s_hdr == slot {
			on_this_header = true
		}
	}
	if !on_this_header {
		outer_h := ctx.nodes[outer_idx].id_hash
		body_mem := get_scope_memory(inp, body_h)
		active_leaf := body_mem.last_leaf_hash if body_mem != nil else 0
		upsert_scope_memory(inp, outer_h, body_h, active_leaf)
	}

	body_flags := cfg.body_focus_flags + {.Focus_Scope, .Default_Focus}
	if s != nil && (cfg.body_border != .None || len(cfg.title) > 0 || cfg.bg.kind != .Default || cfg.fg.kind != .Default || cfg.border_fg.kind != .Default) {
		s.paints[body_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			title_style = {.Bold} if len(cfg.title) > 0 else {},
			fill_bg     = cfg.bg.kind != .Default,
		}
	}

	body_idx := push_node(ctx, body_id, Box_Config{
		dir         = .Row if cfg.body_row else cfg.body_dir if cfg.body_dir != .Row else .Column,
		width       = grow(1),
		height      = grow(1),
		padding     = cfg.body_padding,
		gap         = cfg.body_gap,
		border      = cfg.body_border,
		focus_flags = body_flags,
		focus_scope = true,
		focusable   = .Focusable in body_flags,
	}, {0, 0})
	enter_container_node(ctx, body_idx)
	return true
}

// =============================================================================
// Keyboard (`[`/`]`, `Alt+1..9`, Header `h`/`l`) & Mouse Tab Switching + H*
// =============================================================================

@(private)
select_tab_in_slot :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	slot: ^Tabs_Slot,
	target_tab: i32,
	focus_body: bool,
) -> bool {
	if slot == nil || slot.tab_count <= 0 {
		return false
	}
	if target_tab < 0 || target_tab >= slot.tab_count || target_tab >= MAX_TAB_ITEMS {
		return false
	}
	if slot.tab_disabled[target_tab] {
		return false
	}

	prev_tab := slot.active_tab
	slot.active_tab = target_tab
	if slot.state_ptr != nil {
		slot.state_ptr.active_tab  = int(target_tab)
		slot.state_ptr.initialized = true
	}
	if prev_tab != target_tab {
		inp.tab_changed_id = slot.id_hash
	}

	body_h := slot.body_scope_hash[target_tab]
	body_mem := get_scope_memory(inp, body_h)
	leaf_h := body_mem.last_leaf_hash if body_mem != nil else 0
	if body_h != 0 {
		upsert_scope_memory(inp, slot.id_hash, body_h, leaf_h)
	}

	if focus_body && body_h != 0 {
		inp.wants_focus_id = body_h
		// If the target tab body happens to be mounted in the current tree (e.g. same-tab click), resolve immediately
		if b_idx, ok := ctx.id_map[body_h]; ok && is_node_allowed(ctx, b_idx, capture_idx) {
			if resolved := resolve_scope_target(inp, ctx, b_idx, capture_idx, true); resolved >= 0 {
				reset_preferred_nav(inp)
				set_focused_node(inp, ctx, resolved, capture_idx, false)
			}
		}
	} else if !focus_body {
		item_h := slot.tab_item_hash[target_tab]
		if item_h != 0 {
			inp.wants_focus_id = item_h
			if item_idx, ok := ctx.id_map[item_h]; ok && is_node_allowed(ctx, item_idx, capture_idx) {
				reset_preferred_nav(inp)
				set_focused_node(inp, ctx, item_idx, capture_idx, false)
			}
		}
	}
	return true
}

@(private)
step_tab_in_slot :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	slot: ^Tabs_Slot,
	delta: i32,
	focus_body: bool,
	from_tab: i32 = -1,
) -> bool {
	if slot == nil || slot.tab_count <= 0 || delta == 0 {
		return false
	}
	count := min(slot.tab_count, i32(MAX_TAB_ITEMS))
	if count <= 1 {
		return select_tab_in_slot(inp, ctx, capture_idx, slot, 0, focus_body)
	}

	dir: i32 = 1 if delta > 0 else -1
	steps := abs(delta)
	base := from_tab if (from_tab >= 0 && from_tab < count) else slot.active_tab
	cur := clamp(base, 0, count - 1)

	for s: i32 = 0; s < steps; s += 1 {
		for attempt: i32 = 0; attempt < count; attempt += 1 {
			next := cur + dir
			if slot.wrap_navigation {
				next = ((next % count) + count) % count
			} else {
				if next < 0 || next >= count {
					break
				}
			}
			cur = next
			if !slot.tab_disabled[cur] {
				break
			}
		}
	}

	return select_tab_in_slot(inp, ctx, capture_idx, slot, cur, focus_body)
}

// Handles keyboard tab switching when focus is on the tab header bar (`h`/`l`, `Left`/`Right`, `j`/`Down`, `Enter`)
// or anywhere inside a `ui_tabs` container (`[` / `]`, `Alt+1..9`).
handle_tabs_key :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	if inp.editing_id != 0 {
		return false
	}
	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}

	// 1. Check if focus is directly on a tab header bar or one of its tab header items
	if inp.focused_id != 0 {
		if slot, item_idx, is_hdr := find_tabs_slot_by_header_or_item(inp, inp.focused_id); slot != nil {
			from_tab := item_idx if (!is_hdr && item_idx >= 0) else slot.active_tab
			nav_dir, is_nav := key_to_nav_dir(ev, false, inp.keymap_style)
			if is_nav {
				switch nav_dir {
				case .Left:
					mult := consume_repeat_count(inp)
					return step_tab_in_slot(inp, ctx, capture_idx, slot, -mult, false, from_tab)
				case .Right:
					mult := consume_repeat_count(inp)
					return step_tab_in_slot(inp, ctx, capture_idx, slot, +mult, false, from_tab)
				case .Down:
					clear_repeat_count(inp)
					return select_tab_in_slot(inp, ctx, capture_idx, slot, from_tab, true)
				case .Up:
				}
			}
			if (ev.code == .Enter || ev.code == .Space) && eff_mods == {} {
				clear_repeat_count(inp)
				return select_tab_in_slot(inp, ctx, capture_idx, slot, from_tab, true)
			}
		}
	}

	// 2. Walk `focus_node_path` innermost-first (halting at `.Trap_Focus`) for `[` / `]` and `Alt+1..9`
	is_prev_bracket := eff_mods == {} && ev.code == .Rune && ev.ch == '['
	is_next_bracket := eff_mods == {} && ev.code == .Rune && ev.ch == ']'
	is_alt_num      := eff_mods == {.Alt} && ev.code == .Rune && ev.ch >= '1' && ev.ch <= '9'

	if !is_prev_bracket && !is_next_bracket && !is_alt_num {
		return false
	}

	for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
		n_idx := inp.focus_node_path[p]
		if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
			continue
		}
		node := ctx.nodes[n_idx]
		if !is_node_allowed(ctx, n_idx, capture_idx) {
			if .Trap_Focus in node.focus_flags {
				break
			}
			continue
		}

		slot := find_tabs_slot(inp, node.id_hash)
		if slot == nil {
			slot, _, _ = find_tabs_slot_by_header_or_item(inp, node.id_hash)
		}
		if slot != nil {
			on_header := false
			if s_hdr, _, _ := find_tabs_slot_by_header_or_item(inp, inp.focused_id); s_hdr == slot {
				on_header = true
			}
			focus_body := !on_header
			if is_prev_bracket {
				mult := consume_repeat_count(inp)
				return step_tab_in_slot(inp, ctx, capture_idx, slot, -mult, focus_body)
			}
			if is_next_bracket {
				mult := consume_repeat_count(inp)
				return step_tab_in_slot(inp, ctx, capture_idx, slot, +mult, focus_body)
			}
			if is_alt_num {
				clear_repeat_count(inp)
				target_idx := i32(ev.ch - '1')
				if target_idx >= 0 && target_idx < slot.tab_count {
					return select_tab_in_slot(inp, ctx, capture_idx, slot, target_idx, focus_body)
				}
				return false
			}
		}

		if .Trap_Focus in node.focus_flags {
			break
		}
	}

	// 3. Fallback when a `ui_tab_bar` is used standalone (not wrapping the focused widget in `ui_tabs`):
	//    find the most recently mounted allowed standalone `Tabs_Slot` in the current layout generation.
	for i := 0; i < MAX_TABS_SLOTS; i += 1 {
		slot := &inp.tabs_slots[i]
		if !slot.initialized || slot.id_hash == 0 || slot.last_layout_gen != ctx.layout_gen || slot.has_body_scope {
			continue
		}
		if hdr_idx, ok := ctx.id_map[slot.header_hash]; !ok || !is_node_allowed(ctx, hdr_idx, capture_idx) {
			continue
		}
		if is_prev_bracket {
			mult := consume_repeat_count(inp)
			return step_tab_in_slot(inp, ctx, capture_idx, slot, -mult, true)
		}
		if is_next_bracket {
			mult := consume_repeat_count(inp)
			return step_tab_in_slot(inp, ctx, capture_idx, slot, +mult, true)
		}
		if is_alt_num {
			clear_repeat_count(inp)
			target_idx := i32(ev.ch - '1')
			if target_idx >= 0 && target_idx < slot.tab_count {
				return select_tab_in_slot(inp, ctx, capture_idx, slot, target_idx, true)
			}
		}
	}

	return false
}

// Handles mouse left-click on a tab header item, switching `active_tab` and queuing `wants_focus_id`
// to restore the selected tab's per-tab `Focus_Scope` Deep History ($H^*$).
handle_tabs_mouse_press :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	hit_idx: i32,
) -> bool {
	if hit_idx < 0 || int(hit_idx) >= len(ctx.nodes) {
		return false
	}
	node := ctx.nodes[hit_idx]
	slot, item_idx, is_hdr := find_tabs_slot_by_header_or_item(inp, node.id_hash)
	if slot == nil || is_hdr || item_idx < 0 {
		return false
	}
	clear_repeat_count(inp)
	return select_tab_in_slot(inp, ctx, capture_idx, slot, item_idx, true)
}
