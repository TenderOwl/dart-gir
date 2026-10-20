// One row of the task list.
//
// The row is a `@GtkTemplate` widget: `data/task_row.ui` declares the
// check button and the label, and the generated `_$TaskRowTemplate`
// mixin binds them.

import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';
import 'package:todo/task_object.dart';

part 'task_row.g.dart';

@GtkTemplate(source: GtkTemplateFile('data/task_row.ui'))
class TaskRow extends GtkBox with _$TaskRowTemplate {
  TaskRow() : super(.horizontal, 0) {
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
