// A small GTK4 counter application built with the gir_bindings workspace.
//
// Run it with:
//   dart run example/bin/gtk4_counter.dart
//
// The flow:
//   1. gtk_init() — generated as `void init()` (no argc/argv variants are
//      skipped by the generator because the parameter is `allow-none`).
//   2. Build a GtkWindow → GtkBox → GtkLabel + GtkButton.
//   3. Hook the button's `clicked` signal to a static Dart callback that
//      mutates the counter and updates the label; hook `destroy` to quit
//      the main loop.
//   4. Show the window and run a GLib main loop.
//
// The `g_signal_connect_data` call is made through `gobjectLookup` because
// the generator does not emit signal-helper wrappers; the C signature is
// simple enough to call directly.

import 'dart:ffi' as ffi;
import 'dart:io' show stderr;

import 'package:ffi/ffi.dart';
import 'package:glib/glib.dart';
import 'package:gobject/gobject.dart' show gobjectLookup;
import 'package:gtk4/gtk4.dart' hide init;
import 'package:adw/adw.dart';

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

void _onDestroyDart(
  ffi.Pointer<ffi.Void> window,
  ffi.Pointer<ffi.Void> userData,
) {
  final loop = GMainLoop.fromPointer(userData);
  loop.quit();
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

int main(List<String> args) {
  // `gtk_init` is exposed as a parameterless free function because the
  // generator skips the argc/argv variants (nullable scalar params).
  init();

  final window = AdwWindow();
  window.setTitle('GTK4 Counter');

  final toolbarView = AdwToolbarView();
  window.setContent(toolbarView);

  final headerBar = AdwHeaderBar();
  toolbarView.addTopBar(headerBar);

  // Box holds the label and the button vertically.
  final box = GtkBox(GtkOrientation.vertical, 12);
  toolbarView.setContent(box);

  final label = GtkLabel('Button clicked: 0 times');
  box.append(label);

  final button = GtkButton.withLabel('Click me!');
  button.addCssClass('suggested-action');
  box.append(button);

  // We hand the label pointer to the click handler as user_data so the
  // handler can update the label text.
  _connectSignal(button.handle, 'clicked', _onClickedDart, label.handle);

  // Build the main loop up-front so the destroy handler can reference it.
  final loop = GMainLoop(null, false);
  _connectSignal(window.handle, 'destroy', _onDestroyDart, loop.handle);

  // GTK4 dropped gtk_widget_show in favor of `present()` on the toplevel
  // or `setVisible(true)` on any widget. We use `present()` so the window
  // also gets raised/focused.
  window.present();

  loop.run();
  return 0;
}
