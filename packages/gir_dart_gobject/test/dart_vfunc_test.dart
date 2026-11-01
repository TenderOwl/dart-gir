// A Dart class with its own native type that answers GObject's virtual
// calls.
//
// The point of the slice is that the native side can call *into* Dart:
// a `dispose` that GObject triggers reaches the Dart object, runs the
// Dart code and then chains up to the inherited implementation.
//
// The virtual functions are reached through the class struct's vtable —
// the layout is in `GObjectVtable` and is cross-checked against the
// installed header by `vtable_layout_test.dart`.
//
// The lifecycle rule applies here as everywhere else in these bindings:
// a GObject that carries a Dart callback must not be finalized while the
// isolate shuts down, so every object in this suite is released before
// the test ends.
//
// Run with:
//   dart test test/dart_vfunc_test.dart

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gobject/gir_gobject.dart';
import 'package:test/test.dart';

/// A Dart class with a native type of its own.
class CountingObject extends DartGObject {
  static int get GType =>
      registerDartType('CountingObject', GObject.GType, vfuncs: true);

  CountingObject() : super(GType);

  int constructedCalls = 0;
  int disposeCalls = 0;
  int finalizeCalls = 0;

  @override
  void dartConstructed() {
    constructedCalls++;
  }

  @override
  void dartDispose() {
    disposeCalls++;
  }

  @override
  void dartFinalize() {
    finalizeCalls++;
  }
}

/// A second Dart class, to prove the patch is per type.
class OtherObject extends DartGObject {
  static int get GType =>
      registerDartType('OtherObject', GObject.GType, vfuncs: true);

  OtherObject() : super(GType);

  int disposeCalls = 0;

  @override
  void dartDispose() {
    disposeCalls++;
  }
}

void main() {
  group('a Dart class with its own native type', () {
    test('the type is a real GType', () {
      final object = CountingObject();

      expect(CountingObject.GType, isNot(0));
      expect(CountingObject.GType, isNot(GObject.GType));
      // The native side sees the Dart type, not a plain GObject.
      expect(
        typeNameFromInstance(GTypeInstance.fromPointer(object.handle)),
        'CountingObject',
      );

      object.unref();
    });

    test('the constructed call reaches the Dart object', () {
      final object = CountingObject();

      // GObject calls `constructed` from `g_object_new` — before the
      // Dart wrapper exists — so the call is delivered once it does.
      expect(object.constructedCalls, 1);

      object.unref();
    });

    test('the dispose call reaches the Dart object', () {
      final object = CountingObject();
      expect(object.disposeCalls, 0);

      // Dropping the last reference makes GObject dispose the object.
      object.unref();

      expect(object.disposeCalls, 1);
    });

    test('the patch is per type', () {
      final other = OtherObject();
      final counting = CountingObject();

      other.unref();

      expect(other.disposeCalls, 1);
      expect(counting.disposeCalls, 0);

      counting.unref();
    });

    test('the inherited implementation still runs', () {
      // The inherited `dispose` is what releases the parent's resources.
      // If the Dart override did not chain up, the object would keep its
      // reference — the wrapper knows it no longer holds one.
      final object = CountingObject();

      object.unref();

      expect(object.owned, isFalse);
    });
  });
}
