// End-to-end test: feed a real annotated Dart file to
// `scanSource`, run the codegen, and verify the generated
// source parses as valid Dart.
//
// This test does **not** require a display server; the
// generated code references GTK types but is never
// actually compiled and run. The analysis is done via
// `package:analyzer`'s `parseString` in a tolerant mode.

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';
import 'package:test/test.dart';

void main() {
  group('end-to-end (scanSource + codegen + analyzer validation)', () {
    test('inline-XML class produces a parseable mixin', () {
      const source = r'''
        import 'package:gtk4/gtk4.dart';
        import 'package:gtk_templates/gtk_templates.dart';

        @GtkTemplate(source: GtkTemplateXml('<interface><template class="E2E" parent="GtkBox"><object class="GtkLabel" id="counterLabel"/><object class="GtkButton" id="button"/></template></interface>'))
        class E2E extends GtkBox with _$E2ETemplate {
          E2E();
        }
      ''';
      final plan = scanSource(source);
      expect(plan.classes, hasLength(1));
      final cls = plan.classes.single;
      expect(cls.className, 'E2E');
      expect(cls.parentType, 'GtkBox');
      expect(cls.templateSource, isA<GtkTemplateXml>());

      final xml = (cls.templateSource as GtkTemplateXml).content;
      final children = extractChildrenFromXml(xml);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: xml,
        xmlChildren: children,
      );
      final generated = codegenMixin(input);

      // The generated source must parse as Dart. The
      // analyzer will report `undefined` GTK types (since
      // we don't import gtk4 in this isolated parse), but
      // the parse itself must succeed.
      final result = parseString(
        content: generated,
        throwIfDiagnostics: false,
      );
      expect(result.errors, isEmpty, reason: 'generated source has parse errors: '
          '${result.errors.map((e) => e.message).take(3).join('; ')}');
    });

    test('the on-disk fixture produces a parseable mixin', () {
      final fixtureFile = File('test/fixtures/sample_window.dart');
      if (!fixtureFile.existsSync()) {
        fail('fixture file missing: ${fixtureFile.path}');
      }
      // The fixture references a `.ui` file that the
      // builder would normally read; for the parser test
      // we just need the class name, parent type, and the
      // path captured in the plan.
      final source = fixtureFile.readAsStringSync();
      final plan = scanSource(source, filePath: fixtureFile.path);
      expect(plan.classes, hasLength(1));
      final cls = plan.classes.single;
      expect(cls.className, 'SampleWindow');

      // The fixture currently uses `GtkTemplateFile` —
      // the file is not on disk for the e2e parser test
      // (the actual `.ui` file is what the real builder
      // would resolve). For this test, we assert the
      // scanner captured the path correctly and the
      // codegen accepts a (synthetic) XML body.
      expect(cls.templateSource, isA<GtkTemplateFile>());
      final src = (cls.templateSource as GtkTemplateFile).path;
      expect(src, 'test/fixtures/sample_window.ui');

      // Synthesize a minimal XML for the codegen so the
      // output has a real children list. The real
      // builder would read the file at this point.
      const syntheticXml = '<interface><template class="SampleWindow" '
          'parent="GtkApplicationWindow">'
          '<object class="GtkLabel" id="counterLabel"/>'
          '<object class="GtkButton" id="increment"/>'
          '</template></interface>';
      final children = extractChildrenFromXml(syntheticXml);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: syntheticXml,
        xmlChildren: children,
      );
      final generated = codegenMixin(input);

      final result = parseString(
        content: generated,
        throwIfDiagnostics: false,
      );
      expect(result.errors, isEmpty, reason: 'generated source has parse errors: '
          '${result.errors.map((e) => e.message).take(3).join('; ')}');

      // Spot-check a few invariants in the generated text.
      expect(
        generated,
        contains('mixin _\$SampleWindowTemplate on GtkApplicationWindow'),
      );
      expect(generated, contains('late final GtkLabel counterLabel = '));
      expect(generated, contains('late final GtkButton increment = '));
    });

    test('a class with no children produces a valid mixin', () {
      const source = '''
        @GtkTemplate(source: GtkTemplateXml('<interface><template class="Empty" parent="GtkBox"/></interface>'))
        class Empty extends GtkBox with _\$EmptyTemplate {
          Empty();
        }
      ''';
      final plan = scanSource(source);
      final cls = plan.classes.single;
      final xml = (cls.templateSource as GtkTemplateXml).content;
      final children = extractChildrenFromXml(xml);
      expect(children, isEmpty);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: xml,
        xmlChildren: children,
      );
      final generated = codegenMixin(input);
      final result = parseString(
        content: generated,
        throwIfDiagnostics: false,
      );
      expect(result.errors, isEmpty);
      expect(generated, contains('mixin _\$EmptyTemplate on GtkBox'));
    });
  });
}
