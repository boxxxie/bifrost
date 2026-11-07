package bifrost

// =============================================================================
// Integer-Only 2D Spatial Navigation, Wrapping & Same-Frame Scroll-Into-View
// =============================================================================

key_to_nav_dir :: proc "contextless" (
	ev: Key_Event,
	text_editing: bool,
	style: Keymap_Style = .Vim,
) -> (dir: Nav_Dir, ok: bool) {
	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	if eff_mods == {.Ctrl} && ev.code == .Rune {
		switch ev.ch {
		case 'n', 'N', 'j', 'J':
			return .Down, true
		case 'p', 'P', 'k', 'K':
			return .Up, true
		case 'f', 'F':
			if style == .Emacs && !text_editing {
				return .Right, true
			}
		case 'b', 'B':
			if style == .Emacs && !text_editing {
				return .Left, true
			}
		}
		return .Down, false
	}
	if eff_mods != {} {
		return .Down, false
	}
	#partial switch ev.code {
	case .Up:
		return .Up, true
	case .Down:
		return .Down, true
	case .Left:
		if !text_editing {
			return .Left, true
		}
	case .Right:
		if !text_editing {
			return .Right, true
		}
	case .Rune:
		if !text_editing && style != .Emacs {
			switch ev.ch {
			case 'h':
				return .Left, true
			case 'j':
				return .Down, true
			case 'k':
				return .Up, true
			case 'l':
				return .Right, true
			}
		}
	}
	return .Down, false
}

key_to_page_cmd :: proc "contextless" (
	ev: Key_Event,
	text_editing: bool,
	style: Keymap_Style = .Vim,
) -> (cmd: Page_Cmd, ok: bool) {
	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	if !text_editing && ev.code == .Rune {
		if style == .Emacs {
			if eff_mods == {.Ctrl} && (ev.ch == 'v' || ev.ch == 'V') {
				return .Page_Down, true
			}
			if eff_mods == {.Alt} && (ev.ch == 'v' || ev.ch == 'V') {
				return .Page_Up, true
			}
			if eff_mods == {.Ctrl} && (ev.ch == 'a' || ev.ch == 'A') {
				return .Home, true
			}
			if eff_mods == {.Ctrl} && (ev.ch == 'e' || ev.ch == 'E') {
				return .End, true
			}
		} else {
			if eff_mods == {.Ctrl} && (ev.ch == 'd' || ev.ch == 'D') {
				return .Half_Page_Down, true
			}
			if eff_mods == {.Ctrl} && (ev.ch == 'u' || ev.ch == 'U') {
				return .Half_Page_Up, true
			}
			if eff_mods == {} && ev.ch == 'G' {
				return .End, true
			}
		}
	}
	if eff_mods != {} {
		return .Page_Down, false
	}
	#partial switch ev.code {
	case .Page_Up:
		return .Page_Up, true
	case .Page_Down:
		return .Page_Down, true
	case .Home:
		if !text_editing {
			return .Home, true
		}
	case .End:
		if !text_editing {
			return .End, true
		}
	}
	return .Page_Down, false
}

// Computes edge-to-edge gap and overlap between two 1D half-open intervals [a_min, a_max) and [b_min, b_max).
interval_metrics :: proc "contextless" (a_min, a_max, b_min, b_max: int) -> (gap: int, overlap: int) {
	over_min := max(a_min, b_min)
	over_max := min(a_max, b_max)
	if over_max > over_min {
		return 0, over_max - over_min
	}
	if a_max <= b_min {
		return b_min - a_max, 0
	}
	return a_min - b_max, 0
}

// Scores `cand` relative to `origin` in direction `dir` using integer-only orthogonal lane metrics.
// In-lane candidates (`overlap > 0`) always beat out-of-lane candidates (`OUT_OF_LANE_PENALTY`).
// When `preferred_ortho >= 0`, orthogonal center tie-breaking biases toward `preferred_ortho` (`ImGui NavBiasScoringRect`).
score_spatial_candidate :: proc "contextless" (
	origin, cand: Rect,
	dir: Nav_Dir,
	preferred_ortho: i32 = -1,
) -> (score: int, valid: bool) {
	if cand.w <= 0 || cand.h <= 0 {
		return 0, false
	}

	o_min_p, o_max_p, c_min_p, c_max_p: int
	o_min_s, o_max_s, c_min_s, c_max_s: int

	switch dir {
	case .Left, .Right:
		o_min_p, o_max_p = int(origin.x), int(origin.x + origin.w)
		c_min_p, c_max_p = int(cand.x), int(cand.x + cand.w)
		o_min_s, o_max_s = int(origin.y), int(origin.y + origin.h)
		c_min_s, c_max_s = int(cand.y), int(cand.y + cand.h)
	case .Up, .Down:
		o_min_p, o_max_p = int(origin.y), int(origin.y + origin.h)
		c_min_p, c_max_p = int(cand.y), int(cand.y + cand.h)
		o_min_s, o_max_s = int(origin.x), int(origin.x + origin.w)
		c_min_s, c_max_s = int(cand.x), int(cand.x + cand.w)
	}

	o_center2_p := o_min_p + o_max_p
	c_center2_p := c_min_p + c_max_p

	major_dist: int
	switch dir {
	case .Right, .Down:
		if c_center2_p <= o_center2_p || c_min_p < o_min_p {
			return 0, false
		}
		major_dist = max(0, c_min_p - o_max_p)
	case .Left, .Up:
		if c_center2_p >= o_center2_p || c_max_p > o_max_p {
			return 0, false
		}
		major_dist = max(0, o_min_p - c_max_p)
	}

	minor_gap, overlap := interval_metrics(o_min_s, o_max_s, c_min_s, c_max_s)
	ref_center2_s := o_min_s + o_max_s
	if preferred_ortho >= 0 {
		clamped_pref := clamp(int(preferred_ortho), o_min_s, max(o_min_s, o_max_s - 1))
		ref_center2_s = clamped_pref * 2 + 1
	}
	center2_diff_s := abs(ref_center2_s - (c_min_s + c_max_s))

	if overlap > 0 {
		return major_dist * 1024 + center2_diff_s, true
	}

	if minor_gap > major_dist * 2 + 4 {
		return 0, false
	}
	return OUT_OF_LANE_PENALTY + major_dist * 1024 + minor_gap * 2048 + center2_diff_s, true
}

@(private)
is_spatial_candidate_eligible :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	scope_idx: i32,
	cand_idx: i32,
) -> bool {
	if cand_idx < 0 || int(cand_idx) >= len(ctx.nodes) {
		return false
	}
	cand := ctx.nodes[cand_idx]
	if cand.parent_scope_idx != scope_idx || (.Disabled in cand.focus_flags) || !is_node_allowed(ctx, cand_idx, capture_idx) {
		return false
	}
	if is_node_focusable(cand) {
		return true
	}
	if (.Focus_Scope in cand.focus_flags) && (.Trap_Focus not_in cand.focus_flags) {
		return resolve_scope_target(inp, ctx, cand_idx, capture_idx, true) >= 0
	}
	return false
}

find_spatial_neighbor :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	origin_idx: i32,
	dir: Nav_Dir,
	preferred_ortho: i32 = -1,
) -> (best_idx: i32, found: bool) {
	if origin_idx < 0 || int(origin_idx) >= len(ctx.nodes) {
		return -1, false
	}
	origin := ctx.nodes[origin_idx]
	scope_idx := origin.parent_scope_idx

	// 0. Explicit directional focus override (`nav_overrides[dir]`) takes precedence over geometry
	override_hash := origin.config.nav_overrides[dir]
	if override_hash != 0 {
		if ov_idx, ok := ctx.id_map[override_hash]; ok && ov_idx != origin_idx {
			ov_node := ctx.nodes[ov_idx]
			if (.Disabled not_in ov_node.focus_flags) && is_node_allowed(ctx, ov_idx, capture_idx) {
				if is_node_focusable(ov_node) || ((.Focus_Scope in ov_node.focus_flags) && resolve_scope_target(inp, ctx, ov_idx, capture_idx, true) >= 0) {
					return ov_idx, true
				}
			}
		}
	}

	s_start := i32(0)
	s_end   := i32(len(ctx.nodes))
	if scope_idx >= 0 && int(scope_idx) < len(ctx.nodes) {
		s_start = scope_idx + 1
		s_end   = min(ctx.nodes[scope_idx].subtree_end_idx, i32(len(ctx.nodes)))
	}

	best_score := max(int)
	best_idx = -1

	for i := s_start; i < s_end; i += 1 {
		if i == origin_idx || !is_spatial_candidate_eligible(inp, ctx, capture_idx, scope_idx, i) {
			continue
		}
		if score, ok := score_spatial_candidate(origin.rect, ctx.nodes[i].rect, dir, preferred_ortho); ok {
			if score < best_score {
				best_score = score
				best_idx   = i
			}
		}
	}

	if best_idx >= 0 {
		return best_idx, true
	}

	if scope_idx >= 0 && int(scope_idx) < len(ctx.nodes) {
		s_flags := ctx.nodes[scope_idx].focus_flags
		if .Wrap_Spatial in s_flags {
			return find_wrapped_neighbor(inp, ctx, capture_idx, origin_idx, scope_idx, dir)
		}
		if .Loop_Spatial in s_flags {
			return find_looped_neighbor(inp, ctx, capture_idx, origin_idx, scope_idx, dir, preferred_ortho)
		}
	}

	return -1, false
}

// Same-lane ring wrap (`.Loop_Spatial`): mirrors `origin` outside the sibling envelope along `dir`
// and selects the closest in-lane candidate (`score < OUT_OF_LANE_PENALTY`).
find_looped_neighbor :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	origin_idx: i32,
	scope_idx: i32,
	dir: Nav_Dir,
	preferred_ortho: i32 = -1,
) -> (best_idx: i32, found: bool) {
	origin := ctx.nodes[origin_idx].rect
	s_end := min(ctx.nodes[scope_idx].subtree_end_idx, i32(len(ctx.nodes)))

	min_x := origin.x
	min_y := origin.y
	max_x2 := origin.x + origin.w
	max_y2 := origin.y + origin.h
	cand_count := 0

	for i := scope_idx + 1; i < s_end; i += 1 {
		if !is_spatial_candidate_eligible(inp, ctx, capture_idx, scope_idx, i) {
			continue
		}
		r := ctx.nodes[i].rect
		if r.w <= 0 || r.h <= 0 {
			continue
		}
		min_x  = min(min_x, r.x)
		min_y  = min(min_y, r.y)
		max_x2 = max(max_x2, r.x + r.w)
		max_y2 = max(max_y2, r.y + r.h)
		cand_count += 1
	}

	if cand_count <= 1 {
		return -1, false
	}

	virtual_origin := origin
	switch dir {
	case .Down:
		virtual_origin.y = min_y - origin.h - 1
	case .Up:
		virtual_origin.y = max_y2 + 1
	case .Right:
		virtual_origin.x = min_x - origin.w - 1
	case .Left:
		virtual_origin.x = max_x2 + 1
	}

	best_score := OUT_OF_LANE_PENALTY
	best_idx = -1
	for i := scope_idx + 1; i < s_end; i += 1 {
		if i == origin_idx || !is_spatial_candidate_eligible(inp, ctx, capture_idx, scope_idx, i) {
			continue
		}
		if score, ok := score_spatial_candidate(virtual_origin, ctx.nodes[i].rect, dir, preferred_ortho); ok {
			if score < best_score {
				best_score = score
				best_idx   = i
			}
		}
	}
	return best_idx, best_idx >= 0
}

@(private)
reading_order_less :: proc "contextless" (a, b: Rect, horizontal: bool) -> bool {
	if horizontal {
		_, y_overlap := interval_metrics(int(a.y), int(a.y + a.h), int(b.y), int(b.y + b.h))
		if y_overlap == 0 && a.y != b.y {
			return a.y < b.y
		}
		if a.x != b.x {
			return a.x < b.x
		}
		return a.y < b.y
	}
	_, x_overlap := interval_metrics(int(a.x), int(a.x + a.w), int(b.x), int(b.x + b.w))
	if x_overlap == 0 && a.x != b.x {
		return a.x < b.x
	}
	if a.y != b.y {
		return a.y < b.y
	}
	return a.x < b.x
}

// Reading-order 2D grid wrap (`.Wrap_Spatial`): advances to the next/previous row on `.Right`/`.Left`
// when multiple columns exist, and next/previous column (or top/bottom) on `.Down`/`.Up` when multiple rows exist.
find_wrapped_neighbor :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	origin_idx: i32,
	scope_idx: i32,
	dir: Nav_Dir,
) -> (best_idx: i32, found: bool) {
	origin := ctx.nodes[origin_idx].rect
	s_end := min(ctx.nodes[scope_idx].subtree_end_idx, i32(len(ctx.nodes)))
	horizontal := dir == .Left || dir == .Right
	forward    := dir == .Right || dir == .Down

	has_axis_spread := false
	for i := scope_idx + 1; i < s_end; i += 1 {
		if i == origin_idx || !is_spatial_candidate_eligible(inp, ctx, capture_idx, scope_idx, i) {
			continue
		}
		r := ctx.nodes[i].rect
		if horizontal {
			_, x_over := interval_metrics(int(origin.x), int(origin.x + origin.w), int(r.x), int(r.x + r.w))
			if x_over == 0 {
				has_axis_spread = true
				break
			}
		} else {
			_, y_over := interval_metrics(int(origin.y), int(origin.y + origin.h), int(r.y), int(r.y + r.h))
			if y_over == 0 {
				has_axis_spread = true
				break
			}
		}
	}

	if !has_axis_spread {
		return -1, false
	}

	next_after  := i32(-1)
	first_total := i32(-1)
	prev_before := i32(-1)
	last_total  := i32(-1)

	for i := scope_idx + 1; i < s_end; i += 1 {
		if !is_spatial_candidate_eligible(inp, ctx, capture_idx, scope_idx, i) {
			continue
		}
		r := ctx.nodes[i].rect
		if r.w <= 0 || r.h <= 0 {
			continue
		}

		if first_total < 0 || reading_order_less(r, ctx.nodes[first_total].rect, horizontal) {
			first_total = i
		}
		if last_total < 0 || reading_order_less(ctx.nodes[last_total].rect, r, horizontal) {
			last_total = i
		}
		if i == origin_idx {
			continue
		}
		if reading_order_less(origin, r, horizontal) {
			if next_after < 0 || reading_order_less(r, ctx.nodes[next_after].rect, horizontal) {
				next_after = i
			}
		} else if reading_order_less(r, origin, horizontal) {
			if prev_before < 0 || reading_order_less(ctx.nodes[prev_before].rect, r, horizontal) {
				prev_before = i
			}
		}
	}

	if forward {
		if next_after >= 0 {
			return next_after, true
		}
		if first_total >= 0 && first_total != origin_idx {
			return first_total, true
		}
	} else {
		if prev_before >= 0 {
			return prev_before, true
		}
		if last_total >= 0 && last_total != origin_idx {
			return last_total, true
		}
	}
	return -1, false
}

handle_spatial_nav_at_level :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	path_level: int,
	dir: Nav_Dir,
) -> Key_Result {
	node_idx := inp.focus_node_path[path_level]
	if node_idx < 0 || int(node_idx) >= len(ctx.nodes) {
		return .Ignored
	}
	node := &ctx.nodes[node_idx]
	is_tip := path_level == inp.focus_node_path_len - 1
	count := clamp(inp.repeat_count, 1, 9999) if inp.repeat_count > 0 else i32(1)

	// 1. O(1) Virtualized List / 2D Virtual Table / Collapsible Tree (`virtual_total_rows > 0`) cursor stepping
	if node.config.virtual_total_rows > 0 && is_node_allowed(ctx, node_idx, capture_idx) {
		slot := get_scroll_slot(inp, node.id_hash)
		if t_slot := find_tree_slot(inp, node.id_hash); t_slot != nil {
			if handled, res := handle_tree_spatial_nav(inp, ctx, node_idx, t_slot, slot, dir, count); handled {
				return res
			}
		}
		switch dir {
		case .Up, .Down:
			delta: i32 = (-1 if dir == .Up else +1) * count
			if (dir == .Down && slot.selected_row < slot.total_rows - 1) || (dir == .Up && slot.selected_row > 0) {
				_ = consume_repeat_count(inp)
				move_virtual_selection(slot, delta)
				node.config.scroll_offset = slot.offset
				inp.scrolled_id = node.id_hash
				return .Consumed
			}
			if slot.total_rows > 1 && ((.Loop_Spatial in node.focus_flags) || (.Wrap_Spatial in node.focus_flags)) {
				wrapped := slot.total_rows - 1 if dir == .Up else 0
				_ = consume_repeat_count(inp)
				move_virtual_selection(slot, wrapped - slot.selected_row)
				node.config.scroll_offset = slot.offset
				inp.scrolled_id = node.id_hash
				return .Consumed
			}
			if .Strict_Spatial in node.focus_flags {
				_ = consume_repeat_count(inp)
				return .Consumed
			}
		case .Left, .Right:
			cols := max(1, slot.total_cols)
			if cols > 1 {
				delta_col: i32 = (-1 if dir == .Left else +1) * count
				next_col := slot.selected_col + delta_col
				if (dir == .Right && slot.selected_col < cols - 1) || (dir == .Left && slot.selected_col > 0) {
					_ = consume_repeat_count(inp)
					slot.selected_col = clamp(next_col, 0, cols - 1)
					return .Consumed
				}
				if .Loop_Spatial in node.focus_flags {
					_ = consume_repeat_count(inp)
					slot.selected_col = ((next_col % cols) + cols) % cols
					return .Consumed
				}
				if .Wrap_Spatial in node.focus_flags {
					if dir == .Right && slot.selected_row + 1 < slot.total_rows {
						_ = consume_repeat_count(inp)
						slot.selected_col = 0
						move_virtual_selection(slot, +1)
						node.config.scroll_offset = slot.offset
						inp.scrolled_id = node.id_hash
						return .Consumed
					} else if dir == .Left && slot.selected_row > 0 {
						_ = consume_repeat_count(inp)
						slot.selected_col = cols - 1
						move_virtual_selection(slot, -1)
						node.config.scroll_offset = slot.offset
						inp.scrolled_id = node.id_hash
						return .Consumed
					}
				}
				if .Strict_Spatial in node.focus_flags {
					_ = consume_repeat_count(inp)
					return .Consumed
				}
			}
		}
	}

	// 2. Read-only focusable materialized scroll container (`0` focusable children) line/column scroll
	if is_tip && node.config.scrollable && node.config.virtual_total_rows == 0 {
		if resolve_scope_child_target_idx(inp, ctx, node_idx, capture_idx, false) < 0 {
			slot := get_scroll_slot(inp, node.id_hash)
			if dir == .Up || dir == .Down {
				delta: i32 = (-1 if dir == .Up else +1) * count
				if (delta < 0 && slot.offset > 0) || (delta > 0 && slot.offset < slot.max_offset) {
					_ = consume_repeat_count(inp)
					apply_scroll_delta(inp, ctx, node_idx, delta, false)
					return .Consumed
				}
			} else if dir == .Left || dir == .Right {
				step_x := node.config.scroll_step if node.config.scroll_step > 0 else 4
				delta_x: i32 = (-step_x if dir == .Left else +step_x) * count
				if (delta_x < 0 && slot.offset_x > 0) || (delta_x > 0 && slot.offset_x < slot.max_offset_x) {
					_ = consume_repeat_count(inp)
					apply_scroll_delta_x(inp, ctx, node_idx, delta_x)
					return .Consumed
				}
			}
		}
	}

	// 3. Sticky orthogonal axis memory (`preferred_nav_pos`) on tip spatial transitions
	pref_ortho: i32 = -1
	if is_tip {
		switch dir {
		case .Up, .Down:
			inp.has_preferred_y = false
			if !inp.has_preferred_x {
				inp.preferred_nav_pos[0] = node.rect.x + node.rect.w / 2
				inp.has_preferred_x = true
			}
			pref_ortho = inp.preferred_nav_pos[0]
		case .Left, .Right:
			inp.has_preferred_x = false
			if !inp.has_preferred_y {
				inp.preferred_nav_pos[1] = node.rect.y + node.rect.h / 2
				inp.has_preferred_y = true
			}
			pref_ortho = inp.preferred_nav_pos[1]
		}
	}

	target_idx, found := find_spatial_neighbor(inp, ctx, capture_idx, node_idx, dir, pref_ortho)
	if !found {
		parent_scope := node.parent_scope_idx
		if parent_scope >= 0 && int(parent_scope) < len(ctx.nodes) {
			if .Strict_Spatial in ctx.nodes[parent_scope].focus_flags {
				_ = consume_repeat_count(inp)
				return .Consumed
			}
		}
		return .Ignored
	}
	_ = consume_repeat_count(inp)
	for step := i32(1); step < count; step += 1 {
		next_idx, next_ok := find_spatial_neighbor(inp, ctx, capture_idx, target_idx, dir, pref_ortho)
		if !next_ok {
			break
		}
		target_idx = next_idx
	}

	target := ctx.nodes[target_idx]
	if !is_tip || target.parent_scope_idx != node.parent_scope_idx {
		// Cross-scope transition resets sticky within-scope orthogonal bias
		reset_preferred_nav(inp)
	}

	// Column-to-column / scope-to-scope navigation when already focused directly on a .Focus_Scope container
	if is_tip && (.Focus_Scope in node.focus_flags) && is_node_focusable(target) {
		set_focused_node(inp, ctx, target_idx, capture_idx, false)
		return .Consumed
	}

	// Entering a sibling .Focus_Scope from an inner leaf (or non-focusable scope wrapper) resolves via H* -> H -> Default
	if .Focus_Scope in target.focus_flags {
		resolved := resolve_scope_target(inp, ctx, target_idx, capture_idx, true)
		if resolved >= 0 {
			set_focused_node(inp, ctx, resolved, capture_idx, false)
			return .Consumed
		}
	}

	set_focused_node(inp, ctx, target_idx, capture_idx, false)
	return .Consumed
}


@(private)
resolve_paging_metrics :: proc "contextless" (ctx: ^Layout_Context, origin_idx: i32) -> (vertical: bool, step: i32) {
	curr := origin_idx
	for curr >= 0 && int(curr) < len(ctx.nodes) {
		n := ctx.nodes[curr]
		if n.config.scrollable {
			if n.config.dir == .Row {
				return false, max(1, n.inner_rect.w - 1)
			}
			return true, max(1, n.inner_rect.h - 1)
		}
		if n.out_of_flow {
			break
		}
		curr = n.parent_idx
	}
	scope_idx := ctx.nodes[origin_idx].parent_scope_idx
	if scope_idx >= 0 && int(scope_idx) < len(ctx.nodes) {
		s_node := ctx.nodes[scope_idx]
		if s_node.config.dir == .Row {
			return false, max(1, s_node.inner_rect.w - 1)
		}
		return true, max(1, s_node.inner_rect.h - 1)
	}
	return true, max(1, ctx.screen_size[1] - 1)
}

find_paged_sibling :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	origin_idx: i32,
	cmd: Page_Cmd,
) -> (best_idx: i32, found: bool) {
	if origin_idx < 0 || int(origin_idx) >= len(ctx.nodes) {
		return -1, false
	}
	origin := ctx.nodes[origin_idx]
	scope_idx := origin.parent_scope_idx
	vertical, raw_step := resolve_paging_metrics(ctx, origin_idx)
	step := raw_step
	if cmd == .Half_Page_Up || cmd == .Half_Page_Down {
		step = max(1, raw_step / 2)
	}

	forward := cmd == .Page_Down || cmd == .Half_Page_Down || cmd == .End
	dir: Nav_Dir
	if vertical {
		dir = .Down if forward else .Up
	} else {
		dir = .Right if forward else .Left
	}

	origin_pos := origin.rect.y if vertical else origin.rect.x
	target_pos := origin_pos + step if forward else origin_pos - step

	s_start := i32(0)
	s_end   := i32(len(ctx.nodes))
	if scope_idx >= 0 && int(scope_idx) < len(ctx.nodes) {
		s_start = scope_idx + 1
		s_end   = min(ctx.nodes[scope_idx].subtree_end_idx, i32(len(ctx.nodes)))
	}

	best_under_idx  := i32(-1)
	best_under_dist := max(i32)
	furthest_idx    := i32(-1)
	furthest_dist   := i32(-1)

	for i := s_start; i < s_end; i += 1 {
		if i == origin_idx || !is_spatial_candidate_eligible(inp, ctx, capture_idx, scope_idx, i) {
			continue
		}
		cand := ctx.nodes[i]
		score, ok := score_spatial_candidate(origin.rect, cand.rect, dir)
		if !ok || score >= OUT_OF_LANE_PENALTY {
			continue
		}

		cand_pos := cand.rect.y if vertical else cand.rect.x
		move_dist := (cand_pos - origin_pos) if forward else (origin_pos - cand_pos)
		if move_dist <= 0 {
			continue
		}
		if move_dist > furthest_dist {
			furthest_dist = move_dist
			furthest_idx  = i
		}
		if cmd == .Page_Up || cmd == .Page_Down || cmd == .Half_Page_Up || cmd == .Half_Page_Down {
			overshoot := (cand_pos - target_pos) if forward else (target_pos - cand_pos)
			if overshoot <= 0 {
				dist_to_target := -overshoot
				if dist_to_target < best_under_dist {
					best_under_dist = dist_to_target
					best_under_idx  = i
				}
			}
		}
	}

	if cmd == .Home || cmd == .End {
		return furthest_idx, furthest_idx >= 0
	}
	if best_under_idx >= 0 {
		return best_under_idx, true
	}
	return furthest_idx, furthest_idx >= 0
}

scroll_container_by_page :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	cmd: Page_Cmd,
) -> Key_Result {
	if scroll_idx < 0 || int(scroll_idx) >= len(ctx.nodes) {
		return .Ignored
	}
	node := &ctx.nodes[scroll_idx]
	if !node.config.scrollable {
		return .Ignored
	}
	slot := get_scroll_slot(inp, node.id_hash)
	page := max(1, slot.viewport_rows - 1)
	half_page := max(1, slot.viewport_rows / 2)

	if node.config.virtual_total_rows > 0 {
		old_row := slot.selected_row
		old_off := slot.offset
		switch cmd {
		case .Page_Up:
			move_virtual_selection(slot, -page)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		case .Page_Down:
			move_virtual_selection(slot, +page)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		case .Half_Page_Up:
			move_virtual_selection(slot, -half_page)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		case .Half_Page_Down:
			move_virtual_selection(slot, +half_page)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		case .Home:
			slot.selected_row = 0
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
			apply_scroll_delta(inp, ctx, scroll_idx, -slot.max_offset - 1, false)
			return .Consumed
		case .End:
			slot.selected_row = max(0, slot.total_rows - 1)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
			apply_scroll_delta(inp, ctx, scroll_idx, slot.max_offset + 1, false)
			return .Consumed
		}
		node.config.scroll_offset = slot.offset
		inp.scrolled_id = node.id_hash
		if slot.selected_row != old_row || slot.offset != old_off {
			return .Consumed
		}
		return .Consumed
	}

	old_off := slot.offset
	switch cmd {
	case .Page_Up:
		apply_scroll_delta(inp, ctx, scroll_idx, -page, false)
	case .Page_Down:
		apply_scroll_delta(inp, ctx, scroll_idx, +page, false)
	case .Half_Page_Up:
		apply_scroll_delta(inp, ctx, scroll_idx, -half_page, false)
	case .Half_Page_Down:
		apply_scroll_delta(inp, ctx, scroll_idx, +half_page, false)
	case .Home:
		apply_scroll_delta(inp, ctx, scroll_idx, -slot.max_offset - 1, false)
	case .End:
		apply_scroll_delta(inp, ctx, scroll_idx, slot.max_offset + 1, false)
	}
	if slot.offset != old_off {
		return .Consumed
	}
	return .Ignored
}

handle_page_nav_at_level :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	path_level: int,
	cmd: Page_Cmd,
) -> Key_Result {
	node_idx := inp.focus_node_path[path_level]
	if node_idx < 0 || int(node_idx) >= len(ctx.nodes) || !is_node_allowed(ctx, node_idx, capture_idx) {
		return .Ignored
	}
	node := ctx.nodes[node_idx]
	is_tip := path_level == inp.focus_node_path_len - 1

	// 1. O(1) virtualized list or directly focused read-only scroll pane handles paging directly
	if node.config.virtual_total_rows > 0 {
		return scroll_container_by_page(inp, ctx, node_idx, cmd)
	}
	if is_tip && node.config.scrollable && resolve_scope_child_target_idx(inp, ctx, node_idx, capture_idx, false) < 0 {
		return scroll_container_by_page(inp, ctx, node_idx, cmd)
	}

	// 2. At the focused tip, page across materialized focusable siblings in-lane first
	if is_tip {
		if target_idx, ok := find_paged_sibling(inp, ctx, capture_idx, node_idx, cmd); ok {
			reset_preferred_nav(inp)
			target := ctx.nodes[target_idx]
			if (.Focus_Scope in target.focus_flags) && !is_node_focusable(target) {
				if resolved := resolve_scope_target(inp, ctx, target_idx, capture_idx, true); resolved >= 0 {
					set_focused_node(inp, ctx, resolved, capture_idx, false)
					return .Consumed
				}
			}
			set_focused_node(inp, ctx, target_idx, capture_idx, false)
			return .Consumed
		}
	}

	// 3. Otherwise, scroll an enclosing or directly focused materialized scroll container
	return scroll_container_by_page(inp, ctx, node_idx, cmd)
}

