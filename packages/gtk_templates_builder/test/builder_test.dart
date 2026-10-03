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

// Minimal stubs for the GTK / Libadwaita parent types the builder's
// emitter looks up via `kHandBoundGetTypeCalls`. The test environment
// doesn't resolve `package:gtk4/gtk4.dart` from the on-disk generated
// bindings, so we declare the bare class shells here just to anchor
// the supertype resolution. The emitter never instantiates these;
// it only reads `cls.supertype?.element.name`.
const _gtkStubs = {
  'gtk4|lib/gtk4.dart': '''
class GtkWidget {}
class GtkBox extends GtkWidget {}
class GtkButton extends GtkWidget {}
class GtkApplicationWindow {}
class GtkBin extends GtkWidget {}
class GtkGrid extends GtkWidget {}
class GtkWindow extends GtkBin {}
''',
  'adw|lib/adw.dart': '''
class AdwApplicationWindow {}
''',
};

void main() {
  group('gtk_templates_builder', () {
    test('emits an empty output when no annotation is present', () async {
      await testBuilder(
        _builder,
        {
          ..._annotationSources,
          ..._gtkStubs,
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
          ..._gtkStubs,
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
            contains('// GtkTemplate installer + trampolines + per-field helpers for class FooWidget'),
            // The installer is named after the user class:
            // `bind<Name>Template()`. The user calls it from
            // `app.dart` (or equivalent) before constructing the
            // first instance.
            contains('void bindFooWidgetTemplate() {'),
            // Cached parent GType for the per-field helpers.
            contains('late int parentGtype;'),
            // Parent-class resolution. GtkBox is NOT in the
            // hand-binding whitelist (only `AdwApplicationWindow`
            // and `GtkApplicationWindow` are), so the emitter falls
            // back to `ensureTypeRegistered('GtkBox')` which throws
            // a clear error if the parent isn't registered yet.
            contains("ensureTypeRegistered('GtkBox')"),
          ])),
        },
      );
    });

    test('emits one helper per @TemplateChild field', () async {
      await testBuilder(
        _builder,
        {
          ..._annotationSources,
          ..._gtkStubs,
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
          ..._gtkStubs,
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
          ..._gtkStubs,
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
            // Per-field helpers take a `(self, String name)` pair —
            // the gtype comes from the per-class cache
            // (`parentGtype`), not from the caller. One less
            // argument per call site.
            contains(
                'InvalidType? _getChild_titleLabel(QuxWidget self, String name)'),
          ])),
        },
      );
    });

    test(
      'emits bind<Name>Template that calls <parent>_get_type for AdwApplicationWindow',
      () async {
        await testBuilder(
          _builder,
          {
            ..._annotationSources,
            'a|lib/main.dart': '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'main.gtk_templates.dart';

@GtkTemplate(resourcePath: '/foo.ui')
class AdwWindowSubclass extends AdwApplicationWindow {
  AdwWindowSubclass() : super();
}
''',
          },
          outputs: {
            'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
              // `AdwApplicationWindow` is in the hand-binding
              // whitelist, so the bind function emits a direct call
              // to `adwApplicationWindowGetType()` (no fallback
              // needed).
              contains(
                  "parentGtype = adwApplicationWindowGetType();"),
            ])),
          },
        );
      },
    );

    test(
      'emits bind<Name>Template that calls <parent>_get_type for GtkApplicationWindow',
      () async {
        await testBuilder(
          _builder,
          {
            ..._annotationSources,
            'a|lib/main.dart': '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'main.gtk_templates.dart';

@GtkTemplate(resourcePath: '/foo.ui')
class GtkAppWinSubclass extends GtkApplicationWindow {
  GtkAppWinSubclass() : super();
}
''',
          },
          outputs: {
            'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
              contains(
                  "parentGtype = gtkApplicationWindowGetType();"),
            ])),
          },
        );
      },
    );

    test(
      'emits bind<Name>Template that calls ensureTypeRegistered for unknown parents',
      () async {
        await testBuilder(
          _builder,
          {
            ..._annotationSources,
            'a|lib/main.dart': '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'main.gtk_templates.dart';

@GtkTemplate(resourcePath: '/foo.ui')
class Foo extends GtkButton {
  Foo() : super();
}
''',
          },
          outputs: {
            'a|lib/main.gtk_templates.dart': decodedMatches(allOf([
              // `GtkButton` is not in the hand-binding whitelist,
              // so the emitter falls back to
              // `ensureTypeRegistered('GtkButton')` which throws a
              // clear error if the parent isn't registered.
              contains("ensureTypeRegistered('GtkButton')"),
            ])),
          },
        );
      },
    );

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