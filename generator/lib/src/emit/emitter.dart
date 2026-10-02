/// Orchestrates per-package emission: runs the per-kind emitters, splits
/// declarations into part files (one file per Dart class, chunked for
/// the smaller categories), writes scaffolding and the skip report.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../gir/gir.dart';
import '../resolve/types.dart';
import 'class_emitter.dart';
import 'context.dart';
import 'callback_emitter.dart';
import 'enum_emitter.dart';
import 'function_emitter.dart';
import 'library_emitter.dart';
import 'record_emitter.dart';
import 'report.dart';
import 'signals_helper.dart';

/// Emits one generated package for a [GirNamespace].
class PackageEmitter {
  PackageEmitter({
    required this.namespace,
    required this.allNamespaces,
    required this.packagesDir,
    required this.emittedPackages,
    Set<String>? emittedPropsClassNames,
  }) : emittedPropsClassNames =
            emittedPropsClassNames ?? <String>{};

  final GirNamespace namespace;
  final List<GirNamespace> allNamespaces;

  /// Path to the directory containing generated packages (`packages/`).
  final String packagesDir;

  /// Package names generated in this run.
  final Set<String> emittedPackages;

  /// Tracks props class names emitted across the entire workspace run.
  /// Shared between `PackageEmitter` instances so a child class can
  /// `extends` a parent props class emitted by a previous package
  /// (e.g. `AdwAvatarProps extends GtkWidgetProps`).
  static final Set<String> _emittedPropsClassNames = <String>{};
  final Set<String> emittedPropsClassNames;

  // Roughly halves after `dart format` expansion of long signatures.
  static const _maxLinesPerFile = 400;

  String get pkg => packageNameFor(namespace);

  GenerationReport emit() {
    final report = GenerationReport();
    final ctx = EmitContext(
      namespace: namespace,
      allNamespaces: allNamespaces,
      report: report,
      emittedPackages: emittedPackages,
    );

    final categories = <String, List<String>>{
      'enums': [],
      'constants': [],
      'callbacks': [],
      'functions': [],
      'records': [],
    };

    // One file per Dart class: `lib/src/<lowercased class name>.dart`
    // for the class itself and `lib/src/<lowercased class name>_props.dart`
    // for its `<ClassName>Props` companion. Insertion order is the GIR
    // declaration order, preserved by Dart's `Map` implementation; the
    // barrel's `part` directives end up in that same order so IDE
    // jump-to-source visits classes in declaration order.
    final classFiles = <String, String>{};

    final enumEmitter = EnumEmitter(ctx);
    for (final e in namespace.enumerations) {
      final code = enumEmitter.emit(e);
      if (code != null) categories['enums']!.add(code);
    }
    for (final bf in namespace.bitfields) {
      final code = enumEmitter.emitBitfield(bf);
      if (code != null) categories['enums']!.add(code);
    }

    final functionEmitter = FunctionEmitter(ctx);
    for (final c in namespace.constants) {
      final code = functionEmitter.emitConstant(c);
      if (code != null) categories['constants']!.add(code);
    }
    for (final f in namespace.functions) {
      final base = functionEmitter.emitFunction(f);
      if (base != null) {
        categories['functions']!.add(base);
        // Lifetime-safe `*Callback` overload alongside the base wrapper
        // for async functions whose callback type is `GAsyncReadyCallback`.
        final asyncOverload = functionEmitter.emitAsyncFunctionOverload(
          f,
          f.name,
        );
        if (asyncOverload != null && ctx.claimName('${f.name}Callback')) {
          categories['functions']!.add(asyncOverload);
        }
      }
    }

    final recordEmitter = RecordEmitter(ctx);
    for (final r in namespace.records) {
      final code = recordEmitter.emitRecord(r);
      if (code != null) categories['records']!.add(code);
    }
    for (final u in namespace.unions) {
      final code = recordEmitter.emitUnion(u);
      if (code != null) categories['records']!.add(code);
    }

    final classEmitter =
        ClassEmitter(ctx, emittedPackages: emittedPackages);
    // Track fully-qualified props class names that have been emitted
    // for at least one accessor across the workspace. Child class
    // emissions consult this set before emitting `extends <parentProps>`
    // to avoid referring to a parent props class that was skipped
    // (every property was skipped because its getter/setter couldn't
    // be resolved).
    final emittedPropsClassNames = _emittedPropsClassNames;
    classEmitter.emittedPropsClasses = emittedPropsClassNames;
    // Pre-scan the namespace's classes to populate the props-class
    // set in dependency order. The actual emission loop below then
    // sees a fully-populated set when deciding whether to add
    // `extends <parentProps>`. We can't just collect the names
    // from `pendingPropsClass` because the parent props class may
    // be declared *after* the child in the classes list.
    for (final c in namespace.classes) {
      if (classEmitter.wouldEmitPropsClass(c)) {
        final dartName = ctx.dartTypeName(ctx.namespace.name, c.name);
        emittedPropsClassNames.add('${dartName}Props');
      }
    }
    for (final c in namespace.classes) {
      final code = classEmitter.emitClass(c);
      final dartName = ctx.dartTypeName(ctx.namespace.name, c.name);
      if (code != null) {
        classFiles[_fileNameForClass(dartName)] = code;
      }
      // The props companion class is a top-level class (alongside the
      // class it backs) — placed in its own `<name>_props.dart` file.
      // Forward references between the two `part of` files resolve
      // naturally because Dart compiles every part of one library
      // together.
      final propsCode = classEmitter.pendingPropsClass;
      if (propsCode != null) {
        classFiles[_fileNameForClass(dartName, props: true)] = propsCode;
      }
    }

    for (final i in namespace.interfaces) {
      final code = recordEmitter.emitInterface(i);
      if (code != null) categories['records']!.add(code);
    }
    final callbackEmitter = CallbackEmitter(ctx);
    for (final cb in namespace.callbacks) {
      final code = callbackEmitter.emit(cb);
      if (code != null) categories['callbacks']!.add(code);
    }
    for (final a in namespace.aliases) {
      report.skip('alias', a.name, 'aliases are resolved to their target');
    }

    // Support parts.
    final isGLib = namespace.name == 'GLib';
    final isGObject = namespace.name == 'GObject';
    if (isGLib) {
      ctx.usesFfiString = true; // _GErrorStruct uses Utf8
    }
    if (ctx.usesGlibException && pkg != 'glib') {
      ctx.imports.add('glib');
    }
    ctx.imports.remove(pkg);

    // Write files.
    final pkgDir = p.join(packagesDir, pkg);
    final libDir = p.join(pkgDir, 'lib');
    final stale = Directory(libDir);
    if (stale.existsSync()) stale.deleteSync(recursive: true);
    final srcDir = p.join(libDir, 'src');
    Directory(srcDir).createSync(recursive: true);

    final parts = <String>['lib.dart'];
    File(p.join(srcDir, 'lib.dart'))
        .writeAsStringSync(libDartFor(namespace, pkg));
    if (isGLib) {
      parts.add('exception.dart');
      File(p.join(srcDir, 'exception.dart'))
          .writeAsStringSync(exceptionDartFor(pkg));
    }
    if (isGObject) {
      parts.add('object_support.dart');
      File(p.join(srcDir, 'object_support.dart'))
          .writeAsStringSync(objectSupportDartFor(pkg));
    }
    final signalsCode = emitSignalsHelper(ctx);
    if (signalsCode != null) {
      parts.add('signals.dart');
      File(p.join(srcDir, 'signals.dart')).writeAsStringSync(signalsCode);
    }

    // Classes: one file per Dart class / props companion, in GIR
    // declaration order.
    for (final entry in classFiles.entries) {
      final fileName = '${entry.key}.dart';
      parts.add(fileName);
      final content = StringBuffer()
        ..writeln(generatedHeader)
        ..writeln("part of '../$pkg.dart';")
        ..writeln()
        ..write(entry.value);
      File(p.join(srcDir, fileName)).writeAsStringSync(content.toString());
    }

    for (final entry in categories.entries) {
      final chunks = _chunk(entry.value);
      for (var i = 0; i < chunks.length; i++) {
        final fileName = chunks.length == 1
            ? '${entry.key}.dart'
            : '${entry.key}_$i.dart';
        parts.add(fileName);
        final content = StringBuffer()
          ..writeln(generatedHeader)
          ..writeln("part of '../$pkg.dart';")
          ..writeln()
          ..write(chunks[i]);
        File(p.join(srcDir, fileName)).writeAsStringSync(content.toString());
      }
    }

    File(p.join(pkgDir, 'lib', '$pkg.dart')).writeAsStringSync(barrelFor(
      pkg,
      crossImports: ctx.imports,
      usesFfiPackage: ctx.usesFfiString || ctx.usesMalloc,
      usesGirFfi: ctx.usesGirFfi,
      parts: parts,
    ));
    File(p.join(pkgDir, 'pubspec.yaml'))
        .writeAsStringSync(pubspecFor(pkg, ctx.imports));
    File(p.join(pkgDir, 'analysis_options.yaml'))
        .writeAsStringSync(analysisOptionsFor());
    File(p.join(pkgDir, 'skip_report.txt')).writeAsStringSync(
        report.format('package $pkg (${namespace.name} ${namespace.version})'));

    Process.runSync('dart', ['format', pkgDir]);
    return report;
  }

  /// Groups declarations into chunks of roughly [_maxLinesPerFile] lines.
  List<String> _chunk(List<String> decls) {
    if (decls.isEmpty) return const [];
    final chunks = <StringBuffer>[StringBuffer()];
    var lines = 0;
    for (final decl in decls) {
      final declLines = '\n'.allMatches(decl).length + 2;
      if (lines + declLines > _maxLinesPerFile &&
          chunks.last.isNotEmpty) {
        chunks.add(StringBuffer());
        lines = 0;
      }
      chunks.last
        ..write(decl)
        ..writeln()
        ..writeln();
      lines += declLines;
    }
    return chunks.map((c) => c.toString()).toList();
  }

  /// File name (no `.dart` suffix) for a generated Dart class.
  ///
  /// Lowercased Dart class name verbatim — `GtkButton` →
  /// `gtkbutton.dart`, `GApplication` → `gapplication.dart` — matching
  /// the upstream g-i convention and the user's stated pattern. The
  /// optional `props` flag appends `_props` for the companion class
  /// (`GtkButtonProps` → `gtkbutton_props.dart`).
  String _fileNameForClass(String dartName, {bool props = false}) {
    final base = dartName.toLowerCase();
    return props ? '${base}_props' : base;
  }
}
