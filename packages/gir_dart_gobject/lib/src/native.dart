import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_gobject/gir_gobject.dart';

/// The native functions the Dart-object model needs and the
/// introspection data does not expose.
///
/// The GIR marks `g_signal_newv`, `g_cclosure_new` and
/// `g_signal_connect_data` `introspectable="0"` — they take a
/// `va_list` or a `GCallback`, which the introspection format cannot
/// describe. The generator does not bind them, and the generated
/// signal helpers look `g_signal_connect_data` up at runtime for the
/// same reason. The runtime does the same for the rest.
///
/// The `g_value_*` functions are bound by the generator as methods of
/// the `GValue` record, but a `GValue` that belongs to GObject — the
/// one a property's `set_property` vfunc receives — has no Dart
/// wrapper, and making one would put a borrowed stack address into
/// the wrapper cache. The runtime therefore reads and writes the
/// values through the raw functions.

/// The `GType` of a value that holds nothing.
final int gTypeNone = typeFromName('void');

/// The `GType` of a `gboolean`.
final int gTypeBoolean = typeFromName('gboolean');

/// The `GType` of a `gint`.
final int gTypeInt = typeFromName('gint');

/// The `GType` of a `gdouble`.
final int gTypeDouble = typeFromName('gdouble');

/// The `GType` of a NUL-terminated string.
final int gTypeString = typeFromName('gchararray');

/// The `GType` of a `GObject`.
final int gTypeObject = typeFromName('GObject');

/// The size of a `GValue`, in bytes.
///
/// `GValue` is `{ GType g_type; union _GValue_data data[2]; }`. The
/// introspection data does not carry the layout, and the union holds a
/// `gint64` twice — so the size is the size of a `GType` plus 16. On
/// the 64-bit Linux build the bindings target that is 24 bytes; the
/// header cross-check in `gvalue_layout_test.dart` confirms it.
final int gValueSize = ffi.sizeOf<ffi.Pointer<ffi.Void>>() == 8 ? 24 : 20;

/// `g_signal_newv` — creates a signal on a type.
///
/// ```c
/// guint g_signal_newv (const gchar *signal_name,
///                      GType itype,
///                      GSignalFlags signal_flags,
///                      GClosure *class_closure,
///                      GSignalAccumulator accumulator,
///                      gpointer accu_data,
///                      GCMarshaller c_marshaller,
///                      GType return_type,
///                      guint n_params,
///                      GType *param_types);
/// ```
final _gSignalNewv =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Uint32 Function(
              ffi.Pointer<Utf8>,
              ffi.Size,
              ffi.Uint32,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Size,
              ffi.Uint32,
              ffi.Pointer<ffi.Size>,
            )
          >
        >('g_signal_newv')
        .asFunction<
          int Function(
            ffi.Pointer<Utf8>,
            int,
            int,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            int,
            int,
            ffi.Pointer<ffi.Size>,
          )
        >();

/// Creates the signal [name] on [type] and returns its id.
///
/// The signal's default handler is [classClosure]; the marshaller is
/// the generic one, so the handler receives the signal's arguments in
/// their native shape.
int signalNewv(
  String name,
  int type,
  int signalFlags,
  ffi.Pointer<ffi.Void> classClosure,
  ffi.Pointer<ffi.Void> marshaller,
  int returnType,
  ffi.Pointer<ffi.Size> parameterTypes,
  int parameterCount,
) {
  final nativeName = name.toNativeUtf8();
  try {
    return _gSignalNewv(
      nativeName.cast<Utf8>(),
      type,
      signalFlags,
      classClosure,
      ffi.nullptr,
      ffi.nullptr,
      marshaller,
      returnType,
      parameterCount,
      parameterTypes,
    );
  } finally {
    calloc.free(nativeName);
  }
}

/// `g_cclosure_new` — creates a closure over a C function pointer.
///
/// ```c
/// GClosure* g_cclosure_new (GCallback callback_func,
///                            gpointer user_data,
///                            GClosureNotify destroy_data);
/// ```
final _gCClosureNew =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
            )
          >
        >('g_cclosure_new')
        .asFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
          )
        >();

/// Creates a closure that calls [callback] with [userData].
///
/// The closure is floating: it holds one reference, which the caller
/// owns until the closure is sunk.
ffi.Pointer<ffi.Void> cclosureNew(
  int callbackAddress,
  ffi.Pointer<ffi.Void> userData,
  ffi.Pointer<ffi.Void> destroyNotify,
) {
  return _gCClosureNew(
    ffi.Pointer.fromAddress(callbackAddress),
    userData,
    destroyNotify,
  );
}

/// `g_closure_unref` — drops a reference to a closure.
final _gClosureUnref =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
        >('g_closure_unref')
        .asFunction<void Function(ffi.Pointer<ffi.Void>)>();

/// Drops a reference to [closure].
void closureUnref(ffi.Pointer<ffi.Void> closure) {
  if (closure == ffi.nullptr) return;
  _gClosureUnref(closure);
}

/// `g_cclosure_marshal_generic` — the generic marshaller.
///
/// It reads the signal's arguments out of their `GValue`s and calls the
/// closure's callback with them in their native shape, followed by the
/// closure's user data.
final _gCClosureMarshalGenericPointer =
    girGobjectLookup<
      ffi.NativeFunction<
        ffi.Void Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
        )
      >
    >('g_cclosure_marshal_generic');

/// The address of the generic marshaller.
///
/// A `GCMarshaller` is a plain C function pointer; the signal system
/// stores it and calls it for every emission.
final int genericMarshallerAddress = _gCClosureMarshalGenericPointer.address;

/// `g_signal_connect_data` — connects a handler to a signal.
final _gSignalConnectData =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Uint64 Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<Utf8>,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
            )
          >
        >('g_signal_connect_data')
        .asFunction<
          int Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            int,
          )
        >();

/// Connects [callback] to [signalName] on [instance].
///
/// The callback is called with the instance, the signal's arguments and
/// [userData] as its last argument — the shape the signal's marshaller
/// produces.
int signalConnectData(
  ffi.Pointer<ffi.Void> instance,
  String signalName,
  int callbackAddress,
  ffi.Pointer<ffi.Void> userData,
  ffi.Pointer<ffi.Void> destroyNotify,
) {
  final nativeName = signalName.toNativeUtf8();
  try {
    return _gSignalConnectData(
      instance,
      nativeName.cast<Utf8>(),
      ffi.Pointer.fromAddress(callbackAddress),
      userData,
      destroyNotify,
      0,
    );
  } finally {
    calloc.free(nativeName);
  }
}

/// `g_signal_emitv` — emits a signal with a prepared `GValue` array.
final _gSignalEmitv =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
              ffi.Uint32,
              ffi.Pointer<ffi.Void>,
            )
          >
        >('g_signal_emitv')
        .asFunction<
          void Function(ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Void>)
        >();

/// Emits the signal [signalId] on [instance].
///
/// [instanceAndParams] is the array of `GValue`s the signal system
/// expects: the instance first, then one value per signal argument.
void signalEmitv(
  ffi.Pointer<ffi.Void> instanceAndParams,
  int signalId,
  ffi.Pointer<ffi.Void> returnValue,
) {
  _gSignalEmitv(instanceAndParams, signalId, 0, returnValue);
}

/// `g_value_init` — prepares a `GValue` for a type.
final _gValueInit =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Size)>
        >('g_value_init')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, int)>();

/// Prepares the `GValue` at [value] for [type].
void valueInit(ffi.Pointer<ffi.Void> value, int type) {
  _gValueInit(value, type);
}

/// `g_value_unset` — releases what a `GValue` holds.
final _gValueUnset =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
        >('g_value_unset')
        .asFunction<void Function(ffi.Pointer<ffi.Void>)>();

/// Releases what the `GValue` at [value] holds.
void valueUnset(ffi.Pointer<ffi.Void> value) {
  _gValueUnset(value);
}

/// `g_value_get_string` — reads a string out of a `GValue`.
///
/// The string belongs to the `GValue`; the caller must not free it.
final _gValueGetString =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>)>
        >('g_value_get_string')
        .asFunction<ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>)>();

/// Reads the string out of the `GValue` at [value].
///
/// The pointer stays the `GValue`'s; the caller must not free it.
ffi.Pointer<Utf8> valueGetString(ffi.Pointer<ffi.Void> value) {
  return _gValueGetString(value);
}

/// `g_value_set_string` — writes a string into a `GValue`.
///
/// The `GValue` takes a copy of the string.
final _gValueSetString =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)
          >
        >('g_value_set_string')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>();

/// Writes [text] into the `GValue` at [value]; the `GValue` copies it.
void valueSetString(ffi.Pointer<ffi.Void> value, ffi.Pointer<Utf8> text) {
  _gValueSetString(value, text);
}

/// `g_value_get_int` — reads an `int` out of a `GValue`.
final _gValueGetInt =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>
        >('g_value_get_int')
        .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

/// Reads the `int` out of the `GValue` at [value].
int valueGetInt(ffi.Pointer<ffi.Void> value) {
  return _gValueGetInt(value);
}

/// `g_value_set_int` — writes an `int` into a `GValue`.
final _gValueSetInt =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32)
          >
        >('g_value_set_int')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, int)>();

/// Writes [number] into the `GValue` at [value].
void valueSetInt(ffi.Pointer<ffi.Void> value, int number) {
  _gValueSetInt(value, number);
}

/// `g_value_get_boolean` — reads a `bool` out of a `GValue`.
final _gValueGetBoolean =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>
        >('g_value_get_boolean')
        .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

/// Reads the `bool` out of the `GValue` at [value].
bool valueGetBoolean(ffi.Pointer<ffi.Void> value) {
  return _gValueGetBoolean(value) != 0;
}

/// `g_value_set_boolean` — writes a `bool` into a `GValue`.
final _gValueSetBoolean =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32)
          >
        >('g_value_set_boolean')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, int)>();

/// Writes [flag] into the `GValue` at [value].
void valueSetBoolean(ffi.Pointer<ffi.Void> value, bool flag) {
  _gValueSetBoolean(value, flag ? 1 : 0);
}

/// `g_value_get_double` — reads a `double` out of a `GValue`.
final _gValueGetDouble =
    girGobjectLookup<
          ffi.NativeFunction<ffi.Double Function(ffi.Pointer<ffi.Void>)>
        >('g_value_get_double')
        .asFunction<double Function(ffi.Pointer<ffi.Void>)>();

/// Reads the `double` out of the `GValue` at [value].
double valueGetDouble(ffi.Pointer<ffi.Void> value) {
  return _gValueGetDouble(value);
}

/// `g_value_set_double` — writes a `double` into a `GValue`.
final _gValueSetDouble =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)
          >
        >('g_value_set_double')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, double)>();

/// Writes [number] into the `GValue` at [value].
void valueSetDouble(ffi.Pointer<ffi.Void> value, double number) {
  _gValueSetDouble(value, number);
}

/// `g_value_set_enum` — writes an enum value into a `GValue`.
///
/// The enum's *value* — the integer the C enumeration uses — goes in;
/// the `GValue` knows the enumeration's type already.
final _gValueSetEnum =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32)
          >
        >('g_value_set_enum')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, int)>();

/// Writes [number] into the `GValue` at [value].
void valueSetEnum(ffi.Pointer<ffi.Void> value, int number) {
  _gValueSetEnum(value, number);
}

/// `g_value_get_object` — reads a `GObject` out of a `GValue`.
///
/// The `GValue` holds the reference; the caller must not unref it.
final _gValueGetObject =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >
        >('g_value_get_object')
        .asFunction<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>();

/// Reads the `GObject` out of the `GValue` at [value].
///
/// The `GValue` holds the reference; the caller must not unref it.
ffi.Pointer<ffi.Void> valueGetObject(ffi.Pointer<ffi.Void> value) {
  return _gValueGetObject(value);
}

/// `g_value_set_object` — writes a `GObject` into a `GValue`.
///
/// The `GValue` takes a reference of its own.
final _gValueSetObject =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
          >
        >('g_value_set_object')
        .asFunction<
          void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
        >();

/// Writes [object] into the `GValue` at [value]; the `GValue` refs it.
void valueSetObject(ffi.Pointer<ffi.Void> value, ffi.Pointer<ffi.Void> object) {
  _gValueSetObject(value, object);
}

/// `g_object_get_property` — reads a property into a `GValue`.
final _gObjectGetProperty =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<Utf8>,
              ffi.Pointer<ffi.Void>,
            )
          >
        >('g_object_get_property')
        .asFunction<
          void Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Void>,
          )
        >();

/// Reads the property [name] of [object] into the `GValue` at [value].
void objectGetProperty(
  ffi.Pointer<ffi.Void> object,
  String name,
  ffi.Pointer<ffi.Void> value,
) {
  final nativeName = name.toNativeUtf8();
  try {
    _gObjectGetProperty(object, nativeName.cast<Utf8>(), value);
  } finally {
    calloc.free(nativeName);
  }
}

/// `g_object_set_property` — writes a property from a `GValue`.
final _gObjectSetProperty =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<Utf8>,
              ffi.Pointer<ffi.Void>,
            )
          >
        >('g_object_set_property')
        .asFunction<
          void Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<Utf8>,
            ffi.Pointer<ffi.Void>,
          )
        >();

/// Writes the property [name] of [object] from the `GValue` at [value].
void objectSetProperty(
  ffi.Pointer<ffi.Void> object,
  String name,
  ffi.Pointer<ffi.Void> value,
) {
  final nativeName = name.toNativeUtf8();
  try {
    _gObjectSetProperty(object, nativeName.cast<Utf8>(), value);
  } finally {
    calloc.free(nativeName);
  }
}
