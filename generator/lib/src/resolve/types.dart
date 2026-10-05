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

    final found = _lookup(name, currentNamespace);
    if (found == null) {
      return TypeMapping.unsupported('unknown type: $name');
    }
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
