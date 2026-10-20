import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Loads the first available library from [names].
///
/// Falls back to the current process when none can be opened (symbols may
/// already be loaded globally).
DynamicLibrary openLibrary(List<String> names) {
  for (final name in names) {
    try {
      return DynamicLibrary.open(name);
    } on ArgumentError {
      // try next candidate
    }
  }
  return Platform.isLinux
      ? DynamicLibrary.process()
      : DynamicLibrary.executable();
}

/// Looks up [symbol] in the running process — used for GLib-internal
/// helpers (`g_free`) that are loaded globally when libglib is present.
DynamicLibrary _glibProcessLib() =>
    Platform.isLinux ? DynamicLibrary.process() : DynamicLibrary.executable();

final _gFreeNative = _glibProcessLib()
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>('g_free');
void gFree(Pointer<Void> ptr) {
  if (ptr == nullptr) return;
  _gFreeNative.asFunction<void Function(Pointer<Void>)>().call(ptr);
}

/// Converts a native NUL-terminated UTF-8 string to a Dart [String].
String? stringFromNative(Pointer<Char> ptr, {bool free = false}) {
  if (ptr == nullptr) return null;
  final value = ptr.cast<Utf8>().toDartString();
  if (free) malloc.free(ptr);
  return value;
}

/// Converts a Dart [String] to a native NUL-terminated UTF-8 string.
Pointer<Char> stringToNative(String? value) {
  if (value == null) return nullptr;
  return value.toNativeUtf8().cast<Char>();
}

/// Runs [body] with [value] marshalled to native memory, freeing it after.
R withNativeString<R>(String? value, R Function(Pointer<Char>) body) {
  final ptr = stringToNative(value);
  try {
    return body(ptr);
  } finally {
    if (ptr != nullptr) malloc.free(ptr);
  }
}

/// Re-wraps a raw native pointer as the user's class via [factory].
///
/// Use this when you have a bare `Pointer<Void>` (e.g. from a custom
/// FFI lookup, from a struct OUT param, from `Pointer.fromAddress`)
/// and want to recover your subclass's methods. The companion to the
/// instance `cast<T>(factory)` method on every generated wrapper —
/// they call this internally when the user passes a raw pointer
/// instead of a wrapper.
T castTo<T extends Object>(
  Pointer<Void> handle,
  T Function(Pointer<Void>) factory,
) {
  return factory(handle);
}

/// Marshals a nullable `List<String?>` to a NULL-terminated
/// `Pointer<Pointer<Utf8>>` for the duration of [body], matching how GLib
/// expects argv-style arrays. Each non-null element is copied to a
/// native NUL-terminated string; the outer pointer and all per-element
/// pointers are freed in a `finally`.
///
/// * Pass `null` to leave the array pointer as NULL — the C side sees
///   `argv == NULL`, which is the accepted convention for
///   `g_application_run` and friends when no command-line parsing is
///   needed.
/// * Pass an empty list to allocate a one-slot array whose only entry
///   is NULL — i.e. `argc = 0, argv = {NULL}`. Same as above but
///   distinguishable from a null pointer for C APIs that require a
///   non-null array.
/// * Null elements inside the list become NULL slots in the array;
///   only the non-null allocations are tracked for freeing.
R withNativeStringList<R>(
  List<String?>? values,
  R Function(Pointer<Pointer<Utf8>> argv) body,
) {
  if (values == null) {
    return body(nullptr);
  }
  final argc = values.length;
  final argv = calloc<Pointer<Utf8>>(argc + 1);
  final strs = <Pointer<Utf8>>[];
  try {
    for (var i = 0; i < argc; i++) {
      final v = values[i];
      if (v == null) {
        argv[i] = nullptr;
      } else {
        final p = v.toNativeUtf8();
        strs.add(p);
        argv[i] = p.cast();
      }
    }
    argv[argc] = nullptr; // explicit NULL terminator
    return body(argv);
  } finally {
    for (final p in strs) {
      calloc.free(p);
    }
    calloc.free(argv);
  }
}

/// Backing store for caller-allocated OUT parameters (e.g. `GtkTextIter*`,
/// `GValue*`) emitted by the generator.
///
/// Holds a fixed-size zero-initialized buffer and frees it via
/// [NativeFinalizer] when the anchor is garbage collected. The corresponding
/// Dart wrapper (e.g. `GtkTextIter.fromPointer(_buffer)`) keeps the
/// anchor reachable as long as the user holds the wrapper — matching
/// GTK's "the iter lives until you drop it" semantics.
///
/// Use [HeapAnchor.allocate] to create a new anchor with a buffer of the
/// requested size. The buffer's lifetime is tied to the anchor's
/// reachability; drop the wrapper and the buffer is freed on the next
/// GC cycle.
class HeapAnchor implements Finalizable {
  HeapAnchor(this.buffer);

  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  /// The heap-allocated buffer. The C function fills this memory; the
  /// wrapper then exposes it as `Pointer<Void>` (or any struct-typed
  /// pointer) to its caller.
  final Pointer<Uint8> buffer;

  /// Allocates a [byteCount]-byte zero-initialized buffer and attaches a
  /// finalizer that calls `malloc.nativeFree` when the anchor is GC'd.
  static HeapAnchor allocate(int byteCount) {
    final anchor = HeapAnchor(calloc<Uint8>(byteCount));
    _finalizer.attach(anchor, anchor.buffer.cast());
    return anchor;
  }
}

/// The registry that ties a wrapper to the buffer it points into.
///
/// A wrapper built from an OUT parameter points *into* a buffer the
/// generator allocated for the call — a `GtkTextIter` is not a pointer
/// to an object, it is a window onto the caller's own memory. If the
/// buffer dies while the wrapper lives, the wrapper reads freed memory.
///
/// The registry is a weak-keyed map: the entry disappears with the
/// wrapper, and the buffer's own [NativeFinalizer] frees the memory
/// once nothing holds the anchor any more.
final Expando<Object> _keepAliveRegistry = Expando<Object>();

/// Ties [anchor] to [wrapper]'s lifetime and returns [wrapper].
///
/// The generator calls this for every wrapper it builds from an OUT
/// parameter's buffer, so the buffer outlives the wrapper that reads
/// from it.
T keepAlive<T extends Object>(T wrapper, Object anchor) {
  _keepAliveRegistry[wrapper] = anchor;
  return wrapper;
}

/// The wrapper cache.
///
/// Native code hands the same pointer over more than once: a property
/// getter, a signal argument, a list item. Without a cache every
/// handover produced a *new* Dart wrapper, so a Dart subclass of a
/// GObject class lost its identity — and its Dart state — on the way
/// out of native code.
///
/// The entries are **weak**. A strong entry would keep every wrapper
/// alive forever: its finalizer would never run, the native object
/// would never be released, and every model object would leak. The Dart
/// side is owned by the application.
///
/// One address can hold several wrappers: the same native object may be
/// seen through different classes (a `GObject` and a `GtkWidget`, say),
/// and each of them wants its own view of it.
final Map<int, List<WeakReference<Object>>> _objectCache =
    <int, List<WeakReference<Object>>>{};

/// The Dart object registered for [address] that is a [T], if any.
///
/// Returns `null` when nothing is registered for the address, when every
/// registered object has been collected, or when none of them is a [T].
T? cachedObject<T extends Object>(int address) {
  final entries = _objectCache[address];
  if (entries == null) return null;
  for (var i = 0; i < entries.length; i++) {
    final hit = entries[i].target;
    if (hit == null) {
      // The Dart object is gone; the address may be reused by a later
      // object, so the stale entry goes.
      entries.removeAt(i);
      i--;
      continue;
    }
    if (hit is T) return hit;
  }
  if (entries.isEmpty) _objectCache.remove(address);
  return null;
}

/// Registers [object] under [address].
///
/// A second wrapper for the same address joins the list rather than
/// replacing the first one: a Dart subclass instance must not be
/// shadowed by a later, less specific wrapper for the same pointer.
void registerDartObject(Object object, int address) {
  final entries = _objectCache.putIfAbsent(
    address,
    () => <WeakReference<Object>>[],
  );
  for (final entry in entries) {
    if (identical(entry.target, object)) return;
  }
  entries.add(WeakReference(object));
  _pruneObjectCache();
}

/// Drops the entries whose Dart object has been collected.
///
/// Called from [registerDartObject] so the map cannot grow without
/// bound; the sweep is amortised — it only runs once the map has grown
/// past twice the number of live entries.
void _pruneObjectCache() {
  if (_objectCache.length < _pruneThreshold) return;
  var live = 0;
  for (final entries in _objectCache.values) {
    entries.removeWhere((entry) => entry.target == null);
    live += entries.length;
  }
  _objectCache.removeWhere((_, entries) => entries.isEmpty);
  _pruneThreshold = (live * 2).clamp(64, 1 << 20);
}

/// The size at which the cache is swept.
int _pruneThreshold = 64;

/// The number of entries in the wrapper cache.
///
/// Dead entries are pruned when they are looked up, so this counts the
/// entries that have not been visited since their object died.
int get cachedObjectCount => _objectCache.length;
