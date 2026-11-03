package bifrost

import "core:fmt"
import "core:mem"
import "core:testing"
import actor "../deps/sleipnir/actor"
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
