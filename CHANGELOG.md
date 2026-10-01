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
- **`HeapAnchor` in `package:gir_ffi`** — a `Finalizable` backed by a
  `NativeFinalizer(malloc.nativeFree)`. Used by the generator's
  caller-allocated record OUT path to keep the buffer alive as long
  as the returned wrapper is reachable, and free it on GC. The static
  `_finalizer` is shared across all anchors; `HeapAnchor.allocate(N)`
  is the only public constructor (allocates a `calloc<Uint8>(N)`
  zero-initialized buffer). See
  [`packages/gir_ffi/test/heap_anchor_test.dart`](./packages/gir_ffi/test/heap_anchor_test.dart)
  (6 tests) for the lifetime contract.
- **GLib root-level namespace functions are now surfaced**:
  `g_get_user_data_dir`, `g_get_user_cache_dir`, `g_get_user_config_dir`,
  `g_get_user_name`, `g_get_real_name`, `g_get_home_dir`,
  `g_idle_add_full`, `g_timeout_add_full`, `g_timeout_add_seconds_full`,
  `g_io_add_watch_full`, `g_child_watch_add_full`, `g_source_set_callback`,
  `g_source_set_funcs`, and similar `_full`-suffixed siblings of the
  non-introspectable convenience macros are now real Dart wrappers. Their
  non-`_full` convenience macros (`g_idle_add`, `g_timeout_add`,
  `g_io_add_watch`, `g_child_watch_add`, `g_log_set_handler`, …) are
  recorded in `skip_report.txt` with reason
  `introspectable=0 (C macro; use <sibling>)`, naming the canonical
  wrapper the user should call. See
  [skip-categories.md](./docs/skip-categories.md#introspectable0--introspectable0-c-macro-use-sibling).
- **Nullable callback parameters** (`nullable="1" allow-none="1"` on a
  `<parameter>` whose `<type>` is a `<callback>`) are now emitted. The
  wrapper parameter becomes nullable (`FuncType?`) and the
  `NativeCallable` allocation, call-site argument, and
  `finally`-block close are all conditional on the user supplying a
  function. Without this change, 17 GLib skip entries
  (`g_idle_add_full`, `g_timeout_add_full`, `g_io_add_watch_full`,
  `g_child_watch_add_full`, `g_source_set_callback`,
  `g_source_set_funcs`, …) were unbindable. The lifetime model is only
  safe for callbacks invoked **synchronously** inside the call; see
  [emission.md](./docs/emission.md#callback-parameters) for the full
  pattern and the caveat about long-lived callbacks (idle sources,
  timeout sources, signal handlers).
- **`docs/`** with design references: [architecture](./docs/architecture.md),
  [emission](./docs/emission.md), [type-system](./docs/type-system.md),
  [signals](./docs/signals.md), [skip-categories](./docs/skip-categories.md).
- **Runtime tests** for the typed-signal pipeline:
  [`packages/gobject/test/signal_helpers_test.dart`](./packages/gobject/test/signal_helpers_test.dart)
  (3 trampoline tests: connect/emit/disconnect, closure capture, parallel
  connections) and
  [`packages/gobject/test/typed_signal_test.dart`](./packages/gobject/test/typed_signal_test.dart)
  (smoke test verifying the public `connectSignal` is reachable).
- **Runtime tests for namespace functions and nullable callbacks**:
  [`packages/glib/test/namespace_functions_smoke_test.dart`](./packages/glib/test/namespace_functions_smoke_test.dart)
  exercises `g_get_user_data_dir`, `g_get_user_name`, `g_get_real_name`
  at runtime and verifies that the `idleAddFull` / `timeoutAddFull`
  wrappers accept a top-level Dart callback plus nullable
  `data` / `notify` parameters.
- **`*Callback` convenience overload for async methods** (`openCallback`,
  `queryInfoAsyncCallback`, …). The base wrapper allocates a
  `NativeCallable` and closes it in `finally` — unsafe for async
  callbacks because GLib holds the pointer past the call. The new
  overload routes the dispatch through a permanent
  `Pointer.fromFunction` over a static trampoline + per-call registry,
  so no `NativeCallable` is ever closed. The user's callback signature
  is typed (`void Function(GObject?, GAsyncResult)` for
  `GAsyncReadyCallback`); `user_data` is hidden (always `null`
  internally). See [docs/async.md](./docs/async.md).
- **GIR `glib:finish-func`, `scope`, `closure` attributes** are now
  parsed into `GirMethod.finishFunc`, `GirParameter.scope`, and
  `GirParameter.closureIndex`. The parser test that previously failed
  (it referenced these fields) is now green.
- **Caller-allocated OUT parameters are now emitted as typed
  wrappers.** Methods like `gtk_text_buffer_get_start_iter` (which
  take a `GtkTextIter*` OUT parameter that the caller fills in) used
  to be skipped with `caller-allocates out parameter iter`. The
  generator now allocates the buffer internally, passes its pointer
  to the native function, and reads back via the type's `fromPointer`
  factory. Primitive OUT params (`gint*`, `guint32*`, `gboolean*`)
  free the buffer in `finally`; record/class OUT params use a
  `HeapAnchor` (in `package:gir_ffi`) with a `NativeFinalizer` so the
  buffer's lifetime is tied to the returned wrapper's reachability.
  The wrapper returns the typed Dart value (`GtkTextIter
  getStartIter()`) directly. Skipped count across the workspace
  dropped from 1793 to 1511 (~282 fewer skips) without regressions.

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
- **Parser keeps namespace-level `<function>` elements with
  `introspectable="0"`** so `CallableEmitter.emit` can emit a precise
  skip entry. Previously the parser silently dropped them at the
  outer guard, leaving the macros with no trace in `skip_report.txt`.
  Classes, records, and other top-level elements with
  `introspectable="0"` are still dropped at the parser level — only
  `<function>` gets the keep-and-skip treatment.
- **Interface methods are mirrored onto implementing classes.**
  `GtkButton`, `GtkSwitch`, `GtkCheckButton`, `GtkLinkButton`,
  `GtkToggleButton`, `GtkScaleButton`, `GtkListBoxRow`, `AdwActionRow`,
  `GIOModule`, and every other class with `<implements name="..."/>`
  in GIR now exposes the interface's `<method>` instances as its own
  — same native symbol, same `this.handle` self-arg, same wrapper
  pattern. Write `button.setActionName('win.open')` directly instead
  of wrapping in `GtkActionable(button.handle)`. The interface itself
  is still emitted as a concrete `final class GtkXxx` so wrapping
  opaque pointers keeps working. Override-incompatible shadows (e.g.
  `GIOModule.use` shadowing `GTypeModule.use` with a different
  signature) are detected against the parent's combined method map
  (own methods + ancestor interface methods) and renamed to
  `<name><ClassName>` (`useIOModule`). Async interface methods
  (`scope="async"` or `finishFunc`) get the same lifetime-safe
  `*Callback` overload the class's own async methods use. Cross-package
  mirrors add the foreign package to `ctx.imports` only when an emitted
  method body references a wrapper type from that package — primitive
  mirrors don't import. See [emission.md](./docs/emission.md#interface-mirroring)
  for the full rule set.

### Fixed
- **Use-after-free in caller-allocated record OUT params.** The
  initial implementation allocated `malloc<Pointer<ffi.Void>>()` (8
  bytes for one pointer) for the buffer and freed it in `finally`,
  causing two bugs: (a) `free(): invalid next size` because GTK wrote
  the full 32-byte `GtkTextIter` into 8 bytes of heap; (b) a SEGV
  inside `gtk_text_iter_get_buffer` because the wrapper freed the
  backing buffer before the iter's handle was dereferenced by the
  next call (e.g. `textBuffer.getText(getStartIter(), getEndIter(),
  false)` in `EditorApp.saveFile`). The fix uses
  `HeapAnchor.allocate(256)` from `package:gir_ffi`, a
  `Finalizable` whose `NativeFinalizer` calls `malloc.nativeFree`
  when the anchor is GC'd. The wrapper holds the anchor via
  `T.fromPointer(_buffer)` (`_buffer` is the anchor's `Pointer<Uint8>`
  field, which the returned wrapper captures as its `handle`); drop
  the wrapper and GC frees the buffer. End-to-end covered by
  [`packages/gtk4/test/gtk4_text_iter_test.dart`](./packages/gtk4/test/gtk4_text_iter_test.dart)
  and [`example/test/editor_savefile_test.dart`](./example/test/editor_savefile_test.dart).
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
