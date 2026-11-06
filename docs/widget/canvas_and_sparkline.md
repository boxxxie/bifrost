# Unicode Braille Canvas (`ui_canvas`) & Sparklines (`ui_sparkline`)

**Source File:** [`bifrost/canvas.odin`](../../bifrost/canvas.odin)

Bifrost includes two high-density terminal data-visualization widgets:
1. **`ui_canvas` (`Braille_Canvas`):** Maps each terminal cell `(cx, cy)` to a **$2 \times 4$ sub-cell dot matrix** using ISO/TR 11548-1 Unicode Braille patterns (`U+2800..U+28FF`), providing $(2 \cdot W) \times (4 \cdot H)$ virtual pixel resolution with per-cell RGB foreground tinting.
2. **`ui_sparkline`:** Quantizes `[]f32` or `[]int` time-series arrays into the 8 Unicode vertical block elements (`▁▂▃▄▅▆▇█`, `U+2581..U+2588`) across single-row ($8$ levels) or multi-row ($8 \cdot H$ sub-levels) viewports.

---

## 1. Unicode Braille Sub-Cell Canvas (`ui_canvas`, `Braille_Canvas`)

### ISO/TR 11548-1 $2 \times 4$ Sub-Cell Bitmask Mapping
Each terminal character cell covers $2$ horizontal sub-pixels (`sub_x` $\in \{0, 1\}$) by $4$ vertical sub-pixels (`sub_y` $\in \{0, 1, 2, 3\}$). The Unicode Braille rune is computed as `rune(0x2800 + u32(mask))`:

| Sub-Row (`sub_y`) | Left Column (`sub_x == 0`) | Right Column (`sub_x == 1`) |
| :---: | :---: | :---: |
| `0` (top) | Dot 1 (`0x01`) | Dot 4 (`0x08`) |
| `1` | Dot 2 (`0x02`) | Dot 5 (`0x10`) |
| `2` | Dot 3 (`0x04`) | Dot 6 (`0x20`) |
| `3` (bottom) | Dot 7 (`0x40`) | Dot 8 (`0x80`) |

### Configuration (`Canvas_Config`)
```odin
Braille_Canvas :: struct {
	cell_w:  i32,
	cell_h:  i32,
	pixel_w: i32,     // 2 * cell_w
	pixel_h: i32,     // 4 * cell_h
	masks:   []u8,    // Bitmask per cell (length = cell_w * cell_h)
	fgs:     []Color, // Per-cell foreground color override
}

Draw_Canvas_Proc :: #type proc(canvas: ^Braille_Canvas, userdata: rawptr)

Canvas_Config :: struct {
	title:       string,
	width:       Axis_Size,   // Defaults to grow(1)
	height:      Axis_Size,   // Defaults to fixed(4) (or canvas.cell_h)
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
	canvas:      ^Braille_Canvas,  // Optional pre-allocated Braille_Canvas
	draw_fn:     Draw_Canvas_Proc, // Invoked during render_layout with solved inner_rect dimensions
	userdata:    rawptr,
}
```

### Braille Drawing Primitives
* `canvas_init(c: ^Braille_Canvas, cell_w, cell_h: i32, alloc := context.temp_allocator) -> bool`
* `canvas_clear(c: ^Braille_Canvas)`
* `canvas_set_point(c: ^Braille_Canvas, px, py: i32, fg: Color = {})`
* `canvas_unset_point(c: ^Braille_Canvas, px, py: i32)`
* `canvas_get_point(c: ^Braille_Canvas, px, py: i32) -> bool`
* `canvas_draw_line(c: ^Braille_Canvas, x0, y0, x1, y1: i32, fg: Color = {})` — Integer Bresenham line rasterizer with coordinate clamping to prevent `i32` overflow on extreme inputs.
* `canvas_draw_rect(c: ^Braille_Canvas, x, y, w, h: i32, fg: Color = {})` — Sub-cell rectangle outline.
* `canvas_draw_series(c: ^Braille_Canvas, samples: []f32_or_f64, min_val := 0, max_val := 0, fg: Color = {})` — Plots a connected time-series polyline across `[0, c.pixel_w)` and `[0, c.pixel_h)`. Auto-scales to `[min(samples), max(samples)]` when `min_val == max_val` and safely ignores `NaN` / `±Inf` values.
* `braille_dot_bit(sub_x, sub_y: i32) -> u8` & `braille_rune_from_mask(mask: u8) -> rune`

---

## 2. Vertical Block Sparklines (`ui_sparkline`)

`ui_sparkline` accepts `[]f32` or `[]int` samples and renders them as vertical bar glyphs (`▁▂▃▄▅▆▇█`):
* **Single-Row Sparkline (`inner.h == 1`):** Quantizes each sample into $8$ levels via `sparkline_level_rune(norm)`.
* **Multi-Row Sparkline (`inner.h > 1`):** Quantizes each sample across $8 \times \text{inner.h}$ vertical sub-levels, filling full blocks (`█`) from the bottom row upward and capping the top partial cell with `▁..▇`.
* **Trailing Window Slicing:** When `len(samples) > inner.w`, `ui_sparkline` automatically displays the latest `inner.w` trailing samples (`samples[len(samples) - int(inner.w):]`).
* **Auto-Scaling:** When `cfg.min_val == cfg.max_val`, automatically scales to the `[min, max]` of the visible finite samples.

```odin
Sparkline_Config :: struct {
	title:       string,
	width:       Axis_Size,   // Defaults to grow(1)
	height:      Axis_Size,   // Defaults to fixed(1) (use fixed(3) when border != .None)
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
```

---

## 3. Complete Telemetry Dashboard Example

```odin
package demo

import "../../bifrost"

Telemetry_State :: struct {
	fps_series:     [48]f32,
	latency_series: [48]f32,
	msg_rates:      [32]int,
}

render_telemetry_pane :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	tel: ^Telemetry_State,
) {
	// 1. Dual-Series Sub-Cell 2x4 Braille Plot
	bifrost.ui_canvas(ctx, scr, "braille_plot", {
		title       = "Throughput (Green) vs. P99 Latency (Gold)",
		width       = bifrost.grow(1),
		height      = bifrost.fixed(10),
		border      = .Rounded,
		fill_bg     = true,
		bg          = bifrost.rgb(22, 26, 34),
		focus_flags = {.Focusable},
		userdata    = tel,
		draw_fn     = proc(c: ^bifrost.Braille_Canvas, raw: rawptr) {
			t := (^Telemetry_State)(raw)
			bifrost.canvas_draw_rect(c, 0, 0, c.pixel_w, c.pixel_h, bifrost.rgb(70, 85, 110))
			bifrost.canvas_draw_series(c, t.fps_series[:],     0.0, 100.0, bifrost.rgb(158, 206, 106))
			bifrost.canvas_draw_series(c, t.latency_series[:], 0.0, 100.0, bifrost.rgb(235, 203, 139))
		},
	})

	// 2. 8-Level Vertical Block Sparkline
	bifrost.ui_sparkline(ctx, scr, "msg_sparkline", tel.msg_rates[:], {
		title   = "Actor Mailbox Msgs/sec (▁..█)",
		width   = bifrost.grow(1),
		height  = bifrost.fixed(3),
		border  = .Plain,
		fg      = bifrost.rgb(136, 192, 208),
		min_val = 0,
		max_val = 100,
	})
}
```