// Verifies that the visitor correctly extracts @GtkTemplate /
// @TemplateChild / @TemplateCallback metadata from representative
// source files using package:build_test's in-memory analyzer.

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:test/test.dart';

import 'package:gtk_templates_builder/gtk_templates_builder.dart';

Builder get _builder => gtkTemplatesBuilder(BuilderOptions({}));

// Inlined source for the annotation package. See builder_test.dart
// for the full rationale.
const _annotationSources = {
  'gtk_templates|lib/gtk_templates.dart': '''
export 'src/gtk_template.dart';
export 'src/template_child.dart';
export 'src/template_callback.dart';
''',
  'gtk_templates|lib/src/gtk_template.dart': '''
class GtkTemplate {
  const GtkTemplate({required this.resourcePath});
  final String resourcePath;
}
''',
  'gtk_templates|lib/src/template_child.dart': '''
class TemplateChild {
  const TemplateChild({this.name = ''});
  final String name;
}
''',
  'gtk_templates|lib/src/template_callback.dart': '''
class TemplateCallback {
  const TemplateCallback([this.signalName = '']);
  final String signalName;
}
''',
};

void main() {
  test('visitor extracts the resource path from @GtkTemplate', () async {
    await testBuilder(
      _builder,
      {
        ..._annotationSources,
        'a|lib/main.dart': '''
import 'dart:ffi' as ffi;
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'main.gtk_templates.dart';

@GtkTemplate(resourcePath: '/com/example/extracted.ui')
class ParseMeWidget extends GtkBox {
  ParseMeWidget() : super();
}
''',
      },
      outputs: {
        'a|lib/main.gtk_templates.dart': decodedMatches(
          // The bind function is generated automatically — the
          // user no longer writes anything. Verify the builder
          // produces `bindParseMeWidgetTemplate()` and reads the
          // resource path verbatim from the annotation.
          allOf([
            contains('void bindParseMeWidgetTemplate() {'),
            contains(
                "widgetClass.setTemplateFromResource('/com/example/extracted.ui');"),
          ]),
        ),
      },
    );
  });

  test('visitor extracts snake_case fallback from method names', () async {
    await testBuilder(
      _builder,
      {
        ..._annotationSources,
        'a|lib/main.dart': '''
import 'dart:ffi' as ffi;
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'main.gtk_templates.dart';

@GtkTemplate(resourcePath: '/foo.ui')
class CallbackWidget extends GtkBox {
  CallbackWidget() : super() {
    initTemplate();
  }

  @TemplateCallback()
  void onSomethingHappened() {}
}
''',
      },
      outputs: {
        'a|lib/main.gtk_templates.dart': decodedMatches(
          contains('_\$CallbackWidget_onSomethingHappened'),
        ),
      },
    );
  });
}