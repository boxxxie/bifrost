// =============================================================================
// Bifrost AST Metaprogramming CLI Generator (`tools/bifrost_gen`)
//
// Modes:
//   1. UI Actions (default):
//      Scans one or more Odin package directories for `@(ui_actions)` structs and
//      `@(ui_action="...")` / `@(ui_scope="...")` procedures across all `.odin` files
//      using `core:odin/parser`, validates chord syntax, and emits `<dir>/ui_actions_gen.odin`.
//   2. ATDD DSL & Purity Linter (`--atdd`):
//      Scans an ATDD test directory (`dsl_*.odin` and `spec_*.odin`), validates Layer 1
//      `@(scenario)` purity rules, and emits `<dir>/dsl_atdd_gen.odin` with `@(deferred_out)`
//      RAII `scenario(t, ...)` constructors, `s->step(...)` vtables, and `given.*` /
//      `upon.*` / `then.*` ambient DSL namespaces.
//
// Usage:
//   odin run tools/bifrost_gen -- <package_dir> [<package_dir2> ...]
//   odin run tools/bifrost_gen -- --atdd <tests_dir>
// =============================================================================

package main

import codegen "../../bifrost/codegen"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Usage: odin run tools/bifrost_gen -- [--atdd] <package_dir> [<package_dir2> ...]")
		os.exit(1)
	}

	atdd_mode := false
	args := os.args[1:]
	if len(args) > 0 && args[0] == "--atdd" {
		atdd_mode = true
		args = args[1:]
	}
	if len(args) == 0 {
		fmt.eprintln("Usage: odin run tools/bifrost_gen -- [--atdd] <package_dir> [<package_dir2> ...]")
		os.exit(1)
	}

	for target_dir in args {
		diags := make([dynamic]codegen.Codegen_Diagnostic)
		out_path: string
		ok: bool
		if atdd_mode {
			out_path, ok = codegen.generate_atdd_directory(target_dir, "dsl_atdd_gen.odin", &diags)
		} else {
			out_path, ok = codegen.generate_directory(target_dir, "ui_actions_gen.odin", &diags)
		}
		if !ok {
			for d in diags {
				if d.line > 0 {
					fmt.eprintf("%s(%d:%d): Error: %s\n", d.file, d.line, d.column, d.message)
				} else {
					fmt.eprintf("%s: Error: %s\n", d.file, d.message)
				}
			}
			codegen.destroy_diagnostics(&diags)
			os.exit(1)
		}
		codegen.destroy_diagnostics(&diags)
		if atdd_mode {
			fmt.printfln("Generated Bifrost ATDD DSL -> %s", out_path)
		} else {
			fmt.printfln("Generated Bifrost UI actions -> %s", out_path)
		}
		delete(out_path)
	}
}
