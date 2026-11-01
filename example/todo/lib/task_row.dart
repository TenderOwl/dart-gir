// One row of the task list.
//
// The row is a `@GtkTemplate` widget: `data/task_row.ui` declares the
// check button and the label, and the generated `_$TaskRowTemplate`
// mixin binds them.
//
// The row registers a native type of its own. GTK stores a template on
// the *native class* and allows exactly one per class, so a Dart class
// that has no type of its own shares its parent's — and two Dart rows
// with the same parent could not both have a template. A type of its
// own gives the row a class of its own to put the template on.

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_gtk4/gir_gtk4.dart';
import 'package:gir_gtk_templates/gir_gtk_templates.dart';
import 'package:todo/task_object.dart';

part 'task_row.g.dart';

@GtkTemplate(source: GtkTemplateFile('data/task_row.ui'))
class TaskRow extends GtkBox with _$TaskRowTemplate {
  /// The native type of this class.
  ///
  /// Registering a type of its own is what lets the template live on
  /// this class: GTK keeps one template per native class, and a Dart
  /// subclass without a type of its own has none.
  static int get GType => registerDartType('TaskRow', GtkBox.GType);

  TaskRow()
    : super.rawFromPointer(
        newDartInstance(
          GType,
          constructProperties: {'orientation': GtkOrientation.horizontal.value},
        ),
        owned: true,
      ) {
    initTemplate();
    // The check button writes back into the task: the `toggled` signal
    // fires whenever the button's state changes, and the task is the
    // Dart object the row is bound to.
    completed_button.onToggled(() => _onToggled());
  }

  /// The task this row shows, or `null` while the row is unbound.
  TaskObject? _task;

  /// Shows [task] in this row.
  ///
  /// A list view reuses its rows: the same `TaskRow` is bound to one
  /// task after another, so the row holds the task it currently shows
  /// rather than owning one.
  void bind(TaskObject task) {
    _task = task;
    content_label.setLabel(task.content);
    // `setActive` emits `toggled`, which writes the state back into
    // the task — the same value it already had.
    completed_button.setActive(task.completed);
  }

  void _onToggled() {
    final task = _task;
    if (task == null) return;
    task.completed = completed_button.getActive();
  }
}
