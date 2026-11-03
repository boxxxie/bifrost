### 1. Event Bubbling, Capture Phases, Hover Diffing & Mouse Capture (`libvaxis/vxfw` & `FTXUI`)

#### How `vxfw/App.zig` Tracks Focus Paths and Routes 3-Phase Events

* **Post-Layout Focus Path Reconstruction (`FocusHandler.update`):** After `doLayout` produces a `Surface` tree, `FocusHandler.update` clears `path_to_focused` and calls `childHasFocus(allocator, surface)`. This performs a depth-first search for `self.focused_widget`, appending each ancestor on the unwind and reversing the list so `path_to_focused.items[0]` is `root` and `path_to_focused.last()` is `focused_widget`.


* **Silent Unmount Fallback:** If `childHasFocus` returns `false` (the focused widget was unmounted on this frame), `FocusHandler.update` silently resets `self.focused_widget = self.root` without dispatching `.focus_out` to the destroyed widget. Conversely, explicit focus requests (`wants_focus`) call `focusWidget`, which dispatches `.focus_out` to the old target and `.focus_in` to the new target at `ctx.phase = .at_target`.


* **3-Phase Dispatch (`capturing` $\rightarrow$ `at_target` $\rightarrow$ `bubbling`):**
* **Keyboard/Focus Events (`FocusHandler.handleEvent`):** Walks `path_to_focused` root-to-target (**inclusive** of target) with `ctx.phase = .capturing` calling `widget.captureEvent(ctx, event)`, then invokes `target.handleEvent(ctx, event)` with `ctx.phase = .at_target`, and finally walks backward from target's parent to root (**exclusive** of target) with `ctx.phase = .bubbling` calling `widget.handleEvent(ctx, event)`. Any handler setting `ctx.consume_event = true` halts propagation immediately.


* **Mouse Events (`MouseHandler.handleMouse` & `Surface.hitTest`):** `Surface.hitTest` walks top-down through `SubSurface` children containing the point, translating into local coordinates (`point - child.origin`) and recording widgets with an `eventHandler` or `captureHandler` into `hits`. `handleMouse` pops the deepest leaf as `target = hits.pop()`, runs `.capturing` forward over `hits.items` (ancestors only), runs `.at_target` on `target`, and pops remaining ancestors in reverse for `.bubbling`.





#### How `vxfw` Tracks `mouse_enter` / `mouse_leave` Across Events and Frames

* **Set-Difference on Hit Paths:** `MouseHandler` persists `last_hit_list: []vxfw.HitResult` and `last_frame: vxfw.Surface`. On every mouse event—and again in `mouse_handler.updateMouse` immediately after `doLayout`—it computes the hit list $B$ and compares it to the previous hit list $A$:


* Widgets in $A \setminus B$ receive `.mouse_leave`.


* Widgets in $B \setminus A$ receive `.mouse_enter`.


* Widgets in $A \cap B$ receive nothing.




* Calling `updateMouse` after `doLayout` ensures that if a scroll or layout shift moves a widget out from under a stationary cursor, `.mouse_leave`/`.mouse_enter` still fire and trigger a second layout pass if `ctx.redraw` is set.



#### Why `Input_State` Needs Both `active_press_id` and `prev_hovered_id`

* **`vxfw`'s Drag Bug vs. `FTXUI`'s `CapturedMouse`:** `vxfw` lacks mouse-down capture in `MouseHandler`. In `vxfw/SplitView.zig`, `.mouse_leave` sets `self.pressed = false`, meaning dragging a splitter bar faster than 1 cell per frame (so the cursor briefly leaves the `SplitView` bounds) aborts the resize mid-drag. Similarly, `vxfw/Button.zig` zeroes `self.mouse_down = false` on `.mouse_leave`.


* In contrast, `FTXUI`'s `ResizableSplitBase::OnMouseEvent` (`resizable_split.cpp`) acquires an exclusive `captured_mouse_ = CaptureMouse(event)` token when `Mouse::Left` is pressed inside `separator_box_`. While `captured_mouse_` is held, all subsequent mouse motion updates `main_size()` regardless of whether the cursor leaves `separator_box_`, releasing only on `Mouse::Released`. `Hoverable` (`hoverable.cpp`) also checks `CaptureMouse(event)` so background widgets do not highlight while another widget is being dragged.


* **Design Verdict for `bifrost/input.odin`:**
1. **`active_press_id: Ui_Id` (Mouse-Down Capture):** Latch `active_press_id = hit_id` on left `.Mouse_Press`. While `active_press_id != 0`, route `.Mouse_Drag` / `.Mouse_Move` events directly to `active_press_id` (enabling smooth splitter/scrollbar dragging outside their bounds) and suppress hover highlights on unrelated nodes. On `.Mouse_Release`, fire click actions **only if** `active_press_id == hovered_id`, then clear `active_press_id = 0`.
2. **`prev_hovered_id: Ui_Id` + `hovered_path`:** Retaining the previous hovered node ID (and ancestor hit path) allows immediate-mode widgets to detect `mouse_enter` (`hovered_id == id && prev_hovered_id != id`) and `mouse_leave` (`hovered_id != id && prev_hovered_id == id`), and lets `end_frame` re-run hit-testing against `last_mouse_pos` when layout shifts under a stationary cursor.



---

### 2. Nested Modals & Focus Restoration (`FTXUI modal.cpp` vs. `bifrost/input.odin`)

#### How `FTXUI` Handles Nested Modals

* In `src/ftxui/component/modal.cpp`, `Modal(main, modal, show_modal)` composes a `Container::Tab({main_, modal_}, &selector_)` where `selector_ = *show_modal_` (`0` or `1`).


* In `src/ftxui/component/container.cpp`, `TabContainer::ActiveChild()` returns `children()[*selector_]`, and `TabContainer` routes both keyboard (`ContainerBase::OnEvent`) and mouse (`TabContainer::OnMouseEvent`) exclusively to `ActiveChild()`.


* Because FTXUI is retained-mode and every `ContainerBase` instance owns its own `int selected_` member in memory, nesting `Modal(Modal(main, confirm, &show_confirm), palette, &show_palette)` naturally preserves the inner modal's `selector_ = 1` and its internal focused child while the outer palette modal is active.



#### How `bifrost/input.odin` Must Handle `z_layer = 20` $\rightarrow$ `z_layer = 30` $\rightarrow$ Close `30`

In an immediate-mode architecture where focus lives in a centralized `Input_State`, opening a Command Palette (`z_layer = 30`, `capture_input = true`) over a Confirmation Modal (`z_layer = 20`, `capture_input = true`) requires two invariants:

1. **Dynamic Highest-Shield Floor (`max_capture_z_layer`):**
* During each frame, compute `active_shield_z` as the maximum `z_layer` among all mounted nodes with `.Capture_Input` set.
* When both modals are open, `active_shield_z = 30`. Both `Tab`/`Shift+Tab` focus traversal and mouse `hit_test_point` ignore all nodes with `node.z_layer < 30`.
* When the Command Palette (`z_layer = 30`) closes, `active_shield_z` automatically drops to `20` on the very next frame—keeping the Confirmation Modal (`z_layer = 20`) shielded from the base UI (`z_layer = 0`).


2. **LIFO `focus_history` Stack Keyed by `(scope_id, z_layer, saved_focus_id)`:**
* When Confirmation Modal (`z_layer = 20`) mounts, it pushes `{scope_id = confirm_id, z_layer = 20, saved_focus_id = editor_id}` onto `focus_history` and focuses its first focusable child (e.g., `confirm_cancel_btn`).
* If the user tabs to `confirm_ok_btn` and then opens the Command Palette (`z_layer = 30`), the palette pushes `{scope_id = palette_id, z_layer = 30, saved_focus_id = confirm_ok_btn}` onto `focus_history` and focuses `palette_input`.
* When the Command Palette closes, `end_frame` sees that the top of `focus_history` (`z_layer = 30`) is no longer mounted (or exceeds `active_shield_z == 20`). It pops the `z_layer = 30` entry and restores `focused_id = confirm_ok_btn` (validating that `confirm_ok_btn` is still mounted and focusable at `z_layer >= 20`, or falling back to the first focusable node at `z_layer >= 20`).
* When the Confirmation Modal subsequently closes, `active_shield_z` drops to `0`, the `z_layer = 20` entry is popped, and focus returns to `editor_id`.



---

### 3. Clipped Hit-Testing (`node.node_clip` vs. `node.rect`)

* **The Scroll Ghost-Click Bug:** Layout assigns every widget a `node.rect` in screen coordinates (after applying scroll offsets) and a `node.node_clip = rect_intersect(parent_clip, node.rect)` representing the visible portion inside ancestor scroll viewports.
* If a button inside a scroll container (`viewport = {x=0, y=10, w=40, h=10}`) is scrolled down to `y = 25`, its `node.rect` is `{x=2, y=25, w=12, h=2}`, while its `node.node_clip` is empty (`w = 12, h = 0`).
* If `hit_test_point` checks `point_in_rect(mx, my, node.rect)` instead of `point_in_rect(mx, my, node.node_clip)`:
1. Clicking at `(5, 26)` (below the scroll container, e.g., on a footer button) hits the invisible scrolled-out button!
2. Partially clipped buttons at the viewport boundary remain clickable outside the scroll viewport.


* **Fix in `hit_test_point`:** Always guard hit-testing with `rect_is_valid(node.node_clip) && point_in_rect(mx, my, node.node_clip)` (where `node.node_clip` is already intersected with `node.rect` during layout, or explicitly check both `point_in_rect(mx, my, node.node_clip) && point_in_rect(mx, my, node.rect)`).

---

### 4. Concrete Odin Implementation (`bifrost/input.odin`)

```odin
package bifrost

Ui_Id :: distinct u64

MAX_FOCUS_HISTORY :: 16
MAX_HIT_DEPTH     :: 32

Rect :: struct {
	x, y, w, h: i32,
}

Node_Flag :: enum u8 {
	Focusable,
	Clickable,
	Hoverable,
	Draggable,
	Capture_Input, // Modal shield: blocks mouse & Tab below this node's z_layer
}
Node_Flags :: bit_set[Node_Flag; u8]

Layout_Node :: struct {
	id:        Ui_Id,
	parent_id: Ui_Id,
	rect:      Rect,
	node_clip: Rect, // Pre-intersected with ancestor scroll viewports & node.rect
	z_layer:   i32,
	flags:     Node_Flags,
}

Event_Phase :: enum u8 {
	Capturing,
	At_Target,
	Bubbling,
}

Key_Code :: enum u8 {
	None,
	Tab,
	Enter,
	Escape,
	Up,
	Down,
	Left,
	Right,
	Char,
}

Key_Mod :: enum u8 {
	Shift,
	Ctrl,
	Alt,
}
Key_Mods :: bit_set[Key_Mod; u8]

Mouse_Event_Kind :: enum u8 {
	Move,
	Press,
	Drag,
	Release,
	Wheel_Up,
	Wheel_Down,
}

Mouse_Button :: enum u8 {
	None,
	Left,
	Middle,
	Right,
}

Input_Event :: union {
	Key_Event,
	Mouse_Event,
	Focus_Loss_Event,
}

Key_Event :: struct {
	code: Key_Code,
	mods: Key_Mods,
	rune: rune,
}

Mouse_Event :: struct {
	kind:   Mouse_Event_Kind,
	button: Mouse_Button,
	x, y:   i32,
	mods:   Key_Mods,
}

Focus_Loss_Event :: struct {}

Focus_Scope_Entry :: struct {
	scope_id:       Ui_Id,
	z_layer:        i32,
	saved_focus_id: Ui_Id,
}

Input_State :: struct {
	// Focus state & nested modal restoration stack
	focused_id:         Ui_Id,
	prev_focused_id:    Ui_Id,
	wants_focus_id:     Ui_Id,
	focus_history:      [MAX_FOCUS_HISTORY]Focus_Scope_Entry,
	focus_history_len:  int,
	active_shield_z:    i32,

	// Mouse hover & active press capture state
	hovered_id:         Ui_Id,
	prev_hovered_id:    Ui_Id,
	active_press_id:    Ui_Id,
	clicked_id:         Ui_Id, // Latched for 1 frame when press+release match on target
	drag_delta:         [2]i32,
	last_mouse_pos:     [2]i32,
	has_mouse_pos:      bool,

	// Hit & focus paths (root -> target) for 3-phase capture/target/bubble routing
	focus_path:         [MAX_HIT_DEPTH]Ui_Id,
	focus_path_len:     int,
	hover_path:         [MAX_HIT_DEPTH]Ui_Id,
	hover_path_len:     int,
	prev_hover_path:    [MAX_HIT_DEPTH]Ui_Id,
	prev_hover_path_len: int,
}

Event_Handler_Proc :: #type proc(
	node_id:  Ui_Id,
	phase:    Event_Phase,
	event:    Input_Event,
	userdata: rawptr,
) -> (consumed: bool)

rect_is_valid :: #force_inline proc "contextless" (r: Rect) -> bool {
	return r.w > 0 && r.h > 0
}

point_in_rect :: #force_inline proc "contextless" (px, py: i32, r: Rect) -> bool {
	return r.w > 0 && r.h > 0 && px >= r.x && px < (r.x + r.w) && py >= r.y && py < (r.y + r.h)
}

rect_intersect :: #force_inline proc "contextless" (a, b: Rect) -> Rect {
	x1 := max(a.x, b.x)
	y1 := max(a.y, b.y)
	x2 := min(a.x + a.w, b.x + b.w)
	y2 := min(a.y + a.h, b.y + b.h)
	if x2 <= x1 || y2 <= y1 {
		return Rect{x = x1, y = y1, w = 0, h = 0}
	}
	return Rect{x = x1, y = y1, w = x2 - x1, h = y2 - y1}
}

// Computes the highest z_layer that has .Capture_Input enabled in the current frame.
compute_active_shield_z :: proc "contextless" (nodes: []Layout_Node) -> i32 {
	shield_z: i32 = min(i32)
	for node in nodes {
		if .Capture_Input in node.flags && node.z_layer > shield_z {
			shield_z = node.z_layer
		}
	}
	return shield_z
}

// Clipped hit-testing: checks both node_clip AND rect, respects modal shields,
// and picks the highest z_layer (breaking ties by reverse painter's order).
hit_test_point :: proc "contextless" (
	nodes: []Layout_Node,
	mx, my: i32,
	required_flags := Node_Flags{.Clickable, .Hoverable, .Draggable},
) -> (hit_id: Ui_Id, ok: bool) {
	shield_z := compute_active_shield_z(nodes)
	best_z: i32 = min(i32)

	#reverse for node in nodes {
		if node.z_layer < shield_z {
			continue
		}
		if (node.flags & required_flags) == {} {
			continue
		}
		// Crucial: verify against both node_clip (viewport intersection) and rect
		if !point_in_rect(mx, my, node.node_clip) || !point_in_rect(mx, my, node.rect) {
			continue
		}
		if !ok || node.z_layer > best_z {
			best_z = node.z_layer
			hit_id = node.id
			ok = true
		}
	}
	return hit_id, ok
}

// Builds root-to-target ancestor chain for 3-phase capture -> target -> bubble routing.
build_ancestor_path :: proc "contextless" (
	nodes: []Layout_Node,
	target_id: Ui_Id,
	out_path: ^[MAX_HIT_DEPTH]Ui_Id,
) -> int {
	if target_id == 0 {
		return 0
	}
	len_path := 0
	curr_id := target_id

	for curr_id != 0 && len_path < MAX_HIT_DEPTH {
		out_path[len_path] = curr_id
		len_path += 1

		found_parent := false
		for node in nodes {
			if node.id == curr_id {
				curr_id = node.parent_id
				found_parent = true
				break
			}
		}
		if !found_parent {
			break
		}
	}

	// Reverse in-place so out_path[0] is root and out_path[len_path - 1] is target_id
	for i := 0; i < len_path / 2; i += 1 {
		j := len_path - 1 - i
		out_path[i], out_path[j] = out_path[j], out_path[i]
	}
	return len_path
}

// Dispatches an event through Capturing (root..parent), At_Target, and Bubbling (parent..root).
dispatch_three_phase :: proc(
	path: []Ui_Id,
	event: Input_Event,
	handler: Event_Handler_Proc,
	userdata: rawptr = nil,
) -> bool {
	if len(path) == 0 || handler == nil {
		return false
	}
	target_idx := len(path) - 1

	// 1. Capturing phase: root down to target's parent
	for i := 0; i < target_idx; i += 1 {
		if handler(path[i], .Capturing, event, userdata) {
			return true
		}
	}

	// 2. Target phase
	if handler(path[target_idx], .At_Target, event, userdata) {
		return true
	}

	// 3. Bubbling phase: target's parent back up to root
	for i := target_idx - 1; i >= 0; i -= 1 {
		if handler(path[i], .Bubbling, event, userdata) {
			return true
		}
	}
	return false
}

// Pushes or maintains a modal scope on the focus_history stack.
// Call when a modal with .Capture_Input is declared/mounted.
input_sync_modal_scope :: proc "contextless" (
	state: ^Input_State,
	nodes: []Layout_Node,
	scope_id: Ui_Id,
	z_layer: i32,
) {
	// Check if this modal scope is already on the focus stack
	for i := 0; i < state.focus_history_len; i += 1 {
		if state.focus_history[i].scope_id == scope_id {
			return
		}
	}

	if state.focus_history_len < MAX_FOCUS_HISTORY {
		state.focus_history[state.focus_history_len] = Focus_Scope_Entry{
			scope_id       = scope_id,
			z_layer        = z_layer,
			saved_focus_id = state.focused_id,
		}
		state.focus_history_len += 1
	}

	// Immediately move focus to the first focusable widget inside this modal z_layer
	for node in nodes {
		if node.z_layer >= z_layer && .Focusable in node.flags {
			state.focused_id = node.id
			break
		}
	}
}

// Reconciles focus and hover after layout (end of frame):
// 1. Automatically pushes newly mounted .Capture_Input modal scopes.
// 2. Pops closed modal scopes in LIFO order and restores saved_focus_id.
// 3. Falls back to the first valid focusable widget at >= active_shield_z if focus was unmounted.
// 4. Updates hover state even if the mouse did not move (matching vxfw updateMouse).
input_reconcile_frame :: proc "contextless" (state: ^Input_State, nodes: []Layout_Node) {
	state.prev_focused_id = state.focused_id
	state.active_shield_z = compute_active_shield_z(nodes)

	// 1. Auto-register any newly mounted modal shield scopes in ascending z_layer order
	for node in nodes {
		if .Capture_Input in node.flags {
			input_sync_modal_scope(state, nodes, node.id, node.z_layer)
		}
	}

	// 2. Pop any focus_history scopes whose modal node is no longer mounted
	for state.focus_history_len > 0 {
		top := state.focus_history[state.focus_history_len - 1]
		still_mounted := false
		for node in nodes {
			if node.id == top.scope_id && .Capture_Input in node.flags {
				still_mounted = true
				break
			}
		}
		if still_mounted {
			break
		}
		state.focus_history_len -= 1
		state.focused_id = top.saved_focus_id
	}

	// 3. Apply explicit focus request if valid inside current shield
	if state.wants_focus_id != 0 {
		if is_focusable_in_shield(nodes, state.wants_focus_id, state.active_shield_z) {
			state.focused_id = state.wants_focus_id
		}
		state.wants_focus_id = 0
	}

	// 4. Verify focused_id is still mounted, focusable, and not behind a modal shield
	if !is_focusable_in_shield(nodes, state.focused_id, state.active_shield_z) {
		state.focused_id = first_focusable_in_shield(nodes, state.active_shield_z)
	}

	state.focus_path_len = build_ancestor_path(nodes, state.focused_id, &state.focus_path)

	// 5. Re-evaluate hover under stationary cursor after layout changes
	if state.has_mouse_pos {
		update_hover_state(state, nodes, state.last_mouse_pos.x, state.last_mouse_pos.y)
	}
}

is_focusable_in_shield :: proc "contextless" (
	nodes: []Layout_Node,
	id: Ui_Id,
	shield_z: i32,
) -> bool {
	if id == 0 {
		return false
	}
	for node in nodes {
		if node.id == id {
			return .Focusable in node.flags && node.z_layer >= shield_z
		}
	}
	return false
}

first_focusable_in_shield :: proc "contextless" (nodes: []Layout_Node, shield_z: i32) -> Ui_Id {
	for node in nodes {
		if .Focusable in node.flags && node.z_layer >= shield_z {
			return node.id
		}
	}
	return 0
}

// Cycles focus forward (Tab) or backward (Shift+Tab) strictly within z_layer >= active_shield_z.
cycle_focus :: proc "contextless" (state: ^Input_State, nodes: []Layout_Node, reverse: bool) {
	shield_z := compute_active_shield_z(nodes)
	first_id: Ui_Id = 0
	last_id:  Ui_Id = 0
	prev_id:  Ui_Id = 0
	found_current := false

	for node in nodes {
		if .Focusable not_in node.flags || node.z_layer < shield_z {
			continue
		}
		if first_id == 0 {
			first_id = node.id
		}
		if found_current && !reverse {
			state.focused_id = node.id
			state.focus_path_len = build_ancestor_path(nodes, state.focused_id, &state.focus_path)
			return
		}
		if node.id == state.focused_id {
			found_current = true
			if reverse && prev_id != 0 {
				state.focused_id = prev_id
				state.focus_path_len = build_ancestor_path(nodes, state.focused_id, &state.focus_path)
				return
			}
		}
		prev_id = node.id
		last_id = node.id
	}

	if reverse {
		state.focused_id = last_id
	} else {
		state.focused_id = first_id
	}
	state.focus_path_len = build_ancestor_path(nodes, state.focused_id, &state.focus_path)
}

update_hover_state :: proc "contextless" (
	state: ^Input_State,
	nodes: []Layout_Node,
	mx, my: i32,
) {
	state.prev_hovered_id = state.hovered_id
	state.prev_hover_path = state.hover_path
	state.prev_hover_path_len = state.hover_path_len

	if mx < 0 || my < 0 {
		state.hovered_id = 0
		state.hover_path_len = 0
		return
	}

	hit_id, ok := hit_test_point(nodes, mx, my)
	if !ok {
		state.hovered_id = 0
		state.hover_path_len = 0
		return
	}

	// Follow FTXUI Hoverable + CapturedMouse rule: while dragging an active_press_id,
	// do not allow other background widgets to become hovered.
	if state.active_press_id != 0 && hit_id != state.active_press_id {
		state.hovered_id = 0
		state.hover_path_len = 0
		return
	}

	state.hovered_id = hit_id
	state.hover_path_len = build_ancestor_path(nodes, hit_id, &state.hover_path)
}

// Processes a raw input event against the current frame's Layout_Node slice.
input_handle_event :: proc(
	state: ^Input_State,
	nodes: []Layout_Node,
	event: Input_Event,
	handler: Event_Handler_Proc = nil,
	userdata: rawptr = nil,
) -> (consumed: bool) {
	state.clicked_id = 0
	state.drag_delta = {0, 0}

	switch ev in event {
	case Focus_Loss_Event:
		state.prev_hovered_id = state.hovered_id
		state.hovered_id = 0
		state.hover_path_len = 0
		state.active_press_id = 0
		return true

	case Key_Event:
		state.focus_path_len = build_ancestor_path(nodes, state.focused_id, &state.focus_path)
		if dispatch_three_phase(state.focus_path[:state.focus_path_len], event, handler, userdata) {
			return true
		}
		if ev.code == .Tab {
			cycle_focus(state, nodes, .Shift in ev.mods)
			return true
		}
		return false

	case Mouse_Event:
		prev_pos := state.last_mouse_pos
		state.last_mouse_pos = {ev.x, ev.y}
		state.has_mouse_pos = ev.x >= 0 && ev.y >= 0

		update_hover_state(state, nodes, ev.x, ev.y)

		switch ev.kind {
		case .Move:
			return state.hovered_id != state.prev_hovered_id

		case .Press:
			if ev.button == .Left {
				hit_id, ok := hit_test_point(nodes, ev.x, ev.y)
				if ok {
					state.active_press_id = hit_id
					// Focus the widget if it is focusable
					if is_focusable_in_shield(nodes, hit_id, compute_active_shield_z(nodes)) {
						state.focused_id = hit_id
						state.focus_path_len = build_ancestor_path(nodes, hit_id, &state.focus_path)
					}
					return dispatch_three_phase(
						state.hover_path[:state.hover_path_len],
						event,
						handler,
						userdata,
					) || true
				}
			}
			return false

		case .Drag:
			if state.active_press_id != 0 {
				state.drag_delta = {ev.x - prev_pos.x, ev.y - prev_pos.y}
				var_path: [MAX_HIT_DEPTH]Ui_Id
				path_len := build_ancestor_path(nodes, state.active_press_id, &var_path)
				return dispatch_three_phase(var_path[:path_len], event, handler, userdata) || true
			}
			return false

		case .Release:
			if state.active_press_id != 0 {
				pressed_id := state.active_press_id
				state.active_press_id = 0
				// Re-evaluate hover now that active_press_id is released
				update_hover_state(state, nodes, ev.x, ev.y)

				// Standard GUI button rule: click fires iff release happens inside the pressed target
				if state.hovered_id == pressed_id {
					state.clicked_id = pressed_id
				}
				var_path: [MAX_HIT_DEPTH]Ui_Id
				path_len := build_ancestor_path(nodes, pressed_id, &var_path)
				return dispatch_three_phase(var_path[:path_len], event, handler, userdata) || true
			}
			return false

		case .Wheel_Up, .Wheel_Down:
			return dispatch_three_phase(
				state.hover_path[:state.hover_path_len],
				event,
				handler,
				userdata,
			)
		}
	}
	return false
}

// Helper queries for immediate-mode widgets
did_mouse_enter :: #force_inline proc "contextless" (state: ^Input_State, id: Ui_Id) -> bool {
	return state.hovered_id == id && state.prev_hovered_id != id
}

did_mouse_leave :: #force_inline proc "contextless" (state: ^Input_State, id: Ui_Id) -> bool {
	return state.hovered_id != id && state.prev_hovered_id == id
}

```

---

### 5. Executable ATDD Specifications (`tests/spec_focus_and_input.odin`)

Following the 4-layer ATDD architecture (`Executable Specifications` $\rightarrow$ `DSL` $\rightarrow$ `Protocol Driver` $\rightarrow$ `SUT`), the specifications below express domain intent and concrete coordinates/layers in Layer 1 while isolating `Layout_Node` construction and `Input_State` plumbing in the test driver below.

```odin
package bifrost

import "core:testing"

// =============================================================================
// LAYER 1: EXECUTABLE SPECIFICATIONS
// =============================================================================

@(test)
spec_three_phase_capture_target_and_bubbling :: proc(t: ^testing.T) {
	ctx := spec_init(t)
	defer spec_destroy(&ctx)

	// Given a 3-level widget hierarchy: Root_Panel (1) -> Toolbar (2) -> Save_Button (3)
	given_widget(&ctx, id = 1, parent = 0, rect = {0, 0, 80, 24}, flags = {.Focusable})
	given_widget(&ctx, id = 2, parent = 1, rect = {0, 0, 80, 3},  flags = {.Focusable})
	given_widget(&ctx, id = 3, parent = 2, rect = {2, 1, 10, 1},  flags = {.Focusable, .Clickable})
	given_focused_widget(&ctx, id = 3)

	// Upon pressing Enter without any capture interceptor
	upon_pressing_key(&ctx, .Enter)

	// Then the event traverses Capturing (1 -> 2), At_Target (3), and Bubbling (2 -> 1)
	then_recorded_phases_are(&ctx, []Phase_Record{
		{id = 1, phase = .Capturing},
		{id = 2, phase = .Capturing},
		{id = 3, phase = .At_Target},
		{id = 2, phase = .Bubbling},
		{id = 1, phase = .Bubbling},
	})

	// Upon configuring Toolbar (2) to consume events during Capturing and pressing Enter again
	given_widget_consumes_at(&ctx, id = 2, phase = .Capturing)
	upon_pressing_key(&ctx, .Enter)

	// Then propagation halts at Toolbar (2) in Capturing before reaching Save_Button (3)
	then_recorded_phases_are(&ctx, []Phase_Record{
		{id = 1, phase = .Capturing},
		{id = 2, phase = .Capturing},
	})
}

@(test)
spec_active_press_capture_for_buttons_and_splitters :: proc(t: ^testing.T) {
	ctx := spec_init(t)
	defer spec_destroy(&ctx)

	// Given a Splitter bar (id = 10) at x = 20 and an adjacent Button (id = 11) at x = 25..35
	given_widget(&ctx, id = 10, parent = 0, rect = {20, 0, 1, 20}, flags = {.Draggable, .Hoverable})
	given_widget(&ctx, id = 11, parent = 0, rect = {25, 2, 10, 2}, flags = {.Clickable, .Hoverable})
	upon_frame_reconcile(&ctx)

	// Upon pressing left mouse on the 1-column Splitter (x = 20, y = 5) and dragging outside to x = 28
	upon_mouse_press(&ctx, x = 20, y = 5)
	upon_mouse_drag(&ctx, x = 28, y = 5)

	// Then Splitter (10) retains active_press_id, receives the +8 drag delta,
	// and Button (11) does NOT steal hover while Splitter (10) captures the mouse
	then_active_press_is(&ctx, id = 10)
	then_drag_delta_is(&ctx, dx = 8, dy = 0)
	then_hovered_widget_is(&ctx, id = 0)

	// Upon releasing mouse at x = 28 (over Button 11)
	upon_mouse_release(&ctx, x = 28, y = 5)

	// Then active_press_id clears, Button (11) was NOT clicked, and hover transfers to Button (11)
	then_active_press_is(&ctx, id = 0)
	then_clicked_widget_is(&ctx, id = 0)
	then_hovered_widget_is(&ctx, id = 11)

	// Upon pressing Button (11), dragging outside to x = 2, dragging back inside to x = 27, and releasing
	upon_mouse_press(&ctx, x = 27, y = 3)
	upon_mouse_drag(&ctx, x = 2, y = 3)
	then_clicked_widget_is(&ctx, id = 0)
	upon_mouse_drag(&ctx, x = 27, y = 3)
	upon_mouse_release(&ctx, x = 27, y = 3)

	// Then Button (11) registers a valid click on release-inside
	then_clicked_widget_is(&ctx, id = 11)
}

@(test)
spec_nested_modals_shield_and_lifo_focus_restoration :: proc(t: ^testing.T) {
	ctx := spec_init(t)
	defer spec_destroy(&ctx)

	// Given Base UI (z_layer = 0) with Editor_A (1) and Editor_B (2), focused on Editor_B (2)
	given_widget(&ctx, id = 1, parent = 0, rect = {0, 0, 40, 20},  z_layer = 0, flags = {.Focusable, .Clickable})
	given_widget(&ctx, id = 2, parent = 0, rect = {40, 0, 40, 20}, z_layer = 0, flags = {.Focusable, .Clickable})
	given_focused_widget(&ctx, id = 2)
	upon_frame_reconcile(&ctx)
	then_focused_widget_is(&ctx, id = 2)

	// Upon opening Confirmation Modal (id = 200, z_layer = 20) with Cancel (201) and Confirm (202)
	given_modal_shield(&ctx, id = 200, rect = {10, 5, 60, 10}, z_layer = 20)
	given_widget(&ctx, id = 201, parent = 200, rect = {15, 10, 10, 2}, z_layer = 20, flags = {.Focusable, .Clickable})
	given_widget(&ctx, id = 202, parent = 200, rect = {30, 10, 10, 2}, z_layer = 20, flags = {.Focusable, .Clickable})
	upon_frame_reconcile(&ctx)

	// Then focus moves to Cancel (201), and Tab cycles only between 201 and 202
	then_focused_widget_is(&ctx, id = 201)
	upon_pressing_key(&ctx, .Tab)
	then_focused_widget_is(&ctx, id = 202)

	// And clicking on background Editor_A (x = 5, y = 5) is blocked by the z_layer = 20 shield
	upon_mouse_click(&ctx, x = 5, y = 5)
	then_clicked_widget_is(&ctx, id = 0)
	then_focused_widget_is(&ctx, id = 202)

	// Upon opening Command Palette (id = 300, z_layer = 30) on top of Confirmation Modal (z_layer = 20)
	given_modal_shield(&ctx, id = 300, rect = {20, 2, 40, 6}, z_layer = 30)
	given_widget(&ctx, id = 301, parent = 300, rect = {22, 3, 36, 1}, z_layer = 30, flags = {.Focusable, .Clickable})
	upon_frame_reconcile(&ctx)

	// Then focus moves to Palette_Input (301) and clicking Confirm (202) at (32, 11) is blocked
	then_focused_widget_is(&ctx, id = 301)
	upon_mouse_click(&ctx, x = 32, y = 11)
	then_clicked_widget_is(&ctx, id = 0)
	then_focused_widget_is(&ctx, id = 301)

	// Upon closing Command Palette (z_layer = 30) while Confirmation Modal (z_layer = 20) remains open
	upon_unmounting_layer(&ctx, z_layer = 30)
	upon_frame_reconcile(&ctx)

	// Then focus restores to Confirm (202) (the last focused widget in z_layer = 20),
	// and Base UI (z_layer = 0) remains shielded by Confirmation Modal (z_layer = 20)
	then_focused_widget_is(&ctx, id = 202)
	upon_mouse_click(&ctx, x = 5, y = 5)
	then_clicked_widget_is(&ctx, id = 0)

	// Upon closing Confirmation Modal (z_layer = 20)
	upon_unmounting_layer(&ctx, z_layer = 20)
	upon_frame_reconcile(&ctx)

	// Then focus restores to Editor_B (2) in Base UI (z_layer = 0)
	then_focused_widget_is(&ctx, id = 2)
}

@(test)
spec_clipped_hit_testing_rejects_scrolled_out_buttons :: proc(t: ^testing.T) {
	ctx := spec_init(t)
	defer spec_destroy(&ctx)

	// Given a scroll viewport at {x = 0, y = 10, w = 40, h = 10} (visible rows 10..19)
	viewport := Rect{x = 0, y = 10, w = 40, h = 10}

	// Visible button (id = 51) inside viewport at y = 12..14
	given_clipped_widget(&ctx, id = 51, rect = {2, 12, 12, 2}, viewport_clip = viewport, flags = {.Clickable, .Hoverable})
	// Partially clipped button (id = 52) straddling bottom edge at y = 19..21 (only y = 19 visible)
	given_clipped_widget(&ctx, id = 52, rect = {2, 19, 12, 2}, viewport_clip = viewport, flags = {.Clickable, .Hoverable})
	// Completely scrolled-out button (id = 53) below viewport at y = 24..26
	given_clipped_widget(&ctx, id = 53, rect = {2, 24, 12, 2}, viewport_clip = viewport, flags = {.Clickable, .Hoverable})
	// Footer button (id = 99) outside the scroll container at y = 24..26
	given_widget(&ctx, id = 99, parent = 0, rect = {2, 24, 12, 2}, flags = {.Clickable, .Hoverable})

	upon_frame_reconcile(&ctx)

	// Clicking visible row y = 19 hits partially visible button (52)
	upon_mouse_click(&ctx, x = 5, y = 19)
	then_clicked_widget_is(&ctx, id = 52)

	// Clicking clipped row y = 20 (inside 52.rect, but outside 52.node_clip) does NOT hit 52
	upon_mouse_click(&ctx, x = 5, y = 20)
	then_clicked_widget_is(&ctx, id = 0)

	// Clicking at y = 25 (where scrolled-out button 53 overlaps Footer button 99)
	// ignores ghost button 53 and clicks Footer button 99
	upon_mouse_click(&ctx, x = 5, y = 25)
	then_clicked_widget_is(&ctx, id = 99)
}

// =============================================================================
// LAYERS 2 & 3: DOMAIN-SPECIFIC LANGUAGE & PROTOCOL DRIVER
// =============================================================================

Phase_Record :: struct {
	id:    Ui_Id,
	phase: Event_Phase,
}

Spec_Context :: struct {
	t:               ^testing.T,
	state:           Input_State,
	nodes:           [dynamic]Layout_Node,
	records:         [dynamic]Phase_Record,
	consume_node_id: Ui_Id,
	consume_phase:   Event_Phase,
	has_consumer:    bool,
}

spec_init :: proc(t: ^testing.T) -> Spec_Context {
	return Spec_Context{
		t       = t,
		nodes   = make([dynamic]Layout_Node),
		records = make([dynamic]Phase_Record),
	}
}

spec_destroy :: proc(ctx: ^Spec_Context) {
	delete(ctx.nodes)
	delete(ctx.records)
}

given_widget :: proc(
	ctx: ^Spec_Context,
	id: Ui_Id,
	parent: Ui_Id,
	rect: Rect,
	z_layer: i32 = 0,
	flags: Node_Flags = {},
) {
	append(&ctx.nodes, Layout_Node{
		id        = id,
		parent_id = parent,
		rect      = rect,
		node_clip = rect,
		z_layer   = z_layer,
		flags     = flags,
	})
}

given_clipped_widget :: proc(
	ctx: ^Spec_Context,
	id: Ui_Id,
	rect: Rect,
	viewport_clip: Rect,
	z_layer: i32 = 0,
	flags: Node_Flags = {},
) {
	append(&ctx.nodes, Layout_Node{
		id        = id,
		parent_id = 0,
		rect      = rect,
		node_clip = rect_intersect(viewport_clip, rect),
		z_layer   = z_layer,
		flags     = flags,
	})
}

given_modal_shield :: proc(ctx: ^Spec_Context, id: Ui_Id, rect: Rect, z_layer: i32) {
	given_widget(ctx, id = id, parent = 0, rect = rect, z_layer = z_layer, flags = {.Capture_Input})
}

given_focused_widget :: proc(ctx: ^Spec_Context, id: Ui_Id) {
	ctx.state.focused_id = id
	ctx.state.focus_path_len = build_ancestor_path(ctx.nodes[:], id, &ctx.state.focus_path)
}

given_widget_consumes_at :: proc(ctx: ^Spec_Context, id: Ui_Id, phase: Event_Phase) {
	ctx.consume_node_id = id
	ctx.consume_phase = phase
	ctx.has_consumer = true
}

upon_unmounting_layer :: proc(ctx: ^Spec_Context, z_layer: i32) {
	for i := len(ctx.nodes) - 1; i >= 0; i -= 1 {
		if ctx.nodes[i].z_layer == z_layer {
			ordered_remove(&ctx.nodes, i)
		}
	}
}

upon_frame_reconcile :: proc(ctx: ^Spec_Context) {
	input_reconcile_frame(&ctx.state, ctx.nodes[:])
}

spec_event_recorder :: proc(
	node_id: Ui_Id,
	phase: Event_Phase,
	event: Input_Event,
	userdata: rawptr,
) -> bool {
	ctx := (^Spec_Context)(userdata)
	append(&ctx.records, Phase_Record{id = node_id, phase = phase})
	if ctx.has_consumer && ctx.consume_node_id == node_id && ctx.consume_phase == phase {
		return true
	}
	return false
}

upon_pressing_key :: proc(ctx: ^Spec_Context, code: Key_Code, mods: Key_Mods = {}) {
	clear(&ctx.records)
	input_handle_event(
		&ctx.state,
		ctx.nodes[:],
		Key_Event{code = code, mods = mods},
		spec_event_recorder,
		ctx,
	)
}

upon_mouse_press :: proc(ctx: ^Spec_Context, x, y: i32) {
	clear(&ctx.records)
	input_handle_event(
		&ctx.state,
		ctx.nodes[:],
		Mouse_Event{kind = .Press, button = .Left, x = x, y = y},
		spec_event_recorder,
		ctx,
	)
}

upon_mouse_drag :: proc(ctx: ^Spec_Context, x, y: i32) {
	clear(&ctx.records)
	input_handle_event(
		&ctx.state,
		ctx.nodes[:],
		Mouse_Event{kind = .Drag, button = .Left, x = x, y = y},
		spec_event_recorder,
		ctx,
	)
}

upon_mouse_release :: proc(ctx: ^Spec_Context, x, y: i32) {
	clear(&ctx.records)
	input_handle_event(
		&ctx.state,
		ctx.nodes[:],
		Mouse_Event{kind = .Release, button = .Left, x = x, y = y},
		spec_event_recorder,
		ctx,
	)
}

upon_mouse_click :: proc(ctx: ^Spec_Context, x, y: i32) {
	upon_mouse_press(ctx, x, y)
	upon_mouse_release(ctx, x, y)
}

then_recorded_phases_are :: proc(ctx: ^Spec_Context, expected: []Phase_Record) {
	testing.expect_value(ctx.t, len(ctx.records), len(expected))
	if len(ctx.records) == len(expected) {
		for i := 0; i < len(expected); i += 1 {
			testing.expect_value(ctx.t, ctx.records[i], expected[i])
		}
	}
}

then_focused_widget_is :: proc(ctx: ^Spec_Context, id: Ui_Id) {
	testing.expect_value(ctx.t, ctx.state.focused_id, id)
}

then_hovered_widget_is :: proc(ctx: ^Spec_Context, id: Ui_Id) {
	testing.expect_value(ctx.t, ctx.state.hovered_id, id)
}

then_active_press_is :: proc(ctx: ^Spec_Context, id: Ui_Id) {
	testing.expect_value(ctx.t, ctx.state.active_press_id, id)
}

then_clicked_widget_is :: proc(ctx: ^Spec_Context, id: Ui_Id) {
	testing.expect_value(ctx.t, ctx.state.clicked_id, id)
}

then_drag_delta_is :: proc(ctx: ^Spec_Context, dx, dy: i32) {
	testing.expect_value(ctx.t, ctx.state.drag_delta, [2]i32{dx, dy})
}

```

Would you like to extend `input_handle_event` next to support spatial 2D directional focus navigation (arrow keys / `hjkl` between grid panes), or wire up scroll-wheel bubbling through nested scroll containers?



In an immediate-mode TUI, `Layout_Node` slices are rebuilt from scratch every frame, so wiring `scroll_offset` into the layout pass and building the persistent widget state store are two halves of the same multi-frame loop: without a persistent state store keyed by `Ui_Id`, any `scroll_offset` mutated by `try_scroll_node` on frame $N$ would be wiped when frame $N+1$ begins.

### 1. Multi-Frame Immediate-Mode Scroll & State Lifecycle

1. **Persistent `Widget_State_Store` Across Frames:**
* Stores per-widget state (`scroll_offset`, `scroll_max`, `last_touched_frame`) in a hash map or fixed table keyed by `Ui_Id`.
* At the end of `input_handle_event`, if `state.scrolled_id != 0`, the updated `scroll_offset` on that `Layout_Node` is written back into `Widget_State_Store`.
* Stale entries for unmounted widgets can be pruned at `end_frame` whenever `entry.last_touched_frame < current_frame`.


2. **Hierarchical Scroll Offset & `node_clip` Propagation (`begin_scroll_container` / `end_scroll_container`):**
* When a scroll container is declared on frame $N+1$, it looks up its persisted `scroll_offset` from `Widget_State_Store` and pushes a `Scroll_Scope` onto the layout stack with its viewport clip (`container.node_clip`) and cumulative scroll translation.
* Each child inside the container has its layout position shifted by `-scroll_offset` (`child.rect.y = layout_y - scope.scroll_offset.y`) and its visible clip restricted to `child.node_clip = rect_intersect(scope.viewport_clip, child.rect)`.
* When the container closes (`end_scroll_container`), it computes `content_height` from the maximum unshifted child extent, derives `scroll_max.y = max(0, content_height - container.rect.h)`, clamps `scroll_offset.y` if the terminal or content shrank, and writes `scroll_max` back to both the `Layout_Node` and `Widget_State_Store`.


3. **Stationary-Cursor Hover Handoff After Scroll (`vxfw` `updateMouse` Pattern):**
* In `vxfw/App.zig`, `mouse_handler.updateMouse(self, surface, &ctx)` runs immediately after `doLayout` so widgets that move under a stationary cursor receive `.mouse_leave` and `.mouse_enter`.


* In `bifrost`, calling `input_reconcile_frame` at the end of frame $N+1$'s layout pass re-runs `update_hover_state(state, nodes, state.last_mouse_pos.x, state.last_mouse_pos.y)` against the newly shifted `rect` and `node_clip` values—automatically firing `did_mouse_leave` on the row that scrolled away and `did_mouse_enter` on the row that scrolled under the cursor.



---

### 2. Concrete Odin Implementation (`bifrost/scroll_state.odin`)

```odin
package bifrost

import "core:mem"

MAX_SCROLL_SCOPES :: 16

Widget_Scroll_State :: struct {
	scroll_offset:      [2]i32,
	scroll_max:         [2]i32,
	wheel_step:         i32,
	last_touched_frame: u64,
}

Widget_State_Store :: struct {
	current_frame: u64,
	scroll_states: map[Ui_Id]Widget_Scroll_State,
}

Scroll_Scope :: struct {
	container_idx:    int,
	container_id:     Ui_Id,
	origin:           [2]i32,
	viewport_clip:    Rect,
	cumulative_shift: [2]i32,
	content_max:      [2]i32, // Tracks unshifted max (x + w, y + h) of children
}

Layout_Builder :: struct {
	nodes:             [dynamic]Layout_Node,
	store:             ^Widget_State_Store,
	scopes:            [MAX_SCROLL_SCOPES]Scroll_Scope,
	scope_depth:       int,
	root_viewport:     Rect,
}

state_store_init :: proc(
	store: ^Widget_State_Store,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	store.current_frame = 0
	store.scroll_states = make(map[Ui_Id]Widget_Scroll_State, 64, allocator) or_return
	return nil
}

state_store_destroy :: proc(store: ^Widget_State_Store) {
	delete(store.scroll_states)
	store^ = {}
}

// Prunes state for any widget that was not declared during the current frame.
state_store_prune_unmounted :: proc(store: ^Widget_State_Store) {
	for id, entry in store.scroll_states {
		if entry.last_touched_frame < store.current_frame {
			delete_key(&store.scroll_states, id)
		}
	}
}

// Syncs any scroll_offset mutations performed by input_handle_event back into persistent storage.
state_store_sync_from_nodes :: proc "contextless" (
	store: ^Widget_State_Store,
	nodes: []Layout_Node,
) {
	if store == nil {
		return
	}
	for node in nodes {
		if .Scrollable in node.flags {
			if entry, ok := &store.scroll_states[node.id]; ok {
				entry.scroll_offset = node.scroll_offset
				entry.scroll_max    = node.scroll_max
			}
		}
	}
}

// Begins a new immediate-mode layout frame.
layout_begin_frame :: proc(
	builder: ^Layout_Builder,
	store: ^Widget_State_Store,
	root_viewport: Rect,
) {
	clear(&builder.nodes)
	builder.store = store
	builder.scope_depth = 0
	builder.root_viewport = root_viewport
	if store != nil {
		store.current_frame += 1
	}
}

// Adds a widget inside the current scroll scope, automatically shifting its rect by the
// active cumulative scroll_offset and intersecting its node_clip with the scroll viewport.
layout_add_node :: proc(
	builder: ^Layout_Builder,
	id: Ui_Id,
	local_rect: Rect,
	z_layer: i32 = 0,
	flags: Node_Flags = {},
) -> Layout_Node {
	parent_id: Ui_Id = 0
	active_clip := builder.root_viewport
	shift := [2]i32{0, 0}

	if builder.scope_depth > 0 {
		top := &builder.scopes[builder.scope_depth - 1]
		parent_id = top.container_id
		active_clip = top.viewport_clip
		shift = top.cumulative_shift

		// Record unshifted content extent relative to the scroll container's origin
		rel_right  := (local_rect.x - top.origin.x) + local_rect.w
		rel_bottom := (local_rect.y - top.origin.y) + local_rect.h
		top.content_max.x = max(top.content_max.x, rel_right)
		top.content_max.y = max(top.content_max.y, rel_bottom)
	}

	screen_rect := Rect{
		x = local_rect.x - shift.x,
		y = local_rect.y - shift.y,
		w = local_rect.w,
		h = local_rect.h,
	}
	clipped := rect_intersect(active_clip, screen_rect)

	node := Layout_Node{
		id        = id,
		parent_id = parent_id,
		rect      = screen_rect,
		node_clip = clipped,
		z_layer   = z_layer,
		flags     = flags,
	}
	append(&builder.nodes, node)
	return node
}

// Opens a scrollable container scope, restoring its persisted scroll_offset from Widget_State_Store.
layout_begin_scroll_container :: proc(
	builder: ^Layout_Builder,
	id: Ui_Id,
	local_rect: Rect,
	wheel_step: i32 = DEFAULT_WHEEL_STEP,
	z_layer: i32 = 0,
	extra_flags: Node_Flags = {},
) {
	persisted := Widget_Scroll_State{
		wheel_step = wheel_step,
	}
	if builder.store != nil {
		if existing, ok := builder.store.scroll_states[id]; ok {
			persisted = existing
		}
		persisted.wheel_step = wheel_step
		persisted.last_touched_frame = builder.store.current_frame
		builder.store.scroll_states[id] = persisted
	}

	node := layout_add_node(
		builder,
		id,
		local_rect,
		z_layer,
		extra_flags + {.Scrollable, .Hoverable},
	)
	container_idx := len(builder.nodes) - 1
	builder.nodes[container_idx].scroll_offset = persisted.scroll_offset
	builder.nodes[container_idx].scroll_max    = persisted.scroll_max
	builder.nodes[container_idx].wheel_step    = wheel_step

	parent_shift := [2]i32{0, 0}
	if builder.scope_depth > 0 {
		parent_shift = builder.scopes[builder.scope_depth - 1].cumulative_shift
	}

	if builder.scope_depth < MAX_SCROLL_SCOPES {
		builder.scopes[builder.scope_depth] = Scroll_Scope{
			container_idx    = container_idx,
			container_id     = id,
			origin           = {local_rect.x, local_rect.y},
			viewport_clip    = node.node_clip,
			cumulative_shift = parent_shift + persisted.scroll_offset,
			content_max      = {0, 0},
		}
		builder.scope_depth += 1
	}
}

// Closes the current scrollable container scope, automatically computing scroll_max from
// the measured children extent and clamping scroll_offset if the content shrank.
layout_end_scroll_container :: proc(builder: ^Layout_Builder) {
	if builder.scope_depth <= 0 {
		return
	}
	builder.scope_depth -= 1
	scope := builder.scopes[builder.scope_depth]
	container := &builder.nodes[scope.container_idx]

	max_x := max(0, scope.content_max.x - container.rect.w)
	max_y := max(0, scope.content_max.y - container.rect.h)

	container.scroll_max = {max_x, max_y}
	container.scroll_offset.x = clamp(container.scroll_offset.x, 0, max_x)
	container.scroll_offset.y = clamp(container.scroll_offset.y, 0, max_y)

	if builder.store != nil {
		if entry, ok := &builder.store.scroll_states[scope.container_id]; ok {
			entry.scroll_max    = container.scroll_max
			entry.scroll_offset = container.scroll_offset
		}
	}
}

// Completes the layout pass, prunes unmounted widget state, and reconciles focus & hover.
layout_end_frame :: proc(builder: ^Layout_Builder, input_state: ^Input_State) {
	if builder.store != nil {
		state_store_prune_unmounted(builder.store)
	}
	input_reconcile_frame(input_state, builder.nodes[:])
}

```

To ensure wheel events persist into `Widget_State_Store` immediately, call `state_store_sync_from_nodes` right after `input_handle_event` (or pass `store: ^Widget_State_Store = nil` into a small frame-event wrapper):

```odin
input_dispatch_and_persist :: proc(
	state: ^Input_State,
	store: ^Widget_State_Store,
	nodes: []Layout_Node,
	event: Input_Event,
	handler: Event_Handler_Proc = nil,
	userdata: rawptr = nil,
) -> bool {
	consumed := input_handle_event(state, nodes, event, handler, userdata)
	if state.scrolled_id != 0 {
		state_store_sync_from_nodes(store, nodes)
	}
	return consumed
}

```

---

### 3. Executable ATDD Specifications (`tests/spec_scroll_layout_and_state.odin`)

These specifications verify the complete multi-frame loop across **Track 2 + Track 3**:

1. **Multi-Frame Scroll Translation, Clipping & Stationary Hover Handoff:** Scrolling the mouse wheel on Frame 1 updates `Widget_State_Store`; rebuilding the UI on Frame 2 shifts child `rect` coordinates up by `scroll_offset.y`, clips out-of-bounds items via `node_clip`, prevents ghost clicks on scrolled-out items, and updates `hovered_id` (`did_mouse_leave` / `did_mouse_enter`) under a stationary cursor.


2. **Dynamic Content Shrink Clamping & Unmounted State Pruning:** If the list shrinks on a subsequent frame (e.g., filtering items in a command palette), `layout_end_scroll_container` automatically clamps `scroll_offset.y` to the new `scroll_max.y`, and unmounting the scroll container prunes its entry from `Widget_State_Store`.

```odin
package bifrost

import "core:testing"

// =============================================================================
// LAYER 1: EXECUTABLE SPECIFICATIONS
// =============================================================================

@(test)
spec_multi_frame_scroll_persists_shifts_clips_and_transfers_stationary_hover :: proc(t: ^testing.T) {
	ctx := scroll_spec_init(t, screen = {0, 0, 80, 24})
	defer scroll_spec_destroy(&ctx)

	// --- FRAME 1: Initial mount (scroll_offset = 0) ---
	// Viewport is at y = 10..16 (height = 6), wheel_step = 4.
	// 3 buttons inside (each height = 2), total content height = 10 -> scroll_max.y = 4:
	//   Row_1 (id = 101): local y = 10..12 (visible on Frame 1 at y = 10..12)
	//   Row_2 (id = 102): local y = 14..16 (visible on Frame 1 at y = 14..16)
	//   Row_3 (id = 103): local y = 18..20 (clipped out below viewport on Frame 1)
	upon_building_scroll_list_frame(&ctx, container_id = 50, row_ids = {101, 102, 103})

	// Verify initial Frame 1 geometry & computed scroll_max
	then_persisted_scroll_is(&ctx, container_id = 50, offset_y = 0, max_y = 4)
	then_node_clip_is(&ctx, id = 101, expected = {0, 10, 40, 2})
	then_node_clip_is(&ctx, id = 103, expected = {0, 16, 40, 0}) // Empty clip (scrolled out below)

	// Move mouse to (x = 5, y = 11) -> hovers Row_1 (101)
	upon_moving_mouse(&ctx, x = 5, y = 11)
	then_stationary_hover_is(&ctx, hovered = 101, entered = 101, left = 0)

	// Scroll Wheel_Down at (x = 5, y = 11) -> container 50 scrolls by +4 (offset_y = 4)
	upon_scrolling_wheel(&ctx, kind = .Wheel_Down, x = 5, y = 11)
	then_persisted_scroll_is(&ctx, container_id = 50, offset_y = 4, max_y = 4)

	// --- FRAME 2: Immediate-mode rebuild with persisted scroll_offset.y = 4 ---
	// Even without a new mouse event, rebuilding layout with scroll_offset.y = 4 shifts:
	//   Row_1 (101) to y = 6..8   -> clipped out ABOVE viewport (y = 10..16)!
	//   Row_2 (102) to y = 10..12 -> now directly under stationary cursor at (5, 11)!
	//   Row_3 (103) to y = 14..16 -> now scrolled into view!
	upon_building_scroll_list_frame(&ctx, container_id = 50, row_ids = {101, 102, 103})

	then_node_clip_is(&ctx, id = 101, expected = {0, 10, 40, 0}) // Clipped out above
	then_node_clip_is(&ctx, id = 102, expected = {0, 10, 40, 2}) // Shifted into y = 10..12
	then_node_clip_is(&ctx, id = 103, expected = {0, 14, 40, 2}) // Shifted into y = 14..16

	// Stationary cursor at (5, 11) automatically leaves Row_1 (101) and enters Row_2 (102)
	then_stationary_hover_is(&ctx, hovered = 102, entered = 102, left = 101)

	// Clicking at (5, 15) now clicks newly visible Row_3 (103)
	upon_clicking_mouse(&ctx, x = 5, y = 15)
	then_clicked_row_is(&ctx, id = 103)
}

@(test)
spec_content_shrink_clamps_scroll_offset_and_unmount_prunes_state :: proc(t: ^testing.T) {
	ctx := scroll_spec_init(t, screen = {0, 0, 80, 24})
	defer scroll_spec_destroy(&ctx)

	// Frame 1: Mount scroll container (50) with 3 rows (max_y = 4) and scroll to bottom (offset_y = 4)
	upon_building_scroll_list_frame(&ctx, container_id = 50, row_ids = {101, 102, 103})
	upon_scrolling_wheel(&ctx, kind = .Wheel_Down, x = 5, y = 11)
	then_persisted_scroll_is(&ctx, container_id = 50, offset_y = 4, max_y = 4)

	// Frame 2: Filter list down to 1 row (101) -> content fits inside viewport (max_y = 0)
	// layout_end_scroll_container must clamp scroll_offset.y from 4 -> 0 so Row_1 is not stranded offscreen
	upon_building_scroll_list_frame(&ctx, container_id = 50, row_ids = {101})
	then_persisted_scroll_is(&ctx, container_id = 50, offset_y = 0, max_y = 0)
	then_node_clip_is(&ctx, id = 101, expected = {0, 10, 40, 2})

	// Frame 3: Unmount scroll container (50) completely -> state store prunes entry 50
	upon_building_empty_frame(&ctx)
	then_state_store_contains(&ctx, container_id = 50, expected = false)
}

// =============================================================================
// LAYERS 2 & 3: DOMAIN-SPECIFIC LANGUAGE & PROTOCOL DRIVER
// =============================================================================

Scroll_Spec_Context :: struct {
	t:       ^testing.T,
	input:   Input_State,
	store:   Widget_State_Store,
	builder: Layout_Builder,
	screen:  Rect,
}

scroll_spec_init :: proc(t: ^testing.T, screen: Rect) -> Scroll_Spec_Context {
	ctx := Scroll_Spec_Context{
		t      = t,
		screen = screen,
	}
	err := state_store_init(&ctx.store)
	testing.expect_value(t, err, nil)
	ctx.builder.nodes = make([dynamic]Layout_Node)
	return ctx
}

scroll_spec_destroy :: proc(ctx: ^Scroll_Spec_Context) {
	delete(ctx.builder.nodes)
	state_store_destroy(&ctx.store)
}

upon_building_scroll_list_frame :: proc(
	ctx: ^Scroll_Spec_Context,
	container_id: Ui_Id,
	row_ids: []Ui_Id,
) {
	layout_begin_frame(&ctx.builder, &ctx.store, ctx.screen)

	// Scroll container viewport at {x = 0, y = 10, w = 40, h = 6}, wheel_step = 4
	layout_begin_scroll_container(
		&ctx.builder,
		id         = container_id,
		local_rect = {0, 10, 40, 6},
		wheel_step = 4,
	)

	// Lay out each row spaced by 4 rows vertically (y = 10, 14, 18, ...), height = 2
	for row_id, i in row_ids {
		row_y := i32(10 + i * 4)
		layout_add_node(
			&ctx.builder,
			id         = row_id,
			local_rect = {0, row_y, 40, 2},
			flags      = {.Focusable, .Clickable, .Hoverable},
		)
	}

	layout_end_scroll_container(&ctx.builder)
	layout_end_frame(&ctx.builder, &ctx.input)
}

upon_building_empty_frame :: proc(ctx: ^Scroll_Spec_Context) {
	layout_begin_frame(&ctx.builder, &ctx.store, ctx.screen)
	layout_end_frame(&ctx.builder, &ctx.input)
}

upon_moving_mouse :: proc(ctx: ^Scroll_Spec_Context, x, y: i32) {
	input_dispatch_and_persist(
		&ctx.input,
		&ctx.store,
		ctx.builder.nodes[:],
		Mouse_Event{kind = .Move, button = .None, x = x, y = y},
	)
}

upon_scrolling_wheel :: proc(ctx: ^Scroll_Spec_Context, kind: Mouse_Event_Kind, x, y: i32) {
	input_dispatch_and_persist(
		&ctx.input,
		&ctx.store,
		ctx.builder.nodes[:],
		Mouse_Event{kind = kind, button = .None, x = x, y = y},
	)
}

upon_clicking_mouse :: proc(ctx: ^Scroll_Spec_Context, x, y: i32) {
	input_dispatch_and_persist(
		&ctx.input,
		&ctx.store,
		ctx.builder.nodes[:],
		Mouse_Event{kind = .Press, button = .Left, x = x, y = y},
	)
	input_dispatch_and_persist(
		&ctx.input,
		&ctx.store,
		ctx.builder.nodes[:],
		Mouse_Event{kind = .Release, button = .Left, x = x, y = y},
	)
}

then_persisted_scroll_is :: proc(
	ctx: ^Scroll_Spec_Context,
	container_id: Ui_Id,
	offset_y, max_y: i32,
) {
	entry, ok := ctx.store.scroll_states[container_id]
	testing.expect(ctx.t, ok, "expected container scroll state to be persisted")
	if ok {
		testing.expect_value(ctx.t, entry.scroll_offset.y, offset_y)
		testing.expect_value(ctx.t, entry.scroll_max.y, max_y)
	}
}

then_node_clip_is :: proc(ctx: ^Scroll_Spec_Context, id: Ui_Id, expected: Rect) {
	idx, ok := find_node_index(ctx.builder.nodes[:], id)
	testing.expect(ctx.t, ok, "expected layout node to exist")
	if ok {
		testing.expect_value(ctx.t, ctx.builder.nodes[idx].node_clip, expected)
	}
}

then_stationary_hover_is :: proc(
	ctx: ^Scroll_Spec_Context,
	hovered, entered, left: Ui_Id,
) {
	testing.expect_value(ctx.t, ctx.input.hovered_id, hovered)
	if entered != 0 {
		testing.expect(ctx.t, did_mouse_enter(&ctx.input, entered), "expected did_mouse_enter")
	}
	if left != 0 {
		testing.expect(ctx.t, did_mouse_leave(&ctx.input, left), "expected did_mouse_leave")
	}
}

then_clicked_row_is :: proc(ctx: ^Scroll_Spec_Context, id: Ui_Id) {
	testing.expect_value(ctx.t, ctx.input.clicked_id, id)
}

then_state_store_contains :: proc(ctx: ^Scroll_Spec_Context, container_id: Ui_Id, expected: bool) {
	_, ok := ctx.store.scroll_states[container_id]
	testing.expect_value(ctx.t, ok, expected)
}

```

Would you like to expand `Widget_State_Store` next to cover Track 3's single-line/multi-line `Text_Field_State` (UTF-8 grapheme cursor movement, selection ranges, horizontal scroll-into-view, and bracketed paste), or add scrollbar thumb dragging (`ScrollBars.zig` / `ResizableSplit` style)?
