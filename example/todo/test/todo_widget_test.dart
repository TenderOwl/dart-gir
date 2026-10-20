// The behavioural half of the example's contract.
//
// `todo_test.dart` pins the *file* contract (the part directive, the
// generated file next to its source). This suite pins the thing the
// example is actually about: a **Dart class with a native type**.
//
// The window's list is a `GListStore` typed with `TaskObject.GType` —
// a GType registered with GLib — and the `TaskObject` the window
// creates is the very object that comes back out of the native list.
//
// GTK needs a display, so the suite skips itself when there is none.
// CI runs headless; run it locally under `xvfb-run`:
//
//   xvfb-run -a dart test example/todo
//
// ## The lifecycle of the objects the suite creates
//
// The bindings release a native object when the Dart wrapper that owns
// it is collected, and GTK frees widgets when their parent goes away.
// The two do not always agree, and a mismatch is a use-after-free:
//
//   * A GObject that is finalized *while the isolate shuts down*
//     destroys its signal handlers, and the destroy-notify GObject
//     calls is a Dart callback — the VM refuses to run a callback
//     while it is shutting down and aborts.
//   * `gtk_window_destroy` frees the window, so the wrapper's
//     finalizer must not release it a second time.
//   * A window that is only freed at shutdown stays in GTK's global
//     toplevel list, and GTK walks that list on every main-loop
//     iteration — the gio suite drives the default main context in
//     parallel, so it would walk a window that is already gone.
//   * GTK's selection models dispose the model they wrap before they
//     disconnect the handlers they connected to it.
//
// The suite therefore disconnects the Dart signal handlers as it goes
// and destroys its windows *while the isolate is alive* rather than
// leaving them to the collector. Nothing is released while the isolate
// is tearing itself down, and nothing is released twice.

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:adw/adw.dart' as adw;
import 'package:glib/glib.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart';
import 'package:test/test.dart';

import 'package:todo/task_object.dart';
import 'package:todo/task_row.dart';
import 'package:todo/todo_window.dart';

/// Whether a display is reachable. Without one GTK cannot even
/// initialize, so the whole suite is skipped.
final bool _hasDisplay =
    (Platform.environment['DISPLAY'] ?? '').isNotEmpty ||
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

/// The *native* type name of [object] — the Dart wrapper is typed by
/// the binding's return type, not by what the object really is.
String _nativeTypeName(Object object) {
  final handle = (object as dynamic).handle as ffi.Pointer<ffi.Void>;
  return typeNameFromInstance(GTypeInstance.fromPointer(handle));
}

/// Disconnects every handler for [signalName] on [object].
void _disconnect(GObject object, String signalName, String typeName) {
  final signalId = signalLookup(signalName, typeFromName(typeName));
  if (signalId == 0) return;
  signalHandlersDisconnectMatched(object, GSignalMatchType.id, signalId, 0);
}

/// Runs the default main context until it has nothing left to do.
///
/// A `GtkListView` allocates its items when it is realized and the main
/// loop runs: until then the model holds the item, but the list has no
/// widget for it.
void _pumpMainLoop() {
  final context = GMainContext.default_();
  for (var i = 0; i < 100; i++) {
    context.iteration(false);
  }
}

/// Everything the suite created, kept reachable until the process
/// exits — see the note on the lifecycle above.
final List<Object> _kept = <Object>[];

void main() {
  late adw.AdwApplication app;
  final windows = <TodoWindow>[];
  final rows = <TaskRow>[];
  // The list items the list view built, in the order it built them.
  final listItems = <GtkListItem>[];

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
    _kept.add(app);
  });

  tearDown(() {
    // Disconnect the Dart signal handlers while the suite is still
    // running: a handler that is destroyed during the shutdown would
    // call into an isolate that is not there any more.
    for (final row in rows) {
      _disconnect(row.completed_button, 'toggled', 'GtkCheckButton');
    }
    rows.clear();
    listItems.clear();
    for (final window in windows) {
      _disconnect(window.entry, 'activate', 'GtkEntry');
      _disconnect(window.itemFactory, 'setup', 'GtkSignalListItemFactory');
      _disconnect(window.itemFactory, 'bind', 'GtkSignalListItemFactory');
      // The store and the selection that wraps it are released by the
      // garbage collector, and the collector may release the store
      // first — GTK's selection models dispose the model they wrap,
      // so a model that is already gone is a use-after-free. The
      // attachments are detached, so neither is released at all.
      gobjectFinalizer.detach(window.tasks);
      gobjectFinalizer.detach(window.selection);

      // Destroy the window *here*, while the isolate is alive, instead
      // of leaving it to the collector. A window that is only freed at
      // shutdown stays in GTK's global toplevel list — and GTK walks
      // that list on every main-loop iteration. The gio suite drives
      // the default main context in parallel, so it would walk a
      // window that is already gone.
      //
      // `gtk_window_destroy` frees the window, so the wrapper's
      // finalizer must not release it a second time: detach it first.
      // The window also leaves the application's window list, which
      // the application's dispose walks.
      gobjectFinalizer.detach(window);
      window.setApplication(null);
      window.destroy();
    }
    windows.clear();
    _disconnect(app, 'activate', 'AdwApplication');
  });

  TodoWindow newWindow() {
    final window = TodoWindow(app);
    windows.add(window);
    _kept.add(window);
    // The store has to outlive the selection model that wraps it.
    _kept.add(window.tasks);
    _kept.add(window.selection);
    _kept.add(window.itemFactory);

    // Watch the rows the list view builds. Every row connects a Dart
    // signal handler — the check button's `toggled` — and a row that
    // is finalized while the isolate shuts down would take that Dart
    // callback with it, which the VM refuses to run. The teardown
    // disconnects the handlers of the rows collected here.
    //
    // The handler runs after the window's own one, so by the time it
    // sees the list item the row is already in place.
    window.itemFactory.onSetup((item) {
      final listItem = item.cast<GtkListItem>(GtkListItem.fromPointer);
      listItems.add(listItem);
      rows.add(listItem.getChild() as TaskRow);
    });
    return window;
  }

  TaskRow newRow() {
    final row = TaskRow();
    rows.add(row);
    _kept.add(row);
    return row;
  }

  group('the native type of a Dart class', () {
    test('the class has a GType of its own', () {
      expect(TaskObject.GType, isNot(0));
      expect(TaskObject.GType, isNot(GObject.GType));

      // GLib knows the type by name.
      expect(typeFromName('TaskObject'), TaskObject.GType);

      // And it is a GObject, so it can go anywhere a GObject goes.
      expect(typeIsA(TaskObject.GType, GObject.GType), isTrue);
    }, skip: skip);

    test('an instance reports the native type name', () {
      final task = TaskObject(content: 'write the docs');
      expect(_nativeTypeName(task), 'TaskObject');
    }, skip: skip);

    test('registering the type twice yields the same type', () {
      // The name is the type's identity in GLib — it cannot be
      // registered twice.
      expect(TaskObject.GType, TaskObject.GType);
      expect(typeFromName('TaskObject'), TaskObject.GType);
    }, skip: skip);
  });

  group('the window', () {
    test('the template is built while the window is constructed', () {
      final window = newWindow();

      // The template's `<property name="placeholder-text">` — read
      // *before* any generated field is touched. An empty window is
      // exactly what a lazily-built template produces.
      expect(window.entry.getPlaceholderText(), 'Enter a Task…');
      expect(window.tasks_list.handle, isNot(ffi.nullptr));
    }, skip: skip);

    test('the list is typed with the Dart class\'s native type', () {
      final window = newWindow();

      // The store checks its items against this type, natively.
      expect(window.tasks.getItemType(), TaskObject.GType);
    }, skip: skip);

    test('the store holds the task', () {
      final window = newWindow();
      final task = TaskObject(content: 'write the docs');

      window.tasks.append(task);
      expect(window.tasks.getNItems(), 1);
    }, skip: skip);

    test('the store refuses an item that is not a task', () {
      final window = newWindow();

      // `g_list_store_append` asserts the item's type against the
      // store's item type and drops it. GLib prints the critical to
      // stderr; the store stays empty.
      window.tasks.append(GObject(GObject.GType));
      expect(window.tasks.getNItems(), 0);
    }, skip: skip);

    test('the entry adds a task', () {
      final window = newWindow();

      window.entry.setText('  write the docs  ');
      // The entry's `activate` signal is what the window listens to.
      window.addTask();

      expect(window.tasks.getNItems(), 1);
      expect(window.entry.getText(), isEmpty, reason: 'the entry is cleared');
    }, skip: skip);

    test('an empty entry adds nothing', () {
      final window = newWindow();

      window.entry.setText('   ');
      window.addTask();

      expect(window.tasks.getNItems(), 0);
    }, skip: skip);
  });

  group('the rows the list view builds', () {
    test('the list view builds a row for the task', () {
      final window = newWindow();

      window.tasks.append(TaskObject(content: 'write the docs'));

      // The list view allocates its items when it is realized and the
      // main loop runs.
      window.present();
      _pumpMainLoop();

      expect(listItems, hasLength(1));

      // The `setup` handler put a row in the list item, and the `bind`
      // handler filled it in.
      final row = listItems.first.getChild() as TaskRow;
      expect(row.content_label.getLabel(), 'write the docs');

      // And the list item holds the very Dart object the store was
      // given.
      expect(listItems.first.getItem(), same(window.tasks.getObject(0)));
    });

    test('a row is built for every task', () {
      final window = newWindow();

      window.tasks.append(TaskObject(content: 'first'));
      window.tasks.append(TaskObject(content: 'second'));
      window.present();
      _pumpMainLoop();

      expect(window.tasks.getNItems(), 2);
      expect(listItems, hasLength(2));
      expect(
        listItems
            .map(
              (item) => (item.getChild() as TaskRow).content_label.getLabel(),
            )
            .toList(),
        ['first', 'second'],
      );
    });
  });

  group('a row', () {
    test('the row shows the task it is bound to', () {
      final task = TaskObject(content: 'write the docs');
      final row = newRow();

      row.bind(task);
      expect(row.content_label.getLabel(), 'write the docs');
      expect(row.completed_button.getActive(), isFalse);
    }, skip: skip);

    test('the check button writes back into the task', () {
      final task = TaskObject(content: 'write the docs');
      final row = newRow();
      row.bind(task);

      row.completed_button.setActive(true);
      expect(task.completed, isTrue);
    }, skip: skip);
  });

  group('the round trip through native code', () {
    test('the store hands the very Dart object back', () {
      final window = newWindow();
      final task = TaskObject(content: 'write the docs');
      _kept.add(task);
      window.tasks.append(task);

      // The store holds the *native* object. Reading it back goes
      // through the wrapper cache, which finds the Dart object the
      // window created — the same instance, with its Dart state.
      final read = window.tasks.getObject(0);
      expect(read, same(task));
      expect((read! as TaskObject).content, 'write the docs');
    }, skip: skip);
  });
}
