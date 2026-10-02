import 'package:adw/adw.dart';

class TodoWindow {
  late AdwApplicationWindow _window;

  TodoWindow(AdwApplication app) {
    _window = AdwApplicationWindow(app);
    _window.setDefaultSize(800, 600);
    _window.setTitle('Todo');
  }

  void present() {
    _window.present();
  }
}
