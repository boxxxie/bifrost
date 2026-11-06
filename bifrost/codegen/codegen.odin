package bifrost_codegen

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// =============================================================================
// Bifrost Tier 2 AST Metaprogramming Generator (`core:odin/parser` + `core:odin/ast`)
//
// Discovers:
//   1. `@(ui_actions)` structs (reading `` `bifrost:"..."` `` field tags)
//   2. `@(ui_action="...")` + optional `@(ui_scope="...")` handler procedures
//      taking `self: ^App_Type`
//
// Validates all `key=...` chord expressions at codegen time with exact `file:line`
// diagnostics and emits `<pkg_dir>/ui_actions_gen.odin` with zero-reflection
// `init_<type>_keymap_and_palette`, `dispatch_<app>_action`, and `dispatch_ui_actions`.
// =============================================================================

Codegen_Diagnostic :: struct {
	file:    string,
	line:    int,
	column:  int,
	message: string,
}

destroy_diagnostics :: proc(diags: ^[dynamic]Codegen_Diagnostic) {
	if diags == nil {
		return
	}
	for d in diags^ {
		delete(d.file)
		delete(d.message)
	}
	delete(diags^)
	diags^ = nil
}

@(private)
Parsed_Tag_Spec :: struct {
	action_name:     string,
	chord_spec:      string,
	chord_vim:       string,
	chord_helix:     string,
	chord_emacs:     string,
	scope:           string,
	policy_expr:     string, // ".Root_And_Scopes", ".Scope_Only", ".Global_Always"
	allow_in_edit:   bool,
	has_submode:     bool,
	submode:         u8,
	group:           string,
	group_desc:      string,
	compact:         bool,
	desc:            string,
	desc_vim:        string,
	desc_helix:      string,
	desc_emacs:      string,
	label:           string,
	category:        string,
	show_in_bar:     bool,
	hide_in_bar:     bool,
	show_in_palette: bool,
	hide_in_palette: bool,
}

@(private)
Struct_Action_Group :: struct {
	name:    string,
	entries: [dynamic]Parsed_Tag_Spec,
}

@(private)
Handler_Action :: struct {
	proc_name: string,
	app_type:  string,
	spec:      Parsed_Tag_Spec,
}

@(private)
App_Action_Group :: struct {
	app_type: string,
	handlers: [dynamic]Handler_Action,
}

@(private)
Codegen_Module :: struct {
	package_name:   string,
	bifrost_import: string,
	bifrost_alias:  string,
	struct_groups:  [dynamic]Struct_Action_Group,
	app_groups:     [dynamic]App_Action_Group,
	ast_arena:      mem.Dynamic_Arena,
}

@(private)
init_codegen_module :: proc(m: ^Codegen_Module) {
	m.struct_groups = make([dynamic]Struct_Action_Group)
	m.app_groups    = make([dynamic]App_Action_Group)
	mem.dynamic_arena_init(&m.ast_arena)
}

@(private)
destroy_codegen_module :: proc(m: ^Codegen_Module) {
	for &sg in m.struct_groups {
		delete(sg.entries)
	}
	delete(m.struct_groups)
	for &ag in m.app_groups {
		delete(ag.handlers)
	}
	delete(m.app_groups)
	mem.dynamic_arena_destroy(&m.ast_arena)
}

to_snake_case :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		if ch >= 'A' && ch <= 'Z' {
			if i > 0 && s[i - 1] != '_' && !(s[i - 1] >= 'A' && s[i - 1] <= 'Z') {
				strings.write_byte(&b, '_')
			}
			strings.write_byte(&b, ch + ('a' - 'A'))
		} else {
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

@(private)
append_diagnostic :: proc(
	diags: ^[dynamic]Codegen_Diagnostic,
	file: string,
	line, col: int,
	msg: string,
) {
	if diags == nil {
		return
	}
	append(diags, Codegen_Diagnostic{
		file    = strings.clone(file),
		line    = line,
		column  = col,
		message = strings.clone(msg),
	})
}

@(private)
get_decl_attribute :: proc(
	decl: ^ast.Value_Decl,
	attr_name: string,
) -> (val: string, pos: tokenizer.Pos, found: bool) {
	for attr in decl.attributes {
		for elem in attr.elems {
			#partial switch e in elem.derived {
			case ^ast.Ident:
				if e.name == attr_name {
					return "", e.pos, true
				}
			case ^ast.Field_Value:
				if ident, ok := e.field.derived.(^ast.Ident); ok && ident.name == attr_name {
					if lit, lit_ok := e.value.derived.(^ast.Basic_Lit); lit_ok {
						return unquote_ast_string(lit.tok.text), e.pos, true
					}
					if v_ident, v_ok := e.value.derived.(^ast.Ident); v_ok {
						return v_ident.name, e.pos, true
					}
					return "", e.pos, true
				}
			}
		}
	}
	return "", {}, false
}

@(private)
unquote_ast_string :: proc(raw: string) -> string {
	if len(raw) >= 2 {
		if (raw[0] == '"' && raw[len(raw) - 1] == '"') || (raw[0] == '`' && raw[len(raw) - 1] == '`') {
			return raw[1 : len(raw) - 1]
		}
	}
	return raw
}

@(private)
extract_bifrost_struct_tag :: proc(raw_tag_tok: string) -> (string, bool) {
	tag := unquote_ast_string(raw_tag_tok)
	key_prefix := `bifrost:"`
	idx := strings.index(tag, key_prefix)
	if idx < 0 {
		return "", false
	}
	rest := tag[idx + len(key_prefix):]
	end_q := strings.index_byte(rest, '"')
	if end_q < 0 {
		return "", false
	}
	return rest[:end_q], true
}

@(private)
node_source :: proc(src: string, node: ^ast.Node) -> string {
	if node == nil {
		return ""
	}
	start := node.pos.offset
	end   := node.end.offset
	if start >= 0 && end >= start && end <= len(src) {
		return strings.trim_space(src[start:end])
	}
	return ""
}

@(private)
import_local_alias :: proc(imp: ^ast.Import_Decl) -> string {
	if imp.name.text != "" {
		return imp.name.text
	}
	clean := strings.trim(imp.fullpath, "\"")
	if colon := strings.last_index_byte(clean, ':'); colon >= 0 {
		clean = clean[colon + 1:]
	}
	if slash := strings.last_index_byte(clean, '/'); slash >= 0 {
		clean = clean[slash + 1:]
	}
	return clean
}

@(private)
extract_pointer_ident :: proc(expr: ^ast.Expr) -> (string, bool) {
	if expr == nil {
		return "", false
	}
	if ptr, ok := expr.derived.(^ast.Pointer_Type); ok {
		if ident, ident_ok := ptr.elem.derived.(^ast.Ident); ident_ok {
			return ident.name, true
		}
	}
	return "", false
}

// =============================================================================
// Standalone Compile-Time Chord Syntax Validator (`core:*` only)
// =============================================================================

validate_key_chord_syntax :: proc(spec: string) -> bool {
	trimmed := strings.trim_space(spec)
	if len(trimmed) == 0 {
		return false
	}

	alt_count := 0
	start := 0
	for i := 0; i <= len(trimmed); i += 1 {
		if i == len(trimmed) || trimmed[i] == '|' {
			alt_str := strings.trim_space(trimmed[start:i])
			if len(alt_str) == 0 || alt_count >= 4 {
				return false
			}
			if !validate_chord_sequence(alt_str) {
				return false
			}
			alt_count += 1
			start = i + 1
		}
	}
	return alt_count > 0
}

@(private)
validate_chord_sequence :: proc(alt_str: string) -> bool {
	steps := 0
	idx := 0
	for idx < len(alt_str) {
		for idx < len(alt_str) && (alt_str[idx] == ' ' || alt_str[idx] == '\t') {
			idx += 1
		}
		if idx >= len(alt_str) {
			break
		}
		tok_start := idx
		if alt_str[idx] == '<' {
			for idx < len(alt_str) && alt_str[idx] != '>' {
				idx += 1
			}
			if idx >= len(alt_str) {
				return false
			}
			idx += 1
			if idx < len(alt_str) && alt_str[idx] != ' ' && alt_str[idx] != '\t' {
				return false
			}
		} else {
			for idx < len(alt_str) && alt_str[idx] != ' ' && alt_str[idx] != '\t' {
				idx += 1
			}
		}
		if steps >= 2 || !validate_single_key_token(alt_str[tok_start:idx]) {
			return false
		}
		steps += 1
	}
	return steps >= 1 && steps <= 2
}

@(private)
validate_single_key_token :: proc(tok: string) -> bool {
	if len(tok) == 0 {
		return false
	}
	if tok[0] == '<' {
		if len(tok) < 3 || tok[len(tok) - 1] != '>' {
			return false
		}
		inner := tok[1 : len(tok) - 1]
		for i := 0; i < len(inner); i += 1 {
			if inner[i] == '<' || inner[i] == '>' || inner[i] == ' ' || inner[i] == '\t' {
				return false
			}
		}
		for len(inner) >= 2 && inner[1] == '-' {
			switch inner[0] {
			case 'C', 'c', 'M', 'm', 'A', 'a', 'S', 's', 'D', 'd':
			case:
				return false
			}
			inner = inner[2:]
		}
		if len(inner) == 0 {
			return false
		}
		if is_valid_named_key(inner) {
			return true
		}
		r, w := utf8.decode_rune_in_string(inner)
		return r != utf8.RUNE_ERROR && w == len(inner)
	}

	for i := 0; i < len(tok); i += 1 {
		if tok[i] == '<' || tok[i] == '>' {
			return false
		}
	}
	r, w := utf8.decode_rune_in_string(tok)
	return r != utf8.RUNE_ERROR && w == len(tok)
}

@(private)
is_valid_named_key :: proc(name: string) -> bool {
	known := [?]string{
		"enter", "cr", "return", "esc", "escape", "space", "tab",
		"bs", "backspace", "del", "delete", "ins", "insert",
		"up", "down", "left", "right", "home", "end",
		"pgup", "pageup", "page_up", "pgdn", "pagedown", "page_down",
		"bar", "pipe", "comma", "lt", "gt",
		"f1", "f2", "f3", "f4", "f5", "f6",
		"f7", "f8", "f9", "f10", "f11", "f12",
	}
	for k in known {
		if strings.equal_fold(name, k) {
			return true
		}
	}
	return false
}

@(private)
next_tag_pair_end :: proc(tag_str: string, start: int) -> int {
	in_quote := false
	for i := start; i < len(tag_str); i += 1 {
		if tag_str[i] == '\\' && i + 1 < len(tag_str) {
			i += 1
			continue
		}
		if tag_str[i] == '\'' {
			in_quote = !in_quote
			continue
		}
		if !in_quote && tag_str[i] == ',' {
			rest := strings.trim_space(tag_str[i + 1:])
			is_next_kv := strings.equal_fold(rest, "compact") || strings.has_prefix(rest, "compact,")
			if !is_next_kv {
				for j := 0; j < len(rest); j += 1 {
					c := rest[j]
					if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
						continue
					}
					if c == '=' && j > 0 {
						is_next_kv = true
					}
					break
				}
			}
			if is_next_kv {
				return i
			}
		}
	}
	return len(tag_str)
}

@(private)
unquote_single_quoted :: proc(v: string) -> string {
	if len(v) >= 2 && v[0] == '\'' && v[len(v) - 1] == '\'' {
		return v[1 : len(v) - 1]
	}
	return v
}

@(private)
parse_tag_kv :: proc(tag_str: string, fallback_name: string, default_scope: string = "") -> Parsed_Tag_Spec {
	spec := Parsed_Tag_Spec{
		action_name     = fallback_name,
		scope           = default_scope,
		policy_expr     = ".Root_And_Scopes",
		show_in_bar     = true,
		show_in_palette = true,
	}

	start := 0
	for start <= len(tag_str) {
		end := next_tag_pair_end(tag_str, start)
		pair := strings.trim_space(tag_str[start:end])
		start = end + 1
		if len(pair) == 0 {
			continue
		}
		eq := strings.index_byte(pair, '=')
		if eq < 0 {
			if strings.equal_fold(pair, "compact") {
				spec.compact = true
			}
			continue
		}
		k := strings.trim_space(pair[:eq])
		v := unquote_single_quoted(strings.trim_space(pair[eq + 1:]))
		if strings.equal_fold(k, "key") || strings.equal_fold(k, "chord") {
			spec.chord_spec = v
		} else if strings.equal_fold(k, "vim") {
			spec.chord_vim = v
		} else if strings.equal_fold(k, "helix") {
			spec.chord_helix = v
		} else if strings.equal_fold(k, "emacs") {
			spec.chord_emacs = v
		} else if strings.equal_fold(k, "id") || strings.equal_fold(k, "action") {
			spec.action_name = v
		} else if strings.equal_fold(k, "scope") {
			spec.scope = v
		} else if strings.equal_fold(k, "group") {
			spec.group = v
		} else if strings.equal_fold(k, "group_desc") {
			spec.group_desc = v
		} else if strings.equal_fold(k, "compact") {
			spec.compact = strings.equal_fold(v, "true") || v == "1"
		} else if strings.equal_fold(k, "desc") {
			spec.desc = v
		} else if strings.equal_fold(k, "desc_vim") {
			spec.desc_vim = v
		} else if strings.equal_fold(k, "desc_helix") {
			spec.desc_helix = v
		} else if strings.equal_fold(k, "desc_emacs") {
			spec.desc_emacs = v
		} else if strings.equal_fold(k, "label") {
			spec.label = v
		} else if strings.equal_fold(k, "category") {
			spec.category = v
		} else if strings.equal_fold(k, "policy") {
			if strings.equal_fold(v, "global") || strings.equal_fold(v, "global_always") {
				spec.policy_expr = ".Global_Always"
			} else if strings.equal_fold(v, "scope") || strings.equal_fold(v, "scope_only") {
				spec.policy_expr = ".Scope_Only"
			}
		} else if strings.equal_fold(k, "allow_in_edit") || strings.equal_fold(k, "allow_in_text_input") {
			spec.allow_in_edit = strings.equal_fold(v, "true") || v == "1"
		} else if strings.equal_fold(k, "submode") {
			if len(v) > 0 && v[0] >= '0' && v[0] <= '9' {
				acc := 0
				valid := true
				for c_idx := 0; c_idx < len(v); c_idx += 1 {
					if v[c_idx] < '0' || v[c_idx] > '9' {
						valid = false
						break
					}
					acc = acc * 10 + int(v[c_idx] - '0')
				}
				if valid && acc <= 255 {
					spec.has_submode = true
					spec.submode     = u8(acc)
				}
			}
		} else if strings.equal_fold(k, "hint") || strings.equal_fold(k, "bar") {
			if strings.equal_fold(v, "false") || v == "0" {
				spec.show_in_bar = false
				spec.hide_in_bar = true
			}
		} else if strings.equal_fold(k, "palette") {
			if strings.equal_fold(v, "false") || v == "0" {
				spec.show_in_palette = false
				spec.hide_in_palette = true
			}
		}
	}

	if len(spec.chord_spec) == 0 && len(spec.chord_vim) > 0 {
		spec.chord_spec = spec.chord_vim
	}
	if len(spec.chord_vim) == 0 && len(spec.chord_spec) > 0 {
		spec.chord_vim = spec.chord_spec
	}
	if len(spec.desc) == 0 && len(spec.desc_vim) > 0 {
		spec.desc = spec.desc_vim
	}
	if len(spec.desc_vim) == 0 && len(spec.desc) > 0 {
		spec.desc_vim = spec.desc
	}
	if len(spec.scope) > 0 && spec.policy_expr == ".Root_And_Scopes" {
		spec.policy_expr = ".Scope_Only"
	}
	return spec
}

@(private)
validate_parsed_spec_chords :: proc(spec: Parsed_Tag_Spec, require_chord: bool) -> (bad_chord: string, ok: bool) {
	if require_chord && len(spec.chord_spec) == 0 && len(spec.chord_vim) == 0 && len(spec.chord_helix) == 0 && len(spec.chord_emacs) == 0 {
		return "", false
	}
	chords := [4]string{spec.chord_spec, spec.chord_vim, spec.chord_helix, spec.chord_emacs}
	for c in chords {
		if len(c) > 0 && !validate_key_chord_syntax(c) {
			return c, false
		}
	}
	return "", true
}

@(private)
chord_strings_conflict :: proc(c_a, c_b: string) -> (conflict_alt: string, found: bool) {
	if len(c_a) == 0 || len(c_b) == 0 {
		return "", false
	}
	a_start := 0
	for i := 0; i <= len(c_a); i += 1 {
		if i == len(c_a) || c_a[i] == '|' {
			a_alt := strings.trim_space(c_a[a_start:i])
			a_start = i + 1
			if len(a_alt) == 0 {
				continue
			}
			b_start := 0
			for j := 0; j <= len(c_b); j += 1 {
				if j == len(c_b) || c_b[j] == '|' {
					b_alt := strings.trim_space(c_b[b_start:j])
					b_start = j + 1
					if len(b_alt) > 0 && strings.equal_fold(a_alt, b_alt) {
						return a_alt, true
					}
				}
			}
		}
	}
	return "", false
}

@(private)
specs_have_chord_conflict :: proc(a, b: Parsed_Tag_Spec) -> (conflict_alt: string, found: bool) {
	if a.scope != b.scope || a.policy_expr != b.policy_expr || a.has_submode != b.has_submode || a.submode != b.submode {
		return "", false
	}
	pairs := [4][2]string{
		{a.chord_spec,  b.chord_spec},
		{a.chord_vim,   b.chord_vim},
		{a.chord_helix, b.chord_helix},
		{a.chord_emacs, b.chord_emacs},
	}
	for p in pairs {
		if alt, ok := chord_strings_conflict(p[0], p[1]); ok {
			return alt, true
		}
	}
	return "", false
}

// =============================================================================
// AST Parsing & Code Emission
// =============================================================================

@(private)
parse_source_into_module :: proc(
	src: string,
	filename: string,
	mod: ^Codegen_Module,
	diags: ^[dynamic]Codegen_Diagnostic,
) -> bool {
	arena_alloc := mem.dynamic_arena_allocator(&mod.ast_arena)
	p := parser.default_parser()
	file: ^ast.File
	parse_ok := false
	{
		context.allocator = arena_alloc
		file = ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
		file.src      = src
		file.fullpath = filename
		parse_ok = parser.parse_file(&p, file) && p.error_count == 0
	}
	if !parse_ok {
		msg := fmt.tprintf("failed to parse Odin file (%d syntax errors)", p.error_count)
		append_diagnostic(diags, filename, 1, 1, msg)
		return false
	}

	if len(mod.package_name) == 0 && file.pkg_name != "" {
		mod.package_name = file.pkg_name
	}

	all_valid := true

	for decl_stmt in file.decls {
		#partial switch d in decl_stmt.derived {
		case ^ast.Import_Decl:
			alias := import_local_alias(d)
			if alias == "bifrost" || strings.has_suffix(d.fullpath, "bifrost\"") || strings.has_suffix(d.fullpath, "/bifrost\"") {
				mod.bifrost_import = node_source(src, d)
				mod.bifrost_alias  = alias
			}

		case ^ast.Value_Decl:
			if d.is_mutable || len(d.names) == 0 || len(d.values) == 0 {
				continue
			}
			ident, ok := d.names[0].derived.(^ast.Ident)
			if !ok {
				continue
			}

			// 1. `@(ui_actions)` struct declaration
			if _, _, is_actions := get_decl_attribute(d, "ui_actions"); is_actions {
				if st, is_struct := d.values[0].derived.(^ast.Struct_Type); is_struct && st.fields != nil {
					grp := Struct_Action_Group{
						name    = ident.name,
						entries = make([dynamic]Parsed_Tag_Spec),
					}
					for field in st.fields.list {
						if field.tag.text == "" {
							continue
						}
						tag_body, has_bf := extract_bifrost_struct_tag(field.tag.text)
						if !has_bf {
							continue
						}
						for fname_expr in field.names {
							f_ident, f_ok := fname_expr.derived.(^ast.Ident)
							if !f_ok {
								continue
							}
							spec := parse_tag_kv(tag_body, f_ident.name)
							if bad_c, c_ok := validate_parsed_spec_chords(spec, false); !c_ok {
								msg := fmt.tprintf("invalid key chord %q in %s.%s", bad_c, ident.name, f_ident.name)
								append_diagnostic(diags, filename, field.pos.line, field.pos.column, msg)
								all_valid = false
								continue
							}
							conflict := false
							for prev in grp.entries {
								if dup_alt, has_dup := specs_have_chord_conflict(prev, spec); has_dup {
									msg := fmt.tprintf(
										"duplicate key chord %q in %s: %q conflicts with %q in scope %q",
										dup_alt,
										ident.name,
										spec.action_name,
										prev.action_name,
										spec.scope if len(spec.scope) > 0 else "<root>",
									)
									append_diagnostic(diags, filename, field.pos.line, field.pos.column, msg)
									all_valid = false
									conflict  = true
									break
								}
							}
							if conflict {
								continue
							}
							append(&grp.entries, spec)
						}
					}
					append(&mod.struct_groups, grp)
				}
				continue
			}

			// 2. `@(ui_action="...")` + optional `@(ui_scope="...")` procedure declaration
			if action_attr, attr_pos, is_action := get_decl_attribute(d, "ui_action"); is_action {
				scope_attr, _, _ := get_decl_attribute(d, "ui_scope")
				proc_lit, is_proc := d.values[0].derived.(^ast.Proc_Lit)
				if !is_proc || proc_lit.type == nil || proc_lit.type.params == nil ||
				   len(proc_lit.type.params.list) != 1 || len(proc_lit.type.params.list[0].names) > 1 {
					msg := fmt.tprintf("@(ui_action) procedure '%s' must take exactly one receiver pointer `self: ^App_Type`", ident.name)
					append_diagnostic(diags, filename, d.pos.line, d.pos.column, msg)
					all_valid = false
					continue
				}

				first_param := proc_lit.type.params.list[0]
				app_type, ptr_ok := extract_pointer_ident(first_param.type)
				if !ptr_ok || len(app_type) == 0 {
					msg := fmt.tprintf("@(ui_action) procedure '%s' first parameter must be a struct pointer `^App_Type`", ident.name)
					append_diagnostic(diags, filename, first_param.pos.line, first_param.pos.column, msg)
					all_valid = false
					continue
				}

				spec := parse_tag_kv(action_attr, ident.name, scope_attr)
				if bad_c, c_ok := validate_parsed_spec_chords(spec, true); !c_ok {
					diag_line := attr_pos.line if attr_pos.line > 0 else d.pos.line
					diag_col  := attr_pos.column if attr_pos.column > 0 else d.pos.column
					msg := fmt.tprintf("invalid key chord %q on @(ui_action) '%s'", bad_c, ident.name)
					append_diagnostic(diags, filename, diag_line, diag_col, msg)
					all_valid = false
					continue
				}

				conflict := false
				for ag in mod.app_groups {
					if ag.app_type != app_type {
						continue
					}
					for prev_h in ag.handlers {
						if dup_alt, has_dup := specs_have_chord_conflict(prev_h.spec, spec); has_dup {
							diag_line := attr_pos.line if attr_pos.line > 0 else d.pos.line
							diag_col  := attr_pos.column if attr_pos.column > 0 else d.pos.column
							msg := fmt.tprintf(
								"duplicate key chord %q on @(ui_action) '%s': conflicts with '%s' in scope %q",
								dup_alt,
								ident.name,
								prev_h.proc_name,
								spec.scope if len(spec.scope) > 0 else "<root>",
							)
							append_diagnostic(diags, filename, diag_line, diag_col, msg)
							all_valid = false
							conflict  = true
							break
						}
					}
				}
				if conflict {
					continue
				}

				append_handler_to_app_group(mod, Handler_Action{
					proc_name = ident.name,
					app_type  = app_type,
					spec      = spec,
				})
			}
		}
	}

	return all_valid
}

@(private)
append_handler_to_app_group :: proc(mod: ^Codegen_Module, h: Handler_Action) {
	for &ag in mod.app_groups {
		if ag.app_type == h.app_type {
			append(&ag.handlers, h)
			return
		}
	}
	ag := App_Action_Group{
		app_type = h.app_type,
		handlers = make([dynamic]Handler_Action),
	}
	append(&ag.handlers, h)
	append(&mod.app_groups, ag)
}

@(private)
emit_spec_registration_call :: proc(sb: ^strings.Builder, bf: string, spec: Parsed_Tag_Spec) {
	fmt.sbprintf(sb, "\t_ = %s.register_action_spec(inp, cp, %s.Action_Spec{{\n", bf, bf)
	fmt.sbprintf(sb, "\t\taction_name     = %q,\n", spec.action_name)
	if len(spec.chord_spec) > 0 {
		fmt.sbprintf(sb, "\t\tchord_spec      = %q,\n", spec.chord_spec)
	}
	if len(spec.chord_vim) > 0 {
		fmt.sbprintf(sb, "\t\tchord_vim       = %q,\n", spec.chord_vim)
	}
	if len(spec.chord_helix) > 0 {
		fmt.sbprintf(sb, "\t\tchord_helix     = %q,\n", spec.chord_helix)
	}
	if len(spec.chord_emacs) > 0 {
		fmt.sbprintf(sb, "\t\tchord_emacs     = %q,\n", spec.chord_emacs)
	}
	if len(spec.scope) > 0 {
		fmt.sbprintf(sb, "\t\tscope           = %q,\n", spec.scope)
	}
	fmt.sbprintf(sb, "\t\tpolicy          = %s,\n", spec.policy_expr)
	if spec.allow_in_edit {
		fmt.sbprintln(sb, "\t\tflags           = {.Allow_In_Text_Input},")
	}
	if spec.has_submode {
		fmt.sbprintln(sb, "\t\thas_submode     = true,")
		fmt.sbprintf(sb, "\t\tsubmode         = %d,\n", spec.submode)
	}
	if len(spec.group) > 0 {
		fmt.sbprintf(sb, "\t\tgroup           = %q,\n", spec.group)
	}
	if len(spec.group_desc) > 0 {
		fmt.sbprintf(sb, "\t\tgroup_desc      = %q,\n", spec.group_desc)
	}
	if spec.compact {
		fmt.sbprintln(sb, "\t\tcompact         = true,")
		fmt.sbprintln(sb, "\t\thas_compact     = true,")
	}
	if len(spec.desc) > 0 {
		fmt.sbprintf(sb, "\t\tdesc            = %q,\n", spec.desc)
	}
	if len(spec.desc_vim) > 0 {
		fmt.sbprintf(sb, "\t\tdesc_vim        = %q,\n", spec.desc_vim)
	}
	if len(spec.desc_helix) > 0 {
		fmt.sbprintf(sb, "\t\tdesc_helix      = %q,\n", spec.desc_helix)
	}
	if len(spec.desc_emacs) > 0 {
		fmt.sbprintf(sb, "\t\tdesc_emacs      = %q,\n", spec.desc_emacs)
	}
	if len(spec.label) > 0 {
		fmt.sbprintf(sb, "\t\tlabel           = %q,\n", spec.label)
	}
	if len(spec.category) > 0 {
		fmt.sbprintf(sb, "\t\tcategory        = %q,\n", spec.category)
	}
	fmt.sbprintf(sb, "\t\tshow_in_bar     = %v,\n", spec.show_in_bar)
	if spec.hide_in_bar {
		fmt.sbprintln(sb, "\t\thide_in_bar     = true,")
	}
	fmt.sbprintf(sb, "\t\tshow_in_palette = %v,\n", spec.show_in_palette)
	if spec.hide_in_palette {
		fmt.sbprintln(sb, "\t\thide_in_palette = true,")
	}
	fmt.sbprintln(sb, "\t})")
}

@(private)
codegen_fnv64a :: proc "contextless" (s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i := 0; i < len(s); i += 1 {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

@(private)
emit_module_code :: proc(mod: ^Codegen_Module, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	pkg := mod.package_name if len(mod.package_name) > 0 else "main"
	bf_decl := mod.bifrost_import if len(mod.bifrost_import) > 0 else `import "../../bifrost"`
	bf := mod.bifrost_alias if len(mod.bifrost_alias) > 0 else "bifrost"

	fmt.sbprintln(&sb, "// Code generated by bifrost_gen (`core:odin/parser`). DO NOT EDIT.")
	fmt.sbprintf(&sb, "package %s\n\n", pkg)

	needs_bf := len(mod.struct_groups) > 0 || len(mod.app_groups) > 0
	if needs_bf {
		fmt.sbprintf(&sb, "%s\n\n", bf_decl)
	}

	for sg in mod.struct_groups {
		snake := to_snake_case(sg.name, context.temp_allocator)
		fmt.sbprintf(
			&sb,
			"init_%s_keymap_and_palette :: proc(inp: ^%s.Input_State, cp: ^%s.Command_Palette = nil) {{\n",
			snake,
			bf,
			bf,
		)
		if len(sg.entries) == 0 {
			fmt.sbprintln(&sb, "\t_ = inp")
			fmt.sbprintln(&sb, "\t_ = cp")
		} else {
			for entry in sg.entries {
				emit_spec_registration_call(&sb, bf, entry)
			}
		}
		fmt.sbprintln(&sb, "}\n")
	}

	for ag in mod.app_groups {
		snake := to_snake_case(ag.app_type, context.temp_allocator)
		fmt.sbprintf(
			&sb,
			"init_%s_keymap_and_palette :: proc(inp: ^%s.Input_State, cp: ^%s.Command_Palette = nil) {{\n",
			snake,
			bf,
			bf,
		)
		for h in ag.handlers {
			emit_spec_registration_call(&sb, bf, h.spec)
		}
		fmt.sbprintln(&sb, "}\n")

		fmt.sbprintf(
			&sb,
			"dispatch_%s_action :: proc(self: ^%s, inp: ^%s.Input_State) -> bool {{\n",
			snake,
			ag.app_type,
			bf,
		)
		fmt.sbprintln(&sb, "\tif self == nil || inp == nil || inp.triggered_action_id == 0 {")
		fmt.sbprintln(&sb, "\t\treturn false")
		fmt.sbprintln(&sb, "\t}")
		fmt.sbprintln(&sb, "\tswitch inp.triggered_action_id {")
		for h in ag.handlers {
			act_hash := codegen_fnv64a(h.spec.action_name)
			fmt.sbprintf(&sb, "\tcase 0x%016x: // %q\n", act_hash, h.spec.action_name)
			fmt.sbprintf(&sb, "\t\t%s(self)\n", h.proc_name)
			fmt.sbprintln(&sb, "\t\treturn true")
		}
		fmt.sbprintln(&sb, "\t}")
		fmt.sbprintln(&sb, "\treturn false")
		fmt.sbprintln(&sb, "}\n")
	}

	if len(mod.app_groups) > 0 {
		fmt.sbprintln(&sb, "dispatch_ui_actions :: proc {")
		for ag in mod.app_groups {
			snake := to_snake_case(ag.app_type, context.temp_allocator)
			fmt.sbprintf(&sb, "\tdispatch_%s_action,\n", snake)
		}
		fmt.sbprintln(&sb, "}")
	}

	return strings.to_string(sb)
}

// =============================================================================
// Public Codegen Entrypoints
// =============================================================================

generate_from_source :: proc(
	src: string,
	filename: string = "input.odin",
	diagnostics: ^[dynamic]Codegen_Diagnostic = nil,
	allocator := context.allocator,
) -> (code: string, ok: bool) {
	return generate_from_sources({src}, {filename}, diagnostics, allocator)
}

generate_from_sources :: proc(
	sources: []string,
	filenames: []string = nil,
	diagnostics: ^[dynamic]Codegen_Diagnostic = nil,
	allocator := context.allocator,
) -> (code: string, ok: bool) {
	mod: Codegen_Module
	init_codegen_module(&mod)
	defer destroy_codegen_module(&mod)

	all_ok := true
	for src, idx in sources {
		fname := filenames[idx] if idx < len(filenames) else "input.odin"
		if !parse_source_into_module(src, fname, &mod, diagnostics) {
			all_ok = false
		}
	}
	if !all_ok {
		return "", false
	}
	return emit_module_code(&mod, allocator), true
}

generate_directory :: proc(
	dir_path: string,
	out_filename: string = "ui_actions_gen.odin",
	diagnostics: ^[dynamic]Codegen_Diagnostic = nil,
	allocator := context.allocator,
) -> (out_path: string, ok: bool) {
	entries, rerr := os.read_all_directory_by_path(dir_path, context.allocator)
	if rerr != nil {
		append_diagnostic(diagnostics, dir_path, 0, 0, "failed to read package directory")
		return "", false
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	filenames := make([dynamic]string)
	defer delete(filenames)

	for entry in entries {
		if entry.type == .Regular &&
		   strings.has_suffix(entry.name, ".odin") &&
		   !strings.has_suffix(entry.name, "_gen.odin") &&
		   !strings.has_suffix(entry.name, "_test.odin") &&
		   entry.name != out_filename {
			append(&filenames, entry.name)
		}
	}
	slice.sort(filenames[:])

	mod: Codegen_Module
	init_codegen_module(&mod)
	defer destroy_codegen_module(&mod)

	file_buffers := make([dynamic][]byte)
	defer {
		for buf in file_buffers {
			delete(buf)
		}
		delete(file_buffers)
	}

	all_ok := true
	for name in filenames {
		full, _ := filepath.join({dir_path, name}, context.temp_allocator)
		data, read_err := os.read_entire_file(full, context.allocator)
		if read_err != nil {
			append_diagnostic(diagnostics, full, 0, 0, "failed to read source file")
			return "", false
		}
		append(&file_buffers, data)
		if !parse_source_into_module(string(data), full, &mod, diagnostics) {
			all_ok = false
		}
	}

	if !all_ok {
		return "", false
	}

	code := emit_module_code(&mod, context.allocator)
	defer delete(code)

	out_full, _ := filepath.join({dir_path, out_filename}, allocator)
	write_err := os.write_entire_file_from_string(out_full, code)
	if write_err != nil {
		delete(out_full, allocator)
		append_diagnostic(diagnostics, dir_path, 0, 0, "failed to write generated Odin file")
		return "", false
	}
	return out_full, true
}
