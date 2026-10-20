# todo

A GTK4 task list built on two features of this workspace:

* the **composite-template stack** — the window's and the row's
  templates live in `data/*.ui`, and `gtk_templates_builder` writes
  the mixins that bind their children;
* a **Dart class with a native type** — `TaskObject` is a Dart class
  that registers a GType with GLib, so a `GListStore` can hold it and
  type-check its items natively.

## The Dart GObject

`lib/task_object.dart`:

```dart
class TaskObject extends GObject {
  static int get GType => registerDartType('TaskObject', GObject.GType);

  TaskObject({this.completed = false, required this.content}) : super(GType);

  bool completed;
  String content;
}
```

`registerDartType` registers a static GType with GLib, derived from
`GObject`. The name is the type's identity — GLib refuses to
register it twice — so the runtime returns the type registered first.

The window's model is typed with it:

```dart
final GListStore tasks = GListStore(TaskObject.GType);
```

`GListStore` checks every item against that type, natively: a plain
`GObject` is rejected, a `TaskObject` is accepted.

The list view's `bind` callback reads the item back:

```dart
itemFactory.onBind((item) {
  final listItem = item.cast<GtkListItem>(GtkListItem.fromPointer);
  final row = listItem.getChild() as TaskRow;
  final task = listItem.getItem() as TaskObject;
  row.bind(task);
});
```

The GIR types the `setup` and `bind` signals' argument as `GObject` —
GTK's C signature passes a `GtkListItem`, but the introspection data
does not say so. A plain `item as GtkListItem` therefore throws a
`TypeError`, and GLib swallows the exception raised in a signal
handler: the model fills up, but the list stays empty. `cast` re-wraps
the handle as the real type.

`getItem()` returns the *same* `TaskObject` the window created — the
wrapper cache in `package:gir_ffi` maps the native pointer back to it
— so the row writes back into the object the application still holds.

The design is in
[docs/dart-gobjects.md](../../docs/dart-gobjects.md).

## The templates

The window's template lives in `data/window.ui`; `lib/todo_window.dart`
names it with
`@GtkTemplate(source: GtkTemplateFile('data/window.ui'))` and the
builder emits a `lib/todo_window.g.dart` **part file** that holds the
`_$TodoWindowTemplate` mixin. Because the generated file is a
`part of 'todo_window.dart'`, the mixin lives in the user's
library — its imports and the trampoline's method references
resolve at compile time without dynamic casts.

The mixin:

- Overrides `GtkWidget.initTemplate()`: the widget calls it from
  its constructor, and the mixin installs the template on
  the window's class via `GtkWidgetClass.setTemplate`,
  binds the `<object>` children (`entry`, `tasks_list`) via
  `bindTemplateChildFull`, builds the tree with
  `gtk_widget_init_template()` and wires the signals.
- Exposes the children as `late final` fields on the mixin.
- Wires the `<signal name="…" handler="…"/>` elements to the user's
  methods via per-instance `connectSignal` (the callback trampoline).
  The user doesn't have to call `connectSignal(...)` from the
  constructor.

Two details of the XML are worth knowing:

- The `<template class="…" parent="…">` attributes are advisory. A
  Dart subclass has no `GType` of its own, so the mixin rewrites
  them to the instance's real native type before GTK sees them —
  GTK checks both and rejects a mismatch.
- The `<signal>` element is read by the *builder* (it tells the
  codegen what to wire) and removed before GTK sees the XML:
  GtkBuilder would resolve the handler as a C symbol, which a Dart
  class cannot provide.

The `.ui` file is read **through the build**, so it is a tracked
input: editing it re-runs the builder and the next build regenerates
the part file. It also has to be a public asset of the package — a
build sees `lib/**` and `bin/**` and nothing else — which is why
`build.yaml` declares `additional_public_assets: [data/**]`. A
template under `lib/` would need no configuration at all.

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

## Test

```
# The suite needs a display; it skips itself when there is none.
xvfb-run -a dart test example/todo
```

The suite covers the native type of the Dart class, the typed store,
the template, the rows the list view builds, and the round trip through
the native list. Its teardown disconnects the Dart signal handlers —
including the ones on the rows the list view built — and destroys the
window while the isolate is alive; see the lifecycle notes in
[docs/dart-gobjects.md](../../docs/dart-gobjects.md#lifecycle-notes).

## Layout

```
lib/
  app.dart                       # AdwApplication wiring
  task_object.dart               # a Dart class with a native type
  task_row.dart                  # @GtkTemplate-annotated row
  task_row.g.dart                # generated; part of task_row.dart
  todo_window.dart               # @GtkTemplate-annotated window,
                                 #   declares the part directive
  todo_window.g.dart             # generated; part of todo_window.dart
data/
  window.ui                      # the window's template
  task_row.ui                    # the row's template
bin/
  todo.dart                      # entry point
build.yaml                       # wires gtk_templates_builder to
                                 #   lib/**.dart, and declares
                                 #   data/** a public asset
pubspec.yaml                     # path-deps on adw, dart_gobject,
                                 #   gio, glib, gobject, gtk4,
                                 #   gtk_templates,
                                 #   gtk_templates_builder
```
