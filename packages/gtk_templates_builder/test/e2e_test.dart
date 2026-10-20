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
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/probe.dart';

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
      final signals = extractSignalsFromXml(xml);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: xml,
        xmlChildren: children,
        xmlSignals: signals,
        partOfPath: 'e2e.dart',
      );
      final generated = codegenMixin(input);

      // The generated source must parse as Dart. The
      // analyzer will report `undefined` GTK types (since
      // we don't import gtk4 in this isolated parse), but
      // the parse itself must succeed.
      final result = parseString(content: generated, throwIfDiagnostics: false);
      expect(
        result.errors,
        isEmpty,
        reason:
            'generated source has parse errors: '
            '${result.errors.map((e) => e.message).take(3).join('; ')}',
      );
    });

    test('the on-disk fixture produces a parseable mixin', () async {
      // The fixture path is resolved against the package root, not
      // the current directory — `dart test` may run from the
      // workspace root.
      final root = await packageRoot();
      final fixtureFile = File(
        p.join(root.path, 'test', 'fixtures', 'sample_window.dart'),
      );
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
      const syntheticXml =
          '<interface><template class="SampleWindow" '
          'parent="GtkApplicationWindow">'
          '<object class="GtkLabel" id="counterLabel"/>'
          '<object class="GtkButton" id="increment"/>'
          '</template></interface>';
      final children = extractChildrenFromXml(syntheticXml);
      final signals = extractSignalsFromXml(syntheticXml);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: syntheticXml,
        xmlChildren: children,
        xmlSignals: signals,
        partOfPath: 'sample_window.dart',
      );
      final generated = codegenMixin(input);

      final result = parseString(content: generated, throwIfDiagnostics: false);
      expect(
        result.errors,
        isEmpty,
        reason:
            'generated source has parse errors: '
            '${result.errors.map((e) => e.message).take(3).join('; ')}',
      );

      // Spot-check a few invariants in the generated text.
      expect(
        generated,
        contains('mixin _\$SampleWindowTemplate on GtkApplicationWindow'),
      );
      expect(generated, contains('late final GtkLabel counterLabel = '));
      expect(generated, contains('late final GtkButton increment = '));
      expect(generated, contains("part of 'sample_window.dart';"));
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
      final signals = extractSignalsFromXml(xml);
      final input = CodegenInput.fromPlan(
        cls,
        xmlString: xml,
        xmlChildren: children,
        xmlSignals: signals,
        partOfPath: 'empty.dart',
      );
      final generated = codegenMixin(input);
      final result = parseString(content: generated, throwIfDiagnostics: false);
      expect(result.errors, isEmpty);
      expect(generated, contains('mixin _\$EmptyTemplate on GtkBox'));
    });
  });

  group('the generated file honours the part-file contract', () {
    /// A class with one child and one signal.
    CodegenInput _input(String partOfPath) {
      const xml =
          '<interface><template class="Sample" parent="GtkBox">'
          '<object class="GtkLabel" id="counterLabel"/>'
          '<object class="GtkButton" id="button">'
          '<signal name="clicked" handler="on_clicked"/>'
          '</object>'
          '</template></interface>';
      final plan = scanSource(
        "@GtkTemplate(source: GtkTemplateXml('$xml'))\n"
        'class Sample extends GtkBox { Sample(); }',
      );
      return CodegenInput.fromPlan(
        plan.classes.single,
        xmlString: xml,
        xmlChildren: extractChildrenFromXml(xml),
        xmlSignals: extractSignalsFromXml(xml),
        partOfPath: partOfPath,
      );
    }

    test('the part directive names the input file, not the class', () {
      final generated = codegenMixin(_input('my_window.dart'));
      expect(generated, contains("part of 'my_window.dart';"));
      expect(generated, isNot(contains('todowindow')));
    });

    test('the partOfPath argument is what ends up in the directive', () {
      final generated = codegenMixin(_input('other.dart'));
      expect(generated, contains("part of 'other.dart';"));
    });

    test('the generated file carries no imports of its own', () {
      // It is a `part of` the user's library and inherits that
      // library's imports.
      final generated = codegenMixin(_input('my_window.dart'));
      expect(generated, isNot(contains("import 'package:")));
    });

    test('the trampoline dispatches through `dynamic`', () {
      // The mixin is `on <ParentType>`, so the analyzer rejects a
      // direct call to a user-defined method on `this`. The
      // dispatch goes through `dynamic` instead.
      final generated = codegenMixin(_input('my_window.dart'));
      expect(
        generated,
        contains('button.onClicked(() => (this as dynamic).onClicked())'),
      );
    });

    test('the removed callback spec is not emitted', () {
      // The callback table is gone: the trampoline reads the
      // `<signal>` entries straight from the XML.
      final generated = codegenMixin(_input('my_window.dart'));
      expect(generated, isNot(contains('_TemplateCallbackSpec')));
      expect(generated, isNot(contains('Template_callbacks')));
    });

    test('the part file name is derived from the source file name', () {
      expect(partFileBasename('todo_window.dart'), 'todo_window.g.dart');
      expect(partFileBasename('my-window.dart'), 'my-window.g.dart');
      expect(partFileBasename('noext'), 'noext.g.dart');
    });

    test('the part directive check names the exact line to add', () {
      expect(
        checkPartDirective("part 'x.g.dart';", 'x.g.dart'),
        isNull,
        reason: 'a matching directive is accepted',
      );

      final missing = checkPartDirective('import \'a.dart\';', 'x.g.dart');
      expect(missing, isNotNull);
      expect(missing, contains("part 'x.g.dart';"));

      final stale = checkPartDirective("part 'old.g.dart';", 'x.g.dart');
      expect(stale, isNotNull);
      expect(stale, contains("part 'x.g.dart';"));
    });
  });

  group('the XML extractors handle nesting and self-closing tags', () {
    test('a signal belongs to its own object, not the previous one', () {
      const xml =
          '<interface><template class="T" parent="GtkBox">'
          '<object class="GtkLabel" id="counterLabel"/>'
          '<object class="GtkButton" id="button">'
          '<signal name="clicked" handler="on_clicked"/>'
          '</object>'
          '</template></interface>';
      final signals = extractSignalsFromXml(xml);
      expect(signals, hasLength(1));
      expect(signals.single.childId, 'button');
      expect(signals.single.childType, 'GtkButton');
      expect(signals.single.methodName, 'onClicked');
    });

    test('a signal on a nested object belongs to the nested object', () {
      const xml =
          '<interface><template class="T" parent="GtkBox">'
          '<object class="GtkBox" id="outer">'
          '<object class="GtkButton" id="inner">'
          '<signal name="clicked" handler="on_clicked"/>'
          '</object>'
          '</object>'
          '</template></interface>';
      final signals = extractSignalsFromXml(xml);
      expect(signals, hasLength(1));
      expect(signals.single.childId, 'inner');
      expect(signals.single.childType, 'GtkButton');
    });

    test('children are extracted regardless of attribute order', () {
      const xml =
          '<interface><template class="T" parent="GtkBox">'
          '<object id="byIdFirst" class="GtkLabel"/>'
          '</template></interface>';
      final children = extractChildrenFromXml(xml);
      expect(children, hasLength(1));
      expect(children.single.id, 'byIdFirst');
      expect(children.single.typeName, 'GtkLabel');
    });
  });
}
