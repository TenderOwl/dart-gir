import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:gir_gobject/gir_gobject.dart';

import 'native.dart';
import 'objects.dart';
import 'vtable.dart';

/// The kind of value a Dart property carries.
///
/// The kind decides the `GParamSpec` the property is installed with and
/// how the value travels between the native `GValue` and Dart.
enum DartPropertyKind {
  /// A `gchar*` — a `String?` in Dart.
  string,

  /// A `gint` — an `int` in Dart.
  integer,

  /// A `gboolean` — a `bool` in Dart.
  boolean,

  /// A `gdouble` — a `double` in Dart.
  real,

  /// A `GObject*` — a `GObject?` in Dart.
  object,
}

/// The `GType` of a property of kind [kind].
int gTypeOfProperty(DartPropertyKind kind) {
  switch (kind) {
    case DartPropertyKind.string:
      return gTypeString;
    case DartPropertyKind.integer:
      return gTypeInt;
    case DartPropertyKind.boolean:
      return gTypeBoolean;
    case DartPropertyKind.real:
      return gTypeDouble;
    case DartPropertyKind.object:
      return gTypeObject;
  }
}

/// A property declared on a Dart type.
///
/// The property exists natively: it is installed with
/// `g_object_class_install_property` while the type's class is
/// initialized, so `g_object_get_property` and `g_object_set_property`
/// reach the Dart getter and setter.
///
/// ```dart
/// class TaskObject extends DartGObject {
///   static int get GType => registerDartType(
///     'TaskObject',
///     GObject.GType,
///     properties: {
///       'content': DartProperty.string(
///         getter: (self) => (self! as TaskObject).content,
///         setter: (self, value) => (self! as TaskObject).content = value!,
///       ),
///     },
///   );
/// }
/// ```
class DartProperty {
  /// A property that carries a `String`.
  static DartProperty string({
    required Object? Function(Object?) getter,
    void Function(Object?, String?)? setter,
    String? nick,
    String? blurb,
  }) => DartProperty(
    kind: DartPropertyKind.string,
    getter: getter,
    setter: setter == null
        ? null
        : (self, value) => setter(self, value as String?),
    nick: nick,
    blurb: blurb,
  );

  /// A property that carries an `int`.
  static DartProperty integer({
    required Object? Function(Object?) getter,
    void Function(Object?, int)? setter,
    String? nick,
    String? blurb,
  }) => DartProperty(
    kind: DartPropertyKind.integer,
    getter: getter,
    setter: setter == null ? null : (self, value) => setter(self, value as int),
    nick: nick,
    blurb: blurb,
  );

  /// A property that carries a `bool`.
  static DartProperty boolean({
    required Object? Function(Object?) getter,
    void Function(Object?, bool)? setter,
    String? nick,
    String? blurb,
  }) => DartProperty(
    kind: DartPropertyKind.boolean,
    getter: getter,
    setter: setter == null
        ? null
        : (self, value) => setter(self, value as bool),
    nick: nick,
    blurb: blurb,
  );

  /// A property that carries a `double`.
  static DartProperty real({
    required Object? Function(Object?) getter,
    void Function(Object?, double)? setter,
    String? nick,
    String? blurb,
  }) => DartProperty(
    kind: DartPropertyKind.real,
    getter: getter,
    setter: setter == null
        ? null
        : (self, value) => setter(self, value as double),
    nick: nick,
    blurb: blurb,
  );

  /// A property that carries a `GObject`.
  static DartProperty object({
    required Object? Function(Object?) getter,
    void Function(Object?, GObject?)? setter,
    String? nick,
    String? blurb,
  }) => DartProperty(
    kind: DartPropertyKind.object,
    getter: getter,
    setter: setter == null
        ? null
        : (self, value) => setter(self, value as GObject?),
    nick: nick,
    blurb: blurb,
  );

  /// A property of the given [kind].
  const DartProperty({
    required this.kind,
    required this.getter,
    this.setter,
    this.nick,
    this.blurb,
  });

  /// The kind of the value the property carries.
  final DartPropertyKind kind;

  /// Reads the property's value off the Dart object.
  ///
  /// The object is the Dart wrapper of the instance; it is `null` when
  /// the instance has no Dart wrapper.
  final Object? Function(Object?) getter;

  /// Writes the property's value onto the Dart object.
  ///
  /// A property without a setter is read-only: the native side refuses
  /// to write it.
  final void Function(Object?, Object?)? setter;

  /// The property's human-readable name.
  final String? nick;

  /// The property's description.
  final String? blurb;
}

/// The property of a type, by the type's id and the property's id.
class _InstalledProperty {
  _InstalledProperty(this.declaration, this.pspec);

  /// The Dart declaration of the property.
  final DartProperty declaration;

  /// The native `GParamSpec` the property was installed with.
  final GParamSpec pspec;
}

/// The properties installed on a type, by the type's id and the
/// property's id.
///
/// A property's id is the one GLib knows it by: it is unique inside the
/// class, and the `set_property` and `get_property` vfuncs carry it.
final Map<int, Map<int, _InstalledProperty>> _installed =
    <int, Map<int, _InstalledProperty>>{};

/// The signatures of the property vfuncs.
///
/// ```c
/// void (*set_property) (GObject *object, guint property_id,
///                        const GValue *value, GParamSpec *pspec);
/// void (*get_property) (GObject *object, guint property_id,
///                        GValue *value, GParamSpec *pspec);
/// ```
typedef _SetProperty = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Uint32,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);
typedef _GetProperty = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Uint32,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);

/// The permanent trampolines.
///
/// A class lives for as long as its type does, so its vfuncs must never
/// be closed — a closed `NativeCallable` would leave a dangling C
/// function pointer.
final ffi.NativeCallable<_SetProperty> _setPropertyCallable =
    ffi.NativeCallable<_SetProperty>.isolateLocal(_setPropertyBridge);
final ffi.NativeCallable<_GetProperty> _getPropertyCallable =
    ffi.NativeCallable<_GetProperty>.isolateLocal(_getPropertyBridge);

/// The property the vfunc call is about.
_InstalledProperty? _propertyOf(ffi.Pointer<ffi.Void> object, int propertyId) {
  final properties = _installed[typeOfInstance(object)];
  if (properties == null) return null;
  return properties[propertyId];
}

/// Reads the value the native side wants to write.
Object? _readValue(DartPropertyKind kind, ffi.Pointer<ffi.Void> value) {
  switch (kind) {
    case DartPropertyKind.string:
      final text = valueGetString(value);
      if (text == ffi.nullptr) return null;
      return stringFromNative(text.cast(), free: false);
    case DartPropertyKind.integer:
      return valueGetInt(value);
    case DartPropertyKind.boolean:
      return valueGetBoolean(value);
    case DartPropertyKind.real:
      return valueGetDouble(value);
    case DartPropertyKind.object:
      final object = valueGetObject(value);
      if (object == ffi.nullptr) return null;
      return GObject.fromPointer(object);
  }
}

/// Writes the value the Dart getter returned into the native `GValue`.
void _writeValue(
  DartPropertyKind kind,
  ffi.Pointer<ffi.Void> value,
  Object? result,
) {
  switch (kind) {
    case DartPropertyKind.string:
      final text = result as String?;
      if (text == null) {
        valueSetString(value, ffi.nullptr.cast<Utf8>());
        return;
      }
      final native = text.toNativeUtf8();
      try {
        valueSetString(value, native.cast<Utf8>());
      } finally {
        calloc.free(native);
      }
    case DartPropertyKind.integer:
      valueSetInt(value, result is int ? result : 0);
    case DartPropertyKind.boolean:
      valueSetBoolean(value, result == true);
    case DartPropertyKind.real:
      valueSetDouble(value, result is num ? result.toDouble() : 0);
    case DartPropertyKind.object:
      final object = result;
      valueSetObject(value, object is GObject ? object.handle : ffi.nullptr);
  }
}

void _setPropertyBridge(
  ffi.Pointer<ffi.Void> object,
  int propertyId,
  ffi.Pointer<ffi.Void> value,
  ffi.Pointer<ffi.Void> pspec,
) {
  final installed = _propertyOf(object, propertyId);
  if (installed == null) return;
  final setter = installed.declaration.setter;
  if (setter == null) return;
  setter(dartObjectFor(object), _readValue(installed.declaration.kind, value));
  // The value changed: the property has to be announced, the way a
  // native class announces it.
  GObject.fromPointer(object).notifyByPspec(installed.pspec);
}

void _getPropertyBridge(
  ffi.Pointer<ffi.Void> object,
  int propertyId,
  ffi.Pointer<ffi.Void> value,
  ffi.Pointer<ffi.Void> pspec,
) {
  final installed = _propertyOf(object, propertyId);
  if (installed == null) return;
  _writeValue(
    installed.declaration.kind,
    value,
    installed.declaration.getter(dartObjectFor(object)),
  );
}

/// Creates the `GParamSpec` of the property [name].
GParamSpec _createParamSpec(String name, DartProperty property) {
  final flags = property.setter == null
      ? GParamFlags.readable
      : GParamFlags.readwrite;
  switch (property.kind) {
    case DartPropertyKind.string:
      return paramSpecString(name, property.nick, property.blurb, null, flags);
    case DartPropertyKind.integer:
      return paramSpecInt(
        name,
        property.nick,
        property.blurb,
        -2147483648,
        2147483647,
        0,
        flags,
      );
    case DartPropertyKind.boolean:
      return paramSpecBoolean(
        name,
        property.nick,
        property.blurb,
        false,
        flags,
      );
    case DartPropertyKind.real:
      return paramSpecDouble(
        name,
        property.nick,
        property.blurb,
        -double.maxFinite,
        double.maxFinite,
        0,
        flags,
      );
    case DartPropertyKind.object:
      return paramSpecObject(
        name,
        property.nick,
        property.blurb,
        gTypeObject,
        flags,
      );
  }
}

/// Installs the properties [properties] on the type [type].
///
/// The call belongs to the type's class initializer: GLib refuses a
/// property that is installed after the class was derived.
void installDartProperties(
  int type,
  ffi.Pointer<ffi.Void> gClass,
  Map<String, DartProperty> properties,
) {
  if (properties.isEmpty) return;

  // The class struct of a derived type is the parent's copy: writing
  // the slots here affects this type alone.
  //
  // The slots have to be written *before* the properties are installed:
  // GObject's base initializer resets `set_property` and `get_property`
  // to NULL — they are "instance specific fields and methods that don't
  // get inherited" — and GObject refuses a writable property whose
  // class has no `set_property`.
  writeVtableSlot(
    gClass,
    GObjectVtable.setProperty,
    _setPropertyCallable.nativeFunction.address,
  );
  writeVtableSlot(
    gClass,
    GObjectVtable.getProperty,
    _getPropertyCallable.nativeFunction.address,
  );

  final classWrapper = GObjectClass.fromPointer(gClass);
  // The property ids are unique inside the class. A derived class starts
  // with an empty set of them — GObject's base initializer resets the
  // list — so the first id is 1.
  var propertyId = classWrapper.listProperties().$2 + 1;
  final installed = <int, _InstalledProperty>{};

  for (final entry in properties.entries) {
    final pspec = _createParamSpec(entry.key, entry.value);
    classWrapper.installProperty(propertyId, pspec);
    installed[propertyId] = _InstalledProperty(entry.value, pspec);
    propertyId++;
  }
  _installed[type] = installed;
}

/// The property [name] of the type [type], when the type declares one.
_InstalledProperty? _propertyByName(int type, String name) {
  final properties = _installed[type];
  if (properties == null) return null;
  for (final installed in properties.values) {
    if (installed.pspec.getName() == name) return installed;
  }
  return null;
}

/// The `GParamSpec` of the property [name] on the type [type], when the
/// type declares it.
GParamSpec? dartPropertySpec(int type, String name) =>
    _propertyByName(type, name)?.pspec;

/// The `GType` of the values the property [name] of the type [type]
/// carries, when the type declares it.
int? dartPropertyValueType(int type, String name) {
  final installed = _propertyByName(type, name);
  if (installed == null) return null;
  return gTypeOfProperty(installed.declaration.kind);
}

/// Reads the property [name] of [instance].
///
/// The call goes through the native property machinery: GObject looks
/// the property up, calls the type's `get_property` vfunc, and the Dart
/// getter fills the value.
Object? getDartProperty(GObject instance, String name) {
  final type = typeOfInstance(instance.handle);
  final installed = _propertyByName(type, name);
  if (installed == null) {
    throw StateError(
      'dart_gobject: the type `${typeName(type) ?? '<unknown>'}` has no '
      'property named `$name`.',
    );
  }
  final value = calloc<ffi.Uint8>(gValueSize);
  try {
    valueInit(
      value.cast<ffi.Void>(),
      gTypeOfProperty(installed.declaration.kind),
    );
    objectGetProperty(instance.handle, name, value.cast<ffi.Void>());
    return _readValue(installed.declaration.kind, value.cast<ffi.Void>());
  } finally {
    valueUnset(value.cast<ffi.Void>());
    calloc.free(value);
  }
}

/// Writes the property [name] of [instance].
///
/// The call goes through the native property machinery: GObject looks
/// the property up, calls the type's `set_property` vfunc, and the Dart
/// setter receives the value.
void setDartProperty(GObject instance, String name, Object? value) {
  final type = typeOfInstance(instance.handle);
  final installed = _propertyByName(type, name);
  if (installed == null) {
    throw StateError(
      'dart_gobject: the type `${typeName(type) ?? '<unknown>'}` has no '
      'property named `$name`.',
    );
  }
  final slot = calloc<ffi.Uint8>(gValueSize);
  try {
    valueInit(
      slot.cast<ffi.Void>(),
      gTypeOfProperty(installed.declaration.kind),
    );
    _writeValue(installed.declaration.kind, slot.cast<ffi.Void>(), value);
    objectSetProperty(instance.handle, name, slot.cast<ffi.Void>());
  } finally {
    valueUnset(slot.cast<ffi.Void>());
    calloc.free(slot);
  }
}
