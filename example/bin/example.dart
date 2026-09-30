import 'dart:developer';
import 'dart:io' show exit;

import 'package:adw/adw.dart';
import 'package:gtk4/gtk4.dart' hide init;

import 'dart:async';

Future<void> main(List<String> args) async {
  init();

  final app = MyApp('com.tenderowl.myapp');
  await app.run(args);
}

class MyApp {
  late AdwApplication app;
  late AdwApplicationWindow appWindow;

  MyApp(String applicationId) {
    app = AdwApplication(applicationId, .handlesOpen);

    // Connect the 'activate' signal to the `onActivate` callback.
    app.onActivate(onActivate);
    app.onStartup(() {
      log('onStartup called', level: 0);
    });

    app.onNotify((pspec) {
      print('onNotify: ${pspec.getName()}');
    });

    // Connect the 'shutdown' signal to quit the application properly.
    app.onShutdown(onQuit);
    app.setAccelsForAction('window.close', ['<Primary>w']);
  }

  Future<void> run(List<String> args) async {
    app.run(args.length, args);
  }

  void onActivate() {
    log('onActivte called');
    appWindow = AdwApplicationWindow(app)
      ..setDefaultSize(640, 480)
      ..setTitle('My App')
      ..setContent(
        AdwToolbarView()
          ..addTopBar(AdwHeaderBar())
          ..setContent(
            GtkBox(.vertical, 16)
              ..setValign(.center)
              ..setHalign(.center)
              ..append(
                GtkLabel('Welcome to My App')
                  ..addCssClass('title-1')
                  ..setVexpand(true)
                  ..setValign(.center),
              )
              ..append(
                GtkButton.withLabel('Press me')
                  ..addCssClass('suggested-action')
                  ..onClicked(() => print('Button clicked')),
              ),
          ),
      );

    appWindow.present();
  }

  void onQuit() {
    app.quit();
    exit(0);
  }
}
