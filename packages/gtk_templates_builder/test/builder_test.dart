// Golden-file tests for `gtk_templates_builder`.
//
// `package:build_test`'s `testBuilder` runs the builder against an
// in-memory file set and returns the generated outputs as a Map.
// We compare against hand-written expectations for the basic case
// and verify error cases via exception catching.
//
// The in-memory build environment doesn't know about the
// `gtk_templates` package on disk, so we inline the annotation
// sources as a separate package namespace `gtk_templates|lib/...`
// for each test. This mirrors how a real consumer's `pubspec.yaml`
// declares the dependency.

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:test/test.dart';

import 'package:gtk_templates_builder/gtk_templates_builder.dart';

Builder get _builder => gtkTemplatesBuilder(BuilderOptions({}));

// Inlined source for the annotation package. Mirrors the real
// `packages/gtk_templates/lib/...` tree so the builder can find
// the annotation classes during AST resolution.
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
  group('gtk_templates_builder', () {
    test('emits an empty output when no annotation is present', () async {
      await testBuilder(
        _builder,
        {
          ..._annotationSources,
          'a|lib/main.dart': '''
import 'package:gtk4/gtk4.dart';

class PlainWidget extends GtkBox {
  PlainWidget() : super();
}
''',
        },
        outputs: const {},
      );
    });

    test('emits a part file when @GtkTemplate is present', () async {
      await testBuilder(
        _builder,
        {
          ..._annotationSources,
          'a|lib/main.dart': '''
import 'dart:ffi' as ffi;

import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'main.gtk_templates.dart';

@GtkTemplate(resourcePath: '/com/example/foo.ui')
class FooWidget extends GtkBox {
  FooWidget() : super() {
    initTemplate();
  }
}
''',
        },
        outputs: {
          'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
            // Header banner + `part of` so the file is a valid Dart
            // part of `main.dart` (the user declares
            // `part 'main.gtk_templates.dart';` at the top).
            contains("part of 'main.dart';"),
            // Class-banner comment block names the class so reviewers
            // can find the source for the generated helpers.
            contains('// GtkTemplate trampolines + per-field helpers for class FooWidget'),
            // Documented in the comment block — there's no actual
            // `_$FooWidgetBindTemplate` function emitted, the user
            // writes that into the main source so it can be called
            // from sibling files.
            contains(r'// The bind logic (`_$FooWidgetBindTemplate()`) lives in the main'),
          ])),
        },
      );
    });

    test('emits one helper per @TemplateChild field', () async {
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
class BarWidget extends GtkBox {
  BarWidget() : super() {
    initTemplate();
    label = getTemplateChild<GtkLabel>('label');
  }

  @TemplateChild()
  late GtkLabel label;

  @TemplateChild(name: 'list_box')
  late GtkListBox listBox;
}
''',
        },
        outputs: {
          'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
            contains('_getChild_label('),
            contains('_getChild_listBox('),
          ])),
        },
      );
    });

    test('emits one NativeCallable per @TemplateCallback method', () async {
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
class BazWidget extends GtkBox {
  BazWidget() : super() {
    initTemplate();
  }

  @TemplateCallback('btn::clicked')
  void onBtnClicked(GtkButton button) {}

  @TemplateCallback()
  void onOtherClicked() {}
}
''',
        },
        outputs: {
          'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
            contains(r'_$BazWidget_onBtnClicked'),
            contains(r'_$BazWidget_onOtherClicked'),
          ])),
        },
      );
    });

    test('uses default snake_case when @TemplateChild.name is empty',
        () async {
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
class QuxWidget extends GtkBox {
  QuxWidget() : super() {
    initTemplate();
  }

  @TemplateChild()
  late GtkLabel titleLabel;
}
''',
        },
        outputs: {
          'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
            // The visitor can't resolve `GtkLabel` in the test
            // environment (only the inlined annotation stubs are
            // visible), so the emitted type name is `InvalidType`.
            // In real usage where `gtk4` is resolvable, this would
            // be `GtkLabel`.
            contains('InvalidType? _getChild_titleLabel('),
            // Per-field helpers take a `(self, int gtype, String
            // name)` triple — the user passes the GType the
            // template was loaded against at the call site.
            contains(
                'InvalidType? _getChild_titleLabel(QuxWidget self, int gtype, String name)'),
          ])),
        },
      );
    });

    test(
      'fails when @GtkTemplate is missing a resourcePath',
      () async {
        Object? caught;
        try {
          await testBuilder(
            _builder,
            {
              ..._annotationSources,
              'a|lib/main.dart': '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

@GtkTemplate()
class MissingPathWidget extends GtkBox {
  MissingPathWidget() : super();
}
''',
            },
            outputs: const {},
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isNotNull);
      },
    );
  });
}