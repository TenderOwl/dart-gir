/// Field annotation. The generated `_$<ClassName>BindTemplate()` exposes
/// a `getTemplateChild<T>(name)` lookup helper that fetches the named
/// child from the loaded template via
/// `gtk_widget_get_template_child(GType, name)` and wraps it in `T`.
///
/// Mark each field that backs a template child with this annotation. The
/// field's declared Dart type supplies the cast target at the call site
/// (the generated getter emits `T.fromPointer(...)` directly).
///
/// The id in the `.ui` defaults to the snake_case of the field name —
/// e.g. a field `titleLabel` binds to a child declared as
/// `<object id="title_label" class="GtkLabel"/>` in the `.ui`. Pass an
/// explicit [name] when the .ui id doesn't match the Dart field name.
///
/// Example:
///
/// ```dart
/// @GtkTemplate(resourcePath: '/com/example/todo_window.ui')
/// class TodoWindow extends AdwApplicationWindow {
///   TodoWindow() : super() {
///     _\$TodoWindowBindTemplate();
///     initTemplate();
///     // The generated `getTemplateChild<GtkLabel>('title_label')`
///     // call resolves via the @TemplateChild() annotation below.
///     titleLabel = getTemplateChild<GtkLabel>('title_label');
///   }
///
///   @TemplateChild()
///   late GtkLabel titleLabel;
/// }
/// ```
class TemplateChild {
  const TemplateChild({this.name = ''});

  /// Optional override for the `id` in the `.ui` file. When empty
  /// (the default), the builder derives the id from the field name
  /// (snake_case).
  final String name;
}