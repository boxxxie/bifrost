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

MAX_FOCUS_HISTORY    :: 8
MAX_HIT_DEPTH        :: 32
MAX_SCROLL_SLOTS     :: 32
MAX_SCOPE_MEMORY     :: 64
MAX_FOCUS_PATH       :: 32
MAX_FLOATING_WINDOWS :: 16

Nav_Dir :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

Keymap_Style :: enum u8 {
	Vim = 0, // Prefix count (`5j`, `3l`) + modal `h/j/k/l` navigation
	Helix,   // Selection/Motion-first + postfix/suffix count (`j5`, `l3`) & `g` goto chords
	Emacs,   // Chordal `C-n`/`C-p`/`C-f`/`C-b` navigation + `C-u` universal argument (`4x`, `C-u 7`)
}

Page_Cmd :: enum u8 {
	Page_Up,
	Page_Down,
	Home,
	End,
}

Key_Result :: enum u8 {
	Ignored,
	Consumed,
}

OUT_OF_LANE_PENALTY :: 1_000_000

// Persistent across frames (owned by the UI Actor; zero heap allocations)
Input_State :: struct {
	// Focus state, H/H* scope memory & nested modal LIFO restoration stack
	focused_id:          u64, // Currently focused widget ID hash
	prev_focused_id:     u64, // Focused widget ID hash from start of resolve_input
	wants_focus_id:      u64, // Optional programmatic focus request for next reconcile
	editing_id:          u64, // Active text-capture target (0 = navigation stage; focused_id or ancestor Scope_Text_Sink)
	carry_edit_mode:     bool,
	ensure_visible:      bool,
	preferred_nav_pos:   [2]i32,
	has_preferred_x:     bool,
	has_preferred_y:     bool,
	frame_index:         u64,
	active_scope_id:     u64, // Active focus_scope container ID hash
	active_capture_id:   u64, // Topmost capture_input (modal) ID hash (0 if none)
	active_shield_z:     u8,  // Highest effective_z among mounted capture_input nodes
	focus_history:       [MAX_FOCUS_HISTORY]Focus_Scope_Entry,
	focus_history_len:   int,
	focus_node_path:     [MAX_FOCUS_PATH]i32,
	focus_node_path_len: int,
	scope_memory:        [MAX_SCOPE_MEMORY]Scope_Memory_Entry,
	scope_memory_len:    int,
	floating_mru:        [MAX_FLOATING_WINDOWS]u64,
	floating_mru_len:    int,

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

	// Fixed-capacity single-line UTF-8 text input slots & multi-line text area slots
	text_changed_id:     u64,
	text_slots:          [MAX_TEXT_SLOTS]Text_Input_Slot,
	text_area_slots:     [MAX_TEXT_AREA_SLOTS]Text_Area_State,

	// Fixed-capacity interactive pane splitter slots
	active_splitter_id:  u64,
	splitter_slots:      [MAX_SPLITTER_SLOTS]Splitter_Slot,

	// 3-tier scoped/global keybinding table & per-frame action dispatch
	keybindings:           [MAX_KEYBINDINGS]Keybinding,
	keybinding_count:      int,
	triggered_action_id:   u64,
	triggered_action_name: string,
	triggered_enum_val:    i64,
	has_triggered_enum:    bool,

	// Track 8: Multi-key chord state, per-scope transient sub-modes & single-source action specs
	pending_chord:         Pending_Chord_State,
	clock_ns:              i64, // Monotonic frame clock (updated from UI_Msg_Frame_Tick.tick_ns)
	chord_timeout_ns:      i64, // Prefix timeout in nanoseconds (0 = DEFAULT_CHORD_TIMEOUT_NS)
	repeat_count:          i32, // Accumulated Vim-style numeric prefix or Emacs C-u count (0 = none)
	keymap_style:          Keymap_Style,
	has_last_motion:       bool,
	last_motion_dir:       Nav_Dir,
	last_motion_applied:   i32,
	suffix_count:          i32, // Active Helix-style postfix/suffix count (e.g. `j5` -> 5)
	emacs_universal_arg:   bool,
	emacs_arg_digits:      bool,
	scope_submodes:        [MAX_SCOPE_SUBMODES]Scope_Submode_Entry,
	scope_submode_len:     int,
	action_specs:          [MAX_ACTION_SPECS]Action_Spec,
	action_spec_cnt:       int,
	action_userdata:       rawptr,
	last_disabled_reason:  string,

	// Internal zero-allocation clipboard buffer & OSC 52 request flag
	clipboard_buf:         [MAX_TEXT_BYTES]byte,
	clipboard_len:         int,
	osc52_pending:         bool,
}

consume_repeat_count :: proc "contextless" (inp: ^Input_State) -> i32 {
	if inp == nil || inp.repeat_count <= 0 {
		if inp != nil {
			inp.emacs_universal_arg = false
			inp.emacs_arg_digits    = false
		}
		return 1
	}
	c := clamp(inp.repeat_count, 1, 9999)
	inp.repeat_count        = 0
	inp.emacs_universal_arg = false
	inp.emacs_arg_digits    = false
	return c
}

clear_repeat_count :: proc "contextless" (inp: ^Input_State) {
	if inp != nil {
		inp.repeat_count        = 0
		inp.emacs_universal_arg = false
		inp.emacs_arg_digits    = false
		inp.has_last_motion     = false
		inp.last_motion_applied = 0
		inp.suffix_count        = 0
	}
}

set_keymap_style :: proc(inp: ^Input_State, style: Keymap_Style) {
	if inp == nil {
		return
	}
	inp.keymap_style  = style
	inp.pending_chord = {}
	clear_repeat_count(inp)

	// Rebind all Action_Specs that declare style-specific chords (`vim=`, `helix=`, `emacs=`)
	for i := 0; i < inp.action_spec_cnt; i += 1 {
		spec := inp.action_specs[i]
		target_chord := ""
		target_desc  := ""
		switch style {
		case .Vim:
			target_chord = spec.chord_vim
			target_desc  = spec.desc_vim
		case .Helix:
			target_chord = spec.chord_helix if len(spec.chord_helix) > 0 else spec.chord_vim
			target_desc  = spec.desc_helix if len(spec.desc_helix) > 0 else spec.desc_vim
		case .Emacs:
			target_chord = spec.chord_emacs if len(spec.chord_emacs) > 0 else spec.chord_vim
			target_desc  = spec.desc_emacs if len(spec.desc_emacs) > 0 else spec.desc_vim
		}
		if len(target_desc) > 0 {
			inp.action_specs[i].desc = target_desc
		}
		if !spec.user_rebound && len(target_chord) > 0 && target_chord != spec.chord_spec {
			_ = rebind_action_chord_internal(inp, spec.action_name, target_chord, false)
		}
	}

	// In Emacs mode, free `<C-p>` for `previous-line` (Up) and bind `palette.toggle` to `<M-x>` (`execute-extended-command`)
	pal_id := hash_id("palette.toggle")
	has_palette := false
	pal_user_rebound := false
	for i := 0; i < inp.keybinding_count; i += 1 {
		if inp.keybindings[i].action_id == pal_id {
			has_palette = true
			if inp.keybindings[i].spec_idx > 0 && int(inp.keybindings[i].spec_idx - 1) < inp.action_spec_cnt {
				pal_user_rebound = inp.action_specs[inp.keybindings[i].spec_idx - 1].user_rebound
			}
			break
		}
	}
	if has_palette && !pal_user_rebound {
		_ = rebind_action_chord_internal(inp, "palette.toggle", "<M-x>" if style == .Emacs else "<C-p>|<M-x>", false)
	}
}

cycle_keymap_style :: proc(inp: ^Input_State) -> Keymap_Style {
	if inp == nil {
		return .Vim
	}
	next := Keymap_Style((int(inp.keymap_style) + 1) % len(Keymap_Style))
	set_keymap_style(inp, next)
	return next
}

keymap_style_name :: proc "contextless" (style: Keymap_Style) -> string {
	switch style {
	case .Vim:
		return "Vim"
	case .Helix:
		return "Helix"
	case .Emacs:
		return "Emacs"
	}
	return "Vim"
}

Button_Spec :: struct {
	label:       string,
	width:       Axis_Size,
	height:      Axis_Size,
	border:      Border_Kind,
	fg:          Color,
	bg:          Color,
	hover_bg:    Color,
	focus_fg:    Color,
	focus_bg:    Color,
	focus_flags: Focus_Flags,
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
			off_x := node.config.scroll_offset_x
			off_y := node.config.scroll_offset
			if inp != nil {
				slot := get_scroll_slot(inp, node.id_hash)
				off_x = slot.offset_x
				off_y = slot.offset
			}
			entry.scroll_max = {max_x, max_y}
			entry.scroll_offset[0] = clamp(off_x, 0, max_x)
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
	is_enabled := .Disabled not_in spec.focus_flags
	return leaf(ctx, id, text_w, 1, Box_Config{
		dir         = .Row,
		width       = w,
		height      = h,
		border      = spec.border,
		main_align  = .Center,
		cross_align = .Center,
		focus_flags = spec.focus_flags,
		focusable   = is_enabled,
		clickable   = is_enabled,
		hoverable   = is_enabled,
	})
}

was_activated :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp.activated_id != 0 && inp.activated_id == hash_id(id)
}

request_focus :: #force_inline proc(inp: ^Input_State, id: string) {
	if inp != nil && len(id) > 0 {
		inp.wants_focus_id = hash_id(id)
	}
}

is_focused :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp.focused_id != 0 && inp.focused_id == hash_id(id)
}

is_editing :: #force_inline proc(inp: ^Input_State, id: string) -> bool {
	return inp.editing_id != 0 && inp.editing_id == hash_id(id)
}

is_scope_selected :: proc(inp: ^Input_State, id: string) -> bool {
	h := hash_id(id)
	if h == 0 {
		return false
	}
	for i := 0; i < inp.scope_memory_len; i += 1 {
		if inp.scope_memory[i].scope_hash != 0 && inp.scope_memory[i].last_leaf_hash == h {
			return true
		}
	}
	return false
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

// Releases active mouse captures, splitter drags, and hover state upon terminal focus loss (`CSI O`).
reset_pointer_on_focus_out :: proc "contextless" (inp: ^Input_State) {
	inp.hovered_id         = 0
	inp.hover_path_len     = 0
	inp.active_id          = 0
	inp.active_press_id    = 0
	inp.active_splitter_id = 0
	inp.mouse_down         = false
	inp.mouse_initialized  = false
	inp.drag_delta         = {0, 0}
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
	inp.triggered_enum_val    = 0
	inp.has_triggered_enum    = false
	inp.last_disabled_reason  = ""
	inp.drag_delta            = {0, 0}

	if len(ctx.nodes) == 0 {
		inp.focused_id          = 0
		inp.editing_id          = 0
		inp.carry_edit_mode     = false
		inp.hovered_id          = 0
		inp.active_id           = 0
		inp.active_press_id     = 0
		inp.focus_path_len      = 0
		inp.focus_node_path_len = 0
		inp.hover_path_len      = 0
		inp.focus_history_len   = 0
		return
	}

	// 0. Apply non-modal floating window MRU z-promotion, then sync scroll & splitter geometries
	apply_floating_z_promotion(inp, ctx)
	sync_scroll_viewports(inp, ctx)
	sync_splitters(inp, ctx)

	// 1. Identify topmost active Trap_Focus / capture_input container via ctx.z_order (effective_z)
	capture_idx := find_topmost_capture_node(ctx)
	inp.active_shield_z = compute_active_shield_z(ctx)
	if capture_idx >= 0 {
		inp.active_capture_id = ctx.nodes[capture_idx].id_hash
	}

	// 2. Reconcile focused_id & editing_id with current scope tree, H/H* memory, and modal traps
	reconcile_focus(inp, ctx, capture_idx)

	// 2b. Expire timed-out pending prefix chords (firing any shadowed single-step fallback)
	expire_pending_chord(inp, ctx, capture_idx, inp.clock_ns)

	// 3. Process incoming keyboard, mouse, and focus-loss events
	for ev in events {
		switch e in ev {
		case Key_Event:
			handle_key_event(inp, ctx, capture_idx, e)
		case Mouse_Event:
			handle_mouse_event(inp, ctx, capture_idx, e)
		case Focus_Loss_Event:
			reset_pointer_on_focus_out(inp)
		case Focus_Event:
			if !e.focused {
				reset_pointer_on_focus_out(inp)
			}
		case Paste_Event:
			inp.clipboard_len, _ = copy_string_to_buf(inp.clipboard_buf[:], e.text)
			target_id := inp.editing_id if inp.editing_id != 0 else inp.focused_id
			if target_id != 0 {
				if t_idx, exists := ctx.id_map[target_id]; exists && is_node_allowed(ctx, t_idx, capture_idx) {
					t_node := ctx.nodes[t_idx]
					if (.Captures_Text in t_node.focus_flags) && (.Disabled not_in t_node.focus_flags) {
						if t_node.config.text_area {
							ta_slot := get_text_area_slot(inp, target_id)
							_ = text_area_insert_string(inp, ta_slot, e.text)
						} else {
							slot := get_text_slot(inp, target_id)
							text_input_insert_string(inp, slot, e.text)
							if inp.text_changed_id == t_node.id_hash && (.Scope_Text_Sink in t_node.focus_flags) {
								reset_scope_selection_to_default(inp, ctx, t_node.parent_scope_idx, capture_idx)
							}
						}
					}
				}
			}
		case Resize_Event:
		}
	}

	// 4. Ensure programmatically requested focus visibility if pending
	if inp.ensure_visible {
		inp.ensure_visible = false
		if inp.focused_id != 0 {
			if f_idx, ok := ctx.id_map[inp.focused_id]; ok {
				scroll_node_into_view(inp, ctx, f_idx)
			}
		}
	}

	// 5. Refresh hovered_id against current layout & modal occlusion when no mouse event
	// already updated hover (e.g., stationary cursor over a scrolling viewport)
	if inp.mouse_initialized && len(events) == 0 {
		update_hover_at_point(inp, ctx, capture_idx, inp.mouse_pos[0], inp.mouse_pos[1])
	}
}

// Applies 3-state visual highlight styling to focused, inactive scope-selected, hovered, and disabled widgets before render_layout()
apply_input_highlights :: proc(s: ^Screen, ctx: ^Layout_Context, inp: ^Input_State) {
	if len(ctx.nodes) > 0 {
		apply_floating_z_promotion(inp, ctx)
		sync_scroll_viewports(inp, ctx)
		sync_splitters(inp, ctx)
	}

	for i := 0; i < len(ctx.nodes); i += 1 {
		node := ctx.nodes[i]
		if node.config.text_area {
			sync_text_area_paint(s, inp, node)
			continue
		}
		if node.config.text_input {
			sync_text_input_paint(s, inp, node)
			continue
		}
		if node.config.splitter {
			sync_splitter_paint(s, inp, node)
			continue
		}
		if .Disabled in node.focus_flags {
			if paint, ok := s.paints[node.id_hash]; ok {
				paint.style += {.Dim}
				s.paints[node.id_hash] = paint
			}
			continue
		}
		if !node.config.focusable {
			continue
		}
		paint, ok := s.paints[node.id_hash]
		if !ok {
			continue
		}
		is_container_scope := (.Focus_Scope in node.focus_flags) || node.config.virtual_total_rows > 0
		if node.id_hash == inp.focused_id {
			if is_container_scope && (paint.fill_bg || paint.bg.kind != .Default) {
				paint.title_style += {.Bold, .Reverse}
			} else {
				paint.style += {.Bold, .Reverse}
			}
			if paint.border_fg.kind == .Default {
				paint.border_fg = rgb(255, 215, 0)
			}
		} else if is_inactive_scope_leaf_selected(inp, ctx, i32(i)) {
			if is_container_scope && (paint.fill_bg || paint.bg.kind != .Default) {
				paint.title_style += {.Dim, .Reverse}
			} else {
				paint.style += {.Dim, .Reverse}
			}
		} else if node.id_hash == inp.hovered_id {
			paint.style += {.Underline}
		}
		s.paints[node.id_hash] = paint
	}

	refresh_dynamic_bars(s, ctx, inp)
}


@(private)
is_interactive_node :: #force_inline proc "contextless" (cfg: Box_Config) -> bool {
	return cfg.focusable || cfg.clickable || cfg.hoverable || cfg.draggable || cfg.splitter || cfg.text_input || cfg.text_area
}


handle_key_event :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, ev: Key_Event) {
	if ev.action == .Release || is_pure_modifier_key(ev.code) {
		return
	}
	if inp.focused_id != 0 {
		if f_idx, ok := ctx.id_map[inp.focused_id]; ok {
			inp.focus_path_len      = build_ancestor_path(ctx, f_idx, &inp.focus_path)
			inp.focus_node_path_len = build_focus_node_path(ctx, f_idx, &inp.focus_node_path)
		} else {
			inp.focus_path_len      = 0
			inp.focus_node_path_len = 0
		}
	} else {
		inp.focus_path_len      = 0
		inp.focus_node_path_len = 0
	}

	// 0a. 3-Phase Dispatch (Capturing -> At_Target -> Bubbling) with consume short-circuiting
	if inp.focus_path_len > 0 {
		if dispatch_three_phase(ctx, inp.focus_path[:inp.focus_path_len], ev, inp.event_handler, inp.event_userdata) {
			return
		}
	}

	// 0a2. Pending 2-Step Key-Chord Resolution (`"g g"`, `"<C-w> l"`, `<Esc>` cancel)
	if inp.pending_chord.active {
		resolve_pending_chord_step(inp, ctx, capture_idx, ev)
		return
	}

	// 0b. Global_Always keybindings (active even across Trap_Focus shields)
	if dispatch_global_always_keybindings(inp, ctx, ev) {
		return
	}

	// 0c. Active `editing_id` Text Input / Text Area Routing (two-stage Escape / Emacs C-g exit, Allow_In_Text_Input chords, & UTF-8 editing)
	if inp.editing_id != 0 {
		is_emacs_quit := inp.keymap_style == .Emacs && ev.code == .Rune && (ev.ch == 'g' || ev.ch == 'G') && (ev.mods - {.Caps_Lock, .Num_Lock}) == {.Ctrl}
		if ev.code == .Escape || is_emacs_quit {
			if e_idx, ok := ctx.id_map[inp.editing_id]; ok {
				e_node := ctx.nodes[e_idx]
				if e_node.config.text_area {
					ta_slot := get_text_area_slot(inp, e_node.id_hash)
					if ta_slot.has_selection {
						ta_slot.has_selection = false
						clear_repeat_count(inp)
						return
					}
					ta_slot.exited_edit = true
					inp.editing_id      = 0
					clear_repeat_count(inp)
					return
				}
				if .Auto_Edit not_in e_node.focus_flags {
					inp.editing_id = 0
					clear_repeat_count(inp)
					return
				}
			}
		}

		// Allow explicit .Allow_In_Text_Input / Ctrl chords (e.g. Ctrl+P, Ctrl+Left) while editing
		if dispatch_keybindings(inp, ctx, capture_idx, ev) {
			return
		}

		if e_idx, exists := ctx.id_map[inp.editing_id]; exists && is_node_allowed(ctx, e_idx, capture_idx) {
			e_node := ctx.nodes[e_idx]
			if (.Captures_Text in e_node.focus_flags) && (.Disabled not_in e_node.focus_flags) {
				if e_node.config.text_area {
					if handle_text_area_key(inp, ctx, e_idx, capture_idx, ev) {
						return
					}
				} else if handle_text_input_key(inp, ctx, e_idx, capture_idx, ev) {
					if inp.text_changed_id == e_node.id_hash && (.Scope_Text_Sink in e_node.focus_flags) {
						reset_scope_selection_to_default(inp, ctx, e_node.parent_scope_idx, capture_idx)
					}
					return
				}
			}
		}
	}

	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}

	// Emacs `Ctrl+G` (`keyboard-quit`): cancel universal argument, pending chords, or active resize sub-mode
	if inp.keymap_style == .Emacs && eff_mods == {.Ctrl} && ev.code == .Rune && (ev.ch == 'g' || ev.ch == 'G') {
		clear_repeat_count(inp)
		inp.pending_chord = {}
		if inp.focused_id != 0 && get_scope_submode_by_hash(inp, inp.focused_id) != 0 {
			set_scope_submode_by_hash(inp, inp.focused_id, 0)
		}
		return
	}

	// Emacs `Ctrl+U` universal argument (`C-u` = 4x, `C-u C-u` = 16x, `C-u 7` = 7x)
	if inp.keymap_style == .Emacs && inp.editing_id == 0 && eff_mods == {.Ctrl} && ev.code == .Rune && (ev.ch == 'u' || ev.ch == 'U') {
		if !inp.emacs_universal_arg {
			inp.emacs_universal_arg = true
			inp.emacs_arg_digits    = false
			inp.repeat_count        = 4
		} else if !inp.emacs_arg_digits {
			inp.repeat_count = min(9999, max(1, inp.repeat_count) * 4)
		}
		return
	}

	// Hierarchical scope ring cycling (F6 / Shift+F6 / Ctrl+Tab)
	if ev.code == .F6 || (ev.code == .Tab && .Ctrl in eff_mods) {
		clear_repeat_count(inp)
		cycle_focus_scope(inp, ctx, capture_idx, -1 if .Shift in eff_mods else 1)
		return
	}

	// Tip Splitter Priority: when focused on a splitter, Enter or active .Resize sub-mode keys
	// take precedence before enclosing .Scope_Only bindings or spatial navigation.
	if inp.focus_node_path_len > 0 {
		tip_idx := inp.focus_node_path[inp.focus_node_path_len - 1]
		if tip_idx >= 0 && int(tip_idx) < len(ctx.nodes) && is_node_allowed(ctx, tip_idx, capture_idx) {
			if ctx.nodes[tip_idx].config.splitter && handle_splitter_key(inp, ctx, tip_idx, ev) {
				return
			}
		}
	}

	nav_dir, is_nav := key_to_nav_dir(ev, inp.editing_id != 0, inp.keymap_style)
	page_cmd, is_page := key_to_page_cmd(ev, inp.editing_id != 0, inp.keymap_style)
	has_chord_mod := (.Ctrl in eff_mods) || (.Alt in eff_mods) || (.Super in eff_mods)
	root_bindings_checked := false

	// Pre-check innermost-first `.Scope_Only` keybindings along `focus_node_path` (halting at `.Trap_Focus`)
	if inp.editing_id == 0 {
		if inp.focus_node_path_len > 0 {
			for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
				n_idx := inp.focus_node_path[p]
				if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
					continue
				}
				if dispatch_scope_keybindings_at_node(inp, ctx, capture_idx, n_idx, ev) {
					inp.has_last_motion = false
					if !inp.pending_chord.active {
						inp.suffix_count = 0
					}
					return
				}
				if .Trap_Focus in ctx.nodes[n_idx].focus_flags {
					break
				}
			}
		}
		// Evaluate `.Root_And_Scopes` bindings before spatial/page nav for modified chords (e.g. <C-p>/<C-n>)
		// or non-navigation keys so root shortcuts are never shadowed by fallback list movement.
		if has_chord_mod || (!is_nav && !is_page && ev.code != .Enter && ev.code != .Space && ev.code != .Tab && ev.code != .Escape) {
			root_bindings_checked = true
			if dispatch_root_keybindings(inp, ctx, capture_idx, ev) {
				inp.has_last_motion = false
				if !inp.pending_chord.active {
					inp.suffix_count = 0
				}
				return
			}
		}

		// Numeric count handling across Vim (prefix `5j`), Helix (postfix/suffix `j5` + prefix `5j`), and Emacs (`C-u 5`)
		if !inp.pending_chord.active && eff_mods == {} && ev.code == .Rune && ev.ch >= '0' && ev.ch <= '9' {
			digit := i32(ev.ch - '0')
			switch inp.keymap_style {
			case .Helix:
				if inp.has_last_motion && (digit > 0 || inp.suffix_count > 0) {
					new_suffix := min(9999, inp.suffix_count * 10 + digit)
					inp.suffix_count = new_suffix
					delta := new_suffix - inp.last_motion_applied
					if delta > 0 {
						inp.repeat_count = delta
						for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
							n_idx := inp.focus_node_path[p]
							if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
								continue
							}
							if handle_spatial_nav_at_level(inp, ctx, capture_idx, p, inp.last_motion_dir) == .Consumed {
								break
							}
							if .Trap_Focus in ctx.nodes[n_idx].focus_flags {
								break
							}
						}
						inp.repeat_count        = 0
						inp.last_motion_applied = new_suffix
					}
					return
				} else if digit > 0 || inp.repeat_count > 0 {
					inp.repeat_count = min(9999, inp.repeat_count * 10 + digit)
					return
				}
			case .Emacs:
				if inp.emacs_universal_arg {
					if !inp.emacs_arg_digits {
						inp.emacs_arg_digits = true
						inp.repeat_count     = digit
					} else {
						inp.repeat_count = min(9999, inp.repeat_count * 10 + digit)
					}
					return
				}
			case .Vim:
				if digit > 0 || inp.repeat_count > 0 {
					inp.repeat_count = min(9999, inp.repeat_count * 10 + digit)
					return
				}
			}
		}
	}

	if !is_nav {
		inp.has_last_motion     = false
		inp.last_motion_applied = 0
		inp.suffix_count        = 0
	}

	if ev.code == .Escape && eff_mods == {} && (inp.repeat_count > 0 || inp.suffix_count > 0) {
		clear_repeat_count(inp)
	}

	// 7-Step Bottom-Up `focus_node_path` Walk (tip -> enclosing scopes -> root)
	trapped := false
	for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
		node_idx := inp.focus_node_path[p]
		if node_idx < 0 || int(node_idx) >= len(ctx.nodes) {
			continue
		}
		node := ctx.nodes[node_idx]
		is_tip := p == inp.focus_node_path_len - 1

		// 1. Tip Widget Specifics: Two-Stage Edit Entry (`Enter` or `i`), Scope Drill-Down (`Enter`), Leaf Activation (`Enter`/`Space`)
		if is_tip && is_node_allowed(ctx, node_idx, capture_idx) {
			if node.config.text_area && inp.editing_id != node.id_hash {
				if (ev.code == .Enter || (ev.code == .Rune && ev.ch == 'i')) && eff_mods == {} {
					ta_slot := get_text_area_slot(inp, node.id_hash)
					ta_slot.exited_edit = false
					inp.editing_id      = node.id_hash
					inp.pending_chord   = {}
					return
				}
			}
			if ev.code == .Enter && eff_mods == {} {
				if (.Captures_Text in node.focus_flags) && (.Auto_Edit not_in node.focus_flags) && inp.editing_id != node.id_hash {
					inp.editing_id    = node.id_hash
					inp.pending_chord = {}
					return
				}
				if .Focus_Scope in node.focus_flags {
					child_target := resolve_scope_child_target_idx(inp, ctx, node_idx, capture_idx, true)
					if child_target >= 0 && child_target != node_idx {
						reset_preferred_nav(inp)
						set_focused_node(inp, ctx, child_target, capture_idx, false)
						return
					}
				}
				inp.activated_id = node.id_hash
				return
			}
			if ev.code == .Space && eff_mods == {} && inp.editing_id == 0 {
				inp.activated_id = node.id_hash
				return
			}
		}

		// 2. Fallback `.Root_And_Scopes` keybindings upon reaching root `p == 0`
		if inp.editing_id == 0 && !root_bindings_checked {
			if p == 0 && dispatch_root_keybindings(inp, ctx, capture_idx, ev) {
				return
			}
		}

		// 3. Scope-Local `Tab` / `Shift+Tab` Topological Ring
		if is_tip && ev.code == .Tab && (.Ctrl not_in eff_mods) {
			reset_preferred_nav(inp)
			step_focus_within_scope(inp, ctx, capture_idx, -1 if .Shift in eff_mods else 1, true)
			return
		}

		// 4. 2D Spatial Navigation (`h/j/k/l`, Arrow keys, `Ctrl+N/P/F/B`)
		if is_nav {
			planned_steps := max(i32(1), inp.repeat_count)
			if handle_spatial_nav_at_level(inp, ctx, capture_idx, p, nav_dir) == .Consumed {
				if inp.keymap_style == .Helix {
					inp.has_last_motion     = true
					inp.last_motion_dir     = nav_dir
					inp.last_motion_applied = planned_steps
					inp.suffix_count        = 0
				}
				return
			}
		}

		// 5. Paging (`Page_Up`, `Page_Down`, `Home`, `End`)
		if is_page {
			if handle_page_nav_at_level(inp, ctx, capture_idx, p, page_cmd) == .Consumed {
				return
			}
		}

		// 5b. Active Transient Scope Sub-Mode `Escape` Exit (before drilling focus up)
		if ev.code == .Escape && eff_mods == {} && get_scope_submode_by_hash(inp, node.id_hash) != 0 {
			set_scope_submode_by_hash(inp, node.id_hash, 0)
			return
		}

		// 6. Ancestor `Escape` Drill-Up (e.g. Card -> Kanban Column Header)
		if !is_tip && ev.code == .Escape && eff_mods == {} {
			if (.Focus_Scope in node.focus_flags) && is_node_focusable(node) &&
			   (.Trap_Focus not_in node.focus_flags) && is_node_allowed(ctx, node_idx, capture_idx) {
				reset_preferred_nav(inp)
				set_focused_node(inp, ctx, node_idx, capture_idx, false)
				return
			}
		}

		// 7. `.Trap_Focus` Boundary Shield (halts all further bubbling out of modal)
		if (.Trap_Focus in node.focus_flags) || node.config.capture_input {
			if ev.code == .Escape && eff_mods == {} {
				inp.escape_modal_id = node.id_hash
			}
			trapped = true
			break
		}
	}

	if trapped {
		return
	}

	if capture_idx >= 0 {
		if ev.code == .Escape && eff_mods == {} {
			inp.escape_modal_id = ctx.nodes[capture_idx].id_hash
		}
		return
	}

	// Root fallback when focus_node_path was empty (0 focusable widgets mounted)
	if inp.focus_node_path_len == 0 && inp.editing_id == 0 {
		if dispatch_keybindings(inp, ctx, capture_idx, ev) {
			return
		}
	}

	// Standalone `.Auto_Edit` text_input Escape fallback (transfers focus to linked virtual list or next widget)
	if ev.code == .Escape && eff_mods == {} && inp.focused_id != 0 {
		if f_idx, ok := ctx.id_map[inp.focused_id]; ok && ctx.nodes[f_idx].config.text_input {
			slot := get_text_slot(inp, inp.focused_id)
			if slot.linked_list_id != 0 {
				if l_idx, l_ok := ctx.id_map[slot.linked_list_id]; l_ok && is_node_allowed(ctx, l_idx, capture_idx) {
					reset_preferred_nav(inp)
					set_focused_node(inp, ctx, l_idx, capture_idx, false)
					return
				}
			}
			reset_preferred_nav(inp)
			step_focus_within_scope(inp, ctx, capture_idx, 1, false)
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
				if is_node_focusable(node) && is_node_allowed(ctx, hit_idx, capture_idx) {
					reset_preferred_nav(inp)
					set_focused_node(inp, ctx, hit_idx, capture_idx, false)
				}
				if node.config.splitter {
					begin_splitter_drag(inp, ctx, hit_idx, ev.x, ev.y)
				}
				if (.Captures_Text in node.focus_flags) && (.Disabled not_in node.focus_flags) && is_node_allowed(ctx, hit_idx, capture_idx) {
					inp.editing_id    = node.id_hash
					inp.pending_chord = {}
					if node.config.text_area {
						ta_slot := get_text_area_slot(inp, node.id_hash)
						ta_slot.exited_edit = false
						handle_text_area_click(inp, ctx, hit_idx, ev.x, ev.y)
					} else {
						handle_text_input_click(inp, ctx, hit_idx, ev.x)
					}
				}
				// Virtual list / 2D virtual table click row & column selection
				for v_curr := hit_idx; v_curr >= 0; v_curr = ctx.nodes[v_curr].parent_idx {
					v_node := ctx.nodes[v_curr]
					if v_node.config.virtual_total_rows > 0 && is_node_allowed(ctx, v_curr, capture_idx) {
						slot := get_scroll_slot(inp, v_node.id_hash)
						rel_y := ev.y - v_node.inner_rect.y
						if rel_y >= 0 && rel_y < v_node.inner_rect.h {
							slot.selected_row = clamp(slot.offset + rel_y, 0, max(0, slot.total_rows - 1))
						}
						select_virtual_col_at_x(slot, v_node.inner_rect, ev.x)
						break
					}
					if v_node.out_of_flow {
						break
					}
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

		if !is_node_allowed(ctx, idx, capture_idx) || (.Disabled in node.focus_flags) {
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

