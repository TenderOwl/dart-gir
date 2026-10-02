/// Emits `*Callback` convenience overloads for GIO-style `*_async` methods.
///
/// The base wrapper (`CallableEmitter`) emits the canonical GLib callback
/// shape:
///
/// ```dart
/// void open(GtkWindow? parent, GCancellable? cancellable,
///           GAsyncReadyCallback? callback, ffi.Pointer<ffi.Void> userData);
/// ```
///
/// That wrapper is **unsafe for long-lived sources**: it allocates a
/// `NativeCallable`, passes its pointer to GLib, then closes the
/// `NativeCallable` in `finally` — leaving a dangling C function pointer
/// when GLib later dispatches the callback from the main loop.
///
/// The `*Callback` overload this emitter generates replaces the
/// `NativeCallable` with a permanent `Pointer.fromFunction` over a
/// static trampoline + a per-call registry:
///
/// ```dart
/// void openCallback(GtkWindow? parent, GCancellable? cancellable,
///                   void Function(GObject? sourceObject,
///                                 GAsyncResult result) topLevel);
///
/// static final _openCallbackRegistry =
///     <int, void Function(GObject?, GAsyncResult)>{};
/// static int _openCallbackSeq = 0;
/// static final _openCallbackPtr =
///     ffi.Pointer.fromFunction<ffi.Void Function(
///         ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
///         ffi.Pointer<ffi.Void>)>(_openCallbackTrampoline);
///
/// static void _openCallbackTrampoline(
///   ffi.Pointer<ffi.Void> src,
///   ffi.Pointer<ffi.Void> res,
///   ffi.Pointer<ffi.Void> data,
/// ) {
///   final id = data.cast<ffi.IntPtr>().value;
///   final fn = _openCallbackRegistry.remove(id);
///   malloc.free(data);
///   if (fn != null) {
///     fn(src == ffi.nullptr
///            ? null
///            : GObject.fromPointer(src.cast()),
///        GAsyncResult.fromPointer(res.cast()));
///   }
/// }
/// ```
///
/// The `Pointer.fromFunction` is permanent (lifetime = program), the
/// trampoline is a static method so `Pointer.fromFunction` accepts it,
/// and the per-call id (carried in the `data` pointer) routes the
/// dispatch back to the user's typed callback. No `NativeCallable` to
/// close, no dangling pointer risk.
///
/// The user-facing callback signature is typed (`GObject?`,
/// `GAsyncResult`) for `GAsyncReadyCallback`. For other async callbacks
/// the signature falls back to the FFI-compatible shape with
/// `Pointer<Void>` parameters.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import 'context.dart';

class AsyncCallbackEmitter {
  AsyncCallbackEmitter(this.ctx);

  final EmitContext ctx;

  /// Returns true when [m] has at least one in-parameter that is a
  /// callback with `scope="async"` (the GLib marker for async callbacks).
  bool hasAsyncCallback(GirFunction m) {
    return m.parameters.any((p) =>
        p.scope == 'async' &&
        p.direction == GirParameterDirection.in_ &&
        p.type != null);
  }

  /// Returns the parameter whose `scope="async"` AND whose type is a
  /// `GAsyncReadyCallback` (the GLib async-result callback). Returns
  /// null when there isn't one — methods with only other async
  /// callbacks (e.g. progress callbacks) skip the convenience
  /// overload.
  GirParameter? _asyncCallbackParam(GirFunction m) {
    for (final p in m.parameters) {
      if (p.scope != 'async') continue;
      if (p.direction != GirParameterDirection.in_) continue;
      if (_shortName(p.type?.name ?? '') == 'AsyncReadyCallback') {
        return p;
      }
    }
    return null;
  }

  /// Returns the user_data parameter — GLib convention is that the
  /// parameter immediately after the async callback carries the
  /// closure's state. (GIR's `closure="N"` attribute targets the same
  /// parameter but the indexing is ambiguous in mixed-arity cases; we
  /// rely on positional consistency instead.)
  GirParameter? _userDataParam(GirFunction m, GirParameter cb) {
    final params = m.parameters;
    final idx = params.indexOf(cb);
    if (idx < 0 || idx + 1 >= params.length) return null;
    final next = params[idx + 1];
    if (next.direction != GirParameterDirection.in_) return null;
    return next;
  }

  /// The Dart type the user's callback should have when calling the
  /// `*Callback` overload. For `GAsyncReadyCallback` we render the
  /// typed shape (`GObject?`, `GAsyncResult`); for everything else we
  /// fall back to the FFI-compatible `Pointer<Void>` shape.
  ///
  /// Returns null when the callback type can't be resolved.
  String? _userCallbackType(GirParameter p) {
    final typeName = p.type?.name;
    if (typeName == null) return null;
    // Special case: GAsyncReadyCallback. The signature is fixed:
    //   void Function(GObject? sourceObject, GAsyncResult result)
    if (_shortName(typeName) == 'AsyncReadyCallback') {
      return 'void Function(GObject?, GAsyncResult)';
    }
    // Fallback: keep the FFI-compatible shape so the callback works
    // with Pointer.fromFunction. The user's body casts manually.
    return null;
  }

  /// `Gio.AsyncReadyCallback` → `AsyncReadyCallback`.
  static String _shortName(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1) : name;
  }

  /// Generates the `*Callback` overload + per-method registry /
  /// trampoline / pointer cache, given [m] (the `*_async` method)
  /// and the already-emitted base wrapper's native binding name
  /// ([nativeBindingName]) which the overload reuses.
  ///
  /// [className] is the Dart class name (e.g. `GtkFileDialog`).
  /// [selfArgExpr] is the expression passed as the first native arg
  /// for instance methods (e.g. `'this.handle'`).
  ///
  /// Returns null when the callback type can't be resolved (caller
  /// should skip and record a reason).
  String? emitMethodOverload(
    GirMethod m, {
    required String dartName,
    required String className,
    required String selfArgExpr,
    required String nativeBindingName,
  }) {
    final cb = _asyncCallbackParam(m);
    if (cb == null) return null;
    final userData = _userDataParam(m, cb);
    final userType = _userCallbackType(cb);
    if (userType == null) return null;

    final methodName = '${dartName}Callback';
    final trampolineName = '_${dartName}CallbackTrampoline';
    final registryName = '_${dartName}CallbackRegistry';
    final seqName = '_${dartName}CallbackSeq';
    final ptrName = '_${dartName}CallbackPtr';

    // Build the convenience overload's signature: same params as the
    // base method, minus `callback` (which becomes the typed
    // userType), minus `userData` (always ffi.nullptr internally).
    final overloadParams = <_OverloadParam>[];
    for (final p in m.parameters) {
      if (identical(p, cb)) {
        overloadParams.add(_OverloadParam(
          name: toLowerCamel(p.name),
          bridgeType: userType,
          isCallback: true,
        ));
        continue;
      }
      // Skip userData — the convenience overload always passes null.
      if (userData != null && identical(p, userData)) continue;
      final (bridge, reason) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
      );
      if (bridge == null) {
        ctx.report.skip(
          'method',
          '$className.$methodName',
          'parameter ${p.name}: $reason',
        );
        return null;
      }
      overloadParams.add(_OverloadParam(
        name: toLowerCamel(p.name),
        bridgeType: bridge.wrapperType,
        bridge: bridge,
      ));
    }

    // Optional parameters: a trailing run of nullable params becomes
    // optional positional `[...]`.
    final requiredParams = <String>[];
    final optionalParams = <String>[];
    for (var i = 0; i < overloadParams.length; i++) {
      final p = overloadParams[i];
      final isOptional = p.bridgeType.endsWith('?') &&
          overloadParams.skip(i).every((q) => q.bridgeType.endsWith('?'));
      final decl = '${p.bridgeType} ${p.name}';
      if (isOptional) {
        optionalParams.add(decl);
      } else {
        requiredParams.add(decl);
      }
    }
    var paramList = requiredParams.join(', ');
    if (optionalParams.isNotEmpty) {
      paramList +=
          '${requiredParams.isEmpty ? '' : ', '}[${optionalParams.join(', ')}]';
    }

    // Build the call to the underlying native binding. The trampoline
    // pointer and the malloc'd id-encoded data slot in at the
    // callback + user_data positions; everything else is passed
    // through in declaration order. This matters when other parameters
    // appear after the callback/user_data pair (e.g.
    // `g_simple_async_report_gerror_in_idle` takes an extra `error`
    // argument at the end).
    //
    // Callback-typed IN parameters other than the `cb` async-result
    // callback (e.g. `progressCallback` on
    // `gtk_source_file_loader_load_async`) are NOT replaced by the
    // user's typed function directly at the call site — the C side
    // expects `Pointer<NativeFunction<…>>`, so we allocate a
    // `NativeCallable` local before the call and pass
    // `nc.nativeFunction`. The locals are closed in a `finally` block
    // below, matching the lifecycle `CallableEmitter` already uses
    // for ordinary callbacks.
    final callbackAllocs = <_CallbackAlloc>[];
    final nativeArgs = <String>[selfArgExpr];
    for (var i = 0; i < m.parameters.length; i++) {
      final p = m.parameters[i];
      if (identical(p, cb)) {
        nativeArgs.add(ptrName);
        continue;
      }
      if (userData != null && identical(p, userData)) {
        nativeArgs.add('_data.cast<ffi.Void>()');
        continue;
      }
      final overloadParam = overloadParams.firstWhere(
        (x) => x.name == toLowerCamel(p.name),
      );
      final (bridge, _) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
      );
      if (bridge == null) return null;
      if (p.direction == GirParameterDirection.out) {
        continue;
      }
      if (bridge.isString) {
        nativeArgs.add('${overloadParam.name}.cast<Utf8>()');
      } else if (_isCallbackBridge(bridge)) {
        // Allocate a `NativeCallable` local, pass its function pointer.
        final ncName = '_nc${callbackAllocs.length + 1}';
        callbackAllocs.add(_CallbackAlloc(ncName, overloadParam.name, bridge));
        nativeArgs.add(
          bridge.isNullableCallback
              ? '$ncName?.nativeFunction ?? ffi.nullptr'
              : '$ncName.nativeFunction',
        );
      } else {
        nativeArgs.add(bridge.toNative(overloadParam.name));
      }
    }
    final callExpr = '$nativeBindingName(${nativeArgs.join(', ')})';

    // String params need withNativeString wrapping; collect them in
    // reverse order for proper nesting.
    final stringIns = m.parameters
        .where((p) =>
            p.direction == GirParameterDirection.in_ &&
            p.type != null &&
            _bridgeIsString(ctx, p))
        .toList();
    final listIns = m.parameters
        .where((p) =>
            p.direction == GirParameterDirection.in_ &&
            p.type != null &&
            _bridgeIsStringList(ctx, p))
        .toList();

    final b = StringBuffer();

    // Registry (Map) + sequence counter.
    b.writeln('static final $registryName = '
        '<int, $userType>{};');
    b.writeln('static int $seqName = 0;');

    // Permanent function pointer via Pointer.fromFunction.
    b.writeln(
      'static final $ptrName = ffi.Pointer.fromFunction<'
      'ffi.Void Function('
      'ffi.Pointer<ffi.Void>, '
      'ffi.Pointer<ffi.Void>, '
      'ffi.Pointer<ffi.Void>'
      ')>($trampolineName);',
    );

    // Trampoline: looks up the user's typed callback by id (encoded
    // in the data pointer), casts source/res, then calls it.
    b.writeln('static void $trampolineName(');
    b.writeln('  ffi.Pointer<ffi.Void> sourceObject,');
    b.writeln('  ffi.Pointer<ffi.Void> res,');
    b.writeln('  ffi.Pointer<ffi.Void> data,');
    b.writeln(') {');
    b.writeln('  final id = data.cast<ffi.IntPtr>().value;');
    b.writeln('  final fn = $registryName.remove(id);');
    b.writeln('  malloc.free(data);');
    b.writeln('  if (fn == null) return;');
    b.writeln('  fn(');
    b.writeln(
      '    sourceObject == ffi.nullptr',
    );
    b.writeln('        ? null');
    b.writeln('        : GObject.fromPointer(sourceObject.cast()),');
    b.writeln('    GAsyncResult.fromPointer(res.cast()),');
    b.writeln('  );');
    b.writeln('}');

    // Convenience overload method.
    b.writeln('/// Lifetime-safe variant of [$dartName] for use with');
    b.writeln('/// async callbacks. See `docs/async.md`.');
    b.writeln('void $methodName($paramList) {');
    // Allocate `NativeCallable` locals for any non-`cb` callback
    // parameters so the C call receives a function pointer (not the
    // wrapper instance). Mirrors the lifecycle `CallableEmitter`
    // already uses for ordinary callbacks. Closed in the `finally`
    // block at the end of this method.
    for (final c in callbackAllocs) {
      b.writeln('  final ${c.varName} = ${c.bridge.toNative(c.paramName)};');
    }
    b.writeln('  final id = ++$seqName;');
    b.writeln('  $registryName'
        '[id] = ${toLowerCamel(cb.name)};');
    b.writeln('  final _data = malloc<ffi.IntPtr>()..value = id;');
    if (callbackAllocs.isNotEmpty) {
      b.writeln('  try {');
      if (stringIns.isNotEmpty || listIns.isNotEmpty) {
        var body = '    $callExpr;';
        for (var i = stringIns.length - 1; i >= 0; i--) {
          final p = stringIns[i];
          final paramName = toLowerCamel(p.name);
          body =
              '    withNativeString($paramName, ($paramName) {\n  $body\n});';
        }
        for (var i = listIns.length - 1; i >= 0; i--) {
          final p = listIns[i];
          final paramName = toLowerCamel(p.name);
          body =
              '    withNativeStringList($paramName, ($paramName) {\n  $body\n});';
        }
        b.writeln(body);
      } else {
        b.writeln('    $callExpr;');
      }
      b.writeln('  } finally {');
      for (final c in callbackAllocs) {
        final closeExpr = c.bridge.isNullableCallback
            ? '${c.varName}?.close()'
            : '${c.varName}.close()';
        b.writeln('    $closeExpr;');
      }
      b.writeln('  }');
    } else if (stringIns.isNotEmpty || listIns.isNotEmpty) {
      // Wrap with string / string-list scope.
      var body = '$callExpr;';
      for (var i = stringIns.length - 1; i >= 0; i--) {
        final p = stringIns[i];
        final paramName = toLowerCamel(p.name);
        body = 'withNativeString($paramName, ($paramName) {\n  $body\n});';
      }
      for (var i = listIns.length - 1; i >= 0; i--) {
        final p = listIns[i];
        final paramName = toLowerCamel(p.name);
        body =
            'withNativeStringList($paramName, ($paramName) {\n  $body\n});';
      }
      b.writeln('  $body');
    } else {
      b.writeln('  $callExpr;');
    }
    b.write('}');
    return b.toString();
  }

  /// Convenience overload for namespace-level `<function>` elements
  /// (e.g. `g_file_query_info_async` lives on a record, but a future
  /// binding might surface an async namespace function). Mirrors
  /// [emitMethodOverload] but without an instance parameter.
  String? emitFunctionOverload(
    GirFunction fn, {
    required String dartName,
    required String ownerName,
    required String nativeBindingName,
  }) {
    final cb = _asyncCallbackParam(fn);
    if (cb == null) return null;
    final userData = _userDataParam(fn, cb);
    final userType = _userCallbackType(cb);
    if (userType == null) return null;

    final methodName = '${dartName}Callback';
    final trampolineName = '_${dartName}CallbackTrampoline';
    final registryName = '_${dartName}CallbackRegistry';
    final seqName = '_${dartName}CallbackSeq';
    final ptrName = '_${dartName}CallbackPtr';

    final overloadParams = <_OverloadParam>[];
    for (final p in fn.parameters) {
      if (identical(p, cb)) {
        overloadParams.add(_OverloadParam(
          name: toLowerCamel(p.name),
          bridgeType: userType,
          isCallback: true,
        ));
        continue;
      }
      if (userData != null && identical(p, userData)) continue;
      final (bridge, reason) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
      );
      if (bridge == null) {
        ctx.report.skip(
          'function',
          '$ownerName.$methodName',
          'parameter ${p.name}: $reason',
        );
        return null;
      }
      overloadParams.add(_OverloadParam(
        name: toLowerCamel(p.name),
        bridgeType: bridge.wrapperType,
        bridge: bridge,
      ));
    }

    final requiredParams = <String>[];
    final optionalParams = <String>[];
    for (var i = 0; i < overloadParams.length; i++) {
      final p = overloadParams[i];
      final isOptional = p.bridgeType.endsWith('?') &&
          overloadParams.skip(i).every((q) => q.bridgeType.endsWith('?'));
      final decl = '${p.bridgeType} ${p.name}';
      if (isOptional) {
        optionalParams.add(decl);
      } else {
        requiredParams.add(decl);
      }
    }
    var paramList = requiredParams.join(', ');
    if (optionalParams.isNotEmpty) {
      paramList +=
          '${requiredParams.isEmpty ? '' : ', '}[${optionalParams.join(', ')}]';
    }

    final nativeArgs = <String>[];
    final stringIns = <GirParameter>[];
    final listIns = <GirParameter>[];
    final callbackAllocs = <_CallbackAlloc>[];
    for (final p in fn.parameters) {
      if (identical(p, cb)) {
        nativeArgs.add(ptrName);
        continue;
      }
      if (userData != null && identical(p, userData)) {
        nativeArgs.add('_data.cast<ffi.Void>()');
        continue;
      }
      final overloadParam = overloadParams.firstWhere(
        (x) => x.name == toLowerCamel(p.name),
      );
      final (bridge, _) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
      );
      if (bridge == null) return null;
      if (p.direction == GirParameterDirection.out) {
        continue;
      }
      if (bridge.isString) {
        stringIns.add(p);
        nativeArgs.add('${overloadParam.name}.cast<Utf8>()');
      } else if (bridge.isStringList) {
        listIns.add(p);
        nativeArgs.add(overloadParam.name);
      } else if (_isCallbackBridge(bridge)) {
        final ncName = '_nc${callbackAllocs.length + 1}';
        callbackAllocs.add(_CallbackAlloc(ncName, overloadParam.name, bridge));
        nativeArgs.add(
          bridge.isNullableCallback
              ? '$ncName?.nativeFunction ?? ffi.nullptr'
              : '$ncName.nativeFunction',
        );
      } else {
        nativeArgs.add(bridge.toNative(overloadParam.name));
      }
    }
    final callExpr = '$nativeBindingName(${nativeArgs.join(', ')})';

    final b = StringBuffer();
    // Top-level helpers for namespace functions (no `static` prefix).
    b.writeln('final $registryName = <int, $userType>{};');
    b.writeln('int $seqName = 0;');
    b.writeln(
      'final $ptrName = ffi.Pointer.fromFunction<'
      'ffi.Void Function('
      'ffi.Pointer<ffi.Void>, '
      'ffi.Pointer<ffi.Void>, '
      'ffi.Pointer<ffi.Void>'
      ')>($trampolineName);',
    );
    b.writeln('void $trampolineName(');
    b.writeln('  ffi.Pointer<ffi.Void> sourceObject,');
    b.writeln('  ffi.Pointer<ffi.Void> res,');
    b.writeln('  ffi.Pointer<ffi.Void> data,');
    b.writeln(') {');
    b.writeln('  final id = data.cast<ffi.IntPtr>().value;');
    b.writeln('  final fn = $registryName.remove(id);');
    b.writeln('  malloc.free(data);');
    b.writeln('  if (fn == null) return;');
    b.writeln('  fn(');
    b.writeln('    sourceObject == ffi.nullptr');
    b.writeln('        ? null');
    b.writeln('        : GObject.fromPointer(sourceObject.cast()),');
    b.writeln('    GAsyncResult.fromPointer(res.cast()),');
    b.writeln('  );');
    b.writeln('}');
    b.writeln('/// Lifetime-safe variant of [$dartName] for use with');
    b.writeln('/// async callbacks. See `docs/async.md`.');
    b.writeln('void $methodName($paramList) {');
    // Allocate `NativeCallable` locals for any non-`cb` callback
    // parameters so the C call receives a function pointer (not the
    // wrapper instance). Mirrors the lifecycle `CallableEmitter`
    // already uses for ordinary callbacks. Closed in the `finally`
    // block at the end of this method.
    for (final c in callbackAllocs) {
      b.writeln('  final ${c.varName} = ${c.bridge.toNative(c.paramName)};');
    }
    b.writeln('  final id = ++$seqName;');
    b.writeln('  $registryName[id] = ${toLowerCamel(cb.name)};');
    b.writeln('  final _data = malloc<ffi.IntPtr>()..value = id;');
    if (callbackAllocs.isNotEmpty) {
      b.writeln('  try {');
      if (stringIns.isNotEmpty || listIns.isNotEmpty) {
        var body = '    $callExpr;';
        for (var i = stringIns.length - 1; i >= 0; i--) {
          final p = stringIns[i];
          final paramName = toLowerCamel(p.name);
          body =
              '    withNativeString($paramName, ($paramName) {\n  $body\n});';
        }
        for (var i = listIns.length - 1; i >= 0; i--) {
          final p = listIns[i];
          final paramName = toLowerCamel(p.name);
          body = '    withNativeStringList($paramName, ($paramName) {\n'
              '  $body\n});';
        }
        b.writeln(body);
      } else {
        b.writeln('    $callExpr;');
      }
      b.writeln('  } finally {');
      for (final c in callbackAllocs) {
        final closeExpr = c.bridge.isNullableCallback
            ? '${c.varName}?.close()'
            : '${c.varName}.close()';
        b.writeln('    $closeExpr;');
      }
      b.writeln('  }');
    } else if (stringIns.isNotEmpty || listIns.isNotEmpty) {
      var body = '$callExpr;';
      for (var i = stringIns.length - 1; i >= 0; i--) {
        final p = stringIns[i];
        final paramName = toLowerCamel(p.name);
        body = 'withNativeString($paramName, ($paramName) {\n  $body\n});';
      }
      for (var i = listIns.length - 1; i >= 0; i--) {
        final p = listIns[i];
        final paramName = toLowerCamel(p.name);
        body =
            'withNativeStringList($paramName, ($paramName) {\n  $body\n});';
      }
      b.writeln('  $body');
    } else {
      b.writeln('  $callExpr;');
    }
    b.write('}');
    return b.toString();
  }

  static bool _bridgeIsString(EmitContext ctx, GirParameter p) {
    final (bridge, _) = ctx.bridgeFor(
      p.type,
      nullable: p.nullable,
      transfer: p.transferOwnership,
    );
    return bridge?.isString ?? false;
  }

  static bool _bridgeIsStringList(EmitContext ctx, GirParameter p) {
    final (bridge, _) = ctx.bridgeFor(
      p.type,
      nullable: p.nullable,
      transfer: p.transferOwnership,
    );
    return bridge?.isStringList ?? false;
  }

  /// True when [bridge]'s native side is a `Pointer<NativeFunction<…>>`
  /// (i.e. the parameter is a callback that the C side consumes). Mirrors
  /// the helper in `callable.dart` so the async emitter's allocation +
  /// close() lifecycle stays in sync with the rest of the generator.
  static bool _isCallbackBridge(TypeBridge bridge) {
    final n = bridge.nativeType;
    return n.startsWith('ffi.Pointer<ffi.NativeFunction<');
  }
}

class _CallbackAlloc {
  _CallbackAlloc(this.varName, this.paramName, this.bridge);
  final String varName;
  final String paramName;
  final TypeBridge bridge;
}

class _OverloadParam {
  _OverloadParam({
    required this.name,
    required this.bridgeType,
    this.bridge,
    this.isCallback = false,
  });

  final String name;
  final String bridgeType;
  final TypeBridge? bridge;
  final bool isCallback;
}
