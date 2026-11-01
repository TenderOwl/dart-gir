// The NUL-terminated output of a child process, against the real GLib.
//
// `g_spawn_sync` hands the child's output over as a buffer the callee
// allocates and terminates with a NUL — and states no size anywhere in
// the signature. The wrapper therefore measures the buffer with
// `strlen` and hands the caller a `String`.
//
// A wrong measurement shows up as a truncated string, so the case is
// checked against output whose length is known.
//
// Run with:
//   dart test test/spawn_test.dart

import 'package:gir_glib/gir_glib.dart';
import 'package:test/test.dart';

void main() {
  group("a child's standard output", () {
    test('comes back as a string', () {
      final (ok, stdout, stderr, status) = spawnSync(
        null,
        ['/bin/sh', '-c', 'printf hello'],
        null,
        GSpawnFlags.default_,
      );

      expect(ok, isTrue);
      expect(status, 0);
      expect(stdout, 'hello');
      // The child wrote nothing to stderr, but GLib still hands over a
      // buffer — an empty one.
      expect(stderr, '');
    });

    test('is measured to the end of the buffer', () {
      final (ok, stdout, _, _) = spawnSync(
        null,
        ['/bin/sh', '-c', 'printf "a longer piece of output"'],
        null,
        GSpawnFlags.default_,
      );

      expect(ok, isTrue);
      // A measurement that stopped early would cut the string short.
      expect(stdout, 'a longer piece of output');
    });
  });
}
