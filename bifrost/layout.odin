package bifrost

import "core:hash"
import "core:mem"
import "../deps/heimdall/heimdall"

// =============================================================================
// Core Layout Types & Sizing Primitives
// =============================================================================

Direction :: enum u8 {
	Row,    // Main axis = X (0), Cross axis = Y (1)
	Column, // Main axis = Y (1), Cross axis = X (0)
}

Alignment :: enum u8 {
	Start,
	Center,
	End,
}

Border_Kind :: enum u8 {
	None,
	Plain,
	Rounded,
	Double,
}

Anchor_Mode :: enum u8 {
	Screen, // Position out-of-flow node relative to the full terminal screen
	Parent, // Position out-of-flow node relative to its parent's outer Rect (or anchor_parent_id)
}

Anchor_Point :: enum u8 {
	Top_Left = 0,
	Top_Center,
	Top_Right,
	Center_Left,
	Center,
	Center_Right,
	Bottom_Left,
	Bottom_Center,
	Bottom_Right,
}

Wrap_Mode :: enum u8 {
	None = 0,
	Words,
	Newlines,
}

MAX_SCOPE_DEPTH :: 32

Focus_Flag :: enum u8 {
	Focusable,       // Leaf or container can hold input.focused_id
	Focus_Scope,     // Establishes a hierarchical focus scope & Scope_Memory_Entry
	Trap_Focus,      // Modal barrier: traps Tab/F6/2D nav & halts ancestor memory writes
	Captures_Text,   // Consumes printable runes, Backspace, Delete, Left/Right when editing
	Auto_Edit,       // Enters edit mode (editing_id = id_hash) automatically upon focus
	Loop_Spatial,    // Wrap 2D spatial nav along main axis (Bottom -> Top, Right -> Left)
	Wrap_Spatial,    // Reading-order wrap on 2D grids (Right of row r -> col 0 of row r+1)
	Strict_Spatial,  // Restrict 2D spatial cone strictly to half-plane without wrap
	Default_Focus,   // Preferred initial child when scope has no prior Scope_Memory_Entry
	Scope_Text_Sink, // Delegates printable keys within enclosing scope to this text input
	Disabled,        // Mounted & painted dimmed, but pruned from focus/hit-testing; auto-advances if focused
}

Focus_Flags :: bit_set[Focus_Flag; u16]

MAX_DIM     :: i32(0x3fff_ffff)
FNV64A_OFFSET :: u64(0xcbf29ce484222325)
FNV64A_PRIME  :: u64(0x100000001b3)

// Sizing modes. A zero-initialized Axis_Size (nil) defaults to unconstrained Fit.
Fit :: struct {
	min: i32,
	max: i32, // 0 = unconstrained
}

Grow :: struct {
	weight: i32, // <= 0 defaults to 1
	min:    i32,
	max:    i32, // 0 = unconstrained
}

Fixed :: distinct i32

Percent :: struct {
	fraction: f32, // 0.0 ..= 1.0
	min:      i32,
	max:      i32, // 0 = unconstrained
}

Axis_Size :: union {
	Fit,
	Grow,
	Fixed,
	Percent,
}

Padding :: struct {
	left:   i32,
	right:  i32,
	top:    i32,
	bottom: i32,
}

Rect :: struct {
	x: i32,
	y: i32,
	w: i32,
	h: i32,
}

Box_Config :: struct {
	dir:                Direction,
	width:              Axis_Size,
	height:             Axis_Size,
	padding:            Padding,
	gap:                i32,
	border:             Border_Kind,
	main_align:         Alignment,
	cross_align:        Alignment,
	wrap_mode:          Wrap_Mode,
	text:               string,

	// Z-layer & overlay positioning
	z_layer:            u8,
	floating:           bool,
	anchor:             Anchor_Mode,
	anchor_parent_id:   string,
	parent_anchor:      Anchor_Point,
	element_anchor:     Anchor_Point,
	self_align:         [2]Alignment, // [0] = horizontal, [1] = vertical alignment inside anchor rect
	offset:             [2]i32,       // [x, y] offset from aligned anchor position
	expand:             [2]i32,       // [x, y] bounding expansion for floating nodes
	clip_to_parent:     bool,
	clamp_to_screen:    bool,

	// Focus, input routing & widget role flags
	focus_flags:        Focus_Flags,
	id_hash:            u64,
	local_id:           bool,
	focusable:          bool,
	clickable:          bool,
	hoverable:          bool,
	draggable:          bool,
	focus_scope:        bool,
	capture_input:      bool,
	scrollable:         bool,
	scroll_step:        i32,
	scroll_offset:      i32,
	scroll_offset_x:    i32,
	virtual_total_rows: i32,
	text_input:         bool,
	text_area:          bool,
	splitter:           bool,
	slider:             bool,
	nav_overrides:      [Nav_Dir]u64, // Optional per-direction target node id_hash overrides
}

// Convenience builder for a single directional focus override on `Box_Config` / `Scope_Config`.
nav_target :: proc "contextless" (dir: Nav_Dir, target_id: string) -> (overrides: [Nav_Dir]u64) {
	if len(target_id) > 0 {
		overrides[dir] = hash_local_id(0, target_id)
	}
	return
}

Layout_Node :: struct {
	id:               string,
	id_hash:          u64,
	config:           Box_Config,
	parent_idx:       i32,
	parent_scope_idx: i32,
	subtree_end_idx:  i32,
	text_sink_idx:    i32,
	focus_flags:      Focus_Flags,
	first_child:      i32,
	last_child:       i32,
	next_sibling:     i32,
	child_count:      i32,
	content_size:     [2]i32,
	computed_size:    [2]i32,
	dims:             [2]i32,
	min_dims:         [2]i32,
	content_span:            [2]i32,
	applied_scroll_offset:   i32,
	applied_scroll_offset_x: i32,
	rect:                    Rect,
	inner_rect:            Rect,
	node_clip:             Rect,
	inner_clip:            Rect,
	scope_id:              u64,
	effective_z:           u8,
	out_of_flow:           bool,
	frozen:                bool,
	is_text:               bool,
	text:                  string,
	wrapped_lines:         []string,
	para_spans:            []Styled_Span,
	md_source:             string,
	md_cfg:                Markdown_Config,
	has_markdown:          bool,
	wrapped_span_lines:    [][]Styled_Span,
	wrapped_span_w:        i32,
}

Measure_Text_Intrinsic_Proc :: #type proc "contextless" (
	text:     string,
	userdata: rawptr,
) -> (unwrapped_w, longest_word, line_count: i32)

Layout_Context :: struct {
	nodes:            [dynamic]Layout_Node,
	parent_stack:     [dynamic]i32,
	scope_stack:      [MAX_SCOPE_DEPTH]i32,
	scope_stack_len:  int,
	id_map:           map[u64]i32,
	z_order:          []i32,
	screen_size:      [2]i32,
	layout_gen:       u64,
	allocator:        mem.Allocator,
	recorder:         ^heimdall.Recorder,
	measure_text_fn:  Measure_Text_Intrinsic_Proc,
	measure_userdata: rawptr,
}

// =============================================================================
// Ergonomic Sizing, Geometry & Hashing Helpers
// =============================================================================

fit :: #force_inline proc(min: i32 = 0, max: i32 = 0) -> Axis_Size {
	return Fit{min = min, max = max}
}

grow :: #force_inline proc(weight: i32 = 1, min: i32 = 0, max: i32 = 0) -> Axis_Size {
	w := weight if weight > 1 else 1
	return Grow{weight = w, min = min, max = max}
}

fixed :: #force_inline proc(cells: i32) -> Axis_Size {
	return Fixed(cells)
}

percent :: #force_inline proc(fraction: f32, min: i32 = 0, max: i32 = 0) -> Axis_Size {
	norm := fraction / 100.0 if fraction > 1.0 else fraction
	return Percent{fraction = clamp(norm, 0.0, 1.0), min = min, max = max}
}

pad_all :: #force_inline proc(p: i32) -> Padding {
	return Padding{left = p, right = p, top = p, bottom = p}
}

pad_xy :: #force_inline proc(x, y: i32) -> Padding {
	return Padding{left = x, right = x, top = y, bottom = y}
}

hash_id :: #force_inline proc(id: string) -> u64 {
	return hash.fnv64a(transmute([]byte)id)
}

// Clay-inspired zero-allocation local ID hashing seeded by `parent_hash`.
// When `parent_hash == 0`, produces the exact same FNV-1a 64-bit hash as `hash_id(label)`.
hash_local_id :: #force_inline proc "contextless" (parent_hash: u64, label: string) -> u64 {
	h := FNV64A_OFFSET
	if parent_hash != 0 {
		h = (parent_hash ~ u64(0x1f)) * FNV64A_PRIME
	}
	for i := 0; i < len(label); i += 1 {
		h = (h ~ u64(label[i])) * FNV64A_PRIME
	}
	return h
}

// Clay-inspired indexed local ID hashing (`CLAY_IDI_LOCAL` equivalent) without `fmt.tprintf` allocations.
hash_local_idi :: #force_inline proc "contextless" (parent_hash: u64, label: string, index: i32) -> u64 {
	h := hash_local_id(parent_hash, label)
	h = (h ~ u64(0x1e)) * FNV64A_PRIME
	u := u32(index)
	h = (h ~ u64(u & 0xff)) * FNV64A_PRIME
	h = (h ~ u64((u >> 8) & 0xff)) * FNV64A_PRIME
	h = (h ~ u64((u >> 16) & 0xff)) * FNV64A_PRIME
	h = (h ~ u64((u >> 24) & 0xff)) * FNV64A_PRIME
	return h
}

current_scope_hash :: #force_inline proc "contextless" (ctx: ^Layout_Context) -> u64 {
	if ctx.scope_stack_len > 0 {
		s_idx := ctx.scope_stack[ctx.scope_stack_len - 1]
		if s_idx >= 0 && int(s_idx) < len(ctx.nodes) {
			return ctx.nodes[s_idx].id_hash
		}
	}
	return 0
}

rect_intersect :: #force_inline proc "contextless" (a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 {
		return Rect{x = x0, y = y0, w = 0, h = 0}
	}
	return Rect{
		x = x0,
		y = y0,
		w = x1 - x0,
		h = y1 - y0,
	}
}

point_in_rect :: #force_inline proc "contextless" (x, y: i32, r: Rect) -> bool {
	return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// =============================================================================
// Declarative Tree Construction API
// =============================================================================

begin_layout :: proc(ctx: ^Layout_Context, screen_w, screen_h: i32, allocator := context.temp_allocator) {
	ctx.nodes           = make([dynamic]Layout_Node, 0, 128, allocator)
	ctx.parent_stack    = make([dynamic]i32, 0, 32, allocator)
	ctx.scope_stack_len = 0
	ctx.id_map          = make(map[u64]i32, 128, allocator)
	ctx.z_order         = nil
	ctx.screen_size     = {screen_w, screen_h}
	ctx.layout_gen     += 1
	ctx.allocator       = allocator
}

enter_container_node :: proc(ctx: ^Layout_Context, idx: i32) {
	append(&ctx.parent_stack, idx)
	if idx >= 0 && int(idx) < len(ctx.nodes) {
		if .Focus_Scope in ctx.nodes[idx].focus_flags {
			if ctx.scope_stack_len < MAX_SCOPE_DEPTH {
				ctx.scope_stack[ctx.scope_stack_len] = idx
				ctx.scope_stack_len += 1
			}
		}
	}
}

exit_container_node :: proc(ctx: ^Layout_Context) {
	if len(ctx.parent_stack) == 0 {
		return
	}
	idx := pop(&ctx.parent_stack)
	if idx >= 0 && int(idx) < len(ctx.nodes) {
		ctx.nodes[idx].subtree_end_idx = i32(len(ctx.nodes))
		if ctx.scope_stack_len > 0 && ctx.scope_stack[ctx.scope_stack_len - 1] == idx {
			ctx.scope_stack_len -= 1
		}
	}
}

@(deferred_in = defer_end_container)
container :: proc(ctx: ^Layout_Context, id: string, cfg: Box_Config = {}) -> bool {
	idx := push_node(ctx, id, cfg, {0, 0})
	enter_container_node(ctx, idx)
	return true
}

defer_end_container :: proc(ctx: ^Layout_Context, id: string, cfg: Box_Config = {}) {
	exit_container_node(ctx)
}

leaf :: proc(ctx: ^Layout_Context, id: string, content_w, content_h: i32, cfg: Box_Config = {}) -> i32 {
	return push_node(ctx, id, cfg, {content_w, content_h})
}

push_node :: proc(ctx: ^Layout_Context, id: string, cfg: Box_Config, content_size: [2]i32) -> i32 {
	idx := i32(len(ctx.nodes))
	parent_idx := i32(-1)
	if len(ctx.parent_stack) > 0 {
		parent_idx = ctx.parent_stack[len(ctx.parent_stack) - 1]
	}

	parent_scope_idx := i32(-1)
	if ctx.scope_stack_len > 0 {
		parent_scope_idx = ctx.scope_stack[ctx.scope_stack_len - 1]
	}

	// Synthesize unified Focus_Flags from explicit focus_flags + legacy Box_Config booleans
	flags := cfg.focus_flags
	if idx == 0 {
		flags += {.Focus_Scope}
	}
	if cfg.focusable {
		flags += {.Focusable}
	}
	if cfg.focus_scope {
		flags += {.Focus_Scope}
	}
	if cfg.capture_input {
		flags += {.Focus_Scope, .Trap_Focus}
	}
	if .Trap_Focus in flags {
		flags += {.Focus_Scope}
	}
	if .Scope_Text_Sink in flags {
		flags += {.Captures_Text}
	}
	if cfg.text_input || cfg.text_area {
		flags += {.Captures_Text}
		if cfg.focus_flags == {} {
			flags += {.Auto_Edit}
		}
	}
	if parent_idx >= 0 && (.Disabled in ctx.nodes[parent_idx].focus_flags) {
		flags += {.Disabled}
	}

	node_cfg := cfg
	node_cfg.focus_flags = flags
	if .Disabled in flags {
		node_cfg.focusable     = false
		node_cfg.capture_input = false
	} else {
		if .Focusable in flags {
			node_cfg.focusable = true
		}
		if .Trap_Focus in flags {
			node_cfg.capture_input = true
		}
	}
	if idx > 0 && (.Focus_Scope in flags) {
		node_cfg.focus_scope = true
	}
	if (.Captures_Text in flags) && !node_cfg.text_area {
		node_cfg.text_input = true
	}

	id_hash: u64
	if node_cfg.id_hash != 0 {
		id_hash = node_cfg.id_hash
	} else if len(id) > 0 {
		if node_cfg.local_id && parent_scope_idx >= 0 {
			id_hash = hash_local_id(ctx.nodes[parent_scope_idx].id_hash, id)
		} else {
			id_hash = hash_id(id)
		}
	} else {
		id_hash = u64(idx + 1)
	}

	node := Layout_Node{
		id               = id,
		id_hash          = id_hash,
		config           = node_cfg,
		parent_idx       = parent_idx,
		parent_scope_idx = parent_scope_idx,
		subtree_end_idx  = idx + 1,
		text_sink_idx    = -1,
		focus_flags      = flags,
		first_child      = -1,
		last_child       = -1,
		next_sibling     = -1,
		content_size     = content_size,
		is_text          = len(node_cfg.text) > 0,
		text             = node_cfg.text,
	}

	if (.Scope_Text_Sink in flags) && (.Disabled not_in flags) && parent_scope_idx >= 0 {
		if ctx.nodes[parent_scope_idx].text_sink_idx < 0 {
			ctx.nodes[parent_scope_idx].text_sink_idx = idx
		}
	}

	if parent_idx >= 0 {
		parent := &ctx.nodes[parent_idx]
		if parent.first_child == -1 {
			parent.first_child = idx
		} else {
			ctx.nodes[parent.last_child].next_sibling = idx
		}
		parent.last_child = idx
		parent.child_count += 1
	}

	append(&ctx.nodes, node)
	if len(id) > 0 || node_cfg.id_hash != 0 {
		ctx.id_map[id_hash] = idx
	}
	return idx
}

get_rect :: proc(ctx: ^Layout_Context, id: string) -> (rect: Rect, ok: bool) {
	idx, found := ctx.id_map[hash_id(id)]
	if !found {
		return {}, false
	}
	return ctx.nodes[idx].rect, true
}

get_inner_rect :: proc(ctx: ^Layout_Context, id: string) -> (rect: Rect, ok: bool) {
	idx, found := ctx.id_map[hash_id(id)]
	if !found {
		return {}, false
	}
	return ctx.nodes[idx].inner_rect, true
}

get_node_clip :: proc(ctx: ^Layout_Context, id: string) -> (rect: Rect, ok: bool) {
	idx, found := ctx.id_map[hash_id(id)]
	if !found {
		return {}, false
	}
	return ctx.nodes[idx].node_clip, true
}

// =============================================================================
// Clay-Inspired Multi-Pass Topological Layout Solver
// =============================================================================

end_layout :: proc(ctx: ^Layout_Context) {
	rec := resolve_recorder(ctx.recorder)
	heimdall.scoped_span(rec, TELEMETRY_SCOPE_LAYOUT, "end_layout", i64(len(ctx.nodes)))
	heimdall.gauge_set(rec, TELEMETRY_SCOPE_LAYOUT, "layout_nodes", f64(len(ctx.nodes)), i64(ctx.layout_gen))

	if len(ctx.nodes) == 0 {
		return
	}

	// =========================================================================
	// PASS 0: Propagate effective_z, out_of_flow, and scope_id
	// =========================================================================
	for i := 0; i < len(ctx.nodes); i += 1 {
		node := &ctx.nodes[i]
		if node.parent_idx >= 0 {
			parent := ctx.nodes[node.parent_idx]
			node.effective_z = max(parent.effective_z, node.config.z_layer)
			node.out_of_flow = node.config.floating || (node.config.z_layer > parent.effective_z)
			node.scope_id    = parent.scope_id
		} else {
			node.effective_z = node.config.z_layer
			node.out_of_flow = node.config.floating
			node.scope_id    = 0
		}
		if node.config.focus_scope || node.config.capture_input {
			node.scope_id = node.id_hash
		}
	}

	// =========================================================================
	// PASS 1: Bottom-Up Intrinsic & Min Sizing (Reverse Topological Order)
	// =========================================================================
	for i := len(ctx.nodes) - 1; i >= 0; i -= 1 {
		node := &ctx.nodes[i]
		insets := compute_total_insets(node.config)
		main_axis := 0 if node.config.dir == .Row else 1
		cross_axis := 1 - main_axis

		intrinsic: [2]i32
		min_intrinsic: [2]i32

		in_flow_count: i32 = 0
		children_main: i32 = 0
		children_cross: i32 = 0
		min_main: i32 = 0
		min_cross: i32 = 0

		for c := node.first_child; c != -1; c = ctx.nodes[c].next_sibling {
			child := &ctx.nodes[c]
			if child.out_of_flow {
				continue
			}
			children_main  += child.dims[main_axis]
			children_cross  = max(children_cross, child.dims[cross_axis])
			min_main       += child.min_dims[main_axis]
			min_cross       = max(min_cross, child.min_dims[cross_axis])
			in_flow_count  += 1
		}

		if in_flow_count > 0 {
			gaps := (in_flow_count - 1) * node.config.gap if in_flow_count > 1 else 0
			children_main += gaps
			min_main      += gaps

			intrinsic[main_axis]      = children_main + insets[main_axis]
			intrinsic[cross_axis]     = children_cross + insets[cross_axis]
			min_intrinsic[main_axis]  = insets[main_axis] if node.config.scrollable else (min_main + insets[main_axis])
			min_intrinsic[cross_axis] = insets[cross_axis] if node.config.scrollable else (min_cross + insets[cross_axis])
		} else if len(node.text) > 0 {
			unwrapped_w, longest_word, line_count: i32
			if ctx.measure_text_fn != nil {
				unwrapped_w, longest_word, line_count = ctx.measure_text_fn(node.text, ctx.measure_userdata)
			} else {
				unwrapped_w, longest_word, line_count = measure_text_intrinsic(node.text)
			}
			base_w := max(node.content_size[0], unwrapped_w)
			base_h := max(node.content_size[1], line_count)
			min_w  := longest_word if node.config.wrap_mode == .Words else base_w

			intrinsic[0]     = base_w + insets[0]
			intrinsic[1]     = base_h + insets[1]
			min_intrinsic[0] = insets[0] if node.config.scrollable else (min_w + insets[0])
			min_intrinsic[1] = insets[1] if node.config.scrollable else (line_count + insets[1])
		} else {
			intrinsic[0]     = node.content_size[0] + insets[0]
			intrinsic[1]     = node.content_size[1] + insets[1]
			min_intrinsic[0] = insets[0]
			min_intrinsic[1] = insets[1]
		}

		node.dims[0], node.min_dims[0] = resolve_pass1_axis_with_min(node.config.width, intrinsic[0], min_intrinsic[0])
		node.dims[1], node.min_dims[1] = resolve_pass1_axis_with_min(node.config.height, intrinsic[1], min_intrinsic[1])
		node.computed_size = node.dims
	}

	// =========================================================================
	// PASS 2: Top-Down X-Axis Sizing (Percent, Water-Filling Grow & Compression)
	// =========================================================================
	size_axis(ctx, 0)

	// =========================================================================
	// PASS 3 & 4: Text Wrapping & Bottom-Up Height Re-Propagation
	// =========================================================================
	wrap_text_and_repropagate_heights(ctx)

	// =========================================================================
	// PASS 5: Top-Down Y-Axis Sizing, 9-Point Anchoring & Coordinate Assignment
	// =========================================================================
	size_axis(ctx, 1)
	position_nodes_topological(ctx)

	// =========================================================================
	// PASS 6: Stable Insertion Sort of Node Indices by effective_z Ascending
	// =========================================================================
	node_count := len(ctx.nodes)
	ctx.z_order = make([]i32, node_count, ctx.allocator)
	for i := 0; i < node_count; i += 1 {
		ctx.z_order[i] = i32(i)
	}
	for i := 1; i < node_count; i += 1 {
		key := ctx.z_order[i]
		key_z := ctx.nodes[key].effective_z
		j := i - 1
		for j >= 0 && ctx.nodes[ctx.z_order[j]].effective_z > key_z {
			ctx.z_order[j + 1] = ctx.z_order[j]
			j -= 1
		}
		ctx.z_order[j + 1] = key
	}
}

// =============================================================================
// Internal Solver Passes & Helpers
// =============================================================================

measure_text_intrinsic :: proc "contextless" (text: string) -> (unwrapped_w, longest_word, line_count: i32) {
	line_count = 1
	cur_line_w: i32 = 0
	cur_word_w: i32 = 0
	for r in text {
		if r == '\n' {
			unwrapped_w  = max(unwrapped_w, cur_line_w)
			longest_word = max(longest_word, cur_word_w)
			cur_line_w   = 0
			cur_word_w   = 0
			line_count  += 1
			continue
		}
		w := i32(rune_display_width(r))
		cur_line_w += w
		if r == ' ' {
			longest_word = max(longest_word, cur_word_w)
			cur_word_w   = 0
		} else {
			cur_word_w += w
		}
	}
	unwrapped_w  = max(unwrapped_w, cur_line_w)
	longest_word = max(longest_word, cur_word_w)
	return unwrapped_w, longest_word, line_count
}

@(private)
size_axis :: proc(ctx: ^Layout_Context, axis: int) {
	resizable := make([dynamic]i32, 0, 32, ctx.allocator)

	for i := 0; i < len(ctx.nodes); i += 1 {
		parent := &ctx.nodes[i]

		// 1. Resolve root and out-of-flow overlay dimensions along `axis`
		if i == 0 || parent.out_of_flow {
			ref_dim := ctx.screen_size[axis]
			if i > 0 && parent.out_of_flow {
				if len(parent.config.anchor_parent_id) > 0 {
					if p_idx, ok := ctx.id_map[hash_id(parent.config.anchor_parent_id)]; ok {
						ref_dim = ctx.nodes[p_idx].dims[axis]
					}
				} else if parent.config.anchor == .Parent && parent.parent_idx >= 0 {
					ref_dim = ctx.nodes[parent.parent_idx].dims[axis]
				}
			}

			sizing := parent.config.width if axis == 0 else parent.config.height
			switch s in sizing {
			case Grow:
				parent.dims[axis] = clamp_bounds(ref_dim, s.min, s.max)
			case Percent:
				raw := i32(f32(ref_dim) * s.fraction + 0.5)
				parent.dims[axis] = clamp_bounds(raw, s.min, s.max)
			case Fixed:
				parent.dims[axis] = i32(s)
			case Fit:
				parent.dims[axis] = clamp_bounds(parent.dims[axis], s.min, s.max)
			case nil:
			}
			parent.computed_size[axis] = parent.dims[axis]
		}

		if parent.child_count == 0 {
			continue
		}

		main_axis := 0 if parent.config.dir == .Row else 1
		along_axis := (axis == main_axis)
		insets := compute_total_insets(parent.config)
		inner_avail := max(0, parent.dims[axis] - insets[axis])

		in_flow_count: i32 = 0
		for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
			if !ctx.nodes[c].out_of_flow {
				in_flow_count += 1
			}
		}
		if in_flow_count == 0 {
			continue
		}

		total_gaps := (in_flow_count - 1) * parent.config.gap if (along_axis && in_flow_count > 1) else 0
		avail_for_pct := max(0, inner_avail - total_gaps)

		// 2. Resolve Percent children first against (inner_avail - total_gaps)
		for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
			child := &ctx.nodes[c]
			if child.out_of_flow {
				continue
			}
			c_sizing := child.config.width if axis == 0 else child.config.height
			if p, is_pct := c_sizing.(Percent); is_pct {
				raw := i32(f32(avail_for_pct) * p.fraction + 0.5)
				child.dims[axis]          = clamp_bounds(raw, p.min, p.max)
				child.min_dims[axis]      = child.dims[axis]
				child.computed_size[axis] = child.dims[axis]
			}
		}

		if along_axis {
			current_sum := total_gaps
			grow_count := 0
			has_custom_weights := false
			clear(&resizable)

			for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
				child := &ctx.nodes[c]
				if child.out_of_flow {
					continue
				}
				current_sum += child.dims[axis]
				c_sizing := child.config.width if axis == 0 else child.config.height
				switch s in c_sizing {
				case Grow:
					grow_count += 1
					if s.weight > 1 {
						has_custom_weights = true
					}
					append(&resizable, c)
				case Fit, nil:
					append(&resizable, c)
				case Fixed, Percent:
					// Non-resizable in water-draining/filling
				}
			}

			to_distribute := inner_avail - current_sum

			// 2a. Overflow compression (Water-Draining largest resizable children down to min_dims)
			if to_distribute < 0 && !parent.config.scrollable {
				// Filter resizable to children that can actually shrink (dims > min_dims)
				k := 0
				for k < len(resizable) {
					c_idx := resizable[k]
					if ctx.nodes[c_idx].dims[axis] <= ctx.nodes[c_idx].min_dims[axis] {
						ordered_remove(&resizable, k)
					} else {
						k += 1
					}
				}

				for to_distribute < 0 && len(resizable) > 0 {
					largest: i32 = 0
					second_largest: i32 = 0
					for c_idx in resizable {
						sz := ctx.nodes[c_idx].dims[axis]
						if sz > largest {
							second_largest = largest
							largest = sz
						} else if sz < largest {
							second_largest = max(second_largest, sz)
						}
					}
					if largest <= 0 {
						break
					}

					largest_count: i32 = 0
					for c_idx in resizable {
						if ctx.nodes[c_idx].dims[axis] == largest {
							largest_count += 1
						}
					}

					deficit := -to_distribute
					step_down := (largest - second_largest) if second_largest > 0 else largest
					if step_down * largest_count <= deficit {
						// Drain all tied largest down to second_largest (or their min_dims)
						m := 0
						for m < len(resizable) && to_distribute < 0 {
							c_idx := resizable[m]
							child := &ctx.nodes[c_idx]
							if child.dims[axis] == largest {
								prev := child.dims[axis]
								min_sz := child.min_dims[axis]
								child.dims[axis] = max(min_sz, prev - step_down)
								child.computed_size[axis] = child.dims[axis]
								to_distribute += (prev - child.dims[axis])
								if child.dims[axis] <= min_sz {
									ordered_remove(&resizable, m)
									continue
								}
							}
							m += 1
						}
					} else {
						// Final plateau: distribute exact integer deficit across tied largest children
						rem_deficit := -to_distribute
						seen_idx: i32 = 0
						prev_cut: i32 = 0
						m := 0
						for m < len(resizable) && to_distribute < 0 {
							c_idx := resizable[m]
							child := &ctx.nodes[c_idx]
							if child.dims[axis] == largest {
								seen_idx += 1
								next_cut := (rem_deficit * seen_idx) / largest_count
								cut := next_cut - prev_cut
								prev_cut = next_cut

								prev := child.dims[axis]
								min_sz := child.min_dims[axis]
								child.dims[axis] = max(min_sz, prev - cut)
								child.computed_size[axis] = child.dims[axis]
								to_distribute += (prev - child.dims[axis])
								if child.dims[axis] <= min_sz {
									ordered_remove(&resizable, m)
									continue
								}
							}
							m += 1
						}
					}
				}
			} else if to_distribute > 0 && grow_count > 0 {
				// 2b. Underflow expansion (Water-Filling Grow children)
				if !has_custom_weights {
					// Keep only Grow children that haven't hit their max bound
					k := 0
					for k < len(resizable) {
						c_idx := resizable[k]
						c_sizing := ctx.nodes[c_idx].config.width if axis == 0 else ctx.nodes[c_idx].config.height
						g, is_grow := c_sizing.(Grow)
						max_v := g.max if g.max > 0 else MAX_DIM
						if !is_grow || ctx.nodes[c_idx].dims[axis] >= max_v {
							ordered_remove(&resizable, k)
						} else {
							k += 1
						}
					}

					for to_distribute > 0 && len(resizable) > 0 {
						smallest: i32 = MAX_DIM
						second_smallest: i32 = MAX_DIM
						for c_idx in resizable {
							sz := ctx.nodes[c_idx].dims[axis]
							if sz < smallest {
								second_smallest = smallest
								smallest = sz
							} else if sz > smallest {
								second_smallest = min(second_smallest, sz)
							}
						}

						smallest_count: i32 = 0
						for c_idx in resizable {
							if ctx.nodes[c_idx].dims[axis] == smallest {
								smallest_count += 1
							}
						}

						step_up := (second_smallest - smallest) if second_smallest < MAX_DIM else to_distribute
						if second_smallest < MAX_DIM && step_up * smallest_count <= to_distribute {
							// Raise all tied smallest children up to second_smallest (or their max bound)
							m := 0
							for m < len(resizable) && to_distribute > 0 {
								c_idx := resizable[m]
								child := &ctx.nodes[c_idx]
								if child.dims[axis] == smallest {
									g := get_grow(child.config, axis)
									max_v := g.max if g.max > 0 else MAX_DIM
									prev := child.dims[axis]
									child.dims[axis] = min(max_v, prev + step_up)
									child.computed_size[axis] = child.dims[axis]
									to_distribute -= (child.dims[axis] - prev)
									if child.dims[axis] >= max_v {
										ordered_remove(&resizable, m)
										continue
									}
								}
								m += 1
							}
						} else {
							// Distribute remaining space across tied smallest children (checking max caps first)
							clamped_any := false
							even_target := smallest + (to_distribute / smallest_count)
							m := 0
							for m < len(resizable) {
								c_idx := resizable[m]
								child := &ctx.nodes[c_idx]
								if child.dims[axis] == smallest {
									g := get_grow(child.config, axis)
									if g.max > 0 && even_target >= g.max {
										prev := child.dims[axis]
										child.dims[axis] = g.max
										child.computed_size[axis] = child.dims[axis]
										to_distribute -= (child.dims[axis] - prev)
										ordered_remove(&resizable, m)
										clamped_any = true
										continue
									}
								}
								m += 1
							}
							if !clamped_any {
								rem_add := to_distribute
								seen_idx: i32 = 0
								prev_add: i32 = 0
								for c_idx in resizable {
									child := &ctx.nodes[c_idx]
									if child.dims[axis] == smallest {
										seen_idx += 1
										next_add := (rem_add * seen_idx) / smallest_count
										add := next_add - prev_add
										prev_add = next_add
										child.dims[axis] += add
										child.computed_size[axis] = child.dims[axis]
										to_distribute -= add
									}
								}
								break
							}
						}
					}
				} else {
					// Weighted Grow distribution with min/max freeze clamping and exact integer remainder
					fixed_used: i32 = total_gaps
					unfrozen_count := 0
					for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
						child := &ctx.nodes[c]
						if child.out_of_flow {
							child.frozen = true
							continue
						}
						c_sizing := child.config.width if axis == 0 else child.config.height
						if _, is_grow := c_sizing.(Grow); is_grow {
							child.frozen = false
							unfrozen_count += 1
						} else {
							child.frozen = true
							fixed_used += child.dims[axis]
						}
					}
					rem_main := max(0, inner_avail - fixed_used)
					for unfrozen_count > 0 {
						total_weight: i32 = 0
						for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
							child := &ctx.nodes[c]
							if !child.frozen {
								g := get_grow(child.config, axis)
								total_weight += max(g.weight, 1)
							}
						}
						clamped_any := false
						for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
							child := &ctx.nodes[c]
							if child.frozen {
								continue
							}
							g := get_grow(child.config, axis)
							w := max(g.weight, 1)
							target := (rem_main * w) / max(total_weight, 1)
							if g.min > 0 && target < g.min {
								child.dims[axis] = g.min
								child.computed_size[axis] = g.min
								child.frozen = true
								rem_main = max(0, rem_main - g.min)
								unfrozen_count -= 1
								clamped_any = true
							} else if g.max > 0 && target > g.max {
								child.dims[axis] = g.max
								child.computed_size[axis] = g.max
								child.frozen = true
								rem_main = max(0, rem_main - g.max)
								unfrozen_count -= 1
								clamped_any = true
							}
						}
						if !clamped_any {
							accum_weight: i32 = 0
							prev_dist: i32 = 0
							for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
								child := &ctx.nodes[c]
								if child.frozen {
									continue
								}
								g := get_grow(child.config, axis)
								accum_weight += max(g.weight, 1)
								next_dist := (rem_main * accum_weight) / max(total_weight, 1)
								child.dims[axis] = next_dist - prev_dist
								child.computed_size[axis] = child.dims[axis]
								prev_dist = next_dist
								child.frozen = true
								unfrozen_count -= 1
							}
						}
					}
				}
			}
		} else {
			// Cross-axis sizing
			for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
				child := &ctx.nodes[c]
				if child.out_of_flow {
					continue
				}
				c_sizing := child.config.width if axis == 0 else child.config.height
				switch s in c_sizing {
				case Grow:
					child.dims[axis] = clamp_bounds(inner_avail, s.min, s.max)
				case Fit:
					if child.dims[axis] > inner_avail && child.dims[axis] > child.min_dims[axis] {
						child.dims[axis] = max(child.min_dims[axis], min(child.dims[axis], inner_avail))
					}
				case Fixed, Percent, nil:
					if c_sizing == nil && child.dims[axis] > inner_avail && child.dims[axis] > child.min_dims[axis] {
						child.dims[axis] = max(child.min_dims[axis], min(child.dims[axis], inner_avail))
					}
				}
				child.computed_size[axis] = child.dims[axis]
			}
		}
	}
}

@(private)
wrap_text_and_repropagate_heights :: proc(ctx: ^Layout_Context) {
	any_wrapped := false

	for i := 0; i < len(ctx.nodes); i += 1 {
		node := &ctx.nodes[i]
		if node.has_markdown && node.config.wrap_mode != .None {
			any_wrapped = true
			insets := compute_total_insets(node.config)
			max_w := max(1, node.dims[0] - insets[0])
			md_lines := markdown_parse_document(node.md_source, max_w, node.md_cfg, ctx.allocator)
			node.wrapped_span_lines = md_lines
			node.wrapped_span_w     = max_w
			line_count := max(1, i32(len(md_lines)))
			node.content_size[1] = line_count
			new_h := line_count + insets[1]
			node.dims[1]          = resolve_pass1_axis(node.config.height, new_h)
			node.min_dims[1]      = max(node.min_dims[1], node.dims[1])
			node.computed_size[1] = node.dims[1]
			continue
		}
		if len(node.para_spans) > 0 && node.config.wrap_mode != .None {
			any_wrapped = true
			insets := compute_total_insets(node.config)
			max_w := max(1, node.dims[0] - insets[0])
			para_lines := paragraph_wrap_spans(node.para_spans, max_w, node.config.wrap_mode, ctx.allocator)
			node.wrapped_span_lines = para_lines
			node.wrapped_span_w     = max_w
			line_count := max(1, i32(len(para_lines)))
			node.content_size[1] = line_count
			new_h := line_count + insets[1]
			node.dims[1]          = resolve_pass1_axis(node.config.height, new_h)
			node.min_dims[1]      = max(node.min_dims[1], node.dims[1])
			node.computed_size[1] = node.dims[1]
			continue
		}
		if len(node.text) == 0 || node.config.wrap_mode == .None {
			continue
		}
		any_wrapped = true
		insets := compute_total_insets(node.config)
		max_w := max(1, node.dims[0] - insets[0])

		lines := make([dynamic]string, 0, 4, ctx.allocator)
		rem := node.text
		for len(rem) > 0 {
			nl_idx := -1
			for b_idx in 0 ..< len(rem) {
				if rem[b_idx] == '\n' {
					nl_idx = b_idx
					break
				}
			}
			para := rem[:nl_idx] if nl_idx >= 0 else rem
			rem = rem[nl_idx + 1:] if nl_idx >= 0 else ""

			if len(para) == 0 || string_display_width(para) <= max_w || node.config.wrap_mode == .Newlines {
				append(&lines, para)
				continue
			}

			line_start := 0
			line_w: i32 = 0
			word_start := 0
			word_w: i32 = 0
			in_word := false

			for r, byte_pos in para {
				rw := i32(rune_display_width(r))
				if r == ' ' {
					if in_word {
						if line_w > 0 && line_w + 1 + word_w > max_w {
							append(&lines, para[line_start:word_start - 1])
							line_start = word_start
							line_w = word_w
						} else {
							line_w = (line_w + 1 + word_w) if line_w > 0 else word_w
						}
						in_word = false
						word_w = 0
					}
				} else {
					if !in_word {
						word_start = byte_pos
						in_word = true
						word_w = rw
					} else {
						word_w += rw
					}
				}
			}
			if in_word {
				if line_w > 0 && line_w + 1 + word_w > max_w {
					append(&lines, para[line_start:word_start - 1])
					line_start = word_start
				}
			}
			if line_start < len(para) {
				append(&lines, para[line_start:])
			}
		}

		line_count := max(1, i32(len(lines)))
		node.wrapped_lines = lines[:]
		node.content_size[1] = line_count
		new_h := line_count + insets[1]
		node.dims[1]          = resolve_pass1_axis(node.config.height, new_h)
		node.min_dims[1]      = max(node.min_dims[1], node.dims[1])
		node.computed_size[1] = node.dims[1]
	}

	if !any_wrapped {
		return
	}

	// Reverse topological pass: propagate wrapped text heights up through Fit & Grow ancestors
	for i := len(ctx.nodes) - 1; i >= 0; i -= 1 {
		node := &ctx.nodes[i]
		if node.child_count == 0 {
			continue
		}
		switch _ in node.config.height {
		case Fixed, Percent:
			continue
		case Fit, Grow, nil:
		}

		insets := compute_total_insets(node.config)
		in_flow_count: i32 = 0
		sum_h: i32 = 0
		min_sum_h: i32 = 0
		max_h: i32 = 0
		min_max_h: i32 = 0

		for c := node.first_child; c != -1; c = ctx.nodes[c].next_sibling {
			child := &ctx.nodes[c]
			if child.out_of_flow {
				continue
			}
			sum_h     += child.dims[1]
			min_sum_h += child.min_dims[1]
			max_h      = max(max_h, child.dims[1])
			min_max_h  = max(min_max_h, child.min_dims[1])
			in_flow_count += 1
		}
		if in_flow_count == 0 {
			continue
		}

		if node.config.dir == .Row {
			target_h := max(node.dims[1], max_h + insets[1])
			target_min := max(node.min_dims[1], min_max_h + insets[1])
			node.dims[1]          = clamp_axis(target_h, node.config.height)
			node.min_dims[1]      = clamp_axis(target_min, node.config.height)
			node.computed_size[1] = node.dims[1]
		} else {
			gaps := (in_flow_count - 1) * node.config.gap if in_flow_count > 1 else 0
			target_h := sum_h + gaps + insets[1]
			target_min := insets[1] if node.config.scrollable else (min_sum_h + gaps + insets[1])
			node.dims[1]          = clamp_axis(target_h, node.config.height)
			node.min_dims[1]      = clamp_axis(target_min, node.config.height)
			node.computed_size[1] = node.dims[1]
		}
	}
}

@(private)
position_nodes_topological :: proc(ctx: ^Layout_Context) {
	screen_bounds := Rect{x = 0, y = 0, w = ctx.screen_size[0], h = ctx.screen_size[1]}

	root := &ctx.nodes[0]
	root.rect = Rect{
		x = 0,
		y = 0,
		w = root.dims[0],
		h = root.dims[1],
	}

	for i := 0; i < len(ctx.nodes); i += 1 {
		parent := &ctx.nodes[i]

		// Resolve out-of-flow floating/modal root position relative to Screen or Parent
		if i > 0 && parent.out_of_flow {
			ref_rect := screen_bounds
			if len(parent.config.anchor_parent_id) > 0 {
				if p_idx, ok := ctx.id_map[hash_id(parent.config.anchor_parent_id)]; ok {
					ref_rect = ctx.nodes[p_idx].rect
				}
			} else if parent.config.anchor == .Parent && parent.parent_idx >= 0 {
				ref_rect = ctx.nodes[parent.parent_idx].rect
			}

			ox: i32
			oy: i32
			if parent.config.parent_anchor != .Top_Left || parent.config.element_anchor != .Top_Left {
				ox = anchor_offset_x(parent.config.parent_anchor, ref_rect.w) -
				     anchor_offset_x(parent.config.element_anchor, parent.dims[0]) +
				     parent.config.offset[0]
				oy = anchor_offset_y(parent.config.parent_anchor, ref_rect.h) -
				     anchor_offset_y(parent.config.element_anchor, parent.dims[1]) +
				     parent.config.offset[1]
			} else {
				ox = align_offset(ref_rect.w, parent.dims[0], parent.config.self_align[0]) + parent.config.offset[0]
				oy = align_offset(ref_rect.h, parent.dims[1], parent.config.self_align[1]) + parent.config.offset[1]
			}

			parent.rect = Rect{
				x = ref_rect.x + ox - parent.config.expand[0],
				y = ref_rect.y + oy - parent.config.expand[1],
				w = parent.dims[0] + parent.config.expand[0] * 2,
				h = parent.dims[1] + parent.config.expand[1] * 2,
			}

			if parent.config.clamp_to_screen {
				if parent.rect.y + parent.rect.h > screen_bounds.h && ref_rect.y - parent.rect.h >= 0 {
					parent.rect.y = ref_rect.y - parent.rect.h - max(0, parent.config.offset[1] - 1)
				}
				if parent.rect.y + parent.rect.h > screen_bounds.h {
					parent.rect.y = max(0, screen_bounds.h - parent.rect.h)
				}
				if parent.rect.y < 0 {
					parent.rect.y = 0
				}
				if parent.rect.x + parent.rect.w > screen_bounds.w {
					parent.rect.x = max(0, screen_bounds.w - parent.rect.w)
				}
				if parent.rect.x < 0 {
					parent.rect.x = 0
				}
			}
		}

		parent.inner_rect = compute_inner_rect(parent.rect, parent.config)

		parent_clip := screen_bounds
		if parent.parent_idx >= 0 {
			if !parent.out_of_flow {
				parent_clip = ctx.nodes[parent.parent_idx].inner_clip
			} else if parent.config.clip_to_parent {
				parent_clip = ctx.nodes[parent.parent_idx].node_clip
			}
		}
		parent.node_clip  = rect_intersect(parent_clip, parent.rect)
		parent.inner_clip = rect_intersect(parent.node_clip, parent.inner_rect)

		if parent.child_count == 0 {
			if parent.config.virtual_total_rows > 0 {
				parent.content_span[0] = parent.inner_rect.w
				parent.content_span[1] = parent.config.virtual_total_rows
			}
			continue
		}

		main_axis := 0 if parent.config.dir == .Row else 1
		cross_axis := 1 - main_axis
		inner_size := [2]i32{parent.inner_rect.w, parent.inner_rect.h}

		in_flow_count: i32 = 0
		total_main_span: i32 = 0
		max_cross_span: i32 = inner_size[cross_axis]
		for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
			child := &ctx.nodes[c]
			if child.out_of_flow {
				continue
			}
			total_main_span += child.dims[main_axis]
			max_cross_span = max(max_cross_span, child.dims[cross_axis])
			in_flow_count += 1
		}
		if in_flow_count > 1 {
			total_main_span += (in_flow_count - 1) * parent.config.gap
		}

		parent.content_span[main_axis]  = total_main_span
		parent.content_span[cross_axis] = max_cross_span
		if parent.config.virtual_total_rows > 0 {
			parent.content_span[1] = parent.config.virtual_total_rows
		}

		scroll_shift_main: i32 = 0
		scroll_shift_cross: i32 = 0
		if parent.config.scrollable && parent.config.virtual_total_rows == 0 {
			if main_axis == 1 {
				max_scroll := max(0, total_main_span - inner_size[1])
				scroll_shift_main = clamp(parent.config.scroll_offset, 0, max_scroll)
				parent.config.scroll_offset  = scroll_shift_main
				parent.applied_scroll_offset = scroll_shift_main

				max_scroll_x := max(0, max_cross_span - inner_size[0])
				scroll_shift_cross = clamp(parent.config.scroll_offset_x, 0, max_scroll_x)
				parent.config.scroll_offset_x  = scroll_shift_cross
				parent.applied_scroll_offset_x = scroll_shift_cross
			} else {
				max_scroll_x := max(0, total_main_span - inner_size[0])
				scroll_shift_main = clamp(parent.config.scroll_offset_x, 0, max_scroll_x)
				parent.config.scroll_offset_x  = scroll_shift_main
				parent.applied_scroll_offset_x = scroll_shift_main

				max_scroll := max(0, max_cross_span - inner_size[1])
				scroll_shift_cross = clamp(parent.config.scroll_offset, 0, max_scroll)
				parent.config.scroll_offset  = scroll_shift_cross
				parent.applied_scroll_offset = scroll_shift_cross
			}
		}

		main_cursor := align_offset(inner_size[main_axis], total_main_span, parent.config.main_align) - scroll_shift_main
		inner_origin := [2]i32{parent.inner_rect.x, parent.inner_rect.y}

		for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
			child := &ctx.nodes[c]
			if child.out_of_flow {
				continue
			}
			cross_offset := align_offset(inner_size[cross_axis], child.dims[cross_axis], parent.config.cross_align) - scroll_shift_cross

			pos: [2]i32
			pos[main_axis]  = inner_origin[main_axis] + main_cursor
			pos[cross_axis] = inner_origin[cross_axis] + cross_offset

			child.rect = Rect{
				x = pos[0],
				y = pos[1],
				w = child.dims[0],
				h = child.dims[1],
			}
			main_cursor += child.dims[main_axis] + parent.config.gap
		}
	}
}

compute_total_insets :: #force_inline proc(cfg: Box_Config) -> [2]i32 {
	b := i32(1) if cfg.border != .None else 0
	return {
		cfg.padding.left + cfg.padding.right + b * 2,
		cfg.padding.top + cfg.padding.bottom + b * 2,
	}
}

compute_inner_rect :: #force_inline proc(outer: Rect, cfg: Box_Config) -> Rect {
	b := i32(1) if cfg.border != .None else 0
	left   := cfg.padding.left + b
	right  := cfg.padding.right + b
	top    := cfg.padding.top + b
	bottom := cfg.padding.bottom + b
	return Rect{
		x = outer.x + left,
		y = outer.y + top,
		w = max(0, outer.w - (left + right)),
		h = max(0, outer.h - (top + bottom)),
	}
}

@(private)
resolve_pass1_axis_with_min :: #force_inline proc(sizing: Axis_Size, intrinsic, min_intrinsic: i32) -> (dim, min_dim: i32) {
	switch s in sizing {
	case Fixed:
		return i32(s), i32(s)
	case Percent:
		// Percent axes contribute 0 to Fit parent sums during Pass 1
		return 0, s.min
	case Fit:
		d := clamp_bounds(intrinsic, s.min, s.max)
		m := clamp_bounds(max(s.min, min_intrinsic), s.min, s.max)
		return d, m
	case Grow:
		d := clamp_bounds(intrinsic, s.min, s.max)
		m := clamp_bounds(max(s.min, min_intrinsic), s.min, s.max)
		return d, m
	case nil:
		return intrinsic, min_intrinsic
	}
	return intrinsic, min_intrinsic
}

resolve_pass1_axis :: #force_inline proc(sizing: Axis_Size, intrinsic: i32) -> i32 {
	d, _ := resolve_pass1_axis_with_min(sizing, intrinsic, intrinsic)
	return d
}

clamp_axis :: #force_inline proc(val: i32, sizing: Axis_Size) -> i32 {
	switch s in sizing {
	case Fixed:
		return i32(s)
	case Fit:
		return clamp_bounds(val, s.min, s.max)
	case Grow:
		return clamp_bounds(val, s.min, s.max)
	case Percent:
		return clamp_bounds(val, s.min, s.max)
	case nil:
		return val
	}
	return val
}

clamp_bounds :: #force_inline proc(val, min_v, max_v: i32) -> i32 {
	res := max(val, min_v)
	if max_v > 0 && max_v < MAX_DIM {
		res = min(res, max_v)
	}
	return res
}

get_grow :: #force_inline proc(cfg: Box_Config, axis: int) -> Grow {
	s := cfg.width if axis == 0 else cfg.height
	if g, ok := s.(Grow); ok {
		return g
	}
	return Grow{weight = 1}
}

align_offset :: #force_inline proc(available, content: i32, align: Alignment) -> i32 {
	slack := max(0, available - content)
	switch align {
	case .Start:
		return 0
	case .Center:
		return slack / 2
	case .End:
		return slack
	}
	return 0
}

anchor_offset_x :: #force_inline proc(pt: Anchor_Point, w: i32) -> i32 {
	#partial switch pt {
	case .Top_Center, .Center, .Bottom_Center:
		return w / 2
	case .Top_Right, .Center_Right, .Bottom_Right:
		return w
	}
	return 0
}

anchor_offset_y :: #force_inline proc(pt: Anchor_Point, h: i32) -> i32 {
	#partial switch pt {
	case .Center_Left, .Center, .Center_Right:
		return h / 2
	case .Bottom_Left, .Bottom_Center, .Bottom_Right:
		return h
	}
	return 0
}
