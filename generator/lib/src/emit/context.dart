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
    this.isCountedString = false,
    this.isVoid = false,
    this.isNullableCallback = false,
    this.outPointee,
    this.outAllocSize,
    this.outExtract,
    this.arrayLengthParameter,
    this.structArgType,
    this.outIsStruct = false,
    this.outByteBufferLengthIndex,
    this.outExtractBytes,
    this.evaluatesArgTwice = false,
    this.isByteArrayIn = false,
    this.byteArrayLengthIndex,
    this.byteArrayOwnedByCallee = false,
    this.isNullableScalarPointer = false,
    this.isInoutScalar = false,
    this.isOutArray = false,
    this.outArrayElementType,
    this.outArrayElementNativeType,
    this.outArrayElementIsHandle = false,
    this.outArrayElementOwned = false,
    this.outArrayFixedCount,
    this.outArrayCountIndex,
    this.outArrayCountIsInput = false,
    this.outArrayCallerAllocated = false,
    this.outIsNulTerminatedString = false,
    this.callbackParams,
    this.callbackFfiSignature,
    this.outExtractArray,
    this.ownershipFinalizer,
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

  /// A single string whose **byte** length a sibling parameter carries.
  ///
  /// The string is marshalled via `withNativeStringBytes`, which reports
  /// the byte length; the sibling parameter is absorbed and the count the
  /// C side reads is the length of the string the caller passed.
  final bool isCountedString;

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

  /// Set when the argument is an `ffi.Struct` the caller passes by
  /// value but the C API takes by pointer. The emitter allocates a
  /// native copy for the call and frees it afterwards; this holds the
  /// struct's Dart type name.
  final String? structArgType;

  /// Set when the out parameter is an `ffi.Struct`: the buffer holds
  /// the struct itself, and the value is read back by value.
  final bool outIsStruct;

  /// For a callee-allocated byte buffer, the 0-based index of the
  /// sibling OUT parameter that carries the byte count.
  ///
  /// The GIR binds the two together with `<array length="N">`, where `N`
  /// is that index. The emitter resolves it to the sibling's local
  /// variable and hands it to [outExtractBytes]; the count itself is
  /// not a separate element of the returned record — the buffer already
  /// carries its length.
  final int? outByteBufferLengthIndex;

  /// Reads a callee-allocated byte buffer. [bufferVar] is the local
  /// holding the pointer slot the callee filled, [lengthVar] the local
  /// holding the byte count.
  ///
  /// The generated code copies the bytes into a Dart [Uint8List] and
  /// releases the native buffer — the garbage collector cannot see
  /// native memory.
  final String Function(String bufferVar, String lengthVar)? outExtractBytes;

  /// `true` when [fromNative] mentions its argument twice, so the
  /// argument must be bound to a local before it is converted.
  ///
  /// A nullable pointer return converts as
  /// `($expr) == ffi.nullptr ? null : $expr`; inlining a call there
  /// would call the native function twice.
  final bool evaluatesArgTwice;

  /// `true` when the argument is a **caller-provided byte array**: the
  /// caller owns the buffer, hands it to the callee, and a sibling
  /// parameter carries the byte count.
  ///
  /// The wrapper takes a Dart `Uint8List`, mirrors it into a
  /// GLib-allocated native buffer for the call (`withNativeBytes`), and
  /// the byte count is the list's length — so the length parameter
  /// disappears from the Dart signature while staying in the native one.
  ///
  /// This is the shape of `g_bytes_new`'s `data` and of
  /// `g_file_replace_contents`' `contents`.
  final bool isByteArrayIn;

  /// `true` when a nullable scalar is passed to the callee **by
  /// pointer**.
  ///
  /// FFI cannot express `int?` over a primitive slot, and the C API
  /// takes a `gint *` that may be NULL. The wrapper therefore allocates
  /// a one-slot buffer, writes the caller's value into it (or passes
  /// NULL when the caller passed none), and reads the slot back after
  /// the call: the value the callee wrote becomes the wrapper's return
  /// value, next to the function's own.
  final bool isNullableScalarPointer;

  /// `true` when an **inout** scalar or enum is passed to the callee by
  /// pointer.
  ///
  /// The C function reads the value through the pointer and may write
  /// through it — `gtk_editable_insert_text`'s `position`,
  /// `pango_matrix_transform_point`'s `x` and `y`. The wrapper
  /// allocates the slot, seeds it with the caller's value, and reads the
  /// updated value back after the call; the read-back rides the OUT
  /// machinery and becomes part of the wrapper's return value.
  ///
  /// The GIR's ownership annotation for an inout parameter is ignored:
  /// it is demonstrably wrong (`gtk_source_buffer_forward_iter_to_source_mark`'s
  /// `iter` is marked `transfer-ownership="full"`, but GTK does not take
  /// ownership of the iterator). The caller keeps the storage.
  final bool isInoutScalar;

  /// For a caller-provided byte array, the 0-based index of the sibling
  /// parameter that carries the byte count.
  ///
  /// The GIR binds the two together with `<array length="N">`, where `N`
  /// is that index. The emitter absorbs the sibling: it stays in the
  /// native call and is fed from the list's length.
  final int? byteArrayLengthIndex;

  /// `true` when the callee takes ownership of the buffer
  /// (`transfer-ownership="full"`).
  ///
  /// The buffer is then allocated with `g_malloc` and handed over: the
  /// callee releases it with `g_free`, so the wrapper must not free it
  /// and must not copy the bytes back out of it.
  final bool byteArrayOwnedByCallee;

  /// The `NativeFinalizer` that releases a reference this wrapper owns,
  /// e.g. `gobjectFinalizer` or `GBytes.bytesFinalizer`.
  ///
  /// `null` when the wrapper cannot release the reference on its own —
  /// a borrowed reference, a type without a destructor in the GIR, or a
  /// type whose destructor must not run from a finalizer thread.
  ///
  /// The emitter uses it at a `transfer-ownership="full"` *parameter*:
  /// the callee takes the reference over, so the Dart side has to give
  /// up its claim instead of releasing it twice.
  final String? ownershipFinalizer;

  /// `true` when the parameter is an **OUT array** the wrapper reads back
  /// into a Dart list.
  ///
  /// Two shapes, told apart by `caller-allocates`:
  ///
  /// * **The callee allocates** (`caller-allocates="0"`): the C function
  ///   allocates the array and writes its address into the caller's slot;
  ///   a sibling OUT parameter carries the element count. The wrapper
  ///   passes a slot, reads the array and the count back, copies the
  ///   elements into a Dart list and releases the array with `g_free`.
  /// * **The caller allocates** (`caller-allocates="1"`): the array has a
  ///   fixed size (`fixed-size="4"`), so the wrapper allocates the buffer
  ///   itself, passes it and copies the elements out after the call.
  final bool isOutArray;

  /// The Dart type of one element of an OUT array — `int`, `double`, or
  /// the wrapper class of a handle.
  final String? outArrayElementType;

  /// The FFI type of one element of an OUT array — `ffi.Int32`,
  /// `ffi.Double`, `ffi.Pointer<ffi.Void>`.
  final String? outArrayElementNativeType;

  /// `true` when the element of an OUT array is a *handle* — an object or
  /// a record the wrapper wraps rather than copies.
  final bool outArrayElementIsHandle;

  /// `true` when the elements of an OUT array are owned by the caller.
  ///
  /// `transfer-ownership="full"` on a pointer element means the callee
  /// hands every element over as well (`g_socket_receive_message`'s
  /// control messages); `container` and `none` hand over the array alone.
  final bool outArrayElementOwned;

  /// The number of elements of a caller-allocated OUT array, when the GIR
  /// states it (`fixed-size="4"`).
  ///
  /// A callee-allocated array has no fixed size — its count comes from a
  /// sibling OUT parameter ([outArrayCountIndex]).
  final int? outArrayFixedCount;

  /// The 0-based index of the sibling OUT parameter that carries the
  /// element count of a callee-allocated OUT array.
  final int? outArrayCountIndex;

  /// `true` when the element count of an OUT array comes from an **in**
  /// parameter — the capacity the caller passes for a caller-allocated
  /// array — rather than from an out slot the callee fills.
  final bool outArrayCountIsInput;

  /// `true` when the **caller** allocates the array's buffer.
  ///
  /// The wrapper then allocates the buffer itself, passes it and copies
  /// the elements out after the call. When the callee allocates the
  /// array, the wrapper passes a slot and the callee writes the array
  /// pointer into it.
  final bool outArrayCallerAllocated;

  /// The user-facing parameter list of a callback-typed parameter: the
  /// type and the name of each parameter.
  ///
  /// A destroy-notify trampoline is built over the callback's *own*
  /// signature — `GdkPixbufDestroyNotify` takes the pixel buffer and the
  /// data, `GDestroyNotify` only the data — so the trampoline needs the
  /// parameter list, not just the signature.
  final List<({String type, String ffiType, String name})>? callbackParams;

  /// The **FFI** signature of a callback-typed parameter — the type the
  /// C function pointer has to carry.
  ///
  /// It differs from the user-facing signature in the return type
  /// (`ffi.Void` against `void`) and in the boolean parameters
  /// (`ffi.Bool` against the `int` the convention uses).
  final String? callbackFfiSignature;

  /// `true` when the parameter holds a **NUL-terminated** buffer the
  /// callee allocates — `g_spawn_sync`'s `standard_output`.
  ///
  /// The wrapper copies the text into a Dart `String` and releases the
  /// native buffer with GLib's allocator.
  final bool outIsNulTerminatedString;

  /// `true` when the OUT slot is allocated with `calloc` rather than
  /// `malloc`.
  ///
  /// A pointer-sized slot is zeroed: the C function is allowed to leave
  /// the out parameter untouched, and an uninitialized pointer would be
  /// a wild read.
  bool get outSlotIsCalloc =>
      outPointee == 'ffi.Pointer<ffi.Void>' ||
      outExtractBytes != null ||
      outIsNulTerminatedString;

  /// Reads an OUT array into a Dart list.
  ///
  /// [arrayVar] is the local holding the array pointer, [countExpr] the
  /// expression that yields the element count.
  final String Function(String arrayVar, String countExpr)? outExtractArray;
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

  /// Reports the virtual methods of a class or an interface.
  ///
  /// A virtual method is a slot in the class's C vtable, not a symbol the
  /// caller can invoke: overriding one needs the *layout* of the class
  /// struct, and the GIR does not carry it — it lists a class's virtual
  /// methods alphabetically, while the C struct declares them in
  /// declaration order. The methods are therefore not emitted.
  ///
  /// They are still reported, because the project's rule is that a symbol
  /// never disappears silently: an omission that surfaces as a mystery at
  /// the call site is worse than one the report names.
  void reportVirtualMethods(List<GirMethod> virtualMethods, String dartName) {
    for (final v in virtualMethods) {
      report.skip(
        'virtual',
        '$dartName.${v.name}',
        'virtual method; the class struct layout is not in the GIR',
      );
    }
  }

  /// Namespaces loaded before [namespace] in dependency order.
  List<GirNamespace> get priorNamespaces {
    final idx = allNamespaces.indexOf(namespace);
    return idx <= 0 ? const [] : allNamespaces.sublist(0, idx);
  }

  /// Names the generated library itself occupies: runtime helpers from
  /// `package:ffi`/`gir_ffi` and emitted support declarations. GIR symbols
  /// mapping to these (e.g. `g_malloc` → `malloc`) get a `Fn` suffix.
  ///
  /// The `gir_ffi` names are here because the loader calls
  /// `openLibrary` and builds an `InstallPackages` — the whole
  /// `package:gir_ffi/gir_ffi.dart` namespace is in scope in every
  /// generated package, so a GIR symbol mapping onto one of these names
  /// would collide with it.
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
    'withNativeStringList',
    'withNativeBytes',
    'bytesFromNative',
    'gFree',
    'gMalloc',
    'castTo',
    'HeapAnchor',
    'keepAlive',
    'cachedObject',
    'cachedObjectCount',
    'registerDartObject',
    'openLibrary',
    'namesForCurrentPlatform',
    'InstallPackages',
    'NativeLibraryNotFound',
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

  /// The declaration that claimed each top-level name.
  ///
  /// Recorded alongside [topLevelNames] so that a name collision can
  /// name the sibling that already holds the name. "duplicate
  /// constant: Gdk.KEY_Armenian_at and Gdk.KEY_armenian_at both map
  /// to keyArmenianAt" says what happened and what to do about it;
  /// "name collision: keyArmenianAt" says only that something went
  /// wrong.
  ///
  /// The names seeded into [topLevelNames] without a declaration —
  /// the reserved words and the package's own helpers — have no
  /// owner.
  final Map<String, NameOwner> topLevelNameOwners = {};

  bool usesFfiString = false; // package:ffi Utf8
  bool usesMalloc = false;
  bool usesGirFfi = false; // stringFromNative / withNativeString
  bool usesGlibException = false;

  /// `dart:typed_data` — needed by the `Uint8List` a callee-allocated
  /// byte buffer is copied into.
  bool usesTypedData = false;

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
  ///
  /// [kind] is the kind of declaration claiming the name (`constant`,
  /// `class`, `enum`, …) and [label] the namespace-qualified GIR
  /// symbol it came from. Both are recorded so that a later collision
  /// can name the sibling that already holds the name.
  bool claimName(String name, {String? kind, String? label}) {
    if (!topLevelNames.add(name)) return false;
    if (kind != null || label != null) {
      topLevelNameOwners[name] = NameOwner(
        kind ?? label ?? 'declaration',
        label ?? name,
      );
    }
    return true;
  }

  /// The declaration that already claimed [name], or null when the
  /// name was taken by a reserved word or a package helper and so has
  /// no GIR owner.
  NameOwner? ownerOf(String name) => topLevelNameOwners[name];

  /// The generated package name for the current namespace.
  String get pkg => packageNameFor(namespace);

  /// lowerCamel package identifier used for helper names
  /// (`gdkPixbufLibs`, `gdkPixbufLookup`).
  String get pkgIdent => toLowerCamel(pkg);

  /// The `static int get GType` accessor for a class or interface whose
  /// GIR declaration carries `glib:get-type`.
  ///
  /// The accessor calls the type's own `get_type` function — the one
  /// GLib exports for every registered type — so user code can name a
  /// native type without string lookups:
  ///
  /// ```dart
  /// GListStore(TaskObject.GType)
  /// ```
  ///
  /// Returns `null` when the declaration has no get-type function, in
  /// which case no accessor is emitted.
  String? gTypeAccessor(String? getTypeCId, {String what = 'class'}) {
    if (getTypeCId == null || getTypeCId.isEmpty) return null;
    return '''
  /// The native `GType` of this $what.
  static int get GType => _gType;

  /// The cached native `GType` of this $what.
  ///
  /// The `get_type` function GLib exports for every registered type is
  /// looked up once and the result is kept.
  static final int _gType =
      ${pkgIdent}Lookup<ffi.NativeFunction<ffi.Size Function()>>('$getTypeCId')
          .asFunction<int Function()>()();''';
  }

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

  /// The bridge for an **inout** scalar or enum.
  ///
  /// The C function takes a pointer to the value and may write through
  /// it. The wrapper allocates the slot, seeds it with the caller's
  /// value, passes the slot and reads the updated value back after the
  /// call.
  ///
  /// The seed expression and the read-back expression are the ordinary
  /// scalar conversions: a `gdouble` is seeded with the caller's `double`
  /// and read back as one, an enum is seeded with `.value` and read back
  /// through `fromValue`.
  TypeBridge _inoutScalarBridge(TypeMapping m) {
    final String nativeType;
    final String Function(String) seed;
    final String Function(String) read;
    switch (m.kind) {
      case TypeKind.primitive:
        nativeType = m.nativeType;
        seed = _id;
        read = (v) => '$v.value';
      case TypeKind.boolean:
        nativeType = 'ffi.Int32';
        seed = (e) => '$e ? 1 : 0';
        read = (v) => '$v.value != 0';
      case TypeKind.enumeration:
        nativeType = 'ffi.Int32';
        seed = (e) => '$e.value';
        read = (v) => '${m.dartType}.fromValue($v.value)';
      case TypeKind.bitfield:
        nativeType = 'ffi.Uint32';
        seed = (e) => '$e.value';
        read = (v) => '${m.dartType}($v.value)';
      default:
        throw StateError('not a scalar: ${m.kind}');
    }
    return TypeBridge(
      wrapperType: m.dartType,
      // The C parameter is a pointer to the value.
      nativeType: 'ffi.Pointer<$nativeType>',
      dartFfiType: 'ffi.Pointer<$nativeType>',
      toNative: seed,
      fromNative: _id,
      outPointee: nativeType,
      outExtract: read,
      isInoutScalar: true,
    );
  }

  /// The bridge for an OUT parameter whose value is a wrapper of type
  /// [dartType].
  ///
  /// The C type of the parameter decides the shape of the out slot:
  ///
  /// * `GtkTextIter*` — one star. The C function writes the *struct*
  ///   into the buffer the caller passes, so the buffer **is** the
  ///   value and the wrapper points into it. The wrapper has to keep
  ///   the buffer alive — `keepAlive` (in `package:gir_ffi`) ties the
  ///   buffer's anchor to the wrapper. Without it the anchor is
  ///   unreachable the moment the call returns, the collector frees the
  ///   buffer, and the wrapper reads freed memory.
  /// * `GUnixFDList**` — two stars. The C function writes a *pointer*
  ///   into the slot, so the value is the object that pointer refers
  ///   to. The slot is a pointer-sized cell the generator frees as soon
  ///   as the call returns.
  TypeBridge outWrapperBridge(
    String dartType,
    String? cType, {
    required bool nullable,
    required GirTransferOwnership transfer,
    String? ownershipFinalizer,
    bool floatingReference = false,
  }) {
    // `transfer="full"` hands the reference to the caller, so the
    // wrapper owns it and releases it when it is collected.
    //
    // A type that uses *floating* references is the exception: the GIR
    // marks such a return `transfer="none"` because the reference
    // belongs to nobody — the value is floating, or somebody else owns
    // it. The type's copy function is what turns it into a reference
    // the caller owns, so the wrapper takes that reference and owns it.
    final copies = floatingReference && transfer != GirTransferOwnership.full;
    final ownedArg = transfer == GirTransferOwnership.full
        ? ', owned: true'
        : '';
    String wrap(String e) => copies
        ? '$dartType.copyReference($e)'
        : '$dartType.fromPointer($e$ownedArg)';
    String wrapNullable(String e) => '($e) == ffi.nullptr ? null : ${wrap(e)}';
    if (_pointerDepth(cType) >= 2) {
      return TypeBridge(
        wrapperType: nullable ? '$dartType?' : dartType,
        nativeType: 'ffi.Pointer<ffi.Void>',
        dartFfiType: 'ffi.Pointer<ffi.Void>',
        toNative: nullable
            ? (e) => '$e?.handle ?? ffi.nullptr'
            : (e) => '$e.handle',
        fromNative: nullable ? wrapNullable : wrap,
        evaluatesArgTwice: nullable,
        outPointee: 'ffi.Pointer<ffi.Void>',
        outExtract: nullable
            ? (v) => wrapNullable('$v.value.cast<ffi.Void>()')
            : (v) => wrap('$v.value.cast<ffi.Void>()'),
        ownershipFinalizer: ownershipFinalizer,
      );
    }
    return TypeBridge(
      wrapperType: nullable ? '$dartType?' : dartType,
      nativeType: 'ffi.Pointer<ffi.Void>',
      dartFfiType: 'ffi.Pointer<ffi.Void>',
      toNative: nullable
          ? (e) => '$e?.handle ?? ffi.nullptr'
          : (e) => '$e.handle',
      fromNative: nullable ? wrapNullable : wrap,
      evaluatesArgTwice: nullable,
      // The C function writes the whole struct (~24 bytes for
      // GtkTextIter, ~72 for GtkTreeIter) into the buffer the wrapper
      // passes. The size is not known statically, so the generator
      // allocates a fixed-size buffer via `HeapAnchor.allocate`; the
      // buffer is `Pointer<Uint8>` and is cast at the call and extract
      // sites. The wrapper keeps the anchor alive through `keepAlive`.
      outPointee: 'ffi.Void',
      outAllocSize: 256,
      outExtract: nullable
          ? (v) =>
                '($v) == ffi.nullptr ? null : '
                'keepAlive(${wrap('$v.cast<ffi.Void>()')}, '
                '${v}Anchor)'
          : (v) =>
                'keepAlive(${wrap('$v.cast<ffi.Void>()')}, '
                '${v}Anchor)',
      ownershipFinalizer: ownershipFinalizer,
    );
  }

  /// Whether [ref] names a type that uses *floating* references.
  ///
  /// Such a type hands over a reference nobody owns; the type's copy
  /// function is what turns it into one the caller owns.
  bool _isFloatingReference(GirTypeRef ref, GirNamespace? relativeTo) {
    final decl = findDeclaration(ref.name, relativeTo: relativeTo)?.$2;
    if (decl is! GirRegisteredType) return false;
    return TypeResolver.floatingReferenceCopyFunction(decl) != null;
  }

  /// The number of trailing `*` in [cType] — its pointer depth.
  ///
  /// `GtkTextIter*` has depth 1, `GUnixFDList**` has depth 2. A null
  /// [cType] means the type carries no pointer of its own, which the
  /// out-parameter shape treats as depth 1.
  static int _pointerDepth(String? cType) {
    if (cType == null) return 1;
    var depth = 0;
    for (var i = cType.length - 1; i >= 0 && cType[i] == '*'; i--) {
      depth++;
    }
    return depth;
  }

  /// Builds a [TypeBridge] for [ref]. On failure returns `(null, reason)`.
  /// [relativeTo] overrides the current namespace for type resolution —
  /// used when emitting inherited signals whose arg types belong to an
  /// ancestor namespace (e.g. an Adw class emitting a Gtk signal whose
  /// `Window` arg must resolve against the Gtk namespace).
  ///
  /// [callerAllocates] mirrors the GIR's `caller-allocates` attribute: it
  /// is `false` only for a parameter whose buffer the *callee* allocates
  /// (`g_file_load_contents`' `contents`).
  ///
  /// [byteArrayIn] marks the parameter as a caller-provided byte array
  /// (the caller owns the buffer, a sibling carries the byte count). The
  /// caller decides — the rule lives in [TypeResolver.isByteArrayIn],
  /// because it needs the callable's parameter list.
  /// The bridge for a nullable scalar the caller passes **by pointer**.
  ///
  /// The C API takes a `gint *` that may be NULL, and FFI cannot
  /// express `int?` over a primitive slot. The wrapper therefore
  /// allocates a one-slot buffer, writes the caller's value into it —
  /// or passes NULL when the caller passed none — and reads the slot
  /// back after the call: the value the callee wrote becomes the
  /// wrapper's return value, next to the function's own.
  (TypeBridge?, String?) _nullableScalarBridge(
    TypeMapping m, {
    String? dartType,
    String? nativeType,
    String Function(String)? toNative,
    String Function(String)? outExtract,
  }) {
    final dart = dartType ?? m.dartType;
    final native = nativeType ?? m.nativeType;
    return (
      TypeBridge(
        wrapperType: '$dart?',
        nativeType: 'ffi.Pointer<$native>',
        dartFfiType: 'ffi.Pointer<$native>',
        toNative: toNative ?? _id,
        fromNative: _id,
        outPointee: native,
        // The slot is NULL when the caller passed no value — the
        // callee then wrote nothing, so the read-back is null too.
        outExtract: outExtract == null
            ? (v) => '$v == ffi.nullptr ? null : $v.value'
            : (v) => '$v == ffi.nullptr ? null : ${outExtract(v)}',
        isNullableScalarPointer: true,
      ),
      null,
    );
  }

  /// The bridge for an **OUT array** parameter.
  ///
  /// The array is read back into a Dart list: a `List<int>` for a scalar
  /// element, a `List<T>` for a handle element.
  ///
  /// The elements can only be read out when the generator knows what they
  /// are. A scalar is known; a handle — a pointer to an object or a
  /// record — is wrapped rather than copied. A *struct* the generator
  /// does not emit as an `ffi.Struct` cannot be read out of a native
  /// array at all: its layout is unknown, so the parameter stays skipped
  /// with a reason that names the struct.
  ///
  /// The count comes with the array:
  ///
  /// * a **callee-allocated** array (`caller-allocates="0"`) is counted
  ///   by a sibling OUT parameter — the GIR's `<array length="N">`;
  /// * a **caller-allocated** array (`caller-allocates="1"`) has a fixed
  ///   size (`fixed-size="4"`), so the wrapper allocates the buffer
  ///   itself.
  (TypeBridge?, String?) _outArrayBridge(
    GirTypeRef ref, {
    required GirTransferOwnership transfer,
    required bool callerAllocates,
    List<GirParameter>? siblings,
  }) {
    final shape = TypeResolver.arrayElementShape(
      ref,
      callerAllocates: callerAllocates,
    );
    if (shape == null) {
      return (null, 'the array element carries no C type');
    }
    final array = ref.array!;
    final elemMap = resolve(array.elementType);
    if (elemMap.requiredImport != null) imports.add(elemMap.requiredImport!);

    // The count.
    //
    // * A **callee-allocated** array is counted by a sibling *out*
    //   parameter — the GIR's `<array length="N">`.
    // * A **caller-allocated** array is sized either by a fixed size
    //   (`fixed-size="4"`) or by a sibling *in* parameter — the capacity
    //   the caller passes.
    int? countIndex;
    int? fixedCount;
    var countIsInput = false;
    if (callerAllocates) {
      fixedCount = array.fixedSize;
      if (fixedCount == null) {
        final idx = array.lengthParameterIndex;
        if (idx == null || siblings == null || idx >= siblings.length) {
          return (null, 'the array carries no element count');
        }
        if (siblings[idx].direction != GirParameterDirection.in_) {
          return (null, 'the element count is not an in parameter');
        }
        countIndex = idx;
        countIsInput = true;
      }
    } else {
      final idx = array.lengthParameterIndex;
      if (idx == null || siblings == null || idx >= siblings.length) {
        return (null, 'the array carries no element count');
      }
      if (siblings[idx].direction != GirParameterDirection.out) {
        return (null, 'the element count is not an out parameter');
      }
      countIndex = idx;
    }

    // The element: a scalar the wrapper copies, or a handle it wraps.
    final isHandle = shape.isHandle;
    late final String elementDartType;
    late final String elementNativeType;
    late final String Function(String) readElement;
    if (isHandle) {
      switch (elemMap.kind) {
        case TypeKind.classType:
        case TypeKind.interface:
        case TypeKind.record:
          elementDartType = elemMap.dartType;
          elementNativeType = 'ffi.Pointer<ffi.Void>';
          // `transfer-ownership="full"` on a pointer element hands every
          // element over as well (`g_socket_receive_message`'s control
          // messages); `container` and `none` hand over the array alone —
          // the elements belong to whoever created them. A record has no
          // reference of its own to hand over.
          final owned =
              transfer == GirTransferOwnership.full &&
              elemMap.kind != TypeKind.record;
          readElement = (expr) => owned
              ? '$elementDartType.fromPointer($expr, owned: true)'
              : '$elementDartType.fromPointer($expr)';
        default:
          return (
            null,
            elemMap.kind == TypeKind.unsupported
                ? 'array of ${shape.name}: ${elemMap.reason}'
                : 'array of ${shape.name}: the element is not a handle',
          );
      }
    } else {
      switch (elemMap.kind) {
        case TypeKind.primitive:
          elementDartType = elemMap.dartType;
          elementNativeType = elemMap.nativeType;
          readElement = (expr) => expr;
        case TypeKind.boolean:
          elementDartType = elemMap.dartType;
          elementNativeType = elemMap.nativeType;
          readElement = (expr) => '$expr != 0';
        case TypeKind.enumeration:
          elementDartType = elemMap.dartType;
          elementNativeType = elemMap.nativeType;
          readElement = (expr) => '$elementDartType.fromValue($expr)';
        case TypeKind.bitfield:
          elementDartType = elemMap.dartType;
          elementNativeType = elemMap.nativeType;
          readElement = (expr) => '$elementDartType($expr)';
        default:
          return (
            null,
            elemMap.kind == TypeKind.unsupported
                ? 'array of ${shape.name}: ${elemMap.reason}'
                : 'array of ${shape.name}: the layout of the element is not '
                      'emitted, so the elements cannot be read out of the array',
          );
      }
    }

    // The array pointer: `T *` for a scalar element, `T **` for a handle.
    final arrayPointerType = isHandle
        ? 'ffi.Pointer<ffi.Pointer<ffi.Void>>'
        : 'ffi.Pointer<$elementNativeType>';
    // The C parameter: the callee-allocated shape takes a slot
    // (`T **`), the caller-allocated shape takes the buffer (`T *`).
    final nativeType = callerAllocates
        ? arrayPointerType
        : 'ffi.Pointer<$arrayPointerType>';

    final read = readElement;
    return (
      TypeBridge(
        wrapperType: 'List<$elementDartType>',
        nativeType: nativeType,
        dartFfiType: nativeType,
        toNative: _id,
        fromNative: _id,
        isOutArray: true,
        outArrayElementType: elementDartType,
        outArrayElementNativeType: isHandle
            ? 'ffi.Pointer<ffi.Void>'
            : elementNativeType,
        outArrayElementIsHandle: isHandle,
        outArrayElementOwned:
            isHandle &&
            transfer == GirTransferOwnership.full &&
            elemMap.kind != TypeKind.record,
        outArrayFixedCount: fixedCount,
        outArrayCountIndex: countIndex,
        outArrayCountIsInput: countIsInput,
        outArrayCallerAllocated: callerAllocates,
        outExtractArray: (arrayVar, countExpr) =>
            '<$elementDartType>[for (var i = 0; i < $countExpr; i++) '
            '${read('$arrayVar[i]')}]',
      ),
      null,
    );
  }

  (TypeBridge?, String?) bridgeFor(
    GirTypeRef? ref, {
    bool nullable = false,
    GirTransferOwnership transfer = GirTransferOwnership.none,
    bool forReturn = false,
    GirParameterDirection direction = GirParameterDirection.in_,
    bool callerAllocates = true,
    bool byteArrayIn = false,
    GirNamespace? relativeTo,

    /// The expression that yields the element count of a `char **` return
    /// — the OUT slot the callee filled. `null` when the array carries no
    /// count, and the wrapper reads it until its NULL terminator.
    String? stringListCountExpr,

    /// The callable's parameter list, for the shapes whose behaviour
    /// depends on a sibling parameter — the element count of an OUT
    /// array, for instance.
    List<GirParameter>? siblings,
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

    // The **caller-allocated rule** for inout parameters.
    //
    // The GIR's ownership annotations for an inout parameter are
    // demonstrably wrong — `gtk_source_buffer_forward_iter_to_source_mark`'s
    // `iter` is marked `transfer-ownership="full"`, but GTK does not take
    // ownership of the iterator — so the annotation is ignored and the
    // caller keeps the storage.
    //
    // Two shapes:
    //
    // * a **scalar or enum** the callee reads and writes through the
    //   pointer. The wrapper allocates the slot, seeds it with the
    //   caller's value and reads the updated value back after the call.
    // * a **handle** — a class, a record, an interface. The caller
    //   passes the object and the callee writes through the pointer in
    //   place. The Dart object *is* the memory, so the caller sees the
    //   change.
    //
    // A pointer to a *pointer* stays skipped: the callee allocates the
    // pointee there, and a wrapper would have to release memory it did
    // not allocate.
    if (direction == GirParameterDirection.inout && !forReturn) {
      switch (m.kind) {
        case TypeKind.primitive:
        case TypeKind.boolean:
        case TypeKind.enumeration:
        case TypeKind.bitfield:
          return (_inoutScalarBridge(m), null);
        case TypeKind.classType:
        case TypeKind.interface:
        case TypeKind.record:
        case TypeKind.union:
          // A handle: the ordinary bridge does the job — only the
          // ownership annotation is ignored.
          break;
        case TypeKind.primitiveArray:
        case TypeKind.recordArray:
          // An inout *buffer*: the callee writes through the caller's
          // memory. How much it wrote is only known after the call, so
          // the wrapper cannot copy the result back into the caller's
          // list — the shape stays skipped.
          return (
            null,
            'inout buffer: the callee writes through the caller\'s memory, '
                'and the length it produced is only known after the call',
          );
        case TypeKind.pointer:
        case TypeKind.string:
        case TypeKind.stringList:
        case TypeKind.stringArrayPointer:
          return (
            null,
            'inout parameter of a pointer to a pointer: the callee '
                'allocates the pointee',
          );
        default:
          return (
            null,
            'inout parameter of a shape the wrapper cannot seed: '
                '${m.kind}',
          );
      }
    }

    // A **NUL-terminated** buffer the callee allocates: the C function
    // allocates the buffer, terminates it with a NUL and writes its
    // address into the caller's slot. No length is stated anywhere, so
    // the wrapper measures the buffer with `strlen`.
    //
    // This is the shape of `g_spawn_sync`'s `standard_output`.
    if (direction == GirParameterDirection.out &&
        TypeResolver.isNulTerminatedByteBufferOut(
          ref,
          transfer: transfer,
          direction: direction,
          callerAllocates: callerAllocates,
        )) {
      usesGirFfi = true;
      return (
        TypeBridge(
          wrapperType: 'String?',
          nativeType: 'ffi.Pointer<ffi.Pointer<ffi.Uint8>>',
          dartFfiType: 'ffi.Pointer<ffi.Pointer<ffi.Uint8>>',
          toNative: _id,
          fromNative: (e) => e,
          // The slot the callee writes the buffer pointer into.
          outPointee: 'ffi.Pointer<ffi.Uint8>',
          outExtract: (slotVar) =>
              'nulTerminatedStringFromNative('
              '$slotVar.value.cast<ffi.Uint8>())',
          outIsNulTerminatedString: true,
        ),
        null,
      );
    }
    // A byte buffer the callee allocates, with no length anywhere in
    // the signature: the wrapper cannot copy the buffer out, because it
    // does not know how long the buffer is.
    if (direction == GirParameterDirection.out &&
        !forReturn &&
        !byteArrayIn &&
        TypeResolver.isByteArrayElement(ref) &&
        ref.array!.lengthParameterIndex == null &&
        ref.array!.fixedSize == null) {
      return (
        null,
        'a byte buffer with no length binding: the signature does not '
            'state how long the buffer is',
      );
    }

    // An **OUT array**: the wrapper reads the elements back into a Dart
    // list. The shape is recognised before the ordinary array handling,
    // which covers the arrays the *caller* fills.
    //
    // A byte array is left alone: the byte-buffer machinery below knows
    // how to copy a buffer out of the callee and how to release it.
    if (direction == GirParameterDirection.out &&
        !forReturn &&
        !byteArrayIn &&
        !TypeResolver.isByteArrayElement(ref) &&
        (m.kind == TypeKind.primitiveArray || m.kind == TypeKind.recordArray)) {
      final outArray = _outArrayBridge(
        ref,
        transfer: transfer,
        callerAllocates: callerAllocates,
        siblings: siblings,
      );
      if (outArray.$1 != null || outArray.$2 != null) return outArray;
      // The shape is not an OUT array after all — the ordinary array
      // handling takes over.
    }

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
        // For OUT parameters the generator always allocates a
        // buffer and reads the result with `outExtract`; the C
        // function's `allow-none="1"` only says the caller *may*
        // pass NULL — passing a valid pointer is always accepted.
        if (nullable && !forReturn && direction == GirParameterDirection.in_) {
          return _nullableScalarBridge(m);
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
        if (nullable && !forReturn && direction == GirParameterDirection.in_) {
          return _nullableScalarBridge(
            m,
            dartType: 'bool',
            nativeType: 'ffi.Int32',
            toNative: (e) => '$e ? 1 : 0',
          );
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
            // A nullable OUT string stays nullable on the Dart side:
            // GLib leaves the slot `NULL` when there is no value to
            // report (`g_file_load_contents`' `etag_out` for a file
            // without an etag), and asserting non-null there would
            // throw instead of yielding `null`.
            outExtract: nullable
                ? (v) => 'stringFromNative($v.value.cast(), free: true)'
                : (v) => 'stringFromNative($v.value.cast(), free: true)!',
          ),
          null,
        );
      case TypeKind.stringList:
        usesFfiString = true;
        usesGirFfi = true;
        if (forReturn) {
          // A `char **` return: GLib hands over a NULL-terminated array
          // of strings. The GIR's `transfer-ownership` decides who
          // releases it — `g_strfreev` for a full transfer (the array
          // *and* its strings), nothing for a static table such as
          // `g_get_language_names`, which stays owned by GLib.
          String fromNative(String e) {
            // The GIR binds a callee-allocated string array to the
            // parameter that holds its count. When that count is known,
            // the array is read for exactly that many elements — a
            // `gchar **` is not always NULL-terminated
            // (`g_bookmark_file_get_applications`).
            final count = stringListCountExpr;
            final len = count == null ? '' : ', length: $count';
            final read =
                'stringListFromNative($e, free: ${transfer == GirTransferOwnership.full}$len)';
            return nullable ? read : '$read!';
          }

          return (
            TypeBridge(
              wrapperType: nullable ? 'List<String>?' : 'List<String>',
              nativeType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
              dartFfiType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
              toNative: _id,
              fromNative: fromNative,
            ),
            null,
          );
        }
        return (
          TypeBridge(
            wrapperType: 'List<String?>?',
            nativeType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
            dartFfiType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
            toNative: _id, // handled via withNativeStringList
            fromNative: (e) => e, // never returned by GLib in the corpus
            isStringList: true,
            // The GIR's length binding: the 0-based index of the sibling
            // parameter that carries the count. The emitter checks it
            // against the parameter list — GLib's GIR writes a binding
            // for arrays that carry no count at all.
            arrayLengthParameter: m.arrayLengthParameter,
          ),
          null,
        );
      case TypeKind.countedString:
        // A single string whose **byte** length a sibling parameter
        // carries — GLib's `(string, length)` pair. The string is
        // marshalled through `withNativeStringBytes`, which reports the
        // byte length, and the sibling parameter is absorbed: the count
        // the C side reads is the length of the string the caller passed.
        usesFfiString = true;
        usesGirFfi = true;
        return (
          TypeBridge(
            wrapperType: nullable ? 'String?' : 'String',
            nativeType: 'ffi.Pointer<Utf8>',
            dartFfiType: 'ffi.Pointer<Utf8>',
            toNative: _id, // handled via withNativeStringBytes
            fromNative: (e) => e, // never returned by GLib in the corpus
            isString: true,
            isCountedString: true,
            arrayLengthParameter: m.arrayLengthParameter,
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
            evaluatesArgTwice: nullable,
            outPointee: 'ffi.Pointer<ffi.Void>',
            outExtract: (v) => '$v.value',
          ),
          null,
        );
      case TypeKind.enumeration:
        if (nullable && !forReturn && direction == GirParameterDirection.in_) {
          return _nullableScalarBridge(
            m,
            nativeType: 'ffi.Int32',
            toNative: (e) => '$e.value',
            outExtract: (v) => '${m.dartType}.fromValue($v.value)',
          );
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
        if (nullable && !forReturn && direction == GirParameterDirection.in_) {
          return _nullableScalarBridge(
            m,
            nativeType: 'ffi.Uint32',
            toNative: (e) => '$e.value',
            outExtract: (v) => '${m.dartType}($v.value)',
          );
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
      case TypeKind.record:
        // A record the generator emits as an `ffi.Struct`: the caller
        // passes the struct by value, the C API takes it by pointer.
        // Every other record stays an opaque handle wrapper.
        final found = findDeclaration(ref.name, relativeTo: relativeTo);
        final decl = found?.$2;
        final declNs = found?.$1.name ?? namespace.name;
        final isStruct =
            decl is GirRecord && TypeResolver.isStructRecord(decl, declNs);
        if (!isStruct) {
          return (
            outWrapperBridge(
              m.dartType,
              ref.cType,
              nullable: nullable,
              transfer: transfer,
              ownershipFinalizer: ownershipFinalizerFor(
                ref.name,
                relativeTo: relativeTo,
              ),
              floatingReference:
                  decl is GirRecord &&
                  TypeResolver.floatingReferenceCopyFunction(decl) != null,
            ),
            null,
          );
        }
        final structName = m.dartType;
        final byValue = !(ref.cType ?? '').endsWith('*');
        if (byValue) {
          return (
            TypeBridge(
              wrapperType: structName,
              nativeType: structName,
              dartFfiType: structName,
              toNative: _id,
              fromNative: _id,
            ),
            null,
          );
        }
        return (
          TypeBridge(
            wrapperType: structName,
            nativeType: 'ffi.Pointer<$structName>',
            dartFfiType: 'ffi.Pointer<$structName>',
            toNative: _id,
            fromNative: _id,
            structArgType: structName,
            outPointee: structName,
            outIsStruct: true,
            // The struct is a *view* into the buffer the C function wrote
            // into. `refWithFinalizer` hands the buffer's ownership to the
            // returned struct — it is freed when the struct is collected —
            // so the wrapper must not free the buffer itself.
            outExtract: (v) => '$v.refWithFinalizer(malloc.nativeFree)',
          ),
          null,
        );
      case TypeKind.classType:
      case TypeKind.interface:
      case TypeKind.union:
        return (
          outWrapperBridge(
            m.dartType,
            ref.cType,
            nullable: nullable,
            transfer: transfer,
            ownershipFinalizer: ownershipFinalizerFor(
              ref.name,
              relativeTo: relativeTo,
            ),
            floatingReference: _isFloatingReference(ref, relativeTo),
          ),
          null,
        );
      case TypeKind.primitiveArray:
      case TypeKind.recordArray:
        // A byte buffer the *caller* provides: the caller owns the
        // buffer, hands it to the callee, and a sibling parameter carries
        // the byte count. This is the shape of `g_bytes_new`'s `data` and
        // of `g_file_replace_contents`' `contents`.
        //
        // The same shape appears with the roles swapped: the GIR marks
        // `g_input_stream_read`'s `buffer` `direction="out"` because the
        // callee *fills* it, but `caller-allocates="1"` says the storage
        // is the caller's. The Dart side is the same — the caller hands
        // over a `Uint8List` and the callee writes into it.
        //
        // The wrapper takes a Dart `Uint8List` and mirrors it into a
        // GLib-allocated native buffer for the call (`withNativeBytes`),
        // so the user never handles a raw pointer. The byte count is the
        // list's length — the length parameter is absorbed from the Dart
        // signature and stays in the native one.
        if (byteArrayIn &&
            (direction == GirParameterDirection.in_ ||
                direction == GirParameterDirection.out) &&
            TypeResolver.isByteArrayElement(ref)) {
          usesGirFfi = true;
          usesTypedData = true;
          return (
            TypeBridge(
              wrapperType: 'Uint8List',
              nativeType: 'ffi.Pointer<ffi.Uint8>',
              dartFfiType: 'ffi.Pointer<ffi.Uint8>',
              toNative: _id, // handled via withNativeBytes
              fromNative: (e) => e,
              isByteArrayIn: true,
              byteArrayLengthIndex: ref.array!.lengthParameterIndex!,
              // `transfer-ownership="full"`: the callee owns the buffer
              // and releases it with `g_free`.
              byteArrayOwnedByCallee: transfer == GirTransferOwnership.full,
            ),
            null,
          );
        }
        // A byte buffer the *callee* allocates: the C function allocates
        // the buffer, fills it, and writes the pointer into the caller's
        // slot; a sibling parameter carries the byte count. This is the
        // shape of `g_file_load_contents`' `contents`.
        //
        // The wrapper copies the bytes into a Dart `Uint8List` and
        // releases the native buffer — the garbage collector cannot see
        // native memory, so leaving the buffer to it would leak.
        if (direction == GirParameterDirection.out &&
            !callerAllocates &&
            transfer == GirTransferOwnership.full &&
            TypeResolver.isCalleeAllocatedByteBuffer(ref)) {
          usesGirFfi = true;
          usesTypedData = true;
          return (
            TypeBridge(
              wrapperType: 'Uint8List',
              nativeType: 'ffi.Pointer<ffi.Uint8>',
              dartFfiType: 'ffi.Pointer<ffi.Uint8>',
              toNative: _id,
              fromNative: (e) => e,
              // The slot the callee writes the buffer pointer into. The
              // native parameter is a pointer to it (`char **`), so the
              // emitter allocates one pointer-sized cell.
              outPointee: 'ffi.Pointer<ffi.Uint8>',
              outByteBufferLengthIndex: ref.array!.lengthParameterIndex!,
              outExtractBytes: (bufferVar, lengthVar) =>
                  'bytesFromNative($bufferVar.value.cast<ffi.Uint8>(), '
                  '$lengthVar.value)',
            ),
            null,
          );
        }
        // A byte buffer the *caller* provides and the callee fills: the
        // GIR marks the parameter as an out parameter, but the C
        // signature takes a buffer the caller owns — the bytes arrive
        // with the result, so there is nothing to read back here.
        //
        // This is the shape of `g_input_stream_read_all_async`'s
        // `buffer`.
        if (direction == GirParameterDirection.out &&
            callerAllocates &&
            TypeResolver.isByteArrayElement(ref) &&
            ref.array!.lengthParameterIndex != null) {
          return (
            null,
            'a caller-provided byte buffer: the C signature takes a buffer '
                'the caller owns, and the bytes arrive with the result',
          );
        }
        // The GIR models a **boxed object** as a byte array — the `data`
        // of `g_tls_connection_get_channel_binding_data` is a
        // `GByteArray *` the callee allocates, spelled
        // `<array name="GLib.ByteArray" c:type="GByteArray*">`. The
        // object belongs to the connection, so there is no buffer to copy
        // and nothing to release here.
        if (direction == GirParameterDirection.out &&
            ref.array != null &&
            (ref.name ?? '').isNotEmpty &&
            TypeResolver.isByteArrayElement(ref)) {
          return (
            null,
            'the GIR models the ${ref.name} as a byte array; the C '
                'signature hands over a boxed object the callee allocates',
          );
        }
        // The GIR declares an allocated byte buffer, but the C signature
        // writes a pointer *into* the input string. There is nothing to
        // copy and nothing to release.
        if (direction == GirParameterDirection.out &&
            TypeResolver.isBorrowedEndPointer(ref, transfer)) {
          return (
            null,
            'the GIR declares an allocated byte buffer; the C signature '
                'writes a pointer into the input string',
          );
        }
        // The GIR declares a callee-allocated buffer, but the C signature
        // takes a buffer the caller provides — and states no size.
        if (direction == GirParameterDirection.out &&
            TypeResolver.isCallerProvidedBufferOut(ref, transfer)) {
          return (
            null,
            'the GIR declares a callee-allocated buffer; the C signature '
                'takes a caller-provided buffer and states no size',
          );
        }
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
      case TypeKind.stringArrayPointer:
        // A string array the *callee* allocates: the C function allocates
        // the `gchar **` and writes its address into the caller's slot.
        // This is the shape of `g_shell_parse_argv`'s `argvp` and of
        // `g_settings_schema_source_list_schemas`' `non_relocatable`.
        //
        // The wrapper reads the array out of the slot after the call and
        // releases it the way the GIR's transfer annotation says:
        // `transfer-ownership="full"` hands the array *and* its strings
        // over (`g_strfreev`), `transfer-ownership="container"` hands
        // over the array alone (`g_free`).
        if (direction != GirParameterDirection.out &&
            direction != GirParameterDirection.inout) {
          return (
            null,
            'a string array the callee allocates (gchar ***) cannot be an '
                'input parameter',
          );
        }
        usesGirFfi = true;
        final freeArgs = switch (transfer) {
          GirTransferOwnership.full => 'free: true',
          GirTransferOwnership.container => 'freeArray: true',
          _ => '',
        };
        return (
          TypeBridge(
            wrapperType: 'List<String>?',
            nativeType: 'ffi.Pointer<ffi.Pointer<ffi.Pointer<Utf8>>>',
            dartFfiType: 'ffi.Pointer<ffi.Pointer<ffi.Pointer<Utf8>>>',
            toNative: _id,
            fromNative: (e) => e,
            // The slot the callee writes the array pointer into. The
            // native parameter is a pointer to it (`gchar ***`), so the
            // emitter allocates one pointer-sized cell.
            outPointee: 'ffi.Pointer<ffi.Pointer<Utf8>>',
            outExtract: (v) => 'stringListFromNative($v.value, $freeArgs)',
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
    // The parameter list, for the destroy-notify trampoline. The
    // signature builder already reported the skip, so this one does not
    // report again.
    final cbParams = emitter.userParams(declObj, label: cbName, report: false);
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
        callbackParams: cbParams,
        callbackFfiSignature: sig,
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

  /// Every callable of the current namespace, in declaration order.
  ///
  /// The lookup is by C identifier, which is unique across the whole
  /// library — the GIR's own names are only unique per owner.
  Iterable<GirCallable> get _namespaceCallables sync* {
    for (final c in namespace.classes) {
      yield* c.constructors;
      yield* c.methods;
      yield* c.functions;
    }
    for (final i in namespace.interfaces) {
      yield* i.methods;
      yield* i.functions;
    }
    for (final r in namespace.records) {
      yield* r.constructors;
      yield* r.methods;
      yield* r.functions;
    }
    for (final u in namespace.unions) {
      yield* u.constructors;
      yield* u.methods;
      yield* u.functions;
    }
    yield* namespace.functions;
  }

  /// The `GBytes`-based sibling of [fn], when the library declares one.
  ///
  /// GLib spells the sibling by inserting `_bytes` into the C name
  /// (`g_file_replace_contents_async` →
  /// `g_file_replace_contents_bytes_async`). The sibling takes the same
  /// buffer as a `GBytes`, which the callee keeps alive on its own — the
  /// property a raw byte pointer does not have.
  ///
  /// The lookup verifies that the candidate really takes a `GBytes`, so a
  /// name that merely looks similar is not mistaken for a sibling.
  ({GirCallable sibling, String dartName})? bytesSibling(GirCallable fn) {
    final id = TypeResolver.bytesSiblingCIdentifier(fn.cIdentifier);
    if (id == null) return null;
    for (final candidate in _namespaceCallables) {
      if (candidate.cIdentifier != id) continue;
      if (!candidate.parameters.any((p) => _isBytesType(p.type?.name))) {
        continue;
      }
      return (sibling: candidate, dartName: _dartNameOf(candidate));
    }
    return null;
  }

  /// Whether [name] names GLib's `GBytes` record.
  static bool _isBytesType(String? name) {
    if (name == null) return false;
    final dot = name.lastIndexOf('.');
    final local = dot >= 0 ? name.substring(dot + 1) : name;
    return local == 'Bytes';
  }

  /// The Dart name a callable is emitted under.
  ///
  /// A constructor drops the `new_` prefix (`new_from_bytes` →
  /// `fromBytes`); every other callable is lowerCamelCased.
  static String _dartNameOf(GirCallable callable) {
    var name = callable.name;
    if (callable is GirConstructor && name.startsWith('new_')) {
      name = name.substring(4);
    }
    return escapeKeyword(toLowerCamel(name));
  }

  /// The lifetime note a byte-array wrapper carries.
  ///
  /// A byte array that stays a raw pointer has a lifetime the caller has
  /// to honour, and the GIR states it: the buffer is not copied, so it has
  /// to stay valid until the async callback fires, or until the destroy
  /// notify runs. The note names the `GBytes` sibling when the library
  /// declares one — that variant owns the buffer, so the caller does not
  /// have to.
  List<String> byteArrayLifetimeDoc(GirCallable fn) {
    final raw = TypeResolver.rawByteArrays(fn);
    if (raw.isEmpty) return const [];
    final names = raw.map((p) => p.name).toSet();
    final buffer = names.length == 1 ? '`${names.first}`' : 'the buffer';
    final isAsync = TypeResolver.isAsync(fn);
    final hasDestroy = fn.parameters.any(TypeResolver.isDestroyNotify);
    final sibling = bytesSibling(fn);

    final lines = <String>[];
    if (isAsync) {
      lines.add(
        '/// $buffer is **not** copied: it has to stay valid until the '
        'callback fires.',
      );
    }
    if (hasDestroy) {
      lines.add(
        '/// The callee takes over $buffer: keep it valid until the '
        'destroy notify runs.',
      );
    }
    if (sibling != null) {
      lines.add(
        '/// The `GBytes` variant [${sibling.dartName}] owns the buffer '
        'for the duration of the call — prefer it.',
      );
    }
    return lines;
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

  /// The `NativeFinalizer` that releases a reference the wrapper of
  /// [typeName] owns, or null when the wrapper cannot release it.
  ///
  /// * A GObject-rooted class and a GInterface are released with
  ///   `g_object_unref` — an interface is a GObject in C too.
  /// * A boxed record or union is released with its own destructor, which
  ///   the record's class exposes as a `NativeFinalizer` member.
  /// * Everything else — a borrowed reference, a type the GIR gives no
  ///   destructor, a type whose destructor must not run from a finalizer
  ///   thread — has no finalizer.
  String? ownershipFinalizerFor(String? typeName, {GirNamespace? relativeTo}) {
    final found = findDeclaration(typeName, relativeTo: relativeTo);
    if (found == null) return null;
    final (ns, decl) = found;
    if (decl is GirClass) {
      return isGObjectRooted(decl) ? 'gobjectFinalizer' : null;
    }
    if (decl is GirInterface) return 'gobjectFinalizer';
    if (decl is GirRecord) {
      if (TypeResolver.destructorOf(decl, ns.name) == null) return null;
      return '${dartTypeName(ns.name, decl.name)}.'
          '${boxedFinalizerName(decl.name)}';
    }
    if (decl is GirUnion) {
      if (TypeResolver.destructorOf(decl, ns.name) == null) return null;
      return '${dartTypeName(ns.name, decl.name)}.'
          '${boxedFinalizerName(decl.name)}';
    }
    return null;
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

/// The declaration that claimed a top-level Dart name.
///
/// Recorded so a later name collision can name the sibling that
/// already holds the name.
class NameOwner {
  const NameOwner(this.kind, this.label);

  /// What kind of declaration claimed the name — `constant`, `class`,
  /// `enum`, `bitfield`, `record`, `function`, …
  final String kind;

  /// The namespace-qualified GIR symbol the name came from, e.g.
  /// `Gdk.KEY_Armenian_at`.
  final String label;

  @override
  String toString() => '$kind $label';
}

String _id(String e) => e;
