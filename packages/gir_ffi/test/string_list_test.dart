// The string-list marshalling.
//
// `withNativeStringList` marshals a `List<String?>?` *into* a C
// `char **`; `stringListFromNative` reads one back *out* of it. The
// two directions have one thing in common: the ownership.
//
// A C string array is a NULL-terminated array of pointers, so the
// first NULL ends it — an interior NULL truncates the list, exactly as
// it truncates the array for the C side.
//
// The *release* is the other half: GLib hands a `char **` over in two
// flavours. A static table (`g_get_language_names`) stays GLib's; an
// allocated array (`g_get_environ`) is the caller's to release, with
// `g_strfreev` — which frees the array *and* its strings.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:test/test.dart';

/// `g_strdupv` — copies a NULL-terminated string array with GLib's own
/// allocator. The copy is what `g_strfreev` releases, so it is the
/// cheapest way to get an array the `free: true` path may release.
final _gStrdupv = () {
  final name = Platform.isWindows
      ? 'libglib-2.0-0.dll'
      : Platform.isMacOS
      ? 'libglib-2.0.0.dylib'
      : 'libglib-2.0.so.0';
  return DynamicLibrary.open(name).lookup<
    NativeFunction<Pointer<Pointer<Utf8>> Function(Pointer<Pointer<Utf8>>)>
  >('g_strdupv');
}();

void main() {
  test('a NULL array is a Dart null', () {
    expect(stringListFromNative(nullptr), isNull);
  });

  test('reads the strings of a NULL-terminated array', () {
    final result = withNativeStringList(['alpha', 'beta'], (argv) {
      return stringListFromNative(argv);
    });

    expect(result, ['alpha', 'beta']);
  });

  test('an empty array is an empty list', () {
    final result = withNativeStringList(<String?>[], (argv) {
      return stringListFromNative(argv);
    });

    expect(result, isEmpty);
  });

  test('the first NULL ends the array', () {
    final result = withNativeStringList(<String?>['alpha', null, 'beta'], (
      argv,
    ) {
      return stringListFromNative(argv);
    });

    expect(result, ['alpha']);
  });

  test('releases a GLib-allocated array when asked to', () {
    final result = withNativeStringList(['alpha', 'beta'], (argv) {
      // The copy is GLib's own allocation — `g_strfreev` is the
      // deallocator that goes with it.
      final copy = _gStrdupv
          .asFunction<
            Pointer<Pointer<Utf8>> Function(Pointer<Pointer<Utf8>>)
          >()(argv);
      return stringListFromNative(copy, free: true);
    });

    expect(result, ['alpha', 'beta']);
  });
}
