# dart-gir

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
| `package:gir_glib` | `GLib 2.0` | `libglib-2.0` |
| `package:gir_gobject` | `GObject 2.0` | `libgobject-2.0` |
| `package:gir_gio` | `Gio 2.0` | `libgio-2.0` |
| `package:gir_gdk_pixbuf` | `GdkPixbuf 2.0` | `libgdk_pixbuf-2.0` |
| `package:gir_cairo` | `cairo 1.0` | `libcairo` |
| `package:gir_pango` | `Pango 1.0` | `libpango-1.0` |
| `package:gir_gdk4` | `Gdk 4.0` | `libgtk-4` |
| `package:gir_graphene` | `Graphene 1.0` | `libgraphene-1.0` |
| `package:gir_gsk4` | `Gsk 4.0` | `libgtk-4` |
| `package:gir_gtk4` | `Gtk 4.0` | `libgtk-4` |
| `package:gir_adw` | `Adw 1` | `libadwaita-1` |
| `package:gir_gtk_source5` | `GtkSource 5` | `libgtksourceview-5` |
| `package:gir_ffi` | runtime helpers | — |

All seventeen packages are published on pub.dev under the `gir_` prefix and
move together — one generator, one changelog, one version. Within 1.x the
emitted API only grows; what is *not* promised is the set of bound symbols,
which the per-package `skip_report.txt` states.

**Support: Linux only.** The loader knows the Windows and macOS file names
of every native library, but only Linux is executed and tested.

## Features

Every GObject-rooted class exposes a PyGObject-style typed `props`
accessor that mirrors the GIR `<property>` elements and delegates to the
existing typed `get<Name>` / `set<Name>` methods — no GValue boxing, no
extra FFI lookups, full Dart static type checking:

```dart
import 'package:gir_gtk4/gir_gtk4.dart' as gtk show init;
import 'package:gir_gtk4/gir_gtk4.dart';

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

See [`docs/`](./docs/) for the full design reference,
[`docs/release.md`](./docs/release.md) for the versioning policy, and
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

# Check that every package would pass pub.dev's rules.
dart run tool/release.dart check
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
  gir_glib  gir_gobject  gir_gio     GLib stack
  gir_cairo  gir_pango           text + 2D rendering
  gir_gdk4  gir_graphene  gir_gsk4
  gir_gtk4  gir_adw  gir_gtk_source5
  gir_gtk_templates/       composite-template runtime (annotations + helpers)
  gir_gtk_templates_builder/  the build_runner builder that generates the mixins
example/
  gtk4_examples/       small GTK4 demos
  notepad/             consumer app (Gtk4 editor)
  todo/                consumer app built on @GtkTemplate
docs/                  design reference
```

The full layout and conventions are documented in [`AGENTS.md`](./AGENTS.md).
