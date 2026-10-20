// Shared helpers for the tests that prove the *generated* mixin
// type-checks.
//
// A `part of` file is analysed as part of its library, but the
// analyzer attributes diagnostics to the file the offending code
// lives in — and most of the generated code lives in the part
// file. So both paths have to be collected.
//
// The probe is written into a throwaway package with a copied
// `package_config.json`, so the imports resolve exactly the way
// they do in a real consumer.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:path/path.dart' as p;

/// The root of the `gtk_templates_builder` package — the directory
/// holding `pubspec.yaml`.
///
/// Derived from the package's own URI rather than
/// [Directory.current], which is the invocation directory when
/// `dart test` runs from the workspace root.
Future<Directory> packageRoot() async {
  final uri = await Isolate.resolvePackageUri(
    Uri.parse('package:gtk_templates_builder/gtk_templates_builder.dart'),
  );
  if (uri == null) {
    throw StateError('cannot resolve package:gtk_templates_builder');
  }
  // <root>/lib/gtk_templates_builder.dart -> <root>
  return File.fromUri(uri).parent.parent;
}

/// Finds the `package_config.json` that governs this package.
///
/// A workspace member inherits the *workspace root's* config, so
/// the file is not necessarily inside the package directory — walk
/// up until it turns up.
Future<File> findPackageConfig(Directory from) async {
  var dir = from;
  while (true) {
    final candidate = File(
      p.join(dir.path, '.dart_tool', 'package_config.json'),
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('no package_config.json found above ${from.path}');
    }
    dir = parent;
  }
}

/// Copies this package's `package_config.json` into [target],
/// rewriting the relative `rootUri`s so the copy still resolves
/// the workspace's path dependencies from a different directory.
Future<void> writePackageConfig(Directory target) async {
  final source = await packageRoot();
  final configFile = await findPackageConfig(source);
  // A relative `rootUri` is resolved against the directory holding
  // the `package_config.json` itself — i.e. `<root>/.dart_tool/`.
  final configDir = configFile.parent;
  final config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  final packages = config['packages'] as List<dynamic>;
  for (final entry in packages) {
    final package = entry as Map<String, dynamic>;
    final rootUri = package['rootUri'] as String;
    if (rootUri.startsWith('file:')) continue;
    final absolute = p.normalize(p.join(configDir.path, rootUri));
    package['rootUri'] = Uri.file(absolute).toString();
  }
  // The probe package itself.
  packages.add(<String, dynamic>{
    'name': 'gtk_templates_probe',
    'rootUri': Uri.file(target.path).toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.13',
  });
  final outDir = Directory(p.join(target.path, '.dart_tool'));
  await outDir.create(recursive: true);
  await File(p.join(outDir.path, 'package_config.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert(config));
}

/// The diagnostics the analyzer reports for one file.
Future<List<Diagnostic>> diagnosticsFor(
  AnalysisContextCollection collection,
  String path,
) async {
  final context = collection.contextFor(path);
  final session = context.currentSession;
  final result = await session.getErrors(path);
  if (result is! ErrorsResult) {
    // `InvalidPathResult` / `DisposedAnalysisContextResult` — the
    // path was not analysable at all. Fail loudly rather than
    // silently reporting "no errors".
    throw StateError('could not analyse $path: $result');
  }
  return result.diagnostics;
}

/// The diagnostics for [libraryPath] **and** [partPath].
Future<List<Diagnostic>> diagnosticsForLibrary(
  AnalysisContextCollection collection,
  String libraryPath,
  String partPath,
) async {
  return <Diagnostic>[
    ...await diagnosticsFor(collection, libraryPath),
    ...await diagnosticsFor(collection, partPath),
  ];
}

/// Writes [librarySource] and [partSource] into a throwaway
/// package and returns the diagnostics the analyzer reports.
///
/// The library and the part file are named `probe.dart` and
/// `probe.g.dart`, so the library's `part 'probe.g.dart';`
/// directive resolves.
Future<List<Diagnostic>> analyzeProbe({
  required String librarySource,
  required String partSource,
}) async {
  final temp = await Directory.systemTemp.createTemp('gtk_templates_probe');
  try {
    final libDir = Directory(p.join(temp.path, 'lib'));
    await libDir.create(recursive: true);
    await writePackageConfig(temp);
    final libraryFile = File(p.join(libDir.path, 'probe.dart'));
    final partFile = File(p.join(libDir.path, 'probe.g.dart'));
    await libraryFile.writeAsString(librarySource);
    await partFile.writeAsString(partSource);

    final collection = AnalysisContextCollection(
      includedPaths: <String>[temp.path],
    );
    try {
      return await diagnosticsForLibrary(
        collection,
        libraryFile.path,
        partFile.path,
      );
    } finally {
      collection.dispose();
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

/// Renders [diagnostics] as a readable list for a failure message.
String formatDiagnostics(List<Diagnostic> diagnostics) => diagnostics
    .map(
      (d) =>
          '  ${d.severity.name}: ${d.message} '
          '(offset ${d.offset}, length ${d.length})',
    )
    .join('\n');
