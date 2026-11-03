package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "../../bifrost"
import actor "../../deps/sleipnir/actor"
import xitdb "../../deps/xitdb/xitdb"

extract_row_text :: proc(coord: ^bifrost.UI_Coordinator_State, row: int, alloc := context.temp_allocator) -> string {
	if coord == nil || row < 0 || row >= coord.rows {
		return ""
	}
	b := strings.builder_make(0, coord.cols, alloc)
	for x := 0; x < coord.cols; x += 1 {
		ch := coord.front_buf[row * coord.cols + x].ch
		if ch == 0 {
			continue
		}
		strings.write_rune(&b, ch)
	}
	return strings.trim_right_space(strings.to_string(b))
}

run_inspector :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	if db_err != nil {
		fmt.eprintf("Failed to initialize xitdb database: %v\n", db_err)
		return false
	}

	shared := bifrost.Xitdb_Shared_Handle{db = &db}

	sched: actor.Scheduler
	if actor.scheduler_init(&sched, actor.Scheduler_Config{
		num_workers    = 2,
		num_shards     = 2,
		batch_quota    = 2048,
		enable_parking = true,
	}, context.allocator) != nil {
		fmt.eprintln("Failed to initialize sleipnir scheduler")
		return false
	}

	cols := 100
	rows := 26
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			actor.scheduler_stop_and_destroy(&sched)
			fmt.eprintln("Failed to initialize raw terminal")
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(40, int(ws.width))
			rows = max(12, int(ws.height))
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	ui_actor, ui_ok := bifrost.spawn_ui_coordinator(&sched, cols, rows, &shared, nil, context.allocator)
	if !ui_ok {
		actor.scheduler_stop_and_destroy(&sched)
		return false
	}
	ui_actor.state.active_collection = "$metrics"
	ui_pid := actor.pid(ui_actor)

	worker_state := bifrost.Xitdb_Worker_State{
		shared = &shared,
		ui_pid = ui_pid,
	}
	worker_actor, w_err := actor.spawn(&sched, worker_state, bifrost.xitdb_worker_receive, 2, context.allocator)
	if w_err != nil {
		bifrost.ui_coordinator_destroy(&ui_actor.state)
		actor.scheduler_stop_and_destroy(&sched)
		return false
	}
	worker_pid := actor.pid(worker_actor)

	actor.scheduler_start(&sched)

	// Seed initial moments via background worker actor
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Transact_Script{
		script = `
			doc "bootstrap schema"
			put .metrics$metric:000000 = "boot_ok"
		`,
		tag_name = "v0.1.0",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
		map_name   = "$metrics",
		key_prefix = "metric",
		start_id   = 1,
		count      = 50,
		sorted     = true,
		tag_name   = "v0.2.0",
	}))
	actor.scheduler_wait_idle(&sched)

	if live_tty {
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)
		if ui_actor.state.last_ansi_bytes > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
		}

		for !ui_actor.state.quit_requested {
			ev, has_ev, _ := bifrost.poll_next_event(&term, 16)
			if has_ev {
				#partial switch e in ev {
				case bifrost.Key_Event:
					actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{
						code      = e.code,
						ch        = e.ch,
						ctrl      = .Ctrl in e.mods,
						alt       = .Alt in e.mods,
						shift     = .Shift in e.mods,
						super_mod = .Super in e.mods,
						is_repeat = e.action == .Repeat,
					}))
				case bifrost.Mouse_Event:
					actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Mouse{
						x      = e.x,
						y      = e.y,
						action = e.action,
						ctrl   = .Ctrl in e.mods,
						alt    = .Alt in e.mods,
						shift  = .Shift in e.mods,
					}))
				case bifrost.Resize_Event:
					actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Resize{
						cols = u16(max(2, e.width)),
						rows = u16(max(2, e.height)),
					}))
				}
			}
			actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
				tick_ns = time. tick_now()._nsec,
			}))
			actor.scheduler_wait_idle(&sched)
			if ui_actor.state.last_ansi_bytes > 0 {
				_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
			}
			free_all(context.temp_allocator)
		}
	} else {
		// Headless verification workflow:
		// 1. Render initial seeded state
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Pin to historical moment @0 while worker commits moment @2 and runs diff + Datalog
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Select_Moment{
			moment_idx = 0,
			pin        = true,
		}))
		actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
			map_name   = "$metrics",
			key_prefix = "metric",
			start_id   = 51,
			count      = 50,
			sorted     = true,
			tag_name   = "v0.3.0",
		}))
		actor.scheduler_wait_idle(&sched)

		actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
			moment_a = 0,
			moment_b = 2,
		}))
		actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $metrics[?k] = ?v",
		}))
		actor.scheduler_wait_idle(&sched)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
		actor.scheduler_wait_idle(&sched)

		// 3. Unpin ('f'), filter by prefix ("^metric:00008"), and coalesce a 1,000-message burst
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'f'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Search_Input{query = "^metric:00008"}))
		for i := 0; i < 1000; i += 1 {
			actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
				moment_idx = 2,
				slot_ptr   = 256,
				tx_id      = i64(10 + i),
				tag_name   = "burst",
			}))
		}
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 3}))
		actor.scheduler_wait_idle(&sched)

		total_moments := actor.call(
			&sched,
			worker_pid,
			bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Ping_Count{}),
			i64,
		)

		status_line := extract_row_text(&ui_actor.state, 0)
		footer_line := extract_row_text(&ui_actor.state, rows - 1)
		fmt.printf(
			"[Bifrost xitdb Inspector] moments=%d coalesced=%d frames=%d viewport_rows=%d\n",
			total_moments,
			ui_actor.state.coalesced_commits,
			ui_actor.state.total_frames,
			ui_actor.state.last_viewport_rows,
		)
		fmt.printf("  Status: %s\n", status_line)
		fmt.printf("  Footer: %s\n", footer_line)
	}

	bifrost.ui_coordinator_destroy(&ui_actor.state)
	actor.scheduler_stop_and_destroy(&sched)
	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	live_tty := false
	for arg in os.args[1:] {
		if arg == "--live-tty" {
			live_tty = true
		}
	}

	ok := run_inspector(live_tty)

	leaks := 0
	for _, entry in track.allocation_map {
		fmt.eprintf("LEAK: %v bytes allocated at %v\n", entry.size, entry.location)
		leaks += 1
	}
	for entry in track.bad_free_array {
		fmt.eprintf("BAD FREE: %p at %v\n", entry.memory, entry.location)
		leaks += 1
	}
	mem.tracking_allocator_destroy(&track)

	if !ok || leaks > 0 {
		os.exit(1)
	}
}
