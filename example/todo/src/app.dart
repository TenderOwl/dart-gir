import 'package:adw/adw.dart';

import 'todo_window.dart';

class TodoApp {
  late AdwApplication app;
  TodoApp() {
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
