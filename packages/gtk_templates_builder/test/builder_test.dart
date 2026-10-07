import 'dart:io';

import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';
import 'package:test/test.dart';

void main() {
  group('scanSource', () {
    test('returns empty plan for source with no annotated classes', () {
      final plan = scanSource(
        '''
        class PlainBox extends GtkBox {
          late final GtkLabel label;
        }
        ''',
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.classes, isEmpty);
    });

    test(
      'extracts GtkTemplateXml, children, and callbacks from one class',
      () {
        const source = r'''
        import 'package:gtk4/gtk4.dart';
        import 'package:gtk_templates/gtk_templates.dart';

        @GtkTemplate(source: GtkTemplateXml('<interface><template class="FooBar" parent="GtkBox"><object class="GtkLabel" id="my_label"/><object class="GtkButton" id="button"/></template></interface>'))
        class FooBar extends GtkBox {
          @GtkTemplateChild(name: 'my_label')
          late final GtkLabel label;

          @GtkTemplateChild()
          late final GtkButton button;

          FooBar();

          @GtkTemplateCallback()
          void onClicked(GtkWidget sender) {}

          @GtkTemplateCallback()
          void helloButtonClicked() {}
        }
      ''';
        final plan = scanSource(source);

        expect(plan.classes, hasLength(1));
        final cls = plan.classes.single;
        expect(cls.className, 'FooBar');

        final src = cls.templateSource;
        expect(src, isA<GtkTemplateXml>());
        final xml = src as GtkTemplateXml;
        expect(xml.content, contains('<interface>'));
        expect(xml.content, contains('id="my_label"'));

        expect(cls.children, hasLength(2));
        expect(cls.children[0].fieldName, 'label');
        expect(cls.children[0].childName, 'my_label');
        expect(cls.children[1].fieldName, 'button');
        expect(cls.children[1].childName, 'button');

        expect(cls.callbacks, hasLength(2));
        expect(cls.callbacks[0].methodName, 'onClicked');
        expect(cls.callbacks[0].callbackName, 'on_clicked');
        expect(cls.callbacks[1].methodName, 'helloButtonClicked');
        expect(cls.callbacks[1].callbackName, 'hello_button_clicked');
      },
    );

    test('extracts GtkTemplateFile path verbatim', () {
      const source = '''
        @GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
        class FromFile extends GtkBox {
          @GtkTemplateChild()
          late final GtkLabel first;
        }
      ''';
      final plan = scanSource(source);

      expect(plan.classes, hasLength(1));
      final cls = plan.classes.single;
      expect(cls.className, 'FromFile');
      expect(cls.templateSource, isA<GtkTemplateFile>());
      expect(
        (cls.templateSource as GtkTemplateFile).path,
        'lib/myapp/window.ui',
      );
    });

    test('captures multiple annotated classes in declaration order', () {
      const source = '''
        @GtkTemplate(source: GtkTemplateXml('<interface/>'))
        class One extends GtkBox {
          @GtkTemplateChild()
          late final GtkLabel first;
        }

        @GtkTemplate(source: GtkTemplateFile('lib/two.ui'))
        class Two extends GtkBox {
          @GtkTemplateChild()
          late final GtkLabel second;

          @GtkTemplateCallback()
          void onTwo() {}
        }
      ''';
      final plan = scanSource(source);

      expect(plan.classes.map((c) => c.className), ['One', 'Two']);
      expect(plan.classes[0].callbacks, isEmpty);
      expect(plan.classes[1].callbacks.single.methodName, 'onTwo');
      expect(plan.classes[1].callbacks.single.callbackName, 'on_two');
    });

    test('ignores fields and methods without template annotations', () {
      const source = '''
        @GtkTemplate(source: GtkTemplateXml('<interface/>'))
        class Mixed extends GtkBox {
          late final int count; // no @GtkTemplateChild

          void helper() {} // no @GtkTemplateCallback
        }
      ''';
      final plan = scanSource(source);

      expect(plan.classes.single.children, isEmpty);
      expect(plan.classes.single.callbacks, isEmpty);
    });

    test('@GtkTemplate() with no source: is skipped', () {
      const source = '''
        @GtkTemplate()
        class NoSource extends GtkBox {}
      ''';
      final plan = scanSource(source);
      expect(plan.classes, isEmpty);
    });

    test('legacy 0.1.x @GtkTemplate(resourcePath: ...) is skipped', () {
      const source = '''
        @GtkTemplate(resourcePath: '/com/example/legacy.ui')
        class Legacy extends GtkBox {}
      ''';
      final plan = scanSource(source);
      expect(plan.classes, isEmpty);
    });

    test('@GtkTemplate(source: notAConstructor) is skipped', () {
      // A bare variable in source position; the scanner can
      // not statically prove it is one of the two supported
      // constructor invocations.
      const source = '''
        final s = GtkTemplateXml('<interface/>');
        @GtkTemplate(source: s)
        class VarSource extends GtkBox {}
      ''';
      final plan = scanSource(source);
      expect(plan.classes, isEmpty);
    });

    test('reads source and child name from the on-disk fixture', () {
      final source = File(
        'test/fixtures/sample_window.dart',
      ).readAsStringSync();
      final plan = scanSource(
        source,
        filePath: 'test/fixtures/sample_window.dart',
      );

      expect(plan.filePath, 'test/fixtures/sample_window.dart');
      expect(plan.classes, hasLength(1));
      final cls = plan.classes.single;
      expect(cls.className, 'SampleWindow');
      expect(cls.parentType, 'GtkApplicationWindow');
      expect(cls.templateSource, isA<GtkTemplateFile>());
      expect(
        (cls.templateSource as GtkTemplateFile).path,
        'test/fixtures/sample_window.ui',
      );
      // In the 0.3.0 codegen design, the user does **not**
      // declare `late final` fields — the mixin provides
      // them. The scanner therefore returns an empty
      // children list. The XML is the source of truth and
      // is read by the codegen, not the scanner.
      expect(cls.children, isEmpty);
      expect(cls.callbacks, isEmpty);
    });
  });
}
