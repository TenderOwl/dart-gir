// Front-matter parsing for the site's Markdown page sources.
//
// A page may start with a front-matter block:
//
//     ---
//     title: Features
//     nav_order: 2
//     nav_label: Features
//     ---
//
//     Body of the page.
//
// The block is a flat `key: value` list — deliberately smaller than YAML,
// so the generator stays dependency-free (there is no `package:yaml` in
// the workspace, and adding one would force a re-resolution that breaks
// `dart test`; see the note in `tool/build_api_docs.dart`).

/// A parsed front-matter block plus the body that follows it.
class FrontMatter {
  const FrontMatter(this.values, this.body);

  /// The front-matter keys, in the order they appeared.
  final Map<String, String> values;

  /// The page source with the front-matter block removed.
  final String body;

  /// The value for [key], or `null`.
  String? operator [](String key) => values[key];

  /// The page title — also the visible `h1`.
  String get title => values['title'] ?? '';

  /// The browser title. Falls back to [title].
  String get docTitle => values['doc_title'] ?? title;

  /// The meta description.
  String get description => values['description'] ?? '';

  /// The navigation label. Falls back to [title].
  String get navLabel => values['nav_label'] ?? title;

  /// The navigation position. Pages without one sort last, by label.
  int get navOrder {
    final raw = values['nav_order'];
    final parsed = int.tryParse(raw ?? '');
    return parsed ?? 1 << 30;
  }

  /// The kicker line shown above the `h1`.
  String get sectionLabel => values['section_label'] ?? '';

  /// The `og:type` meta value.
  String get ogType => values['og_type'] ?? 'website';
}

/// Parses [source] into its front matter and body.
///
/// A source without a front-matter block yields empty values and the
/// source unchanged.
FrontMatter parseFrontMatter(String source) {
  final text = source.replaceAll('\r\n', '\n');
  if (!text.startsWith('---\n')) {
    return FrontMatter(const <String, String>{}, text);
  }
  final lines = text.split('\n');
  var end = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      end = i;
      break;
    }
  }
  if (end < 0) {
    throw const FormatException('front matter: no closing "---" line');
  }
  final values = <String, String>{};
  for (var i = 1; i < end; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final colon = line.indexOf(':');
    if (colon < 0) {
      throw FormatException('front matter: expected "key: value" in "$line"');
    }
    final key = line.substring(0, colon).trim();
    if (key.isEmpty) {
      throw FormatException('front matter: empty key in "$line"');
    }
    values[key] = _unquote(line.substring(colon + 1).trim());
  }
  return FrontMatter(values, lines.sublist(end + 1).join('\n'));
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
