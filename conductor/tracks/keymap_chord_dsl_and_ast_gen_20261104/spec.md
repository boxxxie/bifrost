# Specification: Track 8 — Declarative Key-Chord DSL, Transient Sub-Modes, Contextual Hint Bar & AST Codegen (`keymap_chord_dsl_and_ast_gen_20261104`)

## Overview
Eliminate verbose `Key_Event` struct literals, stringly-typed action IDs (`"task.move_next"`), and hand-coded static footer shortcut strings by introducing a **Two-Tier Odin DSL** modeled on [`deps/sleipnir/docs/DSL_GUIDE.md`](../../../deps/sleipnir/docs/DSL_GUIDE.md) and [`deps/xitdb/DSL.md`](../../../deps/xitdb/DSL.md):

1. **Tier 1 — Zero-Build-Step Pure-Library Runtime DSL (`bifrost/keymap_dsl.odin`):**
   - Zero-allocation Vim/TUI key-chord parser (`"<C-p>"`, `"g g"`, `"<C-w> l"`, `"H"`, `"<S-Tab>"`, `"q|<C-q>"`) supporting 1-key and 2-key chord sequences (`pending_chord` on `Input_State`).
   - Lightweight `QHsm`-inspired **transient widget/scope sub-modes** (e.g., pressing `Enter` on `ui_splitter` enters `.Resize` sub-mode where `h/l` or `j/k` adjusts split width and `Escape`/`Enter` exits back to `.Navigate`; `<C-w>` enters transient window-command chord mode).
   - `core:reflect` struct-tag & typed `enum` action binder that populates **`Keymap_Table`**, **`Command_Palette`**, and a live **`ui_focus_breadcrumb_bar` / `ui_key_hint_bar`** from a **single typed source of truth**, plus `@(deferred_in=...)` scoped builder helpers (`ui_scope`).
2. **Tier 2 — Optional Compile-Time AST Generator (`bifrost/codegen/codegen.odin` & `tools/bifrost_gen/main.odin`):**
   - Built on Odin's standard library (`core:odin/tokenizer` + `core:odin/parser` + `core:odin/ast`, zero external dependencies, matching `tools/sleipnir_gen`).
   - Scans a target Odin package directory for `@(ui_actions)` enums/structs and `@(ui_action="...")` / `@(ui_scope="...")` procedures, emitting `<pkg_dir>/ui_actions_gen.odin` with static zero-reflection registration tables, typed action dispatchers (`dispatch_ui_actions`), and compile-time chord validation.

## Reference Blueprint & Patches
- **Investigation Report:** [`investigation.md`](./investigation.md) *(Note: `reference/qpc` is GPLv3/commercial—studied conceptually only; all `bifrost` Odin code is 100% clean-room MIT)*
- **Master Architecture Guide:** [`docs/NAVIGATION_AND_DSL_GUIDE.md`](../../../docs/NAVIGATION_AND_DSL_GUIDE.md)
- [`.tmp/patches/track8_qpc_qhsm_lca.patch`](../../../.tmp/patches/track8_qpc_qhsm_lca.patch) (`reference/qpc` — Conceptual study of `QHsm` 5-code return protocol & fast-path transitions)
- [`.tmp/patches/track8_lazygit_keybindings_hints.patch`](../../../.tmp/patches/track8_lazygit_keybindings_hints.patch) (`reference/lazygit` — Disabled-binding guards, mode-colored hints & display-width truncation)
- [`.tmp/patches/track7_textual_event_bubbling.patch`](../../../.tmp/patches/track7_textual_event_bubbling.patch) (`reference/textual` — `Binding.Group` compact footer merging & tri-state `check_action`)
- [`.tmp/patches/track8_sleipnir_ast_codegen.patch`](../../../.tmp/patches/track8_sleipnir_ast_codegen.patch) (`deps/sleipnir` — Idiomatic Odin `core:odin/parser` + `core:odin/ast` codegen architecture)

## Functional Requirements

1. **Zero-Allocation Key-Chord Parser & Multi-Key Chord State (`bifrost/keymap_dsl.odin`, `bifrost/splitter_keymap.odin`):**
   - `parse_key_chord(spec: string) -> (Key_Chord, bool)` parsing single keys (`"n"`, `"H"`, `"<Enter>"`, `"<Esc>"`, `"<F6>"`), modifier combos (`"<C-p>"`, `"<M-x>"`, `"<S-F6>"`), alternate bindings (`"q|<C-q>"`), and 2-step sequences (`"g g"`, `"<C-w> h"`, `"<C-w> l"`).
   - Fixed `pending_chord` state on `Input_State`: when step 1 of a valid 2-key chord matches an active scope on `focus_node_path`, latch `pending_chord` (displayable in the status/hint bar!) and resolve or cancel on the next `Key_Event` (`Escape` cancels cleanly).

2. **Transient Scope / Widget Sub-Modes (`bifrost/splitter_keymap.odin`, `bifrost/input.odin`):**
   - Support explicit per-scope sub-mode IDs (`u8` / typed enum) on `Input_State` so widgets like `ui_splitter` or modal/pane sub-states can transition `Navigate` $\leftrightarrow$ `Resize` (`Enter` enters resize, `h/j/k/l`/Arrows resize, `Enter`/`Escape` exits).

3. **Single-Source-of-Truth Action Registry + Contextual Breadcrumb & Hint Bar (`bifrost/keymap_dsl.odin`, `bifrost/command_palette.odin`):**
   - `register_action_spec` / `register_actions_struct` (`core:reflect` struct tags: `bifrost:"key=H, scope=col_*, group=stage, desc=Move Task Left"`) registering:
     1. Scoped/global `Key_Binding` entries (supporting prefix/wildcard or explicit scope hashes),
     2. Optional guard callbacks returning `Guard_Result` (`Enabled`, `Disabled_Swallow` with optional reason, or `Disabled_Bubble` allowing fallthrough) + tri-state availability (`Enabled`, `Disabled_Dimmed`, `Hidden`),
     3. `Command_Palette` searchable commands with auto-formatted shortcut badges, and
     4. Compact `Binding_Group` merging (`hjkl: Navigate`, `[/]: Time-Travel`) for concise footer badges.
   - `ui_focus_breadcrumb_bar` & `ui_key_hint_bar`: Inspects `inp.focus_node_path` (`root -> board -> col_doing -> card_3`), `editing_id`, `pending_chord`, and active scope sub-modes to prepend mode/chord hints in high-contrast accent colors, drop shadowed global keys, and truncate cleanly by `rune_display_width` (`" | …"`) on `context.temp_allocator`.

4. **Optional AST Metaprogramming CLI (`bifrost/codegen/` & `tools/bifrost_gen/`):**
   - CLI `odin run tools/bifrost_gen -- <package_dir>` scanning `.odin` ASTs via `core:odin/parser`.
   - Validates chord syntax at codegen time (reporting file:line errors on malformed chords!) and emits `<package_dir>/ui_actions_gen.odin` containing zero-reflection `init_<app>_keymap_and_palette` + exhaustive typed `dispatch_<app>_action` switches (usable with `-custom-attribute:ui_actions,ui_action,ui_scope`).

## Acceptance Criteria
- Unit tests verify single-key, modifier, alternation (`|`), and 2-key chord parsing/dispatch (`g g`, `<C-w> l`), chord cancellation, splitter `Resize` sub-mode transitions, `core:reflect` struct-tag registration into both `Keymap_Table` and `Command_Palette`, live `ui_key_hint_bar` output across focus changes, and `bifrost/codegen` AST generation with zero memory leaks.
