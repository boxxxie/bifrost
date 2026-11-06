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

// =============================================================================
// Bifrost ATDD AST Metaprogramming & Purity Enforcer (`core:odin/parser`)
//
// 1. Scans Layer 2 DSL files (`dsl_*.odin`) for `given_*`, `upon_*`, and `then_*`
//    procedures taking `(s: ^Suite_Ctx, ...)` (with optional `loc := #caller_location`).
// 2. Generates `<dir>/dsl_atdd_gen.odin` containing:
//    - Ambient `@(thread_local)` scenario context management (`current_scenario`)
//    - `@(deferred_out)` RAII `scenario(t, w = 80, h = 24)` & `actor_scenario(...)`
//      constructors that automatically wire `Tracking_Allocator` and `driver_destroy`
//    - `Suite_Ctx_VTable` so `s->given_*`, `s->upon_*`, `s->then_*` selector syntax works
//    - `@(rodata)` `given`, `upon`, `then` ambient namespace structs (`Given_DSL`,
//      `Upon_DSL`, `Then_DSL`) and `<step>_ambient` procedures (plus bare `proc { ... }`
//      overload groups for any Layer 2 procedure suffixed with `_ctx`), preserving
//      `#caller_location` and default parameter values!
// 3. Static AST Purity Linter for Layer 1 (`@(scenario)` procedures):
//    - Rejects raw `testing.expect*` calls directly inside `@(scenario)` procedures
//      (including inside local `:=` declarations, `defer`, `switch`, and callback `proc` literals)
//    - Rejects direct `driver_*` Layer 3 calls inside `@(scenario)` procedures
//    - Rejects zero-argument "Macro Theater" `then.*()` / `s->then_*()` / `then_*()` assertions
// =============================================================================

ATDD_Param :: struct {
	name:         string,
	type_expr:    string,
	default_expr: string,
	is_variadic:  bool,
	is_poly_type: bool,
	is_caller_loc: bool,
}

ATDD_Step_Spec :: struct {
	proc_name:    string, // Canonical step name (e.g. `upon_pressing_key`)
	impl_name:    string, // Actual procedure name in `dsl_*.odin` (e.g. `upon_pressing_key_ctx` or `upon_pressing_key`)
	ctx_type:     string,
	has_loc:      bool,
	loc_param:    string,
	return_type:  string,
	params:       [dynamic]ATDD_Param, // Parameters AFTER `s: ^Suite_Ctx`
}

ATDD_Module :: struct {
	package_name: string,
	imports:      [dynamic]Import_Decl_Spec,
	steps:        [dynamic]ATDD_Step_Spec,
	ast_arena:    mem.Dynamic_Arena,
}

@(private)
Import_Decl_Spec :: struct {
	alias:    string,
	raw_decl: string,
}

init_atdd_module :: proc(m: ^ATDD_Module) {
	m.imports = make([dynamic]Import_Decl_Spec)
	m.steps   = make([dynamic]ATDD_Step_Spec)
	mem.dynamic_arena_init(&m.ast_arena)
}

destroy_atdd_module :: proc(m: ^ATDD_Module) {
	for &st in m.steps {
		delete(st.params)
	}
	delete(m.steps)
	delete(m.imports)
	mem.dynamic_arena_destroy(&m.ast_arena)
}

@(private)
is_dsl_step_name :: proc(name: string) -> bool {
	return strings.has_prefix(name, "given_") ||
	       strings.has_prefix(name, "upon_") ||
	       strings.has_prefix(name, "then_")
}

@(private)
parse_atdd_dsl_source :: proc(
	src: string,
	filename: string,
	mod: ^ATDD_Module,
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
		msg := fmt.tprintf("failed to parse ATDD DSL file (%d syntax errors)", p.error_count)
		append_diagnostic(diags, filename, 1, 1, msg)
		return false
	}

	if len(mod.package_name) == 0 && file.pkg_name != "" {
		mod.package_name = file.pkg_name
	}

	for decl_stmt in file.decls {
		#partial switch d in decl_stmt.derived {
		case ^ast.Import_Decl:
			alias := import_local_alias(d)
			already := false
			for existing in mod.imports {
				if existing.alias == alias {
					already = true
					break
				}
			}
			if !already {
				append(&mod.imports, Import_Decl_Spec{
					alias    = alias,
					raw_decl = node_source(src, d),
				})
			}

		case ^ast.Value_Decl:
			if d.is_mutable || len(d.names) == 0 || len(d.values) == 0 {
				continue
			}
			ident, ok := d.names[0].derived.(^ast.Ident)
			if !ok || !is_dsl_step_name(ident.name) {
				continue
			}
			if _, _, is_priv := get_decl_attribute(d, "private"); is_priv {
				continue
			}

			step_name := strings.trim_suffix(ident.name, "_ctx")

			proc_lit, is_proc := d.values[0].derived.(^ast.Proc_Lit)
			if !is_proc || proc_lit.type == nil || proc_lit.type.params == nil || len(proc_lit.type.params.list) == 0 {
				continue
			}

			fields := proc_lit.type.params.list
			first_field := fields[0]
			ctx_type, ptr_ok := extract_pointer_ident(first_field.type)
			if !ptr_ok || ctx_type != "Suite_Ctx" || len(first_field.names) != 1 {
				continue
			}

			ret_type := ""
			if proc_lit.type.results != nil && len(proc_lit.type.results.list) > 0 {
				res_list := proc_lit.type.results.list
				if len(res_list) == 1 && len(res_list[0].names) == 0 && res_list[0].type != nil {
					ret_type = node_source(src, res_list[0].type)
				} else {
					raw_res := strings.trim_space(node_source(src, proc_lit.type.results))
					if strings.has_prefix(raw_res, "(") {
						ret_type = raw_res
					} else {
						ret_type = fmt.tprintf("(%s)", raw_res)
					}
				}
			}

			step := ATDD_Step_Spec{
				proc_name   = step_name,
				impl_name   = ident.name,
				ctx_type    = ctx_type,
				return_type = ret_type,
				params      = make([dynamic]ATDD_Param),
			}

			for f_idx := 1; f_idx < len(fields); f_idx += 1 {
				field := fields[f_idx]
				type_str := node_source(src, field.type)
				def_str  := node_source(src, field.default_value)
				is_ell := false
				if field.type != nil {
					_, is_ell = field.type.derived.(^ast.Ellipsis)
				}
				is_var := is_ell || (.Ellipsis in field.flags) || strings.has_prefix(type_str, "..")
				if is_var && !strings.has_prefix(type_str, "..") {
					type_str = fmt.tprintf("..%s", type_str)
				}
				is_poly  := strings.contains(type_str, "$")
				is_loc   := def_str == "#caller_location"

				for name_expr in field.names {
					p_name := node_source(src, name_expr)
					if is_loc {
						step.has_loc   = true
						step.loc_param = p_name
					}
					append(&step.params, ATDD_Param{
						name          = p_name,
						type_expr     = type_str,
						default_expr  = def_str,
						is_variadic   = is_var,
						is_poly_type  = is_poly,
						is_caller_loc = is_loc,
					})
				}
			}

			append(&mod.steps, step)
		}
	}

	return true
}

// =============================================================================
// Layer 1 `@(scenario)` AST Purity Validator
// =============================================================================

validate_atdd_scenario_source :: proc(
	src: string,
	filename: string,
	diags: ^[dynamic]Codegen_Diagnostic,
) -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	arena_alloc := mem.dynamic_arena_allocator(&arena)
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
		msg := fmt.tprintf("failed to parse ATDD spec file (%d syntax errors)", p.error_count)
		append_diagnostic(diags, filename, 1, 1, msg)
		return false
	}

	all_valid := true
	for decl_stmt in file.decls {
		d, is_val := decl_stmt.derived.(^ast.Value_Decl)
		if !is_val || d.is_mutable || len(d.names) == 0 || len(d.values) == 0 {
			continue
		}
		ident, ok := d.names[0].derived.(^ast.Ident)
		if !ok {
			continue
		}
		_, _, is_scenario := get_decl_attribute(d, "scenario")
		if !is_scenario {
			continue
		}

		proc_lit, is_proc := d.values[0].derived.(^ast.Proc_Lit)
		if !is_proc || proc_lit.body == nil {
			continue
		}

		if !validate_scenario_block_stmts(src, proc_lit.body, ident.name, filename, diags) {
			all_valid = false
		}
	}

	return all_valid
}

@(private)
validate_scenario_block_stmts :: proc(
	src: string,
	stmt: ^ast.Stmt,
	scenario_name: string,
	filename: string,
	diags: ^[dynamic]Codegen_Diagnostic,
) -> bool {
	if stmt == nil {
		return true
	}
	valid := true
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		for child in s.stmts {
			if !validate_scenario_block_stmts(src, child, scenario_name, filename, diags) {
				valid = false
			}
		}
	case ^ast.Expr_Stmt:
		if !validate_scenario_expr(src, s.expr, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.Assign_Stmt:
		for rhs in s.rhs {
			if !validate_scenario_expr(src, rhs, scenario_name, filename, diags) {
				valid = false
			}
		}
	case ^ast.Value_Decl:
		for val in s.values {
			if !validate_scenario_expr(src, val, scenario_name, filename, diags) {
				valid = false
			}
		}
	case ^ast.Defer_Stmt:
		if !validate_scenario_block_stmts(src, s.stmt, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.Return_Stmt:
		for res in s.results {
			if !validate_scenario_expr(src, res, scenario_name, filename, diags) {
				valid = false
			}
		}
	case ^ast.If_Stmt:
		if !validate_scenario_block_stmts(src, s.init, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_expr(src, s.cond, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.body, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.else_stmt, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.For_Stmt:
		if !validate_scenario_block_stmts(src, s.init, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_expr(src, s.cond, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.post, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.body, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.Range_Stmt:
		if !validate_scenario_expr(src, s.expr, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.body, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.Switch_Stmt:
		if !validate_scenario_block_stmts(src, s.init, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_expr(src, s.cond, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.body, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.Type_Switch_Stmt:
		if !validate_scenario_block_stmts(src, s.tag, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_expr(src, s.expr, scenario_name, filename, diags) {
			valid = false
		}
		if !validate_scenario_block_stmts(src, s.body, scenario_name, filename, diags) {
			valid = false
		}
	case ^ast.Case_Clause:
		for child in s.body {
			if !validate_scenario_block_stmts(src, child, scenario_name, filename, diags) {
				valid = false
			}
		}
	}
	return valid
}

@(private)
validate_scenario_expr :: proc(
	src: string,
	expr: ^ast.Expr,
	scenario_name: string,
	filename: string,
	diags: ^[dynamic]Codegen_Diagnostic,
) -> bool {
	if expr == nil {
		return true
	}

	// Recurse into anonymous procedure literals (e.g. `upon.rendering_frame(proc(...) { ... })`)
	if proc_lit, is_proc := expr.derived.(^ast.Proc_Lit); is_proc {
		return validate_scenario_block_stmts(src, proc_lit.body, scenario_name, filename, diags)
	}
	if paren, is_paren := expr.derived.(^ast.Paren_Expr); is_paren {
		return validate_scenario_expr(src, paren.expr, scenario_name, filename, diags)
	}
	if unary, is_unary := expr.derived.(^ast.Unary_Expr); is_unary {
		return validate_scenario_expr(src, unary.expr, scenario_name, filename, diags)
	}
	if binary, is_binary := expr.derived.(^ast.Binary_Expr); is_binary {
		ok_l := validate_scenario_expr(src, binary.left, scenario_name, filename, diags)
		ok_r := validate_scenario_expr(src, binary.right, scenario_name, filename, diags)
		return ok_l && ok_r
	}
	if field_val, is_fv := expr.derived.(^ast.Field_Value); is_fv {
		return validate_scenario_expr(src, field_val.value, scenario_name, filename, diags)
	}

	// Handle `s->step(...)` (`^ast.Selector_Call_Expr`) by forwarding to `sel_call.call` (`^ast.Call_Expr`)
	if sel_call, is_sel_call := expr.derived.(^ast.Selector_Call_Expr); is_sel_call {
		return validate_scenario_expr(src, sel_call.call, scenario_name, filename, diags)
	}

	call, is_call := expr.derived.(^ast.Call_Expr)
	if !is_call {
		return true
	}

	valid := true

	// 1. Check `pkg.proc_name(...)` or `s->proc_name(...)` selector calls
	if sel, is_sel := call.expr.derived.(^ast.Selector_Expr); is_sel {
		is_arrow := sel.op.kind == .Arrow_Right
		sep := "->" if is_arrow else "."
		pkg_ident, pkg_ok := sel.expr.derived.(^ast.Ident)
		fn_ident, fn_ok   := sel.field.derived.(^ast.Ident)
		recv_str := pkg_ident.name if pkg_ok else node_source(src, sel.expr)
		if fn_ok {
			if pkg_ok && pkg_ident.name == "testing" && strings.has_prefix(fn_ident.name, "expect") {
				msg := fmt.tprintf(
					"@(scenario) '%s' calls `testing.%s` directly in Layer 1; use a `then_*` / `then.%s` Layer 2 DSL step instead",
					scenario_name,
					fn_ident.name,
					fn_ident.name,
				)
				append_diagnostic(diags, filename, call.pos.line, call.pos.column, msg)
				valid = false
			} else if strings.has_prefix(fn_ident.name, "driver_") {
				msg := fmt.tprintf(
					"@(scenario) '%s' calls Layer 3 protocol driver `%s%s%s` directly in Layer 1; use `scenario(t, ...)` or a Layer 2 DSL step",
					scenario_name,
					recv_str,
					sep,
					fn_ident.name,
				)
				append_diagnostic(diags, filename, call.pos.line, call.pos.column, msg)
				valid = false
			} else if pkg_ok && pkg_ident.name == "then" && len(call.args) == 0 {
				msg := fmt.tprintf(
					"@(scenario) '%s' calls zero-argument assertion `then.%s()` (Macro Theater); pass expected domain values explicitly in Layer 1",
					scenario_name,
					fn_ident.name,
				)
				append_diagnostic(diags, filename, call.pos.line, call.pos.column, msg)
				valid = false
			} else if strings.has_prefix(fn_ident.name, "then_") && len(call.args) == 0 {
				msg := fmt.tprintf(
					"@(scenario) '%s' calls zero-argument assertion `%s%s%s()` (Macro Theater); pass expected domain values explicitly in Layer 1",
					scenario_name,
					recv_str,
					sep,
					fn_ident.name,
				)
				append_diagnostic(diags, filename, call.pos.line, call.pos.column, msg)
				valid = false
			}
		}
	}

	// 2. Check bare identifier calls (`driver_*` or zero-arg `then_*()`)
	if fn_ident, is_ident := call.expr.derived.(^ast.Ident); is_ident {
		name := fn_ident.name
		if strings.has_prefix(name, "driver_") {
			msg := fmt.tprintf(
				"@(scenario) '%s' calls Layer 3 protocol driver `%s` directly in Layer 1; use `scenario(t, ...)` or a Layer 2 DSL step",
				scenario_name,
				name,
			)
			append_diagnostic(diags, filename, call.pos.line, call.pos.column, msg)
			valid = false
		}
		if strings.has_prefix(name, "then_") && len(call.args) == 0 {
			msg := fmt.tprintf(
				"@(scenario) '%s' calls zero-argument assertion `%s()` (Macro Theater); pass expected domain values explicitly in Layer 1",
				scenario_name,
				name,
			)
			append_diagnostic(diags, filename, call.pos.line, call.pos.column, msg)
			valid = false
		}
	}

	// 3. Recurse into all call arguments (including `Proc_Lit` callbacks passed to `upon.rendering_frame(...)`)
	for arg in call.args {
		if !validate_scenario_expr(src, arg, scenario_name, filename, diags) {
			valid = false
		}
	}

	return valid
}

// =============================================================================
// ATDD Code Emission (`dsl_atdd_gen.odin`)
// =============================================================================

@(private)
is_atdd_import_used :: proc(mod: ^ATDD_Module, alias: string) -> bool {
	if alias == "testing" {
		return true
	}
	prefix := fmt.tprintf("%s.", alias)
	for st in mod.steps {
		if strings.contains(st.return_type, prefix) {
			return true
		}
		for p in st.params {
			if strings.contains(p.type_expr, prefix) || strings.contains(p.default_expr, prefix) {
				return true
			}
		}
	}
	return false
}

@(private)
format_atdd_param :: proc(sb: ^strings.Builder, p: ATDD_Param) {
	if len(p.type_expr) == 0 && len(p.default_expr) > 0 {
		fmt.sbprintf(sb, "%s := %s", p.name, p.default_expr)
	} else if len(p.default_expr) > 0 {
		fmt.sbprintf(sb, "%s: %s = %s", p.name, p.type_expr, p.default_expr)
	} else {
		fmt.sbprintf(sb, "%s: %s", p.name, p.type_expr)
	}
}

@(private)
step_has_poly_params :: proc(st: ATDD_Step_Spec) -> bool {
	for p in st.params {
		if p.is_poly_type {
			return true
		}
	}
	return false
}

@(private)
module_has_step :: proc(mod: ^ATDD_Module, proc_name: string) -> bool {
	for st in mod.steps {
		if st.proc_name == proc_name {
			return true
		}
	}
	return false
}

@(private)
emit_atdd_module_code :: proc(mod: ^ATDD_Module, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	pkg := mod.package_name if len(mod.package_name) > 0 else "bifrost_tests"
	emit_rune_helper := module_has_step(mod, "upon_pressing_key") && !module_has_step(mod, "upon_pressing_key_rune")

	fmt.sbprintln(&sb, "// Code generated by bifrost_gen (`core:odin/parser`) ATDD DSL generator. DO NOT EDIT.")
	fmt.sbprintf(&sb, "package %s\n\n", pkg)

	for imp in mod.imports {
		if is_atdd_import_used(mod, imp.alias) {
			fmt.sbprintf(&sb, "%s\n", imp.raw_decl)
		}
	}
	fmt.sbprintln(&sb)

	// 1. Ambient `@(thread_local)` Scenario Context + Scoped RAII `@(deferred_out)` Constructors
	fmt.sbprintln(&sb, "// =============================================================================")
	fmt.sbprintln(&sb, "// Ambient Scenario Context & `@(deferred_out)` Scoped RAII Harness")
	fmt.sbprintln(&sb, "// =============================================================================")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "MAX_SCENARIO_DEPTH :: 4")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "@(private)")
	fmt.sbprintln(&sb, "@(thread_local)")
	fmt.sbprintln(&sb, "_scenario_stack: [MAX_SCENARIO_DEPTH]Suite_Ctx")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "@(private)")
	fmt.sbprintln(&sb, "@(thread_local)")
	fmt.sbprintln(&sb, "_scenario_depth: int")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "@(private)")
	fmt.sbprintln(&sb, "@(thread_local)")
	fmt.sbprintln(&sb, "_active_scenario_ctx: ^Suite_Ctx")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "current_scenario :: #force_inline proc(loc := #caller_location) -> ^Suite_Ctx {")
	fmt.sbprintln(&sb, "\tassert(_active_scenario_ctx != nil, \"No active ATDD scenario; call `_ = scenario(t)` or `_ = actor_scenario(t)` first\", loc)")
	fmt.sbprintln(&sb, "\treturn _active_scenario_ctx")
	fmt.sbprintln(&sb, "}")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "Scenario_Handle :: struct {")
	fmt.sbprintln(&sb, "\tusing ctx:    ^Suite_Ctx,")
	fmt.sbprintln(&sb, "\tusing vtable: ^Suite_Ctx_VTable,")
	fmt.sbprintln(&sb, "\tprev_ctx:     ^Suite_Ctx,")
	fmt.sbprintln(&sb, "}")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "@(deferred_out = scenario_scope_end)")
	fmt.sbprintln(&sb, "scenario :: proc(t: ^testing.T, w: i32 = 80, h: i32 = 24, loc := #caller_location) -> Scenario_Handle {")
	fmt.sbprintln(&sb, "\tassert(_scenario_depth < MAX_SCENARIO_DEPTH, \"MAX_SCENARIO_DEPTH exceeded; wrap sequential scenarios in { } blocks\", loc)")
	fmt.sbprintln(&sb, "\ts := &_scenario_stack[_scenario_depth]")
	fmt.sbprintln(&sb, "\t_scenario_depth += 1")
	fmt.sbprintln(&sb, "\ts^ = {}")
	fmt.sbprintln(&sb, "\tdriver_init(s, t, w, h)")
	fmt.sbprintln(&sb, "\tprev := _active_scenario_ctx")
	fmt.sbprintln(&sb, "\t_active_scenario_ctx = s")
	fmt.sbprintln(&sb, "\treturn Scenario_Handle{ctx = s, vtable = &_suite_ctx_vtable, prev_ctx = prev}")
	fmt.sbprintln(&sb, "}")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "@(deferred_out = scenario_scope_end)")
	fmt.sbprintln(&sb, "actor_scenario :: proc(")
	fmt.sbprintln(&sb, "\tt: ^testing.T,")
	fmt.sbprintln(&sb, "\tw: i32 = 80,")
	fmt.sbprintln(&sb, "\th: i32 = 24,")
	fmt.sbprintln(&sb, "\tnum_workers: int = 2,")
	fmt.sbprintln(&sb, "\tactive_collection: string = \"\",")
	fmt.sbprintln(&sb, "\tloc := #caller_location,")
	fmt.sbprintln(&sb, ") -> Scenario_Handle {")
	fmt.sbprintln(&sb, "\tassert(_scenario_depth < MAX_SCENARIO_DEPTH, \"MAX_SCENARIO_DEPTH exceeded; wrap sequential scenarios in { } blocks\", loc)")
	fmt.sbprintln(&sb, "\ts := &_scenario_stack[_scenario_depth]")
	fmt.sbprintln(&sb, "\t_scenario_depth += 1")
	fmt.sbprintln(&sb, "\ts^ = {}")
	fmt.sbprintln(&sb, "\tdriver_actor_xitdb_init(s, t, w, h, num_workers, active_collection)")
	fmt.sbprintln(&sb, "\tprev := _active_scenario_ctx")
	fmt.sbprintln(&sb, "\t_active_scenario_ctx = s")
	fmt.sbprintln(&sb, "\treturn Scenario_Handle{ctx = s, vtable = &_suite_ctx_vtable, prev_ctx = prev}")
	fmt.sbprintln(&sb, "}")
	fmt.sbprintln(&sb)
	fmt.sbprintln(&sb, "scenario_scope_end :: proc(h: Scenario_Handle) {")
	fmt.sbprintln(&sb, "\t_active_scenario_ctx = h.prev_ctx")
	fmt.sbprintln(&sb, "\tif h.ctx != nil {")
	fmt.sbprintln(&sb, "\t\tdriver_destroy(h.ctx)")
	fmt.sbprintln(&sb, "\t\th.ctx^ = {}")
	fmt.sbprintln(&sb, "\t\t_scenario_depth -= 1")
	fmt.sbprintln(&sb, "\t}")
	fmt.sbprintln(&sb, "}")
	fmt.sbprintln(&sb)

	// 2. VTable struct for `s->given_*`, `s->upon_*`, `s->then_*` selector calls
	//    PLUS `@(rodata)` Ambient `given`, `upon`, `then` namespace structs for `given.focused_widget("save_btn")`!
	fmt.sbprintln(&sb, "Suite_Ctx_VTable :: struct {")
	for st in mod.steps {
		if step_has_poly_params(st) {
			continue // Odin struct fields cannot hold polymorphic `$T` proc pointers
		}
		sig_b := strings.builder_make(context.temp_allocator)
		for p in st.params {
			fmt.sbprint(&sig_b, ", ")
			format_atdd_param(&sig_b, p)
		}
		if len(st.return_type) > 0 {
			fmt.sbprintf(&sb, "\t%s: proc(s: ^Suite_Ctx%s) -> %s,\n", st.proc_name, strings.to_string(sig_b), st.return_type)
		} else {
			fmt.sbprintf(&sb, "\t%s: proc(s: ^Suite_Ctx%s),\n", st.proc_name, strings.to_string(sig_b))
		}
	}
	if emit_rune_helper {
		fmt.sbprintln(&sb, "\tupon_pressing_key_rune: proc(s: ^Suite_Ctx, ch: rune, mods: bifrost.Mod_Flags = {}),")
	}
	fmt.sbprintln(&sb, "}\n")

	fmt.sbprintln(&sb, "@(private)")
	fmt.sbprintln(&sb, "@(rodata)")
	fmt.sbprintln(&sb, "_suite_ctx_vtable := Suite_Ctx_VTable{")
	for st in mod.steps {
		if step_has_poly_params(st) {
			continue
		}
		fmt.sbprintf(&sb, "\t%s = %s,\n", st.proc_name, st.impl_name)
	}
	if emit_rune_helper {
		fmt.sbprintln(&sb, "\tupon_pressing_key_rune = upon_pressing_key_rune_ctx,")
	}
	fmt.sbprintln(&sb, "}\n")

	// Emit `Given_DSL`, `Upon_DSL`, and `Then_DSL` ambient namespace structs so Layer 1 specs
	// can write `given.focused_widget("save_btn")`, `upon.pressing_key(.Enter)`, `then.focused_widget_is("save_btn")`!
	prefixes := [3]struct{ pfx, type_name, var_name: string }{
		{"given_", "Given_DSL", "given"},
		{"upon_",  "Upon_DSL",  "upon"},
		{"then_",  "Then_DSL",  "then"},
	}
	for grp in prefixes {
		fmt.sbprintf(&sb, "%s :: struct {{\n", grp.type_name)
		for st in mod.steps {
			if step_has_poly_params(st) || !strings.has_prefix(st.proc_name, grp.pfx) {
				continue
			}
			short := strings.trim_prefix(st.proc_name, grp.pfx)
			sig_b := strings.builder_make(context.temp_allocator)
			for p, idx in st.params {
				if idx > 0 {
					fmt.sbprint(&sig_b, ", ")
				}
				format_atdd_param(&sig_b, p)
			}
			if len(st.return_type) > 0 {
				fmt.sbprintf(&sb, "\t%s: proc(%s) -> %s,\n", short, strings.to_string(sig_b), st.return_type)
			} else {
				fmt.sbprintf(&sb, "\t%s: proc(%s),\n", short, strings.to_string(sig_b))
			}
		}
		if grp.pfx == "upon_" && emit_rune_helper {
			fmt.sbprintln(&sb, "\tpressing_key_rune: proc(ch: rune, mods: bifrost.Mod_Flags = {}),")
		}
		fmt.sbprintln(&sb, "}\n")

		fmt.sbprintln(&sb, "@(rodata)")
		fmt.sbprintf(&sb, "%s := %s{{\n", grp.var_name, grp.type_name)
		for st in mod.steps {
			if step_has_poly_params(st) || !strings.has_prefix(st.proc_name, grp.pfx) {
				continue
			}
			short := strings.trim_prefix(st.proc_name, grp.pfx)
			fmt.sbprintf(&sb, "\t%s = %s_ambient,\n", short, st.proc_name)
		}
		if grp.pfx == "upon_" && emit_rune_helper {
			fmt.sbprintln(&sb, "\tpressing_key_rune = upon_pressing_key_rune_ambient,")
		}
		fmt.sbprintln(&sb, "}\n")
	}

	// 3. Emit `<step>_ambient` procedures & optional `proc { ... }` overload groups for `*_ctx` steps
	fmt.sbprintln(&sb, "// =============================================================================")
	fmt.sbprintln(&sb, "// Ambient Step Wrappers & Procedure Overload Groups (for `*_ctx` steps)")
	fmt.sbprintln(&sb, "// =============================================================================")
	fmt.sbprintln(&sb)

	for st in mod.steps {
		amb_name := fmt.tprintf("%s_ambient", st.proc_name)
		ctx_name := st.impl_name

		sig_b  := strings.builder_make(context.temp_allocator)
		call_b := strings.builder_make(context.temp_allocator)

		seen_variadic := false
		for p, idx in st.params {
			if idx > 0 {
				fmt.sbprint(&sig_b, ", ")
			}
			format_atdd_param(&sig_b, p)

			fmt.sbprint(&call_b, ", ")
			if p.is_variadic {
				seen_variadic = true
				fmt.sbprintf(&call_b, "..%s", p.name)
			} else if seen_variadic {
				fmt.sbprintf(&call_b, "%s = %s", p.name, p.name)
			} else {
				fmt.sbprintf(&call_b, "%s", p.name)
			}
		}

		ctx_expr := "current_scenario()"
		if st.has_loc && len(st.loc_param) > 0 {
			ctx_expr = fmt.tprintf("current_scenario(%s)", st.loc_param)
		}

		if len(st.return_type) > 0 {
			fmt.sbprintf(&sb, "%s :: #force_inline proc(%s) -> %s {{\n", amb_name, strings.to_string(sig_b), st.return_type)
			fmt.sbprintf(&sb, "\treturn %s(%s%s)\n", ctx_name, ctx_expr, strings.to_string(call_b))
			fmt.sbprintln(&sb, "}\n")
		} else {
			fmt.sbprintf(&sb, "%s :: #force_inline proc(%s) {{\n", amb_name, strings.to_string(sig_b))
			fmt.sbprintf(&sb, "\t%s(%s%s)\n", ctx_name, ctx_expr, strings.to_string(call_b))
			fmt.sbprintln(&sb, "}\n")
		}

		if st.impl_name != st.proc_name {
			fmt.sbprintf(&sb, "%s :: proc {{\n", st.proc_name)
			fmt.sbprintf(&sb, "\t%s,\n", ctx_name)
			fmt.sbprintf(&sb, "\t%s,\n", amb_name)
			if st.proc_name == "upon_pressing_key" && emit_rune_helper {
				fmt.sbprintln(&sb, "\tupon_pressing_key_rune_ctx,")
				fmt.sbprintln(&sb, "\tupon_pressing_key_rune_ambient,")
			}
			fmt.sbprintln(&sb, "}\n")
		}
	}

	if emit_rune_helper {
		// Extra ergonomic rune overloads for `upon_pressing_key_rune` / `s->upon_pressing_key_rune('j')`
		fmt.sbprintln(&sb, "upon_pressing_key_rune_ctx :: #force_inline proc(s: ^Suite_Ctx, ch: rune, mods: bifrost.Mod_Flags = {}) {")
		fmt.sbprintln(&sb, "\tupon_pressing_key(s, .Rune, mods, ch)")
		fmt.sbprintln(&sb, "}\n")
		fmt.sbprintln(&sb, "upon_pressing_key_rune_ambient :: #force_inline proc(ch: rune, mods: bifrost.Mod_Flags = {}) {")
		fmt.sbprintln(&sb, "\tupon_pressing_key(current_scenario(), .Rune, mods, ch)")
		fmt.sbprintln(&sb, "}\n")
		fmt.sbprintln(&sb, "upon_pressing_key_rune :: proc {")
		fmt.sbprintln(&sb, "\tupon_pressing_key_rune_ctx,")
		fmt.sbprintln(&sb, "\tupon_pressing_key_rune_ambient,")
		fmt.sbprintln(&sb, "}")
	}

	return strings.to_string(sb)
}

generate_atdd_from_sources :: proc(
	dsl_sources: []string,
	dsl_filenames: []string = nil,
	spec_sources: []string = nil,
	spec_filenames: []string = nil,
	diagnostics: ^[dynamic]Codegen_Diagnostic = nil,
	allocator := context.allocator,
) -> (code: string, ok: bool) {
	mod: ATDD_Module
	init_atdd_module(&mod)
	defer destroy_atdd_module(&mod)

	all_ok := true
	for src, idx in dsl_sources {
		fname := dsl_filenames[idx] if idx < len(dsl_filenames) else "dsl.odin"
		if !parse_atdd_dsl_source(src, fname, &mod, diagnostics) {
			all_ok = false
		}
	}

	for src, idx in spec_sources {
		fname := spec_filenames[idx] if idx < len(spec_filenames) else "spec.odin"
		if !validate_atdd_scenario_source(src, fname, diagnostics) {
			all_ok = false
		}
	}

	if !all_ok {
		return "", false
	}
	return emit_atdd_module_code(&mod, allocator), true
}

generate_atdd_directory :: proc(
	dir_path: string,
	out_filename: string = "dsl_atdd_gen.odin",
	diagnostics: ^[dynamic]Codegen_Diagnostic = nil,
	allocator := context.allocator,
) -> (out_path: string, ok: bool) {
	entries, rerr := os.read_all_directory_by_path(dir_path, context.allocator)
	if rerr != nil {
		append_diagnostic(diagnostics, dir_path, 0, 0, "failed to read ATDD test directory")
		return "", false
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	dsl_files  := make([dynamic]string)
	spec_files := make([dynamic]string)
	defer delete(dsl_files)
	defer delete(spec_files)

	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_gen.odin") || entry.name == out_filename {
			continue
		}
		if strings.has_prefix(entry.name, "dsl_") {
			append(&dsl_files, entry.name)
		} else if strings.has_prefix(entry.name, "spec_") {
			append(&spec_files, entry.name)
		}
	}
	slice.sort(dsl_files[:])
	slice.sort(spec_files[:])

	mod: ATDD_Module
	init_atdd_module(&mod)
	defer destroy_atdd_module(&mod)

	file_buffers := make([dynamic][]byte)
	defer {
		for buf in file_buffers {
			delete(buf)
		}
		delete(file_buffers)
	}

	all_ok := true
	for name in dsl_files {
		full, _ := filepath.join({dir_path, name}, context.temp_allocator)
		data, read_err := os.read_entire_file(full, context.allocator)
		if read_err != nil {
			append_diagnostic(diagnostics, full, 0, 0, "failed to read ATDD DSL file")
			return "", false
		}
		append(&file_buffers, data)
		if !parse_atdd_dsl_source(string(data), full, &mod, diagnostics) {
			all_ok = false
		}
	}

	for name in spec_files {
		full, _ := filepath.join({dir_path, name}, context.temp_allocator)
		data, read_err := os.read_entire_file(full, context.allocator)
		if read_err != nil {
			append_diagnostic(diagnostics, full, 0, 0, "failed to read ATDD spec file")
			return "", false
		}
		append(&file_buffers, data)
		if !validate_atdd_scenario_source(string(data), full, diagnostics) {
			all_ok = false
		}
	}

	if !all_ok {
		return "", false
	}

	code := emit_atdd_module_code(&mod, context.allocator)
	defer delete(code)

	out_full, _ := filepath.join({dir_path, out_filename}, allocator)
	write_err := os.write_entire_file_from_string(out_full, code)
	if write_err != nil {
		delete(out_full, allocator)
		append_diagnostic(diagnostics, dir_path, 0, 0, "failed to write generated ATDD DSL file")
		return "", false
	}
	return out_full, true
}
