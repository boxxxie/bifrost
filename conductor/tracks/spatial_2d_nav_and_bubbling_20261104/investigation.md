# Reference Investigation: Track 7 (`spatial_2d_nav_and_bubbling_20261104`)

## Patches Inspected
- [`.tmp/patches/track7_imgui_nav_internal.patch`](../../../.tmp/patches/track7_imgui_nav_internal.patch) & [`reference/imgui/imgui.cpp`](../../../reference/imgui/imgui.cpp) (`NavScoreItem`, `NavBiasScoringRect`, `NavUpdateCreateWrappingRequest`)
- [`.tmp/patches/track7_ratatui_table_list_state.patch`](../../../.tmp/patches/track7_ratatui_table_list_state.patch) (`reference/ratatui` — `TableState` 2D `(selected, selected_column)` & `ListState` clamping)
- [`.tmp/patches/track7_textual_event_bubbling.patch`](../../../.tmp/patches/track7_textual_event_bubbling.patch) (`reference/textual` — DOM-style event bubbling & scoped binding resolution)
- [`.tmp/patches/track7_ftxui_containers_and_stacking.patch`](../../../.tmp/patches/track7_ftxui_containers_and_stacking.patch) (`reference/ftxui` — `VerticalContainer` / `HorizontalContainer` nested bubbling)

---

## Key Architectural Findings & Design Verdicts for `bifrost`

### 1. Sticky Orthogonal Axis Memory (`curswant` for 2D UIs — `imgui.cpp:14307-14329`)
- **Finding:** When navigating vertically through ragged grids (e.g. moving `Down` from Column 3 (`x=60`) onto a full-width banner (`x=0..80`), then `Down` again into a 3-column row), scoring directly from the wide banner's `rect` loses the user's `x=60` column intent and snaps to Column 1. ImGui solves this in `NavBiasScoringRect` via `NavPreferredScoringPosRel`: horizontal moves update `preferred_x`, vertical moves score against a 1-cell slice at `preferred_x` (and vice versa for `preferred_y`), while mouse clicks reset both.
- **Verdict for `bifrost/input.odin`:** Store `preferred_nav_pos: [2]i32` (`{-1, -1}` when unset) on `Input_State`. Update `preferred_nav_pos[0]` on `Left`/`Right`, update `preferred_nav_pos[1]` on `Up`/`Down`, bias the origin scoring rect along the orthogonal axis when set, and clear on mouse focus or scope jumps.

### 2. Ring Looping (`.Loop_Spatial`) vs. Reading-Order Grid Wrapping (`.Wrap_Spatial`) (`imgui.cpp:14786-14825`)
- **Finding:** `NavUpdateCreateWrappingRequest` separates two distinct boundary behaviors:
  - **`LoopX` / `LoopY` (Same-Lane Ring):** Pressing `Right` at the end of Row 1 wraps to the left edge of **Row 1** (ideal for toolbars, Kanban column lists, and menus).
  - **`WrapX` / `WrapY` (Reading-Order Grid Wrap):** Pressing `Right` at the end of Row 1 translates `y += origin.h` and wraps to the **first item of Row 2** (ideal for 2D card galleries, calendars, and icon grids).
- **Verdict for `bifrost`:** Provide both `.Loop_Spatial` (same-lane ring) and `.Wrap_Spatial` (2D reading-order next row/col wrap) in `Focus_Flags`.

### 3. 2D Virtualized Table `(selected_row, selected_col)` Stepping + Boundary Bubbling (`ratatui/table/state.rs`)
- **Finding:** Ratatui's `TableState` (`state.rs:55-59`) pairs `selected: Option<usize>` (row) with `selected_column: Option<usize>` (column) in a compact POD struct.
- **Verdict for `bifrost/scroll.odin`:** Extend `Virtual_List_State` / `Scroll_Slot` with optional `selected_col` and `total_cols` (`0` = row-only mode). When `total_cols > 1`, `h`/`l` steps across columns `[0 ..< total_cols]`, and pressing `h` at column `0` returns `false` (unhandled) so the key **bubbles naturally out to the parent split-pane scope** to focus the left sidebar!
