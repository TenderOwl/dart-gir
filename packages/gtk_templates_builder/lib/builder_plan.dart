/// Plan emitted by `GtkTemplatesBuilder` for a single Dart source
/// file.
///
/// The first cut returns the plan in-memory (from `scanSource`); the
/// follow-up PR will use it to drive code generation. Tests use the
/// plan to assert what the builder observed without going through
/// `build_runner`.
library;

import 'package:gtk_templates/gtk_templates.dart';

/// Result of scanning one Dart file for template annotations.
class BuilderPlan {
  /// Absolute or relative path of the source file, or `null` when
  /// the plan was built from an in-memory string.
  final String? filePath;

  /// One entry per top-level class carrying `@GtkTemplate`.
  final List<ClassTemplatePlan> classes;

  const BuilderPlan({this.filePath, required this.classes});

  bool get isEmpty => classes.isEmpty;
  bool get isNotEmpty => classes.isNotEmpty;

  BuilderPlan merge(BuilderPlan other) => BuilderPlan(
    filePath: other.filePath ?? filePath,
    classes: [...classes, ...other.classes],
  );

  @override
  String toString() => 'BuilderPlan($filePath, ${classes.length} classes)';
}

/// Per-class template wiring discovered by the builder.
class ClassTemplatePlan {
  /// Simple class name (no library prefix). The codegen will
  /// emit `_$<className>Template` in the same library.
  final String className;

  /// The parent class the user extends (e.g.
  /// `GtkApplicationWindow`). The codegen emits
  /// `mixin _$<className>Template on <parentType>` so the
  /// user can `with _$XTemplate` after the parent.
  final String parentType;

  /// Where the template XML comes from — either inline (a
  /// `GtkTemplateXml`) or a file at the package root (a
  /// `GtkTemplateFile`). The codegen reads it and emits a
  /// `GtkWidgetClass.setTemplate` call.
  final GtkTemplateSource templateSource;

  /// One entry per `@GtkTemplateChild` field. The list preserves
  /// declaration order so the generated binding code stays
  /// stable across regenerations.
  final List<WidgetBinding> children;

  /// One entry per `@GtkTemplateCallback` method. `callbackName`
  /// is the `snake_case` form the user-facing API expects.
  final List<CallbackBinding> callbacks;

  const ClassTemplatePlan({
    required this.className,
    required this.parentType,
    required this.templateSource,
    required this.children,
    required this.callbacks,
  });
}

/// A single `@GtkTemplateChild` field.
///
/// `childName` is the widget id from the `.ui` file (or the field
/// name itself when `@GtkTemplateChild` is used without `name:`);
/// `fieldName` is the Dart field the generated code will write
/// to.
class WidgetBinding {
  final String fieldName;
  final String childName;

  const WidgetBinding({required this.fieldName, required this.childName});

  @override
  String toString() => '$fieldName → $childName';
}

/// A single `@GtkTemplateCallback` method.
///
/// `methodName` is the Dart method on the user class;
/// `callbackName` is the `snake_case` symbol the template
/// expects (this is what `bindTemplateCallbackFull` receives
/// after the runtime's `snakeCase` conversion).
class CallbackBinding {
  final String methodName;
  final String callbackName;

  const CallbackBinding({
    required this.methodName,
    required this.callbackName,
  });

  @override
  String toString() => '$methodName ($callbackName)';
}
