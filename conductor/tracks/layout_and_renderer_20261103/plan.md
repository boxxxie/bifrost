# Implementation Plan: `layout_and_renderer_20261103`

## Phase 1: Reference Investigation & 4-Layer ATDD Harness Setup
- [x] Review findings from `track1_clay_layout.patch`, `track1_libvaxis_screen_cells.patch`, and `track1_notcurses_planes_blend.patch` (documented in [`investigation.md`](./investigation.md)).
- [x] Scaffold `tests/driver_bifrost.odin` and `tests/dsl_bifrost.odin` with `mem.Tracking_Allocator`, `assert_frame_invariants`, and Red-First specs in `tests/spec_layout_and_rendering.odin`.

## Phase 2: Multi-Pass Topological Layout Engine (`bifrost/layout.odin`)
- [x] Implement `Direction`, `Alignment`, `Border_Kind`, `Anchor_Mode`, `Anchor_Point`, `Fit`, `Grow`, `Fixed`, `Percent`, `Axis_Size`, `Padding`, `Rect`, `Box_Config`, `Layout_Node`, and `Layout_Context`.
- [x] Implement `begin_layout`, `container`, `leaf`, `push_node`, `get_rect`, `get_inner_rect`, and Clay-inspired multi-pass `end_layout` (water-filling `Grow`, water-draining compression, text wrapping height re-propagation, 9-point floating anchors, hierarchical clips, and stable `z_order` sort).

## Phase 3: Z-Sorted Rasterizer, Wide-Cell Healing, `.RGB`/`.ANSI_256` Dimming & Synchronized ANSI Diff (`bifrost/renderer.odin`)
- [x] Implement `Color`, `Style_Flags`, `Cell` (`width: u8` 0/1/2 representation), `Backdrop_Mode`, `Paint_Spec`, `Modal_Spec`, `Screen` double-buffer lifecycle, and scoped `ui_modal`.
- [x] Implement `put_cell_clipped` (3-case wide-cell overwrite healing & right-edge clip degradation), `dim_rect_backdrop` (`.RGB` and `.ANSI_256` 3-band dimming with boundary wide-cell healing), `render_layout`, and `screen_diff_ansi` (`\x1b[?2026h ... \x1b[?2026l`).
- [x] Verify all unit tests (`odin test bifrost -vet -strict-style`) and ATDD specs (`odin test tests -vet -strict-style`) pass with zero memory leaks.
