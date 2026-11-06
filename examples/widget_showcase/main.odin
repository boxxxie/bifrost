package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "../../bifrost"

// =============================================================================
// Bifrost Widget Showcase (Tracks 11-14 Unified Interactive Demo)
// =============================================================================
// Demonstrates all four new core widget primitives working together in a single
// zero-allocation immediate-mode TUI application:
//   - Track 12: `ui_tree` — Virtualized collapsible architecture tree (`├─`, `╰─`, `│`, `▾`/`▸`)
//   - Track 13: `ui_tabs` — Focus-Scope-Integrated Tab Bar with $H^*$ deep focus restoration
//   - Track 11: `ui_text_area` — Multi-line UTF-8/grapheme editor with line numbers, sticky `preferred_col`, selection & OSC 52
//   - Track 14: `ui_canvas` & `ui_sparkline` — Sub-cell 2x4 Braille (`U+2800..U+28FF`) & 8-level vertical block (`▁▂▃▄▅▆▇█`) plots

Theme_Preset :: enum u8 {
	Nord = 0,
	Tokyo_Night,
	Gruvbox,
}

Theme_Palette :: struct {
	name:      string,
	bg:        bifrost.Color,
	panel_bg:  bifrost.Color,
	header_bg: bifrost.Color,
	accent_fg: bifrost.Color,
	series_a:  bifrost.Color,
	series_b:  bifrost.Color,
	text_fg:   bifrost.Color,
	muted_fg:  bifrost.Color,
	border_fg: bifrost.Color,
	sel_bg:    bifrost.Color,
	sel_fg:    bifrost.Color,
}

@(rodata)
THEMES := [Theme_Preset]Theme_Palette{
	.Nord = {
		name      = "Nord",
		bg        = {kind = .RGB, r = 22,  g = 26,  b = 34},
		panel_bg  = {kind = .RGB, r = 28,  g = 34,  b = 45},
		header_bg = {kind = .RGB, r = 36,  g = 46,  b = 66},
		accent_fg = {kind = .RGB, r = 136, g = 192, b = 208},
		series_a  = {kind = .RGB, r = 163, g = 190, b = 140},
		series_b  = {kind = .RGB, r = 235, g = 203, b = 139},
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
		series_a  = {kind = .RGB, r = 158, g = 206, b = 106},
		series_b  = {kind = .RGB, r = 247, g = 118, b = 142},
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
		series_a  = {kind = .RGB, r = 184, g = 187, b = 38},
		series_b  = {kind = .RGB, r = 254, g = 128, b = 25},
		text_fg   = {kind = .RGB, r = 235, g = 219, b = 178},
		muted_fg  = {kind = .RGB, r = 168, g = 153, b = 132},
		border_fg = {kind = .RGB, r = 102, g = 92,  b = 84},
		sel_bg    = {kind = .RGB, r = 80,  g = 73,  b = 69},
		sel_fg    = {kind = .RGB, r = 254, g = 128, b = 25},
	},
}

Showcase_Action :: enum u8 {
	None = 0,
	Theme_Cycle,
	Style_Cycle,
	Pulse_Telemetry,
	Focus_Tree,
	Focus_Editor,
	Quit,
}

Showcase_Actions :: struct {
	Theme_Cycle:     Showcase_Action `bifrost:"key=<C-t>, id=theme.cycle, allow_in_edit=true, desc=Theme, label=Cycle Color Theme (Nord / Tokyo / Gruvbox), category=Appearance"`,
	Style_Cycle:     Showcase_Action `bifrost:"key=<F2>, id=style.cycle, policy=global, allow_in_edit=true, desc='Bindings (F2)', label='Cycle Keymap Style (Vim / Helix / Emacs) [F2]', category=Keymap"`,
	Pulse_Telemetry: Showcase_Action `bifrost:"vim=p, helix=<Space> p, emacs=<C-x> p, id=telemetry.pulse, desc=Pulse, label=Advance Telemetry Wave Phase, category=Telemetry"`,
	Focus_Tree:      Showcase_Action `bifrost:"vim=g t, helix=g t, emacs=<C-x> t, id=nav.tree, desc=Tree, label=Focus Architecture Tree Explorer, category=Navigation"`,
	Focus_Editor:    Showcase_Action `bifrost:"vim=g n, helix=g n, emacs=<C-x> n, id=nav.editor, desc=Editor, label=Switch to Tab 1 & Focus Notes Editor, category=Navigation"`,
	Quit:            Showcase_Action `bifrost:"vim=q|<C-q>|<C-c>, helix=q|<C-q>|<C-c>, emacs=<C-x> c|<C-q>, id=app.quit, policy=global, desc=Quit, label=Quit Widget Showcase, category=System"`,
}

@(rodata)
SHOWCASE_TREE_NODES := [18]bifrost.Tree_Node{
	{id = "root_bifrost",    label = "bifrost/",              icon = "📦 ", depth = 0, expanded = true,  has_children = true},
	{id = "dir_core",        label = "core/",                 icon = "📂 ", depth = 1, expanded = true,  has_children = true},
	{id = "mod_layout",      label = "layout.odin",           icon = "📐 ", depth = 2, expanded = false, has_children = false},
	{id = "mod_renderer",    label = "renderer.odin",         icon = "🎨 ", depth = 2, expanded = false, has_children = false},
	{id = "mod_input",       label = "input.odin",            icon = "⌨  ", depth = 2, expanded = false, has_children = false},
	{id = "mod_spatial",     label = "spatial_nav.odin",      icon = "🧭 ", depth = 2, expanded = false, has_children = false},
	{id = "dir_widgets",     label = "widgets/",              icon = "📂 ", depth = 1, expanded = true,  has_children = true},
	{id = "mod_text_area",   label = "text_area.odin (T11)",  icon = "📝 ", depth = 2, expanded = false, has_children = false},
	{id = "mod_tree",        label = "tree.odin (T12)",       icon = "🌲 ", depth = 2, expanded = false, has_children = false},
	{id = "mod_tabs",        label = "tabs.odin (T13)",       icon = "🗂  ", depth = 2, expanded = false, has_children = false},
	{id = "mod_canvas",      label = "canvas.odin (T14)",     icon = "📊 ", depth = 2, expanded = false, has_children = false},
	{id = "dir_tests",       label = "tests/",                icon = "🧪 ", depth = 1, expanded = true,  has_children = true},
	{id = "spec_text_area",  label = "spec_text_area.odin",   icon = "✓ ",  depth = 2, expanded = false, has_children = false},
	{id = "spec_tree",       label = "spec_tree.odin",        icon = "✓ ",  depth = 2, expanded = false, has_children = false},
	{id = "spec_tabs",       label = "spec_tabs.odin",        icon = "✓ ",  depth = 2, expanded = false, has_children = false},
	{id = "spec_canvas",     label = "spec_canvas.odin",      icon = "✓ ",  depth = 2, expanded = false, has_children = false},
	{id = "root_sleipnir",   label = "deps/sleipnir/",        icon = "🐎 ", depth = 0, expanded = false, has_children = true},
	{id = "mod_scheduler",   label = "scheduler.odin",        icon = "⚡ ", depth = 1, expanded = false, has_children = false},
}

@(rodata)
NODE_DOC_SNIPPETS := [18]string{
	"bifrost/: Zero-allocation terminal UI framework in Odin.\nFeatures Flexbox layout, SGR diffing, and 2D spatial focus.",
	"core/: Layout solver, cell renderer, 3-phase input router, and directional cone scorer.",
	"layout.odin: 3-pass Flexbox layout engine (bottom-up intrinsic, top-down distribution, absolute screen rects).",
	"renderer.odin: Double-buffered Cell grid, 4-bit box-drawing junctions, and run-length ANSI SGR diffing.",
	"input.odin: 3-phase Capturing -> At_Target -> Bubbling input dispatch + modal Trap_Focus shields.",
	"spatial_nav.odin: Directional cone hit-testing with sticky preferred_nav_pos lane memory.",
	"widgets/: High-density interactive terminal widgets (Tracks 11-14).",
	"text_area.odin (Track 11):\n- 2D UTF-8/grapheme cursor & sticky preferred_col\n- Shift+Arrow selection & OSC 52 clipboard\n- Optional 1-based line-number gutter",
	"tree.odin (Track 12):\n- Box-drawing guides (├─, ╰─, │, ▾, ▸)\n- h/l/Left/Right expand/collapse & parent jump\n- O(visible_rows) virtualization for 10,000+ nodes",
	"tabs.odin (Track 13):\n- Per-tab Focus_Scope containers with H* deep restoration\n- [/] & Alt+1..9 keyboard switching\n- Active tab brackets & badge indicators",
	"canvas.odin (Track 14):\n- 2x4 sub-cell Unicode Braille (U+2800..U+28FF)\n- Integer Bresenham line/rect/series plotting\n- 8-level vertical block sparklines (▁▂▃▄▅▆▇█)",
	"tests/: 4-Layer ATDD executable specifications (@(scenario)) verified against in-memory VT.",
	"spec_text_area.odin: Verifies 2D editing, sticky preferred_col, viewport scrolling, and OSC 52 copy/cut.",
	"spec_tree.odin: Verifies box-drawing guides, expand/collapse/parent jump, and 10k-node virtualization.",
	"spec_tabs.odin: Verifies [ / ] / Alt+N switching and H* deep focus restoration across tabs.",
	"spec_canvas.odin: Verifies ISO/TR 11548-1 Braille bitmasks, Bresenham lines, and sparkline blocks.",
	"deps/sleipnir/: Lock-free MPSC actor scheduler powering the non-blocking UI Actor loop.",
	"scheduler.odin: Work-stealing actor runtime with bounded backpressure mailboxes.",
}

INITIAL_EDITOR_NOTES :: `// Bifrost Tracks 11-14 Interactive Notes
// Press Enter or 'i' to edit, Esc for 2D navigation.
track_11 :: "ui_text_area (2D UTF-8 editor + gutter)"
track_12 :: "ui_tree (virtualized collapsible tree)"
track_13 :: "ui_tabs (focus-scoped tabs + H* memory)"
track_14 :: "ui_canvas & ui_sparkline (Braille 2x4)"`

TELEMETRY_SAMPLES :: 48

Showcase_App :: struct {
	screen:          bifrost.Screen,
	layout_ctx:      bifrost.Layout_Context,
	input:           bifrost.Input_State,
	state_store:     bifrost.Widget_State_Store,
	palette:         bifrost.Command_Palette,
	ansi_builder:    strings.Builder,
	theme:           Theme_Preset,
	wave_phase:      f32,
	latency_series:  [TELEMETRY_SAMPLES]f32,
	fps_series:      [TELEMETRY_SAMPLES]f32,
	spark_ops:       [32]f32,
	spark_mem:       [32]int,
	last_tree_node:  i32,
	last_activated:  string,
	last_action:     string,
	action_count:    int,
	frames_rendered: int,
	quit_requested:  bool,
}

recompute_telemetry :: proc(app: ^Showcase_App) {
	for i := 0; i < TELEMETRY_SAMPLES; i += 1 {
		t := f32(i) * 0.22 + app.wave_phase
		app.latency_series[i] = 50.0 + 38.0 * math.sin_f32(t) + 10.0 * math.cos_f32(t * 2.1)
		app.fps_series[i]     = 52.0 + 34.0 * math.cos_f32(t * 0.85 - 0.6)
	}
	for i := 0; i < len(app.spark_ops); i += 1 {
		t := f32(i) * 0.35 + app.wave_phase
		app.spark_ops[i] = 10.0 + 85.0 * (0.5 + 0.5 * math.sin_f32(t))
		app.spark_mem[i] = 20 + int(60.0 * (0.5 + 0.5 * math.cos_f32(t * 0.7)))
	}
}

draw_telemetry_braille :: proc(c: ^bifrost.Braille_Canvas, userdata: rawptr) {
	app := (^Showcase_App)(userdata)
	if app == nil || c == nil || c.pixel_w <= 2 || c.pixel_h <= 2 {
		return
	}
	pal := THEMES[app.theme]

	// Subtle horizontal midline & perimeter frame in muted border color
	mid_y := c.pixel_h / 2
	for px: i32 = 0; px < c.pixel_w; px += 4 {
		bifrost.canvas_set_point(c, px, mid_y, pal.border_fg)
	}
	bifrost.canvas_draw_rect(c, 0, 0, c.pixel_w, c.pixel_h, pal.border_fg)

	// Plot dual sub-cell Braille series (Series A: Frame Throughput, Series B: P99 Latency)
	bifrost.canvas_draw_series(c, app.fps_series[:], 0.0, 100.0, pal.series_a)
	bifrost.canvas_draw_series(c, app.latency_series[:], 0.0, 100.0, pal.series_b)
}

showcase_init :: proc(app: ^Showcase_App, cols, rows: i32, allocator := context.allocator) -> bool {
	if bifrost.screen_init(&app.screen, cols, rows, allocator) != nil {
		return false
	}
	if bifrost.state_store_init(&app.state_store, allocator) != nil {
		bifrost.screen_destroy(&app.screen)
		return false
	}
	app.ansi_builder    = strings.builder_make(0, 8192, allocator)
	app.theme           = .Nord
	app.last_action     = "ready"
	app.last_activated  = "mod_text_area"
	app.last_tree_node  = 7 // `text_area.odin (T11)`
	app.wave_phase      = 0.0
	recompute_telemetry(app)

	// Seed initial multi-line editor content and focus the tree explorer first
	bifrost.set_text_area(&app.input, "notes_editor", INITIAL_EDITOR_NOTES)
	app.input.wants_focus_id = bifrost.hash_id("arch_tree")

	// Register declarative struct-tag keybindings + Command Palette
	bifrost.clear_keybindings(&app.input)
	bifrost.command_palette_init(&app.palette, &app.input)
	_ = bifrost.register_actions_struct(&app.input, &app.palette, Showcase_Actions{})

	bifrost.bind_splitter_key(&app.input, bifrost.Key_Event{code = .Rune, ch = 'b', mods = {.Ctrl}}, "showcase_split", -4, "split.narrow")
	bifrost.bind_splitter_key(&app.input, bifrost.Key_Event{code = .Rune, ch = 'f', mods = {.Ctrl}}, "showcase_split", +4, "split.widen")
	bifrost.register_command(&app.palette, "split.widen",  "Widen Tree Explorer Splitter (+4 cols)",  "Layout")
	bifrost.register_command(&app.palette, "split.narrow", "Narrow Tree Explorer Splitter (-4 cols)", "Layout")

	return true
}

showcase_destroy :: proc(app: ^Showcase_App) {
	strings.builder_destroy(&app.ansi_builder)
	bifrost.state_store_destroy(&app.state_store)
	bifrost.screen_destroy(&app.screen)
	app^ = {}
}

build_showcase_ui :: proc(app: ^Showcase_App, out_tree_slice: ^bifrost.Tree_Slice) {
	pal := THEMES[app.theme]
	w := app.screen.width
	h := app.screen.height

	bifrost.begin_frame(&app.screen, pal.bg)
	bifrost.begin_layout(&app.layout_ctx, w, h)

	if bifrost.ui_scope(&app.layout_ctx, &app.screen, "showcase_root", bifrost.Scope_Config{
		dir    = .Column,
		width  = bifrost.fixed(w),
		height = bifrost.fixed(h),
	}) {
		// 1. Top Header Bar
		active_tab := bifrost.get_active_tab(&app.input, "workspace_tabs")
		cur_row, cur_col, _ := bifrost.get_text_area_cursor(&app.input, "notes_editor")
		header_text := fmt.tprintf(
			" BIFROST SHOWCASE (Tracks 11-14) | Theme: %s | Tab: %d | Cursor: L%d:C%d | Last: %s",
			pal.name,
			active_tab + 1,
			cur_row + 1,
			cur_col + 1,
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

		// 2. Main Split Workspace: Left Collapsible Tree (`ui_tree`) | Splitter | Right Tabbed Workspace (`ui_tabs`)
		split_w := bifrost.get_split_size(&app.input, "showcase_split", 34, 24, max(28, w - 44))
		if bifrost.ui_scope(&app.layout_ctx, &app.screen, "main_body", bifrost.Scope_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			// 2a. Left Pane: Track 12 Virtualized Collapsible Tree (`ui_tree`)
			nodes_slice := SHOWCASE_TREE_NODES[:]
			bifrost.ui_tree(
				&app.layout_ctx,
				&app.screen,
				&app.input,
				"arch_tree",
				nodes_slice,
				bifrost.Tree_Config{
					title         = fmt.tprintf("Architecture Tree (%d vis)", bifrost.get_tree_visible_row_count(&app.input, "arch_tree")),
					width         = bifrost.fixed(split_w),
					height        = bifrost.grow(1),
					border        = .Rounded,
					fg            = pal.text_fg,
					bg            = pal.panel_bg,
					border_fg     = pal.border_fg,
					title_fg      = pal.accent_fg,
					guide_fg      = pal.muted_fg,
					toggle_fg     = pal.accent_fg,
					sel_fg        = pal.sel_fg,
					sel_bg        = pal.sel_bg,
					fallback_rows = max(6, h - 6),
				},
				out_tree_slice,
			)

			// 2b. Interactive 1-Cell Vertical Splitter
			bifrost.ui_splitter(&app.layout_ctx, &app.screen, &app.input, "showcase_split", bifrost.Splitter_Config{
				dir          = .Row,
				default_size = 34,
				min_first    = 24,
				min_second   = 44,
				step         = 2,
				fg           = pal.border_fg,
				bg           = pal.bg,
				active_fg    = pal.accent_fg,
			})

			// 2c. Right Pane: Track 13 Focus-Scope-Integrated Tab Bar (`ui_tabs`)
			tab_specs := [3]bifrost.Tab_Item_Spec{
				{label = "Editor & Docs",    badge = "T11", key_hint = "1:"},
				{label = "Braille Telemetry", badge = "T14", key_hint = "2:"},
				{label = "Inspector & Keys", badge = "T12/13", key_hint = "3:"},
			}

			cur_tab := 0
			if bifrost.ui_tabs(
				&app.layout_ctx,
				&app.screen,
				&app.input,
				"workspace_tabs",
				tab_specs[:],
				bifrost.Tabs_Config{
					width            = bifrost.grow(1),
					height           = bifrost.grow(1),
					body_dir         = .Column,
					body_padding     = bifrost.pad_xy(1, 0),
					body_gap         = 0,
					body_border      = .Rounded,
					fg               = pal.text_fg,
					bg               = pal.panel_bg,
					header_bg        = pal.header_bg,
					active_fg        = pal.sel_fg,
					active_bg        = pal.sel_bg,
					inactive_fg      = pal.muted_fg,
					inactive_bg      = pal.header_bg,
					badge_fg         = pal.accent_fg,
					sep_fg           = pal.border_fg,
					border_fg        = pal.border_fg,
					title_fg         = pal.accent_fg,
					title            = "Workspace ([ / ] or Alt+1..3 switches tabs with H* Focus Memory)",
					show_index_hints = true,
				},
				&cur_tab,
			) {
				sel_node := clamp(bifrost.get_tree_selected_node(&app.input, "arch_tree"), 0, i32(len(SHOWCASE_TREE_NODES) - 1))
				sel_label := SHOWCASE_TREE_NODES[sel_node].label
				sel_doc   := NODE_DOC_SNIPPETS[sel_node]

				switch cur_tab {
				case 0:
					// =========================================================
					// TAB 0: Track 11 Multi-Line Text Editor (`ui_text_area`)
					// =========================================================
					doc_banner := fmt.tprintf(" Selected Node [%s]: %s", sel_label, sel_doc)
					bifrost.set_paint(&app.screen, "node_doc_box", bifrost.Paint_Spec{
						text      = doc_banner,
						title     = fmt.tprintf("Tree Selection Context (#%d)", sel_node),
						fg        = pal.text_fg,
						bg        = pal.bg,
						border_fg = pal.border_fg,
						title_fg  = pal.accent_fg,
						fill_bg   = true,
					})
					bifrost.leaf(&app.layout_ctx, "node_doc_box", 40, 4, bifrost.Box_Config{
						width     = bifrost.grow(1),
						height    = bifrost.fixed(4),
						border    = .Plain,
						wrap_mode = .Words,
						text      = doc_banner,
					})

					// Multi-line UTF-8 Text Editor with line numbers, sticky preferred_col & two-stage modal editing
					ta_lines := bifrost.get_text_area_line_count(&app.input, "notes_editor")
					ta_r, ta_c, _ := bifrost.get_text_area_cursor(&app.input, "notes_editor")
					ta_pref := bifrost.get_text_area_state(&app.input, "notes_editor").preferred_col
					bifrost.ui_text_area(&app.layout_ctx, &app.screen, &app.input, "notes_editor", bifrost.Text_Area_Config{
						title             = fmt.tprintf("Multi-Line Editor (Lines: %d | Cur: %d:%d | PrefCol: %d)", ta_lines, ta_r + 1, ta_c + 1, ta_pref),
						placeholder       = "Press Enter or 'i' to edit multi-line notes...",
						width             = bifrost.grow(1),
						height            = bifrost.grow(1),
						border            = .Rounded,
						fg                = pal.text_fg,
						bg                = pal.bg,
						placeholder_fg    = pal.muted_fg,
						border_fg         = pal.border_fg,
						gutter_fg         = pal.muted_fg,
						two_stage         = true,
						show_line_numbers = true,
						tab_width         = 4,
						focus_flags       = {.Default_Focus},
					})

					// Editor Quick Action Bar
					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "editor_toolbar", bifrost.Scope_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						gap    = 2,
					}) {
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_insert_node", bifrost.Button_Spec{
							label  = "Append Selected Node Doc",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.text_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_reset_notes", bifrost.Button_Spec{
							label  = "Reset Notes",
							width  = bifrost.fixed(16),
							height = bifrost.fixed(1),
							fg     = pal.accent_fg,
							bg     = pal.header_bg,
						})
					}

				case 1:
					// =========================================================
					// TAB 1: Track 14 Braille Canvas & Sparklines
					// =========================================================
					bifrost.ui_canvas(&app.layout_ctx, &app.screen, "telemetry_canvas", bifrost.Canvas_Config{
						title       = "Sub-Cell 2x4 Braille Telemetry (Green: FPS | Gold: P99 Latency)",
						width       = bifrost.grow(1),
						height      = bifrost.grow(1),
						border      = .Rounded,
						fg          = pal.series_a,
						bg          = pal.bg,
						border_fg   = pal.border_fg,
						title_fg    = pal.accent_fg,
						fill_bg     = true,
						focus_flags = {.Focusable, .Default_Focus},
						draw_fn     = draw_telemetry_braille,
						userdata    = app,
					})

					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "sparkline_row", bifrost.Scope_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(3),
						gap    = 1,
					}) {
						bifrost.ui_sparkline(&app.layout_ctx, &app.screen, "spark_throughput", app.spark_ops[:], bifrost.Sparkline_Config{
							title     = "Actor Msg/s (▁..█)",
							width     = bifrost.grow(1),
							height    = bifrost.fixed(3),
							border    = .Plain,
							fg        = pal.series_a,
							bg        = pal.bg,
							border_fg = pal.border_fg,
							title_fg  = pal.accent_fg,
							fill_bg   = true,
							min_val   = 0.0,
							max_val   = 100.0,
						})
						bifrost.ui_sparkline(&app.layout_ctx, &app.screen, "spark_arena", app.spark_mem[:], bifrost.Sparkline_Config{
							title     = "Arena KB (▁..█)",
							width     = bifrost.grow(1),
							height    = bifrost.fixed(3),
							border    = .Plain,
							fg        = pal.series_b,
							bg        = pal.bg,
							border_fg = pal.border_fg,
							title_fg  = pal.accent_fg,
							fill_bg   = true,
							min_val   = 0.0,
							max_val   = 100.0,
						})
					}

					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "telemetry_toolbar", bifrost.Scope_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						gap    = 2,
					}) {
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_pulse_wave", bifrost.Button_Spec{
							label  = "Step Telemetry Phase (p)",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.text_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_theme_tab2", bifrost.Button_Spec{
							label  = fmt.tprintf("Cycle Theme: %s (^T)", pal.name),
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.accent_fg,
							bg     = pal.header_bg,
						})
					}

				case 2:
					// =========================================================
					// TAB 2: Track 12 & 13 Focus-Scope H* Memory & Tree Control
					// =========================================================
					info_text := fmt.tprintf(
						"Active Tree Node: #%d (%s) | Activated Leaf: %s | Visible Rows: %d/%d",
						sel_node,
						sel_label,
						app.last_activated,
						bifrost.get_tree_visible_row_count(&app.input, "arch_tree"),
						len(SHOWCASE_TREE_NODES),
					)
					bifrost.set_paint(&app.screen, "inspector_summary", bifrost.Paint_Spec{
						text      = info_text,
						title     = "Tree & Tab Scope State",
						fg        = pal.text_fg,
						bg        = pal.bg,
						border_fg = pal.border_fg,
						title_fg  = pal.accent_fg,
						fill_bg   = true,
					})
					bifrost.leaf(&app.layout_ctx, "inspector_summary", 40, 4, bifrost.Box_Config{
						width     = bifrost.grow(1),
						height    = bifrost.fixed(4),
						border    = .Plain,
						wrap_mode = .Words,
						text      = info_text,
					})

					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "inspector_actions", bifrost.Scope_Config{
						dir     = .Column,
						width   = bifrost.grow(1),
						height  = bifrost.grow(1),
						padding = bifrost.pad_xy(1, 1),
						gap     = 1,
						border  = .Rounded,
						title   = "H* Deep Focus Target Buttons (Switch tabs & return!)",
						fg      = pal.text_fg,
						bg      = pal.bg,
						border_fg = pal.border_fg,
						title_fg  = pal.accent_fg,
					}) {
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_expand_all", bifrost.Button_Spec{
							label       = "Expand All Tree Branches",
							width       = bifrost.grow(1),
							height      = bifrost.fixed(1),
							fg          = pal.text_fg,
							bg          = pal.header_bg,
							focus_flags = {.Default_Focus},
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_collapse_tests", bifrost.Button_Spec{
							label  = "Toggle 'tests/' Subtree Branch",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.accent_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_cycle_keymap", bifrost.Button_Spec{
							label  = fmt.tprintf("Keymap Style: %s (F2)", bifrost.keymap_style_name(app.input.keymap_style)),
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.text_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_open_palette", bifrost.Button_Spec{
							label  = "Open Command Palette (^P)",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.accent_fg,
							bg     = pal.header_bg,
						})
					}
				}
			}
		}

		// 3. Live Focus Breadcrumb Bar + Contextual Key-Hint Bar
		bifrost.ui_focus_breadcrumb_bar(&app.layout_ctx, &app.screen, &app.input, "showcase_breadcrumb", bifrost.Breadcrumb_Bar_Config{
			fg        = pal.muted_fg,
			bg        = pal.header_bg,
			active_fg = pal.sel_fg,
			sep_fg    = pal.border_fg,
		})
		bifrost.ui_key_hint_bar(&app.layout_ctx, &app.screen, &app.input, "showcase_hint_bar", bifrost.Key_Hint_Bar_Config{
			key_fg  = pal.accent_fg,
			desc_fg = pal.text_fg,
			sep_fg  = pal.border_fg,
			bg      = pal.bg,
		})
	}

	// 4. Floating Command Palette Overlay (`z=30`) + Which-Key Overlay (`z=28`)
	bifrost.ui_command_palette(&app.layout_ctx, &app.screen, &app.input, &app.palette, 56, 6)
	bifrost.ui_which_key_overlay(&app.layout_ctx, &app.screen, &app.input, "showcase_which_key")

	bifrost.end_layout(&app.layout_ctx)
}

handle_showcase_interactions :: proc(app: ^Showcase_App) -> bool {
	changed := false

	if bifrost.update_command_palette(&app.palette, &app.input) {
		changed = true
	}

	// Track 12: Check if a leaf node in `arch_tree` was activated via Enter / Space
	act_node := bifrost.get_tree_activated_node(&app.input, "arch_tree")
	if act_node >= 0 && int(act_node) < len(SHOWCASE_TREE_NODES) {
		app.last_tree_node = act_node
		app.last_activated = SHOWCASE_TREE_NODES[act_node].id
		app.last_action    = fmt.tprintf("tree.activate:%s", SHOWCASE_TREE_NODES[act_node].label)
		app.action_count  += 1
		changed = true
	}

	// Track 13: Check if active tab changed this frame
	if bifrost.was_tab_changed(&app.input, "workspace_tabs") {
		app.last_action   = fmt.tprintf("tab.switch:%d", bifrost.get_active_tab(&app.input, "workspace_tabs") + 1)
		app.action_count += 1
		changed = true
	}

	// Typed Showcase_Action dispatch + button activations
	act, has_act := bifrost.triggered_action(&app.input, Showcase_Action)
	if bifrost.was_activated(&app.input, "btn_theme_tab2") || (has_act && act == .Theme_Cycle) || bifrost.was_action_triggered(&app.input, "theme.cycle") {
		app.theme         = Theme_Preset((int(app.theme) + 1) % len(Theme_Preset))
		app.last_action   = fmt.tprintf("theme:%s", THEMES[app.theme].name)
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_cycle_keymap") || (has_act && act == .Style_Cycle) || bifrost.was_action_triggered(&app.input, "style.cycle") {
		next_st           := bifrost.cycle_keymap_style(&app.input)
		app.last_action    = fmt.tprintf("style:%s", bifrost.keymap_style_name(next_st))
		app.action_count  += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_pulse_wave") || (has_act && act == .Pulse_Telemetry) || bifrost.was_action_triggered(&app.input, "telemetry.pulse") {
		app.wave_phase   += 0.65
		recompute_telemetry(app)
		app.last_action   = "telemetry.pulse"
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Focus_Tree) || bifrost.was_action_triggered(&app.input, "nav.tree") {
		app.input.wants_focus_id = bifrost.hash_id("arch_tree")
		app.last_action          = "nav.tree"
		app.action_count        += 1
		changed = true
	}
	if (has_act && act == .Focus_Editor) || bifrost.was_action_triggered(&app.input, "nav.editor") {
		bifrost.set_active_tab(&app.input, "workspace_tabs", 0, true)
		app.input.wants_focus_id = bifrost.hash_id("notes_editor")
		app.last_action          = "nav.editor"
		app.action_count        += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_insert_node") {
		sel_node := clamp(bifrost.get_tree_selected_node(&app.input, "arch_tree"), 0, i32(len(SHOWCASE_TREE_NODES) - 1))
		snippet := fmt.tprintf("\n// Selected: %s", SHOWCASE_TREE_NODES[sel_node].label)
		slot := bifrost.get_text_area_state(&app.input, "notes_editor")
		_ = bifrost.text_area_insert_string(&app.input, slot, snippet)
		app.last_action   = "editor.append_node"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_reset_notes") {
		bifrost.set_text_area(&app.input, "notes_editor", INITIAL_EDITOR_NOTES)
		app.last_action   = "editor.reset"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_expand_all") {
		for idx: i32 = 0; idx < i32(len(SHOWCASE_TREE_NODES)); idx += 1 {
			if SHOWCASE_TREE_NODES[idx].has_children {
				bifrost.set_tree_node_expanded(&app.input, "arch_tree", idx, true)
			}
		}
		app.last_action   = "tree.expand_all"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_collapse_tests") {
		cur_exp := bifrost.is_tree_node_expanded(&app.input, "arch_tree", 11)
		bifrost.set_tree_node_expanded(&app.input, "arch_tree", 11, !cur_exp)
		app.last_action   = "tree.toggle_tests"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_open_palette") {
		app.palette.is_open = true
		bifrost.set_text(&app.input, app.palette.input_id, "")
		app.palette.dirty = true
		bifrost.update_palette_matches(&app.palette, &app.input, "")
		app.input.wants_focus_id = bifrost.hash_id(app.palette.input_id)
		app.last_action          = "palette.opened"
		app.action_count        += 1
		changed = true
	}
	if (has_act && act == .Quit) || bifrost.was_action_triggered(&app.input, "app.quit") {
		app.quit_requested = true
		app.last_action    = "app.quit"
		changed = true
	}

	return changed || (app.input.text_changed_id != 0) || (app.input.scrolled_id != 0) || (app.input.tab_changed_id != 0)
}

step_showcase_frame :: proc(app: ^Showcase_App, events: ..bifrost.Input_Event) {
	bifrost.state_store_begin_frame(&app.state_store)

	tree_slice: bifrost.Tree_Slice
	build_showcase_ui(app, &tree_slice)

	bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
	if handle_showcase_interactions(app) || len(events) > 0 {
		build_showcase_ui(app, &tree_slice)
		bifrost.resolve_input(&app.input, &app.layout_ctx)
	}

	bifrost.state_store_sync_from_layout(&app.state_store, &app.layout_ctx, &app.input)
	bifrost.apply_input_highlights(&app.screen, &app.layout_ctx, &app.input)
	bifrost.render_layout(&app.screen, &app.layout_ctx)

	strings.builder_reset(&app.ansi_builder)
	_ = bifrost.screen_diff_ansi(&app.screen, &app.ansi_builder)
	_ = bifrost.flush_osc52_clipboard(&app.input, &app.ansi_builder)
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

run_showcase :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	cols: i32 = 104
	rows: i32 = 26
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			fmt.eprintln("Failed to initialize raw terminal")
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(80, ws.width)
			rows = max(20, ws.height)
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	app: Showcase_App
	if !showcase_init(&app, cols, rows, context.allocator) {
		return false
	}
	defer showcase_destroy(&app)

	if live_tty {
		step_showcase_frame(&app)
		if strings.builder_len(app.ansi_builder) > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
		}

		for !app.quit_requested {
			ev, has_ev, _ := bifrost.poll_next_event(&term, 16)
			if has_ev {
				if res_ev, is_res := ev.(bifrost.Resize_Event); is_res {
					_ = bifrost.screen_resize(&app.screen, max(80, res_ev.width), max(20, res_ev.height))
				}
				step_showcase_frame(&app, ev)
				if strings.builder_len(app.ansi_builder) > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
				}
			}
			free_all(context.temp_allocator)
		}
	} else {
		// Deterministic headless walkthrough exercising all 4 new components together:
		// 1. Initial frame render (focused on `arch_tree` in the left pane)
		step_showcase_frame(&app)

		// 2. Track 12 (`ui_tree`): Navigate down to `core/` -> collapse `core/` via `h`,
		//    step down to `widgets/canvas.odin (T14)` (5 steps: `widgets/` -> `T11` -> `T12` -> `T13` -> `T14`),
		//    and activate `canvas.odin (T14)` with Enter!
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // `core/` (node 1)
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'h'}) // collapse `core/`! (4 children hidden)
		for _ in 0 ..< 5 {
			step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // step down to `canvas.odin (T14)` (node 10)
		}
		step_showcase_frame(&app, bifrost.Key_Event{code = .Enter}) // activate leaf node `canvas.odin (T14)`

		// 3. Focus Tab 0 (`Editor & Docs` — `notes_editor`) via 2-step chord `g n` (`Focus_Editor`),
		//    enter `.Editing` mode via Enter, append a comment line at the bottom, and press Escape to return to `.Navigation`
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'n'}) // 2-step chord `g n` -> `nav.editor` (`notes_editor`)
		step_showcase_frame(&app, bifrost.Key_Event{code = .Enter})          // two-stage Enter -> `.Editing` mode in `notes_editor`
		step_showcase_frame(&app, bifrost.Key_Event{code = .End})
		step_showcase_frame(&app, bifrost.Key_Event{code = .Enter})
		for ch in "// Verified in headless showcase!" {
			step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = ch})
		}
		step_showcase_frame(&app, bifrost.Key_Event{code = .Escape}) // exit `.Editing` -> `.Navigation` mode

		// 4. Track 13 (`ui_tabs`) + Track 14 (`ui_canvas` & `ui_sparkline`):
		//    Press `]` to switch to Tab 2 (`Braille Telemetry`), pulse the wave twice (`p`),
		//    then press `]` to switch to Tab 3 (`Inspector & Keys`), focus `btn_collapse_tests`,
		//    then press `Alt+1` to jump back to Tab 1 (verifying H* restores `notes_editor`),
		//    and finally press `Alt+2` to showcase the live Braille + Sparkline canvas on screen!
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = ']'}) // switch to Tab 2 (`Braille Telemetry`)
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'p'}) // pulse wave phase
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'p'}) // pulse wave phase again
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = ']'}) // switch to Tab 3 (`Inspector & Keys`)
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // move focus to `btn_collapse_tests` in Tab 3
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = '1', mods = {.Alt}}) // Alt+1 -> Tab 1 (`notes_editor` restored via H*)

		fmt.printf(
			"[Bifrost Showcase — Tab 1 (Multi-Line Editor + Collapsible Tree)] active_tab=%d tree_vis=%d editor_lines=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
			bifrost.get_tree_visible_row_count(&app.input, "arch_tree"),
			bifrost.get_text_area_line_count(&app.input, "notes_editor"),
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		// Switch to Tab 2 (`Alt+2`) so the headless output also prints the rendered Braille & Sparkline view
		step_showcase_frame(&app, bifrost.Key_Event{code = .Rune, ch = '2', mods = {.Alt}})
		fmt.printf(
			"\n[Bifrost Showcase — Tab 2 (2x4 Braille Canvas + 8-Level Sparklines)] active_tab=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
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

	ok := run_showcase(live_tty)

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
