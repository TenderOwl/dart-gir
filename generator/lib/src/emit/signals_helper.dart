/// Emits the per-package `signals.dart` helper file when at least one
/// GObject class or interface in the namespace has a `void(void)` signal
/// that we keep.
///
/// The generated file holds:
///   * the registry of callbacks keyed by an int we pass via user_data,
///   * the `_gSignalConnectData` FFI binding (looked up via
///     `gobjectLookup` because it is `introspectable="0"` in the GIR),
///   * a static trampoline that GObject invokes with the marshaler's
///     `(instance, user_data)` pair — looks up the Dart callback and runs
///     it,
///   * a destroy-notify trampoline that frees the int and removes the
///     registry entry when the closure is finalized,
///   * the `_connectVoidSignal` helper used by every emitted
///     `onSignalName` method, plus a public `connectVoidSignal` escape
///     hatch for signal names without a typed helper (inherited signals,
///     `detail`-qualified names, non-`void(void)` arities we don't
///     trampoline yet).
library;

import 'context.dart';
import 'library_emitter.dart' show generatedHeader;
import 'signals_emitter.dart' show isKeptSignal;

export 'signals_emitter.dart' show isKeptSignal;

/// Returns the contents of `signals.dart` for the package whose namespace
/// is in [ctx], or `null` if no class or interface has a kept void(void)
/// signal.
///
/// Side effects: the helper needs `package:ffi` (calloc/Utf8), `dart:ffi`,
/// and `gobjectLookup` from `package:gobject`, so it sets the usage flags
/// and cross-import the barrel library picks up.
String? emitSignalsHelper(EmitContext ctx) {
  final hasAny =
      ctx.namespace.classes.any((c) => c.signals.any(isKeptSignal)) ||
          ctx.namespace.interfaces.any((i) => i.signals.any(isKeptSignal));
  if (!hasAny) return null;

  ctx.usesGirFfi = true;
  ctx.usesMalloc = true; // calloc
  ctx.usesFfiString = true; // Utf8 / toNativeUtf8
  final pkg = ctx.pkg;
  if (pkg != 'gobject') ctx.imports.add('gobject');

  return '''
$generatedHeader
part of '../$pkg.dart';

/// Registry of callbacks for `void(void)` signals, keyed by an int we
/// pass via `g_signal_connect_data` as the user_data pointer. The pointer
/// is heap-allocated by `_connectVoidSignal` and freed by
/// `_destroyVoidSignalState` when the closure is finalized.
final _voidSignalRegistry = <int, void Function()>{};
int _nextVoidSignalId = 1;

final _gSignalConnectData = gobjectLookup<
      ffi.NativeFunction<
        ffi.Uint64 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<
            ffi.NativeFunction<
              ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
            >
          >,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<
            ffi.NativeFunction<
              ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
            >
          >,
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
        ffi.Pointer<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
          >
        >,
        int,
      )
    >();

/// Trampoline invoked by GObject's default `g_cclosure_marshal_VOID__VOID`.
/// It receives `(instance, user_data)`; `user_data` is our heap-allocated
/// `IntPtr` whose value is the key into [_voidSignalRegistry].
void _voidSignalTrampoline(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
) {
  final id = userData.cast<ffi.IntPtr>().value;
  _voidSignalRegistry[id]!();
}

/// Destroy-notify called by GObject when the closure is freed (signal
/// disconnected or object finalized). Frees the `IntPtr` we allocated
/// and removes the registry entry so the Dart callback becomes
/// unreachable.
void _destroyVoidSignalState(
  ffi.Pointer<ffi.Void> data,
  ffi.Pointer<ffi.Void> closure,
) {
  final id = data.cast<ffi.IntPtr>().value;
  calloc.free(data);
  _voidSignalRegistry.remove(id);
}

/// App-lifetime singletons. Never closed — the trampolines must stay
/// reachable for as long as any signal connection is alive. Process exit
/// reclaims the native resources.
final _voidSignalTrampolineCallable =
    ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
    >.isolateLocal(_voidSignalTrampoline);

final _destroyVoidSignalStateCallable =
    ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
    >.isolateLocal(_destroyVoidSignalState);

/// Registers [callback] against [signalName] on [instance] via
/// `g_signal_connect_data`. Returns the handler ID.
int _connectVoidSignal(
  ffi.Pointer<ffi.Void> instance,
  String signalName,
  void Function() callback,
) {
  final id = _nextVoidSignalId++;
  _voidSignalRegistry[id] = callback;
  final idPtr = calloc<ffi.IntPtr>()..value = id;
  final namePtr = signalName.toNativeUtf8();
  try {
    return _gSignalConnectData(
      instance,
      namePtr.cast<Utf8>(),
      _voidSignalTrampolineCallable.nativeFunction,
      idPtr.cast(),
      _destroyVoidSignalStateCallable.nativeFunction,
      0,
    );
  } finally {
    calloc.free(namePtr);
  }
}

/// Connects [callback] to [signalName] on [instance] and returns the
/// handler ID. This is the low-level escape hatch behind the typed
/// `onSignalName` methods — use it for inherited signals, detailed signal
/// names (`notify::property-name`), or arities the typed helpers don't
/// cover yet.
int connectVoidSignal(
  ffi.Pointer<ffi.Void> instance,
  String signalName,
  void Function() callback,
) =>
    _connectVoidSignal(instance, signalName, callback);
''';
}
