# Specification: Track 21 — Million-Row Table UI Enhancements, 2D Column Virtualization & Zero-Copy CSV Workbench (`table_ui_enhancements_20261109`)

## Overview
Distill the architectural principles from the research docs in this track (`Odin GPU Data Grid Architecture.md`, `High-Performance Spreadsheet Grid Rendering.md`, and `ui_tables_code_example.md`)—stripping away Web/DOM/GPU shader overhead and applying the core data-oriented, zero-allocation algorithms directly to Bifrost's native terminal cell grid (`bifrost/table.odin`, `bifrost/scroll.odin`, `bifrost/renderer.odin`, `bifrost/csv_grid.odin`).

The goal is to load real multi-megabyte / million-row CSV datasets (including the HubSpot and PitchBook datasets from `bragi/benchmarks/data/` and synthetic 1,000,000+ row expansions) and scroll, pan across 200+ columns, sort, filter, resize columns, and inspect records **instantly (`< 1 ms` per frame, `0` per-frame heap allocations)** without rendering glitches, ANSI cursor drift, or truncation bottlenecks.

---

## Deep-Dive Codebase & Research Audit: 10 Critical Findings

Cross-referencing the 3 research documents against Bifrost's actual implementation (`bifrost/table.odin`, `bifrost/scroll.odin`, `bifrost/renderer.odin`, `bifrost/input.odin`, `bifrost/spatial_nav.odin`) and `bragi/benchmarks/data/*.csv` revealed **10 concrete bottlenecks and edge cases** that must be solved together:

### 1. Embedded Multiline Quotes in `Person.csv` & `all-companies.csv` (`30,352` physical lines vs. `15,787` logical records)
- **Empirical Data from `bragi/benchmarks/data/`:**
  - `Person.csv` (`33 MB`, `50` columns) has `30,352` physical newline characters (`\n`), **but only `15,787` actual CSV records**! Over `14,500` newlines are embedded *inside* double-quoted biography and education fields.
  - `all-companies.csv` (`8.1 MB`, `190` columns) has `4,013` physical lines, **but only `3,489` actual CSV records** (`524` embedded multiline newlines).
  - `LPDirectInvestmentRelation.csv` (`9.0 MB`, `7` columns) has `74,356` data rows (`0` embedded newlines).
- **Impact:** A naive line splitter (`strings.split_lines`) corrupts nearly 50% of the rows in `Person.csv` and `15%` of `all-companies.csv`.
- **Solution (`core:simd` + `core:mem/virtual` Sparse Checkpoint Indexer):**
  - Use the research doc's **SIMD `u8x32` quote-parity prefix-XOR newline scanner** (`build_csv_sparse_row_index` in `Odin GPU Data Grid Architecture.md` Section 5) so newlines inside `"..."` are masked out at `> 1 GB/s`.
  - Store **64-row sparse checkpoints** (`checkpoints[row >> 6]`, requiring only `125 KB` of RAM for `1,000,000` rows instead of `8 MB` for dense offsets) and map files zero-copy via `vmem.map_file_from_path`.

### 2. ANSI Terminal Cursor Drift on Astral Unicode (`U+2026` `…`, `▲`, `▼`) in `screen_diff_ansi`
- **Codebase Audit (`bifrost/renderer.odin` lines 992 & 1033):**
  - In `screen_diff_ansi`, Bifrost re-anchors the terminal cursor (`cur_x = -1, cur_y = -1`) after runes `>= 0x2300` (excluding `0x2500..0x259f` box drawing and `0x2800..0x28ff` Braille) because terminal emulators (Kitty, Alacritty, WezTerm, VTE, Windows Terminal) frequently disagree on ambiguous/astral glyph widths.
  - However, `…` (`U+2026`, Horizontal Ellipsis) and `▸`/`▾`/`▲`/`▼` (`U+25B2..U+25BE`, Geometric Shapes) sit in `0x2000..0x22FF` and `0x25A0..0x25FF`! Currently:
    - Line 992 triggers `force_row_flush = true` whenever `ch >= 0x2000`, forcing the entire rest of the terminal row to re-emit over PTY when a single `…` or `│` changes.
    - Line 1033 does **not** re-anchor `cur_x = -1` after `U+2026` (`…`) or `U+25B2..U+25FF` (`▲`, `▼`, `▸`), so if a terminal font renders `…` or `▲` with slightly different advance or ambiguous width, every subsequent column on that row shifts horizontally!
- **Solution (`bifrost/renderer.odin`):**
  - Narrow `force_row_flush` at line 992 so standard 1-cell box-drawing (`0x2500..0x257F`), block elements (`0x2580..0x259F`), and Braille (`0x2800..0x28FF`) do **not** force full-row PTY flushes (cutting ANSI diff bytes per scroll frame by 60–80% on wide tables).
  - Explicitly include `0x2026` (`…`) and `0x25A0..0x25FF` (`▲`, `▼`, `▸`, `▾`) in the cursor re-anchor check or keep them strictly 1-cell safe so column borders never drift.

### 3. `Scroll_Slot` Bloat inside `Input_State` When Lifting `MAX_TABLE_COLS` from `16` to `256`
- **Codebase Audit (`bifrost/scroll.odin` lines 548–580, `bifrost/input.odin` line 345):**
  - `Input_State` embeds `scroll_slots: [MAX_SCROLL_SLOTS]Scroll_Slot` (`32` slots) by value.
  - Each `Scroll_Slot` currently embeds `col_specs: [MAX_TABLE_COLS]Table_Column_Spec` (`40 B` each) plus 3 `i16` arrays (`col_max_observed`, `col_x_starts`, `col_x_widths`).
  - If we simply change `MAX_TABLE_COLS :: 16` to `256` on `Scroll_Slot`, each `Scroll_Slot` balloons from `~800 B` to **`~12 KB`**, bloating `Input_State` by **`~384 KB`** (blowing L1/L2 cache on every `Input_State` copy in tests and actors)!
- **Solution (`#soa` / Compact Column State):**
  - Store only compact per-column arrays on `Scroll_Slot` (`col_max_observed: [MAX_TABLE_COLS]i16`, `col_user_width: [MAX_TABLE_COLS]i16`, `col_x_starts: [MAX_TABLE_COLS]i16`, `col_x_widths: [MAX_TABLE_COLS]i16` — `8 bytes * 256 = 2 KB` per slot, fitting in L1 cache just like the `#soa[]Column_State` design in `Odin GPU Data Grid Architecture.md` Section 1) instead of duplicating the 40-byte `Table_Column_Spec` struct 256 times inside `Scroll_Slot`.

### 4. `sync_scroll_viewports` Overwrites `slot.total_rows` and `slot.total_content_w` on Virtual Tables!
- **Codebase Audit (`bifrost/scroll.odin` lines 768–771 & `bifrost/layout.odin` line 1248):**
  - In `position_nodes_topological` (`layout.odin:1248`), when a virtualized table has `child_count == 0` (because `ui_table` renders rows via `s.table_entries` rather than creating child `Layout_Node`s), `parent.content_span[0]` is set to `parent.inner_rect.w`!
  - Then in `sync_scroll_viewports` (`scroll.odin:769`), `slot.total_content_w = node.content_span[0]` overwrites `slot.total_content_w` with `inner_rect.w`, setting `slot.max_offset_x = 0`!
  - That means **horizontal scrolling (`slot.offset_x`) is currently impossible on `ui_table`** because `sync_scroll_viewports` wipes out `total_content_w` and clamps `slot.offset_x` to `0` every frame!
- **Solution (`bifrost/scroll.odin`, `bifrost/table.odin`):**
  - When a scrollable node has table columns (`col_spec_count > 0` or `total_content_w > inner_rect.w`), compute `total_content_w` from the sum of resolved column widths + spacing + gutter, write that back into `node.content_span[0]` and `slot.total_content_w`, and compute `slot.max_offset_x = max(0, slot.total_content_w - scrollable_viewport_w)`.

### 5. Column-First Culled Cell Submission (`ui_table_next_cell` / `visible_cols` Mask)
- **Research Synthesis (`Odin GPU Data Grid Architecture.md` Section 1 & 5, `ui_tables_code_example.md`):**
  - When viewing `all-companies.csv` (`190` columns) on a 120-column terminal, only `~6–10` columns are visible on screen at any horizontal scroll position (`slot.offset_x`).
  - If the caller's row loop extracts, formats, and copies all `190` cells per row into `ui_table_row`, `95%` of the per-frame CPU work and `temp_allocator` memory is wasted on off-screen columns!
- **Solution (`Virtual_Slice` Visible Column Window + Culled Cell Helpers):**
  - Expose `pinned_cols: i32`, `start_col: i32` (first visible scrollable column), and `end_col: i32` (one past last visible scrollable column) directly on `Virtual_Slice`, plus an inline helper `ui_table_is_col_visible(slice, col_idx)`.
  - For wide tables (`190` cols), the caller (or `csv_grid`) only formats/extracts cells where `col < slice.pinned_cols || (col >= slice.start_col && col < slice.end_col)`, reducing per-frame work from `O(viewport_rows * total_cols)` to strictly **`O(viewport_rows * visible_cols)`** (`~30 * 8 = 240` cells instead of `30 * 190 = 5,700` cells!).

### 6. Unbounded `O(len(cell_text))` String Width Measurement & Multi-KB Bio Cells
- **Empirical Data from `bragi/benchmarks/data/`:**
  - `Person.csv` contains biography cells over `4,500` bytes long with embedded `\r\n` newlines.
  - Currently `table_column_observe_cell` and `draw_table_cell` call `string_display_width(text)`, walking every byte of the 4.5 KB string on every frame even when the column is capped at `max_width = 32` cells.
- **Solution:**
  - Add **`string_display_width_bounded(text, max_cols)`** and **`draw_table_cell_truncated`** that sanitize control runes (`\n`, `\r`, `\t` -> `' '`), stop scanning the instant `cur_w > span.width`, and render a single-cell `…` (`U+2026`) ellipsis when truncated—bounding cell rendering to `O(span.width)`.

### 7. Frame-0 Auto-Sizing Sample & Double-Click / Key Reset (`0` / `=`)
- **Research Synthesis (`Odin GPU Data Grid Architecture.md` Section 1 "Solving the Auto-Sizing Dilemma"):**
  - Monotonic ratcheting (`max_observed_w`) prevents horizontal border jitter during scrolling, *but* if a user scrolls past one outlier row with a 120-char string and then scrolls away, or manually resizes a column and wants to snap it back to the current viewport's content width, they need a way to reset/re-fit.
- **Solution:**
  - Add `auto_size_this_frame: bool` (triggered by pressing `0` / `=` on the selected column or double-clicking a column divider) which resets `col_max_observed[c]` and `col_user_width[c]` so the column snaps tightly to the current visible viewport's content width.

### 8. Dual-Mode Scrollbar Dragging vs. Local Delta Scrolling
- **Research Synthesis (`Odin GPU Data Grid Architecture.md` Section 3 & `High-Performance Spreadsheet Grid Rendering.md` Section 4):**
  - Bifrost already uses integer `slot.offset` (`anchor_row`) and 64-bit integer math in `compute_scrollbar_metrics` (`scroll.odin:152`), so it never suffers from `f32` `2^24` mantissa precision loss.
  - *However*, Bifrost's vertical and horizontal scrollbars (`draw_vertical_scrollbar`, `draw_horizontal_scrollbar`) are currently **display-only**—clicking or dragging the scrollbar track/thumb with the mouse does nothing!
- **Solution:**
  - Add mouse hit-testing on the right vertical scrollbar track (`sb_x`) and bottom horizontal scrollbar track (`sb_y`) inside `handle_mouse_event`: clicking or dragging along the scrollbar track maps the mouse coordinate `(my - track_y)` / `(mx - track_x)` via 64-bit integer ratio (`i64(rel_y) * i64(max_offset) / i64(max(1, track_h - 1))`) directly to `slot.offset` / `slot.selected_row`, allowing instant 1-drag jumps across 1,000,000 rows!

### 9. Dual-Representation Multi-Row Selection (`Interval` + `Bitset`) & Zero-Copy Permutation View
- **Research Synthesis (`Odin GPU Data Grid Architecture.md` Section 4):**
  - Storing selection as a naive map or dynamic array of row IDs stalls when selecting ranges across 1M rows (`Ctrl+A` or `Shift+G`).
  - Storing sort/filter results by copying row data allocates megabytes on every keypress.
- **Solution:**
  - Implement **`Table_Selection_Set`** using sorted disjoint `[2]i32` intervals `[start_row, end_row]` (plus an `invert_all: bool` flag for `O(1)` Select All) so range selections take `16 bytes` per interval and membership queries take `O(log I)`.
  - Implement **`CSV_Grid_Table`** with a flat `row_perm: [dynamic]u32` (`4 MB` at `1M` rows; `0 B` when identity/unfiltered) mapping `visual_row -> physical_row`.
  - Pre-compute a lightweight **column sort key cache** (or numeric `f64` / prefix key slice on `context.temp_allocator` or arena during sort) when sorting a column so `slice.sort` compares 64-bit numbers/keys instead of re-tokenizing CSV rows inside the `O(N log N)` comparator! (This is a critical insight: re-scanning a CSV row from the 64-row checkpoint *inside* `O(N log N)` comparator calls would do `20M` CSV row scans for `1M` rows; extracting a contiguous `(key, row_idx)` slice in a single linear `O(N)` pass before sorting makes sorting `100K–1M` rows `20x` faster!)

### 10. 2D Spatial Navigation & Horizontal Auto-Scroll When Stepping Across `200+` Columns
- **Codebase Audit (`bifrost/spatial_nav.odin` lines 507–544):**
  - When pressing `l` / `Right` or `h` / `Left` inside `ui_table`, `handle_spatial_nav_at_level` updates `slot.selected_col`, **but never updates `slot.offset_x`**! So when `selected_col` moves past the right edge of the terminal viewport (e.g. column 8 of 190), the active cell highlight walks off-screen while the viewport stays stuck at column 0!
  - Furthermore, there are no fast horizontal jump motions (`0` / `^` for first column, `$` for last column, `H` / `L` or `Shift+Left` / `Shift+Right` for horizontal page scroll).
- **Solution (`bifrost/spatial_nav.odin`, `bifrost/scroll.odin`):**
  - Add `ensure_virtual_col_visible(slot)` called whenever `slot.selected_col` changes (via keyboard `h`/`l`, `0`/`$`, or mouse click): if `selected_col >= pinned_cols`, automatically clamp `slot.offset_x` so `selected_col`'s `[col_x, col_x + col_w]` is fully visible within the scrollable right quadrant.

---

## Benchmark & Example Datasets (from `bragi/benchmarks/data/`)

| Dataset File | Physical Lines | Actual CSV Records | Columns | File Size | Primary Stress-Test Role |
| :--- | ---: | ---: | ---: | ---: | :--- |
| `pitchbook/LPDirectInvestmentRelation.csv` | `74,357` | `74,356` | `7` | `9.0 MB` | High row count (`74.3K` rows), fast numeric/date sorting & filtering |
| `pitchbook/Person.csv` | `30,352` | `15,787` | `50` | `33.0 MB` | **50 columns**, **14,500+ embedded multiline newlines**, multi-KB biography truncation (`…`) |
| `hubspot/all-companies.csv` | `4,013` | `3,489` | `190` | `8.1 MB` | **190 wide columns**, frozen left columns (`pinned_cols`), culled column rendering |
| `hubspot/all-contacts.csv` | `9,057` | `8,998` | `65` | `17.0 MB` | Wide contact table with mixed emails, URLs, timestamps, and sparse empty columns |
| **Synthetic `1,000,000`-Row Scale Mode** | — | `1,000,000` | `7..190` | Zero-copy virtual multiplier | Stress-tests `1,000,000` rows for instant scrollbar thumb drag, `O(1)` viewport slicing, and permutation indexing |

---

## Functional Requirements

1. **256-Column Capacity, Frozen Left Columns (`pinned_cols`) & 2D Horizontal Virtualization (`bifrost/table.odin`, `bifrost/scroll.odin`):**
   - Lift `MAX_TABLE_COLS` from `16` to `256` with compact L1-friendly per-column arrays on `Scroll_Slot`.
   - Support `pinned_cols: i32` on `Table_Config` and `Scroll_Slot`: columns `0 ..< pinned_cols` remain anchored on the left, separated by a double vertical divider (`║` on header/rows, `╫` on header separator), while columns `pinned_cols ..< total_cols` scroll horizontally by `-slot.offset_x` and are clipped to the right quadrant.
   - Populate `pinned_cols`, `start_col`, and `end_col` on `Virtual_Slice` and provide `ui_table_is_col_visible(slice, col_idx)` so callers can skip formatting off-screen columns.
   - Automatically scroll horizontally (`ensure_virtual_col_visible`) when `selected_col` changes, and render the bottom horizontal scrollbar (`━` over `─`) when `total_content_w > inner_rect.w`.

2. **Bounded `O(span.width)` Cell Measurement, Newline Sanitization, `…` Ellipsis & ANSI Cursor Stability (`bifrost/scroll.odin`, `bifrost/table.odin`, `bifrost/renderer.odin`):**
   - Implement `string_display_width_bounded(str: string, max_cols: i32) -> (width: i32, truncated: bool)` that maps `\n`, `\r`, `\t` to `' '` and stops scanning once `width > max_cols`.
   - Cap `table_column_observe_cell` scanning to `max_cols` (default `64` or `spec.max_width`) so multi-KB biography strings never trigger full-string scans.
   - Render `…` (`U+2026`) at the right edge of truncated cells in `draw_table_cell`, and update `screen_diff_ansi` in `bifrost/renderer.odin` so box-drawing/table runes don't trigger unnecessary full-row flushes and `…` / `▲` / `▼` never cause cursor drift.

3. **Interactive Column Sorting (`▲`/`▼`), Mouse/Keyboard Resizing, Auto-Fit Reset & Scrollbar Thumb Dragging (`bifrost/table.odin`, `bifrost/scroll.odin`, `bifrost/input.odin`):**
   - Header click or `s` key cycles `Table_Sort_Dir` (`.None -> .Asc -> .Desc`) on the clicked/selected column and renders `▲` / `▼` in the sticky header.
   - Mouse drag on column dividers (`│` / `║`) or `+`/`-` keys resize `slot.col_user_width[col]`; `0` / `=` or double-clicking a divider resets to auto-fit.
   - Clicking or dragging the vertical or horizontal scrollbar track jumps `slot.offset` / `slot.offset_x` proportionally using 64-bit integer math.
   - Support `follow_tail: bool` auto-scroll pinning with automatic unpin on upward scroll and re-pin on `G` / `End`, plus `Table_Selection_Set` interval selection (`Space` toggle, `Shift+Up/Down` range select, `Ctrl+A` select all).

4. **SIMD Zero-Copy CSV Indexer & Single-Pass Sort/Filter Engine (`bifrost/csv_grid.odin`):**
   - Memory-mapped or buffer-backed `CSV_Grid_Table` using SIMD `u8x32` quote-parity newline scanning (`64`-row sparse checkpoints) that accurately indexes multiline quoted fields in `Person.csv` and `all-companies.csv`.
   - Zero-allocation viewport cell slicing (`csv_grid_slice_row`) that only parses visible rows (`30–50` per frame).
   - Single-pass `O(N)` sort-key extraction + `row_perm: [dynamic]u32` permutation sorting (numeric-aware + case-insensitive string) and fast substring filtering, plus 1-click virtual scaling to `1,000,000` rows.

5. **Interactive Million-Row CSV & Data Grid Workbench (`examples/csv_workbench/main.odin`):**
   - Flagship terminal workbench loading the `bragi` benchmark CSVs (`LPDirectInvestmentRelation.csv`, `Person.csv`, `all-companies.csv`, `all-contacts.csv`, or any CLI file path) with a `1,000,000`-row scale toggle (`m`), frozen left columns toggle (`p`), column sort (`s` / header click), column resize (`+`/`-`/`0` / mouse drag), live filter (`/`), multi-row selection (`Space`), full-field record detail modal (`Enter` to inspect full multiline biographies), and live 30 FPS / CPU / VmRSS / Frame-Time HUD.

---

## Acceptance Criteria
- `CSV_Grid_Table` accurately indexes multiline quoted CSVs (`15,787` records in `Person.csv`, `3,489` records in `all-companies.csv`, `74,356` records in `LPDirectInvestmentRelation.csv`) in `< 15 ms` using SIMD quote-parity scanning.
- `ui_table` renders `190` columns (`all-companies.csv`) and `1,000,000` virtual rows at 30 FPS (`< 1 ms` CPU layout/render time per frame, `0` persistent heap allocations per frame) with frozen left columns (`pinned_cols`), horizontal auto-scroll, scrollbar thumb dragging, and `O(span.width)` `…` cell truncation.
- All new features are verified by unit tests (`odin test bifrost`), AST temp-hygiene linter (`--lint-temp`), and 4-layer `@(scenario)` ATDD specifications (`odin test tests`) with zero memory leaks.
