// The facts layer.
//
// The site used to carry hand-copied numbers — per-package skip counts,
// the total number of skipped symbols, the SDK constraint. They drifted
// twice. The facts layer replaces them: `tool/collect_facts.dart`
// derives the numbers from the repository into `site_src/data/facts.json`,
// and the page sources interpolate `{{facts.…}}` placeholders.
//
// A placeholder that names a fact which does not exist fails the build,
// with the file and line. A typo must never render as an empty string.

import 'dart:convert';
import 'dart:io';

/// The derived facts, loaded from `site_src/data/facts.json`.
class Facts {
  const Facts(this.data);

  /// The decoded JSON object.
  final Map<String, Object?> data;

  /// Decodes a facts document.
  factory Facts.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('facts.json must contain a JSON object');
    }
    return Facts(decoded);
  }

  /// Looks a dotted path up in the facts, e.g. `skips.glib`.
  ///
  /// Returns `null` when the path does not resolve, or when it resolves
  /// to a value that is not a string, number or boolean.
  String? lookup(String path) {
    Object? current = data;
    for (final segment in path.split('.')) {
      if (current is Map<String, Object?>) {
        current = current[segment];
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          return null;
        }
        current = current[index];
      } else {
        return null;
      }
      if (current == null) return null;
    }
    if (current is String) return current;
    if (current is int) return formatCount(current);
    if (current is num || current is bool) return current.toString();
    return null;
  }

  /// Replaces every `{{facts.…}}` placeholder in [text].
  ///
  /// Throws a [FormatException] naming the source and the line when a
  /// placeholder refers to a fact that does not exist.
  String substitute(String text, {required String sourceName}) {
    final matches = _placeholder.allMatches(text).toList();
    if (matches.isEmpty) return text;
    final out = StringBuffer();
    var last = 0;
    for (final match in matches) {
      out.write(text.substring(last, match.start));
      final path = match.group(1)!;
      final value = lookup(path);
      if (value == null) {
        final line = '\n'.allMatches(text.substring(0, match.start)).length + 1;
        throw FormatException('$sourceName:$line: unknown fact "facts.$path"');
      }
      out.write(value);
      last = match.end;
    }
    out.write(text.substring(last));
    return out.toString();
  }

  static final RegExp _placeholder = RegExp(
    r'\{\{facts\.([A-Za-z0-9_.\-]+)\}\}',
  );
}

/// Encodes [value] as indented JSON with a stable key order.
///
/// Dart's JSON encoder preserves map insertion order, so the callers
/// build their maps in a fixed order and the output is byte-stable.
String encodeFacts(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

/// Formats a count the way the site writes them: `3,242`, not `3242`.
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Parses the `workspace:` list out of a root `pubspec.yaml`.
///
/// Hand-rolled on purpose: `package:yaml` would force a re-resolution of
/// the workspace's `analyzer` constraint and break `dart test` (see the
/// note in `tool/build_api_docs.dart`).
Set<String> parseWorkspaceList(String content) {
  final lines = content.split('\n');
  var inWorkspace = false;
  final packages = <String>{};
  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.startsWith('workspace:')) {
      inWorkspace = line.trim() == 'workspace:';
      continue;
    }
    if (!inWorkspace) continue;
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      inWorkspace = false;
      continue;
    }
    final dash = line.indexOf('-');
    if (dash < 0) continue;
    final entry = line.substring(dash + 1).trim();
    if (entry.startsWith('packages/')) {
      packages.add(entry.substring('packages/'.length));
    }
  }
  return packages;
}

/// Parses the `environment: sdk:` constraint out of a `pubspec.yaml`.
String? parseSdkConstraint(String content) {
  final lines = content.split('\n');
  var inEnvironment = false;
  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.startsWith('environment:')) {
      inEnvironment = line.trim() == 'environment:';
      continue;
    }
    if (!inEnvironment) continue;
    if (line.trim().isEmpty) {
      inEnvironment = false;
      continue;
    }
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      inEnvironment = false;
      continue;
    }
    final match = RegExp(r'^\s+sdk:\s*(.+?)\s*$').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// A package the site documents.
class PackageEntry {
  const PackageEntry({
    required this.name,
    required this.namespace,
    required this.native,
    required this.role,
    required this.description,
    required this.blurb,
    required this.generated,
  });

  /// The package's directory name, e.g. `gtk4`.
  final String name;

  /// The GIR namespace, e.g. `Gtk 4.0`. Empty for hand-written packages.
  final String namespace;

  /// The native library the package binds, e.g. `libgtk-4`.
  final String native;

  /// The package's role in the stack.
  final String role;

  /// What the package is, for the hand-written ones. Empty for generated
  /// packages — their namespace and native library say it.
  final String description;

  /// The one-line description used on the API landing page.
  final String blurb;

  /// Whether the package is generated from a `.gir` file.
  final bool generated;

  /// Decodes one entry of `packages.json`.
  factory PackageEntry.decode(Map<String, Object?> json) {
    return PackageEntry(
      name: json['name'] as String? ?? '',
      namespace: json['namespace'] as String? ?? '',
      native: json['native'] as String? ?? '',
      role: json['role'] as String? ?? '',
      description: json['description'] as String? ?? '',
      blurb: json['blurb'] as String? ?? '',
      generated: json['generated'] as bool? ?? false,
    );
  }
}

/// Reads a `packages.json` document.
List<PackageEntry> readPackages(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('missing $path');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw FormatException('$path: expected a JSON object');
  }
  final list = decoded['packages'];
  if (list is! List) {
    throw FormatException('$path: expected a "packages" list');
  }
  return list
      .whereType<Map<String, Object?>>()
      .map(PackageEntry.decode)
      .toList();
}

/// A parsed `packages/<lib>/skip_report.txt`.
class SkipReport {
  const SkipReport({
    required this.package,
    required this.namespace,
    required this.total,
    required this.byCategory,
    required this.byReason,
  });

  /// The package's directory name.
  final String package;

  /// The GIR namespace the package was generated from.
  final String namespace;

  /// The `Total skipped:` line.
  final int total;

  /// The `## By category` block.
  final Map<String, int> byCategory;

  /// The `## By reason` block.
  final Map<String, int> byReason;
}

/// Parses a skip report.
///
/// Returns `null` when the content is not a skip report.
SkipReport? parseSkipReport(String content) {
  final header = RegExp(
    r'^# Skip report for package (\S+) \((.*)\)\s*$',
    multiLine: true,
  ).firstMatch(content);
  if (header == null) return null;
  final total = RegExp(
    r'^Total skipped: (\d+)\s*$',
    multiLine: true,
  ).firstMatch(content);
  return SkipReport(
    package: header.group(1)!,
    namespace: header.group(2)!,
    total: total == null ? 0 : int.parse(total.group(1)!),
    byCategory: _parseSkipSection(content, '## By category'),
    byReason: _parseSkipSection(content, '## By reason'),
  );
}

Map<String, int> _parseSkipSection(String content, String header) {
  final result = <String, int>{};
  final lines = content.split('\n');
  var inside = false;
  for (final line in lines) {
    if (!inside) {
      if (line.trim() == header) inside = true;
      continue;
    }
    if (line.startsWith('## ')) break;
    final match = RegExp(r'^(.*): (\d+)\s*$').firstMatch(line);
    if (match == null) continue;
    result[match.group(1)!.trim()] = int.parse(match.group(2)!);
  }
  return result;
}

/// One group of skip reasons, as the features page presents them.
class SkipGroup {
  const SkipGroup(
    this.key,
    this.label, {
    this.prefixes = const <String>[],
    this.contains = const <String>[],
  });

  /// The fact key the group is published under.
  final String key;

  /// The human label — the prose stays in the page source, this is only
  /// a fallback for the API landing page.
  final String label;

  /// Reason prefixes that belong to the group.
  final List<String> prefixes;

  /// Substrings that belong to the group.
  final List<String> contains;

  /// Whether [reason] belongs to the group.
  bool matches(String reason) {
    for (final prefix in prefixes) {
      if (reason.startsWith(prefix)) return true;
    }
    for (final needle in contains) {
      if (reason.contains(needle)) return true;
    }
    return false;
  }
}

/// The groups the features page's coverage table is built from.
///
/// The order is the order the table reads in. The counts are derived;
/// the labels and the verdicts live in the Markdown.
const List<SkipGroup> skipGroups = <SkipGroup>[
  SkipGroup(
    'missing_getter',
    'Property has no typed getter at all',
    prefixes: <String>['missing getter '],
  ),
  SkipGroup(
    'array_types',
    'Array and collection types',
    contains: <String>['array of TypeKind'],
  ),
  SkipGroup(
    'construct_only',
    'Property construct-only or no public setter',
    prefixes: <String>['construct-only'],
  ),
  SkipGroup(
    'duplicate_constant',
    'Duplicate constant — two GIR symbols, one Dart name',
    prefixes: <String>['duplicate constant'],
  ),
  SkipGroup(
    'name_collision',
    'Name collision',
    prefixes: <String>['name collision'],
  ),
  SkipGroup(
    'unsupported_type',
    'Unsupported type',
    prefixes: <String>['unsupported type '],
  ),
  SkipGroup('c_macro', 'C macro', prefixes: <String>['introspectable=0']),
  SkipGroup(
    'unnamed_return',
    'Return type could not be named',
    prefixes: <String>[
      'return: string list return type (null)',
      'return: unknown type',
    ],
  ),
  SkipGroup(
    'unsupported_out_buffer',
    'Unsupported OUT buffer',
    prefixes: <String>['unsupported out parameter'],
  ),
  SkipGroup(
    'override_incompatible',
    'Override-incompatible — emitted under a renamed method',
    prefixes: <String>['override-incompatible'],
  ),
  SkipGroup(
    'inout_parameter',
    'inout parameter',
    prefixes: <String>['inout parameter'],
  ),
  SkipGroup(
    'alias_resolved',
    'Alias resolved to its target',
    prefixes: <String>['aliases are resolved'],
  ),
  SkipGroup(
    'unsupported_return_type',
    'Unsupported return type',
    prefixes: <String>['unsupported return type'],
  ),
  SkipGroup(
    'unsupported_argument_type',
    'Unsupported argument type',
    prefixes: <String>['unsupported arg type'],
  ),
  SkipGroup(
    'nullable_scalar_parameter',
    'Nullable scalar parameter',
    contains: <String>['nullable scalar parameter'],
  ),
  SkipGroup(
    'duplicate_declaration',
    'Duplicate declaration owned by an earlier namespace',
    prefixes: <String>['duplicate declaration'],
  ),
  SkipGroup('other', 'Everything else'),
];

/// Aggregates the skip reports into the per-group counts.
///
/// The groups are applied in order and each reason lands in exactly one
/// group; whatever is left over falls into `other`.
Map<String, int> aggregateSkipGroups(Iterable<SkipReport> reports) {
  final counts = <String, int>{for (final group in skipGroups) group.key: 0};
  for (final report in reports) {
    for (final reason in report.byReason.keys) {
      var placed = false;
      for (final group in skipGroups) {
        if (group.key == 'other') continue;
        if (group.matches(reason)) {
          counts[group.key] = counts[group.key]! + report.byReason[reason]!;
          placed = true;
          break;
        }
      }
      if (!placed) {
        counts['other'] = counts['other']! + report.byReason[reason]!;
      }
    }
  }
  return counts;
}
