// A fixture whose class declares a native type of its own.
//
// GTK keeps a template on the *native class* and allows exactly one per
// class, so a Dart class that registers a type of its own is what lets
// two Dart classes with the same parent each have a template. The
// generated mixin claims that type instead of the type the instance
// happens to have, and refuses an instance that is not one of it.
//
// This fixture is part of the package's analysis (it is no longer
// excluded in `analysis_options.yaml`): it is the fixture that proves
// the *generated* code type-checks — including the `GType` accessor and
// the `newDartInstance` call the class needs.
//
// The `own_type_window.ui` file lives next to this Dart file; the
// codegen reads it from the package root with the
// `test/fixtures/own_type_window.ui` path.

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gtk4/gir_gtk4.dart';
import 'package:gir_gtk_templates/gir_gtk_templates.dart';

part 'own_type_window.g.dart';

@GtkTemplate(source: GtkTemplateFile('test/fixtures/own_type_window.ui'))
class OwnTypeWindow extends GtkBox with _$OwnTypeWindowTemplate {
  /// The native type of this class.
  ///
  /// A type of its own is what lets the template live on *this* class.
  static int get GType => registerDartType('OwnTypeWindow', GtkBox.GType);

  OwnTypeWindow() : super.rawFromPointer(newDartInstance(GType), owned: true) {
    // GTK builds a widget's template in the instance initializer. Dart
    // has no instance-initializer hook, so the generated mixin exposes
    // `initTemplate()` and the widget calls it here.
    initTemplate();
  }
}
