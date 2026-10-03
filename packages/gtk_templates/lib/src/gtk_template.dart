/// Marks a `GtkWidget` subclass as backed by a `GtkBuilder` template
/// loaded from a GResource path.
///
/// The `gtk_templates_builder` build_runner builder scans the source for
/// this annotation and emits a `_$<ClassName>BindTemplate()` method into
/// the user's `part` file. That method, when called from the constructor,
/// performs the GLib-side bookkeeping that GtkBuilder XML templates need
/// but Dart has no class-init hook for:
///
/// 1. Registering a new GType for the class (via `g_type_register_static`).
/// 2. Calling `gtk_widget_class_set_template_from_resource` on the
///    resulting `GtkWidgetClass` (must run before any instance is
///    constructed).
/// 3. Wiring every [TemplateCallback]-annotated method to the
///    corresponding signal via `bind_template_callback_full`.
///
/// The user is responsible for calling the generated method from the
/// constructor, then calling `initTemplate()` on the instance to load
/// the template into it.
class GtkTemplate {
  /// `const`-constructible so the annotation can sit at compile time.
  ///
  /// [resourcePath] is the `/com/example/foo.ui`-style GResource path
  /// to the `.ui` file. The GResource bundle must be registered before
  /// any instance is constructed — the user's project is responsible for
  /// that step (e.g. via `gresource`/`glib-compile-resources` or a
  /// Flutter asset bundle).
  const GtkTemplate({required this.resourcePath});

  /// The GResource path to the `.ui` file (e.g.
  /// `'/com/example/todo_window.ui'`).
  final String resourcePath;
}