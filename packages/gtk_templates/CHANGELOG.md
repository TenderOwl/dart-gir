# Changelog

## 0.3.0 — Codegen runtime support

- New `GBytes` class and `gbytesFromString(String)` helper
  in `package:gtk_templates`. Hand-written FFI binding to
  `g_bytes_new` in `libglib-2.0`, using `package:glib`'s
  `glibLookup` for the symbol. The follow-up regeneration
  of `package:gobject` will replace this with a re-export
  of the generated record.
- The codegen-emitted mixin now uses `gbytesFromString` to
  wrap the embedded template XML before passing it to
  `GtkWidgetClass.setTemplate(...)`.

## 0.2.0 — Breaking change

`@GtkTemplate`'s single mandatory keyword argument is now `source:`,
of type `GtkTemplateSource`. The two variants are:

- `GtkTemplateXml(content)` — the raw XML string, embedded as a
  Dart string literal at the call site.
- `GtkTemplateFile(path)` — a path to a `.ui` file, resolved
  relative to the **package root** (the directory holding
  `pubspec.yaml`).

The 0.1.0 form `@GtkTemplate(resourcePath: '/com/myapp/window.ui')`
is **gone**. `GtkWidgetClass.setTemplateFromResource` is no
longer in the codegen dispatch; users who need it call the
lower-level API directly outside the `gtk_templates` system.

### Migrating from 0.1.x

```dart
// 0.1.0 — gone.
@GtkTemplate(resourcePath: '/com/myapp/window.ui')
class A extends GtkBox { ... }

// 0.2.0 — file in the package source tree.
@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class A extends GtkBox { ... }

// 0.2.0 — inline XML, for short templates and tests.
@GtkTemplate(source: GtkTemplateXml('''
<interface>
  <template class="A" parent="GtkBox"/>
</interface>
'''))
class A extends GtkBox { ... }
```

For users with a `.ui` file at a known package-root-relative
path, the `file:` form is the direct replacement. The codegen
reads the file at build time and embeds its contents as a
string; the runtime path is then identical to the `xml:` form.

## 0.1.0

Initial release.

- `@GtkTemplate`, `@GtkTemplateChild`, `@GtkTemplateCallback`
  marker annotations read by `package:gtk_templates_builder`.
- `getWidgetClass(GtkWidget)` runtime helper used by the
  codegen-emitted `_$ClassTemplate` mixin to walk from a widget
  instance to its `GtkWidgetClass*`.
- `snakeCase(String)` conversion used by the mixin when
  registering callback symbols. Mirrors PyGObject's
  `camel_to_snake` (no coalescing of trailing capitals — GTK
  template symbols don't tend to have them).
