package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "../../bifrost"
import xitdb "../../deps/xitdb/xitdb"

Kanban_Column :: enum u8 {
	Backlog = 0,
	In_Progress,
	Review,
	Done,
}

@(rodata)
COLUMN_TITLES := [Kanban_Column]string{
	.Backlog     = "Backlog",
	.In_Progress = "In Progress",
	.Review      = "In Review",
	.Done        = "Done",
}

@(rodata)
COLUMN_SLUGS := [Kanban_Column]string{
	.Backlog     = "backlog",
	.In_Progress = "progress",
	.Review      = "review",
	.Done        = "done",
}

@(rodata)
COLUMN_ACCENTS := [Kanban_Column]bifrost.Color{
	.Backlog     = {kind = .RGB, r = 140, g = 160, b = 190},
	.In_Progress = {kind = .RGB, r = 110, g = 190, b = 255},
	.Review      = {kind = .RGB, r = 250, g = 200, b = 95},
	.Done        = {kind = .RGB, r = 130, g = 220, b = 155},
}

Task_Priority :: enum u8 {
	Medium = 0,
	High,
	Critical,
}

@(rodata)
PRIORITY_LABELS := [Task_Priority]string{
	.Medium   = "MED",
	.High     = "HIGH",
	.Critical = "CRIT",
}

@(rodata)
PRIORITY_COLORS := [Task_Priority]bifrost.Color{
	.Medium   = {kind = .RGB, r = 130, g = 170, b = 215},
	.High     = {kind = .RGB, r = 245, g = 185, b = 90},
	.Critical = {kind = .RGB, r = 245, g = 110, b = 120},
}

MAX_TASKS :: 32

Task_Record :: struct {
	id:       int,
	col:      Kanban_Column,
	priority: Task_Priority,
	title:    string,
}

Kanban_Snapshot :: struct {
	tasks:      [MAX_TASKS]Task_Record,
	task_count: int,
	moment_idx: i64,
}

Kanban_Action :: enum u8 {
	None = 0,
	Move_Prev,
	Move_Next,
	Cycle_Priority,
	Jump_First,
	New_Task,
	Filter_Focus,
	History_Undo,
	History_Redo,
	History_Follow,
	Quit,
}

Kanban_Actions :: struct {
	Move_Prev:      Kanban_Action `bifrost:"key=H, id=task.move_prev, scope=col_*, group=stage, group_desc=Move Stage, desc=Move Left, label=Move Focused Task Left, category=Board"`,
	Move_Next:      Kanban_Action `bifrost:"key=L, id=task.move_next, scope=col_*, group=stage, group_desc=Move Stage, desc=Move Right, label=Move Focused Task Right, category=Board"`,
	Cycle_Priority: Kanban_Action `bifrost:"key=!, id=task.cycle_priority, scope=col_*, desc=Priority, label=Cycle Task Priority (MED/HIGH/CRIT), category=Board"`,
	Jump_First:     Kanban_Action `bifrost:"key=g g, id=nav.first_card, scope=col_*, desc=Top Card, label=Jump to Top Card in Column, category=Board"`,
	New_Task:       Kanban_Action `bifrost:"key=n, id=task.new, desc=New, label=Create New Kanban Task, category=Board"`,
	Filter_Focus:   Kanban_Action `bifrost:"key=/, id=filter.focus, desc=Filter, label=Focus Live Search Bar, category=Filter"`,
	History_Undo:   Kanban_Action `bifrost:"key=[, id=history.undo, group=time, group_desc=xitdb, desc=Undo, label=Step Backward One xitdb Moment, category=Time Travel"`,
	History_Redo:   Kanban_Action `bifrost:"key=], id=history.redo, group=time, group_desc=xitdb, desc=Redo, label=Step Forward One xitdb Moment, category=Time Travel"`,
	History_Follow: Kanban_Action `bifrost:"key=f, id=history.follow, desc=Follow, label=Unpin & Follow Latest Moment, category=Time Travel"`,
	Quit:           Kanban_Action `bifrost:"key=q|<C-q>|<C-c>, id=app.quit, policy=global, desc=Quit, label=Quit Kanban Board, category=System"`,
}

Kanban_App :: struct {
	core:               xitdb.Core,
	db:                 xitdb.Database,
	screen:             bifrost.Screen,
	layout_ctx:         bifrost.Layout_Context,
	input:              bifrost.Input_State,
	state_store:        bifrost.Widget_State_Store,
	palette:            bifrost.Command_Palette,
	ansi_builder:       strings.Builder,
	owned_titles:       [dynamic]string,
	latest_moment:      i64,
	active_moment:      i64,
	pinned_history:     bool,
	next_task_id:       int,
	new_modal_open:     bool,
	new_task_priority:  Task_Priority,
	focused_task_id:    int,
	quit_requested:     bool,
	last_status:        string,
	frames_rendered:    int,
	allocator:          mem.Allocator,
}

// Formats a task value stored in xitdb as "<col_slug>|<prio_idx>|<title>"
encode_task_value :: proc(col: Kanban_Column, prio: Task_Priority, title: string, alloc := context.temp_allocator) -> string {
	return fmt.aprintf("%s|%d|%s", COLUMN_SLUGS[col], int(prio), title, allocator = alloc)
}

decode_task_value :: proc(key_str: string, val_str: string) -> (rec: Task_Record, ok: bool) {
	if !strings.has_prefix(key_str, "task:") {
		return {}, false
	}
	id_part := key_str[5:]
	id_val := 0
	for ch in id_part {
		if ch >= '0' && ch <= '9' {
			id_val = id_val * 10 + int(ch - '0')
		}
	}
	p1 := strings.index_byte(val_str, '|')
	if p1 <= 0 || p1 + 2 >= len(val_str) {
		return {}, false
	}
	col_slug := val_str[:p1]
	rest := val_str[p1 + 1:]
	p2 := strings.index_byte(rest, '|')
	if p2 <= 0 {
		return {}, false
	}
	prio_ch := rest[0]
	title_str := rest[p2 + 1:]

	col := Kanban_Column.Backlog
	for c in Kanban_Column {
		if COLUMN_SLUGS[c] == col_slug {
			col = c
			break
		}
	}
	prio := Task_Priority.Medium
	if prio_ch == '1' {
		prio = .High
	} else if prio_ch == '2' {
		prio = .Critical
	}

	return Task_Record{
		id       = id_val,
		col      = col,
		priority = prio,
		title    = title_str,
	}, true
}

commit_task_mutation :: proc(
	app: ^Kanban_App,
	task_id: int,
	col: Kanban_Column,
	prio: Task_Priority,
	title: string,
	commit_doc: string,
) -> bool {
	tx := xitdb.tx_init(&app.db, -1, false, context.temp_allocator)
	if len(commit_doc) > 0 {
		xitdb.tx_doc(&tx, commit_doc)
	}
	key_str := fmt.tprintf("task:%03d", task_id)
	val_str := encode_task_value(col, prio, title, context.temp_allocator)
	steps := [2]xitdb.Path_Step{xitdb.hm("tasks"), xitdb.sm(key_str)}
	xitdb.tx_put_steps(&tx, steps[:], val_str)
	report, err := xitdb.tx_commit(&tx)
	if err != nil {
		return false
	}
	app.latest_moment  = report.moment_index
	app.active_moment  = report.moment_index
	app.pinned_history = false
	return true
}

read_kanban_snapshot :: proc(app: ^Kanban_App, moment_idx: i64, alloc := context.temp_allocator) -> Kanban_Snapshot {
	snap: Kanban_Snapshot
	slice, err := bifrost.xitdb_slice_viewport(
		&app.db,
		moment_idx,
		"$tasks",
		0,
		MAX_TASKS,
		bifrost.Xitdb_Filter{hide_tx = true},
		alloc,
	)
	if err != nil {
		return snap
	}
	snap.moment_idx = slice.moment_idx
	for row in slice.rows {
		if snap.task_count >= MAX_TASKS {
			break
		}
		if rec, ok := decode_task_value(row.key_text, row.val_text); ok {
			snap.tasks[snap.task_count] = rec
			snap.task_count += 1
		}
	}
	return snap
}

kanban_init :: proc(app: ^Kanban_App, cols, rows: i32, allocator := context.allocator) -> bool {
	app.allocator = allocator
	app.core = xitdb.core_memory_init(allocator)
	db, db_err := xitdb.database_init(&app.core)
	if db_err != nil {
		_ = xitdb.core_destroy(&app.core)
		return false
	}
	app.db = db

	if bifrost.screen_init(&app.screen, cols, rows, allocator) != nil {
		_ = xitdb.core_destroy(&app.core)
		return false
	}
	if bifrost.state_store_init(&app.state_store, allocator) != nil {
		bifrost.screen_destroy(&app.screen)
		_ = xitdb.core_destroy(&app.core)
		return false
	}
	owned, o_err := make([dynamic]string, 0, 16, allocator)
	if o_err != nil {
		bifrost.state_store_destroy(&app.state_store)
		bifrost.screen_destroy(&app.screen)
		_ = xitdb.core_destroy(&app.core)
		return false
	}
	app.owned_titles      = owned
	app.ansi_builder      = strings.builder_make(0, 8192, allocator)
	app.next_task_id      = 1
	app.focused_task_id   = 1
	app.new_task_priority = .High
	app.last_status       = "seeded initial board"
	app.input.wants_focus_id = bifrost.hash_id("task_card_1")

	// Seed initial Kanban tasks across moments @0..@2
	_ = commit_task_mutation(app, 1, .Backlog,     .High,     "Design Clay 6-pass layout engine",     "seed task 1")
	_ = commit_task_mutation(app, 2, .Backlog,     .Medium,   "Add Kitty keyboard protocol parser",   "seed task 2")
	_ = commit_task_mutation(app, 3, .In_Progress, .Critical, "Implement 50% RGB modal backdrop dim", "seed task 3")
	_ = commit_task_mutation(app, 4, .In_Progress, .High,     "Build xitdb zero-copy viewport slice", "seed task 4")
	_ = commit_task_mutation(app, 5, .Review,      .Medium,   "Verify LIFO modal focus restoration",  "seed task 5")
	_ = commit_task_mutation(app, 6, .Done,        .High,     "Integrate Sleipnir actor scheduler",   "seed task 6")
	app.next_task_id = 7

	// Declarative Single-Source Keymap, Command Palette & Contextual Hint Specs
	bifrost.clear_keybindings(&app.input)
	bifrost.command_palette_init(&app.palette, &app.input)
	if !bifrost.register_actions_struct(&app.input, &app.palette, Kanban_Actions{}) {
		return false
	}
	_ = bifrost.register_action_spec(&app.input, nil, bifrost.Action_Spec{
		action_name     = "palette.toggle",
		chord_spec      = "<C-p>",
		policy          = .Global_Always,
		flags           = {.Allow_In_Text_Input},
		desc            = "Palette",
		show_in_bar     = true,
		hide_in_palette = true,
	})

	return true
}

kanban_destroy :: proc(app: ^Kanban_App) {
	for s in app.owned_titles {
		delete(s, app.allocator)
	}
	delete(app.owned_titles)
	strings.builder_destroy(&app.ansi_builder)
	bifrost.state_store_destroy(&app.state_store)
	bifrost.screen_destroy(&app.screen)
	_ = xitdb.core_destroy(&app.core)
	app^ = {}
}

matches_filter :: proc(rec: Task_Record, query: string) -> bool {
	if len(query) == 0 {
		return true
	}
	return bifrost.contains_case_insensitive(rec.title, query) ||
		bifrost.contains_case_insensitive(PRIORITY_LABELS[rec.priority], query)
}

build_kanban_ui :: proc(app: ^Kanban_App, snap: Kanban_Snapshot) {
	w := app.screen.width
	h := app.screen.height
	bg_dark  := bifrost.rgb(20, 23, 32)
	panel_bg := bifrost.rgb(27, 32, 44)
	bar_bg   := bifrost.rgb(34, 42, 60)
	text_fg  := bifrost.rgb(220, 228, 242)
	muted_fg := bifrost.rgb(140, 155, 180)

	bifrost.begin_frame(&app.screen, bg_dark)
	bifrost.begin_layout(&app.layout_ctx, w, h)

	query := bifrost.get_text(&app.input, "task_filter")

	if bifrost.ui_scope(&app.layout_ctx, &app.screen, "kanban_root", bifrost.Scope_Config{
		dir    = .Column,
		width  = bifrost.fixed(w),
		height = bifrost.fixed(h),
	}) {
		// 1. Top Status Bar
		mode_tag := "PINNED" if app.pinned_history else "LIVE"
		header_str := fmt.tprintf(
			" BIFROST KANBAN | %s @%d (latest @%d) | Tasks: %d | Status: %s",
			mode_tag,
			snap.moment_idx,
			app.latest_moment,
			snap.task_count,
			app.last_status,
		)
		bifrost.set_paint(&app.screen, "header_bar", bifrost.Paint_Spec{
			text    = header_str,
			fg      = bifrost.rgb(130, 200, 255),
			bg      = bar_bg,
			style   = {.Bold},
			fill_bg = true,
		})
		bifrost.leaf(&app.layout_ctx, "header_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_str,
		})

		// 2. Toolbar Row (Two-Stage Search Input + Action Buttons)
		if bifrost.container(&app.layout_ctx, "toolbar", bifrost.Box_Config{
			dir         = .Row,
			width       = bifrost.grow(1),
			height      = bifrost.fixed(1),
			gap         = 1,
			focus_flags = {.Focus_Scope, .Loop_Spatial},
		}) {
			bifrost.ui_label(&app.layout_ctx, &app.screen, "lbl_filter", " Filter (/):", muted_fg)
			bifrost.ui_text_input(&app.layout_ctx, &app.screen, &app.input, "task_filter", bifrost.Text_Input_Config{
				placeholder    = "Enter or / to filter (CRIT/HIGH/MED)...",
				width          = bifrost.grow(1),
				height         = bifrost.fixed(1),
				fg             = text_fg,
				bg             = panel_bg,
				placeholder_fg = muted_fg,
				two_stage      = true,
			})
			bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_new_task", bifrost.Button_Spec{
				label  = "+ New Task (n)",
				width  = bifrost.fixed(16),
				height = bifrost.fixed(1),
				fg     = bifrost.rgb(255, 230, 120),
				bg     = bar_bg,
			})
			bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_undo", bifrost.Button_Spec{
				label  = "Undo ([)",
				width  = bifrost.fixed(10),
				height = bifrost.fixed(1),
				fg     = text_fg,
				bg     = bar_bg,
			})
			bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_redo", bifrost.Button_Spec{
				label  = "Redo (])",
				width  = bifrost.fixed(10),
				height = bifrost.fixed(1),
				fg     = text_fg,
				bg     = bar_bg,
			})
		}

		// 3. 4-Column Board (`Backlog`, `In Progress`, `In Review`, `Done`) with 2D Spatial Nav & H* History
		if bifrost.container(&app.layout_ctx, "board_columns", bifrost.Box_Config{
			dir         = .Row,
			width       = bifrost.grow(1),
			height      = bifrost.grow(1),
			gap         = 1,
			focus_flags = {.Focus_Scope, .Wrap_Spatial},
		}) {
			for col in Kanban_Column {
				col_count := 0
				for i := 0; i < snap.task_count; i += 1 {
					t := snap.tasks[i]
					if t.col == col && matches_filter(t, query) {
						col_count += 1
					}
				}

				col_id := fmt.tprintf("col_%s", COLUMN_SLUGS[col])
				col_title := fmt.tprintf("%s (%d)", COLUMN_TITLES[col], col_count)
				is_col_focused  := bifrost.is_focused(&app.input, col_id)
				is_active_scope := is_col_focused || app.input.active_scope_id == bifrost.hash_id(col_id)

				bifrost.set_paint(&app.screen, col_id, bifrost.Paint_Spec{
					title       = col_title,
					fg          = text_fg,
					bg          = panel_bg,
					border_fg   = bifrost.rgb(255, 220, 100) if is_col_focused else (COLUMN_ACCENTS[col] if is_active_scope else bifrost.rgb(70, 82, 108)),
					title_fg    = COLUMN_ACCENTS[col],
					title_style = {.Bold},
					fill_bg     = true,
				})
				if bifrost.container(&app.layout_ctx, col_id, bifrost.Box_Config{
					dir         = .Column,
					width       = bifrost.grow(1),
					height      = bifrost.grow(1),
					padding     = bifrost.pad_xy(1, 0),
					gap         = 1,
					border      = .Rounded,
					focus_flags = {.Focus_Scope, .Focusable, .Wrap_Spatial},
					scrollable  = true,
				}) {
					if col_count == 0 {
						empty_id := fmt.tprintf("empty_hint_%s", COLUMN_SLUGS[col])
						bifrost.ui_label(&app.layout_ctx, &app.screen, empty_id, "(empty - n: new)", muted_fg, {.Dim})
					}
					for i := 0; i < snap.task_count; i += 1 {
						t := snap.tasks[i]
						if t.col != col || !matches_filter(t, query) {
							continue
						}
						card_id := fmt.tprintf("task_card_%d", t.id)
						card_title := fmt.tprintf("#%02d [%s]", t.id, PRIORITY_LABELS[t.priority])
						is_card_focused  := bifrost.is_focused(&app.input, card_id)
						is_card_selected := bifrost.is_scope_selected(&app.input, card_id)
						if is_card_focused {
							app.focused_task_id = t.id
						}

						card_bg := bifrost.rgb(32, 38, 52)
						if is_card_focused {
							card_bg = bifrost.rgb(42, 52, 74)
						} else if is_card_selected {
							card_bg = bifrost.rgb(36, 44, 62)
						}

						bifrost.set_paint(&app.screen, card_id, bifrost.Paint_Spec{
							title       = card_title,
							text        = t.title,
							fg          = text_fg,
							bg          = card_bg,
							border_fg   = PRIORITY_COLORS[t.priority],
							title_fg    = PRIORITY_COLORS[t.priority],
							title_style = {.Bold},
							fill_bg     = true,
						})
						bifrost.leaf(&app.layout_ctx, card_id, 12, 1, bifrost.Box_Config{
							width       = bifrost.grow(1),
							height      = bifrost.fit(min = 3),
							border      = .Plain,
							main_align  = .Start,
							cross_align = .Start,
							wrap_mode   = .Words,
							focusable   = true,
							clickable   = true,
							hoverable   = true,
							text        = t.title,
						})
					}
				}
			}
		}

		// 4. Live Contextual Breadcrumb & Key-Hint Bars
		bifrost.ui_focus_breadcrumb_bar(&app.layout_ctx, &app.screen, &app.input, "breadcrumb_bar", bifrost.Breadcrumb_Bar_Config{
			bg = bg_dark,
		})
		bifrost.ui_key_hint_bar(&app.layout_ctx, &app.screen, &app.input, "footer_bar", bifrost.Key_Hint_Bar_Config{
			bg = bar_bg,
		})
	}

	// 5. Optional New Task Modal (`z_layer = 20`, `.Dim_Screen`)
	if app.new_modal_open {
		if bifrost.ui_modal(&app.layout_ctx, &app.screen, "new_task_modal", bifrost.Modal_Spec{
			title     = fmt.tprintf("Create New Task (#%02d)", app.next_task_id),
			z_layer   = 20,
			width     = bifrost.fixed(54),
			height    = bifrost.fixed(10),
			padding   = bifrost.pad_xy(2, 1),
			gap       = 1,
			border    = .Double,
			fg        = text_fg,
			bg        = panel_bg,
			border_fg = bifrost.rgb(120, 195, 255),
			title_fg  = bifrost.rgb(255, 225, 115),
			backdrop  = .Dim_Screen,
		}) {
			bifrost.ui_text_input(&app.layout_ctx, &app.screen, &app.input, "new_task_title", bifrost.Text_Input_Config{
				placeholder    = "Enter task description...",
				width          = bifrost.grow(1),
				height         = bifrost.fixed(3),
				border         = .Plain,
				fg             = text_fg,
				bg             = bg_dark,
				placeholder_fg = muted_fg,
				border_fg      = bifrost.rgb(90, 120, 165),
				title          = "Task Title",
			})

			if bifrost.container(&app.layout_ctx, "modal_actions", bifrost.Box_Config{
				dir    = .Row,
				width  = bifrost.grow(1),
				height = bifrost.fixed(1),
				gap    = 1,
			}) {
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_modal_prio", bifrost.Button_Spec{
					label  = fmt.tprintf("Priority: %s", PRIORITY_LABELS[app.new_task_priority]),
					width  = bifrost.fixed(16),
					height = bifrost.fixed(1),
					fg     = PRIORITY_COLORS[app.new_task_priority],
					bg     = bar_bg,
				})
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_modal_create", bifrost.Button_Spec{
					label  = "Commit to xitdb (Enter)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(130, 230, 160),
					bg     = bar_bg,
				})
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_modal_cancel", bifrost.Button_Spec{
					label  = "Cancel",
					width  = bifrost.fixed(10),
					height = bifrost.fixed(1),
					fg     = muted_fg,
					bg     = bar_bg,
				})
			}
		}
	}

	// 6. Command Palette (`z_layer = 30`)
	bifrost.ui_command_palette(&app.layout_ctx, &app.screen, &app.input, &app.palette, 58, 7)

	bifrost.end_layout(&app.layout_ctx)
}

find_task_in_snapshot :: proc(snap: Kanban_Snapshot, id: int) -> (Task_Record, bool) {
	for i := 0; i < snap.task_count; i += 1 {
		if snap.tasks[i].id == id {
			return snap.tasks[i], true
		}
	}
	if snap.task_count > 0 {
		return snap.tasks[0], true
	}
	return {}, false
}

handle_kanban_interactions :: proc(app: ^Kanban_App, snap: Kanban_Snapshot) -> bool {
	changed := false

	if bifrost.update_command_palette(&app.palette, &app.input) {
		changed = true
	}

	// Update focused_task_id from current focus
	for i := 0; i < snap.task_count; i += 1 {
		t := snap.tasks[i]
		card_id := fmt.tprintf("task_card_%d", t.id)
		if bifrost.is_focused(&app.input, card_id) {
			app.focused_task_id = t.id
			break
		}
	}

	// New Task Modal interactions
	if app.new_modal_open {
		if bifrost.was_modal_dismissed(&app.input, "new_task_modal") || bifrost.was_activated(&app.input, "btn_modal_cancel") {
			app.new_modal_open = false
			app.last_status = "cancelled task creation"
			return true
		}
		if bifrost.was_activated(&app.input, "btn_modal_prio") {
			app.new_task_priority = Task_Priority((int(app.new_task_priority) + 1) % len(Task_Priority))
			return true
		}
		if bifrost.was_activated(&app.input, "btn_modal_create") || bifrost.was_activated(&app.input, "new_task_title") {
			raw_title := strings.trim_space(bifrost.get_text(&app.input, "new_task_title"))
			if len(raw_title) > 0 {
				cloned := strings.clone(raw_title, app.allocator)
				append(&app.owned_titles, cloned)
				tid := app.next_task_id
				app.next_task_id += 1
				_ = commit_task_mutation(app, tid, .Backlog, app.new_task_priority, cloned, "create task")
				app.focused_task_id = tid
				app.input.wants_focus_id = bifrost.hash_id(fmt.tprintf("task_card_%d", tid))
				app.last_status = fmt.tprintf("committed task #%02d (@%d)", tid, app.latest_moment)
			}
			app.new_modal_open = false
			return true
		}
		return changed || (app.input.text_changed_id != 0)
	}

	// Board-level typed enum actions & toolbar buttons
	act, _ := bifrost.triggered_action(&app.input, Kanban_Action)

	if bifrost.was_activated(&app.input, "btn_new_task") || act == .New_Task {
		app.new_modal_open = true
		bifrost.set_text(&app.input, "new_task_title", "")
		app.input.wants_focus_id = bifrost.hash_id("new_task_title")
		app.last_status = "opening new task modal"
		return true
	}

	if act == .Filter_Focus {
		app.input.wants_focus_id  = bifrost.hash_id("task_filter")
		app.input.carry_edit_mode = true
		app.last_status = "focused search bar"
		return true
	}

	if act == .Jump_First {
		if rec, ok := find_task_in_snapshot(snap, app.focused_task_id); ok {
			query := bifrost.get_text(&app.input, "task_filter")
			for i := 0; i < snap.task_count; i += 1 {
				t := snap.tasks[i]
				if t.col == rec.col && matches_filter(t, query) {
					app.focused_task_id = t.id
					app.input.wants_focus_id = bifrost.hash_id(fmt.tprintf("task_card_%d", t.id))
					app.last_status = fmt.tprintf("jumped to top card #%02d", t.id)
					changed = true
					break
				}
			}
		}
	}

	if act == .Move_Next {
		if rec, ok := find_task_in_snapshot(snap, app.focused_task_id); ok {
			next_col := Kanban_Column(min(int(Kanban_Column.Done), int(rec.col) + 1))
			if next_col != rec.col {
				cloned := strings.clone(rec.title, app.allocator)
				append(&app.owned_titles, cloned)
				_ = commit_task_mutation(app, rec.id, next_col, rec.priority, cloned, "move task right")
				app.input.wants_focus_id = bifrost.hash_id(fmt.tprintf("task_card_%d", rec.id))
				app.last_status = fmt.tprintf("moved #%02d -> %s (@%d)", rec.id, COLUMN_TITLES[next_col], app.latest_moment)
				changed = true
			}
		}
	}

	if act == .Move_Prev {
		if rec, ok := find_task_in_snapshot(snap, app.focused_task_id); ok {
			prev_col := Kanban_Column(max(0, int(rec.col) - 1))
			if prev_col != rec.col {
				cloned := strings.clone(rec.title, app.allocator)
				append(&app.owned_titles, cloned)
				_ = commit_task_mutation(app, rec.id, prev_col, rec.priority, cloned, "move task left")
				app.input.wants_focus_id = bifrost.hash_id(fmt.tprintf("task_card_%d", rec.id))
				app.last_status = fmt.tprintf("moved #%02d -> %s (@%d)", rec.id, COLUMN_TITLES[prev_col], app.latest_moment)
				changed = true
			}
		}
	}

	if act == .Cycle_Priority {
		if rec, ok := find_task_in_snapshot(snap, app.focused_task_id); ok {
			next_prio := Task_Priority((int(rec.priority) + 1) % len(Task_Priority))
			cloned := strings.clone(rec.title, app.allocator)
			append(&app.owned_titles, cloned)
			_ = commit_task_mutation(app, rec.id, rec.col, next_prio, cloned, "cycle priority")
			app.last_status = fmt.tprintf("task #%02d priority -> %s (@%d)", rec.id, PRIORITY_LABELS[next_prio], app.latest_moment)
			changed = true
		}
	}

	if bifrost.was_activated(&app.input, "btn_undo") || act == .History_Undo {
		app.pinned_history = true
		app.active_moment  = max(0, app.active_moment - 1)
		app.last_status    = fmt.tprintf("time-travel pinned @%d", app.active_moment)
		changed = true
	}

	if bifrost.was_activated(&app.input, "btn_redo") || act == .History_Redo {
		if app.active_moment + 1 >= app.latest_moment {
			app.pinned_history = false
			app.active_moment  = app.latest_moment
			app.last_status    = fmt.tprintf("following latest @%d", app.latest_moment)
		} else {
			app.pinned_history = true
			app.active_moment += 1
			app.last_status    = fmt.tprintf("time-travel pinned @%d", app.active_moment)
		}
		changed = true
	}

	if act == .History_Follow {
		app.pinned_history = false
		app.active_moment  = app.latest_moment
		app.last_status    = fmt.tprintf("following latest @%d", app.latest_moment)
		changed = true
	}

	if act == .Quit {
		app.quit_requested = true
		changed = true
	}

	return changed || (app.input.text_changed_id != 0) || (app.input.scrolled_id != 0)
}

step_kanban_frame :: proc(app: ^Kanban_App, events: ..bifrost.Input_Event) {
	if len(events) > 0 && len(app.layout_ctx.nodes) > 0 && bifrost.is_pure_hover_event_batch(&app.input, events) {
		frame_start_hovered_id     := app.input.hovered_id
		frame_start_hover_path     := app.input.hover_path
		frame_start_hover_path_len := app.input.hover_path_len
		bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
		if app.input.hovered_id == frame_start_hovered_id &&
		   app.input.hover_path_len == frame_start_hover_path_len &&
		   app.input.hover_path == frame_start_hover_path {
			strings.builder_reset(&app.ansi_builder)
			return
		}
		free_all(context.temp_allocator)
		bifrost.state_store_begin_frame(&app.state_store)
		moment := app.active_moment if app.pinned_history else -1
		snap := read_kanban_snapshot(app, moment)
		build_kanban_ui(app, snap)
		bifrost.state_store_sync_from_layout(&app.state_store, &app.layout_ctx, &app.input)
		bifrost.apply_input_highlights(&app.screen, &app.layout_ctx, &app.input)
		bifrost.render_layout(&app.screen, &app.layout_ctx)
		strings.builder_reset(&app.ansi_builder)
		_ = bifrost.screen_diff_ansi(&app.screen, &app.ansi_builder)
		app.frames_rendered += 1
		return
	}

	free_all(context.temp_allocator)
	bifrost.state_store_begin_frame(&app.state_store)

	moment := app.active_moment if app.pinned_history else -1
	snap := read_kanban_snapshot(app, moment)
	build_kanban_ui(app, snap)

	bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
	if handle_kanban_interactions(app, snap) || (len(events) > 0 && !bifrost.is_pure_hover_event_batch(&app.input, events)) {
		moment = app.active_moment if app.pinned_history else -1
		snap = read_kanban_snapshot(app, moment)
		build_kanban_ui(app, snap)
		bifrost.resolve_input(&app.input, &app.layout_ctx)
	}

	bifrost.state_store_sync_from_layout(&app.state_store, &app.layout_ctx, &app.input)
	bifrost.apply_input_highlights(&app.screen, &app.layout_ctx, &app.input)
	bifrost.render_layout(&app.screen, &app.layout_ctx)

	strings.builder_reset(&app.ansi_builder)
	_ = bifrost.screen_diff_ansi(&app.screen, &app.ansi_builder)
	app.frames_rendered += 1
}

extract_kanban_row :: proc(s: ^bifrost.Screen, row: i32, alloc := context.temp_allocator) -> string {
	if row < 0 || row >= s.height {
		return ""
	}
	b := strings.builder_make(0, int(s.width), alloc)
	for x: i32 = 0; x < s.width; x += 1 {
		cell := s.front[int(row * s.width + x)]
		if cell.width == 0 || cell.ch == 0 {
			continue
		}
		strings.write_rune(&b, cell.ch)
	}
	return strings.trim_right_space(strings.to_string(b))
}

run_kanban :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	cols: i32 = 104
	rows: i32 = 22
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			fmt.eprintln("Failed to initialize raw terminal")
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(72, ws.width)
			rows = max(16, ws.height)
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	app: Kanban_App
	if !kanban_init(&app, cols, rows, context.allocator) {
		return false
	}
	defer kanban_destroy(&app)

	if live_tty {
		step_kanban_frame(&app)
		if strings.builder_len(app.ansi_builder) > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
		}

		last_tick := time.tick_now()
		target_frame_interval := 33 * time.Millisecond
		queued_inputs := make([dynamic]bifrost.Input_Event, 0, 64, context.allocator)
		defer delete(queued_inputs)
		for !app.quit_requested {
			elapsed := time.tick_diff(last_tick, time.tick_now())
			wait_ms := max(i32(1), i32((target_frame_interval - elapsed) / time.Millisecond))
			ev, has_ev, _ := bifrost.poll_next_event(&term, wait_ms)
			if has_ev {
				_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev, &app.input)
				for drain := 0; drain < 128; drain += 1 {
					ev2, has_ev2, _ := bifrost.poll_next_event(&term, 0)
					if !has_ev2 {
						break
					}
					_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev2, &app.input)
				}
			}
			now := time.tick_now()
			if len(queued_inputs) > 0 && time.tick_diff(last_tick, now) >= target_frame_interval {
				last_tick = now
				for q_ev in queued_inputs {
					if res_ev, is_res := q_ev.(bifrost.Resize_Event); is_res {
						_ = bifrost.screen_resize(&app.screen, max(72, res_ev.width), max(16, res_ev.height))
					}
				}
				step_kanban_frame(&app, ..queued_inputs[:])
				clear(&queued_inputs)
				if strings.builder_len(app.ansi_builder) > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
				}
			}
		}
	} else {
		// Deterministic headless verification & board walkthrough:
		// 1. Render initial seeded board (focused directly on task_card_1 in Backlog)
		step_kanban_frame(&app)

		// 2. Open New Task modal ('n'), type "Add Datalog query panel", and commit with Enter
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'n'})
		for ch in "Add Datalog query panel" {
			step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = ch})
		}
		step_kanban_frame(&app, bifrost.Key_Event{code = .Enter})

		// 3. Move the newly created task #07 from Backlog -> In Progress ('L' / Shift+L) and escalate priority ('!')
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'L', mods = {.Shift}})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = '!'})

		// 4. Exercise 2D spatial column jump ('h'), vertical wrap ('j'), 2-step chord ('g g'), Escape drill-up, 'l' step, & Enter H* drill-down
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'h'})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Escape})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Enter})

		// 5. Time-travel backward 2 moments ('[') to inspect historical state, then unpin ('f') back to live
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = '['})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = '['})
		step_kanban_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'f'})

		snap := read_kanban_snapshot(&app, -1)
		fmt.printf(
			"[Bifrost Kanban Board] moments=%d tasks=%d focused_task=#%02d frames=%d\n",
			app.latest_moment + 1,
			snap.task_count,
			app.focused_task_id,
			app.frames_rendered,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_kanban_row(&app.screen, r))
		}

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&app.screen, "Bifrost Kanban Board", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/kanban_board.html", dir), strings.to_string(b))
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

	ok := run_kanban(live_tty)

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
