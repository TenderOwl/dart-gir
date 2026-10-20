/// `build_runner` `Builder` for `@GtkTemplate` annotation scanning.
///
/// The builder scans every `.dart` input it is asked about and
/// emits **one part file per source file** — `<input>.g.dart`,
/// next to the source — holding a `_$<className>Template` mixin
/// per annotated class. The mixin registers the template with the
/// widget class, binds the per-instance children via
/// `getTemplateChild`, populates `late final` fields on demand,
/// and wires the XML's `<signal>` handlers to the user's instance
/// methods.
///
/// The user's source must declare `part '<input>.g.dart';`. The
/// builder checks for it and fails the build with an actionable
/// message when it is missing.
///
/// Because the generated file must sit in the same directory as
/// its library, consumers need `build_to: source` in their
/// `build.yaml`.
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

/// The `build_runner` entry point for [GtkTemplatesBuilder].
///
/// `build_config` resolves this by name from the package's
/// `build.yaml`, which is also where `build_to: source` lives —
/// the generated part file has to land next to its library,
/// because Dart requires a part file to sit in the same
/// directory as the source it belongs to.
Builder gtkTemplatesBuilder(BuilderOptions options) =>
    const GtkTemplatesBuilder();

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
    // One part file per source file: `<input>.g.dart`. The name
    // is derivable from the source file name alone, so the user
    // writes `part '<input>.g.dart';` and never has to predict a
    // class-derived name.
    //
    // The output must land **next to** the source file, because
    // Dart requires a part file to sit in the same directory as
    // its library. The provider package's `build.yaml` therefore
    // sets `build_to: source` — see that file.
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    // The `.dart` input extension also matches this builder's
    // own output. Skip the generated part files — they hold a
    // `part of` directive, not a `part` one, and are not
    // sources.
    if (buildStep.inputId.path.endsWith('.g.dart')) return;

    final source = await buildStep.readAsString(buildStep.inputId);
    final plan = scanSource(source, filePath: buildStep.inputId.path);
    if (plan.isEmpty) return;

    final partOfPath = _basename(buildStep.inputId.path);
    final partBasename = partFileBasename(partOfPath);

    // Fail loudly when the user's file does not pull the
    // generated file in. A silent failure here would surface as
    // "undefined mixin" at the use site, far from the cause.
    final diagnostic = checkPartDirective(source, partBasename);
    if (diagnostic != null) {
      final message = 'gtk_templates: ${buildStep.inputId.path}\n$diagnostic';
      log.severe(message);
      throw MissingPartDirectiveException(message);
    }

    final inputs = <CodegenInput>[];
    for (final cls in plan.classes) {
      final xmlString = await resolveTemplateXml(cls.templateSource, buildStep);
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
    if (inputs.isEmpty) return;

    // The generated file is a `part of` this library, so it
    // inherits this library's imports and cannot declare its
    // own. A missing import would surface as an "undefined
    // name" error inside the *generated* file — far from the
    // cause — so check up front.
    final typeNames = <String>[
      for (final input in inputs) input.parentType,
      for (final input in inputs) ...input.children.map((c) => c.typeName),
    ];
    final missingImports = checkRequiredImports(source, typeNames);
    if (missingImports.isNotEmpty) {
      final message =
          'gtk_templates: ${buildStep.inputId.path} is missing the '
          'imports the generated mixin needs:\n'
          '${missingImports.map((p) => "  import '$p';").join('\n')}\n'
          'The generated file is a `part of` this library and inherits its '
          'imports, so add the lines above to this file.';
      log.severe(message);
      throw MissingImportException(message);
    }

    final generated = formatGeneratedSource(codegenLibrary(inputs));
    final outputId = buildStep.inputId.changeExtension('.g.dart');
    await buildStep.writeAsString(outputId, generated);
  }
}

/// Thrown when the user's source file does not pull the generated
/// mixin in via a `part` directive.
///
/// `build_runner` swallows exceptions thrown by a builder and
/// reports them through the log, so the builder also calls
/// `log.severe` with the actionable message before throwing.
class MissingPartDirectiveException implements Exception {
  const MissingPartDirectiveException(this.message);

  /// The user-facing diagnostic, naming the exact `part` line to
  /// add.
  final String message;

  @override
  String toString() => message;
}

/// Thrown when the user's source file does not import the packages
/// the generated mixin needs.
///
/// `build_runner` swallows exceptions thrown by a builder and
/// reports them through the log, so the builder also calls
/// `log.severe` with the actionable message before throwing.
class MissingImportException implements Exception {
  const MissingImportException(this.message);

  /// The user-facing diagnostic, naming the exact import lines to
  /// add.
  final String message;

  @override
  String toString() => message;
}

/// Thrown when the template file named by a `GtkTemplateFile` cannot
/// be read.
///
/// `build_runner` swallows exceptions thrown by a builder and
/// reports them through the log, so the builder also calls
/// `log.severe` with the actionable message before throwing.
class MissingTemplateFileException implements Exception {
  const MissingTemplateFileException(this.message);

  /// The user-facing diagnostic, naming the package and the path
  /// that was looked for.
  final String message;

  @override
  String toString() => message;
}

/// Returns the basename (final path segment) of [path].
String _basename(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// Resolves the template XML for [source].
///
/// Inline XML (`GtkTemplateXml`) is returned as-is. A
/// `GtkTemplateFile` is read through the build's **asset reader**,
/// and that matters for two reasons:
///
///  * the file becomes a *tracked build input*, so editing the `.ui`
///    re-runs the builder. Read off the filesystem it would be
///    invisible to the build, the part file would keep the old
///    template, and the edit would silently do nothing;
///  * the path is resolved through the package's own asset id, so it
///    does not depend on the directory the build was started from.
///    In a workspace, `dart run build_runner build` at the root would
///    otherwise look for the file next to the root package.
///
/// Throws [MissingTemplateFileException] when the file cannot be
/// read. A build that cannot find its template has to fail: writing
/// nothing would leave the previous part file in place, and the
/// stale template would keep running as if nothing had changed.
Future<String> resolveTemplateXml(
  GtkTemplateSource source,
  BuildStep buildStep,
) async {
  if (source is GtkTemplateXml) return source.content;
  if (source is GtkTemplateFile) {
    final assetId = templateAssetId(source.path, buildStep.inputId.package);
    if (assetId != null && await buildStep.canRead(assetId)) {
      return buildStep.readAsString(assetId);
    }
    final message =
        'gtk_templates: ${buildStep.inputId.path} points at a template '
        'file that could not be read.\n'
        '  package: ${buildStep.inputId.package}\n'
        '  path:    ${source.path}\n'
        'The path is relative to the package root — the directory '
        'holding pubspec.yaml — and the file has to be inside the '
        'package.';
    log.severe(message);
    throw MissingTemplateFileException(message);
  }
  throw MissingTemplateFileException(
    'gtk_templates: ${buildStep.inputId.path} has a template source this '
    'builder does not understand: $source',
  );
}

/// The asset id of the template file at [path] in [package].
///
/// [path] is relative to the package root. Returns `null` when it is
/// not a usable asset path — absolute, or escaping the package with
/// `..`.
AssetId? templateAssetId(String path, String package) {
  try {
    return AssetId(package, path);
  } on ArgumentError {
    return null;
  }
}

/// The package root that owns [filePath] — the nearest ancestor
/// directory holding a `pubspec.yaml`.
///
/// Returns `null` when there is none.
String? findPackageRoot(String filePath) {
  var dir = File(filePath).absolute.parent;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
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
  // The parameter names of every method, so the codegen can forward
  // a signal's arguments to the user's method.
  final methodParameters = <String, List<String>>{};

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
      methodParameters[member.name.lexeme] = _parameterNames(member);
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
    methodParameters: methodParameters,
  );
}

/// The names of [member]'s parameters, in order.
///
/// Only the names matter: the codegen forwards a signal's arguments
/// to the user's method, and Dart infers the closure's parameter
/// types from the binding's callback type.
List<String> _parameterNames(MethodDeclaration member) {
  final parameters = member.parameters?.parameters;
  if (parameters == null) return const <String>[];
  final names = <String>[];
  for (final parameter in parameters) {
    final name = parameter.name?.lexeme;
    if (name != null) names.add(name);
  }
  return names;
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
    if (arg is! NamedArgument) continue;
    if (arg.name.lexeme != 'source') continue;
    // `argumentExpression` is the v1 projection. The v2 one
    // (`argumentExpression2`) returns a `ParsedValueArguments`
    // wrapper, while the rest of the scanner walks the v1 AST
    // (`InstanceCreationExpression`, `MethodInvocation`,
    // `SimpleStringLiteral`), so the v1 projection is the one
    // that fits.
    // ignore: deprecated_member_use
    final expr = arg.argumentExpression;

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
    final argValue = args != null && args.arguments.isNotEmpty
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
    if (arg is NamedArgument) {
      final label = arg.name.lexeme;
      // ignore: deprecated_member_use
      final expr = arg.argumentExpression;
      if (label == name && expr is SimpleStringLiteral) {
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
