# Implementation Plan: `sleipnir_xitdb_inspector_20261103`

## Phase 1: Reference Investigation & ATDD Red-First Specs
- [x] Review findings from `track5_bubbletea_actor_loop.patch`, `track5_sleipnir_actor_api.patch`, and `track5_xitdb_api.patch` (documented in [`investigation.md`](./investigation.md)).
- [ ] Write end-to-end actor + `xitdb` + TUI ATDD scenarios in `tests/spec_actor_tui_integration.odin`.

## Phase 2: Sleipnir Actor Bridge & `xitdb` Inspector Demo (`bifrost/actor_bridge.odin`, `examples/xitdb_inspector/main.odin`)
- [ ] Implement `bifrost/actor_bridge.odin` connecting `sleipnir` actors, mailbox burst coalescing (`!actor.mpsc_is_empty(&self.mailbox)`), and $O(\log_{16} N)$ `xitdb_slice_viewport`.
- [ ] Build `examples/xitdb_inspector/main.odin`.
- [ ] Verify all unit tests, ATDD specs, and example builds pass with zero memory leaks.
