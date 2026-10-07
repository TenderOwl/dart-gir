// Annotated fixture used by `builder_test.dart` and
// `e2e_test.dart`. The codegen reads the template XML from
// the file path in `@GtkTemplate(source: ...)` and emits a
// `_$SampleWindowTemplate` mixin next to it.
//
// Per the 0.3.0 codegen design, the user does **not**
// declare the `late final` fields — the mixin provides
// them. The user `with`s the mixin and accesses the
// generated fields directly.
//
// The `sample_window.ui` file lives next to this Dart
// file; the codegen reads it from the package root with
// the `test/fixtures/sample_window.ui` path.

import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

@GtkTemplate(source: GtkTemplateFile('test/fixtures/sample_window.ui'))
class SampleWindow extends GtkApplicationWindow with _$SampleWindowTemplate {
  SampleWindow(super.app);

  // The mixin provides `counterLabel` and `increment` as
  // `late final` fields, populated from the template by
  // `getTemplateChild`. Callbacks are wired manually via
  // `connectSignal(...)` in this first cut.
}
