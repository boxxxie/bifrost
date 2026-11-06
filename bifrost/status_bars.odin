package bifrost

import "core:fmt"

Dynamic_Bar_Kind :: enum u8 {
	Breadcrumb = 0,
	Key_Hints  = 1,
}

Breadcrumb_Bar_Config :: struct {
	width:     Axis_Size,
	fg:        Color,
	bg:        Color,
	active_fg: Color,
	sep_fg:    Color,
	prefix:    string,
}

Key_Hint_Bar_Config :: struct {
	width:    Axis_Size,
	key_fg:   Color,
	desc_fg:  Color,
	sep_fg:   Color,
	bg:       Color,
	mode_fg:  Color,
	mode_bg:  Color,
	chord_fg: Color,
	chord_bg: Color,
	dim_fg:   Color,
}

Dynamic_Bar_Entry :: struct {
	id_hash:   u64,
	kind:      Dynamic_Bar_Kind,
	crumb_cfg: Breadcrumb_Bar_Config,
	hint_cfg:  Key_Hint_Bar_Config,
}


// =============================================================================
// Contextual Focus Breadcrumb Bar & Live Key Hint Bar (Zero-Lag Refresh)
// =============================================================================

ui_focus_breadcrumb_bar :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Breadcrumb_Bar_Config = {},
) -> i32 {
	_ = inp
	id_h := hash_id(id)
	w := cfg.width if cfg.width != nil else grow(1)
	if s != nil {
		s.paints[id_h] = Paint_Spec{
			bg      = cfg.bg,
			fill_bg = cfg.bg.kind != .Default,
		}
		append(&s.dynamic_bars, Dynamic_Bar_Entry{
			id_hash   = id_h,
			kind      = .Breadcrumb,
			crumb_cfg = cfg,
		})
	}
	return leaf(ctx, id, 1, 1, Box_Config{
		width  = w,
		height = fixed(1),
	})
}

ui_key_hint_bar :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Key_Hint_Bar_Config = {},
) -> i32 {
	_ = inp
	id_h := hash_id(id)
	w := cfg.width if cfg.width != nil else grow(1)
	if s != nil {
		s.paints[id_h] = Paint_Spec{
			bg      = cfg.bg,
			fill_bg = cfg.bg.kind != .Default,
		}
		append(&s.dynamic_bars, Dynamic_Bar_Entry{
			id_hash  = id_h,
			kind     = .Key_Hints,
			hint_cfg = cfg,
		})
	}
	return leaf(ctx, id, 1, 1, Box_Config{
		width  = w,
		height = fixed(1),
	})
}

// Re-evaluates all mounted `ui_focus_breadcrumb_bar` and `ui_key_hint_bar` widgets after
// `resolve_input` so mode transitions, pending chords, and focus jumps render on the exact same frame.
refresh_dynamic_bars :: proc(s: ^Screen, ctx: ^Layout_Context, inp: ^Input_State) {
	if s == nil || ctx == nil || inp == nil || len(s.dynamic_bars) == 0 {
		return
	}
	for entry in s.dynamic_bars {
		n_idx, ok := ctx.id_map[entry.id_hash]
		if !ok || n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
			continue
		}
		max_w := max(0, ctx.nodes[n_idx].inner_rect.w)
		switch entry.kind {
		case .Breadcrumb:
			s.paints[entry.id_hash] = build_breadcrumb_paint(ctx, inp, entry.crumb_cfg, max_w)
		case .Key_Hints:
			s.paints[entry.id_hash] = build_key_hints_paint(ctx, inp, entry.hint_cfg, max_w)
		}
	}
}

@(private)
build_breadcrumb_paint :: proc(
	ctx: ^Layout_Context,
	inp: ^Input_State,
	cfg: Breadcrumb_Bar_Config,
	max_w: i32,
) -> Paint_Spec {
	fg        := cfg.fg if cfg.fg.kind != .Default else rgb(165, 180, 200)
	active_fg := cfg.active_fg if cfg.active_fg.kind != .Default else rgb(255, 220, 110)
	sep_fg    := cfg.sep_fg if cfg.sep_fg.kind != .Default else rgb(100, 115, 135)
	prefix    := cfg.prefix if len(cfg.prefix) > 0 else "Focus: "

	names: [MAX_FOCUS_PATH]string
	name_cnt := 0
	for i := 0; i < inp.focus_node_path_len && name_cnt < MAX_FOCUS_PATH; i += 1 {
		idx := inp.focus_node_path[i]
		if idx >= 0 && int(idx) < len(ctx.nodes) && len(ctx.nodes[idx].id) > 0 {
			names[name_cnt] = ctx.nodes[idx].id
			name_cnt += 1
		}
	}

	if max_w <= 0 || name_cnt == 0 {
		return Paint_Spec{bg = cfg.bg, fill_bg = cfg.bg.kind != .Default}
	}

	prefix_w := string_display_width(prefix)
	// Try full breadcrumb first: "<prefix>n0 -> n1 -> ... -> nk"
	full_path_w: i32 = prefix_w
	for i := 0; i < name_cnt; i += 1 {
		if i > 0 {
			full_path_w += 4 // " -> "
		}
		full_path_w += string_display_width(names[i])
	}

	spans := make([dynamic]Styled_Span, 0, name_cnt * 2 + 2, context.temp_allocator)
	if full_path_w <= max_w {
		if len(prefix) > 0 {
			append(&spans, Styled_Span{text = prefix, fg = sep_fg})
		}
		for i := 0; i < name_cnt; i += 1 {
			if i > 0 {
				append(&spans, Styled_Span{text = " -> ", fg = sep_fg})
			}
			is_last := i == name_cnt - 1
			append(&spans, Styled_Span{
				text  = names[i],
				fg    = active_fg if is_last else fg,
				style = {.Bold} if is_last else {},
			})
		}
	} else {
		// Left-truncate ancestor segments ("… -> col_doing -> card_3") keeping the focused tip intact
		best_start := name_cnt - 1
		for start_idx := 1; start_idx < name_cnt; start_idx += 1 {
			cand_w: i32 = 5 // "… -> "
			for j := start_idx; j < name_cnt; j += 1 {
				if j > start_idx {
					cand_w += 4
				}
				cand_w += string_display_width(names[j])
			}
			if cand_w <= max_w {
				best_start = start_idx
				break
			}
		}

		cand_w: i32 = 5
		for j := best_start; j < name_cnt; j += 1 {
			if j > best_start {
				cand_w += 4
			}
			cand_w += string_display_width(names[j])
		}

		if cand_w <= max_w {
			append(&spans, Styled_Span{text = "… -> ", fg = sep_fg})
			for j := best_start; j < name_cnt; j += 1 {
				if j > best_start {
					append(&spans, Styled_Span{text = " -> ", fg = sep_fg})
				}
				is_last := j == name_cnt - 1
				append(&spans, Styled_Span{
					text  = names[j],
					fg    = active_fg if is_last else fg,
					style = {.Bold} if is_last else {},
				})
			}
		} else {
			tip := names[name_cnt - 1]
			tip_clipped := clip_string_left(tip, max_w)
			append(&spans, Styled_Span{text = tip_clipped, fg = active_fg, style = {.Bold}})
		}
	}

	full_text := concat_spans_temp(spans[:])
	return Paint_Spec{
		text    = full_text,
		spans   = spans[:],
		fg      = fg,
		bg      = cfg.bg,
		fill_bg = cfg.bg.kind != .Default,
	}
}

@(private)
Hint_Item :: struct {
	group:     string,
	compact:   bool,
	key_badge: string,
	desc:      string,
	dimmed:    bool,
}

@(private)
build_key_hints_paint :: proc(
	ctx: ^Layout_Context,
	inp: ^Input_State,
	cfg: Key_Hint_Bar_Config,
	max_w: i32,
) -> Paint_Spec {
	key_fg   := cfg.key_fg   if cfg.key_fg.kind   != .Default else rgb(125, 210, 255)
	desc_fg  := cfg.desc_fg  if cfg.desc_fg.kind  != .Default else rgb(210, 220, 235)
	sep_fg   := cfg.sep_fg   if cfg.sep_fg.kind   != .Default else rgb(95, 110, 130)
	mode_fg  := cfg.mode_fg  if cfg.mode_fg.kind  != .Default else rgb(20, 24, 32)
	mode_bg  := cfg.mode_bg  if cfg.mode_bg.kind  != .Default else rgb(255, 200, 75)
	chord_fg := cfg.chord_fg if cfg.chord_fg.kind != .Default else rgb(20, 24, 32)
	chord_bg := cfg.chord_bg if cfg.chord_bg.kind != .Default else rgb(115, 235, 175)
	dim_fg   := cfg.dim_fg   if cfg.dim_fg.kind   != .Default else rgb(115, 125, 140)

	if max_w <= 0 {
		return Paint_Spec{bg = cfg.bg, fill_bg = cfg.bg.kind != .Default}
	}

	mode_badge := ""
	badge_fg := mode_fg
	badge_bg := mode_bg

	items: [MAX_ACTION_SPECS]Hint_Item
	item_cnt := 0

	capture_idx := find_topmost_capture_node(ctx)

	if inp.pending_chord.active {
		if inp.keymap_style == .Emacs && inp.emacs_universal_arg && inp.repeat_count > 0 {
			mode_badge = fmt.tprintf("[C-u: %dx] [CHORD: %s…] ", inp.repeat_count, pending_chord_prefix(inp))
		} else if inp.repeat_count > 0 {
			mode_badge = fmt.tprintf("[COUNT: %dx] [CHORD: %s…] ", inp.repeat_count, pending_chord_prefix(inp))
		} else if inp.keymap_style == .Helix && inp.suffix_count > 0 {
			mode_badge = fmt.tprintf("[SUFFIX: %dx] [CHORD: %s…] ", inp.suffix_count, pending_chord_prefix(inp))
		} else {
			mode_badge = fmt.tprintf("[CHORD: %s…] ", pending_chord_prefix(inp))
		}
		badge_fg = chord_fg
		badge_bg = chord_bg
		item_cnt = collect_pending_chord_hint_items(ctx, inp, capture_idx, &items)
	} else {
		splitter_resizing := false
		if inp.focused_id != 0 {
			if f_idx, ok := ctx.id_map[inp.focused_id]; ok && ctx.nodes[f_idx].config.splitter {
				if get_scope_submode_by_hash(inp, inp.focused_id) == u8(Splitter_Submode.Resize) {
					splitter_resizing = true
				}
			}
		}

		if splitter_resizing {
			if inp.keymap_style == .Helix && inp.suffix_count > 0 {
				mode_badge = fmt.tprintf("[RESIZE %dx] ", inp.suffix_count)
			} else {
				mode_badge = "[RESIZE] "
			}
			slot := get_splitter_slot(inp, inp.focused_id)
			items[item_cnt] = Hint_Item{key_badge = "h/l" if slot.dir == .Row else "j/k", desc = "Resize"}
			item_cnt += 1
			items[item_cnt] = Hint_Item{key_badge = "=", desc = "Reset"}
			item_cnt += 1
			items[item_cnt] = Hint_Item{key_badge = "Enter/Esc", desc = "Done"}
			item_cnt += 1
		} else if inp.editing_id != 0 {
			mode_badge = "[EDIT] "
			if e_idx, ok := ctx.id_map[inp.editing_id]; ok && (.Auto_Edit not_in ctx.nodes[e_idx].focus_flags) {
				items[item_cnt] = Hint_Item{key_badge = "Esc", desc = "Exit Edit"}
				item_cnt += 1
			}
		} else if inp.keymap_style == .Emacs && inp.emacs_universal_arg && inp.repeat_count > 0 {
			mode_badge = fmt.tprintf("[C-u: %dx] ", inp.repeat_count)
		} else if inp.repeat_count > 0 {
			mode_badge = fmt.tprintf("[COUNT: %dx] ", inp.repeat_count)
		} else if inp.keymap_style == .Helix && inp.suffix_count > 0 {
			mode_badge = fmt.tprintf("[SUFFIX: %dx] ", inp.suffix_count)
		}

		if !splitter_resizing {
			item_cnt = collect_contextual_hint_items(ctx, inp, capture_idx, &items, item_cnt)
		}
	}

	badge_w := string_display_width(mode_badge)
	if badge_w >= max_w {
		clipped_badge := clip_string_right(mode_badge, max_w)
		spans := make([]Styled_Span, 1, context.temp_allocator)
		spans[0] = Styled_Span{text = clipped_badge, fg = badge_fg, bg = badge_bg, style = {.Bold}}
		return Paint_Spec{text = clipped_badge, spans = spans, bg = cfg.bg, fill_bg = cfg.bg.kind != .Default}
	}

	// Measure total width of all items
	total_w := badge_w
	for i := 0; i < item_cnt; i += 1 {
		if i > 0 {
			total_w += 3 // " | "
		}
		total_w += hint_item_display_width(items[i])
	}

	spans := make([dynamic]Styled_Span, 0, item_cnt * 3 + 3, context.temp_allocator)
	if len(mode_badge) > 0 {
		append(&spans, Styled_Span{text = mode_badge, fg = badge_fg, bg = badge_bg, style = {.Bold}})
	}

	if total_w <= max_w {
		for i := 0; i < item_cnt; i += 1 {
			if i > 0 {
				append(&spans, Styled_Span{text = " | ", fg = sep_fg})
			}
			append_hint_item_spans(&spans, items[i], key_fg, desc_fg, dim_fg)
		}
	} else {
		// Fit as many complete items as possible inside `max_w - 4` and append `" | …"`
		suffix := " | …"
		suffix_w: i32 = 4
		avail := max_w - badge_w - suffix_w
		used: i32 = 0
		included := 0

		for i := 0; i < item_cnt; i += 1 {
			iw := hint_item_display_width(items[i])
			sep := i32(3) if included > 0 else i32(0)
			if used + sep + iw <= avail {
				if included > 0 {
					append(&spans, Styled_Span{text = " | ", fg = sep_fg})
				}
				append_hint_item_spans(&spans, items[i], key_fg, desc_fg, dim_fg)
				used += sep + iw
				included += 1
			} else {
				break
			}
		}

		if included > 0 {
			append(&spans, Styled_Span{text = suffix, fg = sep_fg})
		} else if max_w - badge_w >= 4 && item_cnt > 0 {
			first_str := fmt.tprintf("%s: %s", items[0].key_badge, items[0].desc)
			clipped := clip_string_right(first_str, max_w - badge_w - suffix_w)
			append(&spans, Styled_Span{text = clipped, fg = key_fg})
			append(&spans, Styled_Span{text = suffix, fg = sep_fg})
		} else if max_w - badge_w >= 1 {
			append(&spans, Styled_Span{text = "…", fg = sep_fg})
		}
	}

	full_text := concat_spans_temp(spans[:])
	return Paint_Spec{
		text    = full_text,
		spans   = spans[:],
		fg      = desc_fg,
		bg      = cfg.bg,
		fill_bg = cfg.bg.kind != .Default,
	}
}

@(private)
collect_pending_chord_hint_items :: proc(
	ctx: ^Layout_Context,
	inp: ^Input_State,
	capture_idx: i32,
	items: ^[MAX_ACTION_SPECS]Hint_Item,
) -> int {
	cnt := 0
	first_key := inp.pending_chord.first_key
	seen_k2: [MAX_ACTION_SPECS]Key_Event
	seen_cnt := 0

	for i := 0; i < inp.keybinding_count && cnt + 1 < MAX_ACTION_SPECS; i += 1 {
		kb := inp.keybindings[i]
		if kb.chord_len != 2 || !key_events_match(kb.key, first_key) {
			continue
		}
		if !is_binding_currently_active(ctx, inp, capture_idx, kb) {
			continue
		}
		already := false
		for s := 0; s < seen_cnt; s += 1 {
			if key_events_match(seen_k2[s], kb.key2) {
				already = true
				break
			}
		}
		if already {
			continue
		}
		desc := kb.action_name
		dimmed := false
		if kb.spec_idx > 0 && int(kb.spec_idx - 1) < inp.action_spec_cnt {
			spec := inp.action_specs[kb.spec_idx - 1]
			avail := resolve_spec_availability(inp, spec)
			if avail == .Hidden {
				continue
			}
			dimmed = avail == .Disabled_Dimmed
			if len(spec.desc) > 0 {
				desc = spec.desc
			} else if len(spec.label) > 0 {
				desc = spec.label
			}
		}
		if seen_cnt < MAX_ACTION_SPECS {
			seen_k2[seen_cnt] = kb.key2
			seen_cnt += 1
		}
		items[cnt] = Hint_Item{
			key_badge = format_key_event(kb.key2),
			desc      = desc,
			dimmed    = dimmed,
		}
		cnt += 1
	}

	if cnt < MAX_ACTION_SPECS {
		items[cnt] = Hint_Item{key_badge = "Esc", desc = "Cancel"}
		cnt += 1
	}
	return cnt
}

@(private)
is_binding_currently_active :: proc "contextless" (
	ctx: ^Layout_Context,
	inp: ^Input_State,
	capture_idx: i32,
	kb: Keybinding,
) -> bool {
	switch kb.policy {
	case .Global_Always:
		return true
	case .Root_And_Scopes:
		if capture_idx >= 0 {
			return false
		}
		if kb.has_submode_filter && get_scope_submode_by_hash(inp, 0) != kb.required_submode {
			return false
		}
		return true
	case .Scope_Only:
		for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
			n_idx := inp.focus_node_path[p]
			if n_idx >= 0 && int(n_idx) < len(ctx.nodes) && is_node_allowed(ctx, n_idx, capture_idx) {
				if binding_matches_scope_node(inp, ctx, n_idx, kb) {
					return true
				}
				if .Trap_Focus in ctx.nodes[n_idx].focus_flags {
					break
				}
			}
		}
		return false
	}
	return false
}

@(private)
collect_contextual_hint_items :: proc(
	ctx: ^Layout_Context,
	inp: ^Input_State,
	capture_idx: i32,
	items: ^[MAX_ACTION_SPECS]Hint_Item,
	initial_cnt: int,
) -> int {
	cnt := initial_cnt
	seen_seqs: [MAX_KEYBINDINGS]Chord_Sequence
	seen_seq_cnt := 0
	seen_actions: [MAX_ACTION_SPECS]u64
	seen_act_cnt := 0
	editing := inp.editing_id != 0

	// Tier 1: Innermost-first Scope_Only specs along focus_node_path (halting at Trap_Focus)
	for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
		n_idx := inp.focus_node_path[p]
		if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
			continue
		}
		node := ctx.nodes[n_idx]
		if is_node_allowed(ctx, n_idx, capture_idx) {
			for s_idx := 0; s_idx < inp.action_spec_cnt; s_idx += 1 {
				spec := inp.action_specs[s_idx]
				if spec.policy != .Scope_Only || len(spec.scope) == 0 {
					continue
				}
				if !spec_matches_node_scope(inp, node, spec) {
					continue
				}
				cnt = try_append_spec_hint(inp, spec, editing, items, cnt, &seen_seqs, &seen_seq_cnt, &seen_actions, &seen_act_cnt)
			}
		}
		if .Trap_Focus in node.focus_flags {
			break
		}
	}

	// Tier 2: Root_And_Scopes
	if capture_idx < 0 {
		for s_idx := 0; s_idx < inp.action_spec_cnt; s_idx += 1 {
			spec := inp.action_specs[s_idx]
			if spec.policy != .Root_And_Scopes {
				continue
			}
			if spec.has_submode && get_scope_submode_by_hash(inp, 0) != spec.submode {
				continue
			}
			cnt = try_append_spec_hint(inp, spec, editing, items, cnt, &seen_seqs, &seen_seq_cnt, &seen_actions, &seen_act_cnt)
		}
	}

	// Tier 3: Global_Always
	for s_idx := 0; s_idx < inp.action_spec_cnt; s_idx += 1 {
		spec := inp.action_specs[s_idx]
		if spec.policy != .Global_Always {
			continue
		}
		cnt = try_append_spec_hint(inp, spec, editing, items, cnt, &seen_seqs, &seen_seq_cnt, &seen_actions, &seen_act_cnt)
	}

	return cnt
}

@(private)
spec_matches_node_scope :: proc "contextless" (inp: ^Input_State, node: Layout_Node, spec: Action_Spec) -> bool {
	matched := false
	if len(spec.scope) > 0 && spec.scope[len(spec.scope) - 1] == '*' {
		matched = str_has_prefix(node.id, spec.scope[:len(spec.scope) - 1])
	} else {
		matched = (node.id == spec.scope) || (len(spec.scope) > 0 && node.id_hash == hash_local_id(0, spec.scope))
	}
	if !matched {
		return false
	}
	if spec.has_submode {
		return get_scope_submode_by_hash(inp, node.id_hash) == spec.submode
	}
	return true
}

@(private)
try_append_spec_hint :: proc(
	inp: ^Input_State,
	spec: Action_Spec,
	editing: bool,
	items: ^[MAX_ACTION_SPECS]Hint_Item,
	cur_cnt: int,
	seen_seqs: ^[MAX_KEYBINDINGS]Chord_Sequence,
	seen_seq_cnt: ^int,
	seen_actions: ^[MAX_ACTION_SPECS]u64,
	seen_act_cnt: ^int,
) -> int {
	cnt := cur_cnt
	if !spec.show_in_bar || len(spec.chord_spec) == 0 {
		return cnt
	}
	avail := resolve_spec_availability(inp, spec)
	if avail == .Hidden {
		return cnt
	}

	for i := 0; i < seen_act_cnt^; i += 1 {
		if seen_actions[i] == spec.action_id {
			return cnt
		}
	}

	chord, ok := parse_key_chord(spec.chord_spec)
	if !ok || chord.alt_count == 0 {
		return cnt
	}
	primary := chord.alts[0]

	if editing && (.Allow_In_Text_Input not_in spec.flags) {
		k0 := primary.steps[0]
		eff_mods := k0.mods - {.Caps_Lock, .Num_Lock}
		if (.Ctrl not_in eff_mods) && (k0.code == .Rune || k0.code == .Space || k0.code == .Backspace || k0.code == .Delete || k0.code == .Left || k0.code == .Right || k0.code == .Home || k0.code == .End) {
			return cnt
		}
	}

	// Drop shadowed lower-priority binding if primary chord sequence was already claimed
	for i := 0; i < seen_seq_cnt^; i += 1 {
		if chord_sequences_equal(seen_seqs[i], primary) {
			return cnt
		}
	}

	for a: u8 = 0; a < chord.alt_count && seen_seq_cnt^ < MAX_KEYBINDINGS; a += 1 {
		seen_seqs[seen_seq_cnt^] = chord.alts[a]
		seen_seq_cnt^ += 1
	}
	if seen_act_cnt^ < MAX_ACTION_SPECS {
		seen_actions[seen_act_cnt^] = spec.action_id
		seen_act_cnt^ += 1
	}

	k_badge := format_chord_sequence(primary)
	dimmed := avail == .Disabled_Dimmed

	if len(spec.group) > 0 {
		for i := 0; i < cnt; i += 1 {
			if items[i].group == spec.group {
				sep := "" if (items[i].compact || spec.compact) else "/"
				items[i].key_badge = fmt.tprintf("%s%s%s", items[i].key_badge, sep, k_badge)
				if len(spec.group_desc) > 0 {
					items[i].desc = spec.group_desc
				}
				items[i].dimmed = items[i].dimmed && dimmed
				return cnt
			}
		}
		if cnt < MAX_ACTION_SPECS {
			grp_desc := spec.group_desc if len(spec.group_desc) > 0 else spec.desc
			items[cnt] = Hint_Item{
				group     = spec.group,
				compact   = spec.compact,
				key_badge = k_badge,
				desc      = grp_desc,
				dimmed    = dimmed,
			}
			cnt += 1
		}
		return cnt
	}

	if cnt < MAX_ACTION_SPECS {
		desc := spec.desc if len(spec.desc) > 0 else spec.label
		items[cnt] = Hint_Item{
			key_badge = k_badge,
			desc      = desc,
			dimmed    = dimmed,
		}
		cnt += 1
	}
	return cnt
}

@(private)
chord_sequences_equal :: proc "contextless" (a, b: Chord_Sequence) -> bool {
	if a.len != b.len {
		return false
	}
	if !key_events_match(a.steps[0], b.steps[0]) {
		return false
	}
	if a.len == 2 && !key_events_match(a.steps[1], b.steps[1]) {
		return false
	}
	return true
}

@(private)
format_chord_sequence :: proc(seq: Chord_Sequence) -> string {
	if seq.len == 2 {
		return fmt.tprintf("%s %s", format_key_event(seq.steps[0]), format_key_event(seq.steps[1]))
	}
	return format_key_event(seq.steps[0])
}

@(private)
hint_item_display_width :: proc "contextless" (item: Hint_Item) -> i32 {
	return string_display_width(item.key_badge) + 2 + string_display_width(item.desc)
}

@(private)
append_hint_item_spans :: proc(
	spans: ^[dynamic]Styled_Span,
	item: Hint_Item,
	key_fg, desc_fg, dim_fg: Color,
) {
	if item.dimmed {
		append(spans, Styled_Span{
			text  = fmt.tprintf("%s: %s", item.key_badge, item.desc),
			fg    = dim_fg,
			style = {.Dim},
		})
	} else {
		append(spans, Styled_Span{
			text  = item.key_badge,
			fg    = key_fg,
			style = {.Bold},
		})
		append(spans, Styled_Span{
			text = fmt.tprintf(": %s", item.desc),
			fg   = desc_fg,
		})
	}
}

@(private)
concat_spans_temp :: proc(spans: []Styled_Span) -> string {
	total_bytes := 0
	for sp in spans {
		total_bytes += len(sp.text)
	}
	if total_bytes == 0 {
		return ""
	}
	buf := make([]u8, total_bytes, context.temp_allocator)
	off := 0
	for sp in spans {
		copy(buf[off:], sp.text)
		off += len(sp.text)
	}
	return string(buf)
}

@(private)
clip_string_right :: proc(s: string, max_cols: i32) -> string {
	if max_cols <= 0 || len(s) == 0 {
		return ""
	}
	used: i32 = 0
	idx := 0
	for idx < len(s) {
		next_idx, w, _ := next_grapheme_cluster(s, idx)
		if used + w > max_cols {
			break
		}
		used += w
		idx = next_idx
	}
	return s[:idx]
}

@(private)
clip_string_left :: proc(s: string, max_cols: i32) -> string {
	if max_cols <= 0 || len(s) == 0 {
		return ""
	}
	if string_display_width(s) <= max_cols {
		return s
	}
	if max_cols == 1 {
		return "…"
	}
	target := max_cols - 1
	idx := len(s)
	used: i32 = 0
	for idx > 0 {
		prev_idx := prev_grapheme_cluster(s, idx)
		_, w, _ := next_grapheme_cluster(s, prev_idx)
		if used + w > target {
			break
		}
		used += w
		idx = prev_idx
	}
	return fmt.tprintf("…%s", s[idx:])
}

// =============================================================================
// Floating "Which-Key" Prefix Continuation Overlay Card
// =============================================================================

Which_Key_Config :: struct {
	title:     string,
	z_layer:   u8,
	width:     i32,
	bg:        Color,
	border_fg: Color,
	key_fg:    Color,
	desc_fg:   Color,
}

// Renders a floating non-capturing card when `inp.pending_chord.active == true`,
// listing all valid second-step continuations for the currently latched prefix key.
ui_which_key_overlay :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string = "__which_key_overlay__",
	cfg: Which_Key_Config = {},
) -> bool {
	if inp == nil || !inp.pending_chord.active {
		return false
	}

	items: [MAX_ACTION_SPECS]Hint_Item
	capture_idx := find_topmost_capture_node(ctx)
	cnt := collect_pending_chord_hint_items(ctx, inp, capture_idx, &items)
	if cnt == 0 {
		return false
	}

	card_w := cfg.width if cfg.width > 0 else 38
	card_h := i32(cnt) + 2
	z := cfg.z_layer if cfg.z_layer > 0 else 28
	bg := cfg.bg if cfg.bg.kind != .Default else rgb(22, 26, 36)
	border_fg := cfg.border_fg if cfg.border_fg.kind != .Default else rgb(115, 235, 175)
	key_fg := cfg.key_fg if cfg.key_fg.kind != .Default else rgb(125, 210, 255)
	desc_fg := cfg.desc_fg if cfg.desc_fg.kind != .Default else rgb(220, 228, 240)
	title := cfg.title if len(cfg.title) > 0 else fmt.tprintf(" Prefix: %s… ", pending_chord_prefix(inp))

	id_h := hash_id(id)
	s.paints[id_h] = Paint_Spec{
		title       = title,
		fg          = desc_fg,
		bg          = bg,
		border_fg   = border_fg,
		title_fg    = border_fg,
		title_style = {.Bold},
		fill_bg     = true,
	}

	if container(ctx, id, Box_Config{
		dir        = .Column,
		width      = fixed(card_w),
		height     = fixed(card_h),
		border     = .Rounded,
		floating   = true,
		z_layer    = z,
		anchor     = .Screen,
		self_align = {.End, .End},
		offset     = {-2, -2},
	}) {
		for i := 0; i < cnt; i += 1 {
			it := items[i]
			row_id := fmt.tprintf("%s_row_%d", id, i)
			line := fmt.tprintf(" %-8s  %s", it.key_badge, it.desc)
			row_fg := key_fg if !it.dimmed else rgb(115, 125, 140)
			row_style := Style_Flags{.Bold} if !it.dimmed else Style_Flags{.Dim}
			_ = leaf(ctx, row_id, card_w - 2, 1, Box_Config{
				width  = grow(1),
				height = fixed(1),
				text   = line,
			})
			set_paint(s, row_id, Paint_Spec{
				text    = line,
				fg      = row_fg,
				bg      = bg,
				style   = row_style,
				fill_bg = true,
			})
		}
	}
	return true
}


