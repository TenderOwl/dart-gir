/// Emits typed signal-connection helpers (`onSignalName`) for GIR signals.
///
/// For each typed signal whose arity, return type, and arg types are
/// supported, an `onSignalName(<typed callback>)` method is emitted on
/// the owning class. The per-package trampolines, registries, and connect
/// helpers live in `signals.dart` (see `signals_helper.dart`).
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart' show TypeKind;
import 'context.dart';

/// Maximum signal arity we emit a typed helper for. The largest in the
/// corpus is 5 (`Gio.DBusObjectManagerClient.interface-proxy-signal`).
const _maxSignalArity = 5;

/// One FFI shape — the type as it appears in the trampoline's FFI
/// signature. Distinct from the bridge's `wrapperType` (the Dart-side
/// type the user sees in their callback).
enum FfiShape { void_, pointer, int32, uint32, bool_, double_, string }

extension FfiShapeExt on FfiShape {
  String get code => switch (this) {
        FfiShape.void_ => 'v',
        FfiShape.pointer => 'o',
        FfiShape.int32 => 'i',
        FfiShape.uint32 => 'u',
        FfiShape.bool_ => 'b',
        FfiShape.double_ => 'd',
        FfiShape.string => 's',
      };

  /// The FFI type as written in the trampoline's NativeCallable.
  String get ffiType => switch (this) {
        FfiShape.void_ => 'ffi.Void',
        FfiShape.pointer => 'ffi.Pointer<ffi.Void>',
        FfiShape.int32 => 'ffi.Int32',
        FfiShape.uint32 => 'ffi.Uint32',
        FfiShape.bool_ => 'ffi.Bool',
        FfiShape.double_ => 'ffi.Double',
        FfiShape.string => 'ffi.Pointer<Utf8>',
      };

  bool get needsFree => this == FfiShape.string;
}

/// Return shape of the signal — affects the trampoline's return type and
/// the user's callback return type.
enum ReturnShape { void_, int, uint, bool_, double_ }

extension ReturnShapeExt on ReturnShape {
  String get code => switch (this) {
        ReturnShape.void_ => 'v',
        ReturnShape.int => 'i',
        ReturnShape.uint => 'u',
        ReturnShape.bool_ => 'b',
        ReturnShape.double_ => 'd',
      };

  /// Dart-side return type for the trampoline function. `NativeCallable<T>`
  /// requires T to be a Dart function type with Dart primitives (bool,
  /// int, double, void) — not the FFI typedefs — at the return position.
  /// Args may still use FFI types.
  String get dartReturnType => switch (this) {
        ReturnShape.void_ => 'void',
        ReturnShape.int => 'int',
        ReturnShape.uint => 'int',
        ReturnShape.bool_ => 'bool',
        ReturnShape.double_ => 'double',
      };
}

/// One typed signal's shape. Signals with the same [bucketId] share a
/// per-package trampoline + registry.
class SignalSignature {
  SignalSignature({
    required this.bucketId,
    required this.marshallerReturn,
    required this.shapes,
    required this.ffiReturnType,
    required this.trampolineFfiType,
    required this.callbackType,
    required this.argNames,
    required this.argMarshals,
  });

  /// Short, stable identifier derived from the return + arg shapes — e.g.
  /// `v_1_o`, `v_3_o_i_s`, `i_1_o`. Used as a suffix for the per-package
  /// singletons.
  final String bucketId;

  /// Return shape — affects the user's callback return type.
  final ReturnShape marshallerReturn;

  /// Per-arg shapes in source order.
  final List<FfiShape> shapes;

  /// FFI return type for the trampoline, e.g. `'ffi.Void'`.
  final String ffiReturnType;

  /// Full FFI type for the trampoline's NativeCallable, e.g.
  /// `'ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)'`.
  final String trampolineFfiType;

  /// Dart type users write in their callback, e.g.
  /// `'void Function(GParamSpec pspec)'`.
  final String callbackType;

  /// Per-arg lowerCamel'd parameter names used in both the trampoline's
  /// FFI signature and the callback's Dart signature.
  final List<String> argNames;

  /// Per-arg expression converting the trampoline's raw FFI arg to the
  /// wrapper-type argument the Dart callback expects. For primitives this
  /// is just the parameter name; for class/record args it is
  /// `WrapperType.fromPointer(rawArg)`; for strings it reads + frees via
  /// `g_free`.
  final List<String> argMarshals;
}

/// The result of partitioning one namespace's signals into typed buckets.
class SignalBuckets {
  SignalBuckets({
    required this.signatures,
    required this.signalToBucketId,
  });

  /// One entry per unique signature.
  final Map<String, SignalSignature> signatures;

  /// Maps each kept signal to its bucket id.
  final Map<GirSignal, String> signalToBucketId;

  bool get isEmpty => signatures.isEmpty;
}

/// Builds Dart code for typed `onSignalName` methods on [className] for
/// each kept signal in [signals]. Returns the concatenation of doc +
/// method bodies, separated by blank lines.
///
/// Signals that don't match the current scope are recorded as `signal`
/// skips via [EmitContext.report] and omitted from the output. [buckets]
/// drives the bucket id used in each emitted method body; pass the result
/// of [buildSignalBuckets] so the same id is shared across every signal
/// of the same signature in the package.
String emitSignalConnectors(
  EmitContext ctx,
  List<GirSignal> signals,
  String className,
  Set<String> memberNames, {
  required SignalBuckets buckets,
}) {
  // Local signals are resolved against the current namespace; the
  // inherited ones already had their bucket id computed by the caller.
  final b = StringBuffer();
  for (final sig in signals) {
    final reason = signalSkipReason(sig, ctx);
    if (reason != null) {
      ctx.report.skip('signal', '$className.${sig.name}', reason);
      continue;
    }
    final bucketId = buckets.signalToBucketId[sig];
    if (bucketId == null) continue; // inherited; emitted by class_emitter
    final sigInfo = buckets.signatures[bucketId]!;
    final methodName = 'on${toUpperCamel(sig.name)}';
    if (!memberNames.add(methodName)) {
      ctx.report.skip(
        'signal',
        '$className.${sig.name}',
        'name collision (a member named `$methodName` already exists)',
      );
      continue;
    }
    for (final line in ctx.docLines(sig.doc)) {
      b.writeln(line);
    }
    b.writeln('int $methodName(${sigInfo.callbackType} callback) {');
    b.writeln(
      '  return _connectSignal_$bucketId(this.handle, ${_stringLiteral(sig.name)}, callback);',
    );
    b.writeln('}');
    b.writeln();
  }
  return b.toString();
}

/// Why [sig] is out of scope, or null when it can be emitted. The
/// reason is also used as the per-bucket id derivation. [relativeTo]
/// overrides the current namespace for arg/return type resolution —
/// used for inherited signals whose arg types belong to an ancestor
/// namespace.
String? signalSkipReason(
  GirSignal sig,
  EmitContext ctx, {
  GirNamespace? relativeTo,
}) {
  // `weak-ref` is dispatched by g_object_weak_ref, not g_signal_emit, and
  // connecting it via g_signal_connect_data is rejected by GObject.
  if (sig.name == 'weak-ref') {
    return 'weak-ref is not connectable via g_signal_connect_data';
  }
  // Detailed signal names (`notify::property-name`) are routed through
  // the `connectSignal` escape hatch — they are reachable via the
  // generated `onSignalName` parent shape, but the detail segment is
  // open-ended and out of scope for typed helpers.
  if (sig.name.contains('::')) {
    return 'detailed signal names (notify::property-name) are out of '
        'scope; use connectSignal';
  }
  if (sig.parameters.length > _maxSignalArity) {
    return 'arity ${sig.parameters.length} exceeds supported max ($_maxSignalArity)';
  }
  // Per-param checks: classify each arg's FFI shape; bail with a precise
  // reason on the first unsupported one.
  for (var i = 0; i < sig.parameters.length; i++) {
    final p = sig.parameters[i];
    final shape = _ffiShapeFor(p.type, ctx, relativeTo: relativeTo);
    if (shape == null) {
      return 'unsupported arg type at index $i: ${_typeName(p.type)}';
    }
  }
  // Return type check: classify the return shape.
  final retShape = _returnShapeFor(sig.returnType);
  if (retShape == null) {
    return 'unsupported return type: ${_typeName(sig.returnType)}';
  }
  return null;
}

/// Whether [sig] gets a typed `onSignalName` helper in this release.
bool isKeptSignal(
  GirSignal sig,
  EmitContext ctx, {
  GirNamespace? relativeTo,
}) =>
    signalSkipReason(sig, ctx, relativeTo: relativeTo) == null;

/// Builds the per-namespace [SignalBuckets] partition. Walks [signals],
/// keeps the ones with supported signatures, and groups them by shape.
/// Each [GirSignal] may carry an optional originating [GirNamespace] — set
/// when the signal is inherited from an ancestor class in a different
/// namespace, so arg types resolve correctly against the original.
SignalBuckets buildSignalBuckets(
  Iterable<({GirSignal signal, GirNamespace? ns})> signals,
  EmitContext ctx,
) {
  final signatures = <String, SignalSignature>{};
  final signalToBucketId = <GirSignal, String>{};
  for (final entry in signals) {
    final sig = entry.signal;
    if (signalSkipReason(sig, ctx, relativeTo: entry.ns) != null) continue;
    final bucket = _signatureFor(sig, ctx, relativeTo: entry.ns);
    signatures.putIfAbsent(bucket.bucketId, () => bucket);
    signalToBucketId[sig] = bucket.bucketId;
  }
  return SignalBuckets(
    signatures: signatures,
    signalToBucketId: signalToBucketId,
  );
}

// ─── shape classification ──────────────────────────────────────────────

FfiShape? _ffiShapeFor(GirTypeRef? ref, EmitContext ctx, {GirNamespace? relativeTo}) {
  if (ref == null) return null;
  final m = ctx.resolve(ref, relativeTo: relativeTo);
  switch (m.kind) {
    case TypeKind.classType:
    case TypeKind.interface:
    case TypeKind.record:
    case TypeKind.union:
      return FfiShape.pointer;
    case TypeKind.enumeration:
      return FfiShape.int32;
    case TypeKind.bitfield:
      return FfiShape.uint32;
    case TypeKind.boolean:
      return FfiShape.bool_;
    case TypeKind.primitive:
      // Primitive scalars map to int/uint/double via the bridge's
      // wrapperType string.
      final t = m.dartType;
      if (t == 'int') return FfiShape.int32;
      if (t == 'double' || t == 'float') return FfiShape.double_;
      // Other primitives are not used by signals today.
      return null;
    case TypeKind.string:
      return FfiShape.string;
    case TypeKind.pointer:
      return FfiShape.pointer;
    case TypeKind.voidType:
      return null;
    case TypeKind.callback:
    case TypeKind.opaque:
    case TypeKind.stringList:
    case TypeKind.unsupported:
      return null;
  }
  return null;
}

ReturnShape? _returnShapeFor(GirTypeRef? ref) {
  if (ref == null) return ReturnShape.void_;
  final name = ref.name;
  if (name == null || name == 'none' || name == 'void') {
    return ReturnShape.void_;
  }
  // Use cType as fallback since primitive return types don't always
  // populate `name` (e.g. `c:type="gboolean"` with `name="gboolean"`).
  final c = ref.cType ?? '';
  if (c == 'gboolean') return ReturnShape.bool_;
  if (c == 'gint' || c == 'gint8' || c == 'gint16' || c == 'gint32' ||
      c == 'gshort' || c == 'glong') {
    return ReturnShape.int;
  }
  if (c == 'guint' || c == 'guint8' || c == 'guint16' || c == 'guint32' ||
      c == 'gushort' || c == 'gulong' || c == 'gsize') {
    return ReturnShape.uint;
  }
  if (c == 'gdouble' || c == 'gfloat') return ReturnShape.double_;
  // Fallback to the name field.
  switch (name) {
    case 'gboolean':
      return ReturnShape.bool_;
    case 'gint':
    case 'gshort':
    case 'glong':
      return ReturnShape.int;
    case 'guint':
    case 'gushort':
    case 'gulong':
      return ReturnShape.uint;
    case 'gdouble':
    case 'gfloat':
      return ReturnShape.double_;
  }
  return null;
}

// ─── signature construction ─────────────────────────────────────────────

SignalSignature _signatureFor(GirSignal sig, EmitContext ctx, {GirNamespace? relativeTo}) {
  final shapes = <FfiShape>[];
  final argTypes = <String>[];
  final argNames = <String>[];
  final argMarshals = <String>[];
  for (var i = 0; i < sig.parameters.length; i++) {
    final p = sig.parameters[i];
    final shape = _ffiShapeFor(p.type, ctx, relativeTo: relativeTo)!;
    shapes.add(shape);
    final bridge = ctx.bridgeFor(
      p.type,
      nullable: p.nullable,
      relativeTo: relativeTo,
    ).$1!;
    argTypes.add(bridge.wrapperType);
    final pname = escapeKeyword(toLowerCamel(p.name));
    argNames.add(pname);
    // Build the per-arg conversion: most primitives pass through; class
    // pointers wrap into the wrapper type; strings read + free.
    argMarshals.add(_argMarshal(pname, shape, bridge, p.nullable));
  }
  final retShape = _returnShapeFor(sig.returnType)!;
  final marshallerReturn = retShape;
  // Bucket id: short structured name derived from FFI shapes plus a
  // Dart-type suffix. The suffix is required — the registry is typed as
  // `Map<int, T>` where T is the Dart callback signature, so two signals
  // sharing FFI shape but having different wrapper types (e.g. two
  // distinct enum classes both encoded as `int32`) cannot share a bucket.
  final idParts = <String>[marshallerReturn.code, shapes.length.toString()];
  for (final s in shapes) {
    idParts.add(s.code);
  }
  final ffiBucketId = idParts.join('_');
  // Build the Dart callback type the user writes — required below.
  final cbArgs = <String>[
    for (var i = 0; i < shapes.length; i++) '${argTypes[i]} ${argNames[i]}',
  ];
  final cbReturn = marshallerReturn.dartReturnType;
  final callbackType = '$cbReturn Function(${cbArgs.join(', ')})';
  final dartSuffix = argTypes
      .map((t) =>
          t.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase())
      .join('_');
  final bucketId =
      dartSuffix.isEmpty ? ffiBucketId : '${ffiBucketId}_$dartSuffix';

  // Build the trampoline's Dart function type. NativeCallable<T>
  // requires T to be a Dart function type whose parameters and return
  // use `dart:ffi` native types. The callback's Dart representation
  // (e.g. `int` for `ffi.Int32`) is what the user actually writes.
  final ffArgs = <String>[
    for (var i = 0; i < shapes.length; i++) shapes[i].ffiType,
    'ffi.Pointer<ffi.Void>', // user_data
  ];
  final retFfi = _ffiReturnType(retShape);
  final trampolineFfiType = '$retFfi Function(${ffArgs.join(', ')})';

  return SignalSignature(
    bucketId: bucketId,
    marshallerReturn: marshallerReturn,
    shapes: shapes,
    ffiReturnType: retFfi,
    trampolineFfiType: trampolineFfiType,
    callbackType: callbackType,
    argNames: argNames,
    argMarshals: argMarshals,
  );
}

/// Builds the trampoline's expression for passing arg [pname] to the
/// user's Dart callback. `g_free` is reserved for the trampoline body to
/// run *after* the callback returns (see [signals_helper.emitBucket]).
String _argMarshal(String pname, FfiShape shape, TypeBridge bridge, bool nullable) {
  switch (shape) {
    case FfiShape.void_:
      return pname;
    case FfiShape.pointer:
      // Class/record/interface: wrap raw pointer into the wrapper type.
      return bridge.fromNative(pname);
    case FfiShape.int32:
    case FfiShape.uint32:
      // Enums/bitfields/primitives all need the bridge's fromNative so
      // the user gets `GtkTextDirection` instead of `int`, etc. The
      // trampoline parameter's static type is the FFI typedef (Int32);
      // at runtime it decodes to a Dart int, but the analyzer sees the
      // typedef — cast through `int` so fromNative's signature accepts
      // it without a lint ignore.
      return bridge.fromNative('($pname as int)');
    case FfiShape.double_:
      return bridge.fromNative('($pname as double)');
    case FfiShape.bool_:
      return '$pname != 0';
    case FfiShape.string:
      // Receiver-side string: read + null-check. The trampoline body
      // calls `g_free(pname)` after the callback returns. Match the
      // callback's nullability — non-nullable args must surface as
      // non-null Dart strings; the receiver owns the `g_free`.
      final read = '($pname).cast<Utf8>().toDartString()';
      if (nullable) {
        return '(($pname) == ffi.nullptr ? null : $read)';
      }
      return '(($pname) == ffi.nullptr ? "" : $read)';
  }
}

String _typeName(GirTypeRef? ref) {
  if (ref == null) return 'null';
  return ref.name ?? ref.cType ?? '?';
}

/// Single-quoted Dart string literal for [value].
String _stringLiteral(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return "'$escaped'";
}

/// Returns the FFI return-type token used in the trampoline's NativeCallable
/// type parameter. NativeCallable<T> requires T to be a Dart function type
/// with all FFI native types (Dart 3.13.x behavior).
String _ffiReturnType(ReturnShape shape) => switch (shape) {
      ReturnShape.void_ => 'ffi.Void',
      ReturnShape.int => 'ffi.Int32',
      ReturnShape.uint => 'ffi.Uint32',
      ReturnShape.bool_ => 'ffi.Bool',
      ReturnShape.double_ => 'ffi.Double',
    };

/// Returns the inherited signals from [cls]'s parent chain, in declaration
/// order (deepest ancestor first, then each closer ancestor). Signals
/// declared locally on [cls] are not included — pass [cls.signals]
/// alongside this list. The result is used to extend the per-class
/// `onSignalName` set with inherited typed helpers.
///
/// Dedup uses identity — two distinct signals with the same name on
/// different ancestor classes are kept separate (they may have
/// different bucket shapes).
List<GirSignal> inheritedSignals(GirClass cls, EmitContext ctx) {
  final result = <GirSignal>[];
  final seenSig = <GirSignal>{};
  final seenCls = <String>{};
  var current = cls;
  var currentNs = ctx.namespace;
  while (current.parent != null &&
      seenCls.add('${currentNs.name}.${current.name}')) {
    final found = ctx.findClass(current.parent!);
    if (found == null) break;
    currentNs = found.$1;
    current = found.$2;
    for (final sig in current.signals) {
      if (seenSig.add(sig)) {
        result.add(sig);
      }
    }
  }
  return result;
}