import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:gobject/gobject.dart';

/// The GTypes this runtime has registered, by name.
///
/// `g_type_register_static` refuses to register a name twice, so the
/// registry is the single place that knows which names exist.
final Map<String, int> _registered = <String, int>{};

/// The GTypes registered through [registerDartType], by name.
///
/// The map is a copy: the registry itself is not mutable from the outside.
Map<String, int> get registeredDartTypes =>
    Map<String, int>.unmodifiable(_registered);

/// Registers a native type named [name], derived from [parentType], and
/// returns its `GType`.
///
/// The type adds no native fields beyond its parent's and installs no
/// properties or signals — it exists so that a Dart class has a *native*
/// identity:
///
/// * `GListStore` type-checks its items against it, natively;
/// * `typeNameFromInstance` can name an instance of it;
/// * `G_TYPE_CHECK_INSTANCE_TYPE` accepts an instance of it wherever the
///   parent type is accepted.
///
/// The Dart class then instantiates it with the generated
/// `GObject(int objectType)` constructor:
///
/// ```dart
/// class TaskObject extends GObject {
///   static int get GType => registerDartType('TaskObject', GObject.GType);
///
///   TaskObject() : super(GType);
/// }
/// ```
///
/// The static getter mirrors the `static int get GType` accessor the
/// generator emits for every GIR class, so a Dart subclass and a
/// generated one are interchangeable wherever a `GType` is expected.
///
///
/// Calling this twice with the same [name] returns the type registered
/// first — the name is the type's identity in GLib, so it cannot be
/// registered twice.
///
/// Throws a [StateError] when GLib refuses the registration (for instance
/// because the name is already taken by a native type).
int registerDartType(String name, int parentType) {
  final existing = _registered[name];
  if (existing != null) return existing;

  // The Dart type adds no native fields, so it inherits the parent's class
  // and instance sizes. `g_type_query` reports both.
  final query = typeQuery(parentType);

  // A struct lives in native memory: allocate it, fill it in, and hand the
  // generator a copy of it. `calloc` zeroes it, so the callback and the
  // data pointers start out NULL.
  final info = calloc<GTypeInfo>();
  late final int type;
  try {
    info.ref
      ..class_size = query.class_size
      ..instance_size = query.instance_size
      ..n_preallocs = 0;
    type = typeRegisterStatic(parentType, name, info.ref, GTypeFlags.none);
  } finally {
    calloc.free(info);
  }
  if (type == 0) {
    throw StateError(
      'dart_gobject: GLib refused to register the type `$name`. The name is '
      'probably taken by a native type already.',
    );
  }
  _registered[name] = type;
  return type;
}

/// The `GType` registered under [name], or `null` when there is none.
///
/// Handy in tests and in diagnostics; the registration itself happens
/// through [registerDartType].
int? dartTypeOf(String name) => _registered[name];
