package bifrost_tests

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "../bifrost"
import actor "../deps/sleipnir/actor"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// Layer 3: Protocol Driver (Headless Frame Harness & Structural Invariants)
// =============================================================================

Suite_Ctx :: struct {
	t:               ^testing.T,
	track_alloc:     mem.Tracking_Allocator,
	alloc:           mem.Allocator,
	tracking_active: bool,

	screen:          bifrost.Screen,
	layout_ctx:      bifrost.Layout_Context,
	input:           bifrost.Input_State,
	state_store:     bifrost.Widget_State_Store,
	dispatch_steps:  [dynamic]bifrost.Dispatch_Step,
	consume_id:      u64,
	consume_phase:   bifrost.Event_Phase,
	has_consumer:    bool,
	ansi_buf:        strings.Builder,
	last_diff_bytes: int,
	last_ansi_str:   string,

	// Independent virtual terminal buffer reconstructed purely from ANSI diffs
	vt_cells:        []bifrost.Cell,
	vt_w:            i32,
	vt_h:            i32,

	// Track 4: Headless ANSI/Kitty/Mouse SGR stream reader & decoded event queue
	stream_reader:   bifrost.Input_Stream_Reader,
	parsed_events:   [dynamic]bifrost.Input_Event,
	last_parse_stat: bifrost.Parse_Status,
	last_consumed:   int,

	// Track 5: Sleipnir Actor Runtime + xitdb Shared Database + UI Coordinator Actor
	actor_active:    bool,
	db_core:         xitdb.Core,
	db:              xitdb.Database,
	shared_db:       bifrost.Xitdb_Shared_Handle,
	sched:           actor.Scheduler,
	ui_actor:        ^actor.Actor(bifrost.UI_Coordinator_State, bifrost.UI_Msg),
	worker_actor:    ^actor.Actor(bifrost.Xitdb_Worker_State, bifrost.Xitdb_Worker_Msg),
	ui_pid:          actor.PID(bifrost.UI_Msg),
	worker_pid:      actor.PID(bifrost.Xitdb_Worker_Msg),
	last_slice:      bifrost.Xitdb_Viewport_Slice,
}

driver_init :: proc(s: ^Suite_Ctx, t: ^testing.T, w: i32 = 80, h: i32 = 24) {
	s.t = t
	mem.tracking_allocator_init(&s.track_alloc, context.allocator)
	s.alloc = mem.tracking_allocator(&s.track_alloc)
	s.tracking_active = true

	err := bifrost.screen_init(&s.screen, w, h, s.alloc)
	testing.expect_value(t, err, nil)

	store_err := bifrost.state_store_init(&s.state_store, s.alloc)
	testing.expect_value(t, store_err, nil)

	s.dispatch_steps = make([dynamic]bifrost.Dispatch_Step, 0, 16, s.alloc)
	s.parsed_events = make([dynamic]bifrost.Input_Event, 0, 16, s.alloc)
	s.ansi_buf = strings.builder_make(s.alloc)
	total := int(max(0, w * h))
	s.vt_cells = make([]bifrost.Cell, total, s.alloc)
	s.vt_w = w
	s.vt_h = h
	for i in 0 ..< total {
		s.vt_cells[i] = bifrost.EMPTY_CELL
	}
}

driver_destroy :: proc(s: ^Suite_Ctx) {
	free_all(context.temp_allocator)
	if s.actor_active {
		actor.scheduler_wait_idle(&s.sched)
		if s.ui_actor != nil {
			bifrost.ui_coordinator_destroy(&s.ui_actor.state)
		}
		actor.scheduler_stop_and_destroy(&s.sched)
		_ = xitdb.core_destroy(&s.db_core)
		s.actor_active = false
	}
	delete(s.parsed_events)
	delete(s.dispatch_steps)
	bifrost.state_store_destroy(&s.state_store)
	delete(s.vt_cells, s.alloc)
	strings.builder_destroy(&s.ansi_buf)
	bifrost.screen_destroy(&s.screen)

	if s.tracking_active {
		for _, entry in s.track_alloc.allocation_map {
			testing.expect(s.t, false, fmt.tprintf("Memory leak: %v bytes allocated at %v", entry.size, entry.location))
		}
		for entry in s.track_alloc.bad_free_array {
			testing.expect(s.t, false, fmt.tprintf("Bad free: %p at %v", entry.memory, entry.location))
		}
		mem.tracking_allocator_destroy(&s.track_alloc)
		s.tracking_active = false
	}
}

driver_actor_xitdb_init :: proc(
	s: ^Suite_Ctx,
	t: ^testing.T,
	w: i32 = 80,
	h: i32 = 24,
	num_workers: int = 2,
	active_collection: string = "",
) {
	driver_init(s, t, w, h)
	s.db_core = xitdb.core_memory_init(s.alloc)
	db_inst, db_err := xitdb.database_init(&s.db_core)
	testing.expect_value(t, db_err, nil)
	s.db = db_inst
	s.shared_db = bifrost.Xitdb_Shared_Handle{db = &s.db}

	sched_err := actor.scheduler_init(&s.sched, actor.Scheduler_Config{
		num_workers    = num_workers,
		num_shards     = num_workers,
		batch_quota    = 2048,
		enable_parking = true,
	}, s.alloc)
	testing.expect_value(t, sched_err, nil)

	ui_act, ok := bifrost.spawn_ui_coordinator(&s.sched, int(w), int(h), &s.shared_db, nil, s.alloc)
	testing.expect(t, ok, "Expected spawn_ui_coordinator to succeed")
	ui_act.state.active_collection = active_collection
	s.ui_actor = ui_act
	s.ui_pid   = actor.pid(ui_act)

	worker_state := bifrost.Xitdb_Worker_State{
		shared = &s.shared_db,
		ui_pid = s.ui_pid,
	}
	w_act, w_err := actor.spawn(&s.sched, worker_state, bifrost.xitdb_worker_receive, 2, s.alloc)
	testing.expect_value(t, w_err, nil)
	s.worker_actor = w_act
	s.worker_pid   = actor.pid(w_act)

	actor.scheduler_start(&s.sched)
	s.actor_active = true
}

driver_actor_row_text :: proc(s: ^Suite_Ctx, row: int) -> string {
	if s.ui_actor == nil || row < 0 || row >= s.ui_actor.state.rows {
		return ""
	}
	cols := s.ui_actor.state.cols
	b := strings.builder_make(0, cols, context.temp_allocator)
	for x := 0; x < cols; x += 1 {
		ch := s.ui_actor.state.front_buf[row * cols + x].ch
		if ch == 0 {
			continue
		}
		strings.write_rune(&b, ch)
	}
	return strings.to_string(b)
}

driver_begin_frame :: proc(s: ^Suite_Ctx, default_bg: bifrost.Color = {}) {
	free_all(context.temp_allocator)
	bifrost.state_store_begin_frame(&s.state_store)
	bifrost.begin_layout(&s.layout_ctx, s.screen.width, s.screen.height, context.temp_allocator)
	bifrost.begin_frame(&s.screen, default_bg, context.temp_allocator)
}

driver_event_recorder :: proc(
	node_id: u64,
	phase: bifrost.Event_Phase,
	event: bifrost.Input_Event,
	userdata: rawptr,
) -> bool {
	_ = event
	s := (^Suite_Ctx)(userdata)
	id_str := ""
	if idx, ok := s.layout_ctx.id_map[node_id]; ok {
		id_str = s.layout_ctx.nodes[idx].id
	}
	append(&s.dispatch_steps, bifrost.Dispatch_Step{
		node_id = node_id,
		id      = id_str,
		phase   = phase,
	})
	if s.has_consumer && s.consume_id == node_id && s.consume_phase == phase {
		return true
	}
	return false
}

driver_end_frame :: proc(s: ^Suite_Ctx, events: ..bifrost.Input_Event) {
	bifrost.end_layout(&s.layout_ctx)
	clear(&s.dispatch_steps)
	s.input.event_handler = driver_event_recorder
	s.input.event_userdata = s
	bifrost.resolve_input(&s.input, &s.layout_ctx, ..events)
	bifrost.state_store_sync_from_layout(&s.state_store, &s.layout_ctx, &s.input)
	bifrost.apply_input_highlights(&s.screen, &s.layout_ctx, &s.input)
	bifrost.render_layout(&s.screen, &s.layout_ctx, context.temp_allocator)
	strings.builder_reset(&s.ansi_buf)
	s.last_diff_bytes = bifrost.screen_diff_ansi(&s.screen, &s.ansi_buf)
	s.last_ansi_str = strings.to_string(s.ansi_buf)

	vt_apply_ansi(s, s.last_ansi_str)
	assert_frame_invariants(s.t, s)
}

// Applies the emitted ANSI diff stream to the independent virtual terminal grid.
vt_apply_ansi :: proc(s: ^Suite_Ctx, ansi: string) {
	if len(ansi) == 0 {
		return
	}
	cur_x: i32 = 0
	cur_y: i32 = 0
	cur_fg := bifrost.Color{kind = .Default}
	cur_bg := bifrost.Color{kind = .Default}
	cur_style := bifrost.Style_Flags{}

	i := 0
	n := len(ansi)
	for i < n {
		if ansi[i] == 0x1b && i + 1 < n && ansi[i + 1] == '[' {
			i += 2
			// Check for private DEC mode (e.g. ?2026h / ?2026l)
			if i < n && ansi[i] == '?' {
				i += 1
				for i < n && !(ansi[i] >= '@' && ansi[i] <= '~') {
					i += 1
				}
				if i < n {
					i += 1
				}
				continue
			}

			param_start := i
			for i < n && !(ansi[i] >= '@' && ansi[i] <= '~') {
				i += 1
			}
			if i >= n {
				break
			}
			final_byte := ansi[i]
			params_str := ansi[param_start:i]
			i += 1

			switch final_byte {
			case 'H':
				// 1-based cursor jump: row;colH
				semi := strings.index_byte(params_str, ';')
				if semi >= 0 {
					row, _ := strconv.parse_int(params_str[:semi])
					col, _ := strconv.parse_int(params_str[semi + 1:])
					cur_y = i32(max(0, row - 1))
					cur_x = i32(max(0, col - 1))
				}
			case 'm':
				vt_parse_sgr(params_str, &cur_fg, &cur_bg, &cur_style)
			}
			continue
		}

		r, byte_len := utf8.decode_rune_in_string(ansi[i:])
		i += byte_len
		w := bifrost.rune_display_width(r)
		if w == 0 {
			w = 1
		}
		if cur_x >= 0 && cur_x < s.vt_w && cur_y >= 0 && cur_y < s.vt_h {
			idx := int(cur_y * s.vt_w + cur_x)
			// Heal split wide neighbors in VT grid just as a real terminal does
			if s.vt_cells[idx].width == 0 && cur_x > 0 {
				s.vt_cells[idx - 1].ch = ' '
				s.vt_cells[idx - 1].width = 1
			} else if s.vt_cells[idx].width == 2 && cur_x + 1 < s.vt_w {
				s.vt_cells[idx + 1].ch = ' '
				s.vt_cells[idx + 1].width = 1
			}
			if w == 2 && cur_x + 1 < s.vt_w {
				if s.vt_cells[idx + 1].width == 2 && cur_x + 2 < s.vt_w {
					s.vt_cells[idx + 2].ch = ' '
					s.vt_cells[idx + 2].width = 1
				}
				s.vt_cells[idx] = bifrost.Cell{
					ch    = r,
					fg    = cur_fg,
					bg    = cur_bg,
					style = cur_style,
					width = 2,
				}
				s.vt_cells[idx + 1] = bifrost.Cell{
					ch    = 0,
					fg    = cur_fg,
					bg    = cur_bg,
					style = cur_style,
					width = 0,
				}
			} else {
				s.vt_cells[idx] = bifrost.Cell{
					ch    = r,
					fg    = cur_fg,
					bg    = cur_bg,
					style = cur_style,
					width = 1,
				}
			}
		}
		cur_x += i32(w)
	}
}

vt_parse_sgr :: proc(params: string, fg, bg: ^bifrost.Color, style: ^bifrost.Style_Flags) {
	if len(params) == 0 {
		fg^ = {kind = .Default}
		bg^ = {kind = .Default}
		style^ = {}
		return
	}
	parts := strings.split(params, ";", context.temp_allocator)
	idx := 0
	for idx < len(parts) {
		code, _ := strconv.parse_int(parts[idx])
		idx += 1
		switch code {
		case 0:
			fg^ = {kind = .Default}
			bg^ = {kind = .Default}
			style^ = {}
		case 1:
			style^ += {.Bold}
		case 2:
			style^ += {.Dim}
		case 3:
			style^ += {.Italic}
		case 4:
			style^ += {.Underline}
		case 5:
			style^ += {.Blink}
		case 7:
			style^ += {.Reverse}
		case 9:
			style^ += {.Strikethrough}
		case 30 ..= 37:
			fg^ = bifrost.ansi16(u8(code - 30))
		case 39:
			fg^ = {kind = .Default}
		case 40 ..= 47:
			bg^ = bifrost.ansi16(u8(code - 40))
		case 49:
			bg^ = {kind = .Default}
		case 90 ..= 97:
			fg^ = bifrost.ansi16(u8(code - 90 + 8))
		case 100 ..= 107:
			bg^ = bifrost.ansi16(u8(code - 100 + 8))
		case 38, 48:
			is_bg := (code == 48)
			if idx < len(parts) {
				mode, _ := strconv.parse_int(parts[idx])
				idx += 1
				if mode == 5 && idx < len(parts) {
					pal, _ := strconv.parse_int(parts[idx])
					idx += 1
					c := bifrost.ansi256(u8(pal))
					if is_bg {
						bg^ = c
					} else {
						fg^ = c
					}
				} else if mode == 2 && idx + 2 < len(parts) {
					r, _ := strconv.parse_int(parts[idx])
					g, _ := strconv.parse_int(parts[idx + 1])
					b, _ := strconv.parse_int(parts[idx + 2])
					idx += 3
					c := bifrost.rgb(u8(r), u8(g), u8(b))
					if is_bg {
						bg^ = c
					} else {
						fg^ = c
					}
				}
			}
		}
	}
}

// Automatically verifies all 7 cross-cutting layout and rendering invariants after every frame.
assert_frame_invariants :: proc(t: ^testing.T, s: ^Suite_Ctx) {
	// 1. Stack balance: parent_stack and scope_stack must be empty after end_layout
	testing.expect_value(t, len(s.layout_ctx.parent_stack), 0)
	testing.expect_value(t, s.layout_ctx.scope_stack_len, 0)

	// 2. Non-negative geometry, clip containment, and non-overlapping in-flow siblings
	screen_bounds := bifrost.Rect{x = 0, y = 0, w = s.screen.width, h = s.screen.height}
	for i := 0; i < len(s.layout_ctx.nodes); i += 1 {
		node := s.layout_ctx.nodes[i]
		testing.expect(t, node.rect.w >= 0 && node.rect.h >= 0, "Negative node dimensions")
		testing.expect(t, node.inner_rect.w >= 0 && node.inner_rect.h >= 0, "Negative inner_rect dimensions")

		clipped := bifrost.rect_intersect(node.node_clip, screen_bounds)
		testing.expect_value(t, node.node_clip, clipped)

		// Verify in-flow siblings are monotonically ordered along main axis
		if node.child_count > 1 {
			prev_c := i32(-1)
			for c := node.first_child; c != -1; c = s.layout_ctx.nodes[c].next_sibling {
				child := s.layout_ctx.nodes[c]
				if child.out_of_flow {
					continue
				}
				if prev_c >= 0 {
					prev := s.layout_ctx.nodes[prev_c]
					if node.config.dir == .Row {
						testing.expect(
							t,
							child.rect.x >= prev.rect.x + prev.rect.w + node.config.gap,
							fmt.tprintf("Overlapping X siblings under %s: prev=%v child=%v", node.id, prev.rect, child.rect),
						)
					} else {
						testing.expect(
							t,
							child.rect.y >= prev.rect.y + prev.rect.h + node.config.gap,
							fmt.tprintf("Overlapping Y siblings under %s: prev=%v child=%v", node.id, prev.rect, child.rect),
						)
					}
				}
				prev_c = c
			}
		}
	}

	// 3. Wide-cell lead/spacer pairing, control-code hygiene, front/back parity, and VT equivalence
	w := s.screen.width
	h := s.screen.height
	for y: i32 = 0; y < h; y += 1 {
		for x: i32 = 0; x < w; x += 1 {
			idx := int(y * w + x)
			fc := s.screen.front[idx]
			bc := s.screen.back[idx]
			vc := s.vt_cells[idx]

			testing.expect_value(t, fc, bc)
			testing.expect_value(t, vc, fc)
			testing.expect(t, fc.width <= 2, "Invalid cell width > 2")

			if fc.width == 2 {
				testing.expect(t, x + 1 < w, "Wide lead cell on rightmost screen column")
				testing.expect(t, fc.ch >= 32, "Wide lead cell has control rune")
				if x + 1 < w {
					spacer := s.screen.front[idx + 1]
					testing.expect_value(t, spacer.width, u8(0))
					testing.expect_value(t, spacer.ch, rune(0))
					testing.expect_value(t, spacer.fg, fc.fg)
					testing.expect_value(t, spacer.bg, fc.bg)
					testing.expect_value(t, spacer.style, fc.style)
				}
			} else if fc.width == 0 {
				testing.expect(t, x > 0, "Orphaned wide spacer at column 0")
				testing.expect_value(t, fc.ch, rune(0))
				if x > 0 {
					lead := s.screen.front[idx - 1]
					testing.expect_value(t, lead.width, u8(2))
				}
			} else {
				testing.expect(
					t,
					fc.ch >= 32 && !(fc.ch >= 0x7f && fc.ch < 0xa0),
					"Control codepoint in narrow cell",
				)
			}
		}
	}

	// 4. Idempotent 0-byte clean diff when nothing changed
	second_buf := strings.builder_make(context.temp_allocator)
	second_bytes := bifrost.screen_diff_ansi(&s.screen, &second_buf)
	testing.expect_value(t, second_bytes, 0)
}
