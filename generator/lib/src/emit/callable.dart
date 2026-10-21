/// Emits Dart wrappers for GIR callables (functions, methods, constructors).
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart';
import 'context.dart';

class _InParam {
  _InParam(this.name, this.bridge, {required this.paramIndex});
  final String name;
  final TypeBridge bridge;

  /// Index of the underlying [GirParameter] in the method's
  /// `fn.parameters` list. Needed because out parameters don't appear
  /// in `ins`, so the in-only index in `ins` would diverge from the
  /// outer parameter index used to look up callback allocations.
  final int paramIndex;

  String get nativeVar => 'native${name[0].toUpperCase()}${name.substring(1)}';
}

/// Metadata for a callback parameter that needs a `NativeCallable.isolateLocal`
/// wrapper (and a matching `.close()` after the call).
class _CallbackAlloc {
  _CallbackAlloc(this.varName, this.inParam);

  /// Local variable name holding the [ffi.NativeCallable] instance.
  final String varName;
  final _InParam inParam;
}

class _OutParam {
  _OutParam(this.varName, this.name, this.bridge, {required this.paramIndex});
  final String varName;
  final String name;
  final TypeBridge bridge;

  /// Index of the underlying [GirParameter] in `fn.parameters`. The
  /// byte count of a callee-allocated byte buffer is found through it.
  final int paramIndex;

  /// `true` when the value is consumed by another OUT parameter — the
  /// byte count of a callee-allocated byte buffer.
  ///
  /// The slot is still allocated and released like any other OUT slot,
  /// but the count is not a separate element of the returned record: the
  /// buffer is copied into a `Uint8List` that knows its own length.
  bool absorbed = false;
}

/// Emits a Dart wrapper (plus its private native binding) for a
/// [GirFunction]. Returns null when the callable is skipped; the reason is
/// recorded in the context report.
class CallableEmitter {
  CallableEmitter(this.ctx);

  final EmitContext ctx;

  static const _objectMembers = {
    'toString',
    'hashCode',
    'noSuchMethod',
    'runtimeType',
  };

  /// [dartName]: wrapper name (method/ctor name, or top-level function name).
  /// [selfArgExpr]: expression passed as first native argument for methods.
  /// [factoryClass]: when non-null, emits a factory constructor returning
  /// this class. [sinkFloating]: call `gObjectRefSink` on ctor results.
  String? emit(
    GirFunction fn, {
    required String dartName,
    required String ownerName,
    String? selfArgExpr,
    bool staticMember = false,
    bool classMember = false,
    String? factoryClass,
    bool factoryOwned = true,
    bool sinkFloating = false,
    GirNamespace? relativeTo,
  }) {
    final label = '$ownerName.$dartName';
    String? skipReason;
    if (!fn.introspectable) {
      // GIR marks C convenience macros (g_idle_add, g_array_new, …) as
      // `introspectable="0"` because they expand to the canonical sibling.
      // Surface the sibling in the skip report so users find the right
      // call without us duplicating the C ABI.
      final sibling = fn.shadows ?? fn.shadowedBy;
      skipReason = sibling != null
          ? 'introspectable=0 (C macro; use $sibling)'
          : 'introspectable=0';
    } else if (fn.cIdentifier == null) {
      skipReason = 'no c:identifier';
    } else if (fn.movedTo != null) {
      skipReason = 'moved to ${fn.movedTo}';
    } else if (fn.shadowedBy != null) {
      skipReason = 'shadowed by ${fn.shadowedBy}';
    } else if (fn.isVarargs) {
      skipReason = 'varargs';
    }
    if (skipReason != null) {
      ctx.report.skip('callable', label, skipReason);
      return null;
    }

    final ins = <_InParam>[];
    final outs = <_OutParam>[];
    final callbackAllocs = <_CallbackAlloc>[];
    // Bridges indexed by parameter position, in declaration order.
    final bridges = <int, TypeBridge>{};
    // The byte count of a callee-allocated byte buffer is consumed by
    // the buffer itself: the wrapper copies the bytes into a
    // `Uint8List` that knows its own length, so the count is not a
    // separate element of the returned record.
    final absorbedOutIndices = <int>{};
    for (final p in fn.parameters) {
      if (!TypeResolver.isByteBufferOut(p)) continue;
      absorbedOutIndices.add(p.type!.array!.lengthParameterIndex!);
    }

    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      final (bridge, reason) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
        direction: p.direction,
        callerAllocates: p.callerAllocates,
        relativeTo: relativeTo,
      );
      if (bridge == null) {
        ctx.report.skip('callable', label, 'parameter ${p.name}: $reason');
        return null;
      }
      bridges[i] = bridge;
      switch (p.direction) {
        case GirParameterDirection.in_:
          final paramName = escapeKeyword(toLowerCamel(p.name));
          final inParam = _InParam(paramName, bridge, paramIndex: i);
          ins.add(inParam);
          if (_isCallbackBridge(bridge)) {
            callbackAllocs.add(_CallbackAlloc('_nc${ins.length}', inParam));
          }
        case GirParameterDirection.inout:
          ctx.report.skip('callable', label, 'inout parameter ${p.name}');
          return null;
        case GirParameterDirection.out:
          // Both `caller-allocates="0"` (function allocates) and
          // `caller-allocates="1"` (caller allocates) reduce to the
          // same wrapper shape: malloc a buffer, pass its pointer,
          // read back the value after the call. The wrapper frees
          // the buffer in `finally` (always — the caller never sees
          // the raw pointer).
          if (bridge.outPointee == null) {
            ctx.report.skip(
              'callable',
              label,
              'unsupported out parameter ${p.name} (${bridge.wrapperType})',
            );
            return null;
          }
          outs.add(
            _OutParam('_out${outs.length}', p.name, bridge, paramIndex: i)
              ..absorbed = absorbedOutIndices.contains(i),
          );
      }
    }

    final (retBridge, retReason) = ctx.bridgeFor(
      fn.returnType,
      nullable: fn.returnNullable,
      transfer: fn.returnTransfer,
      forReturn: true,
      relativeTo: relativeTo,
    );
    if (retBridge == null) {
      ctx.report.skip('callable', label, 'return: $retReason');
      return null;
    }
    if (fn.throws) {
      ctx.usesGlibException = true;
      ctx.usesMalloc = true;
    }
    if (outs.isNotEmpty) ctx.usesMalloc = true;

    // Native + Dart FFI signatures, parameters in GIR order.
    final nativeParams = <String>[
      ?selfArgExpr == null ? null : 'ffi.Pointer<ffi.Void>',
    ];
    final dartParams = <String>[
      ?selfArgExpr == null ? null : 'ffi.Pointer<ffi.Void>',
    ];
    final argExprs = <String>[?selfArgExpr];
    // Pre-built arg expression for callback params: when we allocate a
    // NativeCallable above, the C side consumes its `.nativeFunction`.
    final callbackByParam = <int, _CallbackAlloc>{
      for (final c in callbackAllocs) c.inParam.paramIndex: c,
    };
    // Struct arguments the C API takes by pointer: each one needs a
    // native copy for the duration of the call.
    final structArgs = <({int index, String type, String param})>[];
    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      final bridge = bridges[i]!;
      if (p.direction == GirParameterDirection.out) {
        final o = outs.firstWhere((o) => o.name == p.name);
        // Native FFI parameter: the inner pointer type. For
        // record/class OUT params allocated as `calloc<Uint8>(N)`, the
        // buffer is `Pointer<Uint8>` and we cast at the call site.
        nativeParams.add('ffi.Pointer<${bridge.outPointee}>');
        dartParams.add('ffi.Pointer<${bridge.outPointee}>');
        argExprs.add(
          o.bridge.outAllocSize != null
              ? '${o.varName}.cast<ffi.Void>()'
              : o.varName,
        );
      } else {
        nativeParams.add(bridge.nativeType);
        dartParams.add(bridge.dartFfiType);
        final inP = ins.firstWhere(
          (x) => x.name == escapeKeyword(toLowerCamel(p.name)),
        );
        if (bridge.isString) {
          argExprs.add('${inP.nativeVar}.cast<Utf8>()');
        } else if (bridge.isStringList) {
          // The native signature uses `Pointer<Pointer<Utf8>>`, but the
          // wrapped pointer we get out of `withNativeStringList` is typed
          // as `Pointer<Pointer<Utf8>>` already — no cast needed here.
          argExprs.add(inP.nativeVar);
        } else if (callbackByParam.containsKey(i)) {
          // We allocated `_ncN` above; the native call uses its pointer.
          // Nullable callbacks store either a `NativeCallable` or `null`;
          // the null path passes `ffi.nullptr` to the native side.
          final cb = callbackByParam[i]!;
          argExprs.add(
            cb.inParam.bridge.isNullableCallback
                ? '${cb.varName}?.nativeFunction ?? ffi.nullptr'
                : '${cb.varName}.nativeFunction',
          );
        } else if (bridge.structArgType != null) {
          // The C API takes the struct by pointer; the caller passes it
          // by value. The emitter allocates a native copy for the call
          // and frees it afterwards.
          argExprs.add('_structArg$i');
          structArgs.add((
            index: i,
            type: bridge.structArgType!,
            param: inP.name,
          ));
        } else {
          argExprs.add(bridge.toNative(inP.name));
        }
      }
    }
    if (fn.throws) {
      nativeParams.add('ffi.Pointer<ffi.Pointer<ffi.Void>>');
      dartParams.add('ffi.Pointer<ffi.Pointer<ffi.Void>>');
      argExprs.add('_error');
    }

    final cId = fn.cIdentifier!;
    final nativeSig =
        'ffi.NativeFunction<${retBridge.nativeType} Function(${nativeParams.join(', ')})>';
    final dartSig =
        '${retBridge.dartFfiType} Function(${dartParams.join(', ')})';
    final lookupVar = '_${toLowerCamel(cId)}';
    final staticPrefix = staticMember ? 'static ' : '';
    // Inside a class the binding must be static so factory constructors and
    // static members can use it. asFunction/lookupFunction type arguments
    // must be constant, so no generic helper can be used here.
    final lookupDecl =
        "${staticMember || classMember ? 'static ' : ''}final $lookupVar = "
        "${ctx.pkgIdent}Lookup<$nativeSig>('$cId').asFunction<$dartSig>();";

    // Wrapper signature.
    final requiredParams = <String>[];
    final optionalParams = <String>[];
    for (var i = 0; i < ins.length; i++) {
      final p = ins[i];
      final isOptional =
          p.bridge.wrapperType.endsWith('?') &&
          ins.sublist(i).every((q) => q.bridge.wrapperType.endsWith('?'));
      final decl = '${p.bridge.wrapperType} ${p.name}';
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

    final returnType = _returnType(retBridge, outs);
    final String header;
    if (factoryClass != null) {
      header = dartName.isEmpty
          ? 'factory $factoryClass($paramList) {'
          : 'factory $factoryClass.$dartName($paramList) {';
    } else {
      header = '$staticPrefix$returnType $dartName($paramList) {';
    }

    // Body core.
    final core = <String>[];
    final hasAllocs = outs.isNotEmpty || fn.throws || structArgs.isNotEmpty;
    final hasCallbacks = callbackAllocs.isNotEmpty;
    final call = '$lookupVar(${argExprs.join(', ')})';

    // Subclassable emission for `<constructor>` (the `factoryClass`
    // branch): when the constructor has no `throws`, no OUT params,
    // no string / string-list parameters, and no callback
    // parameters, emit it as a generative constructor instead of a
    // `factory`. Generative constructors chain via `super(...)` from
    // subclasses; the existing factory body pattern made
    // `class MyAdwWindow extends AdwWindow { MyAdwWindow() : super(); }`
    // fail with "The generative constructor 'AdwWindow()' is
    // expected, but a factory was found." The generative form below
    // delegates to `fromPointer` via the super-call argument list,
    // which is evaluated before super runs. Classes with a parent
    // use `super.fromPointer`; records (no parent) use their own
    // `fromPointer` since there's no super.
    //
    // String / string-list parameters are excluded because the
    // factory path wraps them with `withNativeString` /
    // `withNativeStringList` for proper lifetime management
    // (the helper frees the allocated C buffer after the call).
    // A generative initializer list has no body — there's nowhere
    // to free a manually allocated `stringToNative(text)` pointer,
    // and calling `.cast<Utf8>()` directly on a `String?` user
    // parameter would not compile (String? has no `cast`).
    //
    // Callback parameters are excluded for the same reason: the
    // factory path allocates a `NativeCallable` local, passes
    // `.nativeFunction` to C, and `.close()`-s it in `finally`.
    // A generative initializer list has no body to host the
    // `.close()` — falling back to the factory form keeps the
    // lifecycle correct.
    final hasStringInSet = ins.any(
      (p) => p.bridge.isString || p.bridge.isStringList,
    );
    final hasCallback = callbackAllocs.isNotEmpty;
    // A struct argument needs a native copy for the call, and a
    // generative constructor has no body to allocate it in.
    final hasStructInSet = ins.any((p) => p.bridge.structArgType != null);
    if (factoryClass != null &&
        !fn.throws &&
        outs.isEmpty &&
        !hasStringInSet &&
        !hasCallback &&
        !hasStructInSet) {
      final ownedArg = factoryOwned ? ', owned: true' : '';
      // `this.fromPointer` is always valid — every generated class
      // (and record) declares a `fromPointer` named constructor that
      // initializes the inherited `handle` / `owned` fields. The
      // original code emitted `super.fromPointer` for subclassable
      // classes and `this.fromPointer` for root classes (records),
      // but Dart rejects `super.fromPointer` on a class with no
      // declared parent (`final_not_initialized_constructor`,
      // `undefined_constructor_in_initializer` — see
      // `packages/gobject/lib/src/gobject.dart` for `GObject.newv`).
      // Routing every generative constructor through the same class's
      // `fromPointer` works for both shapes — the call delegates up
      // to the parent automatically because `fromPointer` forwards to
      // its own super when one exists.
      // `rawFromPointer` is the generative constructor; `fromPointer` is
      // a factory (it consults the wrapper cache) and a generative
      // constructor may not redirect to a factory.
      final receiver = 'this.rawFromPointer';
      final generativeArgExprs = <String>[];
      for (var i = 0; i < fn.parameters.length; i++) {
        final p = fn.parameters[i];
        if (p.direction == GirParameterDirection.out) continue;
        final inP = ins[i];
        final bridge = bridges[i]!;
        // Strings / string-lists are excluded by `hasStringInSet`
        // above — `bridge.toNative` for those returns the parameter
        // expression unchanged (the actual marshalling happens in
        // `withNativeString` / `withNativeStringList`), so the
        // same expression works here for the rare non-excluded path.
        generativeArgExprs.add(bridge.toNative(inP.name));
      }
      final generativeCall = '$lookupVar(${generativeArgExprs.join(', ')})';
      final generativeHeader = dartName.isEmpty
          ? '$factoryClass($paramList) : $receiver($generativeCall$ownedArg);'
          : '$factoryClass.$dartName($paramList) : '
                '$receiver($generativeCall$ownedArg);';
      final b = StringBuffer();
      for (final line in ctx.docLines(fn.doc)) {
        b.writeln(line);
      }
      b.writeln(lookupDecl);
      b.writeln(generativeHeader);
      return b.toString();
    }

    String resultExpr(String raw) {
      final String converted;
      if (factoryClass != null) {
        final ownedArg = factoryOwned ? ', owned: true' : '';
        converted = sinkFloating
            ? '$factoryClass.fromPointer(gObjectRefSink($raw)$ownedArg)'
            : '$factoryClass.fromPointer($raw$ownedArg)';
      } else {
        converted = retBridge.fromNative(raw);
      }
      final visible = outs.where((o) => !o.absorbed).toList();
      if (visible.isEmpty) return converted;
      final outExprs = visible.map((o) => _outExpr(o, outs)).join(', ');
      return '($converted, $outExprs)';
    }

    // Allocate NativeCallable wrappers for callback params before the call.
    // These are scoped to the body and disposed in the finally block.
    if (hasCallbacks) {
      for (final c in callbackAllocs) {
        core.add(
          'final ${c.varName} = ${c.inParam.bridge.toNative(c.inParam.name)};',
        );
      }
    }

    if (!hasAllocs && !hasCallbacks) {
      if (retBridge.isVoid && outs.isEmpty) {
        core.add('$call;');
      } else if (retBridge.isVoid) {
        core.add('$call;');
        core.add('return ${_outsOnlyExpr(outs)};');
      } else if (retBridge.evaluatesArgTwice) {
        // The conversion mentions its argument twice
        // (`($call) == ffi.nullptr ? null : $call`), so the call is
        // bound to a local first — inlined, the native function would
        // run twice.
        core.add('final _ret = $call;');
        core.add('return ${resultExpr('_ret')};');
      } else {
        core.add('return ${resultExpr(call)};');
      }
    } else {
      for (final o in outs) {
        // Record/class OUT params allocate a fixed-size buffer via a
        // Dart finalizer-backed heap anchor (`HeapAnchor.allocate`).
        // The anchor keeps the buffer alive as long as the returned
        // wrapper (`T.fromPointer(_buffer)`) is reachable — matching
        // GTK's "iter lives until you drop it" semantics. Primitive
        // OUT params allocate one slot of the pointee and free it
        // manually in the finally block.
        if (o.bridge.outAllocSize != null) {
          ctx.usesGirFfi = true;
          core.add(
            'final ${o.varName}Anchor = HeapAnchor.allocate(${o.bridge.outAllocSize});',
          );
          core.add('final ${o.varName} = ${o.varName}Anchor.buffer;');
        } else if (o.bridge.outPointee == 'ffi.Pointer<ffi.Void>' ||
            o.bridge.outExtractBytes != null) {
          // A pointer-sized slot is zeroed: the C function is allowed
          // to leave the out parameter untouched, and an uninitialized
          // pointer would be a wild read. A byte buffer's slot counts —
          // the callee writes the buffer pointer into it.
          core.add('final ${o.varName} = calloc<${o.bridge.outPointee}>();');
        } else {
          core.add('final ${o.varName} = malloc<${o.bridge.outPointee}>();');
        }
      }
      if (fn.throws) {
        core.add('final _error = calloc<ffi.Pointer<ffi.Void>>();');
      }
      for (final s in structArgs) {
        core.add('final _structArg${s.index} = calloc<${s.type}>();');
        core.add('_structArg${s.index}.ref = ${s.param};');
      }
      // The cleanup runs in a `finally` block, so a throwing call still
      // releases what it allocated. When there is nothing to release the
      // block is left out entirely.
      final cleanup = <String>[];
      for (final o in outs) {
        if (o.bridge.outAllocSize != null) {
          // HeapAnchor's NativeFinalizer frees the buffer when the
          // anchor is GC'd; do not free here (would invalidate the
          // returned wrapper's handle).
        } else if (o.bridge.outIsStruct) {
          // The returned struct owns the buffer: `refWithFinalizer`
          // frees it when the struct is collected. Freeing it here would
          // leave the struct pointing at released memory.
        } else {
          cleanup.add('  malloc.free(${o.varName});');
        }
      }
      if (fn.throws) {
        cleanup.add('  calloc.free(_error);');
      }
      for (final s in structArgs) {
        cleanup.add('  calloc.free(_structArg${s.index});');
      }
      for (final c in callbackAllocs) {
        // Nullable callback locals are `null` when the user passes nothing;
        // skip `.close()` in that case.
        final closeExpr = c.inParam.bridge.isNullableCallback
            ? '${c.varName}?.close()'
            : '${c.varName}.close()';
        cleanup.add('  $closeExpr;');
      }

      final body = <String>[];
      if (retBridge.isVoid) {
        body.add('  $call;');
      } else {
        body.add('  final _ret = $call;');
      }
      if (fn.throws) {
        body.add('  if (_error.value != ffi.nullptr) {');
        body.add('    throw GlibException.fromError(_error.value);');
        body.add('  }');
      }
      if (retBridge.isVoid) {
        if (outs.isNotEmpty) body.add('  return ${_outsOnlyExpr(outs)};');
      } else {
        body.add('  return ${resultExpr('_ret')};');
      }

      if (cleanup.isEmpty) {
        core.addAll(body.map((l) => l.isEmpty ? l : l.substring(2)));
      } else {
        core.add('try {');
        core.addAll(body);
        core.add('} finally {');
        core.addAll(cleanup);
        core.add('}');
      }
    }

    // Wrap string parameters in withNativeString scopes.
    final stringIns = ins.where((p) => p.bridge.isString).toList();
    final returnsValue = !(retBridge.isVoid && outs.isEmpty);
    var bodyLines = core;
    for (var i = stringIns.length - 1; i >= 0; i--) {
      final p = stringIns[i];
      final inner = bodyLines.map((l) => l.isEmpty ? l : '  $l').join('\n');
      final ret = returnsValue ? 'return ' : '';
      bodyLines = [
        '$ret withNativeString(${p.name}, (${p.nativeVar}) {',
        inner,
        '});',
      ];
    }

    // Wrap argv-style string-list parameters in withNativeStringList
    // scopes. Done after withNativeString so the nesting reflects the
    // user-facing call order: outer-most call corresponds to the first
    // (leftmost) string-list param. The lambda param type is inferred
    // from the helper signature.
    final listIns = ins.where((p) => p.bridge.isStringList).toList();
    for (var i = listIns.length - 1; i >= 0; i--) {
      final p = listIns[i];
      final inner = bodyLines.map((l) => l.isEmpty ? l : '  $l').join('\n');
      final ret = returnsValue ? 'return ' : '';
      bodyLines = [
        '$ret withNativeStringList(${p.name}, (${p.nativeVar}) {',
        inner,
        '});',
      ];
    }

    final b = StringBuffer();
    for (final line in ctx.docLines(fn.doc)) {
      b.writeln(line);
    }
    b.writeln(lookupDecl);
    b.writeln(header);
    b.writeln(bodyLines.join('\n'));
    b.write('}');
    return b.toString();
  }

  /// The expression that reads [o] out of its slot after the call.
  ///
  /// A callee-allocated byte buffer needs its byte count, which lives
  /// in a sibling OUT slot — the `outs` list is complete by the time
  /// this runs, so the sibling is found through its parameter index.
  String _outExpr(_OutParam o, List<_OutParam> outs) {
    final bytes = o.bridge.outExtractBytes;
    if (bytes != null) {
      final lengthIndex = o.bridge.outByteBufferLengthIndex!;
      final lengthOut = outs.firstWhere((x) => x.paramIndex == lengthIndex);
      return bytes(o.varName, lengthOut.varName);
    }
    return o.bridge.outExtract!(o.varName);
  }

  String _outsOnlyExpr(List<_OutParam> outs) {
    final visible = outs.where((o) => !o.absorbed).toList();
    if (visible.length == 1) {
      return _outExpr(visible.single, outs);
    }
    return '(${visible.map((o) => _outExpr(o, outs)).join(', ')})';
  }

  static String _returnType(TypeBridge ret, List<_OutParam> outs) {
    final visible = outs.where((o) => !o.absorbed).toList();
    if (ret.isVoid) {
      if (visible.isEmpty) return 'void';
      if (visible.length == 1) return visible.single.bridge.wrapperType;
      return '(${visible.map((o) => o.bridge.wrapperType).join(', ')})';
    }
    if (visible.isEmpty) return ret.wrapperType;
    return '(${[ret.wrapperType, ...visible.map((o) => o.bridge.wrapperType)].join(', ')})';
  }

  /// `dart:core` type names that a class member must not shadow (a member
  /// named `int` makes the type `int` unusable inside the class body).
  static const _coreTypes = {
    'int',
    'double',
    'num',
    'bool',
    'String',
    'Object',
    'Null',
    'Function',
    'Record',
    'Iterable',
    'List',
    'Map',
    'Set',
    'Future',
    'Stream',
    'void',
    'Enum',
    'Type',
    'Symbol',
    'BigInt',
    'DateTime',
    'Duration',
    'RegExp',
    'StringBuffer',
    'Pattern',
    'Error',
    'Exception',
    'StackTrace',
  };

  /// True when [bridge] carries a callback parameter that needs a
  /// `NativeCallable` lifecycle around the call. Identified by the native
  /// type pattern set by `_bridgeForCallback` in [EmitContext].
  static bool _isCallbackBridge(TypeBridge bridge) {
    final n = bridge.nativeType;
    return n.startsWith('ffi.Pointer<ffi.NativeFunction<') &&
        !n.contains('Pointer<NativeFunction<');
  }

  /// Whether [name] would collide with a `dart:core` Object member.
  static bool conflictsWithObjectMember(String name) =>
      _objectMembers.contains(name);

  /// Renames members that would shadow a core type inside the class body.
  static String safeMemberName(String name) =>
      _coreTypes.contains(name) ? '${name}_' : name;
}
