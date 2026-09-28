/// Emits Dart function typedefs for GIR callbacks.
///
/// Each callback becomes a plain Dart function type, e.g.
///
///     typedef GCompareDataFunc = int Function(
///         ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
///
/// which the caller wraps at the call site via `Pointer.fromFunction`.
/// The wrapper-level API accepts the typedef; the native bridge hands FFI a
/// `Pointer<NativeFunction<...>>`. See [EmitContext.bridgeFor] for the
/// callback bridge.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart' show packageNameFor, TypeKind;
import 'context.dart';

/// Renders a `GirCallback` as a single Dart `typedef` declaration.
///
/// Returns null and reports a precise skip reason when the callback can't be
/// expressed (unsupported parameter/return type, declared in a non-emitted
/// package, etc.).
class CallbackEmitter {
  CallbackEmitter(this.ctx);

  final EmitContext ctx;

  /// Public Dart name for [cb], matching the GIR `c:type` when present
  /// (`GCompareDataFunc`), otherwise `${cIdentifierPrefixes[0]}${CamelName}`.
  String dartName(GirCallback cb) {
    final cType = cb.cType;
    if (cType != null && cType.isNotEmpty) return cType;
    final prefix = ctx.namespace.cIdentifierPrefixes.isEmpty
        ? ''
        : ctx.namespace.cIdentifierPrefixes.first;
    return '$prefix${toUpperCamel(cb.name)}';
  }

  /// Builds the right-hand side of the user-facing typedef for [cb].
  /// Returns null when any type in the signature can't be represented; the
  /// caller records a skip reason.
  ///
  /// The typedef uses `dart:ffi` types throughout (`int`, `double`, `bool`
  /// map to their FFI counterparts, class parameters render as
  /// `ffi.Pointer<ffi.Void>`, strings as `ffi.Pointer<ffi.Utf8>`). This is
  /// the only way to satisfy `Pointer.fromFunction<T>`'s structural type
  /// requirement that every parameter and return type be a `NativeType` —
  /// non-FFI types like `String`, `List`, or user-defined classes aren't
  /// accepted there. The FFI boundary in [EmitContext] uses [ffiSignature]
  /// (which is identical to this method for non-callback params).
  String? signature(GirCallback cb, {String label = 'callback'}) {
    final ret = _userFacingType(cb.returnType,
        label: '$label return', forReturn: true);
    if (ret == null) return null;
    final params = <String>[];
    for (final p in cb.parameters) {
      final typeName = _userFacingType(p.type,
          label: '$label parameter ${p.name}');
      if (typeName == null) return null;
      params.add(typeName);
    }
    return '$ret Function(${params.join(', ')})';
  }

  /// Builds an inline FFI signature for [cb] suitable for `Pointer.fromFunction<T>`
  /// and `NativeFunction<T>`. Unlike [signature] this uses FFI primitive
  /// types (`ffi.Int32`, `ffi.Double`, `ffi.Pointer<ffi.Void>`) because
  /// those generic FFI APIs require their type arguments to consist solely
  /// of `dart:ffi` `NativeType`s.
  String? ffiSignature(GirCallback cb, {String label = 'callback'}) {
    final ret = _ffiTypeFor(cb.returnType,
        label: '$label return', forReturn: true);
    if (ret == null) return null;
    final params = <String>[];
    for (final p in cb.parameters) {
      final typeName =
          _ffiTypeFor(p.type, label: '$label parameter ${p.name}');
      if (typeName == null) return null;
      params.add(typeName);
    }
    return '$ret Function(${params.join(', ')})';
  }

  /// The full `typedef` declaration including doc comments.
  String? emit(GirCallback cb) {
    final name = dartName(cb);
    final label = '${ctx.namespace.name}.$name';

    // Cross-package guard: callbacks declared in a package the current run
    // is not emitting cannot be resolved into a concrete typedef.
    final declPkg = packageNameFor(ctx.namespace);
    if (!ctx.emittedPackages.contains(declPkg)) {
      ctx.report.skip('callback', label,
          'callback is in non-generated package $declPkg');
      return null;
    }

    final sig = signature(cb, label: name);
    if (sig == null) return null;

    final b = StringBuffer();
    for (final line in ctx.docLines(cb.doc)) {
      b.writeln(line);
    }
    // `Pointer.fromFunction` requires a top-level or static Dart function;
    // closures and instance methods throw at call time. Note the limitation
    // inline so users don't have to read source to find out.
    b.write('/// ');
    b.writeln(
        'Pass a top-level or static Dart function. Closures are not supported.');
    b.write('typedef $name = $sig;');
    return b.toString();
  }

  /// Returns the type string used inside the user-facing callback typedef.
  ///
  /// Dart's `Pointer.fromFunction<T>` accepts a function whose parameters and
  /// return type are `dart:ffi` `NativeType`s, but it's been observed to be
  /// picky about *which* NativeTypes: it treats `Int32 ↔ Int32` as
  /// non-subtype (when both source and target are explicitly written that
  /// way) but accepts `int ↔ Int32` for Dart's `int`. The ergonomic
  /// convention in Dart FFI bindings is therefore to declare callback
  /// typedefs with **Dart convenience types** (`int`, `double`, `Pointer<X>`)
  /// and let `Pointer.fromFunction` do the implicit conversion at the call
  /// site. Pointer-shaped types have no Dart convenience equivalent, so
  /// those render as `ffi.Pointer<ffi.Void>` directly. Booleans are an
  /// exception: `bool` is **not** treated as a subtype of `Int32` here, so
  /// boolean params/returns render as `int` (with the convention 0 = false).
  ///
  /// Callback-typed references render as the nested callback signature.
  String? _userFacingType(GirTypeRef? ref,
      {required String label, bool forReturn = false}) {
    if (ref == null) return 'void';
    if (ref.name != null) {
      final nested = _resolveCallback(ref);
      if (nested != null) return nested;
    }
    final m = ctx.resolve(ref);
    if (m.kind == TypeKind.unsupported) {
      ctx.report.skip('callback', label,
          m.reason ?? 'unsupported type');
      return null;
    }
    switch (m.kind) {
      case TypeKind.primitive:
        return m.dartType; // int or double
      case TypeKind.boolean:
        return 'int'; // Dart FFI doesn't unify bool ↔ Int32 here
      case TypeKind.string:
        return 'ffi.Pointer<Utf8>';
      case TypeKind.classType:
      case TypeKind.interface:
      case TypeKind.record:
      case TypeKind.union:
      case TypeKind.pointer:
      case TypeKind.opaque:
        return 'ffi.Pointer<ffi.Void>';
      case TypeKind.enumeration:
      case TypeKind.bitfield:
        return 'int';
      case TypeKind.callback:
        // Already handled above by _resolveCallback.
        return null;
      case TypeKind.voidType:
        return 'void';
      case TypeKind.unsupported:
        return null;
    }
  }

  /// Returns the FFI-typed parameter/return string for [ref] when building
  /// an inline FFI signature. All types must be `dart:ffi` `NativeType`s.
  /// Callback-typed references render as their nested FFI inline signature.
  String? _ffiTypeFor(GirTypeRef? ref,
      {required String label, bool forReturn = false}) {
    if (ref == null) return 'ffi.Void';
    if (ref.name != null) {
      final nested = _resolveFfiCallback(ref);
      if (nested != null) return nested;
    }
    final (bridge, reason) = ctx.bridgeFor(ref, forReturn: forReturn);
    if (bridge == null) {
      ctx.report.skip('callback', label, reason ?? 'unsupported type');
      return null;
    }
    return bridge.nativeType;
  }

  /// Resolves [ref] to the user-facing Dart callback signature string, or
  /// null if [ref] is not a callback reference (or the callback can't be
  /// emitted).
  String? _resolveCallback(GirTypeRef ref) =>
      _resolveCallbackSig(ref, useFfi: false);

  /// Resolves [ref] to the inline FFI callback signature, or null if [ref]
  /// is not a callback reference.
  String? _resolveFfiCallback(GirTypeRef ref) =>
      _resolveCallbackSig(ref, useFfi: true);

  String? _resolveCallbackSig(GirTypeRef ref, {required bool useFfi}) {
    final decl = ctx.findDeclaration(ref.name);
    if (decl == null) return null;
    final (declNs, declObj) = decl;
    if (declObj is! GirCallback) return null;
    final owningPkg = packageNameFor(declNs);
    if (!ctx.emittedPackages.contains(owningPkg)) return null;
    final cbCtx = EmitContext(
      namespace: declNs,
      allNamespaces: ctx.allNamespaces,
      report: ctx.report,
      emittedPackages: ctx.emittedPackages,
    );
    final emitter = CallbackEmitter(cbCtx);
    return useFfi
        ? emitter.ffiSignature(declObj,
            label: '${declNs.name}.${declObj.name}')
        : emitter.signature(declObj,
            label: '${declNs.name}.${declObj.name}');
  }
}
