# Specification: Track 15 — Form Controls Suite (`ui_checkbox`, `ui_radio_group`, `ui_switch`, `ui_slider`, `ui_dropdown`) (`form_controls_20261108`)

## Overview
Add standard interactive form controls to `bifrost` to enable rich data entry, configuration forms, and settings dialogs without requiring developers to compose low-level buttons and boxes manually:
1. `ui_checkbox`: Interactive `[ ]` / `[x]` toggle with label, keyboard (`Space`), and mouse toggle support.
2. `ui_radio_group`: Mutually exclusive `( )` / `(•)` option group with vertical/horizontal layouts and arrow-key option cycling.
3. `ui_switch`: Visual boolean switch (`[ ON | off ]` or `●─` / `─●`) for high-contrast preference toggling.
4. `ui_slider`: Horizontal numeric scrubber (`[----●-----] 45%`) with bounds `[min_val..max_val]`, mouse dragging, and `h`/`l`/arrow key stepping.
5. `ui_dropdown` / `ui_select`: Anchored popup selection overlay using `floating = true`, `anchor = .Parent`, and `z_layer = 10` with outside-click dismissal.

## Reference Implementations
- `reference/ftxui` (`src/ftxui/component/checkbox.cpp`, `radiobox.cpp`, `slider.cpp`, `dropdown.cpp`)
- `bifrost/input.odin` (`ui_button`, `was_activated`, `is_focused`)
- `conductor/tracks/actor_xitdb_tui_20261103/building_an_actor_driven_odin_tui.md` (`anchor = .Parent`, `z_layer = 10`)

## Functional Requirements

1. **Checkbox & Switch Widgets (`bifrost/form_controls.odin`):**
   - `ui_checkbox(ctx, s, inp, id, &checked, label, cfg)`:
     - Render `[ ] <label>` or `[x] <label>`.
     - Support focus navigation, hover styling, and toggle on `Space` or left mouse click.
   - `ui_switch(ctx, s, inp, id, &value, label, cfg)`:
     - High-contrast toggle switch representation with customizable on/off colors and labels.

2. **Radio Button Group (`ui_radio_group`):**
   - Manage an array of labels/values with a mutable `^int` selected index.
   - Support `Up`/`Down` (or `Left`/`Right` in row mode) to cycle selection when focused, or direct mouse click on any option row.

3. **Numeric Slider (`ui_slider`):**
   - Render a continuous or stepped slider bar across available width: `[======●-------] 42%`.
   - Support mouse drag interpolation across the track width and keyboard stepping via `Left`/`Right`, `h`/`l`, `Home`/`End`, and step increments.

4. **Anchored Dropdown (`ui_dropdown`):**
   - Closed state renders a button-like box showing the currently selected option and a `▾` indicator.
   - When opened, spawns an out-of-flow overlay box (`floating = true, anchor = .Parent, z_layer = 10, offset = {0, 1}`) containing a scrollable option list.
   - Closes automatically upon option selection, `Esc` press, or backdrop click (`was_modal_dismissed`).

5. **4-Layer `@(scenario)` ATDD Specifications & Example Integration:**
   - Pure `@(scenario)` specs in `tests/spec_form_controls.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Add a "Form Controls" panel in `examples/widget_gallery/main.odin`.

## Acceptance Criteria
- All form widgets pass `odin run tools/bifrost_gen -- --atdd tests`, unit tests, and `@(scenario)` ATDD tests with zero per-frame heap allocations.
- Dropdown overlays correctly respect parent anchoring without disrupting sibling layout geometry.
