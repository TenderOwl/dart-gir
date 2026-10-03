/// Walks a [LibraryElement] to find every class annotated with
/// `@GtkTemplate` and extract the per-class field and method
/// annotations into a [TemplateClass] value.
///
/// Mirrors how `package:freezed` walks data-class declarations to
/// extract per-field metadata — we can't use `GeneratorForAnnotation`
/// because it only sees the top-level annotation and doesn't
/// recurse into fields/methods. We need `TypeChecker.firstAnnotationOf`
/// on each field/method after locating the annotated class.
library;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';

import 'package:gtk_templates/gtk_templates.dart';

import 'model.dart';
import 'naming.dart';

/// `package:source_gen`'s `TypeChecker` helpers. `fromRuntime` takes
/// the annotation class's runtime type; the analyzer walks imports
/// to find the matching annotation class symbol.
final _gtkTemplateChecker = TypeChecker.fromRuntime(GtkTemplate);
final _templateChildChecker = TypeChecker.fromRuntime(TemplateChild);
final _templateCallbackChecker = TypeChecker.fromRuntime(TemplateCallback);

class GtkTemplatesVisitor {
  /// Returns the list of annotated classes found. The order matches
  /// the declaration order in the source file, which matches the
  /// order in which `build_runner` resolves library elements.
  List<TemplateClass> visit(LibraryElement library) {
    final result = <TemplateClass>[];
    for (final unit in library.units) {
      for (final cls in unit.classes) {
        if (_gtkTemplateChecker.firstAnnotationOf(cls) == null) continue;
        // Found a class with @GtkTemplate. Now walk its fields
        // and methods to collect @TemplateChild and @TemplateCallback.
        final className = cls.name;
        final resourcePath = _readResourcePath(cls);
        final fields = <TemplateField>[];
        for (final f in cls.fields) {
          final ann = _templateChildChecker.firstAnnotationOf(f);
          if (ann == null) continue;
          final fieldName = f.name;
          final uiName = _readChildName(ann, fallback: toSnakeCase(fieldName));
          final fieldType = _typeName(f.type);
          fields.add(TemplateField(
            fieldName: fieldName,
            fieldType: fieldType,
            uiName: uiName,
          ));
        }
        final callbacks = <TemplateCallbackEntry>[];
        for (final m in cls.methods) {
          final ann = _templateCallbackChecker.firstAnnotationOf(m);
          if (ann == null) continue;
          final methodName = m.name;
          final signalName =
              _readSignalName(ann, fallback: toSnakeCase(methodName));
          callbacks.add(TemplateCallbackEntry(
            methodName: methodName,
            signalName: signalName,
            isStatic: m.isStatic,
          ));
        }
        final superTypeName = cls.supertype?.element.name ?? 'Object';
        result.add(TemplateClass(
          className: className,
          superTypeName: superTypeName,
          resourcePath: resourcePath,
          fields: fields,
          callbacks: callbacks,
        ));
      }
    }
    return result;
  }

  String _readResourcePath(Element cls) {
    // Read the `resourcePath` field of the @GtkTemplate annotation.
    // In source_gen 1.5+, `firstAnnotationOf` already returns the
    // evaluated `DartObject` — no further `computeConstantValue()`
    // call is needed.
    final obj = _gtkTemplateChecker.firstAnnotationOf(cls);
    if (obj == null || obj.type?.element == null) {
      throw InvalidGenerationSourceError(
        '@GtkTemplate annotation on ${cls.name} is not a const expression; '
        'the annotation must be a const constructor call',
        element: cls,
      );
    }
    final field = obj.getField('resourcePath');
    if (field == null || field.isNull) {
      throw InvalidGenerationSourceError(
        '@GtkTemplate on ${cls.name} requires a resourcePath',
        element: cls,
      );
    }
    final value = field.toStringValue();
    if (value == null || value.isEmpty) {
      throw InvalidGenerationSourceError(
        '@GtkTemplate on ${cls.name} requires a non-empty resourcePath',
        element: cls,
      );
    }
    return value;
  }

  String _readChildName(DartObject ann, {required String fallback}) {
    final field = ann.getField('name');
    final value = field?.toStringValue();
    if (value == null || value.isEmpty) return fallback;
    return value;
  }

  String _readSignalName(DartObject ann, {required String fallback}) {
    final field = ann.getField('signalName');
    final value = field?.toStringValue();
    if (value == null || value.isEmpty) return fallback;
    return value;
  }

  String _typeName(DartType t) {
    // Strip generic parameters for the helper signature; we only
    // emit the bare class name in the generated code (e.g.
    // `GtkLabel`, not `GtkLabel<int>`).
    return t.element?.name ?? t.toString();
  }
}