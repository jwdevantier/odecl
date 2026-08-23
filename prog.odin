/*
 * SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// odecl -- inspect Odin packages: list packages and their top-level
// declarations, using Odin's own parser (core:odin/parser) instead of
// scraping `odin doc` text output.
//
//   odecl [-d <dir>] [-P|--project-only] <command> [arguments]
//
// Subcommands:
//
//   ls [filter]
//       List stdlib packages, one import path per line (`core:fmt`,
//       `base:runtime`, `vendor:raylib`, ...). Searches the `core/`,
//       `base/` and `vendor/` subdirectories of the Odin root (from
//       $ODIN_ROOT, falling back to `odin root`). With a filter argument,
//       only packages whose import path has the filter as a
//       (case-sensitive) prefix are printed.
//
//   show <pkg> [ident]
//       Without <ident>: markdown list view of all top-level declarations
//       of the package -- `# package <name>` heading, then one `##` section
//       per declaration kind in `odin doc` order (constants -> variables ->
//       procedures -> proc_group -> types), each a ```odin fenced block
//       with one whitespace-collapsed line per entry, procedure bodies
//       elided as `{...}`.
//
//       With <ident>: markdown detail view of every top-level declaration
//       matching <ident> (case-insensitive): kind, location
//       (file:line:column), attributes, first doc-comment line, then the
//       full declaration in a ```odin fence, then the doc comment verbatim.
//       A matched procedure group (`g :: proc{a, b}`) is expanded: after
//       the group's own entry, each member gets its own entry. Procedures
//       print their full signature with the body elided as `{...}`; types,
//       constants and variables are sliced verbatim from the source, so
//       multi-line struct bodies and raw strings survive intact.
//       Aliases (`x :: other`, `x :: pkg.other`) are resolved: an alias to
//       a procedure also shows the procedure's signature, an alias to a
//       struct shows the struct definition, etc.
//
//   apropos <term>
//       Case-insensitive substring match against declaration names across
//       ALL packages (procedure-group members are checked separately, and
//       reported via their group). Results are grouped by package, with
//       packages sorted alphabetically; the first doc-comment line is shown
//       alongside each match.
//
// Package addressing:
//   - a spec containing ':' is a stdlib address: `<collection>:<path>`
//     (e.g. `core:fmt`, `base:runtime`, `vendor:raylib`)
//   - any other spec is a path relative to the project/scan root (the
//     `-d <dir>` directory, or the current directory when it directly
//     contains .odin files): `.` is the package at the root itself,
//     `foo/bar` is the package `bar` inside `foo`. The scan root's own
//     directory name is also accepted as sugar for `.` (`show odecl`).
// The stdlib is searched in addition to the project unless
// `-P/--project-only` is given. All `.odin` files directly in a package
// directory are parsed (build tags / file suffixes are NOT evaluated, so
// platform-specific variants all appear).
//
// Classification is purely syntactic (no type checking):
//   - `x: int` / `x := 1`            -> variable   (Value_Decl.is_mutable)
//   - `p :: proc(...) {...}`         -> procedure  (value is ^ast.Proc_Lit)
//   - `g :: proc{a, b}`              -> proc_group (value is ^ast.Proc_Group)
//   - `T :: struct{...}` / enum / distinct / map / []T / proc(...) / ...
//                                      -> type      (incl. body-less proc types)
//   - anything else with `::`        -> constant   (this includes ALIASES like
//                                     `Byte :: runtime.Byte`, exactly like
//                                     `odin doc` files them under "constants")
//
// Known gaps (fine for the PoC):
//   - decls inside `foreign { ... }` blocks are not listed
//     (Foreign_Block_Decl at top level is skipped)
//   - decls inside package-level `when` statements are not listed
//   - files that fail to parse are skipped (warning on stderr)
package odecl

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"

Decl_Kind :: enum {
	Constant,
	Variable,
	Procedure,
	Proc_Group,
	Type,
}

// section names + iteration order mirror the `odin doc` section order
SECTION_NAMES := [Decl_Kind]string {
	.Constant   = "constants",
	.Variable   = "variables",
	.Procedure  = "procedures",
	.Proc_Group = "proc_group",
	.Type       = "types",
}

KIND_NAMES := [Decl_Kind]string {
	.Constant   = "constant",
	.Variable   = "variable",
	.Procedure  = "procedure",
	.Proc_Group = "proc_group",
	.Type       = "type",
}

Entry :: struct {
	kind:       Decl_Kind,
	name:       string,
	vd:         ^ast.Value_Decl,
	name_index: int, // index of `name` inside vd.names (grouped decls)
	ident:      ^ast.Ident,
	path:       string, // file this declaration was parsed from
	src:        string, // source text of that file
	file:       ^ast.File, // the parsed file (used to resolve import aliases)
}

COLLECTIONS :: [?]string{"core", "base", "vendor"}

USAGE ::
	"usage: odecl [flags] <command> [arguments]\n" +
	"\n" +
	"flags:\n" +
	"  -d <dir>              project/scan root directory (default: current dir\n" +
	"                        if it directly contains .odin files)\n" +
	"  -P, --project-only    search only the project; exclude the stdlib\n" +
	"                        (default: project + stdlib are all searched)\n" +
	"\n" +
	"commands:\n" +
	"  ls [filter]          list packages, one per line (optional prefix filter)\n" +
	"  show <pkg> [ident]   list a package's top-level declarations, or show\n" +
	"                       one declaration in detail (case-insensitive name)\n" +
	"  apropos <term>       search declaration names across all packages\n" +
	"                       (case-insensitive substring match)\n" +
	"\n" +
	"packages:\n" +
	"  '.' = the package at the scan root; 'foo', 'foo/bar' = packages relative\n" +
	"  to the scan root; 'core:fmt', 'base:runtime', 'vendor:raylib' = stdlib.\n" +
	"  the scan root's directory name also means the root package (show odecl).\n"

main :: proc() {
	args := os.args[1:]

	// global flags come before the subcommand
	dir := ""
	project_only := false
	for len(args) > 0 && (args[0] == "-d" || args[0] == "-P" || args[0] == "--project-only") {
		switch args[0] {
		case "-d":
			if len(args) < 2 {
				fmt.eprintln("odin_decls: `-d` requires a directory argument")
				os.exit(2)
			}
			dir = args[1]
			args = args[2:]
		case "-P", "--project-only":
			project_only = true
			args = args[1:]
		}
	}

	if len(args) == 0 {
		fmt.eprint(USAGE)
		os.exit(2)
	}

	// project/scan root: `-d <dir>`, else the current directory when it
	// directly contains .odin files, else none (stdlib only)
	if dir != "" {
		abs, aerr := os.get_absolute_path(dir, context.allocator)
		if aerr != nil || !os.is_directory(abs) {
			fmt.eprintfln("odin_decls: `-d` is not a directory: %s", dir)
			os.exit(2)
		}
		g_proj_root = strings.trim_right(abs, "/\\")
	} else {
		cwd, _ := os.get_working_directory(context.allocator)
		if is_odin_project(cwd) {
			g_proj_root = cwd
		}
	}
	g_project_only = project_only

	cmd, rest := args[0], args[1:]
	switch cmd {
	case "ls":
		cmd_ls(rest)
	case "show":
		cmd_show(rest)
	case "apropos":
		cmd_apropos(rest)
	case "help", "-h", "--help":
		fmt.print(USAGE)
	case:
		fmt.eprintfln("odin_decls: unknown command %q", cmd)
		fmt.eprint(USAGE)
		os.exit(2)
	}
}

// ── ls ─────────────────────────────────────────────────────────────────────

cmd_ls :: proc(args: []string) {
	if len(args) > 1 {
		fmt.eprintfln("odin_decls: `ls` takes at most one filter argument")
		os.exit(2)
	}
	filter := args[0] if len(args) == 1 else ""
	for pkg in all_scan_packages(context.allocator) {
		if filter != "" && !strings.has_prefix(pkg, filter) {
			continue
		}
		fmt.println(pkg)
	}
}

// All packages in the collections, as `col:relpath` lines (`col:.` for a
// collection root itself), sorted within each collection.
all_packages :: proc(root: string, allocator: runtime.Allocator) -> []string {
	lines: [dynamic]string
	for col in COLLECTIONS {
		col_parts := [?]string{root, "/", col}
		col_dir := strings.concatenate(col_parts[:], context.temp_allocator)
		if !os.is_directory(col_dir) {
			continue
		}
		for dir in find_odin_dirs(col_dir, context.temp_allocator) {
			rel := dir[len(col_dir):]
			if len(rel) > 0 && (rel[0] == '/' || rel[0] == '\\') {
				rel = rel[1:]
			}
			// import paths always use '/', even on Windows
			rel, _ = strings.replace_all(rel, "\\", "/", context.temp_allocator)
			line: string
			if rel == "" {
				line = fmt.aprintf("%s:.", col, allocator = allocator)
			} else {
				line = fmt.aprintf("%s:%s", col, rel, allocator = allocator)
			}
			append(&lines, line)
		}
	}
	return lines[:]
}

// Recursively find all directories that directly contain .odin files
// (sorted).
find_odin_dirs :: proc(dir: string, allocator: runtime.Allocator) -> []string {
	seen: map[string]struct{}
	defer delete(seen)

	w := os.walker_create_path(dir)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if _, err := os.walker_error(&w); err != nil {
			continue
		}
		if info.type != .Regular || !strings.has_suffix(info.name, ".odin") {
			continue
		}
		parent := os.dir(info.fullpath)
		if parent not_in seen {
			seen[strings.clone(parent, allocator)] = {}
		}
	}

	dirs: [dynamic]string
	for d in seen {
		append(&dirs, d)
	}
	slice.sort(dirs[:])
	return dirs[:]
}

// ── show ───────────────────────────────────────────────────────────────────

cmd_show :: proc(args: []string) {
	if len(args) < 1 || len(args) > 2 {
		fmt.eprintfln("odin_decls: usage: odin_decls show <pkg> [ident]")
		os.exit(2)
	}
	dir, label, ok := resolve_pkg(args[0])
	if !ok {
		fmt.eprintfln("odin_decls: no such package: %s", args[0])
		os.exit(1)
	}
	entries := parse_package(dir)
	if len(entries) == 0 {
		fmt.eprintfln("odin_decls: no declarations found in %s (%s)", args[0], dir)
		os.exit(1)
	}
	if len(args) == 1 {
		list_entries(label, entries[:])
	} else if !show_entry(args[1], entries[:]) {
		fmt.eprintfln(
			"odin_decls: no top-level declaration named %q in package %s",
			args[1],
			label,
		)
		os.exit(1)
	}
}

list_entries :: proc(pkg_label: string, entries: []Entry) {
	fmt.printfln("# package `%s`", pkg_label)
	for kind in Decl_Kind {
		has := false
		for e in entries {
			if e.kind == kind {
				has = true
				break
			}
		}
		if !has {
			continue
		}
		fmt.printfln("\n## %s\n", SECTION_NAMES[kind])
		fmt.println("```odin")
		for e in entries {
			if e.kind == kind {
				fmt.println(entry_head(e))
			}
		}
		fmt.println("```")
	}
}

show_entry :: proc(target: string, entries: []Entry) -> bool {
	found := false
	for e in entries {
		if !strings.equal_fold(e.name, target) {
			continue
		}
		if found {
			fmt.println("\n---\n")
		}
		found = true
		print_entry_with_extras(e, entries)
	}
	return found
}

// The detail view of one entry, plus the extras `show` provides on top:
// proc-group expansion and alias resolution.
print_entry_with_extras :: proc(e: Entry, entries: []Entry) {
	print_entry_detail(e, "", "")
	if e.kind == .Proc_Group {
		expand_proc_group(e, entries)
	}
	// Follow aliases (`x :: other` / `x :: pkg.other`), so that an alias to a
	// procedure still shows the procedure's signature and an alias to a
	// struct shows the struct definition.
	seen: map[^ast.Value_Decl]bool
	defer delete(seen)
	current, current_entries := e, entries
	for _ in 0 ..< 8 { 	// bound alias chains
		target, via, pkg_label, target_entries, ok := resolve_alias(current, current_entries)
		if !ok || target.vd in seen {
			break
		}
		seen[target.vd] = true
		fmt.println("\n---\n")
		print_entry_detail(target, via, pkg_label)
		if target.kind == .Proc_Group {
			expand_proc_group(target, target_entries)
		}
		current, current_entries = target, target_entries
	}
}

// Proc groups are expanded: each member gets its own entry.
expand_proc_group :: proc(e: Entry, entries: []Entry) {
	for member in proc_group_members(e) {
		for m in entries {
			if m.name != member {
				continue
			}
			fmt.println("\n---\n")
			print_entry_detail(m, "", "")
		}
	}
}

// If `e` is an alias (`x :: other` or `x :: pkg.other`), find the entry it
// refers to -- in the same package, or in the package the selector's import
// alias refers to. Returns the target entry, a display name (e.g. `os.match`
// for cross-package targets, "" = use the target's own name), the target
// package's import-path label ("" = same package), and the target package's
// entries (for further expansion / alias resolution).
resolve_alias :: proc(
	e: Entry,
	pkg_entries: []Entry,
) -> (
	target: Entry,
	via, pkg_label: string,
	target_entries: []Entry,
	ok: bool,
) {
	value := value_for(e.vd, e.name_index)
	if value == nil {
		return
	}
	#partial switch v in value.derived_expr {
	case ^ast.Ident:
		// same-package alias: `x :: other`
		if v.name == e.name {
			return
		}
		for t in pkg_entries {
			if t.name == v.name && t.vd != e.vd {
				return t, "", "", pkg_entries, true
			}
		}
	case ^ast.Selector_Expr:
		// cross-package alias: `x :: pkg.other`
		pkg_ident, pkg_ok := v.expr.derived_expr.(^ast.Ident)
		if !pkg_ok {
			return
		}
		dir, label, imp_ok := find_import_dir(e, pkg_ident.name)
		if !imp_ok {
			return
		}
		entries := cached_parse_package(dir)
		for t in entries {
			if t.name == v.field.name {
				via := fmt.aprintf(
					"%s.%s",
					pkg_ident.name,
					v.field.name,
					allocator = context.temp_allocator,
				)
				return t, via, label, entries, true
			}
		}
	}
	return
}

// Resolve an import alias in the entry's file to the directory of the
// package it refers to, e.g. `os` -> `<odin-root>/core/os` (labelled
// `core:os`). Relative imports are resolved against the file's directory.
find_import_dir :: proc(e: Entry, alias: string) -> (dir, label: string, ok: bool) {
	for imp in e.file.imports {
		path := imp.relpath.text // the quoted string literal token text
		if len(path) >= 2 && (path[0] == '"' || path[0] == '`') {
			path = path[1:len(path) - 1]
		}
		imp_alias := imp.name.text
		if imp_alias == "" {
			// default import name: the last path segment, minus any
			// collection prefix (`import "core:os"` is referred to as `os`)
			imp_alias = path
			if i := strings.last_index_any(path, "/:"); i >= 0 {
				imp_alias = path[i + 1:]
			}
		}
		if imp_alias != alias {
			continue
		}
		if strings.contains(path, ":") {
			col, rel := split_pkg(path)
			d, d_ok := pkg_dir(odin_root_cached(), col, rel)
			return d, path, d_ok
		}
		joined_parts := [?]string{os.dir(e.path), "/", path}
		joined := strings.concatenate(joined_parts[:], context.temp_allocator)
		d, _ := os.clean_path(joined, context.temp_allocator)
		if !os.is_directory(d) {
			return "", "", false
		}
		return d, path, true
	}
	return "", "", false
}

print_entry_detail :: proc(e: Entry, heading, pkg_label: string) {
	title := heading if heading != "" else e.name
	fmt.printfln("# %s\n", title)
	fmt.printfln("- **kind:** %s", KIND_NAMES[e.kind])
	if pkg_label != "" {
		fmt.printfln("- **package:** `%s`", pkg_label)
	}
	fmt.printfln("- **location:** `%s:%d:%d`", e.path, e.ident.pos.line, e.ident.pos.column)
	if e.kind == .Procedure {
		if value := value_for(e.vd, e.name_index); value != nil {
			if lit, is_lit := value.derived_expr.(^ast.Proc_Lit); is_lit {
				fmt.printfln("- **signature:** `%s`", collapse(proc_signature(lit, e.src)))
			}
		}
	}
	if len(e.vd.attributes) > 0 {
		attrs := make([]string, len(e.vd.attributes), context.temp_allocator)
		for attr, i in e.vd.attributes {
			attrs[i] = attribute_text(e.src, attr)
		}
		joined, _ := strings.join(attrs, " ", context.temp_allocator)
		fmt.printfln("- **attributes:** `%s`", joined)
	}
	if doc := first_doc_line(e.vd); doc != "" {
		fmt.printfln("- **doc:** %s", doc)
	}
	fmt.println("\n```odin")
	fmt.println(entry_decl(e))
	fmt.println("```")
	print_docs(e.vd)
}

// The names referenced by a proc group (`g :: proc{a, b}` -> {"a", "b"}).
proc_group_members :: proc(e: Entry) -> []string {
	if e.kind != .Proc_Group {
		return nil
	}
	value := value_for(e.vd, e.name_index)
	pg, is_pg := value.derived_expr.(^ast.Proc_Group)
	if !is_pg {
		return nil
	}
	names: [dynamic]string
	for arg in pg.args {
		if ident, is_ident := arg.derived_expr.(^ast.Ident); is_ident {
			append(&names, ident.name)
		}
	}
	return names[:]
}

// ── apropos ────────────────────────────────────────────────────────────────

cmd_apropos :: proc(args: []string) {
	if len(args) != 1 {
		fmt.eprintfln("odin_decls: usage: odin_decls apropos <term>")
		os.exit(2)
	}
	term := args[0]
	// NOTE: allocate with the stable allocator, NOT the temp allocator -- the
	// temp allocator is freed after every package in the loop below
	needle := strings.to_lower(term, context.allocator)

	// all_scan_packages allocates with the stable allocator and sorts
	pkgs := all_scan_packages(context.allocator)

	outer_allocator := context.allocator

	fmt.printfln("# apropos `%s`\n", term)
	total := 0
	for pkg in pkgs {
		dir, ok := pkg_line_to_dir(pkg)
		if !ok {
			continue
		}

		// parse the whole package with the temp allocator and free it all
		// once the package's matches have been printed
		context.allocator = context.temp_allocator
		entries := parse_package(dir)

		Match :: struct {
			e:   Entry,
			via: string, // proc-group member that matched ("" = own name)
		}
		matches: [dynamic]Match
		seen: map[string]bool
		for e in entries {
			via := ""
			name_lower := strings.to_lower(e.name, context.temp_allocator)
			if strings.contains(name_lower, needle) {
				via = ""
			} else if e.kind == .Proc_Group {
				// grouped declarations are expanded: each member name is
				// checked separately
				matched := false
				for member in proc_group_members(e) {
					member_lower := strings.to_lower(member, context.temp_allocator)
					if strings.contains(member_lower, needle) {
						via = member
						matched = true
						break
					}
				}
				if !matched {
					continue
				}
			} else {
				continue
			}
			if e.name in seen {
				continue // platform-specific variants share names; show once
			}
			seen[e.name] = true
			append(&matches, Match{e = e, via = via})
		}

		if len(matches) > 0 {
			fmt.printfln("## %s\n", pkg)
			for m in matches {
				kind := KIND_NAMES[m.e.kind]
				doc := first_doc_line(m.e.vd)
				if m.via == "" {
					if doc == "" {
						fmt.printfln("- `%s` (%s)", m.e.name, kind)
					} else {
						fmt.printfln("- `%s` (%s) — %s", m.e.name, kind, doc)
					}
				} else {
					if doc == "" {
						fmt.printfln("- `%s` (%s, via `%s`)", m.e.name, kind, m.via)
					} else {
						fmt.printfln("- `%s` (%s, via `%s`) — %s", m.e.name, kind, m.via, doc)
					}
				}
			}
			fmt.println()
			total += len(matches)
		}

		context.allocator = outer_allocator
		free_all(context.temp_allocator)
	}
	if total == 0 {
		fmt.println("_No declarations match._")
	}
}

// ── package loading / parsing ──────────────────────────────────────────────

// The Odin root, cached on first use (needed to resolve cross-package
// aliases, which can happen long after the command handlers ran).
g_root: string

// Project/scan root: the directory whose packages are searched alongside the
// stdlib. Set from `-d <dir>`, or to the current directory when it directly
// contains .odin files. "" = no project (stdlib only).
g_proj_root: string

// -P/--project-only: exclude the stdlib from `ls` and `apropos`.
g_project_only: bool

odin_root_cached :: proc() -> string {
	if g_root == "" {
		g_root = odin_root()
	}
	return g_root
}

// Parsed package entries, keyed by directory -- resolving aliases can pull in
// the same package repeatedly (e.g. the many `x :: os.y` aliases in
// core:path/filepath), so parse each package at most once.
g_pkg_cache: map[string][dynamic]Entry

cached_parse_package :: proc(dir: string) -> []Entry {
	if entries, ok := g_pkg_cache[dir]; ok {
		return entries[:]
	}
	entries := parse_package(dir)
	g_pkg_cache[dir] = entries
	return entries[:]
}

// The Odin root directory: $ODIN_ROOT (set by `odin run` and most tooling),
// falling back to running `odin root`.
odin_root :: proc() -> string {
	if root, ok := os.lookup_env("ODIN_ROOT", context.allocator); ok && root != "" {
		return strings.trim_right(root, "/\\")
	}
	state, stdout, _, err := os.process_exec(
		os.Process_Desc{command = {"odin", "root"}},
		context.allocator,
	)
	if err != nil || !state.success {
		fmt.eprintfln(
			"odin_decls: cannot determine the Odin root directory " +
			"(ODIN_ROOT is unset and `odin root` failed)",
		)
		os.exit(1)
	}
	root := strings.trim_space(string(stdout))
	return strings.trim_right(root, "/\\")
}

split_pkg :: proc(pkg: string) -> (col, rel: string) {
	if i := strings.index(pkg, ":"); i >= 0 {
		return pkg[:i], pkg[i + 1:]
	}
	return "core", pkg
}

pkg_dir :: proc(root, col, rel: string) -> (dir: string, ok: bool) {
	known := false
	for c in COLLECTIONS {
		if c == col {
			known = true
			break
		}
	}
	if !known {
		return "", false
	}
	parts := [?]string{root, "/", col}
	dir = strings.concatenate(parts[:], context.temp_allocator)
	if rel != "" && rel != "." {
		full_parts := [?]string{dir, "/", rel}
		dir = strings.concatenate(full_parts[:], context.temp_allocator)
	}
	if !os.is_directory(dir) {
		return "", false
	}
	return dir, true
}

// Resolve a package spec to a directory and its display label. A spec with
// a ':' is a stdlib address (`core:fmt`, ...) resolved against the Odin root;
// anything else is a path relative to the project/scan root, where '.' is the
// package at the root itself.
resolve_pkg :: proc(spec: string) -> (dir, label: string, ok: bool) {
	if strings.contains(spec, ":") {
		col, rel := split_pkg(spec)
		d, d_ok := pkg_dir(odin_root_cached(), col, rel)
		return d, spec, d_ok
	}
	proj := g_proj_root
	if proj == "" {
		return "", "", false
	}
	rel := strings.trim_prefix(spec, "./")
	if rel == "" {
		return "", "", false
	}
	if rel == "." {
		return proj, spec, true
	}
	// never let a spec escape the scan root
	if rel == ".." || strings.has_prefix(rel, "../") || strings.has_prefix(rel, "/") {
		return "", "", false
	}
	dir, _ = os.join_path([]string{proj, rel}, context.temp_allocator)
	if os.is_directory(dir) {
		return dir, spec, true
	}
	// the scan root's own directory name is sugar for the root package itself
	// (`show odecl` from inside a project named `odecl` == `show .`)
	if rel == os.base(proj) {
		return proj, spec, true
	}
	return "", "", false
}

// Map a package line (as produced by all_scan_packages) back to a directory.
pkg_line_to_dir :: proc(line: string) -> (dir: string, ok: bool) {
	if strings.contains(line, ":") {
		col, rel := split_pkg(line)
		return pkg_dir(odin_root_cached(), col, rel)
	}
	proj := g_proj_root
	if proj == "" {
		return "", false
	}
	if line == "." {
		return proj, true
	}
	dir, _ = os.join_path([]string{proj, line}, context.temp_allocator)
	return dir, os.is_directory(dir)
}

// All packages to search: the project/scan root (if any) and, unless
// `-P/--project-only`, the Odin stdlib. Project packages are labelled `.`
// (the root package) or `foo/bar` (relative paths); stdlib packages keep
// their `col:rel` labels. The result is sorted.
all_scan_packages :: proc(allocator: runtime.Allocator) -> []string {
	lines: [dynamic]string
	if !g_project_only {
		for pkg in all_packages(odin_root_cached(), allocator) {
			append(&lines, pkg)
		}
	}
	if proj := g_proj_root; proj != "" {
		for dir in find_odin_dirs(proj, allocator) {
			rel := dir[len(proj):]
			if len(rel) > 0 && (rel[0] == '/' || rel[0] == '\\') {
				rel = rel[1:]
			}
			rel, _ = strings.replace_all(rel, "\\", "/", allocator)
			append(&lines, rel == "" ? "." : rel)
		}
	}
	slice.sort(lines[:])
	return lines[:]
}

// Is `dir` inside one of the stdlib collection directories (core, base,
// vendor)? Used to suppress the differing-package-names warning for stdlib
// packages.
is_stdlib_dir :: proc(dir: string) -> bool {
	root := odin_root_cached()
	for col in COLLECTIONS {
		col_parts := [?]string{root, "/", col}
		col_dir := strings.concatenate(col_parts[:], context.temp_allocator)
		if !strings.has_prefix(dir, col_dir) {
			continue
		}
		if len(dir) == len(col_dir) {
			return true
		}
		c := dir[len(col_dir)]
		if c == '/' || c == '\\' {
			return true
		}
	}
	return false
}

// Does `dir` directly contain any `.odin` files? Used to decide whether the
// current directory is a project root.
is_odin_project :: proc(dir: string) -> bool {
	finfos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for fi in finfos {
		if fi.type == .Regular && strings.has_suffix(fi.name, ".odin") {
			return true
		}
	}
	return false
}

// Parse every .odin file directly in `dir` and collect its top-level value
// declarations. Everything is allocated with the ambient context.allocator,
// so callers can scope the lifetime (apropos parses with the temp allocator
// and frees per package).
parse_package :: proc(dir: string) -> [dynamic]Entry {
	entries: [dynamic]Entry

	finfos, ferr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if ferr != nil {
		fmt.eprintfln("odin_decls: cannot read directory %s", dir)
		return entries
	}
	paths: [dynamic]string
	for fi in finfos {
		if fi.type != .Regular || !strings.has_suffix(fi.name, ".odin") {
			continue
		}
		append(&paths, fi.fullpath)
	}
	slice.sort(paths[:]) // deterministic declaration order across files
	pkg_names: map[string]bool
	defer delete(pkg_names)
	for path in paths {
		parse_file_into(path, &entries, &pkg_names)
	}
	// all files in a valid Odin package share one package name; a mismatch
	// means the directory isn't a compilable package. The stdlib's example /
	// test files legitimately carry other package names, so only warn for
	// project (non-stdlib) directories.
	if len(pkg_names) > 1 && !is_stdlib_dir(dir) {
		names: [dynamic]string
		for n in pkg_names {
			append(&names, n)
		}
		slice.sort(names[:])
		joined, _ := strings.join(names[:], ", ", context.temp_allocator)
		fmt.eprintfln(
			"odin_decls: warning: %s contains files with differing package names: %s",
			dir,
			joined,
		)
	}
	return entries
}

parse_file_into :: proc(path: string, entries: ^[dynamic]Entry, pkg_names: ^map[string]bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("odin_decls: cannot read %s", path)
		return
	}
	src := string(data)

	// A File needs just src + fullpath; parse_file wires up the tokenizer.
	file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
	file.src = src
	file.fullpath = path

	p := parser.default_parser()
	p.err = quiet_error_handler // we report skipped files ourselves
	if !parser.parse_file(&p, file) {
		fmt.eprintfln("odin_decls: skipping %s (parse errors)", path)
		return
	}

	if file.pkg_name != "" {
		pkg_names[file.pkg_name] = true
	}

	for stmt in file.decls {
		vd, is_vd := stmt.derived_stmt.(^ast.Value_Decl)
		if !is_vd {
			continue // imports, foreign blocks, package-level when, ...
		}
		for name_expr, i in vd.names {
			ident, is_ident := name_expr.derived_expr.(^ast.Ident)
			if !is_ident {
				continue
			}
			append(
				entries,
				Entry {
					kind = classify(vd, i),
					name = ident.name,
					vd = vd,
					name_index = i,
					ident = ident,
					path = path,
					src = src,
					file = file,
				},
			)
		}
	}
}

// parse errors are reported once per file by parse_file_into; the default
// handler would print every single error to stderr
quiet_error_handler :: proc(pos: tokenizer.Pos, format: string, args: ..any) {}

classify :: proc(vd: ^ast.Value_Decl, name_index: int) -> Decl_Kind {
	if vd.is_mutable {
		return .Variable
	}
	value := value_for(vd, name_index)
	if value == nil {
		return .Constant // `::` without a value shouldn't happen; be lenient
	}
	#partial switch _ in value.derived_expr {
	case ^ast.Proc_Lit:
		return .Procedure
	case ^ast.Proc_Group:
		return .Proc_Group
	case ^ast.Struct_Type,
	     ^ast.Union_Type,
	     ^ast.Enum_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Bit_Field_Type,
	     ^ast.Map_Type,
	     ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Fixed_Capacity_Dynamic_Array_Type,
	     ^ast.Matrix_Type,
	     ^ast.Distinct_Type,
	     ^ast.Helper_Type,
	     ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Relative_Type,
	     ^ast.Proc_Type,
	     ^ast.Poly_Type,
	     ^ast.Typeid_Type:
		return .Type
	}
	return .Constant
}

// ── entry rendering ────────────────────────────────────────────────────────

// One-line declaration for the list view.
entry_head :: proc(e: Entry) -> string {
	vd := e.vd
	value := value_for(vd, e.name_index)
	src := e.src

	#partial switch e.kind {
	case .Procedure:
		lit := value.derived_expr.(^ast.Proc_Lit)
		return fmt.aprintf(
			"%s :: %s",
			e.name,
			proc_value_text(lit, src),
			allocator = context.temp_allocator,
		)
	case .Proc_Group, .Type:
		return fmt.aprintf(
			"%s :: %s",
			e.name,
			collapse(node_text(src, value.pos, value.end)),
			allocator = context.temp_allocator,
		)
	case .Constant:
		if vd.type != nil {
			return fmt.aprintf(
				"%s: %s :: %s",
				e.name,
				collapse(node_text(src, vd.type.pos, vd.type.end)),
				value_text(value, src),
				allocator = context.temp_allocator,
			)
		}
		return fmt.aprintf(
			"%s :: %s",
			e.name,
			value_text(value, src),
			allocator = context.temp_allocator,
		)
	case .Variable:
		type_part :=
			fmt.aprintf(": %s", collapse(node_text(src, vd.type.pos, vd.type.end)), allocator = context.temp_allocator) if vd.type != nil else ""
		value_part := ""
		if value != nil {
			assigner := " = " if vd.type != nil else " := "
			value_part = fmt.aprintf(
				"%s%s",
				assigner,
				value_text(value, src),
				allocator = context.temp_allocator,
			)
		}
		return fmt.aprintf(
			"%s%s%s",
			e.name,
			type_part,
			value_part,
			allocator = context.temp_allocator,
		)
	}
	return e.name
}

// Full declaration for the detail view; multi-line text is kept verbatim.
entry_decl :: proc(e: Entry) -> string {
	vd := e.vd
	value := value_for(vd, e.name_index)
	src := e.src

	// procedures (and variables/constants holding a proc literal): signature
	// with the body elided, like `odin doc` prints them
	if value != nil {
		if lit, is_lit := value.derived_expr.(^ast.Proc_Lit); is_lit {
			sep := ":=" if vd.is_mutable else "::"
			return fmt.aprintf(
				"%s %s %s",
				e.name,
				sep,
				proc_value_text_verbatim(lit, src),
				allocator = context.temp_allocator,
			)
		}
	}
	if e.kind == .Proc_Group {
		return fmt.aprintf(
			"%s :: %s",
			e.name,
			node_text(src, value.pos, value.end),
			allocator = context.temp_allocator,
		)
	}
	// types, constants, variables: slice the whole declaration statement
	// verbatim so multi-line struct bodies / raw strings / composite
	// literals survive intact (a grouped decl shows all of its names)
	return strings.trim_right_space(node_text(src, vd.pos, vd.end))
}

print_docs :: proc(vd: ^ast.Value_Decl) {
	if vd.docs == nil {
		return
	}
	fmt.println()
	for tok in vd.docs.list {
		text := tok.text
		if strings.has_prefix(text, "//") {
			text = strings.trim_prefix(text, "//")
			text = strings.trim_prefix(text, " ") // drop the one conventional space
		} else {
			text = strings.trim_prefix(text, "/*")
			text = strings.trim_suffix(text, "*/")
			text = strings.trim_space(text)
		}
		// printed unindented: doc comments are prose in the markdown output
		fmt.println(text)
	}
}

// The first line of the doc comment, with comment markers stripped.
first_doc_line :: proc(vd: ^ast.Value_Decl) -> string {
	if vd.docs == nil || len(vd.docs.list) == 0 {
		return ""
	}
	text := vd.docs.list[0].text
	if strings.has_prefix(text, "//") {
		text = strings.trim_prefix(text, "//")
		text = strings.trim_prefix(text, " ") // drop the one conventional space
		return text
	}
	// a block comment token spans multiple lines (and commonly opens with a
	// bare `/*` line); return its first non-empty line
	text = strings.trim_prefix(text, "/*")
	text = strings.trim_suffix(text, "*/")
	for len(text) > 0 {
		line := text
		if i := strings.index(text, "\n"); i >= 0 {
			line = text[:i]
			text = text[i + 1:]
		} else {
			text = ""
		}
		line = strings.trim_space(line)
		if line != "" {
			return line
		}
	}
	return ""
}

// `p :: proc(...) -> ... {...}` with the body elided (or verbatim when
// body-less, e.g. `proc(...) ---`), whitespace-collapsed to one line.
proc_value_text :: proc(lit: ^ast.Proc_Lit, src: string) -> string {
	return collapse(proc_value_text_verbatim(lit, src))
}

proc_value_text_verbatim :: proc(lit: ^ast.Proc_Lit, src: string) -> string {
	if lit.body == nil {
		return strings.trim_right_space(node_text(src, lit.pos, lit.end))
	}
	// NOTE: '{...}' is built by concatenation because core:fmt treats '{'
	// as a format directive
	sig := proc_signature(lit, src)
	parts := [?]string{sig, " {...}"}
	return strings.concatenate(parts[:], context.temp_allocator)
}

// The `proc(...) -> ...` part of a proc literal, with where-clauses but
// without the body.
proc_signature :: proc(lit: ^ast.Proc_Lit, src: string) -> string {
	end := lit.end
	if lit.body != nil {
		end = lit.body.pos
	}
	return strings.trim_space(node_text(src, lit.pos, end))
}

value_for :: proc(vd: ^ast.Value_Decl, i: int) -> ^ast.Expr {
	if len(vd.values) == 0 {
		return nil
	}
	return vd.values[min(i, len(vd.values) - 1)]
}

value_text :: proc(value: ^ast.Expr, src: string) -> string {
	if value == nil {
		return ""
	}
	if lit, is_lit := value.derived_expr.(^ast.Proc_Lit); is_lit {
		return proc_value_text(lit, src)
	}
	return collapse(node_text(src, value.pos, value.end))
}

// The parser leaves Attribute.end unset (offset 0) for bare attributes
// without parentheses, e.g. `@require_results` -- `ast.new(ast.Attribute,
// tok.pos, end_pos(close))` with a zero `close`. Derive the end from the
// last element in that case, so slicing stays inside the file.
attribute_text :: proc(src: string, attr: ^ast.Attribute) -> string {
	end := attr.end
	if len(attr.elems) > 0 {
		if last := attr.elems[len(attr.elems) - 1]; last.end.offset > end.offset {
			end = last.end
		}
	}
	return node_text(src, attr.pos, end)
}

// Verbatim source slice covered by a node. Parser nodes occasionally carry
// bogus positions (see attribute_text); never crash on them.
node_text :: proc(src: string, pos, end: tokenizer.Pos) -> string {
	if pos.offset < 0 || end.offset > len(src) || end.offset <= pos.offset {
		return ""
	}
	return src[pos.offset:end.offset]
}

// Collapse all whitespace runs (incl. newlines) to single spaces and drop
// `//` and `/* */` comments (Odin block comments nest), so list entries stay
// one line each. String/char literals are preserved verbatim; raw strings
// keep their characters but their internal whitespace collapses too, since a
// multi-line raw string would otherwise break the one-line list invariant
// (the detail view always shows the verbatim source).
collapse :: proc(s: string) -> string {
	sb: strings.Builder
	strings.builder_init_none(&sb, context.temp_allocator)

	in_string, in_char := false, false // "..." / '...': fully verbatim
	in_raw := false // `...`: chars verbatim, whitespace still collapses
	comment_depth := 0
	pending_space := false

	i := 0
	for i < len(s) {
		c := s[i]

		if comment_depth > 0 {
			if c == '/' && i + 1 < len(s) && s[i + 1] == '*' {
				comment_depth += 1
				i += 2
			} else if c == '*' && i + 1 < len(s) && s[i + 1] == '/' {
				comment_depth -= 1
				i += 2
			} else {
				i += 1
			}
			continue
		}

		if in_string || in_char {
			if c == '\\' && i + 1 < len(s) {
				strings.write_byte(&sb, c)
				strings.write_byte(&sb, s[i + 1])
				i += 2
				continue
			}
			if in_string && c == '"' {
				in_string = false
			} else if in_char && c == '\'' {
				in_char = false
			}
			strings.write_byte(&sb, c)
			i += 1
			continue
		}

		if !in_raw && c == '/' && i + 1 < len(s) && s[i + 1] == '/' {
			for i < len(s) && s[i] != '\n' {
				i += 1
			}
			continue
		}
		if !in_raw && c == '/' && i + 1 < len(s) && s[i + 1] == '*' {
			comment_depth += 1
			i += 2
			continue
		}

		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			pending_space = pending_space || strings.builder_len(sb) > 0
			i += 1
			continue
		}

		if pending_space {
			strings.write_byte(&sb, ' ')
			pending_space = false
		}
		if in_raw {
			if c == '`' {
				in_raw = false
			}
		} else {
			switch c {
			case '"':
				in_string = true
			case '`':
				in_raw = true
			case '\'':
				in_char = true
			}
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	return strings.to_string(sb)
}
