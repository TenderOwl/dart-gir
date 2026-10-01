import 'dart:io' show exit;

import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart' hide init;
import 'package:glib/glib.dart';

import 'dart:async';
import 'dart:ffi' as ffi;

// Top-level idle callback. Must be top-level so `Pointer.fromFunction`
// can lift it into a C-callable function pointer that lives for the
// entire program (no `NativeCallable.close()` to race with the main
// loop). Returning 0 (== G_SOURCE_REMOVE) unregisters the idle source
// after the first fire.
int myIdleCallback(ffi.Pointer<ffi.Void> data) {
  print(
    '  myIdleCallback fired (data was ${data == ffi.nullptr ? 'null' : 'non-null'})',
  );
  return 0;
}

// Top-level destroy notify. Same lifetime rationale as `myIdleCallback`.
void myDestroyNotify(ffi.Pointer<ffi.Void> data) {
  // No-op: nothing to release.
}

// Native binding for `g_idle_add_full` that takes its callback
// parameters as plain `Pointer<NativeFunction<...>>` (not Dart function
// typedefs). We hand it the result of `Pointer.fromFunction(...)` so the
// callback pointer is permanent — safe for long-lived sources whose
// dispatch happens after the call returns.
//
// The generated `idleAddFull(...)` wrapper is *not* used here: it wraps
// the callback in a `NativeCallable` and closes it in the same `finally`
// block as the call, which would leave a dangling C function pointer
// when GLib later iterates the main context and dispatches the source.
// See `docs/emission.md#callback-parameters` for the full discussion.
final _gIdleAddFull =
    glibLookup<
          ffi.NativeFunction<
            ffi.Uint32 Function(
              ffi.Int32,
              ffi.Pointer<
                ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>
              >,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<
                ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
              >,
            )
          >
        >('g_idle_add_full')
        .asFunction<
          int Function(
            int,
            ffi.Pointer<
              ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>
            >,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<
              ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
            >,
          )
        >();

// Demonstrates `g_idle_add_full` — the canonical wrapper behind the
// `g_idle_add` convenience macro. Exercises:
//   * the function's namespace-level emission (root-level GLib call),
//   * a top-level Dart callback as the `function_` argument,
//   * the nullable `data` parameter (`Pointer<Void>` passed as null),
//   * the nullable callback parameter `notify` (passed both null and
//     non-null in two consecutive calls),
//   * the returned source id being removable via `GSource.remove`.
//
// Two sources are registered. Both fire on the next main-context
// iteration (which `app.run` triggers), print, and auto-remove because
// the callback returns G_SOURCE_REMOVE. The second source carries a
// destroy-notify so the non-null `notify` branch is exercised.
void scheduleIdleSources() {
  final cb =
      ffi.Pointer.fromFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>(
        myIdleCallback,
        0,
      );
  final destroy =
      ffi.Pointer.fromFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>(
        myDestroyNotify,
      );

  final id1 = _gIdleAddFull(
    priorityDefaultIdle,
    cb.cast(),
    ffi.nullptr, // data
    ffi.nullptr, // notify — null branch
  );
  print('  idleAddFull (notify=null) registered id=$id1');

  final id2 = _gIdleAddFull(
    priorityDefaultIdle,
    cb.cast(),
    ffi.nullptr,
    destroy.cast(), // notify — non-null branch
  );
  print('  idleAddFull (notify=fn)  registered id=$id2');
}

Future<void> main(List<String> args) async {
  init();

  print('UserName: ${getUserName()} .: ${getUserDataDir()}');
  scheduleIdleSources();

  final app = MyApp('com.tenderowl.myapp');
  await app.run(args);
}

class MyApp {
  late AdwApplication app;
  late AdwApplicationWindow appWindow;
  late GtkLabel label;

  // GtkFileDialog must be class-level so the
  // convenience overload's `Pointer.fromFunction`-backed trampoline can
  // pin it for the lifetime of the instance. Typed parameters courtesy of
  // the `*Callback` overload (`GObject?`, `GAsyncResult`).
  GtkFileDialog? dlg;

  MyApp(String applicationId) {
    app = AdwApplication(applicationId, .handlesOpen);

    // Connect the 'activate' signal to the `onActivate` callback.
    app.onActivate(onActivate);
    app.onStartup(() {
      print('onStartup called');
    });

    print('before onNotify');
    app.onNotify((pspec) {
      print('onNotify: ${pspec.getName()}');
      if (pspec.getName() == 'active-window') {
        print('  active-window changed ${app.getActiveWindow()?.getTitle() ?? ''}');
      }
    });
    print('before onShutdown');

    // Connect the 'shutdown' signal to quit the application properly.
    app.onShutdown(onQuit);
    app.setAccelsForAction('window.close', ['<Primary>w']);
    print('app initialized');
  }

  Future<void> run(List<String> args) async {
    print('before app.run');
    app.run(args.length, args);
    print('after app.run');
  }

  void onActivate() {
    print('onActivte called');
    label = GtkLabel()
      ..setVisible(false)
      ..addCssClass('caption');
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
                  ..onClicked(() {
                    dlg ??= GtkFileDialog()
                      ..setTitle('Select a file')
                      ..setInitialFolder(GFile.newForPath(getUserDataDir()))
                      ..setModal(true);
                    // Lifetime-safe: uses the generated `openCallback`
                    // convenience overload, which routes through a
                    // permanent Pointer.fromFunction + static trampoline
                    // + per-call registry instead of a NativeCallable.
                    // See `docs/async.md`.
                    dlg?.openCallback(appWindow, null, onFileDialogClosed);
                  }),
              ),
          ),
      );

    appWindow.present();
  }

  void onFileDialogClosed(GObject? sourceObject, GAsyncResult result) {
    // final dlg = sourceObject as GtkFileDialog;
    print('File dialog closed');
    try {
      final file = dlg?.openFinish(result); // throws GlibException
      print('  picked file: ${file?.getPath()}');
      label.setLabel('Picked file ${file?.getPath() ?? ''}');
      label.setVisible(true);
    } on GlibException catch (e) {
      // Includes the GTK_DIALOG_ERROR_DISMISSED case when the user
      // cancels.
      print('  openFinish failed: $e');
    } finally {
      dlg = null;
    }
  }

  void onQuit() {
    app.quit();
    exit(0);
  }
}
