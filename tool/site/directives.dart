// Block directives for the site generator.
//
// Markdown cannot express the dossier's bespoke blocks, so a small set of
// fenced containers is supported — the Python-Markdown "container" syntax:
//
//     :::{note} Ownership
//     Text of the note.
//     :::
//
// The header carries a name, an optional label and optional `key=value`
// attributes:
//
//     :::{phase status=done} Phase 0 — Generator foundation
//
// The label is the first bare word after the name; everything that looks
// like `key=value` is an attribute. This file only knows about the
// *syntax*; the rendering lives in `components.dart`.

/// The names the site generator knows how to render.
const Set<String> kKnownDirectives = <String>{
  'note',
  'figure',
  'kv',
  'checklist',
  'phase',
  'cols',
  'meta',
  'packages',
};

/// A parsed `:::{name} label key=value` header.
class DirectiveHeader {
  const DirectiveHeader(this.name, this.label, this.attributes);

  /// The directive name, e.g. `note`.
  final String name;

  /// The optional human label, e.g. `Ownership`.
  final String? label;

  /// The optional `key=value` attributes.
  final Map<String, String> attributes;

  /// The attribute value for [key], or `null`.
  String? attribute(String key) => attributes[key];
}

/// Parses a `:::{name} …` header line.
///
/// The attributes may sit inside the braces (`:::{note variant=warn}`) or
/// after them (`:::{note} variant=warn`); both spellings are accepted.
/// A bare word that is not a `key=value` pair is the label.
///
/// Throws a [FormatException] when the line is not a directive header or
/// when the name is not one of [kKnownDirectives].
DirectiveHeader parseDirectiveHeader(String line) {
  final match = RegExp(r'^\s*:::\{([A-Za-z0-9_-]+)([^}]*)\}\s*(.*?)\s*$')
      .firstMatch(line);
  if (match == null) {
    throw FormatException('not a directive header: "$line"');
  }
  final name = match.group(1)!;
  if (!kKnownDirectives.contains(name)) {
    throw FormatException(
      'unknown directive "$name" — known directives are '
      '${(kKnownDirectives.toList()..sort()).join(', ')}',
    );
  }
  final attributes = <String, String>{};
  final labelParts = <String>[];
  for (final source in <String>[match.group(2)!, match.group(3)!]) {
    for (final token in _splitTokens(source)) {
      final equals = token.indexOf('=');
      if (equals > 0) {
        attributes[token.substring(0, equals)] = _unquote(
          token.substring(equals + 1),
        );
      } else {
        labelParts.add(token);
      }
    }
  }
  final label = labelParts.isEmpty ? null : labelParts.join(' ');
  return DirectiveHeader(name, label, attributes);
}

/// Splits on whitespace, keeping quoted runs together.
List<String> _splitTokens(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (quote.isNotEmpty) {
      if (ch == quote) {
        quote = '';
      } else {
        buffer.write(ch);
      }
      continue;
    }
    // A quote opens a quoted run when it starts a token or follows a
    // `key=` — an apostrophe inside a word ("the project's API") is a
    // literal.
    if ((ch == '"' || ch == "'") &&
        (buffer.isEmpty || buffer.toString().endsWith('='))) {
      quote = ch;
      continue;
    }
    if (ch == ' ' || ch == '\t') {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(ch);
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  return tokens;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
