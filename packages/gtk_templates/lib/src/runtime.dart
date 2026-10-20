/// Runtime helpers used by the codegen-emitted `_$ClassTemplate`
/// mixin and by user code that needs them directly.
///
/// The builder's emitted mixin calls into them; user code rarely
/// needs to.
///
/// The one piece of state is the registry of native types that
/// already carry a template ([claimTemplateType]): GTK stores the
/// template on the native class, and a Dart subclass has no
/// `GType` of its own.
library;

import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart';

/// The native `GType` of [widget].
///
/// Path: `handle` → `GTypeInstance*` → type name (`String`) →
/// `GType` (int).
///
/// A Dart subclass of a widget type does **not** get a `GType` of
/// its own — the native instance is an instance of the *superclass's*
/// type. This is the type GTK sees, the type the template is
/// installed on, and the type
/// `gtk_widget_get_template_child()` expects as its `widget_type`
/// argument.
///
/// Returns `0` when the handle isn't a registered GObject.
int widgetTypeOf(GtkWidget widget) {
  final typeName = typeNameFromInstance(
    GTypeInstance.fromPointer(widget.handle),
  );
  if (typeName.isEmpty) return 0;
  return typeFromName(typeName);
}

/// Walks the GObject type system from a widget instance to its
/// `GtkWidgetClass*`.
///
/// Path: `handle` → `GTypeInstance*` → type name (`String`) →
/// `GType` (int) → `TypeClass*` → `GtkWidgetClass.fromPointer`.
///
/// This is the same lookup GTK performs internally in macros like
/// `GTK_WIDGET_GET_CLASS`. The codegen-emitted mixin uses it from
/// its `initTemplate()` override to install the template and to
/// register the per-instance signal connections.
///
/// Returns null if the lookup fails (e.g. the handle isn't a
/// registered GObject, or `typeFromName` can't resolve it). The
/// caller should treat null as "class init didn't run".
GtkWidgetClass? getWidgetClass(GtkWidget widget) {
  final typeId = widgetTypeOf(widget);
  if (typeId == 0) return null;
  final classPtr = GTypeClass.peek(typeId);
  if (classPtr == null) return null;
  return GtkWidgetClass.fromPointer(classPtr.handle);
}

/// The native types that already carry a GTK template.
///
/// GTK stores the template on the **native class**, and
/// `gtk_widget_class_set_template()` refuses to replace it
/// (`assertion 'widget_class->priv->template == NULL' failed`).
/// A Dart subclass has no `GType` of its own, so two Dart template
/// classes cannot share one native widget type — the second one has
/// to be told so instead of tripping a GTK assertion.
///
/// Maps the native `GType` to the name of the Dart class that
/// claimed it.
final Map<int, String> _templateOwners = <int, String>{};

/// Claims [widgetType] for the template owned by the Dart class
/// [owner].
///
/// Returns `true` when the caller is the first to claim the type
/// and therefore has to install the template
/// (`gtk_widget_class_set_template()` +
/// `gtk_widget_class_bind_template_child_full()`), and `false` when
/// the same [owner] already claimed it — the template is on the
/// class, installing it twice is an error in GTK.
///
/// Throws a [StateError] when a *different* owner already claimed
/// the type: GTK allows exactly one template per native class, and a
/// Dart subclass does not create a new `GType`.
bool claimTemplateType(int widgetType, String owner) {
  final existing = _templateOwners[widgetType];
  if (existing == null) {
    _templateOwners[widgetType] = owner;
    return true;
  }
  if (existing == owner) return false;
  throw StateError(
    'gtk_templates: the native widget type (GType $widgetType) already '
    'carries a template installed by `$existing`. GTK allows one template '
    'per native class, and a Dart subclass does not register a GType of its '
    'own — so two Dart template classes cannot share the same native '
    'widget type.',
  );
}

/// Prepares the user's template XML for GTK.
///
/// Two things happen here, both of them because a Dart subclass has
/// no `GType` of its own and no C symbols:
///
///  1. The `<template>` element's `class` and `parent` attributes are
///     rewritten to the instance's real native type and that type's
///     direct parent. GTK checks both and rejects a mismatch.
///  2. `<signal>` elements are removed. GtkBuilder resolves a
///     `<signal handler="…">` by looking the handler name up as a C
///     symbol in the object's class scope — something a Dart class
///     cannot provide. The signal is wired by the generated mixin
///     instead, through a Dart closure (the trampoline).
///
/// The rest of [xml] is returned unchanged.
String prepareTemplateXml(String xml, int widgetType) {
  final widgetTypeName = typeName(widgetType);
  if (widgetTypeName == null) return xml;

  final parentType = typeParent(widgetType);
  final parentTypeName = parentType == 0 ? null : typeName(parentType);

  return stripTemplateSignals(
    rewriteTemplateTypes(xml, widgetTypeName, parentTypeName),
  );
}

/// Pure: rewrites the `<template>` element's `class` and `parent`
/// attributes in [xml] so that they name [widgetTypeName] and
/// [parentTypeName].
///
/// GTK checks both attributes when it builds the template:
///
///   * `class` must be the type name of the widget — GTK rejects a
///     mismatch with *"Parsed template definition for type 'X',
///     expected type 'Y'"*.
///   * `parent` must be the direct parent type — GTK rejects a
///     mismatch with *"Template parent type 'X' does not match
///     instance parent type 'Y'"*.
///
/// A Dart template class has no `GType` of its own, so the type name
/// the user writes in the XML (typically the Dart class name, e.g.
/// `TodoWindow`) can never match. Rewriting the attributes against
/// the instance's real type keeps the XML free of native type names
/// while satisfying GTK's checks.
///
/// `parent` is optional in GTK's schema; when [parentTypeName] is
/// `null` the attribute is removed rather than left stale. The rest
/// of [xml] is returned unchanged.
String rewriteTemplateTypes(
  String xml,
  String widgetTypeName, [
  String? parentTypeName,
]) {
  final match = RegExp(r'<template\b[^>]*>').firstMatch(xml);
  if (match == null) return xml;

  var tag = match.group(0)!;
  tag = _setXmlAttribute(tag, 'class', widgetTypeName);
  tag = parentTypeName == null
      ? _removeXmlAttribute(tag, 'parent')
      : _setXmlAttribute(tag, 'parent', parentTypeName);
  return xml.replaceRange(match.start, match.end, tag);
}

/// Removes every `<signal>` element from [xml].
///
/// GtkBuilder connects a `<signal handler="…">` by resolving the
/// handler name as a C symbol in the object's class scope. A Dart
/// class has no C symbols, so GTK would fail with *"No function
/// named `…`"* and skip the connection.
///
/// The signal declarations are still what the **builder** reads to
/// generate the Dart-side trampoline; they are only removed from the
/// copy of the XML that is handed to GTK.
String stripTemplateSignals(String xml) {
  return xml.replaceAll(
    RegExp(r'<signal\b[^>]*?/>|<signal\b[^>]*?>.*?</signal\s*>', dotAll: true),
    '',
  );
}

/// Sets the attribute [name] of the XML start tag [tag] to [value],
/// replacing an existing value or appending the attribute.
String _setXmlAttribute(String tag, String name, String value) {
  final pattern = RegExp('(\\b$name\\s*=\\s*")([^"]*)(")');
  final match = pattern.firstMatch(tag);
  if (match != null) {
    return tag.replaceRange(
      match.start,
      match.end,
      '${match.group(1)}$value${match.group(3)}',
    );
  }
  final insertAt = tag.endsWith('/>') ? tag.length - 2 : tag.length - 1;
  return tag.replaceRange(insertAt, insertAt, ' $name="$value"');
}

/// Removes the attribute [name] from the XML start tag [tag].
String _removeXmlAttribute(String tag, String name) {
  final pattern = RegExp('\\s*$name\\s*=\\s*"[^"]*"');
  return tag.replaceFirst(pattern, '');
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
