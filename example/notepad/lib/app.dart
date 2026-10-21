import 'dart:io';

import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:notepad/notepad_window.dart';

class NotepadApp {
  late AdwApplication app;
  NotepadWindow? window;

  NotepadApp() {
    app = AdwApplication("com.tenderowl.notepad", .handlesOpen);

    createAction("quit", (_) => quit(), "<Primary>Q");
    createAction("preferences", (_) => onPreferencesAction(), "<Primary>comma");
    createAction("about", (_) => onAboutAction());
    createAction("show-toast", onShowToast, null, GVariantType('s'));

    // A stateful action carries its type in the *state*, not in a
    // parameter type. A parameter type makes the action *parameterised*:
    // a menu item would then need a target to activate it, and without
    // one GTK4 greys the item out — the action sits in the app, enabled,
    // and the menu entry is still dead.
    //
    // With no parameter type GLib's default takes over: activating the
    // action toggles the boolean state and emits "change-state".
    final darkModeAction = GSimpleAction.stateful(
      'dark-mode',
      null,
      GVariant.boolean(false),
    );

    darkModeAction.onChangeState(
      (param) => changeColorScheme(darkModeAction, param),
    );
    app.addAction(darkModeAction);

    app.setAccelsForAction('win.open', ['<Ctrl>o']);
    app.setAccelsForAction('win.save-as', ['<Ctrl><Shift>s']);

    app.onActivate(onActivate);
    // app.onShutdown(() => quit());
  }

  void onActivate() {
    window ??= NotepadWindow(app);
    window!.onCloseRequest(() {
      quit();
      return false;
    });

    window!.present();
  }

  void run(List<String> args) {
    app.run(args.length, args);
  }

  void quit() {
    app.quit();
    exit(0);
  }

  /// Add an application action.
  void createAction(
    String name,
    void Function(GVariant?) callback, [
    String? accel,
    GVariantType? parameterType,
  ]) {
    final action = GSimpleAction(name, parameterType);
    action.onActivate(callback);
    app.addAction(action);

    if (accel != null) {
      app.setAccelsForAction("app.$name", [accel]);
    }
  }

  /// Callback for the app.preferences action.
  void onPreferencesAction() {
    print("app.preferences action activated");
  }

  /// Callback for the app.about action.
  void onAboutAction() {
    final about = AdwAboutDialog()
      ..setApplicationName("Notepad")
      ..setVersion("0.1.0")
      ..setCopyright("@ 2026, Andrey Maksimov")
      ..setDeveloperName("Andrey Maksimov")
      ..setApplicationIcon("com.tenderowl.notepad")
      ..setLicense("MIT")
      ..setWebsite("https://github.com/tenderowl/dart-gir");

    about.present(window);
  }

  void onShowToast(GVariant? params) {
    final (String, int)? result = params?.getString();
    if (result == null) return;
    final (text, _) = result;
    print('Toast: $text');
  }

  void changeColorScheme(GSimpleAction action, GVariant? param) {
    final darkMode = param?.getBoolean() ?? false;
    final styleManager = AdwStyleManager.getDefault();
    if (darkMode) {
      styleManager.setColorScheme(.forceDark);
    } else {
      styleManager.setColorScheme(.forceLight);
    }

    action.setState(GVariant.boolean(darkMode));
  }
}
