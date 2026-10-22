// Ownership transfer for boxed types.
//
// A boxed type — a GIR record that is not a GObject — is released with its
// *own* destructor (`g_bytes_unref`, `g_date_time_unref`, …), not with
// `g_object_unref`. The wrapper therefore carries a `NativeFinalizer` of its
// own, and the `owned` flag says whether it holds the reference the GIR
// handed over.
//
// The observable here is the claim itself. The *release* is observed
// end-to-end in the GObject and GIO suites, where a weak pointer can report
// when the native object dies.
//
// Run with:
//   dart test test/ownership_test.dart

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:glib/glib.dart';
import 'package:test/test.dart';

/// `g_bytes_new(const guint8 *data, gsize size)` — the bytes are copied, so
/// an empty buffer is enough to get a handle the Dart side has never seen.
final _gBytesNew =
    glibLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr)
          >
        >('g_bytes_new')
        .asFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, int)
        >();

void main() {
  group('boxed types', () {
    test('a boxed constructor owns the reference the GIR hands over', () {
      // `g_bytes_new` is `transfer-ownership="full"`: the caller owns the
      // new `GBytes`, so the wrapper owns it and releases it when it is
      // collected.
      final bytes = GBytes(Uint8List.fromList([1, 2, 3]));
      expect(bytes.owned, isTrue);
      expect(bytes.getSize(), 3);
    });

    test('a boxed type gets a finalizer of its own', () {
      // The destructor is the type's own — `g_date_time_unref`, not
      // `g_object_unref`.
      final when = GDateTime.nowUtc();
      expect(when.owned, isTrue);
      expect(GDateTime.dateTimeFinalizer, isNotNull);
    });

    test('a borrowed boxed reference stays borrowed', () {
      // A handle the Dart side has never seen: the wrapper cache has no
      // entry for it, so `fromPointer` builds a fresh wrapper — one that
      // borrows the reference instead of owning it.
      final handle = _gBytesNew(ffi.nullptr, 0);
      final borrowed = GBytes.fromPointer(handle);
      expect(borrowed.owned, isFalse);
      // The caller owns the reference — the wrapper must not release it.
      borrowed.unref();
    });

    test('the wrapper cache returns the same object for the same pointer', () {
      final bytes = GBytes(Uint8List.fromList([1, 2, 3]));
      final cached = GBytes.fromPointer(bytes.handle);
      expect(identical(cached, bytes), isTrue);
      expect(
        cached.owned,
        isTrue,
        reason: 'the cached wrapper keeps its claim',
      );
    });
  });

  group('ownership handover', () {
    test('a callee that takes the reference over gets it', () {
      // `g_error_new_literal` is `transfer-ownership="full"`: the caller
      // owns the new `GError`, so the wrapper owns it.
      final error = GError.literal(1, 42, 'boom');
      expect(error.owned, isTrue);

      // `g_propagate_error` takes the error over: the GIR says
      // `transfer-ownership="full"` for the parameter, so the callee owns
      // the reference from the call on — and hands it to the caller
      // through the out parameter.
      final propagated = propagateError(error);

      // The reference was *moved*, not duplicated: the same Dart object
      // holds it, and it is intact — a surplus release would have freed
      // the error and left the wrapper pointing at freed memory.
      expect(identical(propagated, error), isTrue);
      expect(propagated!.owned, isTrue);
      expect(propagated.matches(1, 42), isTrue);
    });
  });
}
