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
// Declarative Monitor Actions (Merged onto Built-In `UI_Inspector_Actions`)
// =============================================================================

Log_Monitor_Action :: enum u8 {
	None = 0,
	Filter_All,
	Filter_Warn,
	Filter_Error,
	Stream_Burst,
}

Log_Monitor_Actions :: struct {
	filter_all:   Log_Monitor_Action `bifrost:"action=filter.all,chord=1,policy=root,group=lvl_filter,group_desc=Level Filter,category=Filter,label=Show All Structured Logs,desc=All Logs"`,
	filter_warn:  Log_Monitor_Action `bifrost:"action=filter.warn,chord=2,policy=root,group=lvl_filter,group_desc=Level Filter,category=Filter,label=Filter WARN Logs Only,desc=WARN Only"`,
	filter_error: Log_Monitor_Action `bifrost:"action=filter.error,chord=3,policy=root,group=lvl_filter,group_desc=Level Filter,category=Filter,label=Filter ERROR Logs Only,desc=ERROR Only"`,
	stream_burst: Log_Monitor_Action `bifrost:"action=stream.burst,chord=<C-b>,policy=root,allow_in_edit=true,category=Stream,label=Inject 20 Live Log Events,desc=Burst +20"`,
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

Stream_Burst_Cursor :: struct {
	next_seq: int,
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
// Declarative Action Callbacks & Dynamic Actor Payload Builders
// =============================================================================

apply_monitor_level_filter :: proc(coord: ^bifrost.UI_Coordinator_State, action_name: string, _: rawptr) {
	switch action_name {
	case "filter.all":
		coord.filter.kind   = .None
		coord.filter.needle = ""
		coord.filter.prefix = ""
		coord.search_len    = 0
		bifrost.set_text(&coord.input, "search_box", "")
	case "filter.warn":
		coord.filter.kind   = .Substring
		coord.filter.needle = "WARN"
		coord.filter.prefix = ""
		copy(coord.search_buf[:4], "WARN")
		coord.search_len = 4
		bifrost.set_text(&coord.input, "search_box", "WARN")
	case "filter.error":
		coord.filter.kind   = .Substring
		coord.filter.needle = "ERROR"
		coord.filter.prefix = ""
		copy(coord.search_buf[:5], "ERROR")
		coord.search_len = 5
		bifrost.set_text(&coord.input, "search_box", "ERROR")
	}
}

build_monitor_diff_msg :: proc(coord: ^bifrost.UI_Coordinator_State, _: rawptr) -> (bifrost.Xitdb_Worker_Msg, bool) {
	return bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
		moment_a = coord.active_moment_idx,
		moment_b = coord.latest_moment_idx,
	}), true
}

build_stream_burst_msg :: proc(_: ^bifrost.UI_Coordinator_State, ud: rawptr) -> (Log_Producer_Msg, bool) {
	cursor := (^Stream_Burst_Cursor)(ud)
	if cursor == nil {
		return nil, false
	}
	start := cursor.next_seq
	cursor.next_seq += 20
	return Log_Producer_Msg(Log_Batch_Request{
		start_seq = start,
		count     = 20,
		tag_name  = "manual-burst",
	}), true
}

// =============================================================================
// Custom Immediate-Mode Render Pass for UI_Coordinator_State
// =============================================================================

render_log_monitor_frame :: proc(coord: ^bifrost.UI_Coordinator_State) {
	coord.use_widget_pipeline = true

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
		dir         = .Column,
		width       = bifrost.fixed(w),
		height      = bifrost.fixed(h),
		focus_flags = {.Focus_Scope},
		focus_scope = true,
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
		body_h := max(i32(6), h - 6)
		if bifrost.ui_scope(&coord.layout_ctx, &coord.screen, "monitor_body", bifrost.Scope_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.fixed(body_h),
		}) {
			sidebar_w := bifrost.get_split_size(&coord.input, "monitor_split", 28, 22, max(26, w - 36))

			if bifrost.ui_scope(&coord.layout_ctx, &coord.screen, "filter_sidebar", bifrost.Scope_Config{
				dir       = .Column,
				width     = bifrost.fixed(sidebar_w),
				height    = bifrost.grow(1),
				padding   = bifrost.pad_xy(1, 0),
				gap       = 1,
				border    = .Plain,
				title     = "Stream Controls",
				fg        = text_fg,
				bg        = panel_bg,
				border_fg = bifrost.rgb(75, 95, 125),
				title_fg  = accent,
				fill_bg   = true,
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
					label  = "Show ALL Logs (1)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = text_fg,
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_warn", bifrost.Button_Spec{
					label  = "Filter: WARN Only (2)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(250, 200, 95),
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_err", bifrost.Button_Spec{
					label  = "Filter: ERROR Only (3)",
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

				// Track 14: Live Vertical Block Sparkline (`▁▂▃▄▅▆▇█`) + Unicode Braille Telemetry Canvas (`U+2800..U+28FF`)
				m_off := int(coord.active_moment_idx)
				rps_samples := [16]int{
					320 + m_off * 20, 380 + m_off * 20, 440 + m_off * 20, 510 + m_off * 20,
					490 + m_off * 20, 620 + m_off * 20, 710 + m_off * 20, 680 + m_off * 20,
					790 + m_off * 20, 860 + m_off * 20, 810 + m_off * 20, 920 + m_off * 20,
					880 + m_off * 20, 960 + m_off * 20, 910 + m_off * 20, 990 + m_off * 20,
				}
				bifrost.ui_sparkline(&coord.layout_ctx, &coord.screen, "sidebar_sparkline", rps_samples[:], bifrost.Sparkline_Config{
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(130, 230, 165),
					bg     = bar_bg,
				})

				bifrost.ui_canvas(&coord.layout_ctx, &coord.screen, "sidebar_braille_chart", bifrost.Canvas_Config{
					title     = "Braille p99",
					width     = bifrost.grow(1),
					height    = bifrost.fixed(4),
					border    = .Rounded,
					fg        = accent,
					bg        = bar_bg,
					border_fg = bifrost.rgb(75, 95, 125),
					title_fg  = accent,
					draw_fn   = proc(c: ^bifrost.Braille_Canvas, _: rawptr) {
						p99_series := [8]f32{2.1, 3.4, 2.8, 5.2, 4.1, 6.8, 3.9, 2.4}
						bifrost.canvas_draw_series(c, p99_series[:], 1.0, 8.0, bifrost.rgb(115, 195, 255))
					},
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
			slice := bifrost.ui_coordinator_slice_viewport(coord, "log_stream_pane", visible_rows)

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
					focus_flags   = {.Focusable, .Default_Focus},
				},
				&vslice,
			) {
				for row_i in 0 ..< len(slice.rows) {
					rv := slice.rows[row_i]
					is_sel := int(rv.view_index) == coord.vlist.selected_row
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

		// 4. Worker Telemetry Row (Datalog Audit + Moment Diff) + Live Contextual Key-Hint Bar
		footer_str := fmt.tprintf(
			" Datalog: %s | Diff(@%d->@%d): +%d ~%d -%d",
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

		bifrost.ui_key_hint_bar(&coord.layout_ctx, &coord.screen, &coord.input, "monitor_hint_bar", bifrost.Key_Hint_Bar_Config{
			bg = bifrost.rgb(22, 28, 40),
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
	ui_actor.state.primary_list_id   = "log_stream_pane"
	ui_actor.state.input.wants_focus_id = bifrost.hash_id("log_stream_pane")
	_ = bifrost.register_actions_struct(&ui_actor.state.input, &ui_actor.state.palette, Log_Monitor_Actions{})
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

	burst_cursor := Stream_Burst_Cursor{next_seq = 1001}

	// Declaratively wire widget activations, local filter callbacks, and Sleipnir worker/producer sinks
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_lvl_all",    "filter.all")
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_lvl_warn",   "filter.warn")
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_lvl_err",    "filter.error")
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_pin_toggle", "moment.follow")

	_ = bifrost.on_ui_action(&ui_actor.state, "filter.all",   apply_monitor_level_filter)
	_ = bifrost.on_ui_action(&ui_actor.state, "filter.warn",  apply_monitor_level_filter)
	_ = bifrost.on_ui_action(&ui_actor.state, "filter.error", apply_monitor_level_filter)

	_ = bifrost.bind_actor_action(
		&ui_actor.state,
		"query.datalog",
		worker_pid,
		bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $logs[?k] = ?v",
		}),
	)
	_ = bifrost.bind_actor_action(&ui_actor.state, "query.diff", worker_pid, build_monitor_diff_msg)
	_ = bifrost.bind_actor_action(&ui_actor.state, "stream.burst", producer_pid, build_stream_burst_msg, &burst_cursor)

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
		_ = bifrost.load_ui_workspace_from_xitdb(&shared, &ui_actor.state, "monitor_default")
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
		_ = bifrost.save_ui_workspace_to_xitdb(&shared, &ui_actor.state, "monitor_default")
	} else {
		// Deterministic headless verification workflow:
		// 1. Render initial seeded log stream (120 logs across 3 moments)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Step back to @0 (`[` twice) and trigger `<C-g>` (`query.diff`) + `<C-d>` (`query.datalog`) + `f` (`moment.follow`)
		//    through declarative `bind_actor_action` routing onto `worker_pid`
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '['}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '['}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'g', ctrl = true}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'd', ctrl = true}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'f'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
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
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 3}))
		actor.scheduler_wait_idle(&sched)

		saved_ws := bifrost.save_ui_workspace_to_xitdb(&shared, &ui_actor.state, "monitor_default")
		if !saved_ws {
			bifrost.ui_coordinator_destroy(&ui_actor.state)
			actor.scheduler_stop_and_destroy(&sched)
			return false
		}

		fmt.printf(
			"[Bifrost Log Monitor] batches=%d logs_written=%d coalesced=%d frames=%d viewport_rows=%d workspace_saved=%v\n",
			producer_actor.state.batches_sent,
			producer_actor.state.logs_written,
			ui_actor.state.coalesced_commits,
			ui_actor.state.total_frames,
			ui_actor.state.last_viewport_rows,
			saved_ws,
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
