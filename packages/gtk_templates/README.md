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
  <template class="NotepadWindow" parent="AdwApplicationWindow">
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
            </child>
            <child>
              <object class="GtkButton" id="button">
                <property name="label">Click me</property>
                <signal name="clicked" handler="on_clicked"/>
              </object>
            </child>
          </object>
        </property>
      </object>
    </property>
  </template>
</interface>
'''))
class NotepadWindow extends AdwApplicationWindow
    with _$NotepadWindowTemplate {
  NotepadWindow(super.app) {
    // Build the template while the widget is constructed. GTK does
    // this in the instance initializer; Dart has no equivalent, so
    // the generated mixin exposes `initTemplate()` and the widget
    // calls it here.
    initTemplate();
  }

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
  NotepadWindow(super.app) {
    initTemplate();
  }
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
registers. The builder **auto-wires** signals from the
template XML — the user declares an instance method whose
name matches the XML's `handler="..."` attribute (converted
to `lowerCamelCase`) and the generated mixin connects the
signal for them. The annotation is still accepted for
forward-compat; the scanner records it on
`ClassTemplatePlan.callbacks` for diagnostics.

See [Callback trampoline](#callback-trampoline) below for
the full contract, including the arity requirement.

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

### `widgetTypeOf(GtkWidget)`

The native `GType` of a widget instance. A Dart subclass of a widget
type does **not** get a `GType` of its own — the native instance is an
instance of the *superclass's* type, and this is the type GTK sees.

It is the type the template is installed on, and the type
`getTemplateChild()` expects as its `widget_type` argument (the type
that *declared* the child — not the child's own type).

### `prepareTemplateXml(String, int)`

Prepares the user's template XML for GTK:

1. The `<template>` element's `class` and `parent` attributes are
   rewritten to the instance's real native type and that type's direct
   parent. GTK checks both and rejects a mismatch, and a Dart
   subclass has no `GType` of its own — so the type name the user
   writes (`class="MyWindow"`) can never match.
2. `<signal>` elements are removed. GtkBuilder resolves
   `<signal handler="…">` by looking the handler name up as a **C
   symbol**, which a Dart class cannot provide; the generated mixin
   wires the signal with a Dart closure instead.

The underlying pieces are available separately:
`rewriteTemplateTypes(String, String, [String?])` (pure) and
`stripTemplateSignals(String)` (pure).

### `claimTemplateType(int, String)`

GTK stores the template on the **native class** and allows exactly one
per class (`gtk_widget_class_set_template()` asserts
`widget_class->priv->template == NULL`). A Dart subclass has no
`GType` of its own, so two Dart template classes cannot share one
native widget type.

`claimTemplateType(gtype, owner)` returns `true` when the caller is
the first to claim the type (and therefore has to install the
template), `false` when the same owner claims it again, and throws a
`StateError` when a *different* owner claims it.

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

`GBytes` is the record generated by `gir_generator` from
the glib `<glib:boxed>` declaration; `package:gtk_templates`
re-exports it from `package:glib` so user code needs a
single import. `gbytesFromString(String)` and
`gbytesFromUint8List(Uint8List)` are thin FFI wrappers
over `g_bytes_new` in `libglib-2.0` (resolved through
`package:glib`'s `glibLookup`). The codegen-emitted mixin
uses `gbytesFromString` to convert the embedded template
XML into a `GBytes*` for `GtkWidgetClass.setTemplate(...)`.

```dart
final g = gbytesFromString('<interface>...</interface>');
// g.handle is a `GBytes*`; ownership is held by the
// mixin's `static late final`, freed on process exit.
```

## Generated mixin (what `gtk_templates_builder` emits)

For a source file with `@GtkTemplate`-annotated classes, the
builder emits one `<source-basename>.g.dart` **part file**
next to it — the same convention `json_serializable` uses, so
the name is derivable from the source file's name alone. The
file contains:

- A `part of '<source>.dart';` directive, so the mixin lives
  in the user's library.
- The template XML as a top-level `String` constant per
  class.
- A `List<_TemplateChildSpec>` the mixin iterates over, and
  the `_TemplateChildSpec` class.
- `mixin _$<className>Template on <parentType>` per
  annotated class, with:
  - A one-shot `_ensureClassInit(int widgetType)` that prepares the
    XML and wraps it in a `GBytes`.
  - An `initTemplate()` override of `GtkWidget.initTemplate()`: it
    resolves the widget's class, installs the template **once per
    native class**, binds the children, calls
    `super.initTemplate()` and wires the signals. The host widget
    calls it from its constructor — GTK builds a widget's template in
    the instance initializer and Dart has no equivalent.
  - A per-instance `_ensureInstanceInit()` that falls back to
    `initTemplate()` when the host never called it.
  - A `late final <Type> <id>` per child, populated by
    `getTemplateChild` after the template is built.
  - A `_wireSignals()` block (when the XML declares
    `<signal name="X" handler="Y"/>`) that calls
    `child.on<SignalName>(() => (this as dynamic).userMethod())`
    per signal after the children are populated. See
    [Callback trampoline](#callback-trampoline).

The user's file declares `part '<source-basename>.g.dart';`
and their class declares `with _$ClassTemplate`, then
accesses the fields directly. The user does **not** declare
`late final` fields — the mixin provides them.

Because the generated file is a `part of`, it inherits the
user's library's imports and cannot declare its own. The
library must import `package:gtk4/gtk4.dart`,
`package:gtk_templates/gtk_templates.dart` and the package that
declares the parent widget type. The builder checks this and fails
with the exact import lines to add.

## Callback trampoline

The builder wires signals automatically. For each
`<signal name="X" handler="Y"/>` in the template XML, the
emitted mixin calls
`child.on<SignalName>(() => (this as dynamic).<Y>())` after
`initTemplate()` returns. The user only has to declare
the matching instance method:

```dart
@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class MyWindow extends GtkApplicationWindow
    with _$MyWindowTemplate {
  MyWindow(super.app) {
    initTemplate();
  }

  // 'clicked' on GtkButton has signature `void Function()`
  // in the GTK FFI binding; the user method must match.
  void onClicked() {
    print('clicked');
  }
}
```

with the corresponding XML:

```xml
<object class="GtkButton" id="button">
  <signal name="clicked" handler="on_clicked"/>
</object>
```

The method name is the snake-case `handler` attribute
converted to `lowerCamelCase` (`on_clicked` →
`onClicked`). The signal arity must match the
GIR-declared arity of the FFI binding's
`on<SignalName>(...)` overload — e.g. `clicked` on
`GtkButton` is `void Function()`, so the user method
takes no arguments. Mismatched arity surfaces as a
runtime type error when the signal fires, not a
build-time diagnostic.

The `<signal>` element is what the **builder** reads to generate the
trampoline. It is removed from the XML before GTK sees it: GtkBuilder
would resolve `on_clicked` as a C symbol in the object's class scope,
which a Dart class cannot provide.

The dispatch goes through `dynamic` because the mixin is
declared `on <ParentType>`: the analyzer rejects a call to a
member the parent type does not declare, and the user's
method is declared on *their* class, not on the parent.
`dynamic` defers the call to the runtime class's method
table without giving up static analysis on the rest of the
mixin.

## Migrating from 0.1.x or 0.2.x

0.1.0's `@GtkTemplate(resourcePath: ...)` is gone. The
0.2.0 polymorphic `source:` API is unchanged in 0.3.0.
0.3.0 made the mixin the source of `late final` fields;
0.3.1 added the callback trampoline so the user no longer
calls `connectSignal(...)` from their constructor.

`GtkWidgetClass.setTemplateFromResource` is not in the
codegen dispatch. Users who need it call the lower-level
binding directly outside the `gtk_templates` system.

## Migrating from 0.3.x

The runtime API is unchanged; the *builder's* output contract
changed in 0.4.0. See the
[builder's migration notes](../gtk_templates_builder/README.md#migrating-from-03x)
for the `part` directive rename and the `dynamic` dispatch.

## Migrating from 0.4.x

**Your widget class must now call `initTemplate()`** from its
constructor:

```dart
TodoWindow(super.app) {
  initTemplate();
}
```

0.4.x built the template lazily, on the first read of a generated
field. A widget that never read one came up **empty** — the window
was there, the template was never instantiated. 0.5.0 makes the
template part of the construction instead.

The rest of the runtime API is unchanged: the annotations, the
`late final` fields, the callback trampoline and the helper
functions keep their signatures. `getWidgetClass` gained a sibling,
`widgetTypeOf`, and four helpers were added —
`prepareTemplateXml`, `rewriteTemplateTypes`, `stripTemplateSignals`
and `claimTemplateType`.
