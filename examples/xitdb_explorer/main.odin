package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../../bifrost"
import xitdb "../../deps/xitdb/xitdb"

// =============================================================================
// Bifrost xitdb Explorer & Datalog Workbench
// =============================================================================
// Interactive structural inspector, time-travel debugger, and Datalog/Tx
// workbench for `xitdb` databases built with Bifrost's immediate-mode TUI suite:
//   - Dynamic `ui_tree` walking live `xitdb` moments (`Hash_Map`, `Sorted_Map`,
//     `Counted_Hash_Map`, `Array_List`, `Linked_Array_List`, `Hash_Set`, scalars)
//   - Zero-copy `xitdb_slice_viewport` 2D virtualized slot table + `history_of` lineage
//   - Multi-line `ui_text_area` Datalog query & Layer 2 `transact_script` workbench
//   - Structural `diff_moments` table + `2×4` Braille storage growth telemetry

Theme_Preset :: enum u8 {
	Tokyo_Night = 0,
	Nord,
	Gruvbox,
}

Theme_Palette :: struct {
	name:      string,
	bg:        bifrost.Color,
	panel_bg:  bifrost.Color,
	header_bg: bifrost.Color,
	accent_fg: bifrost.Color,
	good_fg:   bifrost.Color,
	warn_fg:   bifrost.Color,
	bad_fg:    bifrost.Color,
	text_fg:   bifrost.Color,
	muted_fg:  bifrost.Color,
	border_fg: bifrost.Color,
	sel_bg:    bifrost.Color,
	sel_fg:    bifrost.Color,
}

@(rodata)
THEMES := [Theme_Preset]Theme_Palette{
	.Tokyo_Night = {
		name      = "Tokyo Night",
		bg        = {kind = .RGB, r = 20,  g = 22,  b = 34},
		panel_bg  = {kind = .RGB, r = 26,  g = 27,  b = 38},
		header_bg = {kind = .RGB, r = 36,  g = 40,  b = 59},
		accent_fg = {kind = .RGB, r = 122, g = 162, b = 247},
		good_fg   = {kind = .RGB, r = 158, g = 206, b = 106},
		warn_fg   = {kind = .RGB, r = 224, g = 175, b = 104},
		bad_fg    = {kind = .RGB, r = 247, g = 118, b = 142},
		text_fg   = {kind = .RGB, r = 192, g = 202, b = 245},
		muted_fg  = {kind = .RGB, r = 140, g = 152, b = 195},
		border_fg = {kind = .RGB, r = 65,  g = 72,  b = 104},
		sel_bg    = {kind = .RGB, r = 49,  g = 56,  b = 86},
		sel_fg    = {kind = .RGB, r = 224, g = 175, b = 104},
	},
	.Nord = {
		name      = "Nord",
		bg        = {kind = .RGB, r = 22,  g = 26,  b = 34},
		panel_bg  = {kind = .RGB, r = 28,  g = 34,  b = 45},
		header_bg = {kind = .RGB, r = 36,  g = 46,  b = 66},
		accent_fg = {kind = .RGB, r = 136, g = 192, b = 208},
		good_fg   = {kind = .RGB, r = 163, g = 190, b = 140},
		warn_fg   = {kind = .RGB, r = 235, g = 203, b = 139},
		bad_fg    = {kind = .RGB, r = 191, g = 97,  b = 106},
		text_fg   = {kind = .RGB, r = 216, g = 222, b = 233},
		muted_fg  = {kind = .RGB, r = 129, g = 161, b = 193},
		border_fg = {kind = .RGB, r = 76,  g = 86,  b = 106},
		sel_bg    = {kind = .RGB, r = 59,  g = 66,  b = 82},
		sel_fg    = {kind = .RGB, r = 235, g = 203, b = 139},
	},
	.Gruvbox = {
		name      = "Gruvbox",
		bg        = {kind = .RGB, r = 29,  g = 32,  b = 33},
		panel_bg  = {kind = .RGB, r = 40,  g = 40,  b = 40},
		header_bg = {kind = .RGB, r = 60,  g = 56,  b = 54},
		accent_fg = {kind = .RGB, r = 250, g = 189, b = 47},
		good_fg   = {kind = .RGB, r = 184, g = 187, b = 38},
		warn_fg   = {kind = .RGB, r = 254, g = 128, b = 25},
		bad_fg    = {kind = .RGB, r = 251, g = 73,  b = 52},
		text_fg   = {kind = .RGB, r = 235, g = 219, b = 178},
		muted_fg  = {kind = .RGB, r = 168, g = 153, b = 132},
		border_fg = {kind = .RGB, r = 102, g = 92,  b = 84},
		sel_bg    = {kind = .RGB, r = 80,  g = 73,  b = 69},
		sel_fg    = {kind = .RGB, r = 254, g = 128, b = 25},
	},
}

Explorer_Action :: enum u8 {
	None = 0,
	Moment_Prev,
	Moment_Next,
	Moment_Follow,
	Run_Datalog,
	Commit_Tx,
	Cycle_Preset,
	Focus_Filter,
	Focus_Tree,
	Focus_Workbench,
	Tab_1,
	Tab_2,
	Tab_3,
	Theme_Cycle,
	Style_Cycle,
	Quit,
}

Explorer_Actions :: struct {
	Moment_Prev:     Explorer_Action `bifrost:"vim=,, helix=,, emacs=<C-x> [, id=moment.prev, group=moment, group_desc='Moment (, / .)', desc=Prev @m, label='Step Backward One xitdb Moment (,)', category='Time Travel'"`,
	Moment_Next:     Explorer_Action `bifrost:"vim=., helix=., emacs=<C-x> ], id=moment.next, group=moment, group_desc='Moment (, / .)', desc=Next @m, label='Step Forward One xitdb Moment (.)', category='Time Travel'"`,
	Moment_Follow:   Explorer_Action `bifrost:"vim=f, helix=<Space> f, emacs=<C-x> f, id=moment.follow, desc=Follow @-1, label='Follow Latest Committed Moment (f)', category='Time Travel'"`,
	Run_Datalog:     Explorer_Action `bifrost:"vim=r, helix=<Space> r, emacs=<C-c> <C-c>, id=workbench.query, desc='Run Query (r)', label='Execute Datalog Query in Workbench (r)', category=Workbench"`,
	Commit_Tx:       Explorer_Action `bifrost:"vim=x, helix=<Space> x, emacs=<C-x> x, id=workbench.tx, desc='Commit Tx (x)', label='Commit Layer 2 Transaction Script (x)', category=Workbench"`,
	Cycle_Preset:    Explorer_Action `bifrost:"vim=p, helix=<Space> p, emacs=<C-x> p, id=workbench.preset, desc='Preset (p)', label='Cycle Datalog / Transaction Script Preset (p)', category=Workbench"`,
	Focus_Filter:    Explorer_Action `bifrost:"vim=/, helix=/, emacs=<C-s>, id=filter.focus, desc='Filter (/)', label='Focus Collection Prefix/Substring Filter (/)', category=Navigation"`,
	Focus_Tree:      Explorer_Action `bifrost:"vim=g t, helix=g t, emacs=<C-x> t, id=nav.tree, desc=Tree, label='Focus Structural Database Tree (g t)', category=Navigation"`,
	Focus_Workbench: Explorer_Action `bifrost:"vim=g w, helix=g w, emacs=<C-x> w, id=nav.workbench, desc=Workbench, label='Switch to Tab 2 & Focus Datalog Workbench (g w)', category=Navigation"`,
	Tab_1:           Explorer_Action `bifrost:"key=<A-1>, id=tab.slots, desc='Tab 1: Slots', label='Switch to Tab 1: Slot & Lineage Inspector (Alt+1)', category=Navigation"`,
	Tab_2:           Explorer_Action `bifrost:"key=<A-2>, id=tab.datalog, desc='Tab 2: Datalog', label='Switch to Tab 2: Datalog & Tx Workbench (Alt+2)', category=Navigation"`,
	Tab_3:           Explorer_Action `bifrost:"key=<A-3>, id=tab.diff, desc='Tab 3: Diff', label='Switch to Tab 3: Structural Diff & Telemetry (Alt+3)', category=Navigation"`,
	Theme_Cycle:     Explorer_Action `bifrost:"key=<C-t>, id=theme.cycle, allow_in_edit=true, desc=Theme, label='Cycle Color Theme (Tokyo Night / Nord / Gruvbox)', category=Appearance"`,
	Style_Cycle:     Explorer_Action `bifrost:"key=<F2>, id=style.cycle, policy=global, allow_in_edit=true, desc='Bindings (F2)', label='Cycle Keymap Style (Vim / Helix / Emacs) [F2]', category=Keymap"`,
	Quit:            Explorer_Action `bifrost:"vim=q|<C-q>|<C-c>, helix=q|<C-q>|<C-c>, emacs=<C-x> c|<C-q>, id=app.quit, policy=global, desc=Quit, label='Quit xitdb Explorer', category=System"`,
}

Workbench_Preset :: struct {
	title:   string,
	is_tx:   bool,
	content: string,
}

@(rodata)
WORKBENCH_PRESETS := [5]Workbench_Preset{
	{
		title   = "Datalog 1: Join + Predicate Filter (Salary >= 135k)",
		is_tx   = false,
		content = `find ?id, ?name, ?dept, ?role, ?salary
where
	.users[?id].name   = ?name
	.users[?id].dept   = ?dept
	.users[?id].role   = ?role
	.users[?id].salary = ?salary
	?salary >= 135000`,
	},
	{
		title   = "Datalog 2: Grouped Department Aggregations (count, min, max, sum)",
		is_tx   = false,
		content = `find ?dept, count(?id), min(?salary), max(?salary), sum(?salary)
where
	.users[?id].dept   = ?dept
	.users[?id].salary = ?salary`,
	},
	{
		title   = "Datalog 3: Cycle-Safe Transitive Closure (reach over .graph)",
		is_tx   = false,
		content = `find ?from, ?to, ?hops
where
	reach(?from, ?to, ?hops, .graph[?from]%?to)`,
	},
	{
		title   = "Datalog 4: Cross-Moment Temporal Lineage (@?m unification)",
		is_tx   = false,
		content = `find ?m, ?author, ?doc, ?seq
where
	@?m.__tx.author            = ?author
	@?m.__tx.doc               = ?doc
	@?m.#counters["deploy_seq"] = ?seq`,
	},
	{
		title   = "Layer 2 Tx Script: Branch @-1 & Mutate Collections Atomically",
		is_tx   = true,
		content = `branch @-1 {
	doc "Scale cluster replicas & promote u102 to Principal"
	instant 1700004800
	meta "author" = "sre-bot"

	put .users["u102"].role        = "Principal Eng"
	put .users["u102"].salary      = 172000u
	put $metrics["api:p99_ms"]     = 2u
	put #counters["deploy_seq"]    = 105u
	append .events                 = "deploy:v2.5.0-canary"
}`,
	},
}

MAX_TREE_NODES_CAP   :: 128
MAX_DATALOG_ROWS_CAP :: 32
MAX_DATALOG_COLS_CAP :: 6
MAX_MOMENT_HIST_CAP  :: 32

Explorer_Tree_Entry :: struct {
	node:            bifrost.Tree_Node,
	selector_path:   string,
	collection_path: string,
	tag:             xitdb.Tag,
	slot_offset:     i64,
}

Datalog_Table_Cache :: struct {
	col_names: [MAX_DATALOG_COLS_CAP]string,
	col_count: int,
	cells:     [MAX_DATALOG_ROWS_CAP][MAX_DATALOG_COLS_CAP]string,
	row_count: int,
	status:    string,
	has_error: bool,
	arena_buf: [4096]u8,
	arena:     mem.Arena,
}

Explorer_App :: struct {
	screen:           bifrost.Screen,
	layout_ctx:       bifrost.Layout_Context,
	input:            bifrost.Input_State,
	state_store:      bifrost.Widget_State_Store,
	palette:          bifrost.Command_Palette,
	ansi_builder:     strings.Builder,
	db:               ^xitdb.Database,
	db_label:         string,
	theme:            Theme_Preset,
	pinned_moment:    i64, // -1 = follow latest
	resolved_moment:  i64,
	total_moments:    i64,
	selected_path:    string,
	selected_coll:    string,
	preset_idx:       int,
	live_commits:     int,
	frames_rendered:  int,
	action_count:     int,
	quit_requested:   bool,
	last_action:      string,
	slot_col_specs:   [4]bifrost.Table_Column_Spec,
	tree_entries:     [MAX_TREE_NODES_CAP]Explorer_Tree_Entry,
	tree_nodes:       [MAX_TREE_NODES_CAP]bifrost.Tree_Node,
	tree_count:       int,
	tree_arena_buf:   [32768]u8,
	tree_arena:       mem.Arena,
	moment_bytes:     [MAX_MOMENT_HIST_CAP]f32,
	moment_changes:   [MAX_MOMENT_HIST_CAP]f32,
	moment_hist_len:  int,
	datalog_cache:    Datalog_Table_Cache,
	path_buf:         [128]u8,
	path_len:         int,
	coll_buf:         [128]u8,
	coll_len:         int,
	status_buf:       [128]u8,
	status_len:       int,
}

make_slot_filter :: proc(raw_q: string) -> bifrost.Xitdb_Filter {
	q := strings.trim_space(raw_q)
	if len(q) == 0 {
		return {}
	}
	if strings.has_prefix(q, "^") {
		return bifrost.Xitdb_Filter{kind = .Key_Prefix, prefix = q[1:]}
	}
	return bifrost.Xitdb_Filter{kind = .Substring, needle = q}
}

set_selected_paths :: proc(app: ^Explorer_App, sel_path: string, coll_path: string) {
	s_formatted := fmt.bprintf(app.path_buf[:], "%s", sel_path)
	app.path_len = len(s_formatted)
	app.selected_path = string(app.path_buf[:app.path_len])

	c_formatted := fmt.bprintf(app.coll_buf[:], "%s", coll_path)
	app.coll_len = len(c_formatted)
	app.selected_coll = string(app.coll_buf[:app.coll_len])
}

set_last_action :: proc(app: ^Explorer_App, msg: string) {
	formatted := fmt.bprintf(app.status_buf[:], "%s", msg)
	app.status_len = len(formatted)
	app.last_action = string(app.status_buf[:app.status_len])
}

// Seed a rich 4-moment (`@0 .. @3`) in-memory `xitdb` database exercising all 8 collection families
seed_demo_database :: proc(db: ^xitdb.Database) {
	// Moment @0: Genesis schema — users, $metrics Sorted_Map, #counters Counted_Hash_Map, .events Array_List, .graph Hash_Set edges
	_, _ = xitdb.transact_script(db, `
		branch @-1 {
			doc "Genesis schema: users, $metrics B+Tree, #counters, .events & .graph"
			instant 1700001000
			meta "author" = "ada"

			put .users["u101"].name   = "Ada Lovelace"
			put .users["u101"].dept   = "runtime"
			put .users["u101"].role   = "Staff Eng"
			put .users["u101"].salary = 165000u
			put .users["u101"].perms%"admin"   = "admin"
			put .users["u101"].perms%"deploy"  = "deploy"
			append .users["u101"].tasks        = "Design 6-pass layout"
			append .users["u101"].tasks        = "Verify H* focus scopes"

			put .users["u102"].name   = "Grace Hopper"
			put .users["u102"].dept   = "compiler"
			put .users["u102"].role   = "Senior Eng"
			put .users["u102"].salary = 152000u
			put .users["u102"].perms%"deploy"  = "deploy"
			append .users["u102"].tasks        = "Build Datalog optimizer"

			put $metrics["api:p99_ms"]         = 7u
			put $metrics["api:req_per_sec"]    = 4820u
			put $metrics["auth:rebac_us"]      = 19u
			put $metrics["db:btree_depth"]     = 2u
			put $metrics["db:cache_hit_pct"]   = 96u
			put $metrics["ui:frame_us"]        = 240u

			put #counters["deploy_seq"]        = 101u
			put #counters["active_sessions"]   = 42u
			put #counters["schema_version"]    = 1u

			append .events = "boot:genesis-cluster-init"
			append .events = "index:sorted-map-metrics-online"

			put .graph["ui-gateway"]%"auth-service"  = "auth-service"
			put .graph["ui-gateway"]%"api-router"    = "api-router"
			put .graph["api-router"]%"xitdb-store"   = "xitdb-store"
			put .graph["auth-service"]%"xitdb-store" = "xitdb-store"
		}
	`)

	// Moment @1: Onboard storage & runtime engineers + expand service dependency graph
	_, _ = xitdb.transact_script(db, `
		branch @-1 {
			doc "Onboard u103 (Ken) & u104 (Leslie) and link s3-cold-tier replica"
			instant 1700002000
			meta "author" = "grace"

			put .users["u103"].name   = "Ken Thompson"
			put .users["u103"].dept   = "storage"
			put .users["u103"].role   = "Principal Eng"
			put .users["u103"].salary = 178000u
			put .users["u103"].perms%"admin"   = "admin"
			append .users["u103"].tasks        = "Implement HAMT & B+Tree cursor seek"

			put .users["u104"].name   = "Leslie Lamport"
			put .users["u104"].dept   = "runtime"
			put .users["u104"].role   = "Distinguished"
			put .users["u104"].salary = 185000u
			put .users["u104"].perms%"verify"  = "verify"
			append .users["u104"].tasks        = "Model check Vyukov MPSC queues"

			put #counters["deploy_seq"]      = 102u
			put #counters["active_sessions"] = 68u
			append .events                   = "team:onboarded-storage-and-runtime"
			put .graph["xitdb-store"]%"s3-cold-tier" = "s3-cold-tier"
		}
	`)

	// Moment @2: Tune B+Tree prefix pushdown & record latency improvements
	_, _ = xitdb.transact_script(db, `
		branch @-1 {
			doc "Enable B+Tree prefix pushdown; api:p99_ms drops 7ms -> 4ms"
			instant 1700003000
			meta "author" = "ken"

			put $metrics["api:p99_ms"]       = 4u
			put $metrics["api:req_per_sec"]  = 7950u
			put $metrics["db:prefix_seeks"]  = 1240u
			put $metrics["db:cache_hit_pct"] = 99u

			put #counters["deploy_seq"]      = 103u
			append .events                   = "perf:btree-prefix-pushdown-enabled"
		}
	`)

	// Moment @3: Annual compensation review & Sleipnir actor pool telemetry
	_, _ = xitdb.transact_script(db, `
		branch @-1 {
			doc "Annual review adjustments & Sleipnir actor pool telemetry"
			instant 1700004000
			meta "author" = "leslie"

			put .users["u101"].salary         = 175000u
			put .users["u102"].salary         = 160000u
			put $metrics["actor:coalesced"]   = 512u
			put $metrics["actor:msg_per_sec"] = 24500u
			put #counters["deploy_seq"]       = 104u
			put #counters["active_sessions"]  = 94u
			append .events                    = "review:q4-comp-updated"
		}
	`)

	// Moment @4: Scale cluster replicas, promote u102, and add u105 (Barbara Liskov)
	_, _ = xitdb.transact_script(db, `
		branch @-1 {
			doc "Scale cluster replicas, promote u102 & onboard u105 (Barbara)"
			instant 1700004800
			meta "author" = "sre-bot"

			put .users["u102"].role           = "Principal Eng"
			put .users["u102"].salary         = 172000u
			put .users["u105"].name           = "Barbara Liskov"
			put .users["u105"].dept           = "distributed"
			put .users["u105"].role           = "Institute Prof"
			put .users["u105"].salary         = 192000u
			put .users["u105"].perms%"admin"  = "admin"
			put .users["u105"].perms%"consensus" = "consensus"
			append .users["u105"].tasks       = "Specify Viewstamped Replication"

			put $metrics["api:p99_ms"]        = 2u
			put $metrics["api:req_per_sec"]   = 11400u
			put $metrics["raft:quorum_ms"]    = 3u
			put #counters["deploy_seq"]       = 105u
			put #counters["active_sessions"]  = 128u
			append .events                    = "deploy:v2.5.0-canary"
			put .graph["xitdb-store"]%"raft-consensus" = "raft-consensus"
		}
	`)
}

format_tag_badge :: proc(tag: xitdb.Tag) -> string {
	#partial switch tag {
	case .None:              return "None"
	case .Array_List:        return "Array_List"
	case .Linked_Array_List: return "Linked_List"
	case .Hash_Map:          return "Hash_Map"
	case .Counted_Hash_Map:  return "Counted_Map"
	case .Sorted_Map:        return "Sorted_Map"
	case .Hash_Set:          return "Hash_Set"
	case .Counted_Hash_Set:  return "Counted_Set"
	case .Sorted_Set:        return "Sorted_Set"
	case .Short_Bytes:       return "Short_Bytes"
	case .Bytes:             return "Bytes"
	case .Uint:              return "Uint"
	case .Int:               return "Int"
	case .Float:             return "Float"
	}
	return "Slot"
}

format_tag_icon :: proc(tag: xitdb.Tag, key: string) -> string {
	if key == "__tx" {
		return "🕒"
	}
	#partial switch tag {
	case .Hash_Map:          return "📂"
	case .Counted_Hash_Map:  return "📊"
	case .Sorted_Map:        return "🌲"
	case .Array_List:        return "📋"
	case .Linked_Array_List: return "📜"
	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		return "⚡"
	case .Uint, .Int, .Float:
		return "🔢"
	case .Short_Bytes, .Bytes:
		return "📝"
	}
	return "•"
}

is_collection_tag :: proc(tag: xitdb.Tag) -> bool {
	#partial switch tag {
	case .Array_List, .Linked_Array_List, .Hash_Map, .Counted_Hash_Map,
	     .Sorted_Map, .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		return true
	}
	return false
}

needs_bracket_quote :: proc(key: string) -> bool {
	if len(key) == 0 {
		return true
	}
	for i in 0 ..< len(key) {
		ch := key[i]
		is_alpha := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
		is_digit := ch >= '0' && ch <= '9'
		if i == 0 && !is_alpha {
			return true
		}
		if !is_alpha && !is_digit && ch != '-' {
			return true
		}
	}
	return false
}

format_child_selector :: proc(parent_path: string, parent_tag: xitdb.Tag, key: string, idx: i64, alloc := context.temp_allocator) -> string {
	sigil := "."
	#partial switch parent_tag {
	case .Hash_Map:         sigil = "."
	case .Counted_Hash_Map: sigil = "#"
	case .Sorted_Map:       sigil = "$"
	case .Array_List:
		return fmt.aprintf("%s[%d]", parent_path, idx, allocator = alloc)
	case .Linked_Array_List:
		return fmt.aprintf("%s[[%d]]", parent_path, idx, allocator = alloc)
	case .Hash_Set:
		return fmt.aprintf("%s%%\"%s\"", parent_path, key, allocator = alloc)
	case .Counted_Hash_Set:
		return fmt.aprintf("%s#%%\"%s\"", parent_path, key, allocator = alloc)
	case .Sorted_Set:
		return fmt.aprintf("%s^\"%s\"", parent_path, key, allocator = alloc)
	}
	if needs_bracket_quote(key) {
		if sigil == "." && len(parent_path) > 0 {
			return fmt.aprintf("%s[\"%s\"]", parent_path, key, allocator = alloc)
		}
		return fmt.aprintf("%s%s[\"%s\"]", parent_path, sigil, key, allocator = alloc)
	}
	return fmt.aprintf("%s%s%s", parent_path, sigil, key, allocator = alloc)
}

append_tree_node_recursive :: proc(
	app: ^Explorer_App,
	cur: xitdb.Read_Cursor,
	node_id: string,
	label: string,
	icon: string,
	selector_path: string,
	parent_coll_path: string,
	depth: i32,
	default_expanded: bool,
	arena_alloc: mem.Allocator,
) {
	if app.tree_count >= MAX_TREE_NODES_CAP {
		return
	}
	slot, s_err := xitdb.cursor_slot(cur)
	if s_err != nil {
		return
	}
	has_children := is_collection_tag(slot.tag) && depth < 3
	coll_target := selector_path if is_collection_tag(slot.tag) else parent_coll_path

	idx := app.tree_count
	app.tree_count += 1
	app.tree_entries[idx] = Explorer_Tree_Entry{
		node = bifrost.Tree_Node{
			id           = node_id,
			label        = label,
			icon         = icon,
			depth        = depth,
			expanded     = default_expanded,
			has_children = has_children,
			parent_idx   = -1,
		},
		selector_path   = selector_path,
		collection_path = coll_target,
		tag             = slot.tag,
		slot_offset     = slot.value,
	}
	app.tree_nodes[idx] = app.tree_entries[idx].node

	if !has_children {
		return
	}

	it, it_err := xitdb.cursor_iterator(cur)
	if it_err != nil {
		return
	}

	child_idx: i64 = 0
	key_buf: [256]u8
	for app.tree_count < MAX_TREE_NODES_CAP {
		c_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			break
		}
		c, has_c := c_maybe.?
		if !has_c {
			break
		}

		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List:
			c_slot, _ := xitdb.cursor_slot(c)
			c_path := format_child_selector(selector_path, slot.tag, "", child_idx, arena_alloc)
			c_preview := bifrost.xitdb_format_cursor_preview(c, arena_alloc)
			c_label := fmt.aprintf("[%d] = %s (%s)", child_idx, c_preview, format_tag_badge(c_slot.tag), allocator = arena_alloc)
			c_id := fmt.aprintf("node_%s", c_path, allocator = arena_alloc)
			append_tree_node_recursive(
				app,
				c,
				c_id,
				c_label,
				format_tag_icon(c_slot.tag, ""),
				c_path,
				selector_path,
				depth + 1,
				false,
				arena_alloc,
			)
			child_idx += 1

		case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			kv, kv_err := xitdb.cursor_read_kv_pair(c, context.temp_allocator)
			if kv_err != nil {
				continue
			}
			k_raw, _ := xitdb.cursor_read_bytes_buf(kv.key_cursor, key_buf[:])
			k_str := strings.clone(string(k_raw.value), arena_alloc)
			c_path := format_child_selector(selector_path, slot.tag, k_str, child_idx, arena_alloc)
			c_label := fmt.aprintf("%%%s (member)", k_str, allocator = arena_alloc)
			c_id := fmt.aprintf("node_%s", c_path, allocator = arena_alloc)
			append_tree_node_recursive(
				app,
				kv.key_cursor,
				c_id,
				c_label,
				"⚡",
				c_path,
				selector_path,
				depth + 1,
				false,
				arena_alloc,
			)
			child_idx += 1

		case:
			kv, kv_err := xitdb.cursor_read_kv_pair(c, context.temp_allocator)
			if kv_err != nil {
				continue
			}
			k_raw, _ := xitdb.cursor_read_bytes_buf(kv.key_cursor, key_buf[:])
			k_str := strings.clone(string(k_raw.value), arena_alloc)
			val_slot, _ := xitdb.cursor_slot(kv.value_cursor)
			c_path := format_child_selector(selector_path, slot.tag, k_str, child_idx, arena_alloc)
			c_preview := bifrost.xitdb_format_cursor_preview(kv.value_cursor, arena_alloc)

			sigil_prefix := "."
			if val_slot.tag == .Sorted_Map {
				sigil_prefix = "$"
			} else if val_slot.tag == .Counted_Hash_Map {
				sigil_prefix = "#"
			} else if val_slot.tag == .Hash_Set {
				sigil_prefix = "%"
			}

			c_label: string
			if is_collection_tag(val_slot.tag) {
				c_label = fmt.aprintf("%s%s %s (%s)", sigil_prefix if depth == 1 else "", k_str, c_preview, format_tag_badge(val_slot.tag), allocator = arena_alloc)
			} else {
				c_label = fmt.aprintf("%s = %s (%s)", k_str, c_preview, format_tag_badge(val_slot.tag), allocator = arena_alloc)
			}
			c_id := fmt.aprintf("node_%s", c_path, allocator = arena_alloc)
			expand_by_default := (depth == 0) || (depth == 1 && k_str == "users") || (depth == 2 && k_str == "u101")
			append_tree_node_recursive(
				app,
				kv.value_cursor,
				c_id,
				c_label,
				format_tag_icon(val_slot.tag, k_str),
				c_path,
				selector_path,
				depth + 1,
				expand_by_default,
				arena_alloc,
			)
			child_idx += 1
		}
	}
}

rebuild_moment_tree_and_stats :: proc(app: ^Explorer_App) {
	app.tree_count = 0
	if app.db == nil {
		return
	}

	mem.arena_init(&app.tree_arena, app.tree_arena_buf[:])
	arena_alloc := mem.arena_allocator(&app.tree_arena)

	rc := xitdb.database_root_cursor(app.db).read_cursor
	history, h_err := xitdb.read_array_list_init(rc)
	if h_err == nil {
		cnt, _ := xitdb.array_list_count(history)
		app.total_moments = cnt
	}

	moment_cur, resolved_idx, m_err := bifrost.xitdb_open_moment_cursor(app.db, app.pinned_moment)
	if m_err != nil {
		return
	}
	app.resolved_moment = resolved_idx

	root_label := fmt.aprintf("@%d moment root (%d total)", resolved_idx, app.total_moments, allocator = arena_alloc)
	append_tree_node_recursive(
		app,
		moment_cur,
		"moment_root",
		root_label,
		"📦",
		"",
		"",
		0,
		true,
		arena_alloc,
	)

	// Recompute per-moment telemetry (slot offsets & diff counts) across @0 ..< total_moments
	hist_n := min(int(app.total_moments), MAX_MOMENT_HIST_CAP)
	app.moment_hist_len = hist_n
	for i := 0; i < hist_n; i += 1 {
		mc, _, err := bifrost.xitdb_open_moment_cursor(app.db, i64(i))
		if err == nil {
			mslot, _ := xitdb.cursor_slot(mc)
			app.moment_bytes[i] = f32(mslot.value) / 1024.0
		}
		if i == 0 {
			app.moment_changes[i] = 10.0
		} else {
			diffs, d_err := xitdb.diff_moments(app.db, i64(i - 1), i64(i), false, context.temp_allocator)
			app.moment_changes[i] = f32(len(diffs)) if d_err == nil else 0.0
		}
	}
}

format_pull_value :: proc(v: xitdb.Pull_Value, alloc := context.temp_allocator) -> string {
	switch val in v {
	case u64:
		return fmt.aprintf("%d", val, allocator = alloc)
	case i64:
		return fmt.aprintf("%d", val, allocator = alloc)
	case f64:
		return fmt.aprintf("%.2f", val, allocator = alloc)
	case string:
		return strings.clone(val, alloc)
	case xitdb.Bytes:
		return strings.clone(string(val.value), alloc)
	case xitdb.Pull_List:
		return fmt.aprintf("[%d items]", len(val), allocator = alloc)
	case xitdb.Pull_Map:
		return fmt.aprintf("{%d fields}", len(val), allocator = alloc)
	}
	return "nil"
}

execute_workbench_datalog :: proc(app: ^Explorer_App, query_src: string) {
	cache := &app.datalog_cache
	mem.arena_init(&cache.arena, cache.arena_buf[:])
	arena_alloc := mem.arena_allocator(&cache.arena)

	trimmed := strings.trim_space(query_src)
	if strings.has_prefix(trimmed, "branch ") || strings.has_prefix(trimmed, "tx ") {
		cache.col_count = 1
		cache.row_count = 0
		cache.col_names[0] = "Notice"
		cache.has_error = false
		cache.status = strings.clone("Editor holds a Layer 2 Transaction Script — press 'x' to commit!", arena_alloc)
		return
	}

	res, err := xitdb.query_datalog(app.db, trimmed, app.resolved_moment, context.temp_allocator)
	if err != nil {
		cache.col_count = 1
		cache.row_count = 0
		cache.col_names[0] = "Error"
		cache.has_error = true
		cache.status = fmt.aprintf("Datalog error: %v", err, allocator = arena_alloc)
		return
	}

	cache.has_error = false
	cache.col_count = clamp(len(res.vars), 0, MAX_DATALOG_COLS_CAP)
	for c in 0 ..< cache.col_count {
		cache.col_names[c] = strings.clone(res.vars[c], arena_alloc)
	}

	cache.row_count = clamp(len(res.rows), 0, MAX_DATALOG_ROWS_CAP)
	for r in 0 ..< cache.row_count {
		row_vals := res.rows[r]
		for c in 0 ..< cache.col_count {
			cell_str := format_pull_value(row_vals[c], arena_alloc) if c < len(row_vals) else ""
			cache.cells[r][c] = cell_str
		}
	}
	cache.status = fmt.aprintf("Matched %d rows across %d columns (@%d)", cache.row_count, cache.col_count, app.resolved_moment, allocator = arena_alloc)
}

read_moment_tx_summary :: proc(db: ^xitdb.Database, moment_idx: i64, alloc := context.temp_allocator) -> (doc: string, author: string, root_offset: i64) {
	mc, _, err := bifrost.xitdb_open_moment_cursor(db, moment_idx)
	if err != nil {
		return "n/a", "n/a", 0
	}
	mslot, _ := xitdb.cursor_slot(mc)
	root_offset = mslot.value
	doc_s, d_err := xitdb.get_string(db, fmt.aprintf("@%d.__tx.doc", moment_idx, allocator = alloc), alloc)
	auth_s, a_err := xitdb.get_string(db, fmt.aprintf("@%d.__tx.author", moment_idx, allocator = alloc), alloc)
	return (doc_s if d_err == nil else "(genesis)"), (auth_s if a_err == nil else "system"), root_offset
}

draw_storage_braille_canvas :: proc(canvas: ^bifrost.Braille_Canvas, userdata: rawptr) {
	app := (^Explorer_App)(userdata)
	if app == nil || canvas.pixel_w < 4 || canvas.pixel_h < 4 {
		return
	}
	pal := THEMES[app.theme]

	bifrost.canvas_draw_rect(canvas, 0, 0, canvas.pixel_w, canvas.pixel_h, pal.border_fg)

	// Horizontal baseline grid
	mid_y := canvas.pixel_h / 2
	for x: i32 = 2; x < canvas.pixel_w - 2; x += 4 {
		bifrost.canvas_set_point(canvas, x, mid_y, pal.border_fg)
	}

	if app.moment_hist_len > 0 {
		max_kb: f32 = 1.0
		for i := 0; i < app.moment_hist_len; i += 1 {
			if app.moment_bytes[i] > max_kb {
				max_kb = app.moment_bytes[i]
			}
		}
		bifrost.canvas_draw_series(
			canvas,
			app.moment_bytes[:app.moment_hist_len],
			0.0,
			max_kb * 1.15,
			pal.good_fg,
		)
	}
}

explorer_init :: proc(app: ^Explorer_App, db: ^xitdb.Database, db_label: string, cols, rows: i32, allocator := context.allocator) -> bool {
	app^ = {}
	if bifrost.screen_init(&app.screen, cols, rows, allocator) != nil {
		return false
	}
	if bifrost.state_store_init(&app.state_store, allocator) != nil {
		bifrost.screen_destroy(&app.screen)
		return false
	}
	app.ansi_builder  = strings.builder_make(0, 8192, allocator)
	app.db            = db
	app.db_label      = db_label
	app.theme         = .Tokyo_Night
	app.pinned_moment = -1

	app.slot_col_specs = [4]bifrost.Table_Column_Spec{
		{header = "Key / Step",  kind = .Auto_Content, min_width = 12, max_width = 24},
		{header = "Wire Tag",    kind = .Fixed,        value = 12,     min_width = 10, max_width = 14},
		{header = "Slot Offset", kind = .Fixed,        value = 9,      min_width = 8,  max_width = 10},
		{header = "Value",       kind = .Fill,         value = 1,      min_width = 16},
	}

	set_selected_paths(app, ".users", ".users")
	set_last_action(app, "ready")
	rebuild_moment_tree_and_stats(app)
	execute_workbench_datalog(app, WORKBENCH_PRESETS[0].content)

	bifrost.set_text_area(&app.input, "workbench_editor", WORKBENCH_PRESETS[0].content)
	app.input.wants_focus_id = bifrost.hash_id("db_tree")

	bifrost.clear_keybindings(&app.input)
	bifrost.command_palette_init(&app.palette, &app.input)
	_ = bifrost.register_actions_struct(&app.input, &app.palette, Explorer_Actions{})

	bifrost.bind_splitter_key(&app.input, bifrost.Key_Event{code = .Rune, ch = 'b', mods = {.Ctrl}}, "explorer_split", -4, "split.narrow")
	bifrost.bind_splitter_key(&app.input, bifrost.Key_Event{code = .Rune, ch = 'f', mods = {.Ctrl}}, "explorer_split", +4, "split.widen")
	bifrost.register_command(&app.palette, "split.widen",  "Widen Tree Explorer Splitter (+4 cols)",  "Layout")
	bifrost.register_command(&app.palette, "split.narrow", "Narrow Tree Explorer Splitter (-4 cols)", "Layout")

	return true
}

explorer_destroy :: proc(app: ^Explorer_App) {
	strings.builder_destroy(&app.ansi_builder)
	bifrost.state_store_destroy(&app.state_store)
	bifrost.screen_destroy(&app.screen)
	app^ = {}
}

build_explorer_ui :: proc(
	app: ^Explorer_App,
	out_tree_slice: ^bifrost.Tree_Slice,
	out_slot_slice: ^bifrost.Virtual_Slice,
	out_datalog_slice: ^bifrost.Virtual_Slice,
	out_diff_slice: ^bifrost.Virtual_Slice,
) {
	pal := THEMES[app.theme]
	w := app.screen.width
	h := app.screen.height

	bifrost.begin_frame(&app.screen, pal.bg)
	bifrost.begin_layout(&app.layout_ctx, w, h)

	if bifrost.ui_scope(&app.layout_ctx, &app.screen, "explorer_root", bifrost.Scope_Config{
		dir    = .Column,
		width  = bifrost.fixed(w),
		height = bifrost.fixed(h),
	}) {
		// 1. Top Status Header Bar
		tx_doc, tx_author, root_off := read_moment_tx_summary(app.db, app.resolved_moment, context.temp_allocator)
		mode_str := "LIVE @-1" if app.pinned_moment < 0 else "PINNED"
		header_text := fmt.tprintf(
			" BIFROST xitdb EXPLORER | %s | @%d/@%d (%s) | Root:0x%05x | By:%s | %s",
			app.db_label,
			app.resolved_moment,
			max(i64(0), app.total_moments - 1),
			mode_str,
			u64(root_off) & 0xFFFFF,
			tx_author,
			tx_doc,
		)
		bifrost.set_paint(&app.screen, "header_bar", bifrost.Paint_Spec{
			text    = header_text,
			fg      = pal.accent_fg,
			bg      = pal.header_bg,
			style   = {.Bold},
			fill_bg = true,
		})
		bifrost.leaf(&app.layout_ctx, "header_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_text,
		})

		// 2. Main Split Workspace: Left Structural Tree (`ui_tree`) | Splitter | Right 3-Tab Workspace (`ui_tabs`)
		auto_tree_w := bifrost.compute_tree_auto_width(
			app.tree_nodes[:app.tree_count],
			.Rounded,
			"",
			95,
			28,
			max(32, min(46, w - 58)),
		)
		split_w := bifrost.get_split_size(&app.input, "explorer_split", auto_tree_w, 24, max(28, w - 56))
		if bifrost.ui_scope(&app.layout_ctx, &app.screen, "main_body", bifrost.Scope_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			// 2a. Left Pane: Live Structural `xitdb` Tree (`ui_tree`)
			bifrost.ui_tree(
				&app.layout_ctx,
				&app.screen,
				&app.input,
				"db_tree",
				app.tree_nodes[:app.tree_count],
				bifrost.Tree_Config{
					title          = fmt.tprintf("Moment @%d Tree (%d vis)", app.resolved_moment, bifrost.get_tree_visible_row_count(&app.input, "db_tree")),
					width          = bifrost.fixed(split_w),
					height         = bifrost.grow(1),
					border         = .Rounded,
					fg             = pal.text_fg,
					bg             = pal.panel_bg,
					border_fg      = pal.border_fg,
					title_fg       = pal.accent_fg,
					guide_fg       = pal.muted_fg,
					toggle_fg      = pal.accent_fg,
					sel_fg         = pal.sel_fg,
					sel_bg         = pal.sel_bg,
					scroll_step    = 1,
					scroll_padding = 3,
					fallback_rows  = max(6, h - 6),
					focus_flags    = {.Loop_Spatial},
				},
				out_tree_slice,
			)

			// 2b. Interactive 1-Cell Vertical Splitter (`=` resets to p95 auto-width)
			bifrost.ui_splitter(&app.layout_ctx, &app.screen, &app.input, "explorer_split", bifrost.Splitter_Config{
				dir          = .Row,
				default_size = auto_tree_w,
				min_first    = 24,
				min_second   = 56,
				step         = 2,
				fg           = pal.border_fg,
				bg           = pal.bg,
				active_fg    = pal.accent_fg,
			})

			// 2c. Right Pane: 3-Tab Workspace (`ui_tabs`)
			tab_specs := [3]bifrost.Tab_Item_Spec{
				{label = "Slots & Lineage", key_hint = "1:"},
				{label = "Datalog & Tx",    key_hint = "2:"},
				{label = "Diff & Metrics",  key_hint = "3:"},
			}

			cur_tab := 0
			if bifrost.ui_tabs(
				&app.layout_ctx,
				&app.screen,
				&app.input,
				"explorer_tabs",
				tab_specs[:],
				bifrost.Tabs_Config{
					width            = bifrost.grow(1),
					height           = bifrost.grow(1),
					body_dir         = .Column,
					body_padding     = bifrost.pad_xy(1, 0),
					body_gap         = 0,
					body_border      = .Rounded,
					fg               = pal.text_fg,
					bg               = pal.panel_bg,
					header_bg        = pal.header_bg,
					active_fg        = pal.sel_fg,
					active_bg        = pal.sel_bg,
					inactive_fg      = pal.muted_fg,
					inactive_bg      = pal.header_bg,
					badge_fg         = pal.accent_fg,
					sep_fg           = pal.border_fg,
					border_fg        = pal.border_fg,
					title_fg         = pal.accent_fg,
					title            = fmt.tprintf("Workspace (,/.: Moment | r: Query | x: Tx | p: Preset | Last: %s)", app.last_action),
					show_index_hints = true,
				},
				&cur_tab,
			) {
				switch cur_tab {
				case 0:
					// =========================================================
					// TAB 0: Zero-Copy Collection / Slot Inspector + Lineage
					// =========================================================
					bifrost.ui_text_input(&app.layout_ctx, &app.screen, &app.input, "slot_filter", bifrost.Text_Input_Config{
						title          = fmt.tprintf("Filter Collection [%s @%d] (/ to filter, ^prefix or substring)", app.selected_coll if len(app.selected_coll) > 0 else "@root", app.resolved_moment),
						placeholder    = "Type substring or ^prefix (e.g. ^api: or runtime)...",
						linked_list_id = "slot_table",
						width          = bifrost.grow(1),
						height         = bifrost.fixed(3),
						border         = .Plain,
						fg             = pal.text_fg,
						bg             = pal.bg,
						placeholder_fg = pal.muted_fg,
						border_fg      = pal.border_fg,
					})

					raw_q := strings.trim_space(bifrost.get_text(&app.input, "slot_filter"))
					filter := make_slot_filter(raw_q)
					vslice_probe, _ := bifrost.xitdb_slice_viewport(
						app.db,
						app.resolved_moment,
						app.selected_coll,
						0,
						64,
						filter,
						context.temp_allocator,
					)
					slot_total := max(1, i32(vslice_probe.total_rows))
					slot_scroll := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("slot_table"))
					active_col := clamp(slot_scroll.selected_col, 0, 3)

					if bifrost.ui_virtual_list(
						&app.layout_ctx,
						&app.screen,
						&app.input,
						"slot_table",
						slot_total,
						bifrost.Virtual_List_Config{
							title          = fmt.tprintf("Zero-Copy Viewport Slice (%d entries | Col: %s)", int(vslice_probe.total_rows), app.slot_col_specs[active_col].header),
							width          = bifrost.grow(1),
							height         = bifrost.grow(1),
							border         = .Rounded,
							fg             = pal.text_fg,
							bg             = pal.panel_bg,
							border_fg      = pal.border_fg,
							title_fg       = pal.accent_fg,
							scroll_step    = 1,
							scroll_padding = 2,
							fallback_rows  = max(4, h - 15),
							total_cols     = 4,
							focus_flags    = {.Default_Focus, .Loop_Spatial},
						},
						out_slot_slice,
					) {
						for vis_r := out_slot_slice.start_row; vis_r < out_slot_slice.end_row; vis_r += 1 {
							row_id := fmt.tprintf("slot_row_%d", vis_r)
							bifrost.leaf(&app.layout_ctx, row_id, 20, 1, bifrost.Box_Config{
								width     = bifrost.grow(1),
								height    = bifrost.fixed(1),
								clickable = true,
								hoverable = true,
							})
						}
					}

					// Bottom panel: Scrollable Temporal Lineage (`xitdb.history_of`)
					hist_path := app.selected_path if len(app.selected_path) > 0 else ".users"
					lineage, _ := xitdb.history_of(app.db, hist_path, context.temp_allocator)
					lineage_slot := bifrost.get_scroll_slot(&app.input, bifrost.hash_id("lineage_box"))
					scroll_badge := ""
					if lineage_slot.offset_x > 0 || lineage_slot.max_offset_x > 0 {
						scroll_badge = fmt.tprintf(" | h/l: x+%d/%d", lineage_slot.offset_x, lineage_slot.max_offset_x)
					}
					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "lineage_box", bifrost.Scope_Config{
						dir         = .Column,
						width       = bifrost.grow(1),
						height      = bifrost.fixed(5),
						border      = .Plain,
						scrollable  = true,
						scroll_step = 4,
						focus_flags = {.Focusable},
						title       = fmt.tprintf("Temporal Lineage — xitdb.history_of(\"%s\") (%d changes%s)", hist_path, len(lineage), scroll_badge),
						fg          = pal.text_fg,
						bg          = pal.bg,
						border_fg   = pal.border_fg,
						title_fg    = pal.warn_fg,
						fill_bg     = true,
					}) {
						if len(lineage) == 0 {
							bifrost.ui_label(
								&app.layout_ctx,
								&app.screen,
								"lineage_empty",
								" No slot mutations recorded for path.",
								pal.muted_fg,
								{},
								bifrost.Box_Config{width = bifrost.fit(), height = bifrost.fixed(1)},
							)
						} else {
							for i := 0; i < len(lineage); i += 1 {
								he := lineage[len(lineage) - 1 - i]
								val_prev := "removed"
								if hcur, has_c := he.cursor.?; has_c {
									val_prev = bifrost.xitdb_format_cursor_preview(hcur, context.temp_allocator)
								}
								line_str := fmt.tprintf(
									" @%d: %s -> %s (%s) | %s",
									he.moment_index,
									format_tag_badge(he.old_slot.tag),
									format_tag_badge(he.new_slot.tag),
									val_prev,
									he.tx_doc,
								)
								line_id := fmt.tprintf("lineage_row_%d", i)
								bifrost.ui_label(
									&app.layout_ctx,
									&app.screen,
									line_id,
									line_str,
									pal.text_fg,
									{},
									bifrost.Box_Config{width = bifrost.fit(), height = bifrost.fixed(1)},
								)
							}
						}
					}

				case 1:
					// =========================================================
					// TAB 1: Datalog Query & Layer 2 Transaction Workbench
					// =========================================================
					preset := WORKBENCH_PRESETS[app.preset_idx]
					bifrost.ui_text_area(&app.layout_ctx, &app.screen, &app.input, "workbench_editor", bifrost.Text_Area_Config{
						title             = fmt.tprintf("Workbench [%s] (Enter/i: Edit | r: Query | x: Tx | p: Preset)", preset.title),
						placeholder       = "Enter Datalog query (find ... where ...) or branch @-1 { ... } script...",
						width             = bifrost.grow(1),
						height            = bifrost.fixed(9),
						border            = .Rounded,
						fg                = pal.text_fg,
						bg                = pal.bg,
						placeholder_fg    = pal.muted_fg,
						border_fg         = pal.border_fg,
						gutter_fg         = pal.muted_fg,
						two_stage         = true,
						show_line_numbers = true,
						tab_width         = 4,
						syntax_mode       = .Cue,
						focus_flags       = {.Default_Focus},
					})

					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "workbench_toolbar", bifrost.Scope_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(1),
						gap    = 1,
					}) {
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_run_datalog", bifrost.Button_Spec{
							label  = "Run Datalog (r)",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.good_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_commit_tx", bifrost.Button_Spec{
							label  = "Commit Tx Script (x)",
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.warn_fg,
							bg     = pal.header_bg,
						})
						bifrost.ui_button(&app.layout_ctx, &app.screen, "btn_cycle_preset", bifrost.Button_Spec{
							label  = fmt.tprintf("Preset #%d/5 (p)", app.preset_idx + 1),
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
							fg     = pal.accent_fg,
							bg     = pal.header_bg,
						})
					}

					cache := &app.datalog_cache
					dl_rows := max(1, i32(cache.row_count))
					if bifrost.ui_virtual_list(
						&app.layout_ctx,
						&app.screen,
						&app.input,
						"datalog_table",
						dl_rows,
						bifrost.Virtual_List_Config{
							title          = fmt.tprintf("Datalog Results — %s", cache.status),
							width          = bifrost.grow(1),
							height         = bifrost.grow(1),
							border         = .Plain,
							fg             = pal.text_fg,
							bg             = pal.panel_bg,
							border_fg      = pal.border_fg,
							title_fg       = pal.bad_fg if cache.has_error else pal.good_fg,
							scroll_step    = 1,
							scroll_padding = 2,
							fallback_rows  = max(4, h - 16),
							total_cols     = i32(max(1, cache.col_count)),
							focus_flags    = {.Loop_Spatial},
						},
						out_datalog_slice,
					) {
						for vis_r := out_datalog_slice.start_row; vis_r < out_datalog_slice.end_row; vis_r += 1 {
							row_id := fmt.tprintf("dl_row_%d", vis_r)
							bifrost.leaf(&app.layout_ctx, row_id, 20, 1, bifrost.Box_Config{
								width     = bifrost.grow(1),
								height    = bifrost.fixed(1),
								clickable = true,
								hoverable = true,
							})
						}
					}

				case 2:
					// =========================================================
					// TAB 2: Structural Diff (`diff_moments`) & Storage Canvas
					// =========================================================
					from_m := max(i64(0), app.resolved_moment - 1)
					to_m := app.resolved_moment
					diffs, d_err := xitdb.diff_moments(app.db, from_m, to_m, false, context.temp_allocator)
					diff_count := i32(len(diffs)) if d_err == nil else 0

					if bifrost.ui_virtual_list(
						&app.layout_ctx,
						&app.screen,
						&app.input,
						"diff_table",
						max(1, diff_count),
						bifrost.Virtual_List_Config{
							title          = fmt.tprintf("Structural Moment Diff — xitdb.diff_moments(@%d -> @%d) (%d leaf changes)", from_m, to_m, diff_count),
							width          = bifrost.grow(1),
							height         = bifrost.grow(1),
							border         = .Rounded,
							fg             = pal.text_fg,
							bg             = pal.panel_bg,
							border_fg      = pal.border_fg,
							title_fg       = pal.accent_fg,
							scroll_step    = 1,
							scroll_padding = 2,
							fallback_rows  = max(4, h - 14),
							total_cols     = 1,
							focus_flags    = {.Default_Focus, .Loop_Spatial},
						},
						out_diff_slice,
					) {
						for vis_r := out_diff_slice.start_row; vis_r < out_diff_slice.end_row; vis_r += 1 {
							row_id := fmt.tprintf("diff_row_%d", vis_r)
							bifrost.leaf(&app.layout_ctx, row_id, 20, 1, bifrost.Box_Config{
								width     = bifrost.grow(1),
								height    = bifrost.fixed(1),
								clickable = true,
								hoverable = true,
							})
						}
					}

					if bifrost.ui_scope(&app.layout_ctx, &app.screen, "telemetry_row", bifrost.Scope_Config{
						dir    = .Row,
						width  = bifrost.grow(1),
						height = bifrost.fixed(7),
						gap    = 1,
					}) {
						bifrost.ui_canvas(&app.layout_ctx, &app.screen, "storage_canvas", bifrost.Canvas_Config{
							title       = "2×4 Braille Root Slot Offset Curve (KB)",
							width       = bifrost.grow(2),
							height      = bifrost.fixed(7),
							border      = .Rounded,
							fg          = pal.good_fg,
							bg          = pal.bg,
							border_fg   = pal.border_fg,
							title_fg    = pal.good_fg,
							fill_bg     = true,
							focus_flags = {.Focusable},
							draw_fn     = draw_storage_braille_canvas,
							userdata    = app,
						})
						bifrost.ui_sparkline(&app.layout_ctx, &app.screen, "changes_sparkline", app.moment_changes[:app.moment_hist_len], bifrost.Sparkline_Config{
							title     = "Mutations / @m (▁..█)",
							width     = bifrost.grow(1),
							height    = bifrost.fixed(7),
							border    = .Rounded,
							fg        = pal.warn_fg,
							bg        = pal.bg,
							border_fg = pal.border_fg,
							title_fg  = pal.warn_fg,
							fill_bg   = true,
							min_val   = 0.0,
							max_val   = 16.0,
						})
					}
				}
			}
		}

		// 3. Live Focus Breadcrumb Bar + Contextual Key-Hint Bar
		bifrost.ui_focus_breadcrumb_bar(&app.layout_ctx, &app.screen, &app.input, "explorer_breadcrumb", bifrost.Breadcrumb_Bar_Config{
			fg        = pal.muted_fg,
			bg        = pal.header_bg,
			active_fg = pal.sel_fg,
			sep_fg    = pal.border_fg,
		})
		bifrost.ui_key_hint_bar(&app.layout_ctx, &app.screen, &app.input, "explorer_hint_bar", bifrost.Key_Hint_Bar_Config{
			key_fg  = pal.accent_fg,
			desc_fg = pal.text_fg,
			sep_fg  = pal.border_fg,
			bg      = pal.bg,
		})
	}

	// 4. Floating Command Palette (`z=30`) + Which-Key Overlay (`z=28`)
	bifrost.ui_command_palette(&app.layout_ctx, &app.screen, &app.input, &app.palette, 60, 6)
	bifrost.ui_which_key_overlay(&app.layout_ctx, &app.screen, &app.input, "explorer_which_key")

	bifrost.end_layout(&app.layout_ctx)
}

paint_explorer_tables :: proc(
	app: ^Explorer_App,
	slot_slice: bifrost.Virtual_Slice,
	datalog_slice: bifrost.Virtual_Slice,
	diff_slice: bifrost.Virtual_Slice,
) {
	if app.palette.is_open {
		return
	}
	pal := THEMES[app.theme]
	active_tab := bifrost.get_active_tab(&app.input, "explorer_tabs")

	switch active_tab {
	case 0:
		if list_inner, ok := bifrost.get_inner_rect(&app.layout_ctx, "slot_table"); ok && list_inner.w > 4 && list_inner.h > 0 {
			list_clip, _ := bifrost.get_node_clip(&app.layout_ctx, "slot_table")
			usable_rect := list_inner
			usable_rect.w = max(1, usable_rect.w - 1)

			raw_q := strings.trim_space(bifrost.get_text(&app.input, "slot_filter"))
			filter := make_slot_filter(raw_q)
			vslice, _ := bifrost.xitdb_slice_viewport(
				app.db,
				app.resolved_moment,
				app.selected_coll,
				i64(slot_slice.start_row),
				i64(max(1, slot_slice.end_row - slot_slice.start_row)),
				filter,
				context.temp_allocator,
			)

			for row in vslice.rows {
				bifrost.table_column_observe_cell(&app.slot_col_specs[0], row.key_text)
			}

			spans: [4]bifrost.Table_Column_Span
			bifrost.resolve_table_columns(app.slot_col_specs[:], spans[:], usable_rect, 2, 2)
			bifrost.register_virtual_table_col_spans(&app.input, "slot_table", spans[:])

			for i := 0; i < len(vslice.rows); i += 1 {
				vis_r := slot_slice.start_row + i32(i)
				row_id := fmt.tprintf("slot_row_%d", vis_r)
				row_rect, r_ok := bifrost.get_rect(&app.layout_ctx, row_id)
				if !r_ok {
					continue
				}
				row_clip := bifrost.rect_intersect(list_clip, row_rect)
				if row_clip.w <= 0 || row_clip.h <= 0 {
					continue
				}

				rv := vslice.rows[i]
				is_sel := vis_r == slot_slice.selected_row
				sel_col := clamp(slot_slice.selected_col, 0, 3)
				row_bg := pal.sel_bg if is_sel else pal.panel_bg
				row_fg := pal.sel_fg if is_sel else pal.text_fg
				row_st := bifrost.Style_Flags{.Bold} if is_sel else bifrost.Style_Flags{}

				if is_sel {
					bifrost.fill_rect(&app.screen, usable_rect, row_clip, ' ', row_fg, row_bg, row_st)
					bifrost.put_text_clipped(&app.screen, usable_rect.x, row_rect.y, "▸", pal.sel_fg, row_bg, {.Bold}, row_clip)
				}

				off_str := fmt.tprintf("0x%05x", u64(rv.slot_offset) & 0xFFFFF)
				cell_texts := [4]string{rv.key_text, format_tag_badge(rv.tag), off_str, rv.val_text}
				cell_fgs   := [4]bifrost.Color{pal.text_fg, pal.accent_fg, pal.muted_fg, pal.good_fg}
				for col_i := 0; col_i < 4; col_i += 1 {
					c_fg := row_fg if is_sel else cell_fgs[col_i]
					c_st := row_st
					if is_sel && i32(col_i) == sel_col {
						c_fg = pal.accent_fg
						c_st = {.Bold, .Reverse}
					}
					bifrost.draw_table_cell(&app.screen, spans[col_i], row_rect.y, row_clip, cell_texts[col_i], c_fg, row_bg, c_st)
				}
			}
		}

	case 1:
		if list_inner, ok := bifrost.get_inner_rect(&app.layout_ctx, "datalog_table"); ok && list_inner.w > 4 && list_inner.h > 0 {
			list_clip, _ := bifrost.get_node_clip(&app.layout_ctx, "datalog_table")
			usable_rect := list_inner
			usable_rect.w = max(1, usable_rect.w - 1)
			cache := &app.datalog_cache

			for vis_r := datalog_slice.start_row; vis_r < datalog_slice.end_row && int(vis_r) < cache.row_count; vis_r += 1 {
				row_id := fmt.tprintf("dl_row_%d", vis_r)
				row_rect, r_ok := bifrost.get_rect(&app.layout_ctx, row_id)
				if !r_ok {
					continue
				}
				row_clip := bifrost.rect_intersect(list_clip, row_rect)
				if row_clip.w <= 0 || row_clip.h <= 0 {
					continue
				}

				is_sel := vis_r == datalog_slice.selected_row
				row_bg := pal.sel_bg if is_sel else pal.panel_bg
				row_fg := pal.sel_fg if is_sel else pal.text_fg
				row_st := bifrost.Style_Flags{.Bold} if is_sel else bifrost.Style_Flags{}

				if is_sel {
					bifrost.fill_rect(&app.screen, usable_rect, row_clip, ' ', row_fg, row_bg, row_st)
				}

				rb := strings.builder_make(0, 96, context.temp_allocator)
				strings.write_string(&rb, "▸ " if is_sel else "  ")
				for c in 0 ..< cache.col_count {
					fmt.sbprintf(&rb, "%s=%-11s ", cache.col_names[c], cache.cells[vis_r][c])
				}
				bifrost.put_text_clipped(&app.screen, usable_rect.x, row_rect.y, strings.to_string(rb), row_fg, row_bg, row_st, row_clip)
			}
		}

	case 2:
		if list_inner, ok := bifrost.get_inner_rect(&app.layout_ctx, "diff_table"); ok && list_inner.w > 4 && list_inner.h > 0 {
			list_clip, _ := bifrost.get_node_clip(&app.layout_ctx, "diff_table")
			usable_rect := list_inner
			usable_rect.w = max(1, usable_rect.w - 1)

			from_m := max(i64(0), app.resolved_moment - 1)
			to_m := app.resolved_moment
			diffs, d_err := xitdb.diff_moments(app.db, from_m, to_m, false, context.temp_allocator)
			diff_count := len(diffs) if d_err == nil else 0

			for vis_r := diff_slice.start_row; vis_r < diff_slice.end_row && int(vis_r) < diff_count; vis_r += 1 {
				row_id := fmt.tprintf("diff_row_%d", vis_r)
				row_rect, r_ok := bifrost.get_rect(&app.layout_ctx, row_id)
				if !r_ok {
					continue
				}
				row_clip := bifrost.rect_intersect(list_clip, row_rect)
				if row_clip.w <= 0 || row_clip.h <= 0 {
					continue
				}

				ch := diffs[vis_r]
				is_sel := vis_r == diff_slice.selected_row
				row_bg := pal.sel_bg if is_sel else pal.panel_bg
				row_fg := pal.sel_fg if is_sel else pal.text_fg
				row_st := bifrost.Style_Flags{.Bold} if is_sel else bifrost.Style_Flags{}

				if is_sel {
					bifrost.fill_rect(&app.screen, usable_rect, row_clip, ' ', row_fg, row_bg, row_st)
				}

				op_badge := "+PUT"
				op_fg := pal.good_fg
				if ch.op == .Remove {
					op_badge = "-REM"
					op_fg = pal.bad_fg
				} else if ch.old_slot.tag != .None {
					op_badge = "~MOD"
					op_fg = pal.warn_fg
				}

				after_val := ""
				if ch.op != .Remove {
					selector := fmt.tprintf("@%d%s", to_m, ch.path_str)
					if cur_m, c_err := xitdb.select_cursor(app.db, selector); c_err == nil {
						if c, has_c := cur_m.?; has_c {
							after_val = bifrost.xitdb_format_cursor_preview(c, context.temp_allocator)
						}
					}
				}

				line_str := fmt.tprintf(
					"%s%-5s %-26s %s -> %s = %s",
					"▸ " if is_sel else "  ",
					op_badge,
					ch.path_str,
					format_tag_badge(ch.old_slot.tag),
					format_tag_badge(ch.new_slot.tag),
					after_val,
				)
				bifrost.put_text_clipped(&app.screen, usable_rect.x, row_rect.y, line_str, row_fg if is_sel else op_fg, row_bg, row_st, row_clip)
			}
		}
	}
}

commit_editor_or_preset_tx :: proc(app: ^Explorer_App) {
	ed_text := strings.trim_space(bifrost.get_text_area(&app.input, "workbench_editor"))
	script := ed_text
	if !strings.has_prefix(script, "branch ") {
		script = WORKBENCH_PRESETS[4].content
		if app.live_commits > 0 {
			script = fmt.tprintf(
				`branch @-1 {{
	doc "Interactive Explorer Commit #%d"
	instant %d
	meta "author" = "explorer"
	put #counters["deploy_seq"]    = %du
	put $metrics["api:req_per_sec"] = %du
	append .events                 = "explorer:commit-%d"
}}`,
				app.live_commits + 1,
				1700005000 + app.live_commits * 60,
				105 + app.live_commits,
				8400 + app.live_commits * 350,
				app.live_commits + 1,
			)
		}
	}
	report, err := xitdb.transact_script(app.db, script, context.temp_allocator)
	if err == nil {
		if app.db.core != nil {
			_ = xitdb.core_flush(app.db.core)
		}
		app.live_commits += 1
		app.pinned_moment = -1
		rebuild_moment_tree_and_stats(app)
		execute_workbench_datalog(app, WORKBENCH_PRESETS[0].content)
		set_last_action(app, fmt.tprintf("tx.commit:@%d", report.moment_index))
	} else {
		set_last_action(app, "tx.error")
	}
}

cycle_workbench_preset :: proc(app: ^Explorer_App) {
	app.preset_idx = (app.preset_idx + 1) % len(WORKBENCH_PRESETS)
	preset := WORKBENCH_PRESETS[app.preset_idx]
	bifrost.set_text_area(&app.input, "workbench_editor", preset.content)
	if !preset.is_tx {
		execute_workbench_datalog(app, preset.content)
	}
	set_last_action(app, fmt.tprintf("preset:%d", app.preset_idx + 1))
}

handle_explorer_interactions :: proc(app: ^Explorer_App) -> bool {
	changed := false

	if bifrost.update_command_palette(&app.palette, &app.input) {
		changed = true
	}

	// Sync tree selection to active collection & path selector
	sel_tree := clamp(int(bifrost.get_tree_selected_node(&app.input, "db_tree")), 0, max(0, app.tree_count - 1))
	if sel_tree >= 0 && sel_tree < app.tree_count {
		entry := app.tree_entries[sel_tree]
		if entry.selector_path != app.selected_path || entry.collection_path != app.selected_coll {
			set_selected_paths(app, entry.selector_path, entry.collection_path)
			changed = true
		}
	}

	if bifrost.was_tab_changed(&app.input, "explorer_tabs") {
		set_last_action(app, fmt.tprintf("tab:%d", bifrost.get_active_tab(&app.input, "explorer_tabs") + 1))
		app.action_count += 1
		changed = true
	}

	act, has_act := bifrost.triggered_action(&app.input, Explorer_Action)

	if (has_act && act == .Moment_Prev) || bifrost.was_action_triggered(&app.input, "moment.prev") {
		if app.total_moments > 0 {
			app.pinned_moment = max(i64(0), app.resolved_moment - 1)
			rebuild_moment_tree_and_stats(app)
			execute_workbench_datalog(app, bifrost.get_text_area(&app.input, "workbench_editor"))
			set_last_action(app, fmt.tprintf("moment:@%d", app.resolved_moment))
			app.action_count += 1
			changed = true
		}
	}
	if (has_act && act == .Moment_Next) || bifrost.was_action_triggered(&app.input, "moment.next") {
		if app.total_moments > 0 {
			if app.resolved_moment + 1 >= app.total_moments {
				app.pinned_moment = -1
			} else {
				app.pinned_moment = app.resolved_moment + 1
			}
			rebuild_moment_tree_and_stats(app)
			execute_workbench_datalog(app, bifrost.get_text_area(&app.input, "workbench_editor"))
			set_last_action(app, fmt.tprintf("moment:@%d", app.resolved_moment))
			app.action_count += 1
			changed = true
		}
	}
	if (has_act && act == .Moment_Follow) || bifrost.was_action_triggered(&app.input, "moment.follow") {
		app.pinned_moment = -1
		rebuild_moment_tree_and_stats(app)
		execute_workbench_datalog(app, bifrost.get_text_area(&app.input, "workbench_editor"))
		set_last_action(app, "moment:follow@-1")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_run_datalog") || (has_act && act == .Run_Datalog) || bifrost.was_action_triggered(&app.input, "workbench.query") {
		ed_text := bifrost.get_text_area(&app.input, "workbench_editor")
		execute_workbench_datalog(app, ed_text)
		set_last_action(app, "workbench.query")
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_commit_tx") || (has_act && act == .Commit_Tx) || bifrost.was_action_triggered(&app.input, "workbench.tx") {
		commit_editor_or_preset_tx(app)
		app.action_count += 1
		changed = true
	}
	if bifrost.was_activated(&app.input, "btn_cycle_preset") || (has_act && act == .Cycle_Preset) || bifrost.was_action_triggered(&app.input, "workbench.preset") {
		cycle_workbench_preset(app)
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Focus_Filter) || bifrost.was_action_triggered(&app.input, "filter.focus") {
		bifrost.set_active_tab(&app.input, "explorer_tabs", 0, true)
		app.input.wants_focus_id = bifrost.hash_id("slot_filter")
		set_last_action(app, "filter.focus")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Focus_Tree) || bifrost.was_action_triggered(&app.input, "nav.tree") {
		app.input.wants_focus_id = bifrost.hash_id("db_tree")
		set_last_action(app, "nav.tree")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Focus_Workbench) || bifrost.was_action_triggered(&app.input, "nav.workbench") {
		bifrost.set_active_tab(&app.input, "explorer_tabs", 1, true)
		app.input.wants_focus_id = bifrost.hash_id("workbench_editor")
		set_last_action(app, "nav.workbench")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Tab_1) || bifrost.was_action_triggered(&app.input, "tab.slots") {
		bifrost.set_active_tab(&app.input, "explorer_tabs", 0, true)
		set_last_action(app, "tab:1")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Tab_2) || bifrost.was_action_triggered(&app.input, "tab.datalog") {
		bifrost.set_active_tab(&app.input, "explorer_tabs", 1, true)
		set_last_action(app, "tab:2")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Tab_3) || bifrost.was_action_triggered(&app.input, "tab.diff") {
		bifrost.set_active_tab(&app.input, "explorer_tabs", 2, true)
		set_last_action(app, "tab:3")
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Theme_Cycle) || bifrost.was_action_triggered(&app.input, "theme.cycle") {
		app.theme = Theme_Preset((int(app.theme) + 1) % len(Theme_Preset))
		set_last_action(app, fmt.tprintf("theme:%s", THEMES[app.theme].name))
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Style_Cycle) || bifrost.was_action_triggered(&app.input, "style.cycle") {
		next_st := bifrost.cycle_keymap_style(&app.input)
		set_last_action(app, fmt.tprintf("style:%s", bifrost.keymap_style_name(next_st)))
		app.action_count += 1
		changed = true
	}
	if (has_act && act == .Quit) || bifrost.was_action_triggered(&app.input, "app.quit") {
		app.quit_requested = true
		set_last_action(app, "app.quit")
		changed = true
	}

	return changed || (app.input.text_changed_id != 0) || (app.input.scrolled_id != 0) || (app.input.tab_changed_id != 0)
}

step_explorer_frame :: proc(app: ^Explorer_App, events: ..bifrost.Input_Event) {
	tree_slice: bifrost.Tree_Slice
	slot_slice: bifrost.Virtual_Slice
	datalog_slice: bifrost.Virtual_Slice
	diff_slice: bifrost.Virtual_Slice

	if len(events) > 0 && len(app.layout_ctx.nodes) > 0 && bifrost.is_pure_hover_event_batch(&app.input, events) {
		frame_start_hovered_id     := app.input.hovered_id
		frame_start_hover_path     := app.input.hover_path
		frame_start_hover_path_len := app.input.hover_path_len
		bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)
		if app.input.hovered_id == frame_start_hovered_id &&
		   app.input.hover_path_len == frame_start_hover_path_len &&
		   app.input.hover_path == frame_start_hover_path {
			strings.builder_reset(&app.ansi_builder)
			return
		}
		free_all(context.temp_allocator)
		bifrost.state_store_begin_frame(&app.state_store)
		build_explorer_ui(app, &tree_slice, &slot_slice, &datalog_slice, &diff_slice)
	} else {
		free_all(context.temp_allocator)
		bifrost.state_store_begin_frame(&app.state_store)

		build_explorer_ui(app, &tree_slice, &slot_slice, &datalog_slice, &diff_slice)
		bifrost.resolve_input(&app.input, &app.layout_ctx, ..events)

		if handle_explorer_interactions(app) || (len(events) > 0 && !bifrost.is_pure_hover_event_batch(&app.input, events)) {
			build_explorer_ui(app, &tree_slice, &slot_slice, &datalog_slice, &diff_slice)
			bifrost.resolve_input(&app.input, &app.layout_ctx)
		}
	}

	bifrost.state_store_sync_from_layout(&app.state_store, &app.layout_ctx, &app.input)
	bifrost.apply_input_highlights(&app.screen, &app.layout_ctx, &app.input)
	bifrost.render_layout(&app.screen, &app.layout_ctx)
	paint_explorer_tables(app, slot_slice, datalog_slice, diff_slice)

	strings.builder_reset(&app.ansi_builder)
	_ = bifrost.screen_diff_ansi(&app.screen, &app.ansi_builder)
	_ = bifrost.flush_osc52_clipboard(&app.input, &app.ansi_builder)
	app.frames_rendered += 1
}

extract_screen_row :: proc(s: ^bifrost.Screen, row: i32, alloc := context.temp_allocator) -> string {
	if row < 0 || row >= s.height {
		return ""
	}
	b := strings.builder_make(0, int(s.width), alloc)
	for x: i32 = 0; x < s.width; x += 1 {
		cell := s.front[int(row * s.width + x)]
		if cell.width == 0 || cell.ch == 0 {
			continue
		}
		strings.write_rune(&b, cell.ch)
	}
	return strings.trim_right_space(strings.to_string(b))
}

export_screenshot_if_requested :: proc(s: ^bifrost.Screen, filename: string, title: string) {
	if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
		_ = os.make_directory(dir)
		b := strings.builder_make(context.temp_allocator)
		bifrost.screen_export_html(s, title, &b)
		_ = os.write_entire_file_from_string(fmt.tprintf("%s/%s", dir, filename), strings.to_string(b))
	}
}

DEFAULT_DB_FILE_PATH :: "examples/xitdb_explorer/demo.xit"

run_explorer :: proc(live_tty: bool, seed_only: bool, custom_db_path: string) -> bool {
	defer free_all(context.temp_allocator)

	core: xitdb.Core
	using_file := false
	resolved_db_path := custom_db_path
	if len(resolved_db_path) == 0 && (live_tty || seed_only) {
		resolved_db_path = DEFAULT_DB_FILE_PATH
	}
	if len(resolved_db_path) > 0 {
		fc, f_err := xitdb.core_buffered_file_open(resolved_db_path, 2 * 1024 * 1024)
		if f_err == nil {
			core = fc
			using_file = true
		}
	}
	if !using_file {
		if len(custom_db_path) == 0 && os.exists(DEFAULT_DB_FILE_PATH) {
			if raw_bytes, r_err := os.read_entire_file(DEFAULT_DB_FILE_PATH, context.temp_allocator); r_err == nil && len(raw_bytes) > 0 {
				core = xitdb.core_memory_init_from_bytes(raw_bytes)
			} else {
				core = xitdb.core_memory_init()
			}
		} else {
			core = xitdb.core_memory_init()
		}
	}
	defer xitdb.core_destroy(&core, close_file = using_file)

	db, db_err := xitdb.database_init(&core, xitdb.sha1_hasher())
	if db_err != nil {
		return false
	}

	rc_check := xitdb.database_root_cursor(&db).read_cursor
	existing_moments: i64 = 0
	if hist_check, h_err := xitdb.read_array_list_init(rc_check); h_err == nil {
		existing_moments, _ = xitdb.array_list_count(hist_check)
	}
	if existing_moments == 0 {
		seed_demo_database(&db)
	}
	if using_file {
		_ = xitdb.core_flush(&core)
	}
	if seed_only {
		rc_after := xitdb.database_root_cursor(&db).read_cursor
		total_m: i64 = 0
		if h_after, h_err := xitdb.read_array_list_init(rc_after); h_err == nil {
			total_m, _ = xitdb.array_list_count(h_after)
		}
		sz, _ := xitdb.database_committed_size(&db)
		fmt.printf("Seeded xitdb file: %s (%d moments, %d bytes)\n", resolved_db_path, total_m, sz)
		return true
	}

	cols: i32 = 108
	rows: i32 = 27
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			fmt.eprintln("Failed to initialize raw terminal")
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(80, ws.width)
			rows = max(20, ws.height)
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	app := new(Explorer_App)
	defer free(app)
	db_label := resolved_db_path if using_file else "examples/xitdb_explorer/demo.xit"
	if !explorer_init(app, &db, db_label, cols, rows, context.allocator) {
		return false
	}
	defer explorer_destroy(app)

	if live_tty {
		step_explorer_frame(app)
		if strings.builder_len(app.ansi_builder) > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
		}

		last_tick := time.tick_now()
		target_frame_interval := 33 * time.Millisecond
		queued_inputs := make([dynamic]bifrost.Input_Event, 0, 64, context.allocator)
		defer delete(queued_inputs)
		for !app.quit_requested {
			elapsed := time.tick_diff(last_tick, time.tick_now())
			wait_ms := max(i32(1), i32((target_frame_interval - elapsed) / time.Millisecond))
			ev, has_ev, _ := bifrost.poll_next_event(&term, wait_ms)
			if has_ev {
				_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev, &app.input)
				for drain := 0; drain < 128; drain += 1 {
					ev2, has_ev2, _ := bifrost.poll_next_event(&term, 0)
					if !has_ev2 {
						break
					}
					_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev2, &app.input)
				}
			}
			now := time.tick_now()
			if len(queued_inputs) > 0 && time.tick_diff(last_tick, now) >= target_frame_interval {
				last_tick = now
				for q_ev in queued_inputs {
					if res_ev, is_res := q_ev.(bifrost.Resize_Event); is_res {
						_ = bifrost.screen_resize(&app.screen, max(80, res_ev.width), max(20, res_ev.height))
					}
				}
				step_explorer_frame(app, ..queued_inputs[:])
				clear(&queued_inputs)
				if strings.builder_len(app.ansi_builder) > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(app.ansi_builder))
				}
			}
		}
	} else {
		// Deterministic headless walkthrough exercising all 3 tabs + live transaction + Datalog + diff:
		// 1. Mount Tab 1 (Slot & Lineage Inspector), step down to `.users["u101"]` in the structural tree
		step_explorer_frame(app)
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = 'j'})
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = 'j'})
		export_screenshot_if_requested(&app.screen, "xitdb_explorer_slots.html", "Bifrost xitdb Explorer — Tab 1: Slot & Lineage Inspector")

		fmt.printf(
			"[Bifrost xitdb Explorer — Tab 1 (Slot & Lineage Inspector)] moments=%d selected_path=%s tree_nodes=%d\n",
			app.total_moments,
			app.selected_path,
			app.tree_count,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		// 2. Switch to Tab 2 (Datalog & Tx Workbench) via `g w` (or `Alt+2`), commit a live Layer 2 transaction (`x`), and run Datalog (`r`)
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = 'g'})
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = 'w'})
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = 'x'})
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = 'r'})
		export_screenshot_if_requested(&app.screen, "xitdb_explorer_datalog.html", "Bifrost xitdb Explorer — Tab 2: Datalog & Tx Workbench")

		fmt.printf(
			"\n[Bifrost xitdb Explorer — Tab 2 (Datalog & Tx Workbench)] moments=%d datalog_rows=%d status=\"%s\"\n",
			app.total_moments,
			app.datalog_cache.row_count,
			app.datalog_cache.status,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}

		// 3. Switch to Tab 3 (Structural Diff & Storage Braille Telemetry) with `]` (or `Alt+3`)
		step_explorer_frame(app, bifrost.Key_Event{code = .Rune, ch = ']'})
		export_screenshot_if_requested(&app.screen, "xitdb_explorer_diff.html", "Bifrost xitdb Explorer — Tab 3: Structural Diff & Storage")

		fmt.printf(
			"\n[Bifrost xitdb Explorer — Tab 3 (Structural Diff & Storage)] moment=@%d last_action=%s\n",
			app.resolved_moment,
			app.last_action,
		)
		for r: i32 = 0; r < app.screen.height; r += 1 {
			fmt.printf("  %s\n", extract_screen_row(&app.screen, r))
		}
	}

	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	live_tty := false
	seed_only := false
	custom_db_path := ""
	for arg in os.args[1:] {
		if arg == "--live-tty" {
			live_tty = true
		} else if arg == "--seed-only" {
			seed_only = true
		} else if !strings.has_prefix(arg, "-") {
			custom_db_path = arg
		}
	}

	ok := run_explorer(live_tty, seed_only, custom_db_path)

	leaks := 0
	for _, entry in track.allocation_map {
		fmt.eprintf("LEAK: %v bytes allocated at %v\n", entry.size, entry.location)
		leaks += 1
	}
	for entry in track.bad_free_array {
		fmt.eprintf("BAD FREE: %p at %v\n", entry.memory, entry.location)
		leaks += 1
	}
	mem.tracking_allocator_destroy(&track)

	if !ok || leaks > 0 {
		os.exit(1)
	}
}
