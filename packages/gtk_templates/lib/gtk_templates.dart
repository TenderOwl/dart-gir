/// GtkBuilder-template support for user-defined `GtkWidget` subclasses.
///
/// Three annotations mirror the ergonomic shape of PyGObject's
/// `@Gtk.Template` / `Gtk.Template.Child` and Vala/C#'s `[GtkTemplate]` /
/// `[GtkChild]`:
///
/// * [GtkTemplate] — marks a class as backed by a `GtkBuilder` `.ui` file
///   loaded from a GResource path.
/// * [TemplateChild] — binds a named child widget from the loaded template
///   onto a `late` field.
/// * [TemplateCallback] — wires a signal handler declared in the `.ui` to
///   a Dart method on the class.
///
/// The companion build_runner builder (`gtk_templates_builder`) scans the
/// user's `.dart` source for these annotations and emits a `part` file
/// containing a `_$<ClassName>BindTemplate()` method that does the
/// GLib-side bookkeeping (one-shot `g_type_register_static`,
/// `gtk_widget_class_set_template_from_resource`,
/// `bind_template_callback_full`, child lookup via
/// `gtk_widget_get_template_child`). The user calls that method from the
/// constructor, then calls `initTemplate()` on the instance.
///
/// Example:
///
/// ```dart
/// import 'package:adw/adw.dart';
/// import 'package:gtk4/gtk4.dart';
/// import 'package:gtk_templates/gtk_templates.dart';
///
/// part 'todo_window.gtk_templates.dart';
///
/// @GtkTemplate(resourcePath: '/com/example/todo_window.ui')
/// class TodoWindow extends AdwApplicationWindow {
///   TodoWindow() : super() {
///     _\$TodoWindowBindTemplate();
///     initTemplate();
///     titleLabel = getTemplateChild<GtkLabel>('title_label');
///   }
///
///   @TemplateChild()
///   late GtkLabel titleLabel;
///
///   @TemplateCallback('add-button::clicked')
///   void onAddClicked(GtkButton button) { /* ... */ }
/// }
/// ```
library;

export 'src/gtk_template.dart';
export 'src/template_child.dart';
export 'src/template_callback.dart';
export 'src/template_lookup.dart';