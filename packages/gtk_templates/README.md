# gtk_templates

`@GtkTemplate` annotations and runtime helpers for GTK4
widgets written in Dart.

This package ships the **annotations**, **runtime helpers**,
and the **`GBytes`** wrapper that the codegen-emitted mixin
in [`gtk_templates_builder`](../gtk_templates_builder)
relies on. It is a sibling of the generated `gtk4` FFI
bindings, not a replacement for them.

## Annotations

`@GtkTemplate` takes a single mandatory keyword argument,
`source:`, which is one of two values:

- `GtkTemplateXml(content)` — the raw XML, embedded as a
  Dart string literal at the call site. Convenient for small
  templates, prototypes, and tests.
- `GtkTemplateFile(path)` — a path to a `.ui` file, resolved
  relative to the **package root** (the directory holding
  `pubspec.yaml`).

```dart
import 'package:gtk_templates/gtk_templates.dart';

// Inline XML.
@GtkTemplate(source: GtkTemplateXml('''
<interface>
  <template class="NotepadWindow" parent="GtkApplicationWindow">
    <property name="content">
      <object class="AdwToolbarView">
        <child type="top">
          <object class="AdwHeaderBar"/>
        </child>
        <property name="content">
          <object class="GtkBox">
            <property name="orientation">vertical</property>
            <child>
              <object class="GtkLabel" id="counterLabel">
                <property name="label">Not clicked</property>
              </object>
              <object class="GtkButton" id="button">
                <property name="label">Click me</property>
                <signal name="clicked" handler="on_clicked"/>
              </object>
            </child>
          </object>
        </property>
      </object>
    </property>
  </object>
</interface>
'''))
class NotepadWindow extends AdwApplicationWindow
    with _$NotepadWindowTemplate {
  NotepadWindow(super.app);

  // The mixin provides `counterLabel` and `button` as
  // `late final` fields, populated by `getTemplateChild`
  // on first read.
}
```

For a `.ui` file in the package source tree, use the
`file:` form (the codegen reads the file at build time
and embeds its contents):

```dart
@GtkTemplate(source: GtkTemplateFile('lib/notepad/window.ui'))
class NotepadWindow extends AdwApplicationWindow
    with _$NotepadWindowTemplate {
  NotepadWindow(super.app);
}
```

All three annotations are `const` — they have no runtime
cost and can be used as metadata without importing the
generated mixin.

### `@GtkTemplate`

Required on every template-using class. The `source:`
argument is the polymorphic XML source. The class must
extend a `GtkWidget` subclass that participates in the
template system (`GtkWindow`, `GtkBox`,
`GtkApplicationWindow`, …).

### `@GtkTemplateChild`

Forwarded to the codegen-emitted mixin in 0.3.0+; the
codegen reads the **template XML** as the source of truth
for child names and types, and the `late final` fields
live on the mixin. The annotation is preserved in the API
for forward-compat; the scanner still records it on
`ClassTemplatePlan.children` for diagnostics.

### `@GtkTemplateCallback`

Marks an instance method as a callback the template
registers. The first cut of the codegen does **not** wire
callbacks automatically — the user calls
`connectSignal(...)` from their constructor. The
`ClassTemplatePlan.callbacks` list captures the spec for
the follow-up that emits a trampoline.

## Runtime helpers

These are imported from the same package and used by the
generated mixin. User code rarely needs them.

### `getWidgetClass(GtkWidget)`

Walks the GObject type system from a widget instance to
its `GtkWidgetClass*`:

```
handle → GTypeInstance* → type name (String) →
GType (int) → TypeClass* → GtkWidgetClass.fromPointer
```

Returns `null` if the lookup fails (the handle isn't a
registered GObject, or `typeFromName` can't resolve it);
callers should treat `null` as "class init didn't run".

### `snakeCase(String)`

Converts a `lowerCamelCase` Dart name to the `snake_case`
symbol GTK looks up at template-load time. Mirrors
PyGObject's `camel_to_snake` (no coalescing of trailing
capitals):

| Dart name              | Snake case                |
|------------------------|---------------------------|
| `onClicked`            | `on_clicked`              |
| `helloButtonClicked`   | `hello_button_clicked`    |
| `setLabel`             | `set_label`               |
| `getInternalChild`     | `get_internal_child`      |
| `fooBar`               | `foo_bar`                 |
| `fooBAR`               | `foo_b_a_r`               |

### `GBytes` / `gbytesFromString`

A hand-written FFI binding to `g_bytes_new` in
`libglib-2.0`. The codegen-emitted mixin uses
`gbytesFromString` to convert the embedded template XML
into a `GBytes*` for `GtkWidgetClass.setTemplate(...)`.

```dart
final g = gbytesFromString('<interface>...</interface>');
// g.handle is a `GBytes*`; ownership is held by the
// mixin's `static late final`, freed on process exit.
```

Hand-written because `package:gobject` doesn't yet ship a
generated `GBytes` record. When that regen lands, the
helper can become a thin re-export.

## Generated mixin (what `gtk_templates_builder` emits)

For a `@GtkTemplate`-annotated class, the builder emits a
`<className>.<lowercase>.g.dart` file containing:

- The template XML as a top-level `String` constant.
- A `List<_TemplateChildSpec>` and
  `List<_TemplateCallbackSpec>` the mixin iterates over.
- The `_TemplateChildSpec` and `_TemplateCallbackSpec`
  classes.
- `mixin _$<className>Template on <parentType>` with:
  - A one-shot `_ensureClassInit()` that wraps the XML in
    a `GBytes` and binds the children to the widget class.
  - A per-instance `_ensureInstanceInit()` that calls
    `getWidgetClass`, `setTemplate`, `bindTemplateChildFull`,
    and `initTemplate()`.
  - A `late final <Type> <id>` per child, populated by
    `getTemplateChild` after `_ensureInstanceInit`.

The user's class declares `with _$ClassTemplate` and
accesses the fields directly. The user does **not**
declare `late final` fields — the mixin provides them.

## Migrating from 0.1.x or 0.2.x

0.1.0's `@GtkTemplate(resourcePath: ...)` is gone. The
0.2.0 polymorphic `source:` API is unchanged in 0.3.0. The
only behavioural change is that the user no longer
declares `late final` fields by hand; the mixin provides
them.

`GtkWidgetClass.setTemplateFromResource` is not in the
codegen dispatch. Users who need it call the lower-level
binding directly outside the `gtk_templates` system.
