import 'package:adw/adw.dart';

import 'package:todo/todo_window.dart';

class TodoApp {
  late AdwApplication app;
  TodoApp() {
    // libadwaita needs its own initialisation before anything of
    // its is created: it loads the stylesheet and sets up the
    // `Adw` settings. (`init()` here is `adw_init()`.)
    init();

    app = AdwApplication('com.tenderowl.examples.todo', .defaultFlags);

    app.onActivate(onActivate);
  }

  void onActivate() {
    final window = TodoWindow(app);
    window.present();
  }

  void run(List<String> args) {
    app.run(args.length, args);
  }
}
