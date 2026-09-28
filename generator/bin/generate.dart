/// CLI entry point: generates Dart FFI binding packages from GIR files.
///
/// Usage: dart run bin/generate.dart [--gir-dir DIR] GLib-2.0 GObject-2.0
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:gir_generator/src/emit/emit.dart';
import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/types.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  final parser = ArgParser()
    ..addOption('gir-dir',
        abbr: 'g',
        defaultsTo: '/usr/share/gir-1.0',
        help: 'Directory containing .gir files')
    ..addOption('packages-dir',
        defaultsTo: 'packages',
        help:
            'Output directory for packages (run from the repository root, or '
            'pass an absolute path)')
    ..addFlag('help', abbr: 'h', negatable: false);
  final results = parser.parse(args);
  if (results.flag('help') || results.rest.isEmpty) {
    stderr.writeln(
        'Usage: dart run bin/generate.dart [--gir-dir DIR] Name-Version...');
    exit(results.flag('help') ? 0 : 64);
  }

  final targets = results.rest;
  final loader = GirLoader(results.option('gir-dir')!);
  final repos = loader.loadAllWithDependencies(targets);
  final allNamespaces = [for (final r in repos) r.namespace];
  final targetKeys = targets.toSet();
  final targetNamespaces = [
    for (final r in repos)
      if (targetKeys.contains('${r.namespace.name}-${r.namespace.version}'))
        r.namespace,
  ];
  final emittedPackages = {for (final ns in targetNamespaces) packageNameFor(ns)};

  final packagesDir = p.absolute(results.option('packages-dir')!);
  var totalSkipped = 0;
  for (final ns in targetNamespaces) {
    final emitter = PackageEmitter(
      namespace: ns,
      allNamespaces: allNamespaces,
      packagesDir: packagesDir,
      emittedPackages: emittedPackages,
    );
    final report = emitter.emit();
    totalSkipped += report.totalSkipped;
    stdout.writeln(
        'emitted ${packageNameFor(ns)} (${ns.name} ${ns.version}): ${report.totalSkipped} skipped');
  }

  syncRootPubspec(p.dirname(packagesDir));
  stdout.writeln('total skipped: $totalSkipped');
}
