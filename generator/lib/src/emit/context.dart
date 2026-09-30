/// Shared emission context: type bridging, name registry, import tracking.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart';
import 'callback_emitter.dart';
import 'report.dart';

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
    this.outPointee,
    this.outExtract,
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

  /// Pointee type to `malloc` for an out parameter, null when the type
  /// cannot appear as an out parameter.
  final String? outPointee;

  /// Reads the out value from the allocated pointer variable.
  final String Function(String varName)? outExtract;
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
        return (
          TypeBridge(
            wrapperType: 'ffi.Pointer<ffi.Void>',
            nativeType: 'ffi.Pointer<ffi.Void>',
            dartFfiType: 'ffi.Pointer<ffi.Void>',
            toNative: _id,
            fromNative: _id,
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
        if (nullable) {
          // Nullable callback parameters need lifetime handling for the
          // wrapping NativeCallable. None of the GIR files currently in
          // scope declare a nullable callback parameter; revisit when a
          // real case appears.
          return (null, 'nullable callback parameter (${ref.name})');
        }
        return _bridgeForCallback(ref);
      case TypeKind.opaque:
      case TypeKind.unsupported:
        return (null, m.reason ?? 'unsupported type (${ref.name})');
    }
  }

  /// Builds the bridge for a non-nullable callback-typed parameter.
  ///
  /// The wrapper signature uses the inline Dart signature (not the typedef
  /// name) so that the parameter has a concrete type Dart FFI's
  /// `NativeCallable` accepts. The user-facing typedef is still emitted for
  /// documentation and for variable declarations; callers can pass either an
  /// inline-typed function or a typedef-typed value (Dart's structural
  /// typing carries the inline type through).
  (TypeBridge?, String?) _bridgeForCallback(GirTypeRef ref) {
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
    // `Pointer.fromFunction<T>` requires a static/top-level function and
    // throws at runtime when called via a wrapper whose parameter is a
    // function value (even if the caller's literal is static — the runtime
    // can't prove it). `NativeCallable.isolateLocal<T>(fn, ...)` accepts
    // any Dart function (including ones flowing through wrapper params),
    // so the generator wraps the user-supplied function with it.
    //
    // The `toNative` expression below returns the `NativeCallable` instance
    // (not the underlying pointer). The wrapper body holds the instance in
    // a local, passes `.nativeFunction` to the native call, and disposes
    // via `.close()` in a finally block — see [CallableEmitter].
    //
    // The user-facing typedef (`GCompareFunc`) is still emitted for
    // documentation and for typed variable declarations; the generated
    // wrapper parameter uses the inline signature so that callers can pass
    // either an inline-typed function or a typedef-typed variable.
    final userSig = emitter.signature(declObj, label: cbName) ?? 'void';
    final retSig = emitter.ffiSignature(
      declObj,
      label: '${declNs.name}.${ref.name} (return)',
    );
    final hasSentinel = _callbackExceptionalReturn(retSig) != null;
    final String Function(String) toNative;
    toNative = (e) => hasSentinel
        ? 'ffi.NativeCallable<$sig>.isolateLocal($e, '
              'exceptionalReturn: ${_callbackExceptionalReturn(retSig)})'
        : 'ffi.NativeCallable<$sig>.isolateLocal($e)';
    return (
      TypeBridge(
        wrapperType: userSig,
        // `_isCallbackBridge` in callable.dart keys off this nativeType to
        // emit the NativeCallable allocation + close() lifecycle.
        nativeType: 'ffi.Pointer<ffi.NativeFunction<$sig>>',
        dartFfiType: 'ffi.Pointer<ffi.NativeFunction<$sig>>',
        toNative: toNative,
        fromNative: (e) => e, // callbacks are never returned by GLib
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
