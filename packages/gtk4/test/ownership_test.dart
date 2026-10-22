// Ownership handover: when the GIR says the *callee* takes the reference
// over, the Dart side has to give up its claim.
//
// `gtk_widget_add_controller` is `transfer-ownership="full"`: the widget
// keeps the controller. The wrapper must therefore *detach* its finalizer —
// if it kept it, the controller would be released twice: once by the widget
// and once by the collector.
//
// The observable is *when the native object dies*. `g_object_add_weak_pointer`
// is marked `introspectable="0"` in the GIR — the bindings deliberately do
// not expose it — so the test looks the symbol up itself.
//
// Run with:
//   dart test test/ownership_test.dart

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gtk4/gtk4.dart' as gtk show init;
import 'package:gtk4/gtk4.dart';
import 'package:gobject/gobject.dart';
import 'package:test/test.dart';

/// `g_object_add_weak_pointer(GObject *object, gpointer *location)` — the
/// location is set to NULL when the object is finalized.
final _addWeakPointer =
    gobjectLookup<
          ffi.NativeFunction<
            ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
          >
        >('g_object_add_weak_pointer')
        .asFunction<
          void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
        >();

/// Keeps the garbage alive so the allocation is not optimized away.
final List<List<int>> _garbage = [];

/// Collects garbage for a while without expecting the object to die.
void _collectGarbage() {
  for (var i = 0; i < 20; i++) {
    _garbage
      ..clear()
      ..add(List<int>.filled(200000, 0));
    sleep(const Duration(milliseconds: 2));
  }
}

void main() {
  setUpAll(() {
    // GTK4 needs to be initialized before a widget can be constructed.
    gtk.init();
  });

  group('ownership handover', () {
    test('a callee that takes the reference over gets it', () {
      final widget = GtkBox(GtkOrientation.horizontal, 0);
      final controller = GtkGestureClick();

      // The controller is a fresh object: the wrapper owns it.
      expect(controller.owned, isTrue);

      // The widget takes the controller over.
      widget.addController(controller);

      // The Dart side gave up its claim — the widget owns the reference
      // now, and the wrapper's finalizer was detached.
      expect(controller.owned, isFalse);
    });

    test('the object outlives the wrapper that handed it over', () {
      final widget = GtkBox(GtkOrientation.horizontal, 0);
      GtkGestureClick? controller = GtkGestureClick();
      final handle = controller.handle;
      widget.addController(controller);

      final weak = calloc<ffi.Pointer<ffi.Void>>()..value = handle;
      _addWeakPointer(handle, weak.cast<ffi.Void>());

      // Drop the wrapper. The widget still holds the controller, so the
      // object must stay alive — a finalizer that was not detached would
      // release the widget's reference here and the object would die.
      controller = null;
      _collectGarbage();
      expect(weak.value, isNot(ffi.nullptr));

      // The widget releases it: now the object is gone.
      widget.removeController(GtkGestureClick.fromPointer(handle));
      for (var i = 0; i < 200; i++) {
        if (weak.value == ffi.nullptr) break;
        _garbage
          ..clear()
          ..add(List<int>.filled(200000, 0));
        sleep(const Duration(milliseconds: 2));
      }
      expect(weak.value, ffi.nullptr);
      calloc.free(weak);
    });
  });
}
