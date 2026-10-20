---
title: How it actually works
description: How dart-gir works: the GIR to Dart pipeline, the type system and transfer ownership, the typed signal trampoline design, emitter rules, and the skip report contract.
nav_order: 3
nav_label: Design
section_label: Design reference
---

The full design documents live in the repository under `docs/` — architecture, emission, type system, signals, async and skip categories. This page is the summary; the documents are the specification.

:::{meta}
[Read docs/ on GitHub →](https://github.com/TenderOwl/dart-gir/tree/main/docs)
:::

## The pipeline

One command reads GIR files and writes one package per namespace. Nothing in between is hand-maintained, nothing in the output is meant to be edited, and no stage knows what library it is processing.

:::{figure} Every stage is library-agnostic. Adding a namespace is a new argument to the CLI, not a new code path.
<svg viewBox="0 0 1000 300" role="img" aria-label="Generation pipeline: CLI targets are loaded by GirLoader, parsed into an immutable data model, resolved by the TypeResolver, passed to per-kind emitters, and written out as a package plus a skip report.">
  <defs>
    <marker id="ah" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">
      <path d="M0 0 L8 4 L0 8 z" fill="currentColor"/>
    </marker>
  </defs>

  <!-- stage 1: CLI -->
  <text class="d-sub" x="8" y="18">1 · CLI</text>
  <rect class="d-node" x="8" y="28" width="200" height="64" rx="2"/>
  <text class="d-label" x="24" y="52">generate.dart</text>
  <text class="d-sub" x="24" y="70">--gir-dir + target list</text>
  <text class="d-sub" x="24" y="84">Gtk-4.0 Adw-1 …</text>

  <!-- stage 2: loader -->
  <text class="d-sub" x="256" y="18">2 · GirLoader</text>
  <rect class="d-node" x="256" y="28" width="200" height="64" rx="2"/>
  <text class="d-label" x="272" y="52">include closure</text>
  <text class="d-sub" x="272" y="70">deps first, in order</text>
  <text class="d-sub" x="272" y="84">so Gtk sees GObject</text>

  <!-- stage 3: model -->
  <text class="d-sub" x="504" y="18">3 · Data model</text>
  <rect class="d-node" x="504" y="28" width="200" height="64" rx="2"/>
  <text class="d-label" x="520" y="52">immutable elements</text>
  <text class="d-sub" x="520" y="70">class · record · union</text>
  <text class="d-sub" x="520" y="84">enum · signal · property…</text>

  <!-- stage 4: resolver -->
  <text class="d-sub" x="752" y="18">4 · Resolve</text>
  <rect class="d-node" x="752" y="28" width="216" height="64" rx="2"/>
  <text class="d-label" x="768" y="52">TypeResolver</text>
  <text class="d-sub" x="768" y="70">scalar + declared tables</text>
  <text class="d-sub" x="768" y="84">dedup by c:type</text>

  <!-- row 2: emitters -->
  <text class="d-sub" x="8" y="146">5 · Emitters</text>
  <rect class="d-node" x="8" y="156" width="200" height="60" rx="2"/>
  <text class="d-label" x="24" y="180">ClassEmitter</text>
  <text class="d-sub" x="24" y="198">methods, props, signals</text>

  <rect class="d-node" x="256" y="156" width="200" height="60" rx="2"/>
  <text class="d-label" x="272" y="180">RecordEmitter</text>
  <text class="d-sub" x="272" y="198">records, unions, ifaces</text>

  <rect class="d-node" x="504" y="156" width="200" height="60" rx="2"/>
  <text class="d-label" x="520" y="180">EnumEmitter</text>
  <text class="d-sub" x="520" y="198">enums, bitfields</text>

  <rect class="d-node" x="752" y="156" width="216" height="60" rx="2"/>
  <text class="d-label" x="768" y="180">Function · Callback</text>
  <text class="d-sub" x="768" y="198">namespaces, typedefs</text>

  <!-- row 3: outputs -->
  <text class="d-sub" x="8" y="258">6 · Write</text>
  <rect class="d-node-accent" x="8" y="268" width="440" height="26" rx="2"/>
  <text class="d-label" x="24" y="285">packages/&lt;lib&gt;/ + barrel + lib.dart + pubspec</text>

  <rect class="d-node-accent" x="464" y="268" width="504" height="26" rx="2"/>
  <text class="d-label" x="480" y="285">skip_report.txt — every unemitted symbol, with its reason</text>

  <!-- connectors row 1 -->
  <g color="var(--text-3)">
    <path class="d-arrow" d="M214 60 H250" marker-end="url(#ah)"/>
    <path class="d-arrow" d="M462 60 H498" marker-end="url(#ah)"/>
    <path class="d-arrow" d="M710 60 H746" marker-end="url(#ah)"/>
  </g>

  <!-- resolver down to emitter row, then fan to outputs -->
  <g color="var(--text-3)">
    <path class="d-dash" d="M860 98 V128 H108 V150" marker-end="url(#ah)"/>
    <path class="d-dash" d="M860 98 V128 H356 V150" marker-end="url(#ah)"/>
    <path class="d-dash" d="M860 98 V128 H604 V150" marker-end="url(#ah)"/>
    <path class="d-arrow" d="M108 222 V262" marker-end="url(#ah)"/>
    <path class="d-arrow" d="M356 222 V262" marker-end="url(#ah)"/>
    <path class="d-arrow" d="M604 222 V262" marker-end="url(#ah)"/>
    <path class="d-arrow" d="M860 222 V262" marker-end="url(#ah)"/>
  </g>
</svg>
:::

The six stages in prose, if you prefer text to geometry:

- **CLI** — `generator/bin/generate.dart` takes a `--gir-dir` and a list of namespace-version pairs.
- **GirLoader** — resolves the transitive `<include>` closure and returns repositories in dependency order.
- **Immutable data model** — one value type per GIR element kind.
- **TypeResolver + EmitContext** — scalar table, declared-type table, cross-namespace dedup by canonical `c:type`.
- **Emitters** — one per symbol kind, all sharing the same context and report.
- **Package writer** — one file per class, `~400`-line chunks for the rest, then `dart format`.

:::{note}
**{{facts.generator_lines}} lines** of generator code across {{facts.generator_files}} files produce **{{facts.generated_lines}} lines** across {{facts.generated_files}} Dart files. That ratio is not a brag about volume — it is the reason the project is maintainable. The only part anyone reasons about is the {{facts.generator_lines}}.
:::

## The type system and ownership

GIR is a C API description, and most of the difficulty in generating a good Dart API is that `transfer-ownership` and nullability are not decoration — they define who frees what, and getting them wrong is a memory bug. Three rules do most of the work.

:::{cols}
### transfer-none ⇒ nullable

A `gchar*` with `transfer-ownership="none"` is returned as `String?`, because the native getter genuinely can return NULL. The generator does not tighten this to make the API look nicer — a non-nullable annotation over a NULL-returning C function is a runtime crash, not a convenience.

### transfer-full ⇒ copy and free

Ownership transfers to the caller, so the string is copied into Dart memory and the native allocation released. Getting this backwards leaks on every call.

### Props types come from methods

A property accessor takes its Dart type from the typed `get<Name>` / `set<Name>` method's resolved bridge, not from the property's raw `<type>` element. The property element and the method bridge can disagree — and when they do, the method is what the user will actually execute.
:::

### Namespace resolution needs an explicit anchor

The subtlest bug class in this project is unqualified type names resolving against the wrong namespace. Emitting `Adw` that inherits from `Gtk` means `<type name="Application"/>` has two plausible answers. The resolver therefore takes a `relativeTo` parameter, and inherited properties, inherited signals and interface mirrors all pass the namespace that actually declared the symbol.

```dart title="the bug this prevents"
// AdwMessageDialogProps.application, emitted while the namespace is Adw.
// Unqualified "Application" resolved to Adw.Application …
set application(AdwApplication? value)   // AdwApplication

// … overriding GtkWindowProps.application(GtkApplication?) with a
// NARROWER type. AdwApplication extends GtkApplication, so this
// is an invalid override: invalid_override, hundreds of times.

// Fix: resolve against the OWNER's namespace, not the emission namespace.
set application(GtkApplication? value)  // correct
```

The same fix applies to inherited signal arguments: `Gtk.Application::window-added` must resolve its `Window` argument to `GtkWindow` even when emitted into `Adw`.

## The typed signal design

Thousands of typed helpers would be unmaintainable as one class each. Instead, signals are partitioned into buckets by **FFI shape × Dart signature**, and each bucket gets one trampoline, one typed registry and one connect helper.

```dart title="signals.dart — bucket naming"
// The bucket id encodes the native shape, so one trampoline can
// serve every signal that shares it.
_connectSignal_v_1_i_gtktextdirection      // void (*)(gint)
_connectSignal_b_4_i_i_b_o_int_int_bool_gtktooltip
_connectSignal_b_1_s_string                 // gboolean (*)(gchar*)
_connectSignal_v_0                          // void (*)(void)
```

- **Dedup is by `GirSignal` instance identity, not by name.** Two signals called `interface-added` with different arities are different signals; deduplicating by name silently dropped one of them.
- **The inheritance walk is keyed by qualified class name.** Walking by local name stops at `Adw.Application`, because `Gio.Application` has the same local name.
- **Every unsupported signal gets a precise reason** — weak-ref, detailed name (`notify::x`), arity above 5, untypable argument, untypable return, name collision. Not "signal skipped".
- **`connectSignal`** is public in every package for anything the generator will not type, and uses the same trampoline path.

## Callback lifetimes — the central invariant

Almost every memory bug in a hand-written FFI binding comes from one question: how long does the native side hold this callback? The generator has exactly two strategies and picks between them by whether the callee can retain the pointer.

:::{figure} The `*Callback` suffix on the async methods exists to make this choice visible at the call site.
<svg viewBox="0 0 1000 250" role="img" aria-label="Decision: can the callee invoke the callback after the native call returns? If no, allocate a NativeCallable and close it in a finally block. If yes, use a permanent trampoline and registry and never close anything.">
  <defs>
    <marker id="ah2" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">
      <path d="M0 0 L8 4 L0 8 z" fill="currentColor"/>
    </marker>
  </defs>

  <!-- question -->
  <text class="d-sub" x="8" y="16">the only question that matters</text>
  <rect class="d-node" x="8" y="26" width="300" height="62" rx="2"/>
  <text class="d-label" x="24" y="50">Can the callee invoke it</text>
  <text class="d-label" x="24" y="68">after the call returns?</text>

  <!-- branch labels -->
  <path class="d-arrow" d="M158 88 V120" marker-end="url(#ah2)"/>
  <text class="d-sub" x="168" y="110">no</text>
  <path class="d-arrow" d="M310 57 H392"/>
  <path class="d-arrow" d="M386 52 L392 57 L386 62" marker-end="url(#ah2)"/>
  <text class="d-sub" x="326" y="48">yes</text>

  <!-- left: sync -->
  <text class="d-sub" x="90" y="160">synchronous</text>
  <rect class="d-node" x="8" y="170" width="300" height="66" rx="2"/>
  <text class="d-label" x="24" y="194">NativeCallable.isolateLocal</text>
  <text class="d-sub" x="24" y="212">allocated at the call site,</text>
  <text class="d-sub" x="24" y="228">closed in a finally block</text>

  <!-- right: async -->
  <text class="d-sub" x="400" y="160">asynchronous · also sources,</text>
  <text class="d-sub" x="400" y="176">signals, template callbacks</text>
  <rect class="d-node-accent" x="392" y="186" width="576" height="50" rx="2"/>
  <text class="d-label" x="408" y="208">Pointer.fromFunction → static trampoline → per-call registry</text>
  <text class="d-sub" x="408" y="226">nothing is ever closed, and user_data stays internal</text>
</svg>
:::

| Situation | Strategy | Why |
| --- | --- | --- |
| Callback invoked synchronously, before the native call returns | Allocate a `NativeCallable.isolateLocal` at the call site, `.close()` it in `finally` | The callee provably cannot call it later, so releasing it immediately is both safe and leak-free. |
| Async method finishing callback | Permanent `Pointer.fromFunction` over a static trampoline plus a per-call registry; nothing is ever closed | GLib holds the pointer past the return. Closing it would be a use-after-free; leaking a `NativeCallable` would not be, but the registry is bounded and keyed per call instead. |
| Template callback, signal handler, idle / timeout source | Top-level or static Dart function; keep it alive for the object's lifetime | These are long-lived by design. A closure created inside a wrapper call cannot outlive that call safely. |

:::{note variant=warn}
The second row is why the `*Callback` suffix exists on the async methods. A single naming convention makes the lifetime difference visible at the call site, which is the only place a reader can actually act on it.
:::

## The skip report contract

Every symbol the generator declines to emit produces a line in `packages/<lib>/skip_report.txt`, grouped by category and by reason. This is a designed interface, not a log file — the reason string is written to be actionable.

```text title=skip_report.txt
{{facts.skip_report_example}}
```

Note the last entry. A C macro has no symbol to bind, so the reason does not just say "introspectable" — it names the `_full` wrapper to call instead. A skip entry that tells the user what to do instead is worth ten that just say no. The same applies to the override-incompatible reasons elsewhere in the reports, which name the method that *was* emitted under a new name.

The excerpt above is generated from `packages/glib/skip_report.txt` at build time, so it can never quote a number the repository does not hold.

All categories and reasons are documented alphabetically in `docs/skip-categories.md`.

## Generated file layout

One class per file, named after the class, with its props companion alongside:

```text title="packages/gtk4/lib/"
gtk4.dart                     // barrel: exports every part file in declaration order
src/
  lib.dart                    // library list + gtlLookup()
  signals.dart                // trampolines, registries, connectSignal
  gtkbutton.dart              // class GtkButton
  gtkbutton_props.dart        // class GtkButtonProps extends GtkWidgetProps
  gtkwindow.dart              // class GtkWindow
  gtkwindow_props.dart
  records_0.dart …            // records, unions, ~400-line chunks
  enums_0.dart …              // enumerations, bitfields
  functions_0.dart …          // namespace functions, constants
  callbacks_0.dart …          // callback typedefs
skip_report.txt
```

All per-class files are `part of` the same library, so forward references resolve naturally and the public surface is unchanged — `import 'package:gtk4/gtk4.dart'` exposes the same names as before. The practical benefit is navigational: `Ctrl+Click` on `GtkButton` lands in `gtkbutton.dart` instead of `classes_27.dart`.

## Contributing conventions

The repository carries an `AGENTS.md` that defines the workflow and conventions for both humans and AI agents, including a rule that matters more than the rest:

:::{note}
**Never hand-edit generated code.** Changes belong in the generator, and a pull request that modifies `packages/<lib>/lib/` by hand is wrong by definition — because the next regeneration will silently revert it. A generator change must land together with its regenerated output, so reviewers can see the actual effect.
:::

Other conventions worth knowing before opening a pull request:

- Commit prefixes: `feat(generator):` / `fix(generator):` for generator work, `chore(gen):` or `feat(gen <lib>):` for regenerated output.
- One pull request per logical change, including the regenerated packages and updated `skip_report.txt` files.
- `dart analyze` clean and all tests passing across the workspace before merge.
- CI deliberately does *not* re-run the generator, so a committed package that no longer matches the generator cannot merge silently.
- Pointer lifetimes and `transfer-full` vs `transfer-none` are treated as correctness concerns. Leaks and use-after-free are bugs, not style issues.

## The documents

| Document | Covers |
| --- | --- |
| [architecture.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/architecture.md) | The pipeline end to end, top-level layout, and how to add a new binding package |
| [emission.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/emission.md) | What each emitter produces and how — the props accessor rules, interface mirroring, callback parameters |
| [type-system.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/type-system.md) | GIR-to-Dart type mapping, transfer ownership, nullability, cross-namespace resolution |
| [signals.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/signals.md) | Bucket partitioning, the inheritance walk, destroy-notify, the `connectSignal` escape hatch |
| [async.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/async.md) | The `*Callback` overloads and when the temporary-trampoline model is unsafe |
| [templates.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/templates.md) | The composite-template stack: the annotation surface, the codegen contract and the runtime init order |
| [subclassing.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/subclassing.md) | What a Dart-level subclass of a generated wrapper is, and what it is not |
| [skip-categories.md](https://github.com/TenderOwl/dart-gir/blob/main/docs/skip-categories.md) | Every category and reason that appears in a skip report, alphabetised |

- [See what the design still needs](roadmap.html) →
