// A Dart type that implements a native interface.
//
// The interface is added while the type's class is initialized, the way
// a native class adds one — GLib refuses an interface that is added
// after the class was initialized.
//
// Only an interface *without* methods can be implemented this way: an
// interface with methods needs the offsets of its vtable, and the
// introspection data does not carry them.
//
// Run with:
//   dart test test/dart_interface_test.dart

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gio/gir_gio.dart';
import 'package:gir_gobject/gir_gobject.dart';
import 'package:test/test.dart';

/// A Dart class whose type implements `GMemoryMonitor`.
class ActionObject extends DartGObject {
  static int get GType => registerDartType(
    'ActionObject',
    GObject.GType,
    // `GMemoryMonitor` requires `GInitable`; both are interfaces whose
    // vtable carries no method the type has to answer.
    interfaces: [GInitable.GType, GMemoryMonitor.GType],
  );

  ActionObject() : super(GType);
}

/// A Dart class whose type implements nothing.
class PlainObject extends DartGObject {
  static int get GType => registerDartType('PlainObject', GObject.GType);

  PlainObject() : super(GType);
}

void main() {
  group('a Dart type that implements an interface', () {
    test('the type implements the interface natively', () {
      final object = ActionObject();
      addTearDown(object.unref);

      expect(typeIsA(ActionObject.GType, GMemoryMonitor.GType), isTrue);
      expect(typeIsA(ActionObject.GType, GInitable.GType), isTrue);
      expect(typeIsA(ActionObject.GType, GObject.GType), isTrue);
    });

    test('the interface is per type', () {
      final plain = PlainObject();
      addTearDown(plain.unref);

      expect(typeIsA(PlainObject.GType, GMemoryMonitor.GType), isFalse);
    });
  });
}
