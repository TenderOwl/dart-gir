// The dark-mode action: a stateful action, and the two rules that make
// its menu entry work.
//
// A `GSimpleAction` carries the type of its value in the *state* — a
// stateful action has no parameter type. Passing one anyway makes the
// action *parameterised*: a menu item would need a target to activate
// it, and without one GTK4 greys the entry out, even though the action
// sits in the application, enabled, and ready.
//
// With no parameter type, activating the action through its group
// toggles the boolean state and emits "change-state". That signal's
// default handler (which accepts the requested state) is replaced as
// soon as a handler is connected — so the handler has to accept the
// state itself.
//
// The rules are GLib's, not the bindings'; the suite pins them so the
// example's action setup cannot drift back into the greyed-out shape.

import 'dart:io';

import 'package:adw/adw.dart' show init;
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gobject/gobject.dart'
    show gobjectFinalizer, signalHandlerDisconnect;
import 'package:notepad/app.dart';
import 'package:test/test.dart';

/// Whether a display is reachable. Without one GTK cannot even
/// initialize, so the window-dependent part of the suite is skipped.
final bool _hasDisplay =
    (Platform.environment['DISPLAY'] ?? '').isNotEmpty ||
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

void main() {
  group('a stateful action', () {
    test('without a parameter type it toggles when the group activates it', () {
      // This is what a menu item does: the group looks the action up
      // and activates it by name.
      final action = GSimpleAction.stateful(
        'dark-mode',
        null,
        GVariant.boolean(false),
      );
      final group = GSimpleActionGroup()..addAction(action);

      group.activateAction('dark-mode');
      expect(action.getState()?.getBoolean(), isTrue);

      group.activateAction('dark-mode');
      expect(action.getState()?.getBoolean(), isFalse);
    });

    test('with a parameter type it is parameterised', () {
      // The shape that made the menu entry dead: the action wants a
      // parameter, so a menu item needs a target to activate it.
      final action = GSimpleAction.stateful(
        'dark-mode',
        GVariantType('b'),
        GVariant.boolean(false),
      );

      expect(action.getParameterType(), isNotNull);
      expect(action.getStateType(), isNotNull);
    });

    test('a change-state handler has to accept the state itself', () {
      // GLib's default (no handler connected) accepts the requested
      // state. A connected handler replaces that default, so the state
      // only moves when the handler says so.
      final action = GSimpleAction.stateful(
        'dark-mode',
        null,
        GVariant.boolean(false),
      );
      final handler = action.onChangeState((param) {
        action.setState(GVariant.boolean(param!.getBoolean()));
      });
      // The handler has to go before the object does: a GObject
      // finalized while the isolate shuts down destroys its signal
      // handlers, and the destroy-notify call is a Dart callback —
      // the VM refuses to run a callback while it is shutting down and
      // aborts.
      addTearDown(() => signalHandlerDisconnect(action, handler));

      final group = GSimpleActionGroup()..addAction(action);

      group.activateAction('dark-mode');
      expect(action.getState()?.getBoolean(), isTrue);
    });
  });

  group('the app\'s dark-mode action', () {
    final skip = _hasDisplay ? null : 'GTK needs a display';

    setUpAll(() {
      if (!_hasDisplay) return;
      init();
    });

    test('is stateful and has no parameter type', () {
      final notepad = NotepadApp();
      // Same rule as above: the application is a GObject, and it is
      // finalized when the isolate shuts down — which would destroy
      // the action handlers while the VM is going down. The test does
      // not care about the application's lifetime.
      addTearDown(() => gobjectFinalizer.detach(notepad.app));

      final action = notepad.app.lookupAction('dark-mode');

      expect(action, isNotNull);
      // A parameter type would make the menu entry insensitive.
      expect(action!.getParameterType(), isNull);
      // The state carries the type instead.
      expect(action.getStateType(), isNotNull);
      expect(action.getState()?.getBoolean(), isFalse);
    }, skip: skip);
  });
}
