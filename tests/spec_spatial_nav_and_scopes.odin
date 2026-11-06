package bifrost_tests

import "core:fmt"
import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications (Track 2: Focus, Input & Hit-Testing)
// =============================================================================


@(test)
spec_hierarchical_kanban_history_shallow_fallback_and_inactive_selection :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 96, h = 22)
	defer driver_destroy(&s)

	build_board :: proc(
		s: ^Suite_Ctx,
		include_doing_2: bool,
		show_modal: bool,
	) {
		driver_begin_frame(s, bifrost.rgb(16, 20, 26))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(&s.layout_ctx, "board", {
				dir         = .Row,
				width       = bifrost.grow(1),
				height      = bifrost.grow(1),
				gap         = 1,
				focus_flags = {.Focus_Scope},
			}) {
				if bifrost.container(&s.layout_ctx, "col_backlog", {
					dir         = .Column,
					width       = bifrost.fixed(30),
					height      = bifrost.grow(1),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable},
				}) {
					bifrost.set_paint(&s.screen, "col_backlog", {title = "Backlog"})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "backlog_1", {label = "Task 1", focus_flags = {.Default_Focus}})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "backlog_2", {label = "Task 2"})
				}

				if bifrost.container(&s.layout_ctx, "col_doing", {
					dir         = .Column,
					width       = bifrost.fixed(30),
					height      = bifrost.grow(1),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable},
				}) {
					bifrost.set_paint(&s.screen, "col_doing", {title = "In Progress"})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "doing_1", {label = "Active 1"})
					if include_doing_2 {
						bifrost.ui_button(&s.layout_ctx, &s.screen, "doing_2", {label = "Active 2", focus_flags = {.Default_Focus}})
					}
				}

				if bifrost.container(&s.layout_ctx, "col_done_empty", {
					dir         = .Column,
					width       = bifrost.fixed(30),
					height      = bifrost.grow(1),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable},
				}) {
					bifrost.set_paint(&s.screen, "col_done_empty", {title = "Done"})
				}
			}

			if show_modal {
				if bifrost.ui_modal(&s.layout_ctx, &s.screen, "delete_modal", {
					title   = "Archive Card",
					z_layer = 20,
					width   = bifrost.fixed(32),
					height  = bifrost.fixed(6),
				}) {
					bifrost.ui_button(&s.layout_ctx, &s.screen, "confirm_archive", {label = "Archive"})
				}
			}
		}
		driver_end_frame(s)
	}

	// 1. Mount board -> lands on backlog_1, advance to backlog_2, switch F6 -> doing_2
	build_board(&s, true, false)
	then_focused_widget_is(&s, "backlog_1")

	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "backlog_2")

	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "doing_2")
	then_scope_selected_is(&s, "backlog_2", true)

	// 2. Render frame so inactive highlight on backlog_2 is painted into VT cells and verified
	build_board(&s, true, false)
	backlog_rect, _ := bifrost.get_rect(&s.layout_ctx, "backlog_2")
	then_cell_style_at_has(&s, backlog_rect.x + 1, backlog_rect.y, .Dim)
	then_cell_style_at_has(&s, backlog_rect.x + 1, backlog_rect.y, .Reverse)

	// 3. F6 focuses empty col_done_empty container, F6 again restores backlog_2 (H*), F6 returns to doing_2
	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "col_done_empty")
	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "backlog_2")
	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "doing_2")

	// 4. Open modal over doing_2, then archive/delete doing_2 and close modal -> Shallow History (H) lands on doing_1
	build_board(&s, true, true)
	then_focused_widget_is(&s, "confirm_archive")

	build_board(&s, false, false)
	then_focused_widget_is(&s, "doing_1")
}

@(test)
spec_two_stage_form_editing_sticky_tab_carry_and_scope_text_sink :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	bifrost.bind_key(&s.input, {code = .Rune, ch = 'q'}, "quit_app", .Root_And_Scopes)

	build_form_and_sink_ui :: proc(s: ^Suite_Ctx, open_sink_palette: bool) {
		driver_begin_frame(s, bifrost.rgb(16, 20, 26))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(&s.layout_ctx, "editor_form", {
				dir         = .Column,
				width       = bifrost.fixed(50),
				height      = bifrost.fixed(12),
				border      = .Rounded,
				gap         = 1,
				focus_flags = {.Focus_Scope},
			}) {
				bifrost.ui_text_input(&s.layout_ctx, &s.screen, &s.input, "task_title", {
					width       = bifrost.fixed(36),
					height      = bifrost.fixed(3),
					border      = .Plain,
					title       = "Title",
					placeholder = "Enter title...",
					two_stage   = true,
					focus_flags = {.Default_Focus},
				})
				bifrost.ui_text_input(&s.layout_ctx, &s.screen, &s.input, "task_assignee", {
					width       = bifrost.fixed(36),
					height      = bifrost.fixed(3),
					border      = .Plain,
					title       = "Assignee",
					placeholder = "Enter assignee...",
					two_stage   = true,
				})
				bifrost.ui_button(&s.layout_ctx, &s.screen, "submit_btn", {label = "Create Task"})
			}

			if open_sink_palette {
				query := bifrost.get_text(&s.input, "quick_sink")
				if bifrost.ui_modal(&s.layout_ctx, &s.screen, "quick_switcher", {
					title   = "Quick Switcher",
					z_layer = 30,
					width   = bifrost.fixed(48),
					height  = bifrost.fixed(10),
				}) {
					bifrost.ui_text_input(&s.layout_ctx, &s.screen, &s.input, "quick_sink", {
						placeholder = "Filter files...",
						focus_flags = {.Captures_Text, .Auto_Edit, .Scope_Text_Sink},
					})
					files := [3]string{"layout.odin", "input.odin", "quorum.odin"}
					idx := 0
					for f in files {
						if len(query) == 0 || bifrost.contains_case_insensitive(f, query) {
							flags := bifrost.Focus_Flags{.Default_Focus} if idx == 0 else bifrost.Focus_Flags{}
							id := "file_0" if idx == 0 else ("file_1" if idx == 1 else "file_2")
							bifrost.ui_button(&s.layout_ctx, &s.screen, id, {label = f, focus_flags = flags})
							idx += 1
						}
					}
				}
			}
		}
		driver_end_frame(s)
	}

	// 1. Two-stage form starts in navigation stage: 'j' moves down to task_assignee without typing
	build_form_and_sink_ui(&s, false)
	then_focused_widget_is(&s, "task_title")
	then_editing_widget_is(&s, "")

	upon_pressing_key(&s, .Rune, {}, 'j')
	then_focused_widget_is(&s, "task_assignee")
	then_text_input_value_is(&s, "task_title", "")

	upon_pressing_key(&s, .Rune, {}, 'k')
	then_focused_widget_is(&s, "task_title")

	// 2. Enter starts editing task_title; Tab carries edit mode into task_assignee; Escape exits edit mode
	upon_pressing_key(&s, .Enter)
	then_editing_widget_is(&s, "task_title")
	upon_typing_text(&s, "Ship Track 6")
	then_text_input_value_is(&s, "task_title", "Ship Track 6")

	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "task_assignee")
	then_editing_widget_is(&s, "task_assignee")
	upon_typing_text(&s, "pauli")
	then_text_input_value_is(&s, "task_assignee", "pauli")

	upon_pressing_key(&s, .Escape)
	then_focused_widget_is(&s, "task_assignee")
	then_editing_widget_is(&s, "")

	// 3. Open .Scope_Text_Sink quick_switcher modal: focus is on file_0 while quick_sink captures typing
	build_form_and_sink_ui(&s, true)
	then_focused_widget_is(&s, "file_0")
	then_editing_widget_is(&s, "quick_sink")

	upon_pressing_key(&s, .Down)
	then_focused_widget_is(&s, "file_1")

	// Typing "qu" into quick_sink filters list and resets selection back to file_0 (now "quorum.odin")
	upon_typing_text(&s, "qu")
	then_action_triggered_is(&s, "quit_app", false)
	build_form_and_sink_ui(&s, true)
	then_text_input_value_is(&s, "quick_sink", "qu")
	then_focused_widget_is(&s, "file_0")

	// Pressing Enter activates focused item file_0 directly while quick_sink still owns editing_id!
	upon_pressing_key(&s, .Enter)
	then_activated_widget_is(&s, "file_0")
}

@(test)
spec_kanban_2d_spatial_drill_down_up_cross_column_history_and_same_frame_scroll :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 96, h = 20)
	defer driver_destroy(&s)

	// Inner scope binding on col_doing shadows root binding for the same key ('m')
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'm'}, "global_menu", .Root_And_Scopes)
	bifrost.bind_key(&s.input, {code = .Rune, ch = 'm'}, "mark_blocked", .Scope_Only, "col_doing")

	build_kanban_board :: proc(s: ^Suite_Ctx, events: ..bifrost.Input_Event) {
		driver_begin_frame(s, bifrost.rgb(16, 20, 26))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(&s.layout_ctx, "board", {
				dir         = .Row,
				width       = bifrost.grow(1),
				height      = bifrost.grow(1),
				gap         = 1,
				focus_flags = {.Focus_Scope, .Loop_Spatial},
			}) {
				// Scrollable Backlog column: outer height = 8, Plain border -> inner_rect.h = 6 rows.
				// 5 cards * 2 rows = 10 content_span -> todo_3 & todo_4 start offscreen!
				if bifrost.container(&s.layout_ctx, "col_todo", {
					dir         = .Column,
					width       = bifrost.fixed(30),
					height      = bifrost.fixed(8),
					border      = .Plain,
					scrollable  = true,
					focus_flags = {.Focus_Scope, .Focusable, .Loop_Spatial},
				}) {
					bifrost.set_paint(&s.screen, "col_todo", {title = "Backlog"})
					todo_ids := [5]string{"todo_0", "todo_1", "todo_2", "todo_3", "todo_4"}
					todo_labels := [5]string{"CardZero", "CardOne", "CardTwo", "CardThreeOff", "CardFourOff"}
					for i in 0 ..< 5 {
						flags := bifrost.Focus_Flags{.Default_Focus} if i == 0 else bifrost.Focus_Flags{}
						bifrost.ui_button(&s.layout_ctx, &s.screen, todo_ids[i], {
							label       = todo_labels[i],
							width       = bifrost.fixed(28),
							height      = bifrost.fixed(2),
							focus_flags = flags,
						})
					}
				}

				if bifrost.container(&s.layout_ctx, "col_doing", {
					dir         = .Column,
					width       = bifrost.fixed(30),
					height      = bifrost.fixed(8),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable, .Loop_Spatial},
				}) {
					bifrost.set_paint(&s.screen, "col_doing", {title = "In Progress"})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "doing_0", {
						label  = "DoingZero",
						width  = bifrost.fixed(28),
						height = bifrost.fixed(2),
					})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "doing_1", {
						label       = "DoingOne",
						width       = bifrost.fixed(28),
						height      = bifrost.fixed(2),
						focus_flags = {.Default_Focus},
					})
				}

				if bifrost.container(&s.layout_ctx, "col_done", {
					dir         = .Column,
					width       = bifrost.fixed(30),
					height      = bifrost.fixed(8),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable, .Loop_Spatial},
				}) {
					bifrost.set_paint(&s.screen, "col_done", {title = "Done (Empty)"})
				}
			}
		}
		driver_end_frame(s, ..events)
	}

	// 1. Initial render: todo_0 is focused; CardThreeOff is clipped out of the VT screen!
	build_kanban_board(&s)
	then_focused_widget_is(&s, "todo_0")
	then_vt_contains_text(&s, "CardThreeOff", false)

	// 2. Same-frame scroll-into-view: pressing 'j' 3 times in a single frame renders CardThreeOff immediately (0 frame lag)!
	build_kanban_board(
		&s,
		bifrost.Key_Event{code = .Rune, ch = 'j'},
		bifrost.Key_Event{code = .Rune, ch = 'j'},
		bifrost.Key_Event{code = .Rune, ch = 'j'},
	)
	then_focused_widget_is(&s, "todo_3")
	then_vt_contains_text(&s, "CardThreeOff", true)

	// 3. Vertical .Loop_Spatial inside col_todo: j -> todo_4, j -> wraps to todo_0 and scrolls back to top on same frame!
	build_kanban_board(&s, bifrost.Key_Event{code = .Rune, ch = 'j'})
	then_focused_widget_is(&s, "todo_4")
	build_kanban_board(&s, bifrost.Key_Event{code = .Rune, ch = 'j'})
	then_focused_widget_is(&s, "todo_0")
	then_vt_contains_text(&s, "CardZero", true)

	// Move down to todo_2 so col_todo remembers todo_2 in Deep History (H*)
	upon_pressing_key(&s, .Rune, {}, 'j')
	upon_pressing_key(&s, .Rune, {}, 'j')
	then_focused_widget_is(&s, "todo_2")

	// Scoped keybinding check in col_todo -> falls through to root 'global_menu'
	upon_pressing_key(&s, .Rune, {}, 'm')
	then_action_triggered_is(&s, "global_menu", true)

	// 4. Cross-column spatial bubbling ('l') -> enters col_doing at doing_1 (.Default_Focus) while todo_2 stays scope-selected
	upon_pressing_key(&s, .Rune, {}, 'l')
	then_focused_widget_is(&s, "doing_1")
	then_scope_selected_is(&s, "todo_2", true)

	// Scoped keybinding check in col_doing -> inner scope shadows 'global_menu' with 'mark_blocked'!
	upon_pressing_key(&s, .Rune, {}, 'm')
	then_action_triggered_is(&s, "mark_blocked", true)

	// Move up to doing_0, then 'l' into empty col_done, then 'l' wraps around board (.Loop_Spatial) back to todo_2 (H*)!
	upon_pressing_key(&s, .Rune, {}, 'k')
	then_focused_widget_is(&s, "doing_0")
	upon_pressing_key(&s, .Rune, {}, 'l')
	then_focused_widget_is(&s, "col_done")

	// 5. Column-level navigation & Enter/Escape layering:
	// Escape on todo_2 pops up to col_todo; 'l' moves column-to-column onto col_doing; Enter drills down into doing_0 (H*)!
	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "todo_2")

	upon_pressing_key(&s, .Escape)
	then_focused_widget_is(&s, "col_todo")

	upon_pressing_key(&s, .Rune, {}, 'l')
	then_focused_widget_is(&s, "col_doing")

	upon_pressing_key(&s, .Enter)
	then_focused_widget_is(&s, "doing_0")
}


@(test)
spec_wrap_spatial_reading_order_grid_and_virtual_table_column_boundary_bubbling :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 88, h = 18)
	defer driver_destroy(&s)

	build_grid_and_table_ui :: proc(s: ^Suite_Ctx, events: ..bifrost.Input_Event) {
		driver_begin_frame(s, bifrost.rgb(16, 20, 28))
		if bifrost.ui_scope(&s.layout_ctx, &s.screen, "workspace", {
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
			gap    = 1,
		}) {
			// Left: 2x2 .Wrap_Spatial reading-order card grid
			if bifrost.ui_scope(&s.layout_ctx, &s.screen, "card_grid", {
				dir         = .Column,
				width       = bifrost.fixed(34),
				height      = bifrost.grow(1),
				border      = .Plain,
				focus_flags = {.Wrap_Spatial},
			}) {
				if bifrost.container(&s.layout_ctx, "grid_r0", {dir = .Row, width = bifrost.grow(1), height = bifrost.fixed(2), gap = 1}) {
					bifrost.ui_button(&s.layout_ctx, &s.screen, "cell_0_0", {
						label       = "R0C0",
						width       = bifrost.fixed(14),
						height      = bifrost.fixed(2),
						focus_flags = {.Default_Focus},
					})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "cell_0_1", {
						label  = "R0C1",
						width  = bifrost.fixed(14),
						height = bifrost.fixed(2),
					})
				}
				if bifrost.container(&s.layout_ctx, "grid_r1", {dir = .Row, width = bifrost.grow(1), height = bifrost.fixed(2), gap = 1}) {
					bifrost.ui_button(&s.layout_ctx, &s.screen, "cell_1_0", {
						label  = "R1C0",
						width  = bifrost.fixed(14),
						height = bifrost.fixed(2),
					})
					bifrost.ui_button(&s.layout_ctx, &s.screen, "cell_1_1", {
						label  = "R1C1",
						width  = bifrost.fixed(14),
						height = bifrost.fixed(2),
					})
				}
			}

			// Right: 100k-row x 3-col virtualized table
			vslice: bifrost.Virtual_Slice
			if bifrost.ui_virtual_list(&s.layout_ctx, &s.screen, &s.input, "pkg_table", 100_000, {
				title         = "Packages (100k x 3)",
				width         = bifrost.grow(1),
				height        = bifrost.grow(1),
				border        = .Plain,
				fallback_rows = 14,
				total_cols    = 3,
			}, &vslice) {
				for r := vslice.start_row; r < vslice.end_row; r += 1 {
					rid := fmt.tprintf("vrow_%d", r)
					bifrost.ui_label(&s.layout_ctx, &s.screen, rid, rid)
				}
			}
		}
		driver_end_frame(s, ..events)
	}

	// 1. Mount workspace: cell_0_0 holds focus; pressing 'l' moves to cell_0_1, and 'l' again wraps in reading order to cell_1_0!
	build_grid_and_table_ui(&s)
	then_focused_widget_is(&s, "cell_0_0")

	build_grid_and_table_ui(&s, bifrost.Key_Event{code = .Rune, ch = 'l'})
	then_focused_widget_is(&s, "cell_0_1")

	build_grid_and_table_ui(&s, bifrost.Key_Event{code = .Rune, ch = 'l'})
	then_focused_widget_is(&s, "cell_1_0")

	// Pressing 'h' on cell_1_0 wraps backward in reading order to cell_0_1
	build_grid_and_table_ui(&s, bifrost.Key_Event{code = .Rune, ch = 'h'})
	then_focused_widget_is(&s, "cell_0_1")

	// 2. Switch scope via F6 to pkg_table, step columns ('l' twice -> col 2), then step left ('h' twice -> col 0),
	//    and press 'h' once more at col 0 to bubble out of pkg_table into card_grid!
	build_grid_and_table_ui(&s, bifrost.Key_Event{code = .F6})
	then_focused_widget_is(&s, "pkg_table")
	then_virtual_table_cell_is(&s, "pkg_table", 0, 0)

	build_grid_and_table_ui(
		&s,
		bifrost.Key_Event{code = .Rune, ch = 'j'},
		bifrost.Key_Event{code = .Rune, ch = 'l'},
		bifrost.Key_Event{code = .Rune, ch = 'l'},
	)
	then_virtual_table_cell_is(&s, "pkg_table", 1, 2)

	build_grid_and_table_ui(
		&s,
		bifrost.Key_Event{code = .Rune, ch = 'h'},
		bifrost.Key_Event{code = .Rune, ch = 'h'},
	)
	then_focused_widget_is(&s, "pkg_table")
	then_virtual_table_cell_is(&s, "pkg_table", 1, 0)

	// At col 0, pressing 'h' bubbles out of pkg_table back into card_grid (restoring cell_0_1 via H*)
	build_grid_and_table_ui(&s, bifrost.Key_Event{code = .Rune, ch = 'h'})
	then_focused_widget_is(&s, "cell_0_1")
}

