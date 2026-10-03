/// Internal model classes used by the visitor + emitter to describe
/// one annotated class. Not exported as part of the public API.
library;

/// A class annotated with `@GtkTemplate` plus its `@TemplateChild`
/// fields and `@TemplateCallback` methods.
class TemplateClass {
  TemplateClass({
    required this.className,
    required this.superTypeName,
    required this.resourcePath,
    required this.fields,
    required this.callbacks,
  });

  /// The Dart class name (e.g. `TodoWindow`).
  final String className;

  /// The Dart name of the immediate supertype, used to resolve the
  /// parent GType at registration time. E.g. `AdwApplicationWindow`.
  final String superTypeName;

  /// The GResource path passed to `@GtkTemplate(resourcePath: ...)`.
  final String resourcePath;

  final List<TemplateField> fields;
  final List<TemplateCallbackEntry> callbacks;
}

/// A `@TemplateChild()` field.
class TemplateField {
  TemplateField({
    required this.fieldName,
    required this.fieldType,
    required this.uiName,
  });

  /// The Dart field name (e.g. `titleLabel`).
  final String fieldName;

  /// The fully-qualified Dart type (e.g. `GtkLabel`).
  final String fieldType;

  /// The id used in the .ui file. Defaults to snake_case of
  /// [fieldName] when the annotation's `name:` parameter is empty.
  final String uiName;
}

/// A `@TemplateCallback`-annotated method.
class TemplateCallbackEntry {
  TemplateCallbackEntry({
    required this.methodName,
    required this.signalName,
    required this.isStatic,
  });

  /// The Dart method name (e.g. `onAddClicked`).
  final String methodName;

  /// The signal handler name in the .ui file. Defaults to
  /// snake_case of [methodName] when the annotation's
  /// `signalName:` parameter is empty.
  final String signalName;

  /// True for `@TemplateCallback` on a static method. Static methods
  /// cannot use `this`; the trampoline routes to a globally-bound
  /// dispatch that doesn't carry instance state.
  final bool isStatic;
}