/// Method annotation. The generated `_$<ClassName>BindTemplate()`
/// wires the named signal to the marked Dart method via
/// `gtk_widget_class_bind_template_callback_full`.
///
/// Each annotated method becomes a top-level trampoline:
/// `NativeCallable.isolateLocal(...)` whose closure dispatches to the
/// currently-active instance, mirroring how PyGObject's
/// `Gtk.Template.Callback` and the existing `g_idle_add_full` pattern
/// in `example/bin/example.dart` keep callback lifetimes safe for
/// long-lived signal sources.
///
/// The signal name defaults to the snake_case of the method name —
/// e.g. `onAddClicked` binds to `<signal handler="on_add_clicked"/>`
/// in the `.ui`. Pass an explicit [signalName] when the .ui handler
/// name doesn't match the Dart method name.
///
/// Example:
///
/// ```dart
/// @GtkTemplate(resourcePath: '/com/example/todo_window.ui')
/// class TodoWindow extends AdwApplicationWindow {
///   @TemplateCallback('add-button::clicked')
///   void onAddClicked(GtkButton button) { /* ... */ }
///
///   @TemplateCallback()  // → `remove_row_clicked` in the .ui
///   void onRemoveRowClicked(GtkButton button) { /* ... */ }
/// }
/// ```
class TemplateCallback {
  const TemplateCallback([this.signalName = '']);

  /// Signal handler name as it appears in the `.ui` file's
  /// `<signal handler="..."/>` attribute. When empty (the default),
  /// the builder derives the name from the Dart method name
  /// (snake_case).
  final String signalName;
}