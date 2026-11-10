package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "../../bifrost"
import actor "../../deps/heimdall/deps/sleipnir/actor"
import xitdb "../../deps/xitdb/xitdb"

// =============================================================================
// Flagship 1,000,000-Row SIMD CSV Grid Workbench (`examples/csv_workbench`)
// =============================================================================
//
// Features:
//   - Loads real PitchBook / Attio CSV benchmarks from `benchmarks/data/`
//     (`LPDirectInvestmentRelation.csv` 74k rows, `Person.csv` 30k rows x 31 cols,
//     `LimitedPartner.csv`, `all-companies.csv` 190 cols, `all-contacts.csv` 65 cols)
//     or any custom `--file <path.csv>` argument, with a built-in RFC 4180 fallback dataset.
//   - Instantaneous `1,000,000`-row virtual scale toggle (`m`), frozen left columns (`p`),
//     interactive column sorting (`s` or click header), column resizing (`+`/`-`/`0` or drag `│`/`║`),
//     live substring filtering (`/`), multi-row interval selection (`x` / `Ctrl+A` / `Ctrl+I`),
//     and full-record detail modal (`i` or `Enter`).
//   - Zero persistent heap allocations per frame (`--lint-temp` verified) and 30 FPS HUD.

CSV_Preset :: struct {
	label: string,
	path:  string,
}

@(rodata)
CSV_PRESETS := [5]CSV_Preset{
	0 = {label = "LPDirectInvestment (74k x 7)",   path = "benchmarks/data/pitchbook/LPDirectInvestmentRelation.csv"},
	1 = {label = "PitchBook Person (30k x 31)",    path = "benchmarks/data/pitchbook/Person.csv"},
	2 = {label = "LimitedPartner (6k x 32)",       path = "benchmarks/data/pitchbook/LimitedPartner.csv"},
	3 = {label = "HubSpot Companies (3.5k x 190)", path = "benchmarks/data/hubspot/all-companies.csv"},
	4 = {label = "HubSpot Contacts (20k x 65)",    path = "benchmarks/data/hubspot/all-contacts.csv"},
}

FALLBACK_CSV_DATA ::
	"DealID,Company,Sector,Stage,CommittedUSD,IRR_Pct,HQ,LeadPartner,Notes\n" +
	"\"DL-1001\",\"Aether Quantum, Inc.\",\"DeepTech\",\"Series B\",\"$42,500,000\",\"28.4%\",\"San Francisco\",\"E. Vance\",\"Multiline\nBoard Observer\tHigh Conviction\"\n" +
	"\"DL-1002\",\"Borealis BioLabs\",\"Biotech\",\"Series A\",\"$18,000,000\",\"19.2%\",\"Boston\",\"M. Chen\",\"Phase II clinical trial milestone met\"\n" +
	"\"DL-1003\",\"Cobalt Grid Systems\",\"Energy\",\"Growth\",\"$95,000,000\",\"34.1%\",\"Austin\",\"S. Patel\",\"Utility-scale storage \"\"Megapack\"\" rollout\"\n" +
	"\"DL-1004\",\"Daedalus Robotics\",\"Industrial\",\"Seed\",\"$6,250,000\",\"41.0%\",\"Pittsburgh\",\"R. Koothrappali\",\"Autonomous warehouse fulfillment fleet\"\n" +
	"\"DL-1005\",\"Elysium Compute\",\"Semiconductors\",\"Series C\",\"$140,000,000\",\"52.8%\",\"San Jose\",\"L. Su\",\"Next-gen Wafer-Scale AI interconnect\"\n" +
	"\"DL-1006\",\"Fjord Maritime AI\",\"Logistics\",\"Series A\",\"$14,800,000\",\"15.6%\",\"Oslo\",\"H. Lindqvist\",\"Polar route fuel optimization\nZero-emission vessel routing\"\n" +
	"\"DL-1007\",\"GigaForge Materials\",\"Materials\",\"Series B\",\"$33,000,000\",\"22.9%\",\"Munich\",\"K. Weber\",\"Low-carbon titanium powder metallurgy\"\n" +
	"\"DL-1008\",\"Helios Fusion Corp\",\"Energy\",\"Series B\",\"$210,000,000\",\"11.5%\",\"Seattle\",\"A. Sakharov\",\"High-field HTS magnet quench test passed\"\n"

CSV_Workbench_Action :: enum u8 {
	None = 0,
	Preset_1,
	Preset_2,
	Preset_3,
	Preset_4,
	Preset_5,
	Toggle_Million,
	Cycle_Pinned,
	Toggle_Detail,
	Toggle_Row_Select,
	Extend_Row_Select,
	Select_All_Rows,
	Invert_Selection,
	Clear_Selection,
	Focus_Filter,
}

CSV_Workbench_Actions :: struct {
	preset_1:      CSV_Workbench_Action `bifrost:"action=csv.preset_1,chord=1|<M-1>,policy=root,category=Dataset,label='Load LPDirectInvestmentRelation.csv (74k rows)',desc=1:LPDirect"`,
	preset_2:      CSV_Workbench_Action `bifrost:"action=csv.preset_2,chord=2|<M-2>,policy=root,category=Dataset,label='Load PitchBook Person.csv (30k rows x 31 cols)',desc=2:Person"`,
	preset_3:      CSV_Workbench_Action `bifrost:"action=csv.preset_3,chord=3|<M-3>,policy=root,category=Dataset,label='Load LimitedPartner.csv (6k rows x 32 cols)',desc=3:LP"`,
	preset_4:      CSV_Workbench_Action `bifrost:"action=csv.preset_4,chord=4|<M-4>,policy=root,category=Dataset,label='Load Attio all-companies.csv (190 cols)',desc=4:Companies(190c)"`,
	preset_5:      CSV_Workbench_Action `bifrost:"action=csv.preset_5,chord=5|<M-5>,policy=root,category=Dataset,label='Load Attio all-contacts.csv (20k rows x 65 cols)',desc=5:Contacts(65c)"`,
	toggle_1m:     CSV_Workbench_Action `bifrost:"action=csv.toggle_1m,chord=m,policy=root,category=Scale,label='Toggle 1000000-Row Virtual Scale Mode',desc=1M Rows (m)"`,
	cycle_pinned:  CSV_Workbench_Action `bifrost:"action=csv.cycle_pinned,chord=p,policy=root,category=Columns,label='Cycle Frozen Left Columns (0/1/2/3)',desc=Freeze Cols (p)"`,
	toggle_detail: CSV_Workbench_Action `bifrost:"action=csv.toggle_detail,chord=i,policy=root,category=Inspect,label='Open Full-Record Vertical Field Inspector Modal',desc=Inspect Row (i)"`,
	toggle_sel:    CSV_Workbench_Action `bifrost:"action=csv.toggle_sel,chord=x,policy=root,category=Selection,label='Toggle Selection on Current Row',desc=Select Row (x)"`,
	extend_sel:    CSV_Workbench_Action `bifrost:"action=csv.extend_sel,chord=X,policy=root,category=Selection,label='Extend Selection from Anchor to Current Row',desc=Range Sel (X)"`,
	select_all:    CSV_Workbench_Action `bifrost:"action=csv.select_all,chord=<C-a>,policy=global,allow_in_edit=false,category=Selection,label='Select All Visible Rows (O(1) Interval)',desc=All (^A)"`,
	invert_sel:    CSV_Workbench_Action `bifrost:"action=csv.invert_sel,chord=I|<M-i>|<C-i>,policy=root,category=Selection,label='Invert Disjoint Row Selection Set',desc=Invert (I)"`,
	clear_sel:     CSV_Workbench_Action `bifrost:"action=csv.clear_sel,chord=c,policy=root,category=Selection,label='Clear Row Selection Set',desc=Clear Sel (c)"`,
	focus_filter:  CSV_Workbench_Action `bifrost:"action=csv.focus_filter,chord=/,policy=root,category=Filter,label='Focus Substring Filter Bar',desc=Filter (/)"`,
}

CSV_Workbench_App :: struct {
	grid:             bifrost.CSV_Grid_Table,
	selection:        bifrost.Table_Selection_Set,
	track:            ^mem.Tracking_Allocator,
	perf:             bifrost.Heimdall_Runtime_Metrics,
	active_preset:    int,
	dataset_label:    string,
	million_mode:     bool,
	pinned_cols:      i32,
	detail_open:      bool,
	query_buf:        [128]u8,
	query_len:        int,
	last_index_us:    i64,
	last_sort_us:     i64,
	last_frame_ns:    i64,
	last_slice:       bifrost.Virtual_Slice,
}

active_workbench_query :: proc "contextless" (app: ^CSV_Workbench_App) -> string {
	if app == nil || app.query_len <= 0 {
		return ""
	}
	return string(app.query_buf[:app.query_len])
}

set_workbench_query :: proc "contextless" (app: ^CSV_Workbench_App, q: string) {
	if app == nil {
		return
	}
	n := min(len(q), len(app.query_buf))
	if n > 0 {
		copy(app.query_buf[:n], q[:n])
	}
	app.query_len = n
}

load_workbench_dataset :: proc(app: ^CSV_Workbench_App, preset_idx: int, custom_path: string = "") -> bool {
	if app == nil {
		return false
	}
	t0 := time.tick_now()
	loaded := false
	if len(custom_path) > 0 {
		if bifrost.csv_grid_load_file(&app.grid, custom_path, ',', context.allocator) {
			app.dataset_label = custom_path
			loaded = true
		}
	} else if preset_idx >= 0 && preset_idx < len(CSV_PRESETS) {
		p := CSV_PRESETS[preset_idx]
		if bifrost.csv_grid_load_file(&app.grid, p.path, ',', context.allocator) {
			app.active_preset = preset_idx
			app.dataset_label = p.label
			loaded = true
		}
	}

	if !loaded {
		if app.grid.physical_row_count > 0 {
			return false
		}
		// Initial boot fallback: try any available preset in `benchmarks/data/`, or embedded RFC 4180 CSV
		for p, idx in CSV_PRESETS {
			if bifrost.csv_grid_load_file(&app.grid, p.path, ',', context.allocator) {
				app.active_preset = idx
				app.dataset_label = p.label
				loaded = true
				break
			}
		}
		if !loaded {
			bifrost.csv_grid_init_from_bytes(&app.grid, transmute([]u8)string(FALLBACK_CSV_DATA), false, ',', context.allocator)
			app.dataset_label = "Embedded Venture Deals (Fallback)"
		}
	}

	if app.million_mode {
		bifrost.csv_grid_set_virtual_rows(&app.grid, 1_000_000)
	}
	app.last_index_us = i64(time.tick_since(t0) / time.Microsecond)
	app.last_sort_us  = 0
	app.query_len     = 0
	bifrost.table_selection_clear(&app.selection)
	return true
}

select_workbench_preset :: proc(coord: ^bifrost.UI_Coordinator_State, app: ^CSV_Workbench_App, preset_idx: int) {
	if load_workbench_dataset(app, preset_idx) {
		bifrost.set_text(&coord.input, "csv_filter_input", "")
		reset_grid_viewport(coord)
	}
}

reset_grid_viewport :: proc(coord: ^bifrost.UI_Coordinator_State) {
	if coord == nil {
		return
	}
	slot := bifrost.get_scroll_slot(&coord.input, bifrost.hash_id("csv_main_table"))
	slot.offset       = 0
	slot.offset_x     = 0
	slot.selected_row = 0
	slot.selected_col = 0
	slot.sort_col     = -1
	slot.sort_dir     = .None
	slot.sort_changed = false
	for i := 0; i < bifrost.MAX_TABLE_COLS; i += 1 {
		slot.col_max_observed[i] = 0
		slot.col_user_widths[i]  = 0
	}
}

render_csv_workbench_pass :: proc(coord: ^bifrost.UI_Coordinator_State) {
	app := (^CSV_Workbench_App)(coord.user_ptr)
	if app == nil {
		return
	}
	coord.use_widget_pipeline = true
	temp_alloc := context.temp_allocator

	frame_t0 := time.tick_now()
	bifrost.heimdall_sample_runtime_metrics(
		&app.perf,
		u64(coord.total_frames + 1),
		app.last_frame_ns,
		app.track,
	)

	// Synchronize live filter query from `csv_filter_input`
	live_q := bifrost.get_text(&coord.input, "csv_filter_input")
	if live_q != active_workbench_query(app) {
		set_workbench_query(app, live_q)
		t0 := time.tick_now()
		bifrost.csv_grid_set_filter(&app.grid, live_q)
		app.last_sort_us = i64(time.tick_since(t0) / time.Microsecond)
		bifrost.table_selection_clear(&app.selection)
		slot := bifrost.get_scroll_slot(&coord.input, bifrost.hash_id("csv_main_table"))
		slot.offset       = 0
		slot.selected_row = 0
	}

	// Open/close detail modal when `csv_main_table` or `csv_detail_table` is activated via keyboard (`Enter`/`Space`, where `clicked_id == 0`)
	if coord.input.clicked_id == 0 {
		if !app.detail_open && coord.input.activated_id == bifrost.hash_id("csv_main_table") {
			app.detail_open = true
			coord.input.wants_focus_id = bifrost.hash_id("csv_detail_table")
		} else if app.detail_open && (coord.input.activated_id == bifrost.hash_id("csv_detail_table") || coord.input.activated_id == bifrost.hash_id("csv_main_table")) {
			app.detail_open = false
			coord.input.wants_focus_id = bifrost.hash_id("csv_main_table")
		}
	}
	if app.detail_open && (coord.input.escape_modal_id == bifrost.hash_id("csv_detail_modal") || coord.input.backdrop_clicked_id == bifrost.hash_id("csv_detail_modal")) {
		app.detail_open = false
		coord.input.wants_focus_id = bifrost.hash_id("csv_main_table")
	}

	bifrost.begin_frame(&coord.screen)
	bifrost.begin_layout(&coord.layout_ctx, i32(coord.cols), i32(coord.rows), temp_alloc)

	if bifrost.container(&coord.layout_ctx, "wb_root", bifrost.Box_Config{
		dir         = .Column,
		width       = bifrost.fixed(i32(coord.cols)),
		height      = bifrost.fixed(i32(coord.rows)),
		focus_scope = true,
	}) {
		// 1. Top Banner: Dataset Stats + SIMD Indexer
		vis_rows  := bifrost.csv_grid_visible_row_count(&app.grid)
		phys_rows := app.grid.physical_row_count
		col_cnt   := len(app.grid.col_specs)
		sel_cnt   := bifrost.table_selection_count(&app.selection, vis_rows)
		size_kb   := len(app.grid.raw_data) / 1024

		banner_str := fmt.aprintf(
			" BIFROST SIMD CSV WORKBENCH | %s (%d KB) | rows=%d (phys=%d) cols=%d | pinned=%d sel=%d | idx=%dus sort=%dus",
			app.dataset_label,
			size_kb,
			vis_rows,
			phys_rows,
			col_cnt,
			app.pinned_cols,
			sel_cnt,
			app.last_index_us,
			app.last_sort_us,
			allocator = temp_alloc,
		)
		coord.screen.paints[bifrost.hash_id("wb_banner")] = bifrost.Paint_Spec{
			text    = banner_str,
			fg      = bifrost.rgb(235, 245, 255),
			bg      = bifrost.rgb(22, 38, 64),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "wb_banner", 40, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		// 1b. Live App Performance & Resource Metrics Strip (FPS, Frame Time, CPU %, MEM Heap KB/MB, RSS MB)
		rss_mb  := f64(app.perf.rss_kb) / 1024.0
		heap_kb := f64(app.perf.heap_bytes) / 1024.0
		peak_kb := f64(app.perf.peak_heap_bytes) / 1024.0
		perf_str := fmt.aprintf(
			" Perf: %.1f FPS (frame=%dus) | CPU: %.1f%% | MEM (Heap): %.0f KB (peak %.0f KB) | RSS: %.1f MB | Index: %d chks (%d KB raw)",
			app.perf.fps,
			app.perf.frame_time_us,
			app.perf.cpu_percent,
			heap_kb,
			peak_kb,
			rss_mb,
			len(app.grid.checkpoints),
			size_kb,
			allocator = temp_alloc,
		)
		perf_fg := bifrost.rgb(135, 230, 170)
		if app.perf.cpu_percent >= 50.0 || (app.perf.fps > 0.0 && app.perf.fps < 25.0) {
			perf_fg = bifrost.rgb(255, 205, 110)
		}
		coord.screen.paints[bifrost.hash_id("wb_perf_strip")] = bifrost.Paint_Spec{
			text    = perf_str,
			fg      = perf_fg,
			bg      = bifrost.rgb(20, 28, 42),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "wb_perf_strip", 40, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		// 2. Filter & Dataset Controls Bar
		if bifrost.container(&coord.layout_ctx, "wb_toolbar", bifrost.Box_Config{
			dir     = .Row,
			width   = bifrost.grow(1),
			height  = bifrost.fixed(1),
			gap     = 2,
			padding = {left = 1, right = 1},
		}) {
			bifrost.ui_label(&coord.layout_ctx, &coord.screen, "wb_filter_lbl", "Filter (/):", bifrost.rgb(135, 215, 255), {.Bold})
			bifrost.ui_text_input(&coord.layout_ctx, &coord.screen, &coord.input, "csv_filter_input", bifrost.Text_Input_Config{
				placeholder    = "substring across all columns...",
				linked_list_id = "csv_main_table",
				width          = bifrost.fixed(38),
				height         = bifrost.fixed(1),
				fg             = bifrost.rgb(230, 240, 255),
				bg             = bifrost.rgb(26, 34, 48),
				focus_flags    = {.Focusable, .Captures_Text},
			})

			sort_label := "Unsorted"
			if app.grid.active_sort_dir != .None && app.grid.active_sort_col >= 0 && int(app.grid.active_sort_col) < len(app.grid.headers) {
				dir_sym := "▲ ASC" if app.grid.active_sort_dir == .Asc else "▼ DESC"
				sort_label = fmt.aprintf("%s (%s)", app.grid.headers[app.grid.active_sort_col], dir_sym, allocator = temp_alloc)
			}
			toolbar_info := fmt.aprintf(
				"Sort(s/click): %s | Scale(m): %s | Resize: +/-/0/drag | Preset: 1..5",
				sort_label,
				"1,000,000 VIRTUAL" if app.million_mode else "Physical",
				allocator = temp_alloc,
			)
			coord.screen.paints[bifrost.hash_id("wb_toolbar_info")] = bifrost.Paint_Spec{
				text = toolbar_info,
				fg   = bifrost.rgb(165, 195, 225),
			}
			_ = bifrost.leaf(&coord.layout_ctx, "wb_toolbar_info", 20, 1, bifrost.Box_Config{
				width  = bifrost.grow(1),
				height = bifrost.fixed(1),
			})
		}

		// 3. Main 2D Virtualized CSV Grid (`ui_table`)
		if bifrost.ui_table(
			&coord.layout_ctx,
			&coord.screen,
			&coord.input,
			"csv_main_table",
			app.grid.col_specs[:],
			vis_rows,
			bifrost.Table_Config{
				width            = bifrost.grow(1),
				height           = bifrost.grow(1),
				border           = .Rounded,
				gutter_width     = 8,
				show_row_numbers = true,
				pinned_cols      = app.pinned_cols,
				sortable         = true,
				resizable        = true,
				selection        = &app.selection,
				focus_flags      = {.Focusable, .Default_Focus},
				border_fg        = bifrost.rgb(75, 110, 155),
				title_fg         = bifrost.rgb(135, 215, 255),
			},
			&app.last_slice,
		) {
			if app.last_slice.sort_changed {
				t0 := time.tick_now()
				bifrost.csv_grid_set_sort(&app.grid, app.last_slice.sort_col, app.last_slice.sort_dir)
				app.last_sort_us = i64(time.tick_since(t0) / time.Microsecond)
				bifrost.table_selection_clear(&app.selection)
				new_vis := bifrost.csv_grid_visible_row_count(&app.grid)
				vis_rows = new_vis
				slot := bifrost.get_scroll_slot(&coord.input, bifrost.hash_id("csv_main_table"))
				v_rows := max(1, app.last_slice.viewport_rows)
				slot.total_rows   = new_vis
				slot.max_offset   = max(0, new_vis - v_rows)
				slot.offset       = clamp(slot.offset, 0, slot.max_offset)
				slot.selected_row = clamp(slot.selected_row, 0, max(0, new_vis - 1))
				app.last_slice.total_rows    = new_vis
				app.last_slice.scroll_offset = slot.offset
				app.last_slice.selected_row  = slot.selected_row
				app.last_slice.start_row     = clamp(slot.offset, 0, new_vis)
				app.last_slice.end_row       = clamp(app.last_slice.start_row + v_rows, app.last_slice.start_row, new_vis)
			}

			grid_title := fmt.aprintf(
				"%s — Showing rows [%d..%d) of %d | Cols [%d..%d) of %d (Pinned: %d)",
				app.dataset_label,
				app.last_slice.start_row,
				app.last_slice.end_row,
				vis_rows,
				app.last_slice.start_col,
				app.last_slice.end_col,
				col_cnt,
				app.pinned_cols,
				allocator = temp_alloc,
			)
			if p, has_p := &coord.screen.paints[bifrost.hash_id("csv_main_table")]; has_p {
				p.title = grid_title
			}

			max_cols := min(len(app.grid.col_specs), bifrost.MAX_TABLE_COLS)
			slice_limit := clamp(max(int(app.last_slice.end_col), int(app.last_slice.pinned_cols)), 0, max_cols)
			fields_buf := make([]string, max(1, max_cols), temp_alloc)
			row_cells  := make([]string, max(1, max_cols), temp_alloc)

			for r := app.last_slice.start_row; r < app.last_slice.end_row; r += 1 {
				extracted := bifrost.csv_grid_slice_row(&app.grid, r, fields_buf, temp_alloc, slice_limit)
				for c := 0; c < slice_limit; c += 1 {
					if c < extracted && bifrost.ui_table_is_col_visible(app.last_slice, c) {
						row_cells[c] = fields_buf[c]
					} else {
						row_cells[c] = ""
					}
				}
				bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, r, row_cells[:slice_limit])
			}
		}

		// 4. Selected Cell Preview Bar
		sel_r := app.last_slice.selected_row
		sel_c := int(app.last_slice.selected_col)
		col_name := app.grid.headers[sel_c] if (sel_c >= 0 && sel_c < len(app.grid.headers)) else "Col"
		raw_val := bifrost.csv_grid_extract_visual_cell(&app.grid, sel_r, sel_c, temp_alloc)
		// Sanitize newlines in status preview bar
		clean_preview, _ := strings.replace_all(raw_val, "\n", " ↵ ", temp_alloc)
		clean_preview, _ = strings.replace_all(clean_preview, "\r", "", temp_alloc)

		status_line := fmt.aprintf(
			" Cursor [Row %d / %d, Col %d/%d %q]: %s",
			sel_r + 1,
			vis_rows,
			sel_c + 1,
			col_cnt,
			col_name,
			clean_preview,
			allocator = temp_alloc,
		)
		coord.screen.paints[bifrost.hash_id("wb_status")] = bifrost.Paint_Spec{
			text    = status_line,
			fg      = bifrost.rgb(215, 230, 245),
			bg      = bifrost.rgb(18, 26, 38),
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "wb_status", 24, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		bifrost.ui_key_hint_bar(&coord.layout_ctx, &coord.screen, &coord.input, "wb_hint_bar")
	}

	// 5. Full-Record Vertical Inspector Modal (`i` or `Enter` on any row — inspect all 190+ columns!)
	if app.detail_open {
		modal_w := clamp(i32(coord.cols) - 10, 48, 104)
		modal_h := clamp(i32(coord.rows) - 4, 12, 28)

		sel_r := app.last_slice.selected_row
		_, phys_r, _ := bifrost.csv_grid_map_visual_row(&app.grid, sel_r)
		modal_title := fmt.aprintf(
			"Record Inspector — Visual Row #%d (Physical Row #%d, %d Columns) [Esc/Enter to close]",
			sel_r + 1,
			phys_r + 1,
			len(app.grid.headers),
			allocator = temp_alloc,
		)

		if bifrost.ui_modal(
			&coord.layout_ctx,
			&coord.screen,
			"csv_detail_modal",
			{
				title     = modal_title,
				z_layer   = 20,
				width     = bifrost.fixed(modal_w),
				height    = bifrost.fixed(modal_h),
				border    = .Double,
				backdrop  = .Dim_Screen,
				fg        = bifrost.rgb(225, 235, 245),
				bg        = bifrost.rgb(16, 22, 34),
				border_fg = bifrost.rgb(95, 165, 235),
				title_fg  = bifrost.rgb(135, 215, 255),
			},
		) {
			detail_cols := [3]bifrost.Table_Column_Spec{
				0 = {header = "#",     kind = .Fixed, value = 5,  min_width = 4, align = .Right},
				1 = {header = "Field", kind = .Fixed, value = 26, min_width = 12, max_width = 32, align = .Left},
				2 = {header = "Value", kind = .Fill,  value = 1,  min_width = 16, align = .Left},
			}
			total_fields := i32(len(app.grid.headers))
			detail_slice: bifrost.Virtual_Slice
			if bifrost.ui_table(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"csv_detail_table",
				detail_cols[:],
				total_fields,
				bifrost.Table_Config{
					width  = bifrost.grow(1),
					height = bifrost.grow(1),
					border = .None,
				},
				&detail_slice,
			) {
				rec_fields := make([]string, max(1, int(total_fields)), temp_alloc)
				ext_cnt := bifrost.csv_grid_slice_row(&app.grid, sel_r, rec_fields, temp_alloc)
				for f_idx := detail_slice.start_row; f_idx < detail_slice.end_row; f_idx += 1 {
					idx_str := fmt.aprintf("%d", f_idx + 1, allocator = temp_alloc)
					f_name  := app.grid.headers[f_idx] if int(f_idx) < len(app.grid.headers) else ""
					f_val   := rec_fields[f_idx] if int(f_idx) < ext_cnt else ""
					row_arr := [3]string{idx_str, f_name, f_val}
					bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, f_idx, row_arr[:])
				}
			}
		}
	}

	coord.palette.is_open = coord.palette_open
	if coord.palette.is_open {
		bifrost.ui_command_palette(&coord.layout_ctx, &coord.screen, &coord.input, &coord.palette, 64, 4)
	}

	bifrost.end_layout(&coord.layout_ctx)
	app.last_frame_ns = i64(time.tick_since(frame_t0))
}

on_workbench_action :: proc(coord: ^bifrost.UI_Coordinator_State, action_name: string, userdata: rawptr) {
	app := (^CSV_Workbench_App)(userdata)
	if app == nil || coord == nil {
		return
	}
	switch action_name {
	case "csv.preset_1", "csv.preset_2", "csv.preset_3", "csv.preset_4", "csv.preset_5":
		preset_idx := int(action_name[len(action_name) - 1] - '1')
		select_workbench_preset(coord, app, preset_idx)
	case "csv.toggle_1m":
		app.million_mode = !app.million_mode
		if app.million_mode {
			bifrost.csv_grid_set_virtual_rows(&app.grid, 1_000_000)
		} else {
			bifrost.csv_grid_set_virtual_rows(&app.grid, app.grid.physical_row_count)
		}
	case "csv.cycle_pinned":
		app.pinned_cols = (app.pinned_cols + 1) % 4
	case "csv.toggle_detail":
		app.detail_open = !app.detail_open
		if app.detail_open {
			coord.input.wants_focus_id = bifrost.hash_id("csv_detail_table")
		} else {
			coord.input.wants_focus_id = bifrost.hash_id("csv_main_table")
		}
	case "csv.toggle_sel":
		sel_r := bifrost.get_selected_row(&coord.input, "csv_main_table")
		bifrost.table_selection_toggle_row(&app.selection, sel_r)
	case "csv.extend_sel":
		sel_r := bifrost.get_selected_row(&coord.input, "csv_main_table")
		bifrost.table_selection_extend_to(&app.selection, sel_r)
	case "csv.select_all":
		bifrost.table_selection_select_all(&app.selection)
	case "csv.invert_sel":
		app.selection.invert_all = !app.selection.invert_all
	case "csv.clear_sel":
		bifrost.table_selection_clear(&app.selection)
	case "csv.focus_filter":
		coord.input.wants_focus_id = bifrost.hash_id("csv_filter_input")
		coord.input.editing_id     = bifrost.hash_id("csv_filter_input")
	}
	coord.dirty        = true
	coord.layout_dirty = true
}

extract_row_text :: proc(coord: ^bifrost.UI_Coordinator_State, row: int, alloc := context.temp_allocator) -> string {
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

run_csv_workbench :: proc(live_tty: bool, custom_file: string, track: ^mem.Tracking_Allocator = nil) -> bool {
	defer free_all(context.temp_allocator)

	app: CSV_Workbench_App
	app.track       = track
	app.pinned_cols = 1
	bifrost.table_selection_init(&app.selection, context.allocator)
	defer bifrost.table_selection_destroy(&app.selection)
	defer bifrost.csv_grid_destroy(&app.grid)

	_ = load_workbench_dataset(&app, 0, custom_file)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	if db_err != nil {
		return false
	}
	shared := bifrost.Xitdb_Shared_Handle{db = &db}

	sched: actor.Scheduler
	if actor.scheduler_init(&sched, actor.Scheduler_Config{
		num_workers    = 1,
		num_shards     = 1,
		batch_quota    = 2048,
		enable_parking = true,
	}, context.allocator) != nil {
		return false
	}

	ui_actor: ^actor.Actor(bifrost.UI_Coordinator_State, bifrost.UI_Msg)
	defer {
		actor.scheduler_wait_idle(&sched)
		ui_state: bifrost.UI_Coordinator_State
		has_ui := ui_actor != nil
		if has_ui {
			ui_state = ui_actor.state
			ui_actor.state = {}
		}
		actor.scheduler_stop_and_destroy(&sched)
		if has_ui {
			bifrost.ui_coordinator_destroy(&ui_state)
		}
	}

	cols := 120
	rows := 28
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
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

	ui_ok: bool
	ui_actor, ui_ok = bifrost.spawn_ui_coordinator(
		&sched,
		cols,
		rows,
		&shared,
		render_csv_workbench_pass,
		context.allocator,
	)
	if !ui_ok {
		return false
	}
	ui_actor.state.user_ptr               = &app
	ui_actor.state.primary_list_id        = "csv_main_table"
	ui_actor.state.input.wants_focus_id   = bifrost.hash_id("csv_main_table")
	_ = bifrost.register_actions_struct(&ui_actor.state.input, &ui_actor.state.palette, CSV_Workbench_Actions{})
	ui_pid := actor.pid(ui_actor)

	action_names := [?]string{
		"csv.preset_1",
		"csv.preset_2",
		"csv.preset_3",
		"csv.preset_4",
		"csv.preset_5",
		"csv.toggle_1m",
		"csv.cycle_pinned",
		"csv.toggle_detail",
		"csv.toggle_sel",
		"csv.extend_sel",
		"csv.select_all",
		"csv.invert_sel",
		"csv.clear_sel",
		"csv.focus_filter",
	}
	for act in action_names {
		_ = bifrost.on_ui_action(&ui_actor.state, act, on_workbench_action, &app)
	}

	actor.scheduler_start(&sched)

	if live_tty {
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)
		if ui_actor.state.last_ansi_bytes > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
		}

		boot_tick  := time.tick_now()
		last_tick  := boot_tick
		last_pulse := boot_tick
		target_frame_interval := 33 * time.Millisecond
		heartbeat_interval    := 500 * time.Millisecond
		queued_inputs         := make([dynamic]bifrost.Input_Event, 0, 64, context.allocator)
		defer delete(queued_inputs)

		for !ui_actor.state.quit_requested {
			elapsed_since_frame := time.tick_diff(last_tick, time.tick_now())
			wait_ms := max(i32(1), i32((target_frame_interval - elapsed_since_frame) / time.Millisecond))
			ev, has_ev, _ := bifrost.poll_next_event(&term, wait_ms)
			if has_ev {
				_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev, &ui_actor.state.input)
				for drain := 0; drain < 128; drain += 1 {
					ev2, has_ev2, _ := bifrost.poll_next_event(&term, 0)
					if !has_ev2 {
						break
					}
					_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev2, &ui_actor.state.input)
				}
			}
			now := time.tick_now()
			is_heartbeat := time.tick_diff(last_pulse, now) >= heartbeat_interval
			if is_heartbeat {
				last_pulse = now
				ui_actor.state.dirty        = true
				ui_actor.state.layout_dirty = true
			}
			if time.tick_diff(last_tick, now) >= target_frame_interval || is_heartbeat {
				last_tick = now
				if len(queued_inputs) > 0 || ui_actor.state.dirty || ui_actor.state.input.pending_chord.active {
					bifrost.ui_send_inputs_and_tick(
						&sched,
						ui_pid,
						queued_inputs[:],
						max(1, i64(time.tick_diff(boot_tick, now))),
						context.temp_allocator,
					)
					clear(&queued_inputs)
					actor.scheduler_wait_idle(&sched)
					if ui_actor.state.last_ansi_bytes > 0 {
						_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
					}
				}
			}
		}
	} else {
		// Headless verification:
		// 1. Render initial dataset frame
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Toggle 1,000,000-row virtual scaling (`m`), jump to bottom (`G`), and select all 1M rows (`Ctrl+A`)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'm'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .End}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'a', ctrl = true}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
		actor.scheduler_wait_idle(&sched)

		vis_now := bifrost.csv_grid_visible_row_count(&app.grid)
		fmt.printf(
			"[Bifrost SIMD CSV Workbench — 1,000,000-Row Scale] dataset=%q phys_rows=%d vis_rows=%d cols=%d selected=%d idx_us=%d\n",
			app.dataset_label,
			app.grid.physical_row_count,
			vis_now,
			len(app.grid.col_specs),
			bifrost.table_selection_count(&app.selection, vis_now),
			app.last_index_us,
		)
		for r := 0; r < min(12, ui_actor.state.rows); r += 1 {
			fmt.printf("  %s\n", extract_row_text(&ui_actor.state, r))
		}

		if vis_now != 1_000_000 {
			return false
		}
		if bifrost.table_selection_count(&app.selection, vis_now) != 1_000_000 {
			return false
		}

		// 3. Load Preset 4 (`all-companies.csv` 190 columns if present) and jump to the last column (`$`)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '4'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 3}))
		actor.scheduler_wait_idle(&sched)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '$'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 4}))
		actor.scheduler_wait_idle(&sched)

		fmt.printf(
			"\n[Bifrost SIMD CSV Workbench — Wide Column Pan] dataset=%q cols=%d selected_col=%d scroll_offset_x=%d\n",
			app.dataset_label,
			len(app.grid.col_specs),
			bifrost.get_selected_col(&ui_actor.state.input, "csv_main_table"),
			bifrost.get_scroll_offset_x(&ui_actor.state.input, "csv_main_table"),
		)
		for r := 0; r < min(10, ui_actor.state.rows); r += 1 {
			fmt.printf("  %s\n", extract_row_text(&ui_actor.state, r))
		}

		// 4. Verify mouse-clicking a row selects the row without opening the Record Inspector modal,
		//    and pressing `Enter` opens the modal and keeps it open across subsequent heartbeat ticks.
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Input{event = bifrost.Mouse_Event{x = 10, y = 7, col = 10, row = 7, action = .Press, button = .Left}}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Input{event = bifrost.Mouse_Event{x = 10, y = 7, col = 10, row = 7, action = .Release, button = .Left}}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 5}))
		actor.scheduler_wait_idle(&sched)
		if app.detail_open {
			return false
		}

		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Enter}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 6}))
		actor.scheduler_wait_idle(&sched)
		if !app.detail_open {
			return false
		}

		// Simulate subsequent heartbeat tick (dirty + layout_dirty with 0 input events): modal must stay open
		ui_actor.state.dirty        = true
		ui_actor.state.layout_dirty = true
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 7}))
		actor.scheduler_wait_idle(&sched)
		if !app.detail_open {
			return false
		}
	}

	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	live_tty    := false
	custom_file := ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--live-tty" {
			live_tty = true
		} else if args[i] == "--file" && i + 1 < len(args) {
			custom_file = args[i + 1]
			i += 1
		} else if !strings.has_prefix(args[i], "-") && len(custom_file) == 0 {
			custom_file = args[i]
		}
	}

	ok := run_csv_workbench(live_tty, custom_file, &track)

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
