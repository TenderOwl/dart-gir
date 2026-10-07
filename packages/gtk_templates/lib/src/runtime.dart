/// Runtime helpers used by the codegen-emitted `_$ClassTemplate`
/// mixin and by user code that needs them directly.
///
/// These are pure functions / extension methods — they don't
/// hold state. The builders' emitted mixin calls into them; user
/// code rarely needs to.
library;

import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart';

/// Walks the GObject type system from a widget instance to its
/// `GtkWidgetClass*`.
///
/// Path: `handle` → `GTypeInstance*` → type name (`String`) →
/// `GType` (int) → `TypeClass*` → `GtkWidgetClass.fromPointer`.
///
/// This is the same lookup GTK performs internally in macros like
/// `GTK_WIDGET_GET_CLASS`. The codegen-emitted mixin uses it from
/// its `initTemplate()` override to register the per-instance
/// signal connections.
///
/// Returns null if the lookup fails (e.g. the handle isn't a
/// registered GObject, or `typeFromName` can't resolve it). The
/// caller should treat null as "class init didn't run".
GtkWidgetClass? getWidgetClass(GtkWidget widget) {
  final typeName = typeNameFromInstance(
    GTypeInstance.fromPointer(widget.handle),
  );
  if (typeName.isEmpty) return null;
  final typeId = typeFromName(typeName);
  if (typeId == 0) return null;
  final classPtr = GTypeClass.peek(typeId);
  if (classPtr == null) return null;
  return GtkWidgetClass.fromPointer(classPtr.handle);
}

/// Converts a `lowerCamelCase` Dart method name to the
/// `snake_case` symbol GTK looks up at template-load time.
///
/// Examples:
///   `onClicked`          → `on_clicked`
///   `helloButtonClicked` → `hello_button_clicked`
///   `a`                 → `a`
///   `aB`                → `a_b`
///
/// Algorithm mirrors PyGObject' `camel_to_snake` (which itself
/// mirrors GTK's macro convention used in
/// `gtk_widget_class_bind_template_child` etc.):
///   1. Lowercase the first character.
///   2. Insert an underscore before every subsequent capital
///      letter; lowercase that letter.
///   3. If a trailing capital exists (e.g. `fooURL`), the
///      insertion above leaves `foo_u_r_l`; PyGObject coalesces
///      runs of trailing capitals — we don't here because GTK
///      template symbols don't tend to have them. Add a
///      coalescing pass if a corpus use-case shows up.
String snakeCase(String camel) {
  if (camel.isEmpty) return camel;
  final buffer = StringBuffer();
  for (var i = 0; i < camel.length; i++) {
    final c = camel[i];
    final isUpper = c.toUpperCase() == c && c.toLowerCase() != c;
    if (i > 0 && isUpper) buffer.write('_');
    buffer.write(c.toLowerCase());
  }
  return buffer.toString();
}