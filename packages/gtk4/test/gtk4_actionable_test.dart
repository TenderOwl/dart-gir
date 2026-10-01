// End-to-end test for the mirrored `GtkActionable` interface methods
// on the concrete widget classes. Before the interface-mirroring
// generator change, calling `button.setActionName('win.open')` would
// not compile — the actionable methods lived only on `GtkActionable`,
// which is an opaque handle class. Users had to wrap any widget
// pointer in `GtkActionable.fromPointer(...)` to call them.
//
// After the change, `setActionName` / `getActionName` /
// `setActionTargetValue` / `getActionTargetValue` /
// `setDetailedActionName` are reachable on `GtkButton`, `GtkSwitch`,
// `GtkCheckButton`, etc. directly — same native symbol
// (`gtk_actionable_set_action_name`), same `this.handle` self-argument.
//
// The setActionName→getActionName round-trip exercises the C-side
// property storage (`action-name`) without requiring a registered
// `GtkApplication` action. setDetailedActionName writes through the
// parsed-name helper. setActionTargetValue is exercised with a fresh
// `GVariant.string` to confirm the variant reference-counting path.
//
// Run with:
//   dart test test/gtk4_actionable_test.dart

import 'package:glib/glib.dart';
import 'package:gtk4/gtk4.dart' as gtk show init;
import 'package:test/test.dart';

import 'package:gtk4/gtk4.dart';

void main() {
  setUpAll(() {
    // GTK4 needs to be initialized before any widget can be
    // constructed.
    gtk.init();
  });

  group('GtkActionable interface mirror on widgets', () {
    test('GtkButton.setActionName ↔ getActionName round-trip', () {
      final button = GtkButton();
      button.setActionName('win.open');
      expect(button.getActionName(), 'win.open');
      button.setActionName(null);
      expect(button.getActionName(), isNull);
    });

    test('GtkSwitch.setActionName is reachable on the widget', () {
      final sw = GtkSwitch();
      sw.setActionName('app.toggle');
      expect(sw.getActionName(), 'app.toggle');
    });

    test('GtkCheckButton.setActionName is reachable on the widget', () {
      final cb = GtkCheckButton();
      cb.setActionName('app.check');
      expect(cb.getActionName(), 'app.check');
    });

    test('setDetailedActionName stores the action-target variant', () {
      final button = GtkButton();
      button.setDetailedActionName('win.save::format=json');
      // Action name round-trip.
      expect(button.getActionName(), 'win.save');
      // Action target variant was set (non-null). The exact
      // stringification isn't stable across GIR variants, but the
      // pointer is what matters for the FFI mirror contract.
      final target = button.getActionTargetValue();
      expect(target, isNotNull);
      target!.unref();
    });

    test('setActionTargetValue accepts a GVariant and survives read-back', () {
      final button = GtkButton();
      final variant = GVariant.string('json');
      button.setActionTargetValue(variant);
      variant.unref();

      // Read-back returns a non-null GVariant — its reference
      // ownership is held by the button (the original was released
      // with `variant.unref()` above; the button ref'd it via
      // g_variant_ref_sink).
      final readBack = button.getActionTargetValue();
      expect(readBack, isNotNull);
      readBack!.unref();
    });
  });
}
