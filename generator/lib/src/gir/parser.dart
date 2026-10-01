import 'dart:io';

import 'package:xml/xml.dart';

import 'model.dart';

const String girCoreNamespace = 'http://www.gtk.org/introspection/core/1.0';
const String girCNamespace = 'http://www.gtk.org/introspection/c/1.0';
const String girGlibNamespace = 'http://www.gtk.org/introspection/glib/1.0';

/// Parses GIR XML documents into the [GirRepository] model.
class GirParser {
  GirRepository parseFile(String path) =>
      parse(File(path).readAsStringSync());

  GirRepository parse(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final repository = doc.rootElement;
    final includes = <GirInclude>[];
    GirNamespace? namespace;

    for (final child in repository.childElements) {
      if (!_isCore(child)) continue;
      switch (child.name.local) {
        case 'include':
          includes.add(GirInclude(
            name: child.getAttribute('name') ?? '',
            version: child.getAttribute('version') ?? '',
          ));
        case 'namespace':
          namespace = _parseNamespace(child);
      }
    }

    if (namespace == null) {
      throw const FormatException('GIR repository has no <namespace>');
    }
    return GirRepository(namespace: namespace, includes: includes);
  }

  // -- namespace-level declarations ----------------------------------------

  GirNamespace _parseNamespace(XmlElement ns) {
    final aliases = <GirAlias>[];
    final classes = <GirClass>[];
    final interfaces = <GirInterface>[];
    final records = <GirRecord>[];
    final unions = <GirUnion>[];
    final enumerations = <GirEnum>[];
    final bitfields = <GirBitfield>[];
    final callbacks = <GirCallback>[];
    final functions = <GirFunction>[];
    final constants = <GirConstant>[];

    for (final child in ns.childElements) {
      if (!_isCore(child)) continue;
      // GIR marks C convenience macros (g_idle_add, g_array_new, …) as
      // introspectable="0" because they expand to the canonical sibling. We
      // still parse them so `CallableEmitter` can emit a precise skip entry
      // naming the canonical sibling, instead of silently dropping them.
      final isFunction = child.name.local == 'function';
      if (!isFunction && !_introspectable(child)) continue;
      switch (child.name.local) {
        case 'alias':
          aliases.add(_parseAlias(child));
        case 'class':
          classes.add(_parseClass(child));
        case 'interface':
          interfaces.add(_parseInterface(child));
        case 'record':
          // `glib:is-gtype-struct-for` records are class vtable structs;
          // keep them as plain records.
          records.add(_parseRecord(child));
        case 'union':
          unions.add(_parseUnion(child));
        case 'enumeration':
          enumerations.add(_parseEnum(child));
        case 'bitfield':
          bitfields.add(_parseBitfield(child));
        case 'callback':
          callbacks.add(_parseCallback(child));
        case 'function':
          functions.add(_parseFunction(child));
        case 'constant':
          constants.add(_parseConstant(child));
      }
    }

    List<String> prefixes(String? attr) => (attr ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return GirNamespace(
      name: ns.getAttribute('name') ?? '',
      version: ns.getAttribute('version') ?? '',
      sharedLibrary: ns.getAttribute('shared-library'),
      cIdentifierPrefixes:
          prefixes(ns.getAttribute('identifier-prefixes', namespace: girCNamespace)),
      cSymbolPrefixes:
          prefixes(ns.getAttribute('symbol-prefixes', namespace: girCNamespace)),
      aliases: aliases,
      classes: classes,
      interfaces: interfaces,
      records: records,
      unions: unions,
      enumerations: enumerations,
      bitfields: bitfields,
      callbacks: callbacks,
      functions: functions,
      constants: constants,
    );
  }

  GirAlias _parseAlias(XmlElement e) => GirAlias(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        target: _parseType(e) ?? const GirTypeRef(),
        doc: _doc(e),
      );

  GirConstant _parseConstant(XmlElement e) => GirConstant(
        name: _name(e),
        type: _parseType(e),
        value: e.getAttribute('value'),
        cType: _cAttr(e, 'type'),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirClass _parseClass(XmlElement e) => GirClass(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        glibTypeName: _glibAttr(e, 'type-name'),
        glibGetValueFunc: _glibAttr(e, 'get-value-func'),
        parent: e.getAttribute('parent'),
        abstract: _bool(e, 'abstract'),
        final_: _bool(e, 'final'),
        implements_: [
          for (final impl in _coreChildren(e, 'implements'))
            ?impl.getAttribute('name'),
        ],
        constructors: _coreChildren(e, 'constructor').map(_parseConstructor).toList(),
        methods: _coreChildren(e, 'method').map(_parseMethod).toList(),
        functions: _coreChildren(e, 'function').map(_parseFunction).toList(),
        virtualMethods:
            _coreChildren(e, 'virtual-method').map(_parseMethod).toList(),
        properties: _coreChildren(e, 'property').map(_parseProperty).toList(),
        signals: _children(e, 'signal', girGlibNamespace)
            .map(_parseSignal)
            .toList(),
        fields: _coreChildren(e, 'field').map(_parseField).toList(),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirInterface _parseInterface(XmlElement e) => GirInterface(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        glibTypeName: _glibAttr(e, 'type-name'),
        methods: _coreChildren(e, 'method').map(_parseMethod).toList(),
        functions: _coreChildren(e, 'function').map(_parseFunction).toList(),
        virtualMethods:
            _coreChildren(e, 'virtual-method').map(_parseMethod).toList(),
        properties: _coreChildren(e, 'property').map(_parseProperty).toList(),
        signals: _children(e, 'signal', girGlibNamespace).map(_parseSignal).toList(),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirRecord _parseRecord(XmlElement e) => GirRecord(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        glibTypeName: _glibAttr(e, 'type-name'),
        disguised: _bool(e, 'disguised'),
        fields: _coreChildren(e, 'field').map(_parseField).toList(),
        constructors: _coreChildren(e, 'constructor').map(_parseConstructor).toList(),
        methods: _coreChildren(e, 'method').map(_parseMethod).toList(),
        functions: _coreChildren(e, 'function').map(_parseFunction).toList(),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirUnion _parseUnion(XmlElement e) => GirUnion(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        glibTypeName: _glibAttr(e, 'type-name'),
        fields: _coreChildren(e, 'field').map(_parseField).toList(),
        constructors: _coreChildren(e, 'constructor').map(_parseConstructor).toList(),
        methods: _coreChildren(e, 'method').map(_parseMethod).toList(),
        functions: _coreChildren(e, 'function').map(_parseFunction).toList(),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirEnum _parseEnum(XmlElement e) => GirEnum(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        glibTypeName: _glibAttr(e, 'type-name'),
        members: _coreChildren(e, 'member').map(_parseEnumMember).toList(),
        functions: _coreChildren(e, 'function').map(_parseFunction).toList(),
        methods: _coreChildren(e, 'method').map(_parseMethod).toList(),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirBitfield _parseBitfield(XmlElement e) => GirBitfield(
        name: _name(e),
        cType: _cAttr(e, 'type'),
        glibTypeName: _glibAttr(e, 'type-name'),
        members: _coreChildren(e, 'member').map(_parseEnumMember).toList(),
        functions: _coreChildren(e, 'function').map(_parseFunction).toList(),
        methods: _coreChildren(e, 'method').map(_parseMethod).toList(),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirEnumMember _parseEnumMember(XmlElement e) => GirEnumMember(
        name: _name(e),
        value: int.tryParse(e.getAttribute('value') ?? '') ?? 0,
        cIdentifier: _cAttr(e, 'identifier'),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirCallback _parseCallback(XmlElement e) {
    final (returnType, transfer, nullable) = _parseReturnValue(e);
    return GirCallback(
      name: _name(e),
      cType: _cAttr(e, 'type'),
      returnType: returnType,
      returnTransfer: transfer,
      returnNullable: nullable,
      parameters: _parseParameters(e),
      throws: _bool(e, 'throws'),
      deprecated: _bool(e, 'deprecated'),
      version: e.getAttribute('version'),
      introspectable: _introspectable(e),
      doc: _doc(e),
    );
  }

  // -- callables ------------------------------------------------------------

  GirFunction _parseFunction(XmlElement e) {
    final (returnType, transfer, nullable) = _parseReturnValue(e);
    return GirFunction(
      name: _name(e),
      cIdentifier: _cAttr(e, 'identifier'),
      returnType: returnType,
      returnTransfer: transfer,
      returnNullable: nullable,
      parameters: _parseParameters(e),
      throws: _bool(e, 'throws'),
      deprecated: _bool(e, 'deprecated'),
      version: e.getAttribute('version'),
      introspectable: _introspectable(e),
      shadows: e.getAttribute('shadows'),
      shadowedBy: e.getAttribute('shadowed-by'),
      movedTo: e.getAttribute('moved-to'),
      doc: _doc(e),
    );
  }

  GirMethod _parseMethod(XmlElement e) {
    final (returnType, transfer, nullable) = _parseReturnValue(e);
    return GirMethod(
      name: _name(e),
      cIdentifier: _cAttr(e, 'identifier'),
      returnType: returnType,
      returnTransfer: transfer,
      returnNullable: nullable,
      parameters: _parseParameters(e),
      instanceParameter: _parseInstanceParameter(e),
      throws: _bool(e, 'throws'),
      deprecated: _bool(e, 'deprecated'),
      version: e.getAttribute('version'),
      introspectable: _introspectable(e),
      shadows: e.getAttribute('shadows'),
      shadowedBy: e.getAttribute('shadowed-by'),
      finishFunc:
          e.getAttribute('finish-func', namespace: girGlibNamespace),
      doc: _doc(e),
    );
  }

  GirConstructor _parseConstructor(XmlElement e) {
    final (returnType, transfer, nullable) = _parseReturnValue(e);
    return GirConstructor(
      name: _name(e),
      cIdentifier: _cAttr(e, 'identifier'),
      returnType: returnType,
      returnTransfer: transfer,
      returnNullable: nullable,
      parameters: _parseParameters(e),
      throws: _bool(e, 'throws'),
      deprecated: _bool(e, 'deprecated'),
      version: e.getAttribute('version'),
      introspectable: _introspectable(e),
      shadows: e.getAttribute('shadows'),
      shadowedBy: e.getAttribute('shadowed-by'),
      doc: _doc(e),
    );
  }

  (GirTypeRef?, GirTransferOwnership, bool) _parseReturnValue(XmlElement e) {
    final rv = _coreChildren(e, 'return-value').firstOrNull;
    if (rv == null) return (null, GirTransferOwnership.none, false);
    return (
      _parseType(rv),
      _transfer(rv.getAttribute('transfer-ownership')),
      _bool(rv, 'nullable') || _bool(rv, 'allow-none'),
    );
  }

  List<GirParameter> _parseParameters(XmlElement e) {
    final paramsEl = _coreChildren(e, 'parameters').firstOrNull;
    if (paramsEl == null) return const [];
    final result = <GirParameter>[];
    for (final p in paramsEl.childElements) {
      if (!_isCore(p) || !_introspectable(p)) continue;
      if (p.name.local == 'varargs') {
        result.add(const GirParameter(
          name: girVarargsName,
          isVarargs: true,
        ));
      } else if (p.name.local == 'parameter') {
        result.add(_parseParameter(p));
      }
    }
    return result;
  }

  GirParameter? _parseInstanceParameter(XmlElement e) {
    final paramsEl = _coreChildren(e, 'parameters').firstOrNull;
    if (paramsEl == null) return null;
    final el = _coreChildren(paramsEl, 'instance-parameter').firstOrNull;
    if (el == null) return null;
    return _parseParameter(el);
  }

  GirParameter _parseParameter(XmlElement e) => GirParameter(
        name: _name(e),
        direction: switch (e.getAttribute('direction')) {
          'out' => GirParameterDirection.out,
          'inout' => GirParameterDirection.inout,
          _ => GirParameterDirection.in_,
        },
        type: _parseType(e),
        nullable: _bool(e, 'nullable') || _bool(e, 'allow-none'),
        transferOwnership: _transfer(e.getAttribute('transfer-ownership')),
        optional: _bool(e, 'optional'),
        callerAllocates: _bool(e, 'caller-allocates'),
        scope: e.getAttribute('scope'),
        closureIndex: _int(e, 'closure'),
        doc: _doc(e),
      );

  GirProperty _parseProperty(XmlElement e) => GirProperty(
        name: _name(e),
        type: _parseType(e),
        readable: _bool(e, 'readable', defaultValue: true),
        writable: _bool(e, 'writable'),
        deprecated: _bool(e, 'deprecated'),
        version: e.getAttribute('version'),
        doc: _doc(e),
      );

  GirSignal _parseSignal(XmlElement e) {
    final rv = _coreChildren(e, 'return-value').firstOrNull;
    return GirSignal(
      name: _name(e),
      returnType: rv == null ? null : _parseType(rv),
      parameters: _parseParameters(e),
      deprecated: _bool(e, 'deprecated'),
      version: e.getAttribute('version'),
      doc: _doc(e),
    );
  }

  GirField _parseField(XmlElement e) => GirField(
        name: _name(e),
        type: _parseType(e),
        readable: _bool(e, 'readable', defaultValue: true),
        writable: _bool(e, 'writable', defaultValue: true),
        doc: _doc(e),
      );

  // -- types ----------------------------------------------------------------

  /// Finds the first `<type>` or `<array>` child and builds a [GirTypeRef].
  /// An `<array>` becomes a [GirTypeRef] with [GirTypeRef.array] set.
  GirTypeRef? _parseType(XmlElement parent) {
    for (final child in parent.childElements) {
      if (!_isCore(child)) continue;
      if (child.name.local == 'type') {
        return GirTypeRef(
          name: child.getAttribute('name'),
          cType: _cAttr(child, 'type'),
        );
      }
      if (child.name.local == 'array') {
        final element = _parseType(child) ?? const GirTypeRef();
        return GirTypeRef(
          name: child.getAttribute('name'),
          cType: _cAttr(child, 'type'),
          array: GirArrayInfo(
            lengthParameterIndex:
                int.tryParse(child.getAttribute('length') ?? ''),
            zeroTerminated: _bool(child, 'zero-terminated', defaultValue: true),
            elementType: element,
          ),
        );
      }
    }
    return null;
  }

  // -- helpers ---------------------------------------------------------------

  bool _isCore(XmlElement e) =>
      e.name.namespaceUri == null || e.name.namespaceUri == girCoreNamespace;

  bool _introspectable(XmlElement e) =>
      e.getAttribute('introspectable') != '0' &&
      e.getAttribute('introspectable') != 'false';

  String _name(XmlElement e) => e.getAttribute('name') ?? '';

  String? _cAttr(XmlElement e, String local) =>
      e.getAttribute(local, namespace: girCNamespace) ?? e.getAttribute('c:$local');

  String? _glibAttr(XmlElement e, String local) =>
      e.getAttribute(local, namespace: girGlibNamespace) ??
      e.getAttribute('glib:$local');

  bool _bool(XmlElement e, String attr, {bool defaultValue = false}) {
    final v = e.getAttribute(attr);
    if (v == null) return defaultValue;
    return v == '1' || v == 'true';
  }

  int? _int(XmlElement e, String attr) {
    final v = e.getAttribute(attr);
    if (v == null) return null;
    return int.tryParse(v);
  }

  GirTransferOwnership _transfer(String? v) => switch (v) {
        'full' => GirTransferOwnership.full,
        'container' => GirTransferOwnership.container,
        _ => GirTransferOwnership.none,
      };

  List<XmlElement> _coreChildren(XmlElement e, String local) => [
        for (final c in e.childElements)
          if (_isCore(c) && c.name.local == local && _introspectable(c)) c,
      ];

  List<XmlElement> _children(XmlElement e, String local, String ns) => [
        for (final c in e.childElements)
          if (c.name.local == local &&
              c.name.namespaceUri == ns &&
              _introspectable(c))
            c,
      ];

  String? _doc(XmlElement e) {
    for (final c in e.childElements) {
      if (_isCore(c) && c.name.local == 'doc') {
        final text = c.innerText.trim();
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }
}
