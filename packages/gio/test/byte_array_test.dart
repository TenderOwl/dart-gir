// Runtime tests for the byte buffers the GIR hands over to the callee.
//
// Three shapes, one rule: the *caller* owns the buffer's lifetime, and
// the wrapper says so on its doc comment.
//
//  * a destroy notify — the callee takes the buffer over and calls the
//    notify when it is done with it (`GMemoryInputStream.fromData`);
//  * an async callback — the callee keeps the buffer until the callback
//    fires (`GFile.replaceContentsAsync`);
//  * the `GBytes` sibling — the callee holds a reference to the bytes for
//    the duration of the call, so the caller may drop its own copy
//    (`GFile.replaceContentsBytesAsync`).
//
// Run with:
//   dart test test/byte_array_test.dart

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:test/test.dart';

void main() {
  group('destroy-notify byte arrays', () {
    test('the notify runs when the callee releases the buffer', () {
      final buffer = malloc<ffi.Uint8>(4);
      buffer[0] = 7;
      buffer[1] = 8;
      buffer[2] = 9;
      buffer[3] = 10;

      ffi.Pointer<ffi.Void>? notified;
      int? firstByte;
      final stream = GMemoryInputStream.fromData(buffer.cast<ffi.Uint8>(), 4, (
        data,
      ) {
        notified = data;
        // The buffer is still the caller's when the notify runs — the
        // callee releases it *through* the notify.
        firstByte = data.cast<ffi.Uint8>()[0];
        malloc.free(data.cast<ffi.Uint8>());
      });

      // The callee has not released the buffer yet.
      expect(notified, isNull);

      // Releasing the stream is what makes the callee release the
      // buffer: the stream keeps it until it is finalized.
      stream.unref();

      expect(notified!.address, buffer.address);
      expect(firstByte, 7);
    });

    test('the notify of an appended buffer runs the same way', () {
      final buffer = malloc<ffi.Uint8>(2);
      buffer[0] = 42;
      buffer[1] = 43;

      ffi.Pointer<ffi.Void>? notified;
      final stream = GMemoryInputStream.fromBytes(
        GBytes(Uint8List.fromList([1, 2])),
      );
      stream.addData(buffer.cast<ffi.Uint8>(), 2, (data) {
        notified = data;
        malloc.free(data.cast<ffi.Uint8>());
      });

      expect(notified, isNull);

      stream.unref();
      expect(notified!.address, buffer.address);
    });

    test('the buffer is readable while the stream holds it', () {
      final buffer = malloc<ffi.Uint8>(3);
      buffer[0] = 1;
      buffer[1] = 2;
      buffer[2] = 3;

      final stream = GMemoryInputStream.fromData(
        buffer.cast<ffi.Uint8>(),
        3,
        (data) => malloc.free(data.cast<ffi.Uint8>()),
      );

      // The stream hands the bytes out — they are still the caller's.
      final (pointer, length) = stream.readBytes(3).getData();
      expect(pointer.asTypedList(length), orderedEquals([1, 2, 3]));

      stream.unref();
    });
  });

  group('async byte arrays', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('gir_gio_byte_array');
      file = File('${dir.path}/sample.txt')..writeAsStringSync('before');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    /// Runs [body] with a main context of its own and waits for the
    /// completer it fills.
    ///
    /// The callback is dispatched on the *thread-default* main context, so
    /// the suite pushes a context of its own and iterates that one. The
    /// default context is shared by every suite in the process — the test
    /// runner keeps them all in one — and two suites iterating it at the
    /// same time is a data race inside GLib.
    Future<void> withMainContext(
      Future<void> Function(GMainContext ctx) body,
    ) async {
      final ctx = GMainContext();
      ctx.pushThreadDefault();
      try {
        await body(ctx);
      } finally {
        ctx.popThreadDefault();
      }
    }

    test(
      'the GBytes sibling carries the bytes through the async call',
      () async {
        final gfile = GFile.newForPath(file.path);
        final completer = Completer<(bool, String?)>();
        final bytes = GBytes(Uint8List.fromList('after'.codeUnits));

        await withMainContext((ctx) async {
          gfile.replaceContentsBytesAsyncCallback(
            bytes,
            null,
            false,
            .none,
            null,
            (source, result) {
              completer.complete(gfile.replaceContentsFinish(result));
            },
          );

          while (!completer.isCompleted) {
            if (!ctx.iteration(true)) break;
          }
        });

        final (ok, etag) = await completer.future;
        expect(ok, isTrue);
        expect(etag, isNotNull);
        expect(file.readAsStringSync(), 'after');
      },
    );

    test(
      'the raw pointer route keeps the buffer until the callback fires',
      () async {
        final gfile = GFile.newForPath(file.path);
        final completer = Completer<(bool, String?)>();

        // The buffer is *not* copied — GIO reads it when the callback runs.
        // The caller owns it until then.
        final buffer = malloc<ffi.Uint8>(5);
        buffer[0] = 'raw'.codeUnitAt(0);
        buffer[1] = 'raw'.codeUnitAt(1);
        buffer[2] = 'raw'.codeUnitAt(2);
        buffer[3] = 0;
        buffer[4] = 0;

        await withMainContext((ctx) async {
          gfile.replaceContentsAsyncCallback(
            buffer.cast<ffi.Uint8>(),
            3,
            null,
            false,
            .none,
            null,
            (source, result) {
              completer.complete(gfile.replaceContentsFinish(result));
            },
          );

          while (!completer.isCompleted) {
            if (!ctx.iteration(true)) break;
          }
        });

        final (ok, _) = await completer.future;
        expect(ok, isTrue);
        expect(file.readAsStringSync(), 'raw');

        // The buffer was alive all along — the caller's copy is released
        // once the operation is done.
        malloc.free(buffer);
      },
    );
  });
}
