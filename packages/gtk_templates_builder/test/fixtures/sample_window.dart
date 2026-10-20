// Annotated fixture used by `builder_test.dart`, `e2e_test.dart`
// and `generated_code_test.dart`.
//
// The codegen reads the template XML from the file path in
// `@GtkTemplate(source: ...)` and emits a `_$SampleWindowTemplate`
// mixin into `sample_window.g.dart`, a `part of` this library.
//
// Per the codegen design, the user does **not** declare the
// `late final` fields — the mixin provides them. The user `with`s
// the mixin and accesses the generated fields directly.
//
// The `sample_window.ui` file lives next to this Dart file; the
// codegen reads it from the package root with the
// `test/fixtures/sample_window.ui` path.
//
// This file is deliberately part of the package's analysis (it is
// no longer excluded in `analysis_options.yaml`): it is the
// fixture that proves the *generated* code type-checks. The
// imports below are the ones the generated part file relies on —
// it inherits them from this library.

import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'sample_window.g.dart';

@GtkTemplate(source: GtkTemplateFile('test/fixtures/sample_window.ui'))
class SampleWindow extends GtkApplicationWindow with _$SampleWindowTemplate {
  SampleWindow(super.app) {
    // GTK builds a widget's template in the instance initializer.
    // Dart has no instance-initializer hook, so the generated mixin
    // exposes `initTemplate()` and the widget calls it here.
    initTemplate();
  }

  // The mixin provides `counterLabel` and `increment` as
  // `late final` fields, populated from the template by
  // `getTemplateChild`. The mixin also wires the
  // `clicked` signal on `increment` to `onIncrementClicked`
  // via the per-instance `connectSignal` it emits.
  void onIncrementClicked() {
    counterLabel.props.label = 'Clicked!';
  }
}
