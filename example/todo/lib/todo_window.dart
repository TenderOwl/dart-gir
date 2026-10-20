// The window: an entry to type a task and a list of tasks.
//
// The list is a `GListStore` typed with the *native* type of the Dart
// class `TaskObject`:
//
//     final GListStore tasks = GListStore(TaskObject.GType);
//
// `GListStore` checks every item against the type it was created with,
// natively, so the store only ever holds `TaskObject`s — and the
// `bind` callback below gets the very Dart object the window created,
// because the wrapper cache maps the native pointer back to it.

import 'package:gio/gio.dart';
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';
import 'package:todo/task_object.dart';
import 'package:todo/task_row.dart';

part 'todo_window.g.dart';

@GtkTemplate(source: GtkTemplateFile('data/window.ui'))
class TodoWindow extends GtkApplicationWindow with _$TodoWindowTemplate {
  TodoWindow(super.app) {
    // GTK builds a widget's template in the instance initializer.
    // Dart has no instance-initializer hook, so the generated mixin
    // exposes `initTemplate()` and the widget calls it from its
    // constructor. Without this call the window stays empty: the
    // template is only built lazily, on the first read of a
    // generated field.
    initTemplate();
    _setupList();
  }

  /// The tasks shown in the list.
  ///
  /// The store is typed natively: `GListStore` refuses an item that is
  /// not an instance of `TaskObject.GType`.
  final GListStore tasks = GListStore(TaskObject.GType);

  /// The selection model the list view shows.
  ///
  /// `GtkNoSelection` does not take a reference on the model it
  /// wraps: the store has to outlive the selection, or the selection
  /// disposes a model that is already gone. Holding the selection
  /// here — next to the store it wraps — keeps the store alive for as
  /// long as the selection uses it.
  late final GtkNoSelection selection = GtkNoSelection(tasks);

  /// Builds the rows of the list.
  late final GtkSignalListItemFactory itemFactory = GtkSignalListItemFactory();

  void _setupList() {
    // `GtkNoSelection` wraps the model in a selection model that
    // selects nothing — a plain list of rows.
    tasks_list.setModel(selection);

    // `setup` runs once per row: build the widgets.
    itemFactory.onSetup((item) {
      // The GIR types this signal's argument as `GObject` — GTK's C
      // signature passes a `GtkListItem`, but the introspection data
      // does not say so. `cast` re-wraps the handle as the real type;
      // a plain `as GtkListItem` would fail, because the object the
      // trampoline hands over really is a `GObject`.
      final listItem = item.cast<GtkListItem>(GtkListItem.fromPointer);
      listItem.setChild(TaskRow());
    });
    // `bind` runs every time the row is given a task: fill it in.
    itemFactory.onBind((item) {
      final listItem = item.cast<GtkListItem>(GtkListItem.fromPointer);
      // The row is the widget the list item holds. It was registered
      // in the wrapper cache under its own address, so the `GObject`
      // the list item hands back *is* the `TaskRow` the `setup`
      // handler created.
      final row = listItem.getChild() as TaskRow;
      // The item comes back as the *same* Dart object the store was
      // given — the wrapper cache found it.
      final task = listItem.getItem() as TaskObject;
      row.bind(task);
    });
    tasks_list.setFactory(itemFactory);
  }

  /// Adds the entry's text as a new task.
  ///
  /// An empty entry adds nothing.
  void addTask() {
    final text = entry.getText().trim();
    if (text.isEmpty) return;
    tasks.append(TaskObject(content: text));
    entry.setText('');
  }

  /// The entry's secondary icon adds the task, like `Enter` does.
  ///
  /// The template wires the entry's `icon-release` signal to this
  /// method. The signal carries the icon's position, and the generated
  /// mixin forwards it — the argument is part of the signal's
  /// signature, so the method takes it too.
  @GtkTemplateCallback()
  void onIconRelease(GtkEntryIconPosition pos) {
    addTask();
  }

  @GtkTemplateCallback()
  void onActivate() {
    addTask();
  }
}
