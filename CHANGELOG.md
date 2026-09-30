# Changelog

Reverse-chronological record of user-facing changes to the workspace.
Per-package versions stay pinned to the workspace version — `publish_to:
none` keeps everything in lockstep.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
with `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`
sections. Dates are ISO-8601 (YYYY-MM-DD).

## Unreleased

### Added
- **Typed signal helpers** (`onSignalName(<typed callback>)`) on every
  GObject subclass with a supported signal. Examples:
  - `app.onOpen((GFile[] files, String hint) { ... })`
  - `widget.onDirectionChanged((GtkTextDirection previous) { ... })`
  - `anyObject.onNotify((GParamSpec pspec) { ... })`
  Inherited signals are surfaced on every descendant class — e.g.
  `Gio.Application.onNotify(...)`, `AdwApplication.onWindowAdded(...)`.
  See [signals.md](./docs/signals.md).
- **Public `connectSignal` escape hatch** in every package's
  `lib/src/signals.dart` for signal names that don't have a typed
  helper (detailed names like `notify::property-name`, signatures the
  generator can't type). Uses the same trampoline path as the typed
  helpers.
- **`g_free` binding in `package:gir_ffi`** via
  `DynamicLibrary.process().lookup('g_free')` for transferring
  ownership of `transfer-none` strings out of the trampoline.
- **`docs/`** with design references: [architecture](./docs/architecture.md),
  [emission](./docs/emission.md), [type-system](./docs/type-system.md),
  [signals](./docs/signals.md), [skip-categories](./docs/skip-categories.md).
- **Runtime tests** for the typed-signal pipeline:
  [`packages/gobject/test/signal_helpers_test.dart`](./packages/gobject/test/signal_helpers_test.dart)
  (3 trampoline tests: connect/emit/disconnect, closure capture, parallel
  connections) and
  [`packages/gobject/test/typed_signal_test.dart`](./packages/gobject/test/typed_signal_test.dart)
  (smoke test verifying the public `connectSignal` is reachable).

### Changed
- **`ClassEmitter` walks the parent chain** to emit inherited typed
  `onSignalName` methods on every descendant class. The walk is keyed
  by qualified class name (`'${ns.name}.${cls.name}'`) so `Adw.Application`
  correctly continues to `Gtk.Application` instead of stopping at the
  first match (both have local name `Application`).
- **`EmitContext.bridgeFor` / `resolve`** accept a `relativeTo` namespace
  parameter so inherited-signal arg types resolve against the
  namespace where the signal was authored. `Gtk.Application::window-added`
  now resolves its `Window` arg to `GtkWindow`, not `AdwWindow`.
- **Per-package `signals.dart`** now contains the typed-signal buckets
  (one trampoline + typed registry + connect helper per `FFI shape ×
  Dart type signature` bucket), plus a shared `_destroySignalState` and
  a per-id owner map so destroy-notify cleans up only the owning
  bucket's registry slot.
- **Generator's `signalSkipReason`** returns precise reasons for every
  unsupported signal: weak-ref, detailed names (`notify::x`), arity > 5,
  unsupported arg type, unsupported return type, name collision.
- **`analysis_options.yaml`** for generated packages now suppresses
  FFI analyzer false positives: `non_constant_identifier_names`
  (bucket ids carry the FFI shape), `unrelated_type_equality_checks`
  (raw FFI typedef comparisons), `return_of_invalid_type` (void
  trampoline sentinel), `must_be_a_subtype` (multi-line
  `NativeCallable<T>`), `non_native_function_type_argument_to_pointer`
  (cast of trampoline pointer), `must_be_a_native_function_type`
  (variance across Dart SDK versions).
- **Per-package imports of `gir_ffi`** are now hard-coded in the
  barrel and filtered out of `crossImports` so generated packages no
  longer emit a duplicate `import 'package:gir_ffi/gir_ffi.dart';`.
- **The existing `connectVoidSignal` runtime test was renamed to
  `connectSignal`** to reflect the public API surface; the runtime
  tests are unchanged in spirit (register a custom signal on
  `GObject`, connect via the public API, emit, disconnect).

### Fixed
- **Inheritance walker stop-at-local-name**: `Adw.Application` →
  `Gtk.Application` previously stopped at `Adw.Application` because both
  classes have local name `Application`. Now keyed by qualified name
  (`Gio.Application`, `Adw.Application` are distinct keys).
- **Signal dedup that merged different signals with the same name**:
  `Gio.DBusObject::interface-added` (1 arg) and
  `Gio.DBusObjectManager::interface-added` (2 args) used to be merged
  into one bucket, dropping the manager's typed helper. Dedup is now
  by `GirSignal` instance identity.
- **`signals_emitter.dart` had an internal duplicate function body**
  from a partial refactor that produced an uncompilable generator.
- **`Utf8` is now used unqualified** in the generated `signals.dart`
  (`ffi.Pointer<Utf8>` in trampolines, `Pointer<Utf8>` in the
  `g_signal_connect_data` binding). The barrel imports
  `package:ffi/ffi.dart` which exports `Utf8`; prefixing with `ffi.`
  resolves to `dart:ffi`'s namespace, which has no `Utf8`. The earlier
  prefix triggered `non_type_as_type_argument` lints on every bucket.
- **Bool/int/double returns from trampolines** now cast back to the
  FFI native type (`ffi.Bool`, `ffi.Int32`, `ffi.Uint32`,
  `ffi.Double`). Without the cast, the analyzer rejected the
  trampoline's return with `return_of_invalid_type`; with the cast
  only on the Dart representation (`bool`/`int`/`double`), the
  runtime rejected it with "NativeCallable cannot be constructed
  dynamically." The fix uses FFI native types in the trampoline
  signature (the `NativeCallable<T>` constraint) and casts the return
  value in the body so the body matches the Dart-primitive callback
  type.
- **Cross-namespace type lookups for callback-typed params** no longer
  accidentally pick up types from the current namespace when the
  signal was authored elsewhere (`GirSignal` carries its originating
  namespace so the resolver searches there first).
- **`(null as dynamic) as ffi.Void`** is the explicit void return
  for trampolines; a bare `return;` is rejected because `ffi.Void`
  is non-nullable, and `return ffi.nullptr` produces a
  `Pointer<Never>` the analyzer refuses to coerce.

## 1.0.0 — 2025-09-28

### Added
- Initial workspace: 11 generated packages (glib, gobject, gio,
  gdk_pixbuf, cairo, pango, gdk4, gtk4, graphene, gsk4, adw) plus
  `gir_ffi` runtime helpers.
- GIR XML loader with transitive include resolution
  (`GirLoader.loadAllWithDependencies`).
- Immutable data model covering `<class>`, `<interface>`, `<record>`,
  `<union>`, `<enumeration>`, `<bitfield>`, `<callback>`, `<function>`,
  `<constant>`, `<alias>`, `<signal>`, `<property>`, `<method>`,
  `<constructor>`, `<parameter>`.
- Type resolver with built-in scalar table, declared-type table, and
  cross-namespace deduplication via `c:type` canonicalisation.
- Per-package emitter pipeline: `EnumEmitter`, `FunctionEmitter`,
  `RecordEmitter`, `ClassEmitter`, `CallbackEmitter`, plus support
  code (`library_emitter.dart`, `context.dart`, `report.dart`).
- `void(void)` signal helpers via per-package `signals.dart` with a
  single trampoline + per-id registry and shared destroy-notify.
- Skip report written to `packages/<lib>/skip_report.txt` for every
  symbol the generator could not emit, with category + reason.
- Generator unit tests (`loader_test`, `parser_test`, `naming_test`,
  `types_test`, `emitter_test`, `signals_emitter_test`,
  `signals_helper_test`).
- Runtime smoke test in `packages/glib/test/glib_smoke_test.dart`
  exercising constant lookup and async-queue callbacks.

### Known limitations
- Variadic functions (`...` parameters) are skipped.
- Non-string-list arrays are skipped ("array types are handled in a
  later phase").
- Nullable scalars (`int?`, `bool?`) as parameters are skipped.
- Detailed signal names (`notify::property-name`) had no escape
  hatch beyond the bare `g_signal_connect_data` lookup.
- Inherited signals on descendant classes were not surfaced — only
  each class's own signals emitted an `onSignalName` method.
- The per-package analysis_options had only `unintended_html_in_doc_comment`
  suppressed; FFI analyzer false positives on bucket identifiers and
  multi-line `NativeCallable<T>` broke regeneration on every run.
- `Utf8` was emitted as `ffi.Utf8` (resolving to `dart:ffi`'s
  namespace, which has no `Utf8`), causing
  `non_type_as_type_argument` errors in every package.
