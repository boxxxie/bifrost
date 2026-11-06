# Reference Investigation: Track 9 (`sleipnir_actor_action_routing_20261104`)

## Patches Inspected
- [`.tmp/patches/track9_libvaxis_vxfw_commands_focus.patch`](../../../.tmp/patches/track9_libvaxis_vxfw_commands_focus.patch) (`reference/libvaxis` — `vxfw.Command` side-effects & `App.zig` `.focus_out` reset)
- [`.tmp/patches/track9_bubbletea_batch_seq_filter.patch`](../../../.tmp/patches/track9_bubbletea_batch_seq_filter.patch) (`reference/bubbletea` — `Batch` vs `Sequence` commands & `WithFilter` quit guard)
- [`.tmp/patches/track5_sleipnir_actor_api.patch`](../../../.tmp/patches/track5_sleipnir_actor_api.patch) (`deps/sleipnir` — `actor.PID`, `actor.send` batch splicing, `Envelope_Pool`)
- [`.tmp/patches/track9_xitdb_marshal_dsl.patch`](../../../.tmp/patches/track9_xitdb_marshal_dsl.patch) (`deps/xitdb` — Reflection marshaling & `xitdb` persistence)

---

## Key Architectural Findings & Design Verdicts for `bifrost`

### 1. Typed `UI_Side_Effect` Commands & Terminal `Focus_Out` Drag/Hover Reset (`libvaxis/vxfw`)
- **Finding:** `vxfw` (`vxfw.zig:76-101`) keeps event handlers pure by pushing tagged-union `Command` values (`request_focus`, `copy_to_clipboard` via OSC 52, `set_mouse_shape`, `set_title`, `notify`, `tick`) onto `EventContext.cmds`. Furthermore, in `App.zig:190-194`, receiving a terminal window `.focus_out` event (`CSI O`) immediately runs `mouseExit`, clearing hover state and releasing any active splitter drag so Alt-Tabbing mid-drag never leaves a divider stuck in drag mode.
- **Verdict for `bifrost/actor_bridge.odin` & `input.odin`:** Add a lightweight `UI_Side_Effect` command queue (`Request_Focus`, `Copy_OSC52`, `Set_Title`, `Set_Cursor_Shape`, `Request_Quit`) drained by the UI coordinator, and clear `active_press_id` + `hovered_id` whenever terminal focus-out (`Focus_Event{focused = false}`) arrives.

### 2. `Batch` (Concurrent Fan-Out) vs. `Sequence` (Ordered Pipeline) & Quit Interception (`bubbletea`)
- **Finding:** Bubble Tea (`commands.go:15-54`) distinguishes `Batch(cmds...)` (concurrent fan-out with no ordering constraint—matching Sleipnir's `actor.send(pid, batch[:])` single-`XCHG` chain splice!) from `Sequence(cmds...)` (ordered step-by-step execution). Its `WithFilter` pattern (`examples/prevent-quit/main.go:30-41`) intercepts `QuitMsg` when unsaved edits exist so the UI can mount a `.Trap_Focus` confirmation modal instead of terminating immediately.
- **Verdict for `bifrost/actor_bridge.odin`:** Support both batched `sleipnir` actor sends (`actor.send` slice splicing) and an optional `quit_filter: proc(state: ^UI_Coordinator_State) -> bool` hook on `UI_Coordinator_State` so apps with unsaved state can intercept `q` / `UI_Msg_Quit` and open a confirmation modal cleanly.
