/// CLI for `package:gtk_templates_builder`.
///
/// Usage:
///   `dart run gtk_templates_builder <dart-file> [<dart-file>...]`
///
/// Reads each file, runs `scanSource` over it, resolves the
/// template XML (inline or from a package-root file), runs
/// the codegen, and writes the generated `_$<className>Template`
/// mixin next to each annotated class. The first cut wires
/// children only — callbacks are deferred to a follow-up.
///
/// The CLI prints the path of each emitted file to stdout.
library;

import 'dart:io';

import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln(
      'usage: gtk_templates_builder <dart-file> [<dart-file>...]',
    );
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
    for (final cls in plan.classes) {
      final xmlString = _resolveCliXml(cls.templateSource);
      if (xmlString == null) {
        stderr.writeln(
          '$path: cannot resolve ${cls.templateSource} for ${cls.className}',
        );
        continue;
      }
      final children = extractChildrenFromXml(xmlString);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: xmlString,
        xmlChildren: children,
      );
      final generated = codegenMixin(input);
      final outName = '${_basenameWithoutExt(path)}'
          '.${cls.className.toLowerCase()}.g.dart';
      final outFile = File('${_dirOf(path)}/$outName');
      outFile.writeAsStringSync(generated);
      any = true;
      stdout.writeln('${outFile.path}  (← ${cls.className})');
    }
  }
  if (exitCode != 0) return;
  exitCode = any ? 0 : 3;
}

String? _resolveCliXml(GtkTemplateSource source) {
  if (source is GtkTemplateXml) return source.content;
  if (source is GtkTemplateFile) {
    // CLI mode: treat the path as relative to cwd (the
    // package root the user is standing in). This matches
    // the build_runner behavior for a single-package
    // layout.
    final f = File(source.path);
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
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

