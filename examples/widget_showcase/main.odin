package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../bifrost"
import heimdall "../../deps/heimdall/heimdall"

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
	Heimdall_Flush,
	Heimdall_Kind_Cycle,
	Quit,
}

Showcase_Actions :: struct {
	Theme_Cycle:         Showcase_Action `bifrost:"key=<C-t>, id=theme.cycle, allow_in_edit=true, desc=Theme, label=Cycle Color Theme (Nord / Tokyo / Gruvbox), category=Appearance"`,
	Style_Cycle:         Showcase_Action `bifrost:"key=<F2>, id=style.cycle, policy=global, allow_in_edit=true, desc='Bindings (F2)', label='Cycle Keymap Style (Vim / Helix / Emacs) [F2]', category=Keymap"`,
	Pulse_Telemetry:     Showcase_Action `bifrost:"vim=p, helix=<Space> p, emacs=<C-x> p, id=telemetry.pulse, desc=Pulse, label=Advance Telemetry Wave Phase, category=Telemetry"`,
	Focus_Tree:          Showcase_Action `bifrost:"vim=g t, helix=g t, emacs=<C-x> t, id=nav.tree, desc=Tree, label=Focus Architecture Tree Explorer, category=Navigation"`,
	Focus_Editor:        Showcase_Action `bifrost:"vim=g n, helix=g n, emacs=<C-x> n, id=nav.editor, desc=Editor, label=Switch to Tab 1 & Focus Notes Editor, category=Navigation"`,
	Heimdall_Flush:      Showcase_Action `bifrost:"key=<C-r>, id=heimdall.flush, allow_in_edit=true, desc='Flush IPC (^R)', label='Flush & Reload Heimdall .arrow Segments [^R]', category=Telemetry"`,
	Heimdall_Kind_Cycle: Showcase_Action `bifrost:"key=<C-k>, id=heimdall.kind, allow_in_edit=true, desc='Kind (^K)', label='Cycle Heimdall Record Kind Filter [^K]', category=Telemetry"`,
	Quit:                Showcase_Action `bifrost:"vim=q|<C-q>|<C-c>, helix=q|<C-q>|<C-c>, emacs=<C-x> c|<C-q>, id=app.quit, policy=global, desc=Quit, label=Quit Widget Showcase, category=System"`,
}

@(rodata)
SHOWCASE_TREE_NODES := [21]bifrost.Tree_Node{
	{id = "root_bifrost",    label = "bifrost/",              icon = "📦", depth = 0, expanded = true,  has_children = true},
	{id = "dir_core",        label = "core/",                 icon = "📂", depth = 1, expanded = true,  has_children = true},
	{id = "mod_layout",      label = "layout.odin",           icon = "📐", depth = 2, expanded = false, has_children = false},
	{id = "mod_renderer",    label = "renderer.odin",         icon = "🎨", depth = 2, expanded = false, has_children = false},
	{id = "mod_input",       label = "input.odin",            icon = "⌨",  depth = 2, expanded = false, has_children = false},
	{id = "mod_spatial",     label = "spatial_nav.odin",      icon = "🧭", depth = 2, expanded = false, has_children = false},
	{id = "dir_widgets",     label = "widgets/",              icon = "📂", depth = 1, expanded = true,  has_children = true},
	{id = "mod_text_area",   label = "text_area.odin (T11)",  icon = "📝", depth = 2, expanded = false, has_children = false},
	{id = "mod_tree",        label = "tree.odin (T12)",       icon = "🌲", depth = 2, expanded = false, has_children = false},
	{id = "mod_tabs",        label = "tabs.odin (T13)",       icon = "🗂",  depth = 2, expanded = false, has_children = false},
	{id = "mod_canvas",      label = "canvas.odin (T14)",     icon = "📊", depth = 2, expanded = false, has_children = false},
	{id = "dir_tests",       label = "tests/",                icon = "🧪", depth = 1, expanded = true,  has_children = true},
	{id = "spec_text_area",  label = "spec_text_area.odin",   icon = "✓",  depth = 2, expanded = false, has_children = false},
	{id = "spec_tree",       label = "spec_tree.odin",        icon = "✓",  depth = 2, expanded = false, has_children = false},
	{id = "spec_tabs",       label = "spec_tabs.odin",        icon = "✓",  depth = 2, expanded = false, has_children = false},
	{id = "spec_canvas",     label = "spec_canvas.odin",      icon = "✓",  depth = 2, expanded = false, has_children = false},
	{id = "root_sleipnir",   label = "deps/sleipnir/",        icon = "🐎", depth = 0, expanded = false, has_children = true},
	{id = "mod_scheduler",   label = "scheduler.odin",        icon = "⚡", depth = 1, expanded = false, has_children = false},
	{id = "dir_schema",      label = "schema/",               icon = "📂", depth = 0, expanded = true,  has_children = true},
	{id = "cue_site",        label = "site.cue",              icon = "⚙",  depth = 1, expanded = false, has_children = false},
	{id = "cue_theme",       label = "theme.cue",             icon = "🎨", depth = 1, expanded = false, has_children = false},
}

@(rodata)
NODE_DOC_SNIPPETS := [21]string{
	"bifrost/: Zero-allocation terminal UI framework in Odin.\nFeatures Flexbox layout, SGR diffing, and 2D spatial focus.",
	"core/: Layout solver, cell renderer, 3-phase input router, and directional cone scorer.",
	"layout.odin: 3-pass Flexbox layout engine (bottom-up intrinsic, top-down distribution, absolute screen rects).",
	"renderer.odin: Double-buffered Cell grid, 4-bit box-drawing junctions, and run-length ANSI SGR diffing.",
	"input.odin: 3-phase Capturing -> At_Target -> Bubbling input dispatch + modal Trap_Focus shields.",
	"spatial_nav.odin: Directional cone hit-testing with sticky preferred_nav_pos lane memory.",
	"widgets/: High-density interactive terminal widgets (Tracks 11-14).",
	"text_area.odin (Track 11):\n- 2D UTF-8/grapheme cursor & sticky preferred_col\n- Shift+Arrow selection & OSC 52 clipboard\n- Built-in Odin & CUE syntax highlighting",
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
	"schema/: CUE configuration & theme schemas highlighted with syntax_mode = .Cue.",
	"site.cue: CUE workspace & widget schema definitions (#Workspace, #WidgetSpec, @tag).",
	"theme.cue: CUE color palette constraints (#Palette, #RGB, Nord/Tokyo/Gruvbox presets).",
}

@(rodata)
NODE_FILE_SNIPPETS := [21]string{
	// 0: bifrost/
	`// Bifrost Tracks 11-14 Interactive Notes
// Click any file in the left Tree (or press Enter) to load it!
track_11 :: "ui_text_area (2D UTF-8 editor + Odin/CUE syntax)"
track_12 :: "ui_tree (virtualized collapsible tree)"
track_13 :: "ui_tabs (focus-scoped tabs + H* memory)"
track_14 :: "ui_canvas & ui_sparkline (Braille 2x4)"`,
	// 1: core/
	`package bifrost
// Core subsystem: layout.odin, renderer.odin, input.odin`,
	// 2: layout.odin
	`package bifrost

// 3-Pass Flexbox Layout Solver (Bottom-Up, Top-Down, Screen Rects)
begin_layout :: proc(ctx: ^Layout_Context, width, height: i32) {
    ctx.screen_size = {max(0, width), max(0, height)}
    ctx.layout_gen += 1
}`,
	// 3: renderer.odin
	`package bifrost

// Double-buffered Cell Grid & Run-Length ANSI SGR Diffing
Cell :: struct {
    ch:    rune,
    fg:    Color,
    bg:    Color,
    style: Style_Flags,
    width: u8,
}`,
	// 4: input.odin
	`package bifrost

// 3-Phase Input Router (Capturing -> At_Target -> Bubbling)
resolve_input :: proc(inp: ^Input_State, ctx: ^Layout_Context, events: ..Input_Event) {
    for ev in events {
        dispatch_event(inp, ctx, ev)
    }
}`,
	// 5: spatial_nav.odin
	`package bifrost

// Directional Cone Scorer with Sticky Lane Memory
find_spatial_candidate :: proc "contextless" (ctx: ^Layout_Context, origin: Rect, dir: Nav_Dir) -> i32 {
    return best_candidate_in_cone(ctx, origin, dir)
}`,
	// 6: widgets/
	`package bifrost
// Widgets subsystem: text_area, tree, tabs, canvas`,
	// 7: text_area.odin (T11)
	`package bifrost

// Track 11: Multi-Line UTF-8 Text Editor with Odin & CUE Highlighting
Text_Area_Syntax_Mode :: enum u8 {
    None = 0,
    Odin = 1,
    Cue  = 2,
}`,
	// 8: tree.odin (T12)
	`package bifrost

// Track 12: O(visible_rows) Virtualized Collapsible Tree
Tree_Node :: struct {
    id:           string,
    label:        string,
    icon:         string,
    depth:        i32,
    expanded:     bool,
    has_children: bool,
}`,
	// 9: tabs.odin (T13)
	`package bifrost

// Track 13: Focus-Scope-Integrated Tab Bar with H* Deep Restoration
@(deferred_in_out = defer_end_ui_tabs)
ui_tabs :: proc(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, items: []Tab_Item_Spec) -> bool {
    return begin_ui_tabs_internal(ctx, s, inp, id, items)
}`,
	// 10: canvas.odin (T14)
	`package bifrost

// Track 14: 2x4 Sub-Cell Unicode Braille Canvas (U+2800..U+28FF)
braille_dot_bit :: #force_inline proc "contextless" (sub_x, sub_y: i32) -> u8 {
    if sub_x < 0 || sub_x > 1 || sub_y < 0 || sub_y > 3 {
        return 0
    }
    return BRAILLE_BIT_LUT[sub_y][sub_x]
}`,
	// 11: tests/
	`package bifrost_tests
// 4-Layer ATDD Executable Specifications (@(scenario))`,
	// 12: spec_text_area.odin
	`package bifrost_tests

@(test)
@(scenario)
spec_text_area_odin_syntax_highlighting :: proc(t: ^testing.T) {
    _ = scenario(t, w = 48, h = 8)
    then.cell_style_has(1, 1, .Bold, true)
}`,
	// 13: spec_tree.odin
	`package bifrost_tests

@(test)
@(scenario)
spec_tree_virtualizes_ten_thousand_nodes :: proc(t: ^testing.T) {
    _ = scenario(t, w = 60, h = 14)
    then.layout_node_count_is(14)
}`,
	// 14: spec_tabs.odin
	`package bifrost_tests

@(test)
@(scenario)
spec_tabs_switching_and_deep_focus_restoration :: proc(t: ^testing.T) {
    _ = scenario(t, w = 64, h = 14)
    then.active_tab_is("work_tabs", 1)
}`,
	// 15: spec_canvas.odin
	`package bifrost_tests

@(test)
@(scenario)
spec_canvas_braille_encoding_and_sparklines :: proc(t: ^testing.T) {
    _ = scenario(t, w = 48, h = 14)
    then.braille_dot_bit_is(0, 3, 0x40)
}`,
	// 16: deps/sleipnir/
	`package actor
// Lock-free MPSC actor scheduler`,
	// 17: scheduler.odin
	`package actor

// Work-Stealing Actor Scheduler with Bounded Backpressure
step_actor_turn :: proc(sched: ^Scheduler, aid: Actor_Id) -> bool {
    return drain_mailbox_batch(sched, aid, 64)
}`,
	// 18: schema/
	`package schema
// CUE schemas for workspace & themes`,
	// 19: site.cue
	`package schema

// CUE Workspace & Widget Schema (Highlighted with syntax_mode = .Cue)
#WidgetSpec: {
    id!:        string & !=""
    track:      int & >=11 & <=14
    focusable:  bool | *true
    max_Buffer: int | *4096 @tag(bytes)
}

workspace: #WidgetSpec & {
    id:    "notes_editor"
    track: 11
}`,
	// 20: theme.cue
	`package schema

// CUE Color Palette Constraints (Highlighted with syntax_mode = .Cue)
#RGB: {
    r: uint8
    g: uint8
    b: uint8
}

#Theme: {
    name!:   "Nord" | "Tokyo Night" | "Gruvbox"
    accent!: #RGB
    invalid: _|_ // Bottom constraint literal
}

nord: #Theme & {
    name:   "Nord"
    accent: {r: 136, g: 192, b: 208}
}`,
}

INITIAL_EDITOR_NOTES :: `// Bifrost Tracks 11-14 Interactive Notes
// Click any file in the left Tree (or press Enter) to load it!
track_11 :: "ui_text_area (2D UTF-8 editor + Odin/CUE syntax)"
track_12 :: "ui_tree (virtualized collapsible tree)"
track_13 :: "ui_tabs (focus-scoped tabs + H* memory)"
track_14 :: "ui_canvas & ui_sparkline (Braille 2x4)"`

TELEMETRY_SAMPLES :: 48
SYS_HISTORY_LEN   :: 240 // 2 minutes of 500ms history
SYS_VIEW_SAMPLES  :: 32  // 15s visible chart window
SYS_MAX_CORES     :: 256

CPU_Jiffies :: struct {
	total: u64,
	idle:  u64,
	valid: bool,
}

SHOWCASE_HEIMDALL_DIR    :: ".tmp/showcase_heimdall"
SHOWCASE_HEIMDALL_PREFIX :: ".tmp/showcase_heimdall/seg"

Showcase_App :: struct {
	screen:               bifrost.Screen,
	layout_ctx:           bifrost.Layout_Context,
	input:                bifrost.Input_State,
	state_store:          bifrost.Widget_State_Store,
	palette:              bifrost.Command_Palette,
	ansi_builder:         strings.Builder,
	recorder:             heimdall.Recorder,
	heimdall_store:       bifrost.Heimdall_Segment_Store,
	heimdall_filter_kind: bifrost.Heimdall_Filter_Kind,
	heimdall_scope_buf:   [64]u8,
	heimdall_scope_len:   int,
	theme:                Theme_Preset,
	wave_phase:           f32,
	latency_series:       [TELEMETRY_SAMPLES]f32,
	fps_series:           [TELEMETRY_SAMPLES]f32,
	spark_ops:            [32]f32,
	spark_mem:            [32]int,
	last_tree_node:       i32,
	last_activated:       string,
	active_file:          string,
	editor_syntax:        bifrost.Text_Area_Syntax_Mode,
	last_action:          string,
	last_action_buf:      [64]u8,
	action_count:         int,
	frames_rendered:      int,
	quit_requested:       bool,

	// Track 15: Form Controls demo state
	form_chk:             bool,
	form_sw:              bool,
	form_radio:           int,
	form_slider:          f64,
	form_dropdown:        int,
	form_dd_open:         bool,

	// Track 17: Live Linux System Metrics (`/proc/stat` & `/proc/meminfo`) + Timeline Scrubbing
	sys_cpu_hist:         [SYS_HISTORY_LEN]f64,
	sys_mem_hist:         [SYS_HISTORY_LEN]f64,
	sys_core_hist:        [SYS_MAX_CORES][SYS_HISTORY_LEN]f64,
	sys_pan_samples:      f64, // 0.0 = pinned to Live Now, >0 = scrubbed back in time (500ms/sample)
	sys_cpu_pct:          f64,
	sys_core_count:       int,
	sys_core_pct:         [SYS_MAX_CORES]f64,
	sys_mem_used_pct:     f64,
	sys_mem_cach_pct:     f64,
	sys_swap_pct:         f64,
	sys_mem_total_gb:     f64,
	sys_mem_used_gb:      f64,
	prev_cpu_total:       CPU_Jiffies,
	prev_cpu_cores:       [SYS_MAX_CORES]CPU_Jiffies,
	sys_samples_cnt:      int,
	sys_dirty:            bool,

	// Self-process metrics (`/proc/self/stat` & `/proc/self/status`)
	self_cpu_pct:         f64,
	self_rss_mb:          f64,
	prev_self_ticks:      u64,
	prev_self_total:      u64,
}

parse_proc_stat_line :: proc(line: string, alloc := context.temp_allocator) -> (jiffies: CPU_Jiffies, ok: bool) {
	fields := strings.fields(line, alloc)
	if len(fields) < 5 {
		return {}, false
	}
	var_total: u64 = 0
	var_idle: u64  = 0
	for i := 1; i < len(fields); i += 1 {
		v, parsed := strconv.parse_u64_of_base(fields[i], 10)
		if !parsed {
			continue
		}
		var_total += v
		if i == 4 || i == 5 { // idle + iowait
			var_idle += v
		}
	}
	return CPU_Jiffies{total = var_total, idle = var_idle, valid = var_total > 0}, var_total > 0
}

compute_cpu_delta_pct :: proc(prev: ^CPU_Jiffies, cur: CPU_Jiffies, fallback_pct: f64) -> f64 {
	if !cur.valid {
		return fallback_pct
	}
	if !prev.valid || cur.total < prev.total {
		prev^ = cur
		if cur.total > 0 && cur.total >= cur.idle {
			return clamp(f64(cur.total - cur.idle) * 100.0 / f64(cur.total), 0.0, 100.0)
		}
		return fallback_pct
	}
	d_total := cur.total - prev.total
	if d_total == 0 {
		// No kernel jiffy tick elapsed since the previous call
		return fallback_pct
	}
	d_idle := cur.idle - prev.idle if cur.idle >= prev.idle else 0
	prev^  = cur
	if d_idle >= d_total {
		return 0.0
	}
	return clamp(f64(d_total - d_idle) * 100.0 / f64(d_total), 0.0, 100.0)
}

sample_live_system_metrics :: proc(app: ^Showcase_App) {
	arena_buf: [65536]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	scratch := mem.arena_allocator(&arena)

	// 1. Sample `/proc/stat` aggregate + all logical per-core jiffies (`cpu0`..`cpuN`)
	proc_stat_ok := false
	if stat_bytes, stat_err := os.read_entire_file("/proc/stat", scratch); stat_err == nil {
		proc_stat_ok = true
		stat_str := string(stat_bytes)
		detected_cores := 0
		for line in strings.split_lines_iterator(&stat_str) {
			if strings.has_prefix(line, "cpu ") {
				if j, ok := parse_proc_stat_line(line, scratch); ok {
					app.sys_cpu_pct = compute_cpu_delta_pct(&app.prev_cpu_total, j, app.sys_cpu_pct)
				}
			} else if strings.has_prefix(line, "cpu") {
				sp_idx := strings.index_byte(line, ' ')
				if sp_idx > 3 {
					if core_idx, c_ok := strconv.parse_int(line[3:sp_idx], 10); c_ok && core_idx >= 0 && core_idx < SYS_MAX_CORES {
						if j, ok := parse_proc_stat_line(line, scratch); ok {
							app.sys_core_pct[core_idx] = compute_cpu_delta_pct(&app.prev_cpu_cores[core_idx], j, app.sys_core_pct[core_idx])
							if core_idx + 1 > detected_cores {
								detected_cores = core_idx + 1
							}
						}
					}
				}
			}
		}
		if detected_cores > 0 {
			app.sys_core_count = detected_cores
		}
	}
	if app.sys_core_count <= 0 {
		app.sys_core_count = 4
	}

	// 2. Sample `/proc/meminfo` for RAM Used %, Page Cache %, and Swap Used %
	if mem_bytes, mem_err := os.read_entire_file("/proc/meminfo", scratch); mem_err == nil {
		mem_str := string(mem_bytes)
		mem_total_kb: u64 = 0
		mem_avail_kb: u64 = 0
		buffers_kb:   u64 = 0
		cached_kb:    u64 = 0
		swap_tot_kb:  u64 = 0
		swap_free_kb: u64 = 0

		for line in strings.split_lines_iterator(&mem_str) {
			fields := strings.fields(line, scratch)
			if len(fields) < 2 {
				continue
			}
			val, v_ok := strconv.parse_u64_of_base(fields[1], 10)
			if !v_ok {
				continue
			}
			switch fields[0] {
			case "MemTotal:":     mem_total_kb = val
			case "MemAvailable:": mem_avail_kb = val
			case "Buffers:":      buffers_kb   = val
			case "Cached:":       cached_kb    = val
			case "SwapTotal:":    swap_tot_kb  = val
			case "SwapFree:":     swap_free_kb = val
			}
		}
		if mem_total_kb > 0 {
			used_kb := mem_total_kb - min(mem_total_kb, mem_avail_kb)
			cach_kb := min(mem_total_kb, buffers_kb + cached_kb)
			app.sys_mem_total_gb = f64(mem_total_kb) / (1024.0 * 1024.0)
			app.sys_mem_used_gb  = f64(used_kb) / (1024.0 * 1024.0)
			app.sys_mem_used_pct = clamp(f64(used_kb) * 100.0 / f64(mem_total_kb), 0.0, 100.0)
			app.sys_mem_cach_pct = clamp(f64(cach_kb) * 100.0 / f64(mem_total_kb), 0.0, 100.0)
		}
		if swap_tot_kb > 0 {
			swap_used := swap_tot_kb - min(swap_tot_kb, swap_free_kb)
			app.sys_swap_pct = clamp(f64(swap_used) * 100.0 / f64(swap_tot_kb), 0.0, 100.0)
		}
	}

	// 2b. Sample `/proc/self/stat` and `/proc/self/status` for this process's own CPU % and RSS memory
	if self_stat_bytes, ss_err := os.read_entire_file("/proc/self/stat", scratch); ss_err == nil {
		ss_str := string(self_stat_bytes)
		// Skip past `(comm)` since executable name may contain spaces/parens
		if rparen := strings.last_index_byte(ss_str, ')'); rparen >= 0 && rparen + 2 < len(ss_str) {
			rest_fields := strings.fields(ss_str[rparen + 2:], scratch)
			// Field 14 (`utime`) is index 11 after `) `, Field 15 (`stime`) is index 12, Field 24 (`rss` pages) is index 21
			if len(rest_fields) > 12 {
				utime, u_ok := strconv.parse_u64_of_base(rest_fields[11], 10)
				stime, s_ok := strconv.parse_u64_of_base(rest_fields[12], 10)
				if u_ok && s_ok {
					self_ticks := utime + stime
					cur_total  := app.prev_cpu_total.total
					if app.prev_self_total > 0 && cur_total > app.prev_self_total && self_ticks >= app.prev_self_ticks {
						d_self  := self_ticks - app.prev_self_ticks
						d_total := cur_total - app.prev_self_total
						// Multiply by logical core count so 100% = 1 full logical core (matching `top` / `htop` %CPU)
						ncores  := f64(max(1, app.sys_core_count))
						app.self_cpu_pct = clamp((f64(d_self) * ncores * 100.0) / f64(d_total), 0.0, ncores * 100.0)
					}
					app.prev_self_ticks = self_ticks
					app.prev_self_total = cur_total
				}
			}
			if len(rest_fields) > 21 {
				if rss_pages, r_ok := strconv.parse_u64_of_base(rest_fields[21], 10); r_ok {
					app.self_rss_mb = (f64(rss_pages) * 4096.0) / (1024.0 * 1024.0)
				}
			}
		}
	}

	// 3. Shift rolling history ring (`0 ..< SYS_HISTORY_LEN`) and push latest sample at tail
	ncores := max(1, app.sys_core_count)
	if !proc_stat_ok {
		t := f64(SYS_HISTORY_LEN + app.sys_samples_cnt) * 0.22
		cpu_wave := 12.0 * math.sin_f64(t) + 6.0 * math.cos_f64(t * 2.3)
		mem_wave := 3.5 * math.sin_f64(t * 0.45)
		app.sys_cpu_pct = clamp(24.0 + cpu_wave, 1.0, 100.0)
		if app.sys_mem_total_gb <= 0.0 {
			app.sys_mem_total_gb = 16.0
		}
		app.sys_mem_used_pct = clamp(42.0 + mem_wave, 1.0, 100.0)
		app.sys_mem_used_gb  = (app.sys_mem_used_pct / 100.0) * app.sys_mem_total_gb
		app.sys_mem_cach_pct = 18.5
		app.sys_swap_pct     = 4.2
		for c in 0 ..< ncores {
			phase := f64(c) * 0.75
			c_wave := 14.0 * math.sin_f64(t + phase) + 7.0 * math.cos_f64(t * 1.9 - phase)
			app.sys_core_pct[c] = clamp(24.0 + c_wave, 0.0, 100.0)
		}
	}
	if app.sys_samples_cnt == 0 {
		for i in 0 ..< SYS_HISTORY_LEN {
			t := f64(i) * 0.22
			cpu_wave := 12.0 * math.sin_f64(t) + 6.0 * math.cos_f64(t * 2.3)
			mem_wave := 3.5 * math.sin_f64(t * 0.45)
			app.sys_cpu_hist[i] = clamp(app.sys_cpu_pct + cpu_wave, 1.0, 100.0)
			app.sys_mem_hist[i] = clamp(app.sys_mem_used_pct + mem_wave, 1.0, 100.0)
			for c in 0 ..< ncores {
				phase := f64(c) * 0.75
				c_wave := 14.0 * math.sin_f64(t + phase) + 7.0 * math.cos_f64(t * 1.9 - phase)
				app.sys_core_hist[c][i] = clamp(app.sys_core_pct[c] + c_wave, 0.0, 100.0)
			}
		}
		app.sys_cpu_hist[SYS_HISTORY_LEN - 1] = app.sys_cpu_pct
		app.sys_mem_hist[SYS_HISTORY_LEN - 1] = app.sys_mem_used_pct
		for c in 0 ..< ncores {
			app.sys_core_hist[c][SYS_HISTORY_LEN - 1] = app.sys_core_pct[c]
		}
	} else {
		for i in 0 ..< SYS_HISTORY_LEN - 1 {
			app.sys_cpu_hist[i] = app.sys_cpu_hist[i + 1]
			app.sys_mem_hist[i] = app.sys_mem_hist[i + 1]
		}
		for c in 0 ..< ncores {
			for i in 0 ..< SYS_HISTORY_LEN - 1 {
				app.sys_core_hist[c][i] = app.sys_core_hist[c][i + 1]
			}
			app.sys_core_hist[c][SYS_HISTORY_LEN - 1] = app.sys_core_pct[c]
		}
		app.sys_cpu_hist[SYS_HISTORY_LEN - 1] = app.sys_cpu_pct
		app.sys_mem_hist[SYS_HISTORY_LEN - 1] = app.sys_mem_used_pct
		// If user has scrubbed into the past, advance pan offset by 1 sample so their viewed timestamp stays locked!
		if app.sys_pan_samples > 0.05 {
			max_pan := f64(SYS_HISTORY_LEN - SYS_VIEW_SAMPLES)
			app.sys_pan_samples = clamp(app.sys_pan_samples + 1.0, 0.0, max_pan)
		}
	}
	app.sys_samples_cnt += 1
	app.sys_dirty = true
}

active_heimdall_scope_filter :: proc(app: ^Showcase_App) -> string {
	if app.heimdall_scope_len <= 0 {
		return ""
	}
	return string(app.heimdall_scope_buf[:app.heimdall_scope_len])
}

set_heimdall_scope_filter :: proc(app: ^Showcase_App, scope: string) {
	if len(scope) == 0 {
		app.heimdall_scope_len = 0
		return
	}
	n := min(len(scope), len(app.heimdall_scope_buf))
	copy(app.heimdall_scope_buf[:n], scope[:n])
	app.heimdall_scope_len = n
}

flush_and_reload_showcase_heimdall :: proc(app: ^Showcase_App) {
	heimdall.recorder_flush(&app.recorder)
	_, _ = bifrost.heimdall_store_load_prefix_incremental(&app.heimdall_store, SHOWCASE_HEIMDALL_PREFIX)
	scope_filter := active_heimdall_scope_filter(app)
	if len(scope_filter) > 0 {
		found := false
		for st in app.heimdall_store.scope_stats {
			if st.scope == scope_filter {
				found = true
				break
			}
		}
		if !found {
			app.heimdall_scope_len = 0
			scope_filter           = ""
			_ = bifrost.heimdall_store_apply_filter(&app.heimdall_store, app.heimdall_filter_kind, "", "")
		}
	}
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

	_ = os.remove_all(SHOWCASE_HEIMDALL_DIR)
	_ = os.make_directory_all(SHOWCASE_HEIMDALL_DIR)
	if heimdall.recorder_init(&app.recorder, heimdall.Config{
		file_prefix      = SHOWCASE_HEIMDALL_PREFIX,
		batches_per_file = 8,
		ring_page_count  = 4,
	}, allocator) != nil {
		bifrost.state_store_destroy(&app.state_store)
		bifrost.screen_destroy(&app.screen)
		return false
	}
	if bifrost.heimdall_store_init(&app.heimdall_store, allocator) != nil {
		heimdall.recorder_destroy(&app.recorder)
		bifrost.state_store_destroy(&app.state_store)
		bifrost.screen_destroy(&app.screen)
		return false
	}

	// Attach the Heimdall recorder directly to Screen, Layout_Context, and Input_State
	app.screen.recorder     = &app.recorder
	app.layout_ctx.recorder = &app.recorder
	app.input.recorder      = &app.recorder

	app.ansi_builder    = strings.builder_make(0, 8192, allocator)
	app.theme           = .Nord
	app.last_action     = "ready"
	app.last_activated  = "mod_text_area"
	app.last_tree_node  = 7 // `text_area.odin (T11)`
	app.active_file     = "notes.odin"
	app.editor_syntax   = .Odin
	app.wave_phase      = 0.0
	app.form_chk        = true
	app.form_sw         = true
	app.form_radio      = 1
	app.form_slider     = 65.0
	app.form_dropdown   = 1
	app.form_dd_open    = false
	recompute_telemetry(app)
	sample_live_system_metrics(app)

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
	bifrost.heimdall_store_destroy(&app.heimdall_store)
	heimdall.recorder_destroy(&app.recorder)
	_ = os.remove_all(SHOWCASE_HEIMDALL_DIR)
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
			" BIFROST SHOWCASE | Theme: %s | Tab: %d | App: %.1f%% CPU, %.1f MB | Cur: L%d:C%d | Last: %s",
			pal.name,
			active_tab + 1,
			app.self_cpu_pct,
			app.self_rss_mb,
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
			tab_specs := [7]bifrost.Tab_Item_Spec{
				{label = "Editor & Docs",       badge = "T11",    key_hint = "1:"},
				{label = "Braille Telemetry",   badge = "T14",    key_hint = "2:"},
				{label = "Inspector & Keys",    badge = "T12/13", key_hint = "3:"},
				{label = "Form Controls",       badge = "T15",    key_hint = "4:"},
				{label = "Charts & Plots",      badge = "T17",    key_hint = "5:"},
				{label = "Markdown Manual",     badge = "T18",    key_hint = "6:"},
				{label = "Heimdall IPC Viewer", badge = "ARROW",  key_hint = "7:"},
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
					title            = "Workspace ([ / ] or Alt+1..7 switches tabs with H* Focus Memory)",
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
					syntax_name := "CUE" if app.editor_syntax == .Cue else "Odin"
					bifrost.ui_text_area(&app.layout_ctx, &app.screen, &app.input, "notes_editor", bifrost.Text_Area_Config{
						title             = fmt.tprintf("Editor [%s · %s] (Lines: %d | Cur: %d:%d | PrefCol: %d)", app.active_file, syntax_name, ta_lines, ta_r + 1, ta_c + 1, ta_pref),
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
						syntax_mode       = app.editor_syntax,
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

				case 3:
					// =========================================================
					// TAB 3: Track 15 Form Controls Suite
					// =========================================================
					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "form_scope", bifrost.Scope_Config{
						dir         = .Column,
						width       = bifrost.grow(1),
						height      = bifrost.grow(1),
						gap         = 1,
						padding     = bifrost.pad_xy(2, 1),
						focus_flags = {.Focus_Scope},
					}) {
						bifrost.ui_label(&app.layout_ctx, &app.screen, "lbl_form_hdr", "Track 15: Form Controls Suite (Checkbox, Switch, Radio, Slider, Dropdown)", pal.sel_fg, {.Bold})

						bifrost.ui_checkbox(&app.layout_ctx, &app.screen, &app.input, "demo_chk", &app.form_chk, "Hardware Acceleration (Space / Click)", {
							focus_flags = {.Default_Focus},
						})

						bifrost.ui_switch(&app.layout_ctx, &app.screen, &app.input, "demo_sw", &app.form_sw, "Debug Logging Mode")

						radio_opts := [3]string{"Standard Allocation", "Thread-Local Arena", "Virtual Memory Ring"}
						bifrost.ui_radio_group(&app.layout_ctx, &app.screen, &app.input, "demo_radio", &app.form_radio, radio_opts[:])

						bifrost.ui_slider(&app.layout_ctx, &app.screen, &app.input, "demo_slider", &app.form_slider, 0.0, 100.0, 5.0, {
							label = "Buffer Depth",
						})

						backends := [4]string{"Raw POSIX PTY", "Windows ConPTY", "ANSI VT Diff", "Headless Virtual Grid"}
						bifrost.ui_dropdown(&app.layout_ctx, &app.screen, &app.input, "demo_dropdown", &app.form_dropdown, backends[:], &app.form_dd_open)
					}

				case 4:
					// =========================================================
					// TAB 4 (Tab 5): Track 17 Live Linux System Metrics (`ui_chart`, `ui_bar_chart`)
					// =========================================================
					if bifrost.container(&app.layout_ctx, "charts_container", bifrost.Box_Config{
						dir    = .Column,
						width  = bifrost.grow(1),
						height = bifrost.grow(1),
						gap    = 1,
					}) {
						ncores := max(1, app.sys_core_count)
						max_pan := f64(SYS_HISTORY_LEN - SYS_VIEW_SAMPLES)
						pan := clamp(app.sys_pan_samples, 0.0, max_pan)
						x_max := f64(SYS_HISTORY_LEN - 1) - pan
						x_min := x_max - f64(SYS_VIEW_SAMPLES - 1)

						// Dynamic X-axis time labels (`-15s .. Now` when live, or `-75s .. -60s` when scrubbed back)
						x_labels := make([]string, 6, context.temp_allocator)
						for tick in 0 ..< 6 {
							r := f64(tick) / 5.0
							sample_idx := x_min + r * (x_max - x_min)
							sec_ago := int(math.round((f64(SYS_HISTORY_LEN - 1) - sample_idx) * 0.5))
							if sec_ago <= 0 {
								x_labels[tick] = "Now"
							} else {
								x_labels[tick] = fmt.tprintf("-%ds", sec_ago)
							}
						}

						right_idx := clamp(int(math.round(x_max)), 0, SYS_HISTORY_LEN - 1)
						view_cpu  := app.sys_cpu_hist[right_idx]
						view_mem  := app.sys_mem_hist[right_idx]
						pan_sec   := pan * 0.5

						// KSysGuard / System Monitor multi-core color palette (vivid line + dimmed translucent fill)
						sg_line_colors := [8]bifrost.Color{
							bifrost.rgb(88, 214, 141),  // Emerald
							bifrost.rgb(93, 173, 226),  // Sky Blue
							bifrost.rgb(245, 176, 65),  // Amber Gold
							bifrost.rgb(175, 122, 197), // Amethyst Purple
							bifrost.rgb(72, 201, 176),  // Turquoise
							bifrost.rgb(236, 112, 99),  // Coral Red
							bifrost.rgb(244, 208, 63),  // Sun Yellow
							bifrost.rgb(133, 193, 233), // Ice Blue
						}
						sg_fill_colors := [8]bifrost.Color{
							bifrost.rgb(42, 110, 74),
							bifrost.rgb(45, 88, 120),
							bifrost.rgb(125, 88, 32),
							bifrost.rgb(90, 62, 105),
							bifrost.rgb(36, 102, 90),
							bifrost.rgb(120, 56, 50),
							bifrost.rgb(122, 104, 30),
							bifrost.rgb(66, 96, 118),
						}

						// Build System Guard per-CPU area datasets (`c0..cN`, or 8 grouped core clusters if >8 cores)
						num_series := min(ncores, 8)
						cores_per_series := (ncores + num_series - 1) / num_series
						chart_datasets := make([]bifrost.Chart_Dataset, num_series, context.temp_allocator)
						for s_idx in 0 ..< num_series {
							c_start := s_idx * cores_per_series
							c_end   := min(ncores, c_start + cores_per_series)
							pts := make([][2]f64, SYS_HISTORY_LEN, context.temp_allocator)
							for i in 0 ..< SYS_HISTORY_LEN {
								sum_v := 0.0
								cnt_v := 0
								for c in c_start ..< c_end {
									sum_v += app.sys_core_hist[c][i]
									cnt_v += 1
								}
								avg_v := sum_v / f64(max(1, cnt_v))
								pts[i] = {f64(i), avg_v}
							}
							cur_v := pts[right_idx][1]
							series_lbl: string
							if cores_per_series == 1 {
								series_lbl = fmt.tprintf("c%d %.0f%%", c_start, cur_v)
							} else {
								series_lbl = fmt.tprintf("c%d-%d %.0f%%", c_start, c_end - 1, cur_v)
							}
							chart_datasets[s_idx] = bifrost.Chart_Dataset{
								name    = series_lbl,
								data    = pts,
								marker  = .Braille_Area,
								fg      = sg_line_colors[s_idx % len(sg_line_colors)],
								fill_fg = sg_fill_colors[s_idx % len(sg_fill_colors)],
							}
						}

						chart_title: string
						x_axis_title: string
						if pan <= 0.05 {
							chart_title = fmt.tprintf(
								"System Guard CPU History [LIVE] — Avg: %.1f%% | RAM: %.1f/%.1f GB | App: %.1f%% CPU, %.1f MB",
								app.sys_cpu_pct,
								app.sys_mem_used_gb,
								app.sys_mem_total_gb,
								app.self_cpu_pct,
								app.self_rss_mb,
							)
							x_axis_title = "Timeline (Drag or Wheel on chart to scrub history · 500ms live)"
						} else {
							chart_title = fmt.tprintf(
								"System Guard CPU History [PAUSED -%.1fs] — Avg: %.1f%% | RAM: %.1f%% (App: %.1f%% CPU, %.1f MB)",
								pan_sec,
								view_cpu,
								view_mem,
								app.self_cpu_pct,
								app.self_rss_mb,
							)
							x_axis_title = fmt.tprintf("Scrubbed -%.1fs (Drag left/right or Wheel · Press '0' or Home for Live)", pan_sec)
						}

						bifrost.ui_chart(&app.layout_ctx, &app.screen, "telemetry_chart", bifrost.Chart_Config{
							title       = chart_title,
							width       = bifrost.grow(1),
							height      = bifrost.grow(1),
							border      = .Rounded,
							border_fg   = pal.border_fg,
							title_fg    = pal.accent_fg,
							focus_flags = {.Focusable, .Default_Focus},
							show_grid   = true,
							show_legend = true,
							x_axis      = bifrost.Axis_Config{
								title  = x_axis_title,
								bounds = {x_min, x_max},
								labels = x_labels,
								fg     = pal.muted_fg,
							},
							y_axis      = bifrost.Axis_Config{
								title  = "CPU %",
								bounds = {0.0, 100.0},
								labels = {"0", "25", "50", "75", "100"},
								fg     = pal.muted_fg,
							},
							datasets    = chart_datasets,
						})

						if bifrost.container(&app.layout_ctx, "bar_charts_row", bifrost.Box_Config{
							dir    = .Row,
							width  = bifrost.grow(1),
							height = bifrost.fixed(7),
							gap    = 1,
						}) {
							if ncores <= 6 {
								vbar_data := make([]bifrost.Bar_Data, ncores, context.temp_allocator)
								for c in 0 ..< ncores {
									s_idx := min(num_series - 1, c / max(1, cores_per_series))
									vbar_data[c] = bifrost.Bar_Data{
										label = fmt.tprintf("c%d", c),
										value = app.sys_core_hist[c][right_idx],
										color = sg_line_colors[s_idx % len(sg_line_colors)],
									}
								}
								bw: i32 = 4 if ncores <= 4 else 3
								bgap: i32 = 2 if ncores <= 4 else 1
								bifrost.ui_bar_chart(&app.layout_ctx, &app.screen, "svc_vbar", bifrost.Bar_Chart_Config{
									direction   = .Vertical,
									title       = fmt.tprintf("Per-Core Load %% (%d cores)", ncores),
									width       = bifrost.grow(1),
									height      = bifrost.grow(1),
									border      = .Plain,
									border_fg   = pal.border_fg,
									title_fg    = pal.accent_fg,
									bar_width   = bw,
									gap         = bgap,
									max_value   = 100.0,
									show_values = true,
									data        = vbar_data,
								})
							} else if ncores <= 24 {
								if bifrost.ui_scope(&app.layout_ctx, &app.screen, "cores_gauge_grid", bifrost.Scope_Config{
									dir       = .Column,
									width     = bifrost.grow(1),
									height    = bifrost.grow(1),
									border    = .Plain,
									title     = fmt.tprintf("Per-Core Load %% (%d cores · color-coded)", ncores),
									fg        = pal.text_fg,
									bg        = pal.bg,
									border_fg = pal.border_fg,
									title_fg  = pal.accent_fg,
								}) {
									grid_rows :: 4
									grid_cols := (ncores + grid_rows - 1) / grid_rows
									for r in 0 ..< grid_rows {
										if bifrost.container(&app.layout_ctx, fmt.tprintf("core_grid_row_%d", r), bifrost.Box_Config{
											dir    = .Row,
											width  = bifrost.grow(1),
											height = bifrost.fixed(1),
											gap    = 1,
										}) {
											for gc in 0 ..< grid_cols {
												core_idx := gc * grid_rows + r
												if core_idx < ncores {
													pct   := app.sys_core_hist[core_idx][right_idx]
													s_idx := min(num_series - 1, core_idx / max(1, cores_per_series))
													c_fg  := sg_line_colors[s_idx % len(sg_line_colors)]
													bifrost.ui_gauge(&app.layout_ctx, &app.screen, fmt.tprintf("core_g_%d", core_idx), bifrost.Gauge_Config{
														ratio            = clamp(pct / 100.0, 0.0, 1.0),
														show_percentage  = true,
														filled_fg        = c_fg,
														unfilled_fg      = pal.border_fg,
														unfilled_bg      = pal.header_bg,
														text_filled_fg   = pal.bg,
														text_unfilled_fg = c_fg,
														width            = bifrost.grow(1),
														height           = bifrost.fixed(1),
													})
												} else {
													bifrost.leaf(&app.layout_ctx, fmt.tprintf("core_pad_%d_%d", r, gc), 1, 1, bifrost.Box_Config{
														width  = bifrost.grow(1),
														height = bifrost.fixed(1),
													})
												}
											}
										}
									}
								}
							} else {
								max_c := 0
								max_p := 0.0
								spark_cores := make([]f32, ncores, context.temp_allocator)
								for c in 0 ..< ncores {
									val := app.sys_core_hist[c][right_idx]
									spark_cores[c] = f32(val)
									if val > max_p {
										max_p = val
										max_c = c
									}
								}
								bifrost.ui_sparkline(&app.layout_ctx, &app.screen, "cores_spark_all", spark_cores, bifrost.Sparkline_Config{
									title     = fmt.tprintf("All %d Cores (c0..c%d | Peak c%d: %.0f%%)", ncores, ncores - 1, max_c, max_p),
									width     = bifrost.grow(1),
									height    = bifrost.grow(1),
									border    = .Plain,
									fg        = pal.series_a,
									bg        = pal.bg,
									border_fg = pal.border_fg,
									title_fg  = pal.accent_fg,
									fill_bg   = true,
									min_val   = 0.0,
									max_val   = 100.0,
								})
							}

							hbar_data := [3]bifrost.Bar_Data{
								{label = "RAM",   value = app.sys_mem_used_pct, color = pal.series_a},
								{label = "Cache", value = app.sys_mem_cach_pct, color = pal.accent_fg},
								{label = "Swap",  value = app.sys_swap_pct,     color = pal.series_b},
							}
							bifrost.ui_bar_chart(&app.layout_ctx, &app.screen, "res_hbar", bifrost.Bar_Chart_Config{
								direction   = .Horizontal,
								title       = "Memory Breakdown % (/proc/meminfo)",
								width       = bifrost.grow(1),
								height      = bifrost.grow(1),
								border      = .Plain,
								border_fg   = pal.border_fg,
								title_fg    = pal.accent_fg,
								gap         = 1,
								max_value   = 100.0,
								show_values = true,
								data        = hbar_data[:],
							})
						}
					}

				case 5:
					// =========================================================
					// TAB 5: Track 18 Word-Wrapped Markdown Manual (`ui_markdown`)
					// =========================================================
					md_text := `# Bifrost Actor-Driven TUI Engine
Bifrost is an immediate-mode **actor-driven** terminal user interface framework for Odin.

## Core Architectural Pillars
- **Sleipnir Actor Supervision**: Background workers stream diffs into UI queues.
- **Zero-Allocation Tree Layout**: Layout and render pipelines use context.temp_allocator.
- **2D Spatial Navigation**: Directional arrow keys bubble up nested container hierarchies.

> "A terminal interface should feel as fast, crisp, and robust as a game engine."

---
*Track 18 Documentation & Markdown Viewer Suite*`

					bifrost.ui_markdown(&app.layout_ctx, &app.screen, "manual_md", md_text, bifrost.Markdown_Config{
						title       = "Bifrost Architecture Manual (ui_markdown)",
						width       = bifrost.grow(1),
						height      = bifrost.grow(1),
						border      = .Rounded,
						border_fg   = pal.border_fg,
						title_fg    = pal.accent_fg,
						wrap_mode   = .Words,
						h1_fg       = pal.accent_fg,
						h2_fg       = pal.series_a,
						h3_fg       = pal.series_b,
						bullet_fg   = pal.sel_fg,
						quote_fg    = pal.muted_fg,
						code_fg     = pal.sel_fg,
						code_bg     = pal.header_bg,
						rule_fg     = pal.border_fg,
					})

				case 6:
					// =========================================================
					// TAB 6 (Tab 7): Heimdall Arrow IPC Telemetry Viewer
					// =========================================================
					rec_stats := bifrost.heimdall_snapshot_recorder_stats(&app.recorder)
					scope_lbl := active_heimdall_scope_filter(app)
					if len(scope_lbl) == 0 {
						scope_lbl = "ALL SCOPES"
					}
					stats_text := fmt.tprintf(
						" Segs: %d | Records: %d/%d | Spans: %d | Cnt: %d | Gauges: %d | Hists: %d | Drop: %d | Kind: %s | Scope: %s",
						app.heimdall_store.segment_count,
						len(app.heimdall_store.filtered_idxs),
						len(app.heimdall_store.records),
						app.heimdall_store.total_spans,
						app.heimdall_store.total_counters,
						app.heimdall_store.total_gauges,
						app.heimdall_store.total_hists,
						rec_stats.dropped_records,
						bifrost.heimdall_filter_kind_label(app.heimdall_filter_kind),
						scope_lbl,
					)
					bifrost.set_paint(&app.screen, "heimdall_summary_bar", bifrost.Paint_Spec{
						text    = stats_text,
						fg      = pal.accent_fg,
						bg      = pal.header_bg,
						style   = {.Bold},
						fill_bg = true,
					})
					bifrost.leaf(&app.layout_ctx, "heimdall_summary_bar", 24, 1, bifrost.Box_Config{
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
					})

					span_durs := bifrost.heimdall_store_extract_span_durations_us(&app.heimdall_store, 32)
					bifrost.ui_sparkline(&app.layout_ctx, &app.screen, "heimdall_span_spark", span_durs, bifrost.Sparkline_Config{
						title     = fmt.tprintf("Span Durations us (max %d us)", app.heimdall_store.max_duration_ns / 1_000),
						width     = bifrost.grow(1),
						height    = bifrost.fixed(3),
						border    = .Plain,
						fg        = pal.series_a,
						bg        = pal.bg,
						border_fg = pal.border_fg,
						title_fg  = pal.accent_fg,
						fill_bg   = true,
					})

					vslice: bifrost.Virtual_Slice
					total_filtered := i32(len(app.heimdall_store.filtered_idxs))
					list_rows := max(i32(4), h - 15)
					hd_cols   := bifrost.heimdall_table_columns(context.temp_allocator)
					if bifrost.ui_table(
						&app.layout_ctx,
						&app.screen,
						&app.input,
						"heimdall_records_list",
						hd_cols,
						total_filtered,
						bifrost.Table_Config{
							title         = fmt.tprintf("Heimdall Zero-Copy Arrow IPC Records (%d matching)", total_filtered),
							width         = bifrost.grow(1),
							height        = bifrost.grow(1),
							border        = .Rounded,
							fg            = pal.text_fg,
							bg            = pal.bg,
							border_fg     = pal.border_fg,
							title_fg      = pal.accent_fg,
							header_fg     = pal.accent_fg,
							header_bg     = pal.header_bg,
							sep_fg        = pal.border_fg,
							sel_fg        = pal.sel_fg,
							sel_bg        = pal.sel_bg,
							fallback_rows = list_rows,
							focus_flags   = {.Focusable, .Default_Focus},
						},
						&vslice,
					) {
						for row_idx := vslice.start_row; row_idx < vslice.end_row; row_idx += 1 {
							rec, rec_ok := bifrost.heimdall_store_get_filtered_record(&app.heimdall_store, int(row_idx))
							if !rec_ok {
								continue
							}
							cells := bifrost.heimdall_record_table_cells(rec, context.temp_allocator)
							bifrost.ui_table_row(&app.layout_ctx, &app.screen, row_idx, cells[:])
						}
					}

					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "heimdall_toolbar", bifrost.Scope_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						gap    = 1,
					}) {
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_hd_flush", bifrost.Button_Spec{
							label  = "Flush & Reload (^R)",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.accent_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_hd_kind", bifrost.Button_Spec{
							label  = fmt.tprintf("Kind: %s (^K)", bifrost.heimdall_filter_kind_label(app.heimdall_filter_kind)),
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.text_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_hd_scope", bifrost.Button_Spec{
							label  = fmt.tprintf("Scope: %s", scope_lbl),
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.text_fg,
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

set_last_action :: proc(app: ^Showcase_App, s: string) {
	n := min(len(s), len(app.last_action_buf))
	copy(app.last_action_buf[:n], s[:n])
	app.last_action = string(app.last_action_buf[:n])
}

handle_showcase_interactions :: proc(app: ^Showcase_App) -> bool {
	changed := false

	if bifrost.update_command_palette(&app.palette, &app.input) {
		changed = true
	}

	// Track 12: Check if a leaf node in `arch_tree` was activated via Enter / Space / Mouse Click
	act_node := bifrost.get_tree_activated_node(&app.input, "arch_tree")
	if act_node >= 0 && int(act_node) < len(SHOWCASE_TREE_NODES) {
		node_label         := SHOWCASE_TREE_NODES[act_node].label
		app.last_tree_node = act_node
		app.last_activated = SHOWCASE_TREE_NODES[act_node].id
		app.active_file    = node_label
		app.editor_syntax  = .Cue if strings.has_suffix(node_label, ".cue") else .Odin
		bifrost.set_text_area(&app.input, "notes_editor", NODE_FILE_SNIPPETS[act_node])
		set_last_action(app, fmt.tprintf("tree.open:%s", node_label))
		app.action_count  += 1
		changed = true
	}

	// Track 13: Check if active tab changed this frame
	if bifrost.was_tab_changed(&app.input, "workspace_tabs") {
		new_tab := bifrost.get_active_tab(&app.input, "workspace_tabs")
		if new_tab == 6 {
			flush_and_reload_showcase_heimdall(app)
		}
		set_last_action(app, fmt.tprintf("tab.switch:%d", new_tab + 1))
		app.action_count += 1
		changed = true
	}

	// Typed Showcase_Action dispatch + button activations
	act, has_act := bifrost.triggered_action(&app.input, Showcase_Action)
	if bifrost.was_activated(&app.input, "btn_theme_tab2") || (has_act && act == .Theme_Cycle) || bifrost.was_action_triggered(&app.input, "theme.cycle") {
		app.theme         = Theme_Preset((int(app.theme) + 1) % len(Theme_Preset))
		set_last_action(app, fmt.tprintf("theme:%s", THEMES[app.theme].name))
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_cycle_keymap") || (has_act && act == .Style_Cycle) || bifrost.was_action_triggered(&app.input, "style.cycle") {
		next_st           := bifrost.cycle_keymap_style(&app.input)
		set_last_action(app, fmt.tprintf("style:%s", bifrost.keymap_style_name(next_st)))
		app.action_count  += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_pulse_wave") || (has_act && act == .Pulse_Telemetry) || bifrost.was_action_triggered(&app.input, "telemetry.pulse") {
		app.wave_phase   += 0.65
		recompute_telemetry(app)
		sample_live_system_metrics(app)
		set_last_action(app, "telemetry.pulse")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Focus_Tree) || bifrost.was_action_triggered(&app.input, "nav.tree") {
		app.input.wants_focus_id = bifrost.hash_id("arch_tree")
		set_last_action(app, "nav.tree")
		app.action_count        += 1
		changed = true
	}
	if (has_act && act == .Focus_Editor) || bifrost.was_action_triggered(&app.input, "nav.editor") {
		bifrost.set_active_tab(&app.input, "workspace_tabs", 0, true)
		app.input.wants_focus_id = bifrost.hash_id("notes_editor")
		set_last_action(app, "nav.editor")
		app.action_count        += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_insert_node") {
		sel_node := clamp(bifrost.get_tree_selected_node(&app.input, "arch_tree"), 0, i32(len(SHOWCASE_TREE_NODES) - 1))
		snippet := fmt.tprintf("\n// Selected: %s", SHOWCASE_TREE_NODES[sel_node].label)
		slot := bifrost.get_text_area_state(&app.input, "notes_editor")
		_ = bifrost.text_area_insert_string(&app.input, slot, snippet)
		set_last_action(app, "editor.append_node")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_reset_notes") {
		app.active_file   = "notes.odin"
		app.editor_syntax = .Odin
		bifrost.set_text_area(&app.input, "notes_editor", INITIAL_EDITOR_NOTES)
		set_last_action(app, "editor.reset")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_expand_all") {
		for idx: i32 = 0; idx < i32(len(SHOWCASE_TREE_NODES)); idx += 1 {
			if SHOWCASE_TREE_NODES[idx].has_children {
				bifrost.set_tree_node_expanded(&app.input, "arch_tree", idx, true)
			}
		}
		set_last_action(app, "tree.expand_all")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_collapse_tests") {
		cur_exp := bifrost.is_tree_node_expanded(&app.input, "arch_tree", 11)
		bifrost.set_tree_node_expanded(&app.input, "arch_tree", 11, !cur_exp)
		set_last_action(app, "tree.toggle_tests")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_open_palette") {
		app.palette.is_open = true
		bifrost.set_text(&app.input, app.palette.input_id, "")
		app.palette.dirty = true
		bifrost.update_palette_matches(&app.palette, &app.input, "")
		app.input.wants_focus_id = bifrost.hash_id(app.palette.input_id)
		set_last_action(app, "palette.opened")
		app.action_count        += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_hd_flush") || (has_act && act == .Heimdall_Flush) || bifrost.was_action_triggered(&app.input, "heimdall.flush") {
		flush_and_reload_showcase_heimdall(app)
		set_last_action(app, "heimdall.flush")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_hd_kind") || (has_act && act == .Heimdall_Kind_Cycle) || bifrost.was_action_triggered(&app.input, "heimdall.kind") {
		next_ord := (int(app.heimdall_filter_kind) + 1) % len(bifrost.Heimdall_Filter_Kind)
		app.heimdall_filter_kind = bifrost.Heimdall_Filter_Kind(next_ord)
		_ = bifrost.heimdall_store_apply_filter(
			&app.heimdall_store,
			app.heimdall_filter_kind,
			active_heimdall_scope_filter(app),
			"",
		)
		slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("heimdall_records_list"))
		if slot != nil {
			slot.selected_row = 0
			slot.offset       = 0
		}
		set_last_action(app, fmt.tprintf("heimdall.kind:%s", bifrost.heimdall_filter_kind_label(app.heimdall_filter_kind)))
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_hd_scope") {
		cur_scope := active_heimdall_scope_filter(app)
		next_scope := ""
		if len(app.heimdall_store.scope_stats) > 0 {
			if len(cur_scope) == 0 {
				next_scope = app.heimdall_store.scope_stats[0].scope
			} else {
				for st, idx in app.heimdall_store.scope_stats {
					if st.scope == cur_scope {
						if idx + 1 < len(app.heimdall_store.scope_stats) {
							next_scope = app.heimdall_store.scope_stats[idx + 1].scope
						}
						break
					}
				}
			}
		}
		set_heimdall_scope_filter(app, next_scope)
		_ = bifrost.heimdall_store_apply_filter(
			&app.heimdall_store,
			app.heimdall_filter_kind,
			active_heimdall_scope_filter(app),
			"",
		)
		slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("heimdall_records_list"))
		if slot != nil {
			slot.selected_row = 0
			slot.offset       = 0
		}
		set_last_action(app, "heimdall.scope")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Quit) || bifrost.was_action_triggered(&app.input, "app.quit") {
		app.quit_requested = true
		set_last_action(app, "app.quit")
		changed = true
	}

	return changed || (app.input.text_changed_id != 0) || (app.input.scrolled_id != 0) || (app.input.tab_changed_id != 0)
}

handle_chart_timeline_scrubbing :: proc(app: ^Showcase_App, events: []bifrost.Input_Event) -> bool {
	chart_id := bifrost.hash_id("telemetry_chart")
	max_pan  := f64(SYS_HISTORY_LEN - SYS_VIEW_SAMPLES)
	changed  := false

	// 1. Mouse click-and-drag panning on `telemetry_chart`
	if app.input.active_press_id == chart_id && app.input.drag_delta[0] != 0 {
		chart_w: f64 = 56.0
		if idx, ok := app.layout_ctx.id_map[chart_id]; ok {
			chart_w = max(12.0, f64(app.layout_ctx.nodes[idx].inner_rect.w - 4))
		}
		samples_per_col := f64(SYS_VIEW_SAMPLES) / chart_w
		// Dragging right (dx > 0) pulls earlier history into view; dragging left (dx < 0) moves toward Now
		app.sys_pan_samples = clamp(app.sys_pan_samples + f64(app.input.drag_delta[0]) * samples_per_col, 0.0, max_pan)
		if app.sys_pan_samples <= 0.05 {
			app.sys_pan_samples = 0.0
			set_last_action(app, "chart.live")
		} else {
			set_last_action(app, fmt.tprintf("chart.scrub:-%.1fs", app.sys_pan_samples * 0.5))
		}
		changed = true
	}

	// 2. Mouse wheel & keyboard scrubbing when `telemetry_chart` is hovered or focused
	for ev in events {
		switch e in ev {
		case bifrost.Mouse_Event:
			if app.input.hovered_id == chart_id && (e.action == .Press || e.action == .Scroll_Up || e.action == .Scroll_Down || e.action == .Scroll_Left || e.action == .Scroll_Right) {
				step: f64 = 0.0
				if e.button == .Wheel_Up || e.button == .Wheel_Left || e.action == .Scroll_Up || e.action == .Scroll_Left {
					step = 2.0
				} else if e.button == .Wheel_Down || e.button == .Wheel_Right || e.action == .Scroll_Down || e.action == .Scroll_Right {
					step = -2.0
				}
				if step != 0.0 {
					app.sys_pan_samples = clamp(app.sys_pan_samples + step, 0.0, max_pan)
					if app.sys_pan_samples <= 0.05 {
						app.sys_pan_samples = 0.0
						set_last_action(app, "chart.live")
					} else {
						set_last_action(app, fmt.tprintf("chart.scrub:-%.1fs", app.sys_pan_samples * 0.5))
					}
					changed = true
				}
			}
		case bifrost.Key_Event:
			if app.input.focused_id == chart_id {
				if e.code == .Rune && e.ch == '0' {
					app.sys_pan_samples = 0.0
					set_last_action(app, "chart.live")
					changed = true
				} else if e.code == .Home {
					app.sys_pan_samples = max_pan
					set_last_action(app, fmt.tprintf("chart.scrub:-%.1fs", app.sys_pan_samples * 0.5))
					changed = true
				} else if e.code == .End {
					app.sys_pan_samples = 0.0
					set_last_action(app, "chart.live")
					changed = true
				}
			}
		case bifrost.Focus_Loss_Event, bifrost.Focus_Event, bifrost.Paste_Event, bifrost.Resize_Event:
		}
	}
	return changed
}

step_showcase_frame :: proc(app: ^Showcase_App, events: ..bifrost.Input_Event) {
	tree_slice: bifrost.Tree_Slice
	switch bifrost.try_resolve_hover_fast_path(&app.input, &app.layout_ctx, events, app.sys_dirty) {
	case .Hover_Unchanged:
		strings.builder_reset(&app.ansi_builder)
		return
	case .Hover_Changed:
		free_all(context.temp_allocator)
		bifrost.state_store_begin_frame(&app.state_store)
		build_showcase_ui(app, &tree_slice)
	case .Not_Pure_Hover:
		app.sys_dirty = false
		free_all(context.temp_allocator)
		bifrost.state_store_begin_frame(&app.state_store)

		build_showcase_ui(app, &tree_slice)

		bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
		chart_scrubbed := handle_chart_timeline_scrubbing(app, events)
		if handle_showcase_interactions(app) || chart_scrubbed || (len(events) > 0 && !bifrost.is_pure_hover_event_batch(&app.input, events)) {
			build_showcase_ui(app, &tree_slice)
			bifrost.resolve_input(&app.input, &app.layout_ctx)
		}
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

	app, alloc_err := new(Showcase_App, context.allocator)
	if alloc_err != nil {
		return false
	}
	defer free(app, context.allocator)
	if !showcase_init(app, cols, rows, context.allocator) {
		return false
	}
	defer showcase_destroy(app)

	if live_tty {
		step_showcase_frame(app)
		if strings.builder_len(app.ansi_builder) > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
		}

		last_tick := time.tick_now()
		last_sys_sample := last_tick
		target_frame_interval := 33 * time.Millisecond // 30 FPS cap
		queued_inputs := make([dynamic]bifrost.Input_Event, 0, 64, context.allocator)
		defer delete(queued_inputs)
		for !app.quit_requested {
			elapsed_since_frame := time.tick_diff(last_tick, time.tick_now())
			wait_ms := max(i32(1), i32((target_frame_interval - elapsed_since_frame) / time.Millisecond))
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
			sys_tick_due := false
			if time.tick_since(last_sys_sample) >= 500 * time.Millisecond {
				last_sys_sample = now
				sample_live_system_metrics(app)
				sys_tick_due = true
			}
			if (len(queued_inputs) > 0 && time.tick_diff(last_tick, now) >= target_frame_interval) || sys_tick_due {
				last_tick = now
				for q_ev in queued_inputs {
					if res_ev, is_res := q_ev.(bifrost.Resize_Event); is_res {
						_ = bifrost.screen_resize(&app.screen, max(80, res_ev.width), max(20, res_ev.height))
					}
				}
				step_showcase_frame(app, ..queued_inputs[:])
				clear(&queued_inputs)
				if strings.builder_len(app.ansi_builder) > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
				}
			}
		}
	} else {
		// Deterministic headless walkthrough exercising all components together:
		// 1. Initial frame render (focused on `arch_tree` in the left pane)
		step_showcase_frame(app)

		// 2. Track 12 (`ui_tree`): Navigate down to `core/` -> collapse `core/` via `h`,
		//    step down to `widgets/canvas.odin (T14)` (5 steps: `widgets/` -> `T11` -> `T12` -> `T13` -> `T14`),
		//    and activate `canvas.odin (T14)` with Enter!
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // `core/` (node 1)
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'h'}) // collapse `core/`! (4 children hidden)
		for _ in 0 ..< 5 {
			step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // step down to `canvas.odin (T14)` (node 10)
		}
		step_showcase_frame(app, bifrost.Key_Event{code = .Enter}) // activate leaf node `canvas.odin (T14)`

		// 3. Focus Tab 0 (`Editor & Docs` — `notes_editor`) via 2-step chord `g n` (`Focus_Editor`),
		//    enter `.Editing` mode via Enter, append a comment line at the bottom, and press Escape to return to `.Navigation`
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'n'}) // 2-step chord `g n` -> `nav.editor` (`notes_editor`)
		step_showcase_frame(app, bifrost.Key_Event{code = .Enter})          // two-stage Enter -> `.Editing` mode in `notes_editor`
		step_showcase_frame(app, bifrost.Key_Event{code = .End})
		step_showcase_frame(app, bifrost.Key_Event{code = .Enter})
		for ch in "// Verified in headless showcase!" {
			step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = ch})
		}
		step_showcase_frame(app, bifrost.Key_Event{code = .Escape}) // exit `.Editing` -> `.Navigation` mode

		// 4. Track 13 (`ui_tabs`) + Track 14 (`ui_canvas` & `ui_sparkline`):
		//    Press `]` to switch to Tab 2 (`Braille Telemetry`), pulse the wave twice (`p`),
		//    then press `]` to switch to Tab 3 (`Inspector & Keys`), focus `btn_collapse_tests`,
		//    then press `Alt+1` to jump back to Tab 1 (verifying H* restores `notes_editor`),
		//    and finally press `Alt+2` to showcase the live Braille + Sparkline canvas on screen!
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = ']'}) // switch to Tab 2 (`Braille Telemetry`)
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'p'}) // pulse wave phase
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'p'}) // pulse wave phase again
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = ']'}) // switch to Tab 3 (`Inspector & Keys`)
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = 'j'}) // move focus to `btn_collapse_tests` in Tab 3
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = '1', mods = {.Alt}}) // Alt+1 -> Tab 1 (`notes_editor` restored via H*)

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

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&app.screen, "Bifrost Showcase — Tab 1: Editor & Tree", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/widget_showcase_tab1.html", dir), strings.to_string(b))
		}

		// Switch to Tab 2 (`Alt+2`) so the headless output also prints the rendered Braille & Sparkline view
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = '2', mods = {.Alt}})
		fmt.printf(
			"\n[Bifrost Showcase — Tab 2 (2x4 Braille Canvas + 8-Level Sparklines)] active_tab=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&app.screen, "Bifrost Showcase — Tab 2: Braille Telemetry & Sparklines", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/widget_showcase_tab2.html", dir), strings.to_string(b))
		}

		// Switch to Tab 4 (`Alt+4`) to showcase Track 15 Form Controls
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = '4', mods = {.Alt}})
		fmt.printf(
			"\n[Bifrost Showcase — Tab 4 (Track 15 Form Controls Suite)] active_tab=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		// Switch to Tab 5 (`Alt+5`) to showcase the Cartesian 2D Coordinate Chart and Categorical Bar Charts
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = '5', mods = {.Alt}})
		fmt.printf(
			"\n[Bifrost Showcase — Tab 5 (Cartesian 2D Chart + Bar Charts)] active_tab=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		// Switch to Tab 6 (`Alt+6`) to showcase the Track 18 Markdown Viewer
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = '6', mods = {.Alt}})
		fmt.printf(
			"\n[Bifrost Showcase — Tab 6 (Track 18 Markdown Manual)] active_tab=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		// Switch to Tab 7 (`Alt+7`) to flush and inspect live Heimdall Arrow IPC telemetry records
		step_showcase_frame(app, bifrost.Key_Event{code = .Rune, ch = '7', mods = {.Alt}})
		fmt.printf(
			"\n[Bifrost Showcase — Tab 7 (Heimdall Arrow IPC Viewer)] active_tab=%d segments=%d records=%d spans=%d frames=%d actions=%d\n",
			bifrost.get_active_tab(&app.input, "workspace_tabs") + 1,
			app.heimdall_store.segment_count,
			len(app.heimdall_store.records),
			app.heimdall_store.total_spans,
			app.frames_rendered,
			app.action_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&app.screen, "Bifrost Showcase — Tab 7: Heimdall Arrow IPC Viewer", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/widget_showcase_tab4.html", dir), strings.to_string(b))
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
