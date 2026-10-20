// The behavioural half of the example's contract.
//
// `todo_test.dart` pins the *file* contract (the part directive, the
// generated file next to its source). This suite pins the thing that
// actually broke: the window used to come up **empty**, because the
// template was only built when a generated field was read — and
// nothing read one.
//
// GTK needs a display, so the suite skips itself when there is none.
// CI runs headless; run it locally under `xvfb-run`:
//
//   xvfb-run -a dart test example/todo
//
// The teardown disconnects the Dart signal handlers before the suite
// ends. A GObject that is finalized *while the isolate shuts down*
// destroys its signal handlers, and the destroy-notify GObject calls
// is a Dart callback — the VM refuses to run a callback while it is
// shutting down and aborts. That is a pre-existing property of the
// bindings' signal plumbing (it reproduces with three lines and no
// template code); disconnecting in the teardown keeps it out of the
// way.

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:adw/adw.dart' as adw;
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart' as gtk;
import 'package:test/test.dart';

import 'package:todo/todo_window.dart';

/// Whether a display is reachable. Without one GTK cannot even
/// initialize, so the whole suite is skipped.
final bool _hasDisplay =
    (Platform.environment['DISPLAY'] ?? '').isNotEmpty ||
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

/// The *native* type name of [widget] — the Dart wrapper is typed by
/// the binding's return type, not by what the object really is.
String _nativeTypeName(Object widget) {
  final handle = (widget as dynamic).handle as ffi.Pointer<ffi.Void>;
  return typeNameFromInstance(GTypeInstance.fromPointer(handle));
}

/// Disconnects every handler for [signalName] on [object].
void _disconnect(GObject object, String signalName, String typeName) {
  final signalId = signalLookup(signalName, typeFromName(typeName));
  if (signalId == 0) return;
  signalHandlersDisconnectMatched(object, GSignalMatchType.id, signalId, 0);
}

void main() {
  late adw.AdwApplication app;
  final windows = <TodoWindow>[];

  // Without a display GTK cannot even initialize, so the whole suite
  // is skipped — CI runs headless.
  final skip = _hasDisplay ? null : 'GTK needs a display';

  setUpAll(() {
    if (!_hasDisplay) return;
    adw.init();
    app = adw.AdwApplication('com.tenderowl.examples.todo.test', .defaultFlags);
    // Register the application so GTK stops complaining that the
    // windows are added before `GApplication::startup`.
    app.register();
  });

  tearDown(() {
    for (final window in windows) {
      _disconnect(window.button, 'clicked', 'GtkButton');
      // Destroy the window while the suite is still running. A window
      // that is only finalized at isolate shutdown is freed while GTK
      // still has it in its toplevel list — GTK walks that list on
      // every main-loop iteration, and the stale pointer is a
      // use-after-free.
      window.destroy();
    }
    windows.clear();
    _disconnect(app, 'activate', 'AdwApplication');
  });

  TodoWindow newWindow() {
    final window = TodoWindow(app);
    windows.add(window);
    return window;
  }

  test('the template is built while the window is constructed', () {
    final window = newWindow();

    // The template's `<property name="content">` — read *before* any
    // generated field is touched. An empty window is exactly what a
    // lazily-built template produces.
    final content = window.getContent();
    expect(content, isNotNull);
    expect(_nativeTypeName(content!), 'AdwToolbarView');
  }, skip: skip);

  test('the template content is laid out', () {
    final window = newWindow();

    // The template's children are real widgets with a real size —
    // the label's text comes from the XML, so it measures out at the
    // width of that text. A window whose template was never built has
    // no content at all.
    final (labelMinWidth, labelNaturalWidth, _, _) = window.counterLabel
        .measure(gtk.GtkOrientation.horizontal, -1);
    expect(labelMinWidth, greaterThan(0));
    expect(labelNaturalWidth, greaterThan(0));

    final (buttonMinWidth, buttonNaturalWidth, _, _) = window.button.measure(
      gtk.GtkOrientation.horizontal,
      -1,
    );
    expect(buttonMinWidth, greaterThan(0));
    expect(buttonNaturalWidth, greaterThan(0));

    // The content itself is a widget tree, not a placeholder.
    final content = window.getContent()!;
    final (contentMinHeight, contentNaturalHeight, _, _) = content.measure(
      gtk.GtkOrientation.vertical,
      -1,
    );
    expect(contentMinHeight, greaterThan(0));
    expect(contentNaturalHeight, greaterThan(0));
  }, skip: skip);

  test('the template children are bound and reachable', () {
    final window = newWindow();

    // Both properties come from the XML, so they can only be there if
    // the template was built.
    expect(window.counterLabel.props.label, 'Clicked 0 times');
    expect(window.button.props.label, 'Click me');

    // The children are real widgets, not null pointers.
    expect(window.counterLabel.handle, isNot(ffi.nullptr));
    expect(window.button.handle, isNot(ffi.nullptr));
  }, skip: skip);

  test('a second window reuses the template installed on the class', () {
    final first = newWindow();
    final second = newWindow();

    // The template lives on the native class and is installed once;
    // every instance still gets its own widget tree.
    expect(second.getContent(), isNotNull);
    expect(second.counterLabel.props.label, 'Clicked 0 times');
    expect(
      second.counterLabel.handle,
      isNot(equals(first.counterLabel.handle)),
      reason: 'each instance gets its own copy of the template tree',
    );
  }, skip: skip);

  test('the signal handler is wired to the widget method', () {
    final window = newWindow();

    // The XML's `<signal name="clicked" handler="on_clicked"/>` is
    // wired by the generated mixin — GTK cannot do it, because it
    // would have to resolve `on_clicked` as a C symbol. Look the
    // handler up to prove the connection is there.
    final signalId = signalLookup('clicked', typeFromName('GtkButton'));
    expect(signalId, isNot(0));

    final closure = signalHandlerFind(
      window.button,
      GSignalMatchType.id,
      signalId,
      0,
    );
    expect(closure, isNot(0), reason: 'the button has a "clicked" handler');
  }, skip: skip);

  test('the window is a real toplevel', () {
    final window = newWindow();
    expect(_nativeTypeName(window), 'AdwApplicationWindow');
  }, skip: skip);
}
