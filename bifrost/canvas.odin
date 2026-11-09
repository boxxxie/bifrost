package bifrost

import "core:mem"

// =============================================================================
// Track 14: Unicode Braille Sub-Cell Canvas (`ui_canvas`) &
//           Vertical Block Sparkline (`ui_sparkline`)
// =============================================================================

BRAILLE_BASE_RUNE :: rune(0x2800)

// ISO/TR 11548-1 2x4 Braille dot bitmask lookup table indexed by [sub_x][sub_y]:
//   Left column  (sub_x == 0): rows 0..3 -> bits 0x01, 0x02, 0x04, 0x40
//   Right column (sub_x == 1): rows 0..3 -> bits 0x08, 0x10, 0x20, 0x80
@(rodata)
BRAILLE_DOT_BITS := [2][4]u8{
	0 = {0x01, 0x02, 0x04, 0x40},
	1 = {0x08, 0x10, 0x20, 0x80},
}

// 8-level Unicode vertical block glyphs (`U+2581..U+2588`)
@(rodata)
SPARKLINE_BLOCKS := [8]rune{
	'▁', // U+2581 Lower one eighth block
	'▂', // U+2582 Lower one quarter block
	'▃', // U+2583 Lower three eighths block
	'▄', // U+2584 Lower half block
	'▅', // U+2585 Lower five eighths block
	'▆', // U+2586 Lower three quarters block
	'▇', // U+2587 Lower seven eighths block
	'█', // U+2588 Full block
}

Braille_Canvas :: struct {
	cell_w:  i32,
	cell_h:  i32,
	pixel_w: i32,
	pixel_h: i32,
	masks:   []u8,
	fgs:     []Color,
}

Draw_Canvas_Proc :: #type proc(canvas: ^Braille_Canvas, userdata: rawptr)

Canvas_Config :: struct {
	title:       string,
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	border:      Border_Kind,
	fg:          Color,
	bg:          Color,
	border_fg:   Color,
	title_fg:    Color,
	style:       Style_Flags,
	title_style: Style_Flags,
	fill_bg:     bool,
	focus_flags: Focus_Flags,
	canvas:      ^Braille_Canvas,
	draw_fn:     Draw_Canvas_Proc,
	userdata:    rawptr,
}

Sparkline_Config :: struct {
	title:       string,
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	border:      Border_Kind,
	fg:          Color,
	bg:          Color,
	border_fg:   Color,
	title_fg:    Color,
	style:       Style_Flags,
	title_style: Style_Flags,
	fill_bg:     bool,
	focus_flags: Focus_Flags,
	min_val:     f32,
	max_val:     f32,
}

Canvas_Render_Kind :: enum u8 {
	Braille_Canvas = 0,
	Sparkline_F32  = 1,
}

Canvas_Render_Entry :: struct {
	kind:        Canvas_Render_Kind,
	canvas_cfg:  Canvas_Config,
	spark_cfg:   Sparkline_Config,
	samples_f32: []f32,
}

// =============================================================================
// Unicode Braille Bitmask & Sub-Cell Drawing Primitives
// =============================================================================

// Returns the ISO/TR 11548-1 Braille dot bit for sub-cell offset `(sub_x, sub_y)` in `[0..1] x [0..3]`.
braille_dot_bit :: #force_inline proc "contextless" (sub_x, sub_y: i32) -> u8 {
	if sub_x < 0 || sub_x >= 2 || sub_y < 0 || sub_y >= 4 {
		return 0
	}
	return BRAILLE_DOT_BITS[sub_x][sub_y]
}

// Converts an 8-bit ISO/TR 11548-1 Braille dot mask into a Unicode Braille pattern rune (`U+2800..U+28FF`).
braille_rune_from_mask :: #force_inline proc "contextless" (mask: u8) -> rune {
	return rune(u32(BRAILLE_BASE_RUNE) + u32(mask))
}

// Initializes a `Braille_Canvas` over `cell_w x cell_h` terminal cells (`2*cell_w x 4*cell_h` virtual pixels).
canvas_init :: proc(
	c: ^Braille_Canvas,
	cell_w, cell_h: i32,
	alloc := context.temp_allocator,
) -> bool {
	if c == nil {
		return false
	}
	cw := max(i32(0), cell_w)
	ch := max(i32(0), cell_h)
	total := int(cw * ch)
	c.cell_w  = cw
	c.cell_h  = ch
	c.pixel_w = cw * 2
	c.pixel_h = ch * 4
	if total == 0 {
		c.masks = nil
		c.fgs   = nil
		return true
	}
	masks, m_err := make([]u8, total, alloc)
	if m_err != nil {
		c^ = {}
		return false
	}
	fgs, f_err := make([]Color, total, alloc)
	if f_err != nil {
		delete(masks, alloc)
		c^ = {}
		return false
	}
	c.masks = masks
	c.fgs   = fgs
	return true
}

// Clears all Braille dots and per-cell foreground colors in `c`.
canvas_clear :: proc "contextless" (c: ^Braille_Canvas) {
	if c == nil {
		return
	}
	for i in 0 ..< len(c.masks) {
		c.masks[i] = 0
	}
	for i in 0 ..< len(c.fgs) {
		c.fgs[i] = {}
	}
}

// Sets the sub-cell Braille dot at virtual pixel `(px, py)` and optionally updates the cell's foreground color.
canvas_set_point :: proc "contextless" (c: ^Braille_Canvas, px, py: i32, fg: Color = {}) {
	if c == nil || px < 0 || py < 0 || px >= c.pixel_w || py >= c.pixel_h {
		return
	}
	cx := px >> 1
	cy := py >> 2
	sub_x := px & 1
	sub_y := py & 3
	idx := int(cy * c.cell_w + cx)
	if idx < 0 || idx >= len(c.masks) {
		return
	}
	c.masks[idx] |= BRAILLE_DOT_BITS[sub_x][sub_y]
	if fg.kind != .Default && idx < len(c.fgs) {
		c.fgs[idx] = fg
	}
}

// Clears the sub-cell Braille dot at virtual pixel `(px, py)`.
canvas_unset_point :: proc "contextless" (c: ^Braille_Canvas, px, py: i32) {
	if c == nil || px < 0 || py < 0 || px >= c.pixel_w || py >= c.pixel_h {
		return
	}
	cx := px >> 1
	cy := py >> 2
	sub_x := px & 1
	sub_y := py & 3
	idx := int(cy * c.cell_w + cx)
	if idx < 0 || idx >= len(c.masks) {
		return
	}
	c.masks[idx] &= ~BRAILLE_DOT_BITS[sub_x][sub_y]
}

// Queries whether the sub-cell Braille dot at virtual pixel `(px, py)` is set.
canvas_get_point :: proc "contextless" (c: ^Braille_Canvas, px, py: i32) -> bool {
	if c == nil || px < 0 || py < 0 || px >= c.pixel_w || py >= c.pixel_h {
		return false
	}
	cx := px >> 1
	cy := py >> 2
	sub_x := px & 1
	sub_y := py & 3
	idx := int(cy * c.cell_w + cx)
	if idx < 0 || idx >= len(c.masks) {
		return false
	}
	return (c.masks[idx] & BRAILLE_DOT_BITS[sub_x][sub_y]) != 0
}

// Rasterizes a line segment from `(x0, y0)` to `(x1, y1)` in sub-cell pixel coordinates using integer Bresenham.
canvas_draw_line :: proc "contextless" (
	c: ^Braille_Canvas,
	x0, y0, x1, y1: i32,
	fg: Color = {},
) {
	if c == nil || c.pixel_w <= 0 || c.pixel_h <= 0 {
		return
	}
	// Guard against extreme / overflowed coordinates (e.g. `min(i32)` from NaN/Inf conversion)
	// so `abs(x1 - x0)` and `abs(y1 - y0)` never overflow `i32` or loop billions of times.
	max_coord := max(i32(32768), max(c.pixel_w, c.pixel_h) * 4)
	cx0 := clamp(x0, -max_coord, max_coord)
	cy0 := clamp(y0, -max_coord, max_coord)
	cx1 := clamp(x1, -max_coord, max_coord)
	cy1 := clamp(y1, -max_coord, max_coord)

	cur_x := cx0
	cur_y := cy0
	dx := abs(cx1 - cx0)
	sx := i32(1) if cx0 < cx1 else i32(-1)
	dy := -abs(cy1 - cy0)
	sy := i32(1) if cy0 < cy1 else i32(-1)
	err := dx + dy

	for {
		canvas_set_point(c, cur_x, cur_y, fg)
		if cur_x == cx1 && cur_y == cy1 {
			break
		}
		e2 := err * 2
		if e2 >= dy {
			if cur_x == cx1 {
				break
			}
			err += dy
			cur_x += sx
		}
		if e2 <= dx {
			if cur_y == cy1 {
				break
			}
			err += dx
			cur_y += sy
		}
	}
}

// Draws a rectangle outline at `(x, y)` of size `(w, h)` in sub-cell virtual pixel coordinates.
canvas_draw_rect :: proc "contextless" (
	c: ^Braille_Canvas,
	x, y, w, h: i32,
	fg: Color = {},
) {
	if c == nil || w <= 0 || h <= 0 {
		return
	}
	x1 := x + w - 1
	y1 := y + h - 1
	canvas_draw_line(c, x,  y,  x1, y,  fg)
	canvas_draw_line(c, x1, y,  x1, y1, fg)
	canvas_draw_line(c, x1, y1, x,  y1, fg)
	canvas_draw_line(c, x,  y1, x,  y,  fg)
}

@(private)
is_finite_f32 :: #force_inline proc "contextless" (v: f32) -> bool {
	return v == v && (v - v) == 0
}

@(private)
is_finite_f64 :: #force_inline proc "contextless" (v: f64) -> bool {
	return v == v && (v - v) == 0
}

// Plots a connected polyline time-series across `[0, c.pixel_w)` and `[0, c.pixel_h)` from `[]f32` samples.
// When `min_val == max_val`, automatically scales to `[min(samples), max(samples)]`.
canvas_draw_series_f32 :: proc "contextless" (
	c: ^Braille_Canvas,
	samples: []f32,
	min_val: f32 = 0,
	max_val: f32 = 0,
	fg: Color = {},
) {
	if c == nil || len(samples) == 0 || c.pixel_w <= 0 || c.pixel_h <= 0 {
		return
	}
	lo := min_val if is_finite_f32(min_val) else 0
	hi := max_val if is_finite_f32(max_val) else 0
	if lo == hi {
		has_finite := false
		for v in samples {
			if !is_finite_f32(v) {
				continue
			}
			if !has_finite {
				lo = v
				hi = v
				has_finite = true
			} else {
				if v < lo {
					lo = v
				}
				if v > hi {
					hi = v
				}
			}
		}
	}
	span := hi - lo
	if !is_finite_f32(span) || span < 0 {
		span = 0
	}
	last_py_max := f32(max(i32(0), c.pixel_h - 1))

	sample_to_py :: #force_inline proc "contextless" (val, lo, span, last_py_max: f32) -> i32 {
		norm: f32 = 0.5
		if is_finite_f32(val) && span > 0 {
			ratio := (val - lo) / span
			if is_finite_f32(ratio) {
				norm = clamp(ratio, 0.0, 1.0)
			} else if val > lo {
				norm = 1.0
			} else {
				norm = 0.0
			}
		}
		return clamp(i32((1.0 - norm) * last_py_max + 0.5), 0, i32(last_py_max))
	}

	n := len(samples)
	if n == 1 || c.pixel_w == 1 {
		py := sample_to_py(samples[n - 1], lo, span, last_py_max)
		canvas_draw_line(c, 0, py, c.pixel_w - 1, py, fg)
		return
	}

	prev_px: i32 = 0
	prev_py := sample_to_py(samples[0], lo, span, last_py_max)
	canvas_set_point(c, prev_px, prev_py, fg)

	max_px := f32(c.pixel_w - 1)
	denom := f32(n - 1)
	for i := 1; i < n; i += 1 {
		px := i32((f32(i) * max_px) / denom + 0.5)
		py := sample_to_py(samples[i], lo, span, last_py_max)
		canvas_draw_line(c, prev_px, prev_py, px, py, fg)
		prev_px = px
		prev_py = py
	}
}

// Plots a connected polyline time-series across `[0, c.pixel_w)` and `[0, c.pixel_h)` from `[]f64` samples.
canvas_draw_series_f64 :: proc "contextless" (
	c: ^Braille_Canvas,
	samples: []f64,
	min_val: f64 = 0,
	max_val: f64 = 0,
	fg: Color = {},
) {
	if c == nil || len(samples) == 0 || c.pixel_w <= 0 || c.pixel_h <= 0 {
		return
	}
	lo := min_val if is_finite_f64(min_val) else 0
	hi := max_val if is_finite_f64(max_val) else 0
	if lo == hi {
		has_finite := false
		for v in samples {
			if !is_finite_f64(v) {
				continue
			}
			if !has_finite {
				lo = v
				hi = v
				has_finite = true
			} else {
				if v < lo {
					lo = v
				}
				if v > hi {
					hi = v
				}
			}
		}
	}
	span := hi - lo
	if !is_finite_f64(span) || span < 0 {
		span = 0
	}
	last_py_max := f64(max(i32(0), c.pixel_h - 1))

	sample_to_py_f64 :: #force_inline proc "contextless" (val, lo, span, last_py_max: f64) -> i32 {
		norm: f64 = 0.5
		if is_finite_f64(val) && span > 0 {
			ratio := (val - lo) / span
			if is_finite_f64(ratio) {
				norm = clamp(ratio, 0.0, 1.0)
			} else if val > lo {
				norm = 1.0
			} else {
				norm = 0.0
			}
		}
		return clamp(i32((1.0 - norm) * last_py_max + 0.5), 0, i32(last_py_max))
	}

	n := len(samples)
	if n == 1 || c.pixel_w == 1 {
		py := sample_to_py_f64(samples[n - 1], lo, span, last_py_max)
		canvas_draw_line(c, 0, py, c.pixel_w - 1, py, fg)
		return
	}

	prev_px: i32 = 0
	prev_py := sample_to_py_f64(samples[0], lo, span, last_py_max)
	canvas_set_point(c, prev_px, prev_py, fg)

	max_px := f64(c.pixel_w - 1)
	denom := f64(n - 1)
	for i := 1; i < n; i += 1 {
		px := i32((f64(i) * max_px) / denom + 0.5)
		py := sample_to_py_f64(samples[i], lo, span, last_py_max)
		canvas_draw_line(c, prev_px, prev_py, px, py, fg)
		prev_px = px
		prev_py = py
	}
}

canvas_draw_series :: proc {
	canvas_draw_series_f32,
	canvas_draw_series_f64,
}

// =============================================================================
// Sparkline Quantization Helpers (`▁▂▃▄▅▆▇█`)
// =============================================================================

// Maps a normalized value in `[0.0, 1.0]` to one of the 8 vertical block glyphs (`▁..█`).
sparkline_level_rune :: #force_inline proc "contextless" (norm: f32) -> rune {
	clamped := clamp(norm, 0.0, 1.0)
	idx := clamp(int(clamped * 7.0 + 0.5), 0, 7)
	return SPARKLINE_BLOCKS[idx]
}

// =============================================================================
// Declarative Immediate-Mode Widgets (`ui_canvas`, `ui_sparkline`)
// =============================================================================

ui_canvas :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Canvas_Config = {},
) -> i32 {
	id_h := hash_id(id)
	intrinsic_w: i32 = 10
	intrinsic_h: i32 = 4
	if cfg.canvas != nil && cfg.canvas.cell_w > 0 && cfg.canvas.cell_h > 0 {
		intrinsic_w = cfg.canvas.cell_w
		intrinsic_h = cfg.canvas.cell_h
	}
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(intrinsic_h)

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = cfg.title_style if cfg.title_style != {} else {.Bold},
			fill_bg     = cfg.fill_bg || cfg.bg.kind != .Default,
		}
		s.canvas_entries[id_h] = Canvas_Render_Entry{
			kind       = .Braille_Canvas,
			canvas_cfg = cfg,
		}
	}

	focusable := (.Focusable in cfg.focus_flags) && (.Disabled not_in cfg.focus_flags)
	return leaf(ctx, id, intrinsic_w, intrinsic_h, Box_Config{
		width       = w,
		height      = h,
		padding     = cfg.padding,
		border      = cfg.border,
		focus_flags = cfg.focus_flags,
		focusable   = focusable,
		hoverable   = focusable,
	})
}

ui_sparkline_f32 :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	samples: []f32,
	cfg: Sparkline_Config = {},
) -> i32 {
	id_h := hash_id(id)
	intrinsic_w := max(i32(1), i32(len(samples)))
	intrinsic_h: i32 = 1
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(1)

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = cfg.title_style if cfg.title_style != {} else {.Bold},
			fill_bg     = cfg.fill_bg || cfg.bg.kind != .Default,
		}
		cloned := make([]f32, len(samples), context.temp_allocator)
		copy(cloned, samples)
		s.canvas_entries[id_h] = Canvas_Render_Entry{
			kind        = .Sparkline_F32,
			spark_cfg   = cfg,
			samples_f32 = cloned,
		}
	}

	focusable := (.Focusable in cfg.focus_flags) && (.Disabled not_in cfg.focus_flags)
	return leaf(ctx, id, intrinsic_w, intrinsic_h, Box_Config{
		width       = w,
		height      = h,
		padding     = cfg.padding,
		border      = cfg.border,
		focus_flags = cfg.focus_flags,
		focusable   = focusable,
		hoverable   = focusable,
	})
}

ui_sparkline_int :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	samples: []int,
	cfg: Sparkline_Config = {},
) -> i32 {
	id_h := hash_id(id)
	intrinsic_w := max(i32(1), i32(len(samples)))
	intrinsic_h: i32 = 1
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(1)

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = cfg.title_style if cfg.title_style != {} else {.Bold},
			fill_bg     = cfg.fill_bg || cfg.bg.kind != .Default,
		}
		cloned := make([]f32, len(samples), context.temp_allocator)
		for v, i in samples {
			cloned[i] = f32(v)
		}
		s.canvas_entries[id_h] = Canvas_Render_Entry{
			kind        = .Sparkline_F32,
			spark_cfg   = cfg,
			samples_f32 = cloned,
		}
	}

	focusable := (.Focusable in cfg.focus_flags) && (.Disabled not_in cfg.focus_flags)
	return leaf(ctx, id, intrinsic_w, intrinsic_h, Box_Config{
		width       = w,
		height      = h,
		padding     = cfg.padding,
		border      = cfg.border,
		focus_flags = cfg.focus_flags,
		focusable   = focusable,
		hoverable   = focusable,
	})
}

ui_sparkline :: proc {
	ui_sparkline_f32,
	ui_sparkline_int,
}

// =============================================================================
// Layout-Integrated Canvas & Sparkline Cell Rasterizer
// =============================================================================

@(private)
render_canvas_entry :: proc(
	s: ^Screen,
	node: Layout_Node,
	paint: Paint_Spec,
	entry: Canvas_Render_Entry,
	temp_alloc: mem.Allocator,
) {
	inner := node.inner_rect
	clip  := node.inner_clip
	if inner.w <= 0 || inner.h <= 0 || clip.w <= 0 || clip.h <= 0 {
		return
	}

	switch entry.kind {
	case .Braille_Canvas:
		cfg := entry.canvas_cfg
		temp_canvas: Braille_Canvas
		active_canvas := cfg.canvas
		if active_canvas == nil {
			if !canvas_init(&temp_canvas, inner.w, inner.h, temp_alloc) {
				return
			}
			active_canvas = &temp_canvas
		}
		if cfg.draw_fn != nil {
			cfg.draw_fn(active_canvas, cfg.userdata)
		}

		rows := min(inner.h, active_canvas.cell_h)
		cols := min(inner.w, active_canvas.cell_w)
		for cy: i32 = 0; cy < rows; cy += 1 {
			sy := inner.y + cy
			if sy < clip.y || sy >= clip.y + clip.h {
				continue
			}
			for cx: i32 = 0; cx < cols; cx += 1 {
				sx := inner.x + cx
				if sx < clip.x || sx >= clip.x + clip.w {
					continue
				}
				c_idx := int(cy * active_canvas.cell_w + cx)
				if c_idx < 0 || c_idx >= len(active_canvas.masks) {
					continue
				}
				mask := active_canvas.masks[c_idx]
				if mask == 0 {
					continue
				}
				cell_fg := active_canvas.fgs[c_idx] if (c_idx < len(active_canvas.fgs) && active_canvas.fgs[c_idx].kind != .Default) else paint.fg
				eff_bg := paint.bg
				if eff_bg.kind == .Default && sx >= 0 && sx < s.width && sy >= 0 && sy < s.height {
					eff_bg = s.back[int(sy * s.width + sx)].bg
				}
				put_cell_clipped(s, sx, sy, Cell{
					ch    = braille_rune_from_mask(mask),
					fg    = cell_fg,
					bg    = eff_bg,
					style = paint.style,
					width = 1,
				}, clip)
			}
		}

	case .Sparkline_F32:
		render_sparkline_f32(s, inner, clip, paint, entry.spark_cfg, entry.samples_f32)
	}
}

@(private)
render_sparkline_f32 :: proc(
	s: ^Screen,
	inner: Rect,
	clip: Rect,
	paint: Paint_Spec,
	cfg: Sparkline_Config,
	samples: []f32,
) {
	if len(samples) == 0 || inner.w <= 0 || inner.h <= 0 {
		return
	}

	// If more samples than columns exist, display the latest `inner.w` trailing samples
	visible := samples
	if i32(len(visible)) > inner.w {
		visible = visible[len(visible) - int(inner.w):]
	}

	lo := cfg.min_val if is_finite_f32(cfg.min_val) else 0
	hi := cfg.max_val if is_finite_f32(cfg.max_val) else 0
	if lo == hi {
		has_finite := false
		for v in visible {
			if !is_finite_f32(v) {
				continue
			}
			if !has_finite {
				lo = v
				hi = v
				has_finite = true
			} else {
				if v < lo {
					lo = v
				}
				if v > hi {
					hi = v
				}
			}
		}
	}
	span := hi - lo
	if !is_finite_f32(span) || span < 0 {
		span = 0
	}

	cols := min(inner.w, i32(len(visible)))
	total_sub_levels := f32(inner.h * 8)

	for col: i32 = 0; col < cols; col += 1 {
		sx := inner.x + col
		if sx < clip.x || sx >= clip.x + clip.w {
			continue
		}
		val := visible[int(col)]
		norm: f32 = 0.5
		if is_finite_f32(val) {
			if span > 0 {
				ratio := (val - lo) / span
				if is_finite_f32(ratio) {
					norm = clamp(ratio, 0.0, 1.0)
				} else if val > lo {
					norm = 1.0
				} else {
					norm = 0.0
				}
			} else if val > lo {
				norm = 1.0
			} else if val < lo {
				norm = 0.0
			}
		}

		if inner.h == 1 {
			sy := inner.y
			eff_bg := paint.bg
			if eff_bg.kind == .Default && sx >= 0 && sx < s.width && sy >= 0 && sy < s.height {
				eff_bg = s.back[int(sy * s.width + sx)].bg
			}
			put_cell_clipped(s, sx, sy, Cell{
				ch    = sparkline_level_rune(norm),
				fg    = paint.fg,
				bg    = eff_bg,
				style = paint.style,
				width = 1,
			}, clip)
		} else {
			// Multi-row vertical block bar: 1..8*h eighths from bottom row upward
			scaled := clamp(int(norm * (total_sub_levels - 1.0) + 0.5) + 1, 1, int(inner.h * 8))
			for row_from_bottom: i32 = 0; row_from_bottom < inner.h; row_from_bottom += 1 {
				sy := inner.y + (inner.h - 1 - row_from_bottom)
				row_base := int(row_from_bottom * 8)
				rem := scaled - row_base
				if rem <= 0 {
					continue
				}
				ch := '█' if rem >= 8 else SPARKLINE_BLOCKS[clamp(rem - 1, 0, 7)]
				eff_bg := paint.bg
				if eff_bg.kind == .Default && sx >= 0 && sx < s.width && sy >= 0 && sy < s.height {
					eff_bg = s.back[int(sy * s.width + sx)].bg
				}
				put_cell_clipped(s, sx, sy, Cell{
					ch    = ch,
					fg    = paint.fg,
					bg    = eff_bg,
					style = paint.style,
					width = 1,
				}, clip)
			}
		}
	}
}
