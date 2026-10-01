/// Emits the per-package `signals.dart` helper file when at least one
/// GObject class or interface in the namespace has a typed signal we
/// keep.
///
/// For every kept signal, [emitSignalConnectors] emits an
/// `onSignalName(<typed callback>)` method that delegates to a
/// per-bucket `_connectSignal_<bucketId>` helper. The helper, in turn,
/// calls `g_signal_connect_data` with a per-bucket `NativeCallable`
/// trampoline and a heap-allocated `IntPtr` holding a unique id. The
/// trampoline reads the id from `user_data`, looks up the Dart callback
/// in the bucket's registry, converts FFI args to Dart types, runs the
/// callback, then frees any `transfer-none` strings with `g_free`.
///
/// The generated file holds, per bucket:
///   * the registry of callbacks keyed by an int we pass via user_data,
///   * the per-bucket trampoline (FFI shape matches the bucket),
///   * the per-bucket `_connectSignal_<bucketId>` helper used by every
///     emitted `onSignalName` method,
///   * a per-bucket `NativeCallable` for the trampoline.
///
/// Across all buckets, a single destroy-notify + `_signalRegistryOwner`
/// map free the id and remove it from the owning bucket's registry.
///
/// In addition, `connectSignal` is the low-level escape hatch for signal
/// names without a typed helper — detailed signal names like
/// `notify::property-name`, or arities the typed helpers don't cover
/// yet (none in the current corpus).
library;

import '../gir/gir.dart';
import 'context.dart';
import 'library_emitter.dart' show generatedHeader;
import 'signals_emitter.dart';

export 'signals_emitter.dart' show isKeptSignal;

/// Returns the contents of `signals.dart` for the package whose namespace
/// is in [ctx], or `null` if no class or interface has a kept signal.
///
/// Side effects: the helper needs `package:ffi` (calloc/Utf8), `dart:ffi`,
/// `gobjectLookup` from `package:gobject` (for `g_signal_connect_data`),
/// and `gFree` from `package:gir_ffi` (for `transfer-none` strings).
String? emitSignalsHelper(EmitContext ctx) {
  final kept = _allSignals(ctx)
      .where((e) => isKeptSignal(e.signal, ctx, relativeTo: e.ns));
  if (kept.isEmpty) return null;

  final all = _allSignals(ctx).toList();
  final buckets = buildSignalBuckets(all, ctx);

  ctx.usesGirFfi = true;
  ctx.usesMalloc = true; // calloc
  ctx.usesFfiString = true; // Utf8 / toNativeUtf8
  final pkg = ctx.pkg;
  if (pkg != 'gobject') ctx.imports.add('gobject');
  if (pkg != 'gir_ffi') ctx.imports.add('gir_ffi');

  final b = StringBuffer()..writeln(generatedHeader);
  b.writeln("part of '../$pkg.dart';");
  b.writeln();
  b.writeln('/// `g_signal_connect_data` is `introspectable="0"` in the GIR,');
  b.writeln('/// so it is looked up via [gobjectLookup] at runtime.');
  b.writeln(
    _gSignalConnectDataBinding,
  );
  b.writeln();

  // Shared destroy-notify plumbing.
  b.writeln('/// Maps each live signal-handler id to the bucket-specific');
  b.writeln('/// registry the destroy-notify trampoline should clean up.');
  b.writeln('final _signalRegistryOwner = <int, Map<int, Function>>{};');
  b.writeln('int _nextSignalId = 1;');
  b.writeln();
  b.writeln('/// Shared destroy-notify invoked by GObject when the closure is');
  b.writeln('/// finalized (signal disconnected or object destroyed). Frees the');
  b.writeln('/// `IntPtr` and removes the registry entry so the Dart callback');
  b.writeln('/// becomes unreachable.');
  b.writeln('void _destroySignalState(');
  b.writeln('  ffi.Pointer<ffi.Void> data,');
  b.writeln('  ffi.Pointer<ffi.Void> closure,');
  b.writeln(') {');
  b.writeln('  final id = data.cast<ffi.IntPtr>().value;');
  b.writeln('  calloc.free(data);');
  b.writeln('  _signalRegistryOwner.remove(id)?.remove(id);');
  b.writeln('}');
  b.writeln();

  b.writeln(
    'final _destroySignalStateCallable = ffi.NativeCallable<',
  );
  b.writeln(
    '  ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)',
  );
  b.writeln('>.isolateLocal(_destroySignalState);');
  b.writeln();

  // Per-bucket state. Emit a synthetic `v_0_` bucket when none exists
  // yet — the public `connectSignal` escape hatch delegates to it.
  var emittedFallback = false;
  if (!buckets.signatures.containsKey('v_0_')) {
    _emitBucket(b, 'v_0_', _voidVoidSignature());
    emittedFallback = true;
  }
  for (final entry in buckets.signatures.entries) {
    if (emittedFallback && entry.key == 'v_0_') continue;
    _emitBucket(b, entry.key, entry.value);
  }

  // Public escape hatch.
  b.writeln('/// Connects [callback] to [signalName] on [instance] via');
  b.writeln('/// `g_signal_connect_data`. Returns the handler ID. This is the');
  b.writeln('/// low-level escape hatch behind the typed `onSignalName`');
  b.writeln('/// methods — use it for inherited signals, detailed signal names');
  b.writeln('/// (`notify::property-name`), or signatures the typed helpers');
  b.writeln('/// don\'t cover yet.');
  b.writeln('int connectSignal(');
  b.writeln('  ffi.Pointer<ffi.Void> instance,');
  b.writeln('  String signalName,');
  b.writeln('  void Function() callback,');
  b.writeln(') {');
  b.writeln('  return _connectSignal_v_0_(instance, signalName, callback);');
  b.writeln('}');

  return b.toString();
}

/// Synthetic `v_0_` signature for the public escape hatch. Like every
/// bucket, the trampoline receives `(instance, userData)` from
/// `g_cclosure_marshal_VOID__VOID` — both parameters are added by the
/// emission loop, so [shapes] and [argNames] stay empty.
SignalSignature _voidVoidSignature() => SignalSignature(
      bucketId: 'v_0_',
      marshallerReturn: ReturnShape.void_,
      shapes: const [],
      dartReturnType: 'void',
      trampolineFfiType:
          'ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)',
      callbackType: 'void Function()',
      argNames: const [],
      argMarshals: const [],
    );

/// All signals declared on classes and interfaces in the current
/// namespace, including signals inherited from ancestor classes. The
/// per-bucket `_connectSignal_<bucketId>` helper is emitted once per
/// package; it must cover every signal any class in the package can
/// connect via a typed `onSignalName` method. Each entry carries the
/// originating [GirNamespace] so arg/return types resolve against the
/// namespace the signal was authored in (Gtk's `Window` vs. Adw's
/// `Window`).
///
/// Dedup uses identity (`identical`) — two signals with the same name
/// but different owning types (e.g. `interface-added` on both
/// `Gio.DBusObject` and `Gio.DBusObjectManager`) must NOT be merged
/// because they have different bucket shapes.
Iterable<({GirSignal signal, GirNamespace? ns})> _allSignals(
  EmitContext ctx,
) sync* {
  final seen = <GirSignal>{};
  for (final c in ctx.namespace.classes) {
    yield* _signalsIncludingAncestors(c, ctx, seen);
  }
  for (final i in ctx.namespace.interfaces) {
    for (final s in i.signals) {
      if (seen.add(s)) {
        yield (signal: s, ns: ctx.namespace);
      }
    }
  }
}

Iterable<({GirSignal signal, GirNamespace? ns})> _signalsIncludingAncestors(
  GirClass cls,
  EmitContext ctx,
  Set<GirSignal> seen,
) sync* {
  var current = cls;
  var currentNs = ctx.namespace;
  final seenClasses = <String>{};
  while (seenClasses.add('${currentNs.name}.${current.name}')) {
    for (final s in current.signals) {
      if (seen.add(s)) {
        yield (signal: s, ns: currentNs);
      }
    }
    if (current.parent == null) break;
    final found = ctx.findClass(current.parent!);
    if (found == null) break;
    currentNs = found.$1;
    current = found.$2;
  }
}

/// Shared FFI binding for `g_signal_connect_data`. The C handler pointer
/// is typed as `Pointer<NativeFunction<void Function(Pointer<Void>,
/// Pointer<Void>)>>` — at the C ABI level, GLib's marshaller passes
/// `(instance, user_data, ...signal_args)` to the trampoline, and any
/// trampoline with `(Pointer<Void>, Pointer<Void>, ...)` first two args
/// is assignable to this signature via `cast`.
const _gSignalConnectDataBinding = r'''
final _gSignalConnectData = gobjectLookup<
      ffi.NativeFunction<
        ffi.Uint64 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<Utf8>,
          ffi.Pointer<ffi.NativeFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.NativeFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>>,
          ffi.Uint32,
        )
      >
    >('g_signal_connect_data')
    .asFunction<
      int Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<Utf8>,
        ffi.Pointer<ffi.NativeFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>>,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.NativeFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>>,
        int,
      )
    >();
''';

/// Emits the per-bucket singleton, trampoline, registry, and connect helper.
void _emitBucket(StringBuffer b, String bucketId, SignalSignature sig) {
  // 1. Registry — typed map keyed by handler id.
  b.writeln(
    '/// Registry of Dart callbacks for bucket `$bucketId`. Keyed by an int',
  );
  b.writeln('/// we pass via `g_signal_connect_data` as the user_data pointer.');
  b.writeln(
    'final _signalRegistry_$bucketId = <int, ${sig.callbackType}>{};',
  );
  b.writeln();

  // 2. Trampoline — receives FFI args + user_data, looks up the Dart
  //    callback, converts arg types, calls it, frees strings.
  b.writeln('/// Trampoline invoked by GObject for bucket `$bucketId`. Reads');
  b.writeln('/// the handler id from `user_data`, converts the FFI args, and');
  b.writeln('/// runs the Dart callback.');
  b.writeln('${sig.dartReturnType} _signalTrampoline_$bucketId(');
  // GLib's marshaller passes the instance first, then the signal args,
  // then the user_data pointer.
  final ffParams = <String>['ffi.Pointer<ffi.Void> instance_'];
  for (var i = 0; i < sig.shapes.length; i++) {
    final pname = sig.argNames[i];
    final dtype = sig.shapes[i].dartType;
    ffParams.add('$dtype $pname');
  }
  ffParams.add('ffi.Pointer<ffi.Void> userData');
  b.writeln('  ${ffParams.join(',\n  ')},');
  b.writeln(') {');
  b.writeln('  final id = userData.cast<ffi.IntPtr>().value;');
  b.writeln('  final cb = _signalRegistry_$bucketId[id]!;');
  final hasFrees = sig.shapes.contains(FfiShape.string);
  if (sig.marshallerReturn == ReturnShape.void_) {
    b.writeln('  cb(${sig.argMarshals.join(', ')});');
  } else if (hasFrees) {
    // Capture the result so transfer-none strings can still be freed
    // before returning (a bare `return cb(...)` would skip the frees).
    b.writeln('  final result = cb(${sig.argMarshals.join(', ')});');
  }
  // Free `transfer-none` strings after the callback returns: the closure
  // owns the receiver's string-args. Per the GIR convention,
  // `transfer-none` means the receiver (here: our Dart trampoline) must
  // call `g_free`.
  for (var i = 0; i < sig.shapes.length; i++) {
    final shape = sig.shapes[i];
    final pname = sig.argNames[i];
    if (shape == FfiShape.string) {
      b.writeln('  if (($pname) != ffi.nullptr) gFree(($pname).cast());');
    }
  }
  if (sig.marshallerReturn != ReturnShape.void_ && hasFrees) {
    b.writeln('  return result;');
  } else if (sig.marshallerReturn != ReturnShape.void_) {
    b.writeln('  return cb(${sig.argMarshals.join(', ')});');
  }
  b.writeln('}');
  b.writeln();

  // 3. Per-bucket NativeCallable — app-lifetime singleton. A non-void
  //    return type requires an `exceptionalReturn` fallback.
  b.writeln('/// Per-package singleton. Never closed — must stay reachable for');
  b.writeln('/// as long as any connection in this bucket is alive.');
  final exceptionalReturn = switch (sig.marshallerReturn) {
    ReturnShape.void_ => '',
    ReturnShape.int || ReturnShape.uint => ', exceptionalReturn: 0',
    ReturnShape.bool_ => ', exceptionalReturn: false',
    ReturnShape.double_ => ', exceptionalReturn: 0.0',
  };
  b.writeln(
    'final _signalCallable_$bucketId = ffi.NativeCallable<${sig.trampolineFfiType}>.isolateLocal(_signalTrampoline_$bucketId$exceptionalReturn);',
  );
  b.writeln();

  // 4. Connect helper used by every emitted onSignalName method.
  b.writeln('/// Registers [callback] against [signalName] on [instance] via');
  b.writeln('/// `g_signal_connect_data`. Returns the handler ID.');
  b.writeln('int _connectSignal_$bucketId(');
  b.writeln('  ffi.Pointer<ffi.Void> instance,');
  b.writeln('  String signalName,');
  b.writeln('  ${sig.callbackType} callback,');
  b.writeln(') {');
  b.writeln('  final id = _nextSignalId++;');
  b.writeln('  _signalRegistry_$bucketId[id] = callback;');
  b.writeln('  _signalRegistryOwner[id] = _signalRegistry_$bucketId;');
  b.writeln('  final idPtr = calloc<ffi.IntPtr>()..value = id;');
  b.writeln('  final namePtr = signalName.toNativeUtf8();');
  b.writeln('  try {');
  b.writeln('    return _gSignalConnectData(');
  b.writeln('      instance,');
  b.writeln('      namePtr.cast<Utf8>(),');
  b.writeln('      // Cast to `Pointer<NativeFunction<void Function(');
  b.writeln('      // Pointer<Void>, Pointer<Void>)>>` because');
  b.writeln('      // `g_signal_connect_data` is bound against that generic');
  b.writeln('      // signature; GLib dispatches via the signal\'s');
  b.writeln('      // registered marshaller at call time.');
  b.writeln('      _signalCallable_$bucketId.nativeFunction');
  b.writeln('          .cast<ffi.NativeFunction<');
  b.writeln('              void Function(');
  b.writeln('                ffi.Pointer<ffi.Void>,');
  b.writeln('                ffi.Pointer<ffi.Void>,');
  b.writeln('              )');
  b.writeln('            >>(),');
  b.writeln('      idPtr.cast(),');
  b.writeln('      _destroySignalStateCallable.nativeFunction,');
  b.writeln('      0,');
  b.writeln('    );');
  b.writeln('  } finally {');
  b.writeln('    calloc.free(namePtr);');
  b.writeln('  }');
  b.writeln('}');
  b.writeln();
}
