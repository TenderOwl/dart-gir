# GAsync callbacks

GLib's async pattern is `*_async` + `*_finish`: the async function starts
work and accepts a callback; the finish function retrieves the result
once the work completes. This document describes how to call these
patterns from Dart.

## Two wrapper shapes

Every async method gets **two** generated wrappers:

```dart
// 1. Base wrapper — exposes the default GLib callback pattern.
//    Accepts a `GAsyncReadyCallback?` plus a `userData` Pointer<Void>.
void open(
  GtkWindow? parent,
  GCancellable? cancellable,
  GAsyncReadyCallback? callback,
  ffi.Pointer<ffi.Void> userData,
);

// 2. `*Callback` overload — lifetime-safe by construction.
//    Accepts a typed function (`void Function(GObject?, GAsyncResult)`)
//    and hides `userData` (always `null` internally).
void openCallback(
  GtkWindow? parent,
  GCancellable? cancellable,
  void Function(GObject? sourceObject, GAsyncResult result) topLevel,
);
```

The two wrappers emit the same `*_finish` sibling — call it from inside
your callback to retrieve the result.

## When to use which

### Use `*Callback` when...

- The callback fires **asynchronously** (after the call returns) and
  GLib's main loop dispatches it later (idle sources, I/O, file dialogs,
  async queries).
- The callback runs **synchronously inside the call** and only invokes
  passed-in data (e.g. `g_async_queue_sort` with a comparator). The base
  wrapper works fine here.

The base wrapper is **unsafe for async callbacks** because it allocates a
`NativeCallable` and closes it in `finally` — leaving a dangling C
function pointer when GLib later dispatches the callback from the main
loop. The `*Callback` overload routes the dispatch through a permanent
`Pointer.fromFunction` over a static trampoline + per-call registry, so
no `NativeCallable` is ever closed.

### Use the base wrapper when...

- You are calling a **C callback** you registered separately (rare).
- You genuinely need to share `userData` with non-Dart callers.

In those cases, build the function pointer yourself via
`ffi.Pointer.fromFunction` with a top-level Dart function whose lifetime
outlives the source — see the "raw FFI" example below.

## Lifetime model

`Pointer.fromFunction` pins a Dart function for the lifetime of the
program (the VM keeps the function alive). The trampoline is a static
method so `Pointer.fromFunction` accepts it. The per-call `id` (carried
in the `data` pointer — an `int` malloc'd by the convenience overload)
routes the dispatch back to the user's typed callback. After the
callback fires, the trampoline removes the entry from the registry and
frees the malloc'd `data`.

The registry holds a strong reference to the user's callback until the
trampoline removes it. If the operation never completes (e.g. the source
is destroyed without the callback ever firing), the entry leaks — keep
your callback (and the objects it captures) externally referenced.

## Usage

```dart
// Top-level helper because the closure must survive past the call.
void onFileDialogClosed(GObject? sourceObject, GAsyncResult result) {
  final dialog = sourceObject as GtkFileDialog;
  final file = dialog.openFinish(result); // throws GlibException on error
  print('picked: $file');
}

final dialog = GtkFileDialog();
dialog.openCallback(parent, cancellable, onFileDialogClosed);
```

The callback signature is typed (`GObject?`, `GAsyncResult`) — no manual
`Pointer<Void>` casts required.

## How `user_data` is handled

The convenience overload always passes `ffi.nullptr` for `user_data`
(the dispatch is internal — the trampoline routes via `id`). Dart
closures already capture state, so `user_data` is a C-only concept that
the convenience overload hides.

The base wrapper keeps `user_data` for users who genuinely need to share
data with non-Dart callers (e.g. C callbacks registered separately).

## Cross-reference

- **Base wrapper emission**: `CallableEmitter` in
  `generator/lib/src/emit/callable.dart`.
- **`*Callback` overload emission**: `AsyncCallbackEmitter` in
  `generator/lib/src/emit/async_emitter.dart`.
- **Detecting async methods**: a parameter with `scope="async"` and a
  type of `GAsyncReadyCallback` (parsed into `GirParameter.scope`).
- **Parser/model changes**: `GirMethod.finishFunc`,
  `GirParameter.scope`, `GirParameter.closureIndex` (in
  `generator/lib/src/gir/model.dart`).
- **GIR `glib:finish-func` attribute** is now parsed; cross-references
  between the `*_async` and `*_finish` siblings appear in the generated
  doc comments.
