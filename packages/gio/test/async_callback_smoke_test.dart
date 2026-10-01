// Runtime smoke test for the `*Callback` lifetime-safe async convenience
// overloads emitted by `AsyncCallbackEmitter`. See `docs/async.md`.
//
// Without the registry/trampoline pattern, the base wrapper
// (`GFile.queryInfoAsync`) would close its wrapping `NativeCallable` in
// `finally`, leaving GLib's main loop to dispatch the callback against
// freed memory ("Callback invoked after it has been deleted"). The
// `queryInfoAsyncCallback` overload avoids that race by routing the
// callback through a permanent `Pointer.fromFunction` over a static
// trampoline that dispatches to the user-supplied typed function.

import 'dart:async';

import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:test/test.dart';

void main() {
  test(
    'GFile.queryInfoAsyncCallback fires and queries a real file',
    () async {
      final file = GFile.newForPath('/etc/hostname');
      final completer = Completer<GFileInfo>();
      file.queryInfoAsyncCallback(
        'standard::type,standard::size',
        GFileQueryInfoFlags.none,
        priorityDefault,
        null,
        (source, result) {
          // The trampoline gave us typed `sourceObject` (GObject?) and
          // `result` (GAsyncResult). We call the canonical `_finish`
          // sibling to retrieve the result.
          final info = file.queryInfoFinish(result);
          completer.complete(info);
        },
      );
      // Drive the default main context until the callback fires.
      final ctx = GMainContext.default_();
      while (!completer.isCompleted) {
        if (!ctx.iteration(true)) break;
      }
      final info = await completer.future;
      expect(info.getFileType(), GFileType.regular);
    },
  );
}
