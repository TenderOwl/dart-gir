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
DynamicLibrary _glibProcessLib() => Platform.isLinux
    ? DynamicLibrary.process()
    : DynamicLibrary.executable();

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
