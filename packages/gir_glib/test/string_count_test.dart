// The counted shapes of the string bindings, against the real GLib.
//
// Three GIR shapes meet here:
//
//   * a **bound string list** — `g_key_file_set_string_list` and its
//     `gsize length`: the C side reads exactly `length` slots rather
//     than scanning for a NULL terminator. The count is the length of
//     the list the caller passed, so it disappears from the Dart
//     signature and stays in the native one;
//   * a **counted string** — `g_regex_match_full` and its `gssize
//     string_len`: the C side reads `string_len` *bytes*, so a string
//     of four characters can be six UTF-8 bytes and the count has to
//     be a byte count;
//   * a **string list whose count the callee reports** —
//!     `g_bookmark_file_get_applications` and its `gsize *length`: the
//     array is not always NULL-terminated, so the count is what says
//     how many elements there are.
//
// A wrong count shows up as a truncated match or as a list that is
// short, so every case is checked against a value that only comes out
// right when the count is right.
//
// Run with:
//   dart test test/string_count_test.dart

import 'package:gir_glib/gir_glib.dart';
import 'package:test/test.dart';

void main() {
  group('a bound string list', () {
    test('the count the caller passed is the count the C side reads', () {
      final keyFile = GKeyFile();
      keyFile.setStringList('group', 'key', ['alpha', 'beta', 'gamma']);

      // The list comes back whole: a count that was off by one would
      // drop the last element.
      expect(keyFile.getStringList('group', 'key'), ['alpha', 'beta', 'gamma']);
    });

    test('an empty list round-trips as an empty list', () {
      final keyFile = GKeyFile();
      keyFile.setStringList('group', 'empty', <String?>[]);

      expect(keyFile.getStringList('group', 'empty'), isEmpty);
    });
  });

  group('a counted string', () {
    test('the count is a byte count, not a character count', () {
      // '€' is three UTF-8 bytes; 'a€b' is five bytes but only three
      // characters. A character count would cut the string in the
      // middle of the euro sign, and the match would fail.
      final regex = GRegex(
        '€',
        GRegexCompileFlags.default_,
        GRegexMatchFlags(0),
      );

      final (matched, matchInfo) = regex.matchFull(
        'a€b',
        0,
        GRegexMatchFlags(0),
      );

      expect(matched, isTrue);
      matchInfo?.free();
    });

    test('a string without multi-byte characters matches too', () {
      final regex = GRegex(
        'b',
        GRegexCompileFlags.default_,
        GRegexMatchFlags(0),
      );

      final (matched, matchInfo) = regex.matchFull(
        'abc',
        0,
        GRegexMatchFlags(0),
      );

      expect(matched, isTrue);
      matchInfo?.free();
    });
  });

  group('a string list whose count the callee reports', () {
    test('the array is read for exactly the reported count', () {
      final bookmarkFile = GBookmarkFile();
      bookmarkFile.addApplication('file:///tmp/example', 'editor', 'editor %u');

      final applications = bookmarkFile.getApplications('file:///tmp/example');

      expect(applications, ['editor']);
    });

    test('an unknown bookmark reports the error', () {
      final bookmarkFile = GBookmarkFile();

      // The C function sets the error; the wrapper throws it.
      expect(
        () => bookmarkFile.getApplications('file:///tmp/missing'),
        throwsA(isA<GlibException>()),
      );
    });
  });
}
