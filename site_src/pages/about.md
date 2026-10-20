---
title: Who builds this, and how
description: dart-gir is maintained by Andrey Maksimov and was developed with AI coding agents as working collaborators under human direction and review.
nav_order: 5
nav_label: About
section_label: About
---

dart-gir is a one-person project. It is also a project built with AI coding agents as working collaborators. Both facts are stated here rather than left for a reader to infer from the commit history.

## The author

:::{cols}
### Andrey Maksimov

Developer at **TenderOwl**, a small software company in Moscow, and the author and maintainer of dart-gir. The project is published under **{{facts.license}}**, copyright 2026.

The repository is [github.com/TenderOwl/dart-gir](https://github.com/TenderOwl/dart-gir). Issues, questions and pull requests are welcome — with the caveat, stated on the [contributing](roadmap.html#contributing) section, that a generator change must arrive together with its regenerated output.

Other work lives at [tenderowl.com](https://tenderowl.com) and [github.com/TenderOwl](https://github.com/TenderOwl).

### Why this project exists

GTK 4 and libadwaita are excellent C libraries with excellent introspection data — and excellent bindings for Python, JavaScript, Rust and Go. For Dart, the honest options were hand-written FFI, or nothing.

Hand-written FFI does not scale past a demo window, and "nothing" means nobody can write a GTK application in Dart at all. The upstream `.gir` files already contain the complete API description, so the missing piece was a generator that takes them seriously — especially around ownership and nullability, which is exactly where a naive binding layer quietly introduces memory bugs.

The goal is narrow and concrete: a Dart API where `button.props.label` is a `String`, not a `dynamic`, and where the interesting failure modes are in the generator instead of in your application.
:::

## Before the bindings: the applications

dart-gir is the third attempt at solving the same problem, and the reason the design looks the way it does comes from shipping GTK applications rather than from reading documentation about them.

:::{cols}
### [Frog](https://getfrog.app)

OCR tool for GNOME · MIT · on [Flathub](https://flathub.org/en/apps/com.github.tenderowl.frog) and Snapcraft

Text extraction from almost any source — a screenshot, a video, a PDF, a webpage, a QR code. Grab the region, get the text. It is the app most people know TenderOwl by, and it is where the daily friction of doing GTK work in a language without good bindings shows up most concretely.

### [Norka](https://norka.app)

Continuous text editor for Linux · MIT · on [Flathub](https://flathub.org/en/apps/com.github.tenderowl.norka)

A distraction-free editor: markdown, autosave, full-text search, reading time, previews, export to HTML, Docx and PDF. Originally built for elementary OS, later on Flathub. A second, more ambitious rewrite has been attempted more than once.
:::

:::{note}
**Both are PyGObject applications.** Frog and Norka are written in Python on top of GTK through PyGObject — which is exactly where this project's `.props` design comes from. The generated API deliberately mirrors the PyGObject shape (`widget.props.label`, typed signals on the object itself) because it is a model that has already survived contact with real GTK applications. The difference dart-gir is trying to make is that the same shape should be available from Dart, and should come with ownership semantics that the type system can see.
:::

## AI-assisted development

This project was developed with AI coding agents as working collaborators, under human direction and review. This section exists because a project page that quietly omits that fact is not honest, regardless of how good the software is.

### How the work was done

AI coding agents were used as working collaborators throughout the project — across implementation, tests, documentation and maintenance. The architecture, the design decisions, the interpretation of the GIR ownership and lifetime semantics, and the judgement about what is correct all remained human work, under review.

Rather than itemise which files were machine-written, the more useful thing is to say how the two ideas are kept apart in this project: *code having been produced* is not the same claim as *code being correct*, and only the second one is presented as a guarantee. Which is why the next section is a list of things you can check yourself, and why the [roadmap](roadmap.html) names the biggest unverified area first.

### How you can tell what is verified

Every capability claimed on this site links to the code, the tests or the report that demonstrates it:

| Claim | How to check it yourself |
| --- | --- |
| The code is written | It is committed. `dart analyze` reports no issues across the workspace. |
| The generator behaves as documented | `dart test generator/` — the generator's own unit tests. These run in CI on every push. |
| The runtime helpers manage memory correctly | `cd packages/gir_ffi && dart test` — including the `HeapAnchor` lifetime contract. |
| The generated template code type-checks | `dart test packages/gtk_templates_builder` — including a `build_runner` gate and an analyzer-resolution check of the generated part file. `cd example/todo && dart run build_runner build && dart analyze` does the same on a real consumer app. Both run in CI. |
| The generated wrappers can be subclassed in Dart | `dart test packages/gtk4` — the `gtk4_subclass_test.dart` suite subclasses a generated class, narrows a return type covariantly and extends the generated props companion. The rules are written down in `docs/subclassing.md`. |
| The generated bindings work against real GTK | **Not currently verified continuously.** CI never makes a native call. The GTK4/GLib tests require a real native installation and were last run by hand. This gap is the first item on the [roadmap](roadmap.html). |
| Symbols that could not be emitted | `packages/<lib>/skip_report.txt` — every one, with a reason. {{facts.total_skipped}} entries today. |
| The numbers on this site | `dart run tool/collect_facts.dart` — every figure on this site is derived from the repository, and CI fails if the committed facts drift. |

### Known limitations of this way of working

Stated because they are real, not because they are disqualifying:

- **Writing quality varies.** Documentation and comments are accurate more often than they are good, and some of it is longer than it needs to be. Doc comments inherited from GIR also carry upstream HTML quirks that the generated packages have to suppress analyzer warnings for.
- **Verification is uneven.** Generator logic is well covered by unit tests; native behaviour is not covered by CI at all. Tool-assisted development can produce a large, plausible, wrong surface faster than it can be reviewed — which is the main reason the runtime gap is treated as urgent rather than deferred.
- **History is noisy.** The commit log reflects an agent-assisted workflow. The `CHANGELOG.md` is the reliable record of user-facing change, not the commit history.
- **The licence covers the code, not the process.** The [licence](license.html) covers the source; it does not make any claim about how the source was produced, which is why this statement exists alongside it.

:::{note}
**If you would rather not use AI-assisted code:** the licence does not require a preference on this. What it requires is that claims made about the project are checkable — which is why every capability on this site links to the code, the tests or the skip report that demonstrates it.
:::

## Working principles

:::{cols}
### State the gaps

This site has a page of what does not work yet, and the skip report names every symbol the generator declines to emit. A binding layer that hides its omissions is worse than one that has holes, because the hole surfaces later as a mystery at the call site.

### The generator is the source of truth

{{facts.generated_lines}} lines of generated code are disposable. Editing them by hand is not just discouraged, it is wrong — the next regeneration reverts it. This is why CI does not re-run the generator: the committed output is what gets linted and tested, so drift between generator and packages cannot merge unnoticed.

### Memory safety is the feature

Most hand-written FFI bugs are lifetime bugs. The project's own OUT-parameter work produced a heap corruption and a use-after-free before it produced a correct implementation, and both are documented in the changelog with the tests that now prevent them.

### Pre-1.0, honestly

Packages are `publish_to: none` and pinned to a single workspace version. The generated API will change when the generator improves. That is stated on the [home page](index.html) rather than discovered by a consumer.
:::

## Get involved

The most valuable contribution is taking a line from a `skip_report.txt` and making it emitable, ideally with a test that fails before the fix. Adding a namespace is mechanical by comparison — the generator is namespace-agnostic and a new binding is mostly a matter of pointing it at another `.gir` file.

- [Open the repository](https://github.com/TenderOwl/dart-gir) →
- [Read the roadmap](roadmap.html) →
- [Licence](license.html) →
