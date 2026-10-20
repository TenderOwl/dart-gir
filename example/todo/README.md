# todo

GTK4 example built with `@GtkTemplate` annotations and the
`gtk_templates_builder` codegen. The window is defined in
`lib/todo_window.dart` as inline XML; the builder emits a
`lib/todo_window.g.dart` **part file** that holds the
`_$TodoWindowTemplate` mixin. Because the generated file is a
`part of 'todo_window.dart'`, the mixin lives in the user's
library — its imports and the trampoline's method references
resolve at compile time without dynamic casts.

The mixin:

- Overrides `GtkWidget.initTemplate()`: the widget calls it from
  its constructor, and the mixin installs the template on
  `AdwApplicationWindow`'s class via `GtkWidgetClass.setTemplate`,
  binds the two `<object>` children (`counterLabel`, `button`) via
  `bindTemplateChildFull`, builds the tree with
  `gtk_widget_init_template()` and wires the signals.
- Exposes the children as `late final` fields on the mixin.
- Wires the `<signal name="clicked" handler="on_clicked"/>`
  to the user's `onClicked()` instance method via
  per-instance `connectSignal` (the callback trampoline).
  The user doesn't have to call `connectSignal(...)` from
  the constructor.

Two details of the XML are worth knowing:

- The `<template class="…" parent="…">` attributes are advisory. A
  Dart subclass has no `GType` of its own, so the mixin rewrites
  them to the instance's real native type before GTK sees them —
  GTK checks both and rejects a mismatch.
- The `<signal>` element is read by the *builder* (it tells the
  codegen what to wire) and removed before GTK sees the XML:
  GtkBuilder would resolve `on_clicked` as a C symbol, which a Dart
  class cannot provide.

## Run

```
# 1. Fetch the workspace packages (path-deps).
cd example/todo
dart pub get

# 2. Generate the _$TodoWindowTemplate mixin.
dart run build_runner build
# (or, without build_runner, run the CLI standalone:
#  dart run gtk_templates_builder lib/todo_window.dart)

# 3. Run the example.
dart run bin/todo.dart
```

The user does **not** declare `late final` fields for
`counterLabel` or `button` — the mixin provides them.
The `onClicked()` method's name is the XML's
`handler="on_clicked"` attribute converted to
`lowerCamelCase`; the arity must match the
GIR-declared `clicked` signal on `GtkButton`
(`void Function()`).

## Test

```
# The suite needs a display; it skips itself when there is none.
xvfb-run -a dart test example/todo
```

## Layout

```
lib/
  app.dart                       # AdwApplication wiring
  todo_window.dart               # @GtkTemplate-annotated window,
                                 #   declares the part directive
  todo_window.g.dart             # generated; part of todo_window.dart
bin/
  todo.dart                      # entry point
build.yaml                       # wires gtk_templates_builder to
                                 #   lib/**.dart
pubspec.yaml                     # path-deps on adw, glib, gobject,
                                 #   gtk4, gtk_templates,
                                 #   gtk_templates_builder
```
