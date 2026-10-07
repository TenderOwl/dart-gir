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

    app.onActivate(onActivate);

    // app.onShutdown(() => quit());

    createAction("quit", (_) => quit(), "<Primary>Q");
    createAction("preferences", (_) => onPreferencesAction(), "<Primary>comma");
    createAction("about", (_) => onAboutAction());
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
}
