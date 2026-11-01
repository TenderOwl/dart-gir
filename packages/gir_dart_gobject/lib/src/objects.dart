import 'dart:ffi' as ffi;

import 'package:gir_ffi/gir_ffi.dart';

import 'dart_gobject.dart';

/// The `GType` of the instance at [object].
///
/// The instance's first field is the class pointer, and the class
/// struct's first field is the `GType`.
int typeOfInstance(ffi.Pointer<ffi.Void> object) {
  final classPtr = object.cast<ffi.Pointer<ffi.Void>>().value;
  return classPtr.cast<ffi.UintPtr>().value;
}

/// The `GType` of the class struct at [gClass].
///
/// A class struct starts with its own `GType` — unlike an instance,
/// which starts with a pointer to the class struct.
int typeOfClass(ffi.Pointer<ffi.Void> gClass) {
  return gClass.cast<ffi.UintPtr>().value;
}

/// The Dart object that wraps the instance at [object], when there is
/// one.
///
/// An address that was freed and handed out again holds the wrapper of
/// the *old* object next to the wrapper of the new one. The newest
/// registration is the live one — the cache keeps them in the order they
/// were registered.
///
/// A [DartGObject] wins over a plain `GObject` wrapper: the Dart-object
/// model reaches for the subclass, which is the one that carries the
/// user's state.
Object? dartObjectFor(ffi.Pointer<ffi.Void> object) {
  final candidates = cachedObjects<Object>(object.address);
  Object? newest;
  for (var i = candidates.length - 1; i >= 0; i--) {
    final candidate = candidates[i];
    if (candidate is DartGObject) return candidate;
    newest ??= candidate;
  }
  return newest;
}

/// The [DartGObject] that wraps the instance at [object], when there is
/// one.
DartGObject? dartGObjectFor(ffi.Pointer<ffi.Void> object) {
  final candidates = cachedObjects<Object>(object.address);
  for (var i = candidates.length - 1; i >= 0; i--) {
    final candidate = candidates[i];
    if (candidate is DartGObject) return candidate;
  }
  return null;
}
