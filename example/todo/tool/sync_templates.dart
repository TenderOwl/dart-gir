#!/usr/bin/env dart
// Copies `*.gtk_templates.dart` files from the build_runner staging area
// into `lib/` so the `part` directives in user source files resolve.
//
// In build_runner 2.4.x, plain Builder output lands under
// `.dart_tool/build/generated/<package>/lib/` rather than the source
// tree, because there's no source_gen combining_builder post-process
// for non-PartBuilder outputs. This script bridges that gap: run it
// after `dart run build_runner build` (or before running the example
// directly) to promote the generated files.
//
// Usage: dart run tool/sync_templates.dart

import 'dart:io';

void main() {
  final pkg = 'todo';
  final generatedRoot = Directory('.dart_tool/build/generated/$pkg/lib');
  final libRoot = Directory('lib');

  if (!generatedRoot.existsSync()) {
    stderr.writeln(
      'No build_runner output at ${generatedRoot.path}. '
      'Run `dart run build_runner build` first.',
    );
    exitCode = 1;
    return;
  }

  var synced = 0;
  for (final entity in generatedRoot.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.gtk_templates.dart')) continue;
    final rel = entity.path.substring(generatedRoot.path.length + 1);
    final target = File('${libRoot.path}/$rel');
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(entity.readAsStringSync());
    synced++;
    stdout.writeln('synced: ${target.path}');
  }

  if (synced == 0) {
    stderr.writeln(
      'No .gtk_templates.dart files found under ${generatedRoot.path}.',
    );
    exitCode = 1;
  }
}