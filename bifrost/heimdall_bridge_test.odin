package bifrost

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import actor "../deps/heimdall/deps/sleipnir/actor"
import heimdall "../deps/heimdall/heimdall"
import xitdb "../deps/xitdb/xitdb"

@(test)
test_heimdall_explicit_recorder_and_nested_pipeline_spans :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leak: %v bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	tmp_dir := ".tmp/test_heimdall_explicit"
	_ = os.remove_all(tmp_dir)
	mk_err := os.make_directory_all(tmp_dir)
	testing.expect_value(t, mk_err, nil)
	defer {
		_ = os.remove_all(tmp_dir)
	}

	prefix := fmt.tprintf("%s/bifrost_seg", tmp_dir)

	// 1. Initialize an explicit Heimdall recorder
	rec: heimdall.Recorder
	r_err := heimdall.recorder_init(&rec, heimdall.Config{
		file_prefix      = prefix,
		batches_per_file = 4,
		ring_page_count  = 4,
	}, context.allocator)
	testing.expect_value(t, r_err, nil)
	defer heimdall.recorder_destroy(&rec)

	// 2. Initialize xitdb + Sleipnir actor system + UI Coordinator + Worker
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

	ui_act, ui_ok := spawn_ui_coordinator(&sched, 96, 26, &shared, nil, context.allocator)
	testing.expect(t, ui_ok)
	ui_pid := actor.pid(ui_act)

	ui_coordinator_set_recorder(&ui_act.state, &rec)
	ui_set_active_collection(&ui_act.state, "$logs")

	w_act, w_err := actor.spawn(
		&sched,
		Xitdb_Worker_State{
			shared   = &shared,
			ui_pid   = ui_pid,
			recorder = &rec,
		},
		xitdb_worker_receive,
		1,
		context.allocator,
	)
	testing.expect_value(t, w_err, nil)
	w_pid := actor.pid(w_act)

	actor.scheduler_start(&sched)

	// 3. Dispatch background worker operations (`Commit_Batch`, `Run_Datalog`, `Diff_Moments`)
	actor.send(w_pid, Xitdb_Worker_Msg(Worker_Msg_Commit_Batch{
		map_name   = "$logs",
		key_prefix = "evt",
		start_id   = 0,
		count      = 12,
		sorted     = true,
		tag_name   = "batch_0",
	}))
	actor.send(w_pid, Xitdb_Worker_Msg(Worker_Msg_Commit_Batch{
		map_name   = "$logs",
		key_prefix = "evt",
		start_id   = 12,
		count      = 8,
		sorted     = true,
		tag_name   = "batch_1",
	}))
	actor.scheduler_wait_idle(&sched)

	actor.send(w_pid, Xitdb_Worker_Msg(Worker_Msg_Run_Datalog{
		query_source = `[:find ?k ?v :where ["$logs" ?k ?v]]`,
	}))
	actor.send(w_pid, Xitdb_Worker_Msg(Worker_Msg_Diff_Moments{
		moment_a = 0,
		moment_b = 1,
	}))
	actor.scheduler_wait_idle(&sched)

	// 4. Render frame 1, then send input key (`[` to trigger `moment.prev` action) + vsync frame tick 2
	actor.send(ui_pid, UI_Msg(UI_Msg_Frame_Tick{
		tick_ns = 100_000_000,
	}))
	actor.scheduler_wait_idle(&sched)

	actor.send(ui_pid, UI_Msg(UI_Msg_Key{
		code = .Rune,
		ch   = '[',
	}))
	actor.send(ui_pid, UI_Msg(UI_Msg_Frame_Tick{
		tick_ns = 200_000_000,
	}))
	actor.scheduler_wait_idle(&sched)

	heimdall.recorder_flush(&rec)

	stats := heimdall_snapshot_recorder_stats(&rec)
	testing.expect(t, stats.enabled)
	testing.expect(t, stats.flushed_segments >= 1)
	testing.expect_value(t, stats.dropped_records, u64(0))

	// Stop worker threads before tearing down `ui_act.state`, or copy out `ui_state` before `scheduler_stop_and_destroy` frees `ui_act`
	ui_state := ui_act.state
	ui_act.state = {}
	actor.scheduler_stop_and_destroy(&sched)
	ui_coordinator_destroy(&ui_state)

	// 5. Load emitted `.arrow` segments into `Heimdall_Segment_Store` and verify records
	store: Heimdall_Segment_Store
	testing.expect_value(t, heimdall_store_init(&store, context.allocator), nil)
	defer heimdall_store_destroy(&store)

	seg_cnt, total_rows := heimdall_store_load_prefix(&store, prefix)
	testing.expect(t, seg_cnt >= 1)
	testing.expect(t, total_rows >= 12)
	testing.expect(t, len(store.records) >= 12)

	// Verify scopes & operations were captured
	found_actor_turn   := false
	found_flush_frame  := false
	found_end_layout   := false
	found_resolve_inp  := false
	found_render_lay   := false
	found_diff_ansi    := false
	found_slice_vp     := false
	found_xitdb_slice  := false
	found_commit_batch := false
	found_run_datalog  := false
	found_diff_moments := false
	found_action_evt   := false

	flush_frame_span_id: u64 = 0
	end_layout_parent_id: u64 = 0
	render_layout_parent_id: u64 = 0

	for r in store.records {
		if r.scope == TELEMETRY_SCOPE_COORDINATOR && r.name == "actor_turn" && r.kind == .Span {
			found_actor_turn = true
		}
		if r.scope == TELEMETRY_SCOPE_COORDINATOR && r.name == "flush_frame" && r.kind == .Span {
			found_flush_frame   = true
			flush_frame_span_id = r.span_id
		}
		if r.scope == TELEMETRY_SCOPE_LAYOUT && r.name == "end_layout" && r.kind == .Span {
			found_end_layout     = true
			end_layout_parent_id = r.parent_id
		}
		if r.scope == TELEMETRY_SCOPE_INPUT && r.name == "resolve_input" && r.kind == .Span {
			found_resolve_inp = true
		}
		if r.scope == TELEMETRY_SCOPE_INPUT && r.name == "action_triggered" && r.kind == .Event {
			found_action_evt = true
		}
		if r.scope == TELEMETRY_SCOPE_RENDERER && r.name == "render_layout" && r.kind == .Span {
			found_render_lay        = true
			render_layout_parent_id = r.parent_id
		}
		if r.scope == TELEMETRY_SCOPE_RENDERER && r.name == "screen_diff_ansi" && r.kind == .Span {
			found_diff_ansi = true
		}
		if r.scope == TELEMETRY_SCOPE_COORDINATOR && r.name == "slice_viewport" && r.kind == .Span {
			found_slice_vp = true
		}
		if r.scope == TELEMETRY_SCOPE_XITDB && r.name == "xitdb_slice_viewport" && r.kind == .Span {
			found_xitdb_slice = true
		}
		if r.scope == TELEMETRY_SCOPE_XITDB && r.name == "commit_batch" && r.kind == .Span {
			found_commit_batch = true
		}
		if r.scope == TELEMETRY_SCOPE_XITDB && r.name == "run_datalog" && r.kind == .Span {
			found_run_datalog = true
		}
		if r.scope == TELEMETRY_SCOPE_XITDB && r.name == "diff_moments" && r.kind == .Span {
			found_diff_moments = true
		}
	}

	testing.expect(t, found_actor_turn)
	testing.expect(t, found_flush_frame)
	testing.expect(t, found_end_layout)
	testing.expect(t, found_resolve_inp)
	testing.expect(t, found_action_evt)
	testing.expect(t, found_render_lay)
	testing.expect(t, found_diff_ansi)
	testing.expect(t, found_slice_vp)
	testing.expect(t, found_xitdb_slice)
	testing.expect(t, found_commit_batch)
	testing.expect(t, found_run_datalog)
	testing.expect(t, found_diff_moments)

	// Verify nested span parent-child linkage (`end_layout` and `render_layout` have `parent_id == flush_frame.span_id`)
	testing.expect(t, flush_frame_span_id != 0)
	testing.expect_value(t, end_layout_parent_id, flush_frame_span_id)
	testing.expect_value(t, render_layout_parent_id, flush_frame_span_id)

	// 6. Verify `Heimdall_Segment_Store` filtering (including case-insensitive query), `span_tree_items`, series extraction, and `Tree_Node` building
	testing.expect(t, len(store.span_tree_items) >= 6)
	found_child_span_item := false
	for item in store.span_tree_items {
		if item.depth >= 1 {
			found_child_span_item = true
		}
		if item.depth == 0 && item.record.name == "flush_frame" {
			testing.expect(t, item.child_cnt >= 2)
		}
	}
	testing.expect(t, found_child_span_item)

	spans_cnt := heimdall_store_apply_filter(&store, .Spans_Only)
	testing.expect(t, spans_cnt > 0 && spans_cnt < len(store.records))

	// Case-insensitive query matching both uppercase kind labels ("span") and lowercase scopes ("RENDERER")
	ci_span_cnt := heimdall_store_apply_filter(&store, .All, "", "span")
	testing.expect_value(t, ci_span_cnt, spans_cnt)
	ci_rend_cnt := heimdall_store_apply_filter(&store, .All, "", "RENDERER")
	testing.expect(t, ci_rend_cnt >= 2)

	renderer_cnt := heimdall_store_apply_filter(&store, .All, TELEMETRY_SCOPE_RENDERER)
	testing.expect(t, renderer_cnt >= 2)
	for row_idx in 0 ..< renderer_cnt {
		r, ok := heimdall_store_get_filtered_record(&store, row_idx)
		testing.expect(t, ok)
		testing.expect_value(t, r.scope, TELEMETRY_SCOPE_RENDERER)
	}

	_ = heimdall_store_apply_filter(&store, .All)

	dur_series := heimdall_store_extract_span_durations_us(&store, 32, TELEMETRY_SCOPE_COORDINATOR)
	testing.expect(t, len(dur_series) >= 1)

	diff_series, min_v, max_v := heimdall_store_extract_metric_series(&store, "diff_cells", 32)
	testing.expect(t, len(diff_series) >= 2)
	testing.expect(t, diff_series[0] > diff_series[1])
	testing.expect(t, max_v > min_v)

	// Verify heap allocation + `heimdall_free_scope_tree` cleanup with zero leaks
	tree_nodes := heimdall_store_build_scope_tree(&store, context.allocator)
	defer heimdall_free_scope_tree(tree_nodes, context.allocator)
	testing.expect(t, len(tree_nodes) >= 5)
	testing.expect_value(t, tree_nodes[0].depth, i32(0))
	testing.expect(t, tree_nodes[0].has_children)
}

@(test)
test_heimdall_default_recorder_fallback :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leak: %v bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}
	context.allocator = mem.tracking_allocator(&track)
	defer free_all(context.temp_allocator)

	tmp_dir := ".tmp/test_heimdall_default"
	_ = os.remove_all(tmp_dir)
	mk_err := os.make_directory_all(tmp_dir)
	testing.expect_value(t, mk_err, nil)
	defer {
		_ = os.remove_all(tmp_dir)
	}

	prefix := fmt.tprintf("%s/default_seg", tmp_dir)

	rec: heimdall.Recorder
	r_err := heimdall.recorder_init(&rec, heimdall.Config{
		file_prefix      = prefix,
		batches_per_file = 4,
		ring_page_count  = 4,
	}, context.allocator)
	testing.expect_value(t, r_err, nil)
	defer heimdall.recorder_destroy(&rec)

	set_thread_default_recorder(&rec)
	defer set_thread_default_recorder(nil)

	// Run standalone `Layout_Context`, `Input_State`, and `Screen` without setting `.recorder` explicitly
	scr: Screen
	testing.expect_value(t, screen_init(&scr, 60, 16, context.allocator), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context

	inp: Input_State

	begin_frame(&scr)
	begin_layout(&ctx, 60, 16)
	if container(&ctx, "root", Box_Config{width = fixed(60), height = fixed(16)}) {
		_ = ui_button(&ctx, &scr, "btn_ok", Button_Spec{label = "Confirm"})
	}
	end_layout(&ctx)
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Enter, action = .Press}))
	apply_input_highlights(&scr, &ctx, &inp)
	render_layout(&scr, &ctx)

	ansi_b := strings.builder_make(0, 1024, context.temp_allocator)
	_ = screen_diff_ansi(&scr, &ansi_b)

	heimdall.recorder_flush(&rec)

	store: Heimdall_Segment_Store
	testing.expect_value(t, heimdall_store_init(&store, context.allocator), nil)
	defer heimdall_store_destroy(&store)

	seg_cnt, total_rows := heimdall_store_load_prefix(&store, prefix)
	testing.expect(t, seg_cnt >= 1)
	testing.expect(t, total_rows >= 5)
	testing.expect(t, len(store.records) >= 5)
}
