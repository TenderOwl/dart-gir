// Headless smoke test for `withNativeStringList`, the helper that
// marshals a nullable `List<String?>` to a NULL-terminated
// `Pointer<Pointer<Utf8>>` for argv-style FFI calls. Mirrors the
// contract `g_application_run`, `g_spawn_*`, and friends expect: the
// callee reads `argv[0..argc-1]` plus a trailing NULL slot.
//
// Run with:
//   dart test test/strv_test.dart

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('withNativeStringList', () {
    test('null input leaves argv as NULL and frees nothing', () {
      ffi.Pointer<ffi.Pointer<Utf8>>? receivedArgv;
      final result = withNativeStringList<int?>(null, (argv) {
        expect(argv, equals(ffi.nullptr));
        receivedArgv = argv;
        return 42;
      });
      expect(result, 42);
      expect(receivedArgv, equals(ffi.nullptr));
      // The helper short-circuited; no allocation happened.
    });

    test('empty list allocates {NULL} (argc=0, non-null argv)', () {
      withNativeStringList<void>(const <String?>[], (argv) {
        expect(argv, isNot(equals(ffi.nullptr)));
        expect(argv[0], equals(ffi.nullptr));
      });
    });

    test('populated list yields argc+1 slots with a NULL terminator', () {
      withNativeStringList<void>(<String?>['a', 'b', null, 'd'], (argv) {
        expect(argv, isNot(equals(ffi.nullptr)));
        expect(argv[0].cast<Utf8>().toDartString(), 'a');
        expect(argv[1].cast<Utf8>().toDartString(), 'b');
        expect(argv[2], equals(ffi.nullptr));
        expect(argv[3].cast<Utf8>().toDartString(), 'd');
        expect(argv[4], equals(ffi.nullptr));
      });
    });

    test('non-null elements survive past the body (no premature free)', () {
      withNativeStringList<void>(<String?>['one', 'two'], (argv) {
        // Touch each string — if any were freed early we'd crash here.
        expect(argv[0].cast<Utf8>().toDartString(), 'one');
        expect(argv[1].cast<Utf8>().toDartString(), 'two');
      });
    });

    test('body return value is propagated unchanged', () {
      final s = withNativeStringList<String>(<String?>[
        'hello',
      ], (argv) => argv[0].cast<Utf8>().toDartString());
      expect(s, 'hello');
    });
  });
}
