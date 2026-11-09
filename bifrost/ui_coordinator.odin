package bifrost

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import actor "../deps/heimdall/deps/sleipnir/actor"
import heimdall "../deps/heimdall/heimdall"


// =============================================================================
// 2. Typed UI & Worker Actor Messages (Elm / Bubble Tea Architecture)
// =============================================================================

UI_Cmd :: #type proc(alloc: mem.Allocator) -> (msg: UI_Msg, has_msg: bool)

UI_Msg_Key :: struct {
	code:      Key_Code,
	ch:        rune,
	ctrl:      bool,
	alt:       bool,
	shift:     bool,
	super_mod: bool,
	is_repeat: bool,
}

UI_Msg_Mouse :: struct {
	x:      i32,
	y:      i32,
	button: u8,
	action: Mouse_Action,
	ctrl:   bool,
	alt:    bool,
	shift:  bool,
}

UI_Msg_Input :: struct {
	event: Input_Event,
}

UI_Msg_Resize :: struct {
	cols: u16,
	rows: u16,
}

// Sent by background `sleipnir` worker actors after committing an `xitdb` transaction.
UI_Msg_Commit_Notification :: struct {
	moment_idx: i64,
	slot_ptr:   i64,
	tx_id:      i64,
	tag_name:   string,
}

UI_Msg_State_Committed :: UI_Msg_Commit_Notification

UI_Msg_Select_Moment :: struct {
	moment_idx: i64,
	pin:        bool,
}

UI_Msg_Scroll_Viewport :: struct {
	delta_rows:  int,
	page_scroll: bool,
}

UI_Msg_Search_Input :: struct {
	query: string,
}

UI_Msg_Palette_Toggle :: struct {
	open: bool,
}

UI_Msg_Datalog_Ready :: struct {
	row_count:   int,
	col_count:   int,
	summary:     string,
	summary_buf: [128]u8,
	summary_len: int,
}

UI_Msg_Diff_Ready :: struct {
	from_moment: i64,
	to_moment:   i64,
	added:       int,
	modified:    int,
	removed:     int,
}

UI_Msg_Batch :: struct {
	msgs: []UI_Msg,
}

UI_Msg_Sequence :: struct {
	cmds: []UI_Cmd,
}

UI_Msg_Frame_Tick :: struct {
	tick_ns: i64,
}

UI_Msg_Quit :: struct {}

UI_Msg :: union {
	UI_Msg_Key,
	UI_Msg_Mouse,
	UI_Msg_Input,
	UI_Msg_Resize,
	UI_Msg_Commit_Notification,
	UI_Msg_Select_Moment,
	UI_Msg_Scroll_Viewport,
	UI_Msg_Search_Input,
	UI_Msg_Palette_Toggle,
	UI_Msg_Datalog_Ready,
	UI_Msg_Diff_Ready,
	UI_Msg_Batch,
	UI_Msg_Sequence,
	UI_Msg_Frame_Tick,
	UI_Msg_Quit,
}

ui_send_inputs_and_tick :: proc(
	sched: ^actor.Scheduler,
	ui_pid: actor.PID(UI_Msg),
	inputs: []Input_Event,
	tick_ns: i64,
	alloc := context.temp_allocator,
) {
	if len(inputs) == 0 {
		actor.send(sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = tick_ns}))
		return
	}
	msgs := make([]UI_Msg, len(inputs) + 1, alloc)
	for ev, i in inputs {
		msgs[i] = UI_Msg(UI_Msg_Input{event = ev})
	}
	msgs[len(inputs)] = UI_Msg(UI_Msg_Frame_Tick{tick_ns = tick_ns})
	actor.send(sched, ui_pid, UI_Msg(UI_Msg_Batch{msgs = msgs}))
}

ui_batch_cmds :: proc(
	ui_pid: actor.PID(UI_Msg),
	cmds: []UI_Cmd,
	alloc := context.temp_allocator,
) {
	if len(cmds) == 0 {
		return
	}
	msgs := make([dynamic]UI_Msg, 0, len(cmds), alloc)
	for cmd in cmds {
		if cmd == nil {
			continue
		}
		if msg, ok := cmd(alloc); ok {
			append(&msgs, msg)
		}
	}
	if len(msgs) == 1 {
		actor.send(ui_pid, msgs[0])
	} else if len(msgs) > 1 {
		actor.send(ui_pid, UI_Msg(UI_Msg_Batch{msgs = msgs[:]}))
	}
}


// =============================================================================
// 5. UI Coordinator Actor, Declarative Action Sinks, Side-Effects & Persistence
// =============================================================================

BI_WORKSPACE_ROOT_KEY :: "__bifrost_workspace"

MAX_UI_ACTION_SINKS   :: 64
MAX_UI_BUTTON_BINDS   :: 32
MAX_UI_SIDE_EFFECTS   :: 32

UI_Fast_Event :: union {
	UI_Msg_Key,
	UI_Msg_Mouse,
}

UI_Render_Pass_Fn     :: #type proc(coord: ^UI_Coordinator_State)
UI_Quit_Filter_Fn     :: #type proc(coord: ^UI_Coordinator_State) -> bool
UI_Action_Callback_Fn :: #type proc(coord: ^UI_Coordinator_State, action_name: string, userdata: rawptr)


UI_Inspector_Action :: enum {
	None = 0,
	Moment_Follow,
	Moment_Prev,
	Moment_Next,
	Filter_Focus,
	Query_Datalog,
	Query_Diff,
	App_Quit,
}

UI_Inspector_Actions :: struct {
	moment_follow: UI_Inspector_Action `bifrost:"action=moment.follow,chord=f,policy=root,category=Time Travel,label=Follow Latest Moment (Unpin),desc=Follow"`,
	moment_prev:   UI_Inspector_Action `bifrost:"action=moment.prev,chord=[,policy=root,group=moment_step,group_desc=Time-Travel,category=Time Travel,label=Step Backward One Moment,desc=Prev Moment"`,
	moment_next:   UI_Inspector_Action `bifrost:"action=moment.next,chord=],policy=root,group=moment_step,group_desc=Time-Travel,category=Time Travel,label=Step Forward One Moment,desc=Next Moment"`,
	filter_focus:  UI_Inspector_Action `bifrost:"action=filter.focus,chord=/,policy=root,category=Navigation,label=Focus Search Filter,desc=Filter"`,
	query_datalog: UI_Inspector_Action `bifrost:"action=query.datalog,chord=<C-d>,policy=root,allow_in_edit=true,category=Analytics,label=Execute Datalog Audit Query,desc=Datalog"`,
	query_diff:    UI_Inspector_Action `bifrost:"action=query.diff,chord=<C-g>,policy=root,allow_in_edit=true,category=Analytics,label=Diff Pinned vs Latest Moment,desc=Diff"`,
	app_quit:      UI_Inspector_Action `bifrost:"action=app.quit,chord=q,policy=root,category=System,label=Quit Application,desc=Quit"`,
}

UI_Action_Sink :: struct {
	action_id:   u64,
	action_name: string,
	dispatch_fn: UI_Action_Callback_Fn,
	userdata:    rawptr,
	owned_ptr:   rawptr,
	free_fn:     proc(ptr: rawptr, alloc: mem.Allocator),
}

UI_Button_Action_Binding :: struct {
	widget_hash: u64,
	action_id:   u64,
	action_name: string,
}

UI_Coordinator_State :: struct {
	allocator:             mem.Allocator,
	shared_db:             ^Xitdb_Shared_Handle,
	user_ptr:              rawptr,

	// Bifrost Immediate-Mode Rendering & Widget Pipeline
	screen:                Screen,
	layout_ctx:            Layout_Context,
	input:                 Input_State,
	state_store:           Widget_State_Store,
	palette:               Command_Palette,
	pending_inputs:        [dynamic]Input_Event,
	use_widget_pipeline:   bool,
	primary_list_id:       string,

	// Cell-buffer aliases into `screen.front` / `screen.back`
	cols:                  int,
	rows:                  int,
	front_buf:             []Cell,
	back_buf:              []Cell,
	ansi_builder:          strings.Builder,
	last_diff_cells:       int,
	last_ansi_bytes:       int,

	// Frame-Pacing & Mailbox Coalescing State
	dirty:                 bool,
	layout_dirty:          bool,
	urgent_input:          bool,
	quit_requested:        bool,
	quit_filter:           UI_Quit_Filter_Fn,
	render_on_drain:       bool,
	last_frame_tick:       time.Tick,
	frame_interval:        time.Duration,
	min_frame_duration:    time.Duration,
	max_coalesce_batch:    int,
	batch_drained:         int,
	total_msgs_processed:  int,
	total_frames:          int,
	coalesced_commits:     int,

	// Snapshot & Time-Travel State
	latest_moment_idx:     i64,
	latest_slot_ptr:       i64,
	latest_tx_id:          i64,
	pinned_moment:         bool,
	active_moment_idx:     i64,
	active_collection:     string,
	active_collection_buf: [128]u8,
	active_collection_len: int,

	// Widget & Viewport State
	vlist:                 UI_Virtual_List,
	filter:                Xitdb_Filter,
	search_buf:            [128]u8,
	search_len:            int,
	palette_open:          bool,
	palette_selected:      int,
	last_datalog_buf:      [128]u8,
	last_datalog_len:      int,
	last_datalog_summary:  string,
	last_diff_summary:     UI_Msg_Diff_Ready,
	last_viewport_rows:    int,
	alert_log_state:       Log_Viewer_State,

	// Declarative Sleipnir Actor Action Sinks, Button Bridges & Pure Side-Effect Queue
	action_sinks:          [MAX_UI_ACTION_SINKS]UI_Action_Sink,
	action_sink_cnt:       int,
	button_binds:          [MAX_UI_BUTTON_BINDS]UI_Button_Action_Binding,
	button_bind_cnt:       int,
	side_effects:          [MAX_UI_SIDE_EFFECTS]UI_Side_Effect,
	side_effect_cnt:       int,

	// Optional Sharded SPSC Fast-Path Mailbox for Dedicated Terminal Reader
	spsc_mailbox:          ^actor.Sharded_SPSC_Mailbox(UI_Fast_Event),

	// Immediate-Mode Render Callback
	render_pass:           UI_Render_Pass_Fn,

	// Optional Heimdall telemetry recorder (falls back to `heimdall.default_recorder()` when nil)
	recorder:              ^heimdall.Recorder,
}

// Configures `coord.recorder` and propagates it to `coord.screen`, `coord.layout_ctx`, and `coord.input`.
ui_coordinator_set_recorder :: proc "contextless" (coord: ^UI_Coordinator_State, rec: ^heimdall.Recorder) {
	if coord == nil {
		return
	}
	coord.recorder            = rec
	coord.screen.recorder     = rec
	coord.layout_ctx.recorder = rec
	coord.input.recorder      = rec
}

ui_coordinator_init :: proc(
	coord: ^UI_Coordinator_State,
	cols, rows: int,
	shared_db: ^Xitdb_Shared_Handle,
	render_pass: UI_Render_Pass_Fn = nil,
	allocator := context.allocator,
) -> bool {
	if coord == nil {
		return false
	}
	w := max(cols, 2)
	h := max(rows, 2)

	coord.allocator = allocator
	coord.shared_db = shared_db
	if screen_init(&coord.screen, i32(w), i32(h), allocator) != nil {
		return false
	}
	if state_store_init(&coord.state_store, allocator) != nil {
		screen_destroy(&coord.screen)
		return false
	}
	if xitdb_filter_init(&coord.filter, allocator) != nil {
		state_store_destroy(&coord.state_store)
		screen_destroy(&coord.screen)
		return false
	}
	pending_inputs, p_err := make([dynamic]Input_Event, 0, 64, allocator)
	if p_err != nil {
		xitdb_filter_destroy(&coord.filter)
		state_store_destroy(&coord.state_store)
		screen_destroy(&coord.screen)
		return false
	}
	coord.pending_inputs = pending_inputs

	command_palette_init(&coord.palette, &coord.input)
	_ = register_actions_struct(&coord.input, &coord.palette, UI_Inspector_Actions{})
	_ = bind_chord(&coord.input, "<C-q>|<C-c>", "app.quit", .Global_Always, "", {.Allow_In_Text_Input})
	_ = bind_chord(&coord.input, "Q", "app.quit", .Root_And_Scopes)

	coord.cols                 = w
	coord.rows                 = h
	coord.front_buf            = coord.screen.front
	coord.back_buf             = coord.screen.back
	coord.ansi_builder         = strings.builder_make(0, 8192, allocator)
	coord.frame_interval       = DEFAULT_FRAME_INTERVAL
	coord.min_frame_duration   = DEFAULT_MIN_FRAME_DURATION
	coord.max_coalesce_batch   = DEFAULT_MAX_COALESCE_BATCH
	coord.last_frame_tick      = time.tick_now()
	coord.primary_list_id      = "records_pane"
	coord.vlist                = UI_Virtual_List{
		viewport_rows = max(1, h - 6),
		overscan      = DEFAULT_SCROLL_OVERSCAN,
	}
	coord.alert_log_state      = Log_Viewer_State{is_following = true}
	coord.filter.hide_tx       = true
	coord.dirty                = true
	coord.layout_dirty         = true
	coord.render_pass          = render_pass
	coord.input.wants_focus_id = hash_id("records_pane")
	return true
}

ui_coordinator_destroy :: proc(coord: ^UI_Coordinator_State) {
	if coord == nil {
		return
	}
	for i := 0; i < coord.action_sink_cnt; i += 1 {
		sink := coord.action_sinks[i]
		if sink.owned_ptr != nil && sink.free_fn != nil {
			sink.free_fn(sink.owned_ptr, coord.allocator)
		}
	}
	strings.builder_destroy(&coord.ansi_builder)
	delete(coord.pending_inputs)
	xitdb_filter_destroy(&coord.filter)
	state_store_destroy(&coord.state_store)
	screen_destroy(&coord.screen)
	coord^ = {}
}

spawn_ui_coordinator :: proc(
	sched: ^actor.Scheduler,
	cols, rows: int,
	shared_db: ^Xitdb_Shared_Handle,
	render_pass: UI_Render_Pass_Fn = nil,
	allocator := context.allocator,
) -> (
	ui_actor: ^actor.Actor(UI_Coordinator_State, UI_Msg),
	ok: bool,
) {
	init_state: UI_Coordinator_State
	if !ui_coordinator_init(&init_state, cols, rows, shared_db, render_pass, allocator) {
		return nil, false
	}
	spawned, s_err := actor.spawn(sched, init_state, ui_coordinator_receive, 1, allocator)
	if s_err != nil {
		ui_coordinator_destroy(&init_state)
		return nil, false
	}
	ui_rebind_internal_slices(&spawned.state)
	return spawned, true
}

// Safely sets `active_collection_buf` and updates `active_collection` on `coord`.
ui_set_active_collection :: proc "contextless" (coord: ^UI_Coordinator_State, name: string) {
	if coord == nil {
		return
	}
	coord.active_collection_len, coord.active_collection = copy_string_to_buf(coord.active_collection_buf[:], name)
}

// Rebinds interior `string` views (`active_collection`, `last_datalog_summary`, `filter.prefix`/`needle`)
// to `coord`'s current address so struct copies (e.g. `actor.spawn`) never retain dangling stack pointers.
ui_rebind_internal_slices :: proc "contextless" (coord: ^UI_Coordinator_State) {
	if coord == nil {
		return
	}
	if coord.active_collection_len > 0 && coord.active_collection_len <= len(coord.active_collection_buf) {
		coord.active_collection = string(coord.active_collection_buf[:coord.active_collection_len])
	}
	if coord.last_datalog_len > 0 && coord.last_datalog_len <= len(coord.last_datalog_buf) {
		coord.last_datalog_summary = string(coord.last_datalog_buf[:coord.last_datalog_len])
	}
	if coord.search_len > 0 && coord.search_len <= len(coord.search_buf) {
		q_slice := string(coord.search_buf[:coord.search_len])
		if coord.filter.kind == .Key_Prefix && len(q_slice) >= 1 && q_slice[0] == '^' {
			coord.filter.prefix = q_slice[1:]
		} else if coord.filter.kind == .Substring {
			coord.filter.needle = q_slice
		}
	}
}

// Helper for drawing a string directly onto `coord.back_buf` in custom `render_pass` callbacks.
ui_back_draw_text :: proc(
	coord: ^UI_Coordinator_State,
	col, row: int,
	text: string,
	fg: Color = {},
	bg: Color = {},
	style: Style_Flags = {},
) {
	if row < 0 || row >= coord.rows {
		return
	}
	x := col
	for ch in text {
		if x >= coord.cols {
			break
		}
		if x >= 0 {
			coord.back_buf[row * coord.cols + x] = Cell{
				ch    = ch,
				fg    = fg,
				bg    = bg,
				style = style,
				width = 1,
			}
		}
		x += 1
	}
}

ui_coordinator_clear_back :: proc(coord: ^UI_Coordinator_State, fill := DEFAULT_CELL) {
	for i in 0 ..< len(coord.back_buf) {
		coord.back_buf[i] = fill
	}
}


// =============================================================================
// 8. Pure Event-Queuing Reducer & Two-Pass Immediate-Mode Frame Reconciler
// =============================================================================

ui_sync_vlist_to_slot :: proc(
	coord: ^UI_Coordinator_State,
	list_id: string,
	total_rows: int,
	visible_rows: int,
) {
	coord.vlist.viewport_rows = max(1, visible_rows)
	coord.vlist.total_rows    = max(0, total_rows)
	if coord.vlist.total_rows <= 0 {
		coord.vlist.selected_row  = 0
		coord.vlist.scroll_offset = 0
	} else {
		coord.vlist.selected_row  = clamp(coord.vlist.selected_row, 0, coord.vlist.total_rows - 1)
		max_off := max(0, coord.vlist.total_rows - coord.vlist.viewport_rows)
		coord.vlist.scroll_offset = clamp(coord.vlist.scroll_offset, 0, max_off)
	}
	if len(list_id) > 0 {
		slot := get_scroll_slot(&coord.input, hash_id(list_id))
		slot.total_rows    = i32(coord.vlist.total_rows)
		slot.viewport_rows = i32(coord.vlist.viewport_rows)
		slot.max_offset    = max(0, slot.total_rows - slot.viewport_rows)
		slot.selected_row  = i32(coord.vlist.selected_row)
		slot.offset        = i32(coord.vlist.scroll_offset)
	}
}

// Reads collection count, syncs `coord.vlist` + `Scroll_Slot`, and returns a zero-copy `Xitdb_Viewport_Slice`.
ui_coordinator_slice_viewport :: proc(
	coord: ^UI_Coordinator_State,
	list_id: string,
	visible_rows: int,
	allocator := context.temp_allocator,
) -> (slice: Xitdb_Viewport_Slice) {
	if coord == nil {
		return {}
	}
	rec := resolve_recorder(coord.recorder)
	heimdall.scoped_span(rec, TELEMETRY_SCOPE_COORDINATOR, "slice_viewport", i64(visible_rows))
	if coord.shared_db != nil && coord.shared_db.db != nil {
		sync.rw_mutex_shared_lock(&coord.shared_db.rw_lock)
		defer sync.rw_mutex_shared_unlock(&coord.shared_db.rw_lock)
		local_core := coord.shared_db.db.core^
		local_db   := coord.shared_db.db^
		local_db.core = &local_core
		total_cnt, cnt_err := xitdb_read_collection_count(
			&local_db,
			coord.active_moment_idx,
			coord.active_collection,
		)
		if cnt_err == nil {
			ui_sync_vlist_to_slot(coord, list_id, int(total_cnt), visible_rows)
			requested_start := i64(coord.vlist.scroll_offset)
			slice, _ = xitdb_slice_viewport(
				&local_db,
				coord.active_moment_idx,
				coord.active_collection,
				requested_start,
				i64(visible_rows),
				coord.filter,
				allocator,
				coord.recorder,
			)
			ui_sync_vlist_to_slot(coord, list_id, int(slice.total_rows), visible_rows)
			if slice.total_rows > 0 && len(slice.rows) == 0 && i64(coord.vlist.scroll_offset) < requested_start {
				// Clamped retry after filter narrowed `total_rows` below `requested_start`:
				// pass `disabled_recorder()` so the single logical `slice_viewport` operation does not emit a duplicate `xitdb_slice_viewport` span.
				slice, _ = xitdb_slice_viewport(
					&local_db,
					coord.active_moment_idx,
					coord.active_collection,
					i64(coord.vlist.scroll_offset),
					i64(visible_rows),
					coord.filter,
					allocator,
					disabled_recorder(),
				)
			}
		} else {
			ui_sync_vlist_to_slot(coord, list_id, 0, visible_rows)
		}
	} else {
		ui_sync_vlist_to_slot(coord, list_id, coord.vlist.total_rows, visible_rows)
	}
	coord.last_viewport_rows = len(slice.rows)
	heimdall.gauge_set(rec, TELEMETRY_SCOPE_COORDINATOR, "viewport_rows", f64(len(slice.rows)), slice.total_rows)
	return slice
}

@(private)
ui_pull_slot_to_vlist :: proc(state: ^UI_Coordinator_State) {
	if len(state.primary_list_id) == 0 {
		return
	}
	slot := get_scroll_slot(&state.input, hash_id(state.primary_list_id))
	if slot.viewport_rows > 0 {
		state.vlist.viewport_rows = int(slot.viewport_rows)
	}
	state.vlist.selected_row  = int(slot.selected_row)
	state.vlist.scroll_offset = int(slot.offset)
}

@(private)
ui_apply_search_query :: proc(state: ^UI_Coordinator_State, q_raw: string, reset_vlist: bool) {
	q_slice: string
	state.search_len, q_slice = copy_string_to_buf(state.search_buf[:], q_raw)
	if strings.has_prefix(q_slice, "^") {
		state.filter.kind   = .Key_Prefix
		state.filter.prefix = q_slice[1:]
		state.filter.needle = ""
	} else if len(q_slice) > 0 {
		state.filter.kind   = .Substring
		state.filter.needle = q_slice
		state.filter.prefix = ""
	} else {
		state.filter.kind   = .None
		state.filter.prefix = ""
		state.filter.needle = ""
	}
	if reset_vlist {
		state.vlist.selected_row  = 0
		state.vlist.scroll_offset = 0
		if len(state.primary_list_id) > 0 {
			slot := get_scroll_slot(&state.input, hash_id(state.primary_list_id))
			slot.selected_row = 0
			slot.offset       = 0
		}
	}
}

// O(1) state reducer for a single `UI_Msg`.
// Keyboard & mouse events are purely queued into `pending_inputs` so focus scopes,
// active text inputs (`editing_id`), and `.Trap_Focus` modals govern routing in `resolve_input`.
ui_reduce_single_msg :: proc(state: ^UI_Coordinator_State, msg: UI_Msg) -> (is_tick: bool) {
	state.total_msgs_processed += 1

	switch m in msg {
	case UI_Msg_Key:
		state.dirty = true
		state.layout_dirty = true
		state.urgent_input = true

		mods: Modifiers
		if m.shift {
			mods += {.Shift}
		}
		if m.alt {
			mods += {.Alt}
		}
		if m.ctrl {
			mods += {.Ctrl}
		}
		if m.super_mod {
			mods += {.Super}
		}
		ke := Key_Event{
			code      = m.code if m.code != .None else (.Rune if m.ch != 0 else .None),
			ch        = m.ch,
			codepoint = m.ch,
			mods      = mods,
			action    = .Repeat if m.is_repeat else .Press,
		}
		if m.ch != 0 && !m.ctrl && !m.alt {
			encoded, w := utf8.encode_rune(m.ch)
			for b_idx in 0 ..< w {
				ke.text_buf[b_idx] = encoded[b_idx]
			}
			ke.text_len = u8(w)
		}
		append(&state.pending_inputs, Input_Event(ke))

	case UI_Msg_Mouse:
		is_pure_hover := (is_mouse_hover_motion(m.action) || m.action == .Leave) &&
		                 !state.input.mouse_down && state.input.active_splitter_id == 0 && state.input.event_handler == nil
		if is_pure_hover && is_mouse_hover_motion(m.action) &&
		   len(state.pending_inputs) == 0 && state.input.mouse_initialized &&
		   state.input.mouse_pos[0] == m.x && state.input.mouse_pos[1] == m.y {
			break
		}
		state.dirty = true
		if !is_pure_hover {
			state.layout_dirty = true
		}
		state.urgent_input = true
		mods: Modifiers
		if m.shift {
			mods += {.Shift}
		}
		if m.alt {
			mods += {.Alt}
		}
		if m.ctrl {
			mods += {.Ctrl}
		}
		btn := Mouse_Button.None
		if m.button == 1 {
			btn = .Left
		} else if m.button == 2 {
			btn = .Middle
		} else if m.button == 3 {
			btn = .Right
		} else if m.button == 4 || m.action == .Scroll_Up {
			btn = .Wheel_Up
		} else if m.button == 5 || m.action == .Scroll_Down {
			btn = .Wheel_Down
		}
		mev := Input_Event(Mouse_Event{
			x      = m.x,
			y      = m.y,
			col    = i16(m.x),
			row    = i16(m.y),
			action = m.action,
			button = btn,
			mods   = mods,
		})
		_ = append_or_coalesce_input_event(&state.pending_inputs, mev, &state.input)

	case UI_Msg_Input:
		is_pure_hover := false
		if mev, is_m := m.event.(Mouse_Event); is_m {
			is_pure_hover = (is_mouse_hover_motion(mev.action) || mev.action == .Leave) &&
			                !state.input.mouse_down && state.input.active_splitter_id == 0 && state.input.event_handler == nil
			if is_pure_hover && is_mouse_hover_motion(mev.action) &&
			   len(state.pending_inputs) == 0 && state.input.mouse_initialized &&
			   state.input.mouse_pos[0] == mev.x && state.input.mouse_pos[1] == mev.y {
				break
			}
		}
		state.dirty = true
		if !is_pure_hover {
			state.layout_dirty = true
		}
		state.urgent_input = true
		_ = append_or_coalesce_input_event(&state.pending_inputs, m.event, &state.input)
		#partial switch ev in m.event {
		case Resize_Event:
			cols := int(ev.width)
			rows := int(ev.height)
			if is_plausible_window_size(cols, rows) && (cols != state.cols || rows != state.rows) {
				_ = screen_resize(&state.screen, i32(cols), i32(rows))
				state.cols = cols
				state.rows = rows
				state.front_buf = state.screen.front
				state.back_buf  = state.screen.back
				state.vlist.viewport_rows = max(1, rows - 6)
				ui_virtual_list_clamp(&state.vlist)
			}
		}

	case UI_Msg_Resize:
		cols := int(m.cols)
		rows := int(m.rows)
		if is_plausible_window_size(cols, rows) && (cols != state.cols || rows != state.rows) {
			_ = screen_resize(&state.screen, i32(cols), i32(rows))
			state.cols = cols
			state.rows = rows
			state.front_buf = state.screen.front
			state.back_buf  = state.screen.back
			state.vlist.viewport_rows = max(1, rows - 6)
			ui_virtual_list_clamp(&state.vlist)
			state.dirty = true
			state.layout_dirty = true
			state.urgent_input = true
		}

	case UI_Msg_Commit_Notification:
		state.latest_moment_idx = m.moment_idx
		state.latest_slot_ptr   = m.slot_ptr
		state.latest_tx_id      = m.tx_id
		state.coalesced_commits += 1
		if !state.pinned_moment {
			state.active_moment_idx = m.moment_idx
		}
		state.dirty = true
		state.layout_dirty = true

	case UI_Msg_Select_Moment:
		state.pinned_moment = m.pin
		if m.pin {
			state.active_moment_idx = clamp(m.moment_idx, 0, max(i64(0), state.latest_moment_idx))
		} else {
			state.active_moment_idx = state.latest_moment_idx
		}
		state.dirty = true
		state.layout_dirty = true
		state.urgent_input = true

	case UI_Msg_Scroll_Viewport:
		delta := m.delta_rows
		if m.page_scroll {
			delta *= state.vlist.viewport_rows
		}
		ui_virtual_list_move(&state.vlist, delta)
		if len(state.primary_list_id) > 0 {
			slot := get_scroll_slot(&state.input, hash_id(state.primary_list_id))
			slot.selected_row = i32(state.vlist.selected_row)
			slot.offset       = i32(state.vlist.scroll_offset)
		}
		state.dirty = true
		state.layout_dirty = true
		state.urgent_input = true

	case UI_Msg_Search_Input:
		ui_apply_search_query(state, m.query, true)
		set_text(&state.input, "search_box", string(state.search_buf[:state.search_len]))
		state.dirty        = true
		state.layout_dirty = true
		state.urgent_input = true

	case UI_Msg_Palette_Toggle:
		state.palette_open    = m.open
		state.palette.is_open = m.open
		if m.open {
			set_text(&state.input, state.palette.input_id, "")
			state.palette.dirty = true
			update_palette_matches(&state.palette, &state.input, "")
			state.input.wants_focus_id = hash_id(state.palette.input_id)
		}
		state.dirty        = true
		state.layout_dirty = true
		state.urgent_input = true

	case UI_Msg_Datalog_Ready:
		if m.summary_len > 0 {
			n := min(m.summary_len, len(state.last_datalog_buf))
			buf_copy := m.summary_buf
			copy(state.last_datalog_buf[:n], buf_copy[:n])
			state.last_datalog_len     = n
			state.last_datalog_summary = string(state.last_datalog_buf[:n])
		} else if len(m.summary) > 0 {
			n := min(len(m.summary), len(state.last_datalog_buf))
			copy(state.last_datalog_buf[:n], transmute([]u8)m.summary[:n])
			state.last_datalog_len     = n
			state.last_datalog_summary = string(state.last_datalog_buf[:n])
		}
		state.dirty = true
		state.layout_dirty = true

	case UI_Msg_Diff_Ready:
		state.last_diff_summary = m
		state.dirty = true
		state.layout_dirty = true

	case UI_Msg_Batch:
		for sub in m.msgs {
			if ui_reduce_single_msg(state, sub) {
				is_tick = true
			}
		}

	case UI_Msg_Sequence:
		for cmd in m.cmds {
			if cmd == nil {
				continue
			}
			if produced, ok := cmd(context.temp_allocator); ok {
				if ui_reduce_single_msg(state, produced) {
					is_tick = true
				}
			}
		}

	case UI_Msg_Frame_Tick:
		if m.tick_ns > 0 {
			state.input.clock_ns = m.tick_ns
		}
		if state.input.pending_chord.active {
			timeout := state.input.chord_timeout_ns if state.input.chord_timeout_ns > 0 else DEFAULT_CHORD_TIMEOUT_NS
			if state.input.clock_ns > 0 && state.input.pending_chord.started_tick_ns > 0 &&
			   (state.input.clock_ns - state.input.pending_chord.started_tick_ns) >= timeout {
				state.dirty = true
				state.layout_dirty = true
			}
		}
		is_tick = true

	case UI_Msg_Quit:
		_ = ui_request_quit(state)
	}

	return is_tick
}

// Built-in immediate-mode Inspector layout using Bifrost's Flexbox, Focus Scopes, Splitter,
// Virtual List, Text Input, Command Palette, Contextual Hint Bar, and Zero-Copy `xitdb_slice_viewport`.
ui_render_inspector_frame :: proc(coord: ^UI_Coordinator_State) {
	coord.use_widget_pipeline = true
	begin_frame(&coord.screen)
	begin_layout(&coord.layout_ctx, i32(coord.cols), i32(coord.rows))

	if container(
		&coord.layout_ctx,
		"inspector_root",
		Box_Config{
			dir         = .Column,
			width       = fixed(i32(coord.cols)),
			height      = fixed(i32(coord.rows)),
			focus_flags = {.Focus_Scope},
			focus_scope = true,
		},
	) {
		// 1. Top Status Bar
		mode_str := "PINNED" if coord.pinned_moment else "LIVE"
		header_str := fmt.tprintf(
			"BIFROST xitdb | %s @%d (latest @%d tx=%d) | coll=%s | commits=%d frames=%d",
			mode_str,
			coord.active_moment_idx,
			coord.latest_moment_idx,
			coord.latest_tx_id,
			coord.active_collection if len(coord.active_collection) > 0 else "<root>",
			coord.coalesced_commits,
			coord.total_frames + 1,
		)
		coord.screen.paints[hash_id("status_bar")] = Paint_Spec{
			text    = header_str,
			fg      = rgb(230, 240, 255),
			bg      = rgb(25, 35, 55),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = leaf(&coord.layout_ctx, "status_bar", i32(len(header_str)), 1, Box_Config{
			width  = grow(1),
			height = fixed(1),
			text   = header_str,
		})

		// 2. Search Input Bar (linked to `records_pane` so Escape returns focus cleanly)
		ui_text_input(
			&coord.layout_ctx,
			&coord.screen,
			&coord.input,
			"search_box",
			Text_Input_Config{
				placeholder    = "Search (^prefix or substring)...",
				linked_list_id = "records_pane",
				width          = grow(1),
				height         = fixed(1),
				fg             = rgb(230, 235, 245),
				bg             = rgb(32, 40, 56),
			},
		)

		// 3. Main Body Split Pane (Sidebar + Virtualized Record Table)
		has_hint_row := coord.rows >= 12
		reserved_rows: i32 = 4 if has_hint_row else 3
		body_h := max(i32(3), i32(coord.rows) - reserved_rows)
		if ui_scope(
			&coord.layout_ctx,
			&coord.screen,
			"inspector_body",
			Scope_Config{
				dir    = .Row,
				width  = grow(1),
				height = fixed(body_h),
			},
		) {
			sidebar_w := get_split_size(&coord.input, "main_split", max(16, i32(coord.cols) / 4), 12, max(20, i32(coord.cols) - 20))
			sidebar_text := fmt.tprintf(
				"active=@%d latest=@%d %s",
				coord.active_moment_idx,
				coord.latest_moment_idx,
				coord.active_collection if len(coord.active_collection) > 0 else "<root>",
			)
			coord.screen.paints[hash_id("sidebar_pane")] = Paint_Spec{
				title       = "Moments & Collections",
				text        = sidebar_text,
				fg          = rgb(200, 215, 230),
				border_fg   = rgb(80, 100, 130),
				title_style = {.Bold},
			}
			_ = leaf(&coord.layout_ctx, "sidebar_pane", sidebar_w, body_h, Box_Config{
				width       = fixed(sidebar_w),
				height      = grow(1),
				border      = .Plain,
				text        = sidebar_text,
				focus_flags = {.Focusable},
				focusable   = true,
			})

			_ = ui_splitter(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"main_split",
				Splitter_Config{
					dir          = .Row,
					default_size = sidebar_w,
					min_first    = 12,
					min_second   = 16,
				},
			)

			// Right Pane: Zero-Copy Virtualized xitdb Slice
			visible_rows := max(1, int(body_h) - 2)
			slice := ui_coordinator_slice_viewport(coord, "records_pane", visible_rows)

			vslice: Virtual_Slice
			if ui_virtual_list(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"records_pane",
				i32(slice.total_rows),
				Virtual_List_Config{
					title         = fmt.tprintf("Records (%d total)", slice.total_rows),
					width         = grow(1),
					height        = grow(1),
					border        = .Plain,
					fg            = rgb(210, 220, 230),
					border_fg     = rgb(80, 100, 130),
					fallback_rows = i32(visible_rows),
					focus_flags   = {.Focusable, .Default_Focus},
				},
				&vslice,
			) {
				for row_i in 0 ..< len(slice.rows) {
					rv := slice.rows[row_i]
					is_sel := int(rv.view_index) == coord.vlist.selected_row
					row_id := fmt.tprintf("row_%d", row_i)
					row_line := fmt.tprintf(
						"%s %05d | %-18s | %s",
						">" if is_sel else " ",
						rv.logical_index,
						rv.key_text,
						rv.val_text,
					)
					coord.screen.paints[hash_id(row_id)] = Paint_Spec{
						text    = row_line,
						fg      = rgb(255, 255, 180) if is_sel else rgb(210, 220, 230),
						bg      = rgb(45, 65, 95) if is_sel else Color{},
						style   = {.Bold} if is_sel else {},
						fill_bg = is_sel,
					}
					_ = leaf(&coord.layout_ctx, row_id, i32(len(row_line)), 1, Box_Config{
						width  = grow(1),
						height = fixed(1),
						text   = row_line,
					})
				}
			}
		}

		// 4. Telemetry Bar (Datalog + Diff Summary) + Live Contextual Key-Hint Bar
		footer_str := fmt.tprintf(
			"Datalog: %s | Diff(@%d->@%d): +%d ~%d -%d",
			coord.last_datalog_summary if len(coord.last_datalog_summary) > 0 else "idle",
			coord.last_diff_summary.from_moment,
			coord.last_diff_summary.to_moment,
			coord.last_diff_summary.added,
			coord.last_diff_summary.modified,
			coord.last_diff_summary.removed,
		)
		coord.screen.paints[hash_id("footer_bar")] = Paint_Spec{
			text    = footer_str,
			fg      = rgb(180, 200, 220),
			bg      = rgb(20, 26, 38),
			fill_bg = true,
		}
		_ = leaf(&coord.layout_ctx, "footer_bar", i32(len(footer_str)), 1, Box_Config{
			width  = grow(1),
			height = fixed(1),
			text   = footer_str,
		})

		if has_hint_row {
			ui_key_hint_bar(&coord.layout_ctx, &coord.screen, &coord.input, "inspector_hint_bar")
		}
	}

	// 5. Optional Command Palette Modal Overlay
	coord.palette.is_open = coord.palette_open
	if coord.palette.is_open {
		ui_command_palette(
			&coord.layout_ctx,
			&coord.screen,
			&coord.input,
			&coord.palette,
			min(54, max(20, i32(coord.cols) - 4)),
			min(6, max(2, i32(coord.rows) - 6)),
		)
	}

	end_layout(&coord.layout_ctx)
}

@(private)
ui_invoke_render_pass :: proc(state: ^UI_Coordinator_State) {
	if state.render_pass != nil {
		state.render_pass(state)
	} else {
		ui_render_inspector_frame(state)
	}
}

@(private)
ui_post_resolve_step :: proc(state: ^UI_Coordinator_State) -> (mutated: bool) {
	// 1. Sync live edits inside `"search_box"` to `state.filter` without resetting `vlist.selected_row`
	if was_text_changed(&state.input, "search_box") {
		ui_apply_search_query(state, get_text(&state.input, "search_box"), false)
		mutated = true
	}

	// 1b. Drain internal text_input clipboard OSC 52 copy requests
	if state.input.osc52_pending {
		state.input.osc52_pending = false
		_ = ui_cmd_copy_osc52(state, string(state.input.clipboard_buf[:state.input.clipboard_len]))
		mutated = true
	}

	// 2. Promote button-bound widget activations (`bind_button_action`) into triggered actions
	if state.input.activated_id != 0 && state.input.triggered_action_id == 0 {
		for i := 0; i < state.button_bind_cnt; i += 1 {
			b := state.button_binds[i]
			if b.widget_hash == state.input.activated_id {
				_, _ = trigger_action_by_id(&state.input, b.action_id, b.action_name)
				break
			}
		}
	}

	act_id   := state.input.triggered_action_id
	act_name := state.input.triggered_action_name
	if act_id == 0 {
		if ui_drain_side_effects(state, &state.ansi_builder) {
			mutated = true
		}
		return mutated
	}

	// 3. Built-in Inspector action handlers (honored unless overridden, or alongside actor sinks)
	switch act_name {
	case "moment.prev":
		state.pinned_moment     = true
		state.active_moment_idx = max(0, state.active_moment_idx - 1)
		mutated = true
	case "moment.next":
		if state.active_moment_idx + 1 >= state.latest_moment_idx {
			state.pinned_moment     = false
			state.active_moment_idx = state.latest_moment_idx
		} else {
			state.pinned_moment      = true
			state.active_moment_idx += 1
		}
		mutated = true
	case "moment.follow":
		state.pinned_moment     = false
		state.active_moment_idx = state.latest_moment_idx
		mutated = true
	case "filter.focus":
		state.input.wants_focus_id = hash_id("search_box")
		mutated = true
	case "app.quit":
		_ = ui_request_quit(state)
		mutated = true
	}

	// 4. Dispatch any registered Sleipnir worker actor sinks & local `on_ui_action` callbacks
	for i := 0; i < state.action_sink_cnt; i += 1 {
		sink := state.action_sinks[i]
		if sink.action_id == act_id && sink.dispatch_fn != nil {
			sink.dispatch_fn(state, act_name, sink.userdata)
			mutated = true
		}
	}

	if ui_drain_side_effects(state, &state.ansi_builder) {
		mutated = true
	}
	return mutated
}

ui_coordinator_flush_frame :: proc(state: ^UI_Coordinator_State) {
	state.screen.recorder     = state.recorder
	state.layout_ctx.recorder = state.recorder
	state.input.recorder      = state.recorder

	ui_rebind_internal_slices(state)
	strings.builder_reset(&state.ansi_builder)
	has_pre_fx := ui_drain_side_effects(state, &state.ansi_builder)

	has_existing_layout := state.use_widget_pipeline && len(state.layout_ctx.nodes) > 0 && state.cols > 0 && state.rows > 0
	if !state.layout_dirty && !has_pre_fx && has_existing_layout && !state.input.pending_chord.active &&
	   is_pure_hover_event_batch(&state.input, state.pending_inputs[:]) {
		frame_start_focused_id     := state.input.focused_id
		frame_start_hovered_id     := state.input.hovered_id
		frame_start_hover_path     := state.input.hover_path
		frame_start_hover_path_len := state.input.hover_path_len

		for ev in state.pending_inputs {
			resolve_input(&state.input, &state.layout_ctx, ev)
		}
		clear(&state.pending_inputs)

		hover_same := state.input.hovered_id == frame_start_hovered_id &&
		              state.input.hover_path_len == frame_start_hover_path_len &&
		              state.input.hover_path == frame_start_hover_path

		state.input.prev_focused_id     = frame_start_focused_id
		state.input.prev_hovered_id     = frame_start_hovered_id
		state.input.prev_hover_path     = frame_start_hover_path
		state.input.prev_hover_path_len = frame_start_hover_path_len

		if hover_same {
			// Cursor moved to a different cell inside the same widget (e.g. `csv_main_table`):
			// zero layout passes, zero CSV slicing, zero screen diffing.
			// IMPORTANT: Do NOT call `free_all(context.temp_allocator)` here so `state.layout_ctx`
			// remains intact for subsequent hover hit-tests until the next full render pass!
			state.last_diff_cells = 0
			state.last_ansi_bytes = 0
			state.dirty           = false
			state.urgent_input    = false
			state.batch_drained   = 0
			return
		}

		// Hover target changed: now reset temp_allocator and run 1 render pass with the updated `hovered_id`.
		free_all(context.temp_allocator)
		rec := resolve_recorder(state.recorder)
		heimdall.scoped_span(rec, TELEMETRY_SCOPE_COORDINATOR, "flush_frame", i64(state.total_frames + 1))

		state.use_widget_pipeline = false
		state_store_begin_frame(&state.state_store)
		ui_invoke_render_pass(state)
		_ = ui_drain_side_effects(state, &state.ansi_builder)
		if state.use_widget_pipeline {
			state_store_sync_from_layout(&state.state_store, &state.layout_ctx, &state.input)
			apply_input_highlights(&state.screen, &state.layout_ctx, &state.input)
			render_layout(&state.screen, &state.layout_ctx)
		}
		state.last_diff_cells = screen_diff_ansi(&state.screen, &state.ansi_builder)
		state.last_ansi_bytes = strings.builder_len(state.ansi_builder)
		state.front_buf       = state.screen.front
		state.back_buf        = state.screen.back
		state.dirty           = false
		state.urgent_input    = false
		state.batch_drained   = 0
		state.total_frames    += 1
		state.last_frame_tick = time.tick_now()
		heimdall.counter_add(rec, TELEMETRY_SCOPE_COORDINATOR, "frames_rendered", 1.0, i64(state.total_frames))
		heimdall.gauge_set(rec, TELEMETRY_SCOPE_COORDINATOR, "diff_cells", f64(state.last_diff_cells), i64(state.last_ansi_bytes))
		return
	}

	free_all(context.temp_allocator)
	state.layout_dirty = false
	rec := resolve_recorder(state.recorder)
	heimdall.scoped_span(rec, TELEMETRY_SCOPE_COORDINATOR, "flush_frame", i64(state.total_frames + 1))

	state.use_widget_pipeline = false
	// Clear one-shot per-frame edge triggers from the previous frame before Pass #1
	// so `render_pass` never observes stale `activated_id` / `clicked_id` / `escape_modal_id`
	// values left over at the end of the prior frame.
	state.input.activated_id          = 0
	state.input.clicked_id            = 0
	state.input.scrolled_id           = 0
	state.input.text_changed_id       = 0
	state.input.tab_changed_id        = 0
	state.input.backdrop_clicked_id   = 0
	state.input.escape_modal_id       = 0
	state.input.triggered_action_id   = 0
	state.input.triggered_action_name = ""
	state.input.triggered_enum_val    = 0
	state.input.has_triggered_enum    = false
	state.input.last_disabled_reason  = ""
	state_store_begin_frame(&state.state_store)
	ui_invoke_render_pass(state)
	_ = ui_drain_side_effects(state, &state.ansi_builder)

	if state.use_widget_pipeline {
		frame_start_focused_id     := state.input.focused_id
		frame_start_hovered_id     := state.input.hovered_id
		frame_start_hover_path     := state.input.hover_path
		frame_start_hover_path_len := state.input.hover_path_len

		if len(state.pending_inputs) == 0 {
			// Frame 0 / commit-only / chord-timeout frame: reconcile focus and expire timed-out chords
			prev_focus   := state.input.focused_id
			prev_edit    := state.input.editing_id
			prev_pending := state.input.pending_chord.active
			resolve_input(&state.input, &state.layout_ctx)
			ui_pull_slot_to_vlist(state)
			state_changed := ui_post_resolve_step(state)
			if state.input.focused_id != prev_focus ||
			   state.input.editing_id != prev_edit ||
			   state.input.pending_chord.active != prev_pending ||
			   state_changed {
				last_act_id   := state.input.triggered_action_id
				last_act_name := state.input.triggered_action_name
				last_has_enum := state.input.has_triggered_enum
				last_enum_val := state.input.triggered_enum_val
				saved_lay_rec := state.layout_ctx.recorder
				saved_inp_rec := state.input.recorder
				state.layout_ctx.recorder = disabled_recorder()
				state.input.recorder      = disabled_recorder()
				ui_invoke_render_pass(state)
				_ = ui_drain_side_effects(state, &state.ansi_builder)
				resolve_input(&state.input, &state.layout_ctx)
				state.layout_ctx.recorder = saved_lay_rec
				state.input.recorder      = saved_inp_rec
				state.input.triggered_action_id   = last_act_id
				state.input.triggered_action_name = last_act_name
				state.input.has_triggered_enum    = last_has_enum
				state.input.triggered_enum_val    = last_enum_val
			}
		} else {
			events := make([]Input_Event, len(state.pending_inputs), context.temp_allocator)
			copy(events, state.pending_inputs[:])
			clear(&state.pending_inputs)

			last_act_id:       u64
			last_act_name:     string
			last_has_enum:     bool
			last_enum_val:     i64
			last_activated_id: u64
			last_clicked_id:   u64
			last_scrolled_id:  u64
			last_text_changed: u64
			last_disabled_msg: string

			prev_focus   := state.input.focused_id
			prev_edit    := state.input.editing_id
			prev_pending := state.input.pending_chord.active
			needs_rebuild := false

			for ev, ev_idx in events {
				is_pure_hover := false
				if mev, is_m := ev.(Mouse_Event); is_m && (is_mouse_hover_motion(mev.action) || mev.action == .Leave) &&
				   !state.input.mouse_down && state.input.active_splitter_id == 0 && state.input.event_handler == nil {
					is_pure_hover = true
				}
				if !is_pure_hover {
					needs_rebuild = true
				}

				resolve_input(&state.input, &state.layout_ctx, ev)
				ui_pull_slot_to_vlist(state)

				palette_changed := update_command_palette(&state.palette, &state.input)
				if palette_changed {
					state.palette_open = state.palette.is_open
					needs_rebuild      = true
				}

				state_changed := ui_post_resolve_step(state)
				if state_changed ||
				   state.input.focused_id != prev_focus ||
				   state.input.editing_id != prev_edit ||
				   state.input.pending_chord.active != prev_pending ||
				   state.input.wants_focus_id != 0 ||
				   state.input.triggered_action_id != 0 ||
				   state.input.activated_id != 0 ||
				   state.input.clicked_id != 0 ||
				   state.input.scrolled_id != 0 ||
				   state.input.text_changed_id != 0 ||
				   state.input.tab_changed_id != 0 ||
				   state.input.backdrop_clicked_id != 0 ||
				   state.input.escape_modal_id != 0 {
					needs_rebuild = true
				}

				if state.input.triggered_action_id != 0 {
					last_act_id   = state.input.triggered_action_id
					last_act_name = state.input.triggered_action_name
					last_has_enum = state.input.has_triggered_enum
					last_enum_val = state.input.triggered_enum_val
				}
				if state.input.activated_id != 0 {
					last_activated_id = state.input.activated_id
				}
				if state.input.clicked_id != 0 {
					last_clicked_id = state.input.clicked_id
				}
				if state.input.scrolled_id != 0 {
					last_scrolled_id = state.input.scrolled_id
				}
				if state.input.text_changed_id != 0 {
					last_text_changed = state.input.text_changed_id
				}
				if len(state.input.last_disabled_reason) > 0 {
					last_disabled_msg = state.input.last_disabled_reason
				}

				// If a modal/focus/state transition occurred mid-burst and more events remain,
				// rebuild and reconcile immediately so subsequent events in the same burst see the updated tree.
				if ev_idx + 1 < len(events) && (palette_changed || state_changed || state.input.wants_focus_id != 0) {
					saved_lay_rec := state.layout_ctx.recorder
					saved_inp_rec := state.input.recorder
					state.layout_ctx.recorder = disabled_recorder()
					state.input.recorder      = disabled_recorder()
					ui_invoke_render_pass(state)
					resolve_input(&state.input, &state.layout_ctx)
					state.layout_ctx.recorder = saved_lay_rec
					state.input.recorder      = saved_inp_rec
					prev_focus   = state.input.focused_id
					prev_edit    = state.input.editing_id
					prev_pending = state.input.pending_chord.active
				}
			}

			// Rebuild layout with updated state and run post-rebuild focus reconciliation so newly opened
			// `.Trap_Focus` modals (e.g. `Command_Palette`) or `wants_focus_id` targets acquire focus on the same frame.
			// Suppress telemetry on the internal post-action layout/focus reconciliation pass so a single
			// `flush_frame` emits exactly one `end_layout` / `resolve_input` span for the frame.
			// When the frame only processed pure mouse hover motion with zero state/focus mutations, skip the
			// redundant second layout rebuild and input reconciliation pass.
			state.input.triggered_action_id   = last_act_id
			state.input.triggered_action_name = last_act_name
			state.input.has_triggered_enum    = last_has_enum
			state.input.triggered_enum_val    = last_enum_val
			state.input.activated_id          = last_activated_id
			state.input.clicked_id            = last_clicked_id
			state.input.scrolled_id           = last_scrolled_id
			state.input.text_changed_id       = last_text_changed
			state.input.last_disabled_reason  = last_disabled_msg

			if needs_rebuild {
				saved_lay_rec := state.layout_ctx.recorder
				saved_inp_rec := state.input.recorder
				state.layout_ctx.recorder = disabled_recorder()
				state.input.recorder      = disabled_recorder()
				ui_invoke_render_pass(state)
				_ = ui_drain_side_effects(state, &state.ansi_builder)
				resolve_input(&state.input, &state.layout_ctx)
				state.layout_ctx.recorder = saved_lay_rec
				state.input.recorder      = saved_inp_rec

				state.input.triggered_action_id   = last_act_id
				state.input.triggered_action_name = last_act_name
				state.input.has_triggered_enum    = last_has_enum
				state.input.triggered_enum_val    = last_enum_val
				state.input.activated_id          = last_activated_id
				state.input.clicked_id            = last_clicked_id
				state.input.scrolled_id           = last_scrolled_id
				state.input.text_changed_id       = last_text_changed
				state.input.last_disabled_reason  = last_disabled_msg
			}
		}

		state.input.prev_focused_id     = frame_start_focused_id
		state.input.prev_hovered_id     = frame_start_hovered_id
		state.input.prev_hover_path     = frame_start_hover_path
		state.input.prev_hover_path_len = frame_start_hover_path_len

		state_store_sync_from_layout(&state.state_store, &state.layout_ctx, &state.input)
		apply_input_highlights(&state.screen, &state.layout_ctx, &state.input)
		render_layout(&state.screen, &state.layout_ctx)
	} else {
		clear(&state.pending_inputs)
	}

	state.last_diff_cells = screen_diff_ansi(&state.screen, &state.ansi_builder)
	state.last_ansi_bytes = strings.builder_len(state.ansi_builder)
	state.front_buf       = state.screen.front
	state.back_buf        = state.screen.back

	state.dirty           = false
	state.urgent_input    = false
	state.batch_drained   = 0
	state.total_frames    += 1
	state.last_frame_tick = time.tick_now()

	heimdall.counter_add(rec, TELEMETRY_SCOPE_COORDINATOR, "frames_rendered", 1.0, i64(state.total_frames))
	heimdall.gauge_set(rec, TELEMETRY_SCOPE_COORDINATOR, "diff_cells", f64(state.last_diff_cells), i64(state.last_ansi_bytes))
}

// Single-owner UI Coordinator actor receive callback with mailbox burst coalescing.
ui_coordinator_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(UI_Coordinator_State, UI_Msg),
	msg: ^UI_Msg,
) {
	_ = ctx
	state := &self.state
	if msg == nil {
		return
	}
	rec := resolve_recorder(state.recorder)
	heimdall.scoped_span(rec, TELEMETRY_SCOPE_COORDINATOR, "actor_turn", i64(state.batch_drained + 1))
	msgs_before := state.total_msgs_processed

	// 1. Reduce the incoming message in O(1) time.
	is_tick := ui_reduce_single_msg(state, msg^)
	state.batch_drained += 1

	// 2. Also drain any lock-free SPSC fast-path input events from a terminal reader thread.
	if state.spsc_mailbox != nil {
		actor.sharded_spsc_consume(
			state.spsc_mailbox,
			64,
			state,
			proc(s: ^UI_Coordinator_State, fe: ^UI_Fast_Event) {
				switch ev in fe^ {
				case UI_Msg_Key:
					_ = ui_reduce_single_msg(s, UI_Msg(ev))
					s.batch_drained += 1
				case UI_Msg_Mouse:
					_ = ui_reduce_single_msg(s, UI_Msg(ev))
					s.batch_drained += 1
				}
			},
		)
	}

	// Update `actor_turn`'s `attr_i64` with the cumulative `batch_drained` count after draining
	// both the mailbox turn and any SPSC fast-path events.
	heimdall.span_set_status(rec, .Ok, i64(state.batch_drained), true)

	msgs_delta := state.total_msgs_processed - msgs_before
	if msgs_delta > 0 {
		heimdall.counter_add(rec, TELEMETRY_SCOPE_COORDINATOR, "msgs_processed", f64(msgs_delta), i64(state.total_msgs_processed))
	}

	// 3. Mailbox Burst Coalescing:
	//    While more messages are queued in the actor's Vyukov MPSC mailbox and we haven't
	//    exceeded `max_coalesce_batch` (and this message wasn't an explicit vsync tick),
	//    return immediately so `sleipnir`'s scheduler delivers the next message before rendering.
	if !is_tick && !actor.mpsc_is_empty(&self.mailbox) && state.batch_drained < state.max_coalesce_batch {
		return
	}

	if !state.dirty {
		state.batch_drained = 0
		return
	}

	// 4. Frame-Rate Gate:
	elapsed := time.tick_since(state.last_frame_tick)
	should_render := is_tick ||
		state.render_on_drain ||
		(state.urgent_input && elapsed >= state.min_frame_duration) ||
		(elapsed >= state.frame_interval)

	if !should_render {
		return
	}

	// 5. Execute immediate-mode layout, paint, and differential ANSI emission.
	ui_coordinator_flush_frame(state)
}
