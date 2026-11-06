package bifrost

Focus_Scope_Entry :: struct {
	modal_id:       u64,
	z_layer:        u8,
	saved_focus_id: u64,
	saved_scope_id: u64,
}

Scope_Memory_Entry :: struct {
	scope_hash:      u64,
	last_child_hash: u64, // Shallow History (H): immediate child node/scope along path to focused leaf
	last_leaf_hash:  u64, // Deep History (H*): exact focused leaf inside this scope's subtree
	last_seen_frame: u64, // Monotonic frame counter for LRU eviction
}


Scope_Config :: struct {
	dir:           Direction,
	width:         Axis_Size,
	height:        Axis_Size,
	padding:       Padding,
	gap:           i32,
	border:        Border_Kind,
	main_align:    Alignment,
	cross_align:   Alignment,
	self_align:    [2]Alignment,
	z_layer:       u8,
	floating:      bool,
	anchor:        Anchor_Mode,
	offset:        [2]i32,
	scrollable:    bool,
	scroll_step:   i32,
	clickable:     bool,
	hoverable:     bool,
	focus_flags:   Focus_Flags,
	nav_overrides: [Nav_Dir]u64,
	title:         string,
	fg:            Color,
	bg:            Color,
	border_fg:     Color,
	title_fg:      Color,
	fill_bg:       bool,
}


// =============================================================================
// Scoped `@(deferred_in=...)` Container Builder (`ui_scope`)
// =============================================================================

@(deferred_in = defer_end_ui_scope)
ui_scope :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Scope_Config = {},
) -> bool {
	flags := cfg.focus_flags + {.Focus_Scope}
	if s != nil && (cfg.border != .None || len(cfg.title) > 0 || cfg.fill_bg || cfg.bg.kind != .Default || cfg.fg.kind != .Default || cfg.border_fg.kind != .Default) {
		s.paints[hash_id(id)] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			title_style = {.Bold} if len(cfg.title) > 0 else {},
			fill_bg     = cfg.fill_bg || cfg.bg.kind != .Default,
		}
	}
	idx := push_node(ctx, id, Box_Config{
		dir           = cfg.dir,
		width         = cfg.width,
		height        = cfg.height,
		padding       = cfg.padding,
		gap           = cfg.gap,
		border        = cfg.border,
		main_align    = cfg.main_align,
		cross_align   = cfg.cross_align,
		self_align    = cfg.self_align,
		z_layer       = cfg.z_layer,
		floating      = cfg.floating,
		anchor        = cfg.anchor,
		offset        = cfg.offset,
		scrollable    = cfg.scrollable,
		scroll_step   = cfg.scroll_step,
		clickable     = cfg.clickable,
		hoverable     = cfg.hoverable,
		focus_flags   = flags,
		nav_overrides = cfg.nav_overrides,
		focus_scope   = true,
		focusable     = .Focusable in flags,
	}, {0, 0})
	enter_container_node(ctx, idx)
	return true
}

defer_end_ui_scope :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, cfg: Scope_Config = {}) {
	_ = s
	_ = id
	_ = cfg
	exit_container_node(ctx)
}


// =============================================================================
// Internal Focus Reconciliation, LIFO Modal History & Z-Aware Hit-Testing
// =============================================================================

find_topmost_capture_node :: proc "contextless" (ctx: ^Layout_Context) -> i32 {
	for i := len(ctx.z_order) - 1; i >= 0; i -= 1 {
		idx := ctx.z_order[i]
		node := ctx.nodes[idx]
		if ((.Trap_Focus in node.focus_flags) || node.config.capture_input) && (.Disabled not_in node.focus_flags) {
			return idx
		}
	}
	return -1
}

is_node_focusable :: #force_inline proc "contextless" (node: Layout_Node) -> bool {
	return ((.Focusable in node.focus_flags) || node.config.focusable) && (.Disabled not_in node.focus_flags)
}

is_within_scope :: proc "contextless" (ctx: ^Layout_Context, node_idx, scope_idx: i32) -> bool {
	if scope_idx < 0 || int(scope_idx) >= len(ctx.nodes) {
		return false
	}
	if node_idx <= scope_idx || node_idx >= ctx.nodes[scope_idx].subtree_end_idx {
		return false
	}
	curr := ctx.nodes[node_idx].parent_scope_idx
	for curr >= 0 && curr != scope_idx {
		if .Trap_Focus in ctx.nodes[curr].focus_flags {
			return false
		}
		curr = ctx.nodes[curr].parent_scope_idx
	}
	return curr == scope_idx
}

get_scope_memory :: proc "contextless" (inp: ^Input_State, scope_hash: u64) -> ^Scope_Memory_Entry {
	if scope_hash == 0 {
		return nil
	}
	for i := 0; i < inp.scope_memory_len; i += 1 {
		if inp.scope_memory[i].scope_hash == scope_hash {
			return &inp.scope_memory[i]
		}
	}
	return nil
}

upsert_scope_memory :: proc "contextless" (
	inp: ^Input_State,
	scope_hash: u64,
	child_hash: u64,
	leaf_hash: u64,
) {
	if scope_hash == 0 {
		return
	}
	for i := 0; i < inp.scope_memory_len; i += 1 {
		if inp.scope_memory[i].scope_hash == scope_hash {
			inp.scope_memory[i].last_child_hash = child_hash
			inp.scope_memory[i].last_leaf_hash  = leaf_hash
			inp.scope_memory[i].last_seen_frame = inp.frame_index
			return
		}
	}
	if inp.scope_memory_len < MAX_SCOPE_MEMORY {
		inp.scope_memory[inp.scope_memory_len] = Scope_Memory_Entry{
			scope_hash      = scope_hash,
			last_child_hash = child_hash,
			last_leaf_hash  = leaf_hash,
			last_seen_frame = inp.frame_index,
		}
		inp.scope_memory_len += 1
		return
	}
	// LRU eviction: replace entry with smallest last_seen_frame
	lru_idx := 0
	lru_frame := inp.scope_memory[0].last_seen_frame
	for i := 1; i < MAX_SCOPE_MEMORY; i += 1 {
		if inp.scope_memory[i].last_seen_frame < lru_frame {
			lru_frame = inp.scope_memory[i].last_seen_frame
			lru_idx   = i
		}
	}
	inp.scope_memory[lru_idx] = Scope_Memory_Entry{
		scope_hash      = scope_hash,
		last_child_hash = child_hash,
		last_leaf_hash  = leaf_hash,
		last_seen_frame = inp.frame_index,
	}
}

remove_scope_memory :: proc "contextless" (inp: ^Input_State, scope_hash: u64) {
	if scope_hash == 0 {
		return
	}
	write_idx := 0
	for read_idx := 0; read_idx < inp.scope_memory_len; read_idx += 1 {
		if inp.scope_memory[read_idx].scope_hash != scope_hash {
			inp.scope_memory[write_idx] = inp.scope_memory[read_idx]
			write_idx += 1
		}
	}
	inp.scope_memory_len = write_idx
}

@(private)
is_inactive_scope_leaf_selected :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
) -> bool {
	node := ctx.nodes[node_idx]
	if node.parent_scope_idx < 0 || int(node.parent_scope_idx) >= len(ctx.nodes) {
		return false
	}
	p_scope := ctx.nodes[node.parent_scope_idx]
	entry := get_scope_memory(inp, p_scope.id_hash)
	return entry != nil && entry.last_leaf_hash == node.id_hash
}

promote_floating_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, scope_hash: u64) {
	if scope_hash == 0 {
		return
	}
	existing := -1
	for i := 0; i < inp.floating_mru_len; i += 1 {
		if inp.floating_mru[i] == scope_hash {
			existing = i
			break
		}
	}
	if existing >= 0 {
		for i := existing; i < inp.floating_mru_len - 1; i += 1 {
			inp.floating_mru[i] = inp.floating_mru[i + 1]
		}
		inp.floating_mru[inp.floating_mru_len - 1] = scope_hash
	} else if inp.floating_mru_len < MAX_FLOATING_WINDOWS {
		inp.floating_mru[inp.floating_mru_len] = scope_hash
		inp.floating_mru_len += 1
	} else {
		for i := 0; i < MAX_FLOATING_WINDOWS - 1; i += 1 {
			inp.floating_mru[i] = inp.floating_mru[i + 1]
		}
		inp.floating_mru[MAX_FLOATING_WINDOWS - 1] = scope_hash
	}
	apply_floating_z_promotion(inp, ctx)
}

// Rotates promoted non-modal floating scopes (`FTXUI StackedContainer::SetActiveChild`) to the back
// of their `effective_z` run in `ctx.z_order`, preserving exact `effective_z` tiers and relative order.
apply_floating_z_promotion :: proc(inp: ^Input_State, ctx: ^Layout_Context) {
	if inp.floating_mru_len == 0 || len(ctx.z_order) == 0 {
		return
	}
	stack_buf: [256]i32
	for m := 0; m < inp.floating_mru_len; m += 1 {
		s_idx, ok := ctx.id_map[inp.floating_mru[m]]
		if !ok {
			continue
		}
		s_node := ctx.nodes[s_idx]
		if !s_node.out_of_flow || (.Focus_Scope not_in s_node.focus_flags) || (.Trap_Focus in s_node.focus_flags) {
			continue
		}
		s_end := s_node.subtree_end_idx
		subtree_cap := max(0, int(s_end - s_idx))
		moved_buf := stack_buf[:]
		heap_allocated := subtree_cap > len(stack_buf)
		if heap_allocated {
			moved_buf = make([]i32, subtree_cap, ctx.allocator)
		}
		defer if heap_allocated { delete(moved_buf, ctx.allocator) }
		target_z := s_node.effective_z

		run_start := -1
		run_end := -1
		for k := 0; k < len(ctx.z_order); k += 1 {
			z := ctx.nodes[ctx.z_order[k]].effective_z
			if z == target_z {
				if run_start < 0 {
					run_start = k
				}
				run_end = k + 1
			} else if run_start >= 0 {
				break
			}
		}
		if run_start < 0 || run_end - run_start <= 1 {
			continue
		}

		write_pos := run_start
		moved_cnt := 0
		for k := run_start; k < run_end; k += 1 {
			n_idx := ctx.z_order[k]
			if n_idx >= s_idx && n_idx < s_end && moved_cnt < len(moved_buf) {
				moved_buf[moved_cnt] = n_idx
				moved_cnt += 1
			} else {
				ctx.z_order[write_pos] = n_idx
				write_pos += 1
			}
		}
		for k := 0; k < moved_cnt; k += 1 {
			ctx.z_order[write_pos + k] = moved_buf[k]
		}
	}
}

is_descendant_or_self :: proc "contextless" (ctx: ^Layout_Context, node_idx, ancestor_idx: i32) -> bool {
	if ancestor_idx < 0 {
		return true
	}
	curr := node_idx
	for curr >= 0 {
		if curr == ancestor_idx {
			return true
		}
		curr = ctx.nodes[curr].parent_idx
	}
	return false
}

// A node is reachable only if no capturing modal blocks it.
is_node_allowed :: proc "contextless" (ctx: ^Layout_Context, idx, capture_idx: i32) -> bool {
	if idx < 0 || int(idx) >= len(ctx.nodes) {
		return false
	}
	if capture_idx < 0 {
		return true
	}
	cap_z := ctx.nodes[capture_idx].effective_z
	node_z := ctx.nodes[idx].effective_z
	if node_z > cap_z {
		return true
	}
	if node_z < cap_z {
		return false
	}
	return is_descendant_or_self(ctx, idx, capture_idx)
}


@(private)
modal_scope_on_stack :: proc "contextless" (inp: ^Input_State, modal_id: u64) -> bool {
	for i := 0; i < inp.focus_history_len; i += 1 {
		if inp.focus_history[i].modal_id == modal_id {
			return true
		}
	}
	return false
}

@(private)
is_modal_still_mounted :: proc "contextless" (ctx: ^Layout_Context, modal_id: u64) -> bool {
	if idx, ok := ctx.id_map[modal_id]; ok {
		return ctx.nodes[idx].config.capture_input
	}
	return false
}

@(private)
push_focus_scope_entry :: proc "contextless" (inp: ^Input_State, entry: Focus_Scope_Entry) {
	if entry.modal_id == 0 || modal_scope_on_stack(inp, entry.modal_id) {
		return
	}
	if inp.focus_history_len < MAX_FOCUS_HISTORY {
		inp.focus_history[inp.focus_history_len] = entry
		inp.focus_history_len += 1
	} else {
		for i := 0; i < MAX_FOCUS_HISTORY - 1; i += 1 {
			inp.focus_history[i] = inp.focus_history[i + 1]
		}
		inp.focus_history[MAX_FOCUS_HISTORY - 1] = entry
	}
}

@(private)
build_focus_node_path :: proc "contextless" (
	ctx: ^Layout_Context,
	target_idx: i32,
	out_path: ^[MAX_FOCUS_PATH]i32,
) -> int {
	if target_idx < 0 || int(target_idx) >= len(ctx.nodes) {
		return 0
	}
	len_path := 0
	out_path[len_path] = target_idx
	len_path += 1
	curr := ctx.nodes[target_idx].parent_scope_idx
	for curr >= 0 && len_path < MAX_FOCUS_PATH {
		out_path[len_path] = curr
		len_path += 1
		curr = ctx.nodes[curr].parent_scope_idx
	}
	for i := 0; i < len_path / 2; i += 1 {
		j := len_path - 1 - i
		out_path[i], out_path[j] = out_path[j], out_path[i]
	}
	return len_path
}

@(private)
find_enclosing_text_sink :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
) -> u64 {
	for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
		n_idx := inp.focus_node_path[p]
		if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
			continue
		}
		n := ctx.nodes[n_idx]
		if (.Focus_Scope in n.focus_flags) && n.text_sink_idx >= 0 && int(n.text_sink_idx) < len(ctx.nodes) {
			sink_node := ctx.nodes[n.text_sink_idx]
			if (.Disabled not_in sink_node.focus_flags) && (.Auto_Edit in sink_node.focus_flags) &&
			   is_node_allowed(ctx, n.text_sink_idx, capture_idx) {
				return sink_node.id_hash
			}
		}
		if .Trap_Focus in n.focus_flags {
			break
		}
	}
	return 0
}

@(private)
reset_preferred_nav :: #force_inline proc "contextless" (inp: ^Input_State) {
	inp.has_preferred_x = false
	inp.has_preferred_y = false
}

// Commits `target_idx` as the active focused node, builds `focus_path` and `focus_node_path`,
// updates `scope_memory` upward (halting at `.Trap_Focus`), promotes non-modal floating scopes,
// resolves `editing_id`, and scrolls `target_idx` into view on the same frame when focus changes.
set_focused_node :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	target_idx: i32,
	capture_idx: i32,
	preserve_edit: bool,
) {
	if target_idx < 0 || int(target_idx) >= len(ctx.nodes) {
		inp.focused_id          = 0
		inp.editing_id          = 0
		inp.carry_edit_mode     = false
		inp.active_scope_id     = 0
		inp.focus_path_len      = 0
		inp.focus_node_path_len = 0
		return
	}

	old_focused_id := inp.focused_id
	prev_editing := inp.editing_id
	carry := inp.carry_edit_mode
	inp.carry_edit_mode = false

	target := ctx.nodes[target_idx]
	if old_focused_id != 0 && old_focused_id != target.id_hash {
		cleanup_splitter_submode_on_blur(inp, old_focused_id)
	}
	focus_changed := (old_focused_id != target.id_hash) || inp.ensure_visible || (inp.frame_index <= 1 && old_focused_id != 0)
	inp.ensure_visible      = false
	inp.focused_id          = target.id_hash
	inp.active_scope_id     = target.scope_id
	inp.focus_path_len      = build_ancestor_path(ctx, target_idx, &inp.focus_path)
	inp.focus_node_path_len = build_focus_node_path(ctx, target_idx, &inp.focus_node_path)

	// Record H (last_child_hash) and H* (last_leaf_hash) up parent_scope_idx, stopping at Trap_Focus.
	// Skip recording if target_idx is a non-focusable zero-match text_sink_idx fallback.
	if is_node_focusable(target) && (.Trap_Focus not_in target.focus_flags) {
		leaf_hash := target.id_hash
		child_idx := target_idx
		s_idx := target.parent_scope_idx
		for s_idx >= 0 && int(s_idx) < len(ctx.nodes) {
			s_node := ctx.nodes[s_idx]
			upsert_scope_memory(inp, s_node.id_hash, ctx.nodes[child_idx].id_hash, leaf_hash)
			if .Trap_Focus in s_node.focus_flags {
				break
			}
			child_idx = s_idx
			s_idx     = s_node.parent_scope_idx
		}
	}

	// Promote enclosing non-modal floating scope to front of its z_layer run
	for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
		n_idx := inp.focus_node_path[p]
		n := ctx.nodes[n_idx]
		if n.out_of_flow && (.Focus_Scope in n.focus_flags) && (.Trap_Focus not_in n.focus_flags) {
			promote_floating_scope(inp, ctx, n.id_hash)
			break
		}
		if .Trap_Focus in n.focus_flags {
			break
		}
	}

	// Resolve editing_id
	sink_id := find_enclosing_text_sink(inp, ctx, capture_idx)
	if (.Captures_Text in target.focus_flags) && (.Disabled not_in target.focus_flags) {
		if (.Auto_Edit in target.focus_flags) || carry {
			inp.editing_id = target.id_hash
		} else if preserve_edit && prev_editing == target.id_hash {
			inp.editing_id = target.id_hash
		} else {
			inp.editing_id = sink_id
		}
	} else {
		inp.editing_id = sink_id
	}
	if inp.editing_id != 0 {
		inp.pending_chord = {}
	}

	// Same-frame scroll-into-view when focus changes (0-frame lag; never fights idle mouse wheel scroll)
	if focus_changed {
		scroll_node_into_view(inp, ctx, target_idx)
	}
}

// Resolves a descendant target strictly inside `scope_idx` (Stages 1..3: Deep H* -> Shallow H -> Fresh Mount).
resolve_scope_child_target_idx :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scope_idx: i32,
	capture_idx: i32,
	use_history: bool = true,
) -> i32 {
	if scope_idx < 0 || int(scope_idx) >= len(ctx.nodes) {
		return -1
	}
	scope_node := ctx.nodes[scope_idx]
	if .Disabled in scope_node.focus_flags {
		return -1
	}

	if use_history {
		if entry := get_scope_memory(inp, scope_node.id_hash); entry != nil {
			// Stage 1: Deep History (H*) — exact last focused leaf inside scope_idx
			if entry.last_leaf_hash != 0 {
				if leaf_idx, ok := ctx.id_map[entry.last_leaf_hash]; ok {
					leaf_node := ctx.nodes[leaf_idx]
					if is_node_focusable(leaf_node) &&
					   is_within_scope(ctx, leaf_idx, scope_idx) &&
					   is_node_allowed(ctx, leaf_idx, capture_idx) {
						return leaf_idx
					}
				}
			}

			// Stage 2: Shallow History (H) — last immediate child scope/node when prior leaf unmounted
			if entry.last_child_hash != 0 {
				if child_idx, ok := ctx.id_map[entry.last_child_hash]; ok {
					child_node := ctx.nodes[child_idx]
					if (.Disabled not_in child_node.focus_flags) &&
					   is_within_scope(ctx, child_idx, scope_idx) &&
					   is_node_allowed(ctx, child_idx, capture_idx) {
						if .Focus_Scope in child_node.focus_flags {
							resolved := resolve_scope_target(inp, ctx, child_idx, capture_idx, true)
							if resolved >= 0 {
								return resolved
							}
						} else if is_node_focusable(child_node) {
							return child_idx
						}
					}
				}
			}
		}
	}

	// Stage 3: Fresh Mount — direct .Default_Focus member first, else first direct focusable / non-empty child scope
	end_idx := min(scope_node.subtree_end_idx, i32(len(ctx.nodes)))
	for i := scope_idx + 1; i < end_idx; i += 1 {
		n := ctx.nodes[i]
		if n.parent_scope_idx != scope_idx || (.Disabled in n.focus_flags) {
			continue
		}
		if (.Trap_Focus in n.focus_flags) && i != capture_idx {
			continue
		}
		if (.Default_Focus in n.focus_flags) && is_node_allowed(ctx, i, capture_idx) {
			if .Focus_Scope in n.focus_flags {
				t := resolve_scope_target(inp, ctx, i, capture_idx, use_history)
				if t >= 0 {
					return t
				}
			} else if is_node_focusable(n) {
				return i
			}
		}
	}

	first_empty_scope := i32(-1)
	for i := scope_idx + 1; i < end_idx; i += 1 {
		n := ctx.nodes[i]
		if n.parent_scope_idx != scope_idx || (.Disabled in n.focus_flags) {
			continue
		}
		if (.Trap_Focus in n.focus_flags) && i != capture_idx {
			continue
		}
		if !is_node_allowed(ctx, i, capture_idx) {
			continue
		}
		if .Focus_Scope in n.focus_flags {
			t := resolve_scope_target(inp, ctx, i, capture_idx, use_history)
			if t >= 0 && t != i {
				return t
			}
			if t == i && first_empty_scope < 0 {
				first_empty_scope = t
			}
		} else if is_node_focusable(n) {
			return i
		}
	}

	return first_empty_scope
}

// Deterministic 4-stage scope target resolver:
// 1. Deep History (H*) -> 2. Shallow History (H) -> 3. Fresh Mount (.Default_Focus / first leaf) ->
// 4. Empty Focusable Scope (`scope_idx`) or Zero-Match `text_sink_idx`.
resolve_scope_target :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scope_idx: i32,
	capture_idx: i32,
	use_history: bool = true,
) -> i32 {
	if scope_idx < 0 || int(scope_idx) >= len(ctx.nodes) {
		return -1
	}
	scope_node := ctx.nodes[scope_idx]
	if .Disabled in scope_node.focus_flags {
		return -1
	}

	child_target := resolve_scope_child_target_idx(inp, ctx, scope_idx, capture_idx, use_history)
	if child_target >= 0 {
		return child_target
	}

	// Stage 4: Empty Scope / Zero-Match Sink Fallback
	if is_node_focusable(scope_node) && is_node_allowed(ctx, scope_idx, capture_idx) {
		return scope_idx
	}
	if scope_node.text_sink_idx >= 0 && int(scope_node.text_sink_idx) < len(ctx.nodes) {
		sink_node := ctx.nodes[scope_node.text_sink_idx]
		if (.Disabled not_in sink_node.focus_flags) && is_node_allowed(ctx, scope_node.text_sink_idx, capture_idx) {
			return scope_node.text_sink_idx
		}
	}
	return -1
}

// Clears H/H* memory for `scope_idx` (and child scopes inside it), resets virtual scroll rows to 0,
// and snaps focus back to the scope's default/first item upon `.Scope_Text_Sink` text mutation.
reset_scope_selection_to_default :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scope_idx: i32,
	capture_idx: i32,
) {
	if scope_idx < 0 || int(scope_idx) >= len(ctx.nodes) {
		return
	}
	scope_node := ctx.nodes[scope_idx]
	remove_scope_memory(inp, scope_node.id_hash)

	end_idx := min(scope_node.subtree_end_idx, i32(len(ctx.nodes)))
	for i := scope_idx + 1; i < end_idx; i += 1 {
		n := ctx.nodes[i]
		if .Focus_Scope in n.focus_flags {
			remove_scope_memory(inp, n.id_hash)
		}
		if n.config.scrollable {
			slot := get_scroll_slot(inp, n.id_hash)
			slot.offset       = 0
			slot.offset_x     = 0
			slot.selected_row = 0
			slot.selected_col = 0
		}
	}

	target := resolve_scope_target(inp, ctx, scope_idx, capture_idx, false)
	if target >= 0 {
		set_focused_node(inp, ctx, target, capture_idx, false)
	}
}

reconcile_focus :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32) {
	inp.frame_index += 1

	// 1. Synchronize LIFO modal focus_history stack and clear ephemeral Trap_Focus memory on modal unmount
	for inp.focus_history_len > 0 {
		top := inp.focus_history[inp.focus_history_len - 1]
		if is_modal_still_mounted(ctx, top.modal_id) {
			break
		}
		inp.focus_history_len -= 1
		remove_scope_memory(inp, top.modal_id)
	}

	write_idx := 0
	for read_idx := 0; read_idx < inp.focus_history_len; read_idx += 1 {
		entry := inp.focus_history[read_idx]
		if is_modal_still_mounted(ctx, entry.modal_id) {
			inp.focus_history[write_idx] = entry
			write_idx += 1
		} else {
			remove_scope_memory(inp, entry.modal_id)
		}
	}
	inp.focus_history_len = write_idx

	for idx in ctx.z_order {
		node := ctx.nodes[idx]
		if !node.config.capture_input || (.Disabled in node.focus_flags) {
			continue
		}
		if !modal_scope_on_stack(inp, node.id_hash) {
			push_focus_scope_entry(inp, Focus_Scope_Entry{
				modal_id       = node.id_hash,
				z_layer        = node.effective_z,
				saved_focus_id = inp.focused_id,
				saved_scope_id = inp.active_scope_id,
			})
		}
	}

	// Touch last_seen_frame on all mounted scopes so active scopes are never LRU-evicted
	for i := 0; i < len(ctx.nodes); i += 1 {
		n := ctx.nodes[i]
		if .Focus_Scope in n.focus_flags {
			if entry := get_scope_memory(inp, n.id_hash); entry != nil {
				entry.last_seen_frame = inp.frame_index
			}
		}
	}

	// 2. Apply explicit programmatic focus request if valid within active shield
	if inp.wants_focus_id != 0 {
		req_id := inp.wants_focus_id
		inp.wants_focus_id = 0
		if idx, ok := ctx.id_map[req_id]; ok {
			node := ctx.nodes[idx]
			if is_node_focusable(node) && is_node_allowed(ctx, idx, capture_idx) {
				reset_preferred_nav(inp)
				set_focused_node(inp, ctx, idx, capture_idx, false)
				return
			} else if (.Focus_Scope in node.focus_flags) && is_node_allowed(ctx, idx, capture_idx) {
				if resolved := resolve_scope_target(inp, ctx, idx, capture_idx, true); resolved >= 0 {
					reset_preferred_nav(inp)
					set_focused_node(inp, ctx, resolved, capture_idx, false)
					return
				}
			}
		}
	}

	// 3. Verify focused_id is still mounted, focusable (not .Disabled or zero-match sink), and allowed by active trap
	if inp.focused_id != 0 {
		if idx, exists := ctx.id_map[inp.focused_id]; exists {
			node := ctx.nodes[idx]
			if is_node_focusable(node) && is_node_allowed(ctx, idx, capture_idx) {
				set_focused_node(inp, ctx, idx, capture_idx, true)
				return
			}
		}
	}

	// 4. Resolve via active Trap_Focus scope (or Root 0) using H* -> H -> .Default_Focus -> Empty/Sink fallback
	active_root_scope: i32 = capture_idx if capture_idx >= 0 else 0
	target_idx := resolve_scope_target(inp, ctx, active_root_scope, capture_idx, true)
	if target_idx >= 0 {
		set_focused_node(inp, ctx, target_idx, capture_idx, false)
		return
	}

	// 5. Ultimate fallback: scan ctx.z_order / topological nodes for any allowed focusable widget
	for i := 0; i < len(ctx.nodes); i += 1 {
		idx := i32(i)
		node := ctx.nodes[idx]
		if is_node_focusable(node) && is_node_allowed(ctx, idx, capture_idx) {
			set_focused_node(inp, ctx, idx, capture_idx, false)
			return
		}
	}

	set_focused_node(inp, ctx, -1, capture_idx, false)
}



cycle_focus_within_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, step: int) {
	step_focus_within_scope(inp, ctx, capture_idx, step, true)
}

step_focus_within_scope :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	step: int,
	allow_edit_carry: bool,
) {
	candidates := make([dynamic]i32, 0, 16, ctx.allocator)

	target_scope_idx := i32(-1)
	was_editing_focused := false
	if inp.focused_id != 0 {
		if f_idx, ok := ctx.id_map[inp.focused_id]; ok {
			f_node := ctx.nodes[f_idx]
			target_scope_idx = f_node.parent_scope_idx
			was_editing_focused = (inp.editing_id == f_node.id_hash) && (.Captures_Text in f_node.focus_flags)
		}
	}

	if target_scope_idx >= 0 {
		s_end := min(ctx.nodes[target_scope_idx].subtree_end_idx, i32(len(ctx.nodes)))
		for i := target_scope_idx + 1; i < s_end; i += 1 {
			node := ctx.nodes[i]
			if node.parent_scope_idx == target_scope_idx && is_node_focusable(node) && is_node_allowed(ctx, i, capture_idx) {
				append(&candidates, i)
			}
		}
	}

	// Fallback if current parent_scope_idx has no direct focusable widgets
	if len(candidates) == 0 {
		for i := 0; i < len(ctx.nodes); i += 1 {
			idx := i32(i)
			node := ctx.nodes[idx]
			if is_node_focusable(node) && is_node_allowed(ctx, idx, capture_idx) {
				append(&candidates, idx)
			}
		}
	}

	if len(candidates) == 0 {
		return
	}

	cur_pos := -1
	for idx, pos in candidates {
		if ctx.nodes[idx].id_hash == inp.focused_id {
			cur_pos = pos
			break
		}
	}

	next_pos := 0
	if cur_pos >= 0 {
		count := len(candidates)
		next_pos = ((cur_pos + step) % count + count) % count
	} else if step < 0 {
		next_pos = len(candidates) - 1
	}

	chosen_idx := candidates[next_pos]
	inp.carry_edit_mode = allow_edit_carry && was_editing_focused
	set_focused_node(inp, ctx, chosen_idx, capture_idx, false)
}

cycle_focus_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, step: int) {
	if len(ctx.nodes) == 0 {
		return
	}

	cur_scope_idx: i32 = 0
	if inp.focused_id != 0 {
		if f_idx, ok := ctx.id_map[inp.focused_id]; ok {
			if .Focus_Scope in ctx.nodes[f_idx].focus_flags {
				cur_scope_idx = f_idx
			} else if ctx.nodes[f_idx].parent_scope_idx >= 0 {
				cur_scope_idx = ctx.nodes[f_idx].parent_scope_idx
			}
		}
	}

	scopes := make([dynamic]i32, 0, 8, ctx.allocator)
	child_s := cur_scope_idx

	for child_s >= 0 && int(child_s) < len(ctx.nodes) {
		if .Trap_Focus in ctx.nodes[child_s].focus_flags {
			break
		}
		parent_s := ctx.nodes[child_s].parent_scope_idx
		if parent_s < 0 || int(parent_s) >= len(ctx.nodes) {
			break
		}

		clear(&scopes)
		p_end := min(ctx.nodes[parent_s].subtree_end_idx, i32(len(ctx.nodes)))
		has_direct_leaf := false
		for i := parent_s + 1; i < p_end; i += 1 {
			n := ctx.nodes[i]
			if n.parent_scope_idx != parent_s || (.Disabled in n.focus_flags) {
				continue
			}
			if (.Focus_Scope in n.focus_flags) && (.Trap_Focus not_in n.focus_flags) {
				if is_node_allowed(ctx, i, capture_idx) && resolve_scope_target(inp, ctx, i, capture_idx, true) >= 0 {
					append(&scopes, i)
				}
			} else if is_node_focusable(n) && is_node_allowed(ctx, i, capture_idx) {
				has_direct_leaf = true
			}
		}
		if len(scopes) == 1 && has_direct_leaf {
			append(&scopes, parent_s)
		}

		if len(scopes) >= 2 {
			cur_pos := 0
			for s_idx, pos in scopes {
				if s_idx == child_s {
					cur_pos = pos
					break
				}
			}
			count := len(scopes)
			next_pos := ((cur_pos + step) % count + count) % count
			target_scope := scopes[next_pos]

			if target_scope == parent_s {
				for i := parent_s + 1; i < p_end; i += 1 {
					n := ctx.nodes[i]
					if n.parent_scope_idx == parent_s && (.Focus_Scope not_in n.focus_flags) &&
					   is_node_focusable(n) && is_node_allowed(ctx, i, capture_idx) {
						reset_preferred_nav(inp)
						set_focused_node(inp, ctx, i, capture_idx, false)
						return
					}
				}
			} else {
				resolved := resolve_scope_target(inp, ctx, target_scope, capture_idx, true)
				if resolved >= 0 {
					reset_preferred_nav(inp)
					set_focused_node(inp, ctx, resolved, capture_idx, false)
					return
				}
			}
		}

		child_s = parent_s
	}
}

