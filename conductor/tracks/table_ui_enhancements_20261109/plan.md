# Implementation Plan: `table_ui_enhancements_20261109`

## Phase 1: Benchmark CSV Fixtures & SIMD Zero-Copy CSV Grid Engine (`bifrost/csv_grid.odin`)
- [x] Task 1.1: Copy benchmark CSV datasets (`LPDirectInvestmentRelation.csv`, `Person.csv`, `all-companies.csv`, `all-contacts.csv`) from `/home/pauli/projects/odin/bragi/benchmarks/data/` into `benchmarks/data/` and add `benchmarks/data/` to `.gitignore` and `.gdumpignore`.
- [x] Task 1.2: Implement `bifrost/csv_grid.odin` (`CSV_Grid_Table` & `Table_Selection_Set`):
    - [x] Implement SIMD `u8x32` RFC 4180 quote-parity newline scanner (`build_csv_sparse_row_index`) with 64-row sparse byte-offset checkpoints (`125 KB` per `1M` rows) and optional `core:mem/virtual` file mapping (`vmem.map_file_from_path`), accurately handling the `14,500+` embedded multiline newlines in `Person.csv`.
    - [x] Implement zero-allocation per-frame row tokenizer `csv_grid_slice_row(grid, physical_row, out_cells, allocator)` that resolves the nearest 64-row checkpoint, scans at most 63 records in L1 cache, and slices fields directly from the backing buffer.
    - [x] Implement `row_perm: [dynamic]u32` permutation view with **single-pass `O(N)` sort-key extraction** (avoiding `O(N log N)` CSV re-tokenization during `slice.sort`), numeric-aware (`f64`/currency) + case-insensitive string sorting, fast substring filtering, and `1,000,000`-row virtual scale amplification (`csv_grid_set_virtual_rows`).
    - [x] Implement `Table_Selection_Set` using sorted disjoint `[2]i32` intervals `[start_row, end_row]` + `invert_all` flag for `O(1)` Select All and `O(log I)` range selection across `1,000,000+` rows.
- [x] Task 1.3: Add unit tests in `bifrost/csv_grid_test.odin` verifying SIMD multiline quoted newline indexing, zero-copy row slicing, single-pass numeric/string sorting, substring filtering, 1M-row virtual scaling, and disjoint interval selection with `0` memory leaks.

## Phase 2: `ui_table` 2D Horizontal Virtualization, Frozen Columns, `O(width)` Truncation & ANSI Diff Stability (`bifrost/table.odin`, `bifrost/scroll.odin`, `bifrost/renderer.odin`, `bifrost/input.odin`, `bifrost/spatial_nav.odin`)
- [x] Task 2.1: Bounded `O(span.width)` cell measurement, control-rune sanitization, `…` truncation & ANSI diff cursor stability:
    - [x] Implement `string_display_width_bounded(str: string, max_cols: i32) -> (width: i32, truncated: bool)` converting `\n`, `\r`, `\t` to `' '` and stopping after `max_cols`.
    - [x] Update `table_column_observe_cell` and `draw_table_cell` to cap observation and render `…` (`U+2026`) when text exceeds `span.width` in `O(span.width)` time.
    - [x] Update `screen_diff_ansi` in `bifrost/renderer.odin` so 1-cell box-drawing runes (`0x2500..0x257F`) do not trigger `force_row_flush` across the entire row, and re-anchor cursor position after `U+2026` (`…`) and `U+25A0..U+25FF` (`▲`, `▼`, `▸`) so terminal font width differences never shift subsequent table columns.
- [x] Task 2.2: 256-column compact storage, frozen left columns (`pinned_cols`) & 2D horizontal column virtualization:
    - [x] Lift `MAX_TABLE_COLS` from `16` to `256` using compact `i16` arrays on `Scroll_Slot` (`col_max_observed`, `col_user_width`, `col_x_starts`, `col_x_widths`) so `Input_State` remains L1/L2 cache-friendly.
    - [x] Fix `sync_scroll_viewports` (`bifrost/scroll.odin`) so `slot.total_content_w` and `node.content_span[0]` preserve total resolved table width rather than being overwritten by `inner_rect.w`.
    - [x] Add `pinned_cols: i32` to `Table_Config`, `Scroll_Slot`, and `Virtual_Slice`, plus `start_col` / `end_col` and `ui_table_is_col_visible(slice, col_idx)`.
    - [x] Partition `render_table_entry` into left-pinned columns (`0 ..< pinned_cols` with `║` / `╫` freeze divider) and right horizontally-scrolled columns (`-slot.offset_x`), auto-scrolling horizontally (`ensure_virtual_col_visible`) on `h`/`l` / `Left`/`Right` / `0` / `$` and drawing the bottom horizontal scrollbar (`━` over `─`).
- [x] Task 2.3: Interactive column sorting (`▲`/`▼`), divider drag/key resizing, auto-fit reset, scrollbar thumb dragging & `follow_tail`:
    - [x] Add `sort_col`, `sort_dir` (`.None`, `.Asc`, `.Desc`), `sort_changed`, `follow_tail`, and `auto_size_this_frame` to `Scroll_Slot` and `Virtual_Slice`.
    - [x] Render `▲` / `▼` sort indicators in sticky headers; toggle sort on header click or `s` key.
    - [x] Support mouse drag on column dividers (`│` / `║`) and `+`/`-`/`0` keys to resize or auto-fit reset the active column width.
    - [x] Add mouse click/drag hit-testing on the vertical (`sb_x`) and horizontal (`sb_y`) scrollbar tracks in `bifrost/input.odin` using 64-bit integer ratio math for instant 1M-row thumb scrubbing.
    - [x] Support `follow_tail` auto-scroll pinning with automatic unpin on upward scroll and re-pin on `G` / `End`.

## Phase 3: Unit Tests, 4-Layer `@(scenario)` ATDD Specs & `examples/csv_workbench`
- [x] Task 3.1: Add unit tests in `bifrost/widgets_test.odin` and ATDD scenarios in `tests/spec_widgets_and_palette.odin` covering:
    - [x] `ui_table` with `60+` columns, `pinned_cols = 2`, horizontal `l`/`h` auto-scrolling, culled column visibility, and `…` cell truncation.
    - [x] Interactive header click sorting (`▲`/`▼`), column divider drag resizing, scrollbar track dragging, and `follow_tail` auto-pinning.
- [x] Task 3.2: Build `examples/csv_workbench/main.odin` and update docs:
    - [x] Load `benchmarks/data/` CSVs (`LPDirectInvestmentRelation.csv` 74k rows, `Person.csv` 50 cols with multiline bios, `all-companies.csv` 190 cols, `all-contacts.csv` 65 cols) plus a 1-key `1,000,000`-row scale toggle (`m`), frozen columns toggle (`p`), column sort (`s` / header click), column resize (`+`/`-`/`0` & mouse drag), live filter (`/`), multi-row interval selection (`x` / `Ctrl+A` / `Ctrl+I`), full-record detail modal (`i`), and 30 FPS runtime telemetry HUD.
    - [x] Update `docs/widget/virtual_list_and_table.md` and `README.md`.
    - [x] Verify `odin run tools/bifrost_gen -- --lint-temp bifrost examples/csv_workbench`, `odin test bifrost`, `odin test bifrost/codegen`, and `odin test tests` pass with zero memory leaks.
