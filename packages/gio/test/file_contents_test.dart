// Runtime test for the byte-buffer OUT parameters: `GFile.loadContents`
// and `GFile.loadContentsFinish`.
//
// Both hand the file's bytes over the way the GNOME tutorial does —
// the C function allocates the buffer, fills it, and writes the pointer
// into the caller's slot; the wrapper copies the bytes into a
// `Uint8List` and releases the native buffer.

import 'dart:async';
import 'dart:io';

import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gir_gio_contents');
    file = File('${dir.path}/sample.txt')..writeAsStringSync('hello gio');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('GFile.loadContents', () {
    test('reads the file into a Dart byte list', () {
      final gfile = GFile.newForPath(file.path);

      final (ok, contents, etag) = gfile.loadContents();

      expect(ok, isTrue);
      expect(contents, orderedEquals('hello gio'.codeUnits));
      // GLib derives an etag from the file's mtime and size. It is
      // nullable — a `GFile` without an etag leaves the slot NULL — and
      // the wrapper reports that as `null` instead of throwing.
      expect(etag, isNotNull);
      expect(etag, isNotEmpty);
    });

    test('reports a missing file through GlibException', () {
      final gfile = GFile.newForPath('${dir.path}/does-not-exist.txt');

      expect(gfile.loadContents, throwsA(isA<GlibException>()));
    });
  });

  group('GFile.loadContentsFinish', () {
    test('reads the file into a Dart byte list', () async {
      final gfile = GFile.newForPath(file.path);
      final completer = Completer<(bool, List<int>, String?)>();

      // The load dispatches its callback on the *thread-default* main
      // context, so the suite pushes a context of its own and iterates
      // that one. The default context is shared by every suite in the
      // process — the test runner keeps them all in one — and two
      // suites iterating it at the same time is a data race inside GLib.
      final ctx = GMainContext();
      ctx.pushThreadDefault();
      try {
        gfile.loadContentsAsyncCallback(null, (source, result) {
          completer.complete(gfile.loadContentsFinish(result));
        });

        while (!completer.isCompleted) {
          if (!ctx.iteration(true)) break;
        }
      } finally {
        ctx.popThreadDefault();
      }

      final (ok, contents, etag) = await completer.future;
      expect(ok, isTrue);
      expect(contents, orderedEquals('hello gio'.codeUnits));
      expect(etag, isNotEmpty);
    });

    test('a binary file keeps every byte', () {
      final bytes = List<int>.generate(256, (i) => i);
      final binary = File('${dir.path}/bytes.bin')..writeAsBytesSync(bytes);
      final gfile = GFile.newForPath(binary.path);

      final (ok, contents, _) = gfile.loadContents();

      expect(ok, isTrue);
      expect(contents, orderedEquals(bytes));
    });
  });
}
