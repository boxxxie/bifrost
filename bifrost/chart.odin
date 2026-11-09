package bifrost

import "core:fmt"
import "core:math"
import "core:mem"

// =============================================================================
// Track 17: Cartesian 2D Coordinate Charts & Categorical Bar Charts (`ui_chart`,
//           `ui_bar_chart`)
// =============================================================================

Axis_Config :: struct {
	title:  string,
	bounds: [2]f64,
	labels: []string,
	fg:     Color,
	style:  Style_Flags,
}

Chart_Marker :: enum u8 {
	Braille_Line = 0,
	Braille_Dots = 1,
	Braille_Step = 2,
	Braille_Area = 3,
}

Chart_Dataset :: struct {
	name:    string,
	data:    [][2]f64,
	marker:  Chart_Marker,
	fg:      Color,
	fill_fg: Color,
}

Chart_Config :: struct {
	x_axis:      Axis_Config,
	y_axis:      Axis_Config,
	datasets:    []Chart_Dataset,
	show_grid:   bool,
	show_legend: bool,
	legend_fg:   Color,
	legend_bg:   Color,
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	border:      Border_Kind,
	border_fg:   Color,
	title:       string,
	title_fg:    Color,
	fg:          Color,
	bg:          Color,
	style:       Style_Flags,
	focus_flags: Focus_Flags,
}

Bar_Direction :: enum u8 {
	Vertical   = 0,
	Horizontal = 1,
}

Bar_Data :: struct {
	label: string,
	value: f64,
	color: Color,
}

Bar_Chart_Config :: struct {
	direction:   Bar_Direction,
	data:        []Bar_Data,
	bar_width:   i32,
	gap:         i32,
	no_gap:      bool,
	max_value:   f64,
	show_values: bool,
	bar_char:    rune,
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	border:      Border_Kind,
	border_fg:   Color,
	title:       string,
	title_fg:    Color,
	fg:          Color,
	bg:          Color,
	style:       Style_Flags,
	focus_flags: Focus_Flags,
}

Chart_Render_Kind :: enum u8 {
	Cartesian = 0,
	Bar_Chart = 1,
}

Chart_Render_Entry :: struct {
	kind:      Chart_Render_Kind,
	chart_cfg: Chart_Config,
	bar_cfg:   Bar_Chart_Config,
}

// Maps world point (wx, wy) in bounds to inner Braille canvas pixel coordinates (px, py)
chart_project_point :: proc "contextless" (
	point: [2]f64,
	x_bounds, y_bounds: [2]f64,
	pixel_w, pixel_h: i32,
) -> (px, py: i32, in_bounds: bool) {
	if pixel_w <= 0 || pixel_h <= 0 {
		return 0, 0, false
	}
	x_span := x_bounds[1] - x_bounds[0]
	y_span := y_bounds[1] - y_bounds[0]
	if x_span == 0.0 || y_span == 0.0 {
		return 0, 0, false
	}

	norm_x := (point[0] - x_bounds[0]) / x_span
	norm_y := (point[1] - y_bounds[0]) / y_span

	in_bounds = (norm_x >= 0.0 && norm_x <= 1.0 && norm_y >= 0.0 && norm_y <= 1.0)

	clamped_x := clamp(norm_x, 0.0, 1.0)
	clamped_y := clamp(norm_y, 0.0, 1.0)

	px = clamp(i32(math.round(clamped_x * f64(pixel_w - 1))), 0, pixel_w - 1)
	py = clamp(i32(math.round((1.0 - clamped_y) * f64(pixel_h - 1))), 0, pixel_h - 1)
	return px, py, in_bounds
}

@(private)
chart_project_point_unclamped :: proc "contextless" (
	point: [2]f64,
	x_bounds, y_bounds: [2]f64,
	pixel_w, pixel_h: i32,
) -> (px, py: f64, valid: bool) {
	if pixel_w <= 0 || pixel_h <= 0 {
		return 0.0, 0.0, false
	}
	x_span := x_bounds[1] - x_bounds[0]
	y_span := y_bounds[1] - y_bounds[0]
	if x_span == 0.0 || y_span == 0.0 {
		return 0.0, 0.0, false
	}
	norm_x := (point[0] - x_bounds[0]) / x_span
	norm_y := (point[1] - y_bounds[0]) / y_span
	px = norm_x * f64(pixel_w - 1)
	py = (1.0 - norm_y) * f64(pixel_h - 1)
	return px, py, true
}

// Liang-Barsky 2D line segment clipper against [0, pixel_w - 1] x [0, pixel_h - 1]
@(private)
chart_clip_segment :: proc "contextless" (
	x0, y0, x1, y1: f64,
	pixel_w, pixel_h: i32,
) -> (cx0, cy0, cx1, cy1: i32, visible: bool) {
	if pixel_w <= 0 || pixel_h <= 0 {
		return 0, 0, 0, 0, false
	}
	max_x := f64(pixel_w - 1)
	max_y := f64(pixel_h - 1)
	dx := x1 - x0
	dy := y1 - y0

	p := [4]f64{-dx, dx, -dy, dy}
	q := [4]f64{x0, max_x - x0, y0, max_y - y0}

	u1 := 0.0
	u2 := 1.0
	for i := 0; i < 4; i += 1 {
		if p[i] == 0.0 {
			if q[i] < 0.0 {
				return 0, 0, 0, 0, false
			}
		} else {
			t := q[i] / p[i]
			if p[i] < 0.0 {
				if t > u2 {
					return 0, 0, 0, 0, false
				}
				if t > u1 {
					u1 = t
				}
			} else {
				if t < u1 {
					return 0, 0, 0, 0, false
				}
				if t < u2 {
					u2 = t
				}
			}
		}
	}

	cx0 = clamp(i32(math.round(x0 + u1 * dx)), 0, pixel_w - 1)
	cy0 = clamp(i32(math.round(y0 + u1 * dy)), 0, pixel_h - 1)
	cx1 = clamp(i32(math.round(x0 + u2 * dx)), 0, pixel_w - 1)
	cy1 = clamp(i32(math.round(y0 + u2 * dy)), 0, pixel_h - 1)
	return cx0, cy0, cx1, cy1, true
}

ui_chart :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Chart_Config = {},
) -> i32 {
	id_h := hash_id(id)
	default_h: i32 = 10
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(default_h)

	if s != nil {
		chart_cfg := cfg
		if len(cfg.datasets) > 0 {
			ds_copy := make([]Chart_Dataset, len(cfg.datasets), context.temp_allocator)
			for ds, i in cfg.datasets {
				ds_copy[i] = ds
				if len(ds.data) > 0 {
					data_copy := make([][2]f64, len(ds.data), context.temp_allocator)
					copy(data_copy, ds.data)
					ds_copy[i].data = data_copy
				}
			}
			chart_cfg.datasets = ds_copy
		}
		if len(cfg.x_axis.labels) > 0 {
			xl_copy := make([]string, len(cfg.x_axis.labels), context.temp_allocator)
			copy(xl_copy, cfg.x_axis.labels)
			chart_cfg.x_axis.labels = xl_copy
		}
		if len(cfg.y_axis.labels) > 0 {
			yl_copy := make([]string, len(cfg.y_axis.labels), context.temp_allocator)
			copy(yl_copy, cfg.y_axis.labels)
			chart_cfg.y_axis.labels = yl_copy
		}

		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = {.Bold},
			fill_bg     = cfg.bg.kind != .Default,
		}
		s.chart_entries[id_h] = Chart_Render_Entry{
			kind      = .Cartesian,
			chart_cfg = chart_cfg,
		}
	}

	focusable := (.Focusable in cfg.focus_flags) || (.Default_Focus in cfg.focus_flags)
	f_flags := cfg.focus_flags
	if focusable {
		f_flags += {.Focusable}
	}
	return leaf(ctx, id, 20, default_h, Box_Config{
		width       = w,
		height      = h,
		padding     = cfg.padding,
		border      = cfg.border,
		focusable   = focusable,
		hoverable   = focusable,
		focus_flags = f_flags,
	})
}

ui_bar_chart :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Bar_Chart_Config = {},
) -> i32 {
	id_h := hash_id(id)
	default_h: i32 = 6
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(default_h)

	if s != nil {
		bar_cfg := cfg
		if len(cfg.data) > 0 {
			data_copy := make([]Bar_Data, len(cfg.data), context.temp_allocator)
			copy(data_copy, cfg.data)
			bar_cfg.data = data_copy
		}
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = {.Bold},
			fill_bg     = cfg.bg.kind != .Default,
		}
		s.chart_entries[id_h] = Chart_Render_Entry{
			kind    = .Bar_Chart,
			bar_cfg = bar_cfg,
		}
	}

	focusable := (.Focusable in cfg.focus_flags) || (.Default_Focus in cfg.focus_flags)
	f_flags := cfg.focus_flags
	if focusable {
		f_flags += {.Focusable}
	}
	return leaf(ctx, id, 20, default_h, Box_Config{
		width       = w,
		height      = h,
		padding     = cfg.padding,
		border      = cfg.border,
		focusable   = focusable,
		hoverable   = focusable,
		focus_flags = f_flags,
	})
}

@(private)
render_chart_entry :: proc(
	s: ^Screen,
	node: Layout_Node,
	paint: Paint_Spec,
	entry: Chart_Render_Entry,
	temp_alloc: mem.Allocator,
) {
	inner := node.inner_rect
	clip  := node.inner_clip
	if inner.w <= 4 || inner.h <= 3 || clip.w <= 0 || clip.h <= 0 {
		return
	}

	switch entry.kind {
	case .Cartesian:
		cfg := entry.chart_cfg
		default_axis_fg := paint.fg if paint.fg.kind != .Default else rgb(150, 165, 185)
		x_axis_fg := cfg.x_axis.fg if cfg.x_axis.fg.kind != .Default else default_axis_fg
		y_axis_fg := cfg.y_axis.fg if cfg.y_axis.fg.kind != .Default else x_axis_fg

		// 1. Calculate margins for labels and axes
		max_y_label_w: i32 = 0
		for lbl in cfg.y_axis.labels {
			max_y_label_w = max(max_y_label_w, string_display_width(lbl))
		}
		y_margin: i32 = 1 // 1 for axis line
		if max_y_label_w > 0 {
			y_margin = max_y_label_w + 1
		}

		x_margin: i32 = 1 // 1 for axis line
		if len(cfg.x_axis.labels) > 0 {
			x_margin += 1 // label row
		}
		if len(cfg.x_axis.title) > 0 {
			x_margin += 1 // title row
		}

		header_rows: i32 = 0
		if (len(cfg.y_axis.title) > 0 || (cfg.show_legend && len(cfg.datasets) > 0)) && inner.h - x_margin > 2 {
			header_rows = 1
		}

		plot_w := inner.w - y_margin
		plot_h := inner.h - x_margin - header_rows
		if plot_w <= 0 || plot_h <= 0 {
			return
		}

		plot_x := inner.x + y_margin
		plot_y := inner.y + header_rows
		cell_w := plot_w
		cell_h := plot_h
		pixel_w := cell_w * 2
		pixel_h := cell_h * 4

		// 2. Initialize temporary Braille canvas
		temp_canvas: Braille_Canvas
		if !canvas_init(&temp_canvas, cell_w, cell_h, temp_alloc) {
			return
		}

		// Optional background grid lines
		if cfg.show_grid {
			grid_fg := rgb(55, 65, 85)
			num_y_grid := i32(len(cfg.y_axis.labels))
			if num_y_grid < 3 {
				num_y_grid = 5
			}
			for gy: i32 = 1; gy < num_y_grid - 1; gy += 1 {
				py := i32(math.round((f64(gy) / f64(num_y_grid - 1)) * f64(pixel_h - 1)))
				for px: i32 = 0; px < pixel_w; px += 4 {
					canvas_set_point(&temp_canvas, px, py, grid_fg)
				}
			}
		}

		// 3a. First pass: Rasterize translucent/stippled area fills underneath lines (`Braille_Area`)
		for ds in cfg.datasets {
			if len(ds.data) == 0 || ds.marker != .Braille_Area {
				continue
			}
			ds_fg   := ds.fg if ds.fg.kind != .Default else rgb(120, 200, 255)
			fill_fg := ds.fill_fg if ds.fill_fg.kind != .Default else ds_fg
			for i in 0 ..< len(ds.data) - 1 {
				p0 := ds.data[i]
				p1 := ds.data[i + 1]
				fx0, fy0, v0 := chart_project_point_unclamped(p0, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
				fx1, fy1, v1 := chart_project_point_unclamped(p1, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
				if !v0 || !v1 {
					continue
				}
				if fx0 > fx1 {
					fx0, fx1 = fx1, fx0
					fy0, fy1 = fy1, fy0
				}
				if fx1 < 0 || fx0 > f64(pixel_w - 1) {
					continue
				}
				px_start := clamp(i32(math.round(fx0)), 0, pixel_w - 1)
				px_end   := clamp(i32(math.round(fx1)), 0, pixel_w - 1)
				dx       := fx1 - fx0
				for px := px_start; px <= px_end; px += 1 {
					fy := fy0
					if dx > 1e-9 {
						t := clamp((f64(px) - fx0) / dx, 0.0, 1.0)
						fy = fy0 + t * (fy1 - fy0)
					} else {
						fy = min(fy0, fy1)
					}
					top_py := clamp(i32(math.round(fy)), -1, pixel_h - 1)
					for py := max(i32(0), top_py + 1); py < pixel_h; py += 1 {
						// Ordered 50% Bayer checkerboard stipple (`(px + py) & 1 == 0`) so overlapping CPU core fills remain crisp & readable
						if ((px + py) & 1) == 0 {
							canvas_set_point(&temp_canvas, px, py, fill_fg)
						}
					}
				}
			}
		}

		// 3b. Second pass: Rasterize crisp dataset lines/dots/steps on top of fills
		for ds in cfg.datasets {
			if len(ds.data) == 0 {
				continue
			}
			ds_fg := ds.fg if ds.fg.kind != .Default else rgb(120, 200, 255)

			switch ds.marker {
			case .Braille_Line, .Braille_Area:
				if len(ds.data) == 1 {
					if px, py, ok := chart_project_point(ds.data[0], cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h); ok {
						canvas_set_point(&temp_canvas, px, py, ds_fg)
					}
				}
				for i in 0 ..< len(ds.data) - 1 {
					p0 := ds.data[i]
					p1 := ds.data[i + 1]
					fx0, fy0, v0 := chart_project_point_unclamped(p0, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
					fx1, fy1, v1 := chart_project_point_unclamped(p1, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
					if v0 && v1 {
						if cx0, cy0, cx1, cy1, vis := chart_clip_segment(fx0, fy0, fx1, fy1, pixel_w, pixel_h); vis {
							canvas_draw_line(&temp_canvas, cx0, cy0, cx1, cy1, ds_fg)
						}
					}
				}
			case .Braille_Dots:
				for pt in ds.data {
					px, py, ok := chart_project_point(pt, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
					if ok {
						canvas_set_point(&temp_canvas, px, py, ds_fg)
					}
				}
			case .Braille_Step:
				if len(ds.data) == 1 {
					if px, py, ok := chart_project_point(ds.data[0], cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h); ok {
						canvas_set_point(&temp_canvas, px, py, ds_fg)
					}
				}
				for i in 0 ..< len(ds.data) - 1 {
					p0 := ds.data[i]
					p1 := ds.data[i + 1]
					fx0, fy0, v0 := chart_project_point_unclamped(p0, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
					fx1, fy1, v1 := chart_project_point_unclamped(p1, cfg.x_axis.bounds, cfg.y_axis.bounds, pixel_w, pixel_h)
					if v0 && v1 {
						if cx0, cy0, cx1, cy1, vis_h := chart_clip_segment(fx0, fy0, fx1, fy0, pixel_w, pixel_h); vis_h {
							canvas_draw_line(&temp_canvas, cx0, cy0, cx1, cy1, ds_fg)
						}
						if vx0, vy0, vx1, vy1, vis_v := chart_clip_segment(fx1, fy0, fx1, fy1, pixel_w, pixel_h); vis_v {
							canvas_draw_line(&temp_canvas, vx0, vy0, vx1, vy1, ds_fg)
						}
					}
				}
			}
		}

		// 4. Render Braille canvas onto Screen buffer
		for cy: i32 = 0; cy < cell_h; cy += 1 {
			sy := plot_y + cy
			if sy < clip.y || sy >= clip.y + clip.h {
				continue
			}
			for cx: i32 = 0; cx < cell_w; cx += 1 {
				sx := plot_x + cx
				if sx < clip.x || sx >= clip.x + clip.w {
					continue
				}
				c_idx := int(cy * temp_canvas.cell_w + cx)
				if c_idx < 0 || c_idx >= len(temp_canvas.masks) {
					continue
				}
				mask := temp_canvas.masks[c_idx]
				if mask == 0 {
					continue
				}
				cell_fg := temp_canvas.fgs[c_idx] if (c_idx < len(temp_canvas.fgs) && temp_canvas.fgs[c_idx].kind != .Default) else x_axis_fg
				put_cell_clipped(s, sx, sy, Cell{
					ch    = braille_rune_from_mask(mask),
					fg    = cell_fg,
					bg    = paint.bg,
					style = paint.style,
					width = 1,
				}, clip)
			}
		}

		// 5. Draw Axes
		axis_col := inner.x + y_margin - 1
		axis_row := plot_y + plot_h

		// Y-axis line
		for sy := plot_y; sy < plot_y + plot_h; sy += 1 {
			put_cell_clipped(s, axis_col, sy, Cell{
				ch    = '│',
				fg    = y_axis_fg,
				bg    = paint.bg,
				style = cfg.y_axis.style,
				width = 1,
			}, clip)
		}

		// X-axis line
		for sx := inner.x + y_margin; sx < inner.x + inner.w; sx += 1 {
			put_cell_clipped(s, sx, axis_row, Cell{
				ch    = '─',
				fg    = x_axis_fg,
				bg    = paint.bg,
				style = cfg.x_axis.style,
				width = 1,
			}, clip)
		}

		// Origin intersection
		put_cell_clipped(s, axis_col, axis_row, Cell{
			ch    = '└',
			fg    = x_axis_fg,
			bg    = paint.bg,
			style = cfg.x_axis.style,
			width = 1,
		}, clip)

		// Y-axis labels
		num_y_labels := i32(len(cfg.y_axis.labels))
		if num_y_labels > 0 {
			for i: i32 = 0; i < num_y_labels; i += 1 {
				r := f64(i) / f64(num_y_labels - 1) if num_y_labels > 1 else 0.0
				ly := plot_y + (plot_h - 1) - i32(math.round(r * f64(plot_h - 1)))
				lbl := cfg.y_axis.labels[i]
				lbl_w := string_display_width(lbl)
				start_x := axis_col - lbl_w
				if start_x >= inner.x {
					draw_string_clipped(s, start_x, ly, clip, lbl, y_axis_fg, paint.bg, cfg.y_axis.style)
				}
				// Tick mark on Y-axis
				put_cell_clipped(s, axis_col, ly, Cell{
					ch    = '├',
					fg    = y_axis_fg,
					bg    = paint.bg,
					style = cfg.y_axis.style,
					width = 1,
				}, clip)
			}
		}

		// X-axis labels
		num_x_labels := i32(len(cfg.x_axis.labels))
		if num_x_labels > 0 {
			lx_row := axis_row + 1
			for j: i32 = 0; j < num_x_labels; j += 1 {
				r := f64(j) / f64(num_x_labels - 1) if num_x_labels > 1 else 0.0
				lx := plot_x + i32(math.round(r * f64(plot_w - 1)))
				lbl := cfg.x_axis.labels[j]
				lbl_w := string_display_width(lbl)
				start_x := lx - lbl_w / 2
				if j == 0 {
					start_x = lx
				} else if j == num_x_labels - 1 {
					start_x = lx - lbl_w + 1
				}
				draw_string_clipped(s, start_x, lx_row, clip, lbl, x_axis_fg, paint.bg, cfg.x_axis.style)
				// Tick mark on X-axis
				put_cell_clipped(s, lx, axis_row, Cell{
					ch    = '┬',
					fg    = x_axis_fg,
					bg    = paint.bg,
					style = cfg.x_axis.style,
					width = 1,
				}, clip)
			}
		}

		// Optional axis titles
		if len(cfg.y_axis.title) > 0 {
			draw_string_clipped(s, plot_x + 1, inner.y, clip, cfg.y_axis.title, y_axis_fg, paint.bg, cfg.y_axis.style)
		}
		if len(cfg.x_axis.title) > 0 {
			xt_w := string_display_width(cfg.x_axis.title)
			xt_x := plot_x + max(i32(0), (plot_w - xt_w) / 2)
			xt_row_offset: i32 = 2 if num_x_labels > 0 else 1
			xt_y := min(inner.y + inner.h - 1, axis_row + xt_row_offset)
			draw_string_clipped(s, xt_x, xt_y, clip, cfg.x_axis.title, x_axis_fg, paint.bg, cfg.x_axis.style)
		}

		// 6. Legend Box
		if cfg.show_legend && len(cfg.datasets) > 0 {
			legend_y := inner.y
			cur_lx := inner.x + inner.w - 1
			leg_min_x := plot_x
			if len(cfg.y_axis.title) > 0 {
				leg_min_x = plot_x + string_display_width(cfg.y_axis.title) + 2
			}
			leg_fg := cfg.legend_fg if cfg.legend_fg.kind != .Default else x_axis_fg
			leg_bg := cfg.legend_bg if cfg.legend_bg.kind != .Default else paint.bg
			for idx := len(cfg.datasets) - 1; idx >= 0; idx -= 1 {
				ds := cfg.datasets[idx]
				name_w := string_display_width(ds.name)
				item_w := name_w + 3 // "● " + name + " "
				start_item_x := cur_lx - item_w + 1
				if start_item_x < leg_min_x {
					break
				}
				ds_fg := ds.fg if ds.fg.kind != .Default else rgb(120, 200, 255)
				put_cell_clipped(s, start_item_x, legend_y, Cell{ch = '●', fg = ds_fg, bg = leg_bg, width = 1}, clip)
				draw_string_clipped(s, start_item_x + 2, legend_y, clip, ds.name, leg_fg, leg_bg, {.Bold})
				cur_lx = start_item_x - 2
			}
		}

	case .Bar_Chart:
		cfg := entry.bar_cfg
		bar_ch := cfg.bar_char if cfg.bar_char != 0 else '█'
		text_fg := cfg.fg if cfg.fg.kind != .Default else (paint.fg if paint.fg.kind != .Default else rgb(220, 225, 235))

		max_val := cfg.max_value
		if max_val <= 0.0 {
			for it in cfg.data {
				if it.value > max_val {
					max_val = it.value
				}
			}
		}
		if max_val <= 0.0 {
			max_val = 1.0
		}

		switch cfg.direction {
		case .Vertical:
			avail_h := inner.h - 1 // bottom row for category labels
			has_value_row := cfg.show_values && avail_h > 1
			if has_value_row {
				avail_h -= 1 // top row for value numbers
			}
			if avail_h <= 0 {
				return
			}
			bar_w := cfg.bar_width if cfg.bar_width > 0 else 3
			gap: i32 = 0 if cfg.no_gap else (cfg.gap if cfg.gap > 0 else 1)
			base_y := inner.y + inner.h - 2
			label_y := inner.y + inner.h - 1

			for it, idx in cfg.data {
				start_x := inner.x + i32(idx) * (bar_w + gap)
				if start_x + bar_w > inner.x + inner.w {
					break
				}
				r := clamp(it.value / max_val, 0.0, 1.0)
				bar_h := i32(math.round(r * f64(avail_h)))
				bar_color := it.color if it.color.kind != .Default else rgb(80, 180, 240)

				// Draw vertical bar cells
				for bh: i32 = 0; bh < bar_h; bh += 1 {
					sy := base_y - bh
					for bx: i32 = 0; bx < bar_w; bx += 1 {
						put_cell_clipped(s, start_x + bx, sy, Cell{
							ch    = bar_ch,
							fg    = bar_color,
							bg    = paint.bg,
							style = cfg.style,
							width = 1,
						}, clip)
					}
				}

				// Draw value indicator above the bar
				if has_value_row {
					val_str := fmt.tprintf("%d", int(math.round(it.value)))
					val_w := string_display_width(val_str)
					val_x := start_x + (bar_w - val_w) / 2
					val_y := max(inner.y, base_y - bar_h)
					draw_string_clipped(s, val_x, val_y, clip, val_str, text_fg, paint.bg, {.Bold})
				}

				// Draw category label on bottom row
				lbl_w := string_display_width(it.label)
				lbl_x := start_x + (bar_w - lbl_w) / 2
				draw_string_clipped(s, lbl_x, label_y, clip, it.label, text_fg, paint.bg, cfg.style)
			}

		case .Horizontal:
			max_lbl_w: i32 = 0
			for it in cfg.data {
				max_lbl_w = max(max_lbl_w, string_display_width(it.label))
			}
			label_w := min(max_lbl_w, max(i32(1), inner.w / 4))
			bar_start_x := inner.x + label_w + 1
			value_reserve: i32 = 8 if cfg.show_values else 0
			avail_bar_w := max(i32(1), inner.w - (label_w + 1) - value_reserve)
			gap: i32 = 0 if cfg.no_gap else (cfg.gap if cfg.gap >= 0 else 0)

			for it, idx in cfg.data {
				sy := inner.y + i32(idx) * (1 + gap)
				if sy >= inner.y + inner.h {
					break
				}
				bar_color := it.color if it.color.kind != .Default else rgb(80, 180, 240)

				// Draw category label on left, clipped to reserved label_w column
				lbl_clip := rect_intersect(clip, Rect{x = inner.x, y = sy, w = label_w, h = 1})
				draw_string_clipped(s, inner.x, sy, lbl_clip, it.label, text_fg, paint.bg, cfg.style)

				// Draw horizontal bar cells
				r := clamp(it.value / max_val, 0.0, 1.0)
				bar_len := i32(math.round(r * f64(avail_bar_w)))
				for bx: i32 = 0; bx < bar_len; bx += 1 {
					put_cell_clipped(s, bar_start_x + bx, sy, Cell{
						ch    = bar_ch,
						fg    = bar_color,
						bg    = paint.bg,
						style = cfg.style,
						width = 1,
					}, clip)
				}

				// Draw value indicator on the right of bar tip
				if cfg.show_values {
					val_str := fmt.tprintf(" %d", int(math.round(it.value)))
					draw_string_clipped(s, bar_start_x + bar_len, sy, clip, val_str, text_fg, paint.bg, {.Bold})
				}
			}
		}
	}
}
