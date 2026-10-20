---
title: Where this goes
description: Where dart-gir is today and what comes next: array and collection types, real runtime verification in CI, cross-platform library loading, GObject subclassing, and pub.dev publication.
nav_order: 4
nav_label: Roadmap
section_label: Roadmap
---

Phases are ordered by what unblocks the most users, not by what is most fun. Every phase is tied to a measurable exit condition, and the "done" column below is a claim you can check against the repository — not a projection.

:::{note}
**No dates.** This is a one-person project, and putting calendar dates on phases that depend on generator rewrites would be fiction. Each phase instead states what must be true for it to be called finished.
:::

## At a glance

| Phase | Theme | Status | Exit condition |
| --- | --- | --- | --- |
| 0 | Generator foundation | done | Loader, parser, resolver, emitters, 13 packages, skip reports |
| 1 | Ergonomics layer | done | Typed props, typed signals, interface mirroring, async overloads |
| 2 | Prove it at runtime | in progress | CI that makes real native GTK calls; a loading failure says why |
| 3 | Arrays and collections | next | Array-typed parameters, properties and returns are emitted |
| 4 | Cross-platform | planned | Linux, macOS and Windows loaders; a macOS CI job |
| 5 | Subclassing & composite templates | half landed | Templates on `main`; subclassing documented, tested and covered by CI |
| 6 | Distribute | planned | Semver policy, pub.dev packages, documented stability level |
| 7 | More namespaces | exploratory | Only after phases 2–5; driven by real demand |

## Phase details

:::{phase status=done} Phase 0 — Generator foundation
The pipeline that makes every later phase possible.

- GIR XML loader with transitive `<include>` resolution
- Immutable data model for every GIR element kind
- Type resolver with a scalar table, a declared-type table and cross-namespace deduplication by `c:type`
- Emitters for classes, interfaces, records, unions, enums, bitfields, callbacks, functions, constants and signals
- Per-package `skip_report.txt` from day one — no silent omissions
- Twelve packages generated and compiling
:::

:::{phase status=done} Phase 1 — The ergonomics layer
Turning "technically bound" into "pleasant to use". This is what separates dart-gir from a raw FFI dump.

- PyGObject-style typed `.props` accessors, with correct inherited nullability
- Typed `onSignalName` handlers, bucketed by FFI shape and walked through the full parent chain
- Interface methods mirrored onto concrete classes, with rename-on-conflict
- Nullable callback parameters, unblocking the whole `g_*_add_full` family
- Lifetime-safe `*Callback` overloads for async methods
- Caller-allocated OUT parameters as typed return values, anchored by `HeapAnchor`
- One Dart class per file, named after the class
- A non-trivial consumer app in `example/` that compiles and runs against the output
:::

:::{phase status=wip} Phase 2 — Prove it at runtime
The most important phase remaining, because right now the project's central claim — that the generated bindings are correct — is verified by a linter and generator unit tests, not by running against GTK.

#### The concrete problem

Each package's generated loader lists only Linux shared-object names:

```dart title="adw/lib/src/lib.dart (generated)"
for (final name in const ['libadwaita-1.so.0']) { ... }
if (libs.isEmpty) libs.add(ffi.DynamicLibrary.process());
```

On any other platform every name fails to open, the loader silently falls back to the current process, and the first symbol lookup fails with *"None of the loaded modules contained the requested symbol"* — a message that points at the bindings when the real cause is a missing native library. It also means `HeapAnchor`'s finalizer path and the `g_free` binding have no working non-Linux behaviour to fall back on.

#### What "done" means

:::{checklist}
[ ] Platform-aware library name tables per namespace — `.dll`, `.dylib`, `.so.N` — emitted by the generator instead of hardcoded Linux sonames.
[ ] A dedicated, actionable exception when a native library is missing, naming the library, the package and the platform-specific install command.
[ ] A CI job that installs GTK 4 / libadwaita and actually runs `packages/gtk4/test` and `packages/glib/test` — currently CI never makes a native call.
[ ] Heap and lifetime tests run under CI, not only on a maintainer's desktop.
[ ] Every remaining `g_free` / `DynamicLibrary.process()` assumption reviewed for non-Linux correctness.
:::
:::

:::{phase status=next} Phase 3 — Arrays and collections
**{{facts.skips.array_types}} recorded skips** — a small fraction of the report's {{facts.total_skipped}} entries — carry an array-type reason. This was 946 skips before the `array-types` branch landed; what is left is the residue that branch did not cover. It is still the biggest remaining *functional* gap, even though the count is now a small fraction of what it was.

It spans four different positions in a signature, each with its own lifetime rules:

- **Array parameters** — typically accompanied by a length or `n_*` scalar, and sometimes an `inout` for element replacement.
- **Array properties** — including `GStrv`-style string lists, which have their own NULL-termination and ownership contract.
- **Array returns** — the hardest case, because the returned memory is often caller-owned and must be freed with `g_free` or an element-free function, and sometimes transferred in full.
- **Array parameters to a callback** — where the buffer's lifetime is bounded by the trampoline, which changes the allocation strategy entirely.

#### What "done" means

:::{checklist}
[ ] A `GList`/`GPtrArray`/`GStrv`/fixed-array mapping layer in the resolver, with ownership rules per case rather than one generic array type.
[ ] Caller-allocated buffers for OUT-style array parameters, anchored the same way OUT structs are today.
[ ] A documented, tested policy for freeing returned arrays.
[ ] Property and return paths covered, not just parameters.
[ ] The skip reports regenerate with the {{facts.skips.array_types}} entries gone or individually explained.
:::

:::{note}
**Why this phase is not already done:** it needs the ownership and lifetime model settled before the code is written, not after. The earlier `HeapAnchor` work established that a buffer's lifetime must be tied to the Dart wrapper that exposes it — and for arrays the question "who frees this, and when" has more wrong answers than the OUT-struct case did.
:::
:::

:::{phase status=future} Phase 4 — Cross-platform support
Linux is the only platform that has ever run this. macOS is the next target because a large share of GTK application development happens there, and the loader problem from phase 2 has to be solved first.

:::{checklist}
[ ] macOS library names and Homebrew paths; a macOS CI job with GTK from Homebrew
[ ] Windows: DLL names, and an honest decision about whether GTK 4 via MSYS2 is supported or explicitly out of scope — saying so is better than leaving it silently broken
[ ] Platform notes per namespace: how to install the native libraries on each OS
:::
:::

:::{phase status=wip} Phase 5 — Subclassing and composite templates
The capability that most clearly decides whether this project is a set of bindings or a toolkit for building real GTK applications. It splits in two, and the two halves are in different places.

**The composite-template half is on `main` now.** Two packages ship it: `packages/gtk_templates` (the annotations and runtime helpers) and `packages/gtk_templates_builder` (the AST scanner, the codegen, the `build_runner` builder and a standalone CLI). The builder writes one part file per source file beside the source, and the design is written down in `docs/templates.md`. A worked example lives in `example/todo/`, and CI builds it and analyzes the result on every push.

**The subclassing half turned out to be mostly already on `main`.** The generated classes are emitted as `class`, not `final class`, and the props companions are public and extendable — so a user-side subclass, a covariant return-type override and a subclassed props companion all compile. What was missing was the rest of the story: the contract was not pinned by a test, and the ownership and lifetime rules were nowhere written down. Both are now in place — the generator asserts the extendable contract, and `docs/subclassing.md` states what a Dart subclass is and is not.

The `composite-templates` branch itself is **not being merged**. It holds two commits, based on `ed5ce0f`, now behind `main`, and its design has diverged from what landed: it emits a `<class>.gtk_templates.dart` per class, uses program-lifetime `NativeCallable` trampolines, and carries Blueprint, GResource, Meson and gettext scaffolding. The landed design uses one `<source>.g.dart` part file per source file and per-instance closures. Merging the branch would mean merging both designs at once; re-implementing the one genuinely new capability on top of the landed half is less work and produces a smaller diff.

- **Dart-level subclassing of generated wrappers.** Generated classes are emitted as `class` rather than `final class` and props classes as public extendable companions, precisely so that a Dart subclass can override a method for a covariant return type across a package boundary. *Already on `main` — the contract is now pinned by a generator test and documented in `docs/subclassing.md`.*
- **The composite-template stack** — `@GtkTemplate`, `@GtkTemplateChild` and `@GtkTemplateCallback` annotations, a scanner, a codegen, a `build_runner` builder, a standalone CLI, and the runtime helpers they need. *Landed on `main`.*
- **Signal trampolines.** The landed design connects each `<signal>` to the user's instance method with a per-instance closure that lives as long as the widget. The branch instead used program-lifetime `NativeCallable`s. The per-instance closure is the smaller surface and the one that is documented.
- **A real consumer app**: `example/todo/`, a libadwaita counter built on a `@GtkTemplate` host class with an inline XML template. The branch's version was larger — Blueprint (`.blp`) and XML (`.ui`) templates, a `GResource` bundle, Meson integration, gettext catalogues and an icon — but none of that packaging is in scope for a binding generator.

#### What "done" means

:::{checklist}
[ ] Dart-level subclassing lands on `main` as a re-implementation, with `dart analyze` clean and the regenerated packages included in the same change.
[ ] The regenerated packages are covered by CI, not just by a maintainer's machine.
[ ] Subclass registration is documented as supported, with its own lifetime rules written down, rather than left as a pattern the reader has to infer from an example.
[ ] The `composite-templates` branch is retired once its one remaining capability is on `main`.
:::

:::{note}
**Sequencing note:** this is listed after the runtime phase on purpose. Phase 2's GTK-enabled CI job remains the precondition: shipping generated output that no CI job has ever executed would trade a visible gap for an invisible one. The template half does not wait for it — it is pure Dart, so CI can build and analyze it today. The subclassing half changes the generated packages, so it should not land until CI can make real native GTK calls.
:::
:::

:::{phase status=future} Phase 6 — Distributing the packages
Everything is currently `publish_to: none` and pinned to the workspace version, which means nobody can depend on it. Publication is what turns this from a repository into a usable dependency.

:::{checklist}
[ ] A versioning policy: which packages move together, and what constitutes a breaking change for each
[ ] Per-package versions that follow semver, replacing the workspace pin
[ ] Publication to pub.dev, once phases 2–5 have stopped moving the API
[ ] A stated stability level per package — "generated, not hand-curated" is a real and acceptable answer, as long as it is written down
[ ] Migration notes for the generated API when an emitter changes
:::
:::

:::{phase status=future} Phase 7 — More namespaces
The generator is namespace-agnostic, so adding a library is mostly a matter of pointing it at another `.gir` file. That makes this phase cheap per library and therefore driven by demand rather than ambition.

Candidates that fit the existing dependency graph cleanly:

| Candidate | Why it fits |
| --- | --- |
| `libsoup-3` | HTTP client for Gio's network stack; same era, same introspection format. |
| `Poppler` | PDF rendering; commonly needed next to GDK in real apps. |
| `GdkPixbuf` loaders, `Pango` extras | Small additions to namespaces already present. |
| `Gst` (GStreamer) | Large and valuable for media apps, but a much bigger surface than the current packages. |
| `JavaScriptCore` bindings | Would let GTK apps embed script engines without a second binding layer. |

Deliberately absent: Gtk 3. It is a large, widely deployed surface, but supporting two major versions of the same toolkit from one generator is a project in itself and would delay the phases that matter more.
:::

## Constraints the roadmap is built around

:::{cols}
### The generator is the product

{{facts.generated_lines}} lines of generated code are disposable output. A change that requires hand-editing a package is a change to the generator, and any pull request that edits `packages/*/lib/` by hand is by definition wrong. This is also why the generated output is committed: reviewers need to see the effect of a generator change, and CI lints the code that users will actually consume.

### Skip a symbol loudly, never silently

Every unemitted symbol gets a line in `skip_report.txt` with a reason that names the alternative when one exists. A binding generator that quietly omits a method is worse than one that fails, because the omission surfaces as a mystery at the call site. This is why the report is treated as a deliverable rather than a debug artifact.

### Correctness over coverage

A use-after-free in an OUT-parameter buffer is a bug, not a missing feature. The project has shipped at least two such defects — an undersized malloc and a premature free — and both were fixed with end-to-end tests rather than patched. Where the safe design is not yet known, the symbol stays in the skip report.

### Runtime before polish

Static analysis is necessary and not sufficient. The current gap — that no continuously-running test makes a native GTK call — is the single thing standing between this project and a credible stability claim, which is why it is phase 2 and not phase 6.
:::

## Contributing

The most useful contribution is not "add a binding" — the generator makes that mechanical. It is **taking a skip entry and making it emitable**, ideally with a test. Start with the `skip_report.txt` of whichever package you care about; the reasons are alphabetised and documented in `docs/skip-categories.md`.

Two things make a change easy to accept: a change to the generator *and* the regenerated packages in the same pull request, and a test that fails before the fix.

- [Open an issue](https://github.com/TenderOwl/dart-gir) →
- [See what's already built](features.html) →
- [Understand the design first](design.html) →
