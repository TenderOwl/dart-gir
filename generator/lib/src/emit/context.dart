/// Shared emission context: type bridging, name registry, import tracking.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart';
import 'callback_emitter.dart';
import 'report.dart';

/// A namespace `<function>` whose `<method>` GIR sibling carries
/// `moved-to="<bare>"` (i.e. the moved-to value has no dot, so the
/// target is a namespace function, not another class method). The
/// generator re-emits the namespace function as a `static` method on
/// the owning GIR class instead of as a top-level function; the
/// `<method>` itself is skipped via the existing `movedTo != null` rule.
typedef StaticClassFunction = ({
  /// C symbol shared by both the `<method>` and the namespace `<function>`.
  String cIdentifier,

  /// Dart class name of the owning GIR declaration (e.g. `GResource`,
  /// `GdkEvent`). Matches `ctx.dartTypeName(ctx.namespace.name, type.name)`.
  String ownerClassDartName,

  /// GIR `name` attribute of the namespace `<function>`. The Dart method
  /// name is `toLowerCamel(namespaceFunctionName)`.
  String namespaceFunctionName,

  /// The actual namespace `<function>` element. Carries the parameter
  /// list and return type used to emit the static-method body.
  GirFunction fn,
});

/// How a GIR type is marshalled across the FFI boundary for one usage site.
class TypeBridge {
  const TypeBridge({
    required this.wrapperType,
    required this.nativeType,
    required this.dartFfiType,
    required this.toNative,
    required this.fromNative,
    this.isString = false,
    this.isStringList = false,
    this.isVoid = false,
    this.isNullableCallback = false,
    this.outPointee,
    this.outAllocSize,
    this.outExtract,
    this.arrayLengthParameter,
  });

  /// Public Dart type used in wrapper signatures, e.g. `int`, `GObject?`.
  final String wrapperType;

  /// Native type used in `ffi.NativeFunction` signatures, e.g. `ffi.Int32`.
  final String nativeType;

  /// Dart-side type of the FFI function signature, e.g. `int`.
  final String dartFfiType;

  /// Converts a wrapper-typed expression to the FFI call argument.
  final String Function(String expr) toNative;

  /// Converts the raw FFI result to the wrapper type.
  final String Function(String expr) fromNative;

  /// String parameters are marshalled via `withNativeString` nesting.
  final bool isString;

  /// argv-style string-list parameters are marshalled via
  /// `withNativeStringList` nesting. The wrapper signature takes
  /// `List<String?>?`; the native call gets `Pointer<Pointer<Utf8>>`.
  final bool isStringList;

  /// `void` return.
  final bool isVoid;

  /// `true` when this bridge is for a callback-typed parameter that may be
  /// `null` at the call site. The generator emits a conditional allocation
  /// so the `NativeCallable` is only constructed when the user actually
  /// supplied a function; on `null` the native side receives `ffi.nullptr`.
  final bool isNullableCallback;

  /// Pointee type to `malloc` for an out parameter, null when the type
  /// cannot appear as an out parameter.
  final String? outPointee;

  /// For record/struct/class OUT parameters, GLib writes the entire
  /// struct (not a pointer to it) into the buffer the wrapper hands it.
  /// We don't know `sizeof(T)` statically, so allocate a fixed-size
  /// buffer of this many bytes. `null` means allocate per
  /// `malloc<outPointee>()` (one slot of the pointee's natural size).
  final int? outAllocSize;

  /// Reads the out value from the allocated pointer variable.
  final String Function(String varName)? outExtract;

  /// For bound-length array parameters, the 0-based index of the
  /// parameter in the callable's signature that carries the array's
  /// length. The emitter injects an extra `int` slot on both the
  /// native and Dart signatures at this position. `null` for unbounded
  /// arrays (the user is responsible for the length).
  final int? arrayLengthParameter;
}

/// Per-package emission state shared by all emitters.
class EmitContext {
  EmitContext({
    required this.namespace,
    required this.allNamespaces,
    required this.report,
    required this.emittedPackages,
  }) : resolver = TypeResolver(allNamespaces);

  final GirNamespace namespace;
  final List<GirNamespace> allNamespaces;
  final GenerationReport report;
  final TypeResolver resolver;

  /// Package names generated in this run; types in other packages are
  /// treated as unsupported (their members get skipped).
  final Set<String> emittedPackages;

  /// Namespaces loaded before [namespace] in dependency order.
  List<GirNamespace> get priorNamespaces {
    final idx = allNamespaces.indexOf(namespace);
    return idx <= 0 ? const [] : allNamespaces.sublist(0, idx);
  }

  /// Names the generated library itself occupies: runtime helpers from
  /// `package:ffi`/`gir_ffi` and emitted support declarations. GIR symbols
  /// mapping to these (e.g. `g_malloc` → `malloc`) get a `Fn` suffix.
  static const reservedNames = {
    'malloc',
    'calloc',
    'realloc',
    'alignedAlloc',
    'free',
    'Utf8',
    'Char',
    'Opaque',
    'stringFromNative',
    'stringToNative',
    'withNativeString',
    'openLibrary',
    'GlibException',
    'gobjectFinalizer',
    'gObjectRefSink',
    'gObjectUnref',
  };

  /// Cross-package imports required by emitted code (package names).
  final Set<String> imports = {};

  /// Top-level names already declared in this package.
  late final Set<String> topLevelNames = {
    ...reservedNames,
    '${pkgIdent}Libs',
    '${pkgIdent}Lookup',
  };

  bool usesFfiString = false; // package:ffi Utf8
  bool usesMalloc = false;
  bool usesGirFfi = false; // stringFromNative / withNativeString
  bool usesGlibException = false;

  /// C identifier prefix prepended to GIR type names (`G` for GLib/GObject).
  String prefixFor(GirNamespace ns) =>
      ns.cIdentifierPrefixes.isEmpty ? '' : ns.cIdentifierPrefixes.first;

  GirNamespace? namespaceNamed(String name) {
    for (final ns in allNamespaces) {
      if (ns.name == name) return ns;
    }
    return null;
  }

  /// Public Dart type name for [localName] declared in namespace [nsName].
  String dartTypeName(String nsName, String localName) {
    var local = localName;
    // Sanitize nested/odd GIR names like `Value._data__union`.
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(local)) {
      local = toUpperCamel(local);
    }
    final ns = namespaceNamed(nsName);
    final combined = (ns == null ? '' : prefixFor(ns)) + local;
    // Type names are always UpperCamelCase (`cairo` + `Region` →
    // `CairoRegion`).
    return combined.isEmpty
        ? combined
        : combined[0].toUpperCase() + combined.substring(1);
  }

  /// Claims a top-level declaration name; false when already taken.
  bool claimName(String name) => topLevelNames.add(name);

  /// The generated package name for the current namespace.
  String get pkg => packageNameFor(namespace);

  /// lowerCamel package identifier used for helper names
  /// (`gdkPixbufLibs`, `gdkPixbufLookup`).
  String get pkgIdent => toLowerCamel(pkg);

  /// Finds a type declaration by (possibly qualified) GIR name, searching
  /// [relativeTo] (default: current namespace) first, then all others.
  /// Aliases are returned as-is; callers unwrap.
  (GirNamespace, Object)? findDeclaration(
    String? name, {
    GirNamespace? relativeTo,
  }) {
    if (name == null || name.isEmpty) return null;
    final current = relativeTo ?? namespace;
    final dot = name.indexOf('.');
    if (dot >= 0) {
      final ns = namespaceNamed(name.substring(0, dot));
      if (ns == null) return null;
      final found = _findIn(ns, name.substring(dot + 1));
      return found == null ? null : (ns, found);
    }
    final inCurrent = _findIn(current, name);
    if (inCurrent != null) return (current, inCurrent);
    for (final ns in allNamespaces) {
      if (ns.name == current.name) continue;
      final found = _findIn(ns, name);
      if (found != null) return (ns, found);
    }
    return null;
  }

  static Object? _findIn(GirNamespace ns, String name) {
    for (final c in ns.classes) {
      if (c.name == name) return c;
    }
    for (final i in ns.interfaces) {
      if (i.name == name) return i;
    }
    for (final r in ns.records) {
      if (r.name == name) return r;
    }
    for (final u in ns.unions) {
      if (u.name == name) return u;
    }
    for (final b in ns.bitfields) {
      if (b.name == name) return b;
    }
    for (final e in ns.enumerations) {
      if (e.name == name) return e;
    }
    for (final cb in ns.callbacks) {
      if (cb.name == name) return cb;
    }
    for (final a in ns.aliases) {
      if (a.name == name) return a;
    }
    return null;
  }

  /// The first namespace in dependency order declaring a type called [name]
  /// with C type [cType] — the canonical owner of duplicated declarations
  /// (e.g. GObject-2.0.gir re-declares GLib's `GIOCondition`).
  GirNamespace? canonicalNamespace(String name, String? cType) {
    for (final ns in allNamespaces) {
      final found = _findIn(ns, name);
      if (found is GirRegisteredType && found.cType == cType) {
        return ns;
      }
    }
    return null;
  }

  /// True when [type] is a duplicate of a declaration in an earlier
  /// namespace (same name and C type) and must not be re-emitted.
  bool isDuplicateType(GirRegisteredType type) {
    final canonical = canonicalNamespace(type.name, type.cType);
    return canonical != null && canonical.name != namespace.name;
  }

  /// Resolves [ref] like [TypeResolver.resolve] but with Dart type names
  /// carrying the C identifier prefix (`Error` → `GError`), aliases
  /// unwrapped to their target declaration, duplicates canonicalized to the
  /// owning namespace, and types in non-generated packages reported as
  /// unsupported.
  TypeMapping resolve(GirTypeRef ref, {GirNamespace? relativeTo}) {
    final m = resolver.resolve(ref, currentNamespace: relativeTo ?? namespace);
    switch (m.kind) {
      case TypeKind.classType:
      case TypeKind.interface:
      case TypeKind.record:
      case TypeKind.union:
      case TypeKind.enumeration:
      case TypeKind.bitfield:
      case TypeKind.callback:
        final found = findDeclaration(ref.name, relativeTo: relativeTo);
        if (found == null) {
          return TypeMapping.unsupported('unknown type: ${ref.name}');
        }
        var (declNs, decl) = found;
        // Unwrap aliases (e.g. Pango.LayoutRun → GlyphItem, Gtk.Allocation
        // → Gdk.Rectangle); an alias to a built-in resolves via the resolver.
        var guard = 0;
        while (decl is GirAlias && guard++ < 10) {
          final target = findDeclaration(decl.target.name, relativeTo: declNs);
          if (target == null) {
            return resolver.resolve(decl.target, currentNamespace: declNs);
          }
          declNs = target.$1;
          decl = target.$2;
        }
        if (decl is! GirRegisteredType) {
          return m;
        }
        final canonical = canonicalNamespace(decl.name, decl.cType);
        if (canonical != null) declNs = canonical;
        final TypeKind kind;
        final String nativeType;
        final bool isPointer;
        switch (decl) {
          case GirClass():
            kind = TypeKind.classType;
            nativeType = 'Pointer<ffi.Void>';
            isPointer = true;
          case GirInterface():
            kind = TypeKind.interface;
            nativeType = 'Pointer<ffi.Void>';
            isPointer = true;
          case GirRecord():
            kind = TypeKind.record;
            nativeType = 'Pointer<ffi.Void>';
            isPointer = true;
          case GirUnion():
            kind = TypeKind.union;
            nativeType = 'Pointer<ffi.Void>';
            isPointer = true;
          case GirBitfield():
            kind = TypeKind.bitfield;
            nativeType = 'ffi.Uint32';
            isPointer = false;
          case GirEnum():
            kind = TypeKind.enumeration;
            nativeType = 'ffi.Int32';
            isPointer = false;
          default:
            return m;
        }
        final sameNs = declNs.name == namespace.name;
        final requiredImport = sameNs ? null : packageNameFor(declNs);
        if (requiredImport != null &&
            !emittedPackages.contains(requiredImport)) {
          return TypeMapping.unsupported(
            'type ${ref.name} is in non-generated package $requiredImport',
          );
        }
        return TypeMapping(
          dartType: dartTypeName(declNs.name, decl.name),
          nativeType: nativeType,
          kind: kind,
          isPointer: isPointer,
          requiredImport: requiredImport,
        );
      default:
        return m;
    }
  }

  /// Builds a [TypeBridge] for [ref]. On failure returns `(null, reason)`.
  /// [relativeTo] overrides the current namespace for type resolution —
  /// used when emitting inherited signals whose arg types belong to an
  /// ancestor namespace (e.g. an Adw class emitting a Gtk signal whose
  /// `Window` arg must resolve against the Gtk namespace).
  (TypeBridge?, String?) bridgeFor(
    GirTypeRef? ref, {
    bool nullable = false,
    GirTransferOwnership transfer = GirTransferOwnership.none,
    bool forReturn = false,
    GirNamespace? relativeTo,
  }) {
    if (ref == null) {
      return (
        TypeBridge(
          wrapperType: 'void',
          nativeType: 'ffi.Void',
          dartFfiType: 'void',
          toNative: _id,
          fromNative: _id,
          isVoid: true,
        ),
        null,
      );
    }
    final m = resolve(ref, relativeTo: relativeTo);
    if (m.requiredImport != null) imports.add(m.requiredImport!);
    switch (m.kind) {
      case TypeKind.voidType:
        return (
          TypeBridge(
            wrapperType: 'void',
            nativeType: 'ffi.Void',
            dartFfiType: 'void',
            toNative: _id,
            fromNative: _id,
            isVoid: true,
          ),
          null,
        );
      case TypeKind.primitive:
        if (nullable && !forReturn) {
          return (null, 'nullable scalar parameter (${ref.name})');
        }
        return (
          TypeBridge(
            wrapperType: m.dartType,
            nativeType: m.nativeType,
            dartFfiType: m.dartType,
            toNative: _id,
            fromNative: _id,
            outPointee: m.nativeType,
            outExtract: (v) => '$v.value',
          ),
          null,
        );
      case TypeKind.boolean:
        if (nullable && !forReturn) {
          return (null, 'nullable scalar parameter (${ref.name})');
        }
        return (
          TypeBridge(
            wrapperType: 'bool',
            nativeType: 'ffi.Int32',
            dartFfiType: 'int',
            toNative: (e) => '$e ? 1 : 0',
            fromNative: (e) => '($e) != 0',
            outPointee: 'ffi.Int32',
            outExtract: (v) => '$v.value != 0',
          ),
          null,
        );
      case TypeKind.string:
        usesFfiString = true;
        usesGirFfi = true;
        final wrapperType = nullable ? 'String?' : 'String';
        String fromNative(String e) {
          final read =
              'stringFromNative(($e).cast(), free: ${transfer == GirTransferOwnership.full})';
          return nullable ? read : '$read!';
        }

        return (
          TypeBridge(
            wrapperType: wrapperType,
            nativeType: 'ffi.Pointer<Utf8>',
            dartFfiType: 'ffi.Pointer<Utf8>',
            toNative: _id, // handled via withNativeString
            fromNative: fromNative,
            isString: true,
            outPointee: 'ffi.Pointer<Utf8>',
            outExtract: (v) => 'stringFromNative($v.value.cast(), free: true)!',
          ),
          null,
        );
      case TypeKind.stringList:
        if (forReturn) {
          return (null, 'string list return type (${ref.name})');
        }
        usesFfiString = true;
        usesGirFfi = true;
        return (
          TypeBridge(
            wrapperType: 'List<String?>?',
            nativeType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
            dartFfiType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
            toNative: _id, // handled via withNativeStringList
            fromNative: (e) => e, // never returned by GLib in the corpus
            isStringList: true,
          ),
          null,
        );
      case TypeKind.pointer:
        // Mirror the `TypeKind.string` null-asymmetry: the wrapper type
        // the user sees carries the `?` (e.g. `progressCallbackData`
        // declared `<parameter … nullable="1" allow-none="1">` in
        // GIR), but the native slot stays non-nullable — `toNative`
        // converts `null` → `ffi.nullptr` so the FFI call site stays
        // valid. `fromNative` is only consulted for return values; for
        // those, a C-side `ffi.nullptr` round-trips into Dart `null`.
        return (
          TypeBridge(
            wrapperType: nullable
                ? 'ffi.Pointer<ffi.Void>?'
                : 'ffi.Pointer<ffi.Void>',
            nativeType: 'ffi.Pointer<ffi.Void>',
            dartFfiType: 'ffi.Pointer<ffi.Void>',
            toNative: nullable ? (e) => '$e ?? ffi.nullptr' : _id,
            fromNative: nullable
                ? (e) => '($e) == ffi.nullptr ? null : ($e)'
                : _id,
            outPointee: 'ffi.Pointer<ffi.Void>',
            outExtract: (v) => '$v.value',
          ),
          null,
        );
      case TypeKind.enumeration:
        if (nullable && !forReturn) {
          return (null, 'nullable scalar parameter (${ref.name})');
        }
        return (
          TypeBridge(
            wrapperType: m.dartType,
            nativeType: 'ffi.Int32',
            dartFfiType: 'int',
            toNative: (e) => '$e.value',
            fromNative: (e) => '${m.dartType}.fromValue($e)',
            outPointee: 'ffi.Int32',
            outExtract: (v) => '${m.dartType}.fromValue($v.value)',
          ),
          null,
        );
      case TypeKind.bitfield:
        if (nullable && !forReturn) {
          return (null, 'nullable scalar parameter (${ref.name})');
        }
        return (
          TypeBridge(
            wrapperType: m.dartType,
            nativeType: 'ffi.Uint32',
            dartFfiType: 'int',
            toNative: (e) => '$e.value',
            fromNative: (e) => '${m.dartType}($e)',
            outPointee: 'ffi.Uint32',
            outExtract: (v) => '${m.dartType}($v.value)',
          ),
          null,
        );
      case TypeKind.classType:
      case TypeKind.interface:
      case TypeKind.record:
      case TypeKind.union:
        final t = m.dartType;
        return (
          TypeBridge(
            wrapperType: nullable ? '$t?' : t,
            nativeType: 'ffi.Pointer<ffi.Void>',
            dartFfiType: 'ffi.Pointer<ffi.Void>',
            toNative: nullable
                ? (e) => '$e?.handle ?? ffi.nullptr'
                : (e) => '$e.handle',
            fromNative: nullable
                ? (e) => '($e) == ffi.nullptr ? null : $t.fromPointer($e)'
                : (e) => '$t.fromPointer($e)',
            // OUT params for record/struct types: the C function writes
            // the entire struct (~32 bytes for GtkTextIter, etc.) into
            // the buffer the wrapper passes. We don't know the size
            // statically, so allocate a fixed-size buffer via
            // `HeapAnchor.allocate` (lifetime tied to the returned
            // wrapper). The buffer is `Pointer<Uint8>`; cast at the
            // call/extract sites.
            outPointee: 'ffi.Void',
            outAllocSize: 256,
            outExtract: nullable
                ? (v) =>
                      '($v) == ffi.nullptr ? null : $t.fromPointer($v.cast<ffi.Void>())'
                : (v) => '$t.fromPointer($v.cast<ffi.Void>())',
          ),
          null,
        );
      case TypeKind.primitiveArray:
      case TypeKind.recordArray:
        // Both array shapes expose a typed `Pointer<T>` on the Dart
        // side. The user `calloc<T>(n)` directly (or in PRIMITIVE
        // cases `calloc<Int32>(n)` and casts at the buffer level),
        // and the wrapper hands the buffer pointer to FFI unchanged —
        // no `.cast<ffi.Void>()` is needed because the native FFI type
        // matches the user's calloc return type.
        // `arrayLengthParameter` flows through so the callable
        // emitter can keep the length slot in sync across multiple
        // arrays that share the same length parameter.
        return (
          TypeBridge(
            wrapperType: m.dartType,
            nativeType: m.nativeType,
            dartFfiType: m.nativeType,
            toNative: _id,
            fromNative: (e) => e,
            arrayLengthParameter: m.arrayLengthParameter,
          ),
          null,
        );
      case TypeKind.callback:
        if (forReturn) {
          // Callbacks are never returned by GLib functions in the current
          // GIR corpus. If that changes, the same bridge applies — the
          // generator already wraps the return via `fromNative`.
          return (null, 'callback return type (${ref.name})');
        }
        return _bridgeForCallback(ref, nullable: nullable);
      case TypeKind.opaque:
      case TypeKind.unsupported:
        return (null, m.reason ?? 'unsupported type (${ref.name})');
    }
  }

  /// Builds the bridge for a callback-typed parameter.
  ///
  /// The wrapper signature uses the inline Dart signature (not the typedef
  /// name) so that the parameter has a concrete type Dart FFI's
  /// `NativeCallable` accepts. The user-facing typedef is still emitted for
  /// documentation and for variable declarations; callers can pass either an
  /// inline-typed function or a typedef-typed value (Dart's structural
  /// typing carries the inline type through).
  ///
  /// When [nullable] is true the bridge emits a conditional `NativeCallable`
  /// allocation: when the user passes a function the wrapper allocates one
  /// and disposes it in a `finally`; when the user passes `null` the native
  /// side receives `ffi.nullptr` and no `NativeCallable` is created.
  (TypeBridge?, String?) _bridgeForCallback(
    GirTypeRef ref, {
    bool nullable = false,
  }) {
    final decl = findDeclaration(ref.name);
    if (decl == null) {
      return (null, 'callback ${ref.name} not found');
    }
    final (declNs, declObj) = decl;
    if (declObj is! GirCallback) {
      return (null, 'callback ${ref.name} not a callback');
    }
    final owningPkg = packageNameFor(declNs);
    if (!emittedPackages.contains(owningPkg)) {
      return (
        null,
        'callback ${ref.name} is in non-generated package $owningPkg',
      );
    }
    // Build the signature against the *declaring* namespace, not the
    // current one — the typedef is being generated there.
    final cbCtx = EmitContext(
      namespace: declNs,
      allNamespaces: allNamespaces,
      report: report,
      emittedPackages: emittedPackages,
    );
    final emitter = CallbackEmitter(cbCtx);
    final sig = emitter.ffiSignature(
      declObj,
      label: '${declNs.name}.${ref.name}',
    );
    if (sig == null) {
      // The signature builder already recorded a skip with a precise reason.
      return (null, 'callback ${ref.name} has unsupported signature');
    }
    final cbName = emitter.dartName(declObj);
    // The user-facing signature uses the inline Dart signature (not the
    // typedef name) so that the parameter has a concrete type Dart FFI's
    // `NativeCallable` accepts. The user-facing typedef is still emitted
    // for documentation and for variable declarations; callers can pass
    // either an inline-typed function or a typedef-typed value (Dart's
    // structural typing carries the inline type through).
    //
    // If the signature builder can't produce the user-facing form
    // (typically because a nested type or callback reference is
    // unsupported, e.g. `GObject.ClosureMarshal` aliases a callback
    // whose declaration lives in GLib but isn't present in any GIR),
    // skip the parameter rather than emitting a broken wrapper whose
    // param type is `void` — that compiles to a parameter type that
    // doesn't match the `NativeCallable<T>` signature, breaking both
    // the FFI lookup and the user call site.
    final userSig = emitter.signature(declObj, label: cbName);
    if (userSig == null) {
      return (null, 'callback ${ref.name} has unsupported signature');
    }
    final retSig = emitter.ffiSignature(
      declObj,
      label: '${declNs.name}.${ref.name} (return)',
    );
    final hasSentinel = _callbackExceptionalReturn(retSig) != null;
    final sentinelArg = hasSentinel
        ? ', exceptionalReturn: ${_callbackExceptionalReturn(retSig)}'
        : '';
    final String Function(String) toNative;
    if (nullable) {
      toNative = (e) =>
          '$e == null ? null : ffi.NativeCallable<$sig>.isolateLocal($e$sentinelArg)';
    } else {
      toNative = (e) => 'ffi.NativeCallable<$sig>.isolateLocal($e$sentinelArg)';
    }
    return (
      TypeBridge(
        wrapperType: nullable ? '$userSig?' : userSig,
        // `_isCallbackBridge` in callable.dart keys off this nativeType to
        // emit the NativeCallable allocation + close() lifecycle.
        nativeType: 'ffi.Pointer<ffi.NativeFunction<$sig>>',
        dartFfiType: 'ffi.Pointer<ffi.NativeFunction<$sig>>',
        toNative: toNative,
        fromNative: (e) => e, // callbacks are never returned by GLib
        isNullableCallback: nullable,
      ),
      null,
    );
  }

  /// Returns the `exceptionalReturn` literal to pass to `Pointer.fromFunction`
  /// when the callback's return type accepts one. Returns null for `void`,
  /// `Handle`, and any `Pointer<...>` return — `Pointer.fromFunction` rejects
  /// a sentinel for those (`invalid_exception_value` lint).
  ///
  /// The signature here is the FFI inline signature (e.g. `ffi.Int32 Function(...)`),
  /// and we inspect the leading return-type token only.
  String? _callbackExceptionalReturn(String? ffiReturnSig) {
    if (ffiReturnSig == null) return '0';
    if (ffiReturnSig == 'void' || ffiReturnSig == 'ffi.Void') return null;
    // Anything starting with Pointer (incl. Pointer<NativeFunction<...>>) is
    // treated as void-like for sentinel purposes.
    final head = ffiReturnSig.split(' ').first;
    if (head == 'Handle' ||
        head.startsWith('ffi.Pointer') ||
        head == 'Pointer') {
      return null;
    }
    if (head.startsWith('ffi.Int') ||
        head.startsWith('ffi.Uint') ||
        head.startsWith('ffi.Size') ||
        head.startsWith('ffi.Long') ||
        head.startsWith('ffi.UnsignedLong') ||
        head.startsWith('ffi.Float') ||
        head.startsWith('ffi.Double')) {
      return '0';
    }
    return null;
  }

  /// GIR doc rendered as dartdoc lines.
  List<String> docLines(String? doc) {
    if (doc == null || doc.trim().isEmpty) return const [];
    return [
      for (final line in doc.trim().split('\n'))
        line.trimRight().isEmpty ? '///' : '/// ${line.trim()}',
    ];
  }

  /// Finds a class by (possibly qualified) GIR name.
  (GirNamespace, GirClass)? findClass(String name) {
    final dot = name.indexOf('.');
    if (dot >= 0) {
      final ns = namespaceNamed(name.substring(0, dot));
      if (ns == null) return null;
      final local = name.substring(dot + 1);
      for (final c in ns.classes) {
        if (c.name == local) return (ns, c);
      }
      return null;
    }
    // Unqualified: current namespace first, then the rest.
    GirClass? inNs(GirNamespace ns) {
      for (final c in ns.classes) {
        if (c.name == name) return c;
      }
      return null;
    }

    final inCurrent = inNs(namespace);
    if (inCurrent != null) return (namespace, inCurrent);
    for (final ns in allNamespaces) {
      if (ns.name == namespace.name) continue;
      final found = inNs(ns);
      if (found != null) return (ns, found);
    }
    return null;
  }

  /// Finds an interface by (possibly qualified) GIR name. Same
  /// resolution rules as [findClass]: qualified (`'Gtk.Actionable'`)
  /// looks up the namespace first; unqualified searches the current
  /// namespace then all others. Returns `null` when no interface by
  /// that name exists in any loaded namespace.
  (GirNamespace, GirInterface)? findInterface(String name) {
    final dot = name.indexOf('.');
    if (dot >= 0) {
      final ns = namespaceNamed(name.substring(0, dot));
      if (ns == null) return null;
      final local = name.substring(dot + 1);
      for (final i in ns.interfaces) {
        if (i.name == local) return (ns, i);
      }
      return null;
    }
    // Unqualified: current namespace first, then the rest.
    GirInterface? inNs(GirNamespace ns) {
      for (final i in ns.interfaces) {
        if (i.name == name) return i;
      }
      return null;
    }

    final inCurrent = inNs(namespace);
    if (inCurrent != null) return (namespace, inCurrent);
    for (final ns in allNamespaces) {
      if (ns.name == namespace.name) continue;
      final found = inNs(ns);
      if (found != null) return (ns, found);
    }
    return null;
  }

  /// Walks the parent chain of [cls]; true when rooted at `GObject.Object`.
  bool isGObjectRooted(GirClass cls) {
    if (namespace.name == 'GObject' && cls.name == 'Object') return true;
    var current = cls;
    final seen = <String>{};
    while (current.parent != null && seen.add(current.name)) {
      final found = findClass(current.parent!);
      if (found == null) return false;
      final (ns, parent) = found;
      if (ns.name == 'GObject' && parent.name == 'Object') return true;
      current = parent;
    }
    return false;
  }

  /// True when [cls] or any ancestor is `InitiallyUnowned`.
  bool sinksFloatingRefs(GirClass cls) {
    var current = cls;
    final seen = <String>{};
    while (seen.add(current.name)) {
      if (current.name == 'InitiallyUnowned') return true;
      final parentName = current.parent;
      if (parentName == null) return false;
      final found = findClass(parentName);
      if (found == null) return false;
      current = found.$2;
    }
    return false;
  }
}

String _id(String e) => e;
