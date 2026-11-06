package bifrost

import "base:intrinsics"
import "core:reflect"
import "core:unicode/utf8"

// =============================================================================
// Tier 1 Declarative Key-Chord Micro-DSL, Transient Sub-Modes & Contextual Bars
// =============================================================================

MAX_CHORD_ALT      :: 4
MAX_ACTION_SPECS   :: 64
MAX_SCOPE_SUBMODES :: 16

MAX_KEYBINDINGS    :: 128

DEFAULT_CHORD_TIMEOUT_NS :: i64(1_000_000_000)

Chord_Sequence :: struct {
	steps: [2]Key_Event,
	len:   u8,
}

Key_Chord :: struct {
	alts:      [MAX_CHORD_ALT]Chord_Sequence,
	alt_count: u8,
}

Pending_Chord_State :: struct {
	active:               bool,
	first_key:            Key_Event,
	started_tick_ns:      i64,
	has_fallback:         bool,
	fallback_binding_idx: i16,
	prefix_buf:           [32]u8,
	prefix_len:           u8,
}

Scope_Submode_Entry :: struct {
	scope_hash: u64,
	submode:    u8,
}

Guard_Result :: enum u8 {
	Enabled = 0,
	Disabled_Swallow, // Consumes the key at this scope and records optional disabled reason
	Disabled_Bubble,  // Skips this binding and allows outer scopes / spatial nav to handle the key
}

Action_Availability :: enum u8 {
	Enabled = 0,
	Disabled_Dimmed, // Shown dimmed in hint bar; key press is swallowed without firing
	Hidden,          // Omitted from hint bar and ignored during dispatch
}

Action_Guard_Proc :: #type proc(action_id: u64, userdata: rawptr) -> (Guard_Result, string)
Action_Avail_Proc :: #type proc(action_id: u64, userdata: rawptr) -> Action_Availability

Binding_Group :: struct {
	id:      string,
	desc:    string,
	compact: bool,
}

Action_Spec :: struct {
	action_id:       u64,
	action_name:     string,
	chord_spec:      string,
	chord_vim:       string,
	chord_helix:     string,
	chord_emacs:     string,
	user_rebound:    bool,
	scope:           string,
	policy:          Key_Scope_Policy,
	flags:           Keybinding_Flags,
	has_submode:     bool,
	submode:         u8,
	group:           string,
	group_desc:      string,
	compact:         bool,
	has_compact:     bool,
	desc:            string,
	desc_vim:        string,
	desc_helix:      string,
	desc_emacs:      string,
	label:           string,
	category:        string,
	show_in_bar:     bool,
	hide_in_bar:     bool,
	show_in_palette: bool,
	hide_in_palette: bool,
	availability:    Action_Availability,
	guard_proc:      Action_Guard_Proc,
	guard_userdata:  rawptr,
	avail_proc:      Action_Avail_Proc,
	avail_userdata:  rawptr,
	enum_val:        i64,
	has_enum_val:    bool,
}

Keymap_Table :: struct {
	bindings:    [MAX_KEYBINDINGS]Keybinding,
	binding_cnt: int,
	specs:       [MAX_ACTION_SPECS]Action_Spec,
	spec_cnt:    int,
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
	key:                Key_Event,
	key2:               Key_Event,
	chord_len:          u8,     // 0 or 1 = single key, 2 = 2-step sequence
	scope_id:           u64,
	scope_prefix:       string, // Optional wildcard prefix when scope ends with '*' (e.g. "col_")
	policy:             Key_Scope_Policy,
	flags:              Keybinding_Flags,
	has_submode_filter: bool,
	required_submode:   u8,
	spec_idx:           i16,    // 1-based index into inp.action_specs (0 = none)
	action_id:          u64,
	action_name:        string,
	nudge_splitter_id:  u64,
	nudge_delta:        i32,
}

clear_keybindings :: proc "contextless" (inp: ^Input_State) {
	inp.keybinding_count = 0
	inp.action_spec_cnt  = 0
	inp.pending_chord    = {}
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

was_action_triggered_name :: proc(inp: ^Input_State, action_name: string) -> bool {
	return inp.triggered_action_id != 0 && inp.triggered_action_id == hash_id(action_name)
}

was_action_triggered :: proc {
	was_action_triggered_name,
	was_action_triggered_enum,
}

// Evaluates registered keybindings in 3 priority tiers:
// Tier 1: `.Scope_Only` matching scopes along `inp.focus_node_path` (innermost first, stopping at `.Trap_Focus`)
// Tier 2: `.Root_And_Scopes` (when no capturing modal shield is active)
// Tier 3: `.Global_Always` (active even when a capturing modal is open)
// Single-character printable keys without `.Ctrl` are suppressed while `inp.editing_id != 0`
// unless `.Allow_In_Text_Input` is explicitly set.
dispatch_global_always_keybindings :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	ev: Key_Event,
) -> bool {
	if inp.keybinding_count == 0 {
		return false
	}
	text_input_focused := inp.editing_id != 0
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.policy == .Global_Always && match_and_fire_binding(inp, ctx, kb, ev, text_input_focused) {
			return true
		}
	}
	return false
}

binding_matches_scope_node :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	node_idx: i32,
	kb: Keybinding,
) -> bool {
	if kb.policy != .Scope_Only || node_idx < 0 || int(node_idx) >= len(ctx.nodes) {
		return false
	}
	node := ctx.nodes[node_idx]
	scope_ok := false
	if len(kb.scope_prefix) > 0 {
		scope_ok = str_has_prefix(node.id, kb.scope_prefix)
	} else {
		scope_ok = kb.scope_id != 0 && kb.scope_id == node.id_hash
	}
	if !scope_ok {
		return false
	}
	if kb.has_submode_filter {
		return get_scope_submode_by_hash(inp, node.id_hash) == kb.required_submode
	}
	return true
}

dispatch_scope_keybindings_at_node :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	node_idx: i32,
	ev: Key_Event,
) -> bool {
	if inp.keybinding_count == 0 || node_idx < 0 || int(node_idx) >= len(ctx.nodes) {
		return false
	}
	if !is_node_allowed(ctx, node_idx, capture_idx) {
		return false
	}
	text_input_focused := inp.editing_id != 0
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if binding_matches_scope_node(inp, ctx, node_idx, kb) {
			if match_and_fire_binding(inp, ctx, kb, ev, text_input_focused) {
				return true
			}
		}
	}
	return false
}

dispatch_root_keybindings :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	if inp.keybinding_count == 0 || capture_idx >= 0 {
		return false
	}
	text_input_focused := inp.editing_id != 0
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.policy != .Root_And_Scopes {
			continue
		}
		if kb.has_submode_filter && get_scope_submode_by_hash(inp, 0) != kb.required_submode {
			continue
		}
		if match_and_fire_binding(inp, ctx, kb, ev, text_input_focused) {
			return true
		}
	}
	return false
}

dispatch_keybindings :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
) -> bool {
	if inp.keybinding_count == 0 {
		return false
	}

	text_input_focused := inp.editing_id != 0

	// Tier 1: Scope_Only bindings along focus_node_path (innermost scope first, stopping at Trap_Focus)
	if inp.focus_node_path_len > 0 {
		for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
			n_idx := inp.focus_node_path[p]
			if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
				continue
			}
			if dispatch_scope_keybindings_at_node(inp, ctx, capture_idx, n_idx, ev) {
				return true
			}
			if .Trap_Focus in ctx.nodes[n_idx].focus_flags {
				break
			}
		}
	} else {
		for i := 0; i < inp.keybinding_count; i += 1 {
			kb := inp.keybindings[i]
			if kb.policy != .Scope_Only || kb.scope_id == 0 || kb.scope_id != inp.active_scope_id {
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
	}

	// Tier 2: Root_And_Scopes bindings (suppressed when a capturing modal is open)
	if dispatch_root_keybindings(inp, ctx, capture_idx, ev) {
		return true
	}

	// Tier 3: Global_Always bindings
	return dispatch_global_always_keybindings(inp, ctx, ev)
}

key_events_match :: proc "contextless" (kb_key: Key_Event, ev: Key_Event) -> bool {
	if kb_key.code != ev.code {
		return false
	}
	kb_mods := kb_key.mods - {.Caps_Lock, .Num_Lock}
	ev_mods := ev.mods - {.Caps_Lock, .Num_Lock}

	if kb_key.code == .Rune {
		kc := kb_key.ch
		ec := ev.ch
		is_kb_alpha := (kc >= 'a' && kc <= 'z') || (kc >= 'A' && kc <= 'Z')
		is_ev_alpha := (ec >= 'a' && ec <= 'z') || (ec >= 'A' && ec <= 'Z')

		if (.Ctrl not_in kb_mods) && (.Alt not_in kb_mods) && (.Super not_in kb_mods) &&
		   (.Ctrl not_in ev_mods) && (.Alt not_in ev_mods) && (.Super not_in ev_mods) {
			if is_kb_alpha || is_ev_alpha {
				if !is_kb_alpha || !is_ev_alpha {
					return false
				}
				kb_upper := (kc >= 'A' && kc <= 'Z') || (.Shift in kb_mods)
				ev_upper := (ec >= 'A' && ec <= 'Z') || (.Shift in ev_mods)
				if kb_upper != ev_upper {
					return false
				}
				kc_low := kc + 32 if (kc >= 'A' && kc <= 'Z') else kc
				ec_low := ec + 32 if (ec >= 'A' && ec <= 'Z') else ec
				if kc_low != ec_low {
					return false
				}
			} else {
				// Shifted punctuation (e.g. '!', '?', ':') matches regardless of whether terminal reported .Shift
				if kc != ec {
					return false
				}
			}
		} else {
			if kb_mods != ev_mods {
				return false
			}
			kc_low := kc + 32 if (kc >= 'A' && kc <= 'Z') else kc
			ec_low := ec + 32 if (ec >= 'A' && ec <= 'Z') else ec
			if kc_low != ec_low {
				return false
			}
		}
	} else {
		if kb_mods != ev_mods {
			return false
		}
	}
	return true
}

@(private)
is_suppressed_in_text_input :: proc "contextless" (kb: Keybinding, ev: Key_Event, text_input_focused: bool) -> bool {
	if !text_input_focused || (.Allow_In_Text_Input in kb.flags) {
		return false
	}
	ev_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	return (.Ctrl not_in ev_mods) && (ev.code == .Rune || ev.code == .Space || ev.code == .Backspace || ev.code == .Delete || ev.code == .Left || ev.code == .Right || ev.code == .Home || ev.code == .End)
}

@(private)
match_and_fire_binding :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	kb: Keybinding,
	ev: Key_Event,
	text_input_focused: bool,
) -> bool {
	if !key_events_match(kb.key, ev) {
		return false
	}
	if is_suppressed_in_text_input(kb, ev, text_input_focused) {
		return false
	}

	capture_idx := find_topmost_capture_node(ctx)
	if kb.chord_len == 2 {
		if kb.spec_idx > 0 && int(kb.spec_idx - 1) < inp.action_spec_cnt {
			spec := inp.action_specs[kb.spec_idx - 1]
			if resolve_spec_availability(inp, spec) == .Hidden {
				return false
			}
		}
		fb_idx, has_fb := find_single_step_fallback_idx(inp, ctx, capture_idx, ev, text_input_focused)
		latch_pending_chord(inp, kb.key, has_fb, fb_idx)
		return true
	}

	// Prefix-conflict disambiguation: if a 2-step sequence starting with `ev` is also active,
	// latch the pending chord and store this 1-step binding as its timeout fallback.
	if has_active_two_step_prefix(inp, ctx, capture_idx, ev, text_input_focused) {
		fb_idx, has_fb := find_single_step_fallback_idx(inp, ctx, capture_idx, ev, text_input_focused)
		latch_pending_chord(inp, ev, has_fb, fb_idx)
		return true
	}

	return activate_matched_binding(inp, ctx, kb)
}

// =============================================================================
// Zero-Allocation Key-Chord Parser (`"n"`, `"H"`, `"<C-p>"`, `"q|<C-q>"`, `"g g"`)
// =============================================================================

parse_key_chord :: proc "contextless" (spec: string) -> (chord: Key_Chord, ok: bool) {
	trimmed := trim_ascii_space(spec)
	if len(trimmed) == 0 {
		return {}, false
	}

	start := 0
	for i := 0; i <= len(trimmed); i += 1 {
		if i == len(trimmed) || trimmed[i] == '|' {
			alt_str := trim_ascii_space(trimmed[start:i])
			if len(alt_str) == 0 {
				return {}, false
			}
			if chord.alt_count >= MAX_CHORD_ALT {
				return {}, false
			}
			seq, seq_ok := parse_chord_sequence(alt_str)
			if !seq_ok {
				return {}, false
			}
			chord.alts[chord.alt_count] = seq
			chord.alt_count += 1
			start = i + 1
		}
	}

	if chord.alt_count == 0 {
		return {}, false
	}
	return chord, true
}

@(private)
parse_chord_sequence :: proc "contextless" (alt_str: string) -> (seq: Chord_Sequence, ok: bool) {
	idx := 0
	for idx < len(alt_str) {
		for idx < len(alt_str) && (alt_str[idx] == ' ' || alt_str[idx] == '\t') {
			idx += 1
		}
		if idx >= len(alt_str) {
			break
		}
		tok_start := idx
		if alt_str[idx] == '<' {
			for idx < len(alt_str) && alt_str[idx] != '>' {
				idx += 1
			}
			if idx >= len(alt_str) {
				return {}, false
			}
			idx += 1 // include '>'
			// Reject trailing characters glued onto '>' without space (e.g. "<C-w>l")
			if idx < len(alt_str) && alt_str[idx] != ' ' && alt_str[idx] != '\t' {
				return {}, false
			}
		} else {
			for idx < len(alt_str) && alt_str[idx] != ' ' && alt_str[idx] != '\t' {
				idx += 1
			}
		}

		if seq.len >= 2 {
			return {}, false
		}
		ev, ev_ok := parse_single_key_token(alt_str[tok_start:idx])
		if !ev_ok {
			return {}, false
		}
		seq.steps[seq.len] = ev
		seq.len += 1
	}

	if seq.len == 0 {
		return {}, false
	}
	return seq, true
}

@(private)
parse_single_key_token :: proc "contextless" (tok: string) -> (ev: Key_Event, ok: bool) {
	if len(tok) == 0 {
		return {}, false
	}

	if tok[0] == '<' {
		if len(tok) < 3 || tok[len(tok) - 1] != '>' {
			return {}, false
		}
		inner := tok[1 : len(tok) - 1]
		for i := 0; i < len(inner); i += 1 {
			if inner[i] == '<' || inner[i] == '>' || inner[i] == ' ' || inner[i] == '\t' {
				return {}, false
			}
		}

		mods: Mod_Flags
		for len(inner) >= 2 && inner[1] == '-' {
			m := inner[0]
			switch m {
			case 'C', 'c':
				mods += {.Ctrl}
			case 'M', 'm', 'A', 'a':
				mods += {.Alt}
			case 'S', 's':
				mods += {.Shift}
			case 'D', 'd':
				mods += {.Super}
			case:
				return {}, false
			}
			inner = inner[2:]
		}

		if len(inner) == 0 {
			return {}, false
		}

		if sp_code, sp_ch, sp_ok := match_named_key(inner); sp_ok {
			if sp_code == .Rune {
				return Key_Event{code = .Rune, ch = sp_ch, mods = mods}, true
			}
			return Key_Event{code = sp_code, mods = mods}, true
		}

		r, w := utf8.decode_rune_in_string(inner)
		if r == utf8.RUNE_ERROR || w != len(inner) {
			return {}, false
		}
		if r >= 'A' && r <= 'Z' {
			mods += {.Shift}
			if (.Ctrl in mods) || (.Alt in mods) || (.Super in mods) {
				r += 32
			}
		} else if r >= 'a' && r <= 'z' && mods == {.Shift} {
			r -= 32
		}
		return Key_Event{code = .Rune, ch = r, mods = mods}, true
	}

	for i := 0; i < len(tok); i += 1 {
		if tok[i] == '<' || tok[i] == '>' {
			return {}, false
		}
	}

	r, w := utf8.decode_rune_in_string(tok)
	if r == utf8.RUNE_ERROR || w != len(tok) {
		return {}, false
	}
	mods: Mod_Flags
	if r >= 'A' && r <= 'Z' {
		mods = {.Shift}
	}
	return Key_Event{code = .Rune, ch = r, mods = mods}, true
}

@(private)
match_named_key :: proc "contextless" (name: string) -> (code: Key_Code, ch: rune, ok: bool) {
	if ascii_eq_fold(name, "enter") || ascii_eq_fold(name, "cr") || ascii_eq_fold(name, "return") {
		return .Enter, 0, true
	}
	if ascii_eq_fold(name, "esc") || ascii_eq_fold(name, "escape") {
		return .Escape, 0, true
	}
	if ascii_eq_fold(name, "space") {
		return .Space, 0, true
	}
	if ascii_eq_fold(name, "tab") {
		return .Tab, 0, true
	}
	if ascii_eq_fold(name, "bs") || ascii_eq_fold(name, "backspace") {
		return .Backspace, 0, true
	}
	if ascii_eq_fold(name, "del") || ascii_eq_fold(name, "delete") {
		return .Delete, 0, true
	}
	if ascii_eq_fold(name, "ins") || ascii_eq_fold(name, "insert") {
		return .Insert, 0, true
	}
	if ascii_eq_fold(name, "up") {
		return .Up, 0, true
	}
	if ascii_eq_fold(name, "down") {
		return .Down, 0, true
	}
	if ascii_eq_fold(name, "left") {
		return .Left, 0, true
	}
	if ascii_eq_fold(name, "right") {
		return .Right, 0, true
	}
	if ascii_eq_fold(name, "home") {
		return .Home, 0, true
	}
	if ascii_eq_fold(name, "end") {
		return .End, 0, true
	}
	if ascii_eq_fold(name, "pgup") || ascii_eq_fold(name, "pageup") || ascii_eq_fold(name, "page_up") {
		return .Page_Up, 0, true
	}
	if ascii_eq_fold(name, "pgdn") || ascii_eq_fold(name, "pagedown") || ascii_eq_fold(name, "page_down") {
		return .Page_Down, 0, true
	}
	if ascii_eq_fold(name, "bar") || ascii_eq_fold(name, "pipe") {
		return .Rune, '|', true
	}
	if ascii_eq_fold(name, "comma") {
		return .Rune, ',', true
	}
	if ascii_eq_fold(name, "lt") {
		return .Rune, '<', true
	}
	if ascii_eq_fold(name, "gt") {
		return .Rune, '>', true
	}
	if len(name) >= 2 && (name[0] == 'F' || name[0] == 'f') {
		num_str := name[1:]
		if num_str == "1"  { return .F1,  0, true }
		if num_str == "2"  { return .F2,  0, true }
		if num_str == "3"  { return .F3,  0, true }
		if num_str == "4"  { return .F4,  0, true }
		if num_str == "5"  { return .F5,  0, true }
		if num_str == "6"  { return .F6,  0, true }
		if num_str == "7"  { return .F7,  0, true }
		if num_str == "8"  { return .F8,  0, true }
		if num_str == "9"  { return .F9,  0, true }
		if num_str == "10" { return .F10, 0, true }
		if num_str == "11" { return .F11, 0, true }
		if num_str == "12" { return .F12, 0, true }
	}
	return .None, 0, false
}

str_has_prefix :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

@(private)
trim_ascii_space :: proc "contextless" (s: string) -> string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t' || s[start] == '\r' || s[start] == '\n') {
		start += 1
	}
	end := len(s)
	for end > start && (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r' || s[end - 1] == '\n') {
		end -= 1
	}
	return s[start:end]
}

@(private)
ascii_eq_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		ca := a[i] + 32 if (a[i] >= 'A' && a[i] <= 'Z') else a[i]
		cb := b[i] + 32 if (b[i] >= 'A' && b[i] <= 'Z') else b[i]
		if ca != cb {
			return false
		}
	}
	return true
}

// =============================================================================
// Chord Binding, Pending 2-Step State & Transient Scope Sub-Modes
// =============================================================================

bind_chord :: proc {
	bind_chord_input,
	bind_chord_table,
}

bind_chord_input :: proc(
	inp: ^Input_State,
	chord_spec: string,
	action_name: string,
	policy: Key_Scope_Policy = .Root_And_Scopes,
	scope: string = "",
	flags: Keybinding_Flags = {},
	has_submode_filter: bool = false,
	required_submode: u8 = 0,
	spec_idx: i16 = 0,
) -> bool {
	chord, ok := parse_key_chord(chord_spec)
	if !ok {
		return false
	}
	append_parsed_chord(&inp.keybindings, &inp.keybinding_count, chord, action_name, policy, scope, flags, has_submode_filter, required_submode, spec_idx)
	return true
}

bind_chord_table :: proc(
	km: ^Keymap_Table,
	chord_spec: string,
	action_name: string,
	policy: Key_Scope_Policy = .Root_And_Scopes,
	scope: string = "",
	flags: Keybinding_Flags = {},
	has_submode_filter: bool = false,
	required_submode: u8 = 0,
	spec_idx: i16 = 0,
) -> bool {
	chord, ok := parse_key_chord(chord_spec)
	if !ok {
		return false
	}
	append_parsed_chord(&km.bindings, &km.binding_cnt, chord, action_name, policy, scope, flags, has_submode_filter, required_submode, spec_idx)
	return true
}

apply_keymap_table :: proc "contextless" (inp: ^Input_State, km: ^Keymap_Table) {
	if inp == nil || km == nil {
		return
	}
	inp.keybinding_count = km.binding_cnt
	for i := 0; i < km.binding_cnt; i += 1 {
		inp.keybindings[i] = km.bindings[i]
	}
	inp.action_spec_cnt = km.spec_cnt
	for i := 0; i < km.spec_cnt; i += 1 {
		inp.action_specs[i] = km.specs[i]
	}
	inp.pending_chord = {}
}

@(private)
append_parsed_chord :: proc(
	dst: ^[MAX_KEYBINDINGS]Keybinding,
	dst_cnt: ^int,
	chord: Key_Chord,
	action_name: string,
	policy: Key_Scope_Policy,
	scope: string,
	flags: Keybinding_Flags,
	has_submode_filter: bool,
	required_submode: u8,
	spec_idx: i16,
) {
	scope_h: u64 = 0
	scope_prefix := ""
	eff_policy := policy

	if len(scope) > 0 {
		if scope[len(scope) - 1] == '*' {
			scope_prefix = scope[:len(scope) - 1]
		} else {
			scope_h = hash_id(scope)
		}
		if eff_policy == .Root_And_Scopes {
			eff_policy = .Scope_Only
		}
	}

	act_id := hash_id(action_name)
	for a: u8 = 0; a < chord.alt_count; a += 1 {
		if dst_cnt^ >= MAX_KEYBINDINGS {
			return
		}
		seq := chord.alts[a]
		dst[dst_cnt^] = Keybinding{
			key                = seq.steps[0],
			key2               = seq.steps[1] if seq.len == 2 else Key_Event{},
			chord_len          = seq.len,
			scope_id           = scope_h,
			scope_prefix       = scope_prefix,
			policy             = eff_policy,
			flags              = flags,
			has_submode_filter = has_submode_filter,
			required_submode   = required_submode,
			spec_idx           = spec_idx,
			action_id          = act_id,
			action_name        = action_name,
		}
		dst_cnt^ += 1
	}
}

is_pure_modifier_key :: proc "contextless" (code: Key_Code) -> bool {
	#partial switch code {
	case .Left_Shift, .Right_Shift,
	     .Left_Control, .Right_Control,
	     .Left_Alt, .Right_Alt,
	     .Left_Super, .Right_Super,
	     .Left_Hyper, .Right_Hyper,
	     .Left_Meta, .Right_Meta,
	     .Caps_Lock, .Num_Lock,
	     .ISO_Level_3_Shift, .ISO_Level_5_Shift:
		return true
	}
	return false
}

pending_chord_prefix :: proc "contextless" (inp: ^Input_State) -> string {
	if inp == nil || !inp.pending_chord.active {
		return ""
	}
	return string(inp.pending_chord.prefix_buf[:inp.pending_chord.prefix_len])
}

clear_pending_chord :: proc "contextless" (inp: ^Input_State) {
	if inp != nil {
		inp.pending_chord = {}
	}
}

latch_pending_chord :: proc "contextless" (
	inp: ^Input_State,
	first_key: Key_Event,
	has_fallback: bool = false,
	fallback_binding_idx: i16 = 0,
) {
	inp.pending_chord = Pending_Chord_State{
		active               = true,
		first_key            = first_key,
		started_tick_ns      = inp.clock_ns,
		has_fallback         = has_fallback,
		fallback_binding_idx = fallback_binding_idx,
	}
	n := write_key_event_buf(inp.pending_chord.prefix_buf[:], first_key)
	inp.pending_chord.prefix_len = u8(n)
}

has_active_two_step_prefix :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
	text_input_focused: bool,
) -> bool {
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.chord_len == 2 && key_events_match(kb.key, ev) &&
		   !is_suppressed_in_text_input(kb, ev, text_input_focused) &&
		   is_binding_currently_active(ctx, inp, capture_idx, kb) {
			if kb.spec_idx > 0 && int(kb.spec_idx - 1) < inp.action_spec_cnt {
				if resolve_spec_availability(inp, inp.action_specs[kb.spec_idx - 1]) == .Hidden {
					continue
				}
			}
			return true
		}
	}
	return false
}

@(private)
is_valid_single_step_fallback :: proc(
	inp: ^Input_State,
	kb: Keybinding,
	ev: Key_Event,
	text_input_focused: bool,
) -> bool {
	if kb.chord_len > 1 || !key_events_match(kb.key, ev) || is_suppressed_in_text_input(kb, ev, text_input_focused) {
		return false
	}
	if kb.spec_idx > 0 && int(kb.spec_idx - 1) < inp.action_spec_cnt {
		if resolve_spec_availability(inp, inp.action_specs[kb.spec_idx - 1]) == .Hidden {
			return false
		}
	}
	return true
}

find_single_step_fallback_idx :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
	text_input_focused: bool,
) -> (idx: i16, found: bool) {
	// Tier 1: Scope_Only along focus_node_path (innermost first, halting at Trap_Focus)
	if inp.focus_node_path_len > 0 {
		for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
			n_idx := inp.focus_node_path[p]
			if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
				continue
			}
			if is_node_allowed(ctx, n_idx, capture_idx) {
				for i := 0; i < inp.keybinding_count; i += 1 {
					kb := inp.keybindings[i]
					if binding_matches_scope_node(inp, ctx, n_idx, kb) &&
					   is_valid_single_step_fallback(inp, kb, ev, text_input_focused) {
						return i16(i), true
					}
				}
			}
			if .Trap_Focus in ctx.nodes[n_idx].focus_flags {
				break
			}
		}
	}

	// Tier 2: Root_And_Scopes
	if capture_idx < 0 {
		for i := 0; i < inp.keybinding_count; i += 1 {
			kb := inp.keybindings[i]
			if kb.policy == .Root_And_Scopes && is_valid_single_step_fallback(inp, kb, ev, text_input_focused) {
				if kb.has_submode_filter && get_scope_submode_by_hash(inp, 0) != kb.required_submode {
					continue
				}
				return i16(i), true
			}
		}
	}

	// Tier 3: Global_Always
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.policy == .Global_Always && is_valid_single_step_fallback(inp, kb, ev, text_input_focused) {
			return i16(i), true
		}
	}
	return 0, false
}

expire_pending_chord :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	now_ns: i64,
) -> bool {
	if inp == nil || !inp.pending_chord.active {
		return false
	}
	timeout := inp.chord_timeout_ns if inp.chord_timeout_ns > 0 else DEFAULT_CHORD_TIMEOUT_NS
	if now_ns <= 0 || inp.pending_chord.started_tick_ns <= 0 || (now_ns - inp.pending_chord.started_tick_ns) < timeout {
		return false
	}
	has_fb := inp.pending_chord.has_fallback
	fb_idx := inp.pending_chord.fallback_binding_idx
	inp.pending_chord = {}
	if has_fb && fb_idx >= 0 && int(fb_idx) < inp.keybinding_count {
		return activate_matched_binding(inp, ctx, inp.keybindings[fb_idx])
	}
	return true
}

@(private)
matches_chord_step2 :: proc "contextless" (
	kb: Keybinding,
	first_key: Key_Event,
	ev: Key_Event,
	text_input_focused: bool,
) -> bool {
	return kb.chord_len == 2 &&
		key_events_match(kb.key, first_key) &&
		key_events_match(kb.key2, ev) &&
		!is_suppressed_in_text_input(kb, ev, text_input_focused)
}

resolve_pending_chord_step :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	ev: Key_Event,
) {
	first_key := inp.pending_chord.first_key
	inp.pending_chord = {}

	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	if ev.code == .Escape && eff_mods == {} {
		clear_repeat_count(inp)
		return
	}

	text_input_focused := inp.editing_id != 0

	// Tier 1: Scope_Only along focus_node_path (innermost first, halting at Trap_Focus)
	if inp.focus_node_path_len > 0 {
		for p := inp.focus_node_path_len - 1; p >= 0; p -= 1 {
			n_idx := inp.focus_node_path[p]
			if n_idx < 0 || int(n_idx) >= len(ctx.nodes) {
				continue
			}
			if is_node_allowed(ctx, n_idx, capture_idx) {
				for i := 0; i < inp.keybinding_count; i += 1 {
					kb := inp.keybindings[i]
					if binding_matches_scope_node(inp, ctx, n_idx, kb) && matches_chord_step2(kb, first_key, ev, text_input_focused) {
						if activate_matched_binding(inp, ctx, kb) {
							return
						}
					}
				}
			}
			if .Trap_Focus in ctx.nodes[n_idx].focus_flags {
				break
			}
		}
	}

	// Tier 2: Root_And_Scopes
	if capture_idx < 0 {
		for i := 0; i < inp.keybinding_count; i += 1 {
			kb := inp.keybindings[i]
			if kb.policy == .Root_And_Scopes && matches_chord_step2(kb, first_key, ev, text_input_focused) {
				if kb.has_submode_filter && get_scope_submode_by_hash(inp, 0) != kb.required_submode {
					continue
				}
				if activate_matched_binding(inp, ctx, kb) {
					return
				}
			}
		}
	}

	// Tier 3: Global_Always
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.policy == .Global_Always && matches_chord_step2(kb, first_key, ev, text_input_focused) {
			if activate_matched_binding(inp, ctx, kb) {
				return
			}
		}
	}

	clear_repeat_count(inp)
}

set_scope_submode :: proc(inp: ^Input_State, scope_id: string, submode: u8) {
	h := hash_id(scope_id) if len(scope_id) > 0 else 0
	set_scope_submode_by_hash(inp, h, submode)
}

set_scope_submode_by_hash :: proc "contextless" (inp: ^Input_State, scope_hash: u64, submode: u8) {
	if inp == nil {
		return
	}
	for i := 0; i < inp.scope_submode_len; i += 1 {
		if inp.scope_submodes[i].scope_hash == scope_hash {
			if submode == 0 {
				// Remove zero submode entry to keep table compact
				for j := i; j + 1 < inp.scope_submode_len; j += 1 {
					inp.scope_submodes[j] = inp.scope_submodes[j + 1]
				}
				inp.scope_submode_len -= 1
				inp.scope_submodes[inp.scope_submode_len] = {}
			} else {
				inp.scope_submodes[i].submode = submode
			}
			return
		}
	}
	if submode == 0 || inp.scope_submode_len >= MAX_SCOPE_SUBMODES {
		return
	}
	inp.scope_submodes[inp.scope_submode_len] = Scope_Submode_Entry{
		scope_hash = scope_hash,
		submode    = submode,
	}
	inp.scope_submode_len += 1
}

get_scope_submode :: proc(inp: ^Input_State, scope_id: string) -> u8 {
	h := hash_id(scope_id) if len(scope_id) > 0 else 0
	return get_scope_submode_by_hash(inp, h)
}

get_scope_submode_typed :: proc(inp: ^Input_State, scope_id: string, $E: typeid) -> E where intrinsics.type_is_enum(E) {
	return E(get_scope_submode(inp, scope_id))
}

get_scope_submode_by_hash :: proc "contextless" (inp: ^Input_State, scope_hash: u64) -> u8 {
	if inp == nil {
		return 0
	}
	for i := 0; i < inp.scope_submode_len; i += 1 {
		if inp.scope_submodes[i].scope_hash == scope_hash {
			return inp.scope_submodes[i].submode
		}
	}
	return 0
}

cleanup_splitter_submode_on_blur :: proc "contextless" (inp: ^Input_State, old_focused_id: u64) {
	if find_splitter_slot(inp, old_focused_id) != nil {
		set_scope_submode_by_hash(inp, old_focused_id, 0)
	}
}


// =============================================================================
// Single-Source Action Registry (`core:reflect` Struct Tags + Guards + Enum IDs)
// =============================================================================

register_action_spec :: proc {
	register_action_spec_input,
	register_action_spec_table,
}

@(private)
register_action_spec_into_storage :: proc(
	specs: ^[MAX_ACTION_SPECS]Action_Spec,
	spec_cnt: ^int,
	bindings: ^[MAX_KEYBINDINGS]Keybinding,
	binding_cnt: ^int,
	cp: ^Command_Palette,
	spec: Action_Spec,
) -> bool {
	if len(spec.action_name) == 0 {
		return false
	}
	norm := normalize_action_spec(spec)
	spec_idx: i16 = 0
	if spec_cnt^ < MAX_ACTION_SPECS {
		specs[spec_cnt^] = norm
		spec_cnt^ += 1
		spec_idx = i16(spec_cnt^)
	}
	if len(norm.chord_spec) > 0 {
		chord, ok := parse_key_chord(norm.chord_spec)
		if !ok {
			return false
		}
		append_parsed_chord(
			bindings,
			binding_cnt,
			chord,
			norm.action_name,
			norm.policy,
			norm.scope,
			norm.flags,
			norm.has_submode,
			norm.submode,
			spec_idx,
		)
	}
	if cp != nil && norm.show_in_palette {
		pal_label := norm.label if len(norm.label) > 0 else norm.desc
		if len(pal_label) == 0 {
			pal_label = norm.action_name
		}
		register_command(cp, norm.action_name, pal_label, norm.category)
	}
	return true
}

register_action_spec_input :: proc(
	inp: ^Input_State,
	cp: ^Command_Palette,
	spec: Action_Spec,
) -> bool {
	if inp == nil {
		return false
	}
	return register_action_spec_into_storage(&inp.action_specs, &inp.action_spec_cnt, &inp.keybindings, &inp.keybinding_count, cp, spec)
}

register_action_spec_table :: proc(
	km: ^Keymap_Table,
	cp: ^Command_Palette,
	spec: Action_Spec,
) -> bool {
	if km == nil {
		return false
	}
	return register_action_spec_into_storage(&km.specs, &km.spec_cnt, &km.bindings, &km.binding_cnt, cp, spec)
}

@(private)
normalize_action_spec :: proc(spec: Action_Spec) -> Action_Spec {
	out := spec
	out.action_id = hash_id(out.action_name)
	if len(out.chord_vim) == 0 && len(out.chord_spec) > 0 {
		out.chord_vim = out.chord_spec
	}
	if len(out.chord_spec) == 0 && len(out.chord_vim) > 0 {
		out.chord_spec = out.chord_vim
	}
	if len(out.desc_vim) == 0 && len(out.desc) > 0 {
		out.desc_vim = out.desc
	}
	if len(out.desc) == 0 && len(out.desc_vim) > 0 {
		out.desc = out.desc_vim
	}
	if len(out.scope) > 0 && out.policy == .Root_And_Scopes {
		out.policy = .Scope_Only
	}
	if !out.hide_in_bar && (out.show_in_bar || len(out.desc) > 0 || len(out.group_desc) > 0) {
		out.show_in_bar = true
	}
	if !out.hide_in_palette && (out.show_in_palette || len(out.label) > 0 || len(out.desc) > 0) {
		out.show_in_palette = true
	}
	return out
}

register_actions_struct :: proc {
	register_actions_struct_input,
	register_actions_struct_table,
}

@(private)
register_actions_struct_generic :: proc(
	target: ^$Target,
	cp: ^Command_Palette,
	actions: $T,
) -> bool where intrinsics.type_is_struct(T) {
	local_copy := actions
	field_cnt := reflect.struct_field_count(T)
	all_ok := true
	for i := 0; i < field_cnt; i += 1 {
		field := reflect.struct_field_at(T, i)
		tag_val, has_tag := reflect.struct_tag_lookup(field.tag, "bifrost")
		if !has_tag || len(tag_val) == 0 {
			continue
		}
		spec, ok := build_spec_from_field(&local_copy, field, tag_val)
		if !ok || !register_action_spec(target, cp, spec) {
			all_ok = false
		}
	}
	return all_ok
}

register_actions_struct_input :: proc(
	inp: ^Input_State,
	cp: ^Command_Palette,
	actions: $T,
) -> bool where intrinsics.type_is_struct(T) {
	return register_actions_struct_generic(inp, cp, actions)
}

register_actions_struct_table :: proc(
	km: ^Keymap_Table,
	cp: ^Command_Palette,
	actions: $T,
) -> bool where intrinsics.type_is_struct(T) {
	return register_actions_struct_generic(km, cp, actions)
}

@(private)
build_spec_from_field :: proc(
	struct_ptr: rawptr,
	field: reflect.Struct_Field,
	tag_str: string,
) -> (spec: Action_Spec, ok: bool) {
	spec = parse_bifrost_tag_string(tag_str, field.name)

	base_ti := reflect.type_info_base(field.type)
	#partial switch v in base_ti.variant {
	case reflect.Type_Info_Enum:
		field_ptr := rawptr(uintptr(struct_ptr) + field.offset)
		field_any := any{data = field_ptr, id = field.type.id}
		val, val_ok := reflect.as_i64(field_any)
		if val_ok && val != 0 {
			spec.enum_val     = val
			spec.has_enum_val = true
		} else {
			for idx := 0; idx < len(v.names); idx += 1 {
				if v.names[idx] == field.name || ascii_eq_fold(v.names[idx], field.name) {
					spec.enum_val     = i64(v.values[idx])
					spec.has_enum_val = true
					break
				}
			}
		}
	}
	return spec, len(spec.action_name) > 0
}

@(private)
next_tag_pair_end :: proc "contextless" (s: string, start: int) -> int {
	in_single_quote := false
	i := start
	for i < len(s) {
		ch := s[i]
		if ch == '\\' && i + 1 < len(s) {
			i += 2
			continue
		}
		if ch == '\'' {
			in_single_quote = !in_single_quote
		} else if ch == ',' && !in_single_quote {
			return i
		}
		i += 1
	}
	return len(s)
}

@(private)
unquote_single_quoted :: proc "contextless" (v: string) -> string {
	trimmed := trim_ascii_space(v)
	if len(trimmed) >= 2 && trimmed[0] == '\'' && trimmed[len(trimmed) - 1] == '\'' {
		return trimmed[1 : len(trimmed) - 1]
	}
	return trimmed
}

parse_bifrost_tag_string :: proc "contextless" (tag_str: string, fallback_name: string = "") -> Action_Spec {
	spec := Action_Spec{
		action_name     = fallback_name,
		show_in_bar     = true,
		show_in_palette = true,
	}

	for start := 0; start < len(tag_str); {
		end := next_tag_pair_end(tag_str, start)
		pair := trim_ascii_space(tag_str[start:end])
		start = end + 1
		if len(pair) == 0 {
			continue
		}
		eq := -1
		for j := 0; j < len(pair); j += 1 {
			if pair[j] == '=' {
				eq = j
				break
			}
		}
		if eq < 0 {
			if ascii_eq_fold(pair, "compact") {
				spec.compact     = true
				spec.has_compact = true
			}
			continue
		}
		k := trim_ascii_space(pair[:eq])
		v := unquote_single_quoted(pair[eq + 1:])
		if ascii_eq_fold(k, "key") || ascii_eq_fold(k, "chord") {
			spec.chord_spec = v
		} else if ascii_eq_fold(k, "vim") {
			spec.chord_vim = v
			if len(spec.chord_spec) == 0 {
				spec.chord_spec = v
			}
		} else if ascii_eq_fold(k, "helix") {
			spec.chord_helix = v
		} else if ascii_eq_fold(k, "emacs") {
			spec.chord_emacs = v
		} else if ascii_eq_fold(k, "id") || ascii_eq_fold(k, "action") {
			spec.action_name = v
		} else if ascii_eq_fold(k, "scope") {
			spec.scope = v
		} else if ascii_eq_fold(k, "group") {
			spec.group = v
		} else if ascii_eq_fold(k, "group_desc") {
			spec.group_desc = v
		} else if ascii_eq_fold(k, "compact") {
			spec.compact     = ascii_eq_fold(v, "true") || v == "1"
			spec.has_compact = true
		} else if ascii_eq_fold(k, "desc") {
			spec.desc = v
		} else if ascii_eq_fold(k, "desc_vim") {
			spec.desc_vim = v
		} else if ascii_eq_fold(k, "desc_helix") {
			spec.desc_helix = v
		} else if ascii_eq_fold(k, "desc_emacs") {
			spec.desc_emacs = v
		} else if ascii_eq_fold(k, "label") {
			spec.label = v
		} else if ascii_eq_fold(k, "category") {
			spec.category = v
		} else if ascii_eq_fold(k, "policy") {
			if ascii_eq_fold(v, "global") || ascii_eq_fold(v, "global_always") {
				spec.policy = .Global_Always
			} else if ascii_eq_fold(v, "scope") || ascii_eq_fold(v, "scope_only") {
				spec.policy = .Scope_Only
			} else {
				spec.policy = .Root_And_Scopes
			}
		} else if ascii_eq_fold(k, "allow_in_edit") || ascii_eq_fold(k, "allow_in_text_input") {
			if ascii_eq_fold(v, "true") || v == "1" {
				spec.flags += {.Allow_In_Text_Input}
			}
		} else if ascii_eq_fold(k, "submode") {
			if parsed_u8, ok_u8 := parse_small_u8(v); ok_u8 {
				spec.has_submode = true
				spec.submode     = parsed_u8
			}
		} else if ascii_eq_fold(k, "hint") || ascii_eq_fold(k, "bar") {
			if ascii_eq_fold(v, "false") || v == "0" {
				spec.show_in_bar = false
				spec.hide_in_bar = true
			}
		} else if ascii_eq_fold(k, "palette") {
			if ascii_eq_fold(v, "false") || v == "0" {
				spec.show_in_palette = false
				spec.hide_in_palette = true
			}
		}
	}
	return spec
}

@(private)
parse_small_u8 :: proc "contextless" (s: string) -> (u8, bool) {
	if len(s) == 0 {
		return 0, false
	}
	acc: u32 = 0
	for i := 0; i < len(s); i += 1 {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		acc = acc * 10 + u32(s[i] - '0')
		if acc > 255 {
			return 0, false
		}
	}
	return u8(acc), true
}

set_action_guard :: proc(
	inp: ^Input_State,
	action_name: string,
	guard: Action_Guard_Proc,
	userdata: rawptr = nil,
) {
	act_id := hash_id(action_name)
	for i := 0; i < inp.action_spec_cnt; i += 1 {
		if inp.action_specs[i].action_id == act_id {
			inp.action_specs[i].guard_proc     = guard
			inp.action_specs[i].guard_userdata = userdata
		}
	}
}

set_action_availability :: proc(
	inp: ^Input_State,
	action_name: string,
	availability: Action_Availability,
	avail_proc: Action_Avail_Proc = nil,
	userdata: rawptr = nil,
) {
	act_id := hash_id(action_name)
	for i := 0; i < inp.action_spec_cnt; i += 1 {
		if inp.action_specs[i].action_id == act_id {
			inp.action_specs[i].availability   = availability
			inp.action_specs[i].avail_proc     = avail_proc
			inp.action_specs[i].avail_userdata = userdata
		}
	}
}

resolve_spec_availability :: proc(inp: ^Input_State, spec: Action_Spec) -> Action_Availability {
	if spec.avail_proc != nil {
		ud := spec.avail_userdata if spec.avail_userdata != nil else inp.action_userdata
		return spec.avail_proc(spec.action_id, ud)
	}
	return spec.availability
}

activate_matched_binding :: proc(inp: ^Input_State, ctx: ^Layout_Context, kb: Keybinding) -> bool {
	has_enum := false
	enum_val: i64 = 0

	if kb.spec_idx > 0 && int(kb.spec_idx - 1) < inp.action_spec_cnt {
		spec := inp.action_specs[kb.spec_idx - 1]
		avail := resolve_spec_availability(inp, spec)
		if avail == .Hidden {
			return false
		}
		if spec.guard_proc != nil {
			ud := spec.guard_userdata if spec.guard_userdata != nil else inp.action_userdata
			res, reason := spec.guard_proc(kb.action_id, ud)
			switch res {
			case .Enabled:
			case .Disabled_Swallow:
				inp.last_disabled_reason = reason
				return true
			case .Disabled_Bubble:
				return false
			}
		} else if avail == .Disabled_Dimmed {
			return true
		}
		has_enum = spec.has_enum_val
		enum_val = spec.enum_val
	}

	inp.triggered_action_id   = kb.action_id
	inp.triggered_action_name = kb.action_name
	inp.has_triggered_enum    = has_enum
	inp.triggered_enum_val    = enum_val

	if kb.nudge_splitter_id != 0 && kb.nudge_delta != 0 {
		if s_idx, exists := ctx.id_map[kb.nudge_splitter_id]; exists {
			slot := get_splitter_slot(inp, kb.nudge_splitter_id)
			max_first := compute_splitter_max_first(slot)
			target := clamp(slot.size + kb.nudge_delta, slot.min_first, max_first)
			apply_splitter_size_immediate(ctx, s_idx, slot, target)
		}
	}
	return true
}

trigger_action_by_id :: proc(
	inp: ^Input_State,
	action_id: u64,
	fallback_name: string = "",
) -> (dispatched: bool, blocked: bool) {
	if inp == nil || action_id == 0 {
		return false, false
	}
	act_name := fallback_name
	enum_val: i64 = 0
	has_enum := false

	for i := 0; i < inp.action_spec_cnt; i += 1 {
		spec := inp.action_specs[i]
		if spec.action_id == action_id {
			if len(act_name) == 0 {
				act_name = spec.action_name
			}
			avail := resolve_spec_availability(inp, spec)
			if avail == .Hidden {
				return false, true
			}
			if spec.guard_proc != nil {
				ud := spec.guard_userdata if spec.guard_userdata != nil else inp.action_userdata
				res, reason := spec.guard_proc(spec.action_id, ud)
				if res != .Enabled {
					inp.last_disabled_reason = reason
					return false, true
				}
			} else if avail == .Disabled_Dimmed {
				return false, true
			}
			has_enum = spec.has_enum_val
			enum_val = spec.enum_val
			break
		}
	}

	inp.triggered_action_id   = action_id
	inp.triggered_action_name = act_name
	inp.has_triggered_enum    = has_enum
	inp.triggered_enum_val    = enum_val
	return true, false
}

find_keybinding_conflict :: proc(
	inp: ^Input_State,
	chord_spec: string,
	policy: Key_Scope_Policy = .Root_And_Scopes,
	scope: string = "",
	has_submode: bool = false,
	submode: u8 = 0,
) -> (conflicting_action: string, has_conflict: bool) {
	if inp == nil {
		return "", false
	}
	chord, ok := parse_key_chord(chord_spec)
	if !ok {
		return "", false
	}
	scope_h := hash_id(scope) if (len(scope) > 0 && scope[len(scope) - 1] != '*') else u64(0)
	scope_prefix := scope[:len(scope) - 1] if (len(scope) > 0 && scope[len(scope) - 1] == '*') else ""
	eff_policy := policy
	if len(scope) > 0 && eff_policy == .Root_And_Scopes {
		eff_policy = .Scope_Only
	}

	for a: u8 = 0; a < chord.alt_count; a += 1 {
		seq := chord.alts[a]
		for i := 0; i < inp.keybinding_count; i += 1 {
			kb := inp.keybindings[i]
			if kb.policy != eff_policy || kb.scope_id != scope_h || kb.scope_prefix != scope_prefix {
				continue
			}
			if kb.has_submode_filter != has_submode || (has_submode && kb.required_submode != submode) {
				continue
			}
			kb_len := max(u8(1), kb.chord_len)
			if kb_len == seq.len && key_events_match(kb.key, seq.steps[0]) &&
			   (seq.len == 1 || key_events_match(kb.key2, seq.steps[1])) {
				return kb.action_name, true
			}
		}
	}
	return "", false
}

rebind_action_chord :: proc(
	inp: ^Input_State,
	action_name: string,
	new_chord_spec: string,
) -> bool {
	return rebind_action_chord_internal(inp, action_name, new_chord_spec, true)
}

rebind_action_chord_internal :: proc(
	inp: ^Input_State,
	action_name: string,
	new_chord_spec: string,
	mark_user_rebound: bool,
) -> bool {
	if inp == nil || len(action_name) == 0 {
		return false
	}
	new_chord, ok := parse_key_chord(new_chord_spec)
	if !ok {
		return false
	}
	act_id := hash_id(action_name)

	// 1. Update matching Action_Spec if registered
	matched_spec: Action_Spec
	found_spec := false
	matched_spec_idx: i16 = 0
	for i := 0; i < inp.action_spec_cnt; i += 1 {
		if inp.action_specs[i].action_id == act_id {
			inp.action_specs[i].chord_spec   = new_chord_spec
			inp.action_specs[i].user_rebound = mark_user_rebound
			matched_spec     = inp.action_specs[i]
			matched_spec_idx = i16(i + 1)
			found_spec       = true
			break
		}
	}

	// 2. Remove old keybindings for action_id while preserving policy/scope/submode from first old binding if no spec
	fallback_policy     := Key_Scope_Policy.Root_And_Scopes
	fallback_scope_id   := u64(0)
	fallback_scope_pref := ""
	fallback_flags      := Keybinding_Flags{}
	fallback_has_sub    := false
	fallback_submode    := u8(0)
	captured_fallback   := false
	write_idx := 0
	for read_idx := 0; read_idx < inp.keybinding_count; read_idx += 1 {
		kb := inp.keybindings[read_idx]
		if kb.action_id == act_id {
			if !captured_fallback {
				fallback_policy     = kb.policy
				fallback_scope_id   = kb.scope_id
				fallback_scope_pref = kb.scope_prefix
				fallback_flags      = kb.flags
				fallback_has_sub    = kb.has_submode_filter
				fallback_submode    = kb.required_submode
				captured_fallback   = true
			}
			continue
		}
		inp.keybindings[write_idx] = kb
		write_idx += 1
	}
	inp.keybinding_count = write_idx

	// 3. Append newly parsed chord bindings
	if found_spec {
		append_parsed_chord(
			&inp.keybindings,
			&inp.keybinding_count,
			new_chord,
			matched_spec.action_name,
			matched_spec.policy,
			matched_spec.scope,
			matched_spec.flags,
			matched_spec.has_submode,
			matched_spec.submode,
			matched_spec_idx,
		)
	} else {
		prev_cnt := inp.keybinding_count
		append_parsed_chord(
			&inp.keybindings,
			&inp.keybinding_count,
			new_chord,
			action_name,
			fallback_policy,
			"",
			fallback_flags,
			fallback_has_sub,
			fallback_submode,
			0,
		)
		for i := prev_cnt; i < inp.keybinding_count; i += 1 {
			inp.keybindings[i].scope_id     = fallback_scope_id
			inp.keybindings[i].scope_prefix = fallback_scope_pref
		}
	}
	return true
}

was_action_triggered_enum :: proc(inp: ^Input_State, val: $E) -> bool where intrinsics.type_is_enum(E) {
	return inp != nil && inp.has_triggered_enum && inp.triggered_enum_val == i64(val)
}

triggered_action :: proc(inp: ^Input_State, $E: typeid) -> (E, bool) where intrinsics.type_is_enum(E) {
	if inp == nil || !inp.has_triggered_enum {
		return E(0), false
	}
	return E(inp.triggered_enum_val), true
}


@(private)
write_key_event_buf :: proc "contextless" (buf: []u8, ev: Key_Event) -> int {
	off := 0
	eff_mods := ev.mods - {.Caps_Lock, .Num_Lock}
	has_chord_mod := (.Ctrl in eff_mods) || (.Alt in eff_mods) || (.Super in eff_mods)

	if .Ctrl in eff_mods {
		off += copy(buf[off:], "Ctrl+")
	}
	if .Alt in eff_mods {
		off += copy(buf[off:], "Alt+")
	}
	if .Super in eff_mods {
		off += copy(buf[off:], "Super+")
	}

	#partial switch ev.code {
	case .Rune:
		ch := ev.ch
		if has_chord_mod {
			if .Shift in eff_mods {
				off += copy(buf[off:], "Shift+")
			}
			if ch >= 'a' && ch <= 'z' {
				ch -= 32
			}
		} else if (.Shift in eff_mods) && ch >= 'a' && ch <= 'z' {
			ch -= 32
		}
		rb, rw := utf8.encode_rune(ch)
		if off + rw <= len(buf) {
			off += copy(buf[off:], rb[:rw])
		}
		return off
	}

	if .Shift in eff_mods {
		off += copy(buf[off:], "Shift+")
	}

	key_name := "Key"
	#partial switch ev.code {
	case .None:
		return 0
	case .Space:
		key_name = "Space"
	case .Enter:
		key_name = "Enter"
	case .Escape:
		key_name = "Esc"
	case .Tab:
		key_name = "Tab"
	case .Backspace:
		key_name = "Backspace"
	case .Delete:
		key_name = "Del"
	case .Insert:
		key_name = "Ins"
	case .Up:
		key_name = "Up"
	case .Down:
		key_name = "Down"
	case .Left:
		key_name = "Left"
	case .Right:
		key_name = "Right"
	case .Page_Up:
		key_name = "PgUp"
	case .Page_Down:
		key_name = "PgDn"
	case .Home:
		key_name = "Home"
	case .End:
		key_name = "End"
	case .F1:
		key_name = "F1"
	case .F2:
		key_name = "F2"
	case .F3:
		key_name = "F3"
	case .F4:
		key_name = "F4"
	case .F5:
		key_name = "F5"
	case .F6:
		key_name = "F6"
	case .F7:
		key_name = "F7"
	case .F8:
		key_name = "F8"
	case .F9:
		key_name = "F9"
	case .F10:
		key_name = "F10"
	case .F11:
		key_name = "F11"
	case .F12:
		key_name = "F12"
	}
	off += copy(buf[off:], key_name)
	return off
}
