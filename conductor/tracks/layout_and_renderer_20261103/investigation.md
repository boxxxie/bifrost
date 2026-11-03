### 1. Wide / Multi-Column Graphemes (`libvaxis` & `notcurses` vs. `bifrost`)

#### How `libvaxis` and `notcurses` Represent and Guard Wide Cells

* **`Cell` and Width Measurement (`libvaxis`):**
* `Cell.Character` (`src/Cell.zig`) stores `grapheme: []const u8 = " "` and `width: u8 = 1`.


* `gwidth.zig` (`src/gwidth.zig`) calculates display column width via `gwidth(str, method)` across `.unicode`, `.wcwidth`, and `.no_zwj` modes. Control characters (`cp == 0`, `cp < 32`, `0x7f..0xa0`), non-spacing/enclosing marks (`.mark_nonspacing`, `.mark_enclosing`), soft hyphens (`0x00ad`), joiners (`0x200b..0x200d`, `0x2060`, `0x034f`, `0xfeff`), and variation selectors (`0x180b..0x180d`, `0xfe00..0xfe0f`, `0xe0100..0xe01ef`) return width `0` (or `-1` for C0/C1 controls).


* East Asian `.fullwidth` and `.wide` codepoints return `2`. In `.unicode` mode, grapheme clusters containing the emoji variation selector (`U+FE0F`), `is_emoji_presentation`, or a regional indicator pair (`ri_count == 2` in `0x1F1E6..0x1F1FF`) are forced to `@max(2, width)`, whereas explicit text presentation (`U+FE0E`) forces `@max(1, width)`.


* In `Window.print` (`src/Window.zig`), zero-width graphemes (`w == 0`) are skipped, while printable graphemes write a `Cell` with `.width = @intCast(w)` at `(col, row)` and advance `col += w`.


* `InternalScreen.InternalCell` (`src/InternalScreen.zig`) adds `skipped: bool = false` (marking the trailing column skipped by a wide character) and `skip: bool = false` (marking cells covered by scaled/multi-cell glyphs in the current pass).




* **Why `libvaxis`'s `Window.writeCell` Alone Is Insufficient for Partial Overwrites:**
* In `src/Window.zig` and `src/Screen.zig`, `writeCell` only checks `col >= self.width or row >= self.height` and directly assigns `self.buf[i] = cell`. If a 2-column glyph is written at `col = self.width - 1` of a child window, or if a 1-column border glyph (`╭`, `│`, `─`) overwrites column `x` or `x + 1` of an existing 2-column CJK/emoji glyph in the shared `Screen.buf`, `Screen.writeCell` does not clear the other half of the split glyph.


* By contrast, `notcurses` (`include/notcurses/notcurses.h` and `src/lib/render.c`) enforces strict pairing between the left half (`nccell_wide_left_p`: `width >= 2 && gcluster != 0`) and right half (`nccell_wide_right_p`: `width >= 2 && gcluster == 0`):


1. **Right-Edge & Bisection Guard (`paint` in `src/lib/render.c`):** If a 2-column glyph lands on the last column of the target area (`absx >= dstlenx - 1`) or its right half is occluded by a higher z-plane (`crender[1].c.gcluster != 0`), Notcurses degrades the cell in-place to a 1-column space (`targc->gcluster = htole(' '); targc->width = 1;`).


2. **Spacer Propagation (`postpaint_cell` in `src/lib/render.c`):** Committing a wide cell of `width` at `x` loops `for (int i = 1; i < width; ++i)` to zero `gcluster = 0` on the trailing spacer cells while copying `channels` and `stylemask` from the lead cell.


3. **Rasterizer Cursor & Loop Skip (`rasterize_core` in `src/lib/render.c`):** Undamaged wide-left cells increment `++x` to skip their right half; damaged wide-left cells emit the UTF-8 cluster once, advance `nc->rstate.x += srccell->width`, and advance the loop counter by `x += srccell->width - 1`.







#### Exact Updates Required in `bifrost`

1. **`Cell` (`bifrost/renderer.odin`):**
* Add `width: u8` with three canonical states:
* `width == 1`: Standard 1-column glyph (`rune != 0`).
* `width == 2`: Lead (left) cell of a 2-column wide glyph (`rune != 0`).
* `width == 0`: Trailing (right) spacer cell of a 2-column wide glyph (`rune == 0`), carrying identical `fg`, `bg`, and `attrs` to its lead cell at `(x - 1, y)`.




2. **`put_cell_clipped` (`bifrost/renderer.odin`):**
* Reject writes with `cell.width == 0` (spacers are only synthesized internally when placing a `width == 2` lead cell).
* **Right-Boundary Clip Degradation:** If `cell.width == 2` and `x + 1 >= clip_right`, degrade the write to a 1-column space (`rune = ' ', width = 1` with `cell.fg`, `cell.bg`, `cell.attrs`) so a wide glyph never spills across a panel border or wraps the terminal line.
* **3-Case Partial Overwrite Healing (before writing `(x, y)`):**
* **Case A (Overwriting a Spacer at `x`):** If `dst[y, x].width == 0` and `x > 0`, the lead cell at `(x - 1, y)` has lost its right half. Heal `dst[y, x - 1]` to `{rune = ' ', width = 1, fg = lead.fg, bg = lead.bg, attrs = lead.attrs}`.
* **Case B (Overwriting a Wide Lead at `x` with `w == 1`):** If `dst[y, x].width == 2` and `x + 1 < s.width`, its spacer at `(x + 1, y)` is now orphaned. Heal `dst[y, x + 1]` to `{rune = ' ', width = 1, fg = spacer.fg, bg = spacer.bg, attrs = spacer.attrs}`.
* **Case C (Writing `w == 2` at `x` When `x + 1` Is a Wide Lead):** If `w == 2` and `dst[y, x + 1].width == 2` and `x + 2 < s.width`, the wide glyph starting at `x + 1` has lost its left half, orphaning its spacer at `x + 2`. Heal `dst[y, x + 2]` to `{rune = ' ', width = 1, fg = sp2.fg, bg = sp2.bg, attrs = sp2.attrs}`.




3. **`screen_diff_ansi` (`bifrost/renderer.odin`):**
* Never emit a glyph when `back[y, x].width == 0`.
* When `back[y, x].width == 2`, treat the 2-column pair as dirty if **either** `back[y, x] != front[y, x]` **or** `back[y, x + 1] != front[y, x + 1]`.
* After emitting a `width == 2` lead cell at `(x, y)`, advance the tracked hardware cursor by `cur_x = x + 2` and skip `x + 1` in the column loop.



---

### 2. Layout Edge Cases (`clay.h` vs. 2-Pass Topological `end_layout`)

Comparing `Clay__CloseElement` and `Clay__CalculateFinalLayout` in `clay.h` against a 2-pass topological `end_layout` exposes four subtle layout bugs:

1. **The Text-Wrapping X/Y Coupling Bug (Why 2 Passes Cannot Wrap Text in `Fit` Containers):**
* In a 2-pass layout (Pass 1: bottom-up intrinsic W & H; Pass 2: top-down final W, H, X, Y), a text node's final wrap width inside a `Grow` or `Percent` parent is unknown during Pass 1. If Pass 1 sets `height = 1` (unwrapped) and Pass 2 wraps the text into 3 lines once width is resolved, the parent `Fit` container's height was already locked at `1 + padding` in Pass 1—causing the wrapped text to overflow its parent and overlap lower siblings.
* **How `clay.h` solves it (`Clay__CalculateFinalLayout`):** Clay splits sizing into **five distinct sizing phases** before positioning:


1. Bottom-up intrinsic X/Y and `minDimensions` (`Clay__CloseElement`).


2. Top-down X-axis sizing (`Clay__SizeContainersAlongAxis(true, ...)`).


3. Text wrapping against resolved container widths (`lines 1756–1800`), updating `containerElement->dimensions.height = lineHeight * wrappedLines.length`.


4. Bottom-up post-order DFS height re-propagation (`lines 1809–1847`) so `Fit` ancestors expand to wrap the multi-line text. *(Note: Clay itself has a subtle oversight at lines 1835–1845 where it forgets to update `minDimensions.height` alongside `dimensions.height` and doesn't guard `FIXED`/`PERCENT` heights during re-propagation; in `bifrost` we must update both `dims.y` and `min_dims.y` on `Fit`/`Grow` containers so Pass 5 cannot crush wrapped text back down.)*


5. Top-down Y-axis sizing (`Clay__SizeContainersAlongAxis(false, ...)`).






2. **`Fit` / `Grow` Min/Max Clamping (Iterative Water-Filling vs. Single-Pass Equal Division):**
* A single-pass `share = remaining / grow_count` breaks whenever:
* Two `Grow` siblings have different intrinsic `Fit` base sizes (adding an equal delta makes the initially wider child wider than the narrower child instead of equalizing them).
* One `Grow` child hits its `max_size` early (leaving unused space undistributed), or one shrinking child hits its `min_size` early during overflow compression (leaving excess overflow unabsorbed).


* **How `clay.h` solves it (`lines 1620–1691`):**
* **Overflow Compression (`sizeToDistribute < 0`):** Unless the parent clips on that axis, Clay loops while `sizeToDistribute < 0`, finding the `largest` and `secondLargest` resizable children and compressing the `largest` children down toward `secondLargest`. Whenever a child reaches its `minSize` (`minDimensions`), it is clamped to `minSize` and removed from `resizableContainerBuffer` so the remaining deficit is absorbed by the other children.


* **Underflow Expansion (`sizeToDistribute > 0`):** Clay loops while `sizeToDistribute > 0`, finding the `smallest` and `secondSmallest` `GROW` children and raising the `smallest` children up to `secondSmallest`. Whenever a child reaches `maxSize`, it is clamped and removed from the active set.


* **Integer TUI Remainder Distribution:** Because `bifrost` operates on integer terminal cells (`i32`), `width_to_add = max(1, remaining / len(active))` or distributing `remaining % len(active)` 1 column at a time across the smallest/largest bucket prevents losing `1..N-1` columns to integer division truncation.




3. **`Percent` Sizing (`Clay__CloseElement` & `Clay__SizeContainersAlongAxis`):**
* **Bottom-Up Zeroing:** In `Clay__CloseElement` (`lines 1207–1223`), `PERCENT` dimensions are set to `0` during bottom-up accumulation so they do not inflate a `Fit` parent's intrinsic size.


* **Padding & Gap Subtraction:** In `Clay__SizeContainersAlongAxis` (`lines 1582–1615`), `PERCENT` along the layout axis multiplies `percent` by `(parentSize - totalPaddingAndChildGaps)` rather than raw `parentSize`, where `totalPaddingAndChildGaps = parentPadding + max(0, inFlowChildCount - 1) * childGap`. On the cross axis, it multiplies by `(parentSize - parentPadding)`. In `bifrost`, we also clamp `min_size..=max_size` after computing the percentage size.




4. **Out-of-Flow Floating Elements (`Clay_FloatingElementConfig`):**
* **Exclusion from Parent Flow:** In `Clay__CloseElement` (`lines 1232–1235`), floating elements increment `floatingChildrenCount` and return before being appended to the parent's `children` slice, so they never add `childGap` or affect parent `Fit`/`Grow` math.


* **Separate Root List & Parent Sizing:** Floating elements are pushed onto `layoutElementTreeRoots` with `parentId`, `clipElementId`, and `zIndex` (`lines 1403–1409`), and resolve root-level `GROW`/`PERCENT` sizing directly against their anchor parent's dimensions (`lines 1520–1545`).


* **9-Point Anchor Math & Topological Positioning Order:** Clay computes the floating root's origin by adding `attachPoints.parent` (`LEFT/CENTER/RIGHT` × `TOP/CENTER/BOTTOM` of `parentBoundingBox`) and subtracting `attachPoints.element` (`0`, `width/2`, or `width`), plus `offset` (`lines 1880–1925`). In `bifrost`, we resolve anchor positions in topological creation order *before* sorting roots by `(z_index, creation_order)`, fixing the case where a lower-`z_index` floating tooltip attaches to a higher-`z_index` floating modal.





---

### 3. Backdrop Dimming & Cell Blending (`notcurses` vs. `bifrost`)

* **How `notcurses` Handles Blending and Fading (`[cite: 1]`):**
* Notcurses packs two 32-bit channels into `uint64_t channels`, with each channel carrying `NC_BGDEFAULT_MASK` (`0x40000000`), a 2-bit alpha mode (`NCALPHA_OPAQUE`, `NCALPHA_BLEND`, `NCALPHA_TRANSPARENT`, `NCALPHA_HIGHCONTRAST`), `NC_BG_PALETTE` (`0x08000000`), and 24-bit RGB or 8-bit palette index.


* During `paint()` (`src/lib/render.c`), Notcurses composites top-to-bottom across planes using `cell_blend_fchannel` / `cell_blend_bchannel` with running blend counts (`fgblends`, `bgblends`).


* During `ncplane_fadeout_iteration` (`src/lib/fade.c`), Notcurses scales RGB channels toward black (`r * (maxsteps - iter) / maxsteps`), and on 256-color terminals (`src/lib/render.c`), quantizes RGB back into the 256-color palette via `rgb_quantize_256(r, g, b)`.




* **How `bifrost` Should Dim `.ANSI_256` Palette Colors (`0..=255`) in `dim_rect_backdrop`:**
To keep 256-color themes purely in `.ANSI_256` space (emitting compact `38;5;Nm` / `48;5;Nm` sequences without forcing 24-bit TrueColor), `dim_color` should partition `.ANSI_256` by its three Xterm sub-ranges:
1. **Indices `0..=15` (Standard & Bright ANSI 16 within 256-color space):**
* `8` (Bright Black / Dark Gray `128,128,128`) dims to grayscale index `238` (`68,68,68`).
* `9..=15` (Bright ANSI) dim to their standard counterparts `idx - 8` (`1..=7`).
* `1..=7` (Standard ANSI ~`128` intensity) dim to their 50% dark 6×6×6 cube / grayscale equivalents: `[8]u8{0, 52, 22, 58, 18, 53, 23, 246}` (`0` stays `0`, `7` Silver `192` dims to `246` `98,98,98`, and `1..=6` map to single-step dark cube indices `95`).


2. **Indices `16..=231` ($6 \times 6 \times 6$ RGB Color Cube):**
* Decompose `offset := idx - 16` into `r6 := offset / 36`, `g6 := (offset / 6) % 6`, `b6 := offset % 6`, where each step `[0..=5]` maps to `CUBE_LEVELS = [6]u8{0, 95, 135, 175, 215, 255}`.
* **Neutral Cube Grays (`r6 == g6 && g6 == b6`, i.e., `16, 59, 102, 145, 188, 231`):** Because the cube jumps from `0` to `95`, dividing `c6 / 2` turns `59` (`95,95,95`) into pure black `16` (`0,0,0`). Instead, for `r6 > 0`, halve the actual luminance `lum := int(CUBE_LEVELS[r6]) >> 1` and map it directly onto the 24-step grayscale ramp `232 + u8(clamp((lum - 8 + 5) / 10, 0, 23))` (so `231` white `255` dims to `244` `128`, and `59` gray `95` dims to `236` `48`).
* **Chromatic Cube Colors:** Halve each cube coordinate (`dr := r6 >> 1`, `dg := g6 >> 1`, `db := b6 >> 1`). If the color had `max(r6, g6, b6) == 1` (so `dr == 0 && dg == 0 && db == 0`, which would collapse a dark chromatic background into pure black `16`), fall back to dark grayscale `234` (`28,28,28`) for backgrounds or keep `(r6, g6, b6)` with `.Dim` attribute for foregrounds; otherwise repack `16 + 36*dr + 6*dg + db`.


3. **Indices `232..=255` (24-Step Grayscale Ramp):**
* Each step has luminance `lum := 8 + 10 * int(idx - 232)` (`8..=238`).
* Halve luminance: `dim_lum := lum >> 1` (`4..=119`).
* For `dim_lum < 6` (`idx == 232`), map to cube black `16` (`0,0,0`); otherwise map to `232 + u8(clamp((dim_lum - 8 + 5) / 10, 0, 23))` (which equals `232 + (idx - 232) / 2` for `idx >= 233`).





---

### 4. Cross-Cutting Invariants for Layer 3 (`driver_bifrost.odin`)

In the 4-layer ATDD architecture, Layer 3 (`driver_bifrost.odin`) must automatically invoke `assert_frame_invariants(t, drv)` at the end of every rendered frame:

1. **Wide-Cell Lead/Spacer Pairing & Style Parity:**
* Every cell has `width in {0, 1, 2}`.
* Rightmost column `x == width - 1` never has `width == 2`.
* Every lead cell (`width == 2`) at `(x, y)` has `rune >= 32` and is paired with a spacer at `(x + 1, y)` having `width == 0`, `rune == 0`, `fg == lead.fg`, `bg == lead.bg`, and `attrs == lead.attrs`.
* Every spacer cell (`width == 0`) at `(x, y)` has `x > 0`, `rune == 0`, and is preceded by a lead cell at `(x - 1, y)` with `width == 2`.


2. **No Raw Control Codepoints in Screen Buffers:**
* Every non-spacer cell (`width in {1, 2}`) has `rune >= 32 && !(rune >= 0x7f && rune < 0xa0)`.


3. **Front/Back Buffer Convergence & Idempotent 0-Byte Clean Diff:**
* Immediately after `render_frame`, `front` and `back` are cell-for-cell equal, and a second `screen_diff_ansi` call produces `0` bytes.


4. **ANSI Virtual Terminal Round-Trip Equivalence:**
* Parsing and applying the emitted ANSI byte stream to the driver's independent virtual terminal grid (`vt_apply_ansi`) produces a screen identical to `front` at every `(x, y)` coordinate.


5. **Stack Balance & Clip-Rect Monotonicity:**
* Layout `open_stack` and `clip_stack` are empty (`len == 0`) after `end_layout`, and every command's `clip_rect` is contained within `[0..width, 0..height)` and within its parent's `clip_rect`.


6. **Non-Overlapping In-Flow Siblings & Min/Max Bounds:**
* Every resolved `Layout_Node` has `rect.w >= 0 && rect.h >= 0`, respects `[min_size, max_size]` when parent space permits, and in-flow siblings along the main axis satisfy `child[i+1].pos >= child[i].pos + child[i].size + child_gap`.


7. **Zero Per-Frame Heap Leaks:**
* `mem.Tracking_Allocator` records zero net persistent allocations or bad frees across repeated frames.



---

### Idiomatic Odin Implementation Updates

#### 1. `bifrost/renderer.odin`

```odin
package bifrost

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Color_Kind :: enum u8 {
	Default = 0,
	ANSI_16,
	ANSI_256,
	RGB,
}

Color :: struct {
	kind: Color_Kind,
	idx:  u8,
	rgb:  [3]u8,
}

Attr :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Blink,
	Reverse,
	Strikethrough,
}

Attrs :: bit_set[Attr; u8]

// width == 1: standard 1-col glyph
// width == 2: lead (left) cell of a 2-col wide glyph
// width == 0: trailing (right) spacer of a 2-col wide glyph (rune == 0)
Cell :: struct {
	rune:  rune,
	width: u8,
	fg:    Color,
	bg:    Color,
	attrs: Attrs,
}

Rect :: struct {
	x, y, w, h: i32,
}

Screen :: struct {
	width:  i32,
	height: i32,
	cells:  []Cell,
}

DEFAULT_CELL :: Cell{
	rune  = ' ',
	width = 1,
	fg    = Color{kind = .Default},
	bg    = Color{kind = .Default},
	attrs = {},
}

@(rodata)
CUBE_LEVELS := [6]u8{0, 95, 135, 175, 215, 255}

@(rodata)
ANSI_16_DARK_TO_256 := [8]u8{
	0 = 0,   // Black -> Black
	1 = 52,  // Red (128,0,0) -> Cube(1,0,0) (95,0,0)
	2 = 22,  // Green (0,128,0) -> Cube(0,1,0) (0,95,0)
	3 = 58,  // Yellow (128,128,0) -> Cube(1,1,0) (95,95,0)
	4 = 18,  // Blue (0,0,128) -> Cube(0,0,1) (0,0,95)
	5 = 53,  // Magenta (128,0,128) -> Cube(1,0,1) (95,0,95)
	6 = 23,  // Cyan (0,128,128) -> Cube(0,1,1) (0,95,95)
	7 = 246, // White/Silver (192,192,192) -> Gray(98,98,98)
}

screen_init :: proc(s: ^Screen, width, height: i32, allocator := context.allocator) {
	s.width  = max(0, width)
	s.height = max(0, height)
	total := int(s.width * s.height)
	s.cells = make([]Cell, total, allocator)
	screen_clear(s)
}

screen_destroy :: proc(s: ^Screen, allocator := context.allocator) {
	delete(s.cells, allocator)
	s^ = {}
}

screen_clear :: proc(s: ^Screen, fill_cell := DEFAULT_CELL) {
	c := fill_cell
	if c.width != 1 || c.rune == 0 {
		c.rune  = ' '
		c.width = 1
	}
	for i in 0 ..< len(s.cells) {
		s.cells[i] = c
	}
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x1 := max(a.x, b.x)
	y1 := max(a.y, b.y)
	x2 := min(a.x + a.w, b.x + b.w)
	y2 := min(a.y + a.h, b.y + b.h)
	if x2 <= x1 || y2 <= y1 {
		return Rect{x = x1, y = y1, w = 0, h = 0}
	}
	return Rect{x = x1, y = y1, w = x2 - x1, h = y2 - y1}
}

// Computes terminal display column width (0, 1, or 2) for a rune.
rune_display_width :: proc(r: rune) -> u8 {
	if r == 0 || r < 32 || (r >= 0x7f && r < 0xa0) {
		return 0
	}
	// Zero-width joiners, non-joiners, soft hyphen, BOM, combining marks, variation selectors
	if r == 0x00ad || (r >= 0x0300 && r <= 0x036f) || r == 0x034f ||
	   (r >= 0x180b && r <= 0x180d) || (r >= 0x200b && r <= 0x200f) ||
	   (r >= 0x202a && r <= 0x202e) || (r >= 0x2060 && r <= 0x2064) ||
	   r == 0xfeff || (r >= 0xfe00 && r <= 0xfe0f) || (r >= 0xe0100 && r <= 0xe01ef) {
		return 0
	}
	// Wide / Fullwidth East Asian, CJK, Emoji blocks, and Nerd Font wide ranges
	if (r >= 0x1100 && r <= 0x115f) ||
	   r == 0x2329 || r == 0x232a ||
	   (r >= 0x2e80 && r <= 0x303e) ||
	   (r >= 0x3040 && r <= 0xa4cf && r != 0x303f) ||
	   (r >= 0xac00 && r <= 0xd7a3) ||
	   (r >= 0xf900 && r <= 0xfaff) ||
	   (r >= 0xfe10 && r <= 0xfe19) ||
	   (r >= 0xfe30 && r <= 0xfe6f) ||
	   (r >= 0xff00 && r <= 0xff60) ||
	   (r >= 0xffe0 && r <= 0xffe6) ||
	   (r >= 0x1f1e6 && r <= 0x1f6ff) ||
	   (r >= 0x1f900 && r <= 0x1faff) ||
	   (r >= 0x20000 && r <= 0x3fffd) {
		return 2
	}
	return 1
}

string_display_width :: proc(str: string) -> i32 {
	total: i32 = 0
	for r in str {
		total += i32(rune_display_width(r))
	}
	return total
}

@(private)
heal_overwrite_at :: proc(s: ^Screen, x, y: i32) {
	idx := int(y * s.width + x)
	existing := s.cells[idx]

	if existing.width == 0 && x > 0 {
		// Overwriting the right half (spacer) of a wide cell: degrade lead cell at x - 1 to 1-col space
		lead_idx := idx - 1
		lead := s.cells[lead_idx]
		if lead.width == 2 {
			lead.rune  = ' '
			lead.width = 1
			s.cells[lead_idx] = lead
		}
	} else if existing.width == 2 && x + 1 < s.width {
		// Overwriting the left half (lead) of a wide cell: heal orphaned spacer at x + 1 to 1-col space
		spacer_idx := idx + 1
		spacer := s.cells[spacer_idx]
		if spacer.width == 0 {
			spacer.rune  = ' '
			spacer.width = 1
			s.cells[spacer_idx] = spacer
		}
	}
}

// Safely writes a 1-column or 2-column cell within clip, healing any split wide neighbors.
put_cell_clipped :: proc(s: ^Screen, x, y: i32, cell: Cell, clip: Rect) {
	if cell.width == 0 {
		return
	}
	screen_bounds := Rect{0, 0, s.width, s.height}
	eff_clip := rect_intersect(clip, screen_bounds)
	if x < eff_clip.x || x >= eff_clip.x + eff_clip.w || y < eff_clip.y || y >= eff_clip.y + eff_clip.h {
		return
	}

	c := cell
	if c.rune < 32 || (c.rune >= 0x7f && c.rune < 0xa0) {
		c.rune  = ' '
		c.width = 1
	}
	if c.width > 2 {
		c.width = 2
	}

	// If a 2-column glyph hits the right edge of the clip rect (or screen), degrade to 1-col space
	// so it never bleeds into a border or wraps the terminal line.
	if c.width == 2 && x + 1 >= eff_clip.x + eff_clip.w {
		c.rune  = ' '
		c.width = 1
	}

	// Heal any wide glyph split at (x, y)
	heal_overwrite_at(s, x, y)

	idx := int(y * s.width + x)
	if c.width == 2 {
		// Also heal any wide glyph whose lead cell sits at (x + 1, y)
		heal_overwrite_at(s, x + 1, y)
		s.cells[idx] = c
		s.cells[idx + 1] = Cell{
			rune  = 0,
			width = 0,
			fg    = c.fg,
			bg    = c.bg,
			attrs = c.attrs,
		}
	} else {
		s.cells[idx] = c
	}
}

put_text_clipped :: proc(s: ^Screen, x, y: i32, text: string, fg, bg: Color, attrs: Attrs, clip: Rect) -> i32 {
	cur_x := x
	for r in text {
		w := rune_display_width(r)
		if w == 0 {
			continue
		}
		put_cell_clipped(s, cur_x, y, Cell{
			rune  = r,
			width = w,
			fg    = fg,
			bg    = bg,
			attrs = attrs,
		}, clip)
		cur_x += i32(w)
	}
	return cur_x - x
}

// Dims a color by 50% across RGB, ANSI_256 (16..231 cube & 232..255 grayscale), ANSI_16, and Default.
dim_color :: proc(c: Color, is_fg: bool) -> Color {
	switch c.kind {
	case .Default:
		if is_fg {
			return Color{kind = .ANSI_16, idx = 8} // Bright Black / Dark Gray
		}
		return c

	case .ANSI_16:
		if c.idx >= 8 && c.idx <= 15 {
			if c.idx == 8 {
				return Color{kind = .ANSI_16, idx = 0}
			}
			return Color{kind = .ANSI_16, idx = c.idx - 8}
		}
		if c.idx == 7 {
			return Color{kind = .ANSI_16, idx = 8}
		}
		if !is_fg {
			return Color{kind = .ANSI_16, idx = 0}
		}
		return c

	case .ANSI_256:
		idx := c.idx
		if idx < 8 {
			return Color{kind = .ANSI_256, idx = ANSI_16_DARK_TO_256[idx]}
		}
		if idx < 16 {
			if idx == 8 {
				return Color{kind = .ANSI_256, idx = 238} // Gray(68,68,68)
			}
			return Color{kind = .ANSI_256, idx = idx - 8}
		}
		if idx <= 231 {
			offset := idx - 16
			r6 := offset / 36
			g6 := (offset / 6) % 6
			b6 := offset % 6

			// Neutral cube grays (16, 59, 102, 145, 188, 231): project onto the 24-step grayscale ramp
			if r6 == g6 && g6 == b6 {
				if r6 == 0 {
					return Color{kind = .ANSI_256, idx = 16}
				}
				lum := int(CUBE_LEVELS[r6]) >> 1
				g_step := clamp((lum - 8 + 5) / 10, 0, 23)
				return Color{kind = .ANSI_256, idx = u8(232 + g_step)}
			}

			dr := r6 >> 1
			dg := g6 >> 1
			db := b6 >> 1
			// Prevent dark chromatic colors (max cube coord == 1) from collapsing to pure black (16)
			if dr == 0 && dg == 0 && db == 0 {
				return Color{kind = .ANSI_256, idx = 234} // Subtle dark gray (28,28,28)
			}
			return Color{kind = .ANSI_256, idx = 16 + 36 * dr + 6 * dg + db}
		}

		// 232..=255: 24-step grayscale ramp (8, 18, 28, ..., 238)
		g_idx := int(idx - 232)
		lum := (8 + 10 * g_idx) >> 1
		if lum < 6 {
			return Color{kind = .ANSI_256, idx = 16} // Pure black (0,0,0)
		}
		g_step := clamp((lum - 8 + 5) / 10, 0, 23)
		return Color{kind = .ANSI_256, idx = u8(232 + g_step)}

	case .RGB:
		return Color{
			kind = .RGB,
			rgb  = {c.rgb[0] >> 1, c.rgb[1] >> 1, c.rgb[2] >> 1},
		}
	}
	return c
}

// Dims a rectangular backdrop region in-place while preserving wide-cell pairing invariants.
dim_rect_backdrop :: proc(s: ^Screen, rect: Rect) {
	eff := rect_intersect(rect, Rect{0, 0, s.width, s.height})
	if eff.w <= 0 || eff.h <= 0 {
		return
	}

	for y in eff.y ..< eff.y + eff.h {
		// If the left edge of the dim rect bisects a 2-col glyph, heal both halves to 1-col spaces first
		if eff.x > 0 {
			left_idx := int(y * s.width + eff.x)
			if s.cells[left_idx].width == 0 {
				heal_overwrite_at(s, eff.x, y)
				s.cells[left_idx].rune  = ' '
				s.cells[left_idx].width = 1
			}
		}
		// If the right edge of the dim rect bisects a 2-col glyph, heal both halves to 1-col spaces first
		right_col := eff.x + eff.w - 1
		if right_col + 1 < s.width {
			right_idx := int(y * s.width + right_col)
			if s.cells[right_idx].width == 2 {
				heal_overwrite_at(s, right_col, y)
				s.cells[right_idx].rune  = ' '
				s.cells[right_idx].width = 1
			}
		}

		for x in eff.x ..< eff.x + eff.w {
			idx := int(y * s.width + x)
			c := s.cells[idx]
			c.fg = dim_color(c.fg, true)
			c.bg = dim_color(c.bg, false)
			c.attrs -= {.Bold}
			c.attrs += {.Dim}
			s.cells[idx] = c
		}
	}
}

cells_equal :: proc(a, b: Cell) -> bool {
	return a.rune == b.rune &&
	       a.width == b.width &&
	       a.attrs == b.attrs &&
	       colors_equal(a.fg, b.fg) &&
	       colors_equal(a.bg, b.bg)
}

colors_equal :: proc(a, b: Color) -> bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case .Default:
		return true
	case .ANSI_16, .ANSI_256:
		return a.idx == b.idx
	case .RGB:
		return a.rgb == b.rgb
	}
	return false
}

@(private)
emit_color_sgr :: proc(b: ^strings.Builder, c: Color, is_fg: bool) {
	switch c.kind {
	case .Default:
		strings.write_string(b, "\x1b[39m" if is_fg else "\x1b[49m")
	case .ANSI_16:
		code: int
		if c.idx < 8 {
			code = (30 if is_fg else 40) + int(c.idx)
		} else {
			code = (90 if is_fg else 100) + int(c.idx - 8)
		}
		fmt.sbprintf(b, "\x1b[%dm", code)
	case .ANSI_256:
		fmt.sbprintf(b, "\x1b[%d;5;%dm", 38 if is_fg else 48, c.idx)
	case .RGB:
		fmt.sbprintf(b, "\x1b[%d;2;%d;%d;%dm", 38 if is_fg else 48, c.rgb[0], c.rgb[1], c.rgb[2])
	}
}

// Diffs back against front, appends minimal ANSI sequence to out_builder, and syncs front <- back.
screen_diff_ansi :: proc(front, back: ^Screen, out_builder: ^strings.Builder) {
	assert(front.width == back.width && front.height == back.height)

	cur_x: i32 = -1
	cur_y: i32 = -1
	cur_fg := Color{kind = .Default}
	cur_bg := Color{kind = .Default}
	cur_attrs: Attrs = {}
	style_known := false

	for y in 0 ..< back.height {
		x: i32 = 0
		for x < back.width {
			idx := int(y * back.width + x)
			next := back.cells[idx]

			// Spacer cells (width == 0) are never emitted directly
			if next.width == 0 {
				front.cells[idx] = next
				x += 1
				continue
			}

			dirty := !cells_equal(front.cells[idx], next)
			if next.width == 2 && x + 1 < back.width {
				if !cells_equal(front.cells[idx + 1], back.cells[idx + 1]) {
					dirty = true
				}
			}

			if !dirty {
				x += i32(max(1, next.width))
				continue
			}

			if cur_x != x || cur_y != y {
				fmt.sbprintf(out_builder, "\x1b[%d;%dH", y + 1, x + 1)
				cur_x = x
				cur_y = y
			}

			if !style_known || cur_attrs != next.attrs {
				strings.write_string(out_builder, "\x1b[0m")
				if .Bold in next.attrs          { strings.write_string(out_builder, "\x1b[1m") }
				if .Dim in next.attrs           { strings.write_string(out_builder, "\x1b[2m") }
				if .Italic in next.attrs        { strings.write_string(out_builder, "\x1b[3m") }
				if .Underline in next.attrs     { strings.write_string(out_builder, "\x1b[4m") }
				if .Blink in next.attrs         { strings.write_string(out_builder, "\x1b[5m") }
				if .Reverse in next.attrs       { strings.write_string(out_builder, "\x1b[7m") }
				if .Strikethrough in next.attrs { strings.write_string(out_builder, "\x1b[9m") }
				cur_attrs   = next.attrs
				cur_fg      = Color{kind = .Default}
				cur_bg      = Color{kind = .Default}
				style_known = true
			}

			if !colors_equal(cur_fg, next.fg) {
				emit_color_sgr(out_builder, next.fg, true)
				cur_fg = next.fg
			}
			if !colors_equal(cur_bg, next.bg) {
				emit_color_sgr(out_builder, next.bg, false)
				cur_bg = next.bg
			}

			buf, n := utf8.encode_rune(next.rune)
			strings.write_bytes(out_builder, buf[:n])

			front.cells[idx] = next
			if next.width == 2 && x + 1 < back.width {
				front.cells[idx + 1] = back.cells[idx + 1]
				cur_x += 2
				x += 2
			} else {
				cur_x += 1
				x += 1
			}
		}
	}

	if style_known && (cur_attrs != {} || cur_fg.kind != .Default || cur_bg.kind != .Default) {
		strings.write_string(out_builder, "\x1b[0m")
	}
}

```

---

#### 2. `bifrost/layout.odin`

```odin
package bifrost

import "core:slice"

Layout_Dir :: enum u8 {
	Left_To_Right = 0,
	Top_To_Bottom = 1,
}

Sizing_Kind :: enum u8 {
	Fit = 0,
	Grow,
	Fixed,
	Percent,
}

Sizing_Axis :: struct {
	kind:    Sizing_Kind,
	min:     i32,
	max:     i32,
	percent: f32, // 0.0 ..= 1.0
}

Sizing :: struct {
	width:  Sizing_Axis,
	height: Sizing_Axis,
}

Padding :: struct {
	left, right, top, bottom: i32,
}

Align_X :: enum u8 { Left = 0, Center, Right }
Align_Y :: enum u8 { Top = 0, Center, Bottom }

Attach_Point :: enum u8 {
	Left_Top = 0,
	Left_Center,
	Left_Bottom,
	Center_Top,
	Center_Center,
	Center_Bottom,
	Right_Top,
	Right_Center,
	Right_Bottom,
}

Attach_To :: enum u8 {
	None = 0,
	Parent,
	Element_With_Id,
	Root,
}

Floating_Config :: struct {
	attach_to:      Attach_To,
	parent_id:      u32,
	offset:         [2]i32,
	expand:         [2]i32,
	z_index:        i16,
	element_attach: Attach_Point,
	parent_attach:  Attach_Point,
	clip_to_parent: bool,
	dim_backdrop:   bool,
}

Wrap_Mode :: enum u8 {
	None = 0,
	Words,
	Newlines,
}

Layout_Node :: struct {
	id:            u32,
	parent_idx:    i32,
	children:      [dynamic]i32,
	dir:           Layout_Dir,
	sizing:        Sizing,
	padding:       Padding,
	child_gap:     i32,
	align_x:       Align_X,
	align_y:       Align_Y,
	clip_h:        bool,
	clip_v:        bool,
	scroll_offset: [2]i32,
	floating:      Floating_Config,

	// Text payload
	is_text:       bool,
	text:          string,
	wrap_mode:     Wrap_Mode,
	wrapped_lines: [dynamic]string,

	// Computed geometry
	dims:          [2]i32,
	min_dims:      [2]i32,
	rect:          Rect,
	clip_rect:     Rect,
}

Tree_Root :: struct {
	node_idx:   i32,
	parent_id:  u32,
	clip_id:    u32,
	z_index:    i16,
	decl_order: i32,
}

Layout_Context :: struct {
	viewport:   [2]i32,
	nodes:      [dynamic]Layout_Node,
	open_stack: [dynamic]i32,
	clip_stack: [dynamic]u32,
	roots:      [dynamic]Tree_Root,
	id_map:     map[u32]i32,
}

MAX_DIM :: i32(0x3fff_ffff)

sizing_fit :: proc(min_v: i32 = 0, max_v: i32 = MAX_DIM) -> Sizing_Axis {
	return Sizing_Axis{kind = .Fit, min = min_v, max = max_v if max_v > 0 else MAX_DIM}
}

sizing_grow :: proc(min_v: i32 = 0, max_v: i32 = MAX_DIM) -> Sizing_Axis {
	return Sizing_Axis{kind = .Grow, min = min_v, max = max_v if max_v > 0 else MAX_DIM}
}

sizing_fixed :: proc(exact: i32) -> Sizing_Axis {
	return Sizing_Axis{kind = .Fixed, min = exact, max = exact}
}

sizing_percent :: proc(pct: f32, min_v: i32 = 0, max_v: i32 = MAX_DIM) -> Sizing_Axis {
	return Sizing_Axis{kind = .Percent, percent = clamp(pct, 0.0, 1.0), min = min_v, max = max_v if max_v > 0 else MAX_DIM}
}

begin_layout :: proc(ctx: ^Layout_Context, width, height: i32, allocator := context.temp_allocator) {
	ctx.viewport = {width, height}
	ctx.nodes      = make([dynamic]Layout_Node, 0, 256, allocator)
	ctx.open_stack = make([dynamic]i32, 0, 64, allocator)
	ctx.clip_stack = make([dynamic]u32, 0, 32, allocator)
	ctx.roots      = make([dynamic]Tree_Root, 0, 16, allocator)
	ctx.id_map     = make(map[u32]i32, 256, allocator)

	// Root container at index 0
	open_element(ctx, Layout_Node{
		id     = 1,
		dir    = .Top_To_Bottom,
		sizing = {width = sizing_fixed(width), height = sizing_fixed(height)},
	})
	append(&ctx.roots, Tree_Root{node_idx = 0, parent_id = 0, clip_id = 0, z_index = 0, decl_order = 0})
}

open_element :: proc(ctx: ^Layout_Context, decl: Layout_Node) -> i32 {
	node := decl
	if node.sizing.width.max <= 0  { node.sizing.width.max = MAX_DIM }
	if node.sizing.height.max <= 0 { node.sizing.height.max = MAX_DIM }
	node.children = make([dynamic]i32, 0, 8, ctx.nodes.allocator)

	idx := i32(len(ctx.nodes))
	parent_idx: i32 = -1
	if len(ctx.open_stack) > 0 {
		parent_idx = ctx.open_stack[len(ctx.open_stack) - 1]
	}
	node.parent_idx = parent_idx
	if node.id == 0 {
		node.id = u32(idx + 1)
	}

	if node.floating.attach_to != .None && parent_idx >= 0 {
		target_parent_id := node.floating.parent_id
		if node.floating.attach_to == .Parent {
			target_parent_id = ctx.nodes[parent_idx].id
		} else if node.floating.attach_to == .Root {
			target_parent_id = ctx.nodes[0].id
		}
		node.floating.parent_id = target_parent_id
		clip_id: u32 = 0
		if node.floating.clip_to_parent && len(ctx.clip_stack) > 0 {
			clip_id = ctx.clip_stack[len(ctx.clip_stack) - 1]
		}
		append(&ctx.roots, Tree_Root{
			node_idx   = idx,
			parent_id  = target_parent_id,
			clip_id    = clip_id,
			z_index    = node.floating.z_index,
			decl_order = i32(len(ctx.roots)),
		})
	}

	append(&ctx.nodes, node)
	ctx.id_map[node.id] = idx
	append(&ctx.open_stack, idx)

	if node.clip_h || node.clip_v {
		append(&ctx.clip_stack, node.id)
	}
	return idx
}

add_text_element :: proc(ctx: ^Layout_Context, id: u32, text: string, wrap_mode: Wrap_Mode = .Words) -> i32 {
	parent_idx := ctx.open_stack[len(ctx.open_stack) - 1]
	unwrapped_w: i32 = 0
	longest_word: i32 = 0
	line_count: i32 = 1
	cur_line_w: i32 = 0
	cur_word_w: i32 = 0

	for r in text {
		if r == '\n' {
			unwrapped_w  = max(unwrapped_w, cur_line_w)
			longest_word = max(longest_word, cur_word_w)
			cur_line_w   = 0
			cur_word_w   = 0
			line_count  += 1
			continue
		}
		w := i32(rune_display_width(r))
		cur_line_w += w
		if r == ' ' {
			longest_word = max(longest_word, cur_word_w)
			cur_word_w   = 0
		} else {
			cur_word_w += w
		}
	}
	unwrapped_w  = max(unwrapped_w, cur_line_w)
	longest_word = max(longest_word, cur_word_w)

	min_w := longest_word if wrap_mode == .Words else unwrapped_w
	idx := i32(len(ctx.nodes))
	node := Layout_Node{
		id        = id if id != 0 else u32(idx + 1),
		parent_idx = parent_idx,
		is_text   = true,
		text      = text,
		wrap_mode = wrap_mode,
		sizing    = {width = sizing_fit(min_w, MAX_DIM), height = sizing_fit(line_count, MAX_DIM)},
		dims      = {unwrapped_w, line_count},
		min_dims  = {min_w, line_count},
	}
	append(&ctx.nodes, node)
	ctx.id_map[node.id] = idx
	append(&ctx.nodes[parent_idx].children, idx)
	return idx
}

close_element :: proc(ctx: ^Layout_Context) {
	assert(len(ctx.open_stack) > 0, "Unbalanced close_element")
	idx := pop(&ctx.open_stack)
	node := &ctx.nodes[idx]

	if node.clip_h || node.clip_v {
		pop(&ctx.clip_stack)
	}

	pad_x := node.padding.left + node.padding.right
	pad_y := node.padding.top + node.padding.bottom

	if node.dir == .Left_To_Right {
		node.dims.x     = pad_x
		node.min_dims.x = pad_x
		node.dims.y     = pad_y
		node.min_dims.y = pad_y
		for c_idx in node.children {
			child := &ctx.nodes[c_idx]
			node.dims.x += child.dims.x
			node.dims.y  = max(node.dims.y, child.dims.y + pad_y)
			if !node.clip_h { node.min_dims.x += child.min_dims.x }
			if !node.clip_v { node.min_dims.y  = max(node.min_dims.y, child.min_dims.y + pad_y) }
		}
		gaps := max(0, i32(len(node.children)) - 1) * node.child_gap
		node.dims.x += gaps
		if !node.clip_h { node.min_dims.x += gaps }
	} else {
		node.dims.x     = pad_x
		node.min_dims.x = pad_x
		node.dims.y     = pad_y
		node.min_dims.y = pad_y
		for c_idx in node.children {
			child := &ctx.nodes[c_idx]
			node.dims.y += child.dims.y
			node.dims.x  = max(node.dims.x, child.dims.x + pad_x)
			if !node.clip_v { node.min_dims.y += child.min_dims.y }
			if !node.clip_h { node.min_dims.x  = max(node.min_dims.x, child.min_dims.x + pad_x) }
		}
		gaps := max(0, i32(len(node.children)) - 1) * node.child_gap
		node.dims.y += gaps
		if !node.clip_v { node.min_dims.y += gaps }
	}

	// Clamp non-Percent axes; zero Percent axes during bottom-up pass so they don't inflate Fit parents
	if node.sizing.width.kind != .Percent {
		node.dims.x     = clamp(node.dims.x, node.sizing.width.min, node.sizing.width.max)
		node.min_dims.x = clamp(node.min_dims.x, node.sizing.width.min, node.sizing.width.max)
	} else {
		node.dims.x     = 0
		node.min_dims.x = node.sizing.width.min
	}

	if node.sizing.height.kind != .Percent {
		node.dims.y     = clamp(node.dims.y, node.sizing.height.min, node.sizing.height.max)
		node.min_dims.y = clamp(node.min_dims.y, node.sizing.height.min, node.sizing.height.max)
	} else {
		node.dims.y     = 0
		node.min_dims.y = node.sizing.height.min
	}

	// Out-of-flow floating elements do NOT attach to parent's in-flow children list
	if node.parent_idx >= 0 && node.floating.attach_to == .None {
		append(&ctx.nodes[node.parent_idx].children, idx)
	}
}

@(private)
size_axis :: proc(ctx: ^Layout_Context, x_axis: bool) {
	axis := 0 if x_axis else 1
	resizable := make([dynamic]i32, 0, 32, context.temp_allocator)

	for root in ctx.roots {
		root_node := &ctx.nodes[root.node_idx]
		if root_node.floating.attach_to != .None {
			if p_idx, ok := ctx.id_map[root_node.floating.parent_id]; ok {
				parent_dim := ctx.nodes[p_idx].dims[axis]
				sizing := root_node.sizing.width if x_axis else root_node.sizing.height
				switch sizing.kind {
				case .Grow:
					root_node.dims[axis] = clamp(parent_dim, sizing.min, sizing.max)
				case .Percent:
					val := i32(f32(parent_dim) * sizing.percent + 0.5)
					root_node.dims[axis] = clamp(val, sizing.min, sizing.max)
				case .Fit, .Fixed:
					root_node.dims[axis] = clamp(root_node.dims[axis], sizing.min, sizing.max)
				}
			}
		}
	}

	// Topological forward traversal (parents always have lower indices than their children)
	for p_idx in 0 ..< len(ctx.nodes) {
		parent := &ctx.nodes[p_idx]
		if len(parent.children) == 0 {
			continue
		}

		along_axis := (x_axis && parent.dir == .Left_To_Right) || (!x_axis && parent.dir == .Top_To_Bottom)
		parent_size := parent.dims[axis]
		parent_pad := (parent.padding.left + parent.padding.right) if x_axis else (parent.padding.top + parent.padding.bottom)
		total_gaps := max(0, i32(len(parent.children)) - 1) * parent.child_gap
		total_pad_and_gaps := parent_pad + (total_gaps if along_axis else 0)

		inner_content: i32 = 0
		grow_count := 0
		clear(&resizable)

		// 1. Expand Percent children first against (parent_size - total_pad_and_gaps)
		avail_for_pct := max(0, parent_size - total_pad_and_gaps)
		for c_idx in parent.children {
			child := &ctx.nodes[c_idx]
			c_sizing := child.sizing.width if x_axis else child.sizing.height
			if c_sizing.kind == .Percent {
				raw_sz := i32(f32(avail_for_pct) * c_sizing.percent + 0.5)
				child.dims[axis] = clamp(raw_sz, c_sizing.min, c_sizing.max)
			}
			if along_axis {
				inner_content += child.dims[axis]
			} else {
				inner_content = max(inner_content, child.dims[axis])
			}
			if c_sizing.kind != .Percent && c_sizing.kind != .Fixed && (!child.is_text || child.wrap_mode == .Words) {
				append(&resizable, c_idx)
			}
			if c_sizing.kind == .Grow {
				grow_count += 1
			}
		}
		if along_axis {
			inner_content += total_gaps
		}

		if along_axis {
			to_distribute := parent_size - parent_pad - inner_content

			// 2a. Overflow compression: water-draining largest children down toward min_dims
			if to_distribute < 0 && !((x_axis && parent.clip_h) || (!x_axis && parent.clip_v)) {
				for to_distribute < 0 && len(resizable) > 0 {
					largest: i32 = 0
					second_largest: i32 = 0
					for c_idx in resizable {
						sz := ctx.nodes[c_idx].dims[axis]
						if sz > largest {
							second_largest = largest
							largest = sz
						} else if sz < largest {
							second_largest = max(second_largest, sz)
						}
					}
					if largest == 0 {
						break
					}

					// Count how many children are tied at largest
					largest_count: i32 = 0
					for c_idx in resizable {
						if ctx.nodes[c_idx].dims[axis] == largest {
							largest_count += 1
						}
					}

					step_down := largest - second_largest
					even_share := max(1, (-to_distribute) / largest_count)
					delta := min(step_down, even_share) if second_largest > 0 else even_share
					delta = max(1, delta)

					i := 0
					for i < len(resizable) && to_distribute < 0 {
						c_idx := resizable[i]
						child := &ctx.nodes[c_idx]
						if child.dims[axis] == largest {
							prev := child.dims[axis]
							min_sz := child.min_dims[axis]
							actual_cut := min(delta, -to_distribute)
							child.dims[axis] = max(min_sz, prev - actual_cut)
							to_distribute += (prev - child.dims[axis])
							if child.dims[axis] <= min_sz {
								unordered_remove(&resizable, i)
								continue
							}
						}
						i += 1
					}
				}
			} else if to_distribute > 0 && grow_count > 0 {
				// 2b. Underflow expansion: water-filling smallest Grow children up toward max
				i := 0
				for i < len(resizable) {
					c_idx := resizable[i]
					c_sizing := ctx.nodes[c_idx].sizing.width if x_axis else ctx.nodes[c_idx].sizing.height
					if c_sizing.kind != .Grow || ctx.nodes[c_idx].dims[axis] >= c_sizing.max {
						unordered_remove(&resizable, i)
					} else {
						i += 1
					}
				}

				for to_distribute > 0 && len(resizable) > 0 {
					smallest: i32 = MAX_DIM
					second_smallest: i32 = MAX_DIM
					for c_idx in resizable {
						sz := ctx.nodes[c_idx].dims[axis]
						if sz < smallest {
							second_smallest = smallest
							smallest = sz
						} else if sz > smallest {
							second_smallest = min(second_smallest, sz)
						}
					}

					smallest_count: i32 = 0
					for c_idx in resizable {
						if ctx.nodes[c_idx].dims[axis] == smallest {
							smallest_count += 1
						}
					}

					step_up := second_smallest - smallest
					even_share := max(1, to_distribute / smallest_count)
					delta := min(step_up, even_share) if second_smallest < MAX_DIM else even_share
					delta = max(1, delta)

					j := 0
					for j < len(resizable) && to_distribute > 0 {
						c_idx := resizable[j]
						child := &ctx.nodes[c_idx]
						c_sizing := child.sizing.width if x_axis else child.sizing.height
						if child.dims[axis] == smallest {
							prev := child.dims[axis]
							add := min(delta, to_distribute)
							child.dims[axis] = min(c_sizing.max, prev + add)
							to_distribute -= (child.dims[axis] - prev)
							if child.dims[axis] >= c_sizing.max {
								unordered_remove(&resizable, j)
								continue
							}
						}
						j += 1
					}
				}
			}
		} else {
			// Off-axis sizing
			max_avail := max(0, parent_size - parent_pad)
			if (x_axis && parent.clip_h) || (!x_axis && parent.clip_v) {
				max_avail = max(max_avail, inner_content)
			}
			for c_idx in resizable {
				child := &ctx.nodes[c_idx]
				c_sizing := child.sizing.width if x_axis else child.sizing.height
				min_sz := child.min_dims[axis]
				if c_sizing.kind == .Grow {
					child.dims[axis] = min(max_avail, c_sizing.max)
				}
				child.dims[axis] = max(min_sz, min(child.dims[axis], max_avail))
			}
		}
	}
}

@(private)
wrap_text_and_repropagate_heights :: proc(ctx: ^Layout_Context) {
	// Wrap text nodes against their resolved widths
	for i in 0 ..< len(ctx.nodes) {
		node := &ctx.nodes[i]
		if !node.is_text {
			continue
		}
		node.wrapped_lines = make([dynamic]string, 0, 4, ctx.nodes.allocator)
		max_w := max(1, node.dims.x)
		if node.wrap_mode == .None {
			append(&node.wrapped_lines, node.text)
			node.dims.y     = 1
			node.min_dims.y = 1
			continue
		}

		// Split by explicit newlines first, then word-wrap each paragraph
		rem := node.text
		for len(rem) > 0 {
			nl_idx := -1
			for b_idx in 0 ..< len(rem) {
				if rem[b_idx] == '\n' {
					nl_idx = b_idx
					break
				}
			}
			para := rem[:nl_idx] if nl_idx >= 0 else rem
			rem = rem[nl_idx + 1:] if nl_idx >= 0 else ""

			if len(para) == 0 || string_display_width(para) <= max_w || node.wrap_mode == .Newlines {
				append(&node.wrapped_lines, para)
				continue
			}

			// Word-wrap paragraph within max_w columns
			line_start := 0
			line_w: i32 = 0
			word_start := 0
			word_w: i32 = 0
			in_word := false

			for r, byte_pos in para {
				rw := i32(rune_display_width(r))
				if r == ' ' {
					if in_word {
						if line_w > 0 && line_w + 1 + word_w > max_w {
							append(&node.wrapped_lines, para[line_start:word_start - 1])
							line_start = word_start
							line_w = word_w
						} else {
							line_w = (line_w + 1 + word_w) if line_w > 0 else word_w
						}
						in_word = false
						word_w = 0
					}
				} else {
					if !in_word {
						word_start = byte_pos
						in_word = true
						word_w = rw
					} else {
						word_w += rw
					}
				}
			}
			if in_word {
				if line_w > 0 && line_w + 1 + word_w > max_w {
					append(&node.wrapped_lines, para[line_start:word_start - 1])
					line_start = word_start
				}
			}
			if line_start < len(para) {
				append(&node.wrapped_lines, para[line_start:])
			}
		}

		line_count := max(1, i32(len(node.wrapped_lines)))
		node.dims.y     = line_count
		node.min_dims.y = line_count
	}

	// Reverse topological pass: propagate wrapped text heights up through Fit/Grow ancestors
	for i := len(ctx.nodes) - 1; i >= 0; i -= 1 {
		node := &ctx.nodes[i]
		if node.is_text || len(node.children) == 0 {
			continue
		}
		if node.sizing.height.kind == .Fixed || node.sizing.height.kind == .Percent {
			continue
		}

		pad_y := node.padding.top + node.padding.bottom
		if node.dir == .Left_To_Right {
			max_h := node.dims.y
			min_h := node.min_dims.y
			for c_idx in node.children {
				child := &ctx.nodes[c_idx]
				max_h = max(max_h, child.dims.y + pad_y)
				if !node.clip_v {
					min_h = max(min_h, child.min_dims.y + pad_y)
				}
			}
			node.dims.y     = clamp(max_h, node.sizing.height.min, node.sizing.height.max)
			node.min_dims.y = clamp(min_h, node.sizing.height.min, node.sizing.height.max)
		} else {
			sum_h := pad_y + max(0, i32(len(node.children)) - 1) * node.child_gap
			min_h := sum_h
			for c_idx in node.children {
				child := &ctx.nodes[c_idx]
				sum_h += child.dims.y
				if !node.clip_v {
					min_h += child.min_dims.y
				}
			}
			node.dims.y     = clamp(sum_h, node.sizing.height.min, node.sizing.height.max)
			node.min_dims.y = clamp(min_h, node.sizing.height.min, node.sizing.height.max)
		}
	}
}

@(private)
attach_offset_x :: proc(pt: Attach_Point, w: i32) -> i32 {
	#partial switch pt {
	case .Center_Top, .Center_Center, .Center_Bottom: return w / 2
	case .Right_Top, .Right_Center, .Right_Bottom:   return w
	}
	return 0
}

@(private)
attach_offset_y :: proc(pt: Attach_Point, h: i32) -> i32 {
	#partial switch pt {
	case .Left_Center, .Center_Center, .Right_Center: return h / 2
	case .Left_Bottom, .Center_Bottom, .Right_Bottom: return h
	}
	return 0
}

@(private)
position_subtree :: proc(ctx: ^Layout_Context, node_idx: i32, pos: [2]i32, active_clip: Rect) {
	node := &ctx.nodes[node_idx]
	rect := Rect{x = pos.x, y = pos.y, w = node.dims.x, h = node.dims.y}
	if node.floating.attach_to != .None {
		rect.x -= node.floating.expand.x
		rect.y -= node.floating.expand.y
		rect.w += node.floating.expand.x * 2
		rect.h += node.floating.expand.y * 2
	}
	node.rect      = rect
	node.clip_rect = active_clip

	if node.is_text || len(node.children) == 0 {
		return
	}

	child_clip := active_clip
	if node.clip_h || node.clip_v {
		clip_box := active_clip
		if node.clip_h {
			clip_box.x = rect.x
			clip_box.w = rect.w
		}
		if node.clip_v {
			clip_box.y = rect.y
			clip_box.h = rect.h
		}
		child_clip = rect_intersect(active_clip, clip_box)
	}

	pad_x := node.padding.left + node.padding.right
	pad_y := node.padding.top + node.padding.bottom
	gaps  := max(0, i32(len(node.children)) - 1) * node.child_gap

	cur_x := rect.x + node.padding.left + node.scroll_offset.x
	cur_y := rect.y + node.padding.top + node.scroll_offset.y

	if node.dir == .Left_To_Right {
		content_w := gaps
		for c_idx in node.children {
			content_w += ctx.nodes[c_idx].dims.x
		}
		extra_x := max(0, rect.w - pad_x - content_w)
		switch node.align_x {
		case .Left:   // no offset
		case .Center: cur_x += extra_x / 2
		case .Right:  cur_x += extra_x
		}

		for c_idx in node.children {
			child := &ctx.nodes[c_idx]
			extra_y := max(0, rect.h - pad_y - child.dims.y)
			cy := rect.y + node.padding.top + node.scroll_offset.y
			switch node.align_y {
			case .Top:    // no offset
			case .Center: cy += extra_y / 2
			case .Bottom: cy += extra_y
			}
			position_subtree(ctx, c_idx, {cur_x, cy}, child_clip)
			cur_x += child.dims.x + node.child_gap
		}
	} else {
		content_h := gaps
		for c_idx in node.children {
			content_h += ctx.nodes[c_idx].dims.y
		}
		extra_y := max(0, rect.h - pad_y - content_h)
		switch node.align_y {
		case .Top:    // no offset
		case .Center: cur_y += extra_y / 2
		case .Bottom: cur_y += extra_y
		}

		for c_idx in node.children {
			child := &ctx.nodes[c_idx]
			extra_x := max(0, rect.w - pad_x - child.dims.x)
			cx := rect.x + node.padding.left + node.scroll_offset.x
			switch node.align_x {
			case .Left:   // no offset
			case .Center: cx += extra_x / 2
			case .Right:  cx += extra_x
			}
			position_subtree(ctx, c_idx, {cx, cur_y}, child_clip)
			cur_y += child.dims.y + node.child_gap
		}
	}
}

end_layout :: proc(ctx: ^Layout_Context) {
	// Close implicit root container
	if len(ctx.open_stack) == 1 {
		close_element(ctx)
	}
	assert(len(ctx.open_stack) == 0, "Unbalanced open_element / close_element calls")
	assert(len(ctx.clip_stack) == 0, "Unbalanced clip_stack")

	// Phase 2: Top-down X-axis sizing
	size_axis(ctx, true)

	// Phase 3 & 4: Wrap text to resolved widths & re-propagate heights bottom-up
	wrap_text_and_repropagate_heights(ctx)

	// Phase 5: Top-down Y-axis sizing
	size_axis(ctx, false)

	// Phase 6a: Resolve positions in declaration order so floating anchors always have valid parent rects
	viewport_clip := Rect{0, 0, ctx.viewport.x, ctx.viewport.y}
	for root in ctx.roots {
		root_node := &ctx.nodes[root.node_idx]
		root_pos := [2]i32{0, 0}
		root_clip := viewport_clip

		if root_node.floating.attach_to != .None {
			if p_idx, ok := ctx.id_map[root.parent_id]; ok {
				p_rect := ctx.nodes[p_idx].rect
				cfg := root_node.floating
				root_pos.x = p_rect.x + attach_offset_x(cfg.parent_attach, p_rect.w) - attach_offset_x(cfg.element_attach, root_node.dims.x) + cfg.offset.x
				root_pos.y = p_rect.y + attach_offset_y(cfg.parent_attach, p_rect.h) - attach_offset_y(cfg.element_attach, root_node.dims.y) + cfg.offset.y
			}
			if root.clip_id != 0 {
				if c_idx, ok := ctx.id_map[root.clip_id]; ok {
					root_clip = rect_intersect(viewport_clip, ctx.nodes[c_idx].rect)
				}
			}
		}
		position_subtree(ctx, root.node_idx, root_pos, root_clip)
	}

	// Phase 6b: Sort roots by ascending (z_index, decl_order) for painter's order rendering
	slice.sort_by(ctx.roots[:], proc(a, b: Tree_Root) -> bool {
		if a.z_index != b.z_index {
			return a.z_index < b.z_index
		}
		return a.decl_order < b.decl_order
	})
}

```

---

#### 3. Layer 3 Protocol Driver Invariant Checks (`tests/support/driver_bifrost.odin`)

```odin
package test_support

import "core:strings"
import "core:testing"
import "../../bifrost"

Bifrost_Driver :: struct {
	front:       bifrost.Screen,
	back:        bifrost.Screen,
	layout_ctx:  bifrost.Layout_Context,
	ansi_output: strings.Builder,
}

// Automatically invoked at the end of every rendered frame in Layer 3.
assert_frame_invariants :: proc(t: ^testing.T, drv: ^Bifrost_Driver) {
	// Invariant 1: Layout stacks balanced & all nodes have valid non-negative rects and clip bounds
	testing.expect_value(t, len(drv.layout_ctx.open_stack), 0)
	testing.expect_value(t, len(drv.layout_ctx.clip_stack), 0)

	viewport_rect := bifrost.Rect{0, 0, drv.front.width, drv.front.height}
	for node in drv.layout_ctx.nodes {
		testing.expect(t, node.rect.w >= 0 && node.rect.h >= 0, "Negative node dimensions")
		clipped := bifrost.rect_intersect(node.clip_rect, viewport_rect)
		testing.expect_value(t, node.clip_rect, clipped)

		// Verify in-flow siblings are monotonically ordered along main axis
		if len(node.children) > 1 {
			for i in 0 ..< len(node.children) - 1 {
				c1 := drv.layout_ctx.nodes[node.children[i]]
				c2 := drv.layout_ctx.nodes[node.children[i + 1]]
				if node.dir == .Left_To_Right {
					testing.expect(t, c2.rect.x >= c1.rect.x + c1.rect.w + node.child_gap, "Overlapping X siblings")
				} else {
					testing.expect(t, c2.rect.y >= c1.rect.y + c1.rect.h + node.child_gap, "Overlapping Y siblings")
				}
			}
		}
	}

	// Invariant 2: Wide-cell lead/spacer pairing, control-code hygiene, and front/back parity
	w := drv.front.width
	h := drv.front.height
	for y in 0 ..< h {
		for x in 0 ..< w {
			idx := int(y * w + x)
			fc := drv.front.cells[idx]
			bc := drv.back.cells[idx]

			testing.expect(t, bifrost.cells_equal(fc, bc), "Front and back cell mismatch after diff")
			testing.expect(t, fc.width <= 2, "Invalid cell width > 2")

			if fc.width == 2 {
				testing.expect(t, x + 1 < w, "Wide lead cell on rightmost screen column")
				testing.expect(t, fc.rune >= 32, "Wide lead cell has control rune")
				if x + 1 < w {
					spacer := drv.front.cells[idx + 1]
					testing.expect_value(t, spacer.width, u8(0))
					testing.expect_value(t, spacer.rune, rune(0))
					testing.expect(t, bifrost.colors_equal(fc.fg, spacer.fg), "Wide spacer fg mismatch")
					testing.expect(t, bifrost.colors_equal(fc.bg, spacer.bg), "Wide spacer bg mismatch")
					testing.expect_value(t, spacer.attrs, fc.attrs)
				}
			} else if fc.width == 0 {
				testing.expect(t, x > 0, "Orphaned spacer at column 0")
				testing.expect_value(t, fc.rune, rune(0))
				if x > 0 {
					lead := drv.front.cells[idx - 1]
					testing.expect_value(t, lead.width, u8(2))
				}
			} else {
				testing.expect(t, fc.rune >= 32 && !(fc.rune >= 0x7f && fc.rune < 0xa0), "Control rune in narrow cell")
			}
		}
	}

	// Invariant 3: Idempotent 0-byte clean diff on unchanged frame
	second_diff := strings.builder_make(context.temp_allocator)
	bifrost.screen_diff_ansi(&drv.front, &drv.back, &second_diff)
	testing.expect_value(t, strings.builder_len(second_diff), 0)
}

```
