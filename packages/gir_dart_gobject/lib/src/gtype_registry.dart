import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:gir_gobject/gir_gobject.dart';

import 'properties.dart';
import 'signals.dart';
import 'objects.dart';
import 'vtable.dart';

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

/// What a type declares while its class is being initialized.
class _Declaration {
  _Declaration(this.signals, this.properties, this.interfaces, this.overrides);

  /// The signals the type declares.
  final Map<String, DartSignal> signals;

  /// The properties the type declares.
  final Map<String, DartProperty> properties;

  /// The interfaces the type implements.
  final List<int> interfaces;

  /// The virtual functions the type overrides.
  final List<VfuncOverride> overrides;
}

/// The declarations waiting for their class to be initialized, by the id
/// the class initializer carries.
final Map<int, _Declaration> _pending = <int, _Declaration>{};

int _nextDeclarationId = 1;

/// The permanent class initializer.
///
/// GLib calls it once per type, with the type's own class struct — the
/// place where a native class creates its signals and installs its
/// properties. The trampoline must never be closed: the class lives for
/// as long as its type does.
final Pointer<NativeFunction<Void Function(Pointer<Void>, Pointer<Void>)>>
_classInitTrampoline =
    Pointer.fromFunction<Void Function(Pointer<Void>, Pointer<Void>)>(
      _classInitBridge,
    );

void _classInitBridge(Pointer<Void> gClass, Pointer<Void> classData) {
  final id = classData.cast<IntPtr>().value;
  final declaration = _pending.remove(id);
  if (declaration == null) return;
  // The class struct carries its own `GType`, and GLib sets it before it
  // calls the initializer.
  final type = typeOfClass(gClass);
  installDartSignals(type, declaration.signals);
  installDartProperties(type, gClass, declaration.properties);
  installVfuncOverrides(type, gClass, declaration.overrides);
}

/// Adds the interface [interfaceType] to the type [type].
///
/// The interface must not have methods: an interface with methods needs
/// the offsets of its vtable, and the introspection data does not carry
/// them. An interface without methods — a marker interface — works.
///
/// The call belongs before the class is initialized: GLib refuses an
/// interface that is added to a class whose class struct is already
/// there, and the class struct is allocated when the class is
/// initialized.
void addDartInterface(int type, int interfaceType) {
  final info = calloc<GInterfaceInfo>();
  try {
    typeAddInterfaceStatic(type, interfaceType, info.ref);
  } finally {
    calloc.free(info);
  }
}

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
/// With [signals] and [properties] the type also declares them
/// natively — see [DartSignal] and [DartProperty]. The declarations are
/// installed while the type's class is initialized, the way a native
/// class declares its own:
///
/// ```dart
/// class TaskObject extends DartGObject {
///   static int get GType => registerDartType(
///     'TaskObject',
///     GObject.GType,
///     signals: {
///       'completed': DartSignal.withoutArgument((self) {
///         // runs when the signal is emitted
///       }),
///     },
///     properties: {
///       'content': DartProperty.string(
///         getter: (self) => (self! as TaskObject).content,
///         setter: (self, value) => (self! as TaskObject).content = value!,
///       ),
///     },
///   );
/// }
/// ```
///
/// With [vfuncs] the type also gets GObject's virtual functions wired to
/// Dart — see [installGObjectVfuncs]. That is opt-in because a type with
/// Dart callbacks must not be finalized while the isolate shuts down:
/// GObject would call back into a VM that is already tearing itself down,
/// and the VM aborts. A type that opts in has to release its objects
/// before the isolate ends.
///
/// Calling this twice with the same [name] returns the type registered
/// first — the name is the type's identity in GLib, so it cannot be
/// registered twice.
///
/// Throws a [StateError] when GLib refuses the registration (for instance
/// because the name is already taken by a native type).
int registerDartType(
  String name,
  int parentType, {
  bool vfuncs = false,
  Map<String, DartSignal> signals = const {},
  Map<String, DartProperty> properties = const {},
  List<int> interfaces = const [],
  List<VfuncOverride> overrides = const [],
}) {
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
    if (signals.isNotEmpty ||
        properties.isNotEmpty ||
        interfaces.isNotEmpty ||
        overrides.isNotEmpty) {
      // The class initializer is where a native class creates its
      // signals and installs its properties. The declaration travels
      // with the type info, in `class_data`.
      final declarationId = _nextDeclarationId++;
      final declarationData = calloc<IntPtr>()..value = declarationId;
      _pending[declarationId] = _Declaration(
        signals,
        properties,
        interfaces,
        overrides,
      );
      info.ref
        ..class_init = _classInitTrampoline.cast<Void>()
        ..class_data = declarationData.cast<Void>();
      type = typeRegisterStatic(parentType, name, info.ref, GTypeFlags.none);
    } else {
      type = typeRegisterStatic(parentType, name, info.ref, GTypeFlags.none);
    }
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

  // The interfaces go on before the class is initialized: GLib refuses
  // an interface that is added to a class whose class struct is
  // already there.
  for (final interface in interfaces) {
    addDartInterface(type, interface);
  }

  if (signals.isNotEmpty ||
      properties.isNotEmpty ||
      interfaces.isNotEmpty ||
      overrides.isNotEmpty) {
    // The class has to be initialized before the signals and the
    // properties exist: `g_signal_lookup` finds a signal only after the
    // class was initialized, and GLib refuses a property that is
    // installed after the class was derived. The reference is kept, so
    // the class is initialized once and stays initialized.
    GTypeClass.ref(type);
  }

  // With `vfuncs`, GObject's virtual functions on this type must reach
  // the Dart object. The patch is installed right away — before the
  // first instance exists — so that even the `constructed` call of the
  // first instance is dispatched.
  if (vfuncs) installGObjectVfuncs(type);
  return type;
}

/// The `GType` registered under [name], or `null` when there is none.
///
/// Handy in tests and in diagnostics; the registration itself happens
/// through [registerDartType].
int? dartTypeOf(String name) => _registered[name];
