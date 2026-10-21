// The text viewer's contract: opening a file puts its text on screen.
//
// The window loads the file the way the GNOME text-viewer tutorial
// does — `g_file_load_contents_async` hands over a `GAsyncResult`, and
// the `_finish` sibling turns it into the file's bytes. The bytes
// arrive as a `Uint8List`: the binding copies them out of the buffer
// GLib allocated and releases that buffer.
//
// The suite exercises the loader against a plain `GtkTextView` rather
// than against the window. GTK allows exactly one template per native
// class, and both this example and `example/todo` template an
// `AdwApplicationWindow` — so a second templated window in the same
// process (the test runner keeps every suite in one process) cannot
// install its template, and GTK's own assertion tears the heap down.
// The window itself is a three-line wrapper around [loadFileInto].
//
// GTK needs a display, so the suite skips itself when there is none.
// CI runs headless; run it locally under `xvfb-run`:
//
//   xvfb-run -a dart test example/notepad

import 'dart:async';
import 'dart:io';

import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gtk4/gtk4.dart';
import 'package:notepad/file_loader.dart';
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

/// Loads [file] into [buffer] and drives the default main context until
/// the load finishes.
///
/// The load dispatches its callback on the *thread-default* main
/// context, so the suite pushes a context of its own and iterates that
/// one. The default context is shared by every suite in the process —
/// the test runner keeps them all in one — and two suites iterating it
/// at the same time is a data race inside GLib.
Future<void> _loadInto(GFile file, GtkTextBuffer buffer) async {
  final context = GMainContext();
  context.pushThreadDefault();
  final completer = Completer<void>();
  unawaited(
    loadFileInto(
      file,
      buffer,
    ).then(completer.complete, onError: completer.completeError),
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

      await _loadInto(GFile.newForPath(file.path), buffer);

      expect(_bufferText(buffer), 'hello notepad');
    }, skip: skip);

    test('a file that is not valid UTF-8 still loads', () async {
      // `allowMalformed` replaces the invalid sequences instead of
      // throwing — a binary file must not take the window down.
      final binary = File('${dir.path}/bytes.bin')
        ..writeAsBytesSync([0x68, 0x69, 0xff, 0xfe, 0x21]);
      final view = GtkTextView();
      final buffer = view.getBuffer();

      await _loadInto(GFile.newForPath(binary.path), buffer);

      expect(_bufferText(buffer), contains('hi'));
    }, skip: skip);
  });
}
