/// Snake-case helper used by the visitor to derive .ui ids from
/// Dart field/method names when the annotation's explicit name
/// parameter is empty.
library;

/// Converts [camel] (camelCase or PascalCase) to snake_case. Handles
/// consecutive capitals (e.g. `URLPath` → `url_path`).
String toSnakeCase(String camel) {
  if (camel.isEmpty) return camel;
  final buf = StringBuffer();
  for (var i = 0; i < camel.length; i++) {
    final c = camel[i];
    final code = c.codeUnitAt(0);
    final isUpper = code >= 0x41 && code <= 0x5A;
    if (isUpper) {
      // Insert an underscore before an uppercase letter when it
      // follows a lowercase letter, or when it follows an
      // uppercase letter and is followed by a lowercase letter
      // (handles `URLPath` → `url_path`).
      final prev = i > 0 ? camel[i - 1] : '';
      final next = i + 1 < camel.length ? camel[i + 1] : '';
      final prevIsLower =
          prev.codeUnitAt(0) >= 0x61 && prev.codeUnitAt(0) <= 0x7A;
      final prevIsUpper =
          prev.codeUnitAt(0) >= 0x41 && prev.codeUnitAt(0) <= 0x5A;
      final nextIsLower =
          next.codeUnitAt(0) >= 0x61 && next.codeUnitAt(0) <= 0x7A;
      final needsUnderscore = (i > 0 &&
              ((prevIsLower) || (prevIsUpper && nextIsLower))) ||
          (i == 0);
      if (needsUnderscore && buf.isNotEmpty) buf.write('_');
      buf.write(c.toLowerCase());
    } else {
      buf.write(c);
    }
  }
  return buf.toString();
}