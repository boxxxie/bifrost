# Reference Investigation: Track 8 (`keymap_chord_dsl_and_ast_gen_20261104`)

## Patches Inspected
- [`.tmp/patches/track8_lazygit_keybindings_hints.patch`](../../../.tmp/patches/track8_lazygit_keybindings_hints.patch) (`reference/lazygit` — `callKeybindingHandler` disabled guards, `options_map.go` mode-colored width-truncated footer hints)
- [`.tmp/patches/track7_textual_event_bubbling.patch`](../../../.tmp/patches/track7_textual_event_bubbling.patch) (`reference/textual` — `Binding.Group` compact footer merging & tri-state `check_action`)
- [`.tmp/patches/track8_qpc_qhsm_lca.patch`](../../../.tmp/patches/track8_qpc_qhsm_lca.patch) (`reference/qpc` — Miro Samek's `QHsm` 5-code return protocol & fast-path transitions)
- [`.tmp/patches/track8_sleipnir_ast_codegen.patch`](../../../.tmp/patches/track8_sleipnir_ast_codegen.patch) (`deps/sleipnir` — `core:odin/parser` + `core:odin/ast` CLI codegen in `tools/sleipnir_gen`)

---

## Key Architectural Findings & Design Verdicts for `bifrost`

### 1. Compact `Binding_Group` Merging & Tri-State Availability (`textual/binding.py` & `screen.py`)
- **Finding:** Without grouping, binding `h`, `j`, `k`, `l` or `[` and `]` clutters a TUI footer with 4 separate items (`h: Left | j: Down | k: Up | l: Right`). Textual's `Binding.Group(description="Navigate", compact=True)` (`binding.py:93-105`) merges grouped keys into a single compact badge (`hjkl: Navigate` or `[/]: Time-Travel`). Textual's `active_bindings` (`screen.py:473-496`) also uses a **tri-state** check (`Enabled`, `Disabled_Dimmed`, `Hidden`).
- **Verdict for `bifrost/keymap_dsl.odin`:** Add optional `group` (`"nav"`, `"time"`) + `compact: bool` metadata to action specs and a tri-state `Action_Availability :: enum u8 { Enabled, Disabled_Dimmed, Hidden }`.

### 2. Disabled Guard Semantics (`Swallow + Reason` vs. `Bubble`) & Mode-Prefixed Width Truncation (`lazygit`)
- **Finding:** In `callKeybindingHandler` (`keybindings.go:399-418`), Lazygit distinguishes between a disabled guard that allows further bubbling (`AllowFurtherDispatching = true`) vs. one that swallows the key locally and surfaces a short disabled reason (`"Already at rightmost stage"`), preventing a disabled inner-scope shortcut from unexpectedly firing a shadowed outer/global action. In `options_map.go` (`497-565`), active transient modes/chords prepend their hints in accent colors (`Cyan`/`Yellow`) ahead of normal context shortcuts and truncate cleanly on display width (`rune_display_width`) with `" | …"`.
- **Verdict for `bifrost`:** Support `Guard_Result` (`Enabled`, `Disabled_Swallow`, `Disabled_Bubble`) on action guards, prepend active `pending_chord` / sub-mode hints in accent colors inside `ui_key_hint_bar`, deduplicate shadowed global keys, and truncate cleanly using `rune_display_width`.

### 3. Fast-Path Sub-Mode Transitions & Clean-Room Licensing (`qpc/qep_hsm.c`)
- **Finding:** `QHsm` (`qp.h:189-196`, `qep_hsm.c:1132-1196`) handles self, parent$\to$child, sibling$\to$sibling, and child$\to$parent transitions via a tiny $O(1)$ fast-path before general LCA, using 5 ordered return codes (`Super`, `Unhandled`, `Handled`, `Tran`, `Tran_Hist`).
- **License Guardrail:** `reference/qpc` is dual-licensed `GPL-3.0-or-later` / commercial (`qp.h:16-29`), whereas `bifrost`, `sleipnir`, `xitdb`, `lazygit`, `textual`, and `imgui` are permissive (MIT). Keep `reference/qpc` strictly unlinked as a conceptual study reference and write 100% clean-room Odin code in `package bifrost`.
