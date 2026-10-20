---
title: Bindings for GObject-based libraries, not just for GTK
doc_title: dart-gir — Dart bindings for GObject based libraries
description: dart-gir generates type-safe, statically-analysed Dart FFI bindings for GLib, GObject, Gio, Cairo, Pango, GTK4, Gdk, Graphene, GSK, libadwaita and GtkSourceView 5 from upstream GIR files.
nav_order: 1
nav_label: Home
section_label: Dart FFI · GObject · generator-driven
---

**dart-gir** is a Dart workspace monorepo with one generator that reads upstream `.gir` introspection files and emits type-safe, statically-analysed, idiomatic Dart FFI bindings. GTK 4 and libadwaita are the flagship, but nothing in the generator is specific to them — point it at a `.gir` file and it produces the same quality of API for that library.

:::{meta}
{{facts.features.typed_signals}} typed signal helpers · {{facts.features.props_accessors}} typed property accessors · {{facts.total_skipped}} recorded skips · Dart SDK {{facts.sdk_constraint}} · {{facts.license}}
:::

## Why it isn't a "GTK bindings" project

:::{cols}
### The input is introspection data

Every GObject-based library ships a `.gir` file describing its complete public API. The generator reads that and nothing else — no hand-maintained symbol lists, no per-library templates, no hardcoded knowledge of GTK. A new library is a new command-line argument.

That is the difference between a binding layer and a binding *generator*: the first is bounded by its author's patience, the second by the introspection data.

### The hard parts are solved once, per library

Ownership and nullability, signal trampolines, callback lifetimes, caller-allocated OUT parameters, interface mirroring — none of that is GTK-specific, and all of it is where naive FFI bindings quietly introduce memory bugs. Solving it in the generator means every library that goes through it inherits the fix.
:::

Today that covers the full GTK 4 stack and libadwaita. Candidates that fit the same dependency graph — `libsoup-3`, `Poppler`, `GStreamer`, `JavaScriptCore` — are listed on the [roadmap](roadmap.html). Gtk 3 is deliberately out of scope for now.

## The problem

:::{cols}
### Hand-written FFI does not scale

A single GTK window in raw `dart:ffi` is fine. A real application is thousands of symbols, every string is a `Pointer<Utf8>` you must free, every property is a manual `g_object_set` attribute string, and every signal is a `g_signal_connect_data` trampoline you have to get exactly right — or you get a use-after-free in production.

### Existing bindings don't match Dart

C-based binding layers expose the C API nearly verbatim: raw pointers, manual ref-counting, `dynamic` in the places that matter. dart-gir inverts that. The generated code is a Dart API first — typed properties, typed signals, typed OUT parameters, nullability that matches the underlying transfer semantics — with raw FFI still available as the escape hatch.
:::

## What the generated code looks like

Everything below is emitted from GIR. There is no hand-written binding layer in between you and the native call.

### Typed properties, inherited like Dart classes

```dart title=props.dart
// Every GObject-rooted class gets a PyGObject-style typed accessor.
import 'package:gtk4/gtk4.dart' as gtk show init;

void main() {
  gtk.init();
  final button = GtkButton();

  // Declared on GtkButtonProps — writes through the typed setLabel().
  button.props.label = 'Save';
  print(button.props.label);        // 'Save'  (String, not dynamic)

  button.props.canShrink = true;
  print(button.props.canShrink);    // true

  // Declared on GtkWidgetProps, inherited — no redeclaration needed.
  print(button.props.canFocus);     // false
}
```

### Typed signals and interface methods on the object itself

```dart title=signals.dart
// Inherited signals surface on every descendant class, with real types.
app.onWindowAdded((GtkWindow window) { print(window.getTitle()); });
widget.onDirectionChanged((GtkTextDirection previous) { ... });
object.onNotify((GParamSpec pspec) { ... });

// Interface methods are mirrored onto concrete classes — no wrapper object.
button.setActionName('win.open');   // not GtkActionable(button.handle).setActionName(...)

// Async methods get a lifetime-safe overload: no NativeCallable is ever closed.
file.queryInfoAsyncCallback(
  'async://example',
  (GObject? source, GAsyncResult result) { ... },
);
```

### Caller-allocated OUT parameters come back as values

```dart title=out-params.dart
// The C signature is gtk_text_buffer_get_start_iter(buf, GtkTextIter* out).
// You get a value back, and the buffer's lifetime is GC-managed.
final iter = buffer.getStartIter();     // GtkTextIter
final text = buffer.getText(iter, buffer.getEndIter(), false);

// NULL means "not set" — nullability follows transfer-ownership, always.
final maybeTitle = window.getTitle();  // String?
```

## One command, one library per argument

The generated output is disposable: change the generator, rerun one command, and every package is rebuilt from the same upstream GIR files. The CI deliberately does *not* run the generator — it lints and tests the checked-in output, so drift between generator and packages is impossible to merge silently.

:::{figure} One invocation, one package per namespace, and a report for the parts that could not be emitted.
<svg viewBox="0 0 1000 190" role="img" aria-label="Pipeline: GIR files are loaded, parsed into an immutable model, resolved and named, emitted per kind, and written out as a package plus a skip report.">
  <!-- inputs -->
  <text class="d-sub" x="8" y="16">inputs</text>
  <rect class="d-node" x="8" y="26" width="176" height="60" rx="2"/>
  <text class="d-label" x="24" y="52">Gtk-4.0</text>
  <text class="d-label" x="24" y="70">Adw-1</text>
  <text class="d-sub" x="96" y="52">…any .gir</text>
  <text class="d-sub" x="96" y="70">+ its includes</text>

  <!-- arrow -->
  <path class="d-arrow" d="M190 56 H232"/>
  <path class="d-arrow" d="M226 51 L232 56 L226 61"/>

  <!-- loader -->
  <rect class="d-node" x="238" y="26" width="164" height="60" rx="2"/>
  <text class="d-label" x="254" y="50">GirLoader</text>
  <text class="d-sub" x="254" y="68">resolves &lt;include&gt;</text>

  <path class="d-arrow" d="M408 56 H450"/>
  <path class="d-arrow" d="M444 51 L450 56 L444 61"/>

  <!-- model -->
  <rect class="d-node" x="456" y="26" width="176" height="60" rx="2"/>
  <text class="d-label" x="472" y="50">Immutable model</text>
  <text class="d-sub" x="472" y="68">every GIR element kind</text>

  <path class="d-arrow" d="M638 56 H680"/>
  <path class="d-arrow" d="M674 51 L680 56 L674 61"/>

  <!-- resolver + emitters -->
  <rect class="d-node" x="686" y="26" width="148" height="60" rx="2"/>
  <text class="d-label" x="702" y="50">TypeResolver</text>
  <text class="d-sub" x="702" y="68">+ emitters</text>

  <path class="d-arrow" d="M840 56 H882"/>
  <path class="d-arrow" d="M876 51 L882 56 L876 61"/>

  <!-- outputs -->
  <text class="d-sub" x="8" y="126">outputs</text>
  <rect class="d-node-accent" x="8" y="136" width="404" height="44" rx="2"/>
  <text class="d-label" x="24" y="162">packages/&lt;lib&gt;/ — a real Dart API</text>

  <rect class="d-node-accent" x="432" y="136" width="402" height="44" rx="2"/>
  <text class="d-label" x="448" y="162">skip_report.txt — every skip, with a reason</text>

  <!-- emitter fan-out from resolver down to both outputs -->
  <path class="d-dash" d="M760 86 V112 H210 V132"/>
  <path class="d-dash" d="M760 86 V112 H633 V132"/>
  <circle cx="760" cy="86" r="2.5" fill="currentColor" opacity="0.4"/>
</svg>
:::

[Read the design reference](design.html) →

## The libraries bound so far

This is a coverage list, not a limit. Each row is one `.gir` file; the generator itself has no per-library special cases.

:::{packages}
:::

"Skipped" is the number of entries in that package's `skip_report.txt` — see [coverage & honest gaps](features.html#coverage-and-the-honest-gaps) for what they are. Because these are coverage counts rather than difficulty counts, `gtk4` legitimately has the most: it is by far the largest API.

## How the project is verified

A project site that overstates its own maturity is worse than no site, so here is exactly what runs, and what it covers. The commands are stable; the numbers behind them are not quoted, because a quoted number is a number that drifts.

| Check | Command | What it covers |
| --- | --- | --- |
| Static analysis, whole workspace | `dart analyze` | Every package, the generator, the examples and the site tooling. |
| Generator unit tests | `dart test generator/` | The loader, the parser, the resolver, the naming rules and the emitters. |
| Runtime helper tests | `cd packages/gir_ffi && dart test` | String marshalling and the `HeapAnchor` lifetime contract. |
| Composite-template tests | `dart test packages/gtk_templates packages/gtk_templates_builder` | The runtime helpers, the AST scanner, the codegen, and an analyzer-resolution check of the generated part file. |
| Whole workspace | `dart test` with every package directory named | All of the above, plus the per-package smoke tests. |
| Generated template code type-checks | `cd example/todo && dart run build_runner build && dart analyze` | A real consumer app against the generated output. |
| The site matches its sources | `dart run tool/build_site.dart --check` | The committed `site/` matches `site_src/`, and the facts match the repository. |
| GLib / GTK4 runtime tests | `cd packages/gtk4 && dart test` | **Not verified in CI** — they need a real native GTK 4 installation. |
| Continuous integration | `.github/workflows/ci.yml` | Analysis, the generator tests, the template tests and a build + analyze gate over `example/todo`, on Ubuntu. |

:::{note variant=warn}
**The GTK4/GLib runtime tests are the honest gap.** They need a real native GTK 4 / GLib installation. On a machine without one, `openLibrary()` falls back to the current process and fails with a bare *"None of the loaded modules contained the requested symbol"* instead of "libgtk-4 not found". CI currently lints and tests the generator but never exercises a native call, so runtime behaviour is reviewed and hand-tested rather than continuously verified. Fixing exactly that — a platform-aware loader with actionable diagnostics, plus a GTK4-enabled CI matrix — is the top item on the [roadmap](roadmap.html).
:::

## Try it

You need Dart 3.13+ and native GLib/GTK 4 development libraries on the host.

```text title=terminal
# Linux
sudo apt install libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev

# workspace root
dart pub get

# regenerate every package from local GIR files
dart run generator/bin/generate.dart --gir-dir /path/to/gir-1.0 \
  GLib-2.0 GObject-2.0 Gio-2.0 GdkPixbuf-2.0 cairo-1.0 Pango-1.0 \
  Gdk-4.0 Gtk-4.0 Graphene-1.0 Gsk-4.0 Adw-1 GtkSource-5

# lint, test, and run the example text editor
dart analyze
dart test generator/
cd example/gtk4_examples && dart run bin/editor.dart
```

The `example/notepad/` app is a real `AdwApplicationWindow` text editor — open and save through `GtkFileDialog`, a live cursor-position readout driven by a `notify::cursor-position` handler, and `AdwToast` feedback — not a hello-world. It exists because the generator's output is only trustworthy if a non-trivial consumer compiles and runs against it.

## Status and honesty

:::{cols}
### Pre-1.0, by design

The generated API surface changes when the generator improves, and packages are currently `publish_to: none` and pinned to the workspace version. Nothing here is on pub.dev yet. Expect breakage between iterations — the stability promise is aimed at 1.0, and the [roadmap](roadmap.html) says which parts land when.

### Built with AI assistance

This project was developed with AI coding agents as working collaborators, under human direction and review. The [AI development statement](about.html#ai-assisted-development) spells out exactly what that meant, which parts are machine-written, and what is verified by CI rather than asserted.
:::

- [Star / fork on GitHub](https://github.com/TenderOwl/dart-gir) →
- [About the author](about.html) →
