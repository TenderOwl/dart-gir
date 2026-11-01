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

  /// `true` when the parameter is consumed by a caller-provided byte
  /// array — it carries the buffer's byte count.
  ///
  /// The slot stays in the native call (the C ABI needs it) but it
  /// disappears from the Dart signature: the count is the length of the
  /// `Uint8List` the caller passed.
  bool absorbed = false;

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

  /// The Dart parameter whose value seeds the slot — a nullable scalar
  /// the caller passes by pointer. `null` for a plain OUT parameter,
  /// which the callee fills from scratch.
  String? slotParam;
}

/// A `GDestroyNotify`-style parameter whose callback the callee calls
/// *after* the call that passed it.
///
/// The callee takes over the buffer and calls the notify when it is done
/// with it — the notify outlives the call. A scoped `NativeCallable`
/// would be closed in the `finally` block before the notify fires, and
/// the callback would then run against freed memory (the Dart VM aborts
/// the isolate with "Callback invoked after it has been deleted").
///
/// The emitter therefore passes a permanent function pointer over a
/// static trampoline and keeps the user's callback in a per-callable
/// registry until the notify arrives.
class _DestroyNotify {
  _DestroyNotify(
    this.param,
    this.inParam,
    this.registryName,
    this.trampolineName,
    this.ptrName,
  );

  /// The GIR parameter.
  final GirParameter param;

  /// The Dart-side parameter.
  final _InParam inParam;

  /// Name of the generated registry member.
  final String registryName;

  /// Name of the generated trampoline member.
  final String trampolineName;

  /// Name of the generated permanent function pointer member.
  final String ptrName;
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
  /// [factoryCopy]: take a reference of the factory's own through the
  /// type's copy function — the shape a *floating* reference needs.
  /// [bodyPrelude]: lines emitted at the top of the body — the destructor of
  /// an owned wrapper uses it to hand the release from the collector to the
  /// caller.
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
    bool factoryCopy = false,
    GirNamespace? relativeTo,
    List<String> bodyPrelude = const [],
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
    // Destroy notifies the callee calls *after* the call — they need a
    // permanent trampoline instead of a scoped `NativeCallable`.
    final destroyNotifies = <_DestroyNotify>[];
    // Whether the callable hands a byte buffer to the callee. A destroy
    // notify next to such a buffer is the callee's promise to release it
    // later, so the notify outlives the call.
    final hasByteArray = fn.parameters.any(
      (p) => TypeResolver.isByteArrayElement(p.type),
    );
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

    // A `char **` *return* whose element count a sibling OUT parameter
    // carries — `g_key_file_get_string_list` and its `gsize *length`.
    // The count is absorbed: the list knows its own length, so it is not
    // a separate element of the returned record. The array is read for
    // exactly that many elements, because a `gchar **` is not always
    // NULL-terminated.
    final retCountIndex = fn.returnType == null
        ? null
        : TypeResolver.stringListReturnCountIndex(
            fn.returnType!,
            fn.parameters,
          );
    if (retCountIndex != null) absorbedOutIndices.add(retCountIndex);

    // Caller-provided byte arrays: the caller owns the buffer and a
    // sibling parameter carries the byte count. The count is absorbed —
    // it is the length of the `Uint8List` — and the buffer is mirrored
    // into native memory for the call (`withNativeBytes`).
    //
    // An async callable keeps its buffer past the call ("no copy of
    // `@contents` will be made, so it must stay valid until `@callback`
    // is called" — GIO), so its buffers stay raw pointers.
    final hasAsyncScope = fn.parameters.any((p) => p.scope == 'async');
    // Parameter index of the byte array -> parameter index of the
    // sibling that carries its byte count.
    final byteArrayByLengthIndex = <int, int>{};
    if (!hasAsyncScope) {
      for (var i = 0; i < fn.parameters.length; i++) {
        final p = fn.parameters[i];
        // A caller-provided byte buffer: either handed *to* the callee
        // (`g_bytes_new`'s `data`) or filled *by* it (`g_input_stream_read`'s
        // `buffer` — the GIR marks that one `direction="out"` because the
        // callee writes into it, but the storage is the caller's).
        final provided =
            TypeResolver.isByteArrayIn(p, fn.parameters) ||
            TypeResolver.isCallerProvidedByteBuffer(p, fn.parameters);
        if (!provided) continue;
        final lengthIdx = p.type!.array!.lengthParameterIndex!;
        // Two byte arrays sharing one length sibling would have to agree
        // on a count — leave the second one a raw pointer rather than
        // pass a wrong length.
        if (byteArrayByLengthIndex.containsKey(lengthIdx)) continue;
        byteArrayByLengthIndex[lengthIdx] = i;
      }
    }
    final absorbedInIndices = byteArrayByLengthIndex.keys.toSet();

    // String arrays and counted strings whose length a sibling parameter
    // carries — GLib's `(list, length)` and `(string, string_len)` pairs.
    // The count is absorbed: the C side reads the length of the list (or
    // the *byte* length of the string) the caller passed, so the count
    // does not appear in the Dart signature.
    //
    // The map is keyed by the *count* parameter's index and holds the
    // index of the array (or string) it belongs to.
    final stringCountByIndex = <int, int>{};
    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      final countIdx = TypeResolver.stringCountBinding(p, fn.parameters);
      if (countIdx == null) continue;
      // Two arrays sharing one count sibling would have to agree on a
      // count — leave the second one alone rather than pass a wrong
      // length. A byte array already claims the sibling, too.
      if (stringCountByIndex.containsKey(countIdx)) continue;
      if (byteArrayByLengthIndex.containsKey(countIdx)) continue;
      stringCountByIndex[countIdx] = i;
    }
    absorbedInIndices.addAll(stringCountByIndex.keys);

    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      final (bridge, reason) = ctx.bridgeFor(
        p.type,
        nullable: p.nullable,
        transfer: p.transferOwnership,
        direction: p.direction,
        callerAllocates: p.callerAllocates,
        byteArrayIn: byteArrayByLengthIndex.containsValue(i),
        relativeTo: relativeTo,
        siblings: fn.parameters,
      );
      if (bridge == null) {
        ctx.report.skip('callable', label, 'parameter ${p.name}: $reason');
        return null;
      }
      bridges[i] = bridge;
      // A caller-provided byte buffer the callee *fills* — `g_input_stream_read`'s
      // `buffer` — is an input from the Dart side: the caller owns the
      // storage, so the parameter is passed in and filled in place.
      final effectiveDirection =
          bridge.isByteArrayIn && p.direction == GirParameterDirection.out
          ? GirParameterDirection.in_
          : p.direction;
      switch (effectiveDirection) {
        case GirParameterDirection.in_:
          final paramName = escapeKeyword(toLowerCamel(p.name));
          final inParam = _InParam(paramName, bridge, paramIndex: i)
            ..absorbed = absorbedInIndices.contains(i);
          ins.add(inParam);
          if (bridge.isNullableScalarPointer) {
            // A nullable scalar the caller passes by pointer: the
            // wrapper allocates the slot, seeds it with the caller's
            // value (or passes NULL), and reads it back after the
            // call. The slot rides the OUT machinery — the read-back
            // is the wrapper's return value.
            outs.add(
              _OutParam('_out${outs.length}', p.name, bridge, paramIndex: i)
                ..slotParam = paramName,
            );
          }
          if (_isCallbackBridge(bridge)) {
            if (TypeResolver.isDestroyNotify(p) && hasByteArray) {
              // The callee takes over the buffer and calls the notify
              // when it is done with it — the notify outlives the call,
              // so it needs a permanent trampoline.
              destroyNotifies.add(
                _DestroyNotify(
                  p,
                  inParam,
                  _destroyRegistryName(fn.cIdentifier!, p),
                  _destroyTrampolineName(fn.cIdentifier!, p),
                  _destroyPtrName(fn.cIdentifier!, p),
                ),
              );
            } else {
              callbackAllocs.add(_CallbackAlloc('_nc${ins.length}', inParam));
            }
          }
        case GirParameterDirection.inout:
          // The **caller-allocated rule**. The GIR's ownership annotation
          // for an inout parameter is demonstrably wrong — it claims the
          // callee takes the storage over — so the annotation is ignored
          // and the caller keeps it.
          //
          // * A **scalar or enum**: the wrapper allocates the slot, seeds
          //   it with the caller's value and reads the updated value back
          //   after the call. The read-back rides the OUT machinery — it
          //   is part of the wrapper's return value.
          // * A **handle**: the caller passes the object and the callee
          //   writes through the pointer in place. The Dart object *is*
          //   the memory, so the caller sees the change — the ordinary IN
          //   shape does the job.
          final paramName = escapeKeyword(toLowerCamel(p.name));
          final inParam = _InParam(paramName, bridge, paramIndex: i);
          ins.add(inParam);
          if (bridge.isInoutScalar) {
            outs.add(
              _OutParam('_out${outs.length}', p.name, bridge, paramIndex: i)
                ..slotParam = paramName,
            );
          }
        case GirParameterDirection.out:
          // Both `caller-allocates="0"` (function allocates) and
          // `caller-allocates="1"` (caller allocates) reduce to the
          // same wrapper shape: malloc a buffer, pass its pointer,
          // read back the value after the call. The wrapper frees
          // the buffer in `finally` (always — the caller never sees
          // the raw pointer).
          if (bridge.outPointee == null && !bridge.isOutArray) {
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

    // The element count of an OUT array is consumed by the array: the
    // list the wrapper returns knows its own length, so the count does
    // not appear in the returned record.
    for (final o in outs) {
      final countIndex = o.bridge.outArrayCountIndex;
      if (countIndex == null) continue;
      for (final other in outs) {
        if (other.paramIndex == countIndex) other.absorbed = true;
      }
    }

    // Parameters the callee takes over: the GIR says
    // `transfer-ownership="full"`, so from the call on the reference is
    // the callee's. The Dart side has to give up its claim — it must not
    // release a reference it no longer owns, and the wrapper's
    // finalizer must not release it either.
    final handovers = <_InParam>[];
    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      if (p.direction != GirParameterDirection.in_) continue;
      if (p.transferOwnership != GirTransferOwnership.full) continue;
      final bridge = bridges[i];
      if (bridge == null || bridge.ownershipFinalizer == null) continue;
      handovers.add(ins.firstWhere((x) => x.paramIndex == i));
    }

    final (retBridge, retReason) = ctx.bridgeFor(
      fn.returnType,
      nullable: fn.returnNullable,
      transfer: fn.returnTransfer,
      forReturn: true,
      relativeTo: relativeTo,
      stringListCountExpr: _retCountExpr(retCountIndex, outs),
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
    // Destroy notifies: the callee calls them after the call, so the
    // native side gets a permanent function pointer, not the scoped
    // `NativeCallable` of a normal callback.
    final destroyByParam = <int, _DestroyNotify>{
      for (final d in destroyNotifies) d.inParam.paramIndex: d,
    };
    // Struct arguments the C API takes by pointer: each one needs a
    // native copy for the duration of the call.
    final structArgs = <({int index, String type, String param})>[];
    for (var i = 0; i < fn.parameters.length; i++) {
      final p = fn.parameters[i];
      final bridge = bridges[i]!;
      if (p.direction == GirParameterDirection.out && !bridge.isByteArrayIn) {
        final o = outs.firstWhere((o) => o.name == p.name);
        if (bridge.isOutArray) {
          // An OUT array: the C parameter is the array pointer itself
          // (the caller allocates the buffer) or a slot the callee
          // writes the array pointer into (the callee allocates it).
          nativeParams.add(bridge.nativeType);
          dartParams.add(bridge.nativeType);
          argExprs.add(o.varName);
          continue;
        }
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
        if (bridge.isCountedString) {
          // The `withNativeStringBytes` helper hands out the marshalled
          // string as a `Pointer<Utf8>` already — no cast needed here.
          argExprs.add(inP.nativeVar);
        } else if (bridge.isString) {
          argExprs.add('${inP.nativeVar}.cast<Utf8>()');
        } else if (bridge.isStringList) {
          // The native signature uses `Pointer<Pointer<Utf8>>`, but the
          // wrapped pointer we get out of `withNativeStringList` is typed
          // as `Pointer<Pointer<Utf8>>` already — no cast needed here.
          argExprs.add(inP.nativeVar);
        } else if (bridge.isNullableScalarPointer) {
          // The slot the emitter allocated for this nullable scalar.
          argExprs.add(outs.firstWhere((o) => o.name == p.name).varName);
        } else if (bridge.isInoutScalar) {
          // The slot the emitter allocated for this inout scalar: the
          // caller seeds it, the callee writes through it.
          argExprs.add(outs.firstWhere((o) => o.name == p.name).varName);
        } else if (bridge.isByteArrayIn) {
          // The native buffer the `withNativeBytes` helper allocated for
          // this byte array.
          argExprs.add(_bytesBufferVar(i));
        } else if (inP.absorbed) {
          // The count of a caller-provided byte array, of a string array
          // or of a counted string: the length the helper computed.
          final byteOwner = byteArrayByLengthIndex[inP.paramIndex];
          argExprs.add(
            byteOwner != null
                ? _bytesLengthVar(byteOwner)
                : _stringCountVar(ins[stringCountByIndex[inP.paramIndex]!]),
          );
        } else if (destroyByParam.containsKey(i)) {
          // A destroy notify the callee calls after the call: the native
          // side gets the permanent pointer over the static trampoline.
          final d = destroyByParam[i]!;
          argExprs.add(
            d.inParam.bridge.isNullableCallback
                ? '${d.inParam.name} == null ? ffi.nullptr : ${d.ptrName}'
                : d.ptrName,
          );
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

    // Wrapper signature. The absorbed parameters — the byte count of a
    // caller-provided byte array — do not appear: the count is the
    // length of the `Uint8List` the caller passed.
    final visibleIns = ins.where((p) => !p.absorbed).toList();
    final requiredParams = <String>[];
    final optionalParams = <String>[];
    for (var i = 0; i < visibleIns.length; i++) {
      final p = visibleIns[i];
      final isOptional =
          p.bridge.wrapperType.endsWith('?') &&
          visibleIns
              .sublist(i)
              .every((q) => q.bridge.wrapperType.endsWith('?'));
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

    // The prelude runs before everything else: it hands the release of an
    // owned reference from the collector to the caller.
    core.addAll(bodyPrelude);

    // Hand the reference over before the call: the callee owns it from
    // now on, so the wrapper gives up its claim. The finalizer is
    // detached — the wrapper must not release a reference the callee
    // owns — and the flag is cleared, so a second handover of the same
    // wrapper does not detach twice.
    for (final h in handovers) {
      final finalizer = h.bridge.ownershipFinalizer!;
      final nullable = h.bridge.wrapperType.endsWith('?');
      final arg = h.name;
      core.add(
        nullable ? 'if ($arg != null && $arg.owned) {' : 'if ($arg.owned) {',
      );
      core.add('  $finalizer.detach($arg);');
      core.add('  $arg.owned = false;');
      core.add('}');
    }

    // Park the destroy notify in the registry before the call: the
    // trampoline pops it when the callee releases the buffer.
    for (final d in destroyNotifies) {
      final nullable = d.inParam.bridge.isNullableCallback;
      core.add(nullable ? 'if (${d.inParam.name} != null) {' : '{');
      core.add('  ${d.registryName}.add(${d.inParam.name});');
      core.add('}');
    }

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
    // A destroy notify needs a body: the wrapper parks the user's callback
    // in the registry before the call, and a generative initializer list
    // has no body to host that.
    final hasDestroyNotify = destroyNotifies.isNotEmpty;
    // A struct argument needs a native copy for the call, and a
    // generative constructor has no body to allocate it in.
    final hasStructInSet = ins.any((p) => p.bridge.structArgType != null);
    // A caller-provided byte array needs the `withNativeBytes` helper to
    // mirror the list into native memory — and a generative constructor
    // has no body to host that call.
    final hasByteArrayInSet = ins.any((p) => p.bridge.isByteArrayIn);
    // A parameter the callee takes over needs the handover code — and a
    // generative constructor has no body to host it either.
    // A *floating* reference needs the copy function — and a generative
    // constructor has no body to host that either.
    if (factoryClass != null &&
        !fn.throws &&
        outs.isEmpty &&
        !hasStringInSet &&
        !hasCallback &&
        !hasDestroyNotify &&
        !hasStructInSet &&
        !hasByteArrayInSet &&
        !factoryCopy &&
        handovers.isEmpty) {
      final ownedArg = factoryOwned ? ', owned: true' : '';
      // `this.fromPointer` is always valid — every generated class
      // (and record) declares a `fromPointer` named constructor that
      // initializes the inherited `handle` / `owned` fields. The
      // original code emitted `super.fromPointer` for subclassable
      // classes and `this.fromPointer` for root classes (records),
      // but Dart rejects `super.fromPointer` on a class with no
      // declared parent (`final_not_initialized_constructor`,
      // `undefined_constructor_in_initializer` — see
      // `packages/gir_gobject/lib/src/gobject.dart` for `GObject.newv`).
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
      for (final line in ctx.byteArrayLifetimeDoc(fn)) {
        b.writeln(line);
      }
      b.writeln(generativeHeader);
      return b.toString();
    }

    String resultExpr(String raw) {
      final String converted;
      if (factoryClass != null) {
        final ownedArg = factoryOwned ? ', owned: true' : '';
        if (factoryCopy) {
          // A *floating* reference: the type's copy function turns it into
          // a reference the wrapper owns.
          converted = '$factoryClass.copyReference($raw)';
        } else {
          converted = sinkFloating
              ? '$factoryClass.fromPointer(gObjectRefSink($raw)$ownedArg)'
              : '$factoryClass.fromPointer($raw$ownedArg)';
        }
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
        if (o.bridge.isNullableScalarPointer) {
          // A nullable scalar the caller passes by pointer: the slot
          // exists only when the caller supplied a value — otherwise
          // the C side sees NULL, which is what `allow-none="1"`
          // promises it accepts.
          final slot = o.slotParam!;
          core.add(
            'final ${o.varName} = $slot == null ? ffi.nullptr : '
            'malloc<${o.bridge.outPointee}>();',
          );
          core.add(
            'if ($slot != null) ${o.varName}.value = '
            '${o.bridge.toNative(slot)};',
          );
        } else if (o.bridge.isInoutScalar) {
          // An inout scalar: the slot always exists and always carries
          // the caller's value — the callee reads it and may write
          // through it.
          final slot = o.slotParam!;
          core.add('final ${o.varName} = malloc<${o.bridge.outPointee}>();');
          core.add('${o.varName}.value = ${o.bridge.toNative(slot)};');
        } else if (o.bridge.outAllocSize != null) {
          ctx.usesGirFfi = true;
          core.add(
            'final ${o.varName}Anchor = HeapAnchor.allocate(${o.bridge.outAllocSize});',
          );
          core.add('final ${o.varName} = ${o.varName}Anchor.buffer;');
        } else if (o.bridge.outSlotIsCalloc) {
          // A pointer-sized slot is zeroed: the C function is allowed
          // to leave the out parameter untouched, and an uninitialized
          // pointer would be a wild read. A byte buffer's slot counts —
          // the callee writes the buffer pointer into it.
          core.add('final ${o.varName} = calloc<${o.bridge.outPointee}>();');
        } else if (o.bridge.isOutArray) {
          // An OUT array.
          //
          // * The **caller** allocates the buffer: the array has a known
          //   length — a fixed size, or the capacity the caller passes —
          //   so the wrapper allocates it and copies the elements out
          //   after the call.
          // * The **callee** allocates the array: the wrapper passes a
          //   pointer-sized slot the callee writes the array pointer
          //   into.
          if (o.bridge.outArrayCallerAllocated) {
            final element = o.bridge.outArrayElementIsHandle
                ? 'ffi.Pointer<ffi.Void>'
                : o.bridge.outArrayElementNativeType!;
            core.add(
              'final ${o.varName} = calloc<$element>'
              '(${_outArrayCountExpr(o, outs, ins)});',
            );
          } else {
            final pointer = o.bridge.outArrayElementIsHandle
                ? 'ffi.Pointer<ffi.Pointer<ffi.Void>>'
                : 'ffi.Pointer<${o.bridge.outArrayElementNativeType}>';
            core.add('final ${o.varName} = calloc<$pointer>();');
          }
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
        } else if (o.bridge.isNullableScalarPointer) {
          // The slot is NULL when the caller passed no value — there is
          // nothing to release then.
          cleanup.add(
            '  if (${o.varName} != ffi.nullptr) malloc.free(${o.varName});',
          );
        } else if (o.bridge.isOutArray) {
          if (o.bridge.outArrayCallerAllocated) {
            // The wrapper allocated the buffer: it releases it.
            cleanup.add('  calloc.free(${o.varName});');
          } else {
            // The callee allocated the array: the caller owns it (the
            // GIR's `transfer-ownership` says the array is handed over
            // for every value but `none`), and GLib's allocator is the
            // one that freed it.
            ctx.usesGirFfi = true;
            cleanup.add('  gFree(${o.varName}.value.cast());');
          }
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
      // An OUT array is copied into a Dart list before the wrapper hands
      // it to the caller: the native array is released right after, and
      // the garbage collector cannot see native memory.
      for (final o in outs) {
        if (!o.bridge.isOutArray) continue;
        final countExpr = _outArrayCountExpr(o, outs, ins);
        // The callee writes the array pointer into the slot; the caller
        // allocated the buffer itself.
        final arrayVar = o.bridge.outArrayCallerAllocated
            ? o.varName
            : '${o.varName}.value';
        final extract = o.bridge.outExtractArray!(arrayVar, countExpr);
        // A callee that leaves the array alone writes NULL into the slot —
        // an empty list, not a read through a null pointer.
        final list = o.bridge.outArrayCallerAllocated
            ? extract
            : '($arrayVar == ffi.nullptr '
                  '? <${o.bridge.outArrayElementType}>[] : $extract)';
        body.add('  final ${_outListVar(o)} = $list;');
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

    // Wrap string parameters in withNativeString scopes. A *counted*
    // string — one whose byte length a sibling parameter carries — is
    // excluded here: it gets its own scope below.
    final stringIns = ins
        .where((p) => p.bridge.isString && !p.bridge.isCountedString)
        .toList();
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

    // Wrap counted strings in withNativeStringBytes scopes. The helper
    // reports the *byte* length of the string — the count the C side
    // reads — and releases the native copy afterwards.
    final countedStringIns = ins
        .where((p) => p.bridge.isCountedString)
        .toList();
    for (var i = countedStringIns.length - 1; i >= 0; i--) {
      final p = countedStringIns[i];
      final inner = bodyLines.map((l) => l.isEmpty ? l : '  $l').join('\n');
      final ret = returnsValue ? 'return ' : '';
      bodyLines = [
        '$ret withNativeStringBytes(${p.name}, '
            '(${p.nativeVar}, ${_stringCountVar(p)}) {',
        inner,
        '});',
      ];
    }

    // Wrap argv-style string-list parameters in withNativeStringList
    // scopes. Done after withNativeString so the nesting reflects the
    // user-facing call order: outer-most call corresponds to the first
    // (leftmost) string-list param. The lambda param type is inferred
    // from the helper signature.
    //
    // The helper hands out the element count as well: a C function that
    // takes the count reads exactly that many slots, one that does not
    // reads until the terminator.
    final listIns = ins.where((p) => p.bridge.isStringList).toList();
    for (var i = listIns.length - 1; i >= 0; i--) {
      final p = listIns[i];
      final inner = bodyLines.map((l) => l.isEmpty ? l : '  $l').join('\n');
      final ret = returnsValue ? 'return ' : '';
      bodyLines = [
        '$ret withNativeStringList(${p.name}, '
            '(${p.nativeVar}, ${_stringCountVar(p)}) {',
        inner,
        '});',
      ];
    }

    // Wrap caller-provided byte arrays in withNativeBytes scopes. The
    // helper mirrors the `Uint8List` into a GLib-allocated buffer, hands
    // the buffer and its length to the call, and releases the buffer
    // afterwards — unless the callee took ownership of it
    // (`transfer-ownership="full"`), in which case the helper leaves the
    // buffer alone. Same nesting rule as the strings: the first byte
    // array ends up outermost.
    final byteArrayIns = ins.where((p) => p.bridge.isByteArrayIn).toList();
    for (var i = byteArrayIns.length - 1; i >= 0; i--) {
      final p = byteArrayIns[i];
      final inner = bodyLines.map((l) => l.isEmpty ? l : '  $l').join('\n');
      final ret = returnsValue ? 'return ' : '';
      final owned = p.bridge.byteArrayOwnedByCallee ? ', owned: true' : '';
      bodyLines = [
        '$ret withNativeBytes(${p.name}, '
            '(${_bytesBufferVar(p.paramIndex)}, ${_bytesLengthVar(p.paramIndex)}) {',
        inner,
        '}$owned);',
      ];
    }

    final b = StringBuffer();
    for (final line in ctx.docLines(fn.doc)) {
      b.writeln(line);
    }
    // The permanent trampoline a destroy notify needs. The notify runs
    // after the call that passed it, so a scoped `NativeCallable` would
    // already be closed by then.
    for (final d in destroyNotifies) {
      final staticPrefix = staticMember || classMember ? 'static ' : '';
      // The trampoline follows the callback's *own* signature.
      // `GDestroyNotify` takes the data alone; `GdkPixbufDestroyNotify`
      // takes the pixel buffer and the data. The C function pointer has
      // to match the type the callee expects, so the shape comes from
      // the callback declaration and not from a hard-coded one.
      final params = d.inParam.bridge.callbackParams ?? const [];
      final userSig = d.inParam.bridge.wrapperType.replaceAll('?', '');
      final ffiSig = d.inParam.bridge.callbackFfiSignature ?? userSig;
      // The trampoline's own signature is the FFI one: `Pointer.fromFunction`
      // needs the C types. The registry holds the *user-facing* callback —
      // the two agree on every parameter but a boolean, which the
      // convention renders as an `int`.
      final paramList = params.map((p) => '${p.ffiType} ${p.name}').join(', ');
      final argList = params
          .map(
            (p) => p.ffiType == 'ffi.Bool' && p.type == 'int'
                ? '${p.name} ? 1 : 0'
                : p.name,
          )
          .join(', ');
      b.writeln('/// The destroy notify the callee calls when it is done');
      b.writeln('/// with the buffer it took over.');
      b.writeln('///');
      b.writeln('/// The notify outlives the call, so the trampoline is');
      b.writeln('/// permanent — a scoped `NativeCallable` would be closed');
      b.writeln('/// before the notify fires.');
      b.writeln('${staticPrefix}final ${d.registryName} = <$userSig>[];');
      // The trampoline is a Dart function: a C `void` return is Dart's
      // `void`, not `ffi.Void`.
      final ffiReturn = ffiSig.contains(' Function(')
          ? ffiSig.substring(0, ffiSig.indexOf(' Function('))
          : 'ffi.Void';
      final returnType = ffiReturn == 'ffi.Void' ? 'void' : ffiReturn;
      b.writeln('$staticPrefix$returnType ${d.trampolineName}($paramList) {');
      b.writeln('  if (${d.registryName}.isEmpty) return;');
      b.writeln('  final fn = ${d.registryName}.removeAt(0);');
      b.writeln('  fn($argList);');
      b.writeln('}');
      b.writeln(
        '${staticPrefix}final ${d.ptrName} = '
        'ffi.Pointer.fromFunction<$ffiSig>('
        '${d.trampolineName});',
      );
    }
    b.writeln(lookupDecl);
    // The byte-array lifetime note belongs on the *public* wrapper: the
    // native binding above is private, so a note there never reaches the
    // API reference.
    for (final line in ctx.byteArrayLifetimeDoc(fn)) {
      b.writeln(line);
    }
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
    if (o.bridge.isOutArray) return _outListVar(o);
    final bytes = o.bridge.outExtractBytes;
    if (bytes != null) {
      final lengthIndex = o.bridge.outByteBufferLengthIndex!;
      final lengthOut = outs.firstWhere((x) => x.paramIndex == lengthIndex);
      return bytes(o.varName, lengthOut.varName);
    }
    return o.bridge.outExtract!(o.varName);
  }

  /// The local holding the Dart list an OUT array was copied into.
  static String _outListVar(_OutParam o) => '_list${o.varName}';

  /// The expression that yields the element count of the OUT array [o].
  ///
  /// Three shapes:
  ///
  /// * a fixed size (`fixed-size="4"`) — a literal;
  /// * a sibling **in** parameter — the capacity the caller passes;
  /// * a sibling **out** parameter — the slot the callee filled.
  String _outArrayCountExpr(
    _OutParam o,
    List<_OutParam> outs,
    List<_InParam> ins,
  ) {
    final countIndex = o.bridge.outArrayCountIndex;
    if (countIndex == null) return '${o.bridge.outArrayFixedCount}';
    if (o.bridge.outArrayCountIsInput) {
      return ins.firstWhere((x) => x.paramIndex == countIndex).name;
    }
    return '${outs.firstWhere((x) => x.paramIndex == countIndex).varName}.value';
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

  /// The local name of the native buffer the `withNativeBytes` helper
  /// hands to the call for the byte array at parameter index [index].
  static String _bytesBufferVar(int index) => '_bytesBuf$index';

  /// The local name of the byte count the `withNativeBytes` helper hands
  /// to the call for the byte array at parameter index [index].
  static String _bytesLengthVar(int index) => '_bytesLen$index';

  /// The local name of the element count the marshalling helper hands to
  /// the call for the string array or counted string [owner].
  ///
  /// `withNativeStringList` reports the number of elements of the list,
  /// `withNativeStringBytes` the number of *bytes* of the string.
  static String _stringCountVar(_InParam owner) => '${owner.nativeVar}Len';

  /// The expression that yields the element count of a `char **` return.
  ///
  /// The GIR binds a callee-allocated string array to the OUT parameter
  /// that holds its count. The count is read out of the slot the callee
  /// filled — after the call, so the value is there.
  static String? _retCountExpr(int? countIndex, List<_OutParam> outs) {
    if (countIndex == null) return null;
    for (final o in outs) {
      if (o.paramIndex == countIndex) return '${o.varName}.value';
    }
    return null;
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

  /// The base name of the members a destroy notify generates.
  static String _destroyBase(String cIdentifier, GirParameter p) =>
      '_${toLowerCamel(cIdentifier)}${toUpperCamel(p.name)}';

  /// Name of the generated registry member for a destroy notify.
  static String _destroyRegistryName(String cIdentifier, GirParameter p) =>
      '${_destroyBase(cIdentifier, p)}Callbacks';

  /// Name of the generated trampoline member for a destroy notify.
  static String _destroyTrampolineName(String cIdentifier, GirParameter p) =>
      '${_destroyBase(cIdentifier, p)}Trampoline';

  /// Name of the generated permanent function pointer for a destroy notify.
  static String _destroyPtrName(String cIdentifier, GirParameter p) =>
      '${_destroyBase(cIdentifier, p)}Ptr';

  /// Whether [name] would collide with a `dart:core` Object member.
  static bool conflictsWithObjectMember(String name) =>
      _objectMembers.contains(name);

  /// Renames members that would shadow a core type inside the class body.
  static String safeMemberName(String name) =>
      _coreTypes.contains(name) ? '${name}_' : name;
}
