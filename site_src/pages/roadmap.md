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
| 2 | Prove it at runtime | done | CI that makes real native GTK calls; a loading failure says why |
| 3 | Arrays and collections | next | Array-typed parameters, properties and returns are emitted |
| 4 | Cross-platform | planned | Linux, macOS and Windows loaders; a macOS CI job |
| 5 | Subclassing & composite templates | done | Both halves on `main`; the prototype branch is retired |
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

:::{phase status=done} Phase 2 — Prove it at runtime
The phase that turned the project's central claim — that the generated bindings are correct — from something a linter and generator unit tests checked into something CI proves by running against GTK.

#### The problem it solved

Each package's generated loader listed only Linux shared-object names:

```dart title="adw/lib/src/lib.dart (before)"
for (final name in const ['libadwaita-1.so.0']) { ... }
if (libs.isEmpty) libs.add(ffi.DynamicLibrary.process());
```

On any other platform every name failed to open, the loader silently fell back to the current process, and the first symbol lookup failed with *"None of the loaded modules contained the requested symbol"* — a message that points at the bindings when the real cause is a missing native library.

#### What it looks like now

The names are **tabulated** in the generator, one row per native library, and emitted per package. They cannot be derived from the Linux soname: GTK 4 on Windows is `libgtk-4.dll`, with no version suffix at all.

```dart title="adw/lib/src/lib.dart (generated)"
final adwLibs = openLibrary(
  package: 'adw',
  library: 'Adw 1',
  linux: const ['libadwaita-1.so.0'],
  windows: const ['libadwaita-1-0.dll'],
  macos: const ['libadwaita-1.0.dylib'],
  install: const InstallPackages(
    debian: 'libadwaita-1-dev',
    fedora: 'libadwaita-devel',
    homebrew: 'libadwaita',
    arch: 'libadwaita',
  ),
);
```

When none of the names opens, the loader throws instead of falling back — and the error says what to do:

```
Could not load libgtk-4.so.1 (Gtk 4.0), needed by package gtk4.
Install it with:
  sudo apt install libgtk-4-dev
  sudo dnf install gtk4-devel
  sudo pacman -S gtk4
```

CI now makes real native calls too: a second job installs GTK 4, libadwaita and GtkSourceView and runs the native suites — the ownership rules, the byte-array rules and the template stack — against the real libraries, under a virtual display.

#### What "done" means

:::{checklist}
[x] Platform-aware library name tables per namespace — `.dll`, `.dylib`, `.so.N` — emitted by the generator instead of hardcoded Linux sonames. *`generator/lib/src/resolve/platform_libraries.dart` holds the table; a library that is not in it degrades to a derived name plus a `platform-library` line in the skip report, so a new namespace warns instead of breaking.*
[x] A dedicated, actionable exception when a native library is missing, naming the library, the package and the platform-specific install command. *`NativeLibraryNotFound` in `package:gir_ffi`, pinned by `packages/gir_ffi/test/loader_test.dart`.*
[x] A CI job that installs GTK 4 / libadwaita and actually runs the native suites — `packages/gir_gtk4/test`, `packages/gir_glib/test` and the rest. *The `native` job in `.github/workflows/ci.yml`.*
[x] Heap and lifetime tests run under CI, not only on a maintainer's desktop. *The same job: the ownership and byte-array suites are part of it.*
[x] Every remaining `g_free` / `DynamicLibrary.process()` assumption reviewed for non-Linux correctness. *The allocator's own lookup used `DynamicLibrary.executable()`, which throws `UnsupportedError` on Windows; it reads the process's global symbol namespace now.*
:::
:::

:::{phase status=next} Phase 3 — Arrays and collections
**{{facts.skips.array_types}} recorded skips** — a small fraction of the report's {{facts.total_skipped}} entries — carry an array-type reason. This was 946 skips before the `array-types` branch landed; what is left is the residue that branch did not cover. It is still the biggest remaining *functional* gap, even though the count is now a small fraction of what it was.

**The bounded part of this phase landed with 1.0.** A `char **` return — GLib's `GStrv` — is now a `List<String>`, released with `g_strfreev` when the GIR says the caller owns it; and a nullable scalar parameter is passed through a one-slot buffer, so the C function's NULL is representable. What is left is the residue: the counted string arrays (a bound-length array is not a NULL-terminated list), the arrays of records and interfaces, and the arrays that arrive through a callback.

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
**Why this phase is not already done:** it needed the ownership and lifetime model settled before the code was written, not after. That model is on `main` now, and phase 2's CI job is the harness an array's lifetime can be tested in — an array is the first binding shape whose *correctness* cannot be shown by a type signature alone. What is left is the mapping layer itself, which is still the biggest remaining functional gap.
:::
:::

:::{phase status=future} Phase 4 — Cross-platform support
Linux is the only platform that has ever run this, and **1.0 says so**: the loader knows the Windows and macOS file names of every native library, but only Linux is executed and tested, and on macOS the library directory also has to be on the loader path. macOS is the next target because a large share of GTK application development happens there, and the loader problem from phase 2 has to be solved first.

:::{checklist}
[ ] macOS library names and Homebrew paths; a macOS CI job with GTK from Homebrew
[ ] Windows: DLL names, and an honest decision about whether GTK 4 via MSYS2 is supported or explicitly out of scope — saying so is better than leaving it silently broken
[ ] Platform notes per namespace: how to install the native libraries on each OS
:::
:::

:::{phase status=done} Phase 5 — Subclassing and composite templates
The capability that most clearly decides whether this project is a set of bindings or a toolkit for building real GTK applications. It splits in two — and both halves have now been checked against the committed trees, not against a working copy.

**The composite-template half is on `main`.** Two packages ship it: `packages/gir_gtk_templates` (the annotations and runtime helpers) and `packages/gir_gtk_templates_builder` (the AST scanner, the codegen, the `build_runner` builder and a standalone CLI). The builder writes one part file per source file beside the source, and the design is written down in `docs/templates.md`. A worked example lives in `example/todo/`, and CI builds it and analyzes the result on every push.

**The subclassing half is on `main` too.** The generated classes are emitted as `class`, not `final class`, and the props companions are public and extendable — so a user-side subclass, a covariant return-type override and a subclassed props companion all compile. The contract is pinned by the *Dart-level subclassing contract* group in the generator's tests, exercised against real GTK types in `packages/gir_gtk4/test/gtk4_subclass_test.dart`, and its ownership and lifetime rules are written down in `docs/subclassing.md`.

**The `composite-templates` branch has nothing left to merge.** Its merge-base with `main` is `ed5ce0f7` — *"feat: add subclasssing"* — which is the subclassing commit itself, so that capability was already on `main` before the branch started and was never the branch's to deliver. The branch adds two commits on top of that point, and everything they contain is packaging or an older internal layout: Blueprint and GResource templates, Meson and gettext scaffolding, one part file per class instead of one per source file, program-lifetime `NativeCallable` trampolines. The landed design uses one `<source>.g.dart` part file per source file and per-instance closures. `docs/branch-state.md` has the item-by-item comparison and the four commands that reproduce it.

- **Dart-level subclassing of generated wrappers.** Generated classes are emitted as `class` rather than `final class` and props classes as public extendable companions, precisely so that a Dart subclass can override a method for a covariant return type across a package boundary. *On `main` — the contract is pinned by a generator test and documented in `docs/subclassing.md`.*
- **The composite-template stack** — `@GtkTemplate`, `@GtkTemplateChild` and `@GtkTemplateCallback` annotations, a scanner, a codegen, a `build_runner` builder, a standalone CLI, and the runtime helpers they need. *On `main`.*
- **Signal trampolines.** The landed design connects each `<signal>` to the user's instance method with a per-instance closure that lives as long as the widget. The branch instead used program-lifetime `NativeCallable`s. The per-instance closure is the smaller surface and the one that is documented.
- **A real consumer app**: `example/todo/`, a libadwaita counter built on a `@GtkTemplate` host class with an inline XML template. The branch's version was larger — Blueprint (`.blp`) and XML (`.ui`) templates, a `GResource` bundle, Meson integration, gettext catalogues and an icon — but none of that packaging is in scope for a binding generator.

#### What "done" means

:::{checklist}
[x] Dart-level subclassing is on `main`, with `dart analyze` clean and the regenerated packages included in the same change.
[x] The regenerated packages are covered by CI: `dart analyze` runs over the whole workspace and the generator tests assert the emitted shape. The *native* runtime tests now run as well, in phase 2's GTK-enabled job.
[x] Subclass registration is documented as supported, with its own lifetime rules written down, rather than left as a pattern the reader has to infer from an example.
[x] The `composite-templates` ref is deleted. Its condition — the last remaining capability being on `main` — was met, and the ref is gone: the local branch first, then the remote one. The branch's tip survives as a commit id in the object store, so the comparison in `docs/branch-state.md` can still be reproduced.
:::

:::{note}
**Sequencing note:** this phase was listed after the runtime phase on purpose — shipping generated output that no CI job has ever executed would trade a visible gap for an invisible one. The template half did not wait for it, because it is pure Dart: CI builds and analyzes `example/todo` today. The subclassing half changed the generated packages, and it landed before phase 2's GTK-enabled job existed; that gap was tracked by phase 2, and phase 2 has since closed it — the native suites run against the generated packages on every push.
:::
:::

:::{phase status=done} Phase 6 — Distributing the packages
All seventeen packages are published on pub.dev under the `gir_` prefix. The set moves in lockstep — one generator, one changelog, one version — and the working tree stays a Dart workspace with path dependencies; `tool/release.dart` assembles the publication copies and is the only thing that writes a version into a package's pubspec.

:::{checklist}
[x] A versioning policy: which packages move together, and what constitutes a breaking change for each — *`docs/release.md`: lockstep versions, the API may only grow within 1.x, and the ownership rules are stable within 1.x.*
[x] Per-package versions that follow semver, replacing the workspace pin — *one version for the whole set, stamped by `tool/release.dart`.*
[x] Publication to pub.dev — *all seventeen packages, uploaded in dependency order by `tool/release.dart publish`.*
[x] A stated stability level per package — *1.0: the emitted API only grows within 1.x; the set of bound symbols is stated by the skip report, not by the version number.*
[x] Migration notes for the generated API when an emitter changes — *the 1.0.0 changelog entry carries a Migration section for every shape change since 0.1.0.*
[x] A publishability gate in CI — *`tool/release.dart check` runs the structural checks on every pull request, and the real `dart pub publish --dry-run` for the packages whose dependencies are already on pub.dev.*
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

Static analysis is necessary and not sufficient. The gap that used to stand here — that no continuously-running test made a native GTK call — is closed: phase 2's CI job installs GTK 4 and runs the native suites. A binding that only a linter has seen is a *reviewed* binding; one that CI drives through a real GObject is a *verified* one.
:::

## Contributing

The most useful contribution is not "add a binding" — the generator makes that mechanical. It is **taking a skip entry and making it emitable**, ideally with a test. Start with the `skip_report.txt` of whichever package you care about; the reasons are alphabetised and documented in `docs/skip-categories.md`.

Two things make a change easy to accept: a change to the generator *and* the regenerated packages in the same pull request, and a test that fails before the fix.

- [Open an issue](https://github.com/TenderOwl/dart-gir) →
- [See what's already built](features.html) →
- [Understand the design first](design.html) →
