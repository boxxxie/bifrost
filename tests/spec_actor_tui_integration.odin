package bifrost_tests

import "core:fmt"
import "core:testing"
import "../bifrost"

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
@(scenario)
spec_mailbox_burst_coalesces_1000_commits_into_single_frame :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 100, h = 24, num_workers = 2, active_collection = "$events")

	// Seed 1 moment so the database has records to display
	upon.worker_committing_batch("$events", "ev", 0, 10, true, "seed")
	upon.ticking_ui_frame(1)
	then.ui_coordinator_metrics_are(1, 1)

	// Flood 1,000 rapid commit notifications into the UI coordinator actor's mailbox
	// followed by a single vsync tick
	upon.sending_commit_burst(1000)
	upon.ticking_ui_frame(2)

	// All 1,000 notifications must coalesce into 1 additional frame (total_frames == 2)
	then.ui_coordinator_metrics_are(1001, 2)
	then.ui_active_moment_is(999, 999, false)
	then.ui_screen_contains_text("LIVE @999")
}

@(test)
@(scenario)
spec_historical_moment_time_travel_and_datalog_diff_queries :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 110, h = 24, num_workers = 2, active_collection = "$accounts")

	// Commit Moment @0 (5 accounts) and Moment @1 (10 more accounts = 15 total)
	upon.worker_committing_batch("$accounts", "acct", 1, 5, true, "m0")
	upon.worker_committing_batch("$accounts", "acct", 6, 10, true, "m1")
	upon.ticking_ui_frame(1)

	then.ui_active_moment_is(1, 1, false)
	then.ui_screen_contains_text("Records (15 total)")

	// Pin the UI viewport to historical Moment @0
	upon.sending_ui_msg(bifrost.UI_Msg(bifrost.UI_Msg_Select_Moment{
		moment_idx = 0,
		pin        = true,
	}))
	upon.ticking_ui_frame(2)

	then.ui_active_moment_is(0, 1, true)
	then.ui_screen_contains_text("PINNED @0 (latest @1")
	then.ui_screen_contains_text("Records (5 total)")

	// While pinned to @0, background worker commits Moments @2 and @3
	upon.worker_committing_batch("$accounts", "acct", 16, 10, true, "m2")
	upon.worker_committing_batch("$accounts", "acct", 26, 10, true, "m3")
	upon.worker_diffing_moments(0, 3)
	upon.worker_running_datalog("find ?k, ?v where $accounts[?k] = ?v")
	upon.ticking_ui_frame(3)

	// Viewport must remain locked on Moment @0 (5 records) even though latest is @3 (35 records)
	then.ui_active_moment_is(0, 3, true)
	then.ui_screen_contains_text("PINNED @0 (latest @3")
	then.ui_screen_contains_text("Records (5 total)")
	then.ui_screen_contains_text("datalog rows=35 cols=2")
	then.ui_screen_contains_text("Diff(@0->@3): +30 ~0 -0")

	// Unpin via 'f' key to jump back to live latest Moment @3
	upon.sending_ui_msg(bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code = .Rune,
		ch   = 'f',
	}))
	upon.ticking_ui_frame(4)

	then.ui_active_moment_is(3, 3, false)
	then.ui_screen_contains_text("LIVE @3 (latest @3")
	then.ui_screen_contains_text("Records (35 total)")
}

@(test)
@(scenario)
spec_100k_row_log16_viewport_slicing_and_interactive_widgets :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 100, h = 24, num_workers = 2, active_collection = ".logs")

	// Populate a 100,000-row Array_List in a single transaction
	given.xitdb_array_list_populated("logs", 100_000, 10, 0)

	// Notify UI coordinator of Moment @0 and scroll directly to row 75,000 in O(log_16 N)
	upon.sending_ui_msg(bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
		moment_idx = 0,
		slot_ptr   = 64,
		tx_id      = 1,
		tag_name   = "100k_seed",
	}))
	upon.ticking_ui_frame(1)
	then.ui_screen_contains_text("Records (100000 total)")

	// Scroll to row 75,000 and open the Ctrl+P Command Palette
	upon.sending_ui_msg(bifrost.UI_Msg(bifrost.UI_Msg_Scroll_Viewport{
		delta_rows  = 75_000,
		page_scroll = false,
	}))
	upon.sending_ui_msg(bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code = .Rune,
		ch   = 'p',
		ctrl = true,
	}))
	upon.ticking_ui_frame(2)

	// Verify O(log_16 N) slice rendered row 75,000 (val = 750000) and Command Palette is open
	then.ui_vlist_row_is(75_000)
	then.ui_palette_open_is(true)
	then.ui_screen_contains_text("[75000]")
	then.ui_screen_contains_text("750000")
	then.ui_screen_contains_text("Command Palette")

	// Also verify direct xitdb_slice_viewport at row 99,990 returns 10 rows with zero leaks
	then.xitdb_viewport_slice_is(
		0,
		".logs",
		99_990,
		15,
		100_000,
		10,
		99_990,
		fmt.tprintf("%d", 99_990 * 10),
		99_999,
	)
}

@(test)
@(scenario)
spec_typing_in_search_box_or_palette_never_scrolls_unpins_or_quits :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 110, h = 24, num_workers = 2, active_collection = "$services")

	// Seed 2 moments so historical Moment @0 can be pinned while Moment @1 is latest
	upon.worker_committing_batch("$services", "kafka_quit_fail_j_k", 1, 20, true, "m0")
	upon.worker_committing_batch("$services", "kafka_quit_fail_j_k", 21, 20, true, "m1")
	upon.ticking_ui_frame(1)

	// Frame 1 with no inputs must have reconciled default focus onto "records_pane"
	then.ui_focused_widget_is("records_pane")
	then.ui_editing_widget_is("")

	// Step down 3 rows via 'j' while focused on "records_pane" and pin to Moment @0 via '['
	upon.typing_ui_keys("jjj[")
	upon.ticking_ui_frame(2)

	then.ui_vlist_row_is(3)
	then.ui_active_moment_is(0, 1, true)
	then.ui_quit_requested_is(false)

	// 1. Focus "search_box" via '/' and type "kafka fail [j] quit" containing 'k', 'f', '[', 'j', ']', 'q'
	upon.sending_ui_key(.Rune, '/')
	upon.ticking_ui_frame(3)
	then.ui_focused_widget_is("search_box")
	then.ui_editing_widget_is("search_box")

	upon.typing_ui_keys("kafka_quit_fail_j_k")
	upon.ticking_ui_frame(4)

	// Filter text updated, but vlist row stayed at 3, pinned_moment stayed @0, and quit_requested stayed false
	then.ui_text_value_is("search_box", "kafka_quit_fail_j_k")
	then.ui_vlist_row_is(3)
	then.ui_active_moment_is(0, 1, true)
	then.ui_quit_requested_is(false)

	// 2. Open Ctrl+P Command Palette: on the EXACT SAME FRAME, cmd_palette_input acquires focus & editing_id
	upon.sending_ui_key(.Rune, 'p', true)
	upon.ticking_ui_frame(5)
	then.ui_palette_open_is(true)
	then.ui_focused_widget_is("cmd_palette_input")
	then.ui_editing_widget_is("cmd_palette_input")

	// Typing "quit [f] jk" inside Command Palette edits cmd_palette_input without scrolling records_pane, unpinning, or quitting
	upon.typing_ui_keys("quit [f] jk")
	upon.ticking_ui_frame(6)

	then.ui_text_value_is("cmd_palette_input", "quit [f] jk")
	then.ui_vlist_row_is(3)
	then.ui_active_moment_is(0, 1, true)
	then.ui_quit_requested_is(false)

	// Escape closes Command Palette and restores focus back to "search_box" on the same frame
	upon.sending_ui_key(.Escape)
	upon.ticking_ui_frame(7)
	then.ui_palette_open_is(false)
	then.ui_focused_widget_is("search_box")
}

@(test)
@(scenario)
spec_declarative_actor_action_routing_and_xitdb_workspace_snapshot :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 110, h = 24, num_workers = 2, active_collection = "$orders")

	upon.worker_committing_batch("$orders", "ord", 1, 12, true, "m0")
	upon.worker_committing_batch("$orders", "ord", 13, 18, true, "m1")
	upon.ticking_ui_frame(1)

	// Bind Inspector's "query.datalog" and dynamic "query.diff" actions directly to s.worker_pid
	given.actor_action_bound_static(
		"query.datalog",
		bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $orders[?k] = ?v",
		}),
	)
	given.actor_action_bound_dynamic(
		"query.diff",
		proc(coord: ^bifrost.UI_Coordinator_State, _: rawptr) -> (bifrost.Xitdb_Worker_Msg, bool) {
			return bifrost.Worker_Msg_Diff_Moments{
				moment_a = coord.active_moment_idx,
				moment_b = coord.latest_moment_idx,
			}, true
		},
	)

	// Pin to @0 via '[' and trigger "query.diff" via Ctrl+G shortcut -> worker computes Diff(@0->@1): +18
	upon.sending_ui_key(.Rune, '[')
	upon.ticking_ui_frame(2)
	then.ui_active_moment_is(0, 1, true)

	upon.sending_ui_key(.Rune, 'g', true)
	upon.ticking_ui_frame(3)
	upon.ticking_ui_frame(4)
	then.ui_screen_contains_text("Diff(@0->@1): +18 ~0 -0")

	// Open Command Palette (Ctrl+P), filter to "Datalog", and press Enter -> dispatches Worker_Msg_Run_Datalog
	upon.sending_ui_key(.Rune, 'p', true)
	upon.typing_ui_keys("Datalog")
	upon.sending_ui_key(.Enter)
	upon.ticking_ui_frame(5)
	upon.ticking_ui_frame(6)
	then.ui_palette_open_is(false)
	then.ui_screen_contains_text("datalog rows=30 cols=2")

	// Customize splitter width + scope memory, persist workspace to xitdb, and restore into a fresh coordinator
	upon.customizing_ui_workspace("main_split", 34, "inspector_body", "records_pane", "records_pane")
	upon.saving_ui_workspace("orders_ws")
	then.restored_ui_workspace_matches(
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
@(scenario)
spec_ui_side_effects_osc52_title_cursor_quit_filter_and_focus_out_drag_reset :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 96, h = 24, num_workers = 2, active_collection = "$events")

	Quit_Guard_State :: struct {
		unsaved_changes:   bool,
		intercepted_count: int,
	}
	guard := Quit_Guard_State{unsaved_changes = true}
	given.ui_quit_filter(proc(c: ^bifrost.UI_Coordinator_State) -> bool {
		g := (^Quit_Guard_State)(c.user_ptr)
		if g != nil && g.unsaved_changes {
			g.intercepted_count += 1
			return false
		}
		return true
	}, &guard)

	upon.ticking_ui_frame(1)
	then.ui_focused_widget_is("records_pane")

	// 1. Issue pure UI_Side_Effect commands (focus, OSC 52 clipboard "ok" -> "b2s=", OSC 2 title, DECSCUSR cursor, quit)
	upon.issuing_ui_side_effects("search_box", "ok", "Bifrost Inspector", .Bar_Steady, true)
	upon.ticking_ui_frame(2)

	then.ui_focused_widget_is("search_box")
	then.ui_editing_widget_is("search_box")
	then.ui_ansi_output_contains("\x1b]52;c;b2s=\x07")
	then.ui_ansi_output_contains("\x1b]2;Bifrost Inspector\x07")
	then.ui_ansi_output_contains("\x1b[6 q")
	then.ui_quit_requested_is(false)

	// 2. Start a mouse drag on "main_split", then send terminal Focus_Event{focused = false} -> clears active drag & hover
	upon.pressing_mouse_on_ui_widget("main_split")
	upon.ticking_ui_frame(3)
	then.ui_pointer_capture_is("main_split", "main_split")

	upon.sending_ui_focus_event(false)
	upon.ticking_ui_frame(4)
	then.ui_pointer_capture_is("", "")

	// 3. Once unsaved_changes is cleared, pressing Ctrl+Q passes quit_filter and sets quit_requested = true
	guard.unsaved_changes = false
	upon.sending_ui_key(.Rune, 'q', true)
	upon.ticking_ui_frame(5)
	then.ui_quit_requested_is(true)
}
