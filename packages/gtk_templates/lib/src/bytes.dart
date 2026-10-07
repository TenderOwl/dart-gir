/// `GBytes` helpers for the template-codegen path.
///
/// `package:gobject` doesn't ship a generated `GBytes` record
/// yet. The codegen needs to wrap a `String` (the template
/// XML) in a `GBytes*` to pass to
/// `GtkWidgetClass.setTemplate(...)`. This file is a small,
/// hand-written FFI binding that fills the gap until
/// `package:gobject` regenerates with a `GBytes` record.
///
/// Mirrors the precedent of `getWidgetClass` (in
/// `runtime.dart`): a small, purpose-built FFI helper that
/// lives in `package:gtk_templates` and is consumed by both
/// the generated mixin and the user code.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:glib/glib.dart' show glibLookup;

/// A borrowed handle to a `GBytes*` allocated by GLib.
///
/// The handle is owned by the caller of the helper that
/// produced it. `GBytes` is reference-counted in GLib; this
/// Dart wrapper does not manage the reference count — the
/// handle is held for the lifetime of the consuming mixin's
/// `static late final`, and the OS reclaims the underlying
/// memory on process exit. Acceptable for the codegen's
/// "one GBytes per class, held forever" shape.
final class GBytes {
  GBytes._(this.handle);
  final ffi.Pointer<ffi.Void> handle;

  /// Raw FFI binding to `g_bytes_new(data, size)`. Avoids
  /// regenerating `package:gobject`; can become a re-export
  /// once that package has its own generated `GBytes`
  /// record. The symbol lives in `libglib-2.0`; the
  /// existing `glibLookup` helper in `package:glib` walks
  /// the right library list.
  static final _gBytesNew =
      glibLookup<
            ffi.NativeFunction<
              ffi.Pointer<ffi.Void> Function(
                ffi.Pointer<ffi.Void>,
                ffi.Size,
              )
            >
          >('g_bytes_new')
          .asFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
          >();

  /// Copies [data] into a fresh GLib-allocated `GBytes*` and
  /// returns a borrowed wrapper around it.
  ///
  /// The data is copied: the caller may free or mutate
  /// [data] immediately after the call returns.
  static GBytes fromUint8List(Uint8List data) {
    if (data.isEmpty) {
      // g_bytes_new takes a non-null pointer; pass the
      // malloc(0) sentinel for the empty case.
      final empty = malloc<ffi.Uint8>(1);
      try {
        return GBytes._(_gBytesNew(empty.cast(), 0));
      } finally {
        malloc.free(empty);
      }
    }
    final ptr = malloc<ffi.Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return GBytes._(_gBytesNew(ptr.cast(), data.length));
    } finally {
      malloc.free(ptr);
    }
  }
}

/// Encodes [s] as UTF-8 and wraps it in a `GBytes*`.
///
/// Convenience used by the generated mixin to convert the
/// embedded template XML into the form
/// `GtkWidgetClass.setTemplate(...)` expects.
GBytes gbytesFromString(String s) =>
    GBytes.fromUint8List(utf8.encode(s));

