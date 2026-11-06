// =============================================================================
// Bifrost AST Metaprogramming CLI Generator (`tools/bifrost_gen`)
//
// Scans one or more Odin package directories for `@(ui_actions)` structs and
// `@(ui_action="...")` / `@(ui_scope="...")` procedures across all `.odin` files
// using `core:odin/parser`, validates chord syntax, and emits `<dir>/ui_actions_gen.odin`.
//
// Usage:
//   odin run tools/bifrost_gen -- <package_dir> [<package_dir2> ...]
// =============================================================================

package main

import codegen "../../bifrost/codegen"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Usage: odin run tools/bifrost_gen -- <package_dir> [<package_dir2> ...]")
		os.exit(1)
	}

	for target_dir in os.args[1:] {
		diags := make([dynamic]codegen.Codegen_Diagnostic)
		out_path, ok := codegen.generate_directory(target_dir, "ui_actions_gen.odin", &diags)
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
		fmt.printfln("Generated Bifrost UI actions -> %s", out_path)
		delete(out_path)
	}
}
