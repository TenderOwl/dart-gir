// Ownership transfer: the reference the GIR hands over belongs to the
// wrapper, and the wrapper releases it exactly once.
//
// The observable is *when the native object dies*. `g_object_add_weak_pointer`
// is marked `introspectable="0"` in the GIR — the bindings deliberately do not
// expose it — so the test looks the symbol up itself. The caller fills the
// slot with the object pointer; GLib sets it to NULL when the object is
// finalized, which is exactly the moment the wrapper's finalizer released the
// reference.
//
// The second observable is the `owned` flag: it says whether the wrapper
// still holds the reference.
//
// Run with:
//   dart test test/ownership_test.dart

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gobject/gobject.dart';
import 'package:test/test.dart';

/// `g_object_add_weak_pointer(GObject *object, gpointer *location)` — the
/// location is set to NULL when the object is finalized.
final _addWeakPointer =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
          >
        >('g_object_add_weak_pointer')
        .asFunction<
          void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
        >();

/// `g_object_remove_weak_pointer(GObject *object, gpointer *location)` — the
/// counterpart, so the test can drop the registration before it frees the
/// slot.
final _removeWeakPointer =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
          >
        >('g_object_remove_weak_pointer')
        .asFunction<
          void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
        >();

/// `g_object_newv(GType type, guint n_construct_properties, ...)`.
final _gObjectNewv =
    gobjectLookup<
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

/// Keeps the garbage alive so the allocation is not optimized away.
final List<List<int>> _garbage = [];

/// Collects garbage until the native object behind [weak] is finalized.
///
/// The wrapper is released by the garbage collector, so the test has to make
/// the VM collect it: allocating garbage raises the pressure, and the
/// finalizer runs on the VM's finalizer thread right after the collection.
void _awaitFinalized(ffi.Pointer<ffi.Pointer<ffi.Void>> weak) {
  for (var i = 0; i < 500; i++) {
    if (weak.value == ffi.nullptr) return;
    _garbage
      ..clear()
      ..add(List<int>.filled(200000, 0));
    sleep(const Duration(milliseconds: 2));
  }
  fail('the native object was not released');
}

/// Collects garbage for a while without expecting the object to die.
void _collectGarbage() {
  for (var i = 0; i < 20; i++) {
    _garbage
      ..clear()
      ..add(List<int>.filled(200000, 0));
    sleep(const Duration(milliseconds: 2));
  }
}

/// A weak slot for [handle]: the caller fills it, GLib clears it when the
/// object is finalized.
ffi.Pointer<ffi.Pointer<ffi.Void>> _weakSlotFor(ffi.Pointer<ffi.Void> handle) {
  final weak = calloc<ffi.Pointer<ffi.Void>>()..value = handle;
  _addWeakPointer(handle, weak.cast<ffi.Void>());
  return weak;
}

void main() {
  group('GObject', () {
    test('a transfer-full return hands the reference to the wrapper', () {
      // `g_object_ref` returns a reference the caller owns: the GIR says
      // `transfer-ownership="full"`.
      final object = GObject(GObject.GType);
      final ref = object.ref();
      expect(ref.owned, isTrue);
      expect(ref.handle, object.handle);
    });

    test('a borrowed reference stays borrowed', () {
      // A handle the Dart side has never seen: the wrapper cache has no
      // entry for it, so `fromPointer` builds a fresh wrapper — one that
      // borrows the reference instead of owning it. The object is sunk
      // first: `g_object_newv` returns a floating reference, and a
      // floating object has no owner to keep it alive.
      final handle = _gObjectNewv(GObject.GType, 0, ffi.nullptr);
      gObjectRefSink(handle);
      final borrowed = GObject.fromPointer(handle);
      expect(borrowed.owned, isFalse);
      // The caller owns the reference — the wrapper must not release it.
      borrowed.unref();
    });

    test('the wrapper releases the reference it owns', () {
      // A wrapper the GIR handed a reference to — `GObject(int)` creates
      // the object and the wrapper owns it.
      GObject? object = GObject(GObject.GType);
      expect(object.owned, isTrue);
      final weak = _weakSlotFor(object.handle);

      // Drop the wrapper. Nothing else holds a reference, so the finalizer
      // releases it and the object is finalized.
      object = null;
      _awaitFinalized(weak);
      expect(weak.value, ffi.nullptr);
      calloc.free(weak);
    });

    test('a borrowed reference is not released by the wrapper', () {
      final handle = _gObjectNewv(GObject.GType, 0, ffi.nullptr);
      gObjectRefSink(handle);
      final borrowed = GObject.fromPointer(handle);
      final weak = _weakSlotFor(handle);
      expect(borrowed.owned, isFalse);

      // The caller still owns the reference: the object stays alive.
      _collectGarbage();
      expect(weak.value, isNot(ffi.nullptr));

      // Drop the registration before the slot goes away — the object is
      // still alive, so the weak pointer would otherwise be written to
      // freed memory when the process tears the object down.
      _removeWeakPointer(handle, weak.cast<ffi.Void>());
      calloc.free(weak);
      borrowed.unref();
    });
  });
}
