/// Emits Dart enums and bitfield classes from GIR enumerations.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import 'callable.dart';
import 'context.dart';

/// Emits [GirEnum] → Dart enum and [GirBitfield] → flags class.
class EnumEmitter {
  EnumEmitter(this.ctx);

  final EmitContext ctx;

  /// Converts a C type name to its CONSTANT_CASE prefix:
  /// `GFileTest` → `G_FILE_TEST`, `GIOCondition` → `G_IO_CONDITION`.
  static String constCase(String input) {
    final hump = RegExp(r'[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+|\d+');
    final words = hump.allMatches(input).map((m) => m.group(0)!).toList();
    if (words.isEmpty) return input.toUpperCase();
    return words.map((w) => w.toUpperCase()).join('_');
  }

  String? emit(GirEnum e) {
    if (e is GirBitfield) return emitBitfield(e);
    final dartName = ctx.dartTypeName(ctx.namespace.name, e.name);
    if (ctx.isDuplicateType(e)) {
      ctx.report.skip(
          'enum', dartName, 'duplicate declaration owned by an earlier namespace');
      return null;
    }
    if (e.members.isEmpty) {
      ctx.report.skip('enum', dartName, 'no members');
      return null;
    }
    if (!ctx.claimName(dartName)) {
      ctx.report.skip('enum', dartName, 'name collision');
      return null;
    }
    final typePrefix = _typePrefix(e, dartName);
    final usedNames = <String>{};
    final usedValues = <int>{};
    final members = <(String, int)>[];
    for (final m in e.members) {
      var name = CallableEmitter.safeMemberName(escapeKeyword(
          enumValueName(m.cIdentifier ?? m.name, typePrefix: typePrefix)));
      if (name.isEmpty || !_isIdentifierStart(name)) name = valueName(m.value);
      if (!usedNames.add(name)) name = '$name${m.value}';
      usedNames.add(name);
      members.add((name, m.value));
    }
    final b = StringBuffer();
    for (final line in ctx.docLines(e.doc)) {
      b.writeln(line);
    }
    b.writeln('enum $dartName {');
    for (final (name, value) in members) {
      b.writeln('$name($value),');
    }
    b.writeln(';');
    b.writeln('const $dartName(this.value);');
    b.writeln('final int value;');
    b.writeln();
    b.writeln(
        'static $dartName fromValue(int value) => switch (value) {');
    for (final (name, value) in members) {
      if (usedValues.add(value)) {
        b.writeln('$value => $name,');
      }
    }
    b.writeln(
        "_ => throw ArgumentError.value(value, 'value', 'Unknown $dartName value'),");
    b.writeln('};');
    b.write('}');
    return b.toString();
  }

  String? emitBitfield(GirBitfield e) {
    final dartName = ctx.dartTypeName(ctx.namespace.name, e.name);
    if (ctx.isDuplicateType(e)) {
      ctx.report.skip('bitfield', dartName,
          'duplicate declaration owned by an earlier namespace');
      return null;
    }
    if (e.members.isEmpty) {
      ctx.report.skip('bitfield', dartName, 'no members');
      return null;
    }
    if (!ctx.claimName(dartName)) {
      ctx.report.skip('bitfield', dartName, 'name collision');
      return null;
    }
    final typePrefix = _typePrefix(e, dartName);
    final usedNames = <String>{};
    final b = StringBuffer();
    for (final line in ctx.docLines(e.doc)) {
      b.writeln(line);
    }
    b.writeln('final class $dartName {');
    b.writeln('const $dartName(this.value);');
    b.writeln('final int value;');
    b.writeln();
    for (final m in e.members) {
      for (final line in ctx.docLines(m.doc)) {
        b.writeln(line);
      }
      var name = CallableEmitter.safeMemberName(escapeKeyword(
          enumValueName(m.cIdentifier ?? m.name, typePrefix: typePrefix)));
      if (name.isEmpty || !_isIdentifierStart(name)) name = valueName(m.value);
      if (!usedNames.add(name)) name = '$name${m.value}';
      b.writeln('static const $dartName $name = $dartName(${m.value});');
    }
    b.writeln();
    b.writeln(
        '$dartName operator |($dartName other) => $dartName(value | other.value);');
    b.writeln(
        '$dartName operator &($dartName other) => $dartName(value & other.value);');
    b.writeln();
    b.writeln('@override');
    b.writeln(
        'bool operator ==(Object other) => other is $dartName && other.value == value;');
    b.writeln('@override');
    b.writeln('int get hashCode => value.hashCode;');
    b.writeln('@override');
    b.writeln("String toString() => '$dartName(\$value)';");
    b.write('}');
    return b.toString();
  }

  static bool _isIdentifierStart(String s) =>
      s.isNotEmpty && RegExp(r'[a-zA-Z_]').hasMatch(s[0]);

  /// The C identifier prefix shared by all members (e.g. `G_IO_FLAGS`).
  /// Prefers the CONSTANT_CASE of the C type name; falls back to the longest
  /// common member prefix cut at the last underscore.
  static String _typePrefix(GirEnum e, String dartName) {
    final cc = constCase(e.cType ?? dartName);
    final ids = [
      for (final m in e.members)
        if (m.cIdentifier != null) m.cIdentifier!,
    ];
    if (ids.isEmpty || ids.every((id) => id.startsWith('${cc}_'))) return cc;
    var prefix = ids.first;
    for (final id in ids.skip(1)) {
      while (!id.startsWith(prefix) && prefix.isNotEmpty) {
        prefix = prefix.substring(0, prefix.length - 1);
      }
    }
    final idx = prefix.lastIndexOf('_');
    if (idx > 0) {
      final candidate = prefix.substring(0, idx);
      if (ids.every((id) => id.startsWith('${candidate}_'))) return candidate;
    }
    return cc;
  }

  static String valueName(int value) =>
      value < 0 ? 'minus${-value}' : 'v$value';
}
