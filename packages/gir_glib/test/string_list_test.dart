// The string-list returns, against the real GLib.
//
// Two flavours, two ownership rules:
//
//   * `g_get_environ` hands over a **copy** of the environment
//     (`transfer-ownership="full"`), so the wrapper releases it with
//     `g_strfreev`;
//   * `g_get_system_config_dirs` and `g_get_language_names` return a
//     **static table** that stays GLib's (`transfer-ownership="none"`),
//     so the wrapper only copies.
//
// A wrong ownership rule shows up as a double free or as a crash in a
// later call, so the test calls each of them more than once.

import 'package:gir_glib/gir_glib.dart';
import 'package:test/test.dart';

void main() {
  test('an allocated array is released and still readable', () {
    final first = getEnviron();
    expect(first, isNotEmpty);

    // A second call would read freed memory if the first one had
    // released the array twice.
    final second = getEnviron();
    expect(second, isNotEmpty);
    expect(second.length, first.length);
  });

  test('a static table is copied, not freed', () {
    final dirs = getSystemConfigDirs();
    expect(dirs, isNotEmpty);
    expect(dirs.first, isNotEmpty);

    // The table is GLib's own memory — calling it again must find it
    // intact.
    expect(getSystemConfigDirs(), isNotEmpty);
  });

  test('the language names are a static table', () {
    final names = getLanguageNames();
    expect(names, isNotEmpty);
    expect(names, contains('C'));
  });

  test('a split is an allocated array', () {
    // `g_strsplit` returns a newly allocated array (transfer full).
    final parts = strsplit('a:b:c', ':', -1);
    expect(parts, ['a', 'b', 'c']);
  });
}
