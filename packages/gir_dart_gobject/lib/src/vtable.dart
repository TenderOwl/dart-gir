import 'dart:ffi' as ffi;

import 'package:gir_gobject/gir_gobject.dart';

import 'dart_gobject.dart';
import 'objects.dart';

/// The byte offsets of `GObjectClass`'s virtual functions.
///
/// The class struct layout is **not** in the introspection data. The GIR
/// lists a class's virtual methods alphabetically, while the C class
/// struct declares them in the order the vtable uses — so the offset of
/// a slot cannot be derived from the GIR. The offsets are hand-authored
/// here and cross-checked against the installed header by
/// `vtable_layout_test.dart`, which skips when the header is not
/// installed.
///
/// The layout is the one of a 64-bit Linux build:
///
/// ```c
/// struct _GObjectClass {
///   GTypeClass   g_type_class;              //  0  { GType g_type; }
///   GSList      *construct_properties;      //  8
///   GObject*   (*constructor)         (...);// 16
///   void       (*set_property)        (...);// 24
///   void       (*get_property)        (...);// 32
///   void       (*dispose)             (...);// 40
///   void       (*finalize)            (...);// 48
///   void       (*dispatch_properties_changed) (...); // 56
///   void       (*notify)              (...);// 64
///   void       (*constructed)         (...);// 72
///   ...
/// };
/// ```
abstract final class GObjectVtable {
  /// The offset of `GObjectClass::constructed`.
  static const int constructed = 72;

  /// The offset of `GObjectClass::dispose`.
  static const int dispose = 40;

  /// The offset of `GObjectClass::finalize`.
  static const int finalize = 48;

  /// The offset of `GObjectClass::constructor`.
  static const int constructor = 16;

  /// The offset of `GObjectClass::set_property`.
  static const int setProperty = 24;

  /// The offset of `GObjectClass::get_property`.
  static const int getProperty = 32;

  /// The offset of `GObjectClass::dispatch_properties_changed`.
  static const int dispatchPropertiesChanged = 56;

  /// The offset of `GObjectClass::notify`.
  static const int notify = 64;
}

/// An override of a virtual function.
///
/// [offset] is the byte offset of the slot in the class struct, and
/// [address] the address of the native function that implements it.
///
/// The offsets are not in the introspection data — the class struct
/// layout is not — so they come from the runtime's own table of the
/// curated virtual functions.
class VfuncOverride {
  /// Creates an override of the slot at [offset], implemented by the
  /// native function at [address], with [handler] as the Dart
  /// implementation.
  const VfuncOverride(this.offset, this.address, this.handler);

  /// The byte offset of the slot in the class struct.
  final int offset;

  /// The address of the native function that implements the slot.
  final int address;

  /// The Dart implementation of the slot.
  final Object handler;
}

/// The Dart handler of a virtual function, by the type and the slot.
final Map<int, Map<int, Object>> _handlers = <int, Map<int, Object>>{};

/// The inherited implementation of a virtual function, by the type and
/// the slot.
///
/// The inherited implementation is kept so that the Dart override can
/// chain up to it — a `dispose` that forgot to release the parent's
/// resources would leak them.
final Map<int, Map<int, int>> _saved = <int, Map<int, int>>{};

/// The types whose virtual functions have been patched.
final Set<int> _patched = <int>{};

/// The addresses of the instances whose `constructed` call is still
/// waiting for its Dart object.
final Set<int> _pendingConstructed = <int>{};

/// The signature of a virtual function that takes only the instance.
typedef _Void = ffi.Void Function(ffi.Pointer<ffi.Void>);

/// The permanent trampolines.
///
/// GObject calls these for the life of the type, so they must never be
/// closed — a closed `NativeCallable` would leave a dangling C function
/// pointer.
final ffi.NativeCallable<_Void> _constructedCallable =
    ffi.NativeCallable<_Void>.isolateLocal(_constructedBridge);
final ffi.NativeCallable<_Void> _disposeCallable =
    ffi.NativeCallable<_Void>.isolateLocal(_disposeBridge);
final ffi.NativeCallable<_Void> _finalizeCallable =
    ffi.NativeCallable<_Void>.isolateLocal(_finalizeBridge);

/// Patches the virtual functions of [type] so that GObject calls into
/// Dart.
///
/// The inherited implementation of every patched slot is saved first, so
/// the Dart override can chain up to it — a `dispose` that forgot to
/// release the parent's resources would leak them.
///
/// Calling this twice for the same type does nothing the second time.
void installGObjectVfuncs(int type) {
  if (!_patched.add(type)) return;

  final classStruct = GTypeClass.ref(type);
  try {
    final vtable = classStruct.handle.cast<ffi.Void>();
    final saved = <int, int>{
      GObjectVtable.constructed: _take(vtable, GObjectVtable.constructed),
      GObjectVtable.dispose: _take(vtable, GObjectVtable.dispose),
      GObjectVtable.finalize: _take(vtable, GObjectVtable.finalize),
    };
    _saved[type] = saved;

    _put(vtable, GObjectVtable.constructed, _constructedCallable);
    _put(vtable, GObjectVtable.dispose, _disposeCallable);
    _put(vtable, GObjectVtable.finalize, _finalizeCallable);
  } finally {
    classStruct.unref();
  }
}

/// Installs the overrides [overrides] on the type [type].
///
/// The call belongs to the type's class initializer: GLib copies the
/// parent's class struct for the derived type, so writing the slots of
/// the *derived* class's copy affects the derived type alone.
void installVfuncOverrides(
  int type,
  ffi.Pointer<ffi.Void> gClass,
  List<VfuncOverride> overrides,
) {
  if (overrides.isEmpty) return;

  final vtable = gClass.cast<ffi.Void>();
  final saved = _saved.putIfAbsent(type, () => <int, int>{});

  for (final override in overrides) {
    saved[override.offset] = _take(vtable, override.offset);
    writeVtableSlot(vtable, override.offset, override.address);
    registerVfuncHandler(type, override.offset, override.handler);
  }
}

/// Registers [handler] as the Dart implementation of the slot at
/// [offset] for the type [type].
void registerVfuncHandler(int type, int offset, Object handler) {
  _handlers.putIfAbsent(type, () => <int, Object>{})[offset] = handler;
}

/// The Dart handler of the slot at [offset] for the type of [instance],
/// when there is one.
Object? vfuncHandler(ffi.Pointer<ffi.Void> instance, int offset) {
  final handlers = _handlers[typeOfInstance(instance)];
  if (handlers == null) return null;
  return handlers[offset];
}

/// The address of the inherited implementation of the slot at [offset],
/// when there is one.
int? inheritedVfunc(ffi.Pointer<ffi.Void> instance, int offset) {
  final saved = _saved[typeOfInstance(instance)];
  if (saved == null) return null;
  return saved[offset];
}

/// The address of the slot at [offset] in the class struct.
///
/// The class struct is read as an array of pointer-sized words: a
/// `Pointer<Void>` has no element type to step through, but the slots
/// are addresses either way.
int _take(ffi.Pointer<ffi.Void> vtable, int offset) =>
    (vtable.cast<ffi.UintPtr>() + (offset ~/ 8)).value;

/// Writes [trampoline] into the slot at [offset] in the class struct.
void _put(
  ffi.Pointer<ffi.Void> vtable,
  int offset,
  ffi.NativeCallable<_Void> trampoline,
) {
  (vtable.cast<ffi.UintPtr>() + (offset ~/ 8)).value =
      trampoline.nativeFunction.address;
}

/// Writes the function at [address] into the slot at [offset] in the
/// class struct.
///
/// The slot holds a plain C function pointer, so the signature of the
/// function is the caller's business — the class struct only stores the
/// address.
void writeVtableSlot(ffi.Pointer<ffi.Void> vtable, int offset, int address) {
  (vtable.cast<ffi.UintPtr>() + (offset ~/ 8)).value = address;
}

/// The Dart object behind the instance at [object], when there is one.
///
/// An address that was freed and handed out again holds the wrapper of
/// the *old* object next to the wrapper of the new one. The newest
/// registration is the live one — the cache keeps them in the order they
/// were registered.
DartGObject? _dartObject(ffi.Pointer<ffi.Void> object) =>
    dartGObjectFor(object);

void _constructedBridge(ffi.Pointer<ffi.Void> object) {
  // GObject calls `constructed` from `g_object_new` — before the Dart
  // wrapper exists. The call is therefore recorded and delivered by
  // `DartGObject`'s constructor, which runs once the wrapper is there.
  _pendingConstructed.add(object.address);
  _chainUp(object, GObjectVtable.constructed);
}

void _disposeBridge(ffi.Pointer<ffi.Void> object) {
  // The Dart override runs first: it may still use the object, and the
  // inherited implementation is what releases the parent's resources.
  _dartObject(object)?.dartDispose();
  _chainUp(object, GObjectVtable.dispose);
}

void _finalizeBridge(ffi.Pointer<ffi.Void> object) {
  // The object is gone: a `constructed` call that was never delivered
  // must not keep its address alive.
  _pendingConstructed.remove(object.address);
  _dartObject(object)?.dartFinalize();
  _chainUp(object, GObjectVtable.finalize);
}

/// Calls the inherited implementation of the slot [offset], when there
/// is one.
void _chainUp(ffi.Pointer<ffi.Void> object, int offset) {
  final address = inheritedVfunc(object, offset);
  if (address == null || address == 0) return;
  ffi.Pointer<ffi.NativeFunction<_Void>>.fromAddress(address)
      .asFunction<void Function(ffi.Pointer<ffi.Void>)>()(object);
}

/// Delivers a `constructed` call that was waiting for [instance].
///
/// Returns `true` when the call was pending.
bool deliverPendingConstructed(DartGObject instance) {
  if (!_pendingConstructed.remove(instance.handle.address)) return false;
  instance.dartConstructed();
  return true;
}
