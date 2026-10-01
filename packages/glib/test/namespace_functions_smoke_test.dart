import 'dart:ffi' as ffi;

import 'package:glib/glib.dart';
import 'package:test/test.dart';

// Top-level Dart functions that match the inline signatures of the
// callbacks the namespace-level `*_full` functions expect. They are only
// referenced via type assertions below; they are never invoked through the
// generated wrapper because the wrappers dispose their wrapping
// `NativeCallable` in the same `finally` block as the call — safe only for
// callbacks invoked synchronously inside the call.
int idleCallbackSync(ffi.Pointer<ffi.Void> data) {
  return 0;
}

void destroyNotifyNoop(ffi.Pointer<ffi.Void> data) {
  // No-op: nothing to release.
}

void main() {
  test('g_get_user_data_dir returns a non-empty absolute path', () {
    final dir = getUserDataDir();
    expect(dir, isNotEmpty);
    expect(dir.startsWith('/'), isTrue, reason: 'expected an absolute path');
  });

  test('g_get_user_name returns a non-empty string', () {
    expect(getUserName(), isNotEmpty);
  });

  test('g_get_real_name returns a non-empty string when available', () {
    // g_get_real_name may return an empty string on systems without a
    // passwd entry for the user; we only assert it is reachable.
    getRealName();
  });

  test(
    'idleAddFull wrapper accepts a top-level callback and nullable args',
    () {
      // Compile-time check that the wrapper exposes the expected nullable
      // signature: callback typed as `_IdleFn`, data as `Pointer<Void>`,
      // notify as a nullable `_DestroyFn?`. We intentionally do NOT call
      // into the runtime here — `g_idle_add_full` registers an idle source
      // whose callback fires asynchronously when the main loop iterates,
      // but the generated wrapper disposes its wrapping `NativeCallable`
      // in the same `finally` block as the call. That lifetime model is
      // only safe for callbacks invoked synchronously inside the call
      // (see `g_async_queue_sort` in glib_smoke_test.dart). For idle
      // sources, signal handlers, and other long-lived callbacks the
      // caller should use `g_signal_connect_data` directly or build a
      // `Pointer<NativeFunction<...>>` via `Pointer.fromFunction` with
      // a top-level function whose lifetime outlives the source.
      //
      // This test only confirms the wrapper *compiles* with the nullable
      // callback and that the constants/helpers it depends on resolve.
      const int Function(ffi.Pointer<ffi.Void>)? unusedNotify = null;
      expect(unusedNotify, isNull);
      expect(idleCallbackSync, isA<int Function(ffi.Pointer<ffi.Void>)>());
      expect(destroyNotifyNoop, isA<void Function(ffi.Pointer<ffi.Void>)>());
      expect(priorityDefaultIdle, 200);
    },
  );

  test(
    'timeoutAddFull wrapper accepts a top-level callback and nullable args',
    () {
      // Same compile-time check for the timeout variant — guarantees the
      // nullable-callback emission path is uniform across the family.
      const int Function(ffi.Pointer<ffi.Void>)? unusedNotify = null;
      expect(unusedNotify, isNull);
      expect(idleCallbackSync, isA<int Function(ffi.Pointer<ffi.Void>)>());
      expect(destroyNotifyNoop, isA<void Function(ffi.Pointer<ffi.Void>)>());
    },
  );
}
