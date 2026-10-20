# AGENTS.md

GIR-based Dart FFI bindings for GObject libraries (GLib, GTK4, Libadwaita, Cairo, Pango, GDK, GIO, Graphene, GSK, GdkPixbuf, GObject). A Dart `workspace` monorepo: one generator consumes `.gir` files and emits the per-library packages under `packages/`.

## Setup commands

- Install deps (workspace root): `dart pub get`
- Regenerate bindings: `dart run generator/bin/generate.dart` (run from the workspace root)
- Build everything:    `dart pub get` then `dart analyze` — there is no separate `build` step for the FFI bindings; code is generated, not compiled to a binary
- Build the template stack: `cd example/todo && dart run build_runner build` — this is the one package whose Dart source is generated at build time (see [The composite-template stack](#the-composite-template-stack))
- Build the site:      `dart run tool/build_site.dart` (renders `site_src/pages/*.md` → `site/*.html`; `--check` fails if the committed output is stale, `--serve` builds and serves `site/` locally)
- Refresh the facts:   `dart run tool/collect_facts.dart` (re-derives `site_src/data/facts.json` from the repository)
- Build the API reference: `dart run tool/build_api_docs.dart` (runs `dart doc` per package into `site/docs/` — gitignored, not committed)
- Run all tests:       `dart test generator example/gtk4_examples example/notepad example/todo packages/gdk4 packages/gio packages/gir_ffi packages/glib packages/gobject packages/gtk4 packages/gtk_source5 packages/gtk_templates packages/gtk_templates_builder test` (from the workspace root)
- Per-package test:    `cd packages/<name> && dart test`
- Lint / analyze:      `dart analyze` (root enforces `package:lints/recommended.yaml`; sub-packages use `core.yaml` with project-specific overrides — see [Code style](#code-style))
- Format:              `dart format .`

Dart SDK: ^3.13.4 (resolves to the Flutter-bundled Dart at `/home/meamka/Projects/flutter/bin/dart` in this environment).

## Project layout

- `lib/` — workspace-level library code (currently just `lib/src/`, empty)
- `generator/` — `gir_generator` package. `bin/generate.dart` is the CLI; `lib/src/` is split into `emit/` (Dart code emission), `gir/` (XML loading & parsing), `resolve/` (type/symbol resolution)
- `generator/test/` — generator unit tests (`emitter_test`, `loader_test`, `naming_test`, `parser_test`, `types_test`)
- `packages/gir_ffi/` — handwritten runtime helpers shared by every generated package (the only non-generated package besides the generator and the template stack)
- `packages/<lib>/` — generated FFI binding packages: `adw`, `cairo`, `gdk4`, `gdk_pixbuf`, `gio`, `gi_repository3`, `glib`, `gobject`, `graphene`, `gsk4`, `gtk4`, `gtk_source5`, `pango`. Each declares path-deps on its lower-level dependencies
- `packages/<lib>/skip_report.txt` — per-package record of symbols the generator could not emit; regenerate after fixing the generator
- `packages/gtk_templates/` — handwritten runtime for the composite-template stack: the `@GtkTemplate` / `@GtkTemplateChild` / `@GtkTemplateCallback` annotations, `getWidgetClass`, `widgetTypeOf`, `prepareTemplateXml`, `claimTemplateType`, `snakeCase`, and the `GBytes` re-export
- `packages/gtk_templates_builder/` — the `build_runner` builder for that stack: AST scanner, pure codegen, the `Builder`, and a standalone CLI
- `example/` — consumer examples, each a workspace member: `gtk4_examples/` (small GTK4 demos), `notepad/` (imperative UI), `todo/` (uses `@GtkTemplate` and the generated part file). They resolve against the root lock file and are covered by the root `dart analyze`. **No package may live inside another package's directory** — Dart's workspace refuses a member nested inside another member, so `example/` itself holds no `pubspec.yaml`
- `site_src/` — the project's site sources (not a package — no `pubspec.yaml`, so it does not join the workspace). `pages/*.md` holds one Markdown source per page, `data/packages.json` the curated package list, `data/facts.json` the derived facts, `assets/style.css` the design system
- `site/` — the site's **output**, committed so the site stays browsable without a build. `site/*.html` and `site/assets/` are written by `tool/build_site.dart`; `site/docs/` is the gitignored dartdoc output written by `tool/build_api_docs.dart`
- `tool/` — the workspace's build scripts: `build_api_docs.dart` (the API reference), `build_site.dart` (the site), `collect_facts.dart` (the facts layer), and `tool/site/` (the site's generator library: `markdown.dart`, `frontmatter.dart`, `directives.dart`, `layout.dart`, `components.dart`, `facts.dart`, `highlight.dart`)
- `test/` — workspace-level tests. `test/site/` holds the site generator's suite, including the drift check that the committed `site/` matches `site_src/`
- `docs/` — design documents for the generator pipeline, the template stack, Dart-level subclassing and the site pipeline; see [docs/README.md](docs/README.md)

## The composite-template stack

`packages/gtk_templates_builder` scans a Dart source file for
`@GtkTemplate` classes and writes **one part file per source
file** — `<source-basename>.g.dart` — next to it, holding a
`_$<className>Template` mixin per annotated class.

The generated file is a `part of` the user's library, so:

- The user writes `part '<source-basename>.g.dart';` in their
  own file. The name is derived from the source file's name
  alone — the same convention `json_serializable` uses.
- The mixin inherits the user's library's imports and cannot
  declare its own. The library must import
  `package:gtk4/gtk4.dart`, `package:gtk_templates/gtk_templates.dart`
  and the package that declares the parent widget type. The builder
  checks this and fails with the exact import lines to add.
- The trampoline dispatches through `(this as dynamic)`: the
  mixin is declared `on <ParentType>` and the analyzer rejects a
  call to a member the parent type does not declare.
- **The host class calls `initTemplate()` from its constructor.**
  The mixin overrides `GtkWidget.initTemplate()`: it installs the
  template on the native class (once per native class — GTK allows
  one), binds the children, builds the template and wires the
  signals. GTK builds a widget's template in the instance
  initializer and Dart has no equivalent, so the call has to come
  from the constructor body. Without it the template is built
  lazily, on the first read of a generated field, and a widget
  nobody touches comes up **empty**.
- A Dart subclass has no `GType` of its own, so the runtime
  rewrites the XML's `<template class=… parent=…>` attributes
  against the instance's real native type (GTK checks both), and
  strips the `<signal>` elements before GTK sees them (GtkBuilder
  would resolve the handler as a C symbol). The children are
  resolved with `getTemplateChild(<widget's own type>, id)` — the
  type that *declared* the child, not the child's type.

`build_to: source` is set in the **provider** package's
`build.yaml` (`packages/gtk_templates_builder/build.yaml`), not
in the consumer's — Dart requires a part file to sit in the
same directory as its library. Consumers only configure
`generate_for`.

The full design is in [docs/templates.md](docs/templates.md).

**Rule: generated code must type-check.** The builder's output
is resolved with the real analyzer in
`packages/gtk_templates_builder/test/generated_code_test.dart`
and `test/builder_output_test.dart`, and the fixture under
`test/fixtures/` is part of the package's own analysis so
`dart analyze` covers it too. Four codegen bugs shipped to
`main` before those tests existed (an uncalled `_wireSignals()`,
a `cast<T>()` without its factory argument, a missing
`package:gobject` import, and a missing parent-type import).
Do not add codegen that a parse-only check would accept.

## Generated classes are extendable

Generated GObject classes are emitted as `class`, **not**
`final class`, and their `<ClassName>Props` companions are public and
extendable. That is what lets user code write
`class MyButton extends GtkButton`, narrow a return type
covariantly, and subclass the props companion. The contract is
pinned by the *Dart-level subclassing contract* group in
`generator/test/emitter_test.dart` — do not reintroduce `final class`
or a private props companion. The ownership and lifetime rules are in
[docs/subclassing.md](docs/subclassing.md).

## The site

`site/` is generated. The sources live in `site_src/`, the output is
committed, and CI regenerates both and fails if either drifts — the same
rule the repository already applies to the generated bindings.

- `site_src/pages/*.md` — one Markdown file per page. The front matter
  carries `title`, `doc_title`, `description`, `nav_order`, `nav_label`
  and `section_label` (the kicker above the `h1`). `##` headings
  become the numbered sections and feed the rail's table of contents.
- `site_src/data/packages.json` — the curated package list (namespace,
  native library, role, blurb). It is the single source of truth for
  the site's coverage table *and* for the API reference's package index;
  `tool/collect_facts.dart` fails if it names a package that is not in
  the workspace or a namespace the skip report contradicts.
- `site_src/data/facts.json` — the derived facts: the per-package skip
  counts, the aggregated coverage groups, the SDK constraint, the
  licence, the size of the generated tree. Regenerated by
  `tool/collect_facts.dart`; a placeholder that names a fact which does
  not exist **fails the build** with the file and the line.
- `site_src/assets/style.css` — the design system. One stylesheet, CSS
  custom properties, light and dark via `prefers-color-scheme`.

The generator is **plain Dart with no external dependencies** — only
`dart:`. This is not a style choice: `package:markdown` is not in the
local pub cache, `package:yaml` would force a workspace re-resolution
that breaks `dart test`, and CI must be able to build the site with
nothing but the Dart SDK. The Markdown subset the site needs (headings,
paragraphs, lists, tables, code fences, quotes, rules, raw HTML) is
implemented in `tool/site/markdown.dart` and covered by unit tests.

**Rule: a number on the site is derived, never typed.** The page
sources carry no package, skip-count or test-count numbers; they come
from `facts.json` through `{{facts.…}}` placeholders, or from a
generated table. `test/site/site_output_test.dart` enforces it.

The full design is in [docs/site.md](docs/site.md).

## Code style

- Lints at workspace root: `package:lints/recommended.yaml`
- Sub-packages (`packages/<lib>/`) override to `package:lints/core.yaml` and add per-package analyzer overrides in `analysis_options.yaml`. Do not move lints between root and sub-packages without checking downstream packages — the generated packages inherit from their own `analysis_options.yaml`
- Doc comments emitted from GIR contain angle-bracket HTML; sub-packages set `analyzer.errors.unintended_html_in_doc_comment: ignore` for that reason. Keep that override if you regenerate
- `pubspec.lock` is git-ignored (`.gitignore`); do not commit it
- Hand-written code goes under `lib/src/` (or `generator/lib/src/{emit,gir,resolve}`, or `tool/site/` for the site generator); generated code lives in `packages/<lib>/lib/src/` and must not be edited by hand — change the generator instead. The site's generated HTML lives in `site/` and must not be edited by hand either — change `site_src/` and re-run `tool/build_site.dart`
- **Callbacks**: each `<callback>` becomes a Dart function typedef whose name matches the GIR `c:type` (e.g. `GCompareDataFunc`). The typedef uses Dart convenience types (`int`, `double`, `bool` is exposed as `int` per the convention `0` = false / non-zero = true) for primitives and `ffi.Pointer<ffi.Void>` for opaque pointers. Wrapper parameters carry the inline signature rather than the typedef name so Dart FFI's `NativeCallable` accepts the user's function through the wrapper. Callbacks are not currently emitted as nullable parameters (none of the GIR files in scope declare one); a callback as a return type is also rejected

## Testing instructions

- **All tests, one command** (from the workspace root):
  `dart test generator example/gtk4_examples example/notepad example/todo packages/gdk4 packages/gio packages/gir_ffi packages/glib packages/gobject packages/gtk4 packages/gtk_source5 packages/gtk_templates packages/gtk_templates_builder test`
  — 330 passed, 7 skipped (the skips are the native GTK tests — see below).
- **Why the explicit list?** `dart test` with no argument runs only the *root* package's own `test/` directory, which now holds the site generator's suite. The generator tests, the template-package tests and the per-package smoke tests live in their own packages' `test/` directories, so they have to be named. `dart pub workspace run` does not exist in this Dart SDK — `dart pub workspace` only offers `list`.
- **Per package:** `cd <package> && dart test` works for any workspace member.
- **Generator tests** live in `generator/test/` and also run as part of the all-tests command.
- **Generated packages** carry a smoke test (e.g. `packages/glib/test/glib_smoke_test.dart`) — run per-package with `cd packages/<lib> && dart test`
- **Generated code must type-check.** `packages/gtk_templates_builder/test/generated_code_test.dart` resolves the generated part file with the real analyzer and asserts zero diagnostics; `builder_output_test.dart` does the same for the `build_runner` output. A parse-only check is not enough.
- **The committed site must match its sources.** `test/site/site_output_test.dart` renders every page from `site_src/` in memory and compares the result with the committed `site/`, and it walks the generated HTML checking that every internal link resolves and every rail anchor exists. Run it after any change under `site_src/` — or just run `dart run tool/build_site.dart` and commit the result.
- **Native GTK tests skip themselves without a display.** `example/todo/test/todo_widget_test.dart` builds the real window and asserts that the template is on screen. GTK needs a display, so the suite skips when there is none (CI is headless). Run it locally with `xvfb-run -a dart test example/todo`. Its teardown disconnects the Dart signal handlers **and destroys the windows**: a `GObject` finalized *while the isolate shuts down* destroys its signal handlers, and the destroy-notify GObject calls is a Dart callback — the VM refuses to run a callback while it is shutting down and aborts; and a window only freed at shutdown is still in GTK's global toplevel list, which GTK walks on every main-loop iteration (a use-after-free, and `dart test` runs the GTK-using suites concurrently in one process). Both are pre-existing properties of the bindings' object lifecycle, not of the template stack.
- Skip report: when the generator emits fewer bindings, `packages/<lib>/skip_report.txt` lists them by category (`callable`, `class`, `record`, etc.). Use it to triage missing functionality
- All tests must pass and `dart analyze` must be clean for the whole workspace before opening a PR

## PR & commit conventions

- The workspace is a git repository. `main` is the trunk; `array-types`, `notepad` and `props` are already merged. `gasync` is superseded — do not build on it. `composite-templates` holds an unmerged prototype: it is **not** to be merged, and it will be retired once its one remaining capability is confirmed present on `main` (see [Generated classes are extendable](#generated-classes-are-extendable)). Its Blueprint/GResource support, Meson/gettext packaging and program-lifetime `NativeCallable` trampoline are out of scope.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:` — generator changes get a `feat(generator):` or `fix(generator):` prefix; regenerated packages go under `chore(gen):` or `feat(gen <lib>):`
- One PR per logical change. Generator changes must include the regenerated `packages/<lib>/` output and the matching `skip_report.txt` updates in the same PR — reviewers must see the effect on a generated package
- CI is checked in at `.github/workflows/ci.yml`: analyze, the generator tests, the template packages' pure-Dart tests, and a build + analyze gate over `example/todo`. Native GTK runtime tests are deliberately out of CI (they need a display and the native GTK 4 stack); keep them out until a CI image provides one. When you add a CI step, add it to that workflow in the same PR
- **Callback typedefs** follow the GIR `c:type` (e.g. `GCompareDataFunc`). User-supplied callbacks must be **top-level or static Dart functions** with parameter and return types matching the typedef's signature; closures and instance methods are accepted at runtime only through the wrapping `NativeCallable.isolateLocal` that the generator emits at every call site. The wrapper allocates the NativeCallable before the call and `.close()`-s it in a `finally` block — long-lived callbacks must therefore be passed as top-level functions so the temporary `NativeCallable` doesn't outlive the wrapper

## Security

- `.gitignore` excludes `.dart_tool/` and `pubspec.lock` — keep secrets out of the repo and never commit `~/.pub-cache` content
- Generated bindings call into native libraries (`libglib-2.0`, `libgtk-4`, …) via `dart:ffi`. Treat pointer lifetimes and ownership transfers (especially `transfer-full` vs `transfer-none` in GIR) as security-relevant — leaks and use-after-free are bugs, not style issues
- This project is `publish_to: none` for every package; do not enable publishing without explicit owner approval
