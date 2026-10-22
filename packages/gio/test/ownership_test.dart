// Ownership transfer for interfaces.
//
// A GInterface is a GObject in C, so the wrapper that holds a reference the
// GIR handed over releases it with `g_object_unref` — exactly like a class.
//
// The observable is *when the native object dies*: `g_object_add_weak_pointer`
// is marked `introspectable="0"` in the GIR — the bindings deliberately do
// not expose it — so the test looks the symbol up itself. The caller fills
// the slot with the object pointer; GLib sets it to NULL when the object is
// finalized.
//
// Run with:
//   dart test test/ownership_test.dart

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gio/gio.dart';
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

/// Keeps the garbage alive so the allocation is not optimized away.
final List<List<int>> _garbage = [];

/// `g_object_ref(GObject *object)` — the extra reference the surplus test
/// hands over.
final _gObjectRef =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
          >
        >('g_object_ref')
        .asFunction<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>();

/// Collects garbage until the native object behind [weak] is finalized.
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

void main() {
  group('interfaces', () {
    test('an interface owns the reference the GIR hands over', () {
      // `g_file_new_for_path` is `transfer-ownership="full"`.
      final file = GFile.newForPath('/tmp/gio-ownership-test');
      expect(file.owned, isTrue);
    });

    test('the interface wrapper releases the reference it owns', () {
      GFile? file = GFile.newForPath('/tmp/gio-ownership-test');
      final weak = calloc<ffi.Pointer<ffi.Void>>()..value = file.handle;
      _addWeakPointer(file.handle, weak.cast<ffi.Void>());

      // Drop the wrapper: the finalizer releases the reference and the
      // object is finalized.
      file = null;
      _awaitFinalized(weak);
      expect(weak.value, ffi.nullptr);
      calloc.free(weak);
    });

    test(
      'a surplus reference is released when the cache holds the pointer',
      () {
        GFile? file = GFile.newForPath('/tmp/gio-ownership-test');
        final weak = calloc<ffi.Pointer<ffi.Void>>()..value = file.handle;
        _addWeakPointer(file.handle, weak.cast<ffi.Void>());

        // A second `transfer-ownership="full"` handover of the same pointer:
        // the wrapper cache returns the existing wrapper, and the surplus
        // reference is released — otherwise the object would outlive the
        // wrapper by one reference.
        _gObjectRef(file.handle);
        expect(
          identical(GFile.fromPointer(file.handle, owned: true), file),
          isTrue,
        );

        // Drop the wrapper: the finalizer releases the last reference and
        // the object is finalized.
        file = null;
        _awaitFinalized(weak);
        expect(weak.value, ffi.nullptr);
        calloc.free(weak);
      },
    );
  });
}
