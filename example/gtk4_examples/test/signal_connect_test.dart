// Headless smoke test for the `g_signal_connect_data` flow used in
// `bin/gtk4_counter.dart`.
//
// We don't need GTK or a display for this: the test runs entirely against
// GObject. We register a custom `void(void)` signal on the fly via
// `g_signal_new`, connect it with the same FFI binding the binary uses,
// and emit it synchronously via `g_signal_emit_by_name`. The trampoline
// runs inline inside the emit call, so by the time it returns we can read
// the shared state from the test.
//
// The bug we are guarding against is the callback arity. If the Dart
// trampoline is declared with one `Pointer<Void>` parameter, the closure
// receives the `instance` argument (RDI on x86_64) and silently drops the
// `user_data` argument (RSI). With two parameters, the trampoline reads
// both and the user_data we registered is what the callback observes.
//
// Run with:
//   dart test --platform vm test/signal_connect_test.dart

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gobject/gobject.dart' show gobjectLookup;
import 'package:test/test.dart';

// ---------- raw FFI lookups for symbols that aren't in the generator
//                            output (they're macros / variadic in glib) ----

// g_object_new(GType, NULL-terminated varargs) — GObject has no properties
// by default, so we pass just the type and a terminating NULL.
typedef _GObjectNewDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);

final _gObjectNew = gobjectLookup<ffi.NativeFunction<_GObjectNewDart>>(
  'g_object_new',
).asFunction<_GObjectNewDart>();

// g_signal_emit_by_name(instance, detailed_signal) — no varargs for our
// void(void) signal.
typedef _GSignalEmitByNameDart = void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<Utf8>,
);

final _gSignalEmitByName =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)
          >
        >('g_signal_emit_by_name')
        .asFunction<_GSignalEmitByNameDart>();

// g_signal_new — variadic in C; we pass zero `GType` varargs for our
// void(void) signal. On x86_64 Linux, `GType` is `gulong` (Size = 8 bytes).
typedef _GSignalNewDart = int Function(
  ffi.Pointer<Utf8>, // signal_name
  int, // itype (GType)
  int, // signal_flags
  int, // class_offset
  ffi.Pointer<ffi.Void>, // accumulator (nullable)
  ffi.Pointer<ffi.Void>, // accu_data
  ffi.Pointer<ffi.Void>, // c_marshaller (nullable)
  int, // return_type (GType)
  int, // n_params
);

final _gSignalNew =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Uint64 Function(
              ffi.Pointer<Utf8>,
              ffi.Size,
              ffi.Uint32,
              ffi.Uint32,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Size,
              ffi.Uint32,
            )
          >
        >('g_signal_new')
        .asFunction<_GSignalNewDart>();

// g_object_get_type() — returns G_TYPE_OBJECT.
typedef _GObjectGetTypeDart = int Function();

final _gObjectGetType = gobjectLookup<ffi.NativeFunction<ffi.Size Function()>>(
  'g_object_get_type',
).asFunction<_GObjectGetTypeDart>();

// g_type_from_name("gboolean") — returns the GType for gboolean so we can
// pass it as the return type when registering our void(void) signal.
typedef _GTypeFromNameDart = int Function(ffi.Pointer<Utf8>);

final _gTypeFromName =
    gobjectLookup<ffi.NativeFunction<ffi.Size Function(ffi.Pointer<Utf8>)>>(
      'g_type_from_name',
    ).asFunction<_GTypeFromNameDart>();

// ---------- the same g_signal_connect_data declaration used in the binary --
//
// The GCallback slot is declared as `Void Function(Pointer<Void>,
// Pointer<Void>)` to match how `g_cclosure_marshal_VOID__VOID` invokes the
// closure: `closure(instance, user_data)`. Declaring it as a single
// `Pointer<Void>` parameter silently reads `RDI` (instance) and drops `RSI`
// (user_data).

final _gSignalConnectData =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Uint64 Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<Utf8>,
              ffi.Pointer<
                ffi.NativeFunction<
                  ffi.Void Function(
                    ffi.Pointer<ffi.Void>,
                    ffi.Pointer<ffi.Void>,
                  )
                >
              >,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
            )
          >
        >('g_signal_connect_data')
        .asFunction<
          int Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<Utf8>,
            ffi.Pointer<
              ffi.NativeFunction<
                ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
              >
            >,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            int,
          )
        >();

// ---------- shared mutable state for the callback -----------------------

int _callbackInvocations = 0;
ffi.Pointer<ffi.Void>? _observedInstance;
ffi.Pointer<ffi.Void>? _observedUserData;

void _onCallback(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
) {
  _callbackInvocations += 1;
  _observedInstance = instance;
  _observedUserData = userData;
}

void _connectSignal(
  ffi.Pointer<ffi.Void> instance,
  String signal,
  void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>) callback,
  ffi.Pointer<ffi.Void> userData,
) {
  final nc =
      ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
      >.isolateLocal(callback);
  final signalName = signal.toNativeUtf8();
  try {
    _gSignalConnectData(
      instance,
      signalName.cast<Utf8>(),
      nc.nativeFunction,
      userData,
      ffi.nullptr,
      0,
    );
  } finally {
    calloc.free(signalName);
  }
  // Intentionally don't close nc — the connection lives for the rest of
  // the test process, which is fine for a headless smoke test.
}

void main() {
  test('g_signal_connect_data threads user_data through the closure', () {
    _callbackInvocations = 0;
    _observedInstance = null;
    _observedUserData = null;

    // Look up G_TYPE_OBJECT and G_TYPE_NONE (== 4 + 8 = the gtype for
    // "void"). We could hard-code the values (72 and 12 on the standard
    // registration order) but going through the API keeps the test robust.
    final gTypeObject = _gObjectGetType();
    final gTypeNone = _gTypeFromName('void'.toNativeUtf8().cast<Utf8>());
    calloc.free('void'.toNativeUtf8());

    // Register a custom void(void) signal on GObject. Without this, plain
    // GObject has no usable signal — its only one is `notify`, whose
    // default handler dereferences a GParamSpec* and segfaults when we
    // emit it without that argument.
    final signalName = 'dartgir-smoke-test'.toNativeUtf8();
    try {
      _gSignalNew(
        signalName.cast<Utf8>(),
        gTypeObject,
        2, // G_SIGNAL_RUN_LAST
        0, // class_offset
        ffi.nullptr, // accumulator
        ffi.nullptr, // accu_data
        ffi.nullptr, // c_marshaller (NULL → g_cclosure_marshal_generic)
        gTypeNone, // return_type
        0, // n_params
      );
    } finally {
      calloc.free(signalName);
    }

    final obj = _gObjectNew(ffi.Pointer.fromAddress(gTypeObject), ffi.nullptr);
    expect(obj, isNot(equals(ffi.nullptr)));

    final sentinel = calloc<ffi.Uint8>(1);
    sentinel.value = 0xAB;

    try {
      _connectSignal(obj, 'dartgir-smoke-test', _onCallback, sentinel.cast());

      final emitName = 'dartgir-smoke-test'.toNativeUtf8();
      try {
        _gSignalEmitByName(obj, emitName.cast<Utf8>());
      } finally {
        calloc.free(emitName);
      }

      expect(_callbackInvocations, 1, reason: 'callback should fire once');
      expect(_observedInstance, equals(obj), reason: 'instance slot correct');
      expect(
        _observedUserData,
        equals(sentinel.cast()),
        reason: 'user_data slot correct',
      );
    } finally {
      calloc.free(sentinel);
    }
  });
}
