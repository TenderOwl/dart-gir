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
  countedString,

  /// A pointer to a string array the *callee* allocates — a `gchar ***`.
  stringArrayPointer,
  unsupported,
}

/// The natural element type of a GIR array.
///
/// The GIR writes the element of a callee-allocated array with one extra
/// star; see [TypeResolver.arrayElementShape] for the rule and for why
/// it matters.
class ArrayElementShape {
  const ArrayElementShape({
    required this.name,
    required this.cType,
    required this.isHandle,
  });

  /// The GIR name of the element — `gdouble`, `FontFamily`, `LogAttr`.
  final String name;

  /// The C type of one element — `double`, `PangoFontFamily *`.
  final String cType;

  /// `true` when the element is a *pointer*: the array holds pointers,
  /// and the wrapper wraps what they point at instead of copying a
  /// value out of the array.
  final bool isHandle;
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

  /// Package that must be imported to use [dartType], e.g. `gir_gtk4`.
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
///
/// Every name carries the `gir_` prefix: the bare names (`glib`, `gio`,
/// `cairo`, `graphene`) are taken on pub.dev by other publishers, so the
/// prefix is what makes the whole set publishable.
String packageNameFor(GirNamespace namespace) {
  const core = {
    'GLib': 'gir_glib',
    'GObject': 'gir_gobject',
    'Gio': 'gir_gio',
    'GdkPixbuf': 'gir_gdk_pixbuf',
    'cairo': 'gir_cairo',
    'Pango': 'gir_pango',
    'Gdk': 'gir_gdk4',
    'Gtk': 'gir_gtk4',
    'Adw': 'gir_adw',
    'Graphene': 'gir_graphene',
    'Gsk': 'gir_gsk4',
  };
  final known = core[namespace.name];
  if (known != null) return known;

  final base = _snakeCase(namespace.name).toLowerCase();
  final major = namespace.version.split('.').first;
  if (major.isEmpty || major == '0') return 'gir_$base';
  return 'gir_$base$major';
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
    // The POSIX types the GIR names but does not describe. The widths are
    // the LP64 Linux ones — `time_t` is a `long`, `pid_t` an `int` and
    // `uid_t` an `unsigned int`. The GIR carries no width, so a platform
    // with a different `time_t` would need the mapping revisited; the
    // bindings target Linux.
    'time_t': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int64',
      kind: TypeKind.primitive,
    ),
    'pid_t': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Int32',
      kind: TypeKind.primitive,
    ),
    'uid_t': TypeMapping(
      dartType: 'int',
      nativeType: 'ffi.Uint32',
      kind: TypeKind.primitive,
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
  ///
  /// [lengthIdx] is the GIR's length binding: the 0-based index of the
  /// sibling parameter that carries the count. It is `null` for the
  /// NULL-terminated arrays and *may* name a parameter that does not
  /// exist — GLib's GIR writes a length binding for arrays that have no
  /// count at all — so the caller checks it against the parameter list.
  static TypeMapping _stringListMapping(int? lengthIdx) => TypeMapping(
    dartType: 'List<String?>?',
    nativeType: 'ffi.Pointer<ffi.Pointer<Utf8>>',
    kind: TypeKind.stringList,
    isPointer: true,
    arrayLengthParameter: lengthIdx,
  );

  /// Mapping for a *single* string whose byte length a sibling parameter
  /// carries — GLib's `(string, length)` pair, which `g_regex_match_full`
  /// and its siblings use.
  ///
  /// The C side reads `length` *bytes*, so the string may contain a NUL and
  /// the count is part of the contract. The wrapper derives the count from
  /// the string it marshals, so the sibling parameter is absorbed.
  static TypeMapping _countedStringMapping(int lengthIdx) => TypeMapping(
    dartType: 'String',
    nativeType: 'ffi.Pointer<Utf8>',
    kind: TypeKind.countedString,
    isPointer: true,
    arrayLengthParameter: lengthIdx,
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
    // `GStrv` is GLib's own typedef for `gchar **`.
    'GStrv',
  };

  /// `c:type` strings of the GLib *containers* an array can be.
  ///
  /// These are not C arrays: the pointer addresses a `GPtrArray`, a
  /// `GList` or the like, and the elements are reached through the
  /// container's own API. A `char **` is a plain array of pointers and
  /// can be marshalled; a `GPtrArray *` cannot.
  static const Set<String> _glibContainerCtypes = {
    'GPtrArray*',
    'GArray*',
    'GList*',
    'GSList*',
    'GHashTable*',
    'GVariant*',
  };

  /// Whether [type] is an argv-style array of strings we can marshal.
  ///
  /// The C ABI for `gchar**` and `const gchar* const*` is identical on every
  /// platform we target (the `const` is a C-level qualifier that does not
  /// change the pointer representation), so we accept both.
  ///
  /// A *bound* array — one whose `<array length="N">` names a sibling
  /// parameter that carries the count — is accepted too: the C side reads
  /// exactly N slots rather than scanning for a NULL terminator, and the
  /// emitter absorbs the count parameter and passes the list's length.
  /// Whether the binding names a real parameter is checked by the caller,
  /// which has the parameter list; GLib's GIR writes a length binding for
  /// arrays that carry no count at all.
  static bool isStringListArray(GirTypeRef type) {
    final array = type.array;
    if (array == null) return false;
    final cType = type.cType;
    if (cType == null || !_stringListCtypes.contains(cType)) return false;
    final elem = array.elementType;
    final elemName = elem.name;
    return elemName == 'utf8' ||
        elemName == 'filename' ||
        elem.cType == 'gchar*';
  }

  /// `c:type` spellings for a *single* string that carries an explicit
  /// length — GLib's `(string, length)` pair.
  static const Set<String> _countedStringCtypes = {
    'gchar*',
    'const gchar*',
    'char*',
    'const char*',
  };

  /// Whether [type] is a single string whose **byte** length a sibling
  /// parameter carries.
  ///
  /// GLib's GIR models `g_regex_match_full`'s `(string, string_len)` pair
  /// as an array of one string with a length binding: the C side reads
  /// `string_len` bytes, so the count is part of the contract and the
  /// string may contain a NUL.
  static bool isCountedString(GirTypeRef type) {
    final array = type.array;
    if (array == null) return false;
    final lengthIdx = array.lengthParameterIndex;
    if (lengthIdx == null || lengthIdx <= 0) return false;
    final cType = type.cType;
    if (cType == null || !_countedStringCtypes.contains(cType)) return false;
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

  /// Whether [p] is an OUT parameter holding a **NUL-terminated** byte
  /// buffer the callee allocates.
  ///
  /// The shape is `gchar **` with `transfer-ownership="full"` and *no*
  /// length binding: the C function allocates the buffer, terminates it
  /// with a NUL, and nothing in the signature states its size. The
  /// wrapper measures the buffer with `strlen` and hands the caller a
  /// `String`.
  ///
  /// This is the shape of `g_spawn_sync`'s `standard_output`.
  static bool isNulTerminatedByteBufferOut(
    GirTypeRef? ref, {
    required GirTransferOwnership transfer,
    required GirParameterDirection direction,
    required bool callerAllocates,
  }) {
    if (direction != GirParameterDirection.out) return false;
    // `caller-allocates="0"` — the callee allocates the buffer.
    if (callerAllocates) return false;
    // The caller owns the buffer and has to release it.
    if (transfer != GirTransferOwnership.full) return false;
    final array = ref?.array;
    if (array == null) return false;
    final cType = ref!.cType;
    // `gchar **` — the callee writes the buffer pointer into the slot.
    if (cType != 'gchar**' && cType != 'char**') return false;
    if (!_byteNames.contains(array.elementType.name)) return false;
    // A length binding would give the exact size; this shape has none.
    return array.lengthParameterIndex == null && array.fixedSize == null;
  }

  /// Whether [ref] is the `end` shape of `g_utf8_validate`.
  ///
  /// The GIR declares `const gchar **end` as an out parameter of bytes,
  /// but the C signature writes a *pointer into the input string* — the
  /// end of the valid data. There is no buffer to copy, and nothing to
  /// release.
  static bool isBorrowedEndPointer(
    GirTypeRef? ref,
    GirTransferOwnership transfer,
  ) {
    if (transfer != GirTransferOwnership.none) return false;
    final cType = ref?.cType;
    return cType == 'const gchar**' || cType == 'const char**';
  }

  /// Whether [ref] is the `out` shape of `g_base64_encode_step`.
  ///
  /// The GIR declares `gchar *out` as a callee-allocated out parameter,
  /// but the C signature takes a *caller-provided* buffer: the caller
  /// sizes it — from the length of the input — and the function writes
  /// the encoded bytes into it. The GIR's `transfer-ownership="full"`
  /// says the opposite, and no size appears anywhere in the signature.
  static bool isCallerProvidedBufferOut(
    GirTypeRef? ref,
    GirTransferOwnership transfer,
  ) {
    if (transfer != GirTransferOwnership.full) return false;
    final cType = ref?.cType;
    return cType == 'gchar*' || cType == 'char*';
  }

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

  /// The natural element type of a GIR array.
  ///
  /// The GIR writes the element type of a **callee-allocated** array with
  /// one extra star — `PangoFontFamily **` for an array of
  /// `PangoFontFamily *`, `double *` for an array of `double` — while a
  /// **caller-allocated** array names the element directly (`float` for
  /// `float[2]`, `PangoLogAttr` for `PangoLogAttr[5]`). The natural
  /// element type is therefore the element's `c:type` with one star
  /// removed, but only for the callee-allocated shape.
  ///
  /// The distinction matters because it decides what the wrapper has to
  /// copy out of the native array: a *handle* element (a pointer to an
  /// object or a record) is wrapped, a *value* element is copied.
  static ArrayElementShape? arrayElementShape(
    GirTypeRef ref, {
    required bool callerAllocates,
  }) {
    final array = ref.array;
    if (array == null) return null;
    final elem = array.elementType;
    final cType = elem.cType;
    if (cType == null || cType.isEmpty) return null;
    final natural = callerAllocates ? cType : _stripStar(cType);
    if (natural.isEmpty) return null;
    return ArrayElementShape(
      name: elem.name ?? '',
      cType: natural,
      // The element is a handle when the natural type is a pointer: the
      // array holds pointers, and the wrapper wraps what they point at
      // instead of copying a value.
      isHandle: natural.endsWith('*'),
    );
  }

  /// Removes one trailing star from a C type.
  static String _stripStar(String cType) =>
      cType.endsWith('*') ? cType.substring(0, cType.length - 1) : cType;

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

  /// Whether [p] is a **caller-provided byte buffer the callee fills**.
  ///
  /// The GIR marks such a parameter `direction="out"` because the callee
  /// writes into it, but `caller-allocates="1"` says the *storage* is the
  /// caller's. This is the shape of `g_input_stream_read`'s `buffer` and
  /// its `gsize count`, of `g_socket_receive`'s `buffer` and its `gsize
  /// size`, and of `g_io_channel_read_chars`' `buf`.
  ///
  /// From the Dart side the parameter is an *input*: the caller hands
  /// over a `Uint8List` and the callee fills it. The byte count is the
  /// list's length, so the count parameter is absorbed.
  static bool isCallerProvidedByteBuffer(
    GirParameter p,
    List<GirParameter> siblings,
  ) {
    if (p.direction != GirParameterDirection.out) return false;
    if (!p.callerAllocates) return false;
    if (!isByteArrayElement(p.type)) return false;
    final array = p.type!.array!;
    final lengthIdx = array.lengthParameterIndex;
    if (lengthIdx == null || lengthIdx <= 0) return false;
    if (lengthIdx >= siblings.length) return false;
    final length = siblings[lengthIdx];
    if (length.direction != GirParameterDirection.in_) return false;
    if (!_byteLengthNames.contains(length.type?.name)) return false;
    return true;
  }

  /// The GIR names accepted for the length sibling of a string array or
  /// a counted string.
  ///
  /// The count the C side reads is an integer — the number of elements of
  /// a `char **`, or the number of *bytes* of a counted string.
  static const Set<String> _stringLengthNames = {
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

  /// The 0-based index of the parameter that carries the length of [p],
  /// when [p] is a string array or a counted string whose count a
  /// sibling parameter carries.
  ///
  /// Returns `null` when there is no such binding. That is the case for
  /// the NULL-terminated arrays — the C side scans for the terminator, so
  /// there is no count to absorb — and for a binding that does not name
  /// a usable IN integer.
  ///
  /// [siblings] is the callable's full parameter list: the GIR's
  /// `<array length="N">` index is the 0-based position of the count
  /// parameter in it, with the instance parameter left out.
  static int? stringCountBinding(GirParameter p, List<GirParameter> siblings) {
    if (p.direction != GirParameterDirection.in_) return null;
    final type = p.type;
    if (type == null) return null;
    final isList = isStringListArray(type);
    // A counted string is a string with a length binding; a string list
    // is an array of strings. The two never overlap — the C types differ
    // (`gchar*` against `gchar**`).
    if (!isList && !isCountedString(type)) return null;
    final lengthIdx = type.array?.lengthParameterIndex;
    // `length="0"` marks an array that is not length-bound — the GIR
    // convention for NUL-terminated arrays.
    if (lengthIdx == null || lengthIdx <= 0) return null;
    if (lengthIdx >= siblings.length) return null;
    final length = siblings[lengthIdx];
    if (length.direction != GirParameterDirection.in_) return null;
    if (!_stringLengthNames.contains(length.type?.name)) return null;
    return lengthIdx;
  }

  /// The 0-based index of the OUT parameter that carries the element
  /// count of a `char **` *return*, when the GIR binds the two together.
  ///
  /// The GIR binds a callee-allocated string array to the parameter that
  /// holds its count: `g_key_file_get_string_list` and its `gsize
  /// *length`, `g_irepository_enumerate_versions` and its `gint
  /// *n_versions_out`. The count is read out of the OUT slot the callee
  /// filled, and the array is read for exactly that many elements.
  ///
  /// Returns `null` when the array carries no count — the wrapper reads
  /// it until its NULL terminator instead.
  static int? stringListReturnCountIndex(
    GirTypeRef type,
    List<GirParameter> siblings,
  ) {
    if (!isStringListArray(type)) return null;
    final lengthIdx = type.array?.lengthParameterIndex;
    if (lengthIdx == null || lengthIdx <= 0) return null;
    if (lengthIdx >= siblings.length) return null;
    final length = siblings[lengthIdx];
    if (length.direction != GirParameterDirection.out) return null;
    if (!_stringLengthNames.contains(length.type?.name)) return null;
    return lengthIdx;
  }

  /// `c:type` strings of a *pointer to* a string array — a `gchar ***`.
  ///
  /// The C function allocates the `gchar **` and writes its address into
  /// the caller's slot: `g_shell_parse_argv`'s `argvp`,
  /// `g_settings_schema_source_list_schemas`' `non_relocatable`.
  static const Set<String> _stringArrayPointerCtypes = {
    'gchar***',
    'const gchar***',
  };

  /// Whether [ref] is a pointer to a string array the *callee* allocates.
  ///
  /// The GIR models `gchar **` parameters as
  /// `<array c:type="gchar***"><type name="utf8" c:type="gchar**"/></array>`
  /// — the array's element is a `gchar **`, and the whole thing is a
  /// pointer to it. The callee allocates the array and writes its
  /// address into the caller's slot.
  static bool isStringArrayPointer(GirTypeRef ref) {
    final array = ref.array;
    if (array == null) return false;
    final cType = ref.cType;
    if (cType == null || !_stringArrayPointerCtypes.contains(cType)) {
      return false;
    }
    final elem = array.elementType;
    if (elem.cType == 'gchar**' || elem.cType == 'const gchar**') return true;
    // The GIR sometimes omits the element's `c:type` — the array's own
    // `gchar ***` already says the element is a `gchar **`.
    if (elem.cType == null) {
      return elem.name == 'utf8' || elem.name == 'filename';
    }
    return false;
  }

  /// The inout parameters whose C type is a pointer to a *pointer*.
  ///
  /// The GIR spells these inconsistently — `g_once_init_enter`'s
  /// `location` is a `gpointer *` in C but `void*` in the GIR, and
  /// `g_irepository_base_info_iterate_attributes`' `iterator` is a
  /// `GIAttributeIter **` in C but `GIAttributeIter*` in the GIR — so
  /// the table is keyed by the pair (GIR type name, `c:type`).
  ///
  /// The callee allocates the pointee there and hands it over; a wrapper
  /// would have to release memory it did not allocate. These stay
  /// skipped, with the reason naming the shape.
  static const Set<(String, String)> _inoutPointerToPointer = {
    ('Error', 'GError**'),
    ('utf8', 'const char**'),
    ('gpointer', 'gpointer*'),
    ('gpointer', 'void*'),
    ('AttributeIter', 'GIAttributeIter*'),
  };

  /// Whether [p] is an inout parameter whose C type is a pointer to a
  /// *pointer* — the callee allocates the pointee.
  static bool isInoutPointerToPointer(GirParameter p) {
    if (p.direction != GirParameterDirection.inout) return false;
    final type = p.type;
    if (type == null) return false;
    final array = type.array;
    if (array != null) {
      // A `char ***` — a pointer to a pointer to a string array.
      final cType = type.cType;
      return cType == 'char***' || cType == 'gchar***';
    }
    final name = type.name;
    final cType = type.cType;
    if (name == null || cType == null) return false;
    return _inoutPointerToPointer.contains((name, cType));
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
      if (isCallerProvidedByteBuffer(p, fn.parameters) && !isAsync(fn)) {
        continue;
      }
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

  /// The C function that takes a reference of its own, when [type] uses
  /// *floating* references.
  ///
  /// A type uses floating references when the GIR's `copy-function` is a
  /// *sink* function — `g_variant_ref_sink` for `GVariant`. A floating
  /// reference belongs to nobody: the value a constructor hands over is
  /// floating, and a value somebody else owns can only be reached
  /// through a reference of your own. The GIR names the sink as the
  /// type's copy function, because that is the function that does both
  /// — it sinks a floating reference and adds one to a reference that is
  /// already owned.
  ///
  /// The sink must be a method of the type: the bindings call it
  /// through the wrapper. A type that does not declare it keeps the
  /// plain reference semantics — the bindings never guess a symbol name.
  static String? floatingReferenceCopyFunction(GirRegisteredType type) {
    final copy = switch (type) {
      GirRecord r => r.copyFunction,
      GirUnion u => u.copyFunction,
      _ => null,
    };
    if (copy == null || !copy.endsWith('_ref_sink')) return null;
    final methods = switch (type) {
      GirRecord r => r.methods,
      GirUnion u => u.methods,
      _ => const <GirMethod>[],
    };
    final declared = {for (final m in methods) m.cIdentifier};
    if (!declared.contains(copy)) return null;
    return copy;
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
      if (isStringListArray(type)) {
        return _stringListMapping(type.array!.lengthParameterIndex);
      }
      if (isCountedString(type)) {
        return _countedStringMapping(type.array!.lengthParameterIndex!);
      }
      if (isStringArrayPointer(type)) {
        // A `gchar ***`: the callee allocates the `gchar **` and writes
        // its address into the caller's slot. The emitter handles the
        // OUT direction of this shape.
        return const TypeMapping(
          dartType: 'List<String>?',
          nativeType: 'ffi.Pointer<ffi.Pointer<ffi.Pointer<Utf8>>>',
          kind: TypeKind.stringArrayPointer,
          isPointer: true,
        );
      }
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
          case TypeKind.union:
            return const TypeMapping.unsupported(
              'array of unions: the union layout is not emitted',
            );
          default:
            return TypeMapping.unsupported(
              'array of ${elemMap.kind}: no Dart mapping for the element',
            );
        }
      }
      // Unbound array: the C side reads whatever the caller provides.
      // Only primitive/enum element types make sense without an explicit
      // length — anything more complex stays unsupported.
      if (type.cType != null && _glibContainerCtypes.contains(type.cType)) {
        return TypeMapping.unsupported(
          'array of ${type.cType}: a GLib container, not a C array',
        );
      }
      switch (elemMap.kind) {
        case TypeKind.primitive:
        case TypeKind.boolean:
        case TypeKind.enumeration:
        case TypeKind.bitfield:
          return _unboundedArrayMapping(elemMap);
        case TypeKind.union:
          return const TypeMapping.unsupported(
            'array of unions: the union layout is not emitted',
          );
        default:
          return TypeMapping.unsupported(
            'unbound array of ${elemMap.kind}: the signature carries no length',
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
