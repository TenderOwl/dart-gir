import 'dart:io';

import 'package:adw/adw.dart';

import 'package:todo/todo_window.dart';

class TodoApp {
  late AdwApplication app;

  /// The window the application shows.
  ///
  /// The application holds it: the window owns the task store, and
  /// the store has to outlive the selection model that wraps it.
  // ignore: unused_field
  TodoWindow? _window;

  TodoApp() {
    // libadwaita needs its own initialisation before anything of
    // its is created: it loads the stylesheet and sets up the
    // `Adw` settings. (`init()` here is `adw_init()`.)
    init();

    app = AdwApplication('com.tenderowl.examples.todo', .defaultFlags);

    app.onActivate(onActivate);
    app.onShutdown(() => exit(0));
  }

  void onActivate() {
    final window = TodoWindow(app);
    _window = window;
    window.present();
  }

  void run(List<String> args) {
    app.run(args.length, args);
  }
}
