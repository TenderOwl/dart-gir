import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:glib/glib.dart';
import 'package:test/test.dart';

// Top-level comparator used by the callback tests below. Must be top-level
// or static (Pointer.fromFunction rejects closures and instance methods).
int compareIntPtrs(
  ffi.Pointer<ffi.Void> a,
  ffi.Pointer<ffi.Void> b,
  ffi.Pointer<ffi.Void> userData,
) {
  // Reinterpret the void* as an int* and read the values.
  final ai = a.cast<ffi.IntPtr>().value;
  final bi = b.cast<ffi.IntPtr>().value;
  return ai.compareTo(bi);
}

void main() {
  test('g_get_user_name returns a non-empty string', () {
    expect(getUserName(), isNotEmpty);
  });

  test('g_get_home_dir returns an existing directory', () {
    final home = getHomeDir();
    expect(home, isNotEmpty);
    expect(Directory(home).existsSync(), isTrue);
  });

  test('g_utf8_strlen counts runes', () {
    expect(utf8Strlen('héllo', 6), 5); // max is in bytes
  });

  test('GlibException carries GError details', () {
    final e = GlibException('boom', code: 42, domain: 7);
    expect(e.message, 'boom');
    expect(e.toString(), contains('boom'));
  });

  test('enum round-trip via fromValue', () {
    expect(GOptionArg.fromValue(GOptionArg.int_.value), GOptionArg.int_);
  });

  test('bitfield operators', () {
    final flags = GIOFlags.append | GIOFlags.nonblock;
    expect(flags & GIOFlags.append, GIOFlags.append);
    expect(flags.value & GIOFlags.getMask.value, isNot(0));
  });

  test('string constants from GIR are exposed as Dart consts', () {
    // GIR declares these as `utf8` typed constants with literal values; the
    // generator must surface them as Dart `const String` so consumers don't
    // need a native call to learn that the directory separator is "/".
    expect(dirSeparatorS, '/');
    expect(dirSeparator, 47);
    expect(pollfdFormat, '%d');
    expect(gint16Format, 'hi');
    expect(gint16Modifier, 'h');
  });

  test('reserved string constants survive Dart interpolation', () {
    // RFC 3986 subcomponent delimiters include literal `$` and `'`, both of
    // which must round-trip through Dart single-quoted string literals.
    expect(uriReservedCharsSubcomponentDelimiters, "!\$&'()*+,;=");
    expect(uriReservedCharsGenericDelimiters, ':/?#[]@');
  });

  test('callback typedefs are exposed as Dart function types', () {
    // Compile-time sanity check that the user-facing typedef compiles and
    // matches the documented shape. This guards against accidental edits
    // to the typedef emitter that drop parameters or change Dart types.
    GCompareDataFunc? fn;
    expect(fn, isNull);
    fn = compareIntPtrs;
    // Call through the typedef to confirm the FFI round-trip works.
    final a = malloc<ffi.IntPtr>()..value = 5;
    final b = malloc<ffi.IntPtr>()..value = 2;
    // compareIntPtrs returns `a.compareTo(b)` — a > b, so the result is
    // positive, NOT negative. The first arg > second arg case.
    expect(fn(a.cast(), b.cast(), ffi.nullptr) > 0, isTrue);
    expect(fn(b.cast(), a.cast(), ffi.nullptr) < 0, isTrue);
    expect(fn(a.cast(), a.cast(), ffi.nullptr), 0);
    malloc.free(a);
    malloc.free(b);
  });

  test('g_async_queue_sort uses a Dart comparator callback', () {
    // Build a queue, push a handful of integer pointers in scrambled order,
    // then sort with our Dart-defined comparator. After sorting, popping
    // should yield the values in ascending order.
    final queue = GAsyncQueue.new_();
    final values = [3, 1, 4, 1, 5, 9, 2, 6];
    final ptrs = <ffi.Pointer<ffi.IntPtr>>[];
    for (final v in values) {
      final p = malloc<ffi.IntPtr>()..value = v;
      ptrs.add(p);
      queue.push(p.cast());
    }
    queue.sort(compareIntPtrs, ffi.nullptr);
    final popped = <int>[];
    for (var i = 0; i < values.length; i++) {
      final p = queue.pop().cast<ffi.IntPtr>();
      popped.add(p.value);
      malloc.free(p);
    }
    expect(popped, [1, 1, 2, 3, 4, 5, 6, 9]);
  });

  test('g_free releases memory GLib allocated', () {
    // `g_free` lives in libglib, which the bindings load with `dlopen` —
    // and a `dlopen`ed library is not part of the process-global symbol
    // namespace. `gir_ffi`'s `gFree` resolves the symbol through an
    // explicitly opened GLib when the global namespace does not have it.
    // This test fails loudly if the lookup ever stops working.
    final buffer = mallocFn(64);
    expect(buffer, isNotNull);
    expect(buffer!.address, isNot(0));
    gFree(buffer.cast());
  });

  test('g_file_get_contents reads a file into a Dart byte list', () {
    // `g_file_get_contents` hands the buffer over with
    // `transfer-ownership="full"`: the wrapper copies the bytes into a
    // `Uint8List` and releases the native buffer.
    final dir = Directory.systemTemp.createTempSync('gir_glib_contents');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/sample.txt';
    File(path).writeAsStringSync('hello glib');

    final (ok, contents) = fileGetContents(path);

    expect(ok, isTrue);
    expect(contents, orderedEquals('hello glib'.codeUnits));
  });

  test('a failed GLib call reports the GError message', () {
    // `GError` is `{ GQuark domain; gint code; gchar *message; }` and
    // `GQuark` is a `guint32`. Reading the struct with a wider `domain`
    // would shift the message pointer and read it from the wrong
    // offset — a wild pointer, not a wrong string.
    //
    // The message itself is localized, so the test pins the part that
    // is not: the path GLib reports.
    final path = '${Directory.systemTemp.path}/gir-no-such-file';
    expect(
      () => fileGetContents(path),
      throwsA(
        isA<GlibException>()
            .having((e) => e.message, 'message', contains('gir-no-such-file'))
            .having((e) => e.message, 'message', isNotEmpty),
      ),
    );
  });
}
