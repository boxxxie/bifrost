package bifrost

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import actor "../deps/heimdall/deps/sleipnir/actor"
import xitdb "../deps/xitdb/xitdb"

@(test)
test_actor_bridge_mailbox_burst_coalescing_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	testing.expect_value(t, db_err, nil)

	shared := Xitdb_Shared_Handle{db = &db}

	sched: actor.Scheduler
	s_err := actor.scheduler_init(&sched, actor.Scheduler_Config{
		num_workers    = 2,
		num_shards     = 2,
		batch_quota    = 2048,
		enable_parking = true,
	}, context.allocator)
	testing.expect_value(t, s_err, nil)

	ui_actor, ok := spawn_ui_coordinator(&sched, 80, 24, &shared, nil, context.allocator)
	testing.expect(t, ok, "Expected spawn_ui_coordinator to succeed")
	ui_pid := actor.pid(ui_actor)

	actor.scheduler_start(&sched)

	// Send 1,000 rapid commit notifications followed by 1 vsync frame tick
	for i := 0; i < 1000; i += 1 {
		actor.send(ui_pid, UI_Msg(UI_Msg_Commit_Notification{
			moment_idx = i64(i),
			slot_ptr   = i64(i * 64),
			tx_id      = i64(i + 1),
			tag_name   = "burst",
		}))
	}
	actor.send(ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 1}))

	actor.scheduler_wait_idle(&sched)

	testing.expect_value(t, ui_actor.state.coalesced_commits, 1000)
	testing.expect_value(t, ui_actor.state.latest_moment_idx, i64(999))
	testing.expect_value(t, ui_actor.state.active_moment_idx, i64(999))
	testing.expect_value(t, ui_actor.state.total_frames, 1)

	ui_coordinator_destroy(&ui_actor.state)
	actor.scheduler_stop_and_destroy(&sched)
}

@(test)
test_actor_bridge_xitdb_slice_viewport_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	testing.expect_value(t, db_err, nil)

	// Populate a Sorted_Map with 2,500 keys and an Array_List with 2,500 items
	tx := xitdb.tx_init(&db, -1, false, context.temp_allocator)
	sm_step := xitdb.hm("metrics")
	al_step := xitdb.hm("events")
	for i := 0; i < 2500; i += 1 {
		k_str := fmt.tprintf("metric:%05d", i)
		v_str := fmt.tprintf("val_%d", i)
		steps_sm := [2]xitdb.Path_Step{sm_step, xitdb.sm(k_str)}
		xitdb.tx_put_steps(&tx, steps_sm[:], v_str)

		steps_al := [1]xitdb.Path_Step{al_step}
		xitdb.tx_append_steps(&tx, steps_al[:], v_str)
	}
	_, c_err := xitdb.tx_commit(&tx)
	testing.expect_value(t, c_err, nil)
	free_all(context.temp_allocator)

	// 1. O(log_16 N) index seek into Sorted_Map at row 1,500 (visible_rows = 15)
	sm_slice, sm_err := xitdb_slice_viewport(&db, -1, "$metrics", 1500, 15, {}, context.temp_allocator)
	testing.expect_value(t, sm_err, nil)
	testing.expect_value(t, sm_slice.total_rows, i64(2500))
	testing.expect_value(t, len(sm_slice.rows), 15)
	testing.expect_value(t, sm_slice.rows[0].logical_index, i64(1500))
	testing.expect_value(t, sm_slice.rows[0].key_text, "metric:01500")
	testing.expect_value(t, sm_slice.rows[0].val_text, "val_1500")
	testing.expect_value(t, sm_slice.rows[14].key_text, "metric:01514")
	free_all(context.temp_allocator)

	// 2. O(log_16 N) B+Tree key-prefix seek on Sorted_Map ("metric:0249")
	prefix_filter := Xitdb_Filter{
		kind   = .Key_Prefix,
		prefix = "metric:0249",
	}
	pf_slice, pf_err := xitdb_slice_viewport(&db, -1, "$metrics", 0, 20, prefix_filter, context.temp_allocator)
	testing.expect_value(t, pf_err, nil)
	testing.expect_value(t, len(pf_slice.rows), 10) // metric:02490 .. metric:02499
	testing.expect_value(t, pf_slice.rows[0].key_text, "metric:02490")
	testing.expect_value(t, pf_slice.rows[9].key_text, "metric:02499")
	free_all(context.temp_allocator)

	// 3. O(log_16 N) index seek into Array_List at row 2,000 (visible_rows = 12)
	al_slice, al_err := xitdb_slice_viewport(&db, -1, ".events", 2000, 12, {}, context.temp_allocator)
	testing.expect_value(t, al_err, nil)
	testing.expect_value(t, al_slice.total_rows, i64(2500))
	testing.expect_value(t, len(al_slice.rows), 12)
	testing.expect_value(t, al_slice.rows[0].logical_index, i64(2000))
	testing.expect_value(t, al_slice.rows[0].key_text, "[2000]")
	testing.expect_value(t, al_slice.rows[0].val_text, "val_2000")
	free_all(context.temp_allocator)
}

Test_Batch_Cmd_Msg :: struct {
	step_id: int,
	label:   string,
}

Test_Batch_Worker_State :: struct {
	received_count: int,
	step_sum:       int,
	last_label:     string,
}

test_batch_worker_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(Test_Batch_Worker_State, Test_Batch_Cmd_Msg),
	msg: ^Test_Batch_Cmd_Msg,
) {
	_ = ctx
	if msg == nil {
		return
	}
	self.state.received_count += 1
	self.state.step_sum += msg.step_id
	self.state.last_label = msg.label
}

Quit_Guard_Mock :: struct {
	dirty_edits:       bool,
	intercepted_count: int,
}

@(test)
test_actor_bridge_action_sinks_side_effects_focus_out_and_quit_filter_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	testing.expect_value(t, db_err, nil)
	shared := Xitdb_Shared_Handle{db = &db}

	sched: actor.Scheduler
	s_err := actor.scheduler_init(&sched, actor.Scheduler_Config{
		num_workers    = 2,
		num_shards     = 2,
		batch_quota    = 2048,
		enable_parking = true,
	}, context.allocator)
	testing.expect_value(t, s_err, nil)

	ui_actor, ok := spawn_ui_coordinator(&sched, 96, 24, &shared, nil, context.allocator)
	testing.expect(t, ok, "Expected spawn_ui_coordinator to succeed")
	ui_pid := actor.pid(ui_actor)

	worker_actor, w_err := actor.spawn(&sched, Test_Batch_Worker_State{}, test_batch_worker_receive, 2, context.allocator)
	testing.expect_value(t, w_err, nil)
	worker_pid := actor.pid(worker_actor)

	// Bind both a single message action and a batched slice-spliced action to worker_pid
	bind_chord(&ui_actor.state.input, "<C-r>", "worker.single", .Root_And_Scopes)
	bind_chord(&ui_actor.state.input, "<C-b>", "worker.batch", .Root_And_Scopes)
	testing.expect(t, bind_actor_action(&ui_actor.state, "worker.single", worker_pid, Test_Batch_Cmd_Msg{
		step_id = 10,
		label   = "single-ping",
	}))
	batch_payload := [3]Test_Batch_Cmd_Msg{
		{step_id = 1, label = "b1"},
		{step_id = 2, label = "b2"},
		{step_id = 3, label = "b3"},
	}
	testing.expect(t, bind_actor_action(&ui_actor.state, "worker.batch", worker_pid, batch_payload[:]))

	// Install Bubble-Tea-style quit_filter guard
	guard_ctx := Quit_Guard_Mock{dirty_edits = true}
	ui_set_quit_filter(&ui_actor.state, proc(c: ^UI_Coordinator_State) -> bool {
		g := (^Quit_Guard_Mock)(c.user_ptr)
		if g != nil && g.dirty_edits {
			g.intercepted_count += 1
			return false
		}
		return true
	}, &guard_ctx)

	actor.scheduler_start(&sched)

	// 1. Frame 0 with zero pending inputs reconciles default focus onto "records_pane"
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 1}))
	actor.scheduler_wait_idle(&sched)
	testing.expect(t, is_focused(&ui_actor.state.input, "records_pane"), "Frame 0 must reconcile wants_focus_id onto records_pane")

	// 2. Trigger single + batched Sleipnir actor actions via key chords
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Key{code = .Rune, ch = 'r', ctrl = true}))
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 2}))
	actor.scheduler_wait_idle(&sched)
	testing.expect_value(t, worker_actor.state.received_count, 1)
	testing.expect_value(t, worker_actor.state.step_sum, 10)
	testing.expect_value(t, worker_actor.state.last_label, "single-ping")

	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Key{code = .Rune, ch = 'b', ctrl = true}))
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 3}))
	actor.scheduler_wait_idle(&sched)
	testing.expect_value(t, worker_actor.state.received_count, 4)
	testing.expect_value(t, worker_actor.state.step_sum, 16)
	testing.expect_value(t, worker_actor.state.last_label, "b3")

	// 3. Pure UI_Side_Effect commands (Request_Focus, Copy_OSC52, Set_Title, Set_Cursor_Shape, Request_Quit)
	ui_cmd_request_focus(&ui_actor.state, "search_box")
	ui_cmd_copy_osc52(&ui_actor.state, "ok")
	ui_cmd_set_title(&ui_actor.state, "Bifrost Unit")
	ui_cmd_set_cursor_shape(&ui_actor.state, .Bar_Steady)
	ui_cmd_request_quit(&ui_actor.state)
	ui_actor.state.dirty = true
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 4}))
	actor.scheduler_wait_idle(&sched)

	testing.expect(t, is_focused(&ui_actor.state.input, "search_box"))
	testing.expect(t, is_editing(&ui_actor.state.input, "search_box"))
	testing.expect_value(t, guard_ctx.intercepted_count, 1)
	testing.expect_value(t, ui_actor.state.quit_requested, false)

	// Once dirty_edits is cleared, 'q' after exiting search_box (or UI_Msg_Quit) succeeds
	guard_ctx.dirty_edits = false
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Quit{}))
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 5}))
	actor.scheduler_wait_idle(&sched)
	testing.expect_value(t, ui_actor.state.quit_requested, true)

	// 4. Terminal Focus_Out (CSI O -> Focus_Event{focused = false}) clears active splitter drag + hover
	split_rect, has_split := get_rect(&ui_actor.state.layout_ctx, "main_split")
	testing.expect(t, has_split)
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Mouse{
		x      = split_rect.x,
		y      = split_rect.y + 1,
		button = 1,
		action = .Press,
	}))
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 6}))
	actor.scheduler_wait_idle(&sched)
	testing.expect_value(t, ui_actor.state.input.active_press_id, hash_id("main_split"))
	testing.expect_value(t, ui_actor.state.input.active_splitter_id, hash_id("main_split"))

	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Input{event = Focus_Event{focused = false}}))
	actor.send(&sched, ui_pid, UI_Msg(UI_Msg_Frame_Tick{tick_ns = 7}))
	actor.scheduler_wait_idle(&sched)
	testing.expect_value(t, ui_actor.state.input.active_press_id, u64(0))
	testing.expect_value(t, ui_actor.state.input.active_splitter_id, u64(0))
	testing.expect_value(t, ui_actor.state.input.hovered_id, u64(0))

	ui_coordinator_destroy(&ui_actor.state)
	actor.scheduler_stop_and_destroy(&sched)
}

@(test)
test_actor_bridge_xitdb_workspace_persistence_roundtrip_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	testing.expect_value(t, db_err, nil)
	shared := Xitdb_Shared_Handle{db = &db}

	// Session 1: configure splitter width, H/H* scope_memory, focused_id, and pinned collection/moment
	coord_a: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord_a, 100, 24, &shared, nil, context.allocator))
	coord_a.active_collection = "$metrics"
	coord_a.latest_moment_idx = 5
	coord_a.active_moment_idx = 2
	coord_a.pinned_moment     = true

	_ = get_split_size(&coord_a.input, "main_split", 25, 12, 60)
	split_slot := get_splitter_slot(&coord_a.input, hash_id("main_split"))
	split_slot.size = 38
	upsert_scope_memory(&coord_a.input, hash_id("sidebar_scope"), hash_id("btn_child"), hash_id("btn_leaf"))
	coord_a.input.focused_id = hash_id("search_box")

	testing.expect(t, save_ui_workspace_to_xitdb(&shared, &coord_a, "inspector_ws"))
	ui_coordinator_destroy(&coord_a)
	free_all(context.temp_allocator)

	// Session 2: fresh coordinator restores exact splitter size, H/H* scope memory, focus, and pinned moment
	coord_b: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord_b, 100, 24, &shared, nil, context.allocator))
	defer ui_coordinator_destroy(&coord_b)

	testing.expect(t, load_ui_workspace_from_xitdb(&shared, &coord_b, "inspector_ws"))
	free_all(context.temp_allocator)

	testing.expect_value(t, get_split_size(&coord_b.input, "main_split", 25, 12, 60), i32(38))
	testing.expect_value(t, coord_b.active_collection, "$metrics")
	testing.expect_value(t, coord_b.pinned_moment, true)
	testing.expect_value(t, coord_b.active_moment_idx, i64(2))
	testing.expect_value(t, coord_b.input.wants_focus_id, hash_id("search_box"))

	mem_entry := get_scope_memory(&coord_b.input, hash_id("sidebar_scope"))
	testing.expect(t, mem_entry != nil, "Expected H/H* scope_memory entry to round-trip")
	if mem_entry != nil {
		testing.expect_value(t, mem_entry.last_child_hash, hash_id("btn_child"))
		testing.expect_value(t, mem_entry.last_leaf_hash, hash_id("btn_leaf"))
	}
}

@(test)
test_actor_bridge_drains_side_effects_without_triggered_action_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	coord: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord, 80, 24, nil, nil, context.allocator))
	defer ui_coordinator_destroy(&coord)

	// Install a 3-phase event handler that consumes F2 (so triggered_action_id stays 0)
	// and enqueues focus + OSC 2 title side effects mid-burst.
	coord.input.event_userdata = &coord
	coord.input.event_handler = proc(
		_: u64,
		phase: Event_Phase,
		event: Input_Event,
		userdata: rawptr,
	) -> bool {
		if phase != .At_Target {
			return false
		}
		if ke, ok := event.(Key_Event); ok && ke.code == .F2 {
			c := (^UI_Coordinator_State)(userdata)
			ui_cmd_request_focus(c, "search_box")
			ui_cmd_set_title(c, "SideEffectNoAction")
			return true
		}
		return false
	}

	ui_coordinator_flush_frame(&coord)
	testing.expect(t, is_focused(&coord.input, "records_pane"))

	_ = ui_reduce_single_msg(&coord, UI_Msg_Key{code = .F2})
	ui_coordinator_flush_frame(&coord)

	testing.expect_value(t, coord.input.triggered_action_id, u64(0))
	testing.expect(t, is_focused(&coord.input, "search_box"), "Side-effect focus request must drain even when triggered_action_id == 0")
	testing.expect(t, strings.contains(strings.to_string(coord.ansi_builder), "\x1b]2;SideEffectNoAction\x07"))
}

@(test)
test_actor_bridge_filtered_slice_reslices_when_scrolled_and_multi_event_burst_render_pass_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	testing.expect_value(t, db_err, nil)
	shared := Xitdb_Shared_Handle{db = &db}

	// Populate 100 rows in $metrics, where only 2 rows contain "needle"
	tx := xitdb.tx_init(&db, -1, false, context.temp_allocator)
	sm_step := xitdb.hm("metrics")
	for i := 0; i < 100; i += 1 {
		k_str := fmt.tprintf("row:%03d", i)
		v_str := fmt.tprintf("needle_%d", i) if i < 2 else fmt.tprintf("haystack_%d", i)
		steps := [2]xitdb.Path_Step{sm_step, xitdb.sm(k_str)}
		xitdb.tx_put_steps(&tx, steps[:], v_str)
	}
	_, c_err := xitdb.tx_commit(&tx)
	testing.expect_value(t, c_err, nil)
	free_all(context.temp_allocator)

	coord: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord, 90, 24, &shared, nil, context.allocator))
	defer ui_coordinator_destroy(&coord)

	ui_set_active_collection(&coord, "$metrics")
	coord.active_moment_idx = -1

	// 1. Slice unfiltered at scroll_offset = 50
	coord.vlist.scroll_offset = 50
	coord.vlist.selected_row  = 55
	unfiltered := ui_coordinator_slice_viewport(&coord, "records_pane", 10)
	testing.expect_value(t, unfiltered.total_rows, i64(100))
	testing.expect_value(t, len(unfiltered.rows), 10)
	testing.expect_value(t, coord.vlist.scroll_offset, 50)
	free_all(context.temp_allocator)

	// 2. Apply filter matching only 2 rows while scroll_offset is still 50 (simulating typing in search_box)
	ui_apply_search_query(&coord, "needle", false)
	testing.expect_value(t, coord.vlist.scroll_offset, 50)

	filtered := ui_coordinator_slice_viewport(&coord, "records_pane", 10)
	testing.expect_value(t, filtered.total_rows, i64(2))
	testing.expect_value(t, len(filtered.rows), 2)
	testing.expect_value(t, coord.vlist.scroll_offset, 0)
	testing.expect_value(t, coord.vlist.selected_row, 1)
	free_all(context.temp_allocator)

	// 3. Multi-event burst in `ui_coordinator_flush_frame`:
	// Event 1 triggers `"burst.act"`, Event 2 is an unhandled key that clears per-resolve transient flags.
	// Custom `render_pass` must still observe `was_action_triggered(&c.input, "burst.act")` and any side effect
	// queued inside `render_pass` must be drained into `ansi_builder` on the same frame.
	_ = register_action_spec(&coord.input, nil, Action_Spec{
		action_name = "burst.act",
		chord_spec  = "<F5>",
		policy      = .Global_Always,
	})
	saw_action_in_render_pass := false
	coord.user_ptr = &saw_action_in_render_pass
	coord.render_pass = proc(c: ^UI_Coordinator_State) {
		if was_action_triggered(&c.input, "burst.act") {
			(^bool)(c.user_ptr)^ = true
			ui_cmd_set_title(c, "BurstRenderPassTitle")
		}
		ui_render_inspector_frame(c)
	}

	_ = ui_reduce_single_msg(&coord, UI_Msg_Key{code = .F5})
	_ = ui_reduce_single_msg(&coord, UI_Msg_Key{code = .F6}) // Second event in same burst
	ui_coordinator_flush_frame(&coord)

	testing.expect(t, saw_action_in_render_pass, "Custom render_pass must see accumulated triggered_action_id across multi-event burst")
	testing.expect(t, was_action_triggered(&coord.input, "burst.act"))
	testing.expect(t, strings.contains(strings.to_string(coord.ansi_builder), "\x1b]2;BurstRenderPassTitle\x07"))

	// 4. Workspace persistence preserves `user_rebound` even when rebound Vim chord matches Emacs default
	inp_save: Input_State
	_ = register_action_spec(&inp_save, nil, Action_Spec{
		action_name = "doc.open",
		chord_vim   = "o",
		chord_emacs = "<C-o>",
	})
	// User in Vim mode rebinds "doc.open" to "<C-o>" (which happens to match Emacs default), then switches to Emacs and saves
	testing.expect(t, rebind_action_chord(&inp_save, "doc.open", "<C-o>"))
	set_keymap_style(&inp_save, .Emacs)
	testing.expect(t, save_ui_workspace_to_xitdb(&db, &inp_save, "rebound_style_ws"))
	free_all(context.temp_allocator)

	inp_load: Input_State
	_ = register_action_spec(&inp_load, nil, Action_Spec{
		action_name = "doc.open",
		chord_vim   = "o",
		chord_emacs = "<C-o>",
	})
	testing.expect(t, load_ui_workspace_from_xitdb(&db, &inp_load, "rebound_style_ws"))
	testing.expect_value(t, inp_load.keymap_style, Keymap_Style.Emacs)
	testing.expect(t, inp_load.action_specs[0].user_rebound, "user_rebound flag must survive workspace save/load")
	// Switching back to Vim must keep the user's custom "<C-o>" override rather than reverting to "o"
	set_keymap_style(&inp_load, .Vim)
	testing.expect_value(t, inp_load.action_specs[0].chord_spec, "<C-o>")
}

@(test)
test_actor_bridge_mouse_motion_coalescing_and_single_pass_hover_unit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expect(t, false, fmt.tprintf("Leak: %v bytes at %v", entry.size, entry.location))
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	// 1. SGR 1003 any-event mouse tracking (`\x1b[<35;x;yM`) decodes as `Mouse_Action.Motion`
	//    and coalesces with both `.Motion` and `.Move` in `append_or_coalesce_input_event`.
	queued := make([dynamic]Input_Event, 0, 16, context.allocator)
	defer delete(queued)

	for step := 1; step <= 25; step += 1 {
		seq := fmt.tprintf("\x1b[<35;%d;%dM", step + 5, 10)
		ev, _, st := parse_ansi_input(transmute([]byte)seq, false)
		testing.expect_value(t, st, Parse_Status.Ok)
		mev, is_m := ev.(Mouse_Event)
		testing.expect(t, is_m)
		testing.expect_value(t, mev.action, Mouse_Action.Motion)
		_ = append_or_coalesce_input_event(&queued, ev)
	}
	testing.expect_value(t, len(queued), 1)
	if last_m, ok := queued[0].(Mouse_Event); ok {
		testing.expect_value(t, last_m.x, i32(29))
		testing.expect_value(t, last_m.y, i32(9))
	}

	// 2. `UI_Coordinator_State` coalesces consecutive `.Motion` / `.Move` events into a single pending input,
	//    ignores duplicate hover positions at the exact same cell, skips `render_pass` entirely when
	//    `hovered_id` / `hover_path` do not change, and executes 1 `render_pass` AFTER `resolve_input` when `hovered_id` changes.
	coord := new(UI_Coordinator_State)
	defer free(coord)
	render_passes := 0
	coord.user_ptr = &render_passes
	testing.expect(t, ui_coordinator_init(
		coord,
		80,
		24,
		nil,
		proc(c: ^UI_Coordinator_State) {
			(^int)(c.user_ptr)^ += 1
			ui_render_inspector_frame(c)
		},
		context.allocator,
	))
	defer ui_coordinator_destroy(coord)

	// Initial frame
	ui_coordinator_flush_frame(coord)
	render_passes = 0

	// First move into `sidebar_pane` (e.g. x = 3, y = 5) changes `hovered_id` from 0 -> `sidebar_pane`,
	// so `ui_coordinator_flush_frame` runs 1 `render_pass` after `resolve_input`.
	_ = ui_reduce_single_msg(coord, UI_Msg(UI_Msg_Input{
		event = Mouse_Event{x = 3, y = 5, col = 3, row = 5, action = .Motion, button = .None},
	}))
	ui_coordinator_flush_frame(coord)
	testing.expect_value(t, render_passes, 1)
	testing.expect_value(t, coord.input.hovered_id, hash_id("sidebar_pane"))

	// Now move across cells inside `records_pane` (x = 30 ..< 70, y = 8):
	// The first move into `records_pane` (x = 30) changes `hovered_id` to `records_pane` (1 render pass).
	render_passes = 0
	_ = ui_reduce_single_msg(coord, UI_Msg(UI_Msg_Input{
		event = Mouse_Event{x = 30, y = 8, col = 30, row = 8, action = .Motion, button = .None},
	}))
	ui_coordinator_flush_frame(coord)
	testing.expect_value(t, render_passes, 1)
	testing.expect_value(t, coord.input.hovered_id, hash_id("records_pane"))

	// Subsequent moves across 35 cells inside `records_pane` (x = 31 ..< 66, y = 8) keep `hovered_id == records_pane`,
	// so `ui_coordinator_flush_frame` must run 0 render passes and emit 0 ANSI bytes!
	render_passes = 0
	for x: i32 = 31; x < 66; x += 1 {
		_ = ui_reduce_single_msg(coord, UI_Msg(UI_Msg_Input{
			event = Mouse_Event{x = x, y = 8, col = i16(x), row = 8, action = .Motion, button = .None},
		}))
	}
	testing.expect_value(t, len(coord.pending_inputs), 1)
	ui_coordinator_flush_frame(coord)
	testing.expect_value(t, render_passes, 0)
	testing.expect_value(t, coord.last_ansi_bytes, 0)
	testing.expect_value(t, coord.input.mouse_pos, [2]i32{65, 8})

	// Sending another hover `.Motion` at the exact same cell `(65, 8)` is dropped by `append_or_coalesce_input_event`
	// and `ui_reduce_single_msg` before queueing.
	coord.dirty = false
	_ = append_or_coalesce_input_event(
		&queued,
		Mouse_Event{x = 29, y = 9, col = 29, row = 9, action = .Motion, button = .None},
		&coord.input,
	)
	clear(&queued)
	testing.expect(t, append_or_coalesce_input_event(
		&queued,
		Mouse_Event{x = 65, y = 8, col = 65, row = 8, action = .Motion, button = .None},
		&coord.input,
	), "Same-cell hover motion must be dropped when queue is empty")
	testing.expect_value(t, len(queued), 0)

	_ = ui_reduce_single_msg(coord, UI_Msg(UI_Msg_Input{
		event = Mouse_Event{x = 65, y = 8, col = 65, row = 8, action = .Motion, button = .None},
	}))
	testing.expect(t, !coord.dirty, "Duplicate hover motion at identical cell should not mark coordinator dirty")
	testing.expect_value(t, len(coord.pending_inputs), 0)

	// 3. One-shot edge triggers (`activated_id`, `clicked_id`, etc.) set during Frame N must be cleared
	//    before Pass #1 of Frame N+1 so a subsequent heartbeat/commit frame does not re-read a stale `activated_id`.
	seen_activated: u64 = 0
	coord.user_ptr = &seen_activated
	coord.render_pass = proc(c: ^UI_Coordinator_State) {
		if c.input.activated_id != 0 {
			(^u64)(c.user_ptr)^ = c.input.activated_id
		}
		ui_render_inspector_frame(c)
	}
	_ = ui_reduce_single_msg(coord, UI_Msg(UI_Msg_Input{
		event = Mouse_Event{x = 30, y = 8, col = 30, row = 8, action = .Press, button = .Left},
	}))
	_ = ui_reduce_single_msg(coord, UI_Msg(UI_Msg_Input{
		event = Mouse_Event{x = 30, y = 8, col = 30, row = 8, action = .Release, button = .Left},
	}))
	ui_coordinator_flush_frame(coord)
	testing.expect_value(t, coord.input.activated_id, hash_id("records_pane"))
	testing.expect_value(t, seen_activated, hash_id("records_pane"))

	// Next frame (e.g. heartbeat tick with 0 input events): Pass #1 must NOT see stale `activated_id` from prior frame
	seen_activated = 0
	coord.dirty = true
	coord.layout_dirty = true
	ui_coordinator_flush_frame(coord)
	testing.expect_value(t, seen_activated, u64(0))
	testing.expect_value(t, coord.input.activated_id, u64(0))

	// 4. `poll_next_event` (`terminal_poll_event`) automatically coalesces consecutive buffered SGR 1003
	//    hover motion sequences inside `term.read_buf` into a single `Mouse_Event` while preserving any
	//    trailing non-motion event (e.g. a click `.Press` or keystroke).
	term: Terminal
	burst_seq := "\x1b[<35;10;5M\x1b[<35;11;5M\x1b[<35;12;5M\x1b[<0;12;5M"
	copy(term.read_buf[:], transmute([]byte)burst_seq)
	term.read_len = len(burst_seq)

	ev1, has1, err1 := poll_next_event(&term, 0)
	testing.expect_value(t, err1, Terminal_Error.None)
	testing.expect(t, has1)
	if m1, ok := ev1.(Mouse_Event); ok {
		testing.expect_value(t, m1.action, Mouse_Action.Motion)
		testing.expect_value(t, m1.x, i32(11))
		testing.expect_value(t, m1.y, i32(4))
	} else {
		testing.expect(t, false, "Expected coalesced Mouse_Event(.Motion) from poll_next_event")
	}

	ev2, has2, err2 := poll_next_event(&term, 0)
	testing.expect_value(t, err2, Terminal_Error.None)
	testing.expect(t, has2)
	if m2, ok := ev2.(Mouse_Event); ok {
		testing.expect_value(t, m2.action, Mouse_Action.Press)
		testing.expect_value(t, m2.x, i32(11))
		testing.expect_value(t, m2.y, i32(4))
	} else {
		testing.expect(t, false, "Expected trailing Mouse_Event(.Press) after coalesced motion burst")
	}
	testing.expect_value(t, term.read_len, 0)
}
