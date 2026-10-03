// Application entry point for the todo example. Wires up an
// `AdwApplication` whose first activated window is the
// `TodoWindow` composite widget backed by a GtkBuilder `.ui`
// template (see `todo_window.dart`).
//
// The GResource bundle that contains the `.ui` files is compiled
// by meson at build time (see `example/todo/data/meson.build`) and
// registered here at startup so that the builder-emitted
// `setTemplateFromResource('/com/tenderowl/Todo/window.ui')` call
// can resolve the path. Without this registration, GTK's resource
// loader returns `nullptr` and `gtk_widget_init_template` fails.

import 'dart:ffi';
import 'dart:io' show File;

import 'package:adw/adw.dart';
import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:gir_ffi/gir_ffi.dart' show gBytesNew;
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';

import 'todo_window.dart';

final _nativeByteAlloc = pkg_ffi.calloc;

class TodoApp {
  late AdwApplication app;
  TodoApp() {
    app = AdwApplication('com.tenderowl.examples.todo', .defaultFlags);

    _registerCompiledResources();
    app.onActivate(onActivate);
  }

  /// Loads the compiled `.gresource` bundle produced by meson and
  /// registers it with the process-global resource namespace.
  ///
  /// The bundle path is resolved relative to the executable: meson
  /// installs it under `<prefix>/share/todo/` next to the binary.
  /// In a development tree (running `dart run bin/todo.dart`
  /// directly), the path is `_build/data/resources.gresource`.
  void _registerCompiledResources() {
    final candidates = [
      // In-tree development path.
      '_build/data/resources.gresource',
      // Installed path (matches `install_dir: pkgdatadir` in
      // `data/meson.build`).
      'share/todo/resources.gresource',
    ];
    String? path;
    for (final c in candidates) {
      if (File(c).existsSync()) {
        path = c;
        break;
      }
    }
    if (path == null) {
      // ignore: avoid_print
      print(
        'TodoApp: no resources.gresource found in $candidates. '
        'Run `meson compile -C _build` first.',
      );
      return;
    }
    print('TodoApp: registering gresource at $path');

    final bytes = File(path).readAsBytesSync();
    final nativeBytes = _nativeByteAlloc.allocate<Uint8>(bytes.length);
    final typed = (nativeBytes.cast<Uint8>()).asTypedList(bytes.length);
    typed.setAll(0, bytes);
    final gbytes = gBytesNew(
      nativeBytes.cast(),
      bytes.length,
    );
    if (gbytes == nullptr) {
      throw StateError('Failed to wrap $path as GBytes');
    }
    final resource = GResource.fromData(GBytes.fromPointer(gbytes));
    resource.register();
    print('TodoApp: gresource registered');
    // `gbytes` ownership is transferred to the GResource; do not
    // call `g_free` on it. The GResource keeps the reference for
    // the lifetime of the registration.
    // `nativeBytes` is GLib's internal copy target; g_bytes_new
    // copies the bytes into a new GLib-owned buffer, so we can
    // free our Dart-side copy right after.
    pkg_ffi.calloc.free(nativeBytes);
  }

  void onActivate() {
    // Install the GtkBuilder template on AdwApplicationWindow's
    // WidgetClass. Must run BEFORE the first `TodoWindow` instance
    // is constructed — `gtk_widget_init_template` refuses to run if
    // the template hasn't been set on the class. A real app would
    // do this from a static initialiser or a constructor that
    // defers super(); we trigger it explicitly here.
    installTodoWindowTemplate();
    final window = TodoWindow(app);
    window.present();
  }

  void run(List<String> args) {
    app.run(args.length, args);
  }
}