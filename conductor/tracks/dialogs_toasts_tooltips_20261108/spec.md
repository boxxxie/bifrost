# Specification: Track 19 — Turnkey Modal Dialogs, Floating Toasts & Contextual Tooltips (`ui_dialog`, `ui_toast`, `ui_tooltip`) (`dialogs_toasts_tooltips_20261108`)

## Overview
Elevate `bifrost`'s floating overlay engine (`z_layer`, backdrop dimming, parent anchoring) into high-level turnkey interaction dialogs, ephemeral notification toasts, and contextual hover tooltips:
1. `ui_confirm_dialog` / `ui_alert` / `ui_prompt`: Standardized, focus-trapping modal popups returning immediate-mode result enums (`.Pending`, `.Confirmed`, `.Cancelled`).
2. `ui_toast`: Ephemeral floating notification stack positioned at the screen corners (e.g., top-right) with severity themes (`.Info`, `.Success`, `.Warning`, `.Error`), auto-dismiss countdown timers, and dismiss actions.
3. `ui_tooltip`: Hover-triggered helper popup anchored automatically to hovered elements with screen-boundary collision clamping.

## Reference Implementations
- `bifrost/renderer.odin` (`ui_modal`, `Dim_Screen`)
- `bifrost/focus_scope.odin` (`focus_history`, modal stack focus trap and restoration)
- `reference/ftxui` (`src/ftxui/component/modal.cpp`)
- `reference/textual` (`src/textual/notifications.py`)

## Functional Requirements

1. **Turnkey Modal Dialogs (`bifrost/dialogs.odin`):**
   - Result enum: `Dialog_Result :: enum { Pending, Confirmed, Cancelled }`.
   - `ui_confirm_dialog(ctx, s, inp, id, title, message, default_confirm = true) -> Dialog_Result`:
     - Opens a centered modal overlay with 50% RGB background dimming.
     - Traps focus within dialog buttons `[ Confirm ]` and `[ Cancel ]`.
     - Supports `Enter` to trigger focused button, `Esc` or backdrop click to cancel.
     - Restores previous focus scope when dismissed.
   - `ui_alert(ctx, s, inp, id, title, message) -> bool`:
     - Centered informational dialog with a single `[ OK ]` button.
   - `ui_prompt(ctx, s, inp, id, title, message, buffer: ^string) -> Dialog_Result`:
     - Modal containing a single-line `ui_text_input` and `[ OK ]` / `[ Cancel ]` buttons.

2. **Floating Toast Notifications (`ui_toast` in `bifrost/dialogs.odin`):**
   - `Toast_Manager` storing an active queue of up to 8 notifications.
   - Position: Screen-anchored corner (`.Top_Right`, `.Bottom_Right`, etc.) with `z_layer = 30`.
   - Each toast contains: `title`, `message`, `severity` (`.Info`, `.Success`, `.Warning`, `.Error`), `created_at`, and `duration_ms`.
   - Visual styling: Border colored according to severity with a progress indicator or remaining duration bar.
   - Smooth entry/exit and auto-removal when duration expires.

3. **Contextual Tooltips (`ui_tooltip` in `bifrost/dialogs.odin`):**
   - Automatically checks if target widget `target_id` is hovered (`is_hovered(inp, target_id)`).
   - If hover duration exceeds threshold (e.g., 400ms) or on explicit trigger, renders a small floating box (`z_layer = 25`, `anchor = .Parent`, `offset = {0, 1}`) containing helper text.
   - Performs screen-edge clamp to prevent clipping off-screen.

4. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Pure `@(scenario)` specs in `tests/spec_dialogs.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Add confirm dialogs, prompt modals, tooltips, and toast triggers to `examples/widget_gallery/main.odin`.

## Acceptance Criteria
- Modal dialogs reliably trap focus and restore pre-modal focus upon exit.
- Toast notifications stack vertically without layout corruption or memory leakage over continuous dismissals.
- Passes all ATDD and unit tests under `-vet -strict-style`.
