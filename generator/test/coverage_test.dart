// The generator's own rule: **nothing disappears silently**.
//
// A declaration that is neither emitted nor reported is a hole nobody can
// find. The skip report is the only place a missing symbol shows up, so a
// declaration that reaches neither is invisible — and that is exactly the
// bug the virtual methods had: 981 of them were parsed, never emitted and
// never reported.
//
// The test drives the same emitters the CLI drives and checks both halves
// of the rule:
//
//   * every **callable** — a function, a method, a constructor — is either
//     emitted (its C symbol is in the generated code) or reported (the
//     skip report names it);
//   * every **virtual method** is reported, exactly once. A virtual method
//     is never emitted — the class struct layout is not in the GIR — so
//     the count is exact.
//
// The GIR files are the input. When they are not installed the test skips
// rather than fails: the invariant cannot be checked without them.

import 'dart:io';

import 'package:gir_generator/src/emit/context.dart';
import 'package:gir_generator/src/emit/emitter.dart';
import 'package:gir_generator/src/emit/function_emitter.dart';
import 'package:gir_generator/src/emit/report.dart';
import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/naming.dart';
import 'package:gir_generator/src/resolve/types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _girDir = '/usr/share/gir-1.0';

/// The namespaces the repository generates bindings for.
const _targets = [
  'GLib-2.0',
  'GObject-2.0',
  'Gio-2.0',
  'GdkPixbuf-2.0',
  'cairo-1.0',
  'Pango-1.0',
  'Gdk-4.0',
  'Graphene-1.0',
  'Gsk-4.0',
  'Gtk-4.0',
  'Adw-1',
  'GtkSource-5',
  'GIRepository-3.0',
];

void main() {
  test('every declaration is either emitted or reported', () {
    if (!Directory(_girDir).existsSync()) {
      markTestSkipped('the GIR files are not installed');
      return;
    }
    final loader = GirLoader(_girDir);
    final repos = loader.loadAllWithDependencies(_targets);
    final allNamespaces = [for (final r in repos) r.namespace];
    final targetKeys = _targets.toSet();
    final targetNamespaces = [
      for (final r in repos)
        if (targetKeys.contains('${r.namespace.name}-${r.namespace.version}'))
          r.namespace,
    ];
    final emittedPackages = {
      for (final ns in targetNamespaces) packageNameFor(ns),
    };

    final temp = Directory.systemTemp.createTempSync('gir_coverage');
    try {
      for (final ns in targetNamespaces) {
        final emitter = PackageEmitter(
          namespace: ns,
          allNamespaces: allNamespaces,
          packagesDir: temp.path,
          emittedPackages: emittedPackages,
          format: false,
        );
        final report = emitter.emit();
        _checkNamespace(ns, allNamespaces, emittedPackages, report, temp.path);
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}

/// Checks the invariant for one namespace.
void _checkNamespace(
  GirNamespace ns,
  List<GirNamespace> allNamespaces,
  Set<String> emittedPackages,
  GenerationReport report,
  String packagesDir,
) {
  final ctx = EmitContext(
    namespace: ns,
    allNamespaces: allNamespaces,
    report: report,
    emittedPackages: emittedPackages,
  );
  final functionEmitter = FunctionEmitter(ctx);

  // The names the skip report carries. A declaration is accounted for
  // when one of them names it.
  final reported = {for (final e in report.entries) e.name};
  final reportedVirtual = {
    for (final e in report.entries)
      if (e.category == 'virtual') e.name,
  };

  // The C symbols the generated code binds.
  final generated = _generatedSource(packagesDir, packageNameFor(ns));

  final missing = <String>[];

  bool emitted(String? cIdentifier) {
    if (cIdentifier == null) return false;
    return generated.contains(">('$cIdentifier')");
  }

  bool accountedFor(List<String> labels) {
    return labels.any(reported.contains);
  }

  // Namespace functions.
  for (final fn in ns.functions) {
    if (emitted(fn.cIdentifier)) continue;
    final public = escapeKeyword(functionEmitter.publicName(fn));
    final labels = ['${ns.name}.$public', '${ns.name}.${fn.name}'];
    if (!accountedFor(labels)) {
      missing.add('${ns.name}.${fn.name} (${fn.cIdentifier ?? 'no C symbol'})');
    }
  }

  // Methods, constructors and virtual methods of the owned types.
  final owners = <GirRegisteredType>[
    ...ns.classes,
    ...ns.interfaces,
    ...ns.records,
    ...ns.unions,
  ];
  for (final owner in owners) {
    final ownerName = ctx.dartTypeName(ns.name, owner.name);

    for (final m in _methodsOf(owner)) {
      if (m.movedTo != null) continue; // moved elsewhere; reported there
      if (emitted(m.cIdentifier)) continue;
      final dart = escapeKeyword(toLowerCamel(m.name));
      final labels = ['$ownerName.$dart', '$ownerName.${m.name}'];
      if (!accountedFor(labels)) {
        missing.add('$ownerName.${m.name} (${m.cIdentifier ?? 'no C symbol'})');
      }
    }

    // A virtual method is never emitted — the class struct layout is not
    // in the GIR — so it has to be reported, exactly once.
    final virtualMethods = switch (owner) {
      final GirClass c => c.virtualMethods,
      final GirInterface i => i.virtualMethods,
      _ => const <GirMethod>[],
    };
    for (final v in virtualMethods) {
      final label = '$ownerName.${v.name}';
      if (!reportedVirtual.contains(label)) {
        missing.add('virtual $label');
      }
    }
  }

  expect(
    missing,
    isEmpty,
    reason:
        'these declarations were neither emitted nor reported — every '
        'declaration must appear in the generated code or in the skip '
        'report',
  );
}

/// The methods a GIR type declares.
List<GirMethod> _methodsOf(GirRegisteredType owner) => switch (owner) {
  final GirClass c => c.methods,
  final GirInterface i => i.methods,
  final GirRecord r => r.methods,
  final GirUnion u => u.methods,
  _ => const <GirMethod>[],
};

/// The generated Dart source of one package, concatenated.
String _generatedSource(String packagesDir, String pkg) {
  final srcDir = Directory(p.join(packagesDir, pkg, 'lib', 'src'));
  if (!srcDir.existsSync()) return '';
  final b = StringBuffer();
  for (final file in srcDir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    b.write(file.readAsStringSync());
  }
  return b.toString();
}
