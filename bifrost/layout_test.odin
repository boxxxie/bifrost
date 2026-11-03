package bifrost

import "core:testing"

@(test)
test_clay_layout_solver :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ctx: Layout_Context
	begin_layout(&ctx, 80, 24)

	if container(&ctx, "root", {dir = .Column, width = grow(1), height = grow(1), padding = pad_all(1), gap = 1}) {
		if container(&ctx, "header", {dir = .Row, width = grow(1), height = fit(), border = .Rounded, padding = pad_xy(1, 0)}) {
			leaf(&ctx, "title", 15, 1)
		}
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

	title_rect, _ := get_rect(&ctx, "title")
	testing.expect_value(t, title_rect, Rect{x = 3, y = 2, w = 15, h = 1})

	body_rect, _ := get_rect(&ctx, "body")
	testing.expect_value(t, body_rect, Rect{x = 1, y = 5, w = 78, h = 18})

	sidebar_rect, _ := get_rect(&ctx, "sidebar")
	testing.expect_value(t, sidebar_rect, Rect{x = 1, y = 5, w = 20, h = 18})

	main_rect, _ := get_rect(&ctx, "main_panel")
	testing.expect_value(t, main_rect, Rect{x = 23, y = 5, w = 56, h = 18})
}

@(test)
test_grow_min_max_and_remainder :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ctx: Layout_Context
	begin_layout(&ctx, 101, 10)

	if container(&ctx, "row", {dir = .Row, width = grow(1), height = grow(1)}) {
		leaf(&ctx, "capped", 0, 0, {width = grow(weight = 1, max = 20), height = grow(1)})
		leaf(&ctx, "flex_a", 0, 0, {width = grow(1), height = grow(1)})
		leaf(&ctx, "flex_b", 0, 0, {width = grow(1), height = grow(1)})
	}

	end_layout(&ctx)

	capped, _ := get_rect(&ctx, "capped")
	flex_a, _ := get_rect(&ctx, "flex_a")
	flex_b, _ := get_rect(&ctx, "flex_b")

	testing.expect_value(t, capped.w, 20)
	testing.expect_value(t, flex_a.w, 40)
	testing.expect_value(t, flex_b.w, 41)
	testing.expect_value(t, capped.w + flex_a.w + flex_b.w, 101)
}
