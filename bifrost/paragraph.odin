package bifrost

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// =============================================================================
// Track 18: Word-Wrapped Rich Text Paragraph & Markdown Document Viewer
//           (`ui_paragraph`, `ui_markdown`)
// =============================================================================

Text_Span :: Styled_Span

Paragraph_Config :: struct {
	text:        string,
	spans:       []Styled_Span,
	wrap_mode:   Wrap_Mode,
	no_wrap:     bool,
	align:       Alignment,
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	border:      Border_Kind,
	border_fg:   Color,
	title:       string,
	title_fg:    Color,
	fg:          Color,
	bg:          Color,
	style:       Style_Flags,
}

Markdown_Config :: struct {
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	border:      Border_Kind,
	border_fg:   Color,
	title:       string,
	title_fg:    Color,
	fg:          Color,
	bg:          Color,
	h1_fg:       Color,
	h2_fg:       Color,
	h3_fg:       Color,
	bullet_fg:   Color,
	quote_fg:    Color,
	code_fg:     Color,
	code_bg:     Color,
	rule_fg:     Color,
	wrap_mode:   Wrap_Mode,
	no_wrap:     bool,
}

Paragraph_Render_Kind :: enum u8 {
	Paragraph = 0,
	Markdown  = 1,
}

Paragraph_Render_Entry :: struct {
	kind:         Paragraph_Render_Kind,
	para_cfg:     Paragraph_Config,
	md_cfg:       Markdown_Config,
	md_text:      string,
	cached_lines: [][]Styled_Span,
	cached_width: i32,
}

// Token for span word-wrapping
@(private)
Word_Token :: struct {
	text:       string,
	display_w:  i32,
	is_space:   bool,
	is_newline: bool,
	fg:         Color,
	bg:         Color,
	style:      Style_Flags,
	link_url:   string,
}

// Splits a slice of Styled_Spans into wrapped lines respecting width and wrap_mode
paragraph_wrap_spans :: proc(
	spans: []Styled_Span,
	width: i32,
	wrap_mode: Wrap_Mode,
	temp_alloc := context.temp_allocator,
) -> [][]Styled_Span {
	if width <= 0 || len(spans) == 0 {
		return nil
	}

	tokens := make([dynamic]Word_Token, 0, 32, temp_alloc)

	// 1. Tokenize spans into words, spaces, and hard newlines
	for sp in spans {
		txt := sp.text
		idx := 0
		for idx < len(txt) {
			b := txt[idx]
			if b == '\n' {
				append(&tokens, Word_Token{
					text       = "\n",
					display_w  = 0,
					is_newline = true,
					fg         = sp.fg,
					bg         = sp.bg,
					style      = sp.style,
					link_url   = sp.link_url,
				})
				idx += 1
			} else if b == ' ' || b == '\t' {
				start := idx
				for idx < len(txt) && (txt[idx] == ' ' || txt[idx] == '\t') {
					idx += 1
				}
				space_str := txt[start:idx]
				append(&tokens, Word_Token{
					text      = space_str,
					display_w = string_display_width(space_str),
					is_space  = true,
					fg        = sp.fg,
					bg        = sp.bg,
					style     = sp.style,
					link_url  = sp.link_url,
				})
			} else {
				start := idx
				for idx < len(txt) && txt[idx] != ' ' && txt[idx] != '\t' && txt[idx] != '\n' {
					idx += 1
				}
				word_str := txt[start:idx]
				append(&tokens, Word_Token{
					text      = word_str,
					display_w = string_display_width(word_str),
					fg        = sp.fg,
					bg        = sp.bg,
					style     = sp.style,
					link_url  = sp.link_url,
				})
			}
		}
	}

	// 2. Assemble lines respecting wrap width
	lines := make([dynamic][]Styled_Span, 0, 8, temp_alloc)
	cur_line := make([dynamic]Styled_Span, 0, 8, temp_alloc)
	cur_w: i32 = 0
	soft_wrapped := false

	commit_line :: proc(
		lines: ^[dynamic][]Styled_Span,
		cur_line: ^[dynamic]Styled_Span,
		cur_w: ^i32,
		soft_wrapped: ^bool,
		is_soft: bool,
		temp_alloc: mem.Allocator,
	) {
		// Trim trailing whitespace from the end of the line
		for len(cur_line^) > 0 {
			last_idx := len(cur_line^) - 1
			last := cur_line^[last_idx]
			trimmed := strings.trim_right_space(last.text)
			if len(trimmed) == 0 {
				pop(cur_line)
			} else {
				if len(trimmed) < len(last.text) {
					cur_line^[last_idx].text = trimmed
				}
				break
			}
		}

		line_copy := make([]Styled_Span, len(cur_line^), temp_alloc)
		copy(line_copy, cur_line^[:])
		append(lines, line_copy)
		clear(cur_line)
		cur_w^ = 0
		soft_wrapped^ = is_soft
	}

	t_idx := 0
	for t_idx < len(tokens) {
		tok := tokens[t_idx]
		if tok.is_newline {
			commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, false, temp_alloc)
			t_idx += 1
			continue
		}

		if wrap_mode == .None {
			append(&cur_line, Styled_Span{text = tok.text, fg = tok.fg, bg = tok.bg, style = tok.style, link_url = tok.link_url})
			cur_w += tok.display_w
			t_idx += 1
			continue
		}

		if tok.is_space {
			if cur_w == 0 && soft_wrapped {
				t_idx += 1
				continue
			}
			if cur_w + tok.display_w <= width {
				append(&cur_line, Styled_Span{text = tok.text, fg = tok.fg, bg = tok.bg, style = tok.style, link_url = tok.link_url})
				cur_w += tok.display_w
			} else {
				commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, true, temp_alloc)
			}
			t_idx += 1
			continue
		}

		// Group contiguous non-space, non-newline tokens (e.g. "**Bi**frost") into a single compound word
		group_end := t_idx + 1
		group_w := tok.display_w
		for group_end < len(tokens) && !tokens[group_end].is_space && !tokens[group_end].is_newline {
			group_w += tokens[group_end].display_w
			group_end += 1
		}

		if cur_w > 0 && cur_w + group_w > width {
			commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, true, temp_alloc)
		}

		if group_w <= width || wrap_mode != .Words {
			for k := t_idx; k < group_end; k += 1 {
				gt := tokens[k]
				append(&cur_line, Styled_Span{text = gt.text, fg = gt.fg, bg = gt.bg, style = gt.style, link_url = gt.link_url})
			}
			cur_w += group_w
			soft_wrapped = false
		} else {
			// Compound word exceeds full line width: character-split across lines
			for k := t_idx; k < group_end; k += 1 {
				gt := tokens[k]
				rem_text := gt.text
				for len(rem_text) > 0 {
					if cur_w >= width {
						commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, true, temp_alloc)
					}
					avail := max(i32(1), width - cur_w)
					take_len := 0
					take_w: i32 = 0
					for r in rem_text {
						rw := i32(rune_display_width(r))
						if take_w + rw > avail && (take_len > 0 || cur_w > 0) {
							break
						}
						take_len += utf8.rune_size(r)
						take_w += rw
					}
					if take_len == 0 {
						commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, true, temp_alloc)
						continue
					}
					chunk := rem_text[:take_len]
					rem_text = rem_text[take_len:]
					append(&cur_line, Styled_Span{text = chunk, fg = gt.fg, bg = gt.bg, style = gt.style, link_url = gt.link_url})
					cur_w += take_w
					soft_wrapped = false
					if len(rem_text) > 0 {
						commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, true, temp_alloc)
					}
				}
			}
		}
		t_idx = group_end
	}

	if len(cur_line) > 0 {
		commit_line(&lines, &cur_line, &cur_w, &soft_wrapped, false, temp_alloc)
	}

	return lines[:]
}

// Parses inline markdown formatting (**bold**, *italic*, `code`, [label](url)) into a slice of Styled_Spans
markdown_parse_inline :: proc(
	text: string,
	default_fg, default_bg: Color,
	default_style: Style_Flags,
	code_fg, code_bg: Color,
	temp_alloc := context.temp_allocator,
) -> []Styled_Span {
	spans := make([dynamic]Styled_Span, 0, 8, temp_alloc)
	i := 0
	start := 0

	for i < len(text) {
		// Check for `inline code`
		if text[i] == '`' {
			close_idx := strings.index_byte(text[i+1:], '`')
			if close_idx >= 0 {
				if i > start {
					append(&spans, Styled_Span{
						text  = text[start:i],
						fg    = default_fg,
						bg    = default_bg,
						style = default_style,
					})
				}
				code_str := text[i+1 : i+1+close_idx]
				append(&spans, Styled_Span{
					text  = code_str,
					fg    = code_fg,
					bg    = code_bg,
					style = default_style,
				})
				i += 1 + close_idx + 1
				start = i
				continue
			} else {
				i += 1
				continue
			}
		}

		// Check for [label](url) link syntax
		if text[i] == '[' {
			close_br := strings.index_byte(text[i+1:], ']')
			if close_br >= 0 {
				paren_pos := i + 1 + close_br + 1
				if paren_pos < len(text) && text[paren_pos] == '(' {
					close_paren := strings.index_byte(text[paren_pos+1:], ')')
					if close_paren >= 0 {
						if i > start {
							append(&spans, Styled_Span{
								text  = text[start:i],
								fg    = default_fg,
								bg    = default_bg,
								style = default_style,
							})
						}
						lbl_str := text[i+1 : i+1+close_br]
						url_str := text[paren_pos+1 : paren_pos+1+close_paren]
						append(&spans, Styled_Span{
							text     = lbl_str,
							fg       = rgb(95, 175, 255),
							bg       = default_bg,
							style    = default_style + {.Underline},
							link_url = url_str,
						})
						i = paren_pos + 1 + close_paren + 1
						start = i
						continue
					}
				}
			}
		}

		// Check for **bold**
		if i + 1 < len(text) && text[i] == '*' && text[i+1] == '*' {
			close_idx := strings.index(text[i+2:], "**")
			if close_idx >= 0 {
				if i > start {
					append(&spans, Styled_Span{
						text  = text[start:i],
						fg    = default_fg,
						bg    = default_bg,
						style = default_style,
					})
				}
				bold_str := text[i+2 : i+2+close_idx]
				append(&spans, Styled_Span{
					text  = bold_str,
					fg    = default_fg,
					bg    = default_bg,
					style = default_style + {.Bold},
				})
				i += 2 + close_idx + 2
				start = i
				continue
			} else {
				i += 2
				continue
			}
		}

		// Check for *italic* (require non-space after opening '*' and before closing '*', and closing '*' not part of '**')
		if text[i] == '*' && i + 1 < len(text) && text[i+1] != ' ' && text[i+1] != '\t' && text[i+1] != '*' {
			close_idx := -1
			for j := i + 1; j < len(text); j += 1 {
				if text[j] == '*' {
					if j + 1 < len(text) && text[j+1] == '*' {
						j += 1
						continue
					}
					if text[j-1] != ' ' && text[j-1] != '\t' {
						close_idx = j - (i + 1)
						break
					}
				}
			}
			if close_idx > 0 {
				if i > start {
					append(&spans, Styled_Span{
						text  = text[start:i],
						fg    = default_fg,
						bg    = default_bg,
						style = default_style,
					})
				}
				italic_str := text[i+1 : i+1+close_idx]
				append(&spans, Styled_Span{
					text  = italic_str,
					fg    = default_fg,
					bg    = default_bg,
					style = default_style + {.Italic},
				})
				i += 1 + close_idx + 1
				start = i
				continue
			} else {
				i += 1
				continue
			}
		}

		i += 1
	}

	if start < len(text) {
		append(&spans, Styled_Span{
			text  = text[start:],
			fg    = default_fg,
			bg    = default_bg,
			style = default_style,
		})
	}

	return spans[:]
}

// Parses full markdown document into styled lines with wrapping and structural decorations
markdown_parse_document :: proc(
	md: string,
	width: i32,
	cfg: Markdown_Config,
	temp_alloc := context.temp_allocator,
) -> [][]Styled_Span {
	lines := make([dynamic][]Styled_Span, 0, 16, temp_alloc)

	eff_wrap := cfg.wrap_mode if cfg.wrap_mode != .None else (.None if cfg.no_wrap else .Words)
	def_fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)
	def_bg := cfg.bg if cfg.bg.kind != .Default else Color{}
	h1_fg := cfg.h1_fg if cfg.h1_fg.kind != .Default else rgb(120, 200, 255)
	h2_fg := cfg.h2_fg if cfg.h2_fg.kind != .Default else rgb(160, 220, 255)
	h3_fg := cfg.h3_fg if cfg.h3_fg.kind != .Default else rgb(200, 230, 255)
	bullet_fg := cfg.bullet_fg if cfg.bullet_fg.kind != .Default else rgb(240, 180, 80)
	quote_fg := cfg.quote_fg if cfg.quote_fg.kind != .Default else rgb(160, 175, 195)
	code_fg := cfg.code_fg if cfg.code_fg.kind != .Default else rgb(245, 210, 120)
	code_bg := cfg.code_bg if cfg.code_bg.kind != .Default else rgb(35, 42, 54)
	rule_fg := cfg.rule_fg if cfg.rule_fg.kind != .Default else rgb(70, 80, 100)

	in_code_block := false
	code_lang := ""

	make_single_span :: proc(text: string, fg, bg: Color, style: Style_Flags, temp_alloc: mem.Allocator) -> []Styled_Span {
		spans := make([]Styled_Span, 1, temp_alloc)
		spans[0] = Styled_Span{text = text, fg = fg, bg = bg, style = style}
		return spans
	}

	raw_lines := strings.split(md, "\n", temp_alloc)
	for raw in raw_lines {
		line := strings.trim_right_space(raw)

		// Code fence toggle
		if strings.has_prefix(line, "```") {
			if !in_code_block {
				in_code_block = true
				code_lang = strings.trim_space(line[3:])
				header_text := fmt.tprintf("┌── %s ", code_lang) if len(code_lang) > 0 else "┌── "
				rem_w := max(i32(0), width - string_display_width(header_text) - 1)
				rule_str := strings.repeat("─", int(rem_w), temp_alloc)
				full_top := fmt.tprintf("%s%s┐", header_text, rule_str)
				append(&lines, make_single_span(full_top, rule_fg, def_bg, {}, temp_alloc))
			} else {
				in_code_block = false
				rem_w := max(i32(0), width - 2)
				rule_str := strings.repeat("─", int(rem_w), temp_alloc)
				full_bot := fmt.tprintf("└──%s┘", rule_str)
				append(&lines, make_single_span(full_bot, rule_fg, def_bg, {}, temp_alloc))
			}
			continue
		}

		if in_code_block {
			code_spans := make([]Styled_Span, 2, temp_alloc)
			code_spans[0] = Styled_Span{text = "│ ", fg = rule_fg, bg = def_bg}
			code_spans[1] = Styled_Span{text = strings.trim_right(raw, "\r"), fg = code_fg, bg = code_bg}
			append(&lines, code_spans)
			continue
		}

		// Empty line
		if len(line) == 0 {
			append(&lines, make_single_span("", def_fg, def_bg, {}, temp_alloc))
			continue
		}

		// Horizontal rule
		if line == "---" || line == "***" || line == "___" {
			rule_len := max(i32(1), width)
			rule_str := strings.repeat("─", int(rule_len), temp_alloc)
			append(&lines, make_single_span(rule_str, rule_fg, def_bg, {}, temp_alloc))
			continue
		}

		// ATX Headers
		if strings.has_prefix(line, "# ") {
			spans := markdown_parse_inline(line[2:], h1_fg, def_bg, {.Bold, .Underline}, code_fg, code_bg, temp_alloc)
			wrapped := paragraph_wrap_spans(spans, width, eff_wrap, temp_alloc)
			for w_line in wrapped {
				append(&lines, w_line)
			}
			continue
		}
		if strings.has_prefix(line, "## ") {
			spans := markdown_parse_inline(line[3:], h2_fg, def_bg, {.Bold}, code_fg, code_bg, temp_alloc)
			wrapped := paragraph_wrap_spans(spans, width, eff_wrap, temp_alloc)
			for w_line in wrapped {
				append(&lines, w_line)
			}
			continue
		}
		if strings.has_prefix(line, "### ") {
			spans := markdown_parse_inline(line[4:], h3_fg, def_bg, {.Italic}, code_fg, code_bg, temp_alloc)
			wrapped := paragraph_wrap_spans(spans, width, eff_wrap, temp_alloc)
			for w_line in wrapped {
				append(&lines, w_line)
			}
			continue
		}

		// Blockquotes
		if strings.has_prefix(line, "> ") {
			inline := markdown_parse_inline(line[2:], quote_fg, def_bg, {.Italic}, code_fg, code_bg, temp_alloc)
			quote_spans := make([dynamic]Styled_Span, 0, len(inline) + 1, temp_alloc)
			append(&quote_spans, Styled_Span{text = "│ ", fg = h2_fg, bg = def_bg, style = {.Bold}})
			for sp in inline {
				append(&quote_spans, sp)
			}
			wrapped := paragraph_wrap_spans(quote_spans[:], width, eff_wrap, temp_alloc)
			for w_line in wrapped {
				append(&lines, w_line)
			}
			continue
		}

		// Bullet lists
		if strings.has_prefix(line, "- ") || strings.has_prefix(line, "* ") {
			inline := markdown_parse_inline(line[2:], def_fg, def_bg, {}, code_fg, code_bg, temp_alloc)
			bullet_spans := make([dynamic]Styled_Span, 0, len(inline) + 1, temp_alloc)
			append(&bullet_spans, Styled_Span{text = "• ", fg = bullet_fg, bg = def_bg, style = {.Bold}})
			for sp in inline {
				append(&bullet_spans, sp)
			}
			wrapped := paragraph_wrap_spans(bullet_spans[:], width, eff_wrap, temp_alloc)
			for w_line in wrapped {
				append(&lines, w_line)
			}
			continue
		}
		if strings.has_prefix(line, "  - ") || strings.has_prefix(line, "  * ") {
			inline := markdown_parse_inline(line[4:], def_fg, def_bg, {}, code_fg, code_bg, temp_alloc)
			bullet_spans := make([dynamic]Styled_Span, 0, len(inline) + 1, temp_alloc)
			append(&bullet_spans, Styled_Span{text = "  ⁃ ", fg = bullet_fg, bg = def_bg})
			for sp in inline {
				append(&bullet_spans, sp)
			}
			wrapped := paragraph_wrap_spans(bullet_spans[:], width, eff_wrap, temp_alloc)
			for w_line in wrapped {
				append(&lines, w_line)
			}
			continue
		}

		// Standard paragraph line
		inline := markdown_parse_inline(line, def_fg, def_bg, {}, code_fg, code_bg, temp_alloc)
		wrapped := paragraph_wrap_spans(inline, width, eff_wrap, temp_alloc)
		for w_line in wrapped {
			append(&lines, w_line)
		}
	}

	return lines[:]
}

ui_paragraph :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	cfg: Paragraph_Config = {},
) -> i32 {
	id_h := hash_id(id)

	// Prepare spans if text provided
	para_cfg := cfg
	if para_cfg.wrap_mode == .None && !para_cfg.no_wrap {
		para_cfg.wrap_mode = .Words
	}
	if len(para_cfg.spans) == 0 && len(para_cfg.text) > 0 {
		def_fg := para_cfg.fg if para_cfg.fg.kind != .Default else Color{}
		def_bg := para_cfg.bg if para_cfg.bg.kind != .Default else Color{}
		temp_spans := make([]Styled_Span, 1, context.temp_allocator)
		temp_spans[0] = Styled_Span{
			text  = para_cfg.text,
			fg    = def_fg,
			bg    = def_bg,
			style = para_cfg.style,
		}
		para_cfg.spans = temp_spans
	} else if len(para_cfg.spans) > 0 {
		sp_copy := make([]Styled_Span, len(para_cfg.spans), context.temp_allocator)
		copy(sp_copy, para_cfg.spans)
		para_cfg.spans = sp_copy
	}

	// Calculate approximate intrinsic height (only pre-wrap during layout construction if width is Fixed or wrap_mode is .None)
	wrap_w: i32 = 40
	has_fixed_w := false
	if fixed_w, is_fixed := para_cfg.width.(Fixed); is_fixed && i32(fixed_w) > 0 {
		pad_x := para_cfg.padding.left + para_cfg.padding.right
		bdr_x: i32 = 2 if para_cfg.border != .None else 0
		wrap_w = max(1, i32(fixed_w) - pad_x - bdr_x)
		has_fixed_w = true
	} else if _, is_fit := para_cfg.width.(Fit); is_fit {
		max_line_w: i32 = 0
		cur_line_w: i32 = 0
		for sp in para_cfg.spans {
			rem := sp.text
			for {
				nl := strings.index_byte(rem, '\n')
				if nl < 0 {
					cur_line_w += string_display_width(rem)
					break
				}
				cur_line_w += string_display_width(rem[:nl])
				if cur_line_w > max_line_w {
					max_line_w = cur_line_w
				}
				cur_line_w = 0
				rem = rem[nl + 1:]
			}
		}
		if cur_line_w > max_line_w {
			max_line_w = cur_line_w
		}
		if max_line_w > 0 && max_line_w < wrap_w {
			wrap_w = max_line_w
		}
	}

	var_cached_lines: [][]Styled_Span = nil
	content_h: i32 = 1
	if para_cfg.height == nil && (has_fixed_w || para_cfg.wrap_mode == .None) {
		var_cached_lines = paragraph_wrap_spans(para_cfg.spans, wrap_w, para_cfg.wrap_mode, context.temp_allocator)
		content_h = i32(max(1, len(var_cached_lines)))
	}

	w := para_cfg.width if para_cfg.width != nil else grow(1)
	h := para_cfg.height if para_cfg.height != nil else fit(min = 1)

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = para_cfg.title,
			fg          = para_cfg.fg,
			bg          = para_cfg.bg,
			border_fg   = para_cfg.border_fg,
			title_fg    = para_cfg.title_fg,
			style       = para_cfg.style,
			title_style = {.Bold},
			fill_bg     = para_cfg.bg.kind != .Default,
		}
		s.paragraph_entries[id_h] = Paragraph_Render_Entry{
			kind         = .Paragraph,
			para_cfg     = para_cfg,
			cached_lines = var_cached_lines,
			cached_width = wrap_w if var_cached_lines != nil else 0,
		}
	}

	idx := leaf(ctx, id, wrap_w, content_h, Box_Config{
		width     = w,
		height    = h,
		padding   = para_cfg.padding,
		border    = para_cfg.border,
		wrap_mode = para_cfg.wrap_mode,
	})
	if idx >= 0 && int(idx) < len(ctx.nodes) {
		ctx.nodes[idx].para_spans = para_cfg.spans
	}
	return idx
}

ui_markdown :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	markdown: string,
	cfg: Markdown_Config = {},
) -> i32 {
	id_h := hash_id(id)
	md_cfg := cfg
	eff_wrap := md_cfg.wrap_mode if md_cfg.wrap_mode != .None else (.None if md_cfg.no_wrap else .Words)
	md_cfg.wrap_mode = eff_wrap

	wrap_w: i32 = 60
	has_fixed_w := false
	if fixed_w, is_fixed := md_cfg.width.(Fixed); is_fixed && i32(fixed_w) > 0 {
		pad_x := md_cfg.padding.left + md_cfg.padding.right
		bdr_x: i32 = 2 if md_cfg.border != .None else 0
		wrap_w = max(1, i32(fixed_w) - pad_x - bdr_x)
		has_fixed_w = true
	} else if _, is_fit := md_cfg.width.(Fit); is_fit {
		max_line_w: i32 = 0
		rem := markdown
		for {
			nl := strings.index_byte(rem, '\n')
			if nl < 0 {
				w_l := string_display_width(strings.trim_right(rem, "\r"))
				if w_l > max_line_w {
					max_line_w = w_l
				}
				break
			}
			w_l := string_display_width(strings.trim_right(rem[:nl], "\r"))
			if w_l > max_line_w {
				max_line_w = w_l
			}
			rem = rem[nl + 1:]
		}
		if max_line_w > 0 && max_line_w < wrap_w {
			wrap_w = max_line_w
		}
	}

	var_cached_lines: [][]Styled_Span = nil
	content_h: i32 = 1
	if md_cfg.height == nil && (has_fixed_w || eff_wrap == .None) {
		var_cached_lines = markdown_parse_document(markdown, wrap_w, md_cfg, context.temp_allocator)
		content_h = i32(max(1, len(var_cached_lines)))
	}

	w := md_cfg.width if md_cfg.width != nil else grow(1)
	h := md_cfg.height if md_cfg.height != nil else fit(min = 1)

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = md_cfg.title,
			fg          = md_cfg.fg,
			bg          = md_cfg.bg,
			border_fg   = md_cfg.border_fg,
			title_fg    = md_cfg.title_fg,
			title_style = {.Bold},
			fill_bg     = md_cfg.bg.kind != .Default,
		}
		s.paragraph_entries[id_h] = Paragraph_Render_Entry{
			kind         = .Markdown,
			md_cfg       = md_cfg,
			md_text      = markdown,
			cached_lines = var_cached_lines,
			cached_width = wrap_w if var_cached_lines != nil else 0,
		}
	}

	idx := leaf(ctx, id, wrap_w, content_h, Box_Config{
		width     = w,
		height    = h,
		padding   = md_cfg.padding,
		border    = md_cfg.border,
		wrap_mode = eff_wrap,
	})
	if idx >= 0 && int(idx) < len(ctx.nodes) {
		ctx.nodes[idx].md_source    = markdown
		ctx.nodes[idx].md_cfg       = md_cfg
		ctx.nodes[idx].has_markdown = true
	}
	return idx
}

@(private)
render_paragraph_entry :: proc(
	s: ^Screen,
	node: Layout_Node,
	paint: Paint_Spec,
	entry: Paragraph_Render_Entry,
	temp_alloc: mem.Allocator,
) {
	inner := node.inner_rect
	clip  := node.inner_clip
	if inner.w <= 0 || inner.h <= 0 || clip.w <= 0 || clip.h <= 0 {
		return
	}

	switch entry.kind {
	case .Paragraph:
		cfg := entry.para_cfg
		lines: [][]Styled_Span
		if node.wrapped_span_lines != nil && node.wrapped_span_w == inner.w {
			lines = node.wrapped_span_lines
		} else if entry.cached_lines != nil && entry.cached_width == inner.w {
			lines = entry.cached_lines
		} else {
			lines = paragraph_wrap_spans(cfg.spans, inner.w, cfg.wrap_mode, temp_alloc)
		}
		for line, line_idx in lines {
			sy := inner.y + i32(line_idx)
			if sy < clip.y || sy >= clip.y + clip.h {
				continue
			}

			// Measure line display width
			line_w: i32 = 0
			for sp in line {
				line_w += string_display_width(sp.text)
			}

			// Calculate start_x based on alignment
			start_x := inner.x
			switch cfg.align {
			case .Start:
				start_x = inner.x
			case .Center:
				start_x = inner.x + max(i32(0), (inner.w - line_w) / 2)
			case .End:
				start_x = inner.x + max(i32(0), inner.w - line_w)
			}

			cur_x := start_x
			for sp in line {
				eff_fg := sp.fg if sp.fg.kind != .Default else (cfg.fg if cfg.fg.kind != .Default else paint.fg)
				eff_bg := sp.bg if sp.bg.kind != .Default else (cfg.bg if cfg.bg.kind != .Default else paint.bg)
				eff_st := cfg.style + sp.style
				link_u := sp.link_url if len(sp.link_url) > 0 else paint.url
				draw_string_clipped(s, cur_x, sy, clip, sp.text, eff_fg, eff_bg, eff_st, link_u)
				cur_x += string_display_width(sp.text)
			}
		}

	case .Markdown:
		cfg := entry.md_cfg
		lines: [][]Styled_Span
		if node.wrapped_span_lines != nil && node.wrapped_span_w == inner.w {
			lines = node.wrapped_span_lines
		} else if entry.cached_lines != nil && entry.cached_width == inner.w {
			lines = entry.cached_lines
		} else {
			lines = markdown_parse_document(entry.md_text, inner.w, cfg, temp_alloc)
		}
		for line, line_idx in lines {
			sy := inner.y + i32(line_idx)
			if sy < clip.y || sy >= clip.y + clip.h {
				continue
			}

			cur_x := inner.x
			for sp in line {
				if len(sp.text) == 0 {
					continue
				}
				eff_fg := sp.fg if sp.fg.kind != .Default else (cfg.fg if cfg.fg.kind != .Default else paint.fg)
				eff_bg := sp.bg if sp.bg.kind != .Default else (cfg.bg if cfg.bg.kind != .Default else paint.bg)
				link_u := sp.link_url if len(sp.link_url) > 0 else paint.url
				draw_string_clipped(s, cur_x, sy, clip, sp.text, eff_fg, eff_bg, sp.style, link_u)
				cur_x += string_display_width(sp.text)
			}
		}
	}
}
