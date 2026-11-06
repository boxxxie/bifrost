package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../../bifrost"

Theme_Preset :: enum u8 {
	Nord = 0,
	Tokyo_Night,
	Gruvbox,
}

Theme_Palette :: struct {
	name:       string,
	bg:         bifrost.Color,
	panel_bg:   bifrost.Color,
	header_bg:  bifrost.Color,
	accent_fg:  bifrost.Color,
	text_fg:    bifrost.Color,
	muted_fg:   bifrost.Color,
	border_fg:  bifrost.Color,
	sel_bg:     bifrost.Color,
	sel_fg:     bifrost.Color,
}

@(rodata)
THEMES := [Theme_Preset]Theme_Palette{
	.Nord = {
		name      = "Nord",
		bg        = {kind = .RGB, r = 22,  g = 26,  b = 34},
		panel_bg  = {kind = .RGB, r = 28,  g = 34,  b = 45},
		header_bg = {kind = .RGB, r = 36,  g = 46,  b = 66},
		accent_fg = {kind = .RGB, r = 136, g = 192, b = 208},
		text_fg   = {kind = .RGB, r = 216, g = 222, b = 233},
		muted_fg  = {kind = .RGB, r = 129, g = 161, b = 193},
		border_fg = {kind = .RGB, r = 76,  g = 86,  b = 106},
		sel_bg    = {kind = .RGB, r = 59,  g = 66,  b = 82},
		sel_fg    = {kind = .RGB, r = 235, g = 203, b = 139},
	},
	.Tokyo_Night = {
		name      = "Tokyo Night",
		bg        = {kind = .RGB, r = 20,  g = 22,  b = 34},
		panel_bg  = {kind = .RGB, r = 26,  g = 27,  b = 38},
		header_bg = {kind = .RGB, r = 36,  g = 40,  b = 59},
		accent_fg = {kind = .RGB, r = 122, g = 162, b = 247},
		text_fg   = {kind = .RGB, r = 192, g = 202, b = 245},
		muted_fg  = {kind = .RGB, r = 154, g = 165, b = 206},
		border_fg = {kind = .RGB, r = 65,  g = 72,  b = 104},
		sel_bg    = {kind = .RGB, r = 49,  g = 56,  b = 86},
		sel_fg    = {kind = .RGB, r = 224, g = 175, b = 104},
	},
	.Gruvbox = {
		name      = "Gruvbox",
		bg        = {kind = .RGB, r = 29,  g = 32,  b = 33},
		panel_bg  = {kind = .RGB, r = 40,  g = 40,  b = 40},
		header_bg = {kind = .RGB, r = 60,  g = 56,  b = 54},
		accent_fg = {kind = .RGB, r = 250, g = 189, b = 47},
		text_fg   = {kind = .RGB, r = 235, g = 219, b = 178},
		muted_fg  = {kind = .RGB, r = 168, g = 153, b = 132},
		border_fg = {kind = .RGB, r = 102, g = 92,  b = 84},
		sel_bg    = {kind = .RGB, r = 80,  g = 73,  b = 69},
		sel_fg    = {kind = .RGB, r = 254, g = 128, b = 25},
	},
}

@(rodata)
MODULE_NAMES := [10]string{
	"bifrost/layout",
	"bifrost/renderer",
	"bifrost/input",
	"bifrost/scroll",
	"bifrost/text_input",
	"bifrost/command_palette",
	"sleipnir/actor",
	"sleipnir/scheduler",
	"xitdb/btree",
	"xitdb/datalog",
}

@(rodata)
MODULE_CATEGORIES := [5]string{
	"Layout",
	"Rendering",
	"Widgets",
	"Concurrency",
	"Database",
}

@(rodata)
MODULE_STATUSES := [4]string{
	"Verified",
	"Active",
	"Optimized",
	"Stable",
}

TOTAL_GALLERY_ROWS :: 500

Gallery_Action :: enum u8 {
	None = 0,
	Theme_Cycle,
	Style_Cycle,
	Modal_Open,
	Jump_Top,
	Jump_Bottom,
	Filter_Focus,
	Filter_Clear,
	Quit,
}

Gallery_Actions :: struct {
	Theme_Cycle:  Gallery_Action `bifrost:"key=<C-t>, id=theme.cycle, allow_in_edit=true, desc=Theme, label=Cycle Color Theme (Nord / Tokyo / Gruvbox), category=Appearance"`,
	Style_Cycle:  Gallery_Action `bifrost:"key=<F2>, id=style.cycle, policy=global, allow_in_edit=true, desc='Bindings (F2)', label='Cycle Keymap Style (Vim / Helix / Emacs) [F2]', category=Keymap"`,
	Modal_Open:   Gallery_Action `bifrost:"vim=m, helix=<Space> m, emacs=<C-x> m, id=modal.open, desc=Inspect, label=Open Package Inspector Modal (z=20), category=View"`,
	Jump_Top:     Gallery_Action `bifrost:"vim=g g, helix=g g, emacs=<C-x> [, id=pkg.jump_top, scope=pkg_*, desc=Top Row, label=Jump to First Package Row, category=Navigation"`,
	Jump_Bottom:  Gallery_Action `bifrost:"vim=G|g e, helix=g e, emacs=<C-x> ], id=pkg.jump_bottom, scope=pkg_*, desc='Bottom, Last', label='Jump to Bottom, Last Package Row', category=Navigation"`,
	Filter_Focus: Gallery_Action `bifrost:"vim=/, helix=<Space> /, emacs=<C-s>, id=filter.focus, desc=Filter, label=Focus Search Input (/), category=Filter"`,
	Filter_Clear: Gallery_Action `bifrost:"key=<C-l>, id=filter.clear, allow_in_edit=true, desc=Clear, label=Clear Package Search Filter, category=Filter"`,
	Quit:         Gallery_Action `bifrost:"vim=q|<C-q>|<C-c>, helix=q|<C-q>|<C-c>, emacs=<C-x> c|<C-q>, id=app.quit, policy=global, desc=Quit, label=Quit Widget Gallery, category=System"`,
}

Gallery_App :: struct {
	screen:             bifrost.Screen,
	layout_ctx:         bifrost.Layout_Context,
	input:              bifrost.Input_State,
	state_store:        bifrost.Widget_State_Store,
	palette:            bifrost.Command_Palette,
	filter:             bifrost.Xitdb_Filter,
	ansi_builder:       strings.Builder,
	col_specs:          [4]bifrost.Table_Column_Spec,
	theme:              Theme_Preset,
	detail_modal_open:  bool,
	confirm_modal_open: bool,
	quit_requested:     bool,
	action_count:       int,
	last_action:        string,
	frames_rendered:    int,
}

format_package_row :: proc(db_row: i32, alloc := context.temp_allocator) -> string {
	mod := MODULE_NAMES[int(db_row) % len(MODULE_NAMES)]
	cat := MODULE_CATEGORIES[int(db_row) % len(MODULE_CATEGORIES)]
	st  := MODULE_STATUSES[int(db_row) % len(MODULE_STATUSES)]
	return fmt.aprintf("pkg-%04d %s %s %s", db_row, mod, cat, st, allocator = alloc)
}

gallery_init :: proc(app: ^Gallery_App, cols, rows: i32, allocator := context.allocator) -> bool {
	if bifrost.screen_init(&app.screen, cols, rows, allocator) != nil {
		return false
	}
	if bifrost.state_store_init(&app.state_store, allocator) != nil {
		bifrost.screen_destroy(&app.screen)
		return false
	}
	if bifrost.xitdb_filter_init(&app.filter, allocator, 512) != nil {
		bifrost.state_store_destroy(&app.state_store)
		bifrost.screen_destroy(&app.screen)
		return false
	}
	app.ansi_builder = strings.builder_make(0, 8192, allocator)
	app.theme        = .Nord
	app.last_action  = "ready"
	app.input.wants_focus_id = bifrost.hash_id("pkg_list")

	app.col_specs = {
		{header = "ID",       kind = .Fixed,        value = 8,  min_width = 8,  align = .Left},
		{header = "Module",   kind = .Auto_Content, min_width = 16, max_width = 28, align = .Left},
		{header = "Category", kind = .Fixed,        value = 12, min_width = 10, align = .Center},
		{header = "Status",   kind = .Fill,         value = 1,  min_width = 8,  align = .Right},
	}

	// Register declarative struct-tag key-chord bindings + Command Palette
	bifrost.clear_keybindings(&app.input)
	bifrost.command_palette_init(&app.palette, &app.input)
	_ = bifrost.register_actions_struct(&app.input, &app.palette, Gallery_Actions{})

	bifrost.bind_splitter_key(&app.input, bifrost.Key_Event{code = .Rune, ch = 'b', mods = {.Ctrl}}, "gallery_split", -4, "split.narrow")
	bifrost.bind_splitter_key(&app.input, bifrost.Key_Event{code = .Rune, ch = 'f', mods = {.Ctrl}}, "gallery_split", +4, "split.widen")
	bifrost.register_command(&app.palette, "split.widen",  "Widen Sidebar Splitter (+4 cols)",  "Layout")
	bifrost.register_command(&app.palette, "split.narrow", "Narrow Sidebar Splitter (-4 cols)", "Layout")

	return true
}

gallery_destroy :: proc(app: ^Gallery_App) {
	strings.builder_destroy(&app.ansi_builder)
	bifrost.xitdb_filter_destroy(&app.filter)
	bifrost.state_store_destroy(&app.state_store)
	bifrost.screen_destroy(&app.screen)
	app^ = {}
}

build_gallery_ui :: proc(app: ^Gallery_App, out_slice: ^bifrost.Virtual_Slice) {
	pal := THEMES[app.theme]
	w := app.screen.width
	h := app.screen.height

	bifrost.begin_frame(&app.screen, pal.bg)
	bifrost.begin_layout(&app.layout_ctx, w, h)

	filtered_total := bifrost.xitdb_filter_update(
		&app.filter,
		&app.input,
		"filter_input",
		"pkg_list",
		1,
		TOTAL_GALLERY_ROWS,
		format_package_row,
	)

	if bifrost.ui_scope(&app.layout_ctx, &app.screen, "gallery_root", bifrost.Scope_Config{
		dir    = .Column,
		width  = bifrost.fixed(w),
		height = bifrost.fixed(h),
	}) {
		// 1. Header Bar
		modal_depth := (1 if app.detail_modal_open else 0) + (1 if app.confirm_modal_open else 0) + (1 if app.palette.is_open else 0)
		split_w := bifrost.get_split_size(&app.input, "gallery_split", 30, 22, max(26, w - 34))
		header_text := fmt.tprintf(
			" BIFROST GALLERY | Theme: %s | Split: %dc | Matched: %d/%d | Modals: %d | Last: %s",
			pal.name,
			split_w,
			filtered_total,
			TOTAL_GALLERY_ROWS,
			modal_depth,
			app.last_action,
		)
		bifrost.set_paint(&app.screen, "header_bar", bifrost.Paint_Spec{
			text    = header_text,
			fg      = pal.accent_fg,
			bg      = pal.header_bg,
			style   = {.Bold},
			fill_bg = true,
		})
		bifrost.leaf(&app.layout_ctx, "header_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_text,
		})

		// 2. Main Body Row (Sidebar + Interactive Splitter + Content Area)
		if bifrost.ui_scope(&app.layout_ctx, &app.screen, "main_body", bifrost.Scope_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			// 2a. Left Sidebar Scope (`.Loop_Spatial` + `scrollable` same-frame scroll-into-view)
			bifrost.set_paint(&app.screen, "sidebar", bifrost.Paint_Spec{
				title       = "Controls & Filter",
				fg          = pal.text_fg,
				bg          = pal.panel_bg,
				border_fg   = pal.border_fg,
				title_fg    = pal.accent_fg,
				title_style = {.Bold},
				fill_bg     = true,
			})
			if bifrost.container(&app.layout_ctx, "sidebar", bifrost.Box_Config{
				dir         = .Column,
				width       = bifrost.fixed(split_w),
				height      = bifrost.grow(1),
				padding     = bifrost.pad_xy(1, 0),
				gap         = 1,
				border      = .Rounded,
				focus_flags = {.Focus_Scope, .Loop_Spatial},
				scrollable  = true,
			}) {
				// Immediate `.Auto_Edit` search input linked to `pkg_list`
				bifrost.ui_text_input(&app.layout_ctx, &app.screen, &app.input, "filter_input", bifrost.Text_Input_Config{
					placeholder    = "Auto-edit (↑/↓ rows)...",
					linked_list_id = "pkg_list",
					width          = bifrost.grow(1),
					height         = bifrost.fixed(3),
					border         = .Plain,
					fg             = pal.text_fg,
					bg             = pal.bg,
					placeholder_fg = pal.muted_fg,
					border_fg      = pal.border_fg,
					title          = "Auto-Edit Search (/)",
				})

				// Two-stage multi-line text area (`Enter`/`i` enters edit mode, `Escape` returns to 2D nav)
				bifrost.ui_text_area(&app.layout_ctx, &app.screen, &app.input, "notes_input", bifrost.Text_Area_Config{
					placeholder       = "Enter/i edits, Esc navs...",
					initial_text      = "todo: review\nship v1",
					width             = bifrost.grow(1),
					height            = bifrost.fixed(4),
					border            = .Plain,
					fg                = pal.text_fg,
					bg                = pal.bg,
					placeholder_fg    = pal.muted_fg,
					border_fg         = pal.border_fg,
					gutter_fg         = pal.muted_fg,
					title             = "Multi-Line Note (Enter/i)",
					two_stage         = true,
					show_line_numbers = true,
				})

				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_theme", bifrost.Button_Spec{
					label  = fmt.tprintf("Theme: %s (^T)", pal.name),
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = pal.text_fg,
					bg     = pal.header_bg,
				})
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_style", bifrost.Button_Spec{
					label  = fmt.tprintf("Bindings: %s (F2)", bifrost.keymap_style_name(app.input.keymap_style)),
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = pal.accent_fg,
					bg     = pal.header_bg,
				})
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_modal", bifrost.Button_Spec{
					label  = "Inspect Selected (m)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = pal.text_fg,
					bg     = pal.header_bg,
				})
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_palette", bifrost.Button_Spec{
					label  = "Command Palette (^P)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = pal.text_fg,
					bg     = pal.header_bg,
				})

				// Box-drawing junction preview placeholder
				bifrost.set_paint(&app.screen, "junction_box", bifrost.Paint_Spec{
					title     = "4-Bit Box Merge",
					fg        = pal.muted_fg,
					bg        = pal.bg,
					border_fg = pal.border_fg,
					fill_bg   = true,
				})
				bifrost.leaf(&app.layout_ctx, "junction_box", max(10, split_w - 4), 5, bifrost.Box_Config{
					width  = bifrost.grow(1),
					height = bifrost.fixed(5),
					border = .Plain,
				})

				// Below-fold action button exercising same-frame `scroll_node_into_view` + `.Loop_Spatial` wrap
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_clear_filter", bifrost.Button_Spec{
					label  = "Clear Filter (^L)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = pal.accent_fg,
					bg     = pal.header_bg,
				})
			}

			// 2b. Interactive 1-Cell Vertical Splitter
			bifrost.ui_splitter(&app.layout_ctx, &app.screen, &app.input, "gallery_split", bifrost.Splitter_Config{
				dir          = .Row,
				default_size = 30,
				min_first    = 22,
				min_second   = 32,
				step         = 2,
				fg           = pal.border_fg,
				bg           = pal.bg,
				active_fg    = pal.accent_fg,
			})

			// 2c. Right Workspace Column (2D `.Wrap_Spatial` Flexbox Grid + 2D Virtualized Table)
			if bifrost.container(&app.layout_ctx, "workspace", bifrost.Box_Config{
				dir    = .Column,
				width  = bifrost.grow(1),
				height = bifrost.grow(1),
			}) {
				// Top 2x2 Flexbox Sizing Grid (`{.Focus_Scope, .Focusable, .Wrap_Spatial}` with `Enter`/`Escape` drill)
				is_grid_focused := bifrost.is_focused(&app.input, "flex_grid")
				bifrost.set_paint(&app.screen, "flex_grid", bifrost.Paint_Spec{
					title       = "2D Flexbox Grid (.Wrap_Spatial — Enter/Esc)",
					fg          = pal.text_fg,
					bg          = pal.panel_bg,
					border_fg   = pal.sel_fg if is_grid_focused else pal.border_fg,
					title_fg    = pal.accent_fg,
					title_style = {.Bold},
					fill_bg     = true,
				})
				if bifrost.container(&app.layout_ctx, "flex_grid", bifrost.Box_Config{
					dir         = .Column,
					width       = bifrost.grow(1),
					height      = bifrost.fixed(5),
					padding     = bifrost.pad_xy(1, 0),
					gap         = 1,
					border      = .Rounded,
					focus_flags = {.Focus_Scope, .Focusable, .Wrap_Spatial},
				}) {
					if bifrost.container(&app.layout_ctx, "flex_row_top", bifrost.Box_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						gap    = 1,
					}) {
						bifrost.set_paint(&app.screen, "card_fixed", bifrost.Paint_Spec{
							fg = pal.text_fg, bg = pal.header_bg, fill_bg = true,
						})
						bifrost.leaf(&app.layout_ctx, "card_fixed", 0, 1, bifrost.Box_Config{
							width = bifrost.fixed(16), height = bifrost.fixed(1), main_align = .Center,
							focusable = true, clickable = true, hoverable = true,
						})

						bifrost.set_paint(&app.screen, "card_grow1", bifrost.Paint_Spec{
							fg = pal.accent_fg, bg = pal.header_bg, fill_bg = true,
						})
						bifrost.leaf(&app.layout_ctx, "card_grow1", 0, 1, bifrost.Box_Config{
							width = bifrost.grow(1, min = 13), height = bifrost.fixed(1), main_align = .Center,
							focusable = true, clickable = true, hoverable = true,
						})
					}

					if bifrost.container(&app.layout_ctx, "flex_row_bot", bifrost.Box_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						gap    = 1,
					}) {
						bifrost.set_paint(&app.screen, "card_grow2", bifrost.Paint_Spec{
							fg = pal.sel_fg, bg = pal.header_bg, fill_bg = true,
						})
						bifrost.leaf(&app.layout_ctx, "card_grow2", 0, 1, bifrost.Box_Config{
							width = bifrost.grow(2, min = 15), height = bifrost.fixed(1), main_align = .Center,
							focusable = true, clickable = true, hoverable = true,
						})

						bifrost.set_paint(&app.screen, "card_pct", bifrost.Paint_Spec{
							fg = pal.muted_fg, bg = pal.header_bg, fill_bg = true,
						})
						bifrost.leaf(&app.layout_ctx, "card_pct", 0, 1, bifrost.Box_Config{
							width = bifrost.percent(0.35, min = 12), height = bifrost.fixed(1), main_align = .Center,
							focusable = true, clickable = true, hoverable = true,
						})
					}
				}

				// Virtualized 2D Module Table (`ui_virtual_list` inside `pkg_scope`)
				pkg_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("pkg_list"))
				active_col := clamp(pkg_slot.selected_col, 0, i32(len(app.col_specs) - 1))
				if bifrost.ui_scope(&app.layout_ctx, &app.screen, "pkg_scope", bifrost.Scope_Config{
					dir    = .Column,
					width  = bifrost.grow(1),
					height = bifrost.grow(1),
				}) {
					if bifrost.ui_virtual_list(
						&app.layout_ctx,
						&app.screen,
						&app.input,
						"pkg_list",
						filtered_total,
						bifrost.Virtual_List_Config{
							title          = fmt.tprintf("Virtualized Modules (%d rows | Col: %s)", filtered_total, app.col_specs[active_col].header),
							width          = bifrost.grow(1),
							height         = bifrost.grow(1),
							border         = .Rounded,
							fg             = pal.text_fg,
							bg             = pal.panel_bg,
							border_fg      = pal.border_fg,
							title_fg       = pal.accent_fg,
							scroll_step    = 3,
							scroll_padding = 1,
							fallback_rows  = max(4, h - 10),
							total_cols     = len(app.col_specs),
						},
						out_slice,
					) {
						for vis_r := out_slice.start_row; vis_r < out_slice.end_row; vis_r += 1 {
							row_id := fmt.tprintf("pkg_row_%d", vis_r)
							bifrost.leaf(&app.layout_ctx, row_id, 20, 1, bifrost.Box_Config{
								width     = bifrost.grow(1),
								height    = bifrost.fixed(1),
								clickable = true,
								hoverable = true,
							})
						}
					}
				}
			}
		}

		// 3. Live Focus Breadcrumb Bar + Contextual Key-Hint Bar
		bifrost.ui_focus_breadcrumb_bar(&app.layout_ctx, &app.screen, &app.input, "gallery_breadcrumb", bifrost.Breadcrumb_Bar_Config{
			fg        = pal.muted_fg,
			bg        = pal.header_bg,
			active_fg = pal.sel_fg,
			sep_fg    = pal.border_fg,
		})
		bifrost.ui_key_hint_bar(&app.layout_ctx, &app.screen, &app.input, "gallery_hint_bar", bifrost.Key_Hint_Bar_Config{
			key_fg  = pal.accent_fg,
			desc_fg = pal.text_fg,
			sep_fg  = pal.border_fg,
			bg      = pal.bg,
		})
	}

	// 4. Optional Modal Layer 1 (`z_layer = 20`, `.Dim_Screen` 50% RGB backdrop dimming)
	if app.detail_modal_open {
		sel_idx := bifrost.get_selected_row(&app.input, "pkg_list")
		db_row := sel_idx
		if app.filter.query_len > 0 && int(sel_idx) < len(app.filter.matched_indices) {
			db_row = app.filter.matched_indices[sel_idx]
		}
		mod_name := MODULE_NAMES[int(max(0, db_row)) % len(MODULE_NAMES)]
		mod_cat  := MODULE_CATEGORIES[int(max(0, db_row)) % len(MODULE_CATEGORIES)]

		if bifrost.ui_modal(&app.layout_ctx, &app.screen, "detail_modal", bifrost.Modal_Spec{
			title     = fmt.tprintf("Module Inspector: pkg-%04d", db_row),
			z_layer   = 20,
			width     = bifrost.fixed(52),
			height    = bifrost.fixed(10),
			padding   = bifrost.pad_xy(2, 1),
			gap       = 1,
			border    = .Double,
			fg        = pal.text_fg,
			bg        = pal.panel_bg,
			border_fg = pal.accent_fg,
			title_fg  = pal.sel_fg,
			backdrop  = .Dim_Screen,
		}) {
			bifrost.ui_label(&app.layout_ctx, &app.screen, "mdl_l1", fmt.tprintf("Module Path : %s", mod_name), pal.text_fg, {.Bold})
			bifrost.ui_label(&app.layout_ctx, &app.screen, "mdl_l2", fmt.tprintf("Category    : %s (50%% RGB Dim_Screen active)", mod_cat), pal.muted_fg)

			if bifrost.container(&app.layout_ctx, "mdl_btns", bifrost.Box_Config{
				dir    = .Row,
				width  = bifrost.grow(1),
				height = bifrost.fixed(1),
				gap    = 2,
			}) {
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_nested_modal", bifrost.Button_Spec{
					label  = "Open Nested Modal (z=25)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = pal.text_fg,
					bg     = pal.header_bg,
				})
				bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_close_detail", bifrost.Button_Spec{
					label  = "Close (Esc)",
					width  = bifrost.fixed(15),
					height = bifrost.fixed(1),
					fg     = pal.text_fg,
					bg     = pal.sel_bg,
				})
			}
		}
	}

	// 5. Optional Nested Confirmation Modal (`z_layer = 25`, LIFO focus restoration)
	if app.confirm_modal_open {
		if bifrost.ui_modal(&app.layout_ctx, &app.screen, "confirm_modal", bifrost.Modal_Spec{
			title     = "Nested LIFO Focus Shield (z=25)",
			z_layer   = 25,
			width     = bifrost.fixed(44),
			height    = bifrost.fixed(7),
			padding   = bifrost.pad_xy(2, 1),
			gap       = 1,
			border    = .Rounded,
			fg        = pal.text_fg,
			bg        = pal.header_bg,
			border_fg = pal.sel_fg,
			title_fg  = pal.sel_fg,
			backdrop  = .Dim_Rect,
		}) {
			bifrost.ui_label(&app.layout_ctx, &app.screen, "cfm_lbl", "Focus restores to parent modal on Esc!", pal.text_fg)
			bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_close_confirm", bifrost.Button_Spec{
				label  = "Confirm & Pop Scope (Enter/Esc)",
				width  = bifrost.grow(1),
				height = bifrost.fixed(1),
				fg     = pal.sel_fg,
				bg     = pal.panel_bg,
			})
		}
	}

	// 6. Command Palette (`z_layer = 30`) & Pending Chord Which-Key Overlay (`z_layer = 28`)
	bifrost.ui_command_palette(&app.layout_ctx, &app.screen, &app.input, &app.palette, 56, 6)
	bifrost.ui_which_key_overlay(&app.layout_ctx, &app.screen, &app.input, "gallery_which_key")

	bifrost.end_layout(&app.layout_ctx)

	// Populate live solved Flexbox widths into the top showcase cards
	if r, ok := bifrost.get_rect(&app.layout_ctx, "card_fixed"); ok {
		p := app.screen.paints[bifrost.hash_id("card_fixed")]
		p.text = fmt.tprintf("Fixed=%dc", r.w)
		app.screen.paints[bifrost.hash_id("card_fixed")] = p
	}
	if r, ok := bifrost.get_rect(&app.layout_ctx, "card_grow1"); ok {
		p := app.screen.paints[bifrost.hash_id("card_grow1")]
		p.text = fmt.tprintf("Grow(1)=%dc", r.w)
		app.screen.paints[bifrost.hash_id("card_grow1")] = p
	}
	if r, ok := bifrost.get_rect(&app.layout_ctx, "card_grow2"); ok {
		p := app.screen.paints[bifrost.hash_id("card_grow2")]
		p.text = fmt.tprintf("Grow(2)=%dc", r.w)
		app.screen.paints[bifrost.hash_id("card_grow2")] = p
	}
	if r, ok := bifrost.get_rect(&app.layout_ctx, "card_pct"); ok {
		p := app.screen.paints[bifrost.hash_id("card_pct")]
		p.text = fmt.tprintf("Pct(35%%)=%dc", r.w)
		app.screen.paints[bifrost.hash_id("card_pct")] = p
	}
}

paint_custom_overlays :: proc(app: ^Gallery_App, slice: bifrost.Virtual_Slice) {
	pal := THEMES[app.theme]

	// 1. Draw 4-Bit Direction Mask Box Junction Grid inside `"junction_box"`
	if jb_inner, ok := bifrost.get_inner_rect(&app.layout_ctx, "junction_box"); ok && jb_inner.w >= 6 && jb_inner.h >= 3 {
		jb_clip, _ := bifrost.get_node_clip(&app.layout_ctx, "junction_box")
		mid_y := jb_inner.y + jb_inner.h / 2
		mid_x := jb_inner.x + jb_inner.w / 2
		for x := jb_inner.x + 1; x < jb_inner.x + jb_inner.w - 1; x += 1 {
			bifrost.surface_merge_box_cell(&app.screen, x, mid_y, '─', bifrost.NORMAL_BORDER, pal.accent_fg, pal.bg, {}, jb_clip)
		}
		for y := jb_inner.y; y < jb_inner.y + jb_inner.h; y += 1 {
			bifrost.surface_merge_box_cell(&app.screen, mid_x - 3, y, '│', bifrost.NORMAL_BORDER, pal.sel_fg, pal.bg, {}, jb_clip)
			bifrost.surface_merge_box_cell(&app.screen, mid_x + 3, y, '│', bifrost.NORMAL_BORDER, pal.sel_fg, pal.bg, {}, jb_clip)
		}
	}

	// 2. Draw Jitter-Free Table Columns inside `"pkg_list"`
	//    Skip direct cell painting when a full-screen modal dims the background so dimming stays intact
	if app.detail_modal_open || app.palette.is_open {
		return
	}

	if list_inner, ok := bifrost.get_inner_rect(&app.layout_ctx, "pkg_list"); ok && list_inner.w > 4 && list_inner.h > 0 {
		list_clip, _ := bifrost.get_node_clip(&app.layout_ctx, "pkg_list")
		usable_rect := list_inner
		usable_rect.w = max(1, usable_rect.w - 1) // Reserve 1 col on right for vertical scrollbar

		// Observe visible cells first for monotonic high-water-mark Auto_Content sizing
		for vis_r := slice.start_row; vis_r < slice.end_row; vis_r += 1 {
			db_row := vis_r
			if app.filter.query_len > 0 && int(vis_r) < len(app.filter.matched_indices) {
				db_row = app.filter.matched_indices[vis_r]
			}
			mod_str := MODULE_NAMES[int(max(0, db_row)) % len(MODULE_NAMES)]
			bifrost.table_column_observe_cell(&app.col_specs[1], mod_str)
		}

		spans: [4]bifrost.Table_Column_Span
		bifrost.resolve_table_columns(app.col_specs[:], spans[:], usable_rect, 2, 2)
		bifrost.register_virtual_table_col_spans(&app.input, "pkg_list", spans[:])

		wk_rect, has_wk := bifrost.get_rect(&app.layout_ctx, "gallery_which_key")
		wk_saved: []bifrost.Cell
		if has_wk && wk_rect.w > 0 && wk_rect.h > 0 {
			wk_saved = make([]bifrost.Cell, int(wk_rect.w * wk_rect.h), context.temp_allocator)
			for ry: i32 = 0; ry < wk_rect.h; ry += 1 {
				sy := wk_rect.y + ry
				if sy < 0 || sy >= app.screen.height {
					continue
				}
				for rx: i32 = 0; rx < wk_rect.w; rx += 1 {
					sx := wk_rect.x + rx
					if sx >= 0 && sx < app.screen.width {
						wk_saved[int(ry * wk_rect.w + rx)] = app.screen.back[int(sy * app.screen.width + sx)]
					}
				}
			}
		}

		for vis_r := slice.start_row; vis_r < slice.end_row; vis_r += 1 {
			row_id := fmt.tprintf("pkg_row_%d", vis_r)
			row_rect, r_ok := bifrost.get_rect(&app.layout_ctx, row_id)
			if !r_ok {
				continue
			}
			row_clip := bifrost.rect_intersect(list_clip, row_rect)
			if row_clip.w <= 0 || row_clip.h <= 0 {
				continue
			}

			db_row := vis_r
			if app.filter.query_len > 0 && int(vis_r) < len(app.filter.matched_indices) {
				db_row = app.filter.matched_indices[vis_r]
			}

			is_sel := vis_r == slice.selected_row
			sel_col := clamp(slice.selected_col, 0, 3)
			row_bg := pal.sel_bg if is_sel else pal.panel_bg
			row_fg := pal.sel_fg if is_sel else pal.text_fg
			row_st := bifrost.Style_Flags{.Bold} if is_sel else bifrost.Style_Flags{}

			if is_sel {
				bifrost.fill_rect(&app.screen, usable_rect, row_clip, ' ', row_fg, row_bg, row_st)
				bifrost.put_text_clipped(&app.screen, usable_rect.x, row_rect.y, "▸", pal.sel_fg, row_bg, {.Bold}, row_clip)
			}

			id_str  := fmt.tprintf("#%04d", db_row)
			mod_str := MODULE_NAMES[int(max(0, db_row)) % len(MODULE_NAMES)]
			cat_str := MODULE_CATEGORIES[int(max(0, db_row)) % len(MODULE_CATEGORIES)]
			st_str  := MODULE_STATUSES[int(max(0, db_row)) % len(MODULE_STATUSES)]

			cell_texts := [4]string{id_str, mod_str, cat_str, st_str}
			cell_fgs   := [4]bifrost.Color{pal.muted_fg, pal.text_fg, pal.accent_fg, pal.muted_fg}
			for col_i := 0; col_i < 4; col_i += 1 {
				c_fg := row_fg if is_sel else cell_fgs[col_i]
				c_st := row_st
				if is_sel && i32(col_i) == sel_col {
					c_fg = pal.accent_fg
					c_st = {.Bold, .Reverse}
				}
				bifrost.draw_table_cell(&app.screen, spans[col_i], row_rect.y, row_clip, cell_texts[col_i], c_fg, row_bg, c_st)
			}
		}

		if len(wk_saved) > 0 {
			for ry: i32 = 0; ry < wk_rect.h; ry += 1 {
				sy := wk_rect.y + ry
				if sy < 0 || sy >= app.screen.height {
					continue
				}
				for rx: i32 = 0; rx < wk_rect.w; rx += 1 {
					sx := wk_rect.x + rx
					if sx >= 0 && sx < app.screen.width {
						app.screen.back[int(sy * app.screen.width + sx)] = wk_saved[int(ry * wk_rect.w + rx)]
					}
				}
			}
		}
	}
}

handle_gallery_interactions :: proc(app: ^Gallery_App, slice: bifrost.Virtual_Slice) -> bool {
	changed := false

	if bifrost.update_command_palette(&app.palette, &app.input) {
		changed = true
	}

	// Modal Escape / backdrop dismissal
	if app.confirm_modal_open && (bifrost.was_modal_dismissed(&app.input, "confirm_modal") || bifrost.was_activated(&app.input, "btn_close_confirm")) {
		app.confirm_modal_open = false
		app.last_action = "modal.confirm.closed"
		app.action_count += 1
		return true
	}
	if app.detail_modal_open && (bifrost.was_modal_dismissed(&app.input, "detail_modal") || bifrost.was_activated(&app.input, "btn_close_detail")) {
		app.detail_modal_open = false
		app.last_action = "modal.detail.closed"
		app.action_count += 1
		return true
	}
	if app.detail_modal_open && bifrost.was_activated(&app.input, "btn_nested_modal") {
		app.confirm_modal_open = true
		app.last_action = "modal.confirm.opened"
		app.action_count += 1
		return true
	}

	// Typed Gallery_Action dispatch + sidebar button activations
	act, has_act := bifrost.triggered_action(&app.input, Gallery_Action)
	if bifrost.was_activated(&app.input, "btn_theme") || (has_act && act == .Theme_Cycle) || bifrost.was_action_triggered(&app.input, "theme.cycle") {
		app.theme = Theme_Preset((int(app.theme) + 1) % len(Theme_Preset))
		app.last_action = fmt.tprintf("theme:%s", THEMES[app.theme].name)
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_style") || (has_act && act == .Style_Cycle) || bifrost.was_action_triggered(&app.input, "style.cycle") {
		next_st := bifrost.cycle_keymap_style(&app.input)
		app.last_action = fmt.tprintf("style:%s", bifrost.keymap_style_name(next_st))
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_modal") || (has_act && act == .Modal_Open) || bifrost.was_action_triggered(&app.input, "modal.open") {
		app.detail_modal_open = true
		app.last_action = "modal.detail.opened"
		app.action_count += 1
		changed = true
	}
	if has_act && act == .Jump_Top {
		slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("pkg_list"))
		slot.selected_row = 0
		slot.offset       = 0
		app.last_action   = "pkg.jump_top"
		app.action_count += 1
		changed = true
	}
	if has_act && act == .Jump_Bottom {
		slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("pkg_list"))
		last_r := max(i32(0), slot.total_rows - 1)
		slot.selected_row = last_r
		slot.offset       = max(i32(0), last_r - max(i32(1), slot.viewport_rows) + 1)
		app.last_action   = "pkg.jump_bottom"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_palette") {
		app.palette.is_open = true
		bifrost.set_text(&app.input, app.palette.input_id, "")
		app.palette.dirty = true
		bifrost.update_palette_matches(&app.palette, &app.input, "")
		app.input.wants_focus_id = bifrost.hash_id(app.palette.input_id)
		app.last_action = "palette.opened"
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Filter_Focus) || bifrost.was_action_triggered(&app.input, "filter.focus") {
		app.input.wants_focus_id = bifrost.hash_id("filter_input")
		app.last_action = "filter.focused"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_clear_filter") || (has_act && act == .Filter_Clear) || bifrost.was_action_triggered(&app.input, "filter.clear") {
		bifrost.set_text(&app.input, "filter_input", "")
		app.last_action = "filter.cleared"
		app.action_count += 1
		changed = true
	}

	grid_cards := [4]string{"card_fixed", "card_grow1", "card_grow2", "card_pct"}
	for card_id in grid_cards {
		if bifrost.was_activated(&app.input, card_id) {
			app.last_action = fmt.tprintf("grid:%s", card_id)
			app.action_count += 1
			changed = true
		}
	}
	if bifrost.was_action_triggered(&app.input, "split.widen") || bifrost.was_action_triggered(&app.input, "split.narrow") {
		app.last_action = app.input.triggered_action_name
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Quit) || bifrost.was_action_triggered(&app.input, "app.quit") {
		app.quit_requested = true
		app.last_action = "app.quit"
		changed = true
	}

	// Clicking a row in the virtual table selects both its row and the clicked column
	if app.input.clicked_id != 0 {
		for vis_r := slice.start_row; vis_r < slice.end_row; vis_r += 1 {
			row_id := fmt.tprintf("pkg_row_%d", vis_r)
			if app.input.clicked_id == bifrost.hash_id(row_id) {
				slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("pkg_list"))
				slot.selected_row = vis_r
				app.last_action = fmt.tprintf("row.select:%d:col%d", vis_r, slot.selected_col)
				changed = true
				break
			}
		}
	}

	return changed || (app.input.text_changed_id != 0) || (app.input.scrolled_id != 0)
}

step_gallery_frame :: proc(app: ^Gallery_App, events: ..bifrost.Input_Event) {
	bifrost.state_store_begin_frame(&app.state_store)

	slice: bifrost.Virtual_Slice
	build_gallery_ui(app, &slice)

	bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
	if handle_gallery_interactions(app, slice) || len(events) > 0 {
		build_gallery_ui(app, &slice)
		// Reconcile focus for any newly mounted modals/widgets in the same frame
		bifrost.resolve_input(&app.input, &app.layout_ctx)
	}

	bifrost.state_store_sync_from_layout(&app.state_store, &app.layout_ctx, &app.input)
	bifrost.apply_input_highlights(&app.screen, &app.layout_ctx, &app.input)
	bifrost.render_layout(&app.screen, &app.layout_ctx)
	paint_custom_overlays(app, slice)

	strings.builder_reset(&app.ansi_builder)
	_ = bifrost.screen_diff_ansi(&app.screen, &app.ansi_builder)
	app.frames_rendered += 1
}

extract_screen_row :: proc(s: ^bifrost.Screen, row: i32, alloc := context.temp_allocator) -> string {
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

run_gallery :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	cols: i32 = 100
	rows: i32 = 24
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			fmt.eprintln("Failed to initialize raw terminal")
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(60, ws.width)
			rows = max(16, ws.height)
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	app: Gallery_App
	if !gallery_init(&app, cols, rows, context.allocator) {
		return false
	}
	defer gallery_destroy(&app)

	if live_tty {
		step_gallery_frame(&app)
		if strings.builder_len(app.ansi_builder) > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
		}

		for !app.quit_requested {
			ev, has_ev, _ := bifrost.poll_next_event(&term, 16)
			if has_ev {
				if res_ev, is_res := ev.(bifrost.Resize_Event); is_res {
					_ = bifrost.screen_resize(&app.screen, max(60, res_ev.width), max(16, res_ev.height))
				}
				step_gallery_frame(&app, ev)
				if strings.builder_len(app.ansi_builder) > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
				}
			}
			free_all(context.temp_allocator)
		}
	} else {
		// Deterministic headless showcase walkthrough:
		// 1. Initial frame render (focused on pkg_list)
		step_gallery_frame(&app)

		// 2. Press '/' to focus the UTF-8 search input, type "bifrost", and navigate down 2 rows via Telescope-style linked list
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = '/'})
		for ch in "bifrost" {
			step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = ch})
		}
		step_gallery_frame(&app, bifrost.Key_Event{code = .Down})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Down})

		// 3. Widen splitter via Ctrl+F shortcut and cycle theme via Ctrl+T
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'f', mods = {.Ctrl}})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 't', mods = {.Ctrl}})

		// 4. Clear filter via Ctrl+L, press Escape to return focus from filter_input -> pkg_list,
		//    step down and fire 2-step chord "g g" (.Jump_Top), step 2D columns ('l'/'h'),
		//    bubble left to splitter, exercise [RESIZE] submode (Enter -> 'l' -> Esc), and enter sidebar
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l', mods = {.Ctrl}})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'}) // 2-step chord -> pkg.jump_top
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'h'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'h'}) // back at col 0
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'h'}) // bubble out to splitter
		step_gallery_frame(&app, bifrost.Key_Event{code = .Enter})          // enter splitter [RESIZE] submode
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'}) // widen splitter by +2 cols
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape})         // exit splitter [RESIZE] submode
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'h'}) // enter sidebar via H* (`filter_input`)

		// 5. Tab from `.Auto_Edit` `filter_input` -> two-stage multi-line `notes_input` (sticky edit carry), Escape to nav, Enter to edit, insert newline + "ok", Escape, then scroll sidebar
		step_gallery_frame(&app, bifrost.Key_Event{code = .Tab})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape}) // exit carried edit mode -> navigation mode on `notes_input`
		step_gallery_frame(&app, bifrost.Key_Event{code = .Enter})  // two-stage Enter -> edit mode on `notes_input`
		step_gallery_frame(&app, bifrost.Key_Event{code = .Enter})  // insert newline in multi-line text area
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'o'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'k'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape}) // exit edit mode -> resume 2D nav in `sidebar`
		for _ in 0 ..< 4 {
			step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // scrolls `btn_clear_filter` into view on same frame
		}
		for _ in 0 ..< 4 {
			step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'k'}) // scrolls back up to `notes_input`
		}

		// 6. Press F6 into `flex_grid`, wrap 2D reading order ('l' x2 -> Row 1 `card_grow2`), Escape drill-up to `flex_grid`, and 'j' down to `pkg_list`
		step_gallery_frame(&app, bifrost.Key_Event{code = .F6})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'}) // select Col 1 ("Module")

		// 7. Open Detail Modal (z=20) -> Nested Confirm Modal (z=25) -> Dismiss both via LIFO Escape
		step_gallery_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'm'})
		step_gallery_frame(&app, bifrost.Key_Event{code = .Enter}) // Activate btn_nested_modal
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape}) // Pop confirm_modal (z=25 -> z=20)
		step_gallery_frame(&app, bifrost.Key_Event{code = .Escape}) // Pop detail_modal (z=20 -> z=0)

		pkg_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("pkg_list"))
		fmt.printf(
			"[Bifrost Widget Gallery] theme=%s split=%d selected_row=%d selected_col=%d frames=%d actions=%d\n",
			THEMES[app.theme].name,
			bifrost.get_split_size(&app.input, "gallery_split"),
			bifrost.get_selected_row(&app.input, "pkg_list"),
			pkg_slot.selected_col,
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
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

	ok := run_gallery(live_tty)

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
