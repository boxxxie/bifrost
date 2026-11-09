### Yes—You Have Enough to Build the Grid UI Right Now

For **cell geometry, layout, virtual scrolling, and GPU batching**, you do **not** need more research. The core mathematical and graphics constraints are identical whether you render in a browser or natively in Odin:

1. **Viewport Virtualization & Precision:** Decoupling scroll state into `{row_index: int, offset_within_row: f32}` so `f32` vertex coordinates never exceed the $2^{24}$ ($16,777,216\text{ px}$) precision cliff.


2. **Spatial Indexing:** Using $O(1)$ math for uniform telemetry/CSV rows, a small prefix-sum slice with binary search for columns, and sparse overrides for expanded rows.


3. **GPU Draw-Call Batching:** Splitting cell submissions into per-column draw channels so you only issue **1 hardware scissor call per visible column**, plus **1 batched draw call** for all horizontal and vertical grid lines.



The **only** areas where you would ever need additional research later are **outside** the cell-dimension UI layer:

* **Zero-Copy Data Backends:** Memory-mapping (`mmap` / `CreateFileMapping`) multi-gigabyte CSV files with background newline-index threads, or lock-free ring buffers for $100\text{k/sec}$ telemetry ingestion.
* **Fast Cell Text Clipping:** Truncating strings with `...` using glyph-advance tables before shaping/rasterizing text so font layout doesn't bottleneck your frame time.

---

### Actionable Odin Blueprint for `bifrost`

To give you something concrete you can drop into `bifrost` and adapt today, here is a complete, idiomatic Odin skeleton for a multi-million-row table widget. It uses `context.temp_allocator` for zero-GC per-frame channel batching, handles DPI pixel-snapping for crisp $1\text{px}$ grid lines, supports live telemetry "tail mode," and outputs flat vertex/index buffers ready for your GPU backend.

```odin
package bifrost_table

import "core:math"
import "core:slice"

// -----------------------------------------------------------------------------
// 1. Primitive Types & Persistent Table State
// -----------------------------------------------------------------------------

Rect :: struct {
	min_x, min_y: f32,
	max_x, max_y: f32,
}

Vertex :: struct {
	x, y:  f32,
	u, v:  f32,
	color: u32, // Packed RGBA: r | (g << 8) | (b << 16) | (a << 24)
}

Draw_Cmd :: struct {
	clip_rect:    Rect,
	idx_offset:   int,
	idx_count:    int,
}

// Temporary per-frame buffer used to group vertices by column scissor rect
Draw_Channel :: struct {
	clip_rect: Rect,
	vertices:  [dynamic]Vertex,
	indices:   [dynamic]u32,
}

// Persistent state stored by the caller (or retained by bifrost via widget ID)
Table_State :: struct {
	// Anchor + local offset avoids f32 precision loss past 16.77M pixels
	top_row_index:      int,
	offset_within_row:  f32,
	scroll_x:           f32,

	default_row_height: f32,
	header_height:      f32,
	pinned_cols:        int,

	// Columns are typically 10..500; prefix sum fits in L1 cache
	col_widths:         []f32,
	col_offsets:        []f32, // len == len(col_widths) + 1

	// Sparse overrides for expanded rows (e.g. clicked telemetry payload)
	row_height_overrides: map[int]f32,

	// Telemetry auto-scroll ("tail mode")
	follow_tail:        bool,
}

// Per-frame context initialized inside begin_table() via temp_allocator
Table_Frame_Ctx :: struct {
	state:             ^Table_State,
	viewport:          Rect,
	dpi_scale:         f32,
	total_rows:        int,

	// Visible ranges calculated for the caller's loop
	row_start:         int,
	row_end:           int, // exclusive
	col_start:         int,
	col_end:           int, // exclusive

	// Screen-space Y tracking as the caller steps through visible rows
	cur_row:           int,
	cur_row_y:         f32,
	cur_row_h:         f32,

	// Channels:
	// [0]             = Row backgrounds / zebra stripes (clipped to body)
	// [1 .. N_vis]    = One channel per visible column (clipped to column X)
	// [N_vis + 1]     = Batched 1px grid lines & selection borders
	channels:          []Draw_Channel,
}

// -----------------------------------------------------------------------------
// 2. Row & Column Spatial Math (O(1) Row Walk + O(log M) Column Lookup)
// -----------------------------------------------------------------------------

get_row_height :: #force_inline proc(s: ^Table_State, row: int) -> f32 {
	if h, ok := s.row_height_overrides[row]; ok {
		return h
	}
	return s.default_row_height
}

// Recompute column prefix sums when a user drags a column resize handle
rebuild_col_offsets :: proc(s: ^Table_State) {
	acc: f32 = 0
	for w, i in s.col_widths {
		s.col_offsets[i] = acc
		acc += w
	}
	s.col_offsets[len(s.col_widths)] = acc
}

// O(log M) binary search to find the first visible scrolling column
find_col_at_x :: proc(offsets: []f32, x: f32) -> int {
	low := 0
	high := len(offsets) - 1
	for low < high {
		mid := int(uint(low + high + 1) >> 1)
		if offsets[mid] <= x {
			low = mid
		} else {
			high = mid - 1
		}
	}
	return low
}

// -----------------------------------------------------------------------------
// 3. Scroll Mechanics (Wheel Deltas, f64 Thumb Ratio, Telemetry Tail Mode)
// -----------------------------------------------------------------------------

scroll_table_wheel :: proc(s: ^Table_State, delta_px_y: f32, delta_px_x: f32, total_rows: int) {
	s.scroll_x = max(0.0, s.scroll_x + delta_px_x)

	if delta_px_y < 0 {
		s.follow_tail = false // User scrolled up manually; pause tail mode
	}

	s.offset_within_row += delta_px_y

	// Walk forward across row boundaries
	for s.offset_within_row >= get_row_height(s, s.top_row_index) {
		if s.top_row_index >= total_rows - 1 {
			s.top_row_index = max(0, total_rows - 1)
			s.offset_within_row = 0
			s.follow_tail = true
			break
		}
		s.offset_within_row -= get_row_height(s, s.top_row_index)
		s.top_row_index += 1
	}

	// Walk backward across row boundaries
	for s.offset_within_row < 0 {
		if s.top_row_index <= 0 {
			s.top_row_index = 0
			s.offset_within_row = 0
			break
		}
		s.top_row_index -= 1
		s.offset_within_row += get_row_height(s, s.top_row_index)
	}
}

// Use f64 for scrollbar thumb dragging so 100M+ rows never lose index precision
scroll_table_to_ratio :: proc(s: ^Table_State, ratio_y: f64, total_rows: int, visible_rows_est: int) {
	clamped := clamp(ratio_y, 0.0, 1.0)
	max_top := max(0, total_rows - visible_rows_est)
	s.top_row_index = int(math.round(clamped * f64(max_top)))
	s.offset_within_row = 0
	s.follow_tail = (clamped >= 0.999)
}

// -----------------------------------------------------------------------------
// 4. Immediate-Mode Table Lifecycle & Batched Geometry Emission
// -----------------------------------------------------------------------------

// Snaps logical coordinate to physical device pixel boundary for crisp 1px lines
snap_px :: #force_inline proc(coord: f32, dpi_scale: f32) -> f32 {
	return math.floor(coord * dpi_scale) / dpi_scale
}

push_quad :: proc(ch: ^Draw_Channel, r: Rect, color: u32) {
	base := u32(len(ch.vertices))
	append(&ch.vertices,
		Vertex{x = r.min_x, y = r.min_y, color = color},
		Vertex{x = r.max_x, y = r.min_y, color = color},
		Vertex{x = r.max_x, y = r.max_y, color = color},
		Vertex{x = r.min_x, y = r.max_y, color = color},
	)
	append(&ch.indices, base+0, base+1, base+2, base+0, base+2, base+3)
}

begin_table :: proc(
	s: ^Table_State,
	viewport: Rect,
	total_rows: int,
	dpi_scale: f32 = 1.0,
) -> Table_Frame_Ctx {
	body_top := viewport.min_y + s.header_height
	body_h   := viewport.max_y - body_top
	body_w   := viewport.max_x - viewport.min_x

	// 1. If tailing live telemetry, snap to the bottom N rows in O(1)
	if s.follow_tail && total_rows > 0 {
		y_rem := body_h
		r := total_rows - 1
		for r > 0 {
			rh := get_row_height(s, r)
			if y_rem < rh do break
			y_rem -= rh
			r -= 1
		}
		s.top_row_index = r
		s.offset_within_row = 0
	}

	// 2. Compute visible row range by walking from top_row_index
	row_start := s.top_row_index
	row_end   := row_start
	y_cursor  := body_top - s.offset_within_row
	for row_end < total_rows && y_cursor < viewport.max_y {
		y_cursor += get_row_height(s, row_end)
		row_end += 1
	}

	// 3. Compute visible column range via binary search on prefix sums
	total_cols := len(s.col_widths)
	col_start  := find_col_at_x(s.col_offsets, s.scroll_x)
	col_end    := find_col_at_x(s.col_offsets, s.scroll_x + body_w)
	col_end     = min(total_cols, col_end + 1)

	vis_col_count := max(0, col_end - col_start)
	// Channel 0 = backgrounds, 1..vis_col_count = columns, last = grid lines
	num_channels := vis_col_count + 2
	channels := make([]Draw_Channel, num_channels, context.temp_allocator)

	body_rect := Rect{viewport.min_x, body_top, viewport.max_x, viewport.max_y}
	channels[0].clip_rect = body_rect
	channels[num_channels - 1].clip_rect = viewport

	// Assign hardware scissor rects per visible column
	for c_idx in 0 ..< vis_col_count {
		col := col_start + c_idx
		c_min_x := viewport.min_x + (s.col_offsets[col] - s.scroll_x)
		c_max_x := viewport.min_x + (s.col_offsets[col + 1] - s.scroll_x)
		channels[1 + c_idx] = Draw_Channel{
			clip_rect = Rect{
				min_x = max(viewport.min_x, c_min_x),
				min_y = body_top,
				max_x = min(viewport.max_x, c_max_x),
				max_y = viewport.max_y,
			},
			vertices = make([dynamic]Vertex, context.temp_allocator),
			indices  = make([dynamic]u32, context.temp_allocator),
		}
	}
	channels[0].vertices = make([dynamic]Vertex, context.temp_allocator)
	channels[0].indices  = make([dynamic]u32, context.temp_allocator)
	channels[num_channels - 1].vertices = make([dynamic]Vertex, context.temp_allocator)
	channels[num_channels - 1].indices  = make([dynamic]u32, context.temp_allocator)

	return Table_Frame_Ctx{
		state      = s,
		viewport   = viewport,
		dpi_scale  = dpi_scale,
		total_rows = total_rows,
		row_start  = row_start,
		row_end    = row_end,
		col_start  = col_start,
		col_end    = col_end,
		cur_row    = row_start - 1,
		cur_row_y  = body_top - s.offset_within_row,
		channels   = channels,
	}
}

// Call at the start of each visible row in the user loop
table_next_row :: proc(ctx: ^Table_Frame_Ctx, zebra_color_even, zebra_color_odd: u32) -> (row_idx: int, y_min, y_max: f32) {
	if ctx.cur_row >= ctx.row_start {
		ctx.cur_row_y += ctx.cur_row_h
	}
	ctx.cur_row += 1
	ctx.cur_row_h = get_row_height(ctx.state, ctx.cur_row)

	y0 := ctx.cur_row_y
	y1 := y0 + ctx.cur_row_h

	// Emit full-row background into Channel 0 (single scissor rect for all rows)
	bg_col := zebra_color_even if (ctx.cur_row & 1) == 0 else zebra_color_odd
	if bg_col != 0 {
		push_quad(&ctx.channels[0], Rect{ctx.viewport.min_x, y0, ctx.viewport.max_x, y1}, bg_col)
	}
	return ctx.cur_row, y0, y1
}

// Returns the target draw channel and cell screen-space rect for column `col`
table_cell_rect :: #force_inline proc(ctx: ^Table_Frame_Ctx, col: int) -> (^Draw_Channel, Rect) {
	s := ctx.state
	ch_idx := 1 + (col - ctx.col_start)
	x0 := ctx.viewport.min_x + (s.col_offsets[col] - s.scroll_x)
	x1 := ctx.viewport.min_x + (s.col_offsets[col + 1] - s.scroll_x)
	return &ctx.channels[ch_idx], Rect{x0, ctx.cur_row_y, x1, ctx.cur_row_y + ctx.cur_row_h}
}

// Emits R+1 horizontal and C+1 vertical grid lines in 1 batch and merges all channels
end_table :: proc(
	ctx: ^Table_Frame_Ctx,
	grid_line_color: u32,
	out_vertices: ^[dynamic]Vertex,
	out_indices:  ^[dynamic]u32,
	out_cmds:     ^[dynamic]Draw_Cmd,
) {
	s := ctx.state
	overlay_ch := &ctx.channels[len(ctx.channels) - 1]
	px_size := 1.0 / ctx.dpi_scale // Exact 1-physical-pixel thickness

	body_top := ctx.viewport.min_y + s.header_height

	// 1. Batch horizontal row grid lines (R + 1 segments)
	y_cursor := body_top - s.offset_within_row
	for r in ctx.row_start ..< ctx.row_end {
		y_cursor += get_row_height(s, r)
		if y_cursor >= body_top && y_cursor <= ctx.viewport.max_y {
			snapped_y := snap_px(y_cursor, ctx.dpi_scale)
			push_quad(overlay_ch, Rect{ctx.viewport.min_x, snapped_y, ctx.viewport.max_x, snapped_y + px_size}, grid_line_color)
		}
	}

	// Header bottom divider line
	header_y := snap_px(body_top, ctx.dpi_scale)
	push_quad(overlay_ch, Rect{ctx.viewport.min_x, header_y, ctx.viewport.max_x, header_y + px_size}, grid_line_color)

	// 2. Batch vertical column grid lines (C + 1 segments)
	for col in ctx.col_start ..= ctx.col_end {
		x_pos := ctx.viewport.min_x + (s.col_offsets[col] - s.scroll_x)
		if x_pos >= ctx.viewport.min_x && x_pos <= ctx.viewport.max_x {
			snapped_x := snap_px(x_pos, ctx.dpi_scale)
			push_quad(overlay_ch, Rect{snapped_x, ctx.viewport.min_y, snapped_x + px_size, ctx.viewport.max_y}, grid_line_color)
		}
	}

	// 3. Flatten non-empty channels into the main GPU output buffers
	for &ch in ctx.channels {
		if len(ch.indices) == 0 do continue

		vtx_base   := u32(len(out_vertices^))
		idx_offset := len(out_indices^)

		append(out_vertices, ..ch.vertices[:])
		for idx in ch.indices {
			append(out_indices, vtx_base + idx)
		}

		append(out_cmds, Draw_Cmd{
			clip_rect  = ch.clip_rect,
			idx_offset = idx_offset,
			idx_count  = len(ch.indices),
		})
	}
}

```

### How Calling Code Uses This in `bifrost`

Because `begin_table` computes `row_start ..< row_end` and `col_start ..< col_end` up front, rendering a **50,000,000-row telemetry log or CSV** in your application code looks like a tiny loop that only touches ~50 rows per frame:

```odin
tctx := begin_table(&table_state, panel_rect, total_csv_rows, window_dpi_scale)

for _ in tctx.row_start ..< tctx.row_end {
	row_idx, y0, y1 := table_next_row(&tctx, 0xFF1E1E1E, 0xFF252526)

	for col_idx in tctx.col_start ..< tctx.col_end {
		ch, cell_rect := table_cell_rect(&tctx, col_idx)
		// Submit custom cell background, status bar, or text into `ch` within `cell_rect`
	}
}

end_table(&tctx, 0xFF3C3C3C, &gpu_vertices, &gpu_indices, &gpu_draw_cmds)

```


### Yes—You Have Enough to Build the Grid UI Right Now

For **cell geometry, layout, virtual scrolling, and GPU batching**, you do **not** need more research. The core mathematical and graphics constraints are identical whether you render in a browser or natively in Odin:

1. **Viewport Virtualization & Precision:** Decoupling scroll state into `{row_index: int, offset_within_row: f32}` so `f32` vertex coordinates never exceed the $2^{24}$ ($16,777,216\text{ px}$) precision cliff.


2. **Spatial Indexing:** Using $O(1)$ math for uniform telemetry/CSV rows, a small prefix-sum slice with binary search for columns, and sparse overrides for expanded rows.


3. **GPU Draw-Call Batching:** Splitting cell submissions into per-column draw channels so you only issue **1 hardware scissor call per visible column**, plus **1 batched draw call** for all horizontal and vertical grid lines.



The **only** areas where you would ever need additional research later are **outside** the cell-dimension UI layer:

* **Zero-Copy Data Backends:** Memory-mapping (`mmap` / `CreateFileMapping`) multi-gigabyte CSV files with background newline-index threads, or lock-free ring buffers for $100\text{k/sec}$ telemetry ingestion.
* **Fast Cell Text Clipping:** Truncating strings with `...` using glyph-advance tables before shaping/rasterizing text so font layout doesn't bottleneck your frame time.

---

### Actionable Odin Blueprint for `bifrost`

To give you something concrete you can drop into `bifrost` and adapt today, here is a complete, idiomatic Odin skeleton for a multi-million-row table widget. It uses `context.temp_allocator` for zero-GC per-frame channel batching, handles DPI pixel-snapping for crisp $1\text{px}$ grid lines, supports live telemetry "tail mode," and outputs flat vertex/index buffers ready for your GPU backend.

```odin
package bifrost_table

import "core:math"
import "core:slice"

// -----------------------------------------------------------------------------
// 1. Primitive Types & Persistent Table State
// -----------------------------------------------------------------------------

Rect :: struct {
	min_x, min_y: f32,
	max_x, max_y: f32,
}

Vertex :: struct {
	x, y:  f32,
	u, v:  f32,
	color: u32, // Packed RGBA: r | (g << 8) | (b << 16) | (a << 24)
}

Draw_Cmd :: struct {
	clip_rect:    Rect,
	idx_offset:   int,
	idx_count:    int,
}

// Temporary per-frame buffer used to group vertices by column scissor rect
Draw_Channel :: struct {
	clip_rect: Rect,
	vertices:  [dynamic]Vertex,
	indices:   [dynamic]u32,
}

// Persistent state stored by the caller (or retained by bifrost via widget ID)
Table_State :: struct {
	// Anchor + local offset avoids f32 precision loss past 16.77M pixels
	top_row_index:      int,
	offset_within_row:  f32,
	scroll_x:           f32,

	default_row_height: f32,
	header_height:      f32,
	pinned_cols:        int,

	// Columns are typically 10..500; prefix sum fits in L1 cache
	col_widths:         []f32,
	col_offsets:        []f32, // len == len(col_widths) + 1

	// Sparse overrides for expanded rows (e.g. clicked telemetry payload)
	row_height_overrides: map[int]f32,

	// Telemetry auto-scroll ("tail mode")
	follow_tail:        bool,
}

// Per-frame context initialized inside begin_table() via temp_allocator
Table_Frame_Ctx :: struct {
	state:             ^Table_State,
	viewport:          Rect,
	dpi_scale:         f32,
	total_rows:        int,

	// Visible ranges calculated for the caller's loop
	row_start:         int,
	row_end:           int, // exclusive
	col_start:         int,
	col_end:           int, // exclusive

	// Screen-space Y tracking as the caller steps through visible rows
	cur_row:           int,
	cur_row_y:         f32,
	cur_row_h:         f32,

	// Channels:
	// [0]             = Row backgrounds / zebra stripes (clipped to body)
	// [1 .. N_vis]    = One channel per visible column (clipped to column X)
	// [N_vis + 1]     = Batched 1px grid lines & selection borders
	channels:          []Draw_Channel,
}

// -----------------------------------------------------------------------------
// 2. Row & Column Spatial Math (O(1) Row Walk + O(log M) Column Lookup)
// -----------------------------------------------------------------------------

get_row_height :: #force_inline proc(s: ^Table_State, row: int) -> f32 {
	if h, ok := s.row_height_overrides[row]; ok {
		return h
	}
	return s.default_row_height
}

// Recompute column prefix sums when a user drags a column resize handle
rebuild_col_offsets :: proc(s: ^Table_State) {
	acc: f32 = 0
	for w, i in s.col_widths {
		s.col_offsets[i] = acc
		acc += w
	}
	s.col_offsets[len(s.col_widths)] = acc
}

// O(log M) binary search to find the first visible scrolling column
find_col_at_x :: proc(offsets: []f32, x: f32) -> int {
	low := 0
	high := len(offsets) - 1
	for low < high {
		mid := int(uint(low + high + 1) >> 1)
		if offsets[mid] <= x {
			low = mid
		} else {
			high = mid - 1
		}
	}
	return low
}

// -----------------------------------------------------------------------------
// 3. Scroll Mechanics (Wheel Deltas, f64 Thumb Ratio, Telemetry Tail Mode)
// -----------------------------------------------------------------------------

scroll_table_wheel :: proc(s: ^Table_State, delta_px_y: f32, delta_px_x: f32, total_rows: int) {
	s.scroll_x = max(0.0, s.scroll_x + delta_px_x)

	if delta_px_y < 0 {
		s.follow_tail = false // User scrolled up manually; pause tail mode
	}

	s.offset_within_row += delta_px_y

	// Walk forward across row boundaries
	for s.offset_within_row >= get_row_height(s, s.top_row_index) {
		if s.top_row_index >= total_rows - 1 {
			s.top_row_index = max(0, total_rows - 1)
			s.offset_within_row = 0
			s.follow_tail = true
			break
		}
		s.offset_within_row -= get_row_height(s, s.top_row_index)
		s.top_row_index += 1
	}

	// Walk backward across row boundaries
	for s.offset_within_row < 0 {
		if s.top_row_index <= 0 {
			s.top_row_index = 0
			s.offset_within_row = 0
			break
		}
		s.top_row_index -= 1
		s.offset_within_row += get_row_height(s, s.top_row_index)
	}
}

// Use f64 for scrollbar thumb dragging so 100M+ rows never lose index precision
scroll_table_to_ratio :: proc(s: ^Table_State, ratio_y: f64, total_rows: int, visible_rows_est: int) {
	clamped := clamp(ratio_y, 0.0, 1.0)
	max_top := max(0, total_rows - visible_rows_est)
	s.top_row_index = int(math.round(clamped * f64(max_top)))
	s.offset_within_row = 0
	s.follow_tail = (clamped >= 0.999)
}

// -----------------------------------------------------------------------------
// 4. Immediate-Mode Table Lifecycle & Batched Geometry Emission
// -----------------------------------------------------------------------------

// Snaps logical coordinate to physical device pixel boundary for crisp 1px lines
snap_px :: #force_inline proc(coord: f32, dpi_scale: f32) -> f32 {
	return math.floor(coord * dpi_scale) / dpi_scale
}

push_quad :: proc(ch: ^Draw_Channel, r: Rect, color: u32) {
	base := u32(len(ch.vertices))
	append(&ch.vertices,
		Vertex{x = r.min_x, y = r.min_y, color = color},
		Vertex{x = r.max_x, y = r.min_y, color = color},
		Vertex{x = r.max_x, y = r.max_y, color = color},
		Vertex{x = r.min_x, y = r.max_y, color = color},
	)
	append(&ch.indices, base+0, base+1, base+2, base+0, base+2, base+3)
}

begin_table :: proc(
	s: ^Table_State,
	viewport: Rect,
	total_rows: int,
	dpi_scale: f32 = 1.0,
) -> Table_Frame_Ctx {
	body_top := viewport.min_y + s.header_height
	body_h   := viewport.max_y - body_top
	body_w   := viewport.max_x - viewport.min_x

	// 1. If tailing live telemetry, snap to the bottom N rows in O(1)
	if s.follow_tail && total_rows > 0 {
		y_rem := body_h
		r := total_rows - 1
		for r > 0 {
			rh := get_row_height(s, r)
			if y_rem < rh do break
			y_rem -= rh
			r -= 1
		}
		s.top_row_index = r
		s.offset_within_row = 0
	}

	// 2. Compute visible row range by walking from top_row_index
	row_start := s.top_row_index
	row_end   := row_start
	y_cursor  := body_top - s.offset_within_row
	for row_end < total_rows && y_cursor < viewport.max_y {
		y_cursor += get_row_height(s, row_end)
		row_end += 1
	}

	// 3. Compute visible column range via binary search on prefix sums
	total_cols := len(s.col_widths)
	col_start  := find_col_at_x(s.col_offsets, s.scroll_x)
	col_end    := find_col_at_x(s.col_offsets, s.scroll_x + body_w)
	col_end     = min(total_cols, col_end + 1)

	vis_col_count := max(0, col_end - col_start)
	// Channel 0 = backgrounds, 1..vis_col_count = columns, last = grid lines
	num_channels := vis_col_count + 2
	channels := make([]Draw_Channel, num_channels, context.temp_allocator)

	body_rect := Rect{viewport.min_x, body_top, viewport.max_x, viewport.max_y}
	channels[0].clip_rect = body_rect
	channels[num_channels - 1].clip_rect = viewport

	// Assign hardware scissor rects per visible column
	for c_idx in 0 ..< vis_col_count {
		col := col_start + c_idx
		c_min_x := viewport.min_x + (s.col_offsets[col] - s.scroll_x)
		c_max_x := viewport.min_x + (s.col_offsets[col + 1] - s.scroll_x)
		channels[1 + c_idx] = Draw_Channel{
			clip_rect = Rect{
				min_x = max(viewport.min_x, c_min_x),
				min_y = body_top,
				max_x = min(viewport.max_x, c_max_x),
				max_y = viewport.max_y,
			},
			vertices = make([dynamic]Vertex, context.temp_allocator),
			indices  = make([dynamic]u32, context.temp_allocator),
		}
	}
	channels[0].vertices = make([dynamic]Vertex, context.temp_allocator)
	channels[0].indices  = make([dynamic]u32, context.temp_allocator)
	channels[num_channels - 1].vertices = make([dynamic]Vertex, context.temp_allocator)
	channels[num_channels - 1].indices  = make([dynamic]u32, context.temp_allocator)

	return Table_Frame_Ctx{
		state      = s,
		viewport   = viewport,
		dpi_scale  = dpi_scale,
		total_rows = total_rows,
		row_start  = row_start,
		row_end    = row_end,
		col_start  = col_start,
		col_end    = col_end,
		cur_row    = row_start - 1,
		cur_row_y  = body_top - s.offset_within_row,
		channels   = channels,
	}
}

// Call at the start of each visible row in the user loop
table_next_row :: proc(ctx: ^Table_Frame_Ctx, zebra_color_even, zebra_color_odd: u32) -> (row_idx: int, y_min, y_max: f32) {
	if ctx.cur_row >= ctx.row_start {
		ctx.cur_row_y += ctx.cur_row_h
	}
	ctx.cur_row += 1
	ctx.cur_row_h = get_row_height(ctx.state, ctx.cur_row)

	y0 := ctx.cur_row_y
	y1 := y0 + ctx.cur_row_h

	// Emit full-row background into Channel 0 (single scissor rect for all rows)
	bg_col := zebra_color_even if (ctx.cur_row & 1) == 0 else zebra_color_odd
	if bg_col != 0 {
		push_quad(&ctx.channels[0], Rect{ctx.viewport.min_x, y0, ctx.viewport.max_x, y1}, bg_col)
	}
	return ctx.cur_row, y0, y1
}

// Returns the target draw channel and cell screen-space rect for column `col`
table_cell_rect :: #force_inline proc(ctx: ^Table_Frame_Ctx, col: int) -> (^Draw_Channel, Rect) {
	s := ctx.state
	ch_idx := 1 + (col - ctx.col_start)
	x0 := ctx.viewport.min_x + (s.col_offsets[col] - s.scroll_x)
	x1 := ctx.viewport.min_x + (s.col_offsets[col + 1] - s.scroll_x)
	return &ctx.channels[ch_idx], Rect{x0, ctx.cur_row_y, x1, ctx.cur_row_y + ctx.cur_row_h}
}

// Emits R+1 horizontal and C+1 vertical grid lines in 1 batch and merges all channels
end_table :: proc(
	ctx: ^Table_Frame_Ctx,
	grid_line_color: u32,
	out_vertices: ^[dynamic]Vertex,
	out_indices:  ^[dynamic]u32,
	out_cmds:     ^[dynamic]Draw_Cmd,
) {
	s := ctx.state
	overlay_ch := &ctx.channels[len(ctx.channels) - 1]
	px_size := 1.0 / ctx.dpi_scale // Exact 1-physical-pixel thickness

	body_top := ctx.viewport.min_y + s.header_height

	// 1. Batch horizontal row grid lines (R + 1 segments)
	y_cursor := body_top - s.offset_within_row
	for r in ctx.row_start ..< ctx.row_end {
		y_cursor += get_row_height(s, r)
		if y_cursor >= body_top && y_cursor <= ctx.viewport.max_y {
			snapped_y := snap_px(y_cursor, ctx.dpi_scale)
			push_quad(overlay_ch, Rect{ctx.viewport.min_x, snapped_y, ctx.viewport.max_x, snapped_y + px_size}, grid_line_color)
		}
	}

	// Header bottom divider line
	header_y := snap_px(body_top, ctx.dpi_scale)
	push_quad(overlay_ch, Rect{ctx.viewport.min_x, header_y, ctx.viewport.max_x, header_y + px_size}, grid_line_color)

	// 2. Batch vertical column grid lines (C + 1 segments)
	for col in ctx.col_start ..= ctx.col_end {
		x_pos := ctx.viewport.min_x + (s.col_offsets[col] - s.scroll_x)
		if x_pos >= ctx.viewport.min_x && x_pos <= ctx.viewport.max_x {
			snapped_x := snap_px(x_pos, ctx.dpi_scale)
			push_quad(overlay_ch, Rect{snapped_x, ctx.viewport.min_y, snapped_x + px_size, ctx.viewport.max_y}, grid_line_color)
		}
	}

	// 3. Flatten non-empty channels into the main GPU output buffers
	for &ch in ctx.channels {
		if len(ch.indices) == 0 do continue

		vtx_base   := u32(len(out_vertices^))
		idx_offset := len(out_indices^)

		append(out_vertices, ..ch.vertices[:])
		for idx in ch.indices {
			append(out_indices, vtx_base + idx)
		}

		append(out_cmds, Draw_Cmd{
			clip_rect  = ch.clip_rect,
			idx_offset = idx_offset,
			idx_count  = len(ch.indices),
		})
	}
}

```

### How Calling Code Uses This in `bifrost`

Because `begin_table` computes `row_start ..< row_end` and `col_start ..< col_end` up front, rendering a **50,000,000-row telemetry log or CSV** in your application code looks like a tiny loop that only touches ~50 rows per frame:

```odin
tctx := begin_table(&table_state, panel_rect, total_csv_rows, window_dpi_scale)

for _ in tctx.row_start ..< tctx.row_end {
	row_idx, y0, y1 := table_next_row(&tctx, 0xFF1E1E1E, 0xFF252526)

	for col_idx in tctx.col_start ..< tctx.col_end {
		ch, cell_rect := table_cell_rect(&tctx, col_idx)
		// Submit custom cell background, status bar, or text into `ch` within `cell_rect`
	}
}

end_table(&tctx, 0xFF3C3C3C, &gpu_vertices, &gpu_indices, &gpu_draw_cmds)

```
