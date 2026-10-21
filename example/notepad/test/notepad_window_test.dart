// The text viewer's contract: opening a file puts its text on screen,
// saving a file puts it back.
//
// The window loads the file the way the GNOME text-viewer tutorial
// does — `g_file_load_contents_async` hands over a `GAsyncResult`, and
// the `_finish` sibling turns it into the file's bytes. The bytes
// arrive as a `Uint8List`: the binding copies them out of the buffer
// GLib allocated and releases that buffer.
//
// Saving goes through the `GBytes` variant of the call:
// `g_file_replace_contents_bytes_async` takes a `GBytes`, and the
// binding builds one straight from a `Uint8List` — `GBytes(utf8.encode(text))`
// — so the user never handles a native pointer. The `GBytes` variant is
// the one that works asynchronously: GIO keeps a reference to the bytes
// "for the duration of the call", while the raw-buffer variant would
// need the buffer to stay valid until the callback fires.
//
// The suite exercises the loader and the saver against a plain
// `GtkTextView` rather than against the window. GTK allows exactly one
// template per native class, and both this example and `example/todo`
// template an `AdwApplicationWindow` — so a second templated window in
// the same process (the test runner keeps every suite in one process)
// cannot install its template, and GTK's own assertion tears the heap
// down. The window itself is a thin wrapper around the same calls.
//
// GTK needs a display, so the suite skips itself when there is none.
// CI runs headless; run it locally under `xvfb-run`:
//
//   xvfb-run -a dart test example/notepad

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gtk4/gtk4.dart';
import 'package:notepad/notepad.dart';
import 'package:test/test.dart';

/// Whether a display is reachable. Without one GTK cannot even
/// initialize, so the whole suite is skipped.
final bool _hasDisplay =
    (Platform.environment['DISPLAY'] ?? '').isNotEmpty ||
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

/// The text [buffer] currently holds.
String _bufferText(GtkTextBuffer buffer) =>
    buffer.getText(buffer.getStartIter(), buffer.getEndIter(), true);

/// Runs [action] and drives a main context of its own until it is done.
///
/// The callbacks are dispatched on the *thread-default* main context, so
/// the suite pushes a context of its own and iterates that one. The
/// default context is shared by every suite in the process — the test
/// runner keeps them all in one — and two suites iterating it at the
/// same time is a data race inside GLib.
Future<void> _withOwnContext(Future<void> Function() action) async {
  final context = GMainContext();
  context.pushThreadDefault();
  final completer = Completer<void>();
  unawaited(
    action().then(completer.complete, onError: completer.completeError),
  );
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!completer.isCompleted && DateTime.now().isBefore(deadline)) {
      if (!context.iteration(false)) {
        // Nothing was dispatched — wait for the file system.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    await completer.future;
  } finally {
    context.popThreadDefault();
  }
}

/// Loads [file] into [buffer] the way the window does.
Future<void> _loadInto(GFile file, GtkTextBuffer buffer) {
  final completer = Completer<void>();
  file.loadContentsAsyncCallback(null, (source, result) {
    final (ok, contents, _) = source!
        .cast<GFile>(GFile.fromPointer)
        .loadContentsFinish(result);
    if (!ok) {
      completer.completeError(StateError('the file did not load'));
      return;
    }
    buffer.setText(utf8.decode(contents, allowMalformed: true), -1);
    completer.complete();
  });
  return completer.future;
}

/// Saves [text] into [file] the way the window does.
Future<void> _saveFrom(GFile file, String text) {
  final completer = Completer<void>();
  final bytes = GBytes(utf8.encode(text));
  file.replaceContentsBytesAsyncCallback(bytes, null, false, .none, null, (
    source,
    result,
  ) {
    final (ok, _) = source!
        .cast<GFile>(GFile.fromPointer)
        .replaceContentsFinish(result);
    if (!ok) {
      completer.completeError(StateError('the file did not save'));
      return;
    }
    completer.complete();
  });
  return completer.future;
}

void main() {
  test('calculate', () {
    expect(calculate(), 42);
  });

  group('the file loader', () {
    // Without a display GTK cannot even initialize, so the suite is
    // skipped — CI runs headless.
    final skip = _hasDisplay ? null : 'GTK needs a display';

    late Directory dir;
    late File file;

    setUpAll(() {
      if (!_hasDisplay) return;
      init();
    });

    setUp(() {
      dir = Directory.systemTemp.createTempSync('gir_notepad');
      file = File('${dir.path}/sample.txt')..writeAsStringSync('hello notepad');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('opening a file puts its text in the buffer', () async {
      final view = GtkTextView();
      final buffer = view.getBuffer();

      await _withOwnContext(
        () => _loadInto(GFile.newForPath(file.path), buffer),
      );

      expect(_bufferText(buffer), 'hello notepad');
    }, skip: skip);

    test('a file that is not valid UTF-8 still loads', () async {
      // `allowMalformed` replaces the invalid sequences instead of
      // throwing — a binary file must not take the window down.
      final binary = File('${dir.path}/bytes.bin')
        ..writeAsBytesSync([0x68, 0x69, 0xff, 0xfe, 0x21]);
      final view = GtkTextView();
      final buffer = view.getBuffer();

      await _withOwnContext(
        () => _loadInto(GFile.newForPath(binary.path), buffer),
      );

      expect(_bufferText(buffer), contains('hi'));
    }, skip: skip);
  });

  group('the file saver', () {
    final skip = _hasDisplay ? null : 'GTK needs a display';

    late Directory dir;
    late File file;

    setUpAll(() {
      if (!_hasDisplay) return;
      init();
    });

    setUp(() {
      dir = Directory.systemTemp.createTempSync('gir_notepad_save');
      file = File('${dir.path}/saved.txt');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('saving writes the buffer contents to the file', () async {
      final view = GtkTextView();
      final buffer = view.getBuffer();
      buffer.setText('saved by the notepad', -1);

      await _withOwnContext(
        () => _saveFrom(GFile.newForPath(file.path), _bufferText(buffer)),
      );

      expect(file.readAsStringSync(), 'saved by the notepad');
    }, skip: skip);

    test('a `GBytes` built from a `Uint8List` carries the bytes', () async {
      // The binding builds the `GBytes` straight from the list — the
      // user never sees a native pointer.
      final bytes = GBytes(utf8.encode('hello notepad'));
      expect(bytes.getSize(), 'hello notepad'.length);

      await _withOwnContext(
        () => _saveFrom(GFile.newForPath(file.path), 'hello notepad'),
      );

      expect(file.readAsStringSync(), 'hello notepad');
    }, skip: skip);
  });
}
