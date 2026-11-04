package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "../../bifrost"
import actor "../../deps/sleipnir/actor"
import xitdb "../../deps/xitdb/xitdb"

Service_Info :: struct {
	name:   string,
	rps:    int,
	p99_ms: int,
	status: string,
}

@(rodata)
SERVICES := [4]Service_Info{
	{name = "api-gateway", rps = 4820, p99_ms = 4,  status = "HEALTHY"},
	{name = "auth-rebac",  rps = 3190, p99_ms = 7,  status = "HEALTHY"},
	{name = "xitdb-store", rps = 8450, p99_ms = 2,  status = "OPTIMAL"},
	{name = "actor-pool",  rps = 12600, p99_ms = 1, status = "HEALTHY"},
}

@(rodata)
LOG_LEVELS := [4]string{
	"INFO",
	"INFO",
	"WARN",
	"ERROR",
}

@(rodata)
LOG_MESSAGES := [8]string{
	"accepted TLS 1.3 session and routed RPC batch",
	"evaluated Zanzibar ReBAC check in 180us",
	"committed B+Tree copy-on-write root slot",
	"drained Vyukov MPSC mailbox burst (coalesced)",
	"high tail latency detected on shard replica #2",
	"retrying transient peer heartbeat timeout",
	"completed Datalog fixed-point join evaluation",
	"checkpointed immutable moment snapshot",
}

// =============================================================================
// Background Sleipnir Log Producer Actor
// =============================================================================

Log_Batch_Request :: struct {
	start_seq: int,
	count:     int,
	tag_name:  string,
}

Log_Producer_Msg :: union {
	Log_Batch_Request,
}

Log_Producer_State :: struct {
	shared:       ^bifrost.Xitdb_Shared_Handle,
	ui_pid:       actor.PID(bifrost.UI_Msg),
	batches_sent: int,
	logs_written: int,
}

log_producer_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(Log_Producer_State, Log_Producer_Msg),
	msg: ^Log_Producer_Msg,
) {
	state := &self.state
	if state.shared == nil || state.shared.db == nil || msg == nil {
		return
	}

	switch m in msg^ {
	case Log_Batch_Request:
		sync.rw_mutex_lock(&state.shared.rw_lock)
		tx := xitdb.tx_init(state.shared.db, -1, false, context.temp_allocator)
		if len(m.tag_name) > 0 {
			xitdb.tx_doc(&tx, m.tag_name)
		}
		map_step := xitdb.hm("logs")
		for i := 0; i < m.count; i += 1 {
			seq := m.start_seq + i
			lvl := LOG_LEVELS[seq % len(LOG_LEVELS)]
			svc := SERVICES[seq % len(SERVICES)].name
			txt := LOG_MESSAGES[seq % len(LOG_MESSAGES)]

			k_str := fmt.aprintf("log:%06d", seq, allocator = context.temp_allocator)
			v_str := fmt.aprintf("%-5s | %-11s | %s", lvl, svc, txt, allocator = context.temp_allocator)
			steps := [2]xitdb.Path_Step{map_step, xitdb.sm(k_str)}
			xitdb.tx_put_steps(&tx, steps[:], v_str)
		}
		report, c_err := xitdb.tx_commit(&tx)
		latest_idx := report.moment_index
		slot_val: i64 = 0
		if c_err == nil {
			if slot, s_err := xitdb.cursor_slot(report.after.cursor); s_err == nil {
				slot_val = slot.value
			}
		}
		sync.rw_mutex_unlock(&state.shared.rw_lock)

		if c_err == nil {
			state.batches_sent += 1
			state.logs_written += m.count
			if state.ui_pid.ref != nil {
				actor.send(
					ctx,
					state.ui_pid,
					bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
						moment_idx = latest_idx,
						slot_ptr   = slot_val,
						tx_id      = latest_idx + 1,
						tag_name   = m.tag_name,
					}),
				)
			}
		}
	}
}

// =============================================================================
// Custom Immediate-Mode Render Pass for UI_Coordinator_State
// =============================================================================

handle_monitor_shortcuts :: proc(coord: ^bifrost.UI_Coordinator_State) {
	if bifrost.was_action_triggered(&coord.input, "app.quit") {
		coord.quit_requested = true
		return
	}
	if bifrost.was_action_triggered(&coord.input, "filter.focus") {
		coord.input.wants_focus_id = bifrost.hash_id("search_box")
		return
	}
	if bifrost.was_activated(&coord.input, "btn_lvl_all") || bifrost.was_action_triggered(&coord.input, "filter.all") {
		coord.filter.kind   = .None
		coord.filter.needle = ""
		coord.filter.prefix = ""
		bifrost.set_text(&coord.input, "search_box", "")
	} else if bifrost.was_activated(&coord.input, "btn_lvl_err") || bifrost.was_action_triggered(&coord.input, "filter.error") {
		coord.filter.kind   = .Substring
		coord.filter.needle = "ERROR"
		coord.filter.prefix = ""
		bifrost.set_text(&coord.input, "search_box", "ERROR")
	} else if bifrost.was_activated(&coord.input, "btn_lvl_warn") || bifrost.was_action_triggered(&coord.input, "filter.warn") {
		coord.filter.kind   = .Substring
		coord.filter.needle = "WARN"
		coord.filter.prefix = ""
		bifrost.set_text(&coord.input, "search_box", "WARN")
	} else if bifrost.was_activated(&coord.input, "btn_pin_toggle") || bifrost.was_action_triggered(&coord.input, "moment.follow") {
		coord.pinned_moment     = false
		coord.active_moment_idx = coord.latest_moment_idx
	} else if bifrost.was_action_triggered(&coord.input, "moment.prev") {
		coord.pinned_moment     = true
		coord.active_moment_idx = max(0, coord.active_moment_idx - 1)
	} else if bifrost.was_action_triggered(&coord.input, "moment.next") {
		if coord.active_moment_idx + 1 >= coord.latest_moment_idx {
			coord.pinned_moment     = false
			coord.active_moment_idx = coord.latest_moment_idx
		} else {
			coord.pinned_moment     = true
			coord.active_moment_idx += 1
		}
	}

	// Sync live text input edits in `search_box` to `coord.filter`
	if bifrost.was_text_changed(&coord.input, "search_box") {
		q := bifrost.get_text(&coord.input, "search_box")
		n := min(len(q), len(coord.search_buf))
		if n > 0 {
			copy(coord.search_buf[:n], transmute([]u8)q[:n])
		}
		coord.search_len = n
		q_slice := string(coord.search_buf[:n])
		if strings.has_prefix(q_slice, "^") {
			coord.filter.kind   = .Key_Prefix
			coord.filter.prefix = q_slice[1:]
			coord.filter.needle = ""
		} else if len(q_slice) > 0 {
			coord.filter.kind   = .Substring
			coord.filter.needle = q_slice
			coord.filter.prefix = ""
		} else {
			coord.filter.kind   = .None
			coord.filter.prefix = ""
			coord.filter.needle = ""
		}
	}
}

render_log_monitor_frame :: proc(coord: ^bifrost.UI_Coordinator_State) {
	coord.use_widget_pipeline = true
	handle_monitor_shortcuts(coord)

	w := i32(coord.cols)
	h := i32(coord.rows)
	bg_dark  := bifrost.rgb(18, 22, 30)
	panel_bg := bifrost.rgb(24, 30, 42)
	bar_bg   := bifrost.rgb(30, 40, 58)
	text_fg  := bifrost.rgb(215, 225, 240)
	muted_fg := bifrost.rgb(135, 155, 180)
	accent   := bifrost.rgb(115, 195, 255)

	bifrost.begin_frame(&coord.screen, bg_dark)
	bifrost.begin_layout(&coord.layout_ctx, w, h)

	if bifrost.container(&coord.layout_ctx, "monitor_root", bifrost.Box_Config{
		dir    = .Column,
		width  = bifrost.fixed(w),
		height = bifrost.fixed(h),
	}) {
		// 1. Top Header Bar
		mode_str := "PINNED" if coord.pinned_moment else "LIVE STREAM"
		header_str := fmt.tprintf(
			" BIFROST LOG & METRICS MONITOR | %s @%d (latest @%d) | Coalesced: %d | Frames: %d",
			mode_str,
			coord.active_moment_idx,
			coord.latest_moment_idx,
			coord.coalesced_commits,
			coord.total_frames + 1,
		)
		bifrost.set_paint(&coord.screen, "header_bar", bifrost.Paint_Spec{
			text    = header_str,
			fg      = bifrost.rgb(255, 225, 120) if coord.pinned_moment else accent,
			bg      = bar_bg,
			style   = {.Bold},
			fill_bg = true,
		})
		bifrost.leaf(&coord.layout_ctx, "header_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_str,
		})

		// 2. Service Telemetry Strip (4 Grow(1) cards)
		if bifrost.container(&coord.layout_ctx, "telemetry_row", bifrost.Box_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.fixed(3),
			gap    = 1,
		}) {
			for svc, idx in SERVICES {
				card_id := fmt.tprintf("svc_card_%d", idx)
				rps_val := svc.rps + int(coord.active_moment_idx) * 35
				card_txt := fmt.tprintf("%d req/s | p99:%dms", rps_val, svc.p99_ms)
				bifrost.set_paint(&coord.screen, card_id, bifrost.Paint_Spec{
					title       = fmt.tprintf("%s [%s]", svc.name, svc.status),
					text        = card_txt,
					fg          = text_fg,
					bg          = panel_bg,
					border_fg   = bifrost.rgb(80, 145, 115),
					title_fg    = bifrost.rgb(130, 230, 165),
					title_style = {.Bold},
					fill_bg     = true,
				})
				bifrost.leaf(&coord.layout_ctx, card_id, 16, 3, bifrost.Box_Config{
					width       = bifrost.grow(1),
					height      = bifrost.fixed(3),
					border      = .Rounded,
					main_align  = .Center,
					cross_align = .Center,
				})
			}
		}

		// 3. Main Split Body (Filter Sidebar + Interactive Splitter + Virtualized Log Stream)
		body_h := max(i32(6), h - 5)
		if bifrost.container(&coord.layout_ctx, "monitor_body", bifrost.Box_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.fixed(body_h),
		}) {
			sidebar_w := bifrost.get_split_size(&coord.input, "monitor_split", 28, 22, max(26, w - 36))

			bifrost.set_paint(&coord.screen, "filter_sidebar", bifrost.Paint_Spec{
				title       = "Stream Controls",
				fg          = text_fg,
				bg          = panel_bg,
				border_fg   = bifrost.rgb(75, 95, 125),
				title_fg    = accent,
				title_style = {.Bold},
				fill_bg     = true,
			})
			if bifrost.container(&coord.layout_ctx, "filter_sidebar", bifrost.Box_Config{
				dir         = .Column,
				width       = bifrost.fixed(sidebar_w),
				height      = bifrost.grow(1),
				padding     = bifrost.pad_xy(1, 0),
				gap         = 1,
				border      = .Plain,
				focus_scope = true,
			}) {
				bifrost.ui_label(&coord.layout_ctx, &coord.screen, "lbl_q", "Filter (^prefix or text):", muted_fg)
				bifrost.ui_text_input(&coord.layout_ctx, &coord.screen, &coord.input, "search_box", bifrost.Text_Input_Config{
					placeholder    = "e.g. ERROR or auth-rebac...",
					linked_list_id = "log_stream_pane",
					width          = bifrost.grow(1),
					height         = bifrost.fixed(1),
					fg             = text_fg,
					bg             = bar_bg,
					placeholder_fg = muted_fg,
				})

				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_all", bifrost.Button_Spec{
					label  = "Show ALL Logs",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = text_fg,
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_warn", bifrost.Button_Spec{
					label  = "Filter: WARN Only",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(250, 200, 95),
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_err", bifrost.Button_Spec{
					label  = "Filter: ERROR Only",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(250, 115, 120),
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_pin_toggle", bifrost.Button_Spec{
					label  = "Follow Live Head (f)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(130, 230, 165),
					bg     = bar_bg,
				})
			}

			bifrost.ui_splitter(&coord.layout_ctx, &coord.screen, &coord.input, "monitor_split", bifrost.Splitter_Config{
				dir          = .Row,
				default_size = 28,
				min_first    = 22,
				min_second   = 30,
				fg           = muted_fg,
				bg           = bg_dark,
				active_fg    = accent,
			})

			// Zero-Copy xitdb Log Stream Slice
			visible_rows := max(1, int(body_h) - 2)
			coord.vlist.viewport_rows = visible_rows

			slice: bifrost.Xitdb_Viewport_Slice
			if coord.shared_db != nil && coord.shared_db.db != nil {
				sync.rw_mutex_shared_lock(&coord.shared_db.rw_lock)
				total_cnt, cnt_err := bifrost.xitdb_read_collection_count(
					coord.shared_db.db,
					coord.active_moment_idx,
					coord.active_collection,
				)
				if cnt_err == nil {
					coord.vlist.total_rows = int(total_cnt)
					bifrost.ui_virtual_list_clamp(&coord.vlist)
					slice, _ = bifrost.xitdb_slice_viewport(
						coord.shared_db.db,
						coord.active_moment_idx,
						coord.active_collection,
						i64(coord.vlist.scroll_offset),
						i64(visible_rows),
						coord.filter,
						context.temp_allocator,
					)
				}
				sync.rw_mutex_shared_unlock(&coord.shared_db.rw_lock)
			}
			coord.last_viewport_rows = len(slice.rows)

			vslice: bifrost.Virtual_Slice
			if bifrost.ui_virtual_list(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"log_stream_pane",
				i32(slice.total_rows),
				bifrost.Virtual_List_Config{
					title         = fmt.tprintf("Structured Log Stream (%d total in %s, showing %d)", slice.total_rows, coord.active_collection, len(slice.rows)),
					width         = bifrost.grow(1),
					height        = bifrost.grow(1),
					border        = .Plain,
					fg            = text_fg,
					bg            = panel_bg,
					border_fg     = bifrost.rgb(75, 95, 125),
					title_fg      = accent,
					fallback_rows = i32(visible_rows),
				},
				&vslice,
			) {
				for row_i in 0 ..< len(slice.rows) {
					rv := slice.rows[row_i]
					is_sel := int(rv.logical_index) == coord.vlist.selected_row
					row_id := fmt.tprintf("log_row_%d", row_i)
					row_line := fmt.tprintf(
						"%s %-10s | %s",
						"▸" if is_sel else " ",
						rv.key_text,
						rv.val_text,
					)

					row_fg := text_fg
					if strings.contains(rv.val_text, "ERROR") {
						row_fg = bifrost.rgb(255, 120, 125)
					} else if strings.contains(rv.val_text, "WARN") {
						row_fg = bifrost.rgb(250, 205, 100)
					} else if is_sel {
						row_fg = bifrost.rgb(255, 240, 150)
					}

					bifrost.set_paint(&coord.screen, row_id, bifrost.Paint_Spec{
						text    = row_line,
						fg      = row_fg,
						bg      = bifrost.rgb(42, 56, 82) if is_sel else panel_bg,
						style   = {.Bold} if is_sel else {},
						fill_bg = true,
					})
					bifrost.leaf(&coord.layout_ctx, row_id, 20, 1, bifrost.Box_Config{
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
					})
				}
			}
		}

		// 4. Footer Bar (Datalog Audit + Moment Diff + Shortcuts)
		footer_str := fmt.tprintf(
			" Datalog: %s | Diff(@%d->@%d): +%d ~%d -%d | [/]: time-travel | f: follow | ^P: palette | q: quit",
			coord.last_datalog_summary if len(coord.last_datalog_summary) > 0 else "ready",
			coord.last_diff_summary.from_moment,
			coord.last_diff_summary.to_moment,
			coord.last_diff_summary.added,
			coord.last_diff_summary.modified,
			coord.last_diff_summary.removed,
		)
		bifrost.set_paint(&coord.screen, "footer_bar", bifrost.Paint_Spec{
			text    = footer_str,
			fg      = muted_fg,
			bg      = bar_bg,
			fill_bg = true,
		})
		bifrost.leaf(&coord.layout_ctx, "footer_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = footer_str,
		})
	}

	// 5. Optional Command Palette (`z_layer = 30`)
	coord.palette.is_open = coord.palette_open
	if coord.palette.is_open {
		bifrost.ui_command_palette(&coord.layout_ctx, &coord.screen, &coord.input, &coord.palette, 56, 6)
	}

	bifrost.end_layout(&coord.layout_ctx)
}

extract_monitor_row :: proc(coord: ^bifrost.UI_Coordinator_State, row: int, alloc := context.temp_allocator) -> string {
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

run_log_monitor :: proc(live_tty: bool) -> bool {
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

	cols := 104
	rows := 24
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			actor.scheduler_stop_and_destroy(&sched)
			fmt.eprintln("Failed to initialize raw terminal")
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

	ui_actor, ui_ok := bifrost.spawn_ui_coordinator(
		&sched,
		cols,
		rows,
		&shared,
		render_log_monitor_frame,
		context.allocator,
	)
	if !ui_ok {
		actor.scheduler_stop_and_destroy(&sched)
		return false
	}
	ui_actor.state.active_collection = "$logs"
	ui_actor.state.input.wants_focus_id = bifrost.hash_id("log_stream_pane")
	bifrost.bind_key(&ui_actor.state.input, bifrost.Key_Event{code = .Rune, ch = '/'}, "filter.focus", .Root_And_Scopes)
	bifrost.bind_key(&ui_actor.state.input, bifrost.Key_Event{code = .Rune, ch = 'q'}, "app.quit", .Root_And_Scopes)
	bifrost.bind_key(&ui_actor.state.input, bifrost.Key_Event{code = .Rune, ch = 'q', mods = {.Ctrl}}, "app.quit", .Global_Always, "", {.Allow_In_Text_Input})
	bifrost.bind_key(&ui_actor.state.input, bifrost.Key_Event{code = .Rune, ch = 'c', mods = {.Ctrl}}, "app.quit", .Global_Always, "", {.Allow_In_Text_Input})
	bifrost.register_command(&ui_actor.state.palette, "filter.all",   "Show All Structured Logs",  "Filter")
	bifrost.register_command(&ui_actor.state.palette, "filter.error", "Filter ERROR Logs Only",    "Filter")
	bifrost.register_command(&ui_actor.state.palette, "filter.warn",  "Filter WARN Logs Only",     "Filter")
	bifrost.register_command(&ui_actor.state.palette, "filter.focus", "Focus Search Box (/)",      "Filter")
	bifrost.register_command(&ui_actor.state.palette, "app.quit",     "Quit Log Monitor",          "System")
	ui_pid := actor.pid(ui_actor)

	// Spawn xitdb analytics worker actor (Datalog & Moment Diffs)
	worker_actor, w_err := actor.spawn(
		&sched,
		bifrost.Xitdb_Worker_State{shared = &shared, ui_pid = ui_pid},
		bifrost.xitdb_worker_receive,
		2,
		context.allocator,
	)
	if w_err != nil {
		bifrost.ui_coordinator_destroy(&ui_actor.state)
		actor.scheduler_stop_and_destroy(&sched)
		return false
	}
	worker_pid := actor.pid(worker_actor)

	// Spawn Sleipnir Log Producer actor
	producer_actor, p_err := actor.spawn(
		&sched,
		Log_Producer_State{shared = &shared, ui_pid = ui_pid},
		log_producer_receive,
		2,
		context.allocator,
	)
	if p_err != nil {
		bifrost.ui_coordinator_destroy(&ui_actor.state)
		actor.scheduler_stop_and_destroy(&sched)
		return false
	}
	producer_pid := actor.pid(producer_actor)

	actor.scheduler_start(&sched)

	// Seed 3 streaming batches of structured logs via background producer actor
	actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
		start_seq = 1,
		count     = 40,
		tag_name  = "boot-stream",
	}))
	actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
		start_seq = 41,
		count     = 40,
		tag_name  = "steady-stream",
	}))
	actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
		start_seq = 81,
		count     = 40,
		tag_name  = "spike-stream",
	}))
	actor.scheduler_wait_idle(&sched)

	if live_tty {
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)
		if ui_actor.state.last_ansi_bytes > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
		}

		next_seq := 121
		frame_counter := 0
		for !ui_actor.state.quit_requested {
			ev, has_ev, _ := bifrost.poll_next_event(&term, 16)
			if has_ev {
				actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Input{event = ev}))
				if ke, is_k := ev.(bifrost.Key_Event); is_k && ke.action != .Release {
					eff_mods := ke.mods - {.Caps_Lock, .Num_Lock}
					is_ctrl_quit := (.Ctrl in eff_mods) && (ke.ch == 'q' || ke.ch == 'Q' || ke.ch == 'c' || ke.ch == 'C')
					is_plain_q   := (eff_mods == {}) && ke.code == .Rune && (ke.ch == 'q' || ke.ch == 'Q') &&
						!ui_actor.state.palette_open && !bifrost.is_focused(&ui_actor.state.input, "search_box")
					if is_ctrl_quit || is_plain_q {
						actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Quit{}))
					}
				}
			}

			// Periodically stream new log batches in the background every ~60 ticks
			frame_counter += 1
			if frame_counter % 60 == 0 {
				actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
					start_seq = next_seq,
					count     = 10,
					tag_name  = "live-tick",
				}))
				next_seq += 10
			}

			actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
				tick_ns = time.tick_now()._nsec,
			}))
			actor.scheduler_wait_idle(&sched)
			if ui_actor.state.last_ansi_bytes > 0 {
				_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
			}
			free_all(context.temp_allocator)
		}
	} else {
		// Deterministic headless verification workflow:
		// 1. Render initial seeded log stream (120 logs across 3 moments)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Run background Datalog query and Moment Diff (@0 -> @2) via Xitdb_Worker_State
		actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
			moment_a = 0,
			moment_b = 2,
		}))
		actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $logs[?k] = ?v",
		}))
		actor.scheduler_wait_idle(&sched)

		// 3. Scroll down 4 rows and simulate a 500-message commit burst to verify mailbox coalescing
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Scroll_Viewport{delta_rows = 4}))
		for i := 0; i < 500; i += 1 {
			actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
				moment_idx = 2,
				slot_ptr   = 512,
				tx_id      = i64(100 + i),
				tag_name   = "burst",
			}))
		}
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
		actor.scheduler_wait_idle(&sched)

		fmt.printf(
			"[Bifrost Log Monitor] batches=%d logs_written=%d coalesced=%d frames=%d viewport_rows=%d\n",
			producer_actor.state.batches_sent,
			producer_actor.state.logs_written,
			ui_actor.state.coalesced_commits,
			ui_actor.state.total_frames,
			ui_actor.state.last_viewport_rows,
		)
		for r := 0; r < ui_actor.state.rows; r += 1 {
			fmt.printf("  %s\n", extract_monitor_row(&ui_actor.state, r))
		}
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

	ok := run_log_monitor(live_tty)

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
