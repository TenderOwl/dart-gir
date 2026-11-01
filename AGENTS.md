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
- Run all tests:       `dart test generator example/gtk4_examples example/notepad example/todo packages/gir_dart_gobject packages/gir_gdk4 packages/gir_gio packages/gir_ffi packages/gir_glib packages/gir_gobject packages/gir_graphene packages/gir_gtk4 packages/gir_gtk_source5 packages/gir_gtk_templates packages/gir_gtk_templates_builder test` (from the workspace root)
- Per-package test:    `cd packages/<name> && dart test`
- Lint / analyze:      `dart analyze` (root enforces `package:lints/recommended.yaml`; sub-packages use `core.yaml` with project-specific overrides — see [Code style](#code-style))
- Format:              `dart format .`
- Prepare a release:  `dart run tool/release.dart prepare` (writes the publication copies *outside* the repository — pub packs a git-ignored package as an empty archive)
- Check publishability: `dart run tool/release.dart check` (the structural checks pub.dev would run; the CI gate)
- Publish:            `dart run tool/release.dart publish` (the owner runs this, with `PUB_TOKEN` in the environment)

Dart SDK: ^3.13.4 (resolves to the Flutter-bundled Dart at `/home/meamka/Projects/flutter/bin/dart` in this environment).

## Project layout

- `lib/` — workspace-level library code (currently just `lib/src/`, empty)
- `generator/` — `gir_generator` package. `bin/generate.dart` is the CLI; `lib/src/` is split into `emit/` (Dart code emission), `gir/` (XML loading & parsing), `resolve/` (type/symbol resolution)
- `generator/test/` — generator unit tests (`emitter_test`, `loader_test`, `naming_test`, `parser_test`, `types_test`)
- `packages/gir_ffi/` — handwritten runtime helpers shared by every generated package (string marshalling, the wrapper cache, `HeapAnchor`, `keepAlive`)
- `packages/gir_dart_gobject/` — handwritten runtime for Dart classes with a native type: `registerDartType(name, parentType, {vfuncs, signals, properties, interfaces, overrides})` registers a GType with GLib — and the signals, properties, interfaces and virtual functions it declares — so a Dart subclass of `GObject` has a native identity; `newDartInstance(type)` creates an instance of it
- `packages/<lib>/` — generated FFI binding packages: `gir_adw`, `gir_cairo`, `gir_gdk4`, `gir_gdk_pixbuf`, `gir_gi_repository3`, `gir_gio`, `gir_glib`, `gir_gobject`, `gir_graphene`, `gir_gsk4`, `gir_gtk4`, `gir_gtk_source5`, `gir_pango`. Each declares path-deps on its lower-level dependencies
- `packages/<lib>/skip_report.txt` — per-package record of symbols the generator could not emit; regenerate after fixing the generator
- `packages/gir_gtk_templates/` — handwritten runtime for the composite-template stack: the `@GtkTemplate` / `@GtkTemplateChild` / `@GtkTemplateCallback` annotations, `getWidgetClass`, `widgetTypeOf`, `prepareTemplateXml`, `claimTemplateType`, `requireOwnType`, `snakeCase`, and the `GBytes` re-export
- `packages/gir_gtk_templates_builder/` — the `build_runner` builder for that stack: AST scanner, pure codegen, the `Builder`, and a standalone CLI
- `example/` — consumer examples, each a workspace member: `gtk4_examples/` (small GTK4 demos), `notepad/` (imperative UI), `todo/` (uses `@GtkTemplate` and the generated part file). They resolve against the root lock file and are covered by the root `dart analyze`. **No package may live inside another package's directory** — Dart's workspace refuses a member nested inside another member, so `example/` itself holds no `pubspec.yaml`
- `site_src/` — the project's site sources (not a package — no `pubspec.yaml`, so it does not join the workspace). `pages/*.md` holds one Markdown source per page, `data/packages.json` the curated package list, `data/facts.json` the derived facts, `assets/style.css` the design system
- `site/` — the site's **output**, committed so the site stays browsable without a build. `site/*.html` and `site/assets/` are written by `tool/build_site.dart`; `site/docs/` is the gitignored dartdoc output written by `tool/build_api_docs.dart`
- `tool/` — the workspace's build scripts: `build_api_docs.dart` (the API reference), `build_site.dart` (the site), `collect_facts.dart` (the facts layer), `release.dart` (prepare / check / publish), and `tool/site/` (the site's generator library: `markdown.dart`, `frontmatter.dart`, `directives.dart`, `layout.dart`, `components.dart`, `facts.dart`, `highlight.dart`)
- `test/` — workspace-level tests. `test/site/` holds the site generator's suite, including the drift check that the committed `site/` matches `site_src/`
- `docs/` — design documents for the generator pipeline, the template stack, Dart-level subclassing and the site pipeline; see [docs/README.md](docs/README.md)

**Rule: every package name carries the `gir_` prefix.** The bare names
(`glib`, `gio`, `cairo`, `graphene`, …) are taken on pub.dev by other
publishers, so the prefix is what makes the whole set publishable. The
name is decided in one place — `packageNameFor` in
`generator/lib/src/resolve/types.dart` — and everything else follows from
it: the directory (`packages/gir_gtk4/`), the library file
(`lib/gir_gtk4.dart`), the import path
(`package:gir_gtk4/gir_gtk4.dart`), the generated lookup helper
(`girGtk4Lookup`), and the dependency keys in the pubspecs. A package
added to the set needs one line in that map, not a sweep through the
repository.

## The composite-template stack

`packages/gir_gtk_templates_builder` scans a Dart source file for
`@GtkTemplate` classes and writes **one part file per source
file** — `<source-basename>.g.dart` — next to it, holding a
`_$<className>Template` mixin per annotated class.

The generated file is a `part of` the user's library, so:

- The user writes `part '<source-basename>.g.dart';` in their
  own file. The name is derived from the source file's name
  alone — the same convention `json_serializable` uses.
- The mixin inherits the user's library's imports and cannot
  declare its own. The library must import
  `package:gir_gtk4/gir_gtk4.dart`, `package:gir_gtk_templates/gir_gtk_templates.dart`
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
`build.yaml` (`packages/gir_gtk_templates_builder/build.yaml`), not
in the consumer's — Dart requires a part file to sit in the
same directory as its library. Consumers only configure
`generate_for`.

A template in a **file** (`@GtkTemplate(source:
GtkTemplateFile('data/window.ui'))`) is read through the build's
asset reader, so it is a *tracked build input*: editing it re-runs
the builder. Two rules follow from that. The file has to be a
**public asset** of the package — a build sees `lib/**` and
`bin/**`, and nothing else unless the consumer's `build.yaml`
declares `additional_public_assets` — and a template file that
cannot be read **fails the build** rather than being skipped.
A skipped class leaves the previous part file in place, and the
stale template keeps running as if the edit had never happened.

The full design is in [docs/templates.md](docs/templates.md). The stack
is committed on `main`; the retired `composite-templates` branch's variant
of it was a superseded prototype — see
[docs/branch-state.md](docs/branch-state.md).

**Rule: generated code must type-check.** The builder's output
is resolved with the real analyzer in
`packages/gir_gtk_templates_builder/test/generated_code_test.dart`
and `test/builder_output_test.dart`, and the fixture under
`test/fixtures/` is part of the package's own analysis so
`dart analyze` covers it too. Four codegen bugs shipped to
`main` before those tests existed (an uncalled `_wireSignals()`,
a `cast<T>()` without its factory argument, a missing
`package:gobject` import, and a missing parent-type import).
Do not add codegen that a parse-only check would accept.

## Dart classes with a native type

A Dart class can extend a generated GObject wrapper, but it used to
have no *native* type: as far as GLib was concerned it was a plain
`GObject`, so `GListStore` refused it and a native round trip through
a list item produced a new wrapper with no Dart state. Four generator
features and one runtime package fix that:

- **G1** — every generated class and interface exposes
  `static int get GType`, looked up once from the GIR's
  `glib:get-type`.
- **G2** — `GTypeInfo`, `GTypeQuery`, `GTypeFundamentalInfo` and
  `GInterfaceInfo` are emitted as `ffi.Struct`, so the C layout comes
  from the GIR and the struct can be passed *by value*.
- **G3** — `packages/gir_ffi` keeps a **weak** cache from the native
  address to the Dart object, and `fromPointer` became a **factory**:
  the same native pointer always yields the same Dart object.
- **G4** — `GObject(int objectType)` instantiates a native type.
- **R1** — `packages/gir_dart_gobject`'s `registerDartType(name,
  parentType)` registers the type with GLib.

```dart
class TaskObject extends GObject {
  static int get GType => registerDartType('TaskObject', GObject.GType);

  TaskObject({this.completed = false, required this.content}) : super(GType);

  bool completed;
  String content;
}

final store = GListStore(TaskObject.GType);
```

**Rule: the type name is the type's identity.** GLib refuses to
register a name twice; `registerDartType` returns the type registered
first and throws a `StateError` when GLib refuses outright.

**Rule: `GType` breaks `lowerCamelCase`.** The generated accessor and
a Dart subclass's own accessor use GLib's name. The lint
`non_constant_identifier_names` fires on it — the generated packages,
`packages/gir_dart_gobject` and `example/todo` turn it off, and a user
package has to do the same.

**Rule: the instance is released by the garbage collector.** The
wrapper owns the reference `g_object_newv` handed it, and a
`NativeFinalizer` releases it when the wrapper is collected. A widget
that is parented has its floating reference sunk by the generated
constructor; a widget that GTK frees must have its finalizer detached
first (`gobjectFinalizer.detach(widget)`). GTK's selection models
dispose the model they wrap, so the model has to outlive the
selection. See [docs/dart-gobjects.md](docs/dart-gobjects.md) for the
whole story, and `example/todo` for the worked example.

### What a Dart type can carry

`registerDartType(name, parentType, {vfuncs, signals, properties,
interfaces, overrides})` registers the type **and** what it declares:

- **signals** — `DartSignal.withoutArgument` / `.withArgument(kind, …)`;
  real GLib signals, installed in the type's `class_init`.
- **properties** — `DartProperty.string` / `.integer` / `.boolean` /
  `.real` / `.object`; real `GParamSpec`s. The property's
  `set_property` / `get_property` slots are patched **before** the
  property is installed — `g_object_base_class_init` resets them to
  `NULL`, and GLib refuses a writable property without a
  `set_property`.
- **interfaces** — `g_type_add_interface_static`, after
  `g_type_register_static` and **before** the class is initialized.
- **overrides** — the virtual functions: `GObject.constructed` /
  `dispose` / `finalize`, and `GtkWidget.snapshot` / `measure` /
  `size_allocate` through `measureOverride`, `snapshotOverride` and
  `sizeAllocateOverride`. Each chains up to the inherited
  implementation.

**Rule: the ABI table is hand-written, in the runtime package.** The
class struct's layout is not in the GIR — the GIR lists a class's
virtual methods alphabetically, the C struct declares them in vtable
order. The offsets live in `packages/gir_dart_gobject/lib/src/` and are
cross-checked against the installed headers by
`packages/gir_dart_gobject/test/vtable_layout_test.dart`. They are *not*
in the generator: the generated packages cannot depend on
`gir_dart_gobject` — the dependency runs the other way.

**Rule: a GObject carrying a Dart callback must not be finalized while
the isolate shuts down.** GObject would call back into a VM that is
already tearing itself down, and the VM aborts. The virtual-function
wiring is therefore opt-in, and a type that opts in has to release its
objects before the isolate ends.

**Rule: the template stack installs on the type the class registers.**
GTK keeps one template per *native* class, so two Dart classes
extending the same native widget type could not both have a template.
A class that declares a `GType` of its own gets a class of its own —
and the widget has to be an instance of it, which is what
`newDartInstance(type, constructProperties: …)` is for. The builder's
scanner recognizes the `GType` accessor and emits the own-type path;
the generated mixin refuses an instance of the wrong type and says
which constructor to use instead. See
[docs/templates.md](docs/templates.md#51-a-template-on-the-dart-classs-own-type).

## Ownership comes from the GIR

The GIR says who owns a reference — `transfer-ownership="full"` on a
return value or a parameter. The bindings follow it exactly, in both
directions:

- a `transfer="full"` **return** is claimed by the wrapper and released
  by a `NativeFinalizer` when the wrapper is collected;
- a `transfer="full"` **parameter** is handed to the callee: the call
  site detaches the finalizer and clears the `owned` flag;
- a boxed type with a destructor (`free`/`unref`/`destroy`/`release`/
  `close`) gets a `NativeFinalizer` of its own;
- the public `bool owned` field says whether the wrapper still holds the
  reference.

**Rule: the ownership is in the GIR, not in the wrapper's shape.** A
callable that hands a reference to the callee must not keep a claim on
it, and a callable that receives one must release it exactly once. The
`owned` flag is the single source of that truth: `true` while the
wrapper holds the reference, `false` once it has been released or handed
over. Never release a reference behind the wrapper's back — call
`unref()`/`free()`, which detaches the finalizer first.

**Rule: a callback that outlives its call needs a permanent trampoline.**
A `GDestroyNotify` next to a byte buffer is called when the *callee* is
done with the buffer — after the call that passed it returned. A scoped
`NativeCallable` would be closed before the notify fires, and the Dart
VM aborts the isolate with *"Callback invoked after it has been
deleted"*. The generator emits a permanent `ffi.Pointer.fromFunction`
trampoline over a static function, with the user's callback parked in
a per-callable registry until the notify arrives.

**Rule: a byte buffer the callee keeps carries its lifetime on the
wrapper.** A byte array that stays a raw pointer — because the callable
is asynchronous or because the callee takes the buffer over — gets a
doc comment that states the contract and names the `GBytes` sibling
when the library declares one. The note belongs on the **public**
wrapper: a note on the private native binding never reaches the API
reference.

**Rule: a floating reference is taken through the copy function.** One
type in the corpus uses floating references — `GVariant`. The GIR marks
such a return `transfer="none"` because the reference belongs to nobody,
and names the function that takes a reference of your own in the
record's `copy-function` attribute (`g_variant_ref_sink`, which sinks a
floating reference *and* adds one to a reference somebody else owns).
The wrapper takes its own reference through that copy function and owns
it. A wrapper that handed the floating reference over as it was let a
consumer that assumes ownership end up owning the very reference the
wrapper's `unref()` released — the count underflowed and the heap was
corrupted. The rule is pinned by the *Floating references* group in
`generator/test/emitter_test.dart` and by
`packages/gir_glib/test/variant_test.dart`.

The rules are written down in [docs/emission.md](docs/emission.md) and
[docs/subclassing.md](docs/subclassing.md), and pinned by the
*Ownership transfer* and *Byte arrays* groups in
`generator/test/emitter_test.dart` plus the runtime tests in
`packages/{gobject,glib,gio,gtk4}/test/ownership_test.dart` and
`packages/gir_gio/test/byte_array_test.dart`.

## Parameters and returns that do not fit the obvious shape

Four GIR shapes do not map onto a Dart signature in the obvious way. Three
are bridged; one is a documented limitation.

**A `char **` return is a `List<String>`.** GLib's `GStrv` — a
NULL-terminated array of strings — is copied into a Dart list by
`stringListFromNative` (`package:gir_ffi`). The `free` flag follows the
GIR's `transfer-ownership`: a static table stays GLib's (`free: false`),
an allocated array is released with `g_strfreev` (`free: true`). The
*string-list returns* group in `generator/test/emitter_test.dart` and
`packages/{gir_ffi,glib}/test/string_list_test.dart` pin it.

**A nullable scalar parameter is passed by pointer.** The C API takes a
`gint *` that may be NULL (`allow-none="1"`). Dart FFI cannot express
`int?` over a primitive slot, so the wrapper allocates a one-slot
buffer, seeds it with the caller's value — or passes NULL when the
caller passed none — and reads it back after the call. The value the
callee wrote is the wrapper's next return element. The *nullable scalar
parameters* group in `generator/test/emitter_test.dart` pins it.

**A property without a GIR `<type>` takes the type from its getter.** The
props accessor takes the *getter's* return type, and the props layer
may only call typed methods that were actually emitted — it mirrors the
callable emitter's skip list. An accessor that called a method the
package does not have would not compile.

**`inout` parameters are skipped, on purpose.** The C function reads
*and* writes through the pointer, and the GIR's ownership annotations
for these parameters are demonstrably wrong —
`gtk_source_buffer_forward_iter_to_source_mark`'s `iter` is marked
`transfer-ownership="full"`, but GTK does not take ownership of the
iterator. A wrong lifetime rule is worse than no binding, so the
callable is skipped with the reason `inout parameter <X>` (39 callables
in the current corpus). Shipping it would mean releasing memory the
generator does not own. See
[docs/skip-categories.md](docs/skip-categories.md#inout-parameter-x).

**Rule: a native call has one argument per C parameter.** The C ABI has
no notion of an omitted argument, so a parameter may not be dropped from
the native argument list — not even an OUT parameter the wrapper has
nowhere to put. The async convenience overload allocates the OUT slot,
passes it and releases it after the call; the value is discarded and the
base wrapper (which returns it) is still there.

## Generated classes are extendable

Generated GObject classes are emitted as `class`, **not**
`final class`, and their `<ClassName>Props` companions are public and
extendable. That is what lets user code write
`class MyButton extends GtkButton`, narrow a return type
covariantly, and subclass the props companion. The contract is
pinned by the *Dart-level subclassing contract* group in
`generator/test/emitter_test.dart` — do not reintroduce `final class`
or a private props companion. The ownership and lifetime rules are in
[docs/subclassing.md](docs/subclassing.md), and the verified statement
that this contract is committed on `main` — not pending on the
`composite-templates` branch — is in
[docs/branch-state.md](docs/branch-state.md).

## The native library loader

Every generated package opens its native library through
`package:gir_ffi`'s `openLibrary`, and the **names it tries are
generator data**: `generator/lib/src/resolve/platform_libraries.dart`
holds one row per native library — the Windows file name, the macOS file
name and the distribution packages that ship it.

**Rule: the names are tabulated, not derived.** The GIR carries only
the Linux soname (`libgtk-4.so.1`), and the other platforms' names do
not follow from it — GTK 4 on Windows is `libgtk-4.dll`, with no
version suffix. A library that is not in the table degrades to a
mechanically derived name (`libfoo-1.0.so.0` → `libfoo-1.0-0.dll`) plus
a `platform-library` line in the package's `skip_report.txt`; it never
fails the generation. Add the row instead of deriving.

**Rule: a missing library is an error, not a fallback.** The loader
opens every name of the current platform it can; when none of them
opens it throws `NativeLibraryNotFound`, which names the library, the
package, every name that was tried and the command that installs it.
Do not reintroduce the silent `DynamicLibrary.process()` fallback for
the *library* open — it turned a missing library into a misleading
*"None of the loaded modules contained the requested symbol"* much
later. The *symbol* lookup keeps its process fallback: a symbol may
live in another library.

`packages/gir_ffi` owns the mechanism (`openLibrary`,
`InstallPackages`, `NativeLibraryNotFound`); the generator owns the
data. The rules are in
[docs/emission.md](docs/emission.md#the-native-library-loader) and
pinned by the *the native library loader* group in
`generator/test/emitter_test.dart` plus `packages/gir_ffi/test/loader_test.dart`.

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
- **OUT parameters**: one OUT parameter becomes the wrapper's return value, several become a Dart record `(T1, T2)`, and a return value plus OUTs become `(ret, T1, T2)`. A **callee-allocated byte buffer** (`char**` / `guchar**` with a sibling length parameter) becomes a `Uint8List` — the bytes are copied out of the native buffer and the buffer is released with `g_free`; its byte count is absorbed into the list and is not a separate element. A nullable OUT string stays nullable (`String?`) — GLib leaves the slot `NULL` when there is nothing to report, and the old `!` turned that into a `TypeError`. See [docs/emission.md](docs/emission.md#out-parameters)
- **IN byte arrays**: a caller-provided buffer (`<array length="N">` of `guint8`/`guchar`, `direction="in"`) becomes a `Uint8List` — the list is mirrored into a `g_malloc`ed buffer for the call (`withNativeBytes`) and the byte count is absorbed from the Dart signature. `transfer-ownership="full"` hands the buffer to the callee, which frees it with `g_free`. The shape is excluded when the callable has a `GDestroyNotify` sibling (the callee keeps the buffer past the call) or when it is **async** (GIO keeps the buffer until the callback fires — use the `GBytes` variant there). See [docs/emission.md](docs/emission.md#callableemitter--generatorlibsrcemitcallabledart)

## Testing instructions

- **All tests, one command** (from the workspace root):
  `dart test generator example/gtk4_examples example/notepad example/todo packages/gir_dart_gobject packages/gir_gdk4 packages/gir_gio packages/gir_ffi packages/gir_glib packages/gir_gobject packages/gir_graphene packages/gir_gtk4 packages/gir_gtk_source5 packages/gir_gtk_templates packages/gir_gtk_templates_builder test`
  — 622 passed, 1 skipped. The skip is a generator test that needs a resolved `ParamSpec` type; the native GTK suites skip themselves when the machine has no display (see below).
- **Why the explicit list?** `dart test` with no argument runs only the *root* package's own `test/` directory, which now holds the site generator's suite. The generator tests, the template-package tests and the per-package smoke tests live in their own packages' `test/` directories, so they have to be named. `dart pub workspace run` does not exist in this Dart SDK — `dart pub workspace` only offers `list`.
- **Per package:** `cd <package> && dart test` works for any workspace member.
- **Generator tests** live in `generator/test/` and also run as part of the all-tests command.
- **Generated packages** carry a smoke test (e.g. `packages/gir_glib/test/glib_smoke_test.dart`) — run per-package with `cd packages/<lib> && dart test`
- **Generated code must type-check.** `packages/gir_gtk_templates_builder/test/generated_code_test.dart` resolves the generated part file with the real analyzer and asserts zero diagnostics; `builder_output_test.dart` does the same for the `build_runner` output. A parse-only check is not enough.
- **The committed site must match its sources.** `test/site/site_output_test.dart` renders every page from `site_src/` in memory and compares the result with the committed `site/`, and it walks the generated HTML checking that every internal link resolves and every rail anchor exists. Run it after any change under `site_src/` — or just run `dart run tool/build_site.dart` and commit the result.
- **The native suites run serially.** `dart test` runs the test *files*
  in parallel, and each file is its own isolate — but the isolates share
  one process, and therefore one GLib, one GTK and one heap. Two suites
  that initialise GTK at the same time (`packages/gir_gtk4` and
  `example/notepad` both call `gtk_init()` in their `setUpAll`) race
  inside GTK's initialisation, and the process aborts with a heap
  corruption ("free(): invalid size"). It is timing-dependent: it needs
  the two initialisations to overlap, so it shows up on a loaded machine
  and not on a quiet one. **Run the native suites with
  `--concurrency=1`** — that is what CI does.
- **Native GTK tests skip themselves without a display.** `example/todo/test/todo_widget_test.dart` builds the real window and asserts that the template is on screen. GTK needs a display, so the suite skips when there is none. Run it locally with `xvfb-run -a dart test example/todo` — CI does the same in the `native` job. Its teardown disconnects the Dart signal handlers and then **destroys the window while the isolate is alive** — three rules make that safe, and all three are properties of the bindings' object lifecycle, not of the template stack:
  - A `GObject` finalized *while the isolate shuts down* destroys its signal handlers, and the destroy-notify GObject call is a Dart callback — the VM refuses to run a callback while it is shutting down and aborts. So the handlers are disconnected *before* the window goes away.
  - `gtk_window_destroy` frees the window, so the wrapper's finalizer must not release it a second time: `gobjectFinalizer.detach(window)` comes first. The VM runs the native finalizers of *every* attached object at shutdown, in an order that is not the reachability order — so GTK's selection models, which dispose the model they wrap, must not find the model already released. The suite detaches the store's and the selection's finalizers for that reason.
  - A window that is only freed at shutdown stays in GTK's global toplevel list, and GTK walks that list on every main-loop iteration. The gio suite drives the default main context in parallel, so a window left behind would be walked after it was gone. Destroying the window during the teardown — and taking it out of the application's window list with `setApplication(null)` — keeps it off that list.

  See [docs/dart-gobjects.md](docs/dart-gobjects.md#lifecycle-notes).
- Skip report: when the generator emits fewer bindings, `packages/<lib>/skip_report.txt` lists them by category (`callable`, `class`, `record`, etc.). Use it to triage missing functionality
- All tests must pass and `dart analyze` must be clean for the whole workspace before opening a PR

## PR & commit conventions

- The workspace is a git repository. `main` is the trunk; `array-types`, `notepad` and `props` are already merged and their local branches are deleted — do not recreate them. `gasync` is superseded — do not build on it. `composite-templates` held an unmerged prototype and has been **retired**: it was never to be merged, and both the composite-template stack and the Dart-level subclassing contract are on `main` (see [The composite-template stack](#the-composite-template-stack) and [Generated classes are extendable](#generated-classes-are-extendable)); the verified record is [docs/branch-state.md](docs/branch-state.md). Its Blueprint/GResource support, Meson/gettext packaging and program-lifetime `NativeCallable` trampoline are out of scope.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:` — generator changes get a `feat(generator):` or `fix(generator):` prefix; regenerated packages go under `chore(gen):` or `feat(gen <lib>):`
- One PR per logical change. Generator changes must include the regenerated `packages/<lib>/` output and the matching `skip_report.txt` updates in the same PR — reviewers must see the effect on a generated package
- CI is checked in at `.github/workflows/ci.yml`: two jobs. The `build` job analyzes, runs the generator tests, the template packages' pure-Dart tests and a build + analyze gate over `example/todo`. The `native` job installs GTK 4, libadwaita and GtkSourceView and runs the **native** suites — the ownership rules, the byte-array rules and the template stack — against the real libraries under `xvfb-run`. Both jobs are pinned to `ubuntu-26.04`: `ubuntu-latest` moves between Ubuntu 24.04 and 26.04 during the 2026 migration, and the native job's result depends on the GTK version. When you add a CI step, add it to that workflow in the same PR. The `build` job also runs the publishability gate — `dart run tool/release.dart check` — which is the structural check pub.dev would run, plus the real `dart pub publish --dry-run` for the packages whose dependencies are already on pub.dev
- The release workflow is `.github/workflows/release.yml`: `workflow_dispatch`, the pub.dev token from the repository secrets (`PUB_HOSTED_URL`, `PUB_TOKEN`), running `tool/release.dart publish` and then tagging the version. The policy it implements is [docs/release.md](docs/release.md)
- **Callback typedefs** follow the GIR `c:type` (e.g. `GCompareDataFunc`). User-supplied callbacks must be **top-level or static Dart functions** with parameter and return types matching the typedef's signature; closures and instance methods are accepted at runtime only through the wrapping `NativeCallable.isolateLocal` that the generator emits at every call site. The wrapper allocates the NativeCallable before the call and `.close()`-s it in a `finally` block — long-lived callbacks must therefore be passed as top-level functions so the temporary `NativeCallable` doesn't outlive the wrapper

## Security

- `.gitignore` excludes `.dart_tool/` and `pubspec.lock` — keep secrets out of the repo and never commit `~/.pub-cache` content
- Generated bindings call into native libraries (`libglib-2.0`, `libgtk-4`, …) via `dart:ffi`. Treat pointer lifetimes and ownership transfers (especially `transfer-full` vs `transfer-none` in GIR) as security-relevant — leaks and use-after-free are bugs, not style issues
- The packages are published from the copies `tool/release.dart` writes outside the repository; the working tree stays a workspace with path dependencies and `publish_to: none`. A version bump is only ever made by the release tool — the root pubspec's `version:` is the single source of truth for the whole set. The upload itself is the owner's action: it needs a pub.dev account and an API token, and it is never performed by an agent
