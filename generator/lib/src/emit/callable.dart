/// Emits Dart wrappers for GIR callables (functions, methods, constructors).
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import 'context.dart';

class _InParam {
  _InParam(this.name, this.bridge);
  final String name;
  final TypeBridge bridge;

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
  _OutParam(this.varName, this.name, this.bridge);
  final String varName;
  final String name;
  final TypeBridge bridge;
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
    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      final (bridge, reason) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
      );
      if (bridge == null) {
        ctx.report.skip('callable', label, 'parameter ${p.name}: $reason');
        return null;
      }
      bridges[i] = bridge;
      switch (p.direction) {
        case GirParameterDirection.in_:
          final paramName = escapeKeyword(toLowerCamel(p.name));
          final inParam = _InParam(paramName, bridge);
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
          outs.add(_OutParam('_out${outs.length}', p.name, bridge));
      }
    }

    final (retBridge, retReason) = ctx.bridgeFor(
      fn.returnType,
      nullable: fn.returnNullable,
      transfer: fn.returnTransfer,
      forReturn: true,
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
      for (final c in callbackAllocs) ins.indexOf(c.inParam): c,
    };
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
    final hasAllocs = outs.isNotEmpty || fn.throws;
    final hasCallbacks = callbackAllocs.isNotEmpty;
    final call = '$lookupVar(${argExprs.join(', ')})';

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
      if (outs.isEmpty) return converted;
      final outExprs = outs
          .map((o) => o.bridge.outExtract!(o.varName))
          .join(', ');
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
          core.add(
            'final ${o.varName} = ${o.varName}Anchor.buffer;',
          );
        } else {
          core.add('final ${o.varName} = malloc<${o.bridge.outPointee}>();');
        }
      }
      if (fn.throws) {
        core.add('final _error = calloc<ffi.Pointer<ffi.Void>>();');
      }
      core.add('try {');
      if (retBridge.isVoid) {
        core.add('  $call;');
      } else {
        core.add('  final _ret = $call;');
      }
      if (fn.throws) {
        core.add('  if (_error.value != ffi.nullptr) {');
        core.add('    throw GlibException.fromError(_error.value);');
        core.add('  }');
      }
      if (retBridge.isVoid) {
        if (outs.isNotEmpty) core.add('  return ${_outsOnlyExpr(outs)};');
      } else {
        core.add('  return ${resultExpr('_ret')};');
      }
      core.add('} finally {');
      for (final o in outs) {
        if (o.bridge.outAllocSize != null) {
          // HeapAnchor's NativeFinalizer frees the buffer when the
          // anchor is GC'd; do not free here (would invalidate the
          // returned wrapper's handle).
        } else {
          core.add('  malloc.free(${o.varName});');
        }
      }
      if (fn.throws) {
        core.add('  calloc.free(_error);');
      }
      for (final c in callbackAllocs) {
        // Nullable callback locals are `null` when the user passes nothing;
        // skip `.close()` in that case.
        final closeExpr = c.inParam.bridge.isNullableCallback
            ? '${c.varName}?.close()'
            : '${c.varName}.close()';
        core.add('  $closeExpr;');
      }
      core.add('}');
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

  static String _outsOnlyExpr(List<_OutParam> outs) {
    if (outs.length == 1) {
      return outs.single.bridge.outExtract!(outs.single.varName);
    }
    return '(${outs.map((o) => o.bridge.outExtract!(o.varName)).join(', ')})';
  }

  static String _returnType(TypeBridge ret, List<_OutParam> outs) {
    if (ret.isVoid) {
      if (outs.isEmpty) return 'void';
      if (outs.length == 1) return outs.single.bridge.wrapperType;
      return '(${outs.map((o) => o.bridge.wrapperType).join(', ')})';
    }
    if (outs.isEmpty) return ret.wrapperType;
    return '(${[ret.wrapperType, ...outs.map((o) => o.bridge.wrapperType)].join(', ')})';
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
