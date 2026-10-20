// A small GTK4 counter application built with the gir_bindings workspace.
//
// Run it with:
//   dart run example/bin/gtk4_counter.dart
//
// The flow:
//   1. Create an AdwApplication (which is a GApplication subclass).
//   2. Wire the application's `activate` signal to build the window.
//   3. Build a GtkWindow → GtkBox → GtkLabel + GtkButton and hook the
//      button's `clicked` signal to a Dart closure that mutates the
//      counter and updates the label.
//   4. Hand control to GApplication.run(), which returns when the
//      application quits.
//
// Signal connections use the generated `onSignalName` helpers
// (`GApplication.onActivate`, `GtkButton.onClicked`, …), which take plain
// `void Function()` callbacks — closures capture their state directly, no
// `user_data` plumbing.

import 'dart:io' show stderr, exit;

import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:gtk4/gtk4.dart' hide init;

int main(List<String> args) {
  final app = AdwApplication(
    'com.example.gtk4_counter',
    GApplicationFlags.defaultFlags,
  );

  // `activate`/`shutdown` are declared on GApplication and inherited
  // through the Dart class hierarchy (AdwApplication → GtkApplication →
  // GApplication).
  app.onActivate(() {
    createWindow(app).present();
  });
  app.onShutdown(() {
    app.quit();
    exit(0);
  });

  // `app.run()` is generated — it accepts `argc` plus `argv` and forwards
  // both to `g_application_run`. We forward Dart's `main` args so that
  // command-line flags like `--gapplication-service` still flow through.
  return app.run(args.length, args);
}

GtkWindow createWindow(GtkApplication app) {
  final window = AdwApplicationWindow(app);
  window.setTitle('GTK4 Counter');
  window.setDefaultSize(800, 600);

  final toolbarView = AdwToolbarView();
  window.setContent(toolbarView);

  final headerBar = AdwHeaderBar();
  toolbarView.addTopBar(headerBar);

  final clamp = AdwClamp()..setMaximumSize(360);
  toolbarView.setContent(clamp);

  // Box holds the label and the button vertically.
  final box = GtkBox(GtkOrientation.vertical, 12)
    ..setVexpand(true)
    ..setValign(GtkAlign.center)
    ..setMarginStart(16)
    ..setMarginEnd(16);
  clamp.setChild(box);

  final label = GtkLabel('Button clicked: 0 times');
  box.append(label);

  final button = GtkButton.withLabel('Click me!');
  button.addCssClass('suggested-action');
  box.append(button);

  // The closure captures both the counter and the label — the generated
  // registry keeps it alive until the signal is disconnected.
  var counter = 0;
  button.onClicked(() {
    counter += 1;
    stderr.writeln('clicked: counter=$counter');
    label.setLabel('Button clicked: $counter time${counter == 1 ? '' : 's'}');
  });

  return window;
}
