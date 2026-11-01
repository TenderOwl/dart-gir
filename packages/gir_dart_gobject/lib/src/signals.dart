import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_gobject/gir_gobject.dart';

import 'native.dart';
import 'objects.dart';

/// The kind of value a Dart-defined signal's argument carries.
///
/// The kind decides the `GType` the signal declares and how the native
/// marshaller hands the argument to Dart.
enum DartSignalArgument {
  /// A `gint` — an `int` in Dart.
  integer,

  /// A `gboolean` — a `bool` in Dart.
  boolean,

  /// A `gdouble` — a `double` in Dart.
  real,

  /// A `gchar*` — a `String?` in Dart.
  string,

  /// A `GObject*` — a `GObject?` in Dart.
  object,
}

/// The `GType` of the argument of kind [kind].
int gTypeOfArgument(DartSignalArgument kind) {
  switch (kind) {
    case DartSignalArgument.integer:
      return gTypeInt;
    case DartSignalArgument.boolean:
      return gTypeBoolean;
    case DartSignalArgument.real:
      return gTypeDouble;
    case DartSignalArgument.string:
      return gTypeString;
    case DartSignalArgument.object:
      return gTypeObject;
  }
}

/// The Dart handler of a signal declared on a Dart type.
///
/// The handler receives the Dart object that emitted the signal — or
/// `null` when the instance has no Dart wrapper — and the signal's
/// arguments, in the order they were declared.
typedef DartSignalHandler = void Function(Object?, List<Object?>);

/// Adapts a handler that only needs the emitting instance.
///
/// A function literal cannot be written straight into an initializer
/// list — the parser reads it as a record — so the adaptation lives in
/// a function of its own.
DartSignalHandler _withoutArgument(void Function(Object?) callback) =>
    (self, _) => callback(self);

/// Adapts a handler that takes the emitting instance and the signal's
/// one argument.
DartSignalHandler _withArgument(void Function(Object?, Object?) callback) =>
    (self, args) => callback(self, args.isEmpty ? null : args.first);

/// A signal declared on a Dart type.
///
/// The signal exists natively: it is created with `g_signal_newv` while
/// the type's class is initialized, so `g_signal_lookup` finds it, native
/// code can emit it, and the bindings' signal helpers can connect to it
/// like any other signal.
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
///   );
/// }
/// ```
class DartSignal {
  /// A signal without an argument.
  ///
  /// The handler receives the Dart object that emitted the signal.
  DartSignal.withoutArgument(void Function(Object?) callback)
    : handler = _withoutArgument(callback),
      argument = null;

  /// A signal with one argument of kind [kind].
  ///
  /// The handler receives the Dart object that emitted the signal and
  /// the argument.
  DartSignal.withArgument(
    DartSignalArgument kind,
    void Function(Object?, Object?) callback,
  ) : handler = _withArgument(callback),
      argument = kind;

  /// The Dart handler of the signal.
  final DartSignalHandler handler;

  /// The kind of the signal's argument, or `null` when the signal has
  /// none.
  final DartSignalArgument? argument;
}

/// The signal a class closure dispatches to.
class _InstalledSignal {
  _InstalledSignal(this.type, this.signal);

  /// The type the signal belongs to.
  final int type;

  /// The Dart declaration of the signal.
  final DartSignal signal;
}

/// The signals installed on a type, by the id of the installation.
///
/// The class closure's user data is a pointer to an entry of this map,
/// so the trampoline knows which Dart handler to run.
final Map<int, _InstalledSignal> _installed = <int, _InstalledSignal>{};

int _nextInstallationId = 1;

/// The signals a type declares, by the type's id.
final Map<int, Map<String, DartSignal>> _signalsByType =
    <int, Map<String, DartSignal>>{};

/// The id of the signal [name] on [type], or `0` when the type has no
/// such signal.
int? dartSignalId(int type, String name) {
  final signals = _signalsByType[type];
  if (signals == null || !signals.containsKey(name)) return null;
  return signalLookup(name, type);
}

/// The signatures the class closure's callback can have.
///
/// The generic marshaller calls the callback with the instance, the
/// signal's argument in its native shape, and the closure's user data.
typedef _NoArgument = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);
typedef _IntegerArgument = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Pointer<ffi.Void>,
);
typedef _RealArgument = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Double,
  ffi.Pointer<ffi.Void>,
);
typedef _PointerArgument = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);

/// The permanent trampolines.
///
/// A class closure lives for as long as its type does, so its callback
/// must never be closed — a closed `NativeCallable` would leave a
/// dangling C function pointer.
final ffi.NativeCallable<_NoArgument> _noArgumentCallable =
    ffi.NativeCallable<_NoArgument>.isolateLocal(_noArgumentBridge);
final ffi.NativeCallable<_IntegerArgument> _integerArgumentCallable =
    ffi.NativeCallable<_IntegerArgument>.isolateLocal(_integerArgumentBridge);
final ffi.NativeCallable<_RealArgument> _realArgumentCallable =
    ffi.NativeCallable<_RealArgument>.isolateLocal(_realArgumentBridge);
final ffi.NativeCallable<_PointerArgument> _pointerArgumentCallable =
    ffi.NativeCallable<_PointerArgument>.isolateLocal(_pointerArgumentBridge);

/// The destroy notify of a connected handler.
///
/// The handler is destroyed when the object it is connected to goes away;
/// the user data is freed and the Dart callback released then.
typedef _DestroyNotify = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);

void _noArgumentBridge(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
) {
  _dispatch(instance, userData, const <Object?>[]);
}

void _integerArgumentBridge(
  ffi.Pointer<ffi.Void> instance,
  int value,
  ffi.Pointer<ffi.Void> userData,
) {
  _dispatch(instance, userData, <Object?>[value]);
}

void _realArgumentBridge(
  ffi.Pointer<ffi.Void> instance,
  double value,
  ffi.Pointer<ffi.Void> userData,
) {
  _dispatch(instance, userData, <Object?>[value]);
}

void _pointerArgumentBridge(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> value,
  ffi.Pointer<ffi.Void> userData,
) {
  _dispatch(instance, userData, <Object?>[value]);
}

/// Runs the Dart handler of the signal the class closure belongs to.
///
/// The user data of a class closure *is* the installation id — it is
/// passed back as the pointer value, not as a pointer to the id.
void _dispatch(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
  List<Object?> args,
) {
  final id = userData.address;
  final installed = _installed[id];
  if (installed == null) return;
  installed.signal.handler(dartObjectFor(instance), args);
}

/// The address of the class closure's callback for a signal with the
/// given [argument] kind.
int _callbackAddress(DartSignalArgument? argument) {
  switch (argument) {
    case null:
      return _noArgumentCallable.nativeFunction.address;
    case DartSignalArgument.integer:
    case DartSignalArgument.boolean:
      return _integerArgumentCallable.nativeFunction.address;
    case DartSignalArgument.real:
      return _realArgumentCallable.nativeFunction.address;
    case DartSignalArgument.string:
    case DartSignalArgument.object:
      return _pointerArgumentCallable.nativeFunction.address;
  }
}

/// Installs the signals [signals] on the type [type].
///
/// The call belongs to the type's class initializer: GLib refuses a
/// property that is installed after the class was derived, and a signal
/// that is created after the class was derived would not be inherited
/// the way a native one is.
void installDartSignals(int type, Map<String, DartSignal> signals) {
  if (signals.isEmpty) return;
  _signalsByType[type] = Map<String, DartSignal>.of(signals);

  for (final entry in signals.entries) {
    final installationId = _nextInstallationId++;
    _installed[installationId] = _InstalledSignal(type, entry.value);

    // The user data is the installation id itself: GLib only hands it
    // back to the callback, it never dereferences it. That keeps the
    // closure free of an allocation that would have to be freed — and
    // the closure lives until the process ends, so a destroy notify
    // would be a Dart callback at shutdown, which the VM refuses to
    // run.
    final userData = ffi.Pointer<ffi.Void>.fromAddress(installationId);

    final closure = cclosureNew(
      _callbackAddress(entry.value.argument),
      userData,
      ffi.nullptr,
    );

    final parameterTypes = calloc<ffi.Size>(
      entry.value.argument == null ? 0 : 1,
    );
    try {
      if (entry.value.argument != null) {
        parameterTypes[0] = gTypeOfArgument(entry.value.argument!);
      }
      final signalId = signalNewv(
        entry.key,
        type,
        GSignalFlags.runLast.value,
        closure,
        ffi.Pointer.fromAddress(genericMarshallerAddress),
        gTypeNone,
        parameterTypes,
        entry.value.argument == null ? 0 : 1,
      );
      if (signalId == 0) {
        _installed.remove(installationId);
      }
    } finally {
      calloc.free(parameterTypes);
      // The signal system took the closure's reference over: it sinks
      // the closure, which consumes the caller's initial reference.
      // Releasing it here would leave the signal with a dangling
      // closure.
    }
  }
}

/// Emits the signal [name] on [instance].
///
/// The signal must be one the type declares — see [dartSignalId]. The
/// [argument] is the signal's one argument, when it has one.
void emitDartSignal(GObject instance, String name, [Object? argument]) {
  final type = typeOfInstance(instance.handle);
  final signalId = signalLookup(name, type);
  if (signalId == 0) {
    throw StateError(
      'dart_gobject: the type `${typeName(type) ?? '<unknown>'}` has no '
      'signal named `$name`.',
    );
  }
  final signals = _signalsByType[type];
  final declaration = signals?[name];
  final argumentKind = declaration?.argument;

  final count = argumentKind == null ? 1 : 2;
  final values = calloc<ffi.Uint8>(gValueSize * count);
  try {
    final instanceValue = values.cast<ffi.Void>();
    valueInit(instanceValue, gTypeObject);
    valueSetObject(instanceValue, instance.handle);

    if (argumentKind != null) {
      final argumentValue = (values + gValueSize).cast<ffi.Void>();
      valueInit(argumentValue, gTypeOfArgument(argumentKind));
      switch (argumentKind) {
        case DartSignalArgument.integer:
          valueSetInt(argumentValue, argument is int ? argument : 0);
        case DartSignalArgument.boolean:
          valueSetBoolean(argumentValue, argument == true);
        case DartSignalArgument.real:
          valueSetDouble(
            argumentValue,
            argument is num ? argument.toDouble() : 0,
          );
        case DartSignalArgument.string:
          final text = argument as String?;
          if (text == null) {
            valueSetString(argumentValue, ffi.nullptr.cast<Utf8>());
          } else {
            final native = text.toNativeUtf8();
            try {
              valueSetString(argumentValue, native.cast<Utf8>());
            } finally {
              calloc.free(native);
            }
          }
        case DartSignalArgument.object:
          final object = argument;
          valueSetObject(
            argumentValue,
            object is GObject ? object.handle : ffi.nullptr,
          );
      }
    }

    signalEmitv(values.cast<ffi.Void>(), signalId, ffi.nullptr);
  } finally {
    for (var i = 0; i < count; i++) {
      valueUnset((values + i * gValueSize).cast<ffi.Void>());
    }
    calloc.free(values);
  }
}

/// A handler connected to a signal.
class _Connected {
  _Connected(this.callback, this.argument);

  /// The Dart callback.
  final void Function(Object?, List<Object?>) callback;

  /// The kind of the signal's argument, when it has one.
  final DartSignalArgument? argument;
}

/// The connected handlers, by the id the connection carries.
final Map<int, _Connected> _connected = <int, _Connected>{};

int _nextConnectedId = 1;

/// The permanent trampolines of the connected handlers.
///
/// A connection lives as long as the object it is connected to, so the
/// trampoline must never be closed — a closed `NativeCallable` would
/// leave a dangling C function pointer.
final ffi.NativeCallable<_NoArgument> _connectedNoArgumentCallable =
    ffi.NativeCallable<_NoArgument>.isolateLocal(_connectedNoArgumentBridge);
final ffi.NativeCallable<_IntegerArgument> _connectedIntegerCallable =
    ffi.NativeCallable<_IntegerArgument>.isolateLocal(_connectedIntegerBridge);
final ffi.NativeCallable<_RealArgument> _connectedRealCallable =
    ffi.NativeCallable<_RealArgument>.isolateLocal(_connectedRealBridge);
final ffi.NativeCallable<_PointerArgument> _connectedPointerCallable =
    ffi.NativeCallable<_PointerArgument>.isolateLocal(_connectedPointerBridge);

final ffi.NativeCallable<_DestroyNotify> _connectedDestroyCallable =
    ffi.NativeCallable<_DestroyNotify>.isolateLocal(_connectedDestroyBridge);

void _connectedNoArgumentBridge(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
) {
  final connected = _connected[userData.cast<ffi.IntPtr>().value];
  if (connected == null) return;
  connected.callback(dartObjectFor(instance), const <Object?>[]);
}

void _connectedIntegerBridge(
  ffi.Pointer<ffi.Void> instance,
  int value,
  ffi.Pointer<ffi.Void> userData,
) {
  final connected = _connected[userData.cast<ffi.IntPtr>().value];
  if (connected == null) return;
  connected.callback(dartObjectFor(instance), <Object?>[value]);
}

void _connectedRealBridge(
  ffi.Pointer<ffi.Void> instance,
  double value,
  ffi.Pointer<ffi.Void> userData,
) {
  final connected = _connected[userData.cast<ffi.IntPtr>().value];
  if (connected == null) return;
  connected.callback(dartObjectFor(instance), <Object?>[value]);
}

void _connectedPointerBridge(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> value,
  ffi.Pointer<ffi.Void> userData,
) {
  final connected = _connected[userData.cast<ffi.IntPtr>().value];
  if (connected == null) return;
  connected.callback(dartObjectFor(instance), <Object?>[value]);
}

void _connectedDestroyBridge(
  ffi.Pointer<ffi.Void> userData,
  ffi.Pointer<ffi.Void> closure,
) {
  final id = userData.cast<ffi.IntPtr>().value;
  calloc.free(userData);
  _connected.remove(id);
}

/// Connects [callback] to the signal [name] on [instance].
///
/// The callback receives the Dart object that emitted the signal and the
/// signal's arguments. Only a signal the type declares can be connected
/// this way: the shape of the callback has to match the signal's, and
/// the runtime knows the shape of the signals it declared itself. A
/// signal the GIR declares is connected with the generated package's own
/// helper — `onNotify` and the typed `onSignalName` methods.
///
/// Returns the handler id, which `g_signal_handler_disconnect` takes.
int connectDartSignal(
  GObject instance,
  String name,
  void Function(Object?, List<Object?>) callback,
) {
  final type = typeOfInstance(instance.handle);
  final declaration = _signalsByType[type]?[name];
  if (declaration == null) {
    throw StateError(
      'dart_gobject: the type `${typeName(type) ?? '<unknown>'}` declares no '
      'signal named `$name`. A signal of another type is connected with '
      "the package's own signal helper.",
    );
  }
  final argument = declaration.argument;

  final id = _nextConnectedId++;
  _connected[id] = _Connected(callback, argument);
  final userData = calloc<ffi.IntPtr>()..value = id;

  final int address;
  switch (argument) {
    case null:
      address = _connectedNoArgumentCallable.nativeFunction.address;
    case DartSignalArgument.integer:
    case DartSignalArgument.boolean:
      address = _connectedIntegerCallable.nativeFunction.address;
    case DartSignalArgument.real:
      address = _connectedRealCallable.nativeFunction.address;
    case DartSignalArgument.string:
    case DartSignalArgument.object:
      address = _connectedPointerCallable.nativeFunction.address;
  }

  final handlerId = signalConnectData(
    instance.handle,
    name,
    address,
    userData.cast<ffi.Void>(),
    _connectedDestroyCallable.nativeFunction.cast<ffi.Void>(),
  );
  if (handlerId == 0) {
    calloc.free(userData);
    _connected.remove(id);
    throw StateError(
      'dart_gobject: could not connect to the signal `$name` — the object '
      'has no such signal.',
    );
  }
  return handlerId;
}
