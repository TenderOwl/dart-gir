# Architecture

The workspace is a single Dart monorepo organised around one generator and
eleven consumer packages. The generator ingests GObject-Introspection (GIR)
XML and emits per-package Dart FFI bindings; the per-package source lives
under `packages/<lib>/lib/src/` and is regenerated from scratch on every
build.

## Top-level layout

```
.
├── AGENTS.md              Agent-facing workflow + conventions
├── CHANGELOG.md           Reverse-chronological release notes
├── README.md              Public landing page (TODO)
├── docs/                  Design documents (this directory)
│
├── generator/             gir_generator package
│   ├── bin/generate.dart  CLI: regenerates one or more target GIRs
│   ├── lib/src/
│   │   ├── gir/           XML loading + immutable data model
│   │   ├── resolve/       Type/name resolution
│   │   └── emit/          Dart code emitters
│   └── test/              Generator unit tests
│
├── packages/              Generated packages (one per GIR namespace)
│   ├── gir_ffi/           Hand-written runtime helpers shared by every package
│   ├── glib/              GLib
│   ├── gobject/           GObject
│   ├── gio/               GIO
│   ├── gdk_pixbuf/        GdkPixbuf
│   ├── cairo/             cairo
│   ├── pango/             Pango
│   ├── gdk4/              GDK 4
│   ├── gtk4/              GTK 4
│   ├── graphene/           Graphene
│   ├── gsk4/              GSK 4
│   └── adw/               Libadwaita
│
└── example/               Consumer example (uses generated packages end-to-end)
```

`packages/gir_ffi/` is the only hand-written consumer package. It holds
runtime helpers used by every generated package (`stringFromNative`,
`withNativeString`, `withNativeStringList`, `gFree`, the cross-package
native-library opener, `GlibException` factory).

## Generation pipeline

```
┌──────────────────────────────────────────────────────────────────────┐
│  CLI (generator/bin/generate.dart)                                  │
│  target = [GLib-2.0, GObject-2.0, Gio-2.0, ..., Adw-1]              │
└──────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│  GirLoader                                                          │
│  - For each target: GirLoader.loadAllWithDependencies(nameVersion)  │
│    resolves the transitive <include> closure (deps load first)     │
│  - Returns List<GirRepository> in dependency order                  │
└──────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Per-target PackageEmitter                                          │
│  - Builds EmitContext (TypeResolver + GenerationReport)             │
│  - Runs each emitter:                                               │
│      enums + bitfields → EnumEmitter                                 │
│      constants + functions     → FunctionEmitter                    │
│      records + unions    → RecordEmitter                            │
│      interfaces          → RecordEmitter (opaque handle, non-final)│
│      classes             → ClassEmitter                             │
│      callbacks           → CallbackEmitter                          │
│      signals             → SignalBucket → signals.dart helper      │
│  - Chunks the declarations at ~400 lines per part file              │
│  - Writes pubspec.yaml, lib/<pkg>.dart (barrel), analysis_options,   │
│    and skip_report.txt                                              │
│  - Runs `dart format` over the package                              │
└──────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                  packages/<lib>/lib/<pkg>.dart + lib/src/*.dart
```

Each `PackageEmitter` runs once per target namespace. The set of target
namespaces determines which packages end up in `packages/`. Calling the
generator with `GLib-2.0 GObject-2.0 Gio-2.0 ...` emits all 11. Calling
it with just `GtkSource-5` emits only `packages/gtk_source5/`; the
generator will reuse any pre-existing packages on disk so cross-package
type lookups (`GObject.Type` referenced from Gtk) keep working.

## EmitContext

`EmitContext` is the per-package mutable state shared by every emitter:

| Field | Purpose |
|---|---|
| `namespace` | The GIR namespace currently being emitted |
| `allNamespaces` | Every namespace loaded this run (used for cross-namespace type lookup) |
| `report` | `GenerationReport` — collects skip entries with category + reason |
| `emittedPackages` | Set of package names that exist on disk or are being generated |
| `resolver` | `TypeResolver` (immutable) — turns `GirTypeRef` into a `TypeMapping` |
| `imports` | Set of cross-package names that the barrel must `import` |
| `topLevelNames` | Names already claimed at the top level of the package |
| `usesFfiString` | Whether `package:ffi/ffi.dart` is needed (any `Utf8` usage) |
| `usesMalloc` | Whether `package:ffi`'s `calloc`/`malloc` is needed |
| `usesGirFfi` | Whether `package:gir_ffi/gir_ffi.dart` is needed |
| `usesGlibException` | Whether `package:glib/glib.dart` is needed (for `GlibException`) |

`bridgeFor(GirTypeRef?)` is the workhorse: returns a `TypeBridge` whose
`toNative` / `fromNative` strings drive emission, or `null` plus a reason
when the type cannot be mapped (recorded in the skip report).

## What each emitter produces

| Emitter | Output |
|---|---|
| `EnumEmitter` | One Dart `enum` per GIR `<enumeration>`, plus a wrapper class with constants and `fromValue` for bitfields |
| `FunctionEmitter` | Top-level Dart functions + `const` declarations for `<function>` and `<constant>`. Skips functions whose `c:identifier` is in the `staticClassFunctions` map — the class emitter re-emits them as `static` methods. |
| `RecordEmitter` | Opaque pointer wrapper classes for `<record>` and `<union>` plus `<interface>` (non-`final`, so other classes can `implements` them). Picks up static-method promotions from `staticClassFunctions`. |
| `ClassEmitter` | Pointer-wrapper classes with constructors, instance methods, static functions, the `implements` clause on every GIR `<implements>` target, mirrored interface methods, **and** inherited typed `onSignalName` helpers. Picks up static-method promotions from `staticClassFunctions`. |
| `CallbackEmitter` | Dart `typedef` aliases for `<callback>` declarations |
| `SignalEmitter` (in `signals_emitter.dart`) | `onSignalName` method bodies emitted per class via `emitSignalConnectors` |
| `SignalHelper` (in `signals_helper.dart`) | The per-package `lib/src/signals.dart` file: per-bucket trampolines + registries + `connectSignal` escape hatch |

`signals.dart` is emitted once per package and is the only part-file whose
contents are not class/interface records. Everything else is
classifications of declarations from the GIR.

## Package layout in `packages/<lib>/`

```
packages/gtk4/
├── pubspec.yaml              path-deps on gdk4, pango, glib, gobject, gir_ffi
├── analysis_options.yaml     core.yaml + per-package FFI lint suppressions
├── lib/
│   ├── gtk4.dart             barrel: imports + `part` directives
│   └── src/
│       ├── lib.dart          native library loader + lookup helpers
│       ├── object_support.dart  (only if pkg == gobject)
│       ├── exception.dart    (only if pkg == glib)
│       ├── signals.dart      (only if any kept signal exists)
│       ├── enums*.dart        chunked enum/bitfield declarations
│       ├── constants.dart    const declarations
│       ├── callbacks.dart    callback typedefs
│       ├── functions.dart    top-level function wrappers
│       ├── records*.dart     chunked record/union/interface declarations
│       └── classes*.dart     chunked class declarations
└── skip_report.txt           human-readable list of everything the generator could not emit
```

`dart format` runs on every regeneration, so chunk boundaries are an
output detail rather than a hand-tuned artefact.

## Skip report

Whenever an emitter decides it cannot produce code for a symbol, it
records the decision in `GenerationReport` with a `(category, name,
reason)` triple. `emitter.dart` flushes the report to
`packages/<lib>/skip_report.txt` after each package. Categories are
emitter-specific — see [skip-categories.md](./skip-categories.md).

## Adding a new binding package

1. Verify the `.gir` file ships with your distro (default location
   `/usr/share/gir-1.0/<Name>-<Version>.gir`).
2. If the namespace isn't in the core map (`TypeResolver.packageNameFor`),
   add it.
3. Pass the new `<Name>-<Version>` as an extra target to
   `dart run generator/bin/generate.dart`.
4. Inspect `packages/<lib>/skip_report.txt` to triage what didn't make it
   on the first run.
5. Add a smoke test under `packages/<lib>/test/`.
6. Update `example/bin/example.dart` to demonstrate the new bindings.
