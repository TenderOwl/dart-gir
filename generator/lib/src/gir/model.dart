/// Immutable data model for GObject-Introspection (GIR) repositories.
library;

/// Transfer ownership annotation for return values and parameters.
enum GirTransferOwnership { none, container, full }

/// Direction of a callable parameter.
enum GirParameterDirection { in_, out, inout }

/// The varargs pseudo-parameter of a variadic callable.
const String girVarargsName = '...';

String? _emptyToNull(String? s) => (s == null || s.isEmpty) ? null : s;

/// Root of a parsed .gir file.
class GirRepository {
  GirRepository({required this.namespace, List<GirInclude>? includes})
    : includes = List.unmodifiable(includes ?? const []);

  final GirNamespace namespace;
  final List<GirInclude> includes;
}

class GirInclude {
  const GirInclude({required this.name, required this.version});

  final String name;
  final String version;

  String get key => '$name-$version';

  @override
  String toString() => key;
}

/// A `<namespace>` element: the unit of declarations in a repository.
class GirNamespace {
  GirNamespace({
    required this.name,
    required this.version,
    String? sharedLibrary,
    this.cIdentifierPrefixes = const [],
    this.cSymbolPrefixes = const [],
    List<GirAlias>? aliases,
    List<GirClass>? classes,
    List<GirInterface>? interfaces,
    List<GirRecord>? records,
    List<GirUnion>? unions,
    List<GirEnum>? enumerations,
    List<GirBitfield>? bitfields,
    List<GirCallback>? callbacks,
    List<GirFunction>? functions,
    List<GirConstant>? constants,
  }) : sharedLibraries = List.unmodifiable(
         (sharedLibrary ?? '')
             .split(',')
             .map((s) => s.trim())
             .where((s) => s.isNotEmpty),
       ),
       aliases = List.unmodifiable(aliases ?? const []),
       classes = List.unmodifiable(classes ?? const []),
       interfaces = List.unmodifiable(interfaces ?? const []),
       records = List.unmodifiable(records ?? const []),
       unions = List.unmodifiable(unions ?? const []),
       enumerations = List.unmodifiable(enumerations ?? const []),
       bitfields = List.unmodifiable(bitfields ?? const []),
       callbacks = List.unmodifiable(callbacks ?? const []),
       functions = List.unmodifiable(functions ?? const []),
       constants = List.unmodifiable(constants ?? const []);

  final String name;
  final String version;
  final List<String> sharedLibraries;
  final List<String> cIdentifierPrefixes;
  final List<String> cSymbolPrefixes;
  final List<GirAlias> aliases;
  final List<GirClass> classes;
  final List<GirInterface> interfaces;
  final List<GirRecord> records;
  final List<GirUnion> unions;
  final List<GirEnum> enumerations;
  final List<GirBitfield> bitfields;
  final List<GirCallback> callbacks;
  final List<GirFunction> functions;
  final List<GirConstant> constants;
}

/// A reference to a type, from a `<type>` element.
///
/// Arrays are modelled as a [GirTypeRef] whose [array] field carries the
/// array metadata (length parameter index, zero-terminated flag) and whose
/// own [name]/[cType] describe the array as a whole; the element type lives
/// in [GirArrayInfo.elementType].
class GirTypeRef {
  const GirTypeRef({this.name, this.cType, this.array});

  final String? name;
  final String? cType;

  /// Non-null when this type is an `<array>`.
  final GirArrayInfo? array;

  bool get isArray => array != null;

  @override
  String toString() =>
      'GirTypeRef($name${array != null ? '[]' : ''}${cType != null ? ', c:$cType' : ''})';
}

/// Array metadata carried by [GirTypeRef.array].
class GirArrayInfo {
  const GirArrayInfo({
    this.lengthParameterIndex,
    this.zeroTerminated = false,
    required this.elementType,
  });

  final int? lengthParameterIndex;
  final bool zeroTerminated;
  final GirTypeRef elementType;
}

/// Common base for callables: functions, methods, constructors, callbacks.
abstract class GirCallable {
  GirCallable({
    required this.name,
    this.cIdentifier,
    this.returnType,
    this.returnTransfer = GirTransferOwnership.none,
    this.returnNullable = false,
    List<GirParameter>? parameters,
    this.throws = false,
    this.deprecated = false,
    this.version,
    this.doc,
    this.introspectable = true,
  }) : parameters = List.unmodifiable(parameters ?? const []);

  final String name;
  final String? cIdentifier;
  final GirTypeRef? returnType;
  final GirTransferOwnership returnTransfer;
  final bool returnNullable;
  final List<GirParameter> parameters;
  final bool throws;
  final bool deprecated;
  final String? version;
  final String? doc;

  /// Whether the GIR marks this callable `introspectable="0"`/`"false"`.
  /// Non-introspectable callables are C macros whose real symbol is the
  /// `shadowed-by`/`shadows` sibling — the parser still parses them so
  /// the emitter can record an explanatory skip, but no Dart wrapper
  /// is emitted.
  final bool introspectable;

  /// The varargs marker parameter, if this callable is variadic.
  GirParameter? get varargsParameter {
    for (final p in parameters) {
      if (p.isVarargs) return p;
    }
    return null;
  }

  bool get isVarargs => varargsParameter != null;
}

class GirFunction extends GirCallable {
  GirFunction({
    required super.name,
    super.cIdentifier,
    super.returnType,
    super.returnTransfer,
    super.returnNullable,
    super.parameters,
    super.throws,
    super.deprecated,
    super.version,
    super.doc,
    super.introspectable,
    this.shadows,
    this.shadowedBy,
    this.movedTo,
  });

  /// Raw `shadows` / `shadowed-by` / `moved-to` attribute values, kept for
  /// the resolver.
  final String? shadows;
  final String? shadowedBy;
  final String? movedTo;
}

class GirMethod extends GirFunction {
  GirMethod({
    required super.name,
    super.cIdentifier,
    super.returnType,
    super.returnTransfer,
    super.returnNullable,
    super.parameters,
    super.throws,
    super.deprecated,
    super.version,
    super.doc,
    super.introspectable,
    super.shadows,
    super.shadowedBy,
    super.movedTo,
    this.finishFunc,
    this.instanceParameter,
  });

  /// `glib:finish-func="..."` value when this method is the async half
  /// of a GIO-style `*_async` + `*_finish` pair. The `_finish` sibling
  /// is conventionally named `<methodName>Finish` and lives on the
  /// same class/record.
  final String? finishFunc;

  /// The `this`/`self` instance parameter, when present.
  final GirParameter? instanceParameter;
}

class GirConstructor extends GirFunction {
  GirConstructor({
    required super.name,
    super.cIdentifier,
    super.returnType,
    super.returnTransfer,
    super.returnNullable,
    super.parameters,
    super.throws,
    super.deprecated,
    super.version,
    super.doc,
    super.introspectable,
    super.shadows,
    super.shadowedBy,
  });
}

class GirParameter {
  const GirParameter({
    required this.name,
    this.direction = GirParameterDirection.in_,
    this.type,
    this.nullable = false,
    this.transferOwnership = GirTransferOwnership.none,
    this.optional = false,
    this.callerAllocates = false,
    this.isVarargs = false,
    this.scope,
    this.closureIndex,
    this.doc,
  });

  final String name;
  final GirParameterDirection direction;
  final GirTypeRef? type;
  final bool nullable;
  final GirTransferOwnership transferOwnership;
  final bool optional;
  final bool callerAllocates;
  final bool isVarargs;

  /// `scope="..."` attribute value. GLib uses `"async"` for callback
  /// parameters that survive past the call (dispatched by the main
  /// loop), `"call"` for synchronous callbacks, `"notified"` for
  /// `GDestroyNotify`-style parameters, and `null`/absent for plain
  /// data parameters.
  final String? scope;

  /// `closure="N"` attribute value (1-based positional index of the
  /// user_data parameter that carries the closure's state for this
  /// callback). `null` when this parameter is not itself a callback
  /// carrying user_data.
  final int? closureIndex;

  final String? doc;
}

class GirProperty {
  const GirProperty({
    required this.name,
    this.type,
    this.readable = true,
    this.writable = false,
    this.deprecated = false,
    this.version,
    this.doc,
    this.getter,
    this.setter,
    this.transferOwnership = GirTransferOwnership.none,
  });

  final String name;
  final GirTypeRef? type;
  final bool readable;
  final bool writable;
  final bool deprecated;
  final String? version;
  final String? doc;

  /// GIR `getter="..."` attribute — the C function backing the read
  /// accessor (e.g. `get_label` for the `label` property). When set,
  /// the property accessor in the generated `props` class delegates
  /// to the existing typed `get<Name>()` instance method.
  final String? getter;

  /// GIR `setter="..."` attribute — the C function backing the write
  /// accessor (e.g. `set_label`). Delegates to the existing typed
  /// `set<Name>(value)` instance method.
  final String? setter;

  /// `transfer-ownership` for the property's value (the getter's
  /// return value). Mirrors the value on the backing `<method>`
  /// element; carried here for convenience so the props layer can
  /// reason about string ownership without re-resolving the method.
  final GirTransferOwnership transferOwnership;
}

class GirSignal {
  GirSignal({
    required this.name,
    this.returnType,
    List<GirParameter>? parameters,
    this.deprecated = false,
    this.version,
    this.doc,
  }) : parameters = List.unmodifiable(parameters ?? const []);

  final String name;
  final GirTypeRef? returnType;
  final List<GirParameter> parameters;
  final bool deprecated;
  final String? version;
  final String? doc;
}

class GirField {
  const GirField({
    required this.name,
    this.type,
    this.readable = true,
    this.writable = true,
    this.doc,
  });

  final String name;
  final GirTypeRef? type;
  final bool readable;
  final bool writable;
  final String? doc;
}

class GirAlias {
  const GirAlias({
    required this.name,
    this.cType,
    required this.target,
    this.doc,
  });

  final String name;
  final String? cType;
  final GirTypeRef target;
  final String? doc;
}

class GirConstant {
  const GirConstant({
    required this.name,
    this.type,
    this.value,
    this.cType,
    this.deprecated = false,
    this.version,
    this.doc,
  });

  final String name;
  final GirTypeRef? type;
  final String? value;
  final String? cType;
  final bool deprecated;
  final String? version;
  final String? doc;
}

/// Shared base for class-like declarations holding members.
abstract class GirRegisteredType {
  GirRegisteredType({
    required this.name,
    this.cType,
    this.deprecated = false,
    this.version,
    this.doc,
  });

  final String name;
  final String? cType;
  final bool deprecated;
  final String? version;
  final String? doc;
}

class GirClass extends GirRegisteredType {
  GirClass({
    required super.name,
    super.cType,
    this.glibTypeName,
    this.glibGetValueFunc,
    this.parent,
    this.abstract = false,
    this.final_ = false,
    List<String>? implements_,
    List<GirConstructor>? constructors,
    List<GirMethod>? methods,
    List<GirFunction>? functions,
    List<GirMethod>? virtualMethods,
    List<GirProperty>? properties,
    List<GirSignal>? signals,
    List<GirField>? fields,
    super.deprecated,
    super.version,
    super.doc,
  }) : implements_ = List.unmodifiable(implements_ ?? const []),
       constructors = List.unmodifiable(constructors ?? const []),
       methods = List.unmodifiable(methods ?? const []),
       functions = List.unmodifiable(functions ?? const []),
       virtualMethods = List.unmodifiable(virtualMethods ?? const []),
       properties = List.unmodifiable(properties ?? const []),
       signals = List.unmodifiable(signals ?? const []),
       fields = List.unmodifiable(fields ?? const []);

  final String? glibTypeName;
  final String? glibGetValueFunc;

  /// Name of the parent type, e.g. `Gtk.Widget` or `Widget`.
  final String? parent;
  final bool abstract;
  final bool final_;
  final List<String> implements_;
  final List<GirConstructor> constructors;
  final List<GirMethod> methods;
  final List<GirFunction> functions;
  final List<GirMethod> virtualMethods;
  final List<GirProperty> properties;
  final List<GirSignal> signals;
  final List<GirField> fields;
}

class GirInterface extends GirRegisteredType {
  GirInterface({
    required super.name,
    super.cType,
    this.glibTypeName,
    List<GirMethod>? methods,
    List<GirFunction>? functions,
    List<GirMethod>? virtualMethods,
    List<GirProperty>? properties,
    List<GirSignal>? signals,
    super.deprecated,
    super.version,
    super.doc,
  }) : methods = List.unmodifiable(methods ?? const []),
       functions = List.unmodifiable(functions ?? const []),
       virtualMethods = List.unmodifiable(virtualMethods ?? const []),
       properties = List.unmodifiable(properties ?? const []),
       signals = List.unmodifiable(signals ?? const []);

  final String? glibTypeName;
  final List<GirMethod> methods;
  final List<GirFunction> functions;
  final List<GirMethod> virtualMethods;
  final List<GirProperty> properties;
  final List<GirSignal> signals;
}

class GirRecord extends GirRegisteredType {
  GirRecord({
    required super.name,
    super.cType,
    this.glibTypeName,
    this.disguised = false,
    List<GirField>? fields,
    List<GirConstructor>? constructors,
    List<GirMethod>? methods,
    List<GirFunction>? functions,
    super.deprecated,
    super.version,
    super.doc,
  }) : fields = List.unmodifiable(fields ?? const []),
       constructors = List.unmodifiable(constructors ?? const []),
       methods = List.unmodifiable(methods ?? const []),
       functions = List.unmodifiable(functions ?? const []);

  /// Non-null when the record is a boxed type (`glib:is-gtype-struct-for`
  /// absent and `glib:type-name` present).
  final String? glibTypeName;
  final bool disguised;
  final List<GirField> fields;
  final List<GirConstructor> constructors;
  final List<GirMethod> methods;
  final List<GirFunction> functions;

  bool get isBoxed => glibTypeName != null;
}

class GirUnion extends GirRegisteredType {
  GirUnion({
    required super.name,
    super.cType,
    this.glibTypeName,
    List<GirField>? fields,
    List<GirConstructor>? constructors,
    List<GirMethod>? methods,
    List<GirFunction>? functions,
    super.deprecated,
    super.version,
    super.doc,
  }) : fields = List.unmodifiable(fields ?? const []),
       constructors = List.unmodifiable(constructors ?? const []),
       methods = List.unmodifiable(methods ?? const []),
       functions = List.unmodifiable(functions ?? const []);

  final String? glibTypeName;
  final List<GirField> fields;
  final List<GirConstructor> constructors;
  final List<GirMethod> methods;
  final List<GirFunction> functions;
}

class GirEnum extends GirRegisteredType {
  GirEnum({
    required super.name,
    super.cType,
    this.glibTypeName,
    List<GirEnumMember>? members,
    List<GirFunction>? functions,
    List<GirMethod>? methods,
    super.deprecated,
    super.version,
    super.doc,
  }) : members = List.unmodifiable(members ?? const []),
       functions = List.unmodifiable(functions ?? const []),
       methods = List.unmodifiable(methods ?? const []);

  final String? glibTypeName;
  final List<GirEnumMember> members;
  final List<GirFunction> functions;
  final List<GirMethod> methods;
}

/// Bitfield (flags) enumeration. Same shape as [GirEnum]; the subclass lets
/// emitters distinguish flags from plain enumerations.
class GirBitfield extends GirEnum {
  GirBitfield({
    required super.name,
    super.cType,
    super.glibTypeName,
    super.members,
    super.functions,
    super.methods,
    super.deprecated,
    super.version,
    super.doc,
  });
}

class GirEnumMember {
  const GirEnumMember({
    required this.name,
    required this.value,
    this.cIdentifier,
    this.deprecated = false,
    this.version,
    this.doc,
  });

  final String name;
  final int value;
  final String? cIdentifier;
  final bool deprecated;
  final String? version;
  final String? doc;
}

class GirCallback extends GirCallable {
  GirCallback({
    required super.name,
    super.cIdentifier,
    super.returnType,
    super.returnTransfer,
    super.returnNullable,
    super.parameters,
    super.throws,
    super.deprecated,
    super.version,
    super.doc,
    super.introspectable,
    this.cType,
  });

  final String? cType;
}

/// Helper for subclasses in this library.
String? normalizeEmpty(String? s) => _emptyToNull(s);
