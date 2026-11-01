// A Dart widget that overrides a virtual function of its parent.
//
// The point is that the native side calls *into* Dart: the widget's
// `size_allocate` — the slot GTK's layout manager calls — reaches the
// Dart override, which then chains up to the inherited implementation.
//
// The slot's offset is not in the introspection data: the class struct
// layout is not. The offsets live in `GtkWidgetVtable` and are
// cross-checked against the installed header by `vtable_layout_test.dart`.
//
// The instance has to belong to the Dart type itself — `newDartInstance`
// creates it — because the slot is patched on the derived type's own
// copy of the class struct.
//
// The lifecycle rule applies here as everywhere else in these bindings:
// a GObject that carries a Dart callback must not be finalized while the
// isolate shuts down, so every object in this suite is released before
// the test ends.
//
// Run with:
//   xvfb-run -a dart test test/widget_vfunc_test.dart

import 'dart:io';

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:gir_gtk4/gir_gtk4.dart';
import 'package:test/test.dart';

/// The suite needs a display: GTK cannot realize a widget without one.
final skip =
    (Platform.environment['DISPLAY'] ?? '').isEmpty &&
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isEmpty;

/// A Dart class that derives from `GtkWidget` and overrides the widget's
/// `size_allocate`.
///
/// The base widget is the right parent for the test: a container widget
/// has a layout manager, and GTK then allocates through the manager
/// instead of the widget class's `size_allocate` slot.
class MeasuredWidget extends GtkWidget {
  static int get GType => registerDartType(
    'MeasuredWidget',
    GtkWidget.GType,
    overrides: [
      sizeAllocateOverride((widget, width, height, baseline) {
        final box = widget! as MeasuredWidget;
        box.sizeAllocateCalls++;
        box.lastWidth = width;
        box.lastHeight = height;
      }),
    ],
  );

  MeasuredWidget() : super.rawFromPointer(newDartInstance(GType), owned: true);

  /// How often the override ran.
  int sizeAllocateCalls = 0;

  /// The width the widget was last allocated.
  int lastWidth = 0;

  /// The height the widget was last allocated.
  int lastHeight = 0;
}

void main() {
  group('a Dart widget that overrides a virtual function', () {
    test('the override runs when the widget is allocated', () {
      withInitializationLock(init);

      final box = MeasuredWidget();

      // A widget that is not visible is not allocated — GTK skips the
      // allocation altogether.
      box.setVisible(true);

      // `gtk_widget_allocate` calls the widget class's `size_allocate`
      // slot — the one the override patched.
      box.allocate(120, 40, -1);

      expect(box.sizeAllocateCalls, 1);
      expect(box.lastWidth, 120);
      expect(box.lastHeight, 40);

      box.unref();
    }, skip: skip);

    test('the override is per type', () {
      withInitializationLock(init);

      final box = MeasuredWidget();
      final plain = GtkBox(GtkOrientation.horizontal, 0);

      expect(box.sizeAllocateCalls, 0);

      plain.unref();
      box.unref();
    }, skip: skip);
  });
}
