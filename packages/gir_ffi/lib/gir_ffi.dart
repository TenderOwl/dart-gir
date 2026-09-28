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
  return Platform.isLinux ? DynamicLibrary.process() : DynamicLibrary.executable();
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
