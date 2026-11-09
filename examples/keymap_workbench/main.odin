package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "../../bifrost"
import xitdb "../../deps/xitdb/xitdb"

// =============================================================================
// Interactive Keymap, Which-Key & Clipboard Workbench (`examples/keymap_workbench`)
// =============================================================================
// Showcases all 6 standout features & code-review enhancements:
// 1. Pending Chord Timeout (`expire_pending_chord`), Prefix-Conflict Disambiguation
//    (1-step `g` vs 2-step `g g`/`g e`), and floating `ui_which_key_overlay` (z=28).
// 2. Horizontal Scrolling (`offset_x`), Horizontal `scroll_node_into_view` on a wide
//    action ribbon, and Mouse Column Selection (`register_virtual_table_col_spans` /
//    `select_virtual_col_at_x`).
// 3. Vim-Style Numeric Count Prefix (`repeat_count`: `5j` row jumps, `2l` column steps,
//    `4l` splitter `[RESIZE]` nudges, and live `[COUNT: Nx]` badge in `ui_key_hint_bar`).
// 4. Runtime Keybinding Conflict Detection (`find_keybinding_conflict`), Dynamic Rebinding
//    (`rebind_action_chord`), and `xitdb` Keymap Override Persistence
//    (`save_ui_workspace_to_xitdb` / `load_ui_workspace_from_xitdb`).
// 5. Explicit Directional Focus Overrides (`nav_overrides` / `nav_target(.Down, ...)`).
// 6. `ui_text_input` Visual Selection (`Shift+Arrows/Home/End`, `Ctrl+A`) & Clipboard
//    Cut/Copy/Paste (`Ctrl+X/C/V/Y` + base64 OSC 52 terminal sequence emission).
// 7. Single-Quote-Aware Struct Tags (`key=','`, `desc='Sync, Save & Verify'`).

Workbench_Action :: enum u8 {
	None = 0,
	Cycle_Style,
	Set_Style_Vim,
	Set_Style_Helix,
	Set_Style_Emacs,
	Quick_Mark,
	Jump_Top,
	Jump_Bottom,
	Rebind_Bookmark,
	Probe_Conflict,
	Sync_Workspace,
	Bookmark_Row,
	Quit,
}

Workbench_Actions :: struct {
	Cycle_Style:     Workbench_Action `bifrost:"key=<F2>, id=bench.style, policy=global, allow_in_edit=true, desc='Style (F2)', label='Cycle Binding Style (Vim / Helix / Emacs) [F2]', category=Keymap"`,
	Set_Style_Vim:   Workbench_Action `bifrost:"key=<F3>, id=bench.style_vim, policy=global, allow_in_edit=true, bar=false, desc='Vim (F3)', label='Switch to Vim Keybindings [F3]', category=Keymap"`,
	Set_Style_Helix: Workbench_Action `bifrost:"key=<F4>, id=bench.style_helix, policy=global, allow_in_edit=true, bar=false, desc='Helix (F4)', label='Switch to Helix Keybindings [F4]', category=Keymap"`,
	Set_Style_Emacs: Workbench_Action `bifrost:"key=<F5>, id=bench.style_emacs, policy=global, allow_in_edit=true, bar=false, desc='Emacs (F5)', label='Switch to Emacs Keybindings [F5]', category=Keymap"`,
	Quick_Mark:      Workbench_Action `bifrost:"vim=g, helix=g, emacs=<M-m>, id=bench.quick_mark, scope=keymap_*, desc='Quick Mark (g)', desc_vim='Quick Mark (1-Step g)', desc_helix='Quick Mark (1-Step g)', desc_emacs='set-mark-command (M-m)', label='Mark Current Row', category=Navigation"`,
	Jump_Top:        Workbench_Action `bifrost:"vim=g g, helix=g g, emacs=<C-x> [, id=bench.jump_top, scope=keymap_*, desc='Top Row (g g)', desc_vim='Top Row (g g)', desc_helix='Goto File Start (g g)', desc_emacs='beginning-of-buffer (C-x [)', label='Jump to First Keymap Row', category=Navigation"`,
	Jump_Bottom:     Workbench_Action `bifrost:"vim=G|g e, helix=g e, emacs=<C-x> ], id=bench.jump_bottom, scope=keymap_*, desc='Bottom, Last Row', desc_vim='Bottom, Last Row (G)', desc_helix='Goto File End (g e)', desc_emacs='end-of-buffer (C-x ])', label='Jump to Bottom, Last Keymap Row', category=Navigation"`,
	Bookmark_Row:    Workbench_Action `bifrost:"vim=m, helix=<Space> b, emacs=<C-x> b, id=bench.bookmark, desc='Bookmark, Pin', desc_vim='Bookmark, Pin (m)', desc_helix='Space Bookmark (SPC b)', desc_emacs='bookmark-set (C-x b)', label='Bookmark Selected Action Row', category=Keymap"`,
	Rebind_Bookmark: Workbench_Action `bifrost:"vim=<C-r>, helix=<Space> r, emacs=<C-x> r, id=bench.rebind, desc='Rebind Chord', desc_vim='Rebind m -> ^B (^R)', desc_helix='Rebind SPC b -> ^B (SPC r)', desc_emacs='global-set-key (C-x r)', label='Rebind bench.bookmark Chord to <C-b>', category=Keymap"`,
	Probe_Conflict:  Workbench_Action `bifrost:"vim=<C-k>, helix=<Space> k, emacs=<C-x> k, id=bench.conflict, desc='Probe Conflict', desc_vim='Probe Conflict (^K)', desc_helix='Probe Conflict (SPC k)', desc_emacs='describe-key-conflict (C-x k)', label='Test Runtime Keybinding Conflict Detector', category=Keymap"`,
	Sync_Workspace:  Workbench_Action `bifrost:"vim=',', helix=<Space> w, emacs=<C-x> s, id=bench.sync, desc='Sync, Save xitdb', desc_vim='Sync, Save xitdb (,)', desc_helix='Write Workspace (SPC w)', desc_emacs='save-some-buffers (C-x s)', label='Save Keymap Overrides & Workspace to xitdb', category=Persistence"`,
	Quit:            Workbench_Action `bifrost:"vim=q|<C-q>, helix=q|<C-q>, emacs=<C-x> c|<C-q>, id=app.quit, policy=global, desc=Quit, desc_vim='Quit (q)', desc_helix='Quit (:q / q)', desc_emacs='kill-emacs (C-x c)', label='Quit Keymap Workbench', category=System"`,
}

@(rodata)
RIBBON_PILLS := [6]struct {
	id:    string,
	label: string,
}{
	{id = "pill_vim",      label = " [F3] Style: Vim (5j) "},
	{id = "pill_helix",    label = " [F4] Style: Helix (j5) "},
	{id = "pill_emacs",    label = " [F5] Style: Emacs (C-u C-n) "},
	{id = "pill_chords",   label = " [F2] Cycle Style "},
	{id = "pill_rebind",   label = " [Rebind -> ^B] "},
	{id = "pill_portal",   label = " [Portal -> Target (j)] "},
}

TOTAL_BENCH_ROWS :: 24

Workbench_App :: struct {
	core:               xitdb.Core,
	db:                 xitdb.Database,
	screen:             bifrost.Screen,
	layout_ctx:         bifrost.Layout_Context,
	input:              bifrost.Input_State,
	state_store:        bifrost.Widget_State_Store,
	palette:            bifrost.Command_Palette,
	ansi_builder:       strings.Builder,
	col_specs:          [4]bifrost.Table_Column_Spec,
	marked_row:         i32,
	bookmarked_row:     i32,
	rebind_applied:     bool,
	conflict_report:    string,
	osc52_last_seq:     string,
	osc52_buf:          [256]u8,
	workspace_saved:    bool,
	workspace_restored: bool,
	quit_requested:     bool,
	action_count:       int,
	last_action:        string,
	frames_rendered:    int,
}

workbench_init :: proc(app: ^Workbench_App, cols, rows: i32, allocator := context.allocator) -> bool {
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

	app.ansi_builder    = strings.builder_make(0, 8192, allocator)
	app.marked_row      = -1
	app.bookmarked_row  = -1
	app.conflict_report = "none"
	app.osc52_last_seq  = "none"
	app.last_action     = "ready"
	app.input.wants_focus_id = bifrost.hash_id("keymap_table")

	app.col_specs = {
		{header = "Action ID",   kind = .Fixed,        value = 18, min_width = 14, align = .Left},
		{header = "Chord",       kind = .Fixed,        value = 10, min_width = 8,  align = .Center},
		{header = "Scope",       kind = .Auto_Content, min_width = 10, max_width = 16, align = .Center},
		{header = "Description", kind = .Fill,         value = 1,  min_width = 14, align = .Left},
	}

	bifrost.clear_keybindings(&app.input)
	bifrost.command_palette_init(&app.palette, &app.input)
	if !bifrost.register_actions_struct(&app.input, &app.palette, Workbench_Actions{}) {
		return false
	}

	return true
}

workbench_destroy :: proc(app: ^Workbench_App) {
	strings.builder_destroy(&app.ansi_builder)
	bifrost.state_store_destroy(&app.state_store)
	bifrost.screen_destroy(&app.screen)
	_ = xitdb.core_destroy(&app.core)
	app^ = {}
}

Builtin_Row_Spec :: struct {
	id:    string,
	chord: string,
	scope: string,
	desc:  string,
}

@(rodata)
STYLE_BUILTIN_ROWS := [bifrost.Keymap_Style][8]Builtin_Row_Spec{
	.Vim = {
		{id = "nav.row_step",     chord = "j / k",       scope = "keymap_*",   desc = "Vim Down / Up Row Motion"},
		{id = "nav.col_step",     chord = "h / l",       scope = "keymap_*",   desc = "Vim Left / Right Column Motion"},
		{id = "nav.count_prefix", chord = "[1-9]j/k",    scope = "keymap_*",   desc = "Vim Prefix Count Multiplier (5j)"},
		{id = "split.resize",     chord = "CR -> [N]h/l", scope = "splitter",  desc = "Splitter Prefix Resize Submode"},
		{id = "edit.select",      chord = "S-←/→ | ^A",  scope = "edit_box",   desc = "Visual Range Selection"},
		{id = "edit.clipboard",   chord = "^X/^C/^V",    scope = "edit_box",   desc = "Cut / Copy (OSC 52) / Paste"},
		{id = "nav.portal_jump",  chord = "j (override)", scope = "ribbon_bar", desc = "Explicit Directional Override"},
		{id = "cmd.palette",      chord = "<C-p>",       scope = "global",     desc = "Toggle Fuzzy Command Palette"},
	},
	.Helix = {
		{id = "nav.row_step",     chord = "j / k",       scope = "keymap_*",   desc = "Helix Motion-First Row Step"},
		{id = "nav.col_step",     chord = "h / l",       scope = "keymap_*",   desc = "Helix Motion-First Column Step"},
		{id = "nav.count_suffix", chord = "j[1-9]/k[N]", scope = "keymap_*",   desc = "Helix Postfix Suffix Count (j8, k3)"},
		{id = "split.resize",     chord = "CR -> h/l[N]", scope = "splitter",  desc = "Splitter Postfix Suffix Resize (l4)"},
		{id = "edit.select",      chord = "S-←/→ | ^A",  scope = "edit_box",   desc = "Selection-First Range Highlight"},
		{id = "edit.clipboard",   chord = "^X/^C/^V",    scope = "edit_box",   desc = "Yank / Cut (OSC 52) / Paste"},
		{id = "nav.portal_jump",  chord = "j (override)", scope = "ribbon_bar", desc = "Explicit Directional Override"},
		{id = "cmd.palette",      chord = "<C-p>|<M-x>", scope = "global",     desc = "Open Command Palette Picker"},
	},
	.Emacs = {
		{id = "nav.row_step",     chord = "<C-n>/<C-p>", scope = "keymap_*",   desc = "next-line / previous-line"},
		{id = "nav.col_step",     chord = "<C-b>/<C-f>", scope = "keymap_*",   desc = "backward-char / forward-char"},
		{id = "nav.univ_arg",     chord = "<C-u> [N]",   scope = "keymap_*",   desc = "universal-argument (4x, 16x, C-u N)"},
		{id = "split.resize",     chord = "CR -> ^B/^F", scope = "splitter",   desc = "Splitter Chordal Resize (^B/^F)"},
		{id = "edit.motion",      chord = "^A/^E | M-b/f", scope = "edit_box", desc = "Line & Word Cursor Motions"},
		{id = "edit.kill_yank",   chord = "<C-k>/<C-y>", scope = "edit_box",   desc = "kill-line (OSC 52) & yank"},
		{id = "mode.cancel",      chord = "<C-g>",       scope = "global",     desc = "keyboard-quit (Cancel C-u / Prefix)"},
		{id = "cmd.palette",      chord = "<M-x>",       scope = "global",     desc = "execute-extended-command Palette"},
	},
}

format_bench_row :: proc(app: ^Workbench_App, row_idx: i32) -> (act_id, chord, scope_str, desc: string) {
	if int(row_idx) < app.input.action_spec_cnt {
		spec := app.input.action_specs[row_idx]
		sc := "root/scopes"
		if spec.policy == .Global_Always {
			sc = "global"
		} else if len(spec.scope) > 0 {
			sc = spec.scope
		}
		return spec.action_name, spec.chord_spec, sc, spec.desc
	}
	extra_idx := int(row_idx) - app.input.action_spec_cnt
	rows := STYLE_BUILTIN_ROWS[app.input.keymap_style]
	item := rows[extra_idx % len(rows)]
	return fmt.tprintf("%s.%02d", item.id, row_idx), item.chord, item.scope, item.desc
}

build_workbench_ui :: proc(app: ^Workbench_App, out_slice: ^bifrost.Virtual_Slice) {
	w := app.screen.width
	h := app.screen.height

	bg_dark   := bifrost.rgb(19, 22, 32)
	panel_bg  := bifrost.rgb(26, 31, 44)
	header_bg := bifrost.rgb(35, 44, 64)
	accent_fg := bifrost.rgb(125, 195, 255)
	text_fg   := bifrost.rgb(218, 226, 242)
	muted_fg  := bifrost.rgb(142, 158, 188)
	border_fg := bifrost.rgb(72, 86, 116)
	sel_fg    := bifrost.rgb(245, 200, 115)

	bifrost.begin_frame(&app.screen, bg_dark)
	bifrost.begin_layout(&app.layout_ctx, w, h)

	if bifrost.ui_scope(&app.layout_ctx, &app.screen, "bench_root", bifrost.Scope_Config{
		dir    = .Column,
		width  = bifrost.fixed(w),
		height = bifrost.fixed(h),
	}) {
		// 1. Top Status Bar
		rib_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("ribbon_bar"))
		style_str := bifrost.keymap_style_name(app.input.keymap_style)
		header_text := fmt.tprintf(
			" BIFROST WORKBENCH | Style: %s (F2/F3-F5) | RibbonX: %dc | Rebound: %v | xitdb: %v | Last: %s",
			style_str,
			rib_slot.offset_x,
			app.rebind_applied,
			app.workspace_restored,
			app.last_action,
		)
		bifrost.set_paint(&app.screen, "header_bar", bifrost.Paint_Spec{
			text    = header_text,
			fg      = accent_fg,
			bg      = header_bg,
			style   = {.Bold},
			fill_bg = true,
		})
		bifrost.leaf(&app.layout_ctx, "header_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_text,
		})

		// 2. Horizontally Scrollable Ribbon (`scrollable = true` on `.Row` + `nav_overrides` Portal)
		bifrost.set_paint(&app.screen, "ribbon_bar", bifrost.Paint_Spec{
			fg      = text_fg,
			bg      = panel_bg,
			fill_bg = true,
		})
		if bifrost.container(&app.layout_ctx, "ribbon_bar", bifrost.Box_Config{
			dir         = .Row,
			width       = bifrost.grow(1),
			height      = bifrost.fixed(1),
			gap         = 2,
			scrollable  = true,
			focus_flags = {.Focus_Scope, .Loop_Spatial},
		}) {
			for pill, p_idx in RIBBON_PILLS {
				overrides: [bifrost.Nav_Dir]u64
				if p_idx == len(RIBBON_PILLS) - 1 {
					// Explicit Focus Override: pressing Down (`j`) on `pill_portal` jumps directly to `clip_dest`!
					overrides = bifrost.nav_target(.Down, "clip_dest")
				}
				bifrost.set_paint(&app.screen, pill.id, bifrost.Paint_Spec{
					text    = pill.label,
					fg      = sel_fg if p_idx == len(RIBBON_PILLS) - 1 else text_fg,
					bg      = header_bg,
					style   = {.Bold},
					fill_bg = true,
				})
				bifrost.leaf(&app.layout_ctx, pill.id, i32(len(pill.label)), 1, bifrost.Box_Config{
					width         = bifrost.fixed(i32(len(pill.label))),
					height        = bifrost.fixed(1),
					text          = pill.label,
					focusable     = true,
					clickable     = true,
					hoverable     = true,
					nav_overrides = overrides,
				})
			}
		}

		// 3. Main Split Body (Clipboard & Rebind Sidebar + Splitter + Virtualized Keymap Table)
		split_w := bifrost.get_split_size(&app.input, "bench_split", 34, 26, max(30, w - 38))
		if bifrost.ui_scope(&app.layout_ctx, &app.screen, "bench_body", bifrost.Scope_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			// 3a. Left Sidebar: Visual Selection & OSC 52 Clipboard + Conflict & Persistence Telemetry
			bifrost.set_paint(&app.screen, "bench_sidebar", bifrost.Paint_Spec{
				title       = "Clipboard, Selection & Rebind",
				fg          = text_fg,
				bg          = panel_bg,
				border_fg   = border_fg,
				title_fg    = accent_fg,
				title_style = {.Bold},
				fill_bg     = true,
			})
			if bifrost.container(&app.layout_ctx, "bench_sidebar", bifrost.Box_Config{
				dir         = .Column,
				width       = bifrost.fixed(split_w),
				height      = bifrost.grow(1),
				padding     = bifrost.pad_xy(1, 0),
				gap         = 1,
				border      = .Rounded,
				focus_flags = {.Focus_Scope, .Loop_Spatial},
				scrollable  = true,
			}) {
				bifrost.ui_text_input(&app.layout_ctx, &app.screen, &app.input, "clip_src", bifrost.Text_Input_Config{
					placeholder    = "Shift+Arrows / ^A / ^C...",
					width          = bifrost.grow(1),
					height         = bifrost.fixed(3),
					border         = .Plain,
					fg             = text_fg,
					bg             = bg_dark,
					placeholder_fg = muted_fg,
					border_fg      = border_fg,
					title          = "Source Input (Visual Sel + ^C)",
					two_stage      = true,
				})

				bifrost.ui_text_input(&app.layout_ctx, &app.screen, &app.input, "clip_dest", bifrost.Text_Input_Config{
					placeholder    = "Portal target (^V paste)...",
					width          = bifrost.grow(1),
					height         = bifrost.fixed(3),
					border         = .Plain,
					fg             = text_fg,
					bg             = bg_dark,
					placeholder_fg = muted_fg,
					border_fg      = border_fg,
					title          = "Target Input (Portal + ^V)",
					two_stage      = true,
				})

				if bifrost.container(&app.layout_ctx, "bench_btns", bifrost.Box_Config{
					dir    = .Column,
					width  = bifrost.grow(1),
					height = bifrost.fixed(4),
					gap    = 0,
				}) {
					bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_style", bifrost.Button_Spec{
						label  = fmt.tprintf("Bindings: %s (F2 / F3-F5)", style_str),
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						fg     = accent_fg,
						bg     = header_bg,
					})
					bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_rebind", bifrost.Button_Spec{
						label  = "Rebind Bookmark -> ^B",
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						fg     = sel_fg,
						bg     = header_bg,
					})
					bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_conflict", bifrost.Button_Spec{
						label  = "Probe Conflict on 'q'",
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						fg     = text_fg,
						bg     = header_bg,
					})
					bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_sync_xitdb", bifrost.Button_Spec{
						label  = "Save/Reload xitdb Keymap",
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						fg     = accent_fg,
						bg     = header_bg,
					})
				}

				bifrost.ui_label(
					&app.layout_ctx,
					&app.screen,
					"lbl_conflict",
					fmt.tprintf("Conflict: %s", app.conflict_report),
					sel_fg,
				)
				bifrost.ui_label(
					&app.layout_ctx,
					&app.screen,
					"lbl_osc52",
					fmt.tprintf("OSC52: %s", app.osc52_last_seq),
					muted_fg,
				)
			}

			// 3b. Interactive 1-Cell Vertical Splitter (supports `[COUNT]l/h` in `[RESIZE]` mode!)
			bifrost.ui_splitter(&app.layout_ctx, &app.screen, &app.input, "bench_split", bifrost.Splitter_Config{
				dir          = .Row,
				default_size = 34,
				min_first    = 26,
				min_second   = 36,
				step         = 2,
				fg           = border_fg,
				bg           = bg_dark,
				active_fg    = accent_fg,
			})

			// 3c. Right Workspace: Virtualized 2D Keymap Table (`keymap_scope` -> `keymap_table`)
			tbl_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("keymap_table"))
			active_col := clamp(tbl_slot.selected_col, 0, i32(len(app.col_specs) - 1))
			if bifrost.ui_scope(&app.layout_ctx, &app.screen, "keymap_scope", bifrost.Scope_Config{
				dir    = .Column,
				width  = bifrost.grow(1),
				height = bifrost.grow(1),
			}) {
				if bifrost.ui_virtual_list(
					&app.layout_ctx,
					&app.screen,
					&app.input,
					"keymap_table",
					TOTAL_BENCH_ROWS,
					bifrost.Virtual_List_Config{
						title          = fmt.tprintf(
							"Keymap Matrix (Row %d/%d | Col: %s | Mark: #%d | Pin: #%d)",
							tbl_slot.selected_row,
							TOTAL_BENCH_ROWS,
							app.col_specs[active_col].header,
							app.marked_row,
							app.bookmarked_row,
						),
						width          = bifrost.grow(1),
						height         = bifrost.grow(1),
						border         = .Rounded,
						fg             = text_fg,
						bg             = panel_bg,
						border_fg      = sel_fg if bifrost.is_focused(&app.input, "keymap_table") else border_fg,
						title_fg       = accent_fg,
						scroll_step    = 3,
						scroll_padding = 1,
						fallback_rows  = max(4, h - 7),
						total_cols     = len(app.col_specs),
					},
					out_slice,
				) {
					for vis_r := out_slice.start_row; vis_r < out_slice.end_row; vis_r += 1 {
						row_id := fmt.tprintf("km_row_%d", vis_r)
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

		// 4. Focus Breadcrumb Bar + Contextual Key-Hint Bar (renders `[COUNT: Nx]` & `[PREFIX: g …]`)
		bifrost.ui_focus_breadcrumb_bar(&app.layout_ctx, &app.screen, &app.input, "bench_breadcrumb", bifrost.Breadcrumb_Bar_Config{
			fg        = muted_fg,
			bg        = header_bg,
			active_fg = sel_fg,
			sep_fg    = border_fg,
		})
		bifrost.ui_key_hint_bar(&app.layout_ctx, &app.screen, &app.input, "bench_hint_bar", bifrost.Key_Hint_Bar_Config{
			key_fg  = accent_fg,
			desc_fg = text_fg,
			sep_fg  = border_fg,
			bg      = bg_dark,
		})
	}

	// 5. Command Palette (`z_layer = 30`) & Pending Chord Which-Key Overlay (`z_layer = 28`)
	bifrost.ui_command_palette(&app.layout_ctx, &app.screen, &app.input, &app.palette, 58, 6)
	bifrost.ui_which_key_overlay(&app.layout_ctx, &app.screen, &app.input, "bench_which_key")

	bifrost.end_layout(&app.layout_ctx)
}

paint_workbench_table :: proc(app: ^Workbench_App, slice: bifrost.Virtual_Slice) {
	if app.palette.is_open {
		return
	}
	panel_bg  := bifrost.rgb(26, 31, 44)
	accent_fg := bifrost.rgb(125, 195, 255)
	text_fg   := bifrost.rgb(218, 226, 242)
	muted_fg  := bifrost.rgb(142, 158, 188)
	sel_bg    := bifrost.rgb(52, 64, 92)
	sel_fg    := bifrost.rgb(245, 200, 115)

	if list_inner, ok := bifrost.get_inner_rect(&app.layout_ctx, "keymap_table"); ok && list_inner.w > 4 && list_inner.h > 0 {
		list_clip, _ := bifrost.get_node_clip(&app.layout_ctx, "keymap_table")
		usable_rect := list_inner
		usable_rect.w = max(1, usable_rect.w - 1)

		for vis_r := slice.start_row; vis_r < slice.end_row; vis_r += 1 {
			_, _, scope_str, _ := format_bench_row(app, vis_r)
			bifrost.table_column_observe_cell(&app.col_specs[2], scope_str)
		}

		spans: [4]bifrost.Table_Column_Span
		bifrost.resolve_table_columns(app.col_specs[:], spans[:], usable_rect, 2, 1)
		bifrost.register_virtual_table_col_spans(&app.input, "keymap_table", spans[:])

		for vis_r := slice.start_row; vis_r < slice.end_row; vis_r += 1 {
			row_id := fmt.tprintf("km_row_%d", vis_r)
			row_rect, r_ok := bifrost.get_rect(&app.layout_ctx, row_id)
			if !r_ok {
				continue
			}
			row_clip := bifrost.rect_intersect(list_clip, row_rect)
			if row_clip.w <= 0 || row_clip.h <= 0 {
				continue
			}

			is_sel := vis_r == slice.selected_row
			sel_col := clamp(slice.selected_col, 0, 3)
			row_bg := sel_bg if is_sel else panel_bg
			row_fg := sel_fg if is_sel else text_fg
			row_st := bifrost.Style_Flags{.Bold} if is_sel else bifrost.Style_Flags{}

			if is_sel {
				bifrost.fill_rect(&app.screen, usable_rect, row_clip, ' ', row_fg, row_bg, row_st)
				bifrost.put_text_clipped(&app.screen, usable_rect.x, row_rect.y, "▸", sel_fg, row_bg, {.Bold}, row_clip)
			}

			act_id, chord, scope_str, desc := format_bench_row(app, vis_r)
			cell_texts := [4]string{act_id, chord, scope_str, desc}
			cell_fgs   := [4]bifrost.Color{text_fg, accent_fg, muted_fg, text_fg}
			for col_i := 0; col_i < 4; col_i += 1 {
				c_fg := row_fg if is_sel else cell_fgs[col_i]
				c_st := row_st
				if is_sel && i32(col_i) == sel_col {
					c_fg = accent_fg
					c_st = {.Bold, .Reverse}
				}
				bifrost.draw_table_cell(&app.screen, spans[col_i], row_rect.y, row_clip, cell_texts[col_i], c_fg, row_bg, c_st)
			}
		}
	}
}

handle_workbench_interactions :: proc(app: ^Workbench_App, slice: bifrost.Virtual_Slice) -> bool {
	changed := false

	if bifrost.update_command_palette(&app.palette, &app.input) {
		changed = true
	}

	// Capture clipboard & OSC 52 flag whenever a text input copies/cuts to the clipboard
	if app.input.osc52_pending {
		app.input.osc52_pending = false
		clip_str := string(app.input.clipboard_buf[:app.input.clipboard_len])
		msg := fmt.tprintf("]52;c;%s", clip_str)
		n := min(len(msg), len(app.osc52_buf))
		if n > 0 {
			copy(app.osc52_buf[:n], msg[:n])
			app.osc52_last_seq = string(app.osc52_buf[:n])
		}
		changed = true
	}

	act, has_act := bifrost.triggered_action(&app.input, Workbench_Action)
	slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("keymap_table"))

	if bifrost.was_activated(&app.input, "btn_style") || bifrost.was_activated(&app.input, "pill_chords") || (has_act && act == .Cycle_Style) || bifrost.was_action_triggered(&app.input, "bench.style") {
		next_style := bifrost.cycle_keymap_style(&app.input)
		app.last_action = fmt.tprintf("style:%s", bifrost.keymap_style_name(next_style))
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "pill_vim") || (has_act && act == .Set_Style_Vim) || bifrost.was_action_triggered(&app.input, "bench.style_vim") {
		bifrost.set_keymap_style(&app.input, .Vim)
		app.last_action = "style:Vim"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "pill_helix") || (has_act && act == .Set_Style_Helix) || bifrost.was_action_triggered(&app.input, "bench.style_helix") {
		bifrost.set_keymap_style(&app.input, .Helix)
		app.last_action = "style:Helix"
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "pill_emacs") || (has_act && act == .Set_Style_Emacs) || bifrost.was_action_triggered(&app.input, "bench.style_emacs") {
		bifrost.set_keymap_style(&app.input, .Emacs)
		app.last_action = "style:Emacs"
		app.action_count += 1
		changed = true
	}

	if (has_act && act == .Quick_Mark) || bifrost.was_action_triggered(&app.input, "bench.quick_mark") {
		app.marked_row  = slot.selected_row
		app.last_action = fmt.tprintf("quick_mark:#%d", app.marked_row)
		app.action_count += 1
		changed = true
	}
	if has_act && act == .Jump_Top {
		slot.selected_row = 0
		slot.offset       = 0
		app.last_action   = "bench.jump_top"
		app.action_count += 1
		changed = true
	}
	if has_act && act == .Jump_Bottom {
		last_r := max(i32(0), slot.total_rows - 1)
		slot.selected_row = last_r
		slot.offset       = max(i32(0), last_r - max(i32(1), slot.viewport_rows) + 1)
		app.last_action   = "bench.jump_bottom"
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Bookmark_Row) || bifrost.was_action_triggered(&app.input, "bench.bookmark") {
		app.bookmarked_row = slot.selected_row
		app.last_action    = fmt.tprintf("bookmark:#%d", app.bookmarked_row)
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_rebind") || (has_act && act == .Rebind_Bookmark) || bifrost.was_action_triggered(&app.input, "bench.rebind") {
		if bifrost.rebind_action_chord(&app.input, "bench.bookmark", "<C-b>") {
			app.rebind_applied = true
			app.last_action    = "rebound:m-><C-b>"
			app.action_count += 1
			changed = true
		}
	}
	if bifrost.was_activated(&app.input, "btn_conflict") || (has_act && act == .Probe_Conflict) || bifrost.was_action_triggered(&app.input, "bench.conflict") {
		// Probe attempting to bind a global chord on `q` (which conflicts with `app.quit`)
		if existing, has_conflict := bifrost.find_keybinding_conflict(
			&app.input,
			"q",
			.Global_Always,
			"",
		); has_conflict {
			app.conflict_report = fmt.tprintf("'q' vs %s", existing)
			app.last_action     = "conflict.detected"
			app.action_count += 1
			changed = true
		}
	}
	if bifrost.was_activated(&app.input, "btn_sync_xitdb") || (has_act && act == .Sync_Workspace) || bifrost.was_action_triggered(&app.input, "bench.sync") {
		app.workspace_saved = bifrost.save_ui_workspace_to_xitdb(&app.db, &app.input, "workbench_ws")
		// Temporarily reset `bench.bookmark` back to `m`, then reload from `xitdb` to prove round-trip override restore
		_ = bifrost.rebind_action_chord(&app.input, "bench.bookmark", "m")
		app.workspace_restored = bifrost.load_ui_workspace_from_xitdb(&app.db, &app.input, "workbench_ws")
		app.last_action        = "xitdb.keymap.synced"
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Quit) || bifrost.was_action_triggered(&app.input, "app.quit") {
		app.quit_requested = true
		app.last_action    = "app.quit"
		changed = true
	}

	// Clicking a row in `keymap_table` selects both the row and the clicked column
	if app.input.clicked_id != 0 {
		for vis_r := slice.start_row; vis_r < slice.end_row; vis_r += 1 {
			row_id := fmt.tprintf("km_row_%d", vis_r)
			if app.input.clicked_id == bifrost.hash_id(row_id) {
				slot.selected_row = vis_r
				app.last_action = fmt.tprintf("click:r%d:c%d", vis_r, slot.selected_col)
				changed = true
				break
			}
		}
	}

	return changed || (app.input.text_changed_id != 0) || (app.input.scrolled_id != 0)
}

step_workbench_frame :: proc(app: ^Workbench_App, events: ..bifrost.Input_Event) {
	if len(events) > 0 && len(app.layout_ctx.nodes) > 0 && !app.input.pending_chord.active &&
	   bifrost.is_pure_hover_event_batch(&app.input, events) {
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
		slice: bifrost.Virtual_Slice
		build_workbench_ui(app, &slice)
	} else {
		free_all(context.temp_allocator)
		bifrost.state_store_begin_frame(&app.state_store)

		slice: bifrost.Virtual_Slice
		build_workbench_ui(app, &slice)

		bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
		if handle_workbench_interactions(app, slice) || (len(events) > 0 && !bifrost.is_pure_hover_event_batch(&app.input, events)) {
			build_workbench_ui(app, &slice)
			bifrost.resolve_input(&app.input, &app.layout_ctx)
		}
	}

	slice := bifrost.Virtual_Slice{}
	if slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("keymap_table")); slot != nil {
		slice.total_rows    = slot.total_rows
		slice.viewport_rows = slot.viewport_rows
		slice.scroll_offset = slot.offset
		slice.selected_row  = slot.selected_row
		slice.start_row     = clamp(slot.offset, 0, slot.total_rows)
		slice.end_row       = clamp(slice.start_row + slot.viewport_rows, slice.start_row, slot.total_rows)
	}

	bifrost.state_store_sync_from_layout(&app.state_store, &app.layout_ctx, &app.input)
	bifrost.apply_input_highlights(&app.screen, &app.layout_ctx, &app.input)
	bifrost.render_layout(&app.screen, &app.layout_ctx)

	// Save any active `ui_which_key_overlay` cells before custom table cell painting, then restore them
	wk_rect, has_wk := bifrost.get_rect(&app.layout_ctx, "bench_which_key")
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

	paint_workbench_table(app, slice)

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

	strings.builder_reset(&app.ansi_builder)
	_ = bifrost.screen_diff_ansi(&app.screen, &app.ansi_builder)
	app.frames_rendered += 1
}

extract_bench_row :: proc(s: ^bifrost.Screen, row: i32, alloc := context.temp_allocator) -> string {
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

run_workbench :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	cols: i32 = 104
	rows: i32 = 24
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			fmt.eprintln("Failed to initialize raw terminal")
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(64, ws.width)
			rows = max(18, ws.height)
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	app: Workbench_App
	if !workbench_init(&app, cols, rows, context.allocator) {
		return false
	}
	defer workbench_destroy(&app)

	if live_tty {
		step_workbench_frame(&app)
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
			app.input.clock_ns = now._nsec
			if (len(queued_inputs) > 0 || app.input.pending_chord.active) && time.tick_diff(last_tick, now) >= target_frame_interval {
				last_tick = now
				for q_ev in queued_inputs {
					if res_ev, is_res := q_ev.(bifrost.Resize_Event); is_res {
						_ = bifrost.screen_resize(&app.screen, max(64, res_ev.width), max(18, res_ev.height))
					}
				}
				step_workbench_frame(&app, ..queued_inputs[:])
				clear(&queued_inputs)
				if strings.builder_len(app.ansi_builder) > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
				}
			}
		}
	} else {
		// =========================================================================
		// Deterministic Headless Walkthrough of All 6 Standout Features
		// =========================================================================
		// 1. Initial frame (focused on `keymap_table`, row 0)
		app.input.clock_ns = 1_000_000_000
		step_workbench_frame(&app)

		// 2. Vim-Style Numeric Count Prefix (`5j`): jump 5 rows down to Row 5 in a single keypress
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = '5'})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'})

		// 3. Pending Chord Timeout Disambiguation (`expire_pending_chord`):
		//    Press `g` (which is both a 1-step `bench.quick_mark` and a 2-step prefix for `g g`/`g e`),
		//    advance `clock_ns` past `DEFAULT_CHORD_TIMEOUT_NS`, and verify `bench.quick_mark` marks Row 5!
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		app.input.clock_ns += bifrost.DEFAULT_CHORD_TIMEOUT_NS + 1_000_000
		step_workbench_frame(&app)

		// 4. Mouse Column Selection (`register_virtual_table_col_spans` + `select_virtual_col_at_x`):
		//    Click Row 2 at the `Scope` column (`col = 2`)
		row2_rect, _ := bifrost.get_rect(&app.layout_ctx, "km_row_2")
		tbl_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("keymap_table"))
		col2_x := i32(tbl_slot.col_x_starts[2]) + 2
		step_workbench_frame(&app, bifrost.Mouse_Event{
			x      = col2_x,
			y      = row2_rect.y,
			button = .Left,
			action = .Press,
		})

		// 5. Runtime Keybinding Conflict Detection (`<C-k>`), Live Rebind (`<C-r>`: `m` -> `<C-b>`),
		//    Fire the newly rebound `<C-b>` chord to bookmark Row 2, and Sync to `xitdb` (`,`)!
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'k', mods = {.Ctrl}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'r', mods = {.Ctrl}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'b', mods = {.Ctrl}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = ','})

		// 5b. Universal Function-Key Mode Switching (`F4` -> Helix, `F5` -> Emacs, `F2` -> Cycle):
		//     - In Helix (`F4`), `j8` suffix jumps from Row 2 to Row 10!
		//     - In Emacs (`F5`), `C-u C-p` moves up 4 rows from Row 10 to Row 6!
		//     - Press `F4` to switch back to Helix so all list items show Helix bindings (`SPC b`, `SPC r`, `g e`, `j[1-9]`)!
		step_workbench_frame(&app, bifrost.Key_Event{code = .F4}) // Direct switch to Helix (`F4`)
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = '8'}) // Helix suffix `j8` -> Row 2 + 8 = Row 10!
		helix_row := bifrost.get_selected_row(&app.input, "keymap_table")

		step_workbench_frame(&app, bifrost.Key_Event{code = .F5}) // Direct switch to Emacs (`F5`)
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'u', mods = {.Ctrl}}) // Emacs `C-u` (4x)
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'p', mods = {.Ctrl}}) // Emacs `C-p` -> Row 10 - 4 = Row 6!
		emacs_row := bifrost.get_selected_row(&app.input, "keymap_table")

		// Switch back to Helix (`F4`) so the Keymap Matrix, status bar & Which-Key showcase Helix bindings
		step_workbench_frame(&app, bifrost.Key_Event{code = .F4})

		// 6. Horizontal Scrolling (`offset_x`) & Explicit `nav_overrides` Portal:
		//    Focus `pill_vim` in the horizontal `ribbon_bar`, step right 5 times to `pill_portal`
		//    (scrolling `ribbon_bar.offset_x > 0`), then press `j` (`Down`) to teleport via
		//    `nav_overrides = nav_target(.Down, "clip_dest")` straight to `clip_dest`!
		app.input.wants_focus_id = bifrost.hash_id("pill_vim")
		step_workbench_frame(&app)
		for _ in 0 ..< 5 {
			step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'l'})
		}
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // Portal -> `clip_dest`!

		// 7. Visual Selection (`Shift+Arrows`, `Ctrl+A`) & Clipboard Copy/Paste (`Ctrl+C`, `Ctrl+V` + OSC 52):
		//    Step up to `clip_src`, press Enter to edit, type `"osc52-ok"`, select all (`Ctrl+A`),
		//    copy (`Ctrl+C`), keep last 2 chars visually selected (`Right`, then `Shift+Left` x2),
		//    exit edit (`Escape`), step down to `clip_dest`, enter edit (`Enter`), and paste (`Ctrl+V`)!
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'k'}) // `clip_src`
		step_workbench_frame(&app, bifrost.Key_Event{code = .Enter})
		for ch in "osc52-ok" {
			step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = ch})
		}
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'a', mods = {.Ctrl}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'c', mods = {.Ctrl}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Right})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Left, mods = {.Shift}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Left, mods = {.Shift}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Escape})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // `clip_dest`
		step_workbench_frame(&app, bifrost.Key_Event{code = .Enter})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'v', mods = {.Ctrl}})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Escape})

		// 8. Return focus to `keymap_table`, execute Helix `k3` suffix (Row 6 -> Row 3, latching `[SUFFIX: 3x]`),
		//    and press `g` so the final frame renders BOTH `[SUFFIX: 3x] [CHORD: g…]` in the key-hint bar
		//    AND the floating `Which-Key [g]` overlay (`z_layer = 28`)!
		app.input.wants_focus_id = bifrost.hash_id("keymap_table")
		step_workbench_frame(&app)
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'k'})
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = '3'})
		app.input.clock_ns += 1_000_000
		step_workbench_frame(&app, bifrost.Key_Event{code = .Rune, ch = 'g'})

		rib_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("ribbon_bar"))
		fmt.printf(
			"[Bifrost Keymap Workbench] style=%s vim_mark=#%d helix_j8_row=#%d emacs_cu_row=#%d final_row=#%d bookmarked=#%d selected_col=%d ribbon_offset_x=%d osc52=%s pasted=%q\n",
			bifrost.keymap_style_name(app.input.keymap_style),
			app.marked_row,
			helix_row,
			emacs_row,
			tbl_slot.selected_row,
			app.bookmarked_row,
			tbl_slot.selected_col,
			rib_slot.offset_x,
			app.osc52_last_seq,
			bifrost.get_text(&app.input, "clip_dest"),
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_bench_row(&app.screen, r))
		}

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&app.screen, "Bifrost Keymap Workbench & Which-Key", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/keymap_workbench.html", dir), strings.to_string(b))
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

	ok := run_workbench(live_tty)

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
