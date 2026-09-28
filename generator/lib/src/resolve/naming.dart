/// Dart naming-convention utilities used by the resolver and emitters.
library;

/// Splits [input] into words on `_`, `-`, and whitespace, then further
/// splits on camelCase humps and acronym boundaries (`HTMLParser` →
/// `HTML`, `Parser`). Internal digits are preserved (`h264` stays `h264`,
/// `ISO123Code` splits to `ISO123`, `Code`).
List<String> _words(String input) {
  final raw = input
      .split(RegExp(r'[_\-\s]+'))
      .where((w) => w.isNotEmpty);
  final words = <String>[];
  final hump = RegExp(
    r'[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+|\d+',
  );
  for (final part in raw) {
    final matches = hump.allMatches(part).map((m) => m.group(0)!).toList();
    if (matches.isEmpty) {
      words.add(part);
    } else {
      words.addAll(matches);
    }
  }
  return words;
}

String _capitalize(String word) => word.isEmpty
    ? word
    : word[0].toUpperCase() + word.substring(1).toLowerCase();

/// Converts any C-style or Dart-style identifier to lowerCamelCase.
///
/// Handles snake_case, kebab-case, ALL_CAPS and existing camelCase:
/// `set_label` → `setLabel`, `GTK_ALIGN_FILL` → `gtkAlignFill`,
/// `alreadyCamel` → `alreadyCamel`.
String toLowerCamel(String input) {
  final words = _words(input);
  if (words.isEmpty) return input;
  final first = words.first.toLowerCase();
  return first + words.skip(1).map(_capitalize).join();
}

/// Converts any C-style or Dart-style identifier to UpperCamelCase.
String toUpperCamel(String input) {
  final words = _words(input);
  if (words.isEmpty) return input;
  return words.map(_capitalize).join();
}

/// Derives a Dart enum value name from a C enumerator identifier.
///
/// Strips the enum type's C prefix: `GTK_ALIGN_FILL` with typePrefix
/// `GTK_ALIGN` → `fill`, `G_FILE_TEST_EXISTS` with `G_FILE_TEST` →
/// `exists`. Members that do not share the prefix are converted as-is.
String enumValueName(String cIdentifier, {required String typePrefix}) {
  var rest = cIdentifier;
  if (typePrefix.isNotEmpty && cIdentifier.startsWith('${typePrefix}_')) {
    rest = cIdentifier.substring(typePrefix.length + 1);
  }
  if (rest.isEmpty) rest = cIdentifier;
  return toLowerCamel(rest);
}

/// Identifiers that cannot be used directly as Dart member/parameter names:
/// reserved words plus built-in identifiers that would shadow or break.
const Set<String> _dartReserved = {
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
  'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
  'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'for', 'function',
  'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
  'late', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator', 'out',
  'part', 'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
  'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'type',
  'typedef', 'var', 'void', 'when', 'while', 'with', 'yield',
};

/// Escapes Dart reserved words by appending a single trailing underscore:
/// `in` → `in_`, `default` → `default_`. Names already ending with `_`
/// are left unchanged. Non-reserved names pass through untouched.
String escapeKeyword(String name) {
  if (!_dartReserved.contains(name)) return name;
  return name.endsWith('_') ? name : '${name}_';
}

/// Converts a Dart type name to a snake_case file name:
/// `GtkButton` → `gtk_button.dart`, `GFileInputStream` →
/// `g_file_input_stream.dart`.
String dartFileName(String typeName) {
  final words = _words(typeName);
  if (words.isEmpty) return '${typeName.toLowerCase()}.dart';
  return '${words.map((w) => w.toLowerCase()).join('_')}.dart';
}

/// Strips a leading C identifier prefix from [name] (e.g. `G` from
/// `GObject` → `Object` when prefixes contains `G`).
///
/// Used for file names and documentation display only — Dart type names
/// keep their prefix to avoid collisions. Returns [name] unchanged when
/// no prefix matches or stripping would leave an empty string.
String stripNsPrefix(String name, List<String> cIdentifierPrefixes) {
  for (final prefix in cIdentifierPrefixes) {
    if (prefix.isNotEmpty &&
        name.startsWith(prefix) &&
        name.length > prefix.length) {
      return name.substring(prefix.length);
    }
  }
  return name;
}
