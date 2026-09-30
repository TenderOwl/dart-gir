// Runtime test for the generated signal helpers in `lib/src/signals.dart`.
//
// Headless: we register a custom `void(void)` signal on GObject via
// `g_signal_new`, connect it with the generated `connectSignal` escape
// hatch (the same code path every `onSignalName` method delegates to), emit
// it synchronously via `g_signal_emit_by_name`, then disconnect and verify
// the callback no longer fires (the destroy-notify ran and dropped the
// registry entry).
//
// Run with:
//   dart test --platform vm test/signal_helpers_test.dart

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gobject/gobject.dart';
import 'package:test/test.dart';

// g_object_new(GType, NULL) — GObject has no properties by default.
final _gObjectNew =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Pointer<ffi.Void> Function(ffi.Size, ffi.Pointer<ffi.Void>)
          >
        >('g_object_new')
        .asFunction<
          ffi.Pointer<ffi.Void> Function(int, ffi.Pointer<ffi.Void>)
        >();

final _gObjectGetType = gobjectLookup<ffi.NativeFunction<ffi.Size Function()>>(
  'g_object_get_type',
).asFunction<int Function()>();

final _gTypeFromName =
    gobjectLookup<ffi.NativeFunction<ffi.Size Function(ffi.Pointer<Utf8>)>>(
      'g_type_from_name',
    ).asFunction<int Function(ffi.Pointer<Utf8>)>();

// g_signal_new — variadic in C; zero GType varargs for our void(void)
// signal.
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
        .asFunction<
          int Function(
            ffi.Pointer<Utf8>,
            int,
            int,
            int,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            int,
            int,
          )
        >();

final _gSignalEmitByName =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)
          >
        >('g_signal_emit_by_name')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>();

final _gSignalHandlerDisconnect =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.UnsignedLong)
          >
        >('g_signal_handler_disconnect')
        .asFunction<void Function(ffi.Pointer<ffi.Void>, int)>();

void _emitByName(ffi.Pointer<ffi.Void> instance, String name) {
  final namePtr = name.toNativeUtf8();
  try {
    _gSignalEmitByName(instance, namePtr.cast<Utf8>());
  } finally {
    calloc.free(namePtr);
  }
}

int _gTypeNone() {
  final ptr = 'void'.toNativeUtf8();
  try {
    return _gTypeFromName(ptr.cast<Utf8>());
  } finally {
    calloc.free(ptr);
  }
}

void main() {
  late ffi.Pointer<ffi.Void> object;

  setUpAll(() {
    final namePtr = 'dartgir-helper-test'.toNativeUtf8();
    try {
      _gSignalNew(
        namePtr.cast<Utf8>(),
        _gObjectGetType(),
        2, // G_SIGNAL_RUN_LAST
        0, // class_offset
        ffi.nullptr, // accumulator
        ffi.nullptr, // accu_data
        ffi.nullptr, // c_marshaller (NULL → g_cclosure_marshal_generic)
        _gTypeNone(), // return_type
        0, // n_params
      );
    } finally {
      calloc.free(namePtr);
    }
  });

  setUp(() {
    object = _gObjectNew(_gObjectGetType(), ffi.nullptr);
    expect(object, isNot(ffi.nullptr));
  });

  tearDown(() {
    gObjectUnref(object);
  });

  test('connect, emit, disconnect', () {
    var fired = 0;
    final handlerId = connectSignal(object, 'dartgir-helper-test', () {
      fired++;
    });
    expect(handlerId, isNonZero);

    _emitByName(object, 'dartgir-helper-test');
    expect(fired, 1);

    _gSignalHandlerDisconnect(object, handlerId);
    _emitByName(object, 'dartgir-helper-test');
    expect(fired, 1, reason: 'destroy-notify removed the registry entry');
  });

  test('closure capture works through the trampoline', () {
    final seen = <String>[];
    connectSignal(object, 'dartgir-helper-test', () {
      seen.add('fired');
    });
    _emitByName(object, 'dartgir-helper-test');
    expect(seen, ['fired']);
  });

  test('two connections on the same signal both fire', () {
    var a = 0;
    var b = 0;
    connectSignal(object, 'dartgir-helper-test', () => a++);
    connectSignal(object, 'dartgir-helper-test', () => b++);
    _emitByName(object, 'dartgir-helper-test');
    expect(a, 1);
    expect(b, 1);
  });
}
