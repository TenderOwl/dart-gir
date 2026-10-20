/// `GBytes` helpers for the template-codegen path.
///
/// `GBytes` is a `<glib:boxed>` opaque record, declared only in
/// `GLib-2.0.gir`. The generator therefore emits it once, in
/// `package:glib` — the namespace that owns it.
///
/// `package:gtk_templates` re-exports it, so the codegen and the
/// user's code have a single, unambiguous `GBytes` and need only one
/// import.
///
/// The hand-written surface is `gbytesFromString` (the only helper
/// the codegen-emitted mixin needs) and `gbytesFromUint8List` for
/// callers that already have the bytes.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:glib/glib.dart' show GBytes, glibLookup;

/// Encodes [s] as UTF-8 and wraps it in a `GBytes*`.
///
/// Convenience used by the generated mixin to convert the
/// embedded template XML into the form
/// `GtkWidgetClass.setTemplate(...)` expects. The bytes are
/// copied into GLib-managed storage; the caller may free or
/// mutate the Dart-side buffer immediately.
GBytes gbytesFromString(String s) => gbytesFromUint8List(utf8.encode(s));

/// Build a `GBytes` from an existing `Uint8List`.
///
/// The bytes are copied into GLib-managed storage; the caller
/// may free or mutate the input immediately.
GBytes gbytesFromUint8List(Uint8List data) {
  final ptr = malloc<ffi.Uint8>(data.isEmpty ? 1 : data.length);
  try {
    if (data.isNotEmpty) {
      ptr.asTypedList(data.length).setAll(0, data);
    }
    return GBytes.fromPointer(_gBytesNew(ptr.cast(), data.length));
  } finally {
    malloc.free(ptr);
  }
}

final _gBytesNew =
    glibLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Size)
          >
        >('g_bytes_new')
        .asFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
        >();
