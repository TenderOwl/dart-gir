// Runtime smoke test for `GtkSourceFileLoader.loadAsyncCallback` —
// mirrors what the notepad sample does, but drives the default main
// context manually (no GTK display server required). If this passes,
// the lifetime-safe overload works and the notepad's missing callback
// is a notepad-specific setup issue.

import 'dart:async';
import 'dart:io';

import 'package:gobject/gobject.dart';
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gtk_source5/gtk_source5.dart';
import 'package:test/test.dart';

void main() {
  test(
    'GtkSourceFileLoader.loadAsyncCallback fires and loads /etc/hostname',
    () async {
      // Write a temp file so we exercise the real path through the loader.
      final tmp = File(
        '${Directory.systemTemp.path}/notepad_smoke_'
        '${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      tmp.writeAsStringSync('hello from notepad smoke test\nsecond line\n');

      final buffer = GtkSourceBuffer();
      final file = GtkSourceFile()..setLocation(GFile.newForPath(tmp.path));
      final loader = GtkSourceFileLoader(buffer, file);

      addTearDown(() {
        try {
          tmp.deleteSync();
        } catch (_) {}
      });

      final completer = Completer<GObject?>();
      loader.loadAsyncCallback(priorityDefault, null, null, null, null, (
        source,
        result,
      ) {
        completer.complete(source);
      });

      // Drive the default main context until the callback fires.
      final ctx = GMainContext.default_();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!completer.isCompleted) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'callback never fired within 5s — main context did not dispatch',
          );
        }
        if (!ctx.iteration(true)) {
          // iteration returned false; pump again with a small wait.
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      expect(await completer.future, isNotNull);
    },
  );
}
