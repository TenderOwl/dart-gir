import 'dart:async';
import 'dart:convert';

import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gtk4/gtk4.dart';

/// Loads the text of [file].
///
/// This is the shape the GNOME text-viewer tutorial uses: the
/// asynchronous load hands over a `GAsyncResult`, and the `_finish`
/// sibling turns it into the file's bytes. The bytes arrive as a
/// `Uint8List` — the binding copies them out of the buffer GLib
/// allocated and releases that buffer, so the caller owns plain Dart
/// memory.
///
/// The load is asynchronous, so the result arrives from the default main
/// context: whoever awaits the future has to keep the main loop running.
Future<String> loadFileText(GFile file) {
  final completer = Completer<String>();
  file.loadContentsAsyncCallback(null, (source, result) {
    try {
      final (ok, bytes, etag) = file.loadContentsFinish(result);
      if (!ok) {
        throw GlibException('Could not read the file.', code: 0, domain: 0);
      }
      // `allowMalformed` keeps a file that is not valid UTF-8 from
      // taking the whole window down.
      completer.complete(utf8.decode(bytes, allowMalformed: true));
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  });
  return completer.future;
}

/// Loads the text of [file] and puts it into [buffer].
///
/// `-1` is the length GTK expects for a NUL-terminated string.
Future<void> loadFileInto(GFile file, GtkTextBuffer buffer) async {
  final text = await loadFileText(file);
  buffer.setText(text, -1);
}
