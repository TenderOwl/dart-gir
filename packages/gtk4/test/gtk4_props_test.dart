// End-to-end test for the typed `props` accessor on GObject classes
// (PyGObject-style). Every GObject-rooted class now exposes a
// `<ClassName>Props` companion instance via `widget.props.<name>`. The
// getter and setter are thin wrappers over the existing typed
// `get<Name>` / `set<Name>` methods, so:
//   - `button.props.label`     == `button.getLabel()`
//   - `button.props.label = s` == `button.setLabel(s)`
//
// The accessor also reaches inherited GObject properties —
// `button.props.canFocus` is declared on `GtkWidget` but reachable on
// every descendant without re-declaring it, because `GtkButtonProps`
// `extends GtkWidgetProps` and the parent's accessors are inherited.
//
// Run with:
//   dart test test/gtk4_props_test.dart

import 'package:gtk4/gtk4.dart' as gtk show init;
import 'package:test/test.dart';

import 'package:gtk4/gtk4.dart';

void main() {
  setUpAll(() {
    // GTK4 needs to be initialized before any widget can be
    // constructed.
    gtk.init();
  });

  group('PyGObject-style props accessor on GtkButton', () {
    test('props.label round-trips through the typed getLabel/setLabel', () {
      final button = GtkButton();
      // A fresh button has no label set; write first so the
      // non-nullable `String` getter has something to return.
      button.props.label = 'Click me';
      expect(button.props.label, 'Click me');
      // Cross-check against the underlying typed method.
      expect(button.getLabel(), 'Click me');
    });

    test('props.canShrink writes through setCanShrink', () {
      final button = GtkButton();
      button.props.canShrink = true;
      expect(button.props.canShrink, isTrue);
      expect(button.getCanShrink(), isTrue);
    });

    test('inherited props.canFocus is reachable on GtkButton', () {
      // `canFocus` is declared on `GtkWidget` and surfaces on
      // `GtkWidgetProps`; `GtkButtonProps extends GtkWidgetProps`, so
      // the getter is inherited without re-declaration.
      final button = GtkButton();
      expect(button.props.canFocus, isA<bool>());
      // Toggling should also round-trip through the typed setter.
      final original = button.props.canFocus;
      button.props.canFocus = !original;
      expect(button.props.canFocus, equals(!original));
      // Restore so the test is idempotent.
      button.props.canFocus = original;
    });

    test('props getter/setter types match the underlying methods', () {
      // This is a runtime cross-check that the props accessor's
      // declared return and parameter types match what the typed
      // get/set methods actually return and accept. Compile-time
      // type safety is enforced by Dart: assigning
      // `button.props.label = 42` (int) or reading
      // `button.props.canShrink.length` (bool has no length) would
      // both fail at compile time. Here we just verify that the
      // runtime values expose the expected Dart types.
      final button = GtkButton();
      button.props.label = 'Hi';
      button.props.canShrink = false;
      expect(button.props.label.runtimeType, String);
      expect(button.props.canShrink.runtimeType, bool);
    });

    test('props is stable across accesses (single companion instance)', () {
      // The class declares `late final _props = ...`, so repeated
      // reads of `props` should return the same companion instance.
      final button = GtkButton();
      expect(identical(button.props, button.props), isTrue);
    });
  });
}
