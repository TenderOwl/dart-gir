# Signal helpers

GObject classes have signals — typed callback hooks that fire when an
event happens. The generator emits typed `onSignalName(<typed
callback>)` methods on every GObject subclass so users can write:

```dart
final app = GApplication(...);
final handlerId = app.onOpen((GFile[] files, String hint) {
  // typed args, no raw FFI
});
```

This document covers what gets emitted, how signals are partitioned into
buckets, and what to do for signals we can't type (use the escape
hatch).

## What gets emitted

For each kept signal `S` on class `C`, `ClassEmitter.emitClass` appends:

```dart
int onS(<TypedCallback> callback) {
  return _connectSignal_<bucketId>(this.handle, 'S', callback);
}
```

The method name is `on` + `toUpperCamel(signal.name)`. The callback type
matches the GIR signature with Dart wrappers:

```dart
void Function(GParamSpec pspec) callback          // GObject.Object::notify
void Function(GFile[] files, String hint)          // Gio.Application::open
bool Function(GtkDirectionType direction)          // Gtk.Widget::keynav-failed
```

For inherited signals, the same method is appended on every descendant
class — `app.onNotify(...)` works on `Gio.Application` because
`GObject.Object::notify` is inherited.

## What counts as "kept"

`signalSkipReason(sig, ctx, relativeTo: ns)` returns null for supported
signals and a precise reason otherwise:

| Reason | Cause |
|---|---|
| `weak-ref is not connectable via g_signal_connect_data` | The signal is `weak-ref`, dispatched through `g_object_weak_ref` |
| `detailed signal names (notify::property-name) are out of scope; use connectSignal` | The signal name contains `::` |
| `arity N exceeds supported max (5)` | More than 5 parameters |
| `unsupported arg type at index N: <T>` | An arg's type isn't on the supported shape list |
| `unsupported return type: <T>` | The return shape isn't `void`/`int`/`uint`/`bool`/`double` |
| `name collision (a member named on<Name> already exists)` | A class member with the same method name already exists |

Supported per-arg shapes: `Pointer<Void>` (any class/record/interface),
`Int32` (enum / `gint*`), `Uint32` (bitfield / `guint*`), `Bool`
(`gboolean`), `Double` (`gdouble`/`gfloat`), `Pointer<Utf8>`
(`transfer-none` string — the trampoline reads + `g_free`s after the
callback returns).

## Bucket partitioning

Signals sharing the same `(FFI shape × Dart callback signature)` share
one per-package trampoline. The bucket id is constructed as:

```
<retCode>_<arity>_<argCodes...>_<dartSuffix>
```

where:

* `retCode` — `v`/`i`/`u`/`b`/`d` for `void`/`int`/`uint`/`bool`/`double`.
* `argCodes` — `o`/`i`/`u`/`b`/`d`/`s` for `Pointer`/`Int32`/`Uint32`/`Bool`/`Double`/`Pointer<Utf8>`.
* `dartSuffix` — lower-cased, alphanumeric-only concatenation of the
  Dart wrapper types of each arg (`gparamspec`, `gfile_gfile`, etc.).
  Two signals with the same FFI shape but different wrapper types
  (e.g. `int32` carrying `GtkTextDirection` vs `int32` carrying
  `GApplicationCommandLine`) MUST live in different buckets because the
  registry is `Map<int, TCallback>` and `TCallback` differs.

Examples:

| Signal | FFI signature | Bucket id |
|---|---|---|
| `notify(GParamSpec)` | `Void Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Pointer<Void>)` | `v_1_o_gparamspec` |
| `open(GFile[], String)` | `Void Function(..., Pointer<Void>, Pointer<Utf8>, ...)` | `v_2_o_s_gfile_string` |
| `window-added(GDBusObject, GDBusInterface)` | `Void Function(..., Pointer<Void>, Pointer<Void>, ...)` | `v_2_o_o_gdbusobject_gdbusinterface` |
| `keynav-failed(GtkDirectionType) → bool` | `Bool Function(..., Int32, ...)` | `b_1_i_gtkdirectiontype` |

Buckets sharing the same id across signals (e.g. `notify` on every
GObject subclass) share one trampoline + one NativeCallable +
registry.

## What's emitted per bucket

```
// 1. Typed registry
final _signalRegistry_<id> = <int, TCallback>{};

// 2. Trampoline — receives the args (already decoded by dart:ffi into
//    their Dart representations) + user_data, looks up the callback,
//    converts args to Dart wrapper types, invokes, frees transfer-none
//    strings.
<RetDart> _signalTrampoline_<id>(
  <dartArgType> <arg>, ..., ffi.Pointer<ffi.Void> userData,
) {
  final id = userData.cast<ffi.IntPtr>().value;
  final cb = _signalRegistry_<id>[id]!;
  cb(<args>); // or: final result = cb(<args>); ...; return result;
  if (... != ffi.nullptr) gFree((... ).cast()); // per string arg
}

// 3. Per-package NativeCallable singleton (process-lifetime).
final _signalCallable_<id> =
    ffi.NativeCallable<<trampolineFfiType>>.isolateLocal(_signalTrampoline_<id>);

// 4. Connect helper used by every onSignalName method.
int _connectSignal_<id>(
  ffi.Pointer<ffi.Void> instance,
  String signalName,
  TCallback callback,
) { ... }

// 5. Synthetic v_0_ bucket for the escape hatch — receives (instance,
//    userData) from g_cclosure_marshal_VOID__VOID and ignores instance.
```

`NativeCallable<T>.isolateLocal` is constructed with T written in
`dart:ffi` native types (`ffi.Void` / `ffi.Int32` / `ffi.Uint32` /
`ffi.Bool` / `ffi.Double`), but the trampoline function itself must be
declared with the **Dart representation** of each type (`void` / `int` /
`int` / `bool` / `double`) — dart:ffi decodes native values into Dart
primitives when invoking the callback, and the compiler rejects a
trampoline declared with the FFI typedefs (e.g. a `ffi.Bool` parameter
is a compile error: the expected Dart type is `bool`). Non-void
trampolines also pass an `exceptionalReturn` fallback (`0` / `false` /
`0.0`) to `isolateLocal`, which dart:ffi requires for non-void return
types. When a bucket has `transfer-none` string args and a non-void
return, the trampoline stores the callback's value in a local, frees
the strings, then returns it — a bare `return cb(...)` would skip the
frees.

The trampoline is wrapped in a `dart:ffi` `NativeCallable`. GLib's
`g_signal_connect_data` accepts the callback pointer as
`Pointer<NativeFunction<void Function(Pointer<Void>, Pointer<Void>)>>`
at the call site (cast on assignment), since at the C ABI level every
callback signature is the same — GLib dispatches via the marshaller
selected for the signal's registered shape (`g_cclosure_marshal_*`).

## Ownership of `transfer-none` strings

Strings in signal callbacks are passed with `transfer-ownership="none"`
— the receiver owns the buffer. The trampoline reads the string, then
calls `g_free` (resolved via `DynamicLibrary.process()` in
`packages/gir_ffi`) **after** the user's callback returns. This frees
the buffer whether or not the user kept a reference to it. For
non-nullable strings the trampoline reads `''` if the C side passed
`NULL` (defensive — non-nullable args shouldn't be `NULL` in practice
but the underlying GValue can be); for nullable strings the marshal
expression produces `null`.

## Destroy-notify + per-bucket cleanup

The shared destroy-notify trampoline reads the handler id from the
allocated `IntPtr` and removes the entry from whichever bucket owns it:

```dart
final _signalRegistryOwner = <int, Map<int, Function>>{};

void _destroySignalState(ffi.Pointer<ffi.Void> data, ffi.Pointer<ffi.Void> _) {
  final id = data.cast<ffi.IntPtr>().value;
  calloc.free(data);
  _signalRegistryOwner.remove(id)?.remove(id);
}
```

When a connection disconnects or the instance is finalized, GLib
invokes this trampoline with the same `IntPtr` we allocated. The
bucket map is removed (no leaks) and the Dart callback becomes
unreachable.

## Public escape hatch: `connectSignal`

For signal names the generator can't type (detailed signal names like
`notify::property-name`, signals not in the GIR corpus, or arities
beyond the typed helper range), use the public `connectSignal`:

```dart
int connectSignal(
  ffi.Pointer<ffi.Void> instance,
  String signalName,
  void Function() callback,
);
```

This routes through the synthetic `v_0_` bucket — same trampoline +
registry as the typed `void(void)` helpers. Two connections on the same
signal coexist via the per-id registry slot; disconnect via
`g_signal_handler_disconnect` and the destroy-notify clears the slot.

The runtime tests under
[`packages/gobject/test/signal_helpers_test.dart`](../packages/gobject/test/signal_helpers_test.dart)
exercise the trampoline path end-to-end: register a custom
`void(void)` signal via `g_signal_new`, connect with `connectSignal`,
emit, disconnect, verify the registry slot was cleared.

## Inheritance walk

For a class `C` with parent `P`, `inheritedSignals(C, ctx)` walks
`C → P → ...` keyed by `'${ns.name}.${cls.name}'` (qualified name — the
bug it fixed was that `Adw.Application` and `Gtk.Application` both
have local name `Application`, which used to halt the walk after the
first match). For each ancestor class, every signal is yielded with
the originating namespace attached. `buildSignalBuckets` then resolves
each inherited signal's arg types against that namespace via the
`relativeTo` parameter of `bridgeFor`, so `Gtk.Application::window-added`
resolves its `Window` arg to `GtkWindow` (not `AdwWindow`).

The signal dedup key is the `GirSignal` **instance**, not the name —
two distinct `interface-added` signals on `Gio.DBusObject` (1 arg) and
`Gio.DBusObjectManager` (2 args) live in different buckets.

## Inherited typed helpers on interfaces

`RecordEmitter.emitInterface` doesn't walk a parent chain (interfaces
have no `parent` field in the model), so inherited helpers don't apply.
If a class implements an interface, the class's own `inheritedSignals`
walk is what surfaces the interface's signals.

## Limitations

* Arity > 5 → use `connectSignal` (or open a generator issue with the
  GIR excerpt).
* Detailed signal names (`notify::property-name`) → use `connectSignal`
  with the full string.
* Return types outside the supported set → use `connectSignal` with a
  `void Function()` callback and read the result via your own
  query method after the signal fires.
* `weak-ref` → use `g_object_weak_ref` directly through `gobjectLookup`.
