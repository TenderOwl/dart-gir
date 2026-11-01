// A Dart class with its own native type that declares properties.
//
// The point is that the property exists *natively*: it is installed with
// `g_object_class_install_property` while the type's class is
// initialized, and the type's `set_property` and `get_property` vfuncs
// carry the value to and from Dart.
//
// The lifecycle rule applies here as everywhere else in these bindings:
// a GObject that carries a Dart callback must not be finalized while the
// isolate shuts down, so every object in this suite is released before
// the test ends.
//
// Run with:
//   dart test test/dart_property_test.dart

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gobject/gir_gobject.dart';
import 'package:test/test.dart';

/// A Dart class whose type declares two properties.
class PropertyObject extends DartGObject {
  static int get GType => registerDartType(
    'PropertyObject',
    GObject.GType,
    properties: {
      'content': DartProperty.string(
        getter: (self) => (self! as PropertyObject).content,
        setter: (self, value) =>
            (self! as PropertyObject).content = value ?? '',
      ),
      'count': DartProperty.integer(
        getter: (self) => (self! as PropertyObject).count,
        setter: (self, value) => (self! as PropertyObject).count = value,
      ),
    },
  );

  PropertyObject() : super(GType);

  /// The value of the `content` property.
  String content = '';

  /// The value of the `count` property.
  int count = 0;
}

void main() {
  group('a Dart type that declares properties', () {
    test('the property is installed natively', () {
      final spec = dartPropertySpec(PropertyObject.GType, 'content');

      expect(spec, isNotNull);
      expect(spec!.getName(), 'content');
      // The value type the property declares.
      expect(
        dartPropertyValueType(PropertyObject.GType, 'content'),
        typeFromName('gchararray'),
      );
      expect(
        dartPropertyValueType(PropertyObject.GType, 'count'),
        typeFromName('gint'),
      );

      expect(dartPropertySpec(PropertyObject.GType, 'count'), isNotNull);
      expect(dartPropertySpec(PropertyObject.GType, 'missing'), isNull);
    });

    test('the Dart setter runs when the property is written', () {
      final object = PropertyObject();
      addTearDown(object.unref);
      expect(object.content, '');

      setDartProperty(object, 'content', 'hello');

      expect(object.content, 'hello');
    });

    test('the Dart getter runs when the property is read', () {
      final object = PropertyObject();
      addTearDown(object.unref);
      object.content = 'hello';

      expect(getDartProperty(object, 'content'), 'hello');
    });

    test('an integer property carries its value', () {
      final object = PropertyObject();
      addTearDown(object.unref);

      setDartProperty(object, 'count', 17);

      expect(object.count, 17);
      expect(getDartProperty(object, 'count'), 17);
    });

    test('the property is announced when it changes', () {
      final object = PropertyObject();
      addTearDown(object.unref);
      var notified = 0;

      object.onNotify((pspec) {
        notified++;
        expect(pspec.getName(), 'content');
      });

      setDartProperty(object, 'content', 'hello');

      expect(notified, 1);
    });

    test('a property the type does not declare throws', () {
      final object = PropertyObject();
      addTearDown(object.unref);

      expect(
        () => getDartProperty(object, 'missing'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => setDartProperty(object, 'missing', 1),
        throwsA(isA<StateError>()),
      );
    });
  });
}
