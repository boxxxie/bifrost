03/11/2026, 20:42 Building an Actor-Driven Odin TUI

## Building an Actor-Driven Odin TUI

[https://gemini.google.com/app/b1523f6085f4b688](https://gemini.google.com/app/b1523f6085f4b688) *User prompt: what is so special about the rust TUI lib how hard would it be to make one in odin? i made an actor lib in odin, would that help make* *TUI code easier to understand would odins DSL making capabilities help with something like this, and how?* Response: Rust's flagship TUI library, **Ratatui** (the community successor to tui-rs), stands out because it replaces traditional stateful terminal manipulation with **immediate-mode rendering** backed by **double-buffered cell diffing** and a **constraint-based layout solver**. Building a similar library in Odin is very approachable, and pairing an actor model for background concurrency with Odin's scoped attributes and context.temp_allocator makes for a remarkably clean architecture. **What Makes Rust's Ratatui Special** Traditional terminal libraries like ncurses use a **retained-mode** model where you create persistent widget objects, mutate them, and manually manage cursor movement and screen refreshes. Ratatui flips this into an immediate-mode pipeline similar to Dear ImGui or a game loop: **Double-buffered cell diffing:** Widgets never print ANSI escape codes directly; they draw into a flat 2D Buffer of Cell structs, and Ratatui diffs the current buffer against the previous frame to emit minimal ANSI updates. **Constraint layout engine:** Instead of computing (x, y, w, h) math by hand, you declaratively split Rect regions using constraints (Length, Percentage, Min, Fill) backed by a Cassowary solver. **Borrow-checker harmony:** Retained UI trees with parent-child references are notoriously painful in Rust; immediate mode sidesteps ownership fights because widgets are ephemeral views created and dropped every frame. **Swappable I/O backends:** Ratatui only computes layouts and cell grids, delegating raw terminal mode and event polling to backends like crossterm or termion. **How Hard Would It Be to Make One in Odin?** You can build a working Ratatui-style core in Odin over a weekend, though full cross-platform polish takes longer. Existing projects like TermCL and Odin's bundled vendor:microui already prove out parts of this design. **Buffer diffing and ANSI emission (Easy — 1 to 2 days):** Allocate two flat []Cell slices (width * height) on an arena, compare cells in a tight loop, and batch escape codes into a strings.Builder on context.temp_allocator before a single os.write. **Proportional layout splitting (Easy — 1 to 2 days):** You do not need a full Cassowary simplex solver; a two-pass 1D splitter (fixed sizes first, proportional Fill weights second, similar to Clay or microui) takes under 200 lines of Odin. **Raw terminal mode and input parsing (Medium — 3 to 5 days):** Entering raw mode via core:sys/posix (termios) and core:sys/windows (SetConsoleMode) is brief, but parsing ANSI input sequences and distinguishing a bare ESC key from \x1b[A arrow keys requires careful timeout handling. **Unicode grapheme width (Hard — Ongoing):** Terminal columns do not map 1-to-1 with bytes or UTF-8 runes; handling emoji ZWJ sequences and 2-column CJK characters requires core:unicode/utf8 (utf8.grapheme_count) and column-width tables. **Would Your Odin Actor Library Help?** Your actor library is a great fit for **application state, async I/O, and the event loop** (similar to the Elm Architecture or Go's Bubble Tea), provided you keep actors at the **subsystem boundary** rather than making individual UI widgets actors. **Input and timer actors:** Dedicated actors can block on stdin, listen for OS resize signals (SIGWINCH), or emit animation ticks, forwarding clean tagged-union messages to the UI actor without polling delays. **Non-blocking background work:** File indexers, network requests, or shell subprocesses can run in worker actors and message results back to the UI actor, keeping rendering instant and lock-free. **Single-writer UI state:** When a single UI coordinator actor owns the application state and runs the immediate-mode draw pass only after processing a batch of mailbox messages, you eliminate mutexes, data races, and idle CPU spinning. **Avoid widget-level actors:** Turning every button, tab, or list into an independent actor recreates retained-mode state synchronization bugs; let the UI actor own the model and render widgets as pure procedural functions. **Can Odin's Language Features Create a UI DSL?** Odin intentionally omits Rust-style AST macros and custom syntax extensions to keep compilation fast and code explicit. However, four native Odin features combine into an ergonomic **declarative pseudo-DSL** that often reads cleaner than macro-heavy Rust: **@(deferred_in) and @(deferred_none) scoped blocks:** Attaching @(deferred_none = end_panel) to a procedure that returns true lets you nest child widgets inside standard if blocks that automatically pop the layout stack on exit. **bit_set and implicit enum selectors:** Instead of chaining .bold().underlined() builder methods, Odin's bit_set and implicit .Enum_Value inference let you write compact styling like flags = {.Bold,.Underline} and dir =.Vertical.

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=… 1/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

**Zero-initialized designated struct literals:** Because every Odin struct defaults to zero ({}), passing optional widget configuration looks like a declarative config block (Panel_Config{title = "Worker Pool", border =.Rounded}).

**Frame-scoped context.temp_allocator:** In Rust TUIs, dynamic strings inside a draw closure often trigger lifetime issues; in Odin, fmt.tprintf allocates onto the scratch arena and free_all(context.temp_allocator) clears the entire frame in *O*(1) time. **Example: Actor-Driven Immediate-Mode TUI in Odin**

package tui_demo

import "core:fmt"

Style_Flag :: enum u8 { Bold, Dim, Underline, Reverse} Style_Flags :: bit_set[Style_Flag; u8]

Direction :: enum u8 { Horizontal, Vertical} Border_Kind :: enum u8 { None, Plain, Rounded, Double}

Constraint :: union { Fixed, Percent, Fill, } Fixed :: distinct u16 Percent :: distinct u8 Fill :: distinct u8

Panel_Opt :: struct { title: string, dir: Direction, border: Border_Kind, style: Style_Flags, padding: u8, }

// Actor messages flowing into the UI coordinator actor App_Msg :: union { Key_Press, Resize_Event, Worker_Stat, } Key_Press :: struct { rune: rune} Resize_Event :: struct { w, h: u16} Worker_Stat :: struct { actor_id: int, jobs_done: int, cpu_pct: f32}

// @(deferred_none) automatically calls end_panel() when the enclosing scope exits @(deferred_none = end_panel) panel :: proc(opt: Panel_Opt = {}, constraints:..Constraint)-> bool { begin_panel(opt,..constraints) return true }

begin_panel :: proc(opt: Panel_Opt, constraints:..Constraint) { // Push computed child Rects onto the internal layout stack }

end_panel :: proc() { // Pop current container Rect from the internal layout stack }

label :: proc(text: string, style: Style_Flags = {}) { // Write graphemes and style flags into the current frame's []Cell buffer }

render_frame :: proc(stats: []Worker_Stat) {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 2/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

defer free_all(context.temp_allocator)

if panel({title = "Cluster Monitor", dir =.Vertical, border =.Rounded, style = {.Bold}}, Fill(1)) { if panel({title = "Summary", dir =.Horizontal, border =.Plain}, Fixed(3)) { label(fmt.tprintf("Active Actors: %d", len(stats)), {.Bold}) label("Press'q' to quit", {.Dim}) }

if panel({title = "Workers", dir =.Vertical, border =.Plain, padding = 1}, Fill(1)) { for stat in stats { line := fmt.tprintf("Actor #%d — %d jobs (%.1f%% CPU)", stat.actor_id, stat.jobs_don label(line, {.Reverse} if stat.cpu_pct >= 90.0 else {}) } } } } **Sources**

1. lemurclaw-ratatui-Lib.rs
2. Layout | Ratatui
3. ratatui-Rust-Docs.rs
4. clay/bindings/odin/examples/clay-official-website ... - GitHub
*User prompt: would something like persistent data structures help with something like this?* Response: Persistent data structures are a **major win for passing application state between actors**, but they are the **wrong tool for the internal** **rendering and layout engine**. Because Odin has no garbage collector, the trick is avoiding pointer-heavy trees (like Clojure vectors or Rust's Arc- backed HAMTs) in favor of **flat, append-only or chunked structures** backed by arenas. **Where Persistent Structures Shine in an Actor TUI** In an actor-driven TUI, a background worker actor often owns large datasets (logs, file trees, tables, or text buffers) while the UI actor needs a consistent view of that data to draw a frame.

**Zero-copy actor snapshots:** Sending a 100,000-line log or file tree from a worker actor to the UI actor via a persistent root takes *O*(1) time without mutexes or deep cloning.

**Text editing and scrollback:** Ropes and piece tables are persistent structures that handle large text buffers, *O*(log*N*) edits, and infinite undo/redo stacks effortlessly. **Time-travel debugging:** Storing previous state roots in a ring buffer lets you step backward through actor messages and replay UI frames deterministically. **Where They Hurt in Odin**

If you try to port functional persistent structures directly from Haskell, Clojure, or Rust's im crate into Odin, you immediately hit two systems-level bottlenecks: **No garbage collector for shared nodes:** Traditional persistent trees require atomic reference counting on every internal branch node to know when dropped versions can be freed. **Cache-hostile pointer chasing:** Traversing heap-allocated tree nodes during a 60 FPS layout or cell-diffing pass is much slower than scanning a contiguous []Cell slice. **How to Build Odin-Friendly Persistent State for Actors** Instead of pointer-chasing trees with per-node reference counts, you can combine structural sharing with Odin's data-oriented memory model in three ways:

**Append-only buffers and piece tables:** Store raw data in an append-only vmem.Arena or pre-reserved buffer; a "new version" sent to the UI actor is just a lightweight slice header or span table pointing into that immutable memory.

**Index-based node pools:** Store tree nodes in a flat [dynamic]Node array and reference children via u32 indices instead of pointers, compacting or resetting the pool at clean checkpoints.

**Coarse-grained page refcounting:** Group list or table items into fixed 64-item pages (Page :: struct { ref_count: int, items: [64]Item}) so you only copy and refcount whole pages when the active tail page mutates. **Example: Lock-Free Persistent Log Snapshot Between Actors**

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 3/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

Here is how a worker actor can continuously append to a virtual-memory arena while sending *O*(1) immutable snapshots to your TUI actor with zero locks, zero deep copies, and zero per-item reference counting:

package tui_state

import vmem "core:mem/virtual"

// Immutable view sent inside an actor message to the TUI renderer. // Because bytes and line_offsets only grow inside a reserved virtual arena, // previously committed slices remain valid and immutable forever. Log_Snapshot :: struct { raw_bytes: []byte, line_offsets: []u32, // Start offset of each line in raw_bytes }

// Owned exclusively by the background Log/Worker Actor Log_Store :: struct { text_arena: vmem.Arena, offset_arena: vmem.Arena, bytes: [dynamic]byte, offsets: [dynamic]u32, }

log_store_init :: proc(store: ^Log_Store)-> vmem.Allocator_Error { // Virtual arenas reserve address space without committing physical RAM upfront, // so growing slices in-place never invalidates older slices held by the UI actor. vmem.arena_init_growing(&store.text_arena) or_return vmem.arena_init_growing(&store.offset_arena) or_return

store.bytes = make([dynamic]byte, 0, 1024 * 1024, vmem.arena_allocator(&store.text_arena)) store.offsets = make([dynamic]u32, 0, 65536, vmem.arena_allocator(&store.offset_arena)) return nil }

// Worker actor appends a new line and returns an O(1) persistent snapshot for the UI actor log_store_append :: proc(store: ^Log_Store, line: string)-> Log_Snapshot { start := u32(len(store.bytes)) append(&store.offsets, start) append(&store.bytes, line)

return Log_Snapshot{ raw_bytes = store.bytes[:], line_offsets = store.offsets[:], } }

// UI actor reads any visible line in O(1) time during render_frame() snapshot_get_line :: proc(snap: Log_Snapshot, line_idx: int)-> string { if line_idx < 0 || line_idx >= len(snap.line_offsets) { return "" } start := snap.line_offsets[line_idx] end := u32(len(snap.raw_bytes)) if line_idx + 1 < len(snap.line_offsets) { end = snap.line_offsets[line_idx + 1] } return string(snap.raw_bytes[start:end]) }

*User prompt: ok. i actually made a port of xitdb to odin, which is an immutable DB with direct object access API and a set of rich objects to use would* *just having a DB like that be worth using instead of internal datastructures*

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 4/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

Response: Using your Odin xitdb port as the backing store for **application state and inter-actor messaging** is well worth it and eliminates the need to build custom persistent data structures, provided you keep **ephemeral frame-rendering buffers** in native Odin slices. **Why xitdb Pairs So Well with an Actor TUI** Because xitdb stores its nested collections (HashMap, ArrayList, LinkedArrayList, SortedMap) over an append-only memory buffer or buffered file, it sidesteps the hardest parts of building immutable state in a non-GC language: **Zero-GC structural sharing:** Nodes live as offsets inside a linear buffer or file rather than separately heap-allocated pointers, giving you copy- on-write snapshots without atomic reference counting. **Lock-free actor handoffs:** Reads never block writes in xitdb. A worker actor can commit a new transaction while the UI actor reads a previous snapshot concurrently with zero locks or deep copies. **Tiny actor messages:** Instead of copying structs into actor mailboxes, actors just pass a lightweight Slot or history index (i64), and the receiver opens a ReadCursor directly over the shared database. **Built-in time travel and persistence:** Because the root is an ArrayList of transaction moments, undo/redo is just indexing history.getCursor(-2), and switching from .memory to .buffered_file gives you instant disk persistence and larger-than-RAM datasets. **Virtualized viewport reads:** B-tree-backed structures like LinkedArrayList and SortedMap let your TUI seek directly to the 40 visible rows on screen without iterating or loading a 500,000-row dataset into memory. **Where Native Odin Structures Should Stay** You will get the best ergonomics and frame times by drawing a clean line between **committed state (xitdb)** and **per-frame scratch data (native** **Odin slices)**: **The 60 FPS layout and Cell grid:** Traversing cursors and hashing keys per pixel cell is unnecessary overhead; keep your double-buffered []Cell screen arrays and layout Rect stack as contiguous Odin slices on context.temp_allocator. **High-frequency ephemeral UI state:** Cursor blink timers, smooth-scroll animations, or live keystroke buffers before submission shouldn't append a new database transaction 60 times a second—keep those in a plain Odin struct inside the UI actor. **Typed struct ergonomics:** Since xitdb stores scalars and byte slices with 2-byte format tags, wrapping your domain reads in small Odin helper procedures (or mapping fixed-layout structs over bytes payloads) keeps UI rendering code clean. **Append-only growth management:** Because xitdb never mutates in place, high-frequency telemetry in .memory mode will steadily grow; periodically cloning the latest moment's root slot into a fresh buffer compacts old history cleanly. **Recommended Hybrid Architecture in Odin** package tui_xitdb import "core:fmt" message

|// Actor|carries|only|the committed|xitdb|history index|/ Slot|
|---|---|---|---|---|---|---|
|State_Committed|:: struct|{|||||
|moment_idx: }|i64,||||||
|// Ephemeral UI_View_State|state stays :: struct|in a {|plain Odin|struct owned|by the|UI Actor|
|latest_moment:||i64,|||||
|scroll_offset:||int,|||||
|viewport_rows:||int,|||||
|filter_input: }||[dynamic]byte,|||||
|render_log_panel defer|:: proc(db: free_all(context.temp_allocator)|^Database,||view: UI_View_State)||{|
|// history|a lock-free := read_array_list(db,|ReadCursor|at root_cursor(db))|the latest|committed|transaction|
|moment|:= read_hash_map(db,||get_cursor(history,||view.latest_moment))||
|logs total_logs|:= read_linked_array_list(db, :=|count(logs)||get_cursor(moment,||"logs"))|
|end_row|:=|min(view.scroll_offset||+ view.viewport_rows,||int(total_logs))|

Open moment

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 5/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

// Only materialize the 30-50 rows actually visible in the terminal viewport for row := view.scroll_offset; row < end_row; row += 1 { item_cursor := get_cursor(logs, i64(row)) line_bytes := read_bytes(item_cursor, context.temp_allocator) label(string(line_bytes)) } status := fmt.tprintf("Showing %d..%d of %d (Moment #%d)", view.scroll_offset, end_row, total_logs, view label(status, {.Dim}) } **Sources**

1. GitHub-xit-vcs/xitdb: an immutable database for zig
2. xitdb-an immutable, embeddable database for Java 17 - Reddit
*User prompt: ok, i'm pretty interested in this direction. i'm worried that i'm focusing too much on the rust lib. should i consider other similar TUI libs for* *inspiration and adopting the best qualities of them* Response: Looking beyond Ratatui is a smart move because several of Ratatui's design quirks—like forcing you to manually slice Rect coordinates top-down before knowing how big child text actually is, or requiring awkward StatefulWidget traits—exist primarily to appease Rust's borrow checker rather than because they are the cleanest way to build a TUI. In a manual-memory, data-oriented language like Odin paired with your **actor library** and **xitdb**, you can borrow stronger ideas from five other libraries across Zig, C, Go, and C++.

**Library Language Best Idea to Adopt What It Fixes in Ratatui** **libvaxis** Zig Arena surfaces and CSI capability queries Eliminates terminfo bloat and manual top-down sizing **Clay** C Arena-allocated Fit + Grow flexbox pass Lets containers shrink-wrap around child text automatically **Bubble Tea** Go Elm-style (State, Cmd) message loop Gives actors a structured pattern for async side effects **Notcurses** C Z-ordered planes and cell alpha blending Makes floating modals, toasts, and dimmed backdrops trivial **FTXUI** C++ Strict Screen / Layout / Component split Separates focus/input routing from stateless layout drawing

**1. From libvaxis (Zig): Runtime Terminal Queries and Frame-Arena Surfaces** Written in Zig, libvaxis is the closest philosophical cousin to an Odin TUI. Two of its design choices translate directly to Odin: **Query the terminal instead of parsing terminfo:** libvaxis ignores legacy terminfo files and instead sends ANSI capability queries at startup to autodetect the Kitty keyboard protocol, synchronized output (CSI? 2026 h), truecolor, and Kitty/Sixel graphics. It even builds as a standalone static C library (libvaxis.a) exposing just its terminal input parser if you ever want to link it via Odin foreign import before writing your own parser. **Bottom-up Surface sizing on the frame arena:** In libvaxis's widget layer (vxfw), each widget's draw procedure takes a frame arena (context.temp_allocator in Odin) and returns a lightweight Surface containing its measured dimensions and child sub-surfaces. Furthermore, its low-level Window abstraction clips out-of-bounds cell writes automatically so child widgets can never corrupt neighboring panels.
**2. From Clay (C): Two-Pass Fit and Grow Layout Engine** Ratatui forces top-down layout: you split a Rect first, then pass the slices down to widgets. If a badge or button needs to shrink-wrap around a dynamic string from xitdb, you have to measure the string manually before splitting the parent layout. **Clay's arena-based flexbox pass:** Nic Barker's C layout library (Clay) solves Fit (shrink to content), Grow (fill remaining space), Percent, and Fixed sizing in a microsecond-scale multi-pass tree walk over a static arena, outputting a flat array of render commands. **Why it fits Odin:** Because Odin already gives you context.temp_allocator and @(deferred_none) scoped blocks, building a Clay- style layout tree during your immediate-mode pass costs zero heap allocations and resolves both bottom-up content wrapping and top-down flex splitting automatically.
**3. From Bubble Tea & Lip Gloss (Go): Actor Commands and Box-Model Styling** While Ratatui is strictly a rendering library that leaves event loops up to you, Go's Bubble Tea formalizes how state and concurrency interact:
[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 6/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

**Explicit Cmd return values for actors:** In Bubble Tea's Elm architecture, handling an input event updates the model and returns a Cmd (an asynchronous task that eventually emits a new message back into the loop). Paired with your Odin actor library and xitdb, your UI actor can process an input message, read or commit an xitdb snapshot, and emit a typed actor message to a worker actor. **Unified box-model structs (Lip Gloss):** Instead of wrapping widgets inside separate Block or Padding widgets like Ratatui, Lip Gloss treats margins, padding, borders, and alignment as unified properties on a single style struct.

**4. From Notcurses (C): Z-Ordered Planes and Translucent Overlays** In Ratatui, drawing a modal dialog, dropdown menu, or toast notification requires manually calling a Clear widget over a region of the single flat buffer. **Composited Plane layers:** Notcurses models the screen as a z-ordered stack of independent ncplane buffers with per-cell foreground/background alpha states (Opaque, Transparent, or Blend). **Dimmed modal backdrops for free:** If your Odin renderer lets a modal or dropdown push a new Plane onto the frame arena with a translucent background flag, your final diff pass can automatically dim the underlying plane's RGB colors by 50% without mutating the background widgets' cells.
**5. From FTXUI (C++) & Zest (Zig): Focus Domains and Input Routing** Immediate-mode UIs make drawing easy, but routing keyboard focus (Tab / Shift+Tab) and mouse hit-testing can get messy if mixed into drawing code. **Three-layer separation:** FTXUI cleanly separates the raw cell buffer (Screen), the stateless layout tree (DOM), and stateful interactive handlers (Component). **Scoped focus domains:** Zig's Zest framework (built on libvaxis) scopes Tab cycling to explicit focus domain nodes so focus never leaks out of an active modal or sidebar into background panes. **Synthesizing the Best Ideas in Odin** Combining Clay's Fit/Grow sizing, Notcurses's z-planes, Lip Gloss's box model, and your xitdb + actor state looks remarkably clean in Odin: package tui_blueprint
flex (Grow)

|// 1. Clay-inspired|sizing:|supports|bottom-up||shrink-wrapping|(Fit)|AND top-down|
|---|---|---|---|---|---|---|---|
|Axis_Size|union {|||||||
|Fit,|// Shrink-wrap|to|children|+ padding|(min,|max bounds)||
|Grow,|// Share|remaining|space|by weight||||
|Fixed,|// Exact|terminal|cells|||||
|Percent, }|// 0..100|of parent|inner|rect||||
|Fit ::|{min,|max: u16|}|||||
|Grow ::|u8|||||||
|Fixed ::|u16|||||||
|Percent ::|u8|||||||
|// 2. Lip Box_Style|struct {|unified|Box + Style|struct|(zero|value is|valid)|
|dir: width: height:|enum Axis_Size, Axis_Size,|u8 {Row,|Column|},||||
|padding:|[4]u8,|// top,|right,|bottom,|left|||
|gap:|u8,|// spacing|between|children||||
|border:|enum|u8 {None,|Plain,|Rounded,|Double|},||
|bg_alpha:|enum|u8 {Transparent,||Opaque,|Dim_Backdrop|},|// Notcurses-style|
|z_layer:|u8,|// 0 =|base UI,|10 = dropdown,||20 = modal|overlay|
|focus_zone: }|bool,|// Scopes|Tab/Shift-Tab||navigation|inside|this subtree|
|// 3. Bubble UI_Actor_State db:|Tea + xitdb :: struct ^Database,|Actor Loop: {|Events|produce|Actor|Commands|and xitdb|
|moment_slot:|i64,|||||||
|focused_id:|u64,|||||||
|show_modal: }|bool,|||||||

::

struct distinct distinct distinct Gloss-inspired ::

compositing

snapshots

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 7/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

@(deferred_none = end_box) box :: proc(id: string, style: Box_Style = {})-> bool { begin_box(id, style) return true }

begin_box :: proc(id: string, style: Box_Style) { // Records layout node in context.temp_allocator arena for the 2-pass solver }

end_box :: proc() { // Closes current layout node scope }

render_dashboard :: proc(ui: ^UI_Actor_State) { defer free_all(context.temp_allocator)

// Base layer (z_layer = 0) if box("root", {dir =.Column, width = Grow(1), height = Grow(1), padding = {1, 2, 1, 2}, gap = 1}) { // Top bar shrink-wraps its height around its text automatically via Fit{} if box("header", {dir =.Row, width = Grow(1), height = Fit{}, border =.Rounded}) { text("xitdb Inspector") }

// Main content area fills remaining space if box("body", {dir =.Row, width = Grow(1), height = Grow(1), gap = 2}) { if box("sidebar", {width = Fixed(28), height = Grow(1), border =.Plain, focus_zone = true} // Read immutable collection directly from xitdb moment_slot text("Collections") } if box("main_view", {width = Grow(1), height = Grow(1), border =.Plain, focus_zone = true} text("Records Viewport") } } }

// Notcurses-inspired overlay layer (z_layer = 20) dims background cells automatically if ui.show_modal { if box("confirm_modal", { width = Fit{min = 40, max = 60}, height = Fit{}, border =.Double, padding = {1, 2, 1, 2}, bg_alpha =.Dim_Backdrop, z_layer = 20, focus_zone = true, }) { text("Compact xitdb history buffer now?") } }

// At frame end: // 1. Solve Fit/Grow layout tree in microsecond pass (Clay-style) // 2. Rasterize z-ordered planes with Dim_Backdrop blending (Notcurses-style) // 3. Diff against previous Cell buffer and emit synchronized ANSI frame (libvaxis/Ratatui-style) } **Sources**

1. rockorager/libvaxis: a modern tui library written in zig-GitHub
2. FTXUI/doc/getting-started.md at main · ArthurSonzogni/FTXUI-GitHub
[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 8/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

*User prompt: Write the Odin code for the two-pass Clay-style layout solver supporting Fit, Grow, Fixed, padding, and gap on context.temp_allocator.*

Response: Because parent containers are always opened before their children in an immediate-mode UI pass, appending nodes into a flat [dynamic]Layout_Node slice on context.temp_allocator guarantees **topological ordering** (parent_idx < child_idx for every node in the tree).

That invariant lets the entire Clay-style layout solver run in two linear array passes without recursion or heap pointer chasing:

1. **Bottom-Up Fit Pass (Reverse Scan: len(nodes)-1 down to 0):** Every child's intrinsic size is already resolved before its parent is visited, so parents accumulate child sizes, gaps, borders, and padding in a single backward loop.
2. **Top-Down Grow & Position Pass (Forward Scan: 0 up to len(nodes)-1):** Parents distribute remaining main-axis space across Grow children (respecting min/max bounds and distributing integer remainders so zero terminal cells are lost to rounding), stretch cross-axis Grow children, and assign screen-space Rect coordinates.
## Complete Odin Implementation (layout.odin)

Save this in a package directory and verify it directly with odin test.-vet-strict-style:

package tui_layout

import "core:fmt" import "core:hash" import "core:testing"

Direction :: enum u8 { Row, // Main axis = X (0), Cross axis = Y (1) Column, // Main axis = Y (1), Cross axis = X (0) }

Alignment :: enum u8 { Start, Center, End, }

Border_Kind :: enum u8 { None, Plain, Rounded, Double, }

// Sizing modes. A zero-initialized Axis_Size (nil) defaults to unconstrained Fit. Fit :: struct { min: i32, max: i32, // 0 = unconstrained }

Grow :: struct { weight: i32, // <= 0 defaults to 1 min: i32, max: i32, // 0 = unconstrained }

Fixed :: distinct i32

Axis_Size :: union { Fit, Grow, Fixed, }

Padding :: struct { left: i32, right: i32,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=…) 9/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

top: i32, bottom: i32, }

Rect :: struct { x: i32, y: i32, w: i32, h: i32, }

Box_Config :: struct { dir: Direction, width: Axis_Size, height: Axis_Size, padding: Padding, gap: i32, border: Border_Kind, main_align: Alignment, cross_align: Alignment, }

Layout_Node :: struct { id: string, id_hash: u64, config: Box_Config, parent_idx: i32, first_child: i32, last_child: i32, next_sibling: i32, child_count: i32, content_size: [2]i32, // Intrinsic leaf size (e.g., measured text width/height) computed_size: [2]i32, // Solved [w, h] in terminal cells rect: Rect, // Outer bounding box (includes border and padding) inner_rect: Rect, // Content area inside border and padding frozen: bool, // Internal scratch flag for Pass 2 Grow min/max clamping }

Layout_Context :: struct { nodes: [dynamic]Layout_Node, parent_stack:[dynamic]i32, id_map: map[u64]i32, screen_size: [2]i32, }

// Ergonomic sizing and padding helpers fit :: #force_inline proc(min: i32 = 0, max: i32 = 0)-> Axis_Size { return Fit{min = min, max = max} }

grow :: #force_inline proc(weight: i32 = 1, min: i32 = 0, max: i32 = 0)-> Axis_Size { return Grow{weight = max(weight, 1), min = min, max = max} }

fixed :: #force_inline proc(cells: i32)-> Axis_Size { return Fixed(cells) }

pad_all :: #force_inline proc(p: i32)-> Padding { return Padding{left = p, right = p, top = p, bottom = p} }

pad_xy :: #force_inline proc(x, y: i32)-> Padding { return Padding{left = x, right = x, top = y, bottom = y}

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 10/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

}

hash_id :: #force_inline proc(id: string)-> u64 { return hash.fnv64a(transmute([]byte)id) }

// Initializes the layout pass for the current frame on context.temp_allocator begin_layout :: proc(ctx: ^Layout_Context, screen_w, screen_h: i32, allocator := context.temp_allocator) { ctx.nodes = make([dynamic]Layout_Node, 0, 128, allocator) ctx.parent_stack = make([dynamic]i32, 0, 32, allocator) ctx.id_map = make(map[u64]i32, 128, allocator) ctx.screen_size = {screen_w, screen_h} }

// Scoped container widget: use with `if container(&ctx, "id", {...}) {...}`
@(deferred_in = defer_end_container) container :: proc(ctx: ^Layout_Context, id: string, cfg: Box_Config = {})-> bool { idx := push_node(ctx, id, cfg, {0, 0}) append(&ctx.parent_stack, idx) return true }

defer_end_container :: proc(ctx: ^Layout_Context, id: string, cfg: Box_Config = {}) { if len(ctx.parent_stack) > 0 { pop(&ctx.parent_stack) } }

// Leaf widget with intrinsic content dimensions (e.g., text, badge, spinner) leaf :: proc(ctx: ^Layout_Context, id: string, content_w, content_h: i32, cfg: Box_Config = {})-> i32 { return push_node(ctx, id, cfg, {content_w, content_h}) }

push_node :: proc(ctx: ^Layout_Context, id: string, cfg: Box_Config, content_size: [2]i32)-> i32 { idx := i32(len(ctx.nodes)) parent_idx := i32(-1) if len(ctx.parent_stack) > 0 { parent_idx = ctx.parent_stack[len(ctx.parent_stack)-1] }

id_hash := hash_id(id) node := Layout_Node{ id = id, id_hash = id_hash, config = cfg, parent_idx = parent_idx, first_child =-1, last_child =-1, next_sibling =-1, content_size = content_size, }

if parent_idx >= 0 { parent := &ctx.nodes[parent_idx] if parent.first_child ==-1 { parent.first_child = idx } else { ctx.nodes[parent.last_child].next_sibling = idx } parent.last_child = idx parent.child_count += 1 }

append(&ctx.nodes, node)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 11/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

if len(id) > 0 {
ctx.id_map[id_hash] = idx
}
return idx
}
// Look up a solved Rect by widget ID after end_layout()
get_rect :: proc(ctx: ^Layout_Context, id: string) -> (rect: Rect, ok: bool) {
idx, found := ctx.id_map[hash_id(id)]
if !found {
return {}, false
}
return ctx.nodes[idx].rect, true
}
get_inner_rect :: proc(ctx: ^Layout_Context, id: string) -> (rect: Rect, ok: bool) {
idx, found := ctx.id_map[hash_id(id)]
if !found {
return {}, false
}
return ctx.nodes[idx].inner_rect, true
}
// Runs the two-pass Clay-style solver over the flat node array
end_layout :: proc(ctx: ^Layout_Context) {
if len(ctx.nodes) == 0 {
return
}
// =========================================================================
// PASS 1: Bottom-Up Intrinsic & Fit Sizing (Reverse Topological Order)
// =========================================================================
for i := len(ctx.nodes) - 1; i >= 0; i -= 1 {
node := &ctx.nodes[i]
insets := compute_total_insets(node.config)
main_axis := 0 if node.config.dir == .Row else 1
cross_axis := 1 - main_axis
intrinsic: [2]i32
if node.child_count > 0 {
children_main: i32 = 0
children_cross: i32 = 0
for c := node.first_child; c != -1; c = ctx.nodes[c].next_sibling {
child := &ctx.nodes[c]
children_main += child.computed_size[main_axis]
children_cross = max(children_cross, child.computed_size[cross_axis])
}
if node.child_count > 1 {
children_main += (node.child_count - 1) * node.config.gap
}
intrinsic[main_axis] = children_main + insets[main_axis]
intrinsic[cross_axis] = children_cross + insets[cross_axis]
} else {
intrinsic[0] = node.content_size[0] + insets[0]
intrinsic[1] = node.content_size[1] + insets[1]
}
node.computed_size[0] = resolve_pass1_axis(node.config.width, intrinsic[0])
node.computed_size[1] = resolve_pass1_axis(node.config.height, intrinsic[1])
}

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

12/95



03/11/2026, 20:42

Building an Actor-Driven Odin TUI

// Root node anchors to screen dimensions if configured with Grow
root := &ctx.nodes[0]
if _, is_grow_w := root.config.width.(Grow); is_grow_w {
root.computed_size[0] = clamp_axis(ctx.screen_size[0], root.config.width)
}
if _, is_grow_h := root.config.height.(Grow); is_grow_h {
root.computed_size[1] = clamp_axis(ctx.screen_size[1], root.config.height)
}
root.rect = Rect{
x = 0,
y = 0,
w = root.computed_size[0],
h = root.computed_size[1],
}
// =========================================================================
// PASS 2: Top-Down Grow Distribution & Coordinate Assignment
// =========================================================================
for i := 0; i < len(ctx.nodes); i += 1 {
parent := &ctx.nodes[i]
parent.inner_rect = compute_inner_rect(parent.rect, parent.config)
if parent.child_count == 0 {
continue
}
main_axis := 0 if parent.config.dir == .Row else 1
cross_axis := 1 - main_axis
inner_size := [2]i32{parent.inner_rect.w, parent.inner_rect.h}
total_gaps := (parent.child_count - 1) * parent.config.gap if parent.child_count > 1 else 0
// 1. Separate fixed/fit children from Grow children along the main axis
fixed_used: i32 = total_gaps
unfrozen_count := 0
for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
child := &ctx.nodes[c]
main_sizing := child.config.width if main_axis == 0 else child.config.height
if _, is_grow := main_sizing.(Grow); is_grow {
child.frozen = false
unfrozen_count += 1
} else {
child.frozen = true
fixed_used += child.computed_size[main_axis]
}
}
// 2. Iteratively clamp Grow children that violate min/max bounds,
//
then distribute remaining space with exact integer remainder handling.
remaining_main := max(0, inner_size[main_axis] - fixed_used)
for unfrozen_count > 0 {
total_weight: i32 = 0
for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
child := &ctx.nodes[c]
if !child.frozen {
g := get_grow(child.config, main_axis)
total_weight += max(g.weight, 1)
}
}
clamped_any := false
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

13/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.frozen { continue } g := get_grow(child.config, main_axis) w := max(g.weight, 1) target := (remaining_main * w) / max(total_weight, 1)

if g.min > 0 && target < g.min { child.computed_size[main_axis] = g.min child.frozen = true remaining_main = max(0, remaining_main-g.min) unfrozen_count-= 1 clamped_any = true } else if g.max > 0 && target > g.max { child.computed_size[main_axis] = g.max child.frozen = true remaining_main = max(0, remaining_main-g.max) unfrozen_count-= 1 clamped_any = true } }

if!clamped_any { // Final proportional distribution with exact integer remainder accum_weight: i32 = 0 prev_distributed: i32 = 0 for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.frozen { continue } g := get_grow(child.config, main_axis) accum_weight += max(g.weight, 1) next_distributed := (remaining_main * accum_weight) / max(total_weight, 1) child.computed_size[main_axis] = next_distributed-prev_distributed prev_distributed = next_distributed child.frozen = true unfrozen_count-= 1 } } }

// 3. Resolve cross-axis Grow children and compute total main-axis span for alignment total_main_span: i32 = total_gaps for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] cross_sizing := child.config.width if cross_axis == 0 else child.config.height if _, is_grow := cross_sizing.(Grow); is_grow { child.computed_size[cross_axis] = clamp_axis(inner_size[cross_axis], cross_sizing) } total_main_span += child.computed_size[main_axis] }

// 4. Assign screen-space (x, y) coordinates to each child main_cursor := align_offset(inner_size[main_axis], total_main_span, parent.config.main_align) inner_origin := [2]i32{parent.inner_rect.x, parent.inner_rect.y}

for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] cross_offset := align_offset(inner_size[cross_axis], child.computed_size[cross_axis], paren

pos: [2]i32

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 14/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

pos[main_axis] = inner_origin[main_axis] + main_cursor pos[cross_axis] = inner_origin[cross_axis] + cross_offset

child.rect = Rect{ x = pos[0], y = pos[1], w = child.computed_size[0], h = child.computed_size[1], } main_cursor += child.computed_size[main_axis] + parent.config.gap } } }

// Internal helpers

compute_total_insets :: #force_inline proc(cfg: Box_Config)-> [2]i32 { b := i32(1) if cfg.border!=.None else 0 return { cfg.padding.left + cfg.padding.right + b * 2, cfg.padding.top + cfg.padding.bottom + b * 2, } }

compute_inner_rect :: #force_inline proc(outer: Rect, cfg: Box_Config)-> Rect { b := i32(1) if cfg.border!=.None else 0 left := cfg.padding.left + b right := cfg.padding.right + b top := cfg.padding.top + b bottom := cfg.padding.bottom + b return Rect{ x = outer.x + left, y = outer.y + top, w = max(0, outer.w-(left + right)), h = max(0, outer.h-(top + bottom)), } }

resolve_pass1_axis :: #force_inline proc(sizing: Axis_Size, intrinsic: i32)-> i32 { switch s in sizing { case Fixed: return i32(s) case Fit: return clamp_bounds(intrinsic, s.min, s.max) case Grow: // Report minimum/intrinsic base size during Pass 1 so Fit parents can wrap Grow children return clamp_bounds(intrinsic, s.min, s.max) case nil: return intrinsic } return intrinsic }

clamp_axis :: #force_inline proc(val: i32, sizing: Axis_Size)-> i32 { switch s in sizing { case Fixed: return i32(s) case Fit: return clamp_bounds(val, s.min, s.max) case Grow: return clamp_bounds(val, s.min, s.max) case nil: return val }

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 15/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

return val
}
clamp_bounds :: #force_inline proc(val, min_v, max_v: i32) -> i32 {
res := max(val, min_v)
if max_v > 0 {
res = min(res, max_v)
}
return res
}
get_grow :: #force_inline proc(cfg: Box_Config, axis: int) -> Grow {
s := cfg.width if axis == 0 else cfg.height
if g, ok := s.(Grow); ok {
return g
}
return Grow{weight = 1}
}
align_offset :: #force_inline proc(available, content: i32, align: Alignment) -> i32 {
slack := max(0, available - content)
switch align {
case .Start:
return 0
case .Center:
return slack / 2
case .End:
return slack
}
return 0
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
@(test)
test_clay_layout_solver :: proc(t: ^testing.T) {
defer free_all(context.temp_allocator)
ctx: Layout_Context
begin_layout(&ctx, 80, 24)
if container(&ctx, "root", {dir = .Column, width = grow(1), height = grow(1), padding = pad_all(1), gap
// Header shrink-wraps vertically (Fit) around a 1-row title + Rounded border (1+1) = 3 rows
if container(&ctx, "header", {dir = .Row, width = grow(1), height = fit(), border = .Rounded, pad
leaf(&ctx, "title", 15, 1)
}
// Body fills remaining vertical space: 24 - 2 (root pad) - 3 (header) - 1 (gap) = 18 rows
if container(&ctx, "body", {dir = .Row, width = grow(1), height = grow(1), gap = 2}) {
leaf(&ctx, "sidebar", 0, 0, {width = fixed(20), height = grow(1), border = .Plain})
leaf(&ctx, "main_panel", 0, 0, {width = grow(1), height = grow(1), border = .Plain})
}
}
end_layout(&ctx)
root_rect, _ := get_rect(&ctx, "root")
testing.expect_value(t, root_rect, Rect{x = 0, y = 0, w = 80, h = 24})
header_rect, _ := get_rect(&ctx, "header")
testing.expect_value(t, header_rect, Rect{x = 1, y = 1, w = 78, h = 3})

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

16/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

title_rect, _ := get_rect(&ctx, "title") testing.expect_value(t, title_rect, Rect{x = 3, y = 2, w = 15, h = 1})

body_rect, _ := get_rect(&ctx, "body") testing.expect_value(t, body_rect, Rect{x = 1, y = 5, w = 78, h = 18})

sidebar_rect, _ := get_rect(&ctx, "sidebar") testing.expect_value(t, sidebar_rect, Rect{x = 1, y = 5, w = 20, h = 18})

main_rect, _ := get_rect(&ctx, "main_panel") // 78 total width-20 (sidebar)-2 (gap) = 56 width, starting at x = 1 + 20 + 2 = 23 testing.expect_value(t, main_rect, Rect{x = 23, y = 5, w = 56, h = 18}) }

@(test) test_grow_min_max_and_remainder :: proc(t: ^testing.T) { defer free_all(context.temp_allocator)

ctx: Layout_Context begin_layout(&ctx, 101, 10)

// 101 cells split across a Grow(1, max=20) and two Grow(1) siblings if container(&ctx, "row", {dir =.Row, width = grow(1), height = grow(1)}) { leaf(&ctx, "capped", 0, 0, {width = grow(weight = 1, max = 20), height = grow(1)}) leaf(&ctx, "flex_a", 0, 0, {width = grow(1), height = grow(1)}) leaf(&ctx, "flex_b", 0, 0, {width = grow(1), height = grow(1)}) }

end_layout(&ctx)

capped, _ := get_rect(&ctx, "capped") flex_a, _ := get_rect(&ctx, "flex_a") flex_b, _ := get_rect(&ctx, "flex_b")

// "capped" freezes at 20, leaving 81 cells split across flex_a (40) and flex_b (41) = 101 exact testing.expect_value(t, capped.w, 20) testing.expect_value(t, flex_a.w + flex_b.w, 81) testing.expect_value(t, capped.w + flex_a.w + flex_b.w, 101) }

## Why This Design Works Well in Practice

**Zero Lost Terminal Columns on Odd Splits:** Terminal grids are integers, so dividing 81 columns across two grow(1) panels using naive remaining / total_weight loses 1 column on the right margin (40 + 40 = 80). The cumulative (remaining_main * accum_weight) / total_weight step distributes integer remainders across siblings so their widths always sum to the exact available cell count.

**Constrained Grow Freeze Loop:** If one grow(1) panel hits its max = 20 cap (like a sidebar that shouldn't stretch too wide on ultrawide monitors), the solver freezes that child at 20 and redistributes the leftover space among the remaining unfrozen Grow siblings.

**Safe Scope Nesting:** Separating container (decorated with @(deferred_in = defer_end_container) for if container(...) { ...} blocks) from leaf (which pushes without modifying parent_stack) prevents a standalone widget call from accidentally swallowing subsequent siblings.

*User prompt: Write the Odin renderer that walks the solved Layout_Context, draws borders/text into a double-buffered Cell grid, and emits minimal* *ANSI diffs.*

Response: Because ctx.nodes in layout.odin is already in **topological order** (parent_idx < child_idx), the renderer can walk the solved layout tree in a single forward loop (0..< len(ctx.nodes)) without recursion:

1. **Painter's Algorithm & O(1) Parent Clipping:** Visiting nodes forward draws parent backgrounds and borders before child widgets, and each child computes its clip rectangle by intersecting its parent's solved inner_rect with the parent's clip bounds.
2. **Zero-Allocation Hot Loop Diffing:** The ANSI differ compares back and front cell slices, tracks cursor coordinates (cur_x, cur_y) to skip redundant \x1b[row;colH jumps on contiguous horizontal runs, diffs SGR styles/colors incrementally, and emits **0 bytes** if no cells
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 17/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

changed during the frame.

3. **Tear-Free Synchronized Output:** Dirty frames are wrapped in DEC Mode 2026 (\x1b[?2026h ... \x1b[?2026l) so terminals batch the frame atomically.
## Complete Odin Implementation (renderer.odin)

tui_layout) and run odin

|Place renderer.odin in the same directory as layout.odin (package||||test .-vet|-strict-style:|
|---|---|---|---|---|---|
|package|tui_layout|||||
|import|"core:mem"|||||
|import|"core:strings"|||||
|import|"core:testing"|||||
|import|"core:unicode/utf8"|||||
|Style_Flag|::|enum u8|{|||

Bold, Dim, Italic, Underline, Blink, Reverse, Strikethrough, }

Style_Flags :: bit_set[Style_Flag; u8]

Color_Kind :: enum u8 { Default, ANSI_16, ANSI_256, RGB, }

// Compact 4-byte color descriptor. For ANSI_16 and ANSI_256, `r` stores the palette index. Color :: struct { kind: Color_Kind, r: u8, g: u8, b: u8, }

Cell :: struct { ch: rune, fg: Color, bg: Color, style: Style_Flags, width: u8, // 1 = standard, 2 = wide leader, 0 = wide trail cell }

EMPTY_CELL :: Cell{ ch ='', width = 1, }

// Visual styling & content attached to layout nodes by ID hash Paint_Spec :: struct { title: string, text: string, fg: Color, bg: Color, border_fg: Color, title_fg: Color, style: Style_Flags,

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 18/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

title_style: Style_Flags, fill_bg: bool, }

Border_Glyphs :: struct { tl, tr, bl, br: rune, horiz, vert: rune, }

BORDER_GLYPHS :: [Border_Kind]Border_Glyphs{ .None = {}, .Plain = {tl ='┌', tr ='┐', bl ='└', br ='┘', horiz ='─', vert ='│'}, .Rounded = {tl ='╭', tr ='╮', bl ='╰', br ='╯', horiz ='─', vert ='│'}, .Double = {tl ='╔', tr ='╗', bl ='╚', br ='╝', horiz ='═', vert ='║'}, }

Screen :: struct { width: i32, height: i32, front: []Cell, back: []Cell, paints: map[u64]Paint_Spec, first_frame: bool, allocator: mem.Allocator, }

// Color constructors rgb :: #force_inline proc(r, g, b: u8)-> Color { return Color{kind =.RGB, r = r, g = g, b = b} }

ansi256 :: #force_inline proc(idx: u8)-> Color { return Color{kind =.ANSI_256, r = idx} }

ansi16 :: #force_inline proc(idx: u8)-> Color { return Color{kind =.ANSI_16, r = idx} }

// Lifecycle procedures for persistent double buffers screen_init :: proc( s: ^Screen, w, h: i32, allocator := context.allocator, )-> mem.Allocator_Error { total := int(max(0, w * h))

s.front = make([]Cell, total, allocator) or_return
s.back = make([]Cell, total, allocator) or_return
s.width = w
s.height = h
s.first_frame = true
s.allocator = allocator for i in 0..< total {
s.front[i] = EMPTY_CELL
s.back[i] = EMPTY_CELL
} return nil }

screen_destroy :: proc(s: ^Screen) { delete(s.front, s.allocator) delete(s.back, s.allocator) s^ = {}

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 19/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

}
screen_resize :: proc(s: ^Screen, new_w, new_h: i32) -> mem.Allocator_Error {
if s.width == new_w && s.height == new_h {
return nil
}
delete(s.front, s.allocator)
delete(s.back, s.allocator)
return screen_init(s, new_w, new_h, s.allocator)
}
// Resets the back buffer and allocates the per-frame paint map on context.temp_allocator
begin_frame :: proc(s: ^Screen, default_bg: Color = {}, temp_alloc := context.temp_allocator) {
clear_cell := EMPTY_CELL
clear_cell.bg = default_bg
for i in 0 ..< len(s.back) {
s.back[i] = clear_cell
}
s.paints = make(map[u64]Paint_Spec, 128, temp_alloc)
}
// Associates visual properties (borders, titles, text, colors) with a layout node ID
set_paint :: proc(s: ^Screen, id: string, spec: Paint_Spec) {
s.paints[hash_id(id)] = spec
}
// Combined helper: pushes a text leaf into Layout_Context and registers its Paint_Spec
ui_label :: proc(
ctx: ^Layout_Context,
s: ^Screen,
id: string,
text: string,
fg: Color = {},
style: Style_Flags = {},
cfg: Box_Config = {},
) -> i32 {
rune_w := i32(utf8.rune_count_in_string(text))
s.paints[hash_id(id)] = Paint_Spec{
text = text,
fg
= fg,
style = style,
}
return leaf(ctx, id, rune_w, 1, cfg)
}
// =============================================================================
// Layout Tree Rasterizer (Walks Solved Layout_Context)
// =============================================================================
render_layout :: proc(s: ^Screen, ctx: ^Layout_Context, temp_alloc := context.temp_allocator) {
node_count := len(ctx.nodes)
if node_count == 0 {
return
}
screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height}
// Stores the inner clip rect each node exposes to its children
inner_clips := make([]Rect, node_count, temp_alloc)
for i := 0; i < node_count; i += 1 {
node := ctx.nodes[i]
parent_clip := screen_bounds
if node.parent_idx >= 0 {
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

20/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

parent_clip = inner_clips[node.parent_idx] }

node_clip := rect_intersect(parent_clip, node.rect) inner_clips[i] = rect_intersect(node_clip, node.inner_rect)

if node_clip.w <= 0 || node_clip.h <= 0 { continue }

paint := s.paints[node.id_hash]

// 1. Fill background if requested or if a non-default bg color is set if paint.fill_bg || paint.bg.kind!=.Default { fill_rect(s, node.rect, node_clip,'', paint.fg, paint.bg, {}) }

// 2. Draw border and optional embedded title if node.config.border!=.None { b_fg := paint.border_fg if paint.border_fg.kind!=.Default else paint.fg draw_border(s, node.rect, node_clip, node.config.border, b_fg, paint.bg, paint.style)

if len(paint.title) > 0 && node.rect.w > 4 { t_fg := paint.title_fg if paint.title_fg.kind!=.Default else b_fg t_style := paint.title_style if paint.title_style!= {} else paint.style draw_border_title(s, node.rect, node_clip, paint.title, t_fg, paint.bg, t_style) } }

// 3. Draw leaf or container text inside inner_rect if len(paint.text) > 0 && inner_clips[i].w > 0 && inner_clips[i].h > 0 { text_len := i32(utf8.rune_count_in_string(paint.text)) h_align := node.config.main_align if node.config.dir ==.Row else node.config.cross_align v_align := node.config.cross_align if node.config.dir ==.Row else node.config.main_align

tx := node.inner_rect.x + align_offset(node.inner_rect.w, text_len, h_align) ty := node.inner_rect.y + align_offset(node.inner_rect.h, 1, v_align) draw_string_clipped(s, tx, ty, inner_clips[i], paint.text, paint.fg, paint.bg, paint.style) } } }

// Low-level clipped cell primitives

set_cell_clipped :: #force_inline proc(s: ^Screen, x, y: i32, clip: Rect, cell: Cell) { if x < clip.x || x >= clip.x + clip.w || y < clip.y || y >= clip.y + clip.h { return } if x < 0 || x >= s.width || y < 0 || y >= s.height { return } idx := int(y * s.width + x)

s.back[idx] = cell
}

fill_rect :: proc(s: ^Screen, r: Rect, clip: Rect, ch: rune, fg, bg: Color, style: Style_Flags) { bounds := rect_intersect(r, clip) if bounds.w <= 0 || bounds.h <= 0 { return } cell := Cell{ ch = ch, fg = fg, bg = bg,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 21/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

style = style, width = 1, } for y := bounds.y; y < bounds.y + bounds.h; y += 1 { row_offset := y * s.width for x := bounds.x; x < bounds.x + bounds.w; x += 1 {

s.back[int(row_offset + x)] = cell
} } }

draw_border :: proc( s: ^Screen, r: Rect, clip: Rect, kind: Border_Kind, fg, bg: Color, style: Style_Flags, ) { if r.w < 2 || r.h < 2 || kind ==.None { return } glyphs := BORDER_GLYPHS[kind] x0 := r.x y0 := r.y x1 := r.x + r.w-1 y1 := r.y + r.h-1

// Corners set_cell_clipped(s, x0, y0, clip, Cell{ch = glyphs.tl, fg = fg, bg = bg, style = style, width = 1}) set_cell_clipped(s, x1, y0, clip, Cell{ch = glyphs.tr, fg = fg, bg = bg, style = style, width = 1}) set_cell_clipped(s, x0, y1, clip, Cell{ch = glyphs.bl, fg = fg, bg = bg, style = style, width = 1}) set_cell_clipped(s, x1, y1, clip, Cell{ch = glyphs.br, fg = fg, bg = bg, style = style, width = 1})

// Horizontal edges h_cell := Cell{ch = glyphs.horiz, fg = fg, bg = bg, style = style, width = 1} for x := x0 + 1; x < x1; x += 1 { set_cell_clipped(s, x, y0, clip, h_cell) set_cell_clipped(s, x, y1, clip, h_cell) }

// Vertical edges v_cell := Cell{ch = glyphs.vert, fg = fg, bg = bg, style = style, width = 1} for y := y0 + 1; y < y1; y += 1 { set_cell_clipped(s, x0, y, clip, v_cell) set_cell_clipped(s, x1, y, clip, v_cell) } }

draw_border_title :: proc( s: ^Screen, r: Rect, clip: Rect, title: string, fg, bg: Color, style: Style_Flags, ) { max_title_w := r.w-4 if max_title_w <= 0 { return } title_clip := rect_intersect(clip, Rect{x = r.x + 1, y = r.y, w = r.w-2, h = 1}) set_cell_clipped(s, r.x + 1, r.y, title_clip, Cell{ch ='', fg = fg, bg = bg, style = style, width = 1}

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 22/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

cx := r.x + 2
count: i32 = 0
for ch in title {
if count >= max_title_w {
break
}
set_cell_clipped(s, cx, r.y, title_clip, Cell{ch = ch, fg = fg, bg = bg, style = style, width = 1
cx += 1
count += 1
}
set_cell_clipped(s, cx, r.y, title_clip, Cell{ch = ' ', fg = fg, bg = bg, style = style, width = 1})
}
draw_string_clipped :: proc(
s: ^Screen,
x, y: i32,
clip: Rect,
text: string,
fg, bg: Color,
style: Style_Flags,
) {
if y < clip.y || y >= clip.y + clip.h || y < 0 || y >= s.height {
return
}
cx := x
for ch in text {
if cx >= clip.x + clip.w || cx >= s.width {
break
}
if cx >= clip.x && cx >= 0 {
idx := int(y * s.width + cx)
cell_bg := bg if bg.kind != .Default else s.back[idx].bg
s.back[idx] = Cell{
ch
= ch,
fg
= fg,
bg
= cell_bg,
style = style,
width = 1,
}
}
cx += 1
}
}
rect_intersect :: #force_inline proc(a, b: Rect) -> Rect {
x0 := max(a.x, b.x)
y0 := max(a.y, b.y)
x1 := min(a.x + a.w, b.x + b.w)
y1 := min(a.y + a.h, b.y + b.h)
return Rect{
x = x0,
y = y0,
w = max(0, x1 - x0),
h = max(0, y1 - y0),
}
}
// =============================================================================
// Minimal ANSI Diff Emitter
// =============================================================================
screen_diff_ansi :: proc(s: ^Screen, out: ^strings.Builder) -> int {
start_len := len(out.buf)

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

23/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

cur_x := i32(-1) cur_y := i32(-1) cur_fg := Color{kind =.Default} cur_bg := Color{kind =.Default} cur_style := Style_Flags{} sgr_initialized := false emitted_any := false

for y: i32 = 0; y < s.height; y += 1 { row_base := int(y * s.width) for x: i32 = 0; x < s.width; x += 1 { idx := row_base + int(x) next := s.back[idx] prev := s.front[idx]

if!s.first_frame && next == prev { continue }

s.front[idx] = next // Trail cell of a 2-column glyph is advanced implicitly by the terminal if next.width == 0 { continue } if!emitted_any { // Begin DEC Mode 2026 Synchronized Update strings.write_string(out, "\x1b[?2026h") emitted_any = true } // Emit 1-based cursor position only when non-contiguous if x!= cur_x || y!= cur_y { strings.write_string(out, "\x1b[") strings.write_int(out, int(y + 1)) strings.write_byte(out,';') strings.write_int(out, int(x + 1)) strings.write_byte(out,'H') } // Emit SGR sequence only when style or colors differ from active state if!sgr_initialized || next.fg!= cur_fg || next.bg!= cur_bg || next.style!= cur_style { emit_sgr_transition(out, cur_fg, cur_bg, cur_style, next.fg, next.bg, next.style,!s cur_fg = next.fg cur_bg = next.bg cur_style = next.style sgr_initialized = true } ch := next.ch if next.ch!= 0 else'' strings.write_rune(out, ch) step := i32(max(next.width, 1)) cur_x = x + step cur_y = y
} }

if emitted_any { // Reset SGR attributes and end Synchronized Update strings.write_string(out, "\x1b[0m\x1b[?2026l") }

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 24/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

s.first_frame = false return len(out.buf)-start_len
}

emit_sgr_transition :: proc( out: ^strings.Builder, old_fg, old_bg: Color, old_style: Style_Flags, new_fg, new_bg: Color, new_style: Style_Flags, force_reset: bool, ) { strings.write_string(out, "\x1b[") first := true

// If any style bit was removed, issue a full reset (0) and re-apply active attributes removed_styles := old_style-new_style need_reset := force_reset || removed_styles!= {}

if need_reset { strings.write_byte(out,'0') first = false }

styles_to_apply := new_style if need_reset else (new_style-old_style) for flag in styles_to_apply { if!first { strings.write_byte(out,';') } first = false switch flag { case.Bold: strings.write_byte(out,'1') case.Dim: strings.write_byte(out,'2') case.Italic: strings.write_byte(out,'3') case.Underline: strings.write_byte(out,'4') case.Blink: strings.write_byte(out,'5') case.Reverse: strings.write_byte(out,'7') case.Strikethrough: strings.write_byte(out,'9') } }

if need_reset || new_fg!= old_fg { if!(need_reset && new_fg.kind ==.Default) { if!first { strings.write_byte(out,';') } first = false write_color_sgr(out, new_fg, false) } }

if need_reset || new_bg!= old_bg { if!(need_reset && new_bg.kind ==.Default) { if!first { strings.write_byte(out,';') } first = false write_color_sgr(out, new_bg, true) } }

strings.write_byte(out,'m') }

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 25/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

write_color_sgr :: proc(out: ^strings.Builder, c: Color, is_bg: bool) {
switch c.kind {
case .Default:
strings.write_string(out, "49" if is_bg else "39")
case .ANSI_16:
idx := int(c.r)
code := (40 + idx) if is_bg else (30 + idx)
if idx >= 8 {
code = (100 + (idx - 8)) if is_bg else (90 + (idx - 8))
}
strings.write_int(out, code)
case .ANSI_256:
strings.write_string(out, "48;5;" if is_bg else "38;5;")
strings.write_int(out, int(c.r))
case .RGB:
strings.write_string(out, "48;2;" if is_bg else "38;2;")
strings.write_int(out, int(c.r))
strings.write_byte(out, ';')
strings.write_int(out, int(c.g))
strings.write_byte(out, ';')
strings.write_int(out, int(c.b))
}
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
@(test)
test_render_layout_and_incremental_diff :: proc(t: ^testing.T) {
defer free_all(context.temp_allocator)
scr: Screen
err := screen_init(&scr, 30, 6)
testing.expect_value(t, err, nil)
defer screen_destroy(&scr)
out := strings.builder_make(context.temp_allocator)
// --- Frame 1: Initial Render --ctx: Layout_Context
begin_layout(&ctx, 30, 6)
begin_frame(&scr)
if container(&ctx, "panel", {
dir
= .Column,
width = grow(1),
height = grow(1),
border = .Rounded,
}) {
set_paint(&scr, "panel", {
title
= "xitdb",
border_fg = rgb(100, 200, 255),
style
= {.Bold},
})
ui_label(&ctx, &scr, "status", "Moment #41", rgb(0, 255, 128))
}
end_layout(&ctx)
render_layout(&scr, &ctx)
// Verify Rounded top-left corner and title in back buffer
testing.expect_value(t, scr.back[0].ch, '╭')
testing.expect_value(t, scr.back[2].ch, 'x')
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

26/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

testing.expect_value(t, scr.back[6].ch,'b')

// Verify child label placed at inner_rect (x=1, y=1) testing.expect_value(t, scr.back[1 * 30 + 1].ch,'M') testing.expect_value(t, scr.back[1 * 30 + 10].ch,'1')

bytes_frame1 := screen_diff_ansi(&scr, &out) testing.expect(t, bytes_frame1 > 0, "Frame 1 should emit full initial ANSI buffer")

//---Frame 2: Identical State-> 0 Bytes Emitted--- strings.builder_reset(&out) begin_layout(&ctx, 30, 6) begin_frame(&scr)

if container(&ctx, "panel", { dir =.Column, width = grow(1), height = grow(1), border =.Rounded, }) { set_paint(&scr, "panel", { title = "xitdb", border_fg = rgb(100, 200, 255), style = {.Bold}, }) ui_label(&ctx, &scr, "status", "Moment #41", rgb(0, 255, 128)) }

end_layout(&ctx) render_layout(&scr, &ctx)

bytes_frame2 := screen_diff_ansi(&scr, &out) testing.expect_value(t, bytes_frame2, 0)

//---Frame 3: Single Character Changed ('Moment #41'->'Moment #42')--- strings.builder_reset(&out) begin_layout(&ctx, 30, 6) begin_frame(&scr)

if container(&ctx, "panel", { dir =.Column, width = grow(1), height = grow(1), border =.Rounded, }) { set_paint(&scr, "panel", { title = "xitdb", border_fg = rgb(100, 200, 255), style = {.Bold}, }) ui_label(&ctx, &scr, "status", "Moment #42", rgb(0, 255, 128)) }

end_layout(&ctx) render_layout(&scr, &ctx)

bytes_frame3 := screen_diff_ansi(&scr, &out) diff_str := strings.to_string(out)

// Only cell (x=10, y=1)-> 1-based ANSI row 2, col 11 ('\x1b[2;11H') should be emitted expected_delta := "\x1b[?2026h\x1b[2;11H\x1b[0;38;2;0;255;128m2\x1b[0m\x1b[?2026l" testing.expect_value(t, bytes_frame3, len(expected_delta)) testing.expect_value(t, diff_str, expected_delta) }

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 27/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

## How the Pieces Work Together

**Decoupled Layout & Paint (set_paint / ui_label):** Layout_Context stays purely geometric, while Screen.paints maps widget ID hashes (u64) to colors, borders, titles, and text on context.temp_allocator.

**Hierarchical Clipping Without a Stack:** Because ctx.nodes guarantees parent_idx < i, inner_clips[i] is computed in one line (rect_intersect(node_clip, node.inner_rect)), preventing overflowing text or child borders from bleeding outside a shrunken parent panel.

**Exact Delta Verification:** As shown in Frame 3 of test_render_layout_and_incremental_diff, changing "Moment #41" to "Moment #42" inside a 30x6 bordered panel emits **only 44 bytes** (\x1b[? 2026h\x1b[2;11H\x1b[0;38;2;0;255;128m2\x1b[0m\x1b[?2026l), jumping straight to row 2, column 11 and writing '2'.

*User prompt: Extend Screen and Layout_Context to support z_layer sorting and automatic 50% RGB backdrop dimming for modals.*

Response: To support z_layer overlays and automatic 50% RGB backdrop dimming without breaking your two-pass topological solver, we need three targeted upgrades across layout.odin and renderer.odin:

1. **Z-Layer Inheritance & Out-of-Flow Promotion (layout.odin):** Before Pass 1, a fast forward scan computes effective_z = max(parent.effective_z, node.config.z_layer). Any node that elevates z_layer above its parent (or sets floating = true) is marked out_of_flow = true. It is skipped by its parent's Pass 1/Pass 2 flow math so a modal declared deep inside a sidebar widget never pushes sibling widgets around, while the modal's own children inherit effective_z and still Fit/Grow inside the modal normally.
2. **Two-Stage Clipping & Stable Z-Sort (renderer.odin):** render_layout first resolves clipping rectangles in topological order (0..< len(ctx.nodes)), resetting the clip root to screen_bounds whenever a node is out_of_flow. It then runs a **stable sort** on node indices by effective_z, ensuring higher layers render last while preserving parent-before-child order within every layer.
3. **In-Place 50% RGB Bit-Shift Dimming (renderer.odin):** When a node with backdrop =.Dim_Screen (or .Dim_Rect) is visited during the z-sorted render pass, dim_rect_backdrop shifts existing RGB foreground and background channels right by 1 bit (r >> 1, g >> 1, b >> 1) and applies .Dim (while stripping .Bold) for non-RGB palette cells before painting the modal at full brightness.
## 1. Layout Solver Updates (layout.odin)

Replace Box_Config, Layout_Node, and end_layout in layout.odin with the following definitions:

package tui_layout

Anchor_Mode :: enum u8 { Screen, // Position out-of-flow node relative to the full terminal screen Parent, // Position out-of-flow node relative to its parent's outer Rect (e.g., dropdowns) }

Box_Config :: struct { dir: Direction, width: Axis_Size, height: Axis_Size, padding: Padding, gap: i32, border: Border_Kind, main_align: Alignment, cross_align: Alignment, // Z-layer & overlay positioning z_layer: u8, floating: bool, anchor: Anchor_Mode, self_align: [2]Alignment, // [0] = horizontal, [1] = vertical alignment inside anchor rect offset: [2]i32, // [x, y] offset from aligned anchor position }

Layout_Node :: struct { id: string, id_hash: u64, config: Box_Config, parent_idx: i32, first_child: i32,

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 28/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

last_child:
i32,
next_sibling: i32,
child_count:
i32,
content_size: [2]i32,
computed_size: [2]i32,
rect:
Rect,
inner_rect:
Rect,
effective_z:
u8,
// Inherited or elevated z_layer
out_of_flow:
bool, // True when floating or elevating z_layer above parent
frozen:
bool,
}
end_layout :: proc(ctx: ^Layout_Context) {
if len(ctx.nodes) == 0 {
return
}
// =========================================================================
// PASS 0: Propagate effective_z and identify out-of-flow overlay roots
// =========================================================================
for i := 0; i < len(ctx.nodes); i += 1 {
node := &ctx.nodes[i]
if node.parent_idx >= 0 {
parent_z := ctx.nodes[node.parent_idx].effective_z
node.effective_z = max(parent_z, node.config.z_layer)
node.out_of_flow = node.config.floating || (node.config.z_layer > parent_z)
} else {
node.effective_z = node.config.z_layer
node.out_of_flow = node.config.floating
}
}
// =========================================================================
// PASS 1: Bottom-Up Intrinsic & Fit Sizing (Reverse Topological Order)
// =========================================================================
for i := len(ctx.nodes) - 1; i >= 0; i -= 1 {
node := &ctx.nodes[i]
insets := compute_total_insets(node.config)
main_axis := 0 if node.config.dir == .Row else 1
cross_axis := 1 - main_axis
intrinsic: [2]i32
if node.child_count > 0 {
children_main: i32 = 0
children_cross: i32 = 0
in_flow_count: i32 = 0
for c := node.first_child; c != -1; c = ctx.nodes[c].next_sibling {
child := &ctx.nodes[c]
if child.out_of_flow {
continue
}
children_main += child.computed_size[main_axis]
children_cross = max(children_cross, child.computed_size[cross_axis])
in_flow_count += 1
}
if in_flow_count > 1 {
children_main += (in_flow_count - 1) * node.config.gap
}
intrinsic[main_axis] = children_main + insets[main_axis]
intrinsic[cross_axis] = children_cross + insets[cross_axis]
} else {
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

29/95



03/11/2026, 20:42

Building an Actor-Driven Odin TUI

intrinsic[0] = node.content_size[0] + insets[0]
intrinsic[1] = node.content_size[1] + insets[1]
}
node.computed_size[0] = resolve_pass1_axis(node.config.width, intrinsic[0])
node.computed_size[1] = resolve_pass1_axis(node.config.height, intrinsic[1])
}
// Root node anchors to screen dimensions
root := &ctx.nodes[0]
if _, is_grow_w := root.config.width.(Grow); is_grow_w {
root.computed_size[0] = clamp_axis(ctx.screen_size[0], root.config.width)
}
if _, is_grow_h := root.config.height.(Grow); is_grow_h {
root.computed_size[1] = clamp_axis(ctx.screen_size[1], root.config.height)
}
root.rect = Rect{
x = 0,
y = 0,
w = root.computed_size[0],
h = root.computed_size[1],
}
// =========================================================================
// PASS 2: Top-Down Grow Distribution & Coordinate Assignment
// =========================================================================
for i := 0; i < len(ctx.nodes); i += 1 {
parent := &ctx.nodes[i]
// If this node is an out-of-flow overlay/modal root, anchor it to Screen or Parent
if i > 0 && parent.out_of_flow {
ref_rect := Rect{x = 0, y = 0, w = ctx.screen_size[0], h = ctx.screen_size[1]}
if parent.config.anchor == .Parent && parent.parent_idx >= 0 {
ref_rect = ctx.nodes[parent.parent_idx].rect
}
if _, is_grow_w := parent.config.width.(Grow); is_grow_w {
parent.computed_size[0] = clamp_axis(ref_rect.w, parent.config.width)
}
if _, is_grow_h := parent.config.height.(Grow); is_grow_h {
parent.computed_size[1] = clamp_axis(ref_rect.h, parent.config.height)
}
ox := align_offset(ref_rect.w, parent.computed_size[0], parent.config.self_align[0]) + pare
oy := align_offset(ref_rect.h, parent.computed_size[1], parent.config.self_align[1]) + pare
parent.rect = Rect{
x = ref_rect.x + ox,
y = ref_rect.y + oy,
w = parent.computed_size[0],
h = parent.computed_size[1],
}
}
parent.inner_rect = compute_inner_rect(parent.rect, parent.config)
if parent.child_count == 0 {
continue
}
main_axis := 0 if parent.config.dir == .Row else 1
cross_axis := 1 - main_axis
inner_size := [2]i32{parent.inner_rect.w, parent.inner_rect.h}
in_flow_count: i32 = 0
for c := parent.first_child; c != -1; c = ctx.nodes[c].next_sibling {
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

30/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if!ctx.nodes[c].out_of_flow { in_flow_count += 1 } } total_gaps := (in_flow_count-1) * parent.config.gap if in_flow_count > 1 else 0

// 1. Separate fixed/fit in-flow children from Grow in-flow children fixed_used: i32 = total_gaps unfrozen_count := 0

for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.out_of_flow { child.frozen = true continue } main_sizing := child.config.width if main_axis == 0 else child.config.height

if _, is_grow := main_sizing.(Grow); is_grow { child.frozen = false unfrozen_count += 1 } else { child.frozen = true fixed_used += child.computed_size[main_axis] } }

// 2. Iteratively clamp Grow children and distribute remaining main-axis space remaining_main := max(0, inner_size[main_axis]-fixed_used)

for unfrozen_count > 0 { total_weight: i32 = 0 for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if!child.frozen { g := get_grow(child.config, main_axis) total_weight += max(g.weight, 1) } }

clamped_any := false for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.frozen { continue } g := get_grow(child.config, main_axis) w := max(g.weight, 1) target := (remaining_main * w) / max(total_weight, 1)

if g.min > 0 && target < g.min { child.computed_size[main_axis] = g.min child.frozen = true remaining_main = max(0, remaining_main-g.min) unfrozen_count-= 1 clamped_any = true } else if g.max > 0 && target > g.max { child.computed_size[main_axis] = g.max child.frozen = true remaining_main = max(0, remaining_main-g.max) unfrozen_count-= 1 clamped_any = true } }

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 31/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if!clamped_any { accum_weight: i32 = 0 prev_distributed: i32 = 0 for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.frozen { continue } g := get_grow(child.config, main_axis) accum_weight += max(g.weight, 1) next_distributed := (remaining_main * accum_weight) / max(total_weight, 1) child.computed_size[main_axis] = next_distributed-prev_distributed prev_distributed = next_distributed child.frozen = true unfrozen_count-= 1 } } }

// 3. Resolve cross-axis Grow for in-flow children total_main_span: i32 = total_gaps for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.out_of_flow { continue } cross_sizing := child.config.width if cross_axis == 0 else child.config.height if _, is_grow := cross_sizing.(Grow); is_grow { child.computed_size[cross_axis] = clamp_axis(inner_size[cross_axis], cross_sizing) } total_main_span += child.computed_size[main_axis] }

// 4. Assign screen-space (x, y) coordinates to in-flow children main_cursor := align_offset(inner_size[main_axis], total_main_span, parent.config.main_align) inner_origin := [2]i32{parent.inner_rect.x, parent.inner_rect.y}

for c := parent.first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.out_of_flow { continue } cross_offset := align_offset(inner_size[cross_axis], child.computed_size[cross_axis], paren

pos: [2]i32 pos[main_axis] = inner_origin[main_axis] + main_cursor pos[cross_axis] = inner_origin[cross_axis] + cross_offset

child.rect = Rect{ x = pos[0], y = pos[1], w = child.computed_size[0], h = child.computed_size[1], } main_cursor += child.computed_size[main_axis] + parent.config.gap } } }

## 2. Z-Sorted Renderer & 50% RGB Backdrop Dimming (renderer.odin)

Update Paint_Spec and render_layout in renderer.odin, and add the backdrop dimming primitives and ui_modal helper:

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 32/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

package tui_layout

import "core:testing"

Backdrop_Mode :: enum u8 { None, // Standard drawing without modifying underlying cells Dim_Screen, // Halves RGB channels (50%) across the entire screen before drawing this node Dim_Rect, // Halves RGB channels (50%) only inside this node's outer Rect (translucent HUD/toast) }

Paint_Spec :: struct { title: string, text: string, fg: Color, bg: Color, border_fg: Color, title_fg: Color, style: Style_Flags, title_style: Style_Flags, fill_bg: bool, backdrop: Backdrop_Mode, }

Modal_Spec :: struct { title: string, z_layer: u8, width: Axis_Size, height: Axis_Size, padding: Padding, gap: i32, border: Border_Kind, fg: Color, bg: Color, border_fg: Color, title_fg: Color, backdrop: Backdrop_Mode, }

// Scoped modal helper: floats above normal flow, centers on screen, and dims the backdrop @(deferred_in = defer_end_modal) ui_modal :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, spec: Modal_Spec)-> bool { z := spec.z_layer if spec.z_layer > 0 else 20 border := spec.border if spec.border!=.None else.Double w := spec.width if spec.width!= nil else fit(min = 30) h := spec.height if spec.height!= nil else fit()

s.paints[hash_id(id)] = Paint_Spec{ title = spec.title, fg = spec.fg, bg = spec.bg, border_fg = spec.border_fg, title_fg = spec.title_fg, title_style = {.Bold}, fill_bg = true, backdrop = spec.backdrop if spec.backdrop!=.None else.Dim_Screen, } idx := push_node(ctx, id, Box_Config{ dir =.Column, width = w, height = h, padding = spec.padding, gap = spec.gap, border = border,
[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 33/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

z_layer = z, floating = true, anchor =.Screen, self_align = {.Center,.Center}, }, {0, 0}) append(&ctx.parent_stack, idx) return true }

defer_end_modal :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, spec: Modal_Spec) { if len(ctx.parent_stack) > 0 { pop(&ctx.parent_stack) } }

// Halves RGB color channels by 50% using an exact 1-bit right shift dim_color_50 :: #force_inline proc(c: Color)-> Color { if c.kind ==.RGB { return Color{ kind =.RGB, r = c.r >> 1, g = c.g >> 1, b = c.b >> 1, } } return c }

// Dims all existing cells inside `bounds` in-place dim_rect_backdrop :: proc(s: ^Screen, bounds: Rect) { screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height} r := rect_intersect(bounds, screen_bounds) if r.w <= 0 || r.h <= 0 { return }

for y := r.y; y < r.y + r.h; y += 1 { row_offset := y * s.width for x := r.x; x < r.x + r.w; x += 1 { cell := &s.back[int(row_offset + x)] if cell.fg.kind ==.RGB { cell.fg = dim_color_50(cell.fg) } else { // Fallback for Default/ANSI palette colors: strip Bold and apply Dim cell.style = (cell.style-{.Bold}) + {.Dim} } if cell.bg.kind ==.RGB { cell.bg = dim_color_50(cell.bg) } } } }

render_layout :: proc(s: ^Screen, ctx: ^Layout_Context, temp_alloc := context.temp_allocator) { node_count := len(ctx.nodes) if node_count == 0 { return }

screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height} node_clips := make([]Rect, node_count, temp_alloc) inner_clips := make([]Rect, node_count, temp_alloc) sorted_indices := make([]i32, node_count, temp_alloc)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 34/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

// 1. Resolve hierarchical clip rects in topological order (parent_idx < i). // Out-of-flow overlays reset their parent clip to full screen_bounds. for i := 0; i < node_count; i += 1 { node := ctx.nodes[i] parent_clip := screen_bounds if node.parent_idx >= 0 &&!node.out_of_flow { parent_clip = inner_clips[node.parent_idx] } node_clips[i] = rect_intersect(parent_clip, node.rect) inner_clips[i] = rect_intersect(node_clips[i], node.inner_rect) sorted_indices[i] = i32(i) }

// 2. Stable insertion sort by effective_z. // Preserves topological parent-before-child order within each z_layer. for i := 1; i < node_count; i += 1 { key := sorted_indices[i] key_z := ctx.nodes[key].effective_z j := i-1 for j >= 0 && ctx.nodes[sorted_indices[j]].effective_z > key_z { sorted_indices[j + 1] = sorted_indices[j] j-= 1 } sorted_indices[j + 1] = key }

// 3. Rasterize nodes from lowest z_layer to highest z_layer for idx in sorted_indices { node := ctx.nodes[idx] node_clip := node_clips[idx] inner_clip := inner_clips[idx]

paint := s.paints[node.id_hash]

// Apply 50% RGB backdrop dimming over lower z_layers before painting this node switch paint.backdrop { case.None: case.Dim_Screen: dim_rect_backdrop(s, screen_bounds) case.Dim_Rect: dim_rect_backdrop(s, node_clip) }

if node_clip.w <= 0 || node_clip.h <= 0 { continue }

if paint.fill_bg || paint.bg.kind!=.Default { fill_rect(s, node.rect, node_clip,'', paint.fg, paint.bg, {}) }

if node.config.border!=.None { b_fg := paint.border_fg if paint.border_fg.kind!=.Default else paint.fg draw_border(s, node.rect, node_clip, node.config.border, b_fg, paint.bg, paint.style)

if len(paint.title) > 0 && node.rect.w > 4 { t_fg := paint.title_fg if paint.title_fg.kind!=.Default else b_fg t_style := paint.title_style if paint.title_style!= {} else paint.style draw_border_title(s, node.rect, node_clip, paint.title, t_fg, paint.bg, t_style) } }

if len(paint.text) > 0 && inner_clip.w > 0 && inner_clip.h > 0 { text_len := i32( len(paint.text))

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 35/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

h_align := node.config.main_align if node.config.dir == .Row else node.config.cross_align
v_align := node.config.cross_align if node.config.dir == .Row else node.config.main_align
tx := node.inner_rect.x + align_offset(node.inner_rect.w, text_len, h_align)
ty := node.inner_rect.y + align_offset(node.inner_rect.h, 1, v_align)
draw_string_clipped(s, tx, ty, inner_clip, paint.text, paint.fg, paint.bg, paint.style)
}
}
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
@(test)
test_z_layer_sorting_and_backdrop_dimming :: proc(t: ^testing.T) {
defer free_all(context.temp_allocator)
scr: Screen
err := screen_init(&scr, 40, 10)
testing.expect_value(t, err, nil)
defer screen_destroy(&scr)
ctx: Layout_Context
begin_layout(&ctx, 40, 10)
begin_frame(&scr, rgb(20, 30, 40))
if container(&ctx, "root", {dir = .Row, width = grow(1), height = grow(1)}) {
// Left sidebar (width = 16)
if container(&ctx, "sidebar", {dir = .Column, width = fixed(16), height = grow(1), border = .Plai
set_paint(&scr, "sidebar", {border_fg = rgb(100, 120, 140), bg = rgb(20, 30, 40)})
ui_label(&ctx, &scr, "nav_item", "Logs", rgb(200, 100, 50))
// Declare a z_layer=20 modal INSIDE the sidebar BEFORE right_pane is even declared!
if ui_modal(&ctx, &scr, "confirm_modal", {
title
= "Confirm",
z_layer
= 20,
width
= fixed(20),
height
= fit(),
border
= .Double,
bg
= rgb(30, 30, 50),
border_fg = rgb(255, 200, 0),
backdrop = .Dim_Screen,
}) {
ui_label(&ctx, &scr, "modal_msg", "Compact DB?", rgb(255, 255, 255))
}
}
// Right pane declared AFTER the modal in tree order, but on z_layer = 0
if container(&ctx, "right_pane", {dir = .Column, width = grow(1), height = grow(1), border = .Pla
set_paint(&scr, "right_pane", {border_fg = rgb(80, 160, 240), bg = rgb(40, 60, 80)})
ui_label(&ctx, &scr, "right_text", "Active", rgb(120, 240, 160))
}
}
end_layout(&ctx)
render_layout(&scr, &ctx)
// 1. Verify modal did NOT affect sidebar or right_pane layout geometry
sidebar_rect, _ := get_rect(&ctx, "sidebar")
right_rect, _ := get_rect(&ctx, "right_pane")
testing.expect_value(t, sidebar_rect, Rect{x = 0, y = 0, w = 16, h = 10})
testing.expect_value(t, right_rect, Rect{x = 16, y = 0, w = 24, h = 10})

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

36/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

// 2. Verify modal shrink-wrapped its height (1-row child + 2 border rows = 3) and centered on 40x10 scr modal_rect, _ := get_rect(&ctx, "confirm_modal") testing.expect_value(t, modal_rect, Rect{x = 10, y = 3, w = 20, h = 3})

// 3. Verify sidebar text ('L' at x=1, y=1) had its RGB halved from (200, 100, 50)-> (100, 50, 25) nav_cell := scr.back[1 * 40 + 1] testing.expect_value(t, nav_cell.ch,'L') testing.expect_value(t, nav_cell.fg, rgb(100, 50, 25)) testing.expect_value(t, nav_cell.bg, rgb(10, 15, 20))

// 4. Verify right_pane ('A' at x=17, y=1) rendered BEFORE the modal despite later declaration, // and was dimmed 50% from fg=(120, 240, 160), bg=(40, 60, 80)-> fg=(60, 120, 80), bg=(20, 30, 40) right_cell := scr.back[1 * 40 + 17] testing.expect_value(t, right_cell.ch,'A') testing.expect_value(t, right_cell.fg, rgb(60, 120, 80)) testing.expect_value(t, right_cell.bg, rgb(20, 30, 40))

// 5. Verify modal border (at x=10, y=3) and child text ('C' at x=11, y=4) rendered on top at 100% brigh modal_corner := scr.back[3 * 40 + 10] testing.expect_value(t, modal_corner.ch,'╔') testing.expect_value(t, modal_corner.fg, rgb(255, 200, 0)) testing.expect_value(t, modal_corner.bg, rgb(30, 30, 50))

modal_text_cell := scr.back[4 * 40 + 11] testing.expect_value(t, modal_text_cell.ch,'C') testing.expect_value(t, modal_text_cell.fg, rgb(255, 255, 255)) testing.expect_value(t, modal_text_cell.bg, rgb(30, 30, 50)) }

## Why This Approach Fits Immediate-Mode + Actors Cleanly

**Call-Site Locality (ui_modal Anywhere):** You do not have to hoist modal rendering to the end of render_frame. A nested component can open a ui_modal right where its state lives; out_of_flow keeps the parent layout intact, and the stable effective_z sort ensures the modal still composites over widgets declared later in the tree.

**Cumulative Depth for Stacked Modals:** Because dim_rect_backdrop mutates s.back in place (c.r >> 1), stacking a z_layer = 30 confirmation dialog over a z_layer = 20 settings modal automatically dims z_layer = 0 to 25% brightness, z_layer = 20 to 50% brightness, and leaves z_layer = 30 at 100%.

**Anchored Dropdowns (anchor =.Parent):** Setting floating = true, anchor =.Parent, z_layer = 10, offset = {0, 1} on a box lets a dropdown menu anchor directly to its button's solved Rect while escaping the parent toolbar's clip rectangle.

*User prompt: Implement z-layer-aware mouse hit-testing and scoped Tab focus navigation so an active modal captures all input.*

Response: To make mouse hit-testing and Tab focus navigation aware of z_layer overlays and modal input capture, we can take advantage of the fact that layout solving (end_layout) and rendering (render_layout) are already separate passes:

1. **Shared Topological Clips & Z-Order (layout.odin):** end_layout propagates scope_id (the nearest enclosing focus_scope or capture_input container), computes node_clip and inner_clip rectangles during Pass 2, and stores the stable effective_z sort in ctx.z_order.
2. **Reverse Z-Order Hit-Testing & Occlusion (input.odin):** render_layout walks ctx.z_order forward (0..< n, back-to-front), while hit_test_point walks ctx.z_order backward (n-1 down to 0, front-to-back). Solid floating panels occlude clicks from punching through to lower layers, and any active modal with capture_input = true blocks all mouse and keyboard events from reaching lower effective_z layers.
3. **Scoped Tab Cycling & Focus History Stack (input.odin):** Tab and Shift+Tab cycle strictly within the active focus_scope. When a capturing modal opens, resolve_input pushes the previously focused background widget ID onto a history stack, traps focus inside the modal, and automatically restores focus to the original background widget when the modal closes.
## 1. Updates to layout.odin and renderer.odin

In layout.odin, add focusable, focus_scope, and capture_input to Box_Config, store scope_id, node_clip, inner_clip, and z_order during end_layout, and set capture_input = true in ui_modal:

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 37/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

package tui_layout

Box_Config :: struct { dir: Direction, width: Axis_Size, height: Axis_Size, padding: Padding, gap: i32, border: Border_Kind, main_align: Alignment, cross_align: Alignment, // Z-layer & overlay positioning z_layer: u8, floating: bool, anchor: Anchor_Mode, self_align: [2]Alignment, offset: [2]i32, // Focus & input routing focusable: bool, // Can receive keyboard focus and mouse clicks focus_scope: bool, // Traps Tab / Shift+Tab cycling among descendants capture_input: bool, // Traps all mouse/keyboard input at or above effective_z }

Layout_Node :: struct { id: string, id_hash: u64, config: Box_Config, parent_idx: i32, first_child: i32, last_child: i32, next_sibling: i32, child_count: i32, content_size: [2]i32, computed_size: [2]i32, rect: Rect, inner_rect: Rect, node_clip: Rect, // Clipped outer bounds visible on screen inner_clip: Rect, // Clipped inner content bounds exposed to children scope_id: u64, // Enclosing focus_scope or capture_input container ID hash effective_z: u8, out_of_flow: bool, frozen: bool, }

Layout_Context :: struct { nodes: [dynamic]Layout_Node, parent_stack: [dynamic]i32, id_map: map[u64]i32, z_order: []i32, // Indices sorted stably by effective_z ascending screen_size: [2]i32, allocator: mem.Allocator, }

Update begin_layout and end_layout in layout.odin so scope_id, node_clip, inner_clip, and z_order are computed once per frame:

begin_layout :: proc(ctx: ^Layout_Context, screen_w, screen_h: i32, allocator := context.temp_allocator) { ctx.nodes = make([dynamic]Layout_Node, 0, 128, allocator) ctx.parent_stack = make([dynamic]i32, 0, 32, allocator) ctx.id_map = make(map[u64]i32, 128, allocator) ctx.z_order = nil ctx.screen_size = {screen_w, screen_h} ctx.allocator = allocator }

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 38/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

// Inside end_layout(ctx: ^Layout_Context): // 1. Replace PASS 0 with scope_id propagation: for i := 0; i < len(ctx.nodes); i += 1 { node := &ctx.nodes[i] if node.parent_idx >= 0 { parent := ctx.nodes[node.parent_idx] node.effective_z = max(parent.effective_z, node.config.z_layer) node.out_of_flow = node.config.floating || (node.config.z_layer > parent.effective_z) node.scope_id = parent.scope_id } else { node.effective_z = node.config.z_layer node.out_of_flow = node.config.floating node.scope_id = 0 } if node.config.focus_scope || node.config.capture_input { node.scope_id = node.id_hash } }

// 2. In PASS 2, right after `parent.inner_rect = compute_inner_rect(parent.rect, parent.config)`, // compute hierarchical clipping rectangles: screen_bounds := Rect{x = 0, y = 0, w = ctx.screen_size[0], h = ctx.screen_size[1]} parent_clip := screen_bounds if parent.parent_idx >= 0 &&!parent.out_of_flow { parent_clip = ctx.nodes[parent.parent_idx].inner_clip } parent.node_clip = rect_intersect(parent_clip, parent.rect) parent.inner_clip = rect_intersect(parent.node_clip, parent.inner_rect)

// 3. At the end of end_layout, build ctx.z_order using stable insertion sort: node_count := len(ctx.nodes) ctx.z_order = make([]i32, node_count, ctx.allocator) for i := 0; i < node_count; i += 1 { ctx.z_order[i] = i32(i) } for i := 1; i < node_count; i += 1 { key := ctx.z_order[i] key_z := ctx.nodes[key].effective_z j := i-1 for j >= 0 && ctx.nodes[ctx.z_order[j]].effective_z > key_z { ctx.z_order[j + 1] = ctx.z_order[j] j-= 1 } ctx.z_order[j + 1] = key }

In renderer.odin, set focus_scope = true and capture_input = true inside ui_modal's Box_Config, and let render_layout iterate directly over for idx in ctx.z_order using node.node_clip and node.inner_clip.

## 2. Complete Input, Focus & Hit-Testing Engine (input.odin)

tui_layout) and run odin

|Save this as input.odin in the same directory (package|||test .-vet|-strict-style:|
|---|---|---|---|---|
|package|tui_layout||||
|import|"core:testing"||||
|import|"core:unicode/utf8"||||
|Key_Code|:: enum|u8 {|||
||None,||||
||Tab, Enter, Space, Escape,||||

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 39/95


Building an Actor-Driven Odin TUI

sibling focus_scope containers when not modal-locked

u8]

03/11/2026, 20:42

Up, Down, Left, Right, F6, // Cycles between Rune, }

Mod_Flag :: enum u8 { Shift, Ctrl, Alt, }

Mod_Flags :: bit_set[Mod_Flag;

Key_Event :: struct { code: Key_Code, ch: rune, mods: Mod_Flags, }

Mouse_Action :: enum u8 { Move, Press, Release, Scroll_Up, Scroll_Down, }

Mouse_Button :: enum u8 { Left, Middle, Right, }

Mouse_Event :: struct { x: i32, y: i32, action: Mouse_Action, button: Mouse_Button, mods: Mod_Flags, }

Input_Event :: union { Key_Event, Mouse_Event, }

MAX_FOCUS_HISTORY :: 8

// Persistent across frames Input_State :: struct { focused_id: hovered_id: active_id: activated_id: backdrop_clicked_id: escape_modal_id: active_scope_id: active_capture_id: mouse_pos: mouse_initialized: mouse_down:

(owned by the UI Actor; zero heap allocations)

u64, // Currently focused widget ID hash u64, // Widget currently under the mouse cursor u64, // Widget held down by Left mouse press u64, // Widget triggered this frame (Enter/Space or click release) u64, // Capturing modal ID if user clicked outside its bounds u64, // Capturing modal ID if user pressed Escape u64, // Active focus_scope container ID hash u64, // Topmost capture_input (modal) ID hash (0 if none) [2]i32, bool, bool,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 40/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

focus_history: [MAX_FOCUS_HISTORY]u64, focus_history_len: int, }

Button_Spec :: struct { label: string, width: Axis_Size, height: Axis_Size, border: Border_Kind, fg: Color, bg: Color, hover_bg: Color, focus_fg: Color, focus_bg: Color, }

// Interactive button widget helper ui_button :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, spec: Button_Spec)-> i32 { text_w := i32(utf8.rune_count_in_string(spec.label)) w := spec.width if spec.width!= nil else fit(min = text_w + 4) h := spec.height if spec.height!= nil else fit(min = 1)

fg := spec.fg if spec.fg.kind!=.Default else rgb(220, 220, 230) bg := spec.bg if spec.bg.kind!=.Default else rgb(45, 50, 65)

s.paints[hash_id(id)] = Paint_Spec{ text = spec.label, fg = fg, bg = bg, fill_bg = true, } return leaf(ctx, id, text_w, 1, Box_Config{ dir =.Row, width = w, height = h, border = spec.border, main_align =.Center, cross_align =.Center, focusable = true, })
}

// Query helpers after resolve_input() was_activated :: #force_inline proc(inp: ^Input_State, id: string)-> bool { return inp.activated_id!= 0 && inp.activated_id == hash_id(id) }

is_focused :: #force_inline proc(inp: ^Input_State, id: string)-> bool { return inp.focused_id!= 0 && inp.focused_id == hash_id(id) }

is_hovered :: #force_inline proc(inp: ^Input_State, id: string)-> bool { return inp.hovered_id!= 0 && inp.hovered_id == hash_id(id) }

was_modal_dismissed :: #force_inline proc(inp: ^Input_State, modal_id: string)-> bool { h := hash_id(modal_id) return h!= 0 && (inp.backdrop_clicked_id == h || inp.escape_modal_id == h) }

// Resolves focus scopes, modal input capture, keyboard navigation, and z-ordered mouse hit-testing. // Call right after end_layout(&ctx) and before render_layout(&scr, &ctx). resolve_input :: proc(inp: ^Input_State, ctx: ^Layout_Context, events:..Input_Event) {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 41/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

inp.activated_id = 0
inp.backdrop_clicked_id = 0
inp.escape_modal_id = 0
inp.active_capture_id = 0
if len(ctx.nodes) == 0 {
inp.focused_id = 0
inp.hovered_id = 0
inp.active_id = 0
return
}
// 1. Find topmost active capture_input container (highest effective_z modal)
capture_idx := find_topmost_capture_node(ctx)
if capture_idx >= 0 {
inp.active_capture_id = ctx.nodes[capture_idx].id_hash
}
// 2. Reconcile focused_id with current tree and modal capture boundaries
reconcile_focus(inp, ctx, capture_idx)
// 3. Process incoming keyboard and mouse events
for ev in events {
switch e in ev {
case Key_Event:
handle_key_event(inp, ctx, capture_idx, e)
case Mouse_Event:
handle_mouse_event(inp, ctx, capture_idx, e)
}
}
// 4. Refresh hovered_id against current layout & modal occlusion even when mouse is stationary
if inp.mouse_initialized {
hit_idx, _ := hit_test_point(ctx, capture_idx, inp.mouse_pos[0], inp.mouse_pos[1])
inp.hovered_id = ctx.nodes[hit_idx].id_hash if hit_idx >= 0 else 0
}
}
// Applies visual highlight styling to focused, hovered, and active widgets before render_layout()
apply_input_highlights :: proc(s: ^Screen, ctx: ^Layout_Context, inp: ^Input_State) {
for i := 0; i < len(ctx.nodes); i += 1 {
node := ctx.nodes[i]
if !node.config.focusable {
continue
}
paint, ok := s.paints[node.id_hash]
if !ok {
continue
}
if node.id_hash == inp.focused_id {
paint.style += {.Bold, .Reverse}
if paint.border_fg.kind == .Default {
paint.border_fg = rgb(255, 215, 0)
}
} else if node.id_hash == inp.hovered_id {
paint.style += {.Underline}
}
s.paints[node.id_hash] = paint
}
}
// =============================================================================
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

42/95



03/11/2026, 20:42

Building an Actor-Driven Odin TUI

// Internal Focus & Z-Aware Hit-Testing Implementation
// =============================================================================
find_topmost_capture_node :: proc(ctx: ^Layout_Context) -> i32 {
for i := len(ctx.z_order) - 1; i >= 0; i -= 1 {
idx := ctx.z_order[i]
if ctx.nodes[idx].config.capture_input {
return idx
}
}
return -1
}
is_descendant_or_self :: proc(ctx: ^Layout_Context, node_idx, ancestor_idx: i32) -> bool {
if ancestor_idx < 0 {
return true
}
curr := node_idx
for curr >= 0 {
if curr == ancestor_idx {
return true
}
curr = ctx.nodes[curr].parent_idx
}
return false
}
// A node is reachable only if no capturing modal blocks it
is_node_allowed :: proc(ctx: ^Layout_Context, idx, capture_idx: i32) -> bool {
if idx < 0 || int(idx) >= len(ctx.nodes) {
return false
}
if capture_idx < 0 {
return true
}
cap_z := ctx.nodes[capture_idx].effective_z
node_z := ctx.nodes[idx].effective_z
if node_z > cap_z {
return true
}
if node_z < cap_z {
return false
}
return is_descendant_or_self(ctx, idx, capture_idx)
}
reconcile_focus :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32) {
if inp.focused_id != 0 {
if idx, exists := ctx.id_map[inp.focused_id]; exists {
node := ctx.nodes[idx]
if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) {
inp.active_scope_id = node.scope_id
return
}
// A modal stole focus from a valid widget; save it on the focus history stack
if node.config.focusable {
push_focus_history(inp, inp.focused_id)
}
}
}
// Try restoring a previously focused widget from history (e.g., when a modal closes)
for inp.focus_history_len > 0 {
candidate_id := inp.focus_history[inp.focus_history_len - 1]
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

43/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if idx, exists := ctx.id_map[candidate_id]; exists { node := ctx.nodes[idx] if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) { inp.focus_history_len-= 1 inp.focused_id = candidate_id inp.active_scope_id = node.scope_id return } // Still blocked by an active modal; keep it in history for later break } else { // Node no longer exists; discard stale history entry inp.focus_history_len-= 1 } }

// Pick the first allowed focusable widget (preferring inside capture_idx if active) if capture_idx >= 0 { for i := 0; i < len(ctx.nodes); i += 1 { idx := i32(i) node := ctx.nodes[idx] if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) { inp.focused_id = node.id_hash inp.active_scope_id = node.scope_id return } } }

for i := 0; i < len(ctx.nodes); i += 1 { idx := i32(i) node := ctx.nodes[idx] if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) { inp.focused_id = node.id_hash inp.active_scope_id = node.scope_id return } }

inp.focused_id = 0 inp.active_scope_id = 0 }

push_focus_history :: proc(inp: ^Input_State, id: u64) { if id == 0 { return } if inp.focus_history_len > 0 && inp.focus_history[inp.focus_history_len-1] == id { return } if inp.focus_history_len < MAX_FOCUS_HISTORY { inp.focus_history[inp.focus_history_len] = id inp.focus_history_len += 1 } else { for i := 0; i < MAX_FOCUS_HISTORY-1; i += 1 { inp.focus_history[i] = inp.focus_history[i + 1] } inp.focus_history[MAX_FOCUS_HISTORY-1] = id } }

handle_key_event :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, ev: Key_Event) { switch ev.code { case.Tab:

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 44/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if.Ctrl in ev.mods { cycle_focus_scope(inp, ctx, capture_idx,-1 if.Shift in ev.mods else 1) } else { cycle_focus_within_scope(inp, ctx, capture_idx,-1 if.Shift in ev.mods else 1) } case.F6: cycle_focus_scope(inp, ctx, capture_idx,-1 if.Shift in ev.mods else 1) case.Enter,.Space: if inp.focused_id!= 0 { if idx, ok := ctx.id_map[inp.focused_id]; ok && is_node_allowed(ctx, idx, capture_idx) { inp.activated_id = inp.focused_id } } case.Escape: if capture_idx >= 0 { inp.escape_modal_id = ctx.nodes[capture_idx].id_hash } case.None,.Up,.Down,.Left,.Right,.Rune: } }

cycle_focus_within_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, step: int) { candidates := make([dynamic]i32, 0, 16, ctx.allocator)

for i := 0; i < len(ctx.nodes); i += 1 { idx := i32(i) node := ctx.nodes[idx] if!node.config.focusable ||!is_node_allowed(ctx, idx, capture_idx) { continue } if node.scope_id == inp.active_scope_id { append(&candidates, idx) } }

// Fallback if current scope has no focusable widgets if len(candidates) == 0 { for i := 0; i < len(ctx.nodes); i += 1 { idx := i32(i) node := ctx.nodes[idx] if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) { append(&candidates, idx) } } }

if len(candidates) == 0 { return }

cur_pos :=-1 for idx, pos in candidates { if ctx.nodes[idx].id_hash == inp.focused_id { cur_pos = pos break } }

next_pos := 0 if cur_pos >= 0 { count := len(candidates) next_pos = ((cur_pos + step) % count + count) % count } else if step < 0 { next_pos = len(candidates)-1

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 45/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

}

chosen := ctx.nodes[candidates[next_pos]] inp.focused_id = chosen.id_hash inp.active_scope_id = chosen.scope_id }

cycle_focus_scope :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, step: int) { scopes := make([dynamic]u64, 0, 8, ctx.allocator)

for i := 0; i < len(ctx.nodes); i += 1 { idx := i32(i) node := ctx.nodes[idx] if!node.config.focusable ||!is_node_allowed(ctx, idx, capture_idx) { continue } found := false for s in scopes { if s == node.scope_id { found = true break } } if!found { append(&scopes, node.scope_id) } }

if len(scopes) <= 1 { return }

cur_pos := 0 for s, pos in scopes { if s == inp.active_scope_id { cur_pos = pos break } }

count := len(scopes) next_pos := ((cur_pos + step) % count + count) % count target_scope := scopes[next_pos]

for i := 0; i < len(ctx.nodes); i += 1 { idx := i32(i) node := ctx.nodes[idx] if node.config.focusable && is_node_allowed(ctx, idx, capture_idx) && node.scope_id == target_sco inp.focused_id = node.id_hash inp.active_scope_id = target_scope return } } }

handle_mouse_event :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, ev: Mouse_Event) { inp.mouse_pos = {ev.x, ev.y} inp.mouse_initialized = true

hit_idx, backdrop_modal := hit_test_point(ctx, capture_idx, ev.x, ev.y) inp.hovered_id = ctx.nodes[hit_idx].id_hash if hit_idx >= 0 else 0

switch ev.action { case.Move,.Scroll_Up,.Scroll_Down:

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 46/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

case.Press: if ev.button ==.Left { inp.mouse_down = true if hit_idx >= 0 { node := ctx.nodes[hit_idx] inp.active_id = node.id_hash inp.focused_id = node.id_hash inp.active_scope_id = node.scope_id } else { inp.active_id = 0 if backdrop_modal!= 0 { inp.backdrop_clicked_id = backdrop_modal } } } case.Release: if ev.button ==.Left { inp.mouse_down = false if inp.active_id!= 0 && hit_idx >= 0 && ctx.nodes[hit_idx].id_hash == inp.active_id { inp.activated_id = inp.active_id } inp.active_id = 0 } } }

// Walks ctx.z_order in reverse (highest effective_z first, children before parents). // Returns the hit focusable node index, or the capturing modal ID if the click fell on its backdrop. hit_test_point :: proc( ctx: ^Layout_Context, capture_idx: i32, mx, my: i32, )-> (hit_idx: i32, backdrop_modal_id: u64) { if mx < 0 || mx >= ctx.screen_size[0] || my < 0 || my >= ctx.screen_size[1] { return-1, 0 }

min_allowed_z: u8 = 0 if capture_idx >= 0 { min_allowed_z = ctx.nodes[capture_idx].effective_z }

for i := len(ctx.z_order)-1; i >= 0; i-= 1 { idx := ctx.z_order[i] node := ctx.nodes[idx]

// Stop immediately before reaching layers beneath an active capturing modal if node.effective_z < min_allowed_z { break }

if!is_node_allowed(ctx, idx, capture_idx) { continue }

if!point_in_rect(mx, my, node.node_clip) { continue }

if node.config.focusable { return idx, 0 }

// Solid floating or capturing containers occlude lower layers at (mx, my)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 47/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

// so clicking empty space inside a modal/dropdown never punches through to z_layer = 0
if node.out_of_flow || node.config.capture_input {
return -1, 0
}
}
if capture_idx >= 0 {
return -1, ctx.nodes[capture_idx].id_hash
}
return -1, 0
}
point_in_rect :: #force_inline proc(x, y: i32, r: Rect) -> bool {
return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
build_test_ui :: proc(ctx: ^Layout_Context, scr: ^Screen, show_modal: bool) {
begin_layout(ctx, 60, 20)
begin_frame(scr, rgb(20, 25, 30))
if container(ctx, "root", {dir = .Row, width = grow(1), height = grow(1)}) {
// Sidebar focus scope (x = 0..20)
if container(ctx, "sidebar", {
dir
= .Column,
width
= fixed(20),
height
= grow(1),
border
= .Plain,
gap
= 1,
focus_scope = true,
}) {
ui_button(ctx, scr, "nav_logs", {label = "Logs"})
ui_button(ctx, scr, "nav_metrics", {label = "Metrics"})
// Declare modal inside sidebar when active
if show_modal {
if ui_modal(ctx, scr, "confirm_modal", {
title
= "Confirm Compaction",
z_layer = 20,
width
= fixed(30),
height = fixed(8),
border = .Double,
gap
= 1,
}) {
ui_button(ctx, scr, "modal_yes", {label = "Yes"})
ui_button(ctx, scr, "modal_no", {label = "No"})
}
}
}
// Main panel focus scope (x = 20..60)
if container(ctx, "main_panel", {
dir
= .Column,
width
= grow(1),
height
= grow(1),
border
= .Plain,
focus_scope = true,
}) {
ui_button(ctx, scr, "main_compact_btn", {label = "Compact DB"})
}
}
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

48/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

end_layout(ctx) }

@(test) test_scoped_tab_and_modal_input_capture :: proc(t: ^testing.T) { defer free_all(context.temp_allocator)

scr: Screen err := screen_init(&scr, 60, 20) testing.expect_value(t, err, nil) defer screen_destroy(&scr)

ctx: Layout_Context inp: Input_State

|//---|Frame 1:|Base UI|(No Modal)|---|||||||
|---|---|---|---|---|---|---|---|---|---|---|
|build_test_ui(&ctx,||&scr,|false)||||||||
|resolve_input(&inp,||&ctx)|||||||||
|// Default|focus|starts|at first|focusable|in first|scope ("nav_logs")|||||
|testing.expect(t,||is_focused(&inp,||"nav_logs"),|"Initial|focus|should|be nav_logs")|||
|// Pressing|Tab|cycles to|"nav_metrics",|then|wraps|back to "nav_logs"||(stays|inside sidebar|scope!)|
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.Tab})||||||
|testing.expect(t,||is_focused(&inp,||"nav_metrics"),|"Tab|should|advance|to nav_metrics")|||
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.Tab})||||||
|testing.expect(t,||is_focused(&inp,||"nav_logs"),|"Tab|should wrap|inside|sidebar|focus_scope")||
|// Pressing|F6|jumps to|the sibling|focus_scope|("main_panel"||-> "main_compact_btn")||||
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.F6})||||||
|testing.expect(t,||is_focused(&inp,||"main_compact_btn"),||"F6 should|switch|focus|scope|to main_compact_bt|
|//---|Frame 2:|Modal Opens|(z_layer|= 20,|capture_input|= true)|---||||
|build_test_ui(&ctx,||&scr,|true)||||||||
|resolve_input(&inp,||&ctx)|||||||||
|// Modal|automatically|steals|focus|to "modal_yes"|and|saves "main_compact_btn"|||in focus_history||
|testing.expect(t,||is_focused(&inp,||"modal_yes"),|"Opening|modal|should|trap focus|on modal_yes")||
|testing.expect_value(t,|||inp.focus_history_len,||1)||||||
|// Tab|& Shift+Tab|cycle|strictly|between|"modal_yes"|and "modal_no"|||||
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.Tab})||||||
|testing.expect(t,||is_focused(&inp,||"modal_no"),|"Tab|inside modal|should|focus|modal_no")||
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.Tab})||||||
|testing.expect(t,||is_focused(&inp,||"modal_yes"),|"Tab|inside modal|should|wrap|to modal_yes")||
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.Tab, mods|= {.Shift}})|||||
|testing.expect(t,||is_focused(&inp,||"modal_no"),|"Shift+Tab|should|cycle|backward|to modal_no")||
|// F6|is also blocked|from|escaping|the capturing|modal||||||
|resolve_input(&inp,||&ctx,|Key_Event{code|=|.F6})||||||
|testing.expect(t,||is_focused(&inp,||"modal_no"),|"F6|must not escape|an|active|capturing|modal")|
|//---|Frame 3:|Mouse Click|Outside|Modal|vs Inside|Modal---|||||
|nav_logs_rect,||_ := get_rect(&ctx,||"nav_logs")|||||||
|// Try resolve_input(|clicking|directly|on background|"nav_logs"|button|while|modal is|open|||
||&inp,||||||||||
||&ctx,||||||||||
||Mouse_Event{x|= nav_logs_rect.x||+ 1,|y = nav_logs_rect.y,||action|= .Press,|button|= .Left},|
||Mouse_Event{x|= nav_logs_rect.x||+ 1,|y = nav_logs_rect.y,||action|= .Release,|button|= .Left},|

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 49/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

) testing.expect(t,!was_activated(&inp, "nav_logs"), "Background button must be shielded by active modal" testing.expect(t, was_modal_dismissed(&inp, "confirm_modal"), "Outside click should report backdrop clic

// Now click directly on "modal_yes" inside the modal yes_rect, _ := get_rect(&ctx, "modal_yes") resolve_input( &inp, &ctx, Mouse_Event{x = yes_rect.x + 1, y = yes_rect.y, action =.Press, button =.Left}, Mouse_Event{x = yes_rect.x + 1, y = yes_rect.y, action =.Release, button =.Left}, ) testing.expect(t, was_activated(&inp, "modal_yes"), "Clicking modal_yes should activate it") testing.expect(t, is_focused(&inp, "modal_yes"), "Clicking modal_yes should focus it")

//---Frame 4: Modal Closes-> Focus Automatically Restores to "main_compact_btn"--- build_test_ui(&ctx, &scr, false) resolve_input(&inp, &ctx)

testing.expect(t, is_focused(&inp, "main_compact_btn"), "Closing modal should restore focus to main_comp testing.expect_value(t, inp.focus_history_len, 0) }

## How This Fits Together in the Frame Loop

**Zero-Lag Same-Frame Highlights:** Because resolve_input(&inp, &ctx,..events) and apply_input_highlights(&scr, &ctx, &inp) run *after* end_layout(&ctx) and *before* render_layout(&scr, &ctx), pressing Tab, moving the mouse, or opening a modal highlights the newly focused widget on the exact same frame without a 1-frame delay.

**Automatic Focus Restoration:** Input_State stores a fixed 8-entry focus_history stack ([8]u64). Even if you stack a confirmation modal (z_layer = 30) on top of a settings modal (z_layer = 20) over a base view (z_layer = 0), dismissing each modal pops focus back to the exact button that opened it.

**Click-Outside & Escape Dismissal (was_modal_dismissed):** Clicking anywhere outside the topmost modal's clipped bounds blocks the click from hitting background widgets while setting inp.backdrop_clicked_id (and pressing Escape sets inp.escape_modal_id), letting your UI actor close the modal with a single if was_modal_dismissed(&inp, "confirm_modal") check.

*User prompt: Show how to add scroll offsets and z-aware mouse-wheel scroll routing to containers so virtualized xitdb lists scroll smoothly.*

Response: To make virtualized xitdb lists and scrollable panels work seamlessly with your z_layer modal system, we need four pieces working together:

1. **Zero-Allocation Persistent Scroll_Slot Table (input.odin / scroll.odin):** Input_State stores a fixed 32-slot table of scroll offsets, viewport capacities, and selected row indices keyed by widget ID hash (u64), keeping Input_State completely free of heap allocations.
2. **Z-Ordered Scroll Target Bubbling (hit_test_scrollable):** When a Scroll_Up or Scroll_Down wheel event arrives at (mx, my), the hit-tester walks ctx.z_order from front to back (len-1 down to 0). Once it hits the topmost visible node at (mx, my), it walks up that node's parent_idx chain to find the nearest scrollable container—stopping immediately if it hits an out_of_flow modal boundary or an active capture_input layer so wheel events over a modal never scroll background xitdb tables.
3. **Virtualized Viewport Slicing (ui_virtual_list):** Instead of pushing 500,000 layout nodes for an xitdb LinkedArrayList, ui_virtual_list computes the visible [start_row..< end_row] window from the container's solved inner_rect.h and scroll_offset, so your UI loop only reads and lays out the 15–40 rows currently on screen.
4. **Proportional Scrollbar Rendering (renderer.odin):** Any scrollable container whose total content exceeds its viewport height automatically draws a proportional track (│) and thumb (┃) along its right edge.
## 1. Updates to layout.odin and renderer.odin

In layout.odin, add scrollable, scroll_step, scroll_offset, and virtual_total_rows to Box_Config, and record content_span on Layout_Node during Pass 2:

// Add to Box_Config in layout.odin: scrollable: bool, // Enables mouse-wheel and keyboard scrolling

||scrollable:|bool,|// Enables|mouse-wheel|and|keyboard|scrolling|
|---|---|---|---|---|---|---|---|
|[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…|scroll_step:](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…|scroll_step:) scroll_offset:|i32, i32,|// Wheel // Current|lines per vertical|tick (0 scroll|defaults offset|to 3) in rows/cells|

50/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

virtual_total_rows: i32, // > 0 when children are pre-sliced by ui_virtual_list

// Add to Layout_Node in layout.odin: content_span: [2]i32, // Total [w, h] of children (or virtual_total_rows)

In end_layout (layout.odin), right after step 3 of Pass 2 (total_main_span), record parent.content_span and apply scroll_offset to non-virtual scrollable containers:

// Inside Pass 2 of end_layout, right after computing total_main_span: parent.content_span[main_axis] = total_main_span parent.content_span[cross_axis] = inner_size[cross_axis] if parent.config.virtual_total_rows > 0 { parent.content_span[1] = parent.config.virtual_total_rows }

// 4. Assign screen-space (x, y) coordinates to in-flow children. // Physical scroll containers shift children by-scroll_offset; // virtualized lists already emit only the visible slice at offset 0. scroll_shift: i32 = 0 if parent.config.scrollable && parent.config.virtual_total_rows == 0 && main_axis == 1 { max_scroll := max(0, total_main_span-inner_size[1]) scroll_shift = clamp(parent.config.scroll_offset, 0, max_scroll) }

main_cursor := align_offset(inner_size[main_axis], total_main_span, parent.config.main_align)-s

In renderer.odin, add a call to draw_vertical_scrollbar inside render_layout right after drawing the container's border:

// Inside render_layout in renderer.odin, after drawing node.config.border: if node.config.scrollable && node.content_span[1] > node.inner_rect.h { sb_fg := paint.border_fg if paint.border_fg.kind!=.Default else paint.fg draw_vertical_scrollbar( s, node.rect, node.inner_rect, node_clip, node.config.scroll_offset, node.content_span[1], sb_fg, paint.bg, ) }

## 2. Scroll Routing, Virtualized xitdb Lists & Scrollbar Module (scroll.odin)

Add Page_Up, Page_Down, Home, and End to Key_Code in input.odin (and add scroll_slots: [MAX_SCROLL_SLOTS]Scroll_Slot to Input_State), then drop this scroll.odin file into the same directory (package tui_layout):

package tui_layout

import "core:fmt" import "core:testing"

MAX_SCROLL_SLOTS :: 32

Scroll_Slot :: struct { id_hash: u64, offset: i32, // Top visible row index (or cell offset)

||offset:||i32, //|Top visible|row|index (or|cell offset)|||
|---|---|---|---|---|---|---|---|---|---|
|} Virtual_List_Config|max_offset: viewport_rows: total_rows: selected_row:||i32, // i32, // i32, // i32, // :: struct|Clamped Solved Total Highlighted {|maximum inner_rect.h rows in xitdb cursor|scroll offset from previous/current collection row index|or inside|physical virtual|layout pass content_span lists|

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 51/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

width: Axis_Size, height: Axis_Size, border: Border_Kind, padding: Padding, scroll_step: i32, fallback_rows: i32, // Used on Frame 1 before inner_rect.h is solved (default 10) title: string, fg: Color, bg: Color, border_fg: Color, title_fg: Color, }

Virtual_Slice :: struct { start_row: i32, // Inclusive start index to seek in xitdb LinkedArrayList end_row: i32, // Exclusive end index selected_row: i32, // Currently selected row index total_rows: i32, }

// Looks up or allocates a persistent Scroll_Slot inside Input_State (zero heap allocation) get_scroll_slot :: proc(inp: ^Input_State, id_hash: u64)-> ^Scroll_Slot { empty_idx :=-1 for i := 0; i < MAX_SCROLL_SLOTS; i += 1 { if inp.scroll_slots[i].id_hash == id_hash { return &inp.scroll_slots[i] } if empty_idx ==-1 && inp.scroll_slots[i].id_hash == 0 { empty_idx = i } } idx := empty_idx if empty_idx >= 0 else 0 inp.scroll_slots[idx] = Scroll_Slot{ id_hash = id_hash, viewport_rows = 10, } return &inp.scroll_slots[idx] }

get_scroll_offset :: proc(inp: ^Input_State, id: string)-> i32 { slot := get_scroll_slot(inp, hash_id(id)) return slot.offset }

get_selected_row :: proc(inp: ^Input_State, id: string)-> i32 { slot := get_scroll_slot(inp, hash_id(id)) return slot.selected_row }

// Scoped virtual list container for xitdb collections. // Computes the visible [start_row..< end_row] slice so caller only materializes visible rows. @(deferred_in = defer_end_virtual_list) ui_virtual_list :: proc( ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, total_rows: i32, cfg: Virtual_List_Config, out_slice: ^Virtual_Slice, )-> bool { id_hash := hash_id(id) slot := get_scroll_slot(inp, id_hash)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 52/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

fallback := cfg.fallback_rows if cfg.fallback_rows > 0 else 10 vis_rows := slot.viewport_rows if slot.viewport_rows > 0 else fallback

slot.total_rows = max(0, total_rows) slot.max_offset = max(0, slot.total_rows-vis_rows) slot.offset = clamp(slot.offset, 0, slot.max_offset) slot.selected_row = clamp(slot.selected_row, 0, max(0, slot.total_rows-1))

start := slot.offset end := min(slot.total_rows, start + vis_rows) out_slice^ = Virtual_Slice{ start_row = start, end_row = end, selected_row = slot.selected_row, total_rows = slot.total_rows, }

s.paints[id_hash] = Paint_Spec{ title = cfg.title, fg = cfg.fg, bg = cfg.bg, border_fg = cfg.border_fg, title_fg = cfg.title_fg, title_style = {.Bold}, fill_bg = cfg.bg.kind!=.Default, } w := cfg.width if cfg.width!= nil else grow(1) h := cfg.height if cfg.height!= nil else grow(1) idx := push_node(ctx, id, Box_Config{ dir =.Column, width = w, height = h, padding = cfg.padding, border = cfg.border, focusable = true, scrollable = true, scroll_step = cfg.scroll_step if cfg.scroll_step > 0 else 3, scroll_offset = slot.offset, virtual_total_rows = slot.total_rows, }, {0, 0}) append(&ctx.parent_stack, idx) return true
}

defer_end_virtual_list :: proc( ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, total_rows: i32, cfg: Virtual_List_Config, out_slice: ^Virtual_Slice, ) { if len(ctx.parent_stack) > 0 { pop(&ctx.parent_stack) } }

// Synchronizes solved viewport dimensions from Layout_Context into Input_State.scroll_slots. // Called at the start of resolve_input() right after end_layout(). sync_scroll_viewports :: proc(inp: ^Input_State, ctx: ^Layout_Context) { for i := 0; i < len(ctx.nodes); i += 1 {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 53/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

node := &ctx.nodes[i] if!node.config.scrollable { continue } slot := get_scroll_slot(inp, node.id_hash) slot.viewport_rows = max(1, node.inner_rect.h) slot.total_rows = node.content_span[1] slot.max_offset = max(0, slot.total_rows-slot.viewport_rows) slot.offset = clamp(slot.offset, 0, slot.max_offset) slot.selected_row = clamp(slot.selected_row, 0, max(0, slot.total_rows-1)) node.config.scroll_offset = slot.offset } }

// Walks ctx.z_order front-to-back to find the topmost visible node at (mx, my), // then bubbles up parent_idx to find the nearest enclosing scrollable container. // Respects modal capture_input boundaries and floating overlay occlusion. hit_test_scrollable :: proc(ctx: ^Layout_Context, capture_idx: i32, mx, my: i32)-> i32 { if mx < 0 || mx >= ctx.screen_size[0] || my < 0 || my >= ctx.screen_size[1] { return-1 }

min_allowed_z: u8 = 0 if capture_idx >= 0 { min_allowed_z = ctx.nodes[capture_idx].effective_z }

for i := len(ctx.z_order)-1; i >= 0; i-= 1 { idx := ctx.z_order[i] node := ctx.nodes[idx]

// Stop before reaching z_layers beneath an active capturing modal if node.effective_z < min_allowed_z { break } if!is_node_allowed(ctx, idx, capture_idx) { continue } if!point_in_rect(mx, my, node.node_clip) { continue }

// Bubble up from the hit node to its nearest scrollable ancestor // without crossing out-of-flow overlay boundaries. curr := idx for curr >= 0 { curr_node := ctx.nodes[curr] if!is_node_allowed(ctx, curr, capture_idx) { break } if curr_node.config.scrollable { return curr } if curr_node.out_of_flow || curr_node.config.capture_input { break } curr = curr_node.parent_idx }

// If we hit a non-scrollable floating overlay or modal, stop immediately // so mouse-wheel events never punch through to background lists underneath! if node.out_of_flow || node.config.capture_input { return-1 }

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 54/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

}

return-1 }

// Applies a mouse-wheel delta to the scrollable container under (mx, my) handle_mouse_scroll :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, mx, my: i32, dir: i32, //-1 for Scroll_Up, +1 for Scroll_Down )-> bool { scroll_idx := hit_test_scrollable(ctx, capture_idx, mx, my) if scroll_idx < 0 { return false }

node := &ctx.nodes[scroll_idx] step := node.config.scroll_step if node.config.scroll_step > 0 else 3 apply_scroll_delta(inp, ctx, scroll_idx, dir * step, false) return true }

// Routes Up/Down/Page_Up/Page_Down/Home/End keys to the focused scrollable container handle_key_scroll :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, code: Key_Code, )-> bool { if inp.focused_id == 0 { return false } focus_idx, exists := ctx.id_map[inp.focused_id] if!exists ||!is_node_allowed(ctx, focus_idx, capture_idx) { return false }

// Find focused node or its nearest scrollable ancestor scroll_idx := i32(-1) curr := focus_idx for curr >= 0 { if ctx.nodes[curr].config.scrollable && is_node_allowed(ctx, curr, capture_idx) { scroll_idx = curr break } if ctx.nodes[curr].out_of_flow { break } curr = ctx.nodes[curr].parent_idx }

if scroll_idx < 0 { return false }

node := &ctx.nodes[scroll_idx] slot := get_scroll_slot(inp, node.id_hash) page := max(1, slot.viewport_rows-1) is_virtual := node.config.virtual_total_rows > 0

#partial switch code { case.Up:

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 55/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if is_virtual { move_virtual_selection(slot,-1) node.config.scroll_offset = slot.offset } else { apply_scroll_delta(inp, ctx, scroll_idx,-1, false) } return true case.Down: if is_virtual { move_virtual_selection(slot, +1) node.config.scroll_offset = slot.offset } else { apply_scroll_delta(inp, ctx, scroll_idx, +1, false) } return true case.Page_Up: if is_virtual { move_virtual_selection(slot,-page) node.config.scroll_offset = slot.offset } else { apply_scroll_delta(inp, ctx, scroll_idx,-page, false) } return true case.Page_Down: if is_virtual { move_virtual_selection(slot, +page) node.config.scroll_offset = slot.offset } else { apply_scroll_delta(inp, ctx, scroll_idx, +page, false) } return true case.Home: if is_virtual { slot.selected_row = 0 } apply_scroll_delta(inp, ctx, scroll_idx,-slot.max_offset-1, false) return true case.End: if is_virtual { slot.selected_row = max(0, slot.total_rows-1) } apply_scroll_delta(inp, ctx, scroll_idx, slot.max_offset + 1, false) return true } return false }

move_virtual_selection :: proc(slot: ^Scroll_Slot, delta: i32) { if slot.total_rows <= 0 { return } slot.selected_row = clamp(slot.selected_row + delta, 0, slot.total_rows-1) if slot.selected_row < slot.offset { slot.offset = slot.selected_row } else if slot.selected_row >= slot.offset + slot.viewport_rows { slot.offset = slot.selected_row-slot.viewport_rows + 1 } slot.offset = clamp(slot.offset, 0, slot.max_offset) }

apply_scroll_delta :: proc( inp: ^Input_State, ctx: ^Layout_Context, scroll_idx: i32,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 56/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

delta: i32, move_selection: bool, ) { node := &ctx.nodes[scroll_idx] slot := get_scroll_slot(inp, node.id_hash) old_offset := slot.offset new_offset := clamp(old_offset + delta, 0, slot.max_offset) actual_delta := new_offset-old_offset

slot.offset = new_offset node.config.scroll_offset = new_offset

if move_selection && node.config.virtual_total_rows > 0 { slot.selected_row = clamp(slot.selected_row + delta, 0, max(0, slot.total_rows-1)) }

// For non-virtual physical containers, shift child rects immediately for same-frame rendering if actual_delta!= 0 && node.config.virtual_total_rows == 0 { shift_descendants_y(ctx, scroll_idx,-actual_delta, node.inner_clip) } }

shift_descendants_y :: proc(ctx: ^Layout_Context, parent_idx: i32, dy: i32, clip_root: Rect) { for c := ctx.nodes[parent_idx].first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.out_of_flow { continue } child.rect.y += dy child.inner_rect.y += dy child.node_clip = rect_intersect(clip_root, child.rect) child.inner_clip = rect_intersect(child.node_clip, child.inner_rect) if child.child_count > 0 { shift_descendants_y(ctx, c, dy, child.inner_clip) } } }

// Draws a proportional vertical scrollbar along the right edge of a scrollable box draw_vertical_scrollbar :: proc( s: ^Screen, outer: Rect, inner: Rect, clip: Rect, offset: i32, total_content: i32, fg, bg: Color, ) { track_h := inner.h if track_h <= 0 || total_content <= track_h { return }

// Draw on right border column if bordered, otherwise rightmost inner column sb_x := (outer.x + outer.w-1) if outer.w > inner.w else (inner.x + inner.w-1) track_y := inner.y

thumb_h := max(1, (track_h * track_h) / total_content) max_scroll := max(1, total_content-track_h) clamped_off := clamp(offset, 0, max_scroll) thumb_offset := ((track_h-thumb_h) * clamped_off) / max_scroll

track_cell := Cell{ch ='│', fg = fg, bg = bg, style = {.Dim}, width = 1} thumb_cell := Cell{ch ='┃', fg = fg, bg = bg, style = {.Bold}, width = 1}

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 57/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

for row: i32 = 0; row < track_h; row += 1 { is_thumb := row >= thumb_offset && row < (thumb_offset + thumb_h) set_cell_clipped(s, sb_x, track_y + row, clip, thumb_cell if is_thumb else track_cell) } }

In input.odin, wire sync_scroll_viewports, handle_mouse_scroll, and handle_key_scroll into resolve_input, handle_mouse_event, and handle_key_event:

// 1. Inside resolve_input(), call sync_scroll_viewports right after checking len(ctx.nodes) == 0: sync_scroll_viewports(inp, ctx)

// 2. Inside handle_key_event() switch ev.code: case.Up,.Down,.Page_Up,.Page_Down,.Home,.End: handle_key_scroll(inp, ctx, capture_idx, ev.code)

// 3. Inside handle_mouse_event() switch ev.action: case.Scroll_Up: handle_mouse_scroll(inp, ctx, capture_idx, ev.x, ev.y,-1) case.Scroll_Down: handle_mouse_scroll(inp, ctx, capture_idx, ev.x, ev.y, +1)

## 3. Verification Test Suite: 100,000-Row Virtualized xitdb List + Modal Wheel Blocking

Add this test to scroll.odin and run odin test.-vet-strict-style:

// Simulates reading a record by index from an xitdb LinkedArrayList cursor in O(1)/O(log N) mock_xitdb_read_log :: proc(index: i32, allocator := context.temp_allocator)-> string { return fmt.tprintf("[Moment #%06d] Worker committed transaction slot", index) }

build_virtual_xitdb_ui :: proc( ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State, total_db_rows: i32, show_modal: bool, )-> Virtual_Slice { begin_layout(ctx, 50, 8) begin_frame(scr, rgb(18, 22, 28))

slice: Virtual_Slice if container(ctx, "root", {dir =.Column, width = grow(1), height = grow(1)}) { // Virtualized xitdb list: outer height = 8, Plain border (1+1)-> inner_rect.h = 6 visible rows if ui_virtual_list(ctx, scr, inp, "xitdb_logs", total_db_rows, { title = "xitdb Logs (100k)", border =.Plain, border_fg = rgb(90, 170, 250), scroll_step = 4, fallback_rows = 6, }, &slice) { // Only instantiate layout nodes for the 6 visible rows out of 100,000! for row_idx := slice.start_row; row_idx < slice.end_row; row_idx += 1 { row_id := fmt.tprintf("log_row_%d", row_idx) line := mock_xitdb_read_log(row_idx) fg := rgb(255, 230, 100) if row_idx == slice.selected_row else rgb(190, 200, 210) style := Style_Flags{.Bold,.Reverse} if row_idx == slice.selected_row else Style_Fl ui_label(ctx, scr, row_id, line, fg, style) } }

if show_modal { if ui_modal(ctx, scr, "compact_modal", { title = "Modal Active",

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 58/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

z_layer = 20, width = fixed(26), height = fixed(5), border =.Double, bg = rgb(35, 35, 55), border_fg = rgb(255, 200, 0), backdrop =.Dim_Screen, }) { ui_button(ctx, scr, "modal_ok", {label = "OK"}) } } }

end_layout(ctx) return slice }

@(test) test_virtual_xitdb_scroll_and_modal_wheel_blocking :: proc(t: ^testing.T) { defer free_all(context.temp_allocator)

scr: Screen err := screen_init(&scr, 50, 8) testing.expect_value(t, err, nil) defer screen_destroy(&scr)

ctx: Layout_Context inp: Input_State total_rows :: i32(100_000)

//---Frame 1: Initial Render of 100,000-row xitdb list--- slice1 := build_virtual_xitdb_ui(&ctx, &scr, &inp, total_rows, false) resolve_input(&inp, &ctx) render_layout(&scr, &ctx)

// Verify only 6 visible rows were materialized (1 root + 1 list + 6 row leaves = 8 nodes total!) testing.expect_value(t, slice1.start_row, 0) testing.expect_value(t, slice1.end_row, 6) testing.expect_value(t, len(ctx.nodes), 8)

// Verify scrollbar thumb'┃' is drawn at the top of the right border (x = 49, y = 1) testing.expect_value(t, scr.back[1 * 50 + 49].ch,'┃') testing.expect_value(t, scr.back[6 * 50 + 49].ch,'│')

//---Frame 2: Mouse Wheel Scroll_Down Over Child Label Row (x = 5, y = 2)--- // Wheel event hits "log_row_1" and bubbles up to "xitdb_logs" (scroll_step = 4) resolve_input(&inp, &ctx, Mouse_Event{x = 5, y = 2, action =.Scroll_Down}) slice2 := build_virtual_xitdb_ui(&ctx, &scr, &inp, total_rows, false) resolve_input(&inp, &ctx) render_layout(&scr, &ctx)

testing.expect_value(t, get_scroll_offset(&inp, "xitdb_logs"), 4) testing.expect_value(t, slice2.start_row, 4) testing.expect_value(t, slice2.end_row, 10)

//---Frame 3: Keyboard Page_Down & End Navigation--- resolve_input(&inp, &ctx, Key_Event{code =.End}) slice3 := build_virtual_xitdb_ui(&ctx, &scr, &inp, total_rows, false) resolve_input(&inp, &ctx) render_layout(&scr, &ctx)

// Clamped to 100,000-6 = 99,994, and scrollbar thumb moved to bottom row (x = 49, y = 6) testing.expect_value(t, slice3.start_row, 99_994) testing.expect_value(t, slice3.end_row, 100_000)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 59/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

testing.expect_value(t, slice3.selected_row, 99_999) testing.expect_value(t, scr.back[6 * 50 + 49].ch,'┃')

//---Frame 4: Modal Opens-> Mouse Wheel Over Background List is Blocked--- build_virtual_xitdb_ui(&ctx, &scr, &inp, total_rows, true) resolve_input( &inp, &ctx, Mouse_Event{x = 2, y = 1, action =.Scroll_Up}, // On dimmed backdrop Mouse_Event{x = 25, y = 4, action =.Scroll_Up}, // Inside non-scrollable modal Key_Event{code =.Home}, // Keyboard Home while modal captures input )

// Scroll offset of background xitdb_logs remains locked at 99,994 testing.expect_value(t, get_scroll_offset(&inp, "xitdb_logs"), 99_994) }

## Why This Works So Well with xitdb

*O*(1) **Node Budget Regardless of Dataset Size:** In test_virtual_xitdb_scroll_and_modal_wheel_blocking, a 100,000-record xitdb list generates **only 8 Layout_Nodes** per frame (root, xitdb_logs, and the 6 visible rows), keeping layout and rendering under a few microseconds.

**Automatic Child-to-Container Wheel Bubbling:** Hovering anywhere inside the list—even directly over a child ui_label or badge—bubbles the Scroll_Up/Scroll_Down event up parent_idx to xitdb_logs, while stopping at any out_of_flow or capture_input boundary so modals stay impenetrable.

**Proportional Scrollbars on the Border:** Drawing ┃ and │ directly onto the right border column (outer.x + outer.w-1) costs zero extra layout width while giving immediate feedback on where the viewport sits inside the xitdb collection.

*User prompt: Implement an interactive text input widget in Odin with UTF-8 cursor editing that filters the virtualized xitdb list in real time.*

Response: To add interactive UTF-8 text editing and real-time xitdb filtering without breaking your zero-allocation Input_State design, we can introduce four mechanisms:

1. **Zero-Allocation Text_Input_Slot Table (text_input.odin):** Input_State stores a fixed array of Text_Input_Slot buffers ([256]byte each). Every cursor movement (Left, Right, Ctrl+Left/Right, Home, End, Backspace, Delete, Ctrl+W, and mouse click- to-place) steps strictly along UTF-8 codepoint boundaries and automatically updates a horizontal scroll_col offset when text overflows inner_rect.w.
2. **Same-Frame Screen Synchronization (sync_text_input_paint):** Whenever resolve_input processes keystrokes or mouse clicks on a text input, it immediately re-slices the visible UTF-8 window and updates Screen.paints so the newly typed character and inverted block cursor render on the **exact same frame**.
3. **Telescope-Style List Forwarding (linked_list_id):** Linking a filter input to a ui_virtual_list ID lets users type a query and immediately press Up, Down, Page_Up, or Page_Down to move the selection bar through the filtered xitdb results without leaving the search box, while automatically resetting the list's scroll offset to 0 whenever the query changes.
4. **Moment- & Query-Cached Xitdb_Filter:** When the filter string is empty, Xitdb_Filter performs **zero allocations and zero scans**, mapping virtual list rows directly to xitdb cursor indices in *O*(1) time. When a query is active, it caches matching i32 record indices and only re-scans when the user edits the query or a worker actor commits a new xitdb moment.
## 1. Minimal Hook Additions to layout.odin, input.odin, and renderer.odin

In layout.odin, add text_input: bool to Box_Config:

|// Add|to Box_Config|in layout.odin:||||
|---|---|---|---|---|---|
|In renderer.odin, add has_cursor: node loop:|text_input:|bool, //|Marks node bool and cursor_col:|as an interactive|text input|
|// Add|to Paint_Spec has_cursor: cursor_col:|in renderer.odin: bool, i32,||||

UTF-8

i32 to Paint_Spec, and invert the cursor cell at the end of render_layout's

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 60/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

// Inside render_layout() in renderer.odin, right after drawing paint.text: if paint.has_cursor && inner_clip.w > 0 && inner_clip.h > 0 { cx := node.inner_rect.x + paint.cursor_col cy := node.inner_rect.y + align_offset(node.inner_rect.h, 1, node.config.cross_align) if point_in_rect(cx, cy, inner_clip) && cx >= 0 && cx < s.width && cy >= 0 && cy < s.height c_idx := int(cy * s.width + cx) cur_cell := s.back[c_idx] cur_cell.fg = paint.fg if paint.fg.kind!=.Default else cur_cell.fg cur_cell.style += {.Reverse,.Bold}

s.back[c_idx] = cur_cell
} }

In input.odin, add Backspace and Delete to Key_Code, add text_slots and text_changed_id to Input_State, and route keys/clicks to text inputs when focused:

// 1. Add to Key_Code enum in input.odin: Backspace, Delete,

// 2. Add to Input_State struct in input.odin: text_changed_id: u64, text_slots: [MAX_TEXT_SLOTS]Text_Input_Slot,

// 3. In resolve_input() in input.odin, reset inp.text_changed_id = 0 at the top.

// 4. In handle_key_event() in input.odin, before the switch statement, route keys to focused text inputs: if inp.focused_id!= 0 { if f_idx, ok := ctx.id_map[inp.focused_id]; ok && ctx.nodes[f_idx].config.text_input && is_node_allowed(ctx, f_idx, capture_idx) { if handle_text_input_key(inp, ctx, capture_idx, f_idx, ev) { return } } }

// 5. In handle_mouse_event() in input.odin, inside `.Press:` when `hit_idx >= 0`: if node.config.text_input { handle_text_input_click(inp, node, ev.x) }

// 6. In apply_input_highlights() in input.odin, update text inputs via sync_text_input_paint: if node.config.text_input { sync_text_input_paint(s, inp, node, node.id_hash == inp.focused_id) continue }

## 2. Complete UTF-8 Text Input & Real-Time xitdb Filter Module (text_input.odin)

Save this as text_input.odin in the same package directory (package tui_layout) and run odin test.-vet-strict-style:

package tui_layout

import "core:fmt" import "core:mem" import "core:strings" import "core:testing" import "core:unicode/utf8"

MAX_TEXT_SLOTS :: 16 MAX_TEXT_BYTES :: 256

Text_Input_Slot :: struct { id_hash: u64,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 61/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

linked_list_id: u64, // Optional ui_virtual_list ID hash for arrow-key forwarding & scroll reset buf: [MAX_TEXT_BYTES]byte, byte_len: int, cursor_byte: int, // Always aligned to a valid UTF-8 codepoint boundary in 0..=byte_len scroll_col: i32, // Horizontal scroll offset in runes inner_width: i32, // Solved inner_rect.w from layout placeholder: string, fg: Color, bg: Color, placeholder_fg: Color, border_fg: Color, title: string, }

Text_Input_Config :: struct { width: Axis_Size, height: Axis_Size, border: Border_Kind, padding: Padding, title: string, placeholder: string, linked_list_id: string, // Automatically resets & navigates this virtual list while typing fg: Color, bg: Color, placeholder_fg: Color, border_fg: Color, }

// Persistent or frame-cached filter index connecting a text input to an xitdb collection Xitdb_Filter :: struct { matched_indices: [dynamic]i32, last_moment: i64, last_query_hash: u64, last_total_rows: i32, has_active_query: bool, initialized: bool, }

// Looks up or initializes a persistent Text_Input_Slot inside Input_State get_text_slot :: proc(inp: ^Input_State, id_hash: u64)-> ^Text_Input_Slot { empty_idx :=-1 for i := 0; i < MAX_TEXT_SLOTS; i += 1 { if inp.text_slots[i].id_hash == id_hash { return &inp.text_slots[i] } if empty_idx ==-1 && inp.text_slots[i].id_hash == 0 { empty_idx = i } } idx := empty_idx if empty_idx >= 0 else 0 inp.text_slots[idx] = Text_Input_Slot{ id_hash = id_hash, inner_width = 20, } return &inp.text_slots[idx] }

// Returns the current UTF-8 string inside a text input slot (zero allocation) get_text :: proc(inp: ^Input_State, id: string)-> string { slot := get_text_slot(inp, hash_id(id)) return string(slot.buf[:slot.byte_len]) }

// Programmatically sets the text input value and places the cursor at the end

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 62/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

set_text :: proc(inp: ^Input_State, id: string, value: string) { slot := get_text_slot(inp, hash_id(id)) copy_len := min(len(value), MAX_TEXT_BYTES) // Ensure we don't slice mid-codepoint if truncated at MAX_TEXT_BYTES for copy_len > 0 && copy_len < len(value) && (value[copy_len] & 0xC0) == 0x80 { copy_len-= 1 } copy(slot.buf[:copy_len], transmute([]byte)value[:copy_len]) slot.byte_len = copy_len slot.cursor_byte = copy_len slot.scroll_col = 0 }

was_text_changed :: #force_inline proc(inp: ^Input_State, id: string)-> bool { return inp.text_changed_id!= 0 && inp.text_changed_id == hash_id(id) }

// Declarative UTF-8 text input widget ui_text_input :: proc( ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, cfg: Text_Input_Config = {}, )-> i32 { id_hash := hash_id(id) slot := get_text_slot(inp, id_hash) slot.placeholder = cfg.placeholder slot.title = cfg.title slot.fg = cfg.fg if cfg.fg.kind!=.Default else rgb(235, 240, 245) slot.bg = cfg.bg if cfg.bg.kind!=.Default else rgb(28, 34, 44) slot.placeholder_fg = cfg.placeholder_fg if cfg.placeholder_fg.kind!=.Default else rgb(110, 120, 135) slot.border_fg = cfg.border_fg if cfg.border_fg.kind!=.Default else rgb(85, 115, 150) slot.linked_list_id = hash_id(cfg.linked_list_id) if len(cfg.linked_list_id) > 0 else 0

w := cfg.width if cfg.width!= nil else grow(1) border_extra: i32 = 2 if cfg.border!=.None else 0 h := cfg.height if cfg.height!= nil else fixed(1 + border_extra + cfg.padding.top + cfg.padding.bottom)

idx := leaf(ctx, id, slot.inner_width, 1, Box_Config{ dir =.Row, width = w, height = h, border = cfg.border, padding = cfg.padding, main_align =.Start, cross_align =.Center, focusable = true, text_input = true, })

sync_text_input_paint(s, inp, ctx.nodes[idx], inp.focused_id == id_hash) return idx }

// Synchronizes horizontal scroll_col, visible UTF-8 slice, and cursor cell into Screen.paints sync_text_input_paint :: proc( s: ^Screen, inp: ^Input_State, node: Layout_Node, focused: bool, ) { slot := get_text_slot(inp, node.id_hash) if node.inner_rect.w > 0 {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 63/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

slot.inner_width = node.inner_rect.w } vis_w := max(1, slot.inner_width)

raw_str := string(slot.buf[:slot.byte_len]) total_runes := i32(utf8.rune_count_in_string(raw_str)) cursor_rune := i32(utf8.rune_count_in_bytes(slot.buf[:slot.cursor_byte]))

// Keep cursor within [scroll_col, scroll_col + vis_w-1] if cursor_rune < slot.scroll_col { slot.scroll_col = cursor_rune } else if cursor_rune >= slot.scroll_col + vis_w { slot.scroll_col = cursor_rune-vis_w + 1 } max_scroll := max(0, (total_runes + 1)-vis_w) slot.scroll_col = clamp(slot.scroll_col, 0, max_scroll)

border_color := rgb(255, 215, 0) if focused else slot.border_fg

if slot.byte_len == 0 && len(slot.placeholder) > 0 { vis_placeholder := slice_utf8_by_runes(slot.placeholder, 0, vis_w)

s.paints[node.id_hash] = Paint_Spec{ title = slot.title, text = vis_placeholder, fg = slot.placeholder_fg, bg = slot.bg, border_fg = border_color, title_fg = border_color, style = {.Dim}, title_style = {.Bold}, fill_bg = true, has_cursor = focused, cursor_col = 0, } return
}

vis_text := slice_utf8_by_runes(raw_str, slot.scroll_col, vis_w)

s.paints[node.id_hash] = Paint_Spec{ title = slot.title, text = vis_text, fg = slot.fg, bg = slot.bg, border_fg = border_color, title_fg = border_color, title_style = {.Bold}, fill_bg = true, has_cursor = focused, cursor_col = clamp(cursor_rune-slot.scroll_col, 0, vis_w-1), }
}

// Extracts up to `max_runes` UTF-8 codepoints starting at `start_rune` (zero allocation) slice_utf8_by_runes :: proc(str: string, start_rune, max_runes: i32)-> string { if max_runes <= 0 || len(str) == 0 { return "" } start_byte := len(str) end_byte := len(str) rune_idx: i32 = 0

for byte_offset := 0; byte_offset < len(str); { if rune_idx == start_rune { start_byte = byte_offset

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 64/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

}
if rune_idx == start_rune + max_runes {
end_byte = byte_offset
break
}
_, w := utf8.decode_rune_in_string(str[byte_offset:])
byte_offset += max(w, 1)
rune_idx += 1
}
if start_byte >= len(str) {
return ""
}
return str[start_byte:end_byte]
}
// =============================================================================
// UTF-8 Cursor Editing & Event Handlers
// =============================================================================
handle_text_input_key :: proc(
inp: ^Input_State,
ctx: ^Layout_Context,
capture_idx: i32,
node_idx: i32,
ev: Key_Event,
) -> bool {
node := ctx.nodes[node_idx]
slot := get_text_slot(inp, node.id_hash)
if node.inner_rect.w > 0 {
slot.inner_width = node.inner_rect.w
}
#partial switch ev.code {
case .Left:
if .Ctrl in ev.mods || .Alt in ev.mods {
slot.cursor_byte = prev_word_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte)
} else {
slot.cursor_byte = prev_rune_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte)
}
return true
case .Right:
if .Ctrl in ev.mods || .Alt in ev.mods {
slot.cursor_byte = next_word_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte)
} else {
slot.cursor_byte = next_rune_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte)
}
return true
case .Home:
slot.cursor_byte = 0
return true
case .End:
slot.cursor_byte = slot.byte_len
return true
case .Backspace:
if slot.cursor_byte > 0 {
target := prev_word_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte) if (.Ctrl in ev
delete_byte_range(slot, target, slot.cursor_byte)
mark_text_modified(inp, slot)
}
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

65/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

return true

case.Delete: if slot.cursor_byte < slot.byte_len { target := next_word_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte) if (.Ctrl in ev delete_byte_range(slot, slot.cursor_byte, target) mark_text_modified(inp, slot) } return true

case.Space: if insert_utf8_rune(slot,'') { mark_text_modified(inp, slot) } return true

case.Rune: if.Ctrl in ev.mods { switch ev.ch { case'a','A': slot.cursor_byte = 0 return true case'e','E': slot.cursor_byte = slot.byte_len return true case'w','W': if slot.cursor_byte > 0 { target := prev_word_byte_offset(slot.buf[:slot.byte_len], slot.cursor_byte) delete_byte_range(slot, target, slot.cursor_byte) mark_text_modified(inp, slot) } return true case'u','U': if slot.cursor_byte > 0 { delete_byte_range(slot, 0, slot.cursor_byte) mark_text_modified(inp, slot) } return true case'k','K': if slot.cursor_byte < slot.byte_len { slot.byte_len = slot.cursor_byte mark_text_modified(inp, slot) } return true } return false } if ev.ch >='' && insert_utf8_rune(slot, ev.ch) { mark_text_modified(inp, slot) } return true

case.Up,.Down,.Page_Up,.Page_Down: // Telescope-style forwarding: navigate the linked virtual list while typing in the filter box! if slot.linked_list_id!= 0 { if list_idx, ok := ctx.id_map[slot.linked_list_id]; ok && is_node_allowed(ctx, list_idx, ca saved_focus := inp.focused_id inp.focused_id = slot.linked_list_id handle_key_scroll(inp, ctx, capture_idx, ev.code) inp.focused_id = saved_focus return true } } return false

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 66/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

}

return false }

// Places the UTF-8 cursor on the clicked character column inside the text input handle_text_input_click :: proc(inp: ^Input_State, node: Layout_Node, mx: i32) { slot := get_text_slot(inp, node.id_hash) if node.inner_rect.w > 0 { slot.inner_width = node.inner_rect.w } rel_col := max(0, mx-node.inner_rect.x) target_rune := slot.scroll_col + rel_col

byte_pos := 0 cur_rune: i32 = 0 for byte_pos < slot.byte_len && cur_rune < target_rune { _, w := utf8.decode_rune_in_bytes(slot.buf[byte_pos:slot.byte_len]) byte_pos += max(w, 1) cur_rune += 1 } slot.cursor_byte = byte_pos }

mark_text_modified :: proc(inp: ^Input_State, slot: ^Text_Input_Slot) { inp.text_changed_id = slot.id_hash // Automatically reset linked virtual list selection & scroll offset to top on filter edit if slot.linked_list_id!= 0 { scroll_slot := get_scroll_slot(inp, slot.linked_list_id) scroll_slot.offset = 0 scroll_slot.selected_row = 0 } }

insert_utf8_rune :: proc(slot: ^Text_Input_Slot, ch: rune)-> bool { encoded, w := utf8.encode_rune(ch) if w <= 0 || slot.byte_len + w > MAX_TEXT_BYTES { return false } if slot.cursor_byte < slot.byte_len { copy( slot.buf[slot.cursor_byte + w : slot.byte_len + w], slot.buf[slot.cursor_byte : slot.byte_len], ) } copy(slot.buf[slot.cursor_byte : slot.cursor_byte + w], encoded[:w]) slot.cursor_byte += w slot.byte_len += w return true }

delete_byte_range :: proc(slot: ^Text_Input_Slot, start_byte, end_byte: int) { start := clamp(start_byte, 0, slot.byte_len) end := clamp(end_byte, start, slot.byte_len) removed := end-start if removed <= 0 { return } if end < slot.byte_len { copy(slot.buf[start : slot.byte_len-removed], slot.buf[end : slot.byte_len]) } slot.byte_len-= removed slot.cursor_byte = start }

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 67/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

prev_rune_byte_offset :: proc(buf: []byte, pos: int) -> int {
if pos <= 0 {
return 0
}
i := min(pos, len(buf)) - 1
for i > 0 && (buf[i] & 0xC0) == 0x80 {
i -= 1
}
return i
}
next_rune_byte_offset :: proc(buf: []byte, pos: int) -> int {
if pos >= len(buf) {
return len(buf)
}
_, w := utf8.decode_rune_in_bytes(buf[pos:])
return min(len(buf), pos + max(w, 1))
}
prev_word_byte_offset :: proc(buf: []byte, pos: int) -> int {
curr := pos
for curr > 0 {
prev := prev_rune_byte_offset(buf, curr)
r, _ := utf8.decode_rune_in_bytes(buf[prev:curr])
if r != ' ' && r != '\t' {
break
}
curr = prev
}
for curr > 0 {
prev := prev_rune_byte_offset(buf, curr)
r, _ := utf8.decode_rune_in_bytes(buf[prev:curr])
if r == ' ' || r == '\t' {
break
}
curr = prev
}
return curr
}
next_word_byte_offset :: proc(buf: []byte, pos: int) -> int {
curr := pos
for curr < len(buf) {
r, w := utf8.decode_rune_in_bytes(buf[curr:])
if r != ' ' && r != '\t' {
break
}
curr += max(w, 1)
}
for curr < len(buf) {
r, w := utf8.decode_rune_in_bytes(buf[curr:])
if r == ' ' || r == '\t' {
break
}
curr += max(w, 1)
}
return curr
}
// =============================================================================
// Real-Time xitdb Virtual List Filter Helper
// =============================================================================

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

68/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

xitdb_filter_init :: proc(f: ^Xitdb_Filter, allocator := context.allocator) {

f.matched_indices = make([dynamic]i32, 0, 256, allocator)
f.last_moment =-1
f.initialized = true
}

xitdb_filter_destroy :: proc(f: ^Xitdb_Filter) { delete(f.matched_indices) f^ = {} }

// Updates the filtered index table only when the query string or xitdb moment changes. // Returns the filtered row count to pass directly into `ui_virtual_list`. xitdb_filter_update :: proc( f: ^Xitdb_Filter, inp: ^Input_State, input_id: string, list_id: string, moment_slot: i64, total_db_rows: i32, read_record: proc(db_row: i32, temp_alloc: mem.Allocator)-> string, )-> i32 { if!f.initialized { xitdb_filter_init(f) }

query := get_text(inp, input_id) q_hash := hash_id(query)

if f.last_moment == moment_slot && f.last_query_hash == q_hash && f.last_total_rows == total_db_rows { return i32(len(f.matched_indices)) if f.has_active_query else total_db_rows }

// Query or moment changed: reset linked virtual list scroll offset if query changed if f.last_query_hash!= q_hash && len(list_id) > 0 { scroll_slot := get_scroll_slot(inp, hash_id(list_id)) scroll_slot.offset = 0 scroll_slot.selected_row = 0 }

f.last_moment = moment_slot
f.last_query_hash = q_hash
f.last_total_rows = total_db_rows clear(&f.matched_indices) if len(query) == 0 {
f.has_active_query = false return total_db_rows
}

f.has_active_query = true for row: i32 = 0; row < total_db_rows; row += 1 { line := read_record(row, context.temp_allocator) if contains_case_insensitive(line, query) {
append(&f.matched_indices, row) } }

return i32(len(f.matched_indices)) }

// Maps a visible virtual list row [0..< filtered_count] back to its real xitdb index xitdb_filter_map_row :: #force_inline proc(f: ^Xitdb_Filter, virtual_row: i32)-> i32 { if!f.has_active_query {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 69/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

return virtual_row
}
if virtual_row < 0 || int(virtual_row) >= len(f.matched_indices) {
return -1
}
return f.matched_indices[virtual_row]
}
// Zero-allocation ASCII case-insensitive substring matcher
contains_case_insensitive :: proc(haystack, needle: string) -> bool {
n_len := len(needle)
h_len := len(haystack)
if n_len == 0 {
return true
}
if n_len > h_len {
return false
}
limit := h_len - n_len
for i := 0; i <= limit; i += 1 {
matched := true
for j := 0; j < n_len; j += 1 {
hc := haystack[i + j]
nc := needle[j]
if hc >= 'A' && hc <= 'Z' {
hc += 32
}
if nc >= 'A' && nc <= 'Z' {
nc += 32
}
if hc != nc {
matched = false
break
}
}
if matched {
return true
}
}
return false
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
mock_xitdb_log_entry :: proc(db_row: i32, alloc := context.temp_allocator) -> string {
switch db_row % 4 {
case 0:
return fmt.tprintf("INFO [actor-%d] Heartbeat OK", db_row, allocator = alloc)
case 1:
return fmt.tprintf("WARN [actor-%d] High mailbox latency", db_row, allocator = alloc)
case 2:
return fmt.tprintf("ERROR [actor-%d] λ-worker crashed on slot", db_row, allocator = alloc)
case 3:
return fmt.tprintf("DEBUG [actor-%d] xitdb snapshot committed", db_row, allocator = alloc)
}
return ""
}
build_filterable_xitdb_ui :: proc(
ctx: ^Layout_Context,
scr: ^Screen,
inp: ^Input_State,
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

70/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

filter: ^Xitdb_Filter, moment_slot: i64, total_db_rows: i32, show_modal: bool, )-> (slice: Virtual_Slice, filtered_total: i32) { begin_layout(ctx, 48, 10) begin_frame(scr, rgb(16, 20, 26))

filtered_total = xitdb_filter_update( filter, inp, "search_box", "xitdb_logs", moment_slot, total_db_rows, mock_xitdb_log_entry, )

if container(ctx, "root", {dir =.Column, width = grow(1), height = grow(1)}) { // 1. Interactive UTF-8 search input (width = 20 outer-> 18 inner cells) ui_text_input(ctx, scr, inp, "search_box", { width = fixed(20), height = fixed(3), border =.Rounded, title = "Filter", placeholder = "Search logs...", linked_list_id = "xitdb_logs", })

// 2. Virtualized xitdb list showing only matching records (height = 7 outer-> 5 inner rows) if ui_virtual_list(ctx, scr, inp, "xitdb_logs", filtered_total, { title = "Logs", border =.Plain, fallback_rows = 5, }, &slice) { for v_row := slice.start_row; v_row < slice.end_row; v_row += 1 { real_db_idx := xitdb_filter_map_row(filter, v_row) row_id := fmt.tprintf("row_%d", v_row) line := mock_xitdb_log_entry(real_db_idx) fg := rgb(255, 220, 90) if v_row == slice.selected_row else rgb(190, 200, 210) ui_label(ctx, scr, row_id, line, fg) } }

if show_modal { if ui_modal(ctx, scr, "lock_modal", { title = "Locked", z_layer = 20, width = fixed(24), height = fixed(5), border =.Double, }) { ui_button(ctx, scr, "modal_close", {label = "Close"}) } } }

end_layout(ctx) return slice, filtered_total }

@(test) test_utf8_text_input_and_realtime_xitdb_filtering :: proc(t: ^testing.T) { defer free_all(context.temp_allocator)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 71/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

scr: Screen err := screen_init(&scr, 48, 10) testing.expect_value(t, err, nil) defer screen_destroy(&scr)

filter: Xitdb_Filter xitdb_filter_init(&filter) defer xitdb_filter_destroy(&filter)

ctx: Layout_Context inp: Input_State total_rows :: i32(1_000) // 250 INFO, 250 WARN, 250 ERROR (with'λ'), 250 DEBUG

//---Frame 1: Empty Filter-> All 1,000 xitdb Rows Available, Placeholder Shown--- slice1, count1 := build_filterable_xitdb_ui(&ctx, &scr, &inp, &filter, 1, total_rows, false) resolve_input(&inp, &ctx) apply_input_highlights(&scr, &ctx, &inp) render_layout(&scr, &ctx)

testing.expect_value(t, count1, 1_000) testing.expect_value(t, slice1.start_row, 0) testing.expect_value(t, slice1.end_row, 5) testing.expect(t, is_focused(&inp, "search_box"), "search_box should be focused initially")

// Verify inverted block cursor at inner_rect (x=1, y=1) on empty placeholder testing.expect(t,.Reverse in scr.back[1 * 48 + 1].style, "Focused search_box should render block cursor

//---Frame 2: Type Multi-Byte UTF-8 Query "error [actor" + Backspace + "λ"--- // Let's type "λ-worker" using multi-byte UTF-8 rune'λ' (2 bytes: 0xCE 0xBB) + mistake'x' + Backspace resolve_input( &inp, &ctx, Key_Event{code =.Rune, ch ='λ'}, Key_Event{code =.Rune, ch ='-'}, Key_Event{code =.Rune, ch ='w'}, Key_Event{code =.Rune, ch ='x'}, Key_Event{code =.Backspace}, Key_Event{code =.Rune, ch ='o'}, Key_Event{code =.Rune, ch ='r'}, Key_Event{code =.Rune, ch ='k'}, ) testing.expect_value(t, get_text(&inp, "search_box"), "λ-work") testing.expect(t, was_text_changed(&inp, "search_box"), "Typing should flag search_box as changed")

// Rebuild UI with new filter: only every 4th record (250 out of 1,000) matches "λ-work"! slice2, count2 := build_filterable_xitdb_ui(&ctx, &scr, &inp, &filter, 1, total_rows, false) resolve_input(&inp, &ctx) apply_input_highlights(&scr, &ctx, &inp) render_layout(&scr, &ctx)

testing.expect_value(t, count2, 250) testing.expect_value(t, xitdb_filter_map_row(&filter, 0), 2) // First matching DB record is row #2 testing.expect_value(t, xitdb_filter_map_row(&filter, 1), 6) // Second matching DB record is row #6 testing.expect_value(t, slice2.selected_row, 0)

// Verify'λ' rendered at inner (x=1, y=1) and cursor moved to rune index 6-> inner x = 1 + 6 = 7 testing.expect_value(t, scr.back[1 * 48 + 1].ch,'λ') testing.expect(t,.Reverse in scr.back[1 * 48 + 7].style, "Block cursor should advance to rune col 6")

//---Frame 3: Telescope-Style Down Arrow While Still Focused in search_box--- resolve_input(&inp, &ctx, Key_Event{code =.Down}, Key_Event{code =.Down}) testing.expect(t, is_focused(&inp, "search_box"), "Focus stays inside search_box") testing.expect_value(t, get_selected_row(&inp, "xitdb_logs"), 2)

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id… 72/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

//---Frame 4: Left Arrow Across Multi-Byte'λ' & Insert Mode--- // Move to Home, step Right once (over 2-byte'λ'), and verify cursor_byte == 2 resolve_input(&inp, &ctx, Key_Event{code =.Home}, Key_Event{code =.Right}) slot := get_text_slot(&inp, hash_id("search_box")) testing.expect_value(t, slot.cursor_byte, 2) //'λ' is 2 bytes in UTF-8!

//---Frame 5: Horizontal Scrolling on Long Input & Modal Input Capture--- set_text(&inp, "search_box", "0123456789ABCDEFGHIJKLMN") // 24 runes inside an 18-col inner box build_filterable_xitdb_ui(&ctx, &scr, &inp, &filter, 1, total_rows, false) resolve_input(&inp, &ctx) apply_input_highlights(&scr, &ctx, &inp) render_layout(&scr, &ctx)

// Cursor is at rune 24 inside 18-cell inner width-> scroll_col = 24-18 + 1 = 7 ('7' at x=1, y=1) testing.expect_value(t, slot.scroll_col, 7) testing.expect_value(t, scr.back[1 * 48 + 1].ch,'7')

// Open modal: typing'Z' or Backspace is blocked from reaching background search_box build_filterable_xitdb_ui(&ctx, &scr, &inp, &filter, 1, total_rows, true) resolve_input( &inp, &ctx, Key_Event{code =.Rune, ch ='Z'}, Key_Event{code =.Backspace}, ) testing.expect_value(t, get_text(&inp, "search_box"), "0123456789ABCDEFGHIJKLMN") }

## Why This Design Works So Smoothly

**Byte-Exact UTF-8 Cursor Alignment:** Because Odin strings are UTF-8 byte slices while terminal columns count decoded runes, Text_Input_Slot stores cursor_byte for *O*(1) slice mutation (slot.buf[:slot.cursor_byte]) and converts to cursor_rune := utf8.rune_count_in_bytes(slot.buf[:slot.cursor_byte]) when computing scroll_col and the visual block cursor position. Stepping left or right over a 2-byte 'λ' or 4-byte emoji moves cursor_byte by the exact UTF-8 sequence width.

**Telescope / fzf Ergonomics (linked_list_id):** Setting linked_list_id = "xitdb_logs" on ui_text_input means the user never has to press Tab to switch between typing a filter and selecting a log line: typing updates the query and resets xitdb_logs to row 0, while Up/Down/Page_Up/Page_Down move the selection bar directly through the filtered xitdb view.

**Zero-Work Idle Frames (xitdb_filter_update):** By comparing (moment_slot, q_hash, total_db_rows), the filter skips scanning altogether on frames where neither the xitdb snapshot nor the filter text changed.

*User prompt: Implement interactive mouse-dragged and keyboard-driven split-pane dividers and a global keybinding router in Odin.*

Response: To add **interactive split-pane dividers** (both mouse-dragged and keyboard-driven) and a **global/scoped keybinding router** that respects z_layer modals and focused ui_text_input widgets, we can extend the engine with four mechanisms:

1. **Zero-Allocation Splitter_Slot State & Same-Frame Geometry Adjustment (splitter_keymap.odin):** Input_State stores a fixed table of Splitter_Slot records. Dragging a 1-cell divider with the mouse (even when the cursor moves off the 1-cell bar mid-drag) or nudging it via keyboard updates slot.size and immediately adjusts the adjacent sibling Rects and clip bounds on the **same frame**.
2. **Visual Divider Feedback (│ / ┃ and ─ / ━):** Idle splitters draw thin box-drawing lines (│ for .Row splits, ─ for .Column splits) and automatically upgrade to heavy, highlighted bars (┃ / ━) when hovered, focused, or actively dragged.
3. **Text-Input Shielding in the Keybinding Router:** Unmodified single-key shortcuts (like 'q' to quit or 'c' to compact xitdb) are automatically suppressed when a ui_text_input is focused so the user can type freely, while bindings marked with .Allow_In_Text_Input (like Ctrl+P, Ctrl+Left, or Ctrl+Right) execute without stealing focus from the text box.
4. **Three-Tier Modal & Scope Routing (Key_Scope_Policy):** Keybindings declare .Root_And_Scopes (blocked when a capture_input modal is open), .Scope_Only (active only inside a specific focus_scope or modal ID like 'y'/'n' inside "confirm_modal"), or .Global_Always (active even above modals, such as Ctrl+Q).
## 1. Hook Additions to layout.odin, renderer.odin, and input.odin

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 73/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

In layout.odin, add splitter: bool to Box_Config:

// Add to Box_Config in layout.odin: splitter: bool, // Marks node as a 1-cell interactive split-pane divider

In renderer.odin, add fill_char: rune to Paint_Spec and pass it to fill_rect inside render_layout:

// Add to Paint_Spec in renderer.odin: fill_char: rune, // Optional glyph used by fill_rect (e.g.,'│','┃','─','━')

// Inside render_layout() in renderer.odin, replace the fill_rect check with: if paint.fill_bg || paint.bg.kind!=.Default || paint.fill_char!= 0 { ch := paint.fill_char if paint.fill_char!= 0 else'' fill_rect(s, node.rect, node_clip, ch, paint.fg, paint.bg, paint.style) }

In input.odin, add the splitter and keymap fields to Input_State and wire their hooks into resolve_input, handle_key_event, handle_mouse_event, and apply_input_highlights:

// 1. Add to Input_State in input.odin: active_splitter_id: u64, splitter_slots: [MAX_SPLITTER_SLOTS]Splitter_Slot, keybindings: [MAX_KEYBINDINGS]Keybinding, keybinding_count: int, triggered_action_id: u64, triggered_action_name: string,

// 2. Inside resolve_input() in input.odin: // Reset triggered_action_id = 0 and triggered_action_name = "" at the top, // and call sync_splitters(inp, ctx) right after sync_scroll_viewports(inp, ctx): inp.triggered_action_id = 0 inp.triggered_action_name = "" sync_scroll_viewports(inp, ctx) sync_splitters(inp, ctx, capture_idx)

// 3. Inside handle_key_event() in input.odin, place at the very top of the procedure: in_text_input := false f_idx := i32(-1) if inp.focused_id!= 0 { if idx, ok := ctx.id_map[inp.focused_id]; ok && is_node_allowed(ctx, idx, capture_idx) { f_idx = idx in_text_input = ctx.nodes[idx].config.text_input } }

// Step A: Check registered global & scoped keybindings (respecting text-input shield & modal capture) if dispatch_keybindings(inp, ctx, capture_idx, ev, in_text_input) { return }

// Step B: Route typing/editing keys to focused text input if in_text_input && handle_text_input_key(inp, ctx, capture_idx, f_idx, ev) { return }

// Step C: Route arrow/reset keys when a splitter divider itself is focused if f_idx >= 0 && ctx.nodes[f_idx].config.splitter { if handle_splitter_key(inp, ctx, capture_idx, f_idx, ev) { return } }

// 4. Inside handle_mouse_event() in input.odin: //-In `.Move:`: if inp.mouse_down && inp.active_splitter_id!= 0 {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 74/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

handle_splitter_drag(inp, ctx, capture_idx, ev.x, ev.y)
return
//

//
//

}
- In `.Press:` (when `ev.button == .Left` and `hit_idx >= 0`):
if node.config.splitter {
begin_splitter_drag(inp, node, ev.x, ev.y)
}
- In `.Press:` (when `ev.button == .Middle` and `hit_idx >= 0 && ctx.nodes[hit_idx].config.splitter`):
reset_splitter_to_default(inp, ctx, hit_idx)
- In `.Release:` (when `ev.button == .Left`):
inp.active_splitter_id = 0

// 5. Inside apply_input_highlights() in input.odin, before standard focusable styling:
if node.config.splitter {
sync_splitter_paint(s, inp, node)
continue
}

2. Complete Split-Pane Divider & Keybinding Router Module (splitter_keymap.odin)
Save this as splitter_keymap.odin in the same package directory (package tui_layout) and run odin test . -vet -strict-style:
package tui_layout
import "core:testing"
MAX_SPLITTER_SLOTS :: 16
MAX_KEYBINDINGS
:: 64
// =============================================================================
// Interactive Split-Pane Divider State & Widget API
// =============================================================================
Splitter_Slot :: struct {
id_hash:
u64,
dir:
Direction, // .Row = vertical bar splitting left/right; .Column = horizontal bar split
size:
i32,
// Controlled primary pane size in terminal cells
default_size:
i32,
min_size:
i32,
max_size:
i32,
effective_max:
i32,
// Clamped against parent inner_rect so second pane never collapses
step:
i32,
// Keyboard resize step in cells
drag_start_mouse: i32,
drag_start_size: i32,
fg:
Color,
bg:
Color,
active_fg:
Color,
initialized:
bool,
}
Splitter_Config :: struct {
dir:
Direction, // .Row (left/right split) or .Column (top/bottom split)
default_size:
i32,
min_size:
i32,
max_size:
i32,
// 0 = auto-clamped to parent inner size minus min_second_size
min_second_size: i32,
// Minimum cells reserved for the second pane (default 4)
step:
i32,
// Keyboard step per press (default 2)
fg:
Color,
bg:
Color,
active_fg:
Color,
}
// Looks up or initializes a persistent Splitter_Slot inside Input_State
get_splitter_slot :: proc(inp: ^Input_State, id_hash: u64) -> ^Splitter_Slot {

https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

75/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

empty_idx :=-1 for i := 0; i < MAX_SPLITTER_SLOTS; i += 1 { if inp.splitter_slots[i].id_hash == id_hash { return &inp.splitter_slots[i] } if empty_idx ==-1 && inp.splitter_slots[i].id_hash == 0 { empty_idx = i } } idx := empty_idx if empty_idx >= 0 else 0 inp.splitter_slots[idx] = Splitter_Slot{ id_hash = id_hash, } return &inp.splitter_slots[idx] }

// Returns the current controlled pane size in cells so the preceding container can pass `fixed(size)` get_split_size :: proc( inp: ^Input_State, id: string, default_size: i32 = 24, min_size: i32 = 8, max_size: i32 = 0, )-> i32 { slot := get_splitter_slot(inp, hash_id(id)) if!slot.initialized { slot.default_size = max(default_size, min_size) slot.min_size = max(1, min_size) slot.max_size = max_size slot.effective_max = max_size if max_size > 0 else 9999 slot.size = slot.default_size slot.step = 2 slot.initialized = true } return slot.size }

// Places a 1-cell interactive divider bar between two panes inside a Row or Column container ui_splitter :: proc( ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, cfg: Splitter_Config = {}, )-> i32 { id_hash := hash_id(id) slot := get_splitter_slot(inp, id_hash)

min_sz := max(1, cfg.min_size if cfg.min_size > 0 else 8) def_sz := max(min_sz, cfg.default_size if cfg.default_size > 0 else 24)

if!slot.initialized { slot.size = def_sz slot.effective_max = cfg.max_size if cfg.max_size > 0 else 9999 slot.initialized = true }

slot.dir = cfg.dir slot.default_size = def_sz slot.min_size = min_sz slot.max_size = cfg.max_size slot.step = cfg.step if cfg.step > 0 else 2 slot.fg = cfg.fg if cfg.fg.kind!=.Default else rgb(90, 110, 135) slot.bg = cfg.bg

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 76/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

slot.active_fg = cfg.active_fg if cfg.active_fg.kind!=.Default else rgb(255, 215, 0) slot.size = clamp_bounds(slot.size, slot.min_size, slot.max_size)

w: Axis_Size = fixed(1) if cfg.dir ==.Row else grow(1) h: Axis_Size = grow(1) if cfg.dir ==.Row else fixed(1)

idx := leaf(ctx, id, 1, 1, Box_Config{ dir = cfg.dir, width = w, height = h, focusable = true, splitter = true, })

sync_splitter_paint(s, inp, ctx.nodes[idx]) return idx }

sync_splitter_paint :: proc(s: ^Screen, inp: ^Input_State, node: Layout_Node) { slot := get_splitter_slot(inp, node.id_hash) is_active := inp.active_splitter_id == node.id_hash is_focus := inp.focused_id == node.id_hash is_hover := inp.hovered_id == node.id_hash

heavy := is_active || is_focus || is_hover glyph: rune if slot.dir ==.Row { glyph ='┃' if heavy else'│' } else { glyph ='━' if heavy else'─' }

fg := slot.fg style := Style_Flags{} if is_active || is_focus { fg = slot.active_fg style = {.Bold} } else if is_hover { fg = rgb(100, 220, 255) style = {.Bold} }

s.paints[node.id_hash] = Paint_Spec{ fill_char = glyph, fg = fg, bg = slot.bg, style = style, }
}

// Clamps splitter bounds against solved parent inner_rect and cancels drags if a modal captures input sync_splitters :: proc(inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32) { if inp.active_splitter_id!= 0 { if idx, ok := ctx.id_map[inp.active_splitter_id];!ok ||!is_node_allowed(ctx, idx, capture_idx) inp.active_splitter_id = 0 } }

for i := 0; i < len(ctx.nodes); i += 1 { node := ctx.nodes[i] if!node.config.splitter || node.parent_idx < 0 { continue } slot := get_splitter_slot(inp, node.id_hash)

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 77/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

parent := ctx.nodes[node.parent_idx] axis := 0 if slot.dir ==.Row else 1 avail := parent.inner_rect.w if axis == 0 else parent.inner_rect.h

// Reserve at least 1 cell for the splitter and 4 cells for the second pane parent_limit := max(slot.min_size, avail-5) if slot.max_size > 0 { slot.effective_max = min(slot.max_size, parent_limit) } else { slot.effective_max = parent_limit } slot.effective_max = max(slot.min_size, slot.effective_max) } }

begin_splitter_drag :: proc(inp: ^Input_State, node: Layout_Node, mx, my: i32) { slot := get_splitter_slot(inp, node.id_hash) inp.active_splitter_id = node.id_hash slot.drag_start_mouse = mx if slot.dir ==.Row else my slot.drag_start_size = slot.size }

handle_splitter_drag :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, mx, my: i32, ) { idx, ok := ctx.id_map[inp.active_splitter_id] if!ok ||!is_node_allowed(ctx, idx, capture_idx) { inp.active_splitter_id = 0 return } slot := get_splitter_slot(inp, inp.active_splitter_id) mouse_coord := mx if slot.dir ==.Row else my delta := mouse_coord-slot.drag_start_mouse target_size := clamp(slot.drag_start_size + delta, slot.min_size, slot.effective_max) apply_splitter_size_immediate(inp, ctx, idx, target_size) }

handle_splitter_key :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, splitter_idx: i32, ev: Key_Event, )-> bool { if!is_node_allowed(ctx, splitter_idx, capture_idx) { return false } node := ctx.nodes[splitter_idx] slot := get_splitter_slot(inp, node.id_hash) step := slot.step * 3 if.Shift in ev.mods else slot.step

#partial switch ev.code { case.Left: if slot.dir ==.Row { apply_splitter_size_immediate(inp, ctx, splitter_idx, clamp(slot.size-step, slot.min_size return true } case.Right: if slot.dir ==.Row { apply_splitter_size_immediate(inp, ctx, splitter_idx, clamp(slot.size + step, slot.min_size return true

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 78/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

} case.Up: if slot.dir ==.Column { apply_splitter_size_immediate(inp, ctx, splitter_idx, clamp(slot.size-step, slot.min_size return true } case.Down: if slot.dir ==.Column { apply_splitter_size_immediate(inp, ctx, splitter_idx, clamp(slot.size + step, slot.min_size return true } case.Home,.Enter: reset_splitter_to_default(inp, ctx, splitter_idx) return true } return false }

reset_splitter_to_default :: proc(inp: ^Input_State, ctx: ^Layout_Context, splitter_idx: i32) { node := ctx.nodes[splitter_idx] slot := get_splitter_slot(inp, node.id_hash) target := clamp(slot.default_size, slot.min_size, slot.effective_max) apply_splitter_size_immediate(inp, ctx, splitter_idx, target) }

// Programmatically nudges a splitter by `delta` cells (respecting modal capture boundaries) nudge_splitter :: proc( inp: ^Input_State, ctx: ^Layout_Context, id: string, delta: i32, )-> bool { capture_idx := find_topmost_capture_node(ctx) return nudge_splitter_by_hash(inp, ctx, capture_idx, hash_id(id), delta) }

nudge_splitter_by_hash :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, splitter_hash: u64, delta: i32, )-> bool { idx, ok := ctx.id_map[splitter_hash] if!ok ||!is_node_allowed(ctx, idx, capture_idx) { return false } slot := get_splitter_slot(inp, splitter_hash) target := clamp(slot.size + delta, slot.min_size, slot.effective_max) apply_splitter_size_immediate(inp, ctx, idx, target) return true }

// Updates slot.size and immediately adjusts the preceding and following sibling Rects on the current frame apply_splitter_size_immediate :: proc( inp: ^Input_State, ctx: ^Layout_Context, splitter_idx: i32, new_size: i32, ) { splitter := &ctx.nodes[splitter_idx] slot := get_splitter_slot(inp, splitter.id_hash) delta := new_size-slot.size slot.size = new_size

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 79/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if delta == 0 || splitter.parent_idx < 0 { return }

parent := ctx.nodes[splitter.parent_idx] prev_idx := i32(-1) for c := parent.first_child; c!=-1 && c!= splitter_idx; c = ctx.nodes[c].next_sibling { if!ctx.nodes[c].out_of_flow { prev_idx = c } } next_idx := splitter.next_sibling for next_idx!=-1 && ctx.nodes[next_idx].out_of_flow { next_idx = ctx.nodes[next_idx].next_sibling }

if slot.dir ==.Row { if prev_idx >= 0 { prev := &ctx.nodes[prev_idx] prev.computed_size[0] += delta prev.rect.w += delta recompute_subtree_clips(ctx, prev_idx, parent.inner_clip) } splitter.rect.x += delta recompute_subtree_clips(ctx, splitter_idx, parent.inner_clip)

if next_idx >= 0 { next := &ctx.nodes[next_idx] next.computed_size[0] = max(0, next.computed_size[0]-delta) next.rect.x += delta next.rect.w = max(0, next.rect.w-delta) shift_children_x(ctx, next_idx, delta) recompute_subtree_clips(ctx, next_idx, parent.inner_clip) } } else { if prev_idx >= 0 { prev := &ctx.nodes[prev_idx] prev.computed_size[1] += delta prev.rect.h += delta recompute_subtree_clips(ctx, prev_idx, parent.inner_clip) } splitter.rect.y += delta recompute_subtree_clips(ctx, splitter_idx, parent.inner_clip)

if next_idx >= 0 { next := &ctx.nodes[next_idx] next.computed_size[1] = max(0, next.computed_size[1]-delta) next.rect.y += delta next.rect.h = max(0, next.rect.h-delta) shift_descendants_y(ctx, next_idx, delta, next.inner_clip) recompute_subtree_clips(ctx, next_idx, parent.inner_clip) } } }

shift_children_x :: proc(ctx: ^Layout_Context, parent_idx: i32, dx: i32) { for c := ctx.nodes[parent_idx].first_child; c!=-1; c = ctx.nodes[c].next_sibling { child := &ctx.nodes[c] if child.out_of_flow { continue } child.rect.x += dx child.inner_rect.x += dx if child.child_count > 0 {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 80/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

shift_children_x(ctx, c, dx)
}
}
}
recompute_subtree_clips :: proc(ctx: ^Layout_Context, idx: i32, parent_clip: Rect) {
node := &ctx.nodes[idx]
node.inner_rect = compute_inner_rect(node.rect, node.config)
node.node_clip = rect_intersect(parent_clip, node.rect)
node.inner_clip = rect_intersect(node.node_clip, node.inner_rect)
for c := node.first_child; c != -1; c = ctx.nodes[c].next_sibling {
if !ctx.nodes[c].out_of_flow {
recompute_subtree_clips(ctx, c, node.inner_clip)
}
}
}
// =============================================================================
// Global & Scoped Keybinding Router
// =============================================================================
Key_Scope_Policy :: enum u8 {
Root_And_Scopes, // Active across the base UI; blocked when a capture_input modal is open
Scope_Only,
// Active ONLY when active_scope_id or active_capture_id == scope_id
Global_Always,
// Active everywhere, even when a capturing modal is open (e.g., Ctrl+Q)
}
Keybinding_Flag :: enum u8 {
Allow_In_Text_Input, // Fires even when a ui_text_input widget has focus
}
Keybinding_Flags :: bit_set[Keybinding_Flag; u8]
Keybinding :: struct {
key:
Key_Event,
action:
string,
action_id:
u64,
scope_id:
u64,
policy:
Key_Scope_Policy,
flags:
Keybinding_Flags,
splitter_id:
u64, // Non-zero if this keybinding directly resizes a splitter
splitter_delta: i32,
}
clear_keybindings :: proc(inp: ^Input_State) {
inp.keybinding_count = 0
}
// Registers or updates a global or scoped keybinding
bind_key :: proc(
inp: ^Input_State,
key: Key_Event,
action: string,
policy: Key_Scope_Policy = .Root_And_Scopes,
scope_id: string = "",
flags: Keybinding_Flags = {},
) {
act_id := hash_id(action)
sc_id := hash_id(scope_id) if len(scope_id) > 0 else 0
// Update existing binding if same key + policy + scope_id already exists
for i := 0; i < inp.keybinding_count; i += 1 {
b := &inp.keybindings[i]
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

81/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

if b.key == key && b.policy == policy && b.scope_id == sc_id {

b.action = action
b.action_id = act_id
b.flags = flags
b.splitter_id = 0
b.splitter_delta = 0 return
} }

if inp.keybinding_count >= MAX_KEYBINDINGS { return } inp.keybindings[inp.keybinding_count] = Keybinding{ key = key, action = action, action_id = act_id, scope_id = sc_id, policy = policy, flags = flags, } inp.keybinding_count += 1 }

// Registers a shortcut that directly resizes a split-pane divider (works even while focused in a text input) bind_splitter_key :: proc( inp: ^Input_State, key: Key_Event, splitter_id: string, delta: i32, action: string = "resize_split", ) { if inp.keybinding_count >= MAX_KEYBINDINGS { return } inp.keybindings[inp.keybinding_count] = Keybinding{ key = key, action = action, action_id = hash_id(action), policy =.Root_And_Scopes, flags = {.Allow_In_Text_Input}, splitter_id = hash_id(splitter_id), splitter_delta = delta, } inp.keybinding_count += 1 }

was_action_triggered :: #force_inline proc(inp: ^Input_State, action: string)-> bool { return inp.triggered_action_id!= 0 && inp.triggered_action_id == hash_id(action) }

// Evaluates Scope_Only bindings first, then Root_And_Scopes, then Global_Always dispatch_keybindings :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, ev: Key_Event, in_text_input: bool, )-> bool { // Pass 1: Scope_Only bindings (highest specificity) for i := 0; i < inp.keybinding_count; i += 1 { b := inp.keybindings[i] if b.policy ==.Scope_Only && match_and_fire_binding(inp, ctx, capture_idx, b, ev, in_text_input) return true

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 82/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

} } // Pass 2: Root_And_Scopes & Global_Always bindings for i := 0; i < inp.keybinding_count; i += 1 { b := inp.keybindings[i] if b.policy!=.Scope_Only && match_and_fire_binding(inp, ctx, capture_idx, b, ev, in_text_input) return true } } return false }

match_and_fire_binding :: proc( inp: ^Input_State, ctx: ^Layout_Context, capture_idx: i32, b: Keybinding, ev: Key_Event, in_text_input: bool, )-> bool { if b.key.code!= ev.code || b.key.mods!= ev.mods { return false } if b.key.code ==.Rune && b.key.ch!= ev.ch { return false }

// Shield focused text inputs from unmodified single-key shortcuts if in_text_input && (.Allow_In_Text_Input not_in b.flags) { return false }

switch b.policy { case.Scope_Only: if b.scope_id == 0 { return false } if inp.active_scope_id!= b.scope_id && inp.active_capture_id!= b.scope_id { return false } if capture_idx >= 0 { if scope_node_idx, ok := ctx.id_map[b.scope_id];!ok ||!is_node_allowed(ctx, scope_node_id return false } }

case.Root_And_Scopes: // Blocked whenever a capturing modal is active if capture_idx >= 0 { return false }

case.Global_Always: // Always allowed across all z-layers }

if b.splitter_id!= 0 { if!nudge_splitter_by_hash(inp, ctx, capture_idx, b.splitter_id, b.splitter_delta) { return false } }

inp.triggered_action_id = b.action_id inp.triggered_action_name = b.action

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 83/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

return true
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
build_split_workspace_ui :: proc(
ctx: ^Layout_Context,
scr: ^Screen,
inp: ^Input_State,
show_modal: bool,
) {
begin_layout(ctx, 80, 20)
begin_frame(scr, rgb(16, 20, 26))
sidebar_w := get_split_size(inp, "main_split", default_size = 20, min_size = 12, max_size = 36)
if container(ctx, "workspace", {dir = .Row, width = grow(1), height = grow(1)}) {
// Left Pane: Sidebar controlled by "main_split"
if container(ctx, "sidebar", {
dir
= .Column,
width
= fixed(sidebar_w),
height
= grow(1),
border
= .Plain,
focus_scope = true,
}) {
ui_text_input(ctx, scr, inp, "search_box", {
width
= grow(1),
height
= fixed(3),
border
= .Rounded,
title
= "Filter",
placeholder = "Type query...",
})
}
// 1-Cell Interactive Vertical Divider Bar
ui_splitter(ctx, scr, inp, "main_split", {
dir
= .Row,
default_size = 20,
min_size
= 12,
max_size
= 36,
step
= 2,
})
// Right Pane: Main Editor/Logs takes remaining width
if container(ctx, "main_pane", {
dir
= .Column,
width
= grow(1),
height
= grow(1),
border
= .Plain,
focus_scope = true,
}) {
ui_button(ctx, scr, "run_btn", {label = "Run Query"})
}
if show_modal {
if ui_modal(ctx, scr, "confirm_modal", {
title
= "Confirm Action",
z_layer = 20,
width
= fixed(28),
height = fixed(6),
border = .Double,
}) {
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

84/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

ui_button(ctx, scr, "modal_ok", {label = "OK (y)"}) } } }

end_layout(ctx) }

@(test) test_splitter_resize_and_global_keybinding_router :: proc(t: ^testing.T) { defer free_all(context.temp_allocator)

scr: Screen err := screen_init(&scr, 80, 20) testing.expect_value(t, err, nil) defer screen_destroy(&scr)

ctx: Layout_Context inp: Input_State

// Register keybindings: // 1. Unmodified'q'-> quits app (ONLY when not typing in a text input and no modal is open) bind_key(&inp, Key_Event{code =.Rune, ch ='q'}, "quit_app",.Root_And_Scopes) // 2. Ctrl+P-> opens command palette even while typing in a text input bind_key(&inp, Key_Event{code =.Rune, ch ='p', mods = {.Ctrl}}, "open_palette",.Root_And_Scopes, "", // 3. Ctrl+Left / Ctrl+Right-> resizes "main_split" by-5 / +5 cells from anywhere bind_splitter_key(&inp, Key_Event{code =.Left, mods = {.Ctrl}}, "main_split",-5) bind_splitter_key(&inp, Key_Event{code =.Right, mods = {.Ctrl}}, "main_split", +5) // 4. Scoped modal hotkey:'y' inside "confirm_modal" triggers "modal_confirmed" bind_key(&inp, Key_Event{code =.Rune, ch ='y'}, "modal_confirmed",.Scope_Only, "confirm_modal") // 5. Global emergency quit: Ctrl+Q works even when a capturing modal is open bind_key(&inp, Key_Event{code =.Rune, ch ='q', mods = {.Ctrl}}, "force_quit",.Global_Always, "", {.Al

//---Frame 1: Initial Split Layout (20 + 1 + 59 = 80)--- build_split_workspace_ui(&ctx, &scr, &inp, false) resolve_input(&inp, &ctx) apply_input_highlights(&scr, &ctx, &inp) render_layout(&scr, &ctx)

sidebar_r1, _ := get_rect(&ctx, "sidebar") split_r1, _ := get_rect(&ctx, "main_split") main_r1, _ := get_rect(&ctx, "main_pane")

testing.expect_value(t, sidebar_r1, Rect{x = 0, y = 0, w = 20, h = 20}) testing.expect_value(t, split_r1, Rect{x = 20, y = 0, w = 1, h = 20}) testing.expect_value(t, main_r1, Rect{x = 21, y = 0, w = 59, h = 20}) testing.expect_value(t, scr.back[5 * 80 + 20].ch,'│') // Idle splitter glyph

//---Frame 2: Mouse Drag Splitter from x = 20 to x = 28 (Same-Frame Update!)--- resolve_input( &inp, &ctx, Mouse_Event{x = 20, y = 5, action =.Press, button =.Left}, Mouse_Event{x = 28, y = 5, action =.Move, button =.Left}, ) apply_input_highlights(&scr, &ctx, &inp) render_layout(&scr, &ctx)

sidebar_r2, _ := get_rect(&ctx, "sidebar") split_r2, _ := get_rect(&ctx, "main_split") main_r2, _ := get_rect(&ctx, "main_pane")

testing.expect_value(t, get_split_size(&inp, "main_split"), 28) testing.expect_value(t, sidebar_r2, Rect{x = 0, y = 0, w = 28, h = 20})

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 85/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

|testing.expect_value(t,||split_r2,|Rect{x|= 28,|y = 0, w|= 1, h =|20})|||
|---|---|---|---|---|---|---|---|---|---|
|testing.expect_value(t,||main_r2,|Rect{x|= 29,|y = 0, w|= 51, h =|20})|||
|testing.expect_value(t,||scr.back[5|*|80 + 28].ch,|'┃') //|Active drag|upgrades|to heavy|bar '┃'|
|// Drag resolve_input(|way past|max_size =|36 (to x|= 65) and|release; verify|clamped|to 36|||
||&inp,|||||||||
||&ctx,|||||||||
||Mouse_Event{x|= 65, y|= 5, action|= .Move,|button =|.Left},||||
|)|Mouse_Event{x|= 65, y|= 5, action|= .Release,|button|= .Left},||||
|testing.expect_value(t,||get_split_size(&inp,||"main_split"),||36)||||
|//---|Frame 3:||Shielding|& Global Chord|Execution|---||||
|// Focus build_split_workspace_ui(&ctx, resolve_input(|"search_box"|by clicking|inside &scr,|it (x &inp, false)|= 3, y = 2)|||||
||&inp,|||||||||
||&ctx,|||||||||
||Mouse_Event{x|= 3, y|= 2, action|= .Press,|button =|.Left},||||
|)|Mouse_Event{x|= 3, y|= 2, action|= .Release,|button|= .Left},||||
|testing.expect(t,||is_focused(&inp,|"search_box"),||"search_box|should|be focused")|||
|// Type|'q' inside|search_box:|must insert|'q'|into text|and NOT trigger|"quit_app"|||
|resolve_input(&inp,||&ctx, Key_Event{code||= .Rune,|ch = 'q'})|||||
|testing.expect_value(t,||get_text(&inp,||"search_box"),|"q")|||||
|testing.expect(t,||!was_action_triggered(&inp,||"quit_app"),||"Unmodified|'q' must|be shielded|by search_bo|
|// Press|Ctrl+Left|while still|focused|in search_box:|shrinks|"main_split"|from|36-> 31||
|resolve_input(&inp,||&ctx, Key_Event{code||= .Left,|mods =|{.Ctrl}})||||
|testing.expect_value(t,||get_split_size(&inp,||"main_split"),||31)||||
|testing.expect(t,||is_focused(&inp,|"search_box"),||"Ctrl+Left|resize|keeps focus|in search_box")||
|// Press|Ctrl+P|focused|in search_box:|triggers|"open_palette"|||||
|resolve_input(&inp,||&ctx, Key_Event{code||= .Rune,|ch = 'p',|mods =|{.Ctrl}})|||
|testing.expect(t,||was_action_triggered(&inp,||"open_palette"),||"Ctrl+P|should|fire even|inside text|
|//--- build_split_workspace_ui(&ctx, resolve_input(|Frame 4:|Capture|Blocks &scr,|Background &inp, true)|Splitters|& Root Shortcuts|---|||
||&inp,|||||||||
||&ctx,|||||||||
||Key_Event{code|= .Left,|mods =|{.Ctrl}},|// Blocked|by modal!||||
||Mouse_Event{x|= 31, y|= 5, action|= .Press,|button|= .Left},|// Blocked|by modal!||
|)|Mouse_Event{x|= 20, y|= 5, action|= .Move,|button =|.Left},||||
|testing.expect_value(t,||get_split_size(&inp,||"main_split"),||31)||||
|// Pressing|'y'|"confirm_modal"||triggers|the Scope_Only|"modal_confirmed"||action||
|resolve_input(&inp,||&ctx, Key_Event{code||= .Rune,|ch = 'y'})|||||
|testing.expect(t,||was_action_triggered(&inp,||"modal_confirmed"),||"Scoped|'y'|hotkey should|fire inside|
|// Pressing|Ctrl+Q|triggers|the Global_Always|"force_quit"||action even|through|the modal||
|resolve_input(&inp,||&ctx, Key_Event{code||= .Rune,|ch = 'q',|mods =|{.Ctrl}})|||
|testing.expect(t,||was_action_triggered(&inp,||"force_quit"),||"Global_Always|Ctrl+Q|should|fire above|

Text-Input

while input Modal

inside c

moda } **Why This Design Fits Your Architecture Cleanly** **Zero-Latency Dragging Without a Second Full Layout Pass:** When a user drags ui_splitter or hits Ctrl+Left, apply_splitter_size_immediate updates slot.size for future frames and shifts the adjacent sibling Rects and clip regions in-place so render_layout draws the updated split on the current frame.

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 86/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

**Safe Coexistence with ui_text_input:** Because dispatch_keybindings checks in_text_input && (.Allow_In_Text_Input not_in b.flags), single-letter Vim/TUI hotkeys (q, j, k, /, c) work everywhere in the UI *except* when a text box is focused, while Ctrl/Alt chords marked .Allow_In_Text_Input work seamlessly from inside the search bar.

**Modal-Scoped Hotkeys (Scope_Only):** Binding 'y' and 'n' with policy =.Scope_Only, scope_id = "confirm_modal" lets modal dialogs handle single-key confirmations cleanly without polluting global keybindings.

*User prompt: Show how to combine ui_modal, ui_text_input, and ui_virtual_list into a reusable Ctrl+P fuzzy command palette that dispatches* *keybinding actions.*

Response: Because ui_modal, ui_text_input, ui_virtual_list, and the keybinding router already share Input_State, they compose into a Ctrl+P fuzzy command palette with **zero changes** to your existing layout, renderer, or input files:

1. **Automatic Focus Trap & Restoration:** Opening ui_modal at z_layer = 40 causes reconcile_focus to push the active background widget onto inp.focus_history and immediately focus "cmd_palette_input", restoring the previous focus as soon as the palette closes.
2. **Telescope-Style Navigation (linked_list_id):** Because "cmd_palette_input" links to "cmd_palette_list", typing a query filters and re-ranks commands while Up, Down, Page_Up, and Page_Down move the selection bar without leaving the text box.
3. **Space vs. Enter Separation:** Inside handle_text_input_key, Space inserts a space character into the fuzzy query (e.g., "xit compact"), whereas Enter falls through to handle_key_event and sets inp.activated_id = hash_id("cmd_palette_input"), triggering the highlighted command.
4. **Live Shortcut Badge Discovery:** The palette scans inp.keybindings automatically to display right-aligned shortcut badges (Ctrl+Q, Ctrl+Left, q) next to matching commands.
## Complete Fuzzy Command Palette Module (command_palette.odin)

Save this as command_palette.odin in the same package directory (package tui_layout) and run odin test.-vet-strict-style:

package tui_layout

import "core:fmt" import "core:strings" import "core:testing"

MAX_PALETTE_COMMANDS :: 64

Command_Item :: struct { action: string, // Action string dispatched to inp.triggered_action_name label: string, // Human-readable command title category: string, // Optional prefix group (e.g., "xitdb", "View", "App") shortcut_hint: string, // Optional manual badge override; auto-detected from inp.keybindings if empty }

Command_Match :: struct { item_idx: i32, score: i32, }

// Persistent palette state (owned by UI Actor; zero heap allocations) Command_Palette :: struct { is_open: bool, toggle_action: string, commands: [MAX_PALETTE_COMMANDS]Command_Item, command_count: int, matches: [MAX_PALETTE_COMMANDS]Command_Match, match_count: i32, }

// Initializes the command palette and binds its toggle key (default Ctrl+P) as Global_Always command_palette_init :: proc( p: ^Command_Palette, inp: ^Input_State,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 87/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

toggle_key := Key_Event{code =.Rune, ch ='p', mods = {.Ctrl}}, toggle_action := "toggle_command_palette", ) { p^ = {}

p.toggle_action = toggle_action bind_key( inp, toggle_key, toggle_action, .Global_Always, "", {.Allow_In_Text_Input}, )
}

// Registers a command in the palette register_command :: proc( p: ^Command_Palette, action: string, label: string, category: string = "", shortcut_hint: string = "", ) { for i := 0; i < p.command_count; i += 1 { if p.commands[i].action == action {

p.commands[i] = Command_Item{ action = action, label = label, category = category, shortcut_hint = shortcut_hint, } return
} } if p.command_count >= MAX_PALETTE_COMMANDS { return }

p.commands[p.command_count] = Command_Item{ action = action, label = label, category = category, shortcut_hint = shortcut_hint, }
p.command_count += 1
}

// Recomputes fuzzy matches and emits the modal UI when palette.is_open is true ui_command_palette :: proc( ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, p: ^Command_Palette, ) { if!p.is_open { return }

query := get_text(inp, "cmd_palette_input") update_palette_matches(p, query)

if ui_modal(ctx, s, "cmd_palette_modal", { title = "Command Palette", z_layer = 40, width = fixed(56),

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 88/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

height = fixed(12), border =.Double, padding = pad_xy(1, 0), gap = 0, bg = rgb(22, 26, 34), border_fg = rgb(110, 180, 255), title_fg = rgb(255, 220, 100), backdrop =.Dim_Screen, }) { // 1. Search Box linked directly to the virtual command list ui_text_input(ctx, s, inp, "cmd_palette_input", { width = grow(1), height = fixed(3), border =.Rounded, title = "Search (Up/Down to select, Enter to run)", placeholder = "Type a command...", linked_list_id = "cmd_palette_list", fg = rgb(240, 245, 250), bg = rgb(30, 36, 48), border_fg = rgb(90, 140, 200), })

// 2. Virtualized Command Results List (inner height = 12-2 border-3 input = 7 rows) slice: Virtual_Slice if ui_virtual_list(ctx, s, inp, "cmd_palette_list", p.match_count, { width = grow(1), height = grow(1), border =.None, fallback_rows = 7, bg = rgb(22, 26, 34), }, &slice) { if p.match_count == 0 { ui_label(ctx, s, "cmd_palette_empty", "No matching commands", rgb(130, 140, 155), {. } else { for v_row := slice.start_row; v_row < slice.end_row; v_row += 1 { match := p.matches[v_row] item := p.commands[match.item_idx] is_sel := v_row == slice.selected_row

row_id := fmt.tprintf("cmd_palette_row_%d", v_row) row_bg := rgb(50, 80, 125) if is_sel else rgb(22, 26, 34) row_fg := rgb(255, 240, 150) if is_sel else rgb(210, 220, 230) row_style := Style_Flags{.Bold} if is_sel else Style_Flags{}

// Each row is a focusable horizontal container so mouse clicks also activate if container(ctx, row_id, { dir =.Row, width = grow(1), height = fixed(1), padding = pad_xy(1, 0), cross_align =.Center, focusable = true, }) { set_paint(s, row_id, { bg = row_bg, fill_bg = true, })

prefix := ">" if is_sel else " " full_label := fmt.tprintf( "%s [%s] %s", prefix, item.category, item.label,

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 89/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

) if len(item.category) > 0 else fmt.tprintf("%s %s", prefix, item.labe

lbl_id := fmt.tprintf("cmd_lbl_%d", v_row) ui_label(ctx, s, lbl_id, full_label, row_fg, row_style, { width = grow(1), })

badge := item.shortcut_hint if len(item.shortcut_hint) > 0 else lookup_ if len(badge) > 0 { key_id := fmt.tprintf("cmd_key_%d", v_row) badge_fg := rgb(140, 220, 255) if is_sel else rgb(120, 145, 175) ui_label(ctx, s, key_id, badge, badge_fg, row_style, { width = fit(), }) } } } } } } }

// Processes palette toggle, Escape/backdrop dismissal, and Enter/click command execution. // Call right after `resolve_input(&inp, &ctx,..events)`. update_command_palette :: proc(p: ^Command_Palette, inp: ^Input_State) { // 1. Handle Ctrl+P toggle action if len(p.toggle_action) > 0 && was_action_triggered(inp, p.toggle_action) {

p.is_open =!p.is_open // Consume the toggle action so the application doesn't treat it as an unhandled command inp.triggered_action_id = 0 inp.triggered_action_name = "" if p.is_open { set_text(inp, "cmd_palette_input", "") scroll_slot := get_scroll_slot(inp, hash_id("cmd_palette_list")) scroll_slot.offset = 0 scroll_slot.selected_row = 0 inp.focused_id = hash_id("cmd_palette_input") } return
}

if!p.is_open { return }

// 2. Dismiss on Escape or clicking outside the modal backdrop if was_modal_dismissed(inp, "cmd_palette_modal") {

p.is_open = false return
}

// 3. Execute selected command when pressing Enter inside the search input if was_activated(inp, "cmd_palette_input") { sel := get_selected_row(inp, "cmd_palette_list") dispatch_palette_row(p, inp, sel) return }

// 4. Execute clicked command row when clicking with the mouse if inp.activated_id!= 0 { for v_row: i32 = 0; v_row < p.match_count; v_row += 1 { row_id := fmt.tprintf("cmd_palette_row_%d", v_row) if inp.activated_id == hash_id(row_id) {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 90/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

dispatch_palette_row(p, inp, v_row)
return
}
}
}
}
dispatch_palette_row :: proc(p: ^Command_Palette, inp: ^Input_State, v_row: i32) {
if v_row < 0 || v_row >= p.match_count {
return
}
match := p.matches[v_row]
item := p.commands[match.item_idx]
inp.triggered_action_id = hash_id(item.action)
inp.triggered_action_name = item.action
inp.activated_id = 0
p.is_open = false
}
// =============================================================================
// Fuzzy Subsequence Matcher, Ranker & Keybinding Formatter
// =============================================================================
update_palette_matches :: proc(p: ^Command_Palette, query: string) {
p.match_count = 0
// Empty query shows all registered commands in registration order
if len(query) == 0 {
for i := 0; i < p.command_count; i += 1 {
p.matches[p.match_count] = Command_Match{
item_idx = i32(i),
score
= 0,
}
p.match_count += 1
}
return
}
for i := 0; i < p.command_count; i += 1 {
item := p.commands[i]
candidate := fmt.tprintf("%s %s", item.category, item.label) if len(item.category) > 0 else item.
if score, ok := fuzzy_score(candidate, query); ok {
p.matches[p.match_count] = Command_Match{
item_idx = i32(i),
score
= score,
}
p.match_count += 1
}
}
// Stable insertion sort by score descending
for i: i32 = 1; i < p.match_count; i += 1 {
key := p.matches[i]
j := i - 1
for j >= 0 && p.matches[j].score < key.score {
p.matches[j + 1] = p.matches[j]
j -= 1
}
p.matches[j + 1] = key
}
}
// Scores `query` as a subsequence of `target` with bonuses for word boundaries and consecutive runs
fuzzy_score :: proc(target, query: string) -> (score: i32, matched: bool) {
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

91/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

q_idx := 0 for q_idx < len(query) && query[q_idx] =='' { q_idx += 1 } if q_idx >= len(query) { return 0, true }

total_score: i32 = 0 consecutive: i32 = 0

for t_idx := 0; t_idx < len(target) && q_idx < len(query); t_idx += 1 { // Skip spaces in query so multi-token queries like "xit compact" match cleanly for q_idx < len(query) && query[q_idx] =='' { q_idx += 1 consecutive = 0 } if q_idx >= len(query) { break }

tc := to_lower_ascii(target[t_idx]) qc := to_lower_ascii(query[q_idx])

if tc == qc { total_score += 10 if t_idx == 0 || is_word_boundary(target[t_idx-1]) { total_score += 20 } if consecutive > 0 { total_score += 15 * consecutive } consecutive += 1 q_idx += 1 } else { consecutive = 0 total_score-= 1 // Slight penalty for gaps } }

for q_idx < len(query) && query[q_idx] =='' { q_idx += 1 } if q_idx < len(query) { return 0, false } return total_score, true }

to_lower_ascii :: #force_inline proc(b: byte)-> byte { if b >='A' && b <='Z' { return b + 32 } return b }

is_word_boundary :: #force_inline proc(b: byte)-> bool { return b =='' || b =='_' || b =='-' || b ==':' || b =='/' || b =='[' || b ==']' }

// Scans registered keybindings to format a shortcut hint badge on context.temp_allocator lookup_action_shortcut :: proc(inp: ^Input_State, action: string, alloc := context.temp_allocator)-> string { act_id := hash_id(action) for i := 0; i < inp.keybinding_count; i += 1 {

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 92/95


03/11/2026, 20:42

Building an Actor-Driven Odin TUI

b := inp.keybindings[i]
if b.action_id == act_id {
return format_key_event(b.key, alloc)
}
}
return ""
}
format_key_event :: proc(k: Key_Event, alloc := context.temp_allocator) -> string {
sb := strings.builder_make(alloc)
if .Ctrl in k.mods {
strings.write_string(&sb, "Ctrl+")
}
if .Alt in k.mods {
strings.write_string(&sb, "Alt+")
}
if .Shift in k.mods {
strings.write_string(&sb, "Shift+")
}
switch k.code {
case .None:
case .Tab:
strings.write_string(&sb, "Tab")
case .Enter:
strings.write_string(&sb, "Enter")
case .Space:
strings.write_string(&sb, "Space")
case .Escape:
strings.write_string(&sb, "Esc")
case .Up:
strings.write_string(&sb, "Up")
case .Down:
strings.write_string(&sb, "Down")
case .Left:
strings.write_string(&sb, "Left")
case .Right:
strings.write_string(&sb, "Right")
case .Page_Up:
strings.write_string(&sb, "PgUp")
case .Page_Down: strings.write_string(&sb, "PgDn")
case .Home:
strings.write_string(&sb, "Home")
case .End:
strings.write_string(&sb, "End")
case .Backspace: strings.write_string(&sb, "Bksp")
case .Delete:
strings.write_string(&sb, "Del")
case .F6:
strings.write_string(&sb, "F6")
case .Rune:
ch := k.ch
if ch >= 'a' && ch <= 'z' && (.Ctrl in k.mods || .Alt in k.mods) {
ch -= 32 // Render Ctrl+p as "Ctrl+P"
}
strings.write_rune(&sb, ch)
}
return strings.to_string(sb)
}
// =============================================================================
// Verification Test Suite (`odin test . -vet -strict-style`)
// =============================================================================
build_palette_test_app :: proc(
ctx: ^Layout_Context,
scr: ^Screen,
inp: ^Input_State,
palette: ^Command_Palette,
) {
begin_layout(ctx, 80, 24)
begin_frame(scr, rgb(16, 20, 26))
if container(ctx, "root", {dir = .Column, width = grow(1), height = grow(1), focus_scope = true}) {
ui_button(ctx, scr, "workspace_btn", {label = "Query xitdb"})
ui_command_palette(ctx, scr, inp, palette)
}
https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…

93/95



03/11/2026, 20:42 Building an Actor-Driven Odin TUI

end_layout(ctx) }

@(test) test_ctrl_p_fuzzy_command_palette_workflow :: proc(t: ^testing.T) { defer free_all(context.temp_allocator)

scr: Screen err := screen_init(&scr, 80, 24) testing.expect_value(t, err, nil) defer screen_destroy(&scr)

ctx: Layout_Context inp: Input_State palette: Command_Palette

(binds

|// 1.|Initialize|palette|Ctrl+P)|and register|application|keybindings|& commands||
|---|---|---|---|---|---|---|---|---|
|command_palette_init(&palette,|||&inp)||||||
|bind_key(&inp,||Key_Event{code|= .Rune,|ch = 'k',|mods = {.Ctrl}},|"compact_xitdb",||.Root_And_Scopes)|
|bind_key(&inp,||Key_Event{code|= .Rune,|ch = 'r',|mods = {.Ctrl}},|"rollback_moment",||.Root_And_Scopes)|
|bind_key(&inp,||Key_Event{code|= .Rune,|ch = 'q'},|"quit_app",|.Root_And_Scopes)|||
|register_command(&palette,|||"compact_xitdb",|"Compact|History|Buffer",|"xitdb")||
|register_command(&palette,|||"rollback_moment",|"Rollback|to|Previous Slot",|"xitdb")||
|register_command(&palette,|||"clear_filter",|"Clear|Log Search|Filter",|"View")||
|register_command(&palette, // Verify testing.expect_value(t,|auto-formatted|lookup_action_shortcut(&inp,|"quit_app", badge|"Quit discovery|Application", "compact_xitdb"),||"App") "Ctrl+K")||
|//--- build_palette_test_app(&ctx,|Frame|Base Workspace|Focused &scr, &inp,|on "workspace_btn" &palette)|---||||
|resolve_input(&inp,||&ctx)|||||||
|update_command_palette(&palette,|||&inp)||||||
|testing.expect(t,||!palette.is_open,|"Palette|starts|closed")||||
|testing.expect(t,||is_focused(&inp,|"workspace_btn"),||"Initial|focus on|workspace_btn")||
|//---|Frame|Press Ctrl+P|-> Opens|Palette &|Focus|in "cmd_palette_input"||---|
|resolve_input(&inp,||&ctx,||= .Rune,|ch = 'p',|mods = {.Ctrl}})|||
|update_command_palette(&palette,|||&inp)||||||
|testing.expect(t, build_palette_test_app(&ctx,||palette.is_open,|"Ctrl+P &scr, &inp,|should &palette)|open command|palette")|||
|resolve_input(&inp,||&ctx)|||||||
|update_command_palette(&palette, apply_input_highlights(&scr,|||&inp) &ctx, &inp)||||||
|render_layout(&scr,||&ctx)|||||||
|testing.expect(t, testing.expect_value(t,||is_focused(&inp, palette.match_count,|"cmd_palette_input"),|4)|"Palette|input|should capture|focus")|
|//--- resolve_input(|Frame|Type Fuzzy|Query "xit|slot"-> Ranks|"Rollback|to Previous|Slot"|#1---|
||&inp,||||||||
||&ctx,||||||||
||Key_Event{code|= .Rune,|ch = 'x'},||||||
||Key_Event{code|= .Rune,|ch = 'i'},||||||
||Key_Event{code|= .Rune,|ch = 't'},||||||
||Key_Event{code|= .Space},|||||||
||Key_Event{code|= .Rune,|ch = 's'},||||||
||Key_Event{code|= .Rune,|ch = 'l'},||||||
||Key_Event{code|= .Rune,|ch = 'o'},||||||

shortcut

1:

2: Traps Key_Event{code

3:

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 94/95


03/11/2026, 20:42 Building an Actor-Driven Odin TUI

Key_Event{code =.Rune, ch ='t'}, ) update_command_palette(&palette, &inp)

build_palette_test_app(&ctx, &scr, &inp, &palette) resolve_input(&inp, &ctx) update_command_palette(&palette, &inp)

testing.expect_value(t, get_text(&inp, "cmd_palette_input"), "xit slot") testing.expect_value(t, palette.match_count, 1) testing.expect_value(t, palette.commands[palette.matches[0].item_idx].action, "rollback_moment")

//---Frame 4: Press Enter-> Dispatches "rollback_moment", Closes Palette & Restores Focus--- resolve_input(&inp, &ctx, Key_Event{code =.Enter}) update_command_palette(&palette, &inp)

testing.expect(t,!palette.is_open, "Pressing Enter should close palette") testing.expect(t, was_action_triggered(&inp, "rollback_moment"), "Enter should dispatch rollback_moment"

// Rebuild next frame after close-> focus automatically restores to "workspace_btn" build_palette_test_app(&ctx, &scr, &inp, &palette) resolve_input(&inp, &ctx) update_command_palette(&palette, &inp) testing.expect(t, is_focused(&inp, "workspace_btn"), "Closing palette should restore focus to workspace_ }

## How the Pieces Work Together

**Multi-Token Fuzzy Ranking (fuzzy_score):** Typing "xit slot" matches across the category ("xitdb") and command title ("Rollback to Previous Slot"), awarding word-boundary (+20) and consecutive run (+15) bonuses so the best match rises to index 0.

**Zero Duplicate Keybinding Tables:** You only call bind_key once; lookup_action_shortcut inspects inp.keybindings by action_id hash and formats "Ctrl+K" or "Ctrl+R" into the right-aligned badge column automatically.

**Unified Action Dispatch (was_action_triggered):** Whether the user presses Ctrl+R directly in the workspace or presses Ctrl+P, types "xit slot", and hits Enter, both paths set inp.triggered_action_id = hash_id("rollback_moment"), so your UI actor handles shortcuts and palette commands in one place.

[https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…](https://gemini.google.com/app/b1523f6085f4b688?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id…) 95/95
