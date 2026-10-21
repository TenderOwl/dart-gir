// Runtime test for the byte-buffer OUT parameters: `GFile.loadContents`
// and `GFile.loadContentsFinish`.
//
// Both hand the file's bytes over the way the GNOME tutorial does —
// the C function allocates the buffer, fills it, and writes the pointer
// into the caller's slot; the wrapper copies the bytes into a
// `Uint8List` and releases the native buffer.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

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

  group('caller-provided byte arrays', () {
    test('GFile.replaceContents writes a Dart byte list', () {
      final gfile = GFile.newForPath(file.path);
      final contents = Uint8List.fromList('written by gio'.codeUnits);

      final (ok, etag) = gfile.replaceContents(contents, null, false, .none);

      expect(ok, isTrue);
      expect(etag, isNotNull);
      // The file now holds exactly the bytes that were handed over.
      expect(file.readAsBytesSync(), orderedEquals(contents));
    });

    test('GFile.replaceContents writes binary content', () {
      final bytes = List<int>.generate(256, (i) => i);
      final gfile = GFile.newForPath(file.path);

      final (ok, _) = gfile.replaceContents(
        Uint8List.fromList(bytes),
        null,
        false,
        .none,
      );

      expect(ok, isTrue);
      expect(file.readAsBytesSync(), orderedEquals(bytes));
    });

    test('GOutputStream.write takes a Dart byte list', () {
      final stream = GMemoryOutputStream.resizable();
      final contents = Uint8List.fromList('streamed'.codeUnits);

      final written = stream.write(contents);

      expect(written, contents.length);
      final pointer = stream.getDataMemoryOutputStream()!;
      expect(
        pointer.cast<ffi.Uint8>().asTypedList(stream.getDataSize()),
        orderedEquals(contents),
      );
    });

    test('a converter fills the caller-provided output buffer', () {
      // `g_converter_convert` writes into the buffer the caller passes.
      // The wrapper mirrors the Dart list into native memory and copies
      // the result back, so the converted bytes land in `outbuf`.
      final converter = GCharsetConverter('UTF-8', 'UTF-8');
      final inbuf = Uint8List.fromList('converted'.codeUnits);
      final outbuf = Uint8List(inbuf.length);

      final (result, read, written) = converter.convert(
        inbuf,
        outbuf,
        GConverterFlags.noFlags,
      );

      // Without the flush flag the converter reports "converted", not
      // "finished" — all the input was consumed either way.
      expect(result, GConverterResult.converted);
      expect(read, inbuf.length);
      expect(written, inbuf.length);
      expect(outbuf, orderedEquals('converted'.codeUnits));
    });
  });
}
