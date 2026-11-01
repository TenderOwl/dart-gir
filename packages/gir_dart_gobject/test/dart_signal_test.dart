// A Dart class with its own native type that declares signals.
//
// The point is that the signal exists *natively*: it is created with
// `g_signal_newv` while the type's class is initialized, so the native
// side finds it with `g_signal_lookup`, and the Dart handler runs when
// the signal is emitted.
//
// The lifecycle rule applies here as everywhere else in these bindings:
// a GObject that carries a Dart callback must not be finalized while the
// isolate shuts down, so every object in this suite is released before
// the test ends.
//
// Run with:
//   dart test test/dart_signal_test.dart

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gobject/gir_gobject.dart';
import 'package:test/test.dart';

/// A Dart class whose type declares two signals.
class SignalObject extends DartGObject {
  static int get GType => registerDartType(
    'SignalObject',
    GObject.GType,
    signals: {
      'completed': DartSignal.withoutArgument((self) {
        (self! as SignalObject).completedCalls++;
      }),
      'progress': DartSignal.withArgument(DartSignalArgument.integer, (
        self,
        value,
      ) {
        final object = self! as SignalObject;
        object.progressCalls++;
        object.lastProgress = value as int?;
      }),
    },
  );

  SignalObject() : super(GType);

  /// How often the `completed` handler ran.
  int completedCalls = 0;

  /// How often the `progress` handler ran.
  int progressCalls = 0;

  /// The argument the `progress` handler last received.
  Object? lastProgress;
}

/// A second Dart class, to prove the signals are per type.
class OtherSignalObject extends DartGObject {
  static int get GType => registerDartType(
    'OtherSignalObject',
    GObject.GType,
    signals: {
      'completed': DartSignal.withoutArgument((self) {
        (self! as OtherSignalObject).completedCalls++;
      }),
    },
  );

  OtherSignalObject() : super(GType);

  /// How often the `completed` handler ran.
  int completedCalls = 0;
}

void main() {
  group('a Dart type that declares signals', () {
    test('the signal exists natively', () {
      // `g_signal_lookup` finds it: the signal was created while the
      // type's class was initialized, not in Dart.
      expect(signalLookup('completed', SignalObject.GType), isNot(0));
      expect(signalLookup('progress', SignalObject.GType), isNot(0));
      expect(dartSignalId(SignalObject.GType, 'completed'), isNotNull);

      // A type that declares no signal has none.
      expect(dartSignalId(OtherSignalObject.GType, 'progress'), isNull);
    });

    test('the Dart handler runs when the signal is emitted', () {
      final object = SignalObject();
      addTearDown(object.unref);
      expect(object.completedCalls, 0);

      emitDartSignal(object, 'completed');

      expect(object.completedCalls, 1);
    });

    test('the argument reaches the handler', () {
      final object = SignalObject();
      addTearDown(object.unref);

      emitDartSignal(object, 'progress', 42);

      expect(object.progressCalls, 1);
      expect(object.lastProgress, 42);
    });

    test('a connected handler runs too', () {
      final object = SignalObject();
      addTearDown(object.unref);
      var connectedCalls = 0;

      connectDartSignal(object, 'completed', (self, args) {
        connectedCalls++;
        expect(args, isEmpty);
      });

      emitDartSignal(object, 'completed');

      expect(connectedCalls, 1);
      // The type's own handler ran as well.
      expect(object.completedCalls, 1);
    });

    test('a connected handler receives the argument', () {
      final object = SignalObject();
      addTearDown(object.unref);
      Object? received;

      connectDartSignal(object, 'progress', (self, args) {
        received = args.isEmpty ? null : args.first;
      });

      emitDartSignal(object, 'progress', 7);

      expect(received, 7);
    });

    test('the signals are per type', () {
      final other = OtherSignalObject();
      final signal = SignalObject();
      addTearDown(other.unref);
      addTearDown(signal.unref);

      emitDartSignal(other, 'completed');

      expect(other.completedCalls, 1);
      expect(signal.completedCalls, 0);
    });

    test('emitting a signal the type does not declare throws', () {
      final object = SignalObject();
      addTearDown(object.unref);

      expect(
        () => emitDartSignal(object, 'missing'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
