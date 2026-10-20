// Derives the site's facts layer.
//
// Reads the repository and writes `site_src/data/facts.json`: the
// per-package skip counts, the aggregated coverage groups, the SDK
// constraint, the licence and the size of the generated tree.
//
// The output is committed and CI re-runs this script and fails if the
// committed copy differs — so a number on the site can never drift away
// from the repository it describes.
//
// Usage:
//   dart run tool/collect_facts.dart
//
// Like every other script in `tool/`, this depends only on `dart:`.

import 'dart:convert';
import 'dart:io';

import 'site/facts.dart';

/// The curated package list.
const String _packagesFile = 'site_src/data/packages.json';

/// The generated facts.
const String _factsFile = 'site_src/data/facts.json';

void main(List<String> args) {
  final root = Directory.current.path;
  void log(String message) => stdout.writeln('collect_facts: $message');

  final String encoded;
  try {
    encoded = collectFacts(root);
  } on StateError catch (error) {
    stderr.writeln('collect_facts: ${error.message}');
    exit(2);
  }

  final output = File('$root/$_factsFile');
  output.parent.createSync(recursive: true);
  final previous = output.existsSync() ? output.readAsStringSync() : null;
  output.writeAsStringSync(encoded);
  log('wrote $_factsFile');
  if (previous != null && previous != encoded) {
    log('the committed facts changed — commit the new file');
  }
}

/// Derives the facts and returns them as the JSON document that
/// `site_src/data/facts.json` holds.
///
/// The result is byte-stable: the same repository always produces the
/// same document, so regenerating it never creates a spurious diff.
String collectFacts(String root) {
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw StateError('no pubspec.yaml in $root');
  }
  final pubspecText = pubspec.readAsStringSync();
  final workspace = parseWorkspaceList(pubspecText).toList()..sort();
  final sdkConstraint = parseSdkConstraint(pubspecText) ?? 'unknown';

  final packagesFile = File('$root/$_packagesFile');
  if (!packagesFile.existsSync()) {
    throw StateError('no $_packagesFile');
  }
  final curated = _readCurated(packagesFile.readAsStringSync());

  final unknown = <String>[
    for (final package in curated)
      if (!workspace.contains(package['name'])) package['name'] as String,
  ];
  if (unknown.isNotEmpty) {
    throw StateError(
      '$_packagesFile lists package(s) that are not in the workspace: '
      '${unknown.join(', ')}',
    );
  }

  final reports = <SkipReport>[];
  for (final package in curated) {
    if (package['generated'] != true) continue;
    final reportFile = File(
      '$root/packages/${package['name']}/skip_report.txt',
    );
    if (!reportFile.existsSync()) {
      throw StateError(
        '${package['name']} is marked as generated but has no '
        'packages/${package['name']}/skip_report.txt',
      );
    }
    final report = parseSkipReport(reportFile.readAsStringSync());
    if (report == null) {
      throw StateError('${reportFile.path} is not a skip report');
    }
    final curatedNamespace = package['namespace'] as String;
    if (curatedNamespace.isNotEmpty && curatedNamespace != report.namespace) {
      throw StateError(
        '${package['name']} namespace mismatch — $_packagesFile says '
        '"$curatedNamespace", ${reportFile.path} says '
        '"${report.namespace}"',
      );
    }
    reports.add(report);
  }

  final licenseText = _readLicense(root);
  final totalSkipped = reports.fold<int>(0, (sum, r) => sum + r.total);
  final skips = aggregateSkipGroups(reports);
  final categories = <String, int>{};
  for (final report in reports) {
    for (final entry in report.byCategory.entries) {
      categories[entry.key] = (categories[entry.key] ?? 0) + entry.value;
    }
  }

  final generated = <String, ({int files, int lines})>{};
  for (final report in reports) {
    generated[report.package] = _countDartFiles(
      Directory('$root/packages/${report.package}/lib/src'),
    );
  }
  final generator = _countDartFiles(Directory('$root/generator/lib'));
  final generatedFiles = generated.values.fold<int>(
    0,
    (sum, count) => sum + count.files,
  );
  final generatedLines = generated.values.fold<int>(
    0,
    (sum, count) => sum + count.lines,
  );

  final facts = <String, Object?>{
    'generated_by': 'tool/collect_facts.dart',
    'sdk_constraint': sdkConstraint,
    'license': _licenseName(licenseText),
    'license_text': licenseText,
    'total_skipped': totalSkipped,
    'packages': <Map<String, Object?>>[
      for (final report in reports)
        <String, Object?>{
          'name': report.package,
          'namespace': report.namespace,
          'skipped': report.total,
          'by_category': _sorted(report.byCategory),
          'by_reason': _sorted(report.byReason),
        },
    ],
    'skips': <String, Object?>{
      for (final group in skipGroups) group.key: skips[group.key] ?? 0,
    },
    'package_skips': <String, Object?>{
      for (final report in reports) report.package: report.total,
    },
    'categories': _sorted(categories),
    'docs': _docFacts(root),
    'features': _featureFacts(root, reports),
    'skip_report_example': _skipReportExample(reports),
    'generated_files': generatedFiles,
    'generated_lines': generatedLines,
    'generator_files': generator.files,
    'generator_lines': generator.lines,
  };

  return '${encodeFacts(facts)}\n';
}

List<Map<String, Object?>> _readCurated(String source) {
  final decoded = _decode(source);
  final list = decoded['packages'];
  if (list is! List) {
    throw const FormatException('packages.json: expected a "packages" list');
  }
  return list.whereType<Map<String, Object?>>().toList();
}

Map<String, Object?> _decode(String source) {
  final decoded = _jsonDecode(source);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('expected a JSON object');
  }
  return decoded;
}

Object? _jsonDecode(String source) => jsonDecode(source);

Map<String, int> _sorted(Map<String, int> input) {
  final keys = input.keys.toList()..sort();
  return <String, int>{for (final key in keys) key: input[key]!};
}

String _readLicense(String root) {
  final file = File('$root/LICENSE');
  if (!file.existsSync()) return '';
  return file.readAsStringSync().trimRight();
}

String _licenseName(String text) {
  if (text.contains('Neither the name of the copyright holder')) {
    return 'BSD-3-Clause';
  }
  if (text.contains('Permission is hereby granted, free of charge')) {
    return 'MIT';
  }
  if (text.contains('GNU GENERAL PUBLIC LICENSE')) return 'GPL';
  return 'See LICENSE';
}

List<Map<String, Object?>> _docFacts(String root) {
  final directory = Directory('$root/docs');
  if (!directory.existsSync()) return const <Map<String, Object?>>[];
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return <Map<String, Object?>>[
    for (final file in files)
      <String, Object?>{
        'name': file.path.split(Platform.pathSeparator).last,
        'lines': _lineCount(file.readAsStringSync()),
      },
  ];
}

int _lineCount(String text) {
  if (text.isEmpty) return 0;
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines.length;
}

({int files, int lines}) _countDartFiles(Directory directory) {
  if (!directory.existsSync()) return (files: 0, lines: 0);
  var files = 0;
  var lines = 0;
  for (final file in directory.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    files++;
    lines += _lineCount(file.readAsStringSync());
  }
  return (files: files, lines: lines);
}

/// Builds the skip-report excerpt the design page quotes.
///
/// The page's argument is that a reason *names the alternative* — so the
/// excerpt keeps the biggest counts and the first entries that name a
/// replacement. It is derived, so the page can never quote a number the
/// repository does not hold.
String _skipReportExample(List<SkipReport> reports) {
  if (reports.isEmpty) return '';
  final report = reports.first;
  final lines = <String>[
    '# Skip report for package ${report.package} (${report.namespace})',
    'Total skipped: ${report.total}',
    '',
    '## By category',
    for (final entry in report.byCategory.entries)
      '${entry.key}: ${entry.value}',
    '',
    '## By reason',
  ];
  final reasons = report.byReason.entries.toList();
  final picked = <String>[];
  for (final entry in reasons.take(3)) {
    picked.add('${entry.key}: ${entry.value}');
  }
  for (final needle in <String>['use ', 'renamed to ']) {
    final match = reasons.where((entry) => entry.key.contains(needle));
    if (match.isNotEmpty) {
      final entry = match.first;
      picked.add('${entry.key}: ${entry.value}');
    }
  }
  lines.addAll(picked);
  return lines.join('\n');
}

///
/// These used to be hand-copied into the pages, and they had already
/// drifted — the site claimed 3,738 typed signals where the generated
/// tree holds 3,902.
Map<String, Object?> _featureFacts(String root, List<SkipReport> reports) {
  final getter = RegExp(r'^\s+[A-Za-z_][\w<>?,\s]*\s+get\s+[A-Za-z_]\w*\s*=>');
  final setter = RegExp(r'^\s+set\s+[A-Za-z_]\w*\(');
  final signal = RegExp(r'^\s+[A-Za-z_][\w<>?,\s]*\s+on[A-Z]\w*\s*\(');
  final callback = RegExp(r'^\s+[A-Za-z_][\w<>?,\s]*\s+[a-z]\w*Callback\s*\(');

  var propsClasses = 0;
  var propsAccessors = 0;
  var typedSignals = 0;
  var asyncCallbacks = 0;

  for (final report in reports) {
    final source = Directory('$root/packages/${report.package}/lib/src');
    if (!source.existsSync()) continue;
    for (final file in source.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final isProps = file.path.endsWith('_props.dart');
      if (isProps) propsClasses++;
      for (final line in file.readAsLinesSync()) {
        if (isProps) {
          if (getter.hasMatch(line) || setter.hasMatch(line)) propsAccessors++;
          continue;
        }
        if (signal.hasMatch(line)) {
          typedSignals++;
        } else if (callback.hasMatch(line)) {
          asyncCallbacks++;
        }
      }
    }
  }

  return <String, Object?>{
    'props_classes': propsClasses,
    'props_accessors': propsAccessors,
    'typed_signals': typedSignals,
    'async_callbacks': asyncCallbacks,
  };
}
