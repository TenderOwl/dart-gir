// Dart-level subclassing of a generated GObject wrapper.
//
// Generated GObject classes are emitted as `class` (not `final class`)
// and their `<ClassName>Props` companions are public and extendable.
// That is what makes this file legal:
//
//   class TitledButton extends GtkButton { … }
//   class TitledButtonProps extends GtkButtonProps { … }
//
// The rules that come with it — who owns the native pointer, what a
// covariant override asserts, and what a Dart subclass is *not* — are
// written down in docs/subclassing.md.
//
// Run with:
//   dart test test/gtk4_subclass_test.dart

import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart' as gtk show init;
import 'package:test/test.dart';

import 'package:gtk4/gtk4.dart';

/// A Dart subclass of the generated [GtkButton] wrapper.
///
/// It is the *same* native button — `super()` allocates one
/// `GtkButton` and this class adds Dart-side behaviour on top. No
/// second native object is created.
class TitledButton extends GtkButton {
  TitledButton(String label) {
    setLabel(label);
  }

  /// A covariant override of [GtkWidget.getParent]: Dart allows a
  /// narrower return type.
  ///
  /// The native object is untouched — this changes the *static* Dart
  /// type only — so the override has to earn the narrower type at
  /// run time. Here it checks the GObject type name before narrowing
  /// and returns null when the parent is not a button. An override
  /// that narrowed without checking would hand callers a
  /// `GtkButton` wrapping something that is not a button, and the
  /// failure would surface later as a misbehaving native call.
  @override
  GtkButton? getParent() {
    final parent = super.getParent();
    if (parent == null) return null;
    final name = typeNameFromInstance(GTypeInstance.fromPointer(parent.handle));
    if (name != 'GtkButton') return null;
    return parent.cast<GtkButton>(GtkButton.fromPointer);
  }

  /// The unnarrowed parent, for comparison with [getParent].
  ///
  /// Dart dispatches virtually, so an override replaces the behaviour
  /// for *every* caller — including one holding a base-typed
  /// reference. `super.getParent()` is the only way back to the
  /// generated implementation.
  GtkWidget? getRawParent() => super.getParent();

  /// A covariant override of the `props` getter.
  ///
  /// The generated class exposes `GtkButtonProps get props`; this
  /// narrows it to the user-side companion. The generated companion's
  /// own `_props` field is never read, so it is never initialised —
  /// the override replaces it entirely.
  late final TitledButtonProps _titledProps = TitledButtonProps(this);

  @override
  TitledButtonProps get props => _titledProps;
}

/// A props companion for [TitledButton].
///
/// It extends the generated [GtkButtonProps], so every typed accessor
/// the generator emitted is inherited, and adds one of its own.
///
/// The generated companion keeps its widget in a **private** `_self`
/// field — private to `package:gtk4` — so a user-side companion
/// cannot reach the widget through it and keeps its own typed
/// reference instead.
class TitledButtonProps extends GtkButtonProps {
  TitledButtonProps(TitledButton button) : _button = button, super(button);

  final TitledButton _button;

  /// [GtkButtonProps.label] is `String?`; a titled button always has
  /// one.
  String get requiredLabel => _button.getLabel() ?? '';
}

void main() {
  setUpAll(() {
    // GTK4 needs to be initialized before any widget can be
    // constructed.
    gtk.init();
  });

  group('a Dart subclass of a generated wrapper', () {
    test('is the same native object, not a second one', () {
      final button = TitledButton('Hello');
      // The native type is still GtkButton — a Dart subclass does not
      // register a new GType.
      final name = typeNameFromInstance(
        GTypeInstance.fromPointer(button.handle),
      );
      expect(name, 'GtkButton');
      // The Dart type is the subclass, and it is still a GtkButton.
      expect(button, isA<GtkButton>());
      expect(button.getLabel(), 'Hello');
    });

    test('carries the generated constructors and methods through', () {
      final button = TitledButton('Hello');
      // `setLabel` / `getLabel` are inherited from the generated
      // class unchanged.
      button.setLabel('Changed');
      expect(button.getLabel(), 'Changed');
    });
  });

  group('a covariant override', () {
    test('narrows the static type without touching the native object', () {
      final box = GtkBox(GtkOrientation.vertical, 0);
      final button = TitledButton('Hello');
      box.append(button);

      // The generated implementation sees the box…
      final baseParent = button.getRawParent();
      expect(baseParent, isNotNull);
      expect(
        typeNameFromInstance(GTypeInstance.fromPointer(baseParent!.handle)),
        'GtkBox',
      );
      // …and the narrowed override correctly refuses to claim it is
      // a button.
      expect(button.getParent(), isNull);
    });

    test('returns the narrowed value when the native type matches', () {
      final outer = TitledButton('outer');
      final inner = TitledButton('inner');
      // A `GtkButton` is a `GtkBin` — it holds one child. The inner
      // button's parent is therefore a `GtkButton`, so the narrowed
      // override may claim it.
      outer.setChild(inner);

      final parent = inner.getParent();
      expect(parent, isNotNull);
      // The narrowed wrapper and the original wrapper share one
      // native pointer — `cast` re-wraps the handle, it does not
      // copy the object. (`Pointer` compares by address, so this is
      // `==`, not `identical`.)
      expect(parent!.handle, outer.handle);
      expect(
        typeNameFromInstance(GTypeInstance.fromPointer(parent.handle)),
        'GtkButton',
      );
    });
  });

  group('a user-side props companion', () {
    test('inherits the generated typed accessors', () {
      final button = TitledButton('Hello');
      // `label` comes from the generated `GtkButtonProps`…
      expect(button.props.label, 'Hello');
      // …and the own accessor is available too.
      expect(button.props.requiredLabel, 'Hello');
    });

    test('writes through to the generated setter', () {
      final button = TitledButton('Hello');
      button.props.label = 'Changed';
      expect(button.getLabel(), 'Changed');
      expect(button.props.requiredLabel, 'Changed');
    });

    test('is a stable instance across accesses', () {
      final button = TitledButton('Hello');
      expect(identical(button.props, button.props), isTrue);
      // The override replaced the generated companion entirely.
      expect(button.props, isA<TitledButtonProps>());
    });
  });
}
