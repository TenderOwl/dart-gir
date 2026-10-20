/// CLI for `package:gtk_templates_builder`.
///
/// Usage:
///   `dart run gtk_templates_builder <dart-file> [<dart-file>...]`
///
/// Reads each file, runs `scanSource` over it, resolves the
/// template XML (inline or from a package-root file), runs
/// the codegen, and writes **one part file per source file**
/// — `<input>.g.dart`, next to the source — holding a
/// `_$<className>Template` mixin per annotated class.
///
/// The source file must declare `part '<input>.g.dart';`. When
/// it does not, the CLI prints the exact line to add and exits
/// with status 4.
///
/// The CLI prints the path of each emitted file to stdout.
library;

import 'dart:io';

import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln('usage: gtk_templates_builder <dart-file> [<dart-file>...]');
    exitCode = args.isEmpty ? 1 : 0;
    return;
  }

  var any = false;
  for (final path in args) {
    if (path.startsWith('-')) {
      stderr.writeln('unknown flag: $path');
      exitCode = 2;
      continue;
    }
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('not found: $path');
      exitCode = 2;
      continue;
    }
    final source = file.readAsStringSync();
    final plan = scanSource(source, filePath: path);
    if (plan.isEmpty) {
      stdout.writeln('$path: no @GtkTemplate classes');
      continue;
    }

    final partOfPath = _basenameWithoutExt(path) + '.dart';
    final partBasename = partFileBasename(partOfPath);

    // The generated file is a `part of` the user's library, so
    // the user's file must pull it in. Report the exact line to
    // add when it doesn't.
    final diagnostic = checkPartDirective(source, partBasename);
    if (diagnostic != null) {
      stderr.writeln('$path\n$diagnostic');
      exitCode = 4;
      continue;
    }

    final inputs = <CodegenInput>[];
    for (final cls in plan.classes) {
      final xmlString = _resolveCliXml(cls.templateSource, path);
      if (xmlString == null) {
        stderr.writeln(
          '$path: cannot resolve ${cls.templateSource} for ${cls.className}\n'
          'The path is relative to the package root — the directory '
          'holding pubspec.yaml.',
        );
        exitCode = 6;
        continue;
      }
      final children = extractChildrenFromXml(xmlString);
      final signals = extractSignalsFromXml(xmlString);
      inputs.add(
        CodegenInput.fromPlan(
          cls,
          xmlString: xmlString,
          xmlChildren: children,
          xmlSignals: signals,
          partOfPath: partOfPath,
        ),
      );
    }
    if (inputs.isEmpty) continue;

    // The generated file is a `part of` the user's library, so it
    // inherits that library's imports. Report the exact import
    // lines to add when one is missing.
    final typeNames = <String>[
      for (final input in inputs) input.parentType,
      for (final input in inputs) ...input.children.map((c) => c.typeName),
    ];
    final missingImports = checkRequiredImports(source, typeNames);
    if (missingImports.isNotEmpty) {
      stderr.writeln(
        '$path is missing the imports the generated mixin needs:\n'
        '${missingImports.map((p) => "  import '$p';").join('\n')}\n'
        'The generated file is a `part of` this library and inherits its '
        'imports, so add the lines above to this file.',
      );
      exitCode = 5;
      continue;
    }

    final generated = formatGeneratedSource(codegenLibrary(inputs));
    final outFile = File('${_dirOf(path)}/$partBasename');
    outFile.writeAsStringSync(generated);
    any = true;
    stdout.writeln(
      '${outFile.path}  (← ${inputs.map((i) => i.className).join(', ')})',
    );
  }
  if (exitCode != 0) return;
  exitCode = any ? 0 : 3;
}

/// Resolves the template XML for [source] when the builder runs
/// standalone.
///
/// The path of a `GtkTemplateFile` is relative to the **package
/// root** — the nearest ancestor directory holding a `pubspec.yaml`,
/// found from the source file [sourcePath]. That keeps the CLI
/// independent of the directory it was started in, which is what the
/// `build_runner` flow does too.
String? _resolveCliXml(GtkTemplateSource source, String sourcePath) {
  if (source is GtkTemplateXml) return source.content;
  if (source is GtkTemplateFile) {
    final packageRoot = findPackageRoot(sourcePath);
    final file = packageRoot == null
        ? File(source.path)
        : File('$packageRoot/${source.path}');
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }
  return null;
}

String _basenameWithoutExt(String path) {
  final parts = path.split('/');
  final last = parts.removeLast();
  final dot = last.lastIndexOf('.');
  return dot < 0 ? last : last.substring(0, dot);
}

String _dirOf(String path) {
  final parts = path.split('/');
  if (parts.length == 1) return '.';
  parts.removeLast();
  return parts.join('/');
}
