/// Type mapping between GIR/C types and Dart/FFI types.
library;

import '../gir/gir.dart';

/// Classification of a resolved type, driving code emission.
enum TypeKind {
  primitive,
  string,
  stringList,
  boolean,
  enumeration,
  bitfield,
  classType,
  interface,
  record,
  union,
  callback,
  pointer,
  opaque,
  voidType,
  primitiveArray,
  recordArray,
  unsupported,
}

/// The result of resolving a [GirTypeRef] against the loaded namespaces.
class TypeMapping {
  const TypeMapping({
    required this.dartType,
    required this.nativeType,
    required this.kind,
    this.isPointer = false,
    this.requiredImport,
    this.reason,
    this.arrayElement,
    this.arrayLengthParameter,
  });

  const TypeMapping.unsupported(String reason)
    : this(
        dartType: 'Object',
        nativeType: 'Pointer<ffi.Void>',
        kind: TypeKind.unsupported,
        isPointer: true,
        reason: reason,
      );

  /// The public Dart type, e.g. `int`, `bool`, `String`, `GtkWidget`.
  final String dartType;

  /// The FFI native type used in signatures, e.g. `ffi.Int32`,
  /// `Pointer<ffi.Void>`. Emit code imports `package:ffi` as `ffi`.
  final String nativeType;

  final TypeKind kind;

  /// True when values of this type cross the FFI boundary as a pointer.
  final bool isPointer;

  /// Package that must be imported to use [dartType], e.g. `gtk4`.
  /// Null for built-ins and types declared in the current namespace.
  final String? requiredImport;

  /// Why resolution failed, when [kind] is [TypeKind.unsupported].
  final String? reason;

  /// For [TypeKind.primitiveArray] / [TypeKind.recordArray] mappings,
  /// the resolved element mapping. Carries the element's Dart and native
  /// types so the wrapper emits `Pointer<ElementType>` signatures.
  final TypeMapping? arrayElement;

  /// For bound-length arrays, the 0-based index into the callable's
  /// parameter list of the length parameter. Null when the array has
  /// no length binding (e.g. `<array c:type="int*">` without
  /// `<array length="N">`).
  final int? arrayLengthParameter;
}

/// Maps a [GirNamespace] to the Dart package that will hold its bindings.
///
/// The core GNOME stack has an explicit mapping; everything else falls back
/// to `snake_case(name) + major version` (when a version is present).
String packageNameFor(GirNamespace namespace) {
  const core = {
    'GLib': 'glib',
    'GObject': 'gobject',
    'Gio': 'gio',
    'GdkPixbuf': 'gdk_pixbuf',
    'cairo': 'cairo',
    'Pango': 'pango',
    'Gdk': 'gdk4',
    'Gtk': 'gtk4',
    'Adw': 'adw',
    'Graphene': 'graphene',
    'Gsk': 'gsk4',
  };
  final known = core[namespace.name];
  if (known != null) return known;

  final base = _snakeCase(namespace.name).toLowerCase();
  final major = namespace.version.split('.').first;
  if (major.isEmpty || major == '0') return base;
  return '$base$major';
}

String _snakeCase(String input) {
  final buffer = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    final upper = c.toUpperCase() == c && c.toLowerCase() != c;
    if (upper &&
        i > 0 &&
        (input[i - 1].toLowerCase() == input[i - 1] ||
            (i + 1 < input.length &&
                input[i + 1].toLowerCase() == input[i + 1]))) {
      buffer.write('_');
    }
    buffer.write(c.toLowerCase());
  }
  return buffer.toString();
}

/// Resolves [GirTypeRef]s to [TypeMapping]s using a set of loaded
/// namespaces plus a built-in table of GLib/C scalar types.
class TypeResolver {
  TypeResolver(List<GirNamespace> namespaces)
    : namespaces = List.unmodifiable(namespaces);

  final List<GirNamespace> namespaces;

  static const TypeMapping _voidMapping = TypeMapping(
    dartType: 'void',
    nativeType: 'ffi.Void',
    kind: TypeKind.voidType,
  );

  /// Built-in scalar mappings, keyed by GIR type name.
  static const Map<String, TypeMapping> _byGirName = {
    'none': _voidMapping,
    'void': _voidMapping,
    'gboolean': TypeMapping(
      dartType: 'bool',
      nativeType: 'ffi.Int32',
      kind: TypeKind.boolean,
    ),
    'gint': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int32',
      kind: TypeKind.primitive,
    ),
    'gint32': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int32',
      kind: TypeKind.primitive,
    ),
    'guint': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'guint32': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'gint64': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int64',
      kind: TypeKind.primitive,
    ),
    'guint64': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint64',
      kind: TypeKind.primitive,
    ),
    'glong': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Long',
      kind: TypeKind.primitive,
    ),
    'gulong': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.UnsignedLong',
      kind: TypeKind.primitive,
    ),
    'gshort': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int16',
      kind: TypeKind.primitive,
    ),
    'gushort': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint16',
      kind: TypeKind.primitive,
    ),
    'gint16': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int16',
      kind: TypeKind.primitive,
    ),
    'guint16': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint16',
      kind: TypeKind.primitive,
    ),
    'gintptr': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.IntPtr',
      kind: TypeKind.primitive,
    ),
    'guintptr': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Size',
      kind: TypeKind.primitive,
    ),
    'gint8': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int8',
      kind: TypeKind.primitive,
    ),
    'guint8': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint8',
      kind: TypeKind.primitive,
    ),
    'guchar': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint8',
      kind: TypeKind.primitive,
    ),
    'gchar': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int8',
      kind: TypeKind.primitive,
    ),
    'gsize': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Size',
      kind: TypeKind.primitive,
    ),
    'gssize': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.IntPtr',
      kind: TypeKind.primitive,
    ),
    'gfloat': TypeMapping(
      dartType: 'double',
      nativeType: 'ffi.Float',
      kind: TypeKind.primitive,
    ),
    'gdouble': TypeMapping(
      dartType: 'double',
      nativeType: 'ffi.Double',
      kind: TypeKind.primitive,
    ),
    'gunichar': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'GType': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Size',
      kind: TypeKind.primitive,
    ),
    'utf8': TypeMapping(
      dartType: 'String',
      nativeType: 'Pointer<ffi.Utf8>',
      kind: TypeKind.string,
      isPointer: true,
    ),
    'filename': TypeMapping(
      dartType: 'String',
      nativeType: 'Pointer<ffi.Utf8>',
      kind: TypeKind.string,
      isPointer: true,
    ),
    'gpointer': TypeMapping(
      dartType: 'Pointer<ffi.Void>',
      nativeType: 'Pointer<ffi.Void>',
      kind: TypeKind.pointer,
      isPointer: true,
    ),
    'gconstpointer': TypeMapping(
      dartType: 'Pointer<ffi.Void>',
      nativeType: 'Pointer<ffi.Void>',
      kind: TypeKind.pointer,
      isPointer: true,
    ),
  };

  /// Fallback mappings keyed by C type, consulted when the GIR name misses.
  static const Map<String, TypeMapping> _byCType = {
    'void': _voidMapping,
    'gboolean': TypeMapping(
      dartType: 'bool',
      nativeType: 'ffi.Int32',
      kind: TypeKind.boolean,
    ),
    'gint': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int32',
      kind: TypeKind.primitive,
    ),
    'int': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int32',
      kind: TypeKind.primitive,
    ),
    'gint32': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int32',
      kind: TypeKind.primitive,
    ),
    'guint': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'unsigned int': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'guint32': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'gint64': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int64',
      kind: TypeKind.primitive,
    ),
    'guint64': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint64',
      kind: TypeKind.primitive,
    ),
    'glong': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Long',
      kind: TypeKind.primitive,
    ),
    'gulong': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.UnsignedLong',
      kind: TypeKind.primitive,
    ),
    'gsize': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Size',
      kind: TypeKind.primitive,
    ),
    'gssize': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.IntPtr',
      kind: TypeKind.primitive,
    ),
    'gfloat': TypeMapping(
      dartType: 'double',
      nativeType: 'ffi.Float',
      kind: TypeKind.primitive,
    ),
    'gdouble': TypeMapping(
      dartType: 'double',
      nativeType: 'ffi.Double',
      kind: TypeKind.primitive,
    ),
    'double': TypeMapping(
      dartType: 'double',
      nativeType: 'ffi.Double',
      kind: TypeKind.primitive,
    ),
    'gunichar': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
    ),
    'GType': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Size',
      kind: TypeKind.primitive,
    ),
    'gchar*': TypeMapping(
      dartType: 'String',
      nativeType: 'Pointer<ffi.Utf8>',
      kind: TypeKind.string,
      isPointer: true,
    ),
    'char*': TypeMapping(
      dartType: 'String',
      nativeType: 'Pointer<ffi.Utf8>',
      kind: TypeKind.string,
      isPointer: true,
    ),
    'gpointer': TypeMapping(
      dartType: 'Pointer<ffi.Void>',
      nativeType: 'Pointer<ffi.Void>',
      kind: TypeKind.pointer,
      isPointer: true,
    ),
    'gconstpointer': TypeMapping(
      dartType: 'Pointer<ffi.Void>',
      nativeType: 'Pointer<ffi.Void>',
      kind: TypeKind.pointer,
      isPointer: true,
    ),
  };

  /// Mapping for argv-style arrays of strings (`gchar**`). Always
  /// nullable at the Dart layer because GLib APIs accept either a NULL
  /// argv or a NULL-terminated array. The runtime helper
  /// `gir_ffi.withNativeStringList` handles the per-call marshalling.
  static const _stringListMapping = TypeMapping(
    dartType: 'List<String?>?',
    nativeType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
    kind: TypeKind.stringList,
    isPointer: true,
  );

  static const Set<String> _unsupportedNames = {'va_list', girVarargsName};

  /// `c:type` strings we accept for argv-style string arrays. The C ABI
  /// for `gchar**` and `const gchar* const*` is identical on every
  /// platform we target (the `const` is a C-level qualifier that does not
  /// change the pointer representation), so we accept both.
  static const Set<String> _stringListCtypes = {
    'gchar**',
    'const gchar* const*',
    'const gchar**',
    'char**',
    'const char* const*',
    'const char**',
  };

  /// Whether [type] is an argv-style array of strings we can marshal.
  ///
  /// Currently restricted to input-only arrays: bound-length arrays
  /// (`<array length="N">` with N > 0) are rejected because the C side
  /// reads `N` slots rather than scanning for a NULL terminator, and
  /// strv-by-reference (`gchar***`) is rejected because it needs
  /// bidirectional marshalling.
  static bool isStringListArray(GirTypeRef type) {
    final array = type.array;
    if (array == null) return false;
    // `length="0"` in GLib's GIR files is the conventional way to mark a
    // NULL-terminated string list (it shows up in `g_application_run`,
    // `g_subprocess_*`, `g_spawn_*`). Treat it as "no length binding".
    if (array.lengthParameterIndex != null && array.lengthParameterIndex! > 0) {
      return false;
    }
    final cType = type.cType;
    if (cType == null || !_stringListCtypes.contains(cType)) return false;
    final elem = array.elementType;
    final elemName = elem.name;
    return elemName == 'utf8' ||
        elemName == 'filename' ||
        elem.cType == 'gchar*';
  }

  /// `c:type` strings for a byte buffer the callee allocates: the C
  /// parameter is a pointer to a pointer to a byte (`char**`, `guchar**`).
  ///
  /// The single-pointer spellings (`gchar *`) are deliberately absent:
  /// they are either a caller-allocated buffer (`g_io_channel_read_chars`)
  /// or a returned string (`g_base64_encode_step`).
  static const Set<String> _byteBufferCtypes = {
    'char**',
    'gchar**',
    'guchar**',
    'const char**',
    'const gchar**',
    'const guchar**',
  };

  /// The GIR names of the byte-sized element types.
  static const Set<String> _byteNames = {'guint8', 'guchar', 'gchar'};

  /// Whether [ref] is an array of bytes handed over as a double pointer
  /// (`char**` / `guchar**`) — the shape of a buffer the *callee*
  /// allocates and fills in.
  ///
  /// The array must carry a length binding (`<array length="N">`), whose
  /// index is the 0-based position of the sibling parameter holding the
  /// byte count; without one the size of the buffer is unknown and the
  /// wrapper cannot copy it.
  static bool isCalleeAllocatedByteBuffer(GirTypeRef? ref) {
    final array = ref?.array;
    if (array == null) return false;
    final cType = ref!.cType;
    if (cType == null || !_byteBufferCtypes.contains(cType)) return false;
    if (!_byteNames.contains(array.elementType.name)) return false;
    return array.lengthParameterIndex != null;
  }

  /// Whether [p] is an OUT parameter of the callee-allocated byte-buffer
  /// shape: the callee allocates the buffer, the caller owns it, and a
  /// sibling parameter carries the byte count.
  ///
  /// This is the shape of `g_file_load_contents`' `contents`:
  /// `direction="out" caller-allocates="0" transfer-ownership="full"`,
  /// a `char**` of bytes, and a `gsize *length` beside it.
  static bool isByteBufferOut(GirParameter p) {
    if (p.direction != GirParameterDirection.out) return false;
    // `caller-allocates="0"` — the callee allocates the buffer. The GIR
    // default is `true` (the caller allocates), so an absent attribute
    // never reaches this branch.
    if (p.callerAllocates) return false;
    // The caller owns the buffer and has to release it.
    if (p.transferOwnership != GirTransferOwnership.full) return false;
    return isCalleeAllocatedByteBuffer(p.type);
  }

  /// The GIR names of the *unsigned* byte element types a caller-provided
  /// byte array can carry.
  ///
  /// `gchar` is deliberately absent: a `gchar` array is text, and its
  /// signedness makes it a different shape (`g_unix_socket_address_new_abstract`
  /// takes a NUL-terminated path, `g_convert` takes a locale-encoded
  /// string).
  static const Set<String> _unsignedByteNames = {'guint8', 'guchar'};

  /// The GIR names accepted for the length sibling of a byte array.
  static const Set<String> _byteLengthNames = {
    'gsize',
    'gssize',
    'guint',
    'gint',
    'guint8',
    'guchar',
    'gint8',
    'guint16',
    'gint16',
    'guint32',
    'gint32',
    'guint64',
    'gint64',
    'glong',
    'gulong',
    'gshort',
    'gushort',
    'gintptr',
    'guintptr',
  };

  /// Whether [ref] is an array of unsigned bytes.
  static bool isByteArrayElement(GirTypeRef? ref) {
    final array = ref?.array;
    if (array == null) return false;
    return _unsignedByteNames.contains(array.elementType.name);
  }

  /// Whether [p] is a `GDestroyNotify`-style callback parameter.
  ///
  /// The GIR spells the type `DestroyNotify` (GLib), `GLib.DestroyNotify`
  /// (the other namespaces) or `PixbufDestroyNotify` (GdkPixbuf) — all of
  /// them end with `DestroyNotify`.
  static bool isDestroyNotify(GirParameter p) {
    final name = p.type?.name;
    if (name == null) return false;
    return name.endsWith('DestroyNotify');
  }

  /// Whether [p] hands a buffer of bytes to the callee.
  ///
  /// The shape is an IN parameter whose type is an array of unsigned bytes
  /// with a length binding (`<array length="N">`): the caller owns the
  /// buffer and the sibling parameter at index N carries the byte count.
  /// This is the shape of `g_bytes_new`'s `data` and of
  /// `g_file_replace_contents`' `contents`.
  ///
  /// [siblings] is the callable's full parameter list. The rule needs it
  /// twice:
  ///
  /// * the length sibling must be an IN integer — the byte count;
  /// * a `GDestroyNotify` sibling means the callee takes over the buffer's
  ///   *lifetime* (`g_variant_new_from_data`,
  ///   `g_memory_input_stream_new_from_data`,
  ///   `g_tls_password_set_value_full`), so the buffer cannot be a
  ///   temporary that dies with the call.
  static bool isByteArrayIn(GirParameter p, List<GirParameter> siblings) {
    if (p.direction != GirParameterDirection.in_) return false;
    if (!isByteArrayElement(p.type)) return false;
    final array = p.type!.array!;
    // `length="0"` marks an array that is not length-bound — the GIR
    // convention for NUL-terminated arrays.
    final lengthIdx = array.lengthParameterIndex;
    if (lengthIdx == null || lengthIdx <= 0) return false;
    if (lengthIdx >= siblings.length) return false;
    final length = siblings[lengthIdx];
    if (length.direction != GirParameterDirection.in_) return false;
    if (!_byteLengthNames.contains(length.type?.name)) return false;
    for (final sibling in siblings) {
      if (isDestroyNotify(sibling)) return false;
    }
    return true;
  }

  /// The GIR records the generator emits as real `ffi.Struct`s.
  ///
  /// A record qualifies when the GIR declares no methods and no
  /// constructors (a struct carries no behaviour), it is not a boxed
  /// type, and every field has a simple type. In this corpus that is
  /// the GObject type-system records: the type-system API takes them by
  /// pointer, so the *caller* builds them — and the layout has to come
  /// from the GIR instead of hand-written offsets.
  static const structRecords = <String>{
    'GObject.TypeInfo',
    'GObject.TypeQuery',
    'GObject.TypeFundamentalInfo',
    'GObject.InterfaceInfo',
  };

  /// True when [record] is emitted as an `ffi.Struct` rather than as an
  /// opaque handle wrapper.
  static bool isStructRecord(GirRecord record, String namespaceName) {
    if (record.methods.isNotEmpty || record.constructors.isNotEmpty) {
      return false;
    }
    if (record.glibTypeName != null) return false; // a boxed type
    if (record.fields.isEmpty) return false;
    return structRecords.contains('$namespaceName.${record.name}');
  }

  /// The GIR method names that release a boxed type.
  ///
  /// GLib spells the destructor `unref` for a refcounted type, `free` for
  /// a plain one and `destroy` for a couple of leftovers; the GIR's
  /// `free-function` attribute covers the types that have no such method.
  static const destructorMethodNames = <String>{
    'free',
    'unref',
    'destroy',
    'release',
    'close',
  };

  /// Boxed types whose destructor must not run from a finalizer thread.
  ///
  /// A `NativeFinalizer` callback may run on any VM thread. Releasing a
  /// refcounted value or freeing a buffer is safe there; tearing down
  /// something bound to a thread or to a main context is not — GLib
  /// expects the release to happen on the owning thread. These types keep
  /// the caller's explicit `unref()` / `free()` call.
  static const threadAffineDestructors = <String>{
    'GLib.MainContext',
    'GLib.MainLoop',
    'GLib.Source',
    'GLib.Thread',
    'GLib.IOChannel',
    'GLib.Timer',
  };

  /// Whether [fn] carries an async-scoped parameter.
  ///
  /// GLib marks the callback of an asynchronous operation with
  /// `scope="async"`: the callable returns before the callback runs, so
  /// anything the callee keeps — a byte buffer, for instance — has to stay
  /// valid past the call.
  ///
  /// A `GDestroyNotify` is async-scoped too, but it is not an
  /// asynchronous *operation*: the callee calls it when it is done with
  /// the buffer, which is a different lifetime rule.
  static bool isAsync(GirCallable fn) =>
      fn.parameters.any((p) => p.scope == 'async' && !isDestroyNotify(p));

  /// The byte-array IN parameters of [fn] that stay raw pointers.
  ///
  /// A byte array is normally mirrored into a `Uint8List` (see
  /// [isByteArrayIn]). Two situations keep the raw pointer:
  ///
  /// * the callable is **async** — GIO says it outright for
  ///   `g_file_replace_contents_async`: *"no copy of `@contents` will be
  ///   made, so it must stay valid until `@callback` is called"*;
  /// * the callable has a **`GDestroyNotify`** sibling — the callee takes
  ///   over the buffer's lifetime (`g_tls_password_set_value_full`).
  ///
  /// Both shapes need a lifetime note on the generated wrapper, so they
  /// are collected here.
  static List<GirParameter> rawByteArrays(GirCallable fn) {
    final result = <GirParameter>[];
    for (final p in fn.parameters) {
      if (!isByteArrayElement(p.type)) continue;
      if (isByteArrayIn(p, fn.parameters) && !isAsync(fn)) continue;
      result.add(p);
    }
    return result;
  }

  /// The C identifier of the `GBytes`-based sibling of [cIdentifier].
  ///
  /// GLib spells the `GBytes` variant of a byte-buffer callable by
  /// inserting `_bytes` into its name: `g_file_replace_contents_async` →
  /// `g_file_replace_contents_bytes_async`, `g_memory_input_stream_add_data`
  /// → `g_memory_input_stream_add_bytes`. The sibling takes the same
  /// buffer as a `GBytes`, which the callee keeps alive on its own — the
  /// property a raw pointer does not have.
  ///
  /// Returns null when the name carries no such hint (the caller then
  /// looks the symbol up and gives up when it is not in the library).
  static String? bytesSiblingCIdentifier(String? cIdentifier) {
    if (cIdentifier == null || cIdentifier.isEmpty) return null;
    if (cIdentifier.endsWith('_async')) {
      final base = cIdentifier.substring(
        0,
        cIdentifier.length - '_async'.length,
      );
      return '${base}_bytes_async';
    }
    if (cIdentifier.endsWith('_data')) {
      final base = cIdentifier.substring(
        0,
        cIdentifier.length - '_data'.length,
      );
      return '${base}_bytes';
    }
    return null;
  }

  /// The C function that releases [type], or null when the bindings cannot
  /// release it.
  ///
  /// The destructor is the type's own `free` / `unref` / `destroy` /
  /// `release` / `close` method — the very function the generated wrapper
  /// already exposes — or, when the type has no such method, the GIR's
  /// `free-function` attribute.
  ///
  /// [namespaceName] is the namespace the type is declared in; the
  /// thread-affine list is keyed by it.
  static String? destructorOf(GirRegisteredType type, String namespaceName) {
    if (threadAffineDestructors.contains('$namespaceName.${type.name}')) {
      return null;
    }
    final methods = switch (type) {
      GirRecord r => r.methods,
      GirUnion u => u.methods,
      GirInterface i => i.methods,
      _ => const <GirMethod>[],
    };
    for (final m in methods) {
      if (!destructorMethodNames.contains(m.name)) continue;
      final id = m.cIdentifier;
      if (id != null && id.isNotEmpty) return id;
    }
    if (type is GirRecord) return type.freeFunction;
    if (type is GirUnion) return type.freeFunction;
    return null;
  }

  /// Maps a bound-length array whose element is an int-sized primitive
  /// (gint-family scalars), boolean, enumeration, or bitfield. The
  /// wrapper signature and the FFI native signature both use
  /// `Pointer<ElementNativeType>` — e.g. `Pointer<ffi.Int32>` for an
  /// array of `gint`, `GtkAccessibleProperty`, or `gboolean`. The user
  /// `calloc<Int32>(n)` and writes raw int values; the wrapper does not
  /// need a `toNative` cast because the FFI type matches the calloc
  /// result directly. `lengthIdx` is the index of the parameter that
  /// carries the array's length — the GIR `<array length="N">` value.
  static TypeMapping _arrayPrimitiveMapping(
    TypeMapping element,
    int lengthIdx,
  ) {
    return TypeMapping(
      dartType: 'ffi.Pointer<${element.nativeType}>',
      nativeType: 'ffi.Pointer<${element.nativeType}>',
      kind: TypeKind.primitiveArray,
      isPointer: true,
      arrayElement: element,
      arrayLengthParameter: lengthIdx,
    );
  }

  /// Maps a bound-length array whose element is a record, class, or
  /// interface. The wrapper signature and the FFI native signature
  /// both use `ffi.Pointer<ffi.Void>` — the same shape a single record
  /// / class / interface parameter uses. Generated records are
  /// currently emitted as opaque pointer classes (no `StructBase`
  /// subclass), so `Pointer<RecordClass>` is not a valid Dart FFI
  /// type. The user passes a `Pointer<ffi.Void>` (e.g. from
  /// `calloc<ffi.Void>(n * sizeOfRecord)`); the wrapper passes it
  /// through unchanged. Typed iteration via `asTypedList` is a
  /// follow-up once the generator emits real struct classes.
  static TypeMapping _arrayStructMapping(TypeMapping element, int lengthIdx) {
    return TypeMapping(
      dartType: 'ffi.Pointer<ffi.Void>',
      nativeType: 'ffi.Pointer<ffi.Void>',
      kind: TypeKind.recordArray,
      isPointer: true,
      arrayElement: element,
      arrayLengthParameter: lengthIdx,
    );
  }

  /// Maps an unbound array of a primitive/enum element (e.g.
  /// `<array c:type="int*">`). No length parameter is added — the C
  /// function reads whatever the caller provides (typically via a
  /// sibling `get_n_items` accessor).
  static TypeMapping _unboundedArrayMapping(TypeMapping element) {
    return TypeMapping(
      dartType: 'ffi.Pointer<${element.nativeType}>',
      nativeType: 'ffi.Pointer<${element.nativeType}>',
      kind: TypeKind.primitiveArray,
      isPointer: true,
      arrayElement: element,
    );
  }

  /// Resolves [type] to a [TypeMapping]. Never throws: unknown or
  /// unmappable types yield `kind == TypeKind.unsupported` with a [reason].
  TypeMapping resolve(
    GirTypeRef type, {
    required GirNamespace currentNamespace,
  }) {
    if (type.isArray) {
      if (isStringListArray(type)) return _stringListMapping;
      final array = type.array!;
      final elem = array.elementType;
      // Reject elements we cannot identify — neither GIR name nor C type
      // is present, so the resolver has nothing to map.
      if ((elem.name == null || elem.name!.isEmpty) && elem.cType == null) {
        return const TypeMapping.unsupported('array of unknown element');
      }
      final elemMap = resolve(elem, currentNamespace: currentNamespace);
      if (elemMap.kind == TypeKind.unsupported) {
        return TypeMapping.unsupported(
          'array element of unsupported kind'
          '${elemMap.reason != null ? ' (${elemMap.reason})' : ''}',
        );
      }
      final lengthIdx = array.lengthParameterIndex;
      if (lengthIdx != null) {
        // Bound-length array: the C side reads exactly N slots, where N is
        // passed as a separate parameter. The wrapper must add an `int`
        // slot bound to the array's length parameter.
        switch (elemMap.kind) {
          case TypeKind.primitive:
          case TypeKind.boolean:
          case TypeKind.enumeration:
          case TypeKind.bitfield:
            return _arrayPrimitiveMapping(elemMap, lengthIdx);
          case TypeKind.record:
          case TypeKind.classType:
          case TypeKind.interface:
            return _arrayStructMapping(elemMap, lengthIdx);
          default:
            return TypeMapping.unsupported(
              'array of ${elemMap.kind} (later phase)',
            );
        }
      }
      // Unbound array: the C side reads whatever the caller provides.
      // Only primitive/enum element types make sense without an explicit
      // length — anything more complex stays unsupported.
      switch (elemMap.kind) {
        case TypeKind.primitive:
        case TypeKind.boolean:
        case TypeKind.enumeration:
        case TypeKind.bitfield:
          return _unboundedArrayMapping(elemMap);
        default:
          return TypeMapping.unsupported(
            'array of ${elemMap.kind} (later phase)',
          );
      }
    }
    final name = type.name;
    if (name != null && _unsupportedNames.contains(name)) {
      return TypeMapping.unsupported('unsupported C type: $name');
    }
    if (name != null) {
      final builtin = _byGirName[name];
      if (builtin != null) return builtin;
    }
    // Try the namespace lookup *before* falling back to the c-type
    // primitive map. Many GLib APIs declare `<type name="GObject.Object"
    // c:type="gpointer"/>` for backward compatibility — the GIR name
    // resolves to the GObject class but the c-type matches the primitive
    // `gpointer` mapping. Previously the c-type won and emitted
    // `Pointer<ffi.Void>`; the implements-clause plan (T2) needs the
    // canonical typed name (`GObject?`) so the override signature
    // matches across interface and implementing class.
    if (name != null && name.isNotEmpty) {
      final found = _lookup(name, currentNamespace);
      if (found != null) {
        final (declaredIn, target) = found;
        final requiredImport =
            identical(declaredIn, currentNamespace) ||
                declaredIn.name == currentNamespace.name
            ? null
            : packageNameFor(declaredIn);
        final dartName = name.contains('.') ? name.split('.').last : name;

        TypeMapping mappingFor(TypeKind kind) => TypeMapping(
          dartType: dartName,
          nativeType: 'Pointer<ffi.Void>',
          kind: kind,
          isPointer: true,
          requiredImport: requiredImport,
        );

        switch (target) {
          case GirClass():
            return mappingFor(TypeKind.classType);
          case GirInterface():
            return mappingFor(TypeKind.interface);
          case GirRecord():
            return mappingFor(TypeKind.record);
          case GirUnion():
            return mappingFor(TypeKind.union);
          case GirCallback():
            return mappingFor(TypeKind.callback);
          case GirBitfield():
            return TypeMapping(
              dartType: dartName,
              nativeType: 'ffi.Uint32',
              kind: TypeKind.bitfield,
              requiredImport: requiredImport,
            );
          case GirEnum():
            return TypeMapping(
              dartType: dartName,
              nativeType: 'ffi.Int32',
              kind: TypeKind.enumeration,
              requiredImport: requiredImport,
            );
          case GirAlias(target: final aliasTarget):
            return resolve(aliasTarget, currentNamespace: currentNamespace);
        }
        return TypeMapping.unsupported('unknown type: $name');
      }
    }
    final cType = type.cType;
    if (cType != null) {
      final builtin = _byCType[cType];
      if (builtin != null) return builtin;
    }
    if (name == null || name.isEmpty) {
      return TypeMapping.unsupported(
        'no GIR name${cType != null ? ' (c:type $cType)' : ''}',
      );
    }
    return TypeMapping.unsupported('unknown type: $name');
  }

  /// The public Dart type name for [type] (class name only; callers use
  /// [TypeMapping.requiredImport] to add the import prefix).
  String dartTypeName(
    GirTypeRef type, {
    required GirNamespace currentNamespace,
  }) => resolve(type, currentNamespace: currentNamespace).dartType;

  /// Finds [name] (qualified `Ns.Type` or unqualified `Type`) in the
  /// current namespace first, then all other loaded namespaces.
  (GirNamespace, Object)? _lookup(String name, GirNamespace current) {
    if (name.contains('.')) {
      final dot = name.indexOf('.');
      final nsName = name.substring(0, dot);
      final typeName = name.substring(dot + 1);
      for (final ns in namespaces) {
        if (ns.name == nsName) {
          final found = _findIn(ns, typeName);
          if (found != null) return (ns, found);
          return null;
        }
      }
      return null;
    }
    final inCurrent = _findIn(current, name);
    if (inCurrent != null) return (current, inCurrent);
    for (final ns in namespaces) {
      if (identical(ns, current) || ns.name == current.name) continue;
      final found = _findIn(ns, name);
      if (found != null) return (ns, found);
    }
    return null;
  }

  Object? _findIn(GirNamespace ns, String name) {
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
}
