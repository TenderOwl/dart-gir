/// `build_runner` `Builder` for `@GtkTemplate` annotation scanning.
///
/// This first cut scans every `.dart` input the builder is asked
/// about and emits a `_$<className>Template` mixin next to each
/// annotated class. The mixin registers the template with the
/// widget class, binds the per-instance children via
/// `getTemplateChild`, and populates `late final` fields on
/// demand. Callbacks are not yet auto-wired — see
/// `lib/codegen.dart` for the limitation.
///
/// The scanner is exposed as a top-level `scanSource` so tests
/// can run it without going through `build_runner`.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:gtk_templates/gtk_templates.dart';

import 'builder_plan.dart';
import 'codegen.dart';

/// `build_runner` `Builder` entry point.
///
/// Registered by `bin/gtk_templates_builder.dart` when the user
/// runs the builder standalone, and by consumer `build.yaml`s
/// when they want the auto-generated mixin.
class GtkTemplatesBuilder implements Builder {
  /// Creates the builder. The first cut ignores any options —
  /// future revisions may read configuration (e.g. resource
  /// path prefixing) from `build.yaml`.
  const GtkTemplatesBuilder();

  @override
  final Map<String, List<String>> buildExtensions = const {
    // Per-class generated file: <input>.<className>.g.dart.
    // `build_runner` requires every output extension to be
    // declared; we use a single `.g.dart` extension and put
    // the class name into the package's part-of name below.
    r'$lib$': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    final plan = scanSource(source, filePath: buildStep.inputId.path);
    if (plan.isEmpty) return;

    for (final cls in plan.classes) {
      final xmlString = await _resolveTemplateXml(
        cls.templateSource,
        buildStep,
      );
      if (xmlString == null) {
        log.warning(
          'gtk_templates: skipping ${cls.className} — could not '
          'resolve template XML (${cls.templateSource})',
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
      final outputId = buildStep.inputId.addExtension(
        '.${cls.className.toLowerCase()}.g.dart',
      );
      await buildStep.writeAsString(outputId, generated);
    }
  }
}

/// Resolves the template XML for a class. For inline
/// `GtkTemplateXml` it returns the inline content; for
/// `GtkTemplateFile` it reads the file at the package root.
/// Returns `null` on a missing file (the caller logs and
/// skips the class).
Future<String?> _resolveTemplateXml(
  GtkTemplateSource source,
  BuildStep buildStep,
) async {
  if (source is GtkTemplateXml) return source.content;
  if (source is GtkTemplateFile) {
    // The path is relative to the package root. The
    // `BuildStep.inputId.package` gives us the package
    // name; combined with the workspace root (the
    // build's `rootPackage` is harder to reach) we fall
    // back to the input file's directory + path, which
    // works for the test fixture and is correct for
    // monorepo / single-package layouts.
    final inputPath = buildStep.inputId.path;
    final packageRoot = _packageRootFor(inputPath);
    if (packageRoot == null) {
      log.warning(
        'gtk_templates: cannot determine package root for '
        '${buildStep.inputId}',
      );
      return null;
    }
    final file = File('$packageRoot/${source.path}');
    if (!file.existsSync()) {
      log.warning(
        'gtk_templates: ${source.path} not found at '
        '$packageRoot/${source.path}',
      );
      return null;
    }
    return file.readAsStringSync();
  }
  return null;
}

/// Walks up from [inputPath] until it finds the directory
/// containing a `pubspec.yaml`. Returns the directory's path
/// with a trailing slash, or `null` if none is found.
String? _packageRootFor(String inputPath) {
  // inputPath is package-relative (e.g. 'lib/foo.dart').
  // The package root is `..` from `lib/`. For tests in
  // `test/fixtures/`, the package root is the test package
  // dir, and the fixture path is the user's responsibility
  // to express relative to that root.
  //
  // For the standalone CLI we need an absolute path; for
  // the build_runner flow we have a relative path. The
  // simplest cross-mode shape: assume `inputPath` starts
  // with `lib/` or `test/`, strip that prefix, and resolve
  // the rest against the current working directory. The
  // build's `BuildStep.allowedOutputs` keeps everything
  // honest.
  if (Platform.isLinux || Platform.isMacOS) {
    final cwd = Directory.current.path;
    if (inputPath.startsWith('lib/') || inputPath.startsWith('test/')) {
      return cwd;
    }
    // Strip a leading package segment if present.
    final segments = inputPath.split('/');
    if (segments.length > 1) {
      return '$cwd/${segments.sublist(0, segments.length - 1).join('/')}';
    }
    return cwd;
  }
  return Directory.current.path;
}

/// Parses [source] and returns a `BuilderPlan` for every
/// `@GtkTemplate`-annotated top-level class.
///
/// The parser tolerates diagnostics so the test fixtures don't
/// need to be compilable Dart (e.g. they can omit imports and
/// rely on bare names like `GtkBox`).
BuilderPlan scanSource(String source, {String? filePath}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final classes = <ClassTemplatePlan>[];
  for (final decl in result.unit.declarations) {
    if (decl is ClassDeclaration) {
      final plan = _scanClass(decl);
      if (plan != null) classes.add(plan);
    }
  }
  return BuilderPlan(filePath: filePath, classes: classes);
}

ClassTemplatePlan? _scanClass(ClassDeclaration decl) {
  final templateSource = _findGtkTemplateSource(decl.metadata);
  if (templateSource == null) return null;

  final children = <WidgetBinding>[];
  final callbacks = <CallbackBinding>[];

  for (final member in _membersOf(decl)) {
    if (member is FieldDeclaration) {
      final ann = _firstAnnotation(member.metadata, 'GtkTemplateChild');
      if (ann != null) {
        final explicitName = _findNamedStringArg(ann, 'name');
        for (final variable in member.fields.variables) {
          children.add(
            WidgetBinding(
              fieldName: variable.name.lexeme,
              childName: explicitName ?? variable.name.lexeme,
            ),
          );
        }
      }
    } else if (member is MethodDeclaration) {
      final ann = _firstAnnotation(member.metadata, 'GtkTemplateCallback');
      if (ann != null) {
        callbacks.add(
          CallbackBinding(
            methodName: member.name.lexeme,
            callbackName: snakeCase(member.name.lexeme),
          ),
        );
      }
    }
  }

  return ClassTemplatePlan(
    className: decl.namePart.typeName.lexeme,
    parentType: _parentTypeName(decl),
    templateSource: templateSource,
    children: children,
    callbacks: callbacks,
  );
}

/// Reads the `extends` clause of [decl] and returns the
/// parent's simple class name. Defaults to `GtkWidget` when
/// the user omits the clause.
String _parentTypeName(ClassDeclaration decl) {
  final ext = decl.extendsClause;
  if (ext == null) return 'GtkWidget';
  return ext.superclass.name.lexeme;
}

/// Reads the `source:` named argument of a `@GtkTemplate`
/// annotation and returns the matching [GtkTemplateSource]
/// variant, or `null` if the annotation is missing, has no
/// `source:` argument, or carries a `source:` value the scanner
/// can't statically prove is one of the two supported
/// constructor invocations.
///
/// The 0.1.x `@GtkTemplate(resourcePath: '...')` form is **not**
/// accepted; the scanner treats it as "no source" and skips
/// the class. The CHANGELOG entry under 0.2.0 documents the
/// change; users migrating from 0.1.x must rewrite the
/// annotation to `@GtkTemplate(source: ...)` with one of the
/// two variants.
GtkTemplateSource? _findGtkTemplateSource(NodeList<Annotation> annotations) {
  final ann = _firstAnnotation(annotations, 'GtkTemplate');
  if (ann == null) return null;

  final argList = ann.arguments;
  if (argList == null) {
    log.warning('GtkTemplate on a class has no arguments; expected `source:`');
    return null;
  }

  for (final arg in argList.arguments) {
    if (arg is! NamedExpression) continue;
    if (arg.name.label.name != 'source') continue;
    final expr = arg.expression;

    // In Dart 2.12+ a constructor invocation can be written
    // without the `new` keyword, in which case the analyzer
    // represents it as a `MethodInvocation` (with a null
    // `target`) rather than an `InstanceCreationExpression`.
    // Both shapes are accepted here.
    final ctorName = _constructorNameOf(expr);
    if (ctorName == null) {
      log.warning(
        'GtkTemplate.source: must be a `GtkTemplateXml(...)` or '
        '`GtkTemplateFile(...)` constructor invocation; got '
        '`${expr.toSource()}`',
      );
      return null;
    }

    final args = _argumentListOf(expr);
    final argValue =
        args != null && args.arguments.isNotEmpty
            ? args.arguments.first
            : null;
    final literal = argValue is SimpleStringLiteral ? argValue.value : null;
    switch (ctorName) {
      case 'GtkTemplateXml':
        if (literal != null) return GtkTemplateXml(literal);
      case 'GtkTemplateFile':
        if (literal != null) return GtkTemplateFile(literal);
    }
    log.warning(
      'GtkTemplate.source: must be a `GtkTemplateXml(...)` or '
      '`GtkTemplateFile(...)` invocation with a string literal '
      'argument; got `${expr.toSource()}`',
    );
    return null;
  }

  // No `source:` argument. Could be the legacy 0.1.x
  // `resourcePath:` shape or simply a forgotten argument.
  log.warning(
    'GtkTemplate has no `source:` argument; the legacy 0.1.x '
    '`resourcePath:` form is no longer supported — see the '
    'CHANGELOG for the migration recipe.',
  );
  return null;
}

Annotation? _firstAnnotation(NodeList<Annotation> annotations, String name) {
  for (final ann in annotations) {
    if (ann.name.name == name) return ann;
  }
  return null;
}

/// In analyzer 10 `ClassDeclaration.body` is a sealed `ClassBody`
/// with no public members. The concrete body is always a
/// `BlockClassBody`; fall through to an empty list for any
/// future non-block body so the scanner doesn't crash on
/// abstract / native declarations.
List<ClassMember> _membersOf(ClassDeclaration decl) {
  final body = decl.body;
  return body is BlockClassBody ? body.members : const <ClassMember>[];
}

String? _findNamedStringArg(Annotation ann, String name) {
  final args = ann.arguments;
  if (args == null) return null;
  for (final arg in args.arguments) {
    if (arg is NamedExpression) {
      final label = arg.name.label;
      final expr = arg.expression;
      if (label.name == name && expr is SimpleStringLiteral) {
        return expr.value;
      }
    }
  }
  return null;
}

/// Returns the constructor name spelled in [expr], or `null` if
/// [expr] is neither an `InstanceCreationExpression` (i.e. has
/// an explicit `new`/`const` keyword) nor a `MethodInvocation`
/// with a `null` target (i.e. an implicit constructor call).
String? _constructorNameOf(Expression expr) {
  if (expr is InstanceCreationExpression) {
    return expr.constructorName.type.name.lexeme;
  }
  if (expr is MethodInvocation && expr.target == null) {
    return expr.methodName.name;
  }
  return null;
}

/// Returns the argument list of [expr] for both invocation
/// shapes — explicit `new` and implicit constructor call.
ArgumentList? _argumentListOf(Expression expr) {
  if (expr is InstanceCreationExpression) return expr.argumentList;
  if (expr is MethodInvocation) return expr.argumentList;
  return null;
}
