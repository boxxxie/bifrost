package bifrost

import "core:fmt"
import "core:strings"

// =============================================================================
// Track 12: Virtualized Collapsible Tree (`ui_tree`)
// =============================================================================
// Renders hierarchical nodes (file explorers, ASTs, module outlines) with
// box-drawing indentation guides (`├─ `, `╰─ `, `│  `, `   `, `▾ `, `▸ `),
// keyboard/mouse expand/collapse & parent-node jump navigation, and O(1)
// visible-slice virtualization over 10,000+ node trees.

MAX_TREE_SLOTS        :: 8
MAX_TREE_DEPTH        :: 32
MAX_TREE_BITSET_WORDS :: 256 // 256 * 64 = 16,384 nodes tracked inline per Tree_Slot
MAX_TREE_HASH_CAP     :: 512 // Open-addressed power-of-two table tracking expand/collapse by `id_hash`
MAX_TREE_HASH_WORDS   :: MAX_TREE_HASH_CAP / 64
MAX_TREE_WIDTH_HIST   :: 256 // Fixed-bucket row-width histogram for O(N) zero-allocation p95 width estimation

Tree_Node :: struct {
	id:           string,      // Optional explicit string ID (defaults to hashed index/label)
	id_hash:      u64,         // Optional explicit ID hash
	label:        string,      // Primary visible label text
	icon:         string,      // Optional icon/badge prefix rendered after expand/collapse glyph
	depth:        i32,         // 0-based nesting depth (or 0 when parent_idx >= 0 is used)
	parent_idx:   i32,         // Optional explicit parent index (-1 for root; resolved from depth when depth > 0)
	expanded:     bool,        // Initial expand/collapse state on first mount
	has_children: bool,        // Explicit branch flag (also inferred automatically when followed by deeper children)
	fg:           Color,       // Optional per-node foreground color
	bg:           Color,       // Optional per-node background color
	guide_fg:     Color,       // Optional per-node guide glyph color
	icon_fg:      Color,       // Optional per-node icon foreground color
	style:        Style_Flags, // Optional per-node text style flags
	userdata:     rawptr,      // Optional caller payload pointer
}

Tree_Config :: struct {
	title:            string,
	width:            Axis_Size, // Defaults to smart p95 content width when nil (or grow(1) when width_percentile < 0)
	height:           Axis_Size,
	border:           Border_Kind,
	fg:               Color,
	bg:               Color,
	border_fg:        Color,
	title_fg:         Color,
	guide_fg:         Color, // Color for `│  `, `├─ `, `╰─ ` box-drawing connectors
	toggle_fg:        Color, // Color for `▾ ` / `▸ ` branch indicators
	sel_fg:           Color, // Highlighted selected row foreground
	sel_bg:           Color, // Highlighted selected row background
	leaf_prefix:      string, // Optional prefix for leaf nodes (e.g. `""` or `"• "`)
	scroll_step:      i32,
	scroll_padding:   i32,
	fallback_rows:    i32, // Estimated viewport rows on Frame 0 before first layout solve
	width_percentile: i32, // Target item-width percentile (1..100, default 95 when 0; < 0 disables auto p95 sizing)
	min_auto_width:   i32, // Minimum auto-computed outer box width in cells (defaults to 20)
	max_auto_width:   i32, // Maximum auto-computed outer box width in cells (defaults to 56 when 0)
	focus_flags:      Focus_Flags,
}

Tree_Slice :: struct {
	start_row:          i32, // Inclusive start index into flattened visible rows
	end_row:            i32, // Exclusive end index into flattened visible rows
	selected_vis_row:   i32, // Currently highlighted visible row index
	selected_node_idx:  i32, // Index into the `nodes` slice for the selected row (-1 if empty)
	activated_node_idx: i32, // Index into `nodes` if a leaf node was activated this frame (-1 if none)
	scroll_offset:      i32, // Clamped top visible row index
	viewport_rows:      i32, // Number of visible rows in the tree viewport
	total_visible_rows: i32, // Total flattened visible rows after skipping collapsed subtrees
	total_nodes:        i32, // Total nodes in the input `nodes` slice
	recommended_width:  i32, // Auto-computed p95 outer box width (including borders + scrollbar gutter)
}

Tree_Node_Meta :: struct {
	id_hash:        u64,
	parent_idx:     i32,
	first_child:    i32,
	next_sibling:   i32,
	depth:          i32,
	has_children:   bool,
	default_expand: bool,
}

Tree_Slot :: struct {
	id_hash:            u64,
	selected_node_idx:  i32,
	selected_node_hash: u64,
	selected_vis_row:   i32,
	activated_node_idx: i32,
	total_nodes:        i32,
	total_visible_rows: i32,
	recommended_width:  i32,
	expanded_bits:      [MAX_TREE_BITSET_WORDS]u64,
	initialized_bits:   [MAX_TREE_BITSET_WORDS]u64,
	hash_keys:          [MAX_TREE_HASH_CAP]u64,
	hash_expanded:      [MAX_TREE_HASH_WORDS]u64,
	hash_count:         i32,
	meta:               []Tree_Node_Meta,
	vis_to_node:        []i32,
	last_layout_gen:    u64,
}

@(private)
find_tree_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Tree_Slot {
	if inp == nil || id_hash == 0 {
		return nil
	}
	for i := 0; i < MAX_TREE_SLOTS; i += 1 {
		if inp.tree_slots[i].id_hash == id_hash {
			return &inp.tree_slots[i]
		}
	}
	return nil
}

get_tree_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Tree_Slot {
	empty_idx := -1
	lru_idx   := 0
	lru_gen   := max(u64)
	for i := 0; i < MAX_TREE_SLOTS; i += 1 {
		if inp.tree_slots[i].id_hash == id_hash {
			return &inp.tree_slots[i]
		}
		if empty_idx == -1 && inp.tree_slots[i].id_hash == 0 {
			empty_idx = i
		}
		if inp.tree_slots[i].last_layout_gen < lru_gen {
			lru_gen = inp.tree_slots[i].last_layout_gen
			lru_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else lru_idx
	inp.tree_slots[idx] = Tree_Slot{
		id_hash            = id_hash,
		selected_node_idx  = 0,
		selected_vis_row   = 0,
		activated_node_idx = -1,
	}
	return &inp.tree_slots[idx]
}

@(private)
tree_slot_hash_lookup :: #force_inline proc "contextless" (slot: ^Tree_Slot, node_hash: u64) -> (expanded: bool, found: bool) {
	if slot == nil || node_hash == 0 {
		return false, false
	}
	mask := u64(MAX_TREE_HASH_CAP - 1)
	idx  := int(node_hash & mask)
	for step := 0; step < MAX_TREE_HASH_CAP; step += 1 {
		k := slot.hash_keys[idx]
		if k == 0 {
			return false, false
		}
		if k == node_hash {
			w := idx >> 6
			b := u64(1) << u64(u32(idx) & 63)
			return (slot.hash_expanded[w] & b) != 0, true
		}
		idx = (idx + 1) & int(mask)
	}
	return false, false
}

@(private)
tree_slot_hash_upsert :: #force_inline proc "contextless" (slot: ^Tree_Slot, node_hash: u64, expanded: bool) {
	if slot == nil || node_hash == 0 {
		return
	}
	mask := u64(MAX_TREE_HASH_CAP - 1)
	idx  := int(node_hash & mask)
	for step := 0; step < MAX_TREE_HASH_CAP; step += 1 {
		k := slot.hash_keys[idx]
		if k == 0 {
			if slot.hash_count >= MAX_TREE_HASH_CAP - 1 {
				return
			}
			slot.hash_keys[idx] = node_hash
			slot.hash_count += 1
			w := idx >> 6
			b := u64(1) << u64(u32(idx) & 63)
			if expanded {
				slot.hash_expanded[w] |= b
			} else {
				slot.hash_expanded[w] &= ~b
			}
			return
		}
		if k == node_hash {
			w := idx >> 6
			b := u64(1) << u64(u32(idx) & 63)
			if expanded {
				slot.hash_expanded[w] |= b
			} else {
				slot.hash_expanded[w] &= ~b
			}
			return
		}
		idx = (idx + 1) & int(mask)
	}
}

@(private)
tree_slot_is_expanded :: #force_inline proc "contextless" (slot: ^Tree_Slot, node_idx: i32) -> bool {
	if slot == nil || node_idx < 0 {
		return false
	}
	if int(node_idx) < len(slot.meta) {
		if exp, ok := tree_slot_hash_lookup(slot, slot.meta[node_idx].id_hash); ok {
			return exp
		}
	}
	word_idx := int(node_idx) >> 6
	bit_mask := u64(1) << u64(u32(node_idx) & 63)
	if word_idx < MAX_TREE_BITSET_WORDS {
		if (slot.initialized_bits[word_idx] & bit_mask) != 0 {
			return (slot.expanded_bits[word_idx] & bit_mask) != 0
		}
	}
	if int(node_idx) < len(slot.meta) {
		return slot.meta[node_idx].default_expand
	}
	return false
}

@(private)
tree_slot_set_expanded :: #force_inline proc "contextless" (slot: ^Tree_Slot, node_idx: i32, expanded: bool) {
	if slot == nil || node_idx < 0 {
		return
	}
	word_idx := int(node_idx) >> 6
	bit_mask := u64(1) << u64(u32(node_idx) & 63)
	if word_idx < MAX_TREE_BITSET_WORDS {
		slot.initialized_bits[word_idx] |= bit_mask
		if expanded {
			slot.expanded_bits[word_idx] |= bit_mask
		} else {
			slot.expanded_bits[word_idx] &= ~bit_mask
		}
	}
	if int(node_idx) < len(slot.meta) {
		slot.meta[node_idx].default_expand = expanded
		tree_slot_hash_upsert(slot, slot.meta[node_idx].id_hash, expanded)
	}
}

@(private)
tree_slot_seed_expanded :: #force_inline proc "contextless" (slot: ^Tree_Slot, node_idx: i32, node_hash: u64, has_children: bool, initial_expanded: bool) -> bool {
	if slot == nil || node_idx < 0 {
		return initial_expanded
	}
	word_idx := int(node_idx) >> 6
	bit_mask := u64(1) << u64(u32(node_idx) & 63)
	if has_children && node_hash != 0 {
		if exp, ok := tree_slot_hash_lookup(slot, node_hash); ok {
			if word_idx < MAX_TREE_BITSET_WORDS {
				slot.initialized_bits[word_idx] |= bit_mask
				if exp {
					slot.expanded_bits[word_idx] |= bit_mask
				} else {
					slot.expanded_bits[word_idx] &= ~bit_mask
				}
			}
			return exp
		}
		tree_slot_hash_upsert(slot, node_hash, initial_expanded)
		if word_idx < MAX_TREE_BITSET_WORDS {
			slot.initialized_bits[word_idx] |= bit_mask
			if initial_expanded {
				slot.expanded_bits[word_idx] |= bit_mask
			} else {
				slot.expanded_bits[word_idx] &= ~bit_mask
			}
		}
		return initial_expanded
	}
	if word_idx < MAX_TREE_BITSET_WORDS {
		if (slot.initialized_bits[word_idx] & bit_mask) == 0 {
			slot.initialized_bits[word_idx] |= bit_mask
			if initial_expanded {
				slot.expanded_bits[word_idx] |= bit_mask
			} else {
				slot.expanded_bits[word_idx] &= ~bit_mask
			}
			return initial_expanded
		}
		return (slot.expanded_bits[word_idx] & bit_mask) != 0
	}
	return initial_expanded
}

// Rebuilds `slot.vis_to_node` and `slot.total_visible_rows` in O(N) over `slot.meta`,
// skipping descendants of any collapsed branch node, and reconciles `selected_node_idx` / `selected_vis_row`.
@(private)
rebuild_tree_visible_rows :: proc "contextless" (slot: ^Tree_Slot) {
	if slot == nil {
		return
	}
	n := i32(len(slot.meta))
	slot.total_nodes = n
	if n <= 0 || len(slot.vis_to_node) < int(n) {
		slot.total_visible_rows = 0
		slot.selected_vis_row   = 0
		slot.selected_node_idx  = -1
		return
	}

	vis_count: i32 = 0
	collapsed_gate_depth: i32 = -1
	found_selected_vis: i32 = -1

	for i: i32 = 0; i < n; i += 1 {
		m := slot.meta[i]
		if collapsed_gate_depth >= 0 {
			if m.depth > collapsed_gate_depth {
				continue
			}
			collapsed_gate_depth = -1
		}

		vis_row := vis_count
		slot.vis_to_node[vis_row] = i
		vis_count += 1

		if i == slot.selected_node_idx {
			found_selected_vis = vis_row
		}

		if m.has_children && !tree_slot_is_expanded(slot, i) {
			collapsed_gate_depth = m.depth
		}
	}

	slot.total_visible_rows = vis_count
	if vis_count <= 0 {
		slot.selected_vis_row  = 0
		slot.selected_node_idx = -1
		return
	}

	if found_selected_vis >= 0 {
		slot.selected_vis_row = found_selected_vis
		if slot.selected_node_idx >= 0 && slot.selected_node_idx < n {
			slot.selected_node_hash = slot.meta[slot.selected_node_idx].id_hash
		}
		return
	}

	// If the previously selected node became hidden inside a collapsed ancestor,
	// walk up `parent_idx` to the nearest visible ancestor.
	curr := slot.selected_node_idx
	for curr >= 0 && curr < n {
		curr = slot.meta[curr].parent_idx
		if curr >= 0 {
			for v: i32 = 0; v < vis_count; v += 1 {
				if slot.vis_to_node[v] == curr {
					slot.selected_vis_row   = v
					slot.selected_node_idx  = curr
					slot.selected_node_hash = slot.meta[curr].id_hash
					return
				}
			}
		}
	}

	slot.selected_vis_row  = clamp(slot.selected_vis_row, 0, vis_count - 1)
	slot.selected_node_idx = slot.vis_to_node[slot.selected_vis_row]
	if slot.selected_node_idx >= 0 && slot.selected_node_idx < n {
		slot.selected_node_hash = slot.meta[slot.selected_node_idx].id_hash
	}
}

@(private)
sync_tree_scroll_slot :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	t_slot: ^Tree_Slot,
	s_slot: ^Scroll_Slot,
) {
	s_slot.total_rows   = t_slot.total_visible_rows
	s_slot.max_offset   = max(0, s_slot.total_rows - max(1, s_slot.viewport_rows))
	s_slot.selected_row = clamp(t_slot.selected_vis_row, 0, max(0, s_slot.total_rows - 1))
	move_virtual_selection(s_slot, 0)
	s_slot.offset = clamp(s_slot.offset, 0, s_slot.max_offset)
	if node_idx >= 0 && int(node_idx) < len(ctx.nodes) {
		ctx.nodes[node_idx].config.virtual_total_rows = max(1, s_slot.total_rows)
		ctx.nodes[node_idx].config.scroll_offset      = s_slot.offset
		ctx.nodes[node_idx].content_span[1]           = max(1, s_slot.total_rows)
	}
}

// Formats the box-drawing indentation prefix (`│  `, `   `, `├─ `, `╰─ `) for a node at `node_idx`.
format_tree_guide_prefix :: proc(
	meta: []Tree_Node_Meta,
	node_idx: i32,
	allocator := context.temp_allocator,
) -> string {
	if node_idx < 0 || int(node_idx) >= len(meta) {
		return ""
	}
	d := meta[node_idx].depth
	if d <= 0 {
		return ""
	}

	// Collect ancestor chain for depths 1 ..= d
	ancestors: [MAX_TREE_DEPTH]i32
	curr := node_idx
	for level := d; level >= 1 && curr >= 0 && int(curr) < len(meta); level -= 1 {
		if level < MAX_TREE_DEPTH {
			ancestors[level] = curr
		}
		curr = meta[curr].parent_idx
	}

	b := strings.builder_make(0, int(d) * 6, allocator)
	for level: i32 = 1; level < d && level < MAX_TREE_DEPTH; level += 1 {
		anc_idx := ancestors[level]
		if anc_idx >= 0 && int(anc_idx) < len(meta) && meta[anc_idx].next_sibling >= 0 {
			strings.write_string(&b, "│  ")
		} else {
			strings.write_string(&b, "   ")
		}
	}

	if meta[node_idx].next_sibling >= 0 {
		strings.write_string(&b, "├─ ")
	} else {
		strings.write_string(&b, "╰─ ")
	}
	return strings.to_string(b)
}

// Computes the target outer box width (in terminal cells) needed to accommodate the `percentile`-th
// (default p95) rendered row width of `nodes` in a single O(N) zero-allocation pass using a fixed
// 256-bucket histogram. Accounts for box-drawing indentation (`depth * 3`), branch/leaf toggles,
// icons, borders, and scrollbar gutter, while clamping outliers via `[min_width .. max_width]`.
compute_tree_auto_width :: proc "contextless" (
	nodes: []Tree_Node,
	border: Border_Kind = .Rounded,
	leaf_prefix: string = "",
	percentile: i32 = 95,
	min_width: i32 = 20,
	max_width: i32 = 56,
) -> i32 {
	eff_min := max(8, min_width if min_width > 0 else 20)
	eff_max := max(eff_min, max_width) if max_width > 0 else max(eff_min, 56)
	if len(nodes) == 0 {
		return eff_min
	}

	pct := clamp(percentile if percentile > 0 else 95, 1, 100)
	leaf_pref_w := string_display_width(leaf_prefix)
	border_pad: i32 = 2 if border != .None else 0
	scrollbar_gutter: i32 = 2 // 1 cell scrollbar + 1 cell breathing room

	hist: [MAX_TREE_WIDTH_HIST]i32
	prev_depth: i32 = -1
	n := len(nodes)

	for i := 0; i < n; i += 1 {
		nd := nodes[i]
		d := nd.depth
		if i > 0 && d > 0 {
			d = min(d, min(prev_depth + 1, MAX_TREE_DEPTH - 1))
		} else {
			d = 0
		}
		prev_depth = d

		has_ch := nd.has_children || (i + 1 < n && nodes[i + 1].depth > d)
		prefix_w := d * 3
		toggle_w := i32(2) if has_ch else leaf_pref_w
		icon_w   := (string_display_width(nd.icon) + 1) if len(nd.icon) > 0 else 0
		label_w  := string_display_width(nd.label)

		outer_w := prefix_w + toggle_w + icon_w + label_w + border_pad + scrollbar_gutter
		bucket  := clamp(outer_w, 0, MAX_TREE_WIDTH_HIST - 1)
		hist[bucket] += 1
	}

	target_rank := max(1, (i32(n) * pct + 99) / 100)
	accum: i32 = 0
	p_width := eff_min
	for w: i32 = 0; w < MAX_TREE_WIDTH_HIST; w += 1 {
		accum += hist[w]
		if accum >= target_rank {
			p_width = w
			break
		}
	}

	return clamp(p_width, eff_min, eff_max)
}

// Mounts a virtualized collapsible tree container and materializes ONLY the visible row slice
// `[start_row ..< end_row]` inside the scroll viewport (`O(visible_rows)` `Layout_Node`s per frame).
ui_tree :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	nodes: []Tree_Node,
	cfg: Tree_Config = {},
	out_slice: ^Tree_Slice = nil,
) -> i32 {
	id_h := hash_id(id)
	s_slot := get_scroll_slot(inp, id_h)
	t_slot := get_tree_slot(inp, id_h)

	n := i32(len(nodes))
	if n > 0 {
		meta := make([]Tree_Node_Meta, int(n), ctx.allocator)
		vis_to_node := make([]i32, int(n), ctx.allocator)

		ancestor_at_depth: [MAX_TREE_DEPTH]i32
		last_child_at_depth: [MAX_TREE_DEPTH]i32
		for d := 0; d < MAX_TREE_DEPTH; d += 1 {
			ancestor_at_depth[d]   = -1
			last_child_at_depth[d] = -1
		}

		// Single O(N) pre-order pass to resolve depth, parent_idx, first_child, next_sibling, and has_children
		prev_depth: i32 = -1
		for i: i32 = 0; i < n; i += 1 {
			nd := nodes[i]
			d := nd.depth
			p_idx: i32 = -1

			if i > 0 && d > 0 {
				d = min(d, min(prev_depth + 1, MAX_TREE_DEPTH - 1))
				p_idx = ancestor_at_depth[d - 1]
			} else if i > 0 && nd.parent_idx >= 0 && nd.parent_idx < i && nodes[0].parent_idx < 0 {
				p_idx = nd.parent_idx
				d = min(meta[p_idx].depth + 1, MAX_TREE_DEPTH - 1)
			} else {
				d = 0
				p_idx = -1
			}
			prev_depth = d

			// Clear deeper sibling tracking when moving up/across to depth `d`
			for clear_d := d + 1; clear_d < MAX_TREE_DEPTH; clear_d += 1 {
				last_child_at_depth[clear_d] = -1
				ancestor_at_depth[clear_d]   = -1
			}

			node_hash := nd.id_hash
			if node_hash == 0 {
				if len(nd.id) > 0 {
					node_hash = hash_id(nd.id)
				} else {
					node_hash = hash_local_id(id_h, nd.label) ~ u64(d + 1)
				}
			}

			meta[i] = Tree_Node_Meta{
				id_hash        = node_hash,
				parent_idx     = p_idx,
				first_child    = -1,
				next_sibling   = -1,
				depth          = d,
				has_children   = nd.has_children,
				default_expand = nd.expanded,
			}

			if d >= 0 && d < MAX_TREE_DEPTH {
				prev_sib := last_child_at_depth[d]
				if prev_sib >= 0 && meta[prev_sib].parent_idx == p_idx {
					meta[prev_sib].next_sibling = i
				}
				last_child_at_depth[d] = i
				ancestor_at_depth[d]   = i
			}

			if p_idx >= 0 && p_idx < i {
				meta[p_idx].has_children = true
				if meta[p_idx].first_child < 0 {
					meta[p_idx].first_child = i
				}
			}
		}

		// Seed expand/collapse state after `has_children` has been resolved across all parent-child links
		for i: i32 = 0; i < n; i += 1 {
			_ = tree_slot_seed_expanded(t_slot, i, meta[i].id_hash, meta[i].has_children, meta[i].default_expand)
		}

		t_slot.meta            = meta
		t_slot.vis_to_node     = vis_to_node
		t_slot.last_layout_gen = ctx.layout_gen
		if t_slot.selected_node_hash != 0 {
			for i: i32 = 0; i < n; i += 1 {
				if meta[i].id_hash == t_slot.selected_node_hash {
					t_slot.selected_node_idx = i
					break
				}
			}
		}
		if t_slot.selected_node_idx < 0 || t_slot.selected_node_idx >= n {
			t_slot.selected_node_idx = 0
		}
		rebuild_tree_visible_rows(t_slot)
	} else {
		t_slot.meta               = nil
		t_slot.vis_to_node        = nil
		t_slot.total_nodes        = 0
		t_slot.total_visible_rows = 0
		t_slot.selected_vis_row   = 0
		t_slot.selected_node_idx  = -1
		t_slot.last_layout_gen    = ctx.layout_gen
	}

	if s_slot.viewport_rows <= 0 {
		s_slot.viewport_rows = cfg.fallback_rows if cfg.fallback_rows > 0 else 10
	}
	prev_total_rows := s_slot.total_rows
	prev_sel_row    := s_slot.selected_row
	s_slot.total_rows     = t_slot.total_visible_rows
	s_slot.total_cols     = 1
	s_slot.max_offset     = max(0, s_slot.total_rows - s_slot.viewport_rows)
	s_slot.selected_row   = clamp(t_slot.selected_vis_row, 0, max(0, s_slot.total_rows - 1))
	s_slot.scroll_padding = max(0, cfg.scroll_padding)
	if s_slot.total_rows != prev_total_rows || s_slot.selected_row != prev_sel_row {
		move_virtual_selection(s_slot, 0)
	}
	s_slot.offset = clamp(s_slot.offset, 0, s_slot.max_offset)

	start_r := s_slot.offset
	end_r   := min(s_slot.total_rows, start_r + s_slot.viewport_rows)

	auto_w := compute_tree_auto_width(
		nodes,
		cfg.border,
		cfg.leaf_prefix,
		cfg.width_percentile if cfg.width_percentile > 0 else 95,
		cfg.min_auto_width,
		cfg.max_auto_width,
	)
	if len(cfg.title) > 0 {
		title_outer_w := string_display_width(cfg.title) + 4
		eff_max_w := max(auto_w, cfg.max_auto_width) if cfg.max_auto_width > 0 else max(auto_w, 56)
		auto_w = clamp(max(auto_w, title_outer_w), auto_w, eff_max_w)
	}
	t_slot.recommended_width = auto_w

	if out_slice != nil {
		out_slice^ = Tree_Slice{
			start_row          = start_r,
			end_row            = end_r,
			selected_vis_row   = t_slot.selected_vis_row,
			selected_node_idx  = t_slot.selected_node_idx,
			activated_node_idx = t_slot.activated_node_idx,
			scroll_offset      = s_slot.offset,
			viewport_rows      = s_slot.viewport_rows,
			total_visible_rows = t_slot.total_visible_rows,
			total_nodes        = t_slot.total_nodes,
			recommended_width  = auto_w,
		}
	}

	w: Axis_Size
	if cfg.width != nil {
		w = cfg.width
	} else if cfg.width_percentile < 0 {
		w = grow(1)
	} else {
		w = fixed(auto_w)
	}
	h := cfg.height if cfg.height != nil else grow(1)
	step := cfg.scroll_step if cfg.scroll_step > 0 else 3

	s.paints[id_h] = Paint_Spec{
		title       = cfg.title,
		fg          = cfg.fg,
		bg          = cfg.bg,
		border_fg   = cfg.border_fg,
		title_fg    = cfg.title_fg,
		title_style = {.Bold},
		fill_bg     = cfg.bg.kind != .Default,
	}

	tree_idx := push_node(ctx, id, Box_Config{
		dir                = .Column,
		width              = w,
		height             = h,
		border             = cfg.border,
		scrollable         = true,
		scroll_offset      = s_slot.offset,
		scroll_step        = step,
		virtual_total_rows = max(1, s_slot.total_rows),
		focus_flags        = cfg.focus_flags,
		focusable          = .Disabled not_in cfg.focus_flags,
	}, {0, 0})

	enter_container_node(ctx, tree_idx)
	defer exit_container_node(ctx)

	is_tree_focused := inp.focused_id == id_h
	guide_fg  := cfg.guide_fg if cfg.guide_fg.kind != .Default else (cfg.border_fg if cfg.border_fg.kind != .Default else cfg.fg)
	toggle_fg := cfg.toggle_fg if cfg.toggle_fg.kind != .Default else cfg.fg

	// Materialize ONLY the visible slice `[start_r ..< end_r]` inside the tree viewport
	for vis_r := start_r; vis_r < end_r; vis_r += 1 {
		node_idx := t_slot.vis_to_node[vis_r]
		nd := nodes[node_idx]
		m  := t_slot.meta[node_idx]
		is_sel := vis_r == t_slot.selected_vis_row

		prefix_str := format_tree_guide_prefix(t_slot.meta, node_idx, ctx.allocator)
		toggle_str := cfg.leaf_prefix
		if m.has_children {
			toggle_str = "▾ " if tree_slot_is_expanded(t_slot, node_idx) else "▸ "
		}

		row_fg := nd.fg if nd.fg.kind != .Default else cfg.fg
		row_bg := nd.bg if nd.bg.kind != .Default else cfg.bg
		row_style := nd.style

		if is_sel {
			if cfg.sel_fg.kind != .Default {
				row_fg = cfg.sel_fg
			}
			if cfg.sel_bg.kind != .Default {
				row_bg = cfg.sel_bg
			}
			if is_tree_focused {
				row_style += {.Bold, .Reverse}
			} else {
				row_style += {.Reverse}
			}
		}

		n_guide_fg := nd.guide_fg if nd.guide_fg.kind != .Default else guide_fg
		n_icon_fg  := nd.icon_fg if nd.icon_fg.kind != .Default else row_fg

		span_count := 1
		if len(prefix_str) > 0 {
			span_count += 1
		}
		if len(toggle_str) > 0 {
			span_count += 1
		}
		if len(nd.icon) > 0 {
			span_count += 1
		}

		spans := make([]Styled_Span, span_count, ctx.allocator)
		sp_i := 0
		if len(prefix_str) > 0 {
			spans[sp_i] = Styled_Span{
				text  = prefix_str,
				fg    = row_fg if is_sel && cfg.sel_fg.kind != .Default else n_guide_fg,
				bg    = row_bg,
				style = row_style,
			}
			sp_i += 1
		}
		if len(toggle_str) > 0 {
			spans[sp_i] = Styled_Span{
				text  = toggle_str,
				fg    = row_fg if is_sel && cfg.sel_fg.kind != .Default else toggle_fg,
				bg    = row_bg,
				style = row_style + ({.Bold} if m.has_children else {}),
			}
			sp_i += 1
		}
		if len(nd.icon) > 0 {
			icon_with_space := fmt.aprintf("%s ", nd.icon, allocator = ctx.allocator)
			spans[sp_i] = Styled_Span{
				text  = icon_with_space,
				fg    = row_fg if is_sel && cfg.sel_fg.kind != .Default else n_icon_fg,
				bg    = row_bg,
				style = row_style,
			}
			sp_i += 1
		}
		spans[sp_i] = Styled_Span{
			text  = nd.label,
			fg    = row_fg,
			bg    = row_bg,
			style = row_style,
		}

		full_text := fmt.aprintf("%s%s%s%s%s", prefix_str, toggle_str, nd.icon, " " if len(nd.icon) > 0 else "", nd.label, allocator = ctx.allocator)
		row_id_str := nd.id if len(nd.id) > 0 else fmt.aprintf("%s_row_%d", id, node_idx, allocator = ctx.allocator)

		row_node_idx := push_node(ctx, row_id_str, Box_Config{
			id_hash   = m.id_hash,
			width     = grow(1),
			height    = fixed(1),
			text      = full_text,
			clickable = true,
			hoverable = true,
		}, {string_display_width(full_text), 1})

		row_hash := ctx.nodes[row_node_idx].id_hash
		s.paints[row_hash] = Paint_Spec{
			text    = full_text,
			spans   = spans,
			fg      = row_fg,
			bg      = row_bg,
			style   = row_style,
			fill_bg = is_sel || row_bg.kind != .Default,
		}
	}

	return tree_idx
}

// =============================================================================
// Tree Keyboard, Paging & Mouse Routing Integration
// =============================================================================

@(private)
reset_tree_per_frame_flags :: proc "contextless" (inp: ^Input_State) {
	if inp == nil {
		return
	}
	for i := 0; i < MAX_TREE_SLOTS; i += 1 {
		if inp.tree_slots[i].id_hash != 0 {
			inp.tree_slots[i].activated_node_idx = -1
		}
	}
}

@(private)
sync_tree_selection_from_scroll :: proc "contextless" (inp: ^Input_State, id_hash: u64, selected_vis_row: i32) {
	t_slot := find_tree_slot(inp, id_hash)
	if t_slot == nil || t_slot.total_visible_rows <= 0 {
		return
	}
	clamped_vis := clamp(selected_vis_row, 0, t_slot.total_visible_rows - 1)
	t_slot.selected_vis_row = clamped_vis
	if int(clamped_vis) < len(t_slot.vis_to_node) {
		t_slot.selected_node_idx = t_slot.vis_to_node[clamped_vis]
		if t_slot.selected_node_idx >= 0 && int(t_slot.selected_node_idx) < len(t_slot.meta) {
			t_slot.selected_node_hash = t_slot.meta[t_slot.selected_node_idx].id_hash
		}
	}
}

@(private)
handle_tree_spatial_nav :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	t_slot: ^Tree_Slot,
	s_slot: ^Scroll_Slot,
	dir: Nav_Dir,
	count: i32,
) -> (handled: bool, res: Key_Result) {
	if t_slot == nil || t_slot.total_visible_rows <= 0 {
		return false, .Ignored
	}
	node := &ctx.nodes[node_idx]

	switch dir {
	case .Up, .Down:
		delta: i32 = (-1 if dir == .Up else +1) * count
		if (dir == .Down && s_slot.selected_row < s_slot.total_rows - 1) || (dir == .Up && s_slot.selected_row > 0) {
			_ = consume_repeat_count(inp)
			move_virtual_selection(s_slot, delta)
			sync_tree_selection_from_scroll(inp, node.id_hash, s_slot.selected_row)
			node.config.scroll_offset = s_slot.offset
			inp.scrolled_id = node.id_hash
			return true, .Consumed
		}
		if s_slot.total_rows > 1 && ((.Loop_Spatial in node.focus_flags) || (.Wrap_Spatial in node.focus_flags)) {
			wrapped := s_slot.total_rows - 1 if dir == .Up else 0
			_ = consume_repeat_count(inp)
			move_virtual_selection(s_slot, wrapped - s_slot.selected_row)
			sync_tree_selection_from_scroll(inp, node.id_hash, s_slot.selected_row)
			node.config.scroll_offset = s_slot.offset
			inp.scrolled_id = node.id_hash
			return true, .Consumed
		}
		if .Strict_Spatial in node.focus_flags {
			_ = consume_repeat_count(inp)
			return true, .Consumed
		}
		return true, .Ignored

	case .Right:
		sel_idx := t_slot.selected_node_idx
		if sel_idx >= 0 && int(sel_idx) < len(t_slot.meta) {
			m := t_slot.meta[sel_idx]
			if m.has_children {
				if !tree_slot_is_expanded(t_slot, sel_idx) {
					_ = consume_repeat_count(inp)
					tree_slot_set_expanded(t_slot, sel_idx, true)
					rebuild_tree_visible_rows(t_slot)
					sync_tree_scroll_slot(inp, ctx, node_idx, t_slot, s_slot)
					inp.scrolled_id = node.id_hash
					return true, .Consumed
				} else if m.first_child >= 0 && t_slot.selected_vis_row + 1 < t_slot.total_visible_rows {
					_ = consume_repeat_count(inp)
					move_virtual_selection(s_slot, +1)
					sync_tree_selection_from_scroll(inp, node.id_hash, s_slot.selected_row)
					node.config.scroll_offset = s_slot.offset
					inp.scrolled_id = node.id_hash
					return true, .Consumed
				}
			}
		}
		if .Strict_Spatial in node.focus_flags {
			_ = consume_repeat_count(inp)
			return true, .Consumed
		}
		return true, .Ignored

	case .Left:
		sel_idx := t_slot.selected_node_idx
		if sel_idx >= 0 && int(sel_idx) < len(t_slot.meta) {
			m := t_slot.meta[sel_idx]
			if m.has_children && tree_slot_is_expanded(t_slot, sel_idx) {
				// Collapse expanded branch in-place
				_ = consume_repeat_count(inp)
				tree_slot_set_expanded(t_slot, sel_idx, false)
				rebuild_tree_visible_rows(t_slot)
				sync_tree_scroll_slot(inp, ctx, node_idx, t_slot, s_slot)
				inp.scrolled_id = node.id_hash
				return true, .Consumed
			} else if m.parent_idx >= 0 {
				// Jump directly to parent node and auto-scroll viewport to keep parent visible
				_ = consume_repeat_count(inp)
				parent_idx := m.parent_idx
				parent_vis: i32 = -1
				for v: i32 = 0; v < t_slot.total_visible_rows; v += 1 {
					if t_slot.vis_to_node[v] == parent_idx {
						parent_vis = v
						break
					}
				}
				if parent_vis >= 0 {
					move_virtual_selection(s_slot, parent_vis - s_slot.selected_row)
					sync_tree_selection_from_scroll(inp, node.id_hash, s_slot.selected_row)
					node.config.scroll_offset = s_slot.offset
					inp.scrolled_id = node.id_hash
					return true, .Consumed
				}
			}
		}
		if .Strict_Spatial in node.focus_flags {
			_ = consume_repeat_count(inp)
			return true, .Consumed
		}
		return true, .Ignored
	}
	return false, .Ignored
}

@(private)
handle_tree_activate_key :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
) -> bool {
	if node_idx < 0 || int(node_idx) >= len(ctx.nodes) {
		return false
	}
	node := ctx.nodes[node_idx]
	t_slot := find_tree_slot(inp, node.id_hash)
	if t_slot == nil || t_slot.total_visible_rows <= 0 {
		return false
	}
	sel_idx := t_slot.selected_node_idx
	if sel_idx < 0 || int(sel_idx) >= len(t_slot.meta) {
		return true
	}
	s_slot := get_scroll_slot(inp, node.id_hash)
	m := t_slot.meta[sel_idx]
	if m.has_children {
		tree_slot_set_expanded(t_slot, sel_idx, !tree_slot_is_expanded(t_slot, sel_idx))
		rebuild_tree_visible_rows(t_slot)
		sync_tree_scroll_slot(inp, ctx, node_idx, t_slot, s_slot)
		inp.scrolled_id = node.id_hash
	} else {
		t_slot.activated_node_idx = sel_idx
		inp.activated_id = m.id_hash
	}
	return true
}

@(private)
handle_tree_mouse_click :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	tree_node_idx: i32,
	capture_idx: i32,
	my: i32,
) -> bool {
	if tree_node_idx < 0 || int(tree_node_idx) >= len(ctx.nodes) {
		return false
	}
	v_node := ctx.nodes[tree_node_idx]
	t_slot := find_tree_slot(inp, v_node.id_hash)
	if t_slot == nil {
		return false
	}

	if is_node_focusable(v_node) && is_node_allowed(ctx, tree_node_idx, capture_idx) {
		reset_preferred_nav(inp)
		set_focused_node(inp, ctx, tree_node_idx, capture_idx, false)
	}

	s_slot := get_scroll_slot(inp, v_node.id_hash)
	rel_y := my - v_node.inner_rect.y
	if rel_y >= 0 && rel_y < v_node.inner_rect.h && t_slot.total_visible_rows > 0 {
		target_vis := s_slot.offset + rel_y
		if target_vis < 0 || target_vis >= t_slot.total_visible_rows {
			return true
		}
		vis_row := target_vis
		s_slot.selected_row     = vis_row
		t_slot.selected_vis_row = vis_row
		clicked_node_idx := t_slot.vis_to_node[vis_row]
		t_slot.selected_node_idx = clicked_node_idx

		if clicked_node_idx >= 0 && int(clicked_node_idx) < len(t_slot.meta) {
			m := t_slot.meta[clicked_node_idx]
			t_slot.selected_node_hash = m.id_hash
			if m.has_children {
				tree_slot_set_expanded(t_slot, clicked_node_idx, !tree_slot_is_expanded(t_slot, clicked_node_idx))
				rebuild_tree_visible_rows(t_slot)
				sync_tree_scroll_slot(inp, ctx, tree_node_idx, t_slot, s_slot)
				inp.scrolled_id = v_node.id_hash
			} else {
				t_slot.activated_node_idx = clicked_node_idx
				inp.activated_id = m.id_hash
			}
		}
	}
	return true
}

// =============================================================================
// Public Query & State Helpers for `ui_tree`
// =============================================================================

get_tree_selected_node :: proc(inp: ^Input_State, id: string) -> i32 {
	t_slot := find_tree_slot(inp, hash_id(id))
	if t_slot == nil {
		return -1
	}
	return t_slot.selected_node_idx
}

get_tree_selected_vis_row :: proc(inp: ^Input_State, id: string) -> i32 {
	t_slot := find_tree_slot(inp, hash_id(id))
	if t_slot == nil {
		return 0
	}
	return t_slot.selected_vis_row
}

get_tree_activated_node :: proc(inp: ^Input_State, id: string) -> i32 {
	t_slot := find_tree_slot(inp, hash_id(id))
	if t_slot == nil {
		return -1
	}
	return t_slot.activated_node_idx
}

get_tree_visible_row_count :: proc(inp: ^Input_State, id: string) -> i32 {
	t_slot := find_tree_slot(inp, hash_id(id))
	if t_slot == nil {
		return 0
	}
	return t_slot.total_visible_rows
}

get_tree_recommended_width :: proc(inp: ^Input_State, id: string) -> i32 {
	t_slot := find_tree_slot(inp, hash_id(id))
	if t_slot == nil {
		return 0
	}
	return t_slot.recommended_width
}

is_tree_node_expanded :: proc(inp: ^Input_State, id: string, node_idx: i32) -> bool {
	t_slot := find_tree_slot(inp, hash_id(id))
	return tree_slot_is_expanded(t_slot, node_idx)
}

set_tree_node_expanded :: proc(inp: ^Input_State, id: string, node_idx: i32, expanded: bool) {
	t_slot := get_tree_slot(inp, hash_id(id))
	tree_slot_set_expanded(t_slot, node_idx, expanded)
	if len(t_slot.meta) > 0 {
		rebuild_tree_visible_rows(t_slot)
	}
}
