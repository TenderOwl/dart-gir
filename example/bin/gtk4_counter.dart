// A small GTK4 counter application built with the gir_bindings workspace.
//
// Run it with:
//   dart run example/bin/gtk4_counter.dart
//
// The flow:
//   1. Create an AdwApplication (which is a GApplication subclass).
//   2. Wire the application's `activate` signal to build the window.
//   3. Build a GtkWindow → GtkBox → GtkLabel + GtkButton and hook the
//      button's `clicked` signal to a static Dart callback that mutates
//      the counter and updates the label.
//   4. Hand control to GApplication.run(), which returns when the
//      application quits.
//
// One raw binding still lives in this file:
//   * `g_signal_connect_data` — signal-helper wrappers are skipped by the
//     generator; the C signature is small enough to call directly.

import 'dart:ffi' as ffi;
import 'dart:io' show stderr, exit;

import 'package:adw/adw.dart';
import 'package:ffi/ffi.dart';
import 'package:gio/gio.dart';
import 'package:gobject/gobject.dart' show gobjectLookup;
import 'package:gtk4/gtk4.dart' hide init;

/// State shared with the static Dart callbacks below. We keep the counter
/// in a top-level field because `g_signal_connect_data` passes a
/// `gpointer` user_data, which we use to thread this state back in.
int _counter = 0;

/// Static callback for the `clicked` signal.
///
/// GObject's default `g_cclosure_marshal_VOID__VOID` invokes the closure as
/// `closure(instance, user_data)`. Declaring the trampoline with a single
/// `Pointer<Void>` argument therefore reads `RDI` (the instance, i.e. the
/// button) and silently drops the real user data on `RSI` — that was the
/// first bug in this example. The correct signature mirrors the marshaler's
/// call site: `(instance, user_data)`.
void _onClickedDart(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
) {
  _counter += 1;
  stderr.writeln(
    'clicked: instance=0x${instance.address.toRadixString(16)} '
    'user_data=0x${userData.address.toRadixString(16)}',
  );
  // Re-enter the generated bindings from the foreign callback by rebuilding
  // the label widget around the pointer that was registered as user_data.
  // The pointer stays valid for the whole run because we never free it (the
  // process exits when the loop quits).
  final label = GtkLabel.fromPointer(userData.cast());
  final newText = 'Button clicked: $_counter time${_counter == 1 ? '' : 's'}';
  label.setLabel(newText);
}

/// Raw binding to `g_signal_connect_data`. The generator skips signal
/// helpers (they're callback-rich and depend on `user_data` lifetime
/// conventions we haven't modelled yet), so we reach for `gobjectLookup`
/// for this single symbol. The `GCallback` slot is declared as
/// `void(*)(gpointer, gpointer)` to match how GObject's default
/// `g_cclosure_marshal_VOID__VOID` invokes the closure (instance, user_data).
final _gSignalConnectData =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Uint64 Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<Utf8>,
              ffi.Pointer<
                ffi.NativeFunction<
                  ffi.Void Function(
                    ffi.Pointer<ffi.Void>,
                    ffi.Pointer<ffi.Void>,
                  )
                >
              >,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
            )
          >
        >('g_signal_connect_data')
        .asFunction<
          int Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<Utf8>,
            ffi.Pointer<
              ffi.NativeFunction<
                ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
              >
            >,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            int,
          )
        >();

/// Connects [callback] to [signal] on [instance], passing [userData] as the
/// gpointer. Uses `NativeCallable.isolateLocal` under the hood so the
/// callback can flow through a Dart closure that captures local state.
void _connectSignal(
  ffi.Pointer<ffi.Void> instance,
  String signal,
  void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>) callback,
  ffi.Pointer<ffi.Void> userData,
) {
  // Wrap the Dart closure in a NativeCallable so the FFI runtime can call
  // back into Dart. `isolateLocal` is sufficient for main-thread UI work.
  // The trampoline signature MUST be `(Pointer<Void>, Pointer<Void>)` —
  // GObject's default marshaler invokes the closure with two arguments.
  final nc =
      ffi.NativeCallable<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
      >.isolateLocal(callback);
  try {
    final signalName = signal.toNativeUtf8();
    try {
      _gSignalConnectData(
        instance,
        signalName.cast<Utf8>(),
        nc.nativeFunction,
        userData,
        ffi.nullptr,
        0,
      );
    } finally {
      malloc.free(signalName);
    }
  } finally {
    // We deliberately don't `nc.close()` here — the connection lives for
    // the duration of the program and `close()` here would invalidate the
    // trampoline the next time GTK dispatches the signal. In a long-lived
    // program you'd want a release path; for this example, process exit
    // reclaims the native resources.
  }
}

/// `GApplication::activate` callback. The default void(void) marshaler
/// calls us as `closure(instance, user_data)`, so the trampoline takes
/// `(Pointer<Void>, Pointer<Void>)` — see the `clicked` callback above for
/// the full reasoning.
void _onActivateDart(
  ffi.Pointer<ffi.Void> instance,
  ffi.Pointer<ffi.Void> userData,
) {
  // `instance` is the AdwApplication created in main(). We rebuild the
  // full wrapper around the pointer so `AdwApplicationWindow` accepts it
  // (the constructor expects a `GtkApplication`, which AdwApplication is).
  final app = AdwApplication.fromPointer(instance);
  final window = createWindow(app);
  window.present();
}

void _onQuit(ffi.Pointer<ffi.Void> instance, ffi.Pointer<ffi.Void> userData) {
  final app = AdwApplication.fromPointer(instance);
  app.quit();
  exit(0);
}

int main(List<String> args) {
  final app = AdwApplication(
    'com.example.gtk4_counter',
    GApplicationFlags.defaultFlags,
  );

  // We connect `activate` first so the window is built when the
  // application's main loop wakes us up.
  _connectSignal(app.handle, 'activate', _onActivateDart, ffi.nullptr);

  _connectSignal(app.handle, 'shutdown', _onQuit, ffi.nullptr);

  // `app.run()` is generated — it accepts `argc` plus an optional
  // `argv` and forwards both to `g_application_run` via
  // `withNativeStringList`. We forward Dart's `main` args so that
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

  // We hand the label pointer to the click handler as user_data so the
  // handler can update the label text.
  _connectSignal(button.handle, 'clicked', _onClickedDart, label.handle);

  return window;
}
