/// Emits top-level namespace functions and constants.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart';
import 'async_emitter.dart';
import 'callable.dart';
import 'context.dart';

/// Top-level namespace functions and constants.
class FunctionEmitter {
  FunctionEmitter(this.ctx);

  final EmitContext ctx;

  /// Public Dart name for a namespace function: lowerCamel of the C symbol
  /// minus the namespace symbol prefix (`g_utf8_strlen` → `utf8Strlen`).
  String publicName(GirFunction fn) {
    final cId = fn.cIdentifier;
    if (cId != null) {
      final prefixes = [...ctx.namespace.cSymbolPrefixes]
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final prefix in prefixes) {
        if (prefix.isNotEmpty && cId.startsWith('${prefix}_')) {
          return toLowerCamel(cId.substring(prefix.length + 1));
        }
      }
    }
    return toLowerCamel(fn.name);
  }

  /// Returns the base namespace-function wrapper (today's emission).
  /// Returns null when the function is skipped (the caller records the
  /// reason in the report).
  String? emitFunction(GirFunction fn) {
    var name = escapeKeyword(publicName(fn));
    if (name.isEmpty) {
      ctx.report.skip('function', fn.name, 'empty public name');
      return null;
    }
    if (!ctx.claimName(name)) {
      final alt = '${name}Fn';
      if (!ctx.claimName(alt)) {
        ctx.report.skip('function', fn.name, 'name collision: $name');
        return null;
      }
      name = alt;
    }
    return CallableEmitter(ctx)
        .emit(fn, dartName: name, ownerName: ctx.namespace.name);
  }

  /// Returns the lifetime-safe `*Callback` convenience overload for
  /// async namespace functions, when applicable. Returns null when
  /// there is no async callback or the callback type isn't a
  /// `GAsyncReadyCallback`. The caller is responsible for collecting
  /// the result and ensuring the name doesn't collide.
  String? emitAsyncFunctionOverload(GirFunction fn, String baseDartName) {
    if (!fn.parameters.any((p) => p.scope == 'async')) return null;
    return AsyncCallbackEmitter(ctx).emitFunctionOverload(
      fn,
      dartName: baseDartName,
      ownerName: ctx.namespace.name,
      nativeBindingName: '_${toLowerCamel(fn.cIdentifier!)}',
    );
  }

  /// Constants become top-level `const` when the value is a primitive int,
  /// double, or string literal whose type is `utf8`/`filename` in GIR.
  /// Everything else is skipped.
  String? emitConstant(GirConstant c) {
    final label = '${ctx.namespace.name}.${c.name}';
    final value = c.value;
    if (value == null) {
      ctx.report.skip('constant', label, 'no value');
      return null;
    }
    final m = ctx.resolve(c.type ?? const GirTypeRef());
    final String literal;
    switch (m.kind) {
      case TypeKind.primitive:
        if (m.dartType == 'int') {
          var v = value.trim();
          // Strip C literal suffixes (u, l, ul...) and parenthesisation.
          v = v.replaceAll(RegExp(r'[uUlL]+$'), '');
          if (v.startsWith('(') && v.endsWith(')')) {
            v = v.substring(1, v.length - 1).trim();
          }
          if (int.tryParse(v) == null) {
            ctx.report.skip('constant', label, 'unparseable int value: $value');
            return null;
          }
          literal = v;
        } else if (m.dartType == 'double') {
          var v = value.trim();
          v = v.replaceAll(RegExp(r'[fF]$'), '');
          if (double.tryParse(v) == null) {
            ctx.report.skip(
                'constant', label, 'unparseable double value: $value');
            return null;
          }
          if (!v.contains('.') && !v.contains('e') && !v.contains('E')) {
            v = '$v.0';
          }
          literal = v;
        } else {
          ctx.report.skip(
              'constant', label, 'unsupported primitive type ${m.dartType}');
          return null;
        }
      case TypeKind.string:
        literal = _dartStringLiteral(value);
      case TypeKind.boolean:
        switch (value.trim().toLowerCase()) {
          case 'true':
          case '1':
            literal = 'true';
          case 'false':
          case '0':
            literal = 'false';
          default:
            ctx.report.skip(
                'constant', label, 'unparseable boolean value: $value');
            return null;
        }
      default:
        ctx.report.skip('constant', label, 'non-primitive type');
        return null;
    }
    var name = escapeKeyword(toLowerCamel(c.name));
    if (!ctx.claimName(name)) {
      ctx.report.skip('constant', label, 'name collision: $name');
      return null;
    }
    final b = StringBuffer();
    for (final line in ctx.docLines(c.doc)) {
      b.writeln(line);
    }
    b.write('const $name = $literal;');
    return b.toString();
  }

  /// Renders a GIR string-literal constant value as a Dart single-quoted
  /// string literal. GIR values are stored verbatim — including any C-style
  /// escape sequences — so we re-emit them with Dart-compatible escapes:
  /// known C escapes (`\n`, `\r`, `\t`, `\"`, `\\`) become their Dart
  /// equivalents, and any other `\X` pair is preserved literally by doubling
  /// the backslash (so `"\U"` in GIR becomes `'\\U'` in Dart, which Dart
  /// parses as the two characters `\` and `U`).
  static String _dartStringLiteral(String raw) {
    final b = StringBuffer("'");
    var i = 0;
    while (i < raw.length) {
      final c = raw[i];
      if (c == r'\' && i + 1 < raw.length) {
        final next = raw[i + 1];
        switch (next) {
          case 'n':
            b.write(r'\n');
          case 'r':
            b.write(r'\r');
          case 't':
            b.write(r'\t');
          case r'\':
            b.write(r'\\');
          default:
            // Preserve the literal backslash and the following character.
            b.write(r'\\');
            b.write(next);
        }
        i += 2;
        continue;
      }
      // Escape literal single quotes so the result is a single-quoted literal.
      if (c == "'") {
        b.write(r"\'");
        i++;
        continue;
      }
      // Replace literal newlines with their escape (a raw newline would
      // terminate the single-quoted Dart literal).
      if (c == '\n') {
        b.write(r'\n');
        i++;
        continue;
      }
      // Dart strings honour `$expr` interpolation in all quoted forms, so a
      // literal `$` must be escaped to `\$` to round-trip.
      if (c == r'$') {
        b.write(r'\$');
        i++;
        continue;
      }
      b.write(c);
      i++;
    }
    b.write("'");
    return b.toString();
  }
}
