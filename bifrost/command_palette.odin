package bifrost

import "core:fmt"

// =============================================================================
// Ctrl+P Fuzzy Command Palette Modal (`z_layer = 30`) with Shortcut Discovery
// =============================================================================

MAX_PALETTE_COMMANDS :: 64

Command_Item :: struct {
	action:    string,
	action_id: u64,
	label:     string,
	category:  string,
	shortcut:  string, // Auto-discovered from Input_State.keybindings if left empty
}

Command_Match :: struct {
	item_idx: i32,
	score:    i32,
}

Command_Palette :: struct {
	id:            string,
	input_id:      string,
	list_id:       string,
	toggle_action: string,
	is_open:       bool,
	commands:      [MAX_PALETTE_COMMANDS]Command_Item,
	command_cnt:   int,
	matches:       [MAX_PALETTE_COMMANDS]Command_Match,
	match_count:   int,
	last_query:    [MAX_TEXT_BYTES]byte,
	last_q_len:    int,
	dirty:         bool,
}

command_palette_init :: proc(
	cp: ^Command_Palette,
	inp: ^Input_State = nil,
	id: string = "cmd_palette_modal",
	input_id: string = "cmd_palette_input",
	list_id: string = "cmd_palette_list",
	toggle_action: string = "palette.toggle",
) {
	cp^ = Command_Palette{
		id            = id,
		input_id      = input_id,
		list_id       = list_id,
		toggle_action = toggle_action,
		dirty         = true,
	}
	if inp != nil && len(toggle_action) > 0 {
		bind_key(
			inp,
			Key_Event{code = .Rune, ch = 'p', mods = {.Ctrl}},
			toggle_action,
			.Global_Always,
			"",
			{.Allow_In_Text_Input},
		)
	}
}

register_command :: proc(
	cp: ^Command_Palette,
	action_name: string,
	label: string,
	category: string = "",
	shortcut: string = "",
) {
	if cp.command_cnt >= MAX_PALETTE_COMMANDS {
		return
	}
	cp.commands[cp.command_cnt] = Command_Item{
		action    = action_name,
		action_id = hash_id(action_name),
		label     = label,
		category  = category,
		shortcut  = shortcut,
	}
	cp.command_cnt += 1
	cp.dirty = true
}

// Renders the Command Palette floating modal at `z_layer = 30` with `.Dim_Screen` backdrop,
// an auto-focused search `ui_text_input`, and a virtualized list of right-aligned shortcut badges.
ui_command_palette :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	cp: ^Command_Palette,
	width: i32 = 54,
	visible_rows: i32 = 8,
) {
	if !cp.is_open {
		return
	}

	query := get_text(inp, cp.input_id)
	update_palette_matches(cp, inp, query)

	modal_h := visible_rows + 5 // 2 modal border + 1 input row + 2 list border
	if ui_modal(ctx, s, cp.id, Modal_Spec{
		title     = "Command Palette",
		z_layer   = 30,
		width     = fixed(width),
		height    = fixed(modal_h),
		border    = .Double,
		fg        = rgb(235, 240, 250),
		bg        = rgb(24, 28, 38),
		border_fg = rgb(120, 190, 255),
		title_fg  = rgb(255, 220, 110),
		backdrop  = .Dim_Screen,
	}) {
		ui_text_input(ctx, s, inp, cp.input_id, Text_Input_Config{
			placeholder    = "Type a command or search...",
			linked_list_id = cp.list_id,
			width          = grow(1),
			height         = fixed(1),
			fg             = rgb(255, 255, 255),
			bg             = rgb(36, 42, 56),
			placeholder_fg = rgb(130, 140, 160),
			focus_flags    = {.Focusable, .Default_Focus, .Captures_Text, .Auto_Edit, .Scope_Text_Sink},
		})

		slice: Virtual_Slice
		if ui_virtual_list(ctx, s, inp, cp.list_id, i32(cp.match_count), Virtual_List_Config{
			border        = .Plain,
			fg            = rgb(215, 225, 240),
			bg            = rgb(24, 28, 38),
			border_fg     = rgb(75, 90, 115),
			scroll_step   = 1,
			fallback_rows = visible_rows,
		}, &slice) {
			inner_w := max(10, width - 4)
			for m_idx := slice.start_row; m_idx < slice.end_row; m_idx += 1 {
				match := cp.matches[m_idx]
				cmd := cp.commands[match.item_idx]
				shortcut := cmd.shortcut if len(cmd.shortcut) > 0 else lookup_action_shortcut_by_id(inp, cmd.action_id)

				left_text := fmt.tprintf("[%s] %s", cmd.category, cmd.label) if len(cmd.category) > 0 else cmd.label
				left_w := string_display_width(left_text)
				right_w := string_display_width(shortcut)
				pad_spaces := max(1, inner_w - left_w - right_w - 1)

				row_str := fmt.tprintf("%s%*s%s", left_text, int(pad_spaces), "", shortcut) if right_w > 0 else left_text
				row_id  := fmt.tprintf("%s_item_%d", cp.list_id, m_idx)

				is_sel := m_idx == slice.selected_row
				fg := rgb(255, 230, 110) if is_sel else rgb(210, 220, 235)
				st := Style_Flags{.Bold, .Reverse} if is_sel else Style_Flags{}
				leaf(ctx, row_id, inner_w, 1, Box_Config{
					width     = grow(1),
					height    = fixed(1),
					clickable = true,
					hoverable = true,
					text      = row_str,
				})
				set_paint(s, row_id, Paint_Spec{
					text  = row_str,
					fg    = fg,
					bg    = rgb(48, 58, 82) if is_sel else rgb(24, 28, 38),
					style = st,
				})
			}
		}
	}
}

// Processes Command Palette open/close shortcuts (`toggle_action`), Escape/backdrop dismissal,
// and Enter/click command execution after `resolve_input`.
update_command_palette :: proc(
	cp: ^Command_Palette,
	inp: ^Input_State,
	toggle_action: string = "",
) -> bool {
	act := toggle_action if len(toggle_action) > 0 else cp.toggle_action
	if len(act) > 0 && was_action_triggered(inp, act) {
		inp.triggered_action_id   = 0
		inp.triggered_action_name = ""
		if cp.is_open {
			cp.is_open = false
		} else {
			cp.is_open = true
			set_text(inp, cp.input_id, "")
			cp.dirty = true
			update_palette_matches(cp, inp, "")
			inp.wants_focus_id = hash_id(cp.input_id)
		}
		return true
	}

	if !cp.is_open {
		return false
	}

	if was_modal_dismissed(inp, cp.id) {
		cp.is_open = false
		return true
	}

	query := get_text(inp, cp.input_id)
	update_palette_matches(cp, inp, query)

	// Enter while focused inside the palette input or list dispatches the selected command
	input_h := hash_id(cp.input_id)
	list_h  := hash_id(cp.list_id)
	if inp.activated_id == input_h || inp.activated_id == list_h {
		sel := get_selected_row(inp, cp.list_id)
		return dispatch_palette_row(inp, cp, sel)
	}

	// Mouse click on a visible command row dispatches that row
	if inp.clicked_id != 0 {
		slot := get_scroll_slot(inp, list_h)
		end_r := min(i32(cp.match_count), slot.offset + max(1, slot.viewport_rows))
		for m_idx := slot.offset; m_idx < end_r; m_idx += 1 {
			row_id := fmt.tprintf("%s_item_%d", cp.list_id, m_idx)
			if inp.clicked_id == hash_id(row_id) {
				slot.selected_row = m_idx
				return dispatch_palette_row(inp, cp, m_idx)
			}
		}
	}

	return false
}

@(private)
dispatch_palette_row :: proc(inp: ^Input_State, cp: ^Command_Palette, row_idx: i32) -> bool {
	if row_idx < 0 || int(row_idx) >= cp.match_count {
		return false
	}
	cmd_idx := cp.matches[row_idx].item_idx
	cmd := cp.commands[cmd_idx]
	dispatched, blocked := trigger_action_by_id(inp, cmd.action_id, cmd.action)
	if dispatched || blocked {
		cp.is_open = false
		return true
	}
	return false
}

// Re-scores and sorts registered commands against `query` using subsequence fuzzy matching.
update_palette_matches :: proc(cp: ^Command_Palette, inp: ^Input_State, query: string) {
	q_len := min(len(query), MAX_TEXT_BYTES)
	query_changed := (q_len != cp.last_q_len) || (string(cp.last_query[:cp.last_q_len]) != query[:q_len])
	if !cp.dirty && !query_changed {
		return
	}

	for i := 0; i < q_len; i += 1 {
		cp.last_query[i] = query[i]
	}
	cp.last_q_len  = q_len
	cp.dirty       = false
	cp.match_count = 0

	q_str := query[:q_len]
	for i := 0; i < cp.command_cnt; i += 1 {
		cmd := cp.commands[i]
		score, ok := fuzzy_score(cmd.label, cmd.category, q_str)
		if ok {
			cp.matches[cp.match_count] = Command_Match{
				item_idx = i32(i),
				score    = score,
			}
			cp.match_count += 1
		}
	}

	// Insertion sort by descending score (stable for equal scores)
	for i := 1; i < cp.match_count; i += 1 {
		cur := cp.matches[i]
		j := i - 1
		for j >= 0 && cp.matches[j].score < cur.score {
			cp.matches[j + 1] = cp.matches[j]
			j -= 1
		}
		cp.matches[j + 1] = cur
	}

	if query_changed && inp != nil {
		slot := get_scroll_slot(inp, hash_id(cp.list_id))
		slot.offset       = 0
		slot.selected_row = 0
	}
}

// Multi-token fuzzy subsequence scorer with bonuses for word boundaries, camelCase transitions,
// and consecutive runs. Every space-separated token in `query` must match either `label` or `category`.
fuzzy_score :: proc "contextless" (label, category, query: string) -> (score: i32, matched: bool) {
	if len(query) == 0 {
		return 1, true
	}

	total_score: i32 = 0
	any_token := false
	idx := 0
	for idx < len(query) {
		for idx < len(query) && query[idx] == ' ' {
			idx += 1
		}
		if idx >= len(query) {
			break
		}
		tok_start := idx
		for idx < len(query) && query[idx] != ' ' {
			idx += 1
		}
		token := query[tok_start:idx]
		any_token = true

		s_label, ok_label := fuzzy_score_single(label, token)
		s_cat, ok_cat     := fuzzy_score_single(category, token)
		if !ok_label && !ok_cat {
			return 0, false
		}
		if ok_label && ok_cat {
			total_score += max(s_label + 20, s_cat)
		} else if ok_label {
			total_score += s_label + 20
		} else {
			total_score += s_cat
		}
	}

	if !any_token {
		return 1, true
	}
	return total_score, true
}

@(private)
fuzzy_score_single :: proc "contextless" (candidate, token: string) -> (score: i32, matched: bool) {
	if len(token) == 0 {
		return 1, true
	}
	if len(candidate) == 0 {
		return 0, false
	}

	q_idx := 0
	total_score: i32 = 0
	consecutive: i32 = 0

	for c_idx := 0; c_idx < len(candidate) && q_idx < len(token); c_idx += 1 {
		q_ch := token[q_idx]
		c_ch := candidate[c_idx]
		c_low := c_ch + 32 if (c_ch >= 'A' && c_ch <= 'Z') else c_ch
		q_low := q_ch + 32 if (q_ch >= 'A' && q_ch <= 'Z') else q_ch

		if c_low == q_low {
			pts: i32 = 10
			if c_idx == 0 {
				pts += 25 // Start-of-string bonus
			} else {
				prev := candidate[c_idx - 1]
				if prev == ' ' || prev == '_' || prev == '-' || prev == '/' || prev == ':' || prev == '.' {
					pts += 20 // Word-boundary bonus
				} else if (c_ch >= 'A' && c_ch <= 'Z') && (prev >= 'a' && prev <= 'z') {
					pts += 15 // camelCase bonus
				}
			}
			if consecutive > 0 {
				pts += 12 * consecutive // Consecutive character run bonus
			}
			total_score += pts
			consecutive += 1
			q_idx += 1
		} else {
			consecutive = 0
			total_score -= 1 // Small gap penalty
		}
	}

	if q_idx < len(token) {
		return 0, false
	}
	return total_score, true
}

// Looks up the human-readable shortcut badge (e.g. `"Ctrl+K"`, `"F6"`) for `action_name` from `inp.keybindings`.
lookup_action_shortcut :: proc(inp: ^Input_State, action_name: string) -> string {
	if inp == nil || len(action_name) == 0 {
		return ""
	}
	return lookup_action_shortcut_by_id(inp, hash_id(action_name))
}

lookup_action_shortcut_by_id :: proc(inp: ^Input_State, action_id: u64) -> string {
	if inp == nil || action_id == 0 {
		return ""
	}
	for i := 0; i < inp.keybinding_count; i += 1 {
		kb := inp.keybindings[i]
		if kb.action_id == action_id {
			if kb.chord_len == 2 {
				return fmt.tprintf("%s %s", format_key_event(kb.key), format_key_event(kb.key2))
			}
			return format_key_event(kb.key)
		}
	}
	return ""
}

format_key_event :: proc(ev: Key_Event) -> string {
	buf: [32]u8
	n := write_key_event_buf(buf[:], ev)
	if n <= 0 {
		return ""
	}
	return fmt.tprintf("%s", string(buf[:n]))
}
