*(Note: `building_an_actor_driven_odin_tui.md` was not attached alongside the three reference `.patch` files, so the analysis and concrete Odin modules below target the exact procedures and types referenced in your prompt—`slice_utf8_by_runes`, `ui_virtual_list`, `draw_vertical_scrollbar`, `scroll.odin`, `text_input.odin`, `splitter_keymap.odin`, and `command_palette.odin`.)*

---

## 1. UTF-8 / Grapheme Text Editing (`libvaxis` vs. `text_input.odin`)

### How `libvaxis` (`TextField.zig` & `TextInput.zig`) Handles Editing and Scrolling

* **Gap-Buffer Storage & Grapheme-Aligned Cursor Movement:** Both `TextField.zig` and `TextInput.zig` use a byte-level gap buffer (`Buffer`) split into `firstHalf()` (`buffer[0..cursor]`) and `secondHalf()` (`buffer[cursor + gap_size..]`), maintaining the invariant that the gap never sits inside a multi-byte grapheme cluster.


* **Grapheme-Cluster Stepping (`Left` / `Right` / `Backspace` / `Delete`):**
* `cursorLeft()` and `deleteBeforeCursor()` iterate `unicode.graphemeIterator(self.buf.firstHalf())` to find the byte length (`len`) of the final grapheme before the cursor, then call `moveGapLeft(len)` or `growGapLeft(len)`.


* `cursorRight()` and `deleteAfterCursor()` take the first grapheme from `unicode.graphemeIterator(self.buf.secondHalf())` and call `moveGapRight(grapheme.len)` or `growGapRight(grapheme.len)`.




* **Two Distinct Backward Word-Deletion Semantics (`Ctrl+W` vs. `Alt+Backspace`):**
* **`Ctrl+W` (`deleteWordBeforeWhitespace` / Readline `unix-word-rubout`):** Walks backward through `firstHalf()` via `decodeCodepointBefore`, first skipping trailing Unicode whitespace (`isWhitespaceCodepoint`, including ASCII whitespace and Unicode `separator_space`, `separator_line`, and `separator_paragraph` such as `U+3000` ideographic space), then skipping non-whitespace codepoints until hitting whitespace or index `0`. It deletes `to_delete = self.buf.cursor - i` bytes via `moveGapLeft(to_delete)` and `growGapRight(to_delete)`. Punctuation-joined tokens like `foo.bar` or `hello-world` are deleted as a single unit.


* **`Alt+Backspace` (`deleteWordBefore` / Readline `backward-kill-word`):** Calls `moveBackwardWordwise()`, which skips non-word codepoints (hyphens, slashes, dots, em-dashes) and then skips word codepoints (`isWordCodepoint`: letters, digits, combining marks, connector punctuation, and `_`), then expands the gap right by `pre - self.buf.cursor`. On `"hello-world"`, `Alt+Backspace` stops at `"hello-"`, whereas `Ctrl+W` deletes the entire `"hello-world"`.




* **Kill-to-End (`Ctrl+K`) and Kill-to-Start (`Ctrl+U`):**
* `deleteToEnd()` (`Ctrl+K`) executes `self.buf.growGapRight(self.buf.secondHalf().len)`, absorbing everything after the cursor into the gap in $O(1)$ time with zero memory movement.


* `deleteToStart()` (`Ctrl+U`) executes `self.buf.growGapLeft(self.buf.cursor)`, resetting the cursor to `0` and expanding the gap in $O(1)$ time.





### What Goes Wrong in `slice_utf8_by_runes` with 2-Column CJK / Emoji Runes

When `text_input.odin` slices the visible window and positions the cursor using **rune counts** (`slice_utf8_by_runes(text, scroll_offset, viewport_width)`) rather than **display cell widths** and **grapheme boundaries**, four bugs occur:

1. **Right-Border Overflow (Up to 2x Width Bleed):** Fullwidth CJK ideographs (`"称号"`, `"コン"`), halfwidth katakana with non-combining dakuten (`"ｶﾞ"`), and emojis (`"🦀"`) occupy **2 terminal columns** per grapheme. Slicing `viewport_width` runes when the user types CJK characters emits up to `2 * viewport_width` terminal columns, overwriting the right border and neighboring split panes.


2. **Visual Cursor Desynchronization:** When cursor screen X is calculated as `cursor_rune_index - scroll_offset`, every 2-column rune to the left of the cursor advances the rendered text by 2 cells while the cursor math only advances by 1. The visual cursor lags behind the actual insertion point by 1 column per wide rune.
3. **Mid-Cluster Splitting on ZWJ / VS16 / Combining Sequences:** Multi-codepoint graphemes like `"👩‍🚀"` (3 codepoints, 11 UTF-8 bytes, 2 cells), `"🐻‍❄️"` (4 codepoints, 2 cells), or `"⌨️"` (base + `U+FE0F` variation selector, 2 cells) are single visual characters. Stepping or slicing by `rune` parks the cursor inside the sequence, corrupting terminal output and requiring multiple `Backspace` presses to delete one character.


4. **Wide-Character Boundary Clipping & `libvaxis`'s Left-Ellipsis Bug:**
* If only 1 column remains at the right edge of the input box (`col == max_width - 1`) and the next grapheme has width 2, rendering it bleeds out of bounds. Both `ratatui` (`remaining_width.checked_sub(width)` in `Buffer::set_stringn`) and `libvaxis` (`if (col + w > max_width)`) stop before drawing the wide glyph, with `libvaxis` placing a 1-column `"…"` at `max_width - 1`.


* However, `libvaxis` has a subtle bug when horizontally scrolled (`self.draw_offset` greater than `0`): it draws graphemes starting at `col = 0` and afterwards overwrites cell `(0, 0)` with `"…"` (`surface.writeCell(0, 0, .{ .char = ellipsis, .style = style })`). If the first visible grapheme at `draw_offset` is a 2-column CJK/emoji character occupying cells `0` and `1`, overwriting cell `0` with a 1-column `"…"` leaves the orphaned trailing cell of the wide character at `col = 1`. In `bifrost/text_input.odin` below, we reserve column `0` for `"…"` (or pad split 2-column cells with `" "`) so wide glyphs never corrupt either edge.





---

## 2. Virtualized List & Table Column Sizing (`libvaxis` & `ratatui`)

### Comparing Reference Table Sizing Patterns

* **`ratatui/table.rs` (`get_column_widths` + `HighlightSpacing`):**
* Separates **horizontal column layout** from **virtualized vertical row slicing**.


* First, `selection_width` reserves a fixed gutter for the row cursor indicator; using `HighlightSpacing::Always` ensures the table columns never shift horizontally when selection state changes.


* Second, `get_column_widths(max_width, selection_width, col_count)` solves horizontal `Constraint`s (`Length`, `Min`, `Max`, `Percentage`, `Ratio`, `Fill`) plus `column_spacing` once per frame into a slice of `(x, width)` column spans (`Vec<Rect>`).


* Third, `render_header`, `render_rows` (which only materializes visible rows `.skip(start_index).take(end_index - start_index)`), and `render_footer` all iterate over that same `column_widths` slice.




* **`libvaxis/Table.zig` (`WidthStyle` + `calcColWidth`) & `ScrollBars.zig`:**
* `Table.zig` provides `WidthStyle` variants: `.dynamic_fill` (divides window width across columns), `.dynamic_header_len: u16` (header width + padding), `.static_all: u16`, and `.static_individual: []const u16`.


* `ScrollBars.zig` highlights the core danger of virtualized auto-sizing: estimating widths solely from the currently visible slice of children causes **inconsistent widths and horizontal jitter** as the user scrolls through records of varying lengths.





### Minimal Pattern to Include for Virtualized `xitdb` Tables

To render virtualized `xitdb` map/struct records with aligned columns and zero horizontal jitter:

1. **`Table_Column_Spec` + `resolve_table_columns`:** Solve all column `(x, width)` spans **once before the visible row loop** using fixed (`Fixed`), minimum/fill (`Fill`), percentage (`Percent`), or content-sampled (`Auto`) constraints, reserving space for the selection gutter (`2` cols) and vertical scrollbar (`1` col).


2. **Monotonic High-Water-Mark Content Widths (`update_column_high_water_marks`):** For `.Auto` columns on `xitdb` cursors where scanning 100,000 rows up front is undesirable, initialize `max_seen_width` from the column header length and update `col.max_seen_width = max(col.max_seen_width, cell_display_width)` for each visible window (clamped to `[min_width, max_width]`). Because `max_seen_width` only grows monotonically (resetting only when the `xitdb` collection/query changes), scrolling back and forth never causes columns to shrink or oscillate.

---

## 3. Proportional Scrollbars (`ScrollBars.zig` & `scrollbar.rs`)

### Rounding and Clamping Edge Cases at `total_rows = 100,000` (`max_scroll - 1` vs. `max_scroll`)

When `total_rows = 100,000` and `viewport_rows = 20` (`track_height = 20`, `max_scroll = 99,980`, `thumb_height = 1`, `max_thumb_offset = 19`), three edge cases appear in reference and naive scrollbar implementations:

1. **Premature Bottom/Top Snap (`max_scroll - 1` Renders Identically to `max_scroll`):**
* In `ratatui/scrollbar.rs`, `part_lengths` uses nearest-integer rounding (`rounding_divide(numerator, denominator) = (numerator + denominator / 2) / denominator`).


* With nearest-integer rounding (or float rounding), when `scroll_offset = max_scroll - 1 = 99,979`:

$$\frac{99,979 \times 19}{99,980} = 18.999809\dots \xrightarrow{\text{round}} 19$$



In fact, every row from `scroll_offset = 97,349` to `99,979` rounds to `19` (the bottom cell). The thumb hits the bottom of the track **2,631 rows before the actual end**, making `max_scroll - 1` visually indistinguishable from `max_scroll`.
* Symmetrically, at `scroll_offset = 1` (and up to `2,631`), both nearest-rounding and truncation yield `thumb_offset = 0`, making the scrollbar look parked at the very top even after scrolling down thousands of rows.


2. **Thumb Overrun at Track End (`Ratatui Issue #2582` & `libvaxis ScrollBars.zig`):**
* In `libvaxis/ScrollBars.zig`, when `has_more_vertical` is `true`, `thumb_top` is computed as `@intFromFloat(widget_height_f * top_child_idx_f / total_num_children_f)` **without clamping** to `max.height - thumb_height`. If `thumb_height` is greater than `1` and `scroll.top` is near the bottom (`max_scroll - 1`), `thumb_top + thumb_height` can exceed the track height.


* `ratatui/scrollbar.rs` explicitly fixed this in Issue #2582 by clamping `thumb_start` to `track_length.saturating_sub(thumb_length)` rather than `track_length - 1` so `thumb_start + thumb_length` never overruns the track.




3. **32-Bit Integer Overflow:**
* Multiplying `scroll_offset * track_avail` in 32-bit integers overflows when `total_rows` reaches tens of millions; the numerator must be promoted to `i64`.



### The Fix: Interior-Detent Clamping in `draw_vertical_scrollbar`

In `bifrost/scroll.odin`, we compute `track_avail := track_height - thumb_height` in `i64` and reserve the two boundary cells when `track_avail` is at least `2`:

* `thumb_offset = 0` **only** when `scroll_offset` is `0` (true top).
* `thumb_offset = track_avail` **only** when `scroll_offset` reaches `max_scroll` (true bottom).
* Whenever `0` is less than `scroll_offset` and `scroll_offset` is less than `max_scroll`, `thumb_offset` is clamped to the interior range `[1, track_avail - 1]`. At `max_scroll - 1` (`99,979`), the thumb sits at `track_avail - 1` (`18`), leaving 1 visible track cell at the bottom until the user steps onto `max_scroll` (`99,980`).

---

## Concrete Odin Refinements

### 1. `bifrost/scroll.odin`

Includes `Scroll_State` (with `scroll_padding` from `ratatui` and `jump_to_item` / `scroll_to_bottom` from `libvaxis`), interior-detent `draw_vertical_scrollbar`, and synchronized `Table_Column_Spec` / `resolve_table_columns` for virtualized `xitdb` tables.

```odin
package bifrost

import "core:unicode/utf8"

Rect :: struct {
	x: int,
	y: int,
	w: int,
	h: int,
}

Color :: distinct u32

Style_Flags :: bit_set[enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Reverse,
}; u8]

Style :: struct {
	fg:    Color,
	bg:    Color,
	flags: Style_Flags,
}

Cell :: struct {
	ch:    rune,
	width: u8,
	style: Style,
}

Surface :: struct {
	w:        int,
	h:        int,
	cells:    []Cell,
	cursor_x: int,
	cursor_y: int,
}

surface_set_cell :: proc(s: ^Surface, x, y: int, ch: rune, style: Style, rune_w: u8 = 1) {
	if s == nil || x < 0 || y < 0 || x >= s.w || y >= s.h {
		return
	}
	idx := y * s.w + x
	s.cells[idx] = Cell{
		ch    = ch,
		width = rune_w,
		style = style,
	}
	// Reset trailing cell for 2-column wide glyphs (matching ratatui Buffer::set_stringn)
	if rune_w == 2 && x + 1 < s.w {
		s.cells[idx + 1] = Cell{
			ch    = ' ',
			width = 0,
			style = style,
		}
	}
}

surface_fill_rect :: proc(s: ^Surface, r: Rect, ch: rune, style: Style) {
	if s == nil || r.w <= 0 || r.h <= 0 {
		return
	}
	x0 := max(0, r.x)
	y0 := max(0, r.y)
	x1 := min(s.w, r.x + r.w)
	y1 := min(s.h, r.y + r.h)
	for y in y0 ..< y1 {
		row_base := y * s.w
		for x in x0 ..< x1 {
			s.cells[row_base + x] = Cell{
				ch    = ch,
				width = 1,
				style = style,
			}
		}
	}
}

// -----------------------------------------------------------------------------
// Proportional Scrollbar with Interior-Detent Clamping
// -----------------------------------------------------------------------------

Scrollbar_Metrics :: struct {
	track_height: int,
	thumb_offset: int,
	thumb_height: int,
	max_scroll:   int,
}

compute_scrollbar_metrics :: proc(
	track_height: int,
	total_rows:   int,
	viewport_rows: int,
	scroll_offset: int,
) -> Scrollbar_Metrics {
	if track_height <= 0 || total_rows <= 0 || viewport_rows <= 0 {
		return {}
	}

	max_scroll := max(0, total_rows - viewport_rows)
	clamped_scroll := clamp(scroll_offset, 0, max_scroll)

	if max_scroll == 0 {
		return Scrollbar_Metrics{
			track_height = track_height,
			thumb_offset = 0,
			thumb_height = track_height,
			max_scroll   = 0,
		}
	}

	// Nearest-integer division in 64-bit arithmetic to avoid i32 overflow on 100k+ rows.
	thumb_num := i64(viewport_rows) * i64(track_height) + i64(total_rows) / 2
	raw_thumb_h := int(thumb_num / i64(total_rows))
	// When scrollable (max_scroll > 0) and track_height >= 2, cap thumb_height at
	// track_height - 1 so there is always at least 1 cell of travel.
	max_thumb_h := max(1, track_height - 1)
	thumb_height := clamp(raw_thumb_h, 1, max_thumb_h)

	track_avail := track_height - thumb_height
	if track_avail <= 0 {
		return Scrollbar_Metrics{
			track_height = track_height,
			thumb_offset = 0,
			thumb_height = track_height,
			max_scroll   = max_scroll,
		}
	}

	thumb_offset := 0
	if clamped_scroll <= 0 {
		thumb_offset = 0
	} else if clamped_scroll >= max_scroll {
		thumb_offset = track_avail
	} else if track_avail == 1 {
		// Only 2 positions exist (0 and 1): split at midpoint.
		thumb_offset = 1 if i64(clamped_scroll) * 2 >= i64(max_scroll) else 0
	} else {
		// Interior-detent mapping:
		// Reserve 0 strictly for top (scroll_offset == 0) and track_avail strictly
		// for bottom (scroll_offset == max_scroll). Map 0 < scroll_offset < max_scroll
		// into [1, track_avail - 1] so max_scroll - 1 never prematurely snaps to bottom.
		pos_num := i64(clamped_scroll) * i64(track_avail) + i64(max_scroll) / 2
		raw_offset := int(pos_num / i64(max_scroll))
		thumb_offset = clamp(raw_offset, 1, track_avail - 1)
	}

	return Scrollbar_Metrics{
		track_height = track_height,
		thumb_offset = thumb_offset,
		thumb_height = thumb_height,
		max_scroll   = max_scroll,
	}
}

draw_vertical_scrollbar :: proc(
	s:             ^Surface,
	area:          Rect,
	total_rows:    int,
	viewport_rows: int,
	scroll_offset: int,
	track_style:   Style,
	thumb_style:   Style,
	track_ch:      rune = '│',
	thumb_ch:      rune = '┃',
) {
	if s == nil || area.w <= 0 || area.h <= 0 || total_rows <= viewport_rows {
		return
	}

	metrics := compute_scrollbar_metrics(area.h, total_rows, viewport_rows, scroll_offset)
	col := area.x + area.w - 1
	thumb_end := metrics.thumb_offset + metrics.thumb_height

	for row in 0 ..< area.h {
		is_thumb := row >= metrics.thumb_offset && row < thumb_end
		ch := thumb_ch if is_thumb else track_ch
		st := thumb_style if is_thumb else track_style
		surface_set_cell(s, col, area.y + row, ch, st, 1)
	}
}

// -----------------------------------------------------------------------------
// Virtualized Scroll State (List & Table Navigation)
// -----------------------------------------------------------------------------

Scroll_State :: struct {
	offset:         int,
	cursor:         int,
	scroll_padding: int,
	wheel_step:     int,
}

scroll_state_clamp :: proc(state: ^Scroll_State, total_rows, viewport_rows: int) {
	if total_rows <= 0 {
		state.cursor = 0
		state.offset = 0
		return
	}
	v_rows := max(1, viewport_rows)
	state.cursor = clamp(state.cursor, 0, total_rows - 1)

	// Reduce effective padding if viewport is smaller than 2 * padding + 1 (ratatui pattern)
	max_pad := max(0, (v_rows - 1) / 2)
	pad := clamp(state.scroll_padding, 0, max_pad)

	top_bound := max(0, state.cursor - pad)
	bot_bound := min(total_rows - 1, state.cursor + pad)

	if top_bound < state.offset {
		state.offset = top_bound
	} else if bot_bound >= state.offset + v_rows {
		state.offset = bot_bound - v_rows + 1
	}

	max_scroll := max(0, total_rows - v_rows)
	state.offset = clamp(state.offset, 0, max_scroll)
}

scroll_move_cursor :: proc(state: ^Scroll_State, delta, total_rows, viewport_rows: int) {
	if total_rows <= 0 {
		state.cursor = 0
		state.offset = 0
		return
	}
	state.cursor = clamp(state.cursor + delta, 0, total_rows - 1)
	scroll_state_clamp(state, total_rows, viewport_rows)
}

scroll_jump_to :: proc(state: ^Scroll_State, idx, total_rows, viewport_rows: int) {
	if total_rows <= 0 {
		state.cursor = 0
		state.offset = 0
		return
	}
	state.cursor = clamp(idx, 0, total_rows - 1)
	scroll_state_clamp(state, total_rows, viewport_rows)
}

scroll_to_bottom :: proc(state: ^Scroll_State, total_rows, viewport_rows: int) {
	scroll_jump_to(state, total_rows - 1, total_rows, viewport_rows)
}

scroll_wheel :: proc(state: ^Scroll_State, lines, total_rows, viewport_rows: int) {
	max_scroll := max(0, total_rows - max(1, viewport_rows))
	state.offset = clamp(state.offset + lines, 0, max_scroll)
}

Virtual_Range :: struct {
	start_row:    int,
	end_row:      int,
	content_area: Rect,
	has_scrollbar: bool,
}

begin_virtual_list :: proc(
	state:      ^Scroll_State,
	area:       Rect,
	total_rows: int,
) -> Virtual_Range {
	if area.w <= 0 || area.h <= 0 || total_rows <= 0 {
		state.offset = 0
		state.cursor = 0
		return Virtual_Range{content_area = area}
	}
	scroll_state_clamp(state, total_rows, area.h)
	has_sb := total_rows > area.h && area.w > 1
	content_w := area.w - (1 if has_sb else 0)
	end_row := min(total_rows, state.offset + area.h)

	return Virtual_Range{
		start_row     = state.offset,
		end_row       = end_row,
		content_area  = Rect{x = area.x, y = area.y, w = content_w, h = area.h},
		has_scrollbar = has_sb,
	}
}

// -----------------------------------------------------------------------------
// Synchronized Column Sizing for Virtualized xitdb Tables
// -----------------------------------------------------------------------------

Column_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Column_Width_Kind :: enum u8 {
	Fixed,
	Percent,
	Fill,
	Auto_Content,
}

Table_Column_Spec :: struct {
	header:         string,
	kind:           Column_Width_Kind,
	value:          int, // Fixed width, Percentage (0..100), or Fill weight (>= 1)
	min_width:      int,
	max_width:      int,
	max_seen_width: int, // Monotonic high-water mark across visited xitdb rows
	align:          Column_Align,
}

Table_Column_Span :: struct {
	x:     int,
	width: int,
	align: Column_Align,
}

// Updates the monotonic high-water mark for an Auto_Content column so scrolling
// through virtualized xitdb rows never shrinks or jitters column widths.
table_column_observe_cell :: proc(spec: ^Table_Column_Spec, cell_text: string) {
	w := max(string_display_width(spec.header), string_display_width(cell_text))
	if spec.min_width > 0 {
		w = max(w, spec.min_width)
	}
	if spec.max_width > 0 {
		w = min(w, spec.max_width)
	}
	if w > spec.max_seen_width {
		spec.max_seen_width = w
	}
}

resolve_table_columns :: proc(
	specs:          []Table_Column_Spec,
	out_spans:      []Table_Column_Span,
	area:           Rect,
	gutter_width:   int = 2,
	column_spacing: int = 1,
) -> int {
	n := min(len(specs), len(out_spans))
	if n == 0 || area.w <= 0 {
		return 0
	}

	total_spacing := max(0, n - 1) * column_spacing
	avail_w := max(0, area.w - gutter_width - total_spacing)

	used_w := 0
	fill_weight_sum := 0

	// Pass 1: Allocate Fixed, Percent, and Auto_Content (high-water-mark) columns
	for i in 0 ..< n {
		spec := specs[i]
		w := 0
		switch spec.kind {
		case .Fixed:
			w = max(0, spec.value)
		case .Percent:
			pct := clamp(spec.value, 0, 100)
			w = (avail_w * pct) / 100
		case .Auto_Content:
			hdr_w := string_display_width(spec.header)
			w = max(spec.max_seen_width, hdr_w)
		case .Fill:
			w = max(0, spec.min_width)
			fill_weight_sum += max(1, spec.value)
		}

		if spec.min_width > 0 {
			w = max(w, spec.min_width)
		}
		if spec.max_width > 0 {
			w = min(w, spec.max_width)
		}

		rem := max(0, avail_w - used_w)
		w = min(w, rem)
		out_spans[i] = Table_Column_Span{
			width = w,
			align = spec.align,
		}
		used_w += w
	}

	// Pass 2: Distribute remaining space across Fill columns
	extra_w := max(0, avail_w - used_w)
	if extra_w > 0 && fill_weight_sum > 0 {
		distributed := 0
		last_fill_idx := -1
		for i in 0 ..< n {
			if specs[i].kind == .Fill {
				weight := max(1, specs[i].value)
				share := (extra_w * weight) / fill_weight_sum
				out_spans[i].width += share
				distributed += share
				last_fill_idx = i
			}
		}
		if last_fill_idx >= 0 && distributed < extra_w {
			out_spans[last_fill_idx].width += (extra_w - distributed)
		}
	}

	// Pass 3: Compute absolute X positions
	cur_x := area.x + gutter_width
	for i in 0 ..< n {
		out_spans[i].x = cur_x
		cur_x += out_spans[i].width + column_spacing
	}

	return n
}

draw_table_cell :: proc(
	s:         ^Surface,
	y:         int,
	span:      Table_Column_Span,
	text:      string,
	style:     Style,
	ellipsis:  rune = '…',
) {
	if s == nil || span.width <= 0 || y < 0 || y >= s.h {
		return
	}
	text_w := string_display_width(text)
	start_x := span.x

	if text_w <= span.width {
		pad := span.width - text_w
		switch span.align {
		case .Left:
			start_x = span.x
		case .Center:
			start_x = span.x + pad / 2
		case .Right:
			start_x = span.x + pad
		}
	}

	col := 0
	for ch in text {
		rw := rune_display_width(ch)
		if rw == 0 {
			continue
		}
		if text_w > span.width && col + rw >= span.width {
			surface_set_cell(s, span.x + span.width - 1, y, ellipsis, style, 1)
			return
		}
		if col + rw > span.width {
			break
		}
		surface_set_cell(s, start_x + col, y, ch, style, u8(rw))
		col += rw
	}
}

```

---

### 2. `bifrost/text_input.odin`

Replaces `slice_utf8_by_runes` with display-width-aware horizontal scrolling (`slice_utf8_by_display_width` and `text_input_sync_scroll`), implements grapheme-cluster cursor stepping, and supports both `Ctrl+W` (`delete_word_before_whitespace`) and `Alt+Backspace` (`delete_word_before_boundary`) plus `Ctrl+K` and `Ctrl+U`.

```odin
package bifrost

import "core:unicode"
import "core:unicode/utf8"

// -----------------------------------------------------------------------------
// Display-Width & Grapheme Cluster Utilities
// -----------------------------------------------------------------------------

is_zero_width_rune :: proc(r: rune) -> bool {
	if r < 0x20 || (r >= 0x7F && r < 0xA0) {
		return true // Control characters
	}
	switch r {
	case 0x200B ..= 0x200F, // ZWSP, ZWNJ, ZWJ, LRM, RLM
	     0xFE00 ..= 0xFE0F, // Variation Selectors (VS1..VS16)
	     0xE0100 ..= 0xE01EF, // Variation Selectors Supplement
	     0xFEFF: // BOM / ZWNBSP
		return true
	}
	// Combining Diacritical Marks & Halfwidth Katakana Voiced Sound Marks (U+3099, U+309A)
	if (r >= 0x0300 && r <= 0x036F) ||
	   (r >= 0x1AB0 && r <= 0x1AFF) ||
	   (r >= 0x1DC0 && r <= 0x1DFF) ||
	   (r >= 0x20D0 && r <= 0x20FF) ||
	   (r >= 0x3099 && r <= 0x309A) ||
	   (r >= 0xFE20 && r <= 0xFE2F) {
		return true
	}
	return false
}

is_wide_rune :: proc(r: rune) -> bool {
	return (r >= 0x1100 && r <= 0x115F) || // Hangul Jamo
	       r == 0x2329 || r == 0x232A ||
	       (r >= 0x2E80 && r <= 0x303E) || // CJK Radicals / Symbols
	       (r >= 0x3040 && r <= 0x3247 && r != 0x3099 && r != 0x309A) || // Hiragana, Katakana
	       (r >= 0x3250 && r <= 0x4DBF) || // CJK Extension A
	       (r >= 0x4E00 && r <= 0xA4C6) || // CJK Unified Ideographs
	       (r >= 0xA960 && r <= 0xA97C) ||
	       (r >= 0xAC00 && r <= 0xD7A3) || // Hangul Syllables
	       (r >= 0xF900 && r <= 0xFAFF) || // CJK Compatibility Ideographs
	       (r >= 0xFE10 && r <= 0xFE19) ||
	       (r >= 0xFE30 && r <= 0xFE6B) ||
	       (r >= 0xFF01 && r <= 0xFF60) || // Fullwidth Forms
	       (r >= 0xFFE0 && r <= 0xFFE6) ||
	       (r >= 0x1F300 && r <= 0x1F9FF) || // Emoji & Pictographs
	       (r >= 0x20000 && r <= 0x3FFFD) // CJK Extensions B..G
}

rune_display_width :: proc(r: rune) -> int {
	if is_zero_width_rune(r) {
		return 0
	}
	if is_wide_rune(r) {
		return 2
	}
	return 1
}

// Advances one grapheme cluster forward from `byte_pos`, keeping ZWJ sequences
// (e.g. "👩‍🚀"), VS16 emoji presentation (U+FE0F), and combining marks together.
next_grapheme_cluster :: proc(s: string, byte_pos: int) -> (next_pos: int, cell_width: int, lead_rune: rune) {
	if byte_pos >= len(s) {
		return len(s), 0, utf8.RUNE_ERROR
	}
	r, r_len := utf8.decode_rune_in_string(s[byte_pos:])
	lead_rune = r
	cur := byte_pos + r_len
	w := rune_display_width(r)

	for cur < len(s) {
		nr, nr_len := utf8.decode_rune_in_string(s[cur:])
		if nr == 0x200D { // Zero-Width Joiner: glue next base codepoint into this cluster
			cur += nr_len
			if cur < len(s) {
				jr, jr_len := utf8.decode_rune_in_string(s[cur:])
				w = max(w, rune_display_width(jr))
				cur += jr_len
			}
			continue
		}
		if nr == 0xFE0F { // Emoji presentation selector forces cluster width to 2
			w = max(w, 2)
			cur += nr_len
			continue
		}
		if nr == 0xFF9E || nr == 0xFF9F { // Halfwidth dakuten/handakuten (2 cells total)
			w = 2
			cur += nr_len
			continue
		}
		if is_zero_width_rune(nr) {
			cur += nr_len
			continue
		}
		break
	}
	return cur, w, lead_rune
}

prev_grapheme_cluster :: proc(s: string, byte_pos: int) -> (prev_pos: int, cell_width: int) {
	if byte_pos <= 0 {
		return 0, 0
	}
	target := min(byte_pos, len(s))
	cur := 0
	last_start := 0
	last_w := 0
	for cur < target {
		last_start = cur
		cur, last_w, _ = next_grapheme_cluster(s, cur)
	}
	return last_start, last_w
}

string_display_width :: proc(s: string) -> int {
	total := 0
	cur := 0
	for cur < len(s) {
		next_cur, w, _ := next_grapheme_cluster(s, cur)
		total += w
		cur = next_cur
	}
	return total
}

// Display-width-aware replacement for `slice_utf8_by_runes`.
// Returns the byte slice fitting `[start_col, start_col + max_cols)` plus leading/trailing
// padding spaces (`lead_pad`, `trail_pad`) when a 2-column CJK/emoji rune straddles a boundary.
Visible_Utf8_Slice :: struct {
	text:         string,
	lead_pad:     int,
	trail_pad:    int,
	clipped_left: bool,
	clipped_right: bool,
}

slice_utf8_by_display_width :: proc(s: string, start_col, max_cols: int) -> Visible_Utf8_Slice {
	if max_cols <= 0 || len(s) == 0 {
		return {}
	}
	end_col := start_col + max_cols
	col := 0
	cur := 0
	byte_start := len(s)
	byte_end := len(s)
	started := false
	lead_pad := 0
	trail_pad := 0
	clipped_right := false

	for cur < len(s) {
		next_cur, w, _ := next_grapheme_cluster(s, cur)
		next_col := col + w

		if !started {
			if next_col > start_col {
				started = true
				if col < start_col {
					// A 2-column CJK/emoji character straddled start_col: skip it and pad 1 space
					byte_start = next_cur
					lead_pad = next_col - start_col
				} else {
					byte_start = cur
				}
			}
		}

		if started && cur >= byte_start {
			if next_col > end_col {
				byte_end = cur
				trail_pad = max(0, end_col - col)
				clipped_right = true
				break
			}
			byte_end = next_cur
		}

		col = next_col
		cur = next_cur
	}

	if !started {
		return Visible_Utf8_Slice{clipped_left = start_col > 0}
	}

	return Visible_Utf8_Slice{
		text          = s[byte_start:byte_end],
		lead_pad      = lead_pad,
		trail_pad     = trail_pad,
		clipped_left  = start_col > 0,
		clipped_right = clipped_right || (byte_end < len(s)),
	}
}

// -----------------------------------------------------------------------------
// Word Boundary Predicates (Readline & libvaxis TextField.zig semantics)
// -----------------------------------------------------------------------------

is_word_rune :: proc(r: rune) -> bool {
	if r == '_' {
		return true
	}
	return unicode.is_letter(r) || unicode.is_number(r)
}

is_whitespace_rune :: proc(r: rune) -> bool {
	switch r {
	case ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0x00A0, 0x3000:
		return true
	}
	return unicode.is_white_space(r)
}

// -----------------------------------------------------------------------------
// Single-Line Text_Input Widget
// -----------------------------------------------------------------------------

Text_Input :: struct {
	buf:        [dynamic]u8,
	cursor:     int, // Byte offset in `buf` (always grapheme-aligned)
	scroll_col: int, // Horizontal viewport offset in terminal display columns
}

text_input_init :: proc(allocator := context.allocator) -> Text_Input {
	return Text_Input{
		buf = make([dynamic]u8, 0, 128, allocator),
	}
}

text_input_destroy :: proc(ti: ^Text_Input) {
	delete(ti.buf)
	ti^ = {}
}

text_input_string :: proc(ti: ^Text_Input) -> string {
	return string(ti.buf[:])
}

text_input_clear :: proc(ti: ^Text_Input) {
	clear(&ti.buf)
	ti.cursor = 0
	ti.scroll_col = 0
}

text_input_insert_string :: proc(ti: ^Text_Input, text: string) {
	if len(text) == 0 {
		return
	}
	ti.cursor = clamp(ti.cursor, 0, len(ti.buf))
	inject_at_elems(&ti.buf, ti.cursor, ..transmute([]u8)text)
	ti.cursor += len(text)
}

text_input_insert_rune :: proc(ti: ^Text_Input, r: rune) {
	if r < 0x20 || r == 0x7F {
		return
	}
	encoded, n := utf8.encode_rune(r)
	text_input_insert_string(ti, string(encoded[:n]))
}

text_input_move_left :: proc(ti: ^Text_Input) {
	s := text_input_string(ti)
	ti.cursor, _ = prev_grapheme_cluster(s, ti.cursor)
}

text_input_move_right :: proc(ti: ^Text_Input) {
	s := text_input_string(ti)
	ti.cursor, _, _ = next_grapheme_cluster(s, ti.cursor)
}

text_input_move_home :: proc(ti: ^Text_Input) {
	ti.cursor = 0
}

text_input_move_end :: proc(ti: ^Text_Input) {
	ti.cursor = len(ti.buf)
}

text_input_backspace :: proc(ti: ^Text_Input) {
	if ti.cursor <= 0 {
		return
	}
	s := text_input_string(ti)
	prev_pos, _ := prev_grapheme_cluster(s, ti.cursor)
	remove_range(&ti.buf, prev_pos, ti.cursor)
	ti.cursor = prev_pos
}

text_input_delete :: proc(ti: ^Text_Input) {
	if ti.cursor >= len(ti.buf) {
		return
	}
	s := text_input_string(ti)
	next_pos, _, _ := next_grapheme_cluster(s, ti.cursor)
	remove_range(&ti.buf, ti.cursor, next_pos)
}

// Ctrl+K: Kill from cursor to end of line
text_input_kill_to_end :: proc(ti: ^Text_Input) {
	if ti.cursor < len(ti.buf) {
		resize(&ti.buf, ti.cursor)
	}
}

// Ctrl+U: Kill from start of line to cursor
text_input_kill_to_start :: proc(ti: ^Text_Input) {
	if ti.cursor > 0 {
		remove_range(&ti.buf, 0, ti.cursor)
		ti.cursor = 0
		ti.scroll_col = 0
	}
}

// Alt+B / Alt+Left: Move backward by character-class word boundary
text_input_move_word_left :: proc(ti: ^Text_Input) {
	s := text_input_string(ti)
	i := clamp(ti.cursor, 0, len(s))
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:i])
		if is_word_rune(r) {
			break
		}
		i -= w
	}
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:i])
		if !is_word_rune(r) {
			break
		}
		i -= w
	}
	ti.cursor = i
}

// Alt+F / Alt+Right: Move forward by character-class word boundary
text_input_move_word_right :: proc(ti: ^Text_Input) {
	s := text_input_string(ti)
	i := clamp(ti.cursor, 0, len(s))
	for i < len(s) {
		r, w := utf8.decode_rune_in_string(s[i:])
		if is_word_rune(r) {
			break
		}
		i += w
	}
	for i < len(s) {
		r, w := utf8.decode_rune_in_string(s[i:])
		if !is_word_rune(r) {
			break
		}
		i += w
	}
	ti.cursor = i
}

// Alt+Backspace: Delete previous word stopping at punctuation boundaries ("hello-world" -> "hello-")
text_input_delete_word_boundary :: proc(ti: ^Text_Input) {
	old_cursor := ti.cursor
	text_input_move_word_left(ti)
	if ti.cursor < old_cursor {
		remove_range(&ti.buf, ti.cursor, old_cursor)
	}
}

// Ctrl+W: Readline unix-word-rubout (deletes whitespace-delimited word: "hello-world foo.bar" -> "hello-world ")
text_input_delete_word_whitespace :: proc(ti: ^Text_Input) {
	s := text_input_string(ti)
	i := clamp(ti.cursor, 0, len(s))
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:i])
		if !is_whitespace_rune(r) {
			break
		}
		i -= w
	}
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:i])
		if is_whitespace_rune(r) {
			break
		}
		i -= w
	}
	if i < ti.cursor {
		remove_range(&ti.buf, i, ti.cursor)
		ti.cursor = i
	}
}

// Alt+D: Delete word after cursor
text_input_delete_word_after :: proc(ti: ^Text_Input) {
	old_cursor := ti.cursor
	text_input_move_word_right(ti)
	end_cursor := ti.cursor
	ti.cursor = old_cursor
	if end_cursor > old_cursor {
		remove_range(&ti.buf, old_cursor, end_cursor)
	}
}

// Synchronizes `ti.scroll_col` with the display width of text before the cursor
text_input_sync_scroll :: proc(ti: ^Text_Input, viewport_width: int) -> int {
	if viewport_width <= 0 {
		ti.scroll_col = 0
		return 0
	}
	s := text_input_string(ti)
	cursor_col := string_display_width(s[:clamp(ti.cursor, 0, len(s))])

	// Reserve 1 cell at the right edge for the cursor block when at end of text
	usable_w := max(1, viewport_width - 1)
	if cursor_col < ti.scroll_col {
		ti.scroll_col = cursor_col
	} else if cursor_col >= ti.scroll_col + usable_w {
		ti.scroll_col = cursor_col - usable_w + 1
	}
	return cursor_col - ti.scroll_col
}

draw_text_input :: proc(
	s:           ^Surface,
	area:        Rect,
	ti:          ^Text_Input,
	style:       Style,
	placeholder: string = "",
	ph_style:    Style = {},
	focused:     bool = true,
) {
	if s == nil || area.w <= 0 || area.h <= 0 {
		return
	}
	surface_fill_rect(s, Rect{area.x, area.y, area.w, 1}, ' ', style)

	full_text := text_input_string(ti)
	if len(full_text) == 0 && len(placeholder) > 0 {
		vis := slice_utf8_by_display_width(placeholder, 0, area.w)
		col := 0
		for ch in vis.text {
			rw := rune_display_width(ch)
			if rw > 0 && col + rw <= area.w {
				surface_set_cell(s, area.x + col, area.y, ch, ph_style, u8(rw))
				col += rw
			}
		}
		if focused {
			s.cursor_x = area.x
			s.cursor_y = area.y
		}
		return
	}

	rel_cursor_col := text_input_sync_scroll(ti, area.w)
	vis := slice_utf8_by_display_width(full_text, ti.scroll_col, area.w)

	col := vis.lead_pad
	cur := 0
	for cur < len(vis.text) {
		next_cur, gw, lead_r := next_grapheme_cluster(vis.text, cur)
		if gw > 0 && col + gw <= area.w {
			surface_set_cell(s, area.x + col, area.y, lead_r, style, u8(gw))
			col += gw
		}
		cur = next_cur
	}

	// Safe left/right overflow indicators without clobbering 2-column glyphs
	if vis.clipped_left && area.w >= 2 {
		// If cell 0 held the left half of a 2-col glyph, clear cell 1 so it isn't orphaned
		if s.cells[area.y * s.w + area.x].width == 2 {
			surface_set_cell(s, area.x + 1, area.y, ' ', style, 1)
		}
		surface_set_cell(s, area.x, area.y, '…', style, 1)
	}
	if vis.clipped_right && area.w >= 2 {
		last_x := area.x + area.w - 1
		// If cell (last_x - 1) started a 2-col glyph covering last_x, clear (last_x - 1)
		if s.cells[area.y * s.w + last_x - 1].width == 2 {
			surface_set_cell(s, last_x - 1, area.y, ' ', style, 1)
		}
		surface_set_cell(s, last_x, area.y, '…', style, 1)
	}

	if focused {
		s.cursor_x = area.x + clamp(rel_cursor_col, 0, area.w - 1)
		s.cursor_y = area.y
	}
}

```

---

### 3. `bifrost/splitter_keymap.odin`

Combines Lip Gloss border presets (`borders.go`), Ratatui box-drawing junction merging (`Cell::merge_symbol` in `cell.rs`) for clean split-pane dividers, and a declarative `Keymap` dispatcher that routes editing keys directly to `Text_Input`.

```odin
package bifrost

// -----------------------------------------------------------------------------
// Lip Gloss Border Presets & Box-Drawing Junction Merging
// -----------------------------------------------------------------------------

Border_Spec :: struct {
	top:           rune,
	bottom:        rune,
	left:          rune,
	right:         rune,
	top_left:      rune,
	top_right:     rune,
	bottom_left:   rune,
	bottom_right:  rune,
	middle_left:   rune,
	middle_right:  rune,
	middle:        rune,
	middle_top:    rune,
	middle_bottom: rune,
}

NORMAL_BORDER :: Border_Spec{
	top = '─', bottom = '─', left = '│', right = '│',
	top_left = '┌', top_right = '┐', bottom_left = '└', bottom_right = '┘',
	middle_left = '├', middle_right = '┤', middle = '┼',
	middle_top = '┬', middle_bottom = '┴',
}

ROUNDED_BORDER :: Border_Spec{
	top = '─', bottom = '─', left = '│', right = '│',
	top_left = '╭', top_right = '╮', bottom_left = '╰', bottom_right = '╯',
	middle_left = '├', middle_right = '┤', middle = '┼',
	middle_top = '┬', middle_bottom = '┴',
}

THICK_BORDER :: Border_Spec{
	top = '━', bottom = '━', left = '┃', right = '┃',
	top_left = '┏', top_right = '┓', bottom_left = '┗', bottom_right = '┛',
	middle_left = '┣', middle_right = '┫', middle = '╋',
	middle_top = '┳', middle_bottom = '┻',
}

DOUBLE_BORDER :: Border_Spec{
	top = '═', bottom = '═', left = '║', right = '║',
	top_left = '╔', top_right = '╗', bottom_left = '╚', bottom_right = '╝',
	middle_left = '╠', middle_right = '╣', middle = '╬',
	middle_top = '╦', middle_bottom = '╩',
}

Box_Dir :: enum u8 { Up, Right, Down, Left }
Box_Dirs :: bit_set[Box_Dir; u8]

box_rune_dirs :: proc(r: rune) -> Box_Dirs {
	switch r {
	case '─', '━', '═': return {.Left, .Right}
	case '│', '┃', '║': return {.Up, .Down}
	case '┌', '╭', '┏', '╔': return {.Right, .Down}
	case '┐', '╮', '┓', '╗': return {.Left, .Down}
	case '└', '╰', '┗', '╚': return {.Up, .Right}
	case '┘', '╯', '┛', '╝': return {.Up, .Left}
	case '├', '┣', '╠': return {.Up, .Down, .Right}
	case '┤', '┫', '╣': return {.Up, .Down, .Left}
	case '┬', '┳', '╦': return {.Left, .Right, .Down}
	case '┴', '┻', '╩': return {.Left, .Right, .Up}
	case '┼', '╋', '╬': return {.Up, .Right, .Down, .Left}
	}
	return {}
}

dirs_to_box_rune :: proc(dirs: Box_Dirs, b: Border_Spec) -> rune {
	switch dirs {
	case {.Left, .Right}:             return b.top
	case {.Up, .Down}:                return b.left
	case {.Right, .Down}:             return b.top_left
	case {.Left, .Down}:              return b.top_right
	case {.Up, .Right}:               return b.bottom_left
	case {.Up, .Left}:                return b.bottom_right
	case {.Up, .Down, .Right}:        return b.middle_left
	case {.Up, .Down, .Left}:         return b.middle_right
	case {.Left, .Right, .Down}:      return b.middle_top
	case {.Left, .Right, .Up}:        return b.middle_bottom
	case {.Up, .Right, .Down, .Left}: return b.middle
	}
	return b.middle
}

// Collapses adjacent box-drawing characters (matching ratatui Cell::merge_symbol)
surface_merge_box_cell :: proc(s: ^Surface, x, y: int, ch: rune, b: Border_Spec, style: Style) {
	if s == nil || x < 0 || y < 0 || x >= s.w || y >= s.h {
		return
	}
	existing := s.cells[y * s.w + x].ch
	merged_dirs := box_rune_dirs(existing) + box_rune_dirs(ch)
	final_ch := dirs_to_box_rune(merged_dirs, b) if card(merged_dirs) > 0 else ch
	surface_set_cell(s, x, y, final_ch, style, 1)
}

draw_border_box :: proc(s: ^Surface, r: Rect, b: Border_Spec, style: Style, title: string = "") -> Rect {
	if s == nil || r.w < 2 || r.h < 2 {
		return r
	}
	x0, y0 := r.x, r.y
	x1, y1 := r.x + r.w - 1, r.y + r.h - 1

	surface_merge_box_cell(s, x0, y0, b.top_left, b, style)
	surface_merge_box_cell(s, x1, y0, b.top_right, b, style)
	surface_merge_box_cell(s, x0, y1, b.bottom_left, b, style)
	surface_merge_box_cell(s, x1, y1, b.bottom_right, b, style)

	for x in (x0 + 1) ..< x1 {
		surface_merge_box_cell(s, x, y0, b.top, b, style)
		surface_merge_box_cell(s, x, y1, b.bottom, b, style)
	}
	for y in (y0 + 1) ..< y1 {
		surface_merge_box_cell(s, x0, y, b.left, b, style)
		surface_merge_box_cell(s, x1, y, b.right, b, style)
	}

	if len(title) > 0 && r.w > 4 {
		vis := slice_utf8_by_display_width(title, 0, r.w - 4)
		col := 0
		for ch in vis.text {
			rw := rune_display_width(ch)
			if rw > 0 && col + rw <= r.w - 4 {
				surface_set_cell(s, x0 + 2 + col, y0, ch, style, u8(rw))
				col += rw
			}
		}
	}

	return Rect{x = r.x + 1, y = r.y + 1, w = r.w - 2, h = r.h - 2}
}

// -----------------------------------------------------------------------------
// Splitter Layout & Divider Rendering
// -----------------------------------------------------------------------------

Split_Axis :: enum u8 {
	Horizontal, // Left | Right panes
	Vertical,   // Top / Bottom panes
}

Splitter_State :: struct {
	axis:        Split_Axis,
	ratio_permil: int, // 0..1000 (e.g. 500 = 50%)
	min_first:   int,
	min_second:  int,
	focused_idx: int, // 0 or 1
}

splitter_adjust :: proc(sp: ^Splitter_State, delta_permil: int) {
	sp.ratio_permil = clamp(sp.ratio_permil + delta_permil, 100, 900)
}

splitter_toggle_focus :: proc(sp: ^Splitter_State) {
	sp.focused_idx = 1 - (sp.focused_idx & 1)
}

split_rect :: proc(
	s:            ^Surface,
	area:         Rect,
	sp:           Splitter_State,
	border:       Border_Spec,
	divider_style: Style,
) -> (first: Rect, second: Rect) {
	ratio := sp.ratio_permil if sp.ratio_permil > 0 else 500
	switch sp.axis {
	case .Horizontal:
		avail := max(0, area.w - 1)
		w1 := (avail * ratio) / 1000
		w1 = clamp(w1, sp.min_first, max(sp.min_first, avail - sp.min_second))
		w2 := max(0, avail - w1)
		div_x := area.x + w1
		if s != nil && area.w >= 3 {
			for y in area.y ..< (area.y + area.h) {
				surface_merge_box_cell(s, div_x, y, border.left, border, divider_style)
			}
		}
		first  = Rect{x = area.x, y = area.y, w = w1, h = area.h}
		second = Rect{x = div_x + 1, y = area.y, w = w2, h = area.h}
	case .Vertical:
		avail := max(0, area.h - 1)
		h1 := (avail * ratio) / 1000
		h1 = clamp(h1, sp.min_first, max(sp.min_first, avail - sp.min_second))
		h2 := max(0, avail - h1)
		div_y := area.y + h1
		if s != nil && area.h >= 3 {
			for x in area.x ..< (area.x + area.w) {
				surface_merge_box_cell(s, x, div_y, border.top, border, divider_style)
			}
		}
		first  = Rect{x = area.x, y = area.y, w = area.w, h = h1}
		second = Rect{x = area.x, y = div_y + 1, w = area.w, h = h2}
	}
	return first, second
}

// -----------------------------------------------------------------------------
// Key Events & Declarative Keymap
// -----------------------------------------------------------------------------

Key_Code :: enum u8 {
	None,
	Rune,
	Enter,
	Escape,
	Backspace,
	Delete,
	Tab,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
}

Key_Mod :: enum u8 { Ctrl, Alt, Shift }
Key_Mods :: bit_set[Key_Mod; u8]

Key_Event :: struct {
	code: Key_Code,
	ch:   rune,
	mods: Key_Mods,
}

Key_Binding :: struct {
	id:       int,
	event:    Key_Event,
	key_hint: string,
	desc:     string,
}

keymap_match :: proc(bindings: []Key_Binding, ev: Key_Event) -> (id: int, matched: bool) {
	for b in bindings {
		if b.event.code == ev.code && b.event.mods == ev.mods {
			if b.event.code != .Rune || b.event.ch == ev.ch {
				return b.id, true
			}
		}
	}
	return 0, false
}

// Routes standard Readline / libvaxis TextField key events into a Text_Input
text_input_handle_key :: proc(ti: ^Text_Input, ev: Key_Event) -> (handled: bool, changed: bool) {
	#partial switch ev.code {
	case .Backspace:
		if .Alt in ev.mods {
			text_input_delete_word_boundary(ti)
		} else {
			text_input_backspace(ti)
		}
		return true, true
	case .Delete:
		text_input_delete(ti)
		return true, true
	case .Left:
		if .Alt in ev.mods || .Ctrl in ev.mods {
			text_input_move_word_left(ti)
		} else {
			text_input_move_left(ti)
		}
		return true, false
	case .Right:
		if .Alt in ev.mods || .Ctrl in ev.mods {
			text_input_move_word_right(ti)
		} else {
			text_input_move_right(ti)
		}
		return true, false
	case .Home:
		text_input_move_home(ti)
		return true, false
	case .End:
		text_input_move_end(ti)
		return true, false
	case .Rune:
		if ev.mods == {.Ctrl} {
			switch ev.ch {
			case 'a': text_input_move_home(ti);              return true, false
			case 'e': text_input_move_end(ti);               return true, false
			case 'b': text_input_move_left(ti);              return true, false
			case 'f': text_input_move_right(ti);             return true, false
			case 'd': text_input_delete(ti);                 return true, true
			case 'k': text_input_kill_to_end(ti);            return true, true
			case 'u': text_input_kill_to_start(ti);          return true, true
			case 'w': text_input_delete_word_whitespace(ti); return true, true
			}
		} else if ev.mods == {.Alt} {
			switch ev.ch {
			case 'b': text_input_move_word_left(ti);  return true, false
			case 'f': text_input_move_word_right(ti); return true, false
			case 'd': text_input_delete_word_after(ti); return true, true
			}
		} else if ev.mods == {} || ev.mods == {.Shift} {
			text_input_insert_rune(ti, ev.ch)
			return true, true
		}
	}
	return false, false
}

```

---

### 4. `bifrost/command_palette.odin`

Combines `Text_Input`, fuzzy subsequence scoring with word-boundary bonuses, `Scroll_State` + `draw_vertical_scrollbar`, and `resolve_table_columns` to align command titles on the left and shortcut hints on the right.

```odin
package bifrost

import "core:slice"
import "core:unicode"
import "core:unicode/utf8"

Command_Item :: struct {
	id:       int,
	title:    string,
	category: string,
	shortcut: string,
}

Scored_Command :: struct {
	item_idx: int,
	score:    int,
}

Command_Palette :: struct {
	visible:  bool,
	input:    Text_Input,
	scroll:   Scroll_State,
	items:    []Command_Item,
	filtered: [dynamic]Scored_Command,
}

command_palette_init :: proc(items: []Command_Item, allocator := context.allocator) -> Command_Palette {
	cp := Command_Palette{
		input    = text_input_init(allocator),
		items    = items,
		filtered = make([dynamic]Scored_Command, 0, len(items), allocator),
		scroll   = Scroll_State{scroll_padding = 1, wheel_step = 3},
	}
	command_palette_refilter(&cp)
	return cp
}

command_palette_destroy :: proc(cp: ^Command_Palette) {
	text_input_destroy(&cp.input)
	delete(cp.filtered)
	cp^ = {}
}

// Fuzzy subsequence scorer with word-start and consecutive-match bonuses
fuzzy_score :: proc(query, candidate: string) -> (score: int, matched: bool) {
	if len(query) == 0 {
		return 1, true
	}
	q_pos := 0
	c_pos := 0
	prev_matched := false
	prev_sep := true
	total := 0

	for q_pos < len(query) {
		qr, qw := utf8.decode_rune_in_string(query[q_pos:])
		if is_whitespace_rune(qr) {
			q_pos += qw
			continue
		}
		qr_low := unicode.to_lower(qr)
		found := false

		for c_pos < len(candidate) {
			cr, cw := utf8.decode_rune_in_string(candidate[c_pos:])
			c_pos += cw
			if unicode.to_lower(cr) == qr_low {
				total += 10
				if prev_sep {
					total += 15 // Word-boundary bonus
				}
				if prev_matched {
					total += 12 // Consecutive character bonus
				}
				prev_matched = true
				prev_sep = !is_word_rune(cr)
				found = true
				break
			}
			prev_matched = false
			prev_sep = !is_word_rune(cr)
		}

		if !found {
			return 0, false
		}
		q_pos += qw
	}

	return total, true
}

command_palette_refilter :: proc(cp: ^Command_Palette) {
	clear(&cp.filtered)
	q := text_input_string(&cp.input)

	for item, idx in cp.items {
		sc, ok := fuzzy_score(q, item.title)
		if !ok && len(item.category) > 0 {
			sc, ok = fuzzy_score(q, item.category)
		}
		if ok {
			append(&cp.filtered, Scored_Command{item_idx = idx, score = sc})
		}
	}

	if len(q) > 0 {
		slice.sort_by(cp.filtered[:], proc(a, b: Scored_Command) -> bool {
			if a.score != b.score {
				return a.score > b.score
			}
			return a.item_idx < b.item_idx
		})
	}
	cp.scroll.cursor = 0
	cp.scroll.offset = 0
}

Command_Palette_Result :: enum u8 {
	None,
	Consumed,
	Submitted,
	Dismissed,
}

command_palette_handle_key :: proc(
	cp:            ^Command_Palette,
	ev:            Key_Event,
	viewport_rows: int = 8,
) -> (res: Command_Palette_Result, selected_id: int) {
	if !cp.visible {
		return .None, 0
	}

	#partial switch ev.code {
	case .Escape:
		cp.visible = false
		return .Dismissed, 0
	case .Enter:
		if len(cp.filtered) > 0 && cp.scroll.cursor < len(cp.filtered) {
			idx := cp.filtered[cp.scroll.cursor].item_idx
			cp.visible = false
			return .Submitted, cp.items[idx].id
		}
		return .Consumed, 0
	case .Up:
		scroll_move_cursor(&cp.scroll, -1, len(cp.filtered), viewport_rows)
		return .Consumed, 0
	case .Down:
		scroll_move_cursor(&cp.scroll, 1, len(cp.filtered), viewport_rows)
		return .Consumed, 0
	case .Rune:
		if ev.mods == {.Ctrl} {
			switch ev.ch {
			case 'n':
				scroll_move_cursor(&cp.scroll, 1, len(cp.filtered), viewport_rows)
				return .Consumed, 0
			case 'p':
				scroll_move_cursor(&cp.scroll, -1, len(cp.filtered), viewport_rows)
				return .Consumed, 0
			}
		}
	}

	handled, changed := text_input_handle_key(&cp.input, ev)
	if changed {
		command_palette_refilter(cp)
	}
	if handled {
		return .Consumed, 0
	}
	return .None, 0
}

draw_command_palette :: proc(
	s:            ^Surface,
	screen_area:  Rect,
	cp:           ^Command_Palette,
	base_style:   Style,
	border_style: Style,
	sel_style:    Style,
	hint_style:   Style,
) {
	if s == nil || !cp.visible || screen_area.w < 16 || screen_area.h < 6 {
		return
	}

	box_w := clamp((screen_area.w * 60) / 100, 24, screen_area.w - 2)
	box_h := clamp(len(cp.filtered) + 4, 5, min(14, screen_area.h - 2))
	box_rect := Rect{
		x = screen_area.x + (screen_area.w - box_w) / 2,
		y = screen_area.y + max(1, (screen_area.h - box_h) / 4),
		w = box_w,
		h = box_h,
	}

	surface_fill_rect(s, box_rect, ' ', base_style)
	inner := draw_border_box(s, box_rect, ROUNDED_BORDER, border_style, " Command Palette ")

	// Row 0: Prompt + Text_Input
	surface_set_cell(s, inner.x, inner.y, '>', border_style, 1)
	input_area := Rect{x = inner.x + 2, y = inner.y, w = max(1, inner.w - 2), h = 1}
	draw_text_input(s, input_area, &cp.input, base_style, "Type a command…", hint_style, true)

	// Row 1: Horizontal separator with merged T-junctions on the outer border
	sep_y := inner.y + 1
	surface_merge_box_cell(s, box_rect.x, sep_y, ROUNDED_BORDER.middle_left, ROUNDED_BORDER, border_style)
	surface_merge_box_cell(s, box_rect.x + box_rect.w - 1, sep_y, ROUNDED_BORDER.middle_right, ROUNDED_BORDER, border_style)
	for x in inner.x ..< (inner.x + inner.w) {
		surface_merge_box_cell(s, x, sep_y, ROUNDED_BORDER.top, ROUNDED_BORDER, border_style)
	}

	// Rows 2..N: Virtualized 2-column command list + proportional scrollbar
	list_area := Rect{x = inner.x, y = inner.y + 2, w = inner.w, h = max(0, inner.h - 2)}
	vrange := begin_virtual_list(&cp.scroll, list_area, len(cp.filtered))

	col_specs := [2]Table_Column_Spec{
		{header = "Command",  kind = .Fill,  value = 1,  min_width = 8, align = .Left},
		{header = "Shortcut", kind = .Fixed, value = 12, min_width = 4, align = .Right},
	}
	col_spans: [2]Table_Column_Span
	resolve_table_columns(col_specs[:], col_spans[:], vrange.content_area, gutter_width = 2, column_spacing = 1)

	for row_idx in vrange.start_row ..< vrange.end_row {
		y := vrange.content_area.y + (row_idx - vrange.start_row)
		is_sel := row_idx == cp.scroll.cursor
		row_st := sel_style if is_sel else base_style
		sc_st := sel_style if is_sel else hint_style

		surface_fill_rect(s, Rect{vrange.content_area.x, y, vrange.content_area.w, 1}, ' ', row_st)
		if is_sel {
			surface_set_cell(s, vrange.content_area.x, y, '▐', sel_style, 1)
		}

		item := cp.items[cp.filtered[row_idx].item_idx]
		draw_table_cell(s, y, col_spans[0], item.title, row_st)
		draw_table_cell(s, y, col_spans[1], item.shortcut, sc_st)
	}

	if vrange.has_scrollbar {
		draw_vertical_scrollbar(
			s,
			list_area,
			len(cp.filtered),
			list_area.h,
			cp.scroll.offset,
			border_style,
			sel_style,
		)
	}
}

```



`bifrost/track3_test.odin` is a self-contained `@(test)` suite designed to compile alongside `scroll.odin`, `text_input.odin`, `splitter_keymap.odin`, and `command_palette.odin`. Run it with:

```sh
odin test bifrost -vet -strict-style -vet-tabs -disallow-do

```

### `bifrost/track3_test.odin`

```odin
package bifrost

import "core:testing"

@(test)
test_cjk_and_emoji_grapheme_navigation_and_width :: proc(t: ^testing.T) {
	// 1. Display width calculations across ASCII, CJK, ZWJ emoji, VS16 emoji, and halfwidth dakuten
	testing.expect_value(t, string_display_width("hello"), 5)
	testing.expect_value(t, string_display_width("称号コン"), 8)
	testing.expect_value(t, string_display_width("👩‍🚀"), 2)
	testing.expect_value(t, string_display_width("⌨️"), 2)
	testing.expect_value(t, string_display_width("ｶﾞｷﾞ"), 4)
	testing.expect_value(t, string_display_width("a🦀b"), 4)

	// 2. Grapheme-aligned cursor movement and backspace over multi-codepoint clusters
	ti := text_input_init()
	defer text_input_destroy(&ti)

	text_input_insert_string(&ti, "a👩‍🚀⌨️称b")
	// Total display width: 'a'(1) + '👩‍🚀'(2) + '⌨️'(2) + '称'(2) + 'b'(1) = 8 cells
	testing.expect_value(t, string_display_width(text_input_string(&ti)), 8)

	// Step left across 'b' (1 byte)
	text_input_move_left(&ti)
	testing.expect_value(t, text_input_string(&ti)[:ti.cursor], "a👩‍🚀⌨️称")

	// Step left across '称' (3 bytes)
	text_input_move_left(&ti)
	testing.expect_value(t, text_input_string(&ti)[:ti.cursor], "a👩‍🚀⌨️")

	// Step left across '⌨️' (base U+2328 + VS16 U+FE0F = 6 bytes) in a single keystroke
	text_input_move_left(&ti)
	testing.expect_value(t, text_input_string(&ti)[:ti.cursor], "a👩‍🚀")

	// Backspace deletes the entire 11-byte ZWJ astronaut cluster "👩‍🚀" at once
	text_input_backspace(&ti)
	testing.expect_value(t, text_input_string(&ti), "a⌨️称b")
	testing.expect_value(t, ti.cursor, 1)

	// Delete removes the entire 6-byte VS16 keyboard cluster "⌨️" after cursor
	text_input_delete(&ti)
	testing.expect_value(t, text_input_string(&ti), "a称b")
}

@(test)
test_cjk_horizontal_scrolling_and_boundary_clipping :: proc(t: ^testing.T) {
	// 1. Slicing across 2-column CJK boundaries produces padding instead of half-glyphs
	cjk := "称号コン" // 4 wide runes = 8 display columns (cols 0..1, 2..3, 4..5, 6..7)

	// Exact alignment on 2-column boundaries: cols [2..6) -> "号コ"
	aligned := slice_utf8_by_display_width(cjk, 2, 4)
	testing.expect_value(t, aligned.text, "号コ")
	testing.expect_value(t, aligned.lead_pad, 0)
	testing.expect_value(t, aligned.trail_pad, 0)
	testing.expect_value(t, aligned.clipped_left, true)
	testing.expect_value(t, aligned.clipped_right, true)

	// Odd column slice: cols [1..6) splits '称' (0..2) on the left -> skips '称', lead_pad = 1,
	// fits "号コ" (cols 2..6), clips 'ン' on the right
	straddled := slice_utf8_by_display_width(cjk, 1, 5)
	testing.expect_value(t, straddled.text, "号コ")
	testing.expect_value(t, straddled.lead_pad, 1)
	testing.expect_value(t, straddled.trail_pad, 0)
	testing.expect_value(t, straddled.clipped_left, true)
	testing.expect_value(t, straddled.clipped_right, true)

	// Odd width at right boundary: cols [0..5) fits "称号" (4 cols), cannot fit 2-col 'コ' in 1 remaining col
	right_split := slice_utf8_by_display_width(cjk, 0, 5)
	testing.expect_value(t, right_split.text, "称号")
	testing.expect_value(t, right_split.lead_pad, 0)
	testing.expect_value(t, right_split.trail_pad, 1)
	testing.expect_value(t, right_split.clipped_left, false)
	testing.expect_value(t, right_split.clipped_right, true)

	// 2. Rendering into an 8-column Surface while scrolling across CJK runes
	cells := make([]Cell, 8)
	defer delete(cells)
	surf := Surface{
		w     = 8,
		h     = 1,
		cells = cells,
	}

	ti := text_input_init()
	defer text_input_destroy(&ti)

	text_input_insert_string(&ti, "称号コンピュータ") // 8 wide runes = 16 display columns
	draw_text_input(&surf, Rect{0, 0, 8, 1}, &ti, Style{})

	// Cursor must be clamped inside the 8-column viewport and scroll_col must be > 0
	testing.expect(t, ti.scroll_col > 0)
	testing.expect(t, surf.cursor_x >= 0 && surf.cursor_x < 8)

	// Left cell (col 0) must show '…' with width 1, and col 1 must NOT be an orphaned width-0 continuation cell
	testing.expect_value(t, surf.cells[0].ch, '…')
	testing.expect_value(t, surf.cells[0].width, u8(1))
	testing.expect(t, surf.cells[1].width != 0)
}

@(test)
test_word_deletion_ctrl_w_vs_alt_backspace_and_kills :: proc(t: ^testing.T) {
	ti := text_input_init()
	defer text_input_destroy(&ti)

	// 1. Ctrl+W (delete_word_whitespace) vs Alt+Backspace (delete_word_boundary)
	text_input_insert_string(&ti, "hello-world foo.bar")

	// Ctrl+W deletes whitespace-delimited "foo.bar" as a single token
	handled, changed := text_input_handle_key(&ti, Key_Event{code = .Rune, ch = 'w', mods = {.Ctrl}})
	testing.expect(t, handled && changed)
	testing.expect_value(t, text_input_string(&ti), "hello-world ")

	// Alt+Backspace skips trailing space and stops at hyphen boundary: "hello-world " -> "hello-"
	handled, changed = text_input_handle_key(&ti, Key_Event{code = .Backspace, mods = {.Alt}})
	testing.expect(t, handled && changed)
	testing.expect_value(t, text_input_string(&ti), "hello-")

	// Second Alt+Backspace skips '-' and deletes "hello": "hello-" -> ""
	handled, changed = text_input_handle_key(&ti, Key_Event{code = .Backspace, mods = {.Alt}})
	testing.expect(t, handled && changed)
	testing.expect_value(t, text_input_string(&ti), "")

	// 2. Unicode ideographic space (U+3000) with Ctrl+W and em-dash (U+2014) with Alt+Backspace
	text_input_insert_string(&ti, "alpha\u3000beta\u2014gamma")
	// Alt+Backspace stops at em-dash U+2014
	text_input_delete_word_boundary(&ti)
	testing.expect_value(t, text_input_string(&ti), "alpha\u3000beta\u2014")

	// Ctrl+W deletes "beta\u2014" up to ideographic space U+3000
	text_input_delete_word_whitespace(&ti)
	testing.expect_value(t, text_input_string(&ti), "alpha\u3000")

	// 3. Ctrl+K (kill to end) and Ctrl+U (kill to start)
	text_input_clear(&ti)
	text_input_insert_string(&ti, "one two three")
	// Move back 1 word ("three") -> cursor at "one two |three"
	text_input_move_word_left(&ti)
	testing.expect_value(t, text_input_string(&ti)[:ti.cursor], "one two ")

	// Ctrl+K kills "three"
	_, _ = text_input_handle_key(&ti, Key_Event{code = .Rune, ch = 'k', mods = {.Ctrl}})
	testing.expect_value(t, text_input_string(&ti), "one two ")

	// Move left 3 chars ("two ") and press Ctrl+U to kill prefix
	text_input_move_word_left(&ti)
	_, _ = text_input_handle_key(&ti, Key_Event{code = .Rune, ch = 'u', mods = {.Ctrl}})
	testing.expect_value(t, text_input_string(&ti), "two ")
	testing.expect_value(t, ti.cursor, 0)
}

@(test)
test_scrollbar_100k_rows_interior_detent_clamping :: proc(t: ^testing.T) {
	total_rows := 100_000
	viewport_rows := 20
	track_height := 20
	max_scroll := total_rows - viewport_rows // 99,980

	// 1. At scroll_offset == 0 (true top), thumb is at 0
	m_top := compute_scrollbar_metrics(track_height, total_rows, viewport_rows, 0)
	testing.expect_value(t, m_top.thumb_height, 1)
	testing.expect_value(t, m_top.thumb_offset, 0)

	// 2. At scroll_offset == 1 (1 row below top), thumb immediately leaves cell 0 -> offset 1
	m_one := compute_scrollbar_metrics(track_height, total_rows, viewport_rows, 1)
	testing.expect_value(t, m_one.thumb_offset, 1)

	// 3. At scroll_offset == max_scroll - 1 (99,979), thumb MUST NOT prematurely snap to bottom (19);
	//    it stays at track_avail - 1 (18).
	m_almost_bot := compute_scrollbar_metrics(track_height, total_rows, viewport_rows, max_scroll - 1)
	testing.expect_value(t, m_almost_bot.thumb_offset, 18)

	// 4. At scroll_offset == max_scroll (99,980), thumb reaches the final cell (19)
	m_bot := compute_scrollbar_metrics(track_height, total_rows, viewport_rows, max_scroll)
	testing.expect_value(t, m_bot.thumb_offset, 19)

	// 5. Verify rendered Surface cells at max_scroll - 1 vs max_scroll
	cells := make([]Cell, track_height)
	defer delete(cells)
	surf := Surface{
		w     = 1,
		h     = track_height,
		cells = cells,
	}

	draw_vertical_scrollbar(&surf, Rect{0, 0, 1, track_height}, total_rows, viewport_rows, max_scroll - 1, Style{}, Style{})
	testing.expect_value(t, surf.cells[18].ch, '┃')
	testing.expect_value(t, surf.cells[19].ch, '│')

	draw_vertical_scrollbar(&surf, Rect{0, 0, 1, track_height}, total_rows, viewport_rows, max_scroll, Style{}, Style{})
	testing.expect_value(t, surf.cells[18].ch, '│')
	testing.expect_value(t, surf.cells[19].ch, '┃')

	// 6. Large thumb near bottom must never overrun track_height (Ratatui #2582 edge case)
	m_large := compute_scrollbar_metrics(22, 25, 22, 3)
	testing.expect(t, m_large.thumb_offset + m_large.thumb_height <= 22)
	testing.expect_value(t, m_large.thumb_offset + m_large.thumb_height, 22)
}

@(test)
test_virtual_table_column_sizing_and_box_merging :: proc(t: ^testing.T) {
	// 1. Monotonic high-water-mark column sizing prevents horizontal jitter across xitdb pages
	specs := [3]Table_Column_Spec{
		{header = "ID",     kind = .Auto_Content, min_width = 4, max_width = 12, align = .Left},
		{header = "Name",   kind = .Fill,         value = 1,     min_width = 6,  align = .Left},
		{header = "Status", kind = .Fixed,        value = 8,                     align = .Right},
	}
	spans: [3]Table_Column_Span

	// Page 1 has short IDs ("101") -> width uses min_width (4)
	table_column_observe_cell(&specs[0], "101")
	resolve_table_columns(specs[:], spans[:], Rect{0, 0, 40, 10}, gutter_width = 2, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 4)

	// Page 2 has a wider ID ("xit-98412") -> grows to 9
	table_column_observe_cell(&specs[0], "xit-98412")
	resolve_table_columns(specs[:], spans[:], Rect{0, 0, 40, 10}, gutter_width = 2, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 9)

	// Page 3 has a short ID ("7") -> stays at 9 (no shrinkage jitter)
	table_column_observe_cell(&specs[0], "7")
	resolve_table_columns(specs[:], spans[:], Rect{0, 0, 40, 10}, gutter_width = 2, column_spacing = 1)
	testing.expect_value(t, spans[0].width, 9)

	// 2. Box-drawing junction merging on split borders
	cells := make([]Cell, 10 * 5)
	defer delete(cells)
	surf := Surface{
		w     = 10,
		h     = 5,
		cells = cells,
	}
	inner := draw_border_box(&surf, Rect{0, 0, 10, 5}, ROUNDED_BORDER, Style{})
	_, _ = split_rect(&surf, inner, Splitter_State{axis = .Horizontal, ratio_permil = 500}, ROUNDED_BORDER, Style{})

	// Divider at x = 1 + (8 * 500 / 1000) = 5; merging vertical divider with top/bottom borders if drawn on full rect
	surface_merge_box_cell(&surf, 5, 0, ROUNDED_BORDER.left, ROUNDED_BORDER, Style{})
	surface_merge_box_cell(&surf, 5, 4, ROUNDED_BORDER.left, ROUNDED_BORDER, Style{})
	testing.expect_value(t, surf.cells[0 * 10 + 5].ch, '┬')
	testing.expect_value(t, surf.cells[4 * 10 + 5].ch, '┴')
}

@(test)
test_command_palette_fuzzy_filter_and_submission :: proc(t: ^testing.T) {
	items := []Command_Item{
		{id = 10, title = "Database: Compact xitdb Store", category = "Database", shortcut = "Ctrl+Shift+C"},
		{id = 20, title = "Split: Toggle Vertical Pane",   category = "Window",   shortcut = "Ctrl+W v"},
		{id = 30, title = "Database: Inspect B-Tree Root", category = "Database", shortcut = "Ctrl+I"},
	}

	cp := command_palette_init(items)
	defer command_palette_destroy(&cp)
	cp.visible = true

	// Typing "dbbt" matches "Database: Inspect B-Tree Root"
	for ch in "dbbt" {
		res, _ := command_palette_handle_key(&cp, Key_Event{code = .Rune, ch = ch})
		testing.expect_value(t, res, Command_Palette_Result.Consumed)
	}
	testing.expect(t, len(cp.filtered) >= 1)

	// Pressing Enter submits the top-scored command (id = 30) and hides the palette
	res, sel_id := command_palette_handle_key(&cp, Key_Event{code = .Enter})
	testing.expect_value(t, res, Command_Palette_Result.Submitted)
	testing.expect_value(t, sel_id, 30)
	testing.expect_value(t, cp.visible, false)
}

```
