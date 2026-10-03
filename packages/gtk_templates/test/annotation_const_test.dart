import 'package:gtk_templates/gtk_templates.dart';
import 'package:test/test.dart';

void main() {
  group('GtkTemplate annotation', () {
    test('constructs with required resourcePath', () {
      const ann = GtkTemplate(resourcePath: '/com/example/foo.ui');
      expect(ann.resourcePath, equals('/com/example/foo.ui'));
    });

    test('is const-constructible', () {
      const a = GtkTemplate(resourcePath: '/a');
      const b = GtkTemplate(resourcePath: '/a');
      expect(identical(a, b), isTrue);
    });

    test('different paths produce different instances', () {
      const a = GtkTemplate(resourcePath: '/a');
      const b = GtkTemplate(resourcePath: '/b');
      expect(a.resourcePath, isNot(equals(b.resourcePath)));
    });
  });

  group('TemplateChild annotation', () {
    test('default name is empty string', () {
      const ann = TemplateChild();
      expect(ann.name, equals(''));
    });

    test('explicit name is stored', () {
      const ann = TemplateChild(name: 'custom-id');
      expect(ann.name, equals('custom-id'));
    });

    test('is const-constructible', () {
      const a = TemplateChild();
      const b = TemplateChild();
      expect(identical(a, b), isTrue);
    });
  });

  group('TemplateCallback annotation', () {
    test('default signalName is empty string', () {
      const ann = TemplateCallback();
      expect(ann.signalName, equals(''));
    });

    test('positional signalName is stored', () {
      const ann = TemplateCallback('add-button::clicked');
      expect(ann.signalName, equals('add-button::clicked'));
    });

    test('is const-constructible', () {
      const a = TemplateCallback();
      const b = TemplateCallback();
      expect(identical(a, b), isTrue);
    });
  });

  group('Library exports', () {
    test('all three annotations are exported from gtk_templates.dart', () {
      expect(GtkTemplate, isNotNull);
      expect(TemplateChild, isNotNull);
      expect(TemplateCallback, isNotNull);
    });
  });
}