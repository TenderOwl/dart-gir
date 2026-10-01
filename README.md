# gir-bindings

A [Dart workspace](https://dart.dev/tools/pub/workspaces) monorepo that
generates type-safe, statically-analysed, idiomatic Dart FFI bindings for
the GObject C ecosystem — GLib, GObject, Gio, GdkPixbuf, Cairo, Pango,
Gdk4, Graphene, Gsk4, Gtk4, Adw, and GtkSource-5.

One generator (`generator/`) consumes upstream [`.gir`](https://docs.gtk.org/gir/) files
and emits the per-library packages under `packages/`. The generated code
is the only API surface; raw FFI is the escape hatch.

## Packages

| Package | Namespace | Native lib |
| --- | --- | --- |
| `package:glib` | `GLib 2.0` | `libglib-2.0` |
| `package:gobject` | `GObject 2.0` | `libgobject-2.0` |
| `package:gio` | `Gio 2.0` | `libgio-2.0` |
| `package:gdk_pixbuf` | `GdkPixbuf 2.0` | `libgdk_pixbuf-2.0` |
| `package:cairo` | `cairo 1.0` | `libcairo` |
| `package:pango` | `Pango 1.0` | `libpango-1.0` |
| `package:gdk4` | `Gdk 4.0` | `libgtk-4` |
| `package:graphene` | `Graphene 1.0` | `libgraphene-1.0` |
| `package:gsk4` | `Gsk 4.0` | `libgtk-4` |
| `package:gtk4` | `Gtk 4.0` | `libgtk-4` |
| `package:adw` | `Adw 1` | `libadwaita-1` |
| `package:gtk_source5` | `GtkSource 5` | `libgtksourceview-5` |
| `package:gir_ffi` | runtime helpers | — |

All packages are `publish_to: none` and pinned to the workspace version.

## Features

Every GObject-rooted class exposes a PyGObject-style typed `props`
accessor that mirrors the GIR `<property>` elements and delegates to the
existing typed `get<Name>` / `set<Name>` methods — no GValue boxing, no
extra FFI lookups, full Dart static type checking:

```dart
import 'package:gtk4/gtk4.dart' as gtk show init;
import 'package:gtk4/gtk4.dart';

void main() {
  gtk.init();
  final button = GtkButton();

  // Set and read a writable property.
  button.props.label = 'Save';
  print(button.props.label);            // 'Save'

  // Toggle a bool property.
  button.props.canShrink = true;
  print(button.props.canShrink);        // true

  // Inherited from GtkWidget — no redeclaration needed.
  print(button.props.canFocus);         // false
}
```

Other highlights:

* **Interface methods mirrored onto concrete classes** —
  `button.setActionName('win.open')` instead of
  `GtkActionable(button.handle).setActionName(...)`. Async interface
  methods get the lifetime-safe `*Callback` overload.
* **Typed signal helpers** — `app.onOpen((GList<File> files, String hint)
  { ... })`, inherited signals surfaced on every descendant class.
* **Caller-allocated OUT parameters** — methods like
  `gtk_text_buffer_get_start_iter` return the typed wrapper
  (`GtkTextIter`) instead of taking a buffer the user has to manage.
* **Nullable callbacks** — `g_idle_add_full` /
  `g_timeout_add_full` / signal handlers accept Dart callbacks
  directly.
* **Cross-package imports + path-deps** are emitted automatically by
  the resolver — `Adw` classes can use `GtkWidget`, `GdkCursor`,
  `GObject`, etc. without manual wiring.

See [`docs/`](./docs/) for the full design reference and
[`CHANGELOG.md`](./CHANGELOG.md) for the release history.

## Quick start

```bash
# Install deps (workspace root).
dart pub get

# Regenerate all packages from .gir files.
dart run generator/bin/generate.dart --gir-dir /path/to/gir-1.0 \
  GLib-2.0 GObject-2.0 Gio-2.0 GdkPixbuf-2.0 cairo-1.0 Pango-1.0 \
  Gdk-4.0 Gtk-4.0 Graphene-1.0 Gsk-4.0 Adw-1 GtkSource-5

# Build / lint / test.
dart analyze
dart test            # generator + per-package tests
```

Per-package iteration: `cd packages/<name> && dart test`.

## Layout

```
generator/             the GIR → Dart generator
  bin/generate.dart    CLI entry point
  lib/src/
    emit/              per-symbol-kind emitters
    gir/               GIR XML model + parser
    resolve/           type / name resolution
  test/                generator unit tests
packages/
  gir_ffi/             handwritten runtime helpers shared by every package
  glib  gobject  gio   GLib stack
  cairo  pango         text + 2D rendering
  gdk4  graphene  gsk4
  gtk4  adw  gtk_source5
example/               consumer app (Gtk4 editor)
docs/                  design reference
```

The full layout and conventions are documented in [`AGENTS.md`](./AGENTS.md).
