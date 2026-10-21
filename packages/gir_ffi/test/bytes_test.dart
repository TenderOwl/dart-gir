// Unit test for `bytesFromNative`, the helper that copies a
// callee-allocated byte buffer into a Dart `Uint8List` and releases the
// native buffer.
//
// The buffer a GLib function hands over (`g_file_load_contents`'
// `contents`) is native memory the garbage collector cannot see, and the
// GIR gives it to the caller with `transfer-ownership="full"` — so the
// caller owns it and has to release it. `bytesFromNative` does both:
// copy, then free.
//
// The buffer here is allocated with `dart:ffi`'s `calloc`, which uses the
// same system allocator as GLib's `g_malloc`, so `g_free` releases it
// correctly. The pairing of `g_malloc` with `g_free` itself is covered
// by `packages/glib/test/glib_smoke_test.dart`.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('bytesFromNative', () {
    test('copies the bytes into a Dart list', () {
      final buffer = calloc<ffi.Uint8>(5);
      buffer[0] = 0x68; // 'h'
      buffer[1] = 0x65; // 'e'
      buffer[2] = 0x6c; // 'l'
      buffer[3] = 0x6c; // 'l'
      buffer[4] = 0x6f; // 'o'

      final bytes = bytesFromNative(buffer, 5);

      expect(bytes, hasLength(5));
      expect(bytes, orderedEquals([0x68, 0x65, 0x6c, 0x6c, 0x6f]));
    });

    test('copies exactly `length` bytes, not the whole allocation', () {
      final buffer = calloc<ffi.Uint8>(4);
      buffer[0] = 1;
      buffer[1] = 2;
      buffer[2] = 3;
      buffer[3] = 4;

      final bytes = bytesFromNative(buffer, 2);

      expect(bytes, orderedEquals([1, 2]));
    });

    test('a null buffer yields an empty list', () {
      expect(bytesFromNative(ffi.nullptr, 0), isEmpty);
    });

    test('a zero length yields an empty list', () {
      final buffer = calloc<ffi.Uint8>(1);
      expect(bytesFromNative(buffer, 0), isEmpty);
    });

    test('the returned list is independent of the native buffer', () {
      final buffer = calloc<ffi.Uint8>(2);
      buffer[0] = 7;
      buffer[1] = 8;

      final bytes = bytesFromNative(buffer, 2);

      // The native buffer is released by the call, so the Dart list has
      // to be the only owner of the values.
      expect(bytes[0], 7);
      expect(bytes[1], 8);
      expect(bytes, isA<List<int>>());
    });
  });
}
