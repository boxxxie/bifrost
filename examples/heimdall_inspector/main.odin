package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "../../bifrost"
import actor "../../deps/heimdall/deps/sleipnir/actor"
import heimdall "../../deps/heimdall/heimdall"
import xitdb "../../deps/xitdb/xitdb"

Heimdall_Inspector_App :: struct {
	prefix:         string,
	recorder:       ^heimdall.Recorder,
	store:          bifrost.Heimdall_Segment_Store,
	filter_kind:    bifrost.Heimdall_Filter_Kind,
	scope_buf:      [64]u8, // Stored by value (not zero-copy pointer) so reloads across new scopes remain stable
	scope_len:      int,
	pending_reload: bool,   // Deferred reload flag so `recorder_flush` runs outside `actor_turn` / `flush_frame` spans
}

active_inspector_scope :: proc "contextless" (app: ^Heimdall_Inspector_App) -> string {
	if app == nil || app.scope_len <= 0 {
		return ""
	}
	return string(app.scope_buf[:app.scope_len])
}

set_inspector_scope :: proc "contextless" (app: ^Heimdall_Inspector_App, scope: string) {
	if app == nil || len(scope) == 0 {
		if app != nil {
			app.scope_len = 0
		}
		return
	}
	n := min(len(scope), len(app.scope_buf))
	copy(app.scope_buf[:n], scope[:n])
	app.scope_len = n
}

filter_kind_name :: proc "contextless" (k: bifrost.Heimdall_Filter_Kind) -> string {
	switch k {
	case .All:          return "ALL"
	case .Spans_Only:   return "SPANS"
	case .Metrics_Only: return "METRICS"
	case .Events_Only:  return "EVENTS"
	case .Errors_Only:  return "ERRORS"
	}
	return "ALL"
}

refresh_inspector_store :: proc(app: ^Heimdall_Inspector_App) {
	if app == nil || app.recorder == nil {
		return
	}
	heimdall.recorder_flush(app.recorder)
	_, _ = bifrost.heimdall_store_load_prefix(&app.store, app.prefix)

	scope_filter := active_inspector_scope(app)
	if len(scope_filter) > 0 {
		found := false
		for stat in app.store.scope_stats {
			if stat.scope == scope_filter {
				found = true
				break
			}
		}
		if !found {
			app.scope_len = 0
			scope_filter  = ""
		}
	}
	_ = bifrost.heimdall_store_apply_filter(&app.store, app.filter_kind, scope_filter, "")
}

render_heimdall_inspector_pass :: proc(coord: ^bifrost.UI_Coordinator_State) {
	app := (^Heimdall_Inspector_App)(coord.user_ptr)
	if app == nil {
		return
	}

	coord.use_widget_pipeline = true
	bifrost.begin_frame(&coord.screen)
	bifrost.begin_layout(&coord.layout_ctx, i32(coord.cols), i32(coord.rows))

	rec_stats := bifrost.heimdall_snapshot_recorder_stats(app.recorder)
	scope_filter := active_inspector_scope(app)
	if len(scope_filter) == 0 {
		scope_filter = "ALL SCOPES"
	}

	if bifrost.container(
		&coord.layout_ctx,
		"hm_inspector_root",
		bifrost.Box_Config{
			dir         = .Column,
			width       = bifrost.fixed(i32(coord.cols)),
			height      = bifrost.fixed(i32(coord.rows)),
			focus_flags = {.Focus_Scope},
			focus_scope = true,
		},
	) {
		// 1. Header Bar
		header_str := fmt.tprintf(
			"BIFROST x HEIMDALL TELEMETRY INSPECTOR | backend=%s segs=%d rows=%d (filtered=%d) | filter=%s scope=%s",
			bifrost.heimdall_backend_label(rec_stats.backend),
			app.store.segment_count,
			len(app.store.records),
			len(app.store.filtered_idxs),
			filter_kind_name(app.filter_kind),
			scope_filter,
		)
		coord.screen.paints[bifrost.hash_id("hm_header")] = bifrost.Paint_Spec{
			text    = header_str,
			fg      = bifrost.rgb(230, 245, 255),
			bg      = bifrost.rgb(22, 34, 56),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "hm_header", i32(len(header_str)), 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_str,
		})

		// 2. Top Analytics Row (Sparkline of Span Durations + Braille Canvas of Diff Cells)
		chart_h: i32 = 4
		if bifrost.container(
			&coord.layout_ctx,
			"hm_charts_row",
			bifrost.Box_Config{
				dir    = .Row,
				width  = bifrost.grow(1),
				height = bifrost.fixed(chart_h),
			},
		) {
			raw_scope_filter := active_inspector_scope(app)
			durs := bifrost.heimdall_store_extract_span_durations_us(&app.store, 36, raw_scope_filter)
			max_dur_ns := app.store.max_duration_ns
			if len(raw_scope_filter) > 0 {
				for st in app.store.scope_stats {
					if st.scope == raw_scope_filter {
						max_dur_ns = st.max_dur_ns
						break
					}
				}
			}
			_ = bifrost.ui_sparkline(
				&coord.layout_ctx,
				&coord.screen,
				"hm_span_spark",
				durs,
				bifrost.Sparkline_Config{
					title     = fmt.tprintf("Span Durations us (max %d us)", max_dur_ns / 1000),
					width     = bifrost.grow(1),
					height    = bifrost.fixed(chart_h),
					border    = .Plain,
					fg        = bifrost.rgb(110, 225, 165),
					border_fg = bifrost.rgb(75, 100, 130),
				},
			)

			canvas: bifrost.Braille_Canvas
			_ = bifrost.canvas_init(&canvas, 34, 2, context.temp_allocator)
			series, min_v, max_v := bifrost.heimdall_store_extract_metric_series(&app.store, "ansi_diff_bytes", 36)
			if len(series) > 0 {
				bifrost.canvas_draw_series(&canvas, series, min_v, max_v, bifrost.rgb(120, 195, 255))
			}
			_ = bifrost.ui_canvas(
				&coord.layout_ctx,
				&coord.screen,
				"hm_metric_canvas",
				bifrost.Canvas_Config{
					title     = "ANSI Diff Bytes (Braille Series)",
					canvas    = &canvas,
					width     = bifrost.fixed(canvas.cell_w + 2),
					height    = bifrost.fixed(chart_h),
					border    = .Plain,
					fg        = bifrost.rgb(120, 195, 255),
					border_fg = bifrost.rgb(75, 100, 130),
				},
			)
		}

		// 3. Main Body Split (Left: Collapsible Scope & Operation Tree | Right: Virtualized 11-Column Record Table)
		body_h := max(i32(6), i32(coord.rows) - (chart_h + 3))
		if bifrost.ui_scope(
			&coord.layout_ctx,
			&coord.screen,
			"hm_body_scope",
			bifrost.Scope_Config{
				dir    = .Row,
				width  = bifrost.grow(1),
				height = bifrost.fixed(body_h),
			},
		) {
			tree_nodes := bifrost.heimdall_store_build_scope_tree(&app.store, context.temp_allocator)
			tslice: bifrost.Tree_Slice
			_ = bifrost.ui_tree(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"hm_scope_tree",
				tree_nodes,
				bifrost.Tree_Config{
					title     = "Telemetry Scopes & Ops",
					width     = bifrost.fixed(34),
					height    = bifrost.grow(1),
					border    = .Plain,
					fg        = bifrost.rgb(210, 225, 240),
					border_fg = bifrost.rgb(80, 105, 135),
				},
				&tslice,
			)

			visible_rows := max(1, int(body_h) - 2)
			total_filtered := len(app.store.filtered_idxs)
			bifrost.ui_sync_vlist_to_slot(coord, "records_pane", total_filtered, visible_rows)

			vslice: bifrost.Virtual_Slice
			if bifrost.ui_virtual_list(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"records_pane",
				i32(total_filtered),
				bifrost.Virtual_List_Config{
					title         = fmt.tprintf("Arrow Telemetry Records (%d shown / %d total)", total_filtered, len(app.store.records)),
					width         = bifrost.grow(1),
					height        = bifrost.grow(1),
					border        = .Plain,
					fg            = bifrost.rgb(215, 225, 235),
					border_fg     = bifrost.rgb(80, 105, 135),
					fallback_rows = i32(visible_rows),
					focus_flags   = {.Focusable, .Default_Focus},
				},
				&vslice,
			) {
				for vis_row := vslice.start_row; vis_row < vslice.end_row; vis_row += 1 {
					rec, r_ok := bifrost.heimdall_store_get_filtered_record(&app.store, int(vis_row))
					if !r_ok {
						continue
					}
					is_sel := int(vis_row) == coord.vlist.selected_row
					row_id := fmt.tprintf("hm_row_%d", vis_row)
					dur_us := max(i64(0), rec.duration_ns) / 1000
					ts_ms  := (max(i64(0), rec.timestamp_ns) / 1_000_000) % 100_000
					row_line := fmt.tprintf(
						"%s %04d | %-9.9s | %-3.3s | %-19.19s | %-16.16s | span=%04d<-%04d | t=%04d | +%05dms | %5dus | %6.1f | a=%d",
						">" if is_sel else " ",
						vis_row,
						bifrost.heimdall_kind_label(rec.kind),
						bifrost.heimdall_status_label(rec.status),
						rec.scope,
						rec.name,
						rec.span_id,
						rec.parent_id,
						rec.thread_id % 10_000,
						ts_ms,
						dur_us,
						rec.value_f64,
						rec.attr_i64,
					)
					coord.screen.paints[bifrost.hash_id(row_id)] = bifrost.Paint_Spec{
						text    = row_line,
						fg      = bifrost.rgb(255, 255, 185) if is_sel else (bifrost.rgb(255, 135, 135) if rec.status == .Error else bifrost.rgb(210, 220, 230)),
						bg      = bifrost.rgb(45, 68, 102) if is_sel else bifrost.Color{},
						style   = {.Bold} if is_sel else {},
						fill_bg = is_sel,
					}
					_ = bifrost.leaf(&coord.layout_ctx, row_id, bifrost.string_display_width(row_line), 1, bifrost.Box_Config{
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						text   = row_line,
					})
				}
			}
		}

		// 4. Footer Status & Shortcut Bar
		footer_str := fmt.tprintf(
			"Spans=%d Tree=%d Counters=%d Gauges=%d Hists=%d Events=%d Errs=%d Drop=%d | [r] Reload  [k] Kind  [s] Scope  [q] Quit",
			app.store.total_spans,
			len(app.store.span_tree_items),
			app.store.total_counters,
			app.store.total_gauges,
			app.store.total_hists,
			app.store.total_events,
			app.store.total_errors,
			rec_stats.dropped_records,
		)
		coord.screen.paints[bifrost.hash_id("hm_footer")] = bifrost.Paint_Spec{
			text    = footer_str,
			fg      = bifrost.rgb(185, 205, 225),
			bg      = bifrost.rgb(18, 25, 38),
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "hm_footer", i32(len(footer_str)), 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = footer_str,
		})

		bifrost.ui_key_hint_bar(&coord.layout_ctx, &coord.screen, &coord.input, "hm_hint_bar")
	}

	bifrost.end_layout(&coord.layout_ctx)
}

on_action_reload :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	// Reload any already-flushed `.arrow` segments immediately for same-frame visual feedback,
	// and mark `pending_reload = true` so the outer loop flushes the live recorder *after*
	// `ui_coordinator_receive`'s `actor_turn` and `flush_frame` spans have closed.
	refresh_inspector_store(app)
	app.pending_reload = true
	total_filtered := len(app.store.filtered_idxs)
	if coord.vlist.selected_row >= total_filtered {
		coord.vlist.selected_row = max(0, total_filtered - 1)
	}
	if coord.vlist.scroll_offset > coord.vlist.selected_row {
		coord.vlist.scroll_offset = coord.vlist.selected_row
	}
	bifrost.ui_sync_vlist_to_slot(coord, "records_pane", total_filtered, coord.vlist.viewport_rows)
	coord.dirty = true
}

on_action_cycle_kind :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	next_ord := (int(app.filter_kind) + 1) % len(bifrost.Heimdall_Filter_Kind)
	app.filter_kind = bifrost.Heimdall_Filter_Kind(next_ord)
	scope_filter := active_inspector_scope(app)
	_ = bifrost.heimdall_store_apply_filter(&app.store, app.filter_kind, scope_filter, "")
	coord.vlist.selected_row  = 0
	coord.vlist.scroll_offset = 0
	bifrost.ui_sync_vlist_to_slot(coord, "records_pane", len(app.store.filtered_idxs), coord.vlist.viewport_rows)
	coord.dirty               = true
}

on_action_cycle_scope :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	cur_scope := active_inspector_scope(app)
	cur_idx := -1
	for stat, idx in app.store.scope_stats {
		if stat.scope == cur_scope {
			cur_idx = idx
			break
		}
	}
	if len(app.store.scope_stats) == 0 || cur_idx + 1 >= len(app.store.scope_stats) {
		set_inspector_scope(app, "")
	} else {
		set_inspector_scope(app, app.store.scope_stats[cur_idx + 1].scope)
	}
	scope_filter := active_inspector_scope(app)
	_ = bifrost.heimdall_store_apply_filter(&app.store, app.filter_kind, scope_filter, "")
	coord.vlist.selected_row  = 0
	coord.vlist.scroll_offset = 0
	bifrost.ui_sync_vlist_to_slot(coord, "records_pane", len(app.store.filtered_idxs), coord.vlist.viewport_rows)
	coord.dirty               = true
}

extract_row_text :: proc(coord: ^bifrost.UI_Coordinator_State, row: int, alloc := context.temp_allocator) -> string {
	if coord == nil || row < 0 || row >= coord.rows {
		return ""
	}
	b := strings.builder_make(0, coord.cols, alloc)
	for x := 0; x < coord.cols; x += 1 {
		cell := coord.front_buf[row * coord.cols + x]
		if cell.width == 0 || cell.ch == 0 {
			continue
		}
		strings.write_rune(&b, cell.ch)
	}
	return strings.trim_right_space(strings.to_string(b))
}

run_heimdall_inspector :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	tmp_dir := ".tmp/heimdall_inspector_demo"
	_ = os.remove_all(tmp_dir)
	if os.make_directory_all(tmp_dir) != nil {
		fmt.eprintln("Failed to create temporary directory for Heimdall segments")
		return false
	}
	defer {
		_ = os.remove_all(tmp_dir)
	}
	prefix := ".tmp/heimdall_inspector_demo/telemetry"

	rec: heimdall.Recorder
	if heimdall.recorder_init(&rec, heimdall.Config{
		file_prefix      = prefix,
		batches_per_file = 4,
		ring_page_count  = 4,
	}, context.allocator) != nil {
		fmt.eprintln("Failed to initialize Heimdall recorder")
		return false
	}
	defer heimdall.recorder_destroy(&rec)

	app: Heimdall_Inspector_App
	app.prefix   = prefix
	app.recorder = &rec
	if bifrost.heimdall_store_init(&app.store, context.allocator) != nil {
		return false
	}
	defer bifrost.heimdall_store_destroy(&app.store)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	if db_err != nil {
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
		return false
	}
	ui_actor: ^actor.Actor(bifrost.UI_Coordinator_State, bifrost.UI_Msg)
	defer {
		actor.scheduler_wait_idle(&sched)
		ui_state: bifrost.UI_Coordinator_State
		has_ui := ui_actor != nil
		if has_ui {
			ui_state = ui_actor.state
			ui_actor.state = {}
		}
		actor.scheduler_stop_and_destroy(&sched)
		if has_ui {
			bifrost.ui_coordinator_destroy(&ui_state)
		}
	}

	cols := 116
	rows := 28
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(60, int(ws.width))
			rows = max(16, int(ws.height))
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	ui_ok: bool
	ui_actor, ui_ok = bifrost.spawn_ui_coordinator(
		&sched,
		cols,
		rows,
		&shared,
		render_heimdall_inspector_pass,
		context.allocator,
	)
	if !ui_ok {
		return false
	}
	ui_actor.state.user_ptr = &app
	bifrost.ui_coordinator_set_recorder(&ui_actor.state, &rec)
	ui_pid := actor.pid(ui_actor)

	_ = bifrost.bind_chord(&ui_actor.state.input, "r", "heimdall.reload", .Root_And_Scopes)
	_ = bifrost.bind_chord(&ui_actor.state.input, "k", "heimdall.cycle_kind", .Root_And_Scopes)
	_ = bifrost.bind_chord(&ui_actor.state.input, "s", "heimdall.cycle_scope", .Root_And_Scopes)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.reload", on_action_reload, &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.cycle_kind", on_action_cycle_kind, &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.cycle_scope", on_action_cycle_scope, &app)

	worker_actor, w_err := actor.spawn(
		&sched,
		bifrost.Xitdb_Worker_State{
			shared   = &shared,
			ui_pid   = ui_pid,
			recorder = &rec,
		},
		bifrost.xitdb_worker_receive,
		2,
		context.allocator,
	)
	if w_err != nil {
		return false
	}
	worker_pid := actor.pid(worker_actor)

	actor.scheduler_start(&sched)

	// Seed workload so Heimdall captures actor turns, xitdb commits, Datalog queries, diffs, and UI frames
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
		map_name   = "$services",
		key_prefix = "svc",
		start_id   = 1,
		count      = 25,
		sorted     = true,
		tag_name   = "v1",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
		map_name   = "$services",
		key_prefix = "svc",
		start_id   = 26,
		count      = 25,
		sorted     = true,
		tag_name   = "v2",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
		query_source = "find ?k, ?v where $services[?k] = ?v",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
		moment_a = 0,
		moment_b = 1,
	}))
	actor.scheduler_wait_idle(&sched)

	if live_tty {
		refresh_inspector_store(&app)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)
		if ui_actor.state.last_ansi_bytes > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
		}

		boot_tick := time.tick_now()
		last_tick := boot_tick
		for !ui_actor.state.quit_requested {
			ev, has_ev, _ := bifrost.poll_next_event(&term, 16)
			if has_ev {
				actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Input{event = ev}))
			}
			now := time.tick_now()
			if has_ev || time.tick_diff(last_tick, now) >= 16 * time.Millisecond {
				last_tick = now
				actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
					tick_ns = max(1, i64(time.tick_diff(boot_tick, now))),
				}))
				actor.scheduler_wait_idle(&sched)
				if app.pending_reload {
					app.pending_reload = false
					refresh_inspector_store(&app)
					ui_actor.state.dirty = true
					actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
						tick_ns = max(1, i64(time.tick_since(boot_tick))),
					}))
					actor.scheduler_wait_idle(&sched)
				}
				if ui_actor.state.last_ansi_bytes > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
				}
			}
			free_all(context.temp_allocator)
		}
	} else {
		// Headless verification:
		// 1. Render Frame 1 so UI Coordinator + Layout + Input + Renderer emit spans & metrics
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Press 'r' to reload segments, then complete the deferred post-turn flush so Frame 1's
		//    closed `actor_turn` and `flush_frame` spans are also captured in `.arrow` segments
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'r'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
		actor.scheduler_wait_idle(&sched)
		if app.pending_reload {
			app.pending_reload = false
			refresh_inspector_store(&app)
		}

		// 3. Press 'k' to filter to SPANS only, then render Frame 3
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'k'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 3}))
		actor.scheduler_wait_idle(&sched)

		header_line := extract_row_text(&ui_actor.state, 0)
		footer_line := extract_row_text(&ui_actor.state, rows - 2)
		fmt.printf(
			"[Bifrost x Heimdall Inspector] segments=%d total_records=%d filtered_spans=%d scopes=%d frames=%d\n",
			app.store.segment_count,
			len(app.store.records),
			len(app.store.filtered_idxs),
			len(app.store.scope_stats),
			ui_actor.state.total_frames,
		)
		fmt.printf("  Header: %s\n", header_line)
		fmt.printf("  Footer: %s\n", footer_line)

		if app.store.segment_count < 1 || len(app.store.records) < 10 || len(app.store.filtered_idxs) < 5 {
			return false
		}
	}

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

	ok := run_heimdall_inspector(live_tty)

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
