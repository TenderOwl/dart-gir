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
* **Interface-mirrored methods** are appended last — see
  [Interface mirroring](#interface-mirroring) below for the full rule
  set, the rename-on-conflict logic, and the cross-package import
  heuristic.

The set of reserved class member names: `handle`, `owned`, `fromPointer`,
plus the package's Dart class name. Any GIR member whose lowerCamel
collides gets a `name collision` skip.

### Interface mirroring

GIR's `<class>` may declare `<implements name="..."/>` — concrete
classes advertise that they satisfy a GObject interface's contract.
The interface itself is emitted as `final class GtkActionable { ... }`
by [`RecordEmitter`](#recorder-emitter) (see above), so users with an
opaque pointer can still wrap it and call actionable methods directly.
For ergonomic use on the concrete widget, the class emitter mirrors
every `<method>` declared on each implemented interface onto the
class as if it were its own. Result: `button.setActionName('win.open')`
compiles and dispatches to `gtk_actionable_set_action_name` with
`this.handle` — no `GtkActionable(button.handle)` wrapper required.

```dart
// GtkButton extends GtkWidget, implements Gtk.Actionable.
class GtkButton extends GtkWidget {
  // ... <constructor>, <method>, <function>, signals ...

  // Mirrored from GtkActionable.get_action_name:
  static final _gtkActionableGetActionName = gtk4Lookup<…>(
    'gtk_actionable_get_action_name',
  ).asFunction<ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>)>();
  String? getActionName() {
    return stringFromNative(
      (_gtkActionableGetActionName(this.handle)).cast(),
      free: false,
    );
  }

  // Mirrored from GtkActionable.set_action_name:
  void setActionName([String? actionName]) {
    withNativeString(actionName, (nativeActionName) {
      _gtkActionableSetActionName(this.handle, nativeActionName.cast<Utf8>());
    });
  }
}
```

**Resolution rules** (failure → recorded skip, mirror dropped):

* Interface name in `implements_` doesn't resolve → `interface <name> not found`.
* Interface lives in a non-emitted package → `interface <name> is in non-generated package <pkg>`.
* Method name collides with a class member or another mirrored method → `name collision`.

**Override-incompatible rename** (mirrored method has a different
signature than a parent's same-named method). The mirror's signature
key is compared against:

1. The parent chain's combined method map
   (`_inheritedSigs`), which walks each ancestor and adds its own
   methods first (they shadow interface methods with the same name in
   Dart's resolution rules) and then the methods mirrored onto each
   ancestor's interfaces. This catches cases like:
   * `GtkCellAreaBox.packEnd(4 args)` shadows
     `GtkCellArea.packEnd(2 args)` (the parent absorbed `packEnd` from
     `GtkCellLayout`).
   * `GIOModule.use()` (the `GObject.TypePlugin` interface method,
     `void use()`) shadows `GTypeModule.use()` (the parent's own
     `bool use()`).

   When the signatures differ, the mirror is renamed to `<name><ClassName>`
   (`packEndCellAreaBox`, `useIOModule`) and recorded with
   `override-incompatible with ancestor; renamed to <name>`. The
   parent's method is preserved; the renamed mirror is a distinct
   method that the user can call explicitly when they want the
   interface behavior.

2. The interface's own expected signature
   (`_interfaceMethodSigs`). A class method that diverges from its
   declared interface is renamed so it doesn't claim to satisfy the
   contract. With Phase 1's concrete `final class` interface
   emission, this rename is purely defensive; Phase 2 will promote
   the interface to `abstract class` and the rename will keep the
   Dart analyzer happy.

**Async interface methods** mirror the same logic the class's own
methods use: a method with `scope="async"` parameter or `finishFunc`
emits a lifetime-safe `*Callback` overload alongside the base
wrapper (`button.initAsyncCallback(...)`).

**Cross-package mirrors**. When the interface is in another emitted
package (e.g. `PangoFontFamily implements Gio.ListModel`), the
emitter scans each mirrored method's parameter and return types via
the resolver. If a type's `requiredImport` is the interface's own
package — meaning the emitted Dart code references a wrapper class
that lives in that package (e.g. `GtkWidget` from `gtk4`) — the
import is added to the package barrel. If the only types referenced
are primitives, `Pointer<Void>`, or types from other already-imported
packages (e.g. `GObject` from `gobject`), the import is suppressed
to avoid `unused_import` warnings.

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

### Caller-allocated OUT parameters (HeapAnchor)

GIR `direction="out"` parameters with `caller-allocates="1"` are emitted
in two flavors depending on the pointee type:

**Primitive OUT** (`gint*`, `guint32*`, `gboolean*`, …). The size is
known at compile time, so the wrapper allocates one slot of the pointee
with `malloc<T>()` and frees it in `finally`:

```dart
gint value() {
  final _out0 = malloc<ffi.Int32>();
  try {
    _someFunction(_out0);
    return _out0.value;
  } finally {
    malloc.free(_out0);
  }
}
```

**Record / class / union / interface OUT** (`GtkTextIter*`, `GValue*`,
…). GLib writes the *entire struct* (not a pointer to it) into the
caller-provided buffer, but the generator has no static `sizeof(T)` to
allocate the right amount. The previous implementation under-allocated
(8 bytes for a 32-byte struct), causing heap corruption, and then freed
the buffer in `finally` — invalidating the returned wrapper's handle
and crashing on the next C deref.

The fix uses a `HeapAnchor` from `package:gir_ffi`:

```dart
GtkTextIter getStartIter() {
  final _out0Anchor = HeapAnchor.allocate(256);
  final _out0 = _out0Anchor.buffer;
  try {
    _gtkTextBufferGetStartIter(this.handle, _out0.cast<ffi.Void>());
    return GtkTextIter.fromPointer(_out0.cast<ffi.Void>());
  } finally {
    // No `malloc.free(_out0)` here: the NativeFinalizer attached in
    // HeapAnchor.allocate() frees the buffer when the anchor becomes
    // unreachable.
  }
}
```

The anchor's `Finalizable` + `NativeFinalizer` keeps the buffer alive
as long as the returned wrapper is reachable (`GtkTextIter.handle`
holds the `Pointer<Uint8>`). Drop the wrapper, GC reclaims the anchor,
the finalizer calls `malloc.nativeFree`. `usesGirFfi` is set so the
package barrel adds `import 'package:gir_ffi/gir_ffi.dart';`
automatically.

The 256-byte size is a deliberate blanket upper bound — it covers
every struct currently in the GIR corpus (largest is `PangoLayoutRun`
at ~176 bytes) and keeps allocation O(1) per call. Per-type sizing
(using a future GIR `sizeof` annotation or a build-time probe) is a
known follow-up.

Caveat documented for users: GTK functions that *copy* an OUT struct
into GTK-owned memory (e.g. `gtk_text_iter_copy`) keep using the
caller's pointer for the copy; the anchor protects only the buffer we
handed to GLib. If a returned wrapper's lifetime exceeds the buffer's
(rare, but possible if GTK holds the pointer past the Dart GC), the
finalizer will free it and the next access from native code will SEGV.
Use `Pointer<...>` directly when you need full control.

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

## AsyncCallbackEmitter — `generator/lib/src/emit/async_emitter.dart`

Emits the lifetime-safe `*Callback` convenience overload alongside
every async method (a method whose callback parameter carries
`scope="async"` AND whose callback type is `GAsyncReadyCallback`).

The base wrapper (emitted by `CallableEmitter`) is unsafe for
async callbacks because it closes its wrapping `NativeCallable` in
`finally` — leaving a dangling C function pointer when GLib later
dispatches the callback from the main loop. The `*Callback` overload
replaces the `NativeCallable` with a permanent `Pointer.fromFunction`
over a static trampoline + a per-call registry:

```dart
// Generated alongside `void open(...)`:
void openCallback(
  GtkWindow? parent,
  GCancellable? cancellable,
  void Function(GObject? sourceObject, GAsyncResult result) topLevel,
);

static final _openCallbackRegistry =
    <int, void Function(GObject?, GAsyncResult)>{};
static int _openCallbackSeq = 0;
static final _openCallbackPtr = ffi.Pointer.fromFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>)>(_openCallbackTrampoline);

static void _openCallbackTrampoline(
  ffi.Pointer<ffi.Void> sourceObject,
  ffi.Pointer<ffi.Void> res,
  ffi.Pointer<ffi.Void> data,
) {
  final id = data.cast<ffi.IntPtr>().value;
  final fn = _openCallbackRegistry.remove(id);
  malloc.free(data);
  if (fn == null) return;
  fn(
    sourceObject == ffi.nullptr
        ? null
        : GObject.fromPointer(sourceObject.cast()),
    GAsyncResult.fromPointer(res.cast()),
  );
}
```

`Pointer.fromFunction` is permanent (lifetime = program), the
trampoline is a static method so `Pointer.fromFunction` accepts it,
and the per-call `id` (carried in the malloc'd `data` pointer) routes
the dispatch back to the user's typed callback. No `NativeCallable`
to close, no dangling pointer risk.

The convenience overload:

* **hides `user_data`** — always passes `ffi.nullptr` internally.
  Dart closures already capture state.
* **types the callback** — `void Function(GObject?, GAsyncResult)`
  for `GAsyncReadyCallback`. Other async callbacks fall back to the
  FFI-compatible shape with `Pointer<Void>` parameters.

Methods with multiple `scope="async"` callback parameters (e.g.
`g_file_copy_async` with its progress callback) target the
`GAsyncReadyCallback` specifically; the other async callbacks keep
their existing emission.

See [async.md](./async.md) for the user-facing guide and
[signals.md](./signals.md) for the related signal-helper pattern.

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
