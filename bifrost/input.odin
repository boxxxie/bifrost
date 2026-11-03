package bifrost

import "core:mem"

// =============================================================================
// Input Events, Phases & Zero-Allocation Input State
// =============================================================================

// Key_Code reuses ASCII/Unicode values for standard keys and Kitty's Private
// Use Area (57348..=57454) for functional keys, plus .Rune for general scalar runes.
Key_Code :: enum rune {
	None              = 0,
	Tab               = 0x09,
	Enter             = 0x0D,
	Escape            = 0x1B,
	Space             = 0x20,
	Backspace         = 0x7F,

	Insert            = 57348,
	Delete            = 57349,
	Left              = 57350,
	Right             = 57351,
	Up                = 57352,
	Down              = 57353,
	Page_Up           = 57354,
	Page_Down         = 57355,
	Home              = 57356,
	End               = 57357,
	Caps_Lock         = 57358,
	Scroll_Lock       = 57359,
	Num_Lock          = 57360,
	Print_Screen      = 57361,
	Pause             = 57362,
	Menu              = 57363,
	F1                = 57364,
	F2                = 57365,
	F3                = 57366,
	F4                = 57367,
	F5                = 57368,
	F6                = 57369, // Cycles between sibling focus_scope containers when not modal-locked
	F7                = 57370,
	F8                = 57371,
	F9                = 57372,
	F10               = 57373,
	F11               = 57374,
	F12               = 57375,
	F13               = 57376,
	F14               = 57377,
	F15               = 57378,
	F16               = 57379,
	F17               = 57380,
	F18               = 57381,
	F19               = 57382,
	F20               = 57383,
	F21               = 57384,
	F22               = 57385,
	F23               = 57386,
	F24               = 57387,
	F25               = 57388,
	F26               = 57389,
	F27               = 57390,
	F28               = 57391,
	F29               = 57392,
	F30               = 57393,
	F31               = 57394,
	F32               = 57395,
	F33               = 57396,
	F34               = 57397,
	F35               = 57398,
	KP_0              = 57399,
	KP_1              = 57400,
	KP_2              = 57401,
	KP_3              = 57402,
	KP_4              = 57403,
	KP_5              = 57404,
	KP_6              = 57405,
	KP_7              = 57406,
	KP_8              = 57407,
	KP_9              = 57408,
	KP_Decimal        = 57409,
	KP_Divide         = 57410,
	KP_Multiply       = 57411,
	KP_Subtract       = 57412,
	KP_Add            = 57413,
	KP_Enter          = 57414,
	KP_Equal          = 57415,
	KP_Separator      = 57416,
	KP_Left           = 57417,
	KP_Right          = 57418,
	KP_Up             = 57419,
	KP_Down           = 57420,
	KP_Page_Up        = 57421,
	KP_Page_Down      = 57422,
	KP_Home           = 57423,
	KP_End            = 57424,
	KP_Insert         = 57425,
	KP_Delete         = 57426,
	KP_Begin          = 57427,
	Media_Play        = 57428,
	Media_Pause       = 57429,
	Media_Play_Pause  = 57430,
	Media_Reverse     = 57431,
	Media_Stop        = 57432,
	Media_Fast_Fwd    = 57433,
	Media_Rewind      = 57434,
	Media_Track_Next  = 57435,
	Media_Track_Prev  = 57436,
	Media_Record      = 57437,
	Lower_Volume      = 57438,
	Raise_Volume      = 57439,
	Mute_Volume       = 57440,
	Left_Shift        = 57441,
	Left_Control      = 57442,
	Left_Alt          = 57443,
	Left_Super        = 57444,
	Left_Hyper        = 57445,
	Left_Meta         = 57446,
	Right_Shift       = 57447,
	Right_Control     = 57448,
	Right_Alt         = 57449,
	Right_Super       = 57450,
	Right_Hyper       = 57451,
	Right_Meta        = 57452,
	ISO_Level_3_Shift = 57453,
	ISO_Level_5_Shift = 57454,
	Multicodepoint    = 0x110001,
	Rune              = 0x110002,
}

Mod_Flag :: enum u8 {
	Shift     = 0,
	Alt       = 1,
	Ctrl      = 2,
	Super     = 3,
	Hyper     = 4,
	Meta      = 5,
	Caps_Lock = 6,
	Num_Lock  = 7,
}

Mod_Flags     :: bit_set[Mod_Flag; u8]
Modifier_Flag :: Mod_Flag
Modifiers     :: Mod_Flags

Key_Action :: enum u8 {
	Press   = 0,
	Repeat  = 1,
	Release = 2,
}

Key_Event :: struct {
	code:                  Key_Code,
	ch:                    rune,
	codepoint:             rune,
	shifted_codepoint:     rune,
	base_layout_codepoint: rune,
	mods:                  Mod_Flags,
	action:                Key_Action,
	text_buf:              [64]u8,
	text_len:              u8,
}

Mouse_Action :: enum u8 {
	Move        = 0,
	Press       = 1,
	Drag        = 2,
	Release     = 3,
	Scroll_Up   = 4,
	Scroll_Down = 5,
	Motion      = 6,
	Leave       = 7,
}

Mouse_Button :: enum u8 {
	Left        = 0,
	Middle      = 1,
	Right       = 2,
	None        = 3,
	Wheel_Up    = 64,
	Wheel_Down  = 65,
	Wheel_Right = 66,
	Wheel_Left  = 67,
	Button_8    = 128,
	Button_9    = 129,
	Button_10   = 130,
	Button_11   = 131,
}

Mouse_Event :: struct {
	x:        i32,
	y:        i32,
	col:      i16,
	row:      i16,
	x_offset: u16,
	y_offset: u16,
	action:   Mouse_Action,
	button:   Mouse_Button,
	mods:     Mod_Flags,
}

Focus_Loss_Event :: struct {}

Focus_Event :: struct {
	focused: bool,
}

Paste_Kind :: enum u8 {
	Complete = 0,
	Start    = 1,
	End      = 2,
}

Paste_Event :: struct {
	text: string,
	kind: Paste_Kind,
}

Resize_Event :: struct {
	width:   i32,
	height:  i32,
	x_pixel: u16,
	y_pixel: u16,
}

Input_Event :: union {
	Key_Event,
	Mouse_Event,
	Focus_Loss_Event,
	Focus_Event,
	Paste_Event,
	Resize_Event,
}

Event_Phase :: enum u8 {
	Capturing,
	At_Target,
	Bubbling,
}

Dispatch_Step :: struct {
	node_id: u64,
	id:      string,
	phase:   Event_Phase,
}

Event_Handler_Proc :: #type proc(
	node_id:  u64,
	phase:    Event_Phase,
	event:    Input_Event,
	userdata: rawptr,
) -> (consumed: bool)

MAX_FOCUS_HISTORY :: 8
MAX_HIT_DEPTH     :: 32
MAX_SCROLL_SLOTS  :: 32

Focus_Scope_Entry :: struct {
	modal_id:       u64,
	z_layer:        u8,
	saved_focus_id: u64,
	saved_scope_id: u64,
}

Scroll_Slot :: struct {
	id_hash:        u64,
	offset:         i32, // Top visible row index (or cell offset)
	max_offset:     i32, // Clamped maximum scroll offset
	viewport_rows:  i32, // Solved inner_rect.h from previous/current layout pass
	total_rows:     i32, // Total rows in xitdb collection or physical content_span
	selected_row:   i32, // Highlighted cursor row index inside virtual lists
	scroll_padding: i32, // Lookahead padding rows maintained above/below selected_row
}

// Persistent across frames (owned by the UI Actor; zero heap allocations)
Input_State :: struct {
	// Focus state & nested modal LIFO restoration stack
	focused_id:          u64, // Currently focused widget ID hash
	prev_focused_id:     u64, // Focused widget ID hash from start of resolve_input
	wants_focus_id:      u64, // Optional programmatic focus request for next reconcile
	active_scope_id:     u64, // Active focus_scope container ID hash
	active_capture_id:   u64, // Topmost capture_input (modal) ID hash (0 if none)
	active_shield_z:     u8,  // Highest effective_z among mounted capture_input nodes
	focus_history:       [MAX_FOCUS_HISTORY]Focus_Scope_Entry,
	focus_history_len:   int,

	// Mouse hover & active press capture state
	hovered_id:          u64, // Widget currently under the mouse cursor
	prev_hovered_id:     u64, // Hovered widget prior to current resolve_input call
	active_id:           u64, // Alias for active_press_id (widget held down by Left mouse press)
	active_press_id:     u64, // Widget held down by Left mouse press (latched during drag)
	activated_id:        u64, // Widget triggered this frame (Enter/Space or click release)
	clicked_id:          u64, // Widget clicked via Left mouse press + release inside bounds
	scrolled_id:         u64, // Scrollable container scrolled during this resolve_input call
	backdrop_clicked_id: u64, // Capturing modal ID if user clicked outside its bounds
	escape_modal_id:     u64, // Capturing modal ID if user pressed Escape
	mouse_pos:           [2]i32,
	drag_delta:          [2]i32,
	mouse_initialized:   bool,
	mouse_down:          bool,

	// Ancestor chains (root -> target) for 3-phase Capturing -> At_Target -> Bubbling routing
	focus_path:          [MAX_HIT_DEPTH]u64,
	focus_path_len:      int,
	hover_path:          [MAX_HIT_DEPTH]u64,
	hover_path_len:      int,
	prev_hover_path:     [MAX_HIT_DEPTH]u64,
	prev_hover_path_len: int,

	// Optional 3-phase event interceptor
	event_handler:       Event_Handler_Proc,
	event_userdata:      rawptr,

	// Fixed-capacity scroll slots for zero-allocation immediate-mode scrolling
	scroll_slots:        [MAX_SCROLL_SLOTS]Scroll_Slot,

	// Fixed-capacity single-line UTF-8 text input slots
	text_changed_id:     u64,
	text_slots:          [MAX_TEXT_SLOTS]Text_Input_Slot,

	// Fixed-capacity interactive pane splitter slots
	active_splitter_id:  u64,
	splitter_slots:      [MAX_SPLITTER_SLOTS]Splitter_Slot,

	// 3-tier scoped/global keybinding table & per-frame action dispatch
	keybindings:           [MAX_KEYBINDINGS]Keybinding,
	keybinding_count:      int,
	triggered_action_id:   u64,
	triggered_action_name: string,
}

Button_Spec :: struct {
	label:    string,
	width:    Axis_Size,
	height:   Axis_Size,
	border:   Border_Kind,
	fg:       Color,
	bg:       Color,
	hover_bg: Color,
	focus_fg: Color,
	focus_bg: Color,
}

// =============================================================================
// Persistent Widget State Store (Scroll Offset & Max Clamping Across Frames)
// =============================================================================

Widget_Scroll_State :: struct {
	scroll_offset:      [2]i32,
	scroll_max:         [2]i32,
	wheel_step:         i32,
	last_touched_frame: u64,
}

Widget_State_Store :: struct {
	current_frame: u64,
	scroll_states: map[u64]Widget_Scroll_State,
	allocator:     mem.Allocator,
}

state_store_init :: proc(
	store: ^Widget_State_Store,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	store.current_frame = 0
	store.allocator = allocator
	store.scroll_states = make(map[u64]Widget_Scroll_State, 64, allocator) or_return
	return nil
}

state_store_destroy :: proc(store: ^Widget_State_Store) {
	delete(store.scroll_states)
	store^ = {}
}

state_store_begin_frame :: proc "contextless" (store: ^Widget_State_Store) {
	if store != nil {
		store.current_frame += 1
	}
}

state_store_get_scroll :: proc(
	store: ^Widget_State_Store,
	id: string,
	default_step: i32 = 3,
) -> Widget_Scroll_State {
	if store == nil {
		return Widget_Scroll_State{wheel_step = default_step}
	}
	h := hash_id(id)
	persisted := Widget_Scroll_State{
		wheel_step = default_step,
	}
	if existing, ok := store.scroll_states[h]; ok {
		persisted = existing
	}
	if persisted.wheel_step <= 0 {
		persisted.wheel_step = default_step
	}
	persisted.last_touched_frame = store.current_frame
	store.scroll_states[h] = persisted
	return persisted
}

state_store_prune_unmounted :: proc(store: ^Widget_State_Store) {
	if store == nil {
		return
	}
	for id_hash, entry in store.scroll_states {
		if entry.last_touched_frame < store.current_frame {
			delete_key(&store.scroll_states, id_hash)
		}
	}
}

// Synchronizes clamped scroll offsets and max bounds from solved Layout_Context nodes into Widget_State_Store,
// and prunes unmounted widget entries when called at the end of a layout frame.
state_store_sync_from_layout :: proc(
	store: ^Widget_State_Store,
	ctx: ^Layout_Context,
	inp: ^Input_State = nil,
) {
	if store == nil {
		return
	}
	for i := 0; i < len(ctx.nodes); i += 1 {
		node := ctx.nodes[i]
		if !node.config.scrollable {
			continue
		}
		if entry, ok := &store.scroll_states[node.id_hash]; ok {
			max_x := max(0, node.content_span[0] - node.inner_rect.w)
			max_y := max(0, node.content_span[1] - node.inner_rect.h)
			off_y := node.config.scroll_offset
			if inp != nil {
				slot := get_scroll_slot(inp, node.id_hash)
				off_y = slot.offset
			}
			entry.scroll_max = {max_x, max_y}
			entry.scroll_offset[0] = clamp(node.config.scroll_offset_x, 0, max_x)
			entry.scroll_offset[1] = clamp(off_y, 0, max_y)
		}
	}
	state_store_prune_unmounted(store)
}

// =============================================================================
// Interactive Widget Builders & Immediate-Mode Query Helpers
// =============================================================================

ui_button :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, spec: Button_Spec) -> i32 {
	text_w := string_display_width(spec.label)
	w := spec.width if spec.width != nil else fit(min = text_w + 4)
	h := spec.height if spec.height != nil else fit(min = 1)

	fg := spec.fg if spec.fg.kind != .Default else rgb(220, 220, 230)
	bg := spec.bg if spec.bg.kind != .Default else rgb(45, 50, 65)

	s.paints[hash_id(id)] = Paint_Spec{
		text    = spec.label,
		fg      = fg,
		bg      = bg,
		fill_bg = true,
	}
	return leaf(ctx, id, text_w, 1, Box_Config{
		dir         = .Row,
		width       = w,
		height      = h,
		border      = spec.border,
		main_align  = .Center,
		cross_align = .Center,
		focusable   = true,
		clickable   = true,
		hoverable   = true,
	})
}

was_activated :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp.activated_id != 0 && inp.activated_id == hash_id(id)
}

is_focused :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp.focused_id != 0 && inp.focused_id == hash_id(id)
}

is_hovered :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp.hovered_id != 0 && inp.hovered_id == hash_id(id)
}

did_mouse_enter :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	h := hash_id(id)
	return h != 0 && inp.hovered_id == h && inp.prev_hovered_id != h
}

did_mouse_leave :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	h := hash_id(id)
	return h != 0 && inp.hovered_id != h && inp.prev_hovered_id == h
}

was_modal_dismissed :: #force_inline proc(inp: ^Input_State, modal_id: string) -> bool {
	h := hash_id(modal_id)
	return h != 0 && (inp.backdrop_clicked_id == h || inp.escape_modal_id == h)
}

// =============================================================================
// 3-Phase Dispatch, Focus Reconciliation & Z-Aware Input Resolution
// =============================================================================

// Computes the highest effective_z among all mounted nodes with capture_input enabled.
compute_active_shield_z :: proc "contextless" (ctx: ^Layout_Context) -> u8 {
	shield_z: u8 = 0
	for node in ctx.nodes {
		if node.config.capture_input && node.effective_z > shield_z {
			shield_z = node.effective_z
		}
	}
	return shield_z
}

// Builds root-to-target ancestor chain (out_path[0] = root, out_path[len - 1] = target).
build_ancestor_path :: proc "contextless" (
	ctx: ^Layout_Context,
	target_idx: i32,
	out_path: ^[MAX_HIT_DEPTH]u64,
) -> int {
	if target_idx < 0 || int(target_idx) >= len(ctx.nodes) {
		return 0
	}
	len_path := 0
	curr := target_idx
	for curr >= 0 && len_path < MAX_HIT_DEPTH {
		out_path[len_path] = ctx.nodes[curr].id_hash
		len_path += 1
		curr = ctx.nodes[curr].parent_idx
	}
	// Reverse in-place so out_path[0] is root and out_path[len_path - 1] is target
	for i := 0; i < len_path / 2; i += 1 {
		j := len_path - 1 - i
		out_path[i], out_path[j] = out_path[j], out_path[i]
	}
	return len_path
}

// Routes an Input_Event through Capturing (root..parent) -> At_Target -> Bubbling (parent..root).
// Halts immediately and returns true if handler returns true (consume_event short-circuiting).
dispatch_three_phase :: proc(
	ctx: ^Layout_Context,
	path: []u64,
	event: Input_Event,
	handler: Event_Handler_Proc = nil,
	userdata: rawptr = nil,
) -> (consumed: bool) {
	_ = ctx
	if len(path) == 0 || handler == nil {
		return false
	}
	target_pos := len(path) - 1

	// 1. Capturing phase: root down to target's parent
	for i := 0; i < target_pos; i += 1 {
		if handler(path[i], .Capturing, event, userdata) {
			return true
		}
	}

	// 2. At_Target phase
	if handler(path[target_pos], .At_Target, event, userdata) {
		return true
	}

	// 3. Bubbling phase: target's parent back up to root
	for i := target_pos - 1; i >= 0; i -= 1 {
		if handler(path[i], .Bubbling, event, userdata) {
			return true
		}
	}
	return false
}

// Resolves focus scopes, nested modal LIFO input capture, 3-phase keyboard/mouse routing,
// and clipped reverse-Z mouse hit-testing. Call after end_layout(&ctx) and before render_layout(&scr, &ctx).
resolve_input :: proc(inp: ^Input_State, ctx: ^Layout_Context, events: ..Input_Event) {
	inp.prev_focused_id     = inp.focused_id
	inp.prev_hovered_id     = inp.hovered_id
	inp.prev_hover_path     = inp.hover_path
	inp.prev_hover_path_len = inp.hover_path_len

	inp.activated_id          = 0
	inp.clicked_id            = 0
	inp.scrolled_id           = 0
	inp.backdrop_clicked_id   = 0
	inp.escape_modal_id       = 0
	inp.active_capture_id     = 0
	inp.active_shield_z       = 0
	inp.text_changed_id       = 0
	inp.triggered_action_id   = 0
	inp.triggered_action_name = ""
	inp.drag_delta            = {0, 0}

	if len(ctx.nodes) == 0 {
		inp.focused_id        = 0
		inp.hovered_id        = 0
		inp.active_id         = 0
		inp.active_press_id   = 0
		inp.focus_path_len    = 0
		inp.hover_path_len    = 0
		inp.focus_history_len = 0
		return
	}

	// 0. Synchronize solved scroll container dimensions and splitter geometries
	sync_scroll_viewports(inp, ctx)
	sync_splitters(inp, ctx)

	// 1. Identify topmost active capture_input container (highest effective_z modal)
	capture_idx := find_topmost_capture_node(ctx)
	inp.active_shield_z = compute_active_shield_z(ctx)
	if capture_idx >= 0 {
		inp.active_capture_id = ctx.nodes[capture_idx].id_hash
	}

	// 2. Reconcile focused_id with current tree and nested modal LIFO focus_history stack
	reconcile_focus(inp, ctx, capture_idx)

	// 3. Process incoming keyboard, mouse, and focus-loss events
	for ev in events {
		switch e in ev {
		case Key_Event:
			handle_key_event(inp, ctx, capture_idx, e)
		case Mouse_Event:
			handle_mouse_event(inp, ctx, capture_idx, e)
		case Focus_Loss_Event:
			inp.hovered_id         = 0
			inp.hover_path_len     = 0
			inp.active_id          = 0
			inp.active_press_id    = 0
			inp.active_splitter_id = 0
			inp.mouse_down         = false
		case Focus_Event:
			if !e.focused {
				inp.hovered_id         = 0
				inp.hover_path_len     = 0
				inp.active_id          = 0
				inp.active_press_id    = 0
				inp.active_splitter_id = 0
				inp.mouse_down         = false
			}
		case Paste_Event:
			if inp.focused_id != 0 {
				if f_idx, exists := ctx.id_map[inp.focused_id]; exists && is_node_allowed(ctx, f_idx, capture_idx) {
					if ctx.nodes[f_idx].config.text_input {
						slot := get_text_slot(inp, inp.focused_id)
						for r in e.text {
							if r >= 32 {
								text_input_insert_rune(inp, slot, r)
							}
						}
					}
				}
			}
		case Resize_Event:
		}
	}

	// 4. Refresh hovered_id against current layout & modal occlusion when no mouse event
	// already updated hover (e.g., stationary cursor over a scrolling viewport)
	if inp.mouse_initialized && len(events) == 0 {
		update_hover_at_point(inp, ctx, capture_idx, inp.mouse_pos[0], inp.mouse_pos[1])
	}
}

// Applies visual highlight styling to focused, hovered, and active widgets before render_layout()
apply_input_highlights :: proc(s: ^Screen, ctx: ^Layout_Context, inp: ^Input_State) {
	for i := 0; i < len(ctx.nodes); i += 1 {
		node := ctx.nodes[i]
		if node.config.text_input {
			sync_text_input_paint(s, inp, node)
			continue
		}
		if node.config.splitter {
			sync_splitter_paint(s, inp, node)
			continue
		}
		if !node.config.focusable {
			continue
		}
		paint, ok := s.paints[node.id_hash]
		if !ok {
			continue
		}
		if node.id_hash == inp.focused_id {
			paint.style += {.Bold, .Reverse}
			if paint.border_fg.kind == .Default {
				paint.border_fg = rgb(255, 215, 0)
			}
		} else if node.id_hash == inp.hovered_id {
			paint.style += {.Underline}
		}
		s.paints[node.id_hash] = paint
	}
}

// =============================================================================
// Internal Focus Reconciliation, LIFO Modal History & Z-Aware Hit-Testing
// =============================================================================

find_topmost_capture_node :: proc "contextless" (ctx: ^Layout_Context) -> i32 {
	for i := len(ctx.z_order) - 1; i >= 0; i -= 1 {
		idx := ctx.z_order[i]
		if ctx.nodes[idx].config.capture_input {
			return idx
		}
	}
	return -1
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
is_interactive_node :: #force_inline proc "contextless" (cfg: Box_Config) -> bool {
	return cfg.focusable || cfg.clickable || cfg.hoverable || cfg.draggable || cfg.splitter || cfg.text_input
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
first_focusable_for_modal :: proc "contextless" (ctx: ^Layout_Context, modal_idx: i32) -> (u64, u64) {
	for i := 0; i < len(ctx.nodes); i += 1 {
		idx := i32(i)
		node := ctx.nodes[idx]
		if node.config.focusable && is_node_allowed(ctx, idx, modal_idx) {
			return node.id_hash, node.scope_id
		}
	}
	return 0, 0
}

reconcile_focus :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32) {
	// 1. Pop any focus_history entries from the top of the LIFO stack whose modal has unmounted
	for inp.focus_history_len > 0 {
		top := inp.focus_history[inp.focus_history_len - 1]
		if is_modal_still_mounted(ctx, top.modal_id) {
			break
		}
		inp.focus_history_len -= 1
		if top.saved_focus_id != 0 {
			inp.focused_id      = top.saved_focus_id
			inp.active_scope_id = top.saved_scope_id
		}
	}

	// Also compact any non-top modal entries that may have unmounted out of order
	write_idx := 0
	for read_idx := 0; read_idx < inp.focus_history_len; read_idx += 1 {
		entry := inp.focus_history[read_idx]
		if is_modal_still_mounted(ctx, entry.modal_id) {
			inp.focus_history[write_idx] = entry
			write_idx += 1
		}
	}
	inp.focus_history_len = write_idx

	// 2. Register any newly mounted capture_input modals in ascending effective_z order (via z_order),
	// saving the currently focused widget in LIFO order and advancing focus into the new modal
	for idx in ctx.z_order {
		node := ctx.nodes[idx]
		if !node.config.capture_input {
			continue
		}
		if !modal_scope_on_stack(inp, node.id_hash) {
			push_focus_scope_entry(inp, Focus_Scope_Entry{
				modal_id       = node.id_hash,
				z_layer        = node.effective_z,
				saved_focus_id = inp.focused_id,
				saved_scope_id = inp.active_scope_id,
			})
			new_focus, new_scope := first_focusable_for_modal(ctx, idx)
			if new_focus != 0 {
				inp.focused_id      = new_focus
				inp.active_scope_id = new_scope
			}
		}
	}

	// 3. Apply explicit programmatic focus request if valid within active shield
	if inp.wants_focus_id != 0 {
		if idx, ok := ctx.id_map[inp.wants_focus_id]; ok {
			node := ctx.nodes[idx]
			if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) {
				inp.focused_id      = node.id_hash
				inp.active_scope_id = node.scope_id
			}
		}
		inp.wants_focus_id = 0
	}

	// 4. Verify focused_id is still mounted, focusable, and allowed by the active modal shield
	if inp.focused_id != 0 {
		if idx, exists := ctx.id_map[inp.focused_id]; exists {
			node := ctx.nodes[idx]
			if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) {
				inp.active_scope_id = node.scope_id
				inp.focus_path_len  = build_ancestor_path(ctx, idx, &inp.focus_path)
				return
			}
		}
	}

	// 5. Fallback: pick the first allowed focusable widget in topological order
	for i := 0; i < len(ctx.nodes); i += 1 {
		idx := i32(i)
		node := ctx.nodes[idx]
		if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) {
			inp.focused_id      = node.id_hash
			inp.active_scope_id = node.scope_id
			inp.focus_path_len  = build_ancestor_path(ctx, idx, &inp.focus_path)
			return
		}
	}

	inp.focused_id      = 0
	inp.active_scope_id = 0
	inp.focus_path_len  = 0
}

handle_key_event :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, ev: Key_Event) {
	if inp.focused_id != 0 {
		if f_idx, ok := ctx.id_map[inp.focused_id]; ok {
			inp.focus_path_len = build_ancestor_path(ctx, f_idx, &inp.focus_path)
		} else {
			inp.focus_path_len = 0
		}
	} else {
		inp.focus_path_len = 0
	}

	// 1. 3-Phase Dispatch (Capturing -> At_Target -> Bubbling) with consume short-circuiting
	if inp.focus_path_len > 0 {
		if dispatch_three_phase(ctx, inp.focus_path[:inp.focus_path_len], ev, inp.event_handler, inp.event_userdata) {
			return
		}
	}

	// 2. Scoped & Global Keybinding Table (3-tier priority resolution)
	if dispatch_keybindings(inp, ctx, capture_idx, ev) {
		return
	}

	// 3. Focused Text Input or Splitter Widget Handling
	if inp.focused_id != 0 {
		if f_idx, exists := ctx.id_map[inp.focused_id]; exists && is_node_allowed(ctx, f_idx, capture_idx) {
			f_node := ctx.nodes[f_idx]
			if f_node.config.text_input {
				if handle_text_input_key(inp, ctx, f_idx, capture_idx, ev) {
					return
				}
			}
			if f_node.config.splitter {
				if handle_splitter_key(inp, ctx, f_idx, ev) {
					return
				}
			}
		}
	}

	// 4. Default focus navigation, activation, modal escape, and keyboard scrolling
	#partial switch ev.code {
	case .Tab:
		if .Ctrl in ev.mods {
			cycle_focus_scope(inp, ctx, capture_idx, -1 if .Shift in ev.mods else 1)
		} else {
			cycle_focus_within_scope(inp, ctx, capture_idx, -1 if .Shift in ev.mods else 1)
		}
	case .F6:
		cycle_focus_scope(inp, ctx, capture_idx, -1 if .Shift in ev.mods else 1)
	case .Enter, .Space:
		if inp.focused_id != 0 {
			if idx, ok := ctx.id_map[inp.focused_id]; ok && is_node_allowed(ctx, idx, capture_idx) {
				inp.activated_id = inp.focused_id
			}
		}
	case .Escape:
		if capture_idx >= 0 {
			inp.escape_modal_id = ctx.nodes[capture_idx].id_hash
		}
	case .Up, .Down, .Page_Up, .Page_Down, .Home, .End:
		handle_key_scroll(inp, ctx, capture_idx, ev.code)
	}
}

cycle_focus_within_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, step: int) {
	candidates := make([dynamic]i32, 0, 16, ctx.allocator)

	for i := 0; i < len(ctx.nodes); i += 1 {
		idx := i32(i)
		node := ctx.nodes[idx]
		if !node.config.focusable || !is_node_allowed(ctx, idx, capture_idx) {
			continue
		}
		if node.scope_id == inp.active_scope_id {
			append(&candidates, idx)
		}
	}

	// Fallback if current scope has no focusable widgets
	if len(candidates) == 0 {
		for i := 0; i < len(ctx.nodes); i += 1 {
			idx := i32(i)
			node := ctx.nodes[idx]
			if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) {
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
	chosen := ctx.nodes[chosen_idx]
	inp.focused_id      = chosen.id_hash
	inp.active_scope_id = chosen.scope_id
	inp.focus_path_len  = build_ancestor_path(ctx, chosen_idx, &inp.focus_path)
}

cycle_focus_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, step: int) {
	scopes := make([dynamic]u64, 0, 8, ctx.allocator)

	for i := 0; i < len(ctx.nodes); i += 1 {
		idx := i32(i)
		node := ctx.nodes[idx]
		if !node.config.focusable || !is_node_allowed(ctx, idx, capture_idx) {
			continue
		}
		found := false
		for s in scopes {
			if s == node.scope_id {
				found = true
				break
			}
		}
		if !found {
			append(&scopes, node.scope_id)
		}
	}

	if len(scopes) <= 1 {
		return
	}

	cur_pos := 0
	for s, pos in scopes {
		if s == inp.active_scope_id {
			cur_pos = pos
			break
		}
	}

	count := len(scopes)
	next_pos := ((cur_pos + step) % count + count) % count
	target_scope := scopes[next_pos]

	for i := 0; i < len(ctx.nodes); i += 1 {
		idx := i32(i)
		node := ctx.nodes[idx]
		if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) && node.scope_id == target_scope {
			inp.focused_id      = node.id_hash
			inp.active_scope_id = target_scope
			inp.focus_path_len  = build_ancestor_path(ctx, idx, &inp.focus_path)
			return
		}
	}
}

@(private)
update_hover_at_point :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	mx, my: i32,
) -> (hit_idx: i32, backdrop_modal: u64) {
	if mx < 0 || my < 0 {
		inp.hovered_id     = 0
		inp.hover_path_len = 0
		return -1, 0
	}

	hit_idx, backdrop_modal = hit_test_point(ctx, capture_idx, mx, my)
	raw_hit_id := ctx.nodes[hit_idx].id_hash if hit_idx >= 0 else 0

	// While a widget holds active_press_id capture, suppress hover highlights on unrelated background nodes
	if inp.active_press_id != 0 && raw_hit_id != inp.active_press_id {
		inp.hovered_id     = 0
		inp.hover_path_len = 0
		return hit_idx, backdrop_modal
	}

	inp.hovered_id = raw_hit_id
	if hit_idx >= 0 {
		inp.hover_path_len = build_ancestor_path(ctx, hit_idx, &inp.hover_path)
	} else {
		inp.hover_path_len = 0
	}
	return hit_idx, backdrop_modal
}

handle_mouse_event :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, ev: Mouse_Event) {
	prev_pos := inp.mouse_pos if inp.mouse_initialized else [2]i32{ev.x, ev.y}
	inp.mouse_pos = {ev.x, ev.y}
	inp.mouse_initialized = ev.x >= 0 && ev.y >= 0

	hit_idx, backdrop_modal := update_hover_at_point(inp, ctx, capture_idx, ev.x, ev.y)

	switch ev.action {
	case .Move, .Motion:
		if inp.active_splitter_id != 0 {
			handle_splitter_drag(inp, ctx, ev.x, ev.y)
		}
		if inp.mouse_down && inp.active_press_id != 0 {
			inp.drag_delta = {ev.x - prev_pos[0], ev.y - prev_pos[1]}
			if p_idx, ok := ctx.id_map[inp.active_press_id]; ok {
				var_path: [MAX_HIT_DEPTH]u64
				p_len := build_ancestor_path(ctx, p_idx, &var_path)
				dispatch_three_phase(ctx, var_path[:p_len], ev, inp.event_handler, inp.event_userdata)
			}
		} else if inp.hover_path_len > 0 {
			dispatch_three_phase(ctx, inp.hover_path[:inp.hover_path_len], ev, inp.event_handler, inp.event_userdata)
		}

	case .Leave:
		inp.hovered_id     = 0
		inp.hover_path_len = 0

	case .Drag:
		if inp.active_splitter_id != 0 {
			handle_splitter_drag(inp, ctx, ev.x, ev.y)
		}
		if inp.active_press_id != 0 {
			inp.drag_delta = {ev.x - prev_pos[0], ev.y - prev_pos[1]}
			if p_idx, ok := ctx.id_map[inp.active_press_id]; ok {
				var_path: [MAX_HIT_DEPTH]u64
				p_len := build_ancestor_path(ctx, p_idx, &var_path)
				dispatch_three_phase(ctx, var_path[:p_len], ev, inp.event_handler, inp.event_userdata)
			}
		}

	case .Press:
		if ev.button == .Wheel_Up {
			if inp.hover_path_len > 0 {
				dispatch_three_phase(ctx, inp.hover_path[:inp.hover_path_len], ev, inp.event_handler, inp.event_userdata)
			}
			handle_mouse_scroll(inp, ctx, capture_idx, ev.x, ev.y, -1)
		} else if ev.button == .Wheel_Down {
			if inp.hover_path_len > 0 {
				dispatch_three_phase(ctx, inp.hover_path[:inp.hover_path_len], ev, inp.event_handler, inp.event_userdata)
			}
			handle_mouse_scroll(inp, ctx, capture_idx, ev.x, ev.y, +1)
		} else if ev.button == .Left {
			inp.mouse_down = true
			if hit_idx >= 0 {
				node := ctx.nodes[hit_idx]
				inp.active_press_id = node.id_hash
				inp.active_id       = node.id_hash
				inp.hovered_id      = node.id_hash
				inp.hover_path_len  = build_ancestor_path(ctx, hit_idx, &inp.hover_path)
				if node.config.focusable && is_node_allowed(ctx, hit_idx, capture_idx) {
					inp.focused_id      = node.id_hash
					inp.active_scope_id = node.scope_id
					inp.focus_path_len  = build_ancestor_path(ctx, hit_idx, &inp.focus_path)
				}
				if node.config.splitter {
					begin_splitter_drag(inp, ctx, hit_idx, ev.x, ev.y)
				}
				if node.config.text_input {
					handle_text_input_click(inp, ctx, hit_idx, ev.x)
				}
				dispatch_three_phase(ctx, inp.hover_path[:inp.hover_path_len], ev, inp.event_handler, inp.event_userdata)
			} else {
				inp.active_press_id = 0
				inp.active_id       = 0
				if backdrop_modal != 0 {
					inp.backdrop_clicked_id = backdrop_modal
				}
			}
		} else if ev.button == .Middle && hit_idx >= 0 {
			if ctx.nodes[hit_idx].config.splitter {
				reset_splitter_to_default(inp, ctx, hit_idx)
			}
		}

	case .Release:
		if ev.button == .Left {
			inp.mouse_down = false
			inp.active_splitter_id = 0
			pressed_id := inp.active_press_id
			inp.active_press_id = 0
			inp.active_id       = 0

			// Re-evaluate hover now that active_press_id capture has been released
			rel_hit_idx, _ := update_hover_at_point(inp, ctx, capture_idx, ev.x, ev.y)
			rel_hit_id := ctx.nodes[rel_hit_idx].id_hash if rel_hit_idx >= 0 else 0

			if pressed_id != 0 {
				consumed := false
				if p_idx, ok := ctx.id_map[pressed_id]; ok {
					var_path: [MAX_HIT_DEPTH]u64
					p_len := build_ancestor_path(ctx, p_idx, &var_path)
					consumed = dispatch_three_phase(ctx, var_path[:p_len], ev, inp.event_handler, inp.event_userdata)
				}
				// Standard GUI button rule: click activates iff release occurs inside the pressed widget
				if !consumed && rel_hit_id == pressed_id {
					inp.activated_id = pressed_id
					inp.clicked_id   = pressed_id
				}
			}
		}

	case .Scroll_Up:
		if inp.hover_path_len > 0 {
			dispatch_three_phase(ctx, inp.hover_path[:inp.hover_path_len], ev, inp.event_handler, inp.event_userdata)
		}
		handle_mouse_scroll(inp, ctx, capture_idx, ev.x, ev.y, -1)

	case .Scroll_Down:
		if inp.hover_path_len > 0 {
			dispatch_three_phase(ctx, inp.hover_path[:inp.hover_path_len], ev, inp.event_handler, inp.event_userdata)
		}
		handle_mouse_scroll(inp, ctx, capture_idx, ev.x, ev.y, +1)
	}
}

// Walks ctx.z_order in reverse (highest effective_z first, children before parents).
// Intersects against both node.node_clip and node.rect (preventing ghost clicks on scrolled-out children),
// enforces modal shields, and returns the capturing modal ID if a click fell on its backdrop.
hit_test_point :: proc "contextless" (
	ctx: ^Layout_Context,
	capture_idx: i32,
	mx, my: i32,
) -> (hit_idx: i32, backdrop_modal_id: u64) {
	if mx < 0 || mx >= ctx.screen_size[0] || my < 0 || my >= ctx.screen_size[1] {
		return -1, 0
	}

	min_allowed_z := compute_active_shield_z(ctx)
	if capture_idx >= 0 {
		min_allowed_z = max(min_allowed_z, ctx.nodes[capture_idx].effective_z)
	}

	for i := len(ctx.z_order) - 1; i >= 0; i -= 1 {
		idx := ctx.z_order[i]
		node := ctx.nodes[idx]

		// Stop immediately before reaching layers beneath an active capturing modal shield
		if node.effective_z < min_allowed_z {
			break
		}

		if !is_node_allowed(ctx, idx, capture_idx) {
			continue
		}

		// Crucial: check both node_clip (viewport intersection) and rect
		if !point_in_rect(mx, my, node.node_clip) || !point_in_rect(mx, my, node.rect) {
			continue
		}

		if is_interactive_node(node.config) {
			return idx, 0
		}

		// Solid floating or capturing containers occlude lower layers at (mx, my)
		// so clicking empty space inside a modal/dropdown never punches through to z_layer = 0
		if node.out_of_flow || node.config.capture_input {
			return -1, 0
		}
	}

	if capture_idx >= 0 {
		return -1, ctx.nodes[capture_idx].id_hash
	}
	return -1, 0
}

// =============================================================================
// Scroll Slot Management & Z-Aware Scroll Bubbling
// =============================================================================

get_scroll_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Scroll_Slot {
	empty_idx := -1
	for i := 0; i < MAX_SCROLL_SLOTS; i += 1 {
		if inp.scroll_slots[i].id_hash == id_hash {
			return &inp.scroll_slots[i]
		}
		if empty_idx == -1 && inp.scroll_slots[i].id_hash == 0 {
			empty_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else 0
	inp.scroll_slots[idx] = Scroll_Slot{
		id_hash       = id_hash,
		viewport_rows = 0,
	}
	return &inp.scroll_slots[idx]
}

get_scroll_offset :: proc(inp: ^Input_State, id: string) -> i32 {
	slot := get_scroll_slot(inp, hash_id(id))
	return slot.offset
}

get_selected_row :: proc(inp: ^Input_State, id: string) -> i32 {
	slot := get_scroll_slot(inp, hash_id(id))
	return slot.selected_row
}

sync_scroll_viewports :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context) {
	for i := 0; i < len(ctx.nodes); i += 1 {
		node := &ctx.nodes[i]
		if !node.config.scrollable {
			continue
		}
		slot := get_scroll_slot(inp, node.id_hash)
		slot.viewport_rows = max(1, node.inner_rect.h)
		slot.total_rows    = node.content_span[1]
		slot.max_offset    = max(0, slot.total_rows - slot.viewport_rows)
		if node.config.virtual_total_rows == 0 {
			slot.offset = clamp(node.config.scroll_offset, 0, slot.max_offset)
		} else {
			slot.offset = clamp(slot.offset, 0, slot.max_offset)
		}
		slot.selected_row         = clamp(slot.selected_row, 0, max(0, slot.total_rows - 1))
		node.config.scroll_offset = slot.offset
	}
}

// Walks ctx.z_order front-to-back to find the topmost visible node at (mx, my),
// then bubbles up parent_idx to find the nearest enclosing scrollable container.
hit_test_scrollable :: proc "contextless" (ctx: ^Layout_Context, capture_idx: i32, mx, my: i32) -> i32 {
	if mx < 0 || mx >= ctx.screen_size[0] || my < 0 || my >= ctx.screen_size[1] {
		return -1
	}

	min_allowed_z := compute_active_shield_z(ctx)
	if capture_idx >= 0 {
		min_allowed_z = max(min_allowed_z, ctx.nodes[capture_idx].effective_z)
	}

	for i := len(ctx.z_order) - 1; i >= 0; i -= 1 {
		idx := ctx.z_order[i]
		node := ctx.nodes[idx]

		if node.effective_z < min_allowed_z {
			break
		}
		if !is_node_allowed(ctx, idx, capture_idx) {
			continue
		}
		if !point_in_rect(mx, my, node.node_clip) || !point_in_rect(mx, my, node.rect) {
			continue
		}

		// Bubble up from the hit node to its nearest scrollable ancestor
		// without crossing out-of-flow overlay boundaries.
		curr := idx
		for curr >= 0 {
			curr_node := ctx.nodes[curr]
			if !is_node_allowed(ctx, curr, capture_idx) {
				break
			}
			if curr_node.config.scrollable {
				return curr
			}
			if curr_node.out_of_flow || curr_node.config.capture_input {
				break
			}
			curr = curr_node.parent_idx
		}

		// Stop if we hit a non-scrollable floating overlay or modal so wheel events never punch through
		if node.out_of_flow || node.config.capture_input {
			return -1
		}
	}
	return -1
}

handle_mouse_scroll :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	mx, my: i32,
	dir: i32, // -1 for Scroll_Up, +1 for Scroll_Down
) -> bool {
	scroll_idx := hit_test_scrollable(ctx, capture_idx, mx, my)
	if scroll_idx < 0 {
		return false
	}

	node := &ctx.nodes[scroll_idx]
	step := node.config.scroll_step if node.config.scroll_step > 0 else 3
	apply_scroll_delta(inp, ctx, scroll_idx, dir * step, false)
	return true
}

handle_key_scroll :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	code: Key_Code,
) -> bool {
	if inp.focused_id == 0 {
		return false
	}
	focus_idx, exists := ctx.id_map[inp.focused_id]
	if !exists || !is_node_allowed(ctx, focus_idx, capture_idx) {
		return false
	}

	scroll_idx := i32(-1)
	curr := focus_idx
	for curr >= 0 {
		if ctx.nodes[curr].config.scrollable && is_node_allowed(ctx, curr, capture_idx) {
			scroll_idx = curr
			break
		}
		if ctx.nodes[curr].out_of_flow {
			break
		}
		curr = ctx.nodes[curr].parent_idx
	}

	if scroll_idx < 0 {
		return false
	}

	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	page := max(1, slot.viewport_rows - 1)
	is_virtual := node.config.virtual_total_rows > 0

	#partial switch code {
	case .Up:
		if is_virtual {
			move_virtual_selection(slot, -1)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, -1, false)
		}
		return true
	case .Down:
		if is_virtual {
			move_virtual_selection(slot, +1)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, +1, false)
		}
		return true
	case .Page_Up:
		if is_virtual {
			move_virtual_selection(slot, -page)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, -page, false)
		}
		return true
	case .Page_Down:
		if is_virtual {
			move_virtual_selection(slot, +page)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, +page, false)
		}
		return true
	case .Home:
		if is_virtual {
			slot.selected_row = 0
		}
		apply_scroll_delta(inp, ctx, scroll_idx, -slot.max_offset - 1, false)
		return true
	case .End:
		if is_virtual {
			slot.selected_row = max(0, slot.total_rows - 1)
		}
		apply_scroll_delta(inp, ctx, scroll_idx, slot.max_offset + 1, false)
		return true
	}
	return false
}

move_virtual_selection :: proc "contextless" (slot: ^Scroll_Slot, delta: i32) {
	if slot.total_rows <= 0 {
		return
	}
	slot.selected_row = clamp(slot.selected_row + delta, 0, slot.total_rows - 1)
	v_rows := max(1, slot.viewport_rows)
	pad := clamp(slot.scroll_padding, 0, max(0, (v_rows - 1) / 2))
	if slot.selected_row < slot.offset + pad {
		slot.offset = slot.selected_row - pad
	} else if slot.selected_row >= slot.offset + v_rows - pad {
		slot.offset = slot.selected_row - v_rows + 1 + pad
	}
	slot.offset = clamp(slot.offset, 0, slot.max_offset)
}

apply_scroll_delta :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	delta: i32,
	move_selection: bool,
) {
	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	old_offset := slot.offset
	new_offset := clamp(old_offset + delta, 0, slot.max_offset)
	actual_delta := new_offset - old_offset

	slot.offset               = new_offset
	node.config.scroll_offset = new_offset
	inp.scrolled_id           = node.id_hash

	if move_selection && node.config.virtual_total_rows > 0 {
		slot.selected_row = clamp(slot.selected_row + delta, 0, max(0, slot.total_rows - 1))
	}

	if actual_delta != 0 && node.config.virtual_total_rows == 0 {
		shift_descendants_y(ctx, scroll_idx, -actual_delta, node.inner_clip)
	}
}

shift_descendants_y :: proc "contextless" (ctx: ^Layout_Context, parent_idx: i32, dy: i32, clip_root: Rect) {
	for c := ctx.nodes[parent_idx].first_child; c != -1; c = ctx.nodes[c].next_sibling {
		child := &ctx.nodes[c]
		if child.out_of_flow {
			continue
		}
		child.rect.y       += dy
		child.inner_rect.y += dy
		child.node_clip     = rect_intersect(clip_root, child.rect)
		child.inner_clip    = rect_intersect(child.node_clip, child.inner_rect)
		if child.child_count > 0 {
			shift_descendants_y(ctx, c, dy, child.inner_clip)
		}
	}
}
