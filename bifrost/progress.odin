package bifrost

import "core:fmt"
import "core:math"
import "core:mem"

// =============================================================================
// Track 16: Progress Bars, Gauges & Indeterminate Spinners (`ui_progress_bar`,
//           `ui_gauge`, `ui_spinner`)
// =============================================================================

// Unicode 1/8th sub-cell horizontal blocks
PROGRESS_BLOCKS := [8]rune{
	' ', // 0/8
	'▏', // 1/8 (U+258F)
	'▎', // 2/8 (U+258E)
	'▍', // 3/8 (U+258D)
	'▌', // 4/8 (U+258C)
	'▋', // 5/8 (U+258B)
	'▊', // 6/8 (U+258A)
	'▉', // 7/8 (U+2589)
}
PROGRESS_FULL_BLOCK: rune : '█' // U+2588

SPINNER_DOTS := [10]string{
	"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
}

SPINNER_LINE := [4]string{
	"-", "\\", "|", "/",
}

SPINNER_PULSE := [12]string{
	" ", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃",
}

SPINNER_MOON := [8]string{
	"🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘",
}

Progress_Bar_Config :: struct {
	ratio:            f64,
	label:            string,
	show_percentage:  bool,
	filled_fg:        Color,
	filled_bg:        Color,
	unfilled_fg:      Color,
	unfilled_bg:      Color,
	text_filled_fg:   Color,
	text_unfilled_fg: Color,
	filled_char:      rune,
	empty_char:       rune,
	no_sub_cell:      bool,
	width:            Axis_Size,
	height:           Axis_Size,
	padding:          Padding,
	border:           Border_Kind,
	border_fg:        Color,
	title:            string,
	title_fg:         Color,
	style:            Style_Flags,
}

Gauge_Threshold :: struct {
	above: f64,
	fg:    Color,
	bg:    Color,
}

Gauge_Config :: struct {
	ratio:            f64,
	label:            string,
	show_percentage:  bool,
	thresholds:       []Gauge_Threshold,
	filled_fg:        Color,
	filled_bg:        Color,
	unfilled_fg:      Color,
	unfilled_bg:      Color,
	text_filled_fg:   Color,
	text_unfilled_fg: Color,
	filled_char:      rune,
	empty_char:       rune,
	no_sub_cell:      bool,
	width:            Axis_Size,
	height:           Axis_Size,
	padding:          Padding,
	border:           Border_Kind,
	border_fg:        Color,
	title:            string,
	title_fg:         Color,
	style:            Style_Flags,
}

Spinner_Kind :: enum u8 {
	Dots  = 0,
	Line  = 1,
	Pulse = 2,
	Moon  = 3,
}

Spinner_Config :: struct {
	kind:          Spinner_Kind,
	custom_frames: []string,
	tick:          int,
	label:         string,
	fg:            Color,
	bg:            Color,
	label_fg:      Color,
	style:         Style_Flags,
	label_style:   Style_Flags,
	width:         Axis_Size,
	height:        Axis_Size,
	padding:       Padding,
	border:        Border_Kind,
	border_fg:     Color,
}

Progress_Render_Kind :: enum u8 {
	Bar     = 0,
	Gauge   = 1,
	Spinner = 2,
}

Progress_Render_Entry :: struct {
	kind:          Progress_Render_Kind,
	bar_cfg:       Progress_Bar_Config,
	gauge_cfg:     Gauge_Config,
	spinner_cfg:   Spinner_Config,
	formatted_lbl: string,
}

// Computes full cells and fractional 1/8th remainder for given ratio and cell width
progress_subcell_eighths :: proc "contextless" (ratio: f64, width: i32) -> (full_cells: i32, rem_eighths: i32) {
	if width <= 0 {
		return 0, 0
	}
	r := clamp(ratio, 0.0, 1.0)
	total_eighths := i32(math.round(r * f64(width * 8)))
	full_cells = clamp(total_eighths / 8, 0, width)
	if full_cells == width {
		rem_eighths = 0
	} else {
		rem_eighths = total_eighths % 8
	}
	return full_cells, rem_eighths
}

// Evaluates highest matching threshold color for a gauge ratio
gauge_eval_threshold :: proc "contextless" (ratio: f64, thresholds: []Gauge_Threshold, default_fg, default_bg: Color) -> (fg, bg: Color) {
	fg = default_fg
	bg = default_bg
	r := clamp(ratio, 0.0, 1.0)
	best_above: f64 = -1.0
	for t in thresholds {
		if r >= t.above && t.above > best_above {
			best_above = t.above
			if t.fg.kind != .Default {
				fg = t.fg
			}
			if t.bg.kind != .Default {
				bg = t.bg
			}
		}
	}
	return fg, bg
}

// Returns animation frame string for spinner kind and tick count
spinner_get_frame :: proc(kind: Spinner_Kind, custom_frames: []string, tick: int) -> string {
	frames: []string
	if len(custom_frames) > 0 {
		frames = custom_frames
	} else {
		switch kind {
		case .Dots:  frames = SPINNER_DOTS[:]
		case .Line:  frames = SPINNER_LINE[:]
		case .Pulse: frames = SPINNER_PULSE[:]
		case .Moon:  frames = SPINNER_MOON[:]
		}
	}
	if len(frames) == 0 {
		return " "
	}
	idx := (tick % len(frames) + len(frames)) % len(frames)
	return frames[idx]
}

ui_progress_bar :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Progress_Bar_Config = {},
) -> i32 {
	id_h := hash_id(id)
	default_h: i32 = 3 if cfg.border != .None else 1
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(default_h)

	lbl := cfg.label
	if len(lbl) == 0 && cfg.show_percentage {
		lbl = fmt.tprintf(" %d%% ", int(math.round(clamp(cfg.ratio, 0.0, 1.0) * 100.0)))
	}

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.filled_fg,
			bg          = cfg.unfilled_bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = {.Bold},
			fill_bg     = cfg.unfilled_bg.kind != .Default,
		}
		s.progress_entries[id_h] = Progress_Render_Entry{
			kind          = .Bar,
			bar_cfg       = cfg,
			formatted_lbl = lbl,
		}
	}

	return leaf(ctx, id, 10, default_h, Box_Config{
		width   = w,
		height  = h,
		padding = cfg.padding,
		border  = cfg.border,
	})
}

ui_gauge :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Gauge_Config = {},
) -> i32 {
	id_h := hash_id(id)
	default_h: i32 = 3 if cfg.border != .None else 1
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else fixed(default_h)

	lbl := cfg.label
	if len(lbl) == 0 && cfg.show_percentage {
		lbl = fmt.tprintf(" %d%% ", int(math.round(clamp(cfg.ratio, 0.0, 1.0) * 100.0)))
	}

	if s != nil {
		gauge_cfg := cfg
		if len(cfg.thresholds) > 0 {
			th_copy := make([]Gauge_Threshold, len(cfg.thresholds), context.temp_allocator)
			copy(th_copy, cfg.thresholds)
			gauge_cfg.thresholds = th_copy
		}
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.filled_fg,
			bg          = cfg.unfilled_bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = {.Bold},
			fill_bg     = cfg.unfilled_bg.kind != .Default,
		}
		s.progress_entries[id_h] = Progress_Render_Entry{
			kind          = .Gauge,
			gauge_cfg     = gauge_cfg,
			formatted_lbl = lbl,
		}
	}

	return leaf(ctx, id, 10, default_h, Box_Config{
		width   = w,
		height  = h,
		padding = cfg.padding,
		border  = cfg.border,
	})
}

ui_spinner :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Spinner_Config = {},
) -> i32 {
	id_h := hash_id(id)
	glyph := spinner_get_frame(cfg.kind, cfg.custom_frames, cfg.tick)
	content_w := string_display_width(glyph)
	if len(cfg.label) > 0 {
		content_w += 1 + string_display_width(cfg.label)
	}
	bdr_w: i32 = 2 if cfg.border != .None else 0
	bdr_h: i32 = 2 if cfg.border != .None else 0
	intrinsic_w := content_w + bdr_w + cfg.padding.left + cfg.padding.right
	intrinsic_h := 1 + bdr_h + cfg.padding.top + cfg.padding.bottom
	w := cfg.width if cfg.width != nil else fixed(intrinsic_w)
	h := cfg.height if cfg.height != nil else fixed(intrinsic_h)

	if s != nil {
		spinner_cfg := cfg
		if len(cfg.custom_frames) > 0 {
			cf_copy := make([]string, len(cfg.custom_frames), context.temp_allocator)
			copy(cf_copy, cfg.custom_frames)
			spinner_cfg.custom_frames = cf_copy
		}
		s.paints[id_h] = Paint_Spec{
			fg        = cfg.fg,
			bg        = cfg.bg,
			border_fg = cfg.border_fg,
			style     = cfg.style,
			fill_bg   = cfg.bg.kind != .Default,
		}
		s.progress_entries[id_h] = Progress_Render_Entry{
			kind        = .Spinner,
			spinner_cfg = spinner_cfg,
		}
	}

	return leaf(ctx, id, content_w, 1, Box_Config{
		width   = w,
		height  = h,
		padding = cfg.padding,
		border  = cfg.border,
	})
}

@(private)
render_progress_entry :: proc(
	s: ^Screen,
	node: Layout_Node,
	paint: Paint_Spec,
	entry: Progress_Render_Entry,
	temp_alloc: mem.Allocator,
) {
	inner := node.inner_rect
	clip  := node.inner_clip
	if inner.w <= 0 || inner.h <= 0 || clip.w <= 0 || clip.h <= 0 {
		return
	}

	switch entry.kind {
	case .Bar, .Gauge:
		ratio: f64
		label: string
		eff_filled_fg, eff_filled_bg: Color
		eff_unfilled_fg, eff_unfilled_bg: Color
		text_filled_fg, text_unfilled_fg: Color
		filled_ch: rune
		empty_ch: rune
		use_sub_cell: bool
		style: Style_Flags

		if entry.kind == .Bar {
			cfg := entry.bar_cfg
			ratio = cfg.ratio
			label = entry.formatted_lbl
			eff_filled_fg = cfg.filled_fg if cfg.filled_fg.kind != .Default else rgb(80, 180, 240)
			eff_filled_bg = cfg.filled_bg if cfg.filled_bg.kind != .Default else paint.bg
			eff_unfilled_fg = cfg.unfilled_fg if cfg.unfilled_fg.kind != .Default else rgb(120, 130, 145)
			eff_unfilled_bg = cfg.unfilled_bg if cfg.unfilled_bg.kind != .Default else rgb(30, 35, 45)
			text_filled_fg = cfg.text_filled_fg if cfg.text_filled_fg.kind != .Default else rgb(0, 0, 0)
			text_unfilled_fg = cfg.text_unfilled_fg if cfg.text_unfilled_fg.kind != .Default else rgb(220, 220, 220)
			filled_ch = cfg.filled_char if cfg.filled_char != 0 else PROGRESS_FULL_BLOCK
			empty_ch = cfg.empty_char if cfg.empty_char != 0 else ' '
			use_sub_cell = !cfg.no_sub_cell
			style = cfg.style
		} else {
			cfg := entry.gauge_cfg
			ratio = cfg.ratio
			label = entry.formatted_lbl
			def_filled_fg := cfg.filled_fg if cfg.filled_fg.kind != .Default else rgb(80, 220, 100)
			def_filled_bg := cfg.filled_bg if cfg.filled_bg.kind != .Default else paint.bg
			eff_filled_fg, eff_filled_bg = gauge_eval_threshold(ratio, cfg.thresholds, def_filled_fg, def_filled_bg)
			eff_unfilled_fg = cfg.unfilled_fg if cfg.unfilled_fg.kind != .Default else rgb(120, 130, 145)
			eff_unfilled_bg = cfg.unfilled_bg if cfg.unfilled_bg.kind != .Default else rgb(30, 35, 45)
			text_filled_fg = cfg.text_filled_fg if cfg.text_filled_fg.kind != .Default else rgb(0, 0, 0)
			text_unfilled_fg = cfg.text_unfilled_fg if cfg.text_unfilled_fg.kind != .Default else rgb(220, 220, 220)
			filled_ch = cfg.filled_char if cfg.filled_char != 0 else PROGRESS_FULL_BLOCK
			empty_ch = cfg.empty_char if cfg.empty_char != 0 else ' '
			use_sub_cell = !cfg.no_sub_cell
			style = cfg.style
		}

		full_cells, rem_eighths: i32
		if use_sub_cell {
			full_cells, rem_eighths = progress_subcell_eighths(ratio, inner.w)
		} else {
			full_cells = clamp(i32(math.round(clamp(ratio, 0.0, 1.0) * f64(inner.w))), 0, inner.w)
			rem_eighths = 0
		}

		Label_Cell :: struct {
			ch:    rune,
			width: u8,
		}
		label_w := string_display_width(label)
		has_label := label_w > 0 && label_w <= inner.w
		label_cells: []Label_Cell
		if has_label {
			label_cells = make([]Label_Cell, int(label_w), temp_alloc)
			col_i := 0
			idx := 0
			for idx < len(label) {
				next_idx, cluster_w, lead_r := next_grapheme_cluster(label, idx)
				idx = next_idx
				if cluster_w <= 0 {
					continue
				}
				rw := int(clamp(cluster_w, 1, 2))
				if col_i < len(label_cells) {
					label_cells[col_i] = Label_Cell{ch = lead_r, width = u8(rw)}
				}
				if rw == 2 && col_i + 1 < len(label_cells) {
					label_cells[col_i + 1] = Label_Cell{ch = 0, width = 0}
				}
				col_i += rw
			}
		}
		label_start := (inner.w - label_w) / 2 if has_label else 0
		label_end := label_start + label_w if has_label else 0
		center_y := inner.y + inner.h / 2

		for row_y: i32 = 0; row_y < inner.h; row_y += 1 {
			sy := inner.y + row_y
			if sy < clip.y || sy >= clip.y + clip.h {
				continue
			}
			row_has_label := has_label && (inner.h == 1 || sy == center_y)

			for col_x: i32 = 0; col_x < inner.w; col_x += 1 {
				sx := inner.x + col_x
				if sx < clip.x || sx >= clip.x + clip.w {
					continue
				}

				if row_has_label && col_x >= label_start && col_x < label_end {
					lc := label_cells[col_x - label_start]
					if lc.width == 0 {
						continue
					}
					lbl_fg: Color
					lbl_bg: Color
					if col_x < full_cells {
						lbl_fg = text_filled_fg
						lbl_bg = eff_filled_fg
					} else if col_x == full_cells && rem_eighths >= 4 {
						lbl_fg = text_filled_fg
						lbl_bg = eff_filled_fg
					} else {
						lbl_fg = text_unfilled_fg
						lbl_bg = eff_unfilled_bg
					}
					put_cell_clipped(s, sx, sy, Cell{
						ch    = lc.ch,
						fg    = lbl_fg,
						bg    = lbl_bg,
						style = style,
						width = lc.width,
					}, clip)
				} else {
					cell_ch: rune
					cell_fg: Color
					cell_bg: Color
					if col_x < full_cells {
						cell_ch = filled_ch
						cell_fg = eff_filled_fg
						cell_bg = eff_filled_bg
					} else if col_x == full_cells && rem_eighths > 0 {
						cell_ch = PROGRESS_BLOCKS[rem_eighths]
						cell_fg = eff_filled_fg
						cell_bg = eff_unfilled_bg
					} else {
						cell_ch = empty_ch
						cell_fg = eff_unfilled_fg
						cell_bg = eff_unfilled_bg
					}
					put_cell_clipped(s, sx, sy, Cell{
						ch    = cell_ch,
						fg    = cell_fg,
						bg    = cell_bg,
						style = style,
						width = 1,
					}, clip)
				}
			}
		}

	case .Spinner:
		cfg := entry.spinner_cfg
		glyph := spinner_get_frame(cfg.kind, cfg.custom_frames, cfg.tick)
		eff_fg := cfg.fg if cfg.fg.kind != .Default else rgb(80, 200, 255)
		eff_bg := cfg.bg if cfg.bg.kind != .Default else paint.bg
		eff_lbl_fg := cfg.label_fg if cfg.label_fg.kind != .Default else (paint.fg if paint.fg.kind != .Default else rgb(220, 220, 220))

		gw := string_display_width(glyph)
		draw_string_clipped(s, inner.x, inner.y, clip, glyph, eff_fg, eff_bg, cfg.style)
		if len(cfg.label) > 0 {
			draw_string_clipped(s, inner.x + gw + 1, inner.y, clip, cfg.label, eff_lbl_fg, eff_bg, cfg.label_style)
		}
	}
}
