import 'dart:ffi' as ffi;

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gio/gir_gio.dart';
import 'package:gir_gobject/gir_gobject.dart';
import 'package:test/test.dart';

void main() {
  group('newDartInstance', () {
    test('creates an instance of the type itself, not of its parent', () {
      final type = registerDartType('ConstructionPlain', GObject.GType);

      final handle = newDartInstance(type);
      expect(handle, isNot(ffi.nullptr));

      final object = GObject.fromPointer(handle, owned: true);
      expect(
        typeNameFromInstance(GTypeInstance.fromPointer(handle)),
        'ConstructionPlain',
      );
      expect(object.handle, handle);
    });

    test('hands the construct properties to the constructor', () {
      // `GSimpleAction`'s `name` is a construct-only property: it can
      // only be set while the object is constructed.
      final type = registerDartType('ConstructionAction', GSimpleAction.GType);

      final handle = newDartInstance(
        type,
        constructProperties: {'name': 'hello'},
      );
      final action = GSimpleAction.fromPointer(handle, owned: true);

      expect(action.getName(), 'hello');
    });

    test('the instance belongs to the derived type', () {
      final type = registerDartType('ConstructionAction2', GSimpleAction.GType);

      final handle = newDartInstance(
        type,
        constructProperties: {'name': 'second'},
      );
      final action = GSimpleAction.fromPointer(handle, owned: true);

      expect(
        typeNameFromInstance(GTypeInstance.fromPointer(handle)),
        'ConstructionAction2',
      );
      expect(action.getName(), 'second');
    });

    test('a value of the wrong type is refused', () {
      final type = registerDartType('ConstructionBad', GSimpleAction.GType);

      expect(
        () => newDartInstance(type, constructProperties: {'name': 42}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a property the type does not have is refused', () {
      final type = registerDartType('ConstructionMissing', GSimpleAction.GType);

      expect(
        () => newDartInstance(type, constructProperties: {'nonsense': 'value'}),
        throwsA(anything),
      );
    });
  });
}
