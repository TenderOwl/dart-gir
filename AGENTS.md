# AGENTS.md

GIR-based Dart FFI bindings for GObject libraries (GLib, GTK4, Libadwaita, Cairo, Pango, GDK, GIO, Graphene, GSK, GdkPixbuf, GObject). A Dart `workspace` monorepo: one generator consumes `.gir` files and emits the per-library packages under `packages/`.

## Setup commands

- Install deps (workspace root): `dart pub get`
- Regenerate bindings: `dart run generator/bin/generate.dart` (run from the workspace root)
- Build everything:    `dart pub get` then `dart analyze` — there is no separate `build` step; code is generated, not compiled to a binary
- Run all tests:       `dart test` (run from the workspace root; uses `test: ^1.25.6`)
- Per-package test:    `cd packages/<name> && dart test`
- Lint / analyze:      `dart analyze` (root enforces `package:lints/recommended.yaml`; sub-packages use `core.yaml` with project-specific overrides — see [Code style](#code-style))
- Format:              `dart format .`

Dart SDK: ^3.13.4 (resolves to the Flutter-bundled Dart at `/home/meamka/Projects/flutter/bin/dart` in this environment).

## Project layout

- `lib/` — workspace-level library code (currently just `lib/src/`, empty)
- `generator/` — `gir_generator` package. `bin/generate.dart` is the CLI; `lib/src/` is split into `emit/` (Dart code emission), `gir/` (XML loading & parsing), `resolve/` (type/symbol resolution)
- `generator/test/` — generator unit tests (`emitter_test`, `loader_test`, `naming_test`, `parser_test`, `types_test`)
- `packages/gir_ffi/` — handwritten runtime helpers shared by every generated package (the only non-generated package besides the generator)
- `packages/<lib>/` — generated FFI binding packages: `adw`, `cairo`, `gdk4`, `gdk_pixbuf`, `gio`, `glib`, `gobject`, `graphene`, `gsk4`, `gtk4`, `pango`. Each declares path-deps on its lower-level dependencies
- `packages/<lib>/skip_report.txt` — per-package record of symbols the generator could not emit; regenerate after fixing the generator
- `example/` — consumer example (empty placeholder)
- `test/` — workspace-level tests (empty placeholder)

## Code style

- Lints at workspace root: `package:lints/recommended.yaml`
- Sub-packages (`packages/<lib>/`) override to `package:lints/core.yaml` and add per-package analyzer overrides in `analysis_options.yaml`. Do not move lints between root and sub-packages without checking downstream packages — the generated packages inherit from their own `analysis_options.yaml`
- Doc comments emitted from GIR contain angle-bracket HTML; sub-packages set `analyzer.errors.unintended_html_in_doc_comment: ignore` for that reason. Keep that override if you regenerate
- `pubspec.lock` is git-ignored (`.gitignore`); do not commit it
- Hand-written code goes under `lib/src/` (or `generator/lib/src/{emit,gir,resolve}`); generated code lives in `packages/<lib>/lib/src/` and must not be edited by hand — change the generator instead
- **Callbacks**: each `<callback>` becomes a Dart function typedef whose name matches the GIR `c:type` (e.g. `GCompareDataFunc`). The typedef uses Dart convenience types (`int`, `double`, `bool` is exposed as `int` per the convention `0` = false / non-zero = true) for primitives and `ffi.Pointer<ffi.Void>` for opaque pointers. Wrapper parameters carry the inline signature rather than the typedef name so Dart FFI's `NativeCallable` accepts the user's function through the wrapper. Callbacks are not currently emitted as nullable parameters (none of the GIR files in scope declare one); a callback as a return type is also rejected

## Testing instructions

- Workspace tests: `dart test` (resolves to `test/` at the root and any package-level `test/`)
- Generator tests live in `generator/test/` and run as part of `dart test` from the root, or directly via `cd generator && dart test`
- Generated packages carry a smoke test (e.g. `packages/glib/test/glib_smoke_test.dart`) — run per-package with `cd packages/<lib> && dart test`
- Skip report: when the generator emits fewer bindings, `packages/<lib>/skip_report.txt` lists them by category (`callable`, `class`, `record`, etc.). Use it to triage missing functionality
- All tests must pass and `dart analyze` must be clean for the whole workspace before opening a PR

## PR & commit conventions

- No git repository exists in this workspace yet — initialize with `git init` before the first commit, and commit `AGENTS.md` with the initial source drop
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:` — generator changes get a `feat(generator):` or `fix(generator):` prefix; regenerated packages go under `chore(gen):` or `feat(gen <lib>):`
- One PR per logical change. Generator changes must include the regenerated `packages/<lib>/` output and the matching `skip_report.txt` updates in the same PR — reviewers must see the effect on a generated package
- No CI configuration is checked in yet; add `.github/workflows/` under the same PR that introduces CI
- **Callback typedefs** follow the GIR `c:type` (e.g. `GCompareDataFunc`). User-supplied callbacks must be **top-level or static Dart functions** with parameter and return types matching the typedef's signature; closures and instance methods are accepted at runtime only through the wrapping `NativeCallable.isolateLocal` that the generator emits at every call site. The wrapper allocates the NativeCallable before the call and `.close()`-s it in a `finally` block — long-lived callbacks must therefore be passed as top-level functions so the temporary `NativeCallable` doesn't outlive the wrapper

## Security

- `.gitignore` excludes `.dart_tool/` and `pubspec.lock` — keep secrets out of the repo and never commit `~/.pub-cache` content
- Generated bindings call into native libraries (`libglib-2.0`, `libgtk-4`, …) via `dart:ffi`. Treat pointer lifetimes and ownership transfers (especially `transfer-full` vs `transfer-none` in GIR) as security-relevant — leaks and use-after-free are bugs, not style issues
- This project is `publish_to: none` for every package; do not enable publishing without explicit owner approval
