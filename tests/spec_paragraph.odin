package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 18
//          (Word-Wrapped Rich Text Paragraph & Markdown Document Viewer)
// =============================================================================

@(private="file")
s_wrap_spans := [1]bifrost.Styled_Span{
	{text = "The quick brown fox jumps over the lazy dog."},
}

@(private="file")
s_styled_spans := [3]bifrost.Styled_Span{
	{text = "Bifrost ", fg = bifrost.Color{kind = .RGB, r = 100, g = 200, b = 255}, style = {.Bold}},
	{text = "actor-driven ", fg = bifrost.Color{kind = .RGB, r = 240, g = 180, b = 80}, style = {.Italic}},
	{text = "TUI engine."},
}

@(private="file")
s_test_markdown :: `# Architecture Overview
Bifrost is an **actor-driven** TUI.

## Core Features
- Fast immediate-mode layout
- Sub-cell Braille graphics

> Sleipnir actor supervision tree

---
*Documentation v1.0*`

@(test)
@(scenario)
spec_paragraph_soft_word_wrapping_and_breaks :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 10)

	// Wrap 44-character sentence at width 16
	then.wrapped_lines_count_is(s_wrap_spans[:], 16, .Words, 3)
	then.wrapped_line_text_is(s_wrap_spans[:], 16, .Words, 0, "The quick brown")
	then.wrapped_line_text_is(s_wrap_spans[:], 16, .Words, 1, "fox jumps over")
	then.wrapped_line_text_is(s_wrap_spans[:], 16, .Words, 2, "the lazy dog.")
}

@(test)
@(scenario)
spec_paragraph_multispan_styling_preserved :: proc(t: ^testing.T) {
	_ = scenario(t, w = 40, h = 5)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(35), height = bifrost.fixed(3)}) {
			bifrost.ui_paragraph(ctx, scr, "para_styled", bifrost.Paragraph_Config{
				width     = bifrost.fixed(35),
				height    = bifrost.fixed(3),
				spans     = s_styled_spans[:],
				wrap_mode = .Words,
			})
		}
	})

	// Row 0 has "Bifrost actor-driven TUI engine."
	// Col 0: 'B' with Bold style and RGB(100, 200, 255)
	then.cell_at_is(0, 0, 'B', 1)
	then.cell_style_has(0, 0, .Bold, true)
	then.cell_colors_at_are(0, 0, bifrost.rgb(100, 200, 255), bifrost.Color{})

	// Col 8: 'a' in "actor-driven" with Italic style and RGB(240, 180, 80)
	then.cell_at_is(8, 0, 'a', 1)
	then.cell_style_has(8, 0, .Italic, true)
	then.cell_colors_at_are(8, 0, bifrost.rgb(240, 180, 80), bifrost.Color{})

	then.vt_contains_text("Bifrost actor-driven TUI engine.", true)
}

@(test)
@(scenario)
spec_markdown_parser_ast_elements :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 15)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(45), height = bifrost.fixed(12)}) {
			bifrost.ui_markdown(ctx, scr, "md_doc", s_test_markdown, bifrost.Markdown_Config{
				width     = bifrost.fixed(45),
				height    = bifrost.fixed(12),
				wrap_mode = .Words,
			})
		}
	})

	// Check H1 header
	then.vt_contains_text("Architecture Overview", true)

	// Check bullet list item
	then.vt_contains_text("• Fast immediate-mode layout", true)
	then.vt_contains_text("• Sub-cell Braille graphics", true)

	// Check blockquote
	then.vt_contains_text("│ Sleipnir actor supervision tree", true)

	// Check footer italic
	then.vt_contains_text("Documentation v1.0", true)

	// Verify unclosed inline markdown delimiters do not duplicate preceding text
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(45), height = bifrost.fixed(4)}) {
			bifrost.ui_markdown(ctx, scr, "md_unclosed", "Formula: 2 * 3 = 6", bifrost.Markdown_Config{
				width     = bifrost.fixed(45),
				height    = bifrost.fixed(4),
				wrap_mode = .Words,
			})
		}
	})
	then.vt_contains_text("Formula: 2 * 3 = 6", true)
	then.vt_contains_text("Formula: 2 Formula:", false)

	// Verify compound multi-span word ("**Bi**frost") wraps together and [label](url) parses label
	compound_spans := [3]bifrost.Styled_Span{
		{text = "Hello "},
		{text = "Bi", style = {.Bold}},
		{text = "frost"},
	}
	then.wrapped_lines_count_is(compound_spans[:], 10, .Words, 2)
	then.wrapped_line_text_is(compound_spans[:], 10, .Words, 0, "Hello")
	then.wrapped_line_text_is(compound_spans[:], 10, .Words, 1, "Bifrost")

	// Verify overlong multi-span compound word where span 0 equals exact line width (10)
	// commits line before starting span 1 instead of overflowing to width 11
	overlong_compound := [2]bifrost.Styled_Span{
		{text = "0123456789", style = {.Bold}},
		{text = "abcdef"},
	}
	then.wrapped_lines_count_is(overlong_compound[:], 10, .Words, 2)
	then.wrapped_line_text_is(overlong_compound[:], 10, .Words, 0, "0123456789")
	then.wrapped_line_text_is(overlong_compound[:], 10, .Words, 1, "abcdef")

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(45), height = bifrost.fixed(4)}) {
			bifrost.ui_markdown(ctx, scr, "md_link", "Visit [Bifrost Docs](https://example.com) now", bifrost.Markdown_Config{
				width  = bifrost.fixed(45),
				height = bifrost.fixed(4),
			})
		}
	})
	then.vt_contains_text("Visit Bifrost Docs now", true)
	then.vt_contains_text("https://example.com", false)

	// Verify nested Markdown sub-bullets preserve 2-space indentation ("  ⁃ ") and multiplication asterisks ("2 * 3 * 4") are not consumed as italics
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(45), height = bifrost.fixed(6)}) {
			bifrost.ui_markdown(ctx, scr, "md_nested_mul", "- Top\n  - Nested sub-item\nFormula: 2 * 3 * 4 = 24\n5 * x and **bold**", bifrost.Markdown_Config{
				width  = bifrost.fixed(45),
				height = bifrost.fixed(6),
			})
		}
	})
	then.vt_row_contains_text(1, "  ⁃ Nested sub-item", true)
	then.vt_contains_text("Formula: 2 * 3 * 4 = 24", true)
	then.vt_contains_text("5 * x and bold", true)

	// Verify ui_paragraph with width = grow(1) and height = nil dynamically resolves height in Pass 3 & 4 for narrow containers
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(16), height = bifrost.grow(1)}) {
			bifrost.ui_paragraph(ctx, scr, "para_narrow_grow", bifrost.Paragraph_Config{
				text = "The quick brown fox jumps over the lazy dog.",
			})
		}
	})
	then.node_rect_is("para_narrow_grow", bifrost.Rect{x = 0, y = 0, w = 16, h = 3})

	// Verify ui_markdown with default Markdown_Config{} (wrap_mode = .None -> .Words) dynamically resolves height in Pass 3 & 4,
	// and spaced interior '*' inside *a * b* parses as italic "a * b"
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(20), height = bifrost.grow(1)}) {
			bifrost.ui_markdown(ctx, scr, "md_narrow_grow", "Product *a * b* wraps across narrow lines cleanly.")
		}
	})
	then.node_rect_is("md_narrow_grow", bifrost.Rect{x = 0, y = 0, w = 20, h = 3})
	then.vt_contains_text("Product a * b wraps", true)
}
