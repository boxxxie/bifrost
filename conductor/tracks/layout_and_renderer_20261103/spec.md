# Specification: Track 1 — Core Layout Solver, Z-Layers & Tear-Free Cell Diff Renderer (`layout_and_renderer_20261103`)

## Overview
Build the foundational layout and rendering engine (`bifrost/layout.odin` and `bifrost/renderer.odin`) and the 4-Layer ATDD testing harness (`tests/driver_bifrost.odin`, `tests/dsl_bifrost.odin`, `tests/spec_layout_and_rendering.odin`).

## Reference Patches & Investigation
- **Investigation Report:** [`investigation.md`](./investigation.md)
- [`.tmp/patches/track1_clay_layout.patch`](../../../.tmp/patches/track1_clay_layout.patch) (`reference/clay`)
- [`.tmp/patches/track1_libvaxis_screen_cells.patch`](../../../.tmp/patches/track1_libvaxis_screen_cells.patch) (`reference/libvaxis`)
- [`.tmp/patches/track1_notcurses_planes_blend.patch`](../../../.tmp/patches/track1_notcurses_planes_blend.patch) (`reference/notcurses`)

## Functional Requirements (Refined via Investigation)
1. **Multi-Pass Topological Layout Engine (`bifrost/layout.odin`):**
   - `Direction` (`.Row`, `.Column`), `Alignment` (`.Start`, `.Center`, `.End`), `Border_Kind` (`.None`, `.Plain`, `.Rounded`, `.Double`), `Anchor_Mode` (`.Screen`, `.Parent`), `Anchor_Point` (9-point attachment).
   - `Axis_Size` union (`Fit{min, max}`, `Grow{weight, min, max}`, `Fixed(i32)`, `Percent{fraction, min, max}`).
   - Scoped `container` (`@(deferred_in = defer_end_container)`) and `leaf` builders on `context.temp_allocator`.
   - `end_layout` (Clay-inspired 5-phase sizing + topological floating anchor resolution):
     - **Pass 0:** Propagate `effective_z`, `out_of_flow`, and `scope_id`.
     - **Pass 1 (Reverse Topological Order):** Bottom-up intrinsic X/Y and `min_dims` calculation (skipping `out_of_flow` children; `Percent` axes contribute `0` to `Fit` parent sums).
     - **Pass 2 (Forward Topological Order — X Axis):** Resolve `Percent` widths, iterative water-filling expansion for `Grow` children (smallest first up to next plateau with deterministic remainder distribution), and water-draining compression for overflow down to `min_dims.x`.
     - **Pass 3 & 4 (Text Wrapping & Bottom-Up Height Re-Propagation):** Wrap text leaves against resolved inner widths and propagate wrapped height deltas upward to both `dims.y` and `min_dims.y` on `Fit`/`Grow` ancestors.
     - **Pass 5 (Forward Topological Order — Y Axis & Positioning):** Resolve Y-axis water-filling/draining, record `content_span`, apply scroll offsets, resolve 9-point floating anchors (`Anchor_Point` + `Anchor_Mode`), and compute hierarchical `node_clip` / `inner_clip` intersections.
     - **Pass 6:** Stable insertion sort of node indices into `ctx.z_order` by `effective_z` ascending.
2. **Z-Sorted Rasterizer, Wide-Cell Healing & Minimal ANSI Diff Renderer (`bifrost/renderer.odin`):**
   - `Color` (`.Default`, `.ANSI_16`, `.ANSI_256`, `.RGB`), `Style_Flags`, `Cell` with explicit `width: u8` (`1` narrow glyph, `2` wide lead cell, `0` wide trailing spacer), `Paint_Spec`, `Backdrop_Mode` (`.None`, `.Dim_Screen`, `.Dim_Rect`).
   - Double-buffered `Screen` (`screen_init`, `screen_destroy`, `screen_resize`, `begin_frame`).
   - `put_cell_clipped` with right-edge clip boundary protection (degrading a `width == 2` glyph at `x + 1 >= eff_clip.x + eff_clip.w` to `' '`) and 3-case partial overwrite healing (`heal_overwrite_at`) when a narrow or wide write bisects an existing wide character.
   - `dim_rect_backdrop` with left/right boundary wide-cell healing and `dim_color` supporting `.RGB` 50% bit-shift, `.ANSI_16` dark mapping, and `.ANSI_256` 3-band dimming (0–15 standard, 16–231 6×6×6 cube with grayscale-ramp preservation for neutral grays and `234` floor for dark chromatics, 232–255 grayscale ramp).
   - `screen_diff_ansi` skipping `width == 0` trailing spacers after `width == 2` lead emissions, emitting 1-based cursor jumps, incremental SGR transitions, and DEC Mode 2026 synchronized output (`\x1b[?2026h ... \x1b[?2026l`).
3. **4-Layer ATDD Harness & Executable Specifications (`tests/`):**
   - Layer 3 `driver_bifrost.odin`: Headless `Suite_Ctx` with `mem.Tracking_Allocator` and automatic `assert_frame_invariants` (stack balance, non-overlapping in-flow siblings, wide-cell lead/spacer pairing, control-code hygiene, front/back buffer equality, and idempotent `0`-byte second diff).
   - Layer 2 `dsl_bifrost.odin`: Composable `given_*`, `upon_*`, `then_*` layout and cell-inspection steps.
   - Layer 1 `spec_layout_and_rendering.odin`: Executable specifications for water-filling `Grow`, overflow compression, text wrapping inside `Fit` columns, CJK wide-cell boundary clipping & bisected overwrite healing, `.RGB`/`.ANSI_256` backdrop dimming, and incremental ANSI diff output.
