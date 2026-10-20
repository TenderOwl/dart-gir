import 'package:dart_gobject/dart_gobject.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:gobject/gobject.dart';
import 'package:test/test.dart';

/// A Dart class with a native type of its own.
class _Thing extends GObject {
  static int get GType => registerDartType('TestObject', GObject.GType);

  _Thing() : super(GType);

  final String payload = 'hello';
}

void main() {
  test('registerDartType registers a type GLib knows by name', () {
    final type = registerDartType('TestObject', GObject.GType);
    expect(type, isNot(0));
    expect(typeFromName('TestObject'), type);
    // Registering the same name again returns the type registered first.
    expect(registerDartType('TestObject', GObject.GType), type);
    expect(dartTypeOf('TestObject'), type);
  });

  test('an instance of the registered type reports its name', () {
    final thing = _Thing();
    expect(
      typeNameFromInstance(GTypeInstance.fromPointer(thing.handle)),
      'TestObject',
    );
    expect(typeIsA(_Thing.GType, GObject.GType), isTrue);
  });

  test('the wrapper cache keeps the Dart object across a round trip', () {
    final thing = _Thing();
    // The same pointer yields the same Dart object.
    expect(cachedObject<Object>(thing.handle.address), same(thing));
    expect(GObject.fromPointer(thing.handle), same(thing));
    // A pointer nothing was registered for has no Dart object.
    expect(cachedObject<Object>(thing.handle.address + 1024), isNull);
  });
}
