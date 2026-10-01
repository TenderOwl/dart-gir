# Emission reference

How each emitter turns a part of the GIR model into Dart source. Every
emitter returns either a string of code (concatenated into the relevant
part-file) or `null` when the symbol is skipped (with the reason recorded
in `GenerationReport`).

## EnumEmitter — `generator/lib/src/emit/enum_emitter.dart`

Emits `<enumeration>` and `<bitfield>`.

* GIR `<enumeration>` → Dart `enum` with `fromValue(int)` and a `value`
  getter. Members are renamed via `enumValueName` — strips the enum
  type's C prefix (`GTK_ALIGN_FILL` → `fill`).
* GIR `<bitfield>` → Dart class with `static const` values, `|`, `&`,
  `^`, `~`, and a `(BitfieldClass)(int)` constructor. Not a Dart `enum`
  because bitfield members combine.

Both are emitted as plain Dart declarations, so each package gets
`lib/src/enums_0.dart`, `lib/src/enums_1.dart`, … chunked at ~400 lines
per file.

## FunctionEmitter — `generator/lib/src/emit/function_emitter.dart`

Emits `<constant>` and `<function>`.

* `<constant>` → `const <dartType> <name> = <value>;` where `value` is a
  Dart literal (string → `'foo'`, integer → `42`, boolean → `true/false`).
* `<function>` → delegates to `CallableEmitter.emit` with `staticMember:
  false` and `classMember: false`. The wrapper carries a private native
  binding plus the public Dart signature.

## RecordEmitter — `generator/lib/src/emit/record_emitter.dart`

Emits `<record>`, `<union>`, and `<interface>`.

Each becomes an **opaque handle class**:

```dart
final class GFileInfo {
  GFileInfo.fromPointer(this.handle);
  final ffi.Pointer<ffi.Void> handle;
  // …constructors, methods, static functions, signals
}
```

Records have no fields; the GIR corpus has no vtable support yet, so
interfaces (e.g. `Gio.DBusObjectManager`) are emitted the same way rather
than as Dart `implements`. Methods on the record go through
`CallableEmitter` with `selfArgExpr: 'this.handle'`.

## ClassEmitter — `generator/lib/src/emit/class_emitter.dart`

Emits `<class>`.

Output for `final class GtkButton extends GtkWidget implements ffi.Finalizable`:

* A default constructor `GtkButton.fromPointer(super.handle, {super.owned})`
  if there's a parent, or `GtkButton.fromPointer(this.handle, {this.owned
  = false})` with a finalizer attachment otherwise.
* `<constructor>` → `factory GtkButton.new(...)` (named for
  `GirConstructor` whose `cIdentifier` doesn't start with `new_`) or
  `GtkButton(...)` (default `new()` constructor). Wraps the constructor
  result in `_attachFinalizer()` when `sinkFloating` is true (the class
  is in the `InitiallyUnowned` chain).
* `<method>` → `R methodName(...)` with `selfArgExpr: 'this.handle'`.
  Override-incompatible ancestor methods are renamed to disambiguate
  (`activate` on `AdwActionRow` becomes `activateActionRow` when
  `GtkWidget.activate` has a different signature). The skip reason
  `override-incompatible with ancestor; renamed to <name>` is recorded.
* `<function>` → `static R name(...)` with no self-arg.
* **Inherited typed `onSignalName` methods** are appended after methods
  — see [signals.md](./signals.md) for details.

The set of reserved class member names: `handle`, `owned`, `fromPointer`,
plus the package's Dart class name. Any GIR member whose lowerCamel
collides gets a `name collision` skip.

## CallableEmitter — `generator/lib/src/emit/callable.dart`

Used by every emitter that produces a function-shaped wrapper (methods,
constructors, static functions, top-level functions, callback wrappers).

For each call it emits:

1. A private native binding `<int Function(...)> _<name>Native(...)` that
   does the FFI lookup, parameter marshalling, native call, and return
   conversion.
2. A public Dart wrapper `<dartReturn> <name>(...)` that calls the
   private native binding.

### Parameter marshalling

Each `<parameter>` is classified:

| GIR kind | Wrapper type | Native type | Marshalling |
|---|---|---|---|
| primitive (`gint`, `gdouble`, `gboolean`) | `int` / `double` / `bool` | `ffi.Int32` / `ffi.Double` / `ffi.Int32` (gboolean) | Direct |
| string (`utf8`, `gchar*`, `filename`) | `String` / `String?` | `Pointer<Utf8>` | `withNativeString` outer wrap |
| string list | `List<String?>?` | `Pointer<Pointer<Utf8>>` | `withNativeStringList` outer wrap |
| class/record/union/interface | wrapper class | `Pointer<Void>` | `.handle` ↔ `fromPointer(ptr)` |
| enum / bitfield | wrapper class | `Int32` / `Uint32` | `.value` ↔ `Wrapper.fromValue(...)` |
| callback | inline Dart signature (nullable for `nullable="1"`) | `Pointer<NativeFunction>` | `NativeCallable.isolateLocal` wrap + `.close()` in `finally` (conditional on null for nullable callbacks) |
| out / inout | wrapper type | `Pointer<...>` | `calloc<...>` + `.value` extraction |
| array | (not yet supported) | — | Skip with `array types are handled in a later phase` |

The wrapper type for a class/record/union/interface carries the package
name when the declaring namespace differs from the current namespace
(emit context adds the package to `ctx.imports`).

### Callback parameters

User-supplied callbacks are **not** aliased to a typed function pointer at
the call site. Instead, `CallableEmitter.emit` allocates a temporary
`NativeCallable<T>` with the wrapper signature in `T`, captures the
user's Dart callback, and closes the callable in a `finally` block:

```dart
final callable = ffi.NativeCallable<...>.isolateLocal(callback);
try {
  _someFunctionNative(..., callable.nativeFunction);
} finally {
  callable.close();
}
```

The Dart `typedef` for the callback is still emitted (named after the
GIR `c:type`, e.g. `GCompareDataFunc`) so callers can name the type, but
the call site uses the inline signature for `NativeCallable` to work
around `Pointer.fromFunction`'s static-function constraint.

Nullable callback parameters (e.g. `notify` on `g_idle_add_full`) take
the wrapper parameter type with a trailing `?` and become trailing
positional optional parameters in the Dart signature. The
`NativeCallable` allocation is conditional on the user passing a
function, and the call site forwards either `.nativeFunction` or
`ffi.nullptr`. The `finally` block uses `?.close()` so the cleanup is
also conditional:

```dart
final _nc = notify == null
    ? null
    : ffi.NativeCallable<...>.isolateLocal(notify);
try {
  _native(..., _nc?.nativeFunction ?? ffi.nullptr);
} finally {
  _nc?.close();
}
```

This pattern is only safe for callbacks invoked **synchronously** inside
the call — see `g_async_queue_sort` in `packages/glib/test/glib_smoke_test.dart`
for a working example. Long-lived callbacks (idle sources, timeout
sources, signal handlers, …) register a C function pointer that GLib
later invokes from the main loop; the wrapping `NativeCallable` would
already be `.close()`d by then. For those, build a `Pointer` via
`Pointer.fromFunction` with a top-level Dart function whose lifetime
outlives the source, or use `connectSignal` /
`g_signal_connect_data` directly.

### Variadic / skipped

* Varargs (`...`) parameters → skip with `varargs`.
* Moved/shadowed functions → skip with the destination.

## CallbackEmitter — `generator/lib/src/emit/callback_emitter.dart`

Emits `<callback>` declarations as Dart function typedefs:

```dart
typedef GDestroyNotify = void Function(ffi.Pointer<ffi.Void> data);
```

The typedef's name matches the GIR `c:type` so users can refer to the
canonical C identifier. Nullable callback **return** types are still
skipped (none of the GIR files in scope declare one) — see
[skip-categories.md](./skip-categories.md). Nullable callback
**parameters** are accepted and emitted via the conditional pattern
described above.

## SignalHelper — `generator/lib/src/emit/signals_helper.dart`

Emits `lib/src/signals.dart` when at least one kept signal exists.

Per-package contents:

1. **`_gSignalConnectData`** — one-time FFI binding for
   `g_signal_connect_data`. Casts the trampoline pointer to
   `Pointer<NativeFunction<void Function(Pointer<Void>, Pointer<Void>)>>`
   so any bucket signature is assignable at the call site.
2. **`_signalRegistryOwner`** — `Map<int, Map<int, Function>>` mapping each
   live handler id to its bucket's registry. Destroy-notify reads this
   to clean up only the owning bucket.
3. **`_nextSignalId` / `_destroySignalState`** — id allocator + shared
   destroy-notify trampoline.
4. **One bucket per `(FFI shape × Dart type signature)`** — see
   [signals.md](./signals.md) for the partitioning rule. Each bucket
   declares: `_signalRegistry_<id>` (`Map<int, TCallback>`), the trampoline
   `_signalTrampoline_<id>`, the per-bucket `NativeCallable
   _signalCallable_<id>`, and `_connectSignal_<id>(handle, name,
   callback)`.
5. **`connectSignal(handle, name, callback)`** — public escape hatch that
   uses the synthetic `v_0_` bucket for arbitrary signal names (e.g.
   `notify::property-name`).

The barrel's `part 'src/signals.dart';` plus the file-level
`part of '../<pkg>.dart';` makes the singletons reachable from every
class in the same library without an extra import.

## Cross-package imports

Every emitter that resolves a cross-package type calls
`ctx.bridgeFor(...)`, which records the required package via
`ctx.imports.add(...)`. `emitter.dart` then writes a deduplicated
`import 'package:<name>/<name>.dart';` for each entry when emitting the
barrel. `pubspecFor` mirrors this in `pubspec.yaml` as path-deps. The
filter excludes `gir_ffi` (already hard-coded in the barrel + pubspec).
