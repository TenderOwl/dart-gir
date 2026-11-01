import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_gobject/gir_gobject.dart';

import 'native.dart';

/// The layout of a `GValue`.
///
/// ```c
/// struct _GValue {
///   GType g_type;
///   union {
///     gint v_int; guint v_uint; glong v_long; gulong v_ulong;
///     gint64 v_int64; guint64 v_uint64; gfloat v_float;
///     gdouble v_double; gpointer v_pointer;
///   } data[2];
/// };
/// ```
///
/// The union is two `gint64`s wide, so the payload is 16 bytes and the
/// whole value 24 on a 64-bit build. The introspection data does not
/// carry the layout, so it is spelled out here; `gvalue_layout_test.dart`
/// cross-checks it against the installed header.
final class GValueLayout extends ffi.Struct {
  /// The type of the value the `GValue` holds.
  @ffi.Size()
  external int gType;

  /// The payload — two 64-bit slots.
  @ffi.Array(2)
  external ffi.Array<ffi.Uint64> data;
}

/// The layout of `GParameter`.
///
/// ```c
/// struct _GParameter {
///   const gchar *name;
///   GValue       value;
/// };
/// ```
///
/// `g_object_newv` takes an array of these: the property's name and
/// the value to set it to.
final class GParameterLayout extends ffi.Struct {
  /// The name of the construct property.
  external ffi.Pointer<ffi.Char> name;

  /// The value the property is constructed with.
  external GValueLayout value;
}

/// `g_object_newv` — creates an instance of a type.
///
/// ```c
/// gpointer g_object_newv (GType object_type,
///                          guint n_parameters,
///                          GParameter *parameters);
/// ```
final _gObjectNewv =
    girGobjectLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(
              ffi.Size,
              ffi.Uint32,
              ffi.Pointer<ffi.Void>,
            )
          >
        >('g_object_newv')
        .asFunction<
          ffi.Pointer<ffi.Void> Function(int, int, ffi.Pointer<ffi.Void>)
        >();

/// The fundamental type of an object — `G_TYPE_OBJECT`.
final int _fundamentalObject = typeFromName('GObject');

/// The fundamental type of a string — `G_TYPE_STRING`.
final int _fundamentalString = typeFromName('gchararray');

/// The fundamental type of an integer — `G_TYPE_INT`.
///
/// `G_TYPE_BOOLEAN` is an alias of `G_TYPE_INT`: `gboolean` is a
/// `gint` in C, so a boolean property and an integer property have the
/// same value type and cannot be told apart.
final int _fundamentalInt = typeFromName('gint');

/// The fundamental type of a double — `G_TYPE_DOUBLE`.
final int _fundamentalDouble = typeFromName('gdouble');

/// The fundamental type of an enumeration — `G_TYPE_ENUM`.
final int _fundamentalEnum = typeFromName('GEnum');

/// Creates an instance of the type [type].
///
/// The instance belongs to [type] itself and not to its parent, which
/// is what makes the virtual functions the type overrides the ones the
/// native side calls, and what lets a GTK template live on the type
/// instead of on its parent.
///
/// ```dart
/// class TaskObject extends GObject {
///   static int get GType => registerDartType('TaskObject', GObject.GType);
///
///   TaskObject() : super(GType);
/// }
/// ```
///
/// [constructProperties] are the properties the object is *constructed*
/// with — the ones a `G_PARAM_CONSTRUCT` property carries. GLib refuses
/// to set them afterwards, so they have to be handed over here:
///
/// ```dart
/// final row = newDartInstance(
///   TaskRow.GType,
///   constructProperties: {'orientation': 0},
/// );
/// ```
///
/// The values are Dart objects: a `GObject` for an object property, a
/// `String` for a string property, an `int` for an integer or
/// enumeration property, a `bool` for a boolean property and a `double`
/// for a double property. The property's own value type decides which
/// one is expected — a `bool` for an integer property becomes `1` or
/// `0`, and an `int` for a boolean property does the same.
///
/// Throws an [ArgumentError] when a value does not fit the property, and
/// an [UnsupportedError] when the property holds a type this function
/// cannot fill — a boxed type, a variant or a pointer.
ffi.Pointer<ffi.Void> newDartInstance(
  int type, {
  Map<String, Object> constructProperties = const {},
}) {
  if (constructProperties.isEmpty) {
    return _gObjectNewv(type, 0, ffi.nullptr);
  }
  return _newWithConstructProperties(type, constructProperties);
}

/// Creates an instance of [type] with [constructProperties].
ffi.Pointer<ffi.Void> _newWithConstructProperties(
  int type,
  Map<String, Object> constructProperties,
) {
  // The class has to exist before the properties can be looked up: the
  // property's value type is what the `GValue` is initialized with, and
  // a value of the wrong type is silently dropped by GLib.
  final classPtr = GTypeClass.ref(type);
  final names = <ffi.Pointer<Utf8>>[];
  final params = calloc<GParameterLayout>(constructProperties.length);
  // The offset of the `value` field inside a `GParameter`. The value is
  // the last field, so the offset is what is left of the record.
  final valueOffset =
      ffi.sizeOf<GParameterLayout>() - ffi.sizeOf<GValueLayout>();
  var initialized = 0;
  try {
    final gobjectClass = GObjectClass.fromPointer(classPtr.handle);
    var index = 0;
    for (final entry in constructProperties.entries) {
      final pspec = gobjectClass.findProperty(entry.key);
      if (pspec.handle == ffi.nullptr) {
        throw ArgumentError.value(
          entry.key,
          'constructProperties',
          'the type has no property with that name',
        );
      }
      // The property's value type is the type of its default value: a
      // `GValue` knows the type of what it holds, and the default
      // value is the one `GValue` the property owns.
      final defaultValue = pspec.getDefaultValue();
      final valueType = defaultValue.handle.cast<ffi.Size>().value;

      final name = entry.key.toNativeUtf8();
      names.add(name);

      final param = params + index;
      param.ref.name = name.cast<ffi.Char>();

      final valueAddress = param.cast<ffi.Uint8>().address + valueOffset;
      final valuePointer = ffi.Pointer<ffi.Void>.fromAddress(valueAddress);
      valueInit(valuePointer, valueType);
      initialized++;
      _setConstructValue(valuePointer, valueType, entry.value, entry.key);

      index++;
    }

    return _gObjectNewv(
      type,
      constructProperties.length,
      params.cast<ffi.Void>(),
    );
  } finally {
    // The values are the caller's: `g_object_newv` copies them into the
    // object, and the `GValue`s still hold what was put in them. An
    // object property holds a reference, so the values are released
    // here — exactly once.
    for (var i = 0; i < initialized; i++) {
      final valueAddress = (params + i).cast<ffi.Uint8>().address + valueOffset;
      valueUnset(ffi.Pointer<ffi.Void>.fromAddress(valueAddress));
    }
    for (final name in names) {
      calloc.free(name);
    }
    calloc.free(params);
    classPtr.unref();
  }
}

/// Writes [value] into the `GValue` at [valuePointer], which holds a
/// value of [valueType].
///
/// [name] is the property's name — it is only used in the error
/// messages.
void _setConstructValue(
  ffi.Pointer<ffi.Void> valuePointer,
  int valueType,
  Object value,
  String name,
) {
  final fundamental = typeFundamental(valueType);

  if (fundamental == _fundamentalObject) {
    if (value is! GObject) {
      throw ArgumentError.value(value, name, 'the property holds a GObject');
    }
    valueSetObject(valuePointer, value.handle);
    return;
  }

  if (fundamental == _fundamentalString) {
    if (value is! String) {
      throw ArgumentError.value(value, name, 'the property holds a string');
    }
    final text = value.toNativeUtf8();
    try {
      valueSetString(valuePointer, text.cast<Utf8>());
    } finally {
      calloc.free(text);
    }
    return;
  }

  if (fundamental == _fundamentalInt) {
    // `gboolean` is a `gint` in C, so a boolean property and an
    // integer property share their value type.
    if (value is bool) {
      valueSetInt(valuePointer, value ? 1 : 0);
      return;
    }
    if (value is int) {
      valueSetInt(valuePointer, value);
      return;
    }
    throw ArgumentError.value(value, name, 'the property holds an integer');
  }

  if (fundamental == _fundamentalDouble) {
    if (value is! double) {
      throw ArgumentError.value(value, name, 'the property holds a double');
    }
    valueSetDouble(valuePointer, value);
    return;
  }

  if (fundamental == _fundamentalEnum) {
    if (value is! int) {
      throw ArgumentError.value(
        value,
        name,
        'the property holds an enumeration; pass its integer value',
      );
    }
    valueSetEnum(valuePointer, value);
    return;
  }

  throw UnsupportedError(
    'dart_gobject: the construct property `$name` holds a type this '
    'runtime cannot fill (fundamental type $fundamental). Only objects, '
    'strings, integers, booleans, doubles and enumerations are '
    'supported.',
  );
}
