<!--
SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier

SPDX-License-Identifier: BSD-2-Clause
-->

# odecl

Inspect Odin packages — list packages, list top-level declarations, and search
for declarations — using Odin's own parser (`core:odin/parser`) instead of
scraping `odin doc` text output.

## Usage

```
odecl [-d <dir>] [-P|--project-only] <command> [arguments]
```

Flags (must come before the subcommand):

| flag | meaning |
|------|---------|
| `-d <dir>` | project/scan root directory (default: current dir, if it directly contains `.odin` files) |
| `-P`, `--project-only` | search only the project; exclude the stdlib (default: project **and** stdlib are searched) |

Commands:

| command | description |
|---------|-------------|
| `ls [filter]` | list packages, one per line (optional case-sensitive prefix filter) |
| `show <pkg> [ident]` | list a package's top-level declarations, or show one declaration in detail |
| `apropos <term>` | search declaration names across all packages (case-insensitive substring) |

### Package addressing

* A spec containing `:` is a stdlib address: `core:fmt`, `base:runtime`,
  `vendor:raylib`.
* Any other spec is a path relative to the scan root:
  * `.` — the package at the scan root itself
  * `foo` — the package `foo` inside the scan root
  * `foo/bar` — the package `bar` inside package `foo`

The stdlib is always searched in addition to the project unless `-P` is given.
`show` addresses are always resolved explicitly, so `-P show core:fmt` still
works.

### Examples

```sh
odecl ls                    # project (if any) + stdlib packages
odecl -P ls                 # only this project's packages
odecl ls core:              # only core: packages
odecl show .                # declarations of the scan-root package
odecl show foo/bar          # declarations of the foo/bar package
odecl show core:fmt         # declarations of the core:fmt stdlib package
odecl show core:fmt println # detail view for one declaration
odecl apropos alloc         # search declarations across project + stdlib
odecl -d ~/proj/mylib ls    # scan another directory
```

## Notes

* `odecl` warns on stderr when a package directory contains files with
  differing `package X` declarations.
* Files that fail to parse are skipped with a warning on stderr.
* As a result, `base/builtin/builtin.odin` and `base/intrinsics/intrinsics.odin`
  are skipped (their files fail to parse), so their declarations are absent
  from `show base:builtin` / `show base:intrinsics` and from `apropos`.

Finally, this tool is built entirely by various LLM models, using skills and tools
dreamt up or outright developed by their human shepherd.

Building this tool, I used [Odin Language Overview](https://github.com/jwdevantier/pi.odin.lang.overview), a pi extension which parses the official Odin Language Overview page and constructs a markdown version of it and provides the LLM with tools for reading the table-of-contents and any desired (sub-)sections.
The LLMs also had access to a more primitive variant of `odecl` for purposes of navigating the stdlib and vendored packages.

## Compile

```sh
odin build .
```
