import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
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
}
