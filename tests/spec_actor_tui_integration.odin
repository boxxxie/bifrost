package bifrost_tests

import "core:fmt"
import "core:testing"
import "../bifrost"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// Layer 1: Executable Specifications — Sleipnir Actor Runtime & xitdb Inspector
// =============================================================================

@(test)
@(scenario)
spec_worker_actor_commits_and_ui_coordinator_renders :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 100, h = 24, num_workers = 2, active_collection = "$users")

	// Commit 2 moments via worker actor (1 DSL script + 1 sorted batch)
	upon.worker_transacting_script(
		`
		doc "initial seed"
		put .users$user_000001 = "alice"
		put .users$user_000002 = "bob"
		`,
		"v0.1.0",
	)
	upon.worker_committing_batch("$users", "user", 3, 25, true, "v0.2.0")

	// Render 1 coalesced UI frame
	upon.ticking_ui_frame(1)

	then.worker_ping_count_is(2)
	then.ui_coordinator_metrics_are(2, 1)
	then.ui_active_moment_is(1, 1, false)
	then.ui_screen_contains_text("LIVE @1 (latest @1")
	then.ui_screen_contains_text("Records (27 total)")
	then.ui_screen_contains_text("user:000003")
}

@(test)
spec_mailbox_burst_coalesces_1000_commits_into_single_frame :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 100, 24, 2, "$events")
	defer driver_destroy(&s)

	// Seed 1 moment so the database has records to display
	upon_worker_committing_batch(&s, "$events", "ev", 0, 10, true, "seed")
	upon_ticking_ui_frame(&s, 1)
	then_ui_coordinator_metrics_are(&s, 1, 1)

	// Flood 1,000 rapid commit notifications into the UI coordinator actor's mailbox
	// followed by a single vsync tick
	upon_sending_commit_burst(&s, 1000)
	upon_ticking_ui_frame(&s, 2)

	// All 1,000 notifications must coalesce into 1 additional frame (total_frames == 2)
	then_ui_coordinator_metrics_are(&s, 1001, 2)
	then_ui_active_moment_is(&s, 999, 999, false)
	then_ui_screen_contains_text(&s, "LIVE @999")
}

@(test)
spec_historical_moment_time_travel_and_datalog_diff_queries :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 110, 24, 2, "$accounts")
	defer driver_destroy(&s)

	// Commit Moment @0 (5 accounts) and Moment @1 (10 more accounts = 15 total)
	upon_worker_committing_batch(&s, "$accounts", "acct", 1, 5, true, "m0")
	upon_worker_committing_batch(&s, "$accounts", "acct", 6, 10, true, "m1")
	upon_ticking_ui_frame(&s, 1)

	then_ui_active_moment_is(&s, 1, 1, false)
	then_ui_screen_contains_text(&s, "Records (15 total)")

	// Pin the UI viewport to historical Moment @0
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Select_Moment{
		moment_idx = 0,
		pin        = true,
	}))
	upon_ticking_ui_frame(&s, 2)

	then_ui_active_moment_is(&s, 0, 1, true)
	then_ui_screen_contains_text(&s, "PINNED @0 (latest @1")
	then_ui_screen_contains_text(&s, "Records (5 total)")

	// While pinned to @0, background worker commits Moments @2 and @3
	upon_worker_committing_batch(&s, "$accounts", "acct", 16, 10, true, "m2")
	upon_worker_committing_batch(&s, "$accounts", "acct", 26, 10, true, "m3")
	upon_worker_diffing_moments(&s, 0, 3)
	upon_worker_running_datalog(&s, "find ?k, ?v where $accounts[?k] = ?v")
	upon_ticking_ui_frame(&s, 3)

	// Viewport must remain locked on Moment @0 (5 records) even though latest is @3 (35 records)
	then_ui_active_moment_is(&s, 0, 3, true)
	then_ui_screen_contains_text(&s, "PINNED @0 (latest @3")
	then_ui_screen_contains_text(&s, "Records (5 total)")
	then_ui_screen_contains_text(&s, "datalog rows=35 cols=2")
	then_ui_screen_contains_text(&s, "Diff(@0->@3): +30 ~0 -0")

	// Unpin via 'f' key to jump back to live latest Moment @3
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code = .Rune,
		ch   = 'f',
	}))
	upon_ticking_ui_frame(&s, 4)

	then_ui_active_moment_is(&s, 3, 3, false)
	then_ui_screen_contains_text(&s, "LIVE @3 (latest @3")
	then_ui_screen_contains_text(&s, "Records (35 total)")
}

@(test)
spec_100k_row_log16_viewport_slicing_and_interactive_widgets :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 100, 24, 2, ".logs")
	defer driver_destroy(&s)

	// Populate a 100,000-row Array_List in a single transaction
	tx := xitdb.tx_init(&s.db, -1, false, context.temp_allocator)
	logs_step := [1]xitdb.Path_Step{xitdb.hm("logs")}
	for i := 0; i < 100_000; i += 1 {
		xitdb.tx_append_steps(&tx, logs_step[:], i64(i * 10))
	}
	report, err := xitdb.tx_commit(&tx)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, report.moment_index, i64(0))
	free_all(context.temp_allocator)

	// Notify UI coordinator of Moment @0 and scroll directly to row 75,000 in O(log_16 N)
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
		moment_idx = 0,
		slot_ptr   = 64,
		tx_id      = 1,
		tag_name   = "100k_seed",
	}))
	upon_ticking_ui_frame(&s, 1)
	then_ui_screen_contains_text(&s, "Records (100000 total)")

	// Scroll to row 75,000 and open the Ctrl+P Command Palette
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Scroll_Viewport{
		delta_rows  = 75_000,
		page_scroll = false,
	}))
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code = .Rune,
		ch   = 'p',
		ctrl = true,
	}))
	upon_ticking_ui_frame(&s, 2)

	// Verify O(log_16 N) slice rendered row 75,000 (val = 750000) and Command Palette is open
	testing.expect_value(t, s.ui_actor.state.vlist.selected_row, 75_000)
	testing.expect_value(t, s.ui_actor.state.palette_open, true)
	then_ui_screen_contains_text(&s, "[75000]")
	then_ui_screen_contains_text(&s, "750000")
	then_ui_screen_contains_text(&s, "Command Palette")

	// Also verify direct xitdb_slice_viewport at row 99,990 returns 10 rows with zero leaks
	slice, s_err := bifrost.xitdb_slice_viewport(
		&s.db,
		0,
		".logs",
		99_990,
		15,
		{},
		context.temp_allocator,
	)
	testing.expect_value(t, s_err, nil)
	testing.expect_value(t, slice.total_rows, i64(100_000))
	testing.expect_value(t, len(slice.rows), 10)
	testing.expect_value(t, slice.rows[0].logical_index, i64(99_990))
	testing.expect_value(t, slice.rows[0].val_text, fmt.tprintf("%d", 99_990 * 10))
	testing.expect_value(t, slice.rows[9].logical_index, i64(99_999))
}

@(test)
spec_typing_in_search_box_or_palette_never_scrolls_unpins_or_quits :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 110, 24, 2, "$services")
	defer driver_destroy(&s)

	// Seed 2 moments so historical Moment @0 can be pinned while Moment @1 is latest
	upon_worker_committing_batch(&s, "$services", "kafka_quit_fail_j_k", 1, 20, true, "m0")
	upon_worker_committing_batch(&s, "$services", "kafka_quit_fail_j_k", 21, 20, true, "m1")
	upon_ticking_ui_frame(&s, 1)

	// Frame 1 with no inputs must have reconciled default focus onto "records_pane"
	then_ui_focused_widget_is(&s, "records_pane")
	then_ui_editing_widget_is(&s, "")

	// Step down 3 rows via 'j' while focused on "records_pane" and pin to Moment @0 via '['
	upon_typing_ui_keys(&s, "jjj[")
	upon_ticking_ui_frame(&s, 2)

	then_ui_vlist_row_is(&s, 3)
	then_ui_active_moment_is(&s, 0, 1, true)
	then_ui_quit_requested_is(&s, false)

	// 1. Focus "search_box" via '/' and type "kafka fail [j] quit" containing 'k', 'f', '[', 'j', ']', 'q'
	upon_sending_ui_key(&s, .Rune, '/')
	upon_ticking_ui_frame(&s, 3)
	then_ui_focused_widget_is(&s, "search_box")
	then_ui_editing_widget_is(&s, "search_box")

	upon_typing_ui_keys(&s, "kafka_quit_fail_j_k")
	upon_ticking_ui_frame(&s, 4)

	// Filter text updated, but vlist row stayed at 3, pinned_moment stayed @0, and quit_requested stayed false
	then_ui_text_value_is(&s, "search_box", "kafka_quit_fail_j_k")
	then_ui_vlist_row_is(&s, 3)
	then_ui_active_moment_is(&s, 0, 1, true)
	then_ui_quit_requested_is(&s, false)

	// 2. Open Ctrl+P Command Palette: on the EXACT SAME FRAME, cmd_palette_input acquires focus & editing_id
	upon_sending_ui_key(&s, .Rune, 'p', true)
	upon_ticking_ui_frame(&s, 5)
	then_ui_palette_open_is(&s, true)
	then_ui_focused_widget_is(&s, "cmd_palette_input")
	then_ui_editing_widget_is(&s, "cmd_palette_input")

	// Typing "quit [f] jk" inside Command Palette edits cmd_palette_input without scrolling records_pane, unpinning, or quitting
	upon_typing_ui_keys(&s, "quit [f] jk")
	upon_ticking_ui_frame(&s, 6)

	then_ui_text_value_is(&s, "cmd_palette_input", "quit [f] jk")
	then_ui_vlist_row_is(&s, 3)
	then_ui_active_moment_is(&s, 0, 1, true)
	then_ui_quit_requested_is(&s, false)

	// Escape closes Command Palette and restores focus back to "search_box" on the same frame
	upon_sending_ui_key(&s, .Escape)
	upon_ticking_ui_frame(&s, 7)
	then_ui_palette_open_is(&s, false)
	then_ui_focused_widget_is(&s, "search_box")
}

@(test)
spec_declarative_actor_action_routing_and_xitdb_workspace_snapshot :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 110, 24, 2, "$orders")
	defer driver_destroy(&s)

	upon_worker_committing_batch(&s, "$orders", "ord", 1, 12, true, "m0")
	upon_worker_committing_batch(&s, "$orders", "ord", 13, 18, true, "m1")
	upon_ticking_ui_frame(&s, 1)

	// Bind Inspector's "query.datalog" and dynamic "query.diff" actions directly to s.worker_pid
	given_actor_action_bound_static(
		&s,
		"query.datalog",
		bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $orders[?k] = ?v",
		}),
	)
	given_actor_action_bound_dynamic(
		&s,
		"query.diff",
		proc(coord: ^bifrost.UI_Coordinator_State, _: rawptr) -> (bifrost.Xitdb_Worker_Msg, bool) {
			return bifrost.Worker_Msg_Diff_Moments{
				moment_a = coord.active_moment_idx,
				moment_b = coord.latest_moment_idx,
			}, true
		},
	)

	// Pin to @0 via '[' and trigger "query.diff" via Ctrl+G shortcut -> worker computes Diff(@0->@1): +18
	upon_sending_ui_key(&s, .Rune, '[')
	upon_ticking_ui_frame(&s, 2)
	then_ui_active_moment_is(&s, 0, 1, true)

	upon_sending_ui_key(&s, .Rune, 'g', true)
	upon_ticking_ui_frame(&s, 3)
	upon_ticking_ui_frame(&s, 4)
	then_ui_screen_contains_text(&s, "Diff(@0->@1): +18 ~0 -0")

	// Open Command Palette (Ctrl+P), filter to "Datalog", and press Enter -> dispatches Worker_Msg_Run_Datalog
	upon_sending_ui_key(&s, .Rune, 'p', true)
	upon_typing_ui_keys(&s, "Datalog")
	upon_sending_ui_key(&s, .Enter)
	upon_ticking_ui_frame(&s, 5)
	upon_ticking_ui_frame(&s, 6)
	then_ui_palette_open_is(&s, false)
	then_ui_screen_contains_text(&s, "datalog rows=30 cols=2")

	// Customize splitter width + scope memory, persist workspace to xitdb, and restore into a fresh coordinator
	upon_customizing_ui_workspace(&s, "main_split", 34, "inspector_body", "records_pane", "records_pane")
	upon_saving_ui_workspace(&s, "orders_ws")
	then_restored_ui_workspace_matches(
		&s,
		"orders_ws",
		"main_split",
		34,
		"$orders",
		true,
		0,
		"inspector_body",
		"records_pane",
	)
}

@(test)
spec_ui_side_effects_osc52_title_cursor_quit_filter_and_focus_out_drag_reset :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 96, 24, 2, "$events")
	defer driver_destroy(&s)

	Quit_Guard_State :: struct {
		unsaved_changes:   bool,
		intercepted_count: int,
	}
	guard := Quit_Guard_State{unsaved_changes = true}
	given_ui_quit_filter(&s, proc(c: ^bifrost.UI_Coordinator_State) -> bool {
		g := (^Quit_Guard_State)(c.user_ptr)
		if g != nil && g.unsaved_changes {
			g.intercepted_count += 1
			return false
		}
		return true
	}, &guard)

	upon_ticking_ui_frame(&s, 1)
	then_ui_focused_widget_is(&s, "records_pane")

	// 1. Issue pure UI_Side_Effect commands (focus, OSC 52 clipboard "ok" -> "b2s=", OSC 2 title, DECSCUSR cursor, quit)
	upon_issuing_ui_side_effects(&s, "search_box", "ok", "Bifrost Inspector", .Bar_Steady, true)
	upon_ticking_ui_frame(&s, 2)

	then_ui_focused_widget_is(&s, "search_box")
	then_ui_editing_widget_is(&s, "search_box")
	then_ui_ansi_output_contains(&s, "\x1b]52;c;b2s=\x07")
	then_ui_ansi_output_contains(&s, "\x1b]2;Bifrost Inspector\x07")
	then_ui_ansi_output_contains(&s, "\x1b[6 q")
	then_ui_quit_requested_is(&s, false)

	// 2. Start a mouse drag on "main_split", then send terminal Focus_Event{focused = false} -> clears active drag & hover
	upon_pressing_mouse_on_ui_widget(&s, "main_split")
	upon_ticking_ui_frame(&s, 3)
	then_ui_pointer_capture_is(&s, "main_split", "main_split")

	upon_sending_ui_focus_event(&s, false)
	upon_ticking_ui_frame(&s, 4)
	then_ui_pointer_capture_is(&s, "", "")

	// 3. Once unsaved_changes is cleared, pressing Ctrl+Q passes quit_filter and sets quit_requested = true
	guard.unsaved_changes = false
	upon_sending_ui_key(&s, .Rune, 'q', true)
	upon_ticking_ui_frame(&s, 5)
	then_ui_quit_requested_is(&s, true)
}
