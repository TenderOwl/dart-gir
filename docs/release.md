# Releasing

How the seventeen packages are versioned, published, and what a release
promises. The policy in one place, because a release that changes its mind
between the changelog and the upload is not a release.

## The shape of the set

Seventeen packages, released **in lockstep**:

| Package | Namespace | Role |
| --- | --- | --- |
| `gir_ffi` | — | the handwritten runtime helpers every package uses |
| `gir_glib` | GLib 2.0 | types, main loop, strings, byte arrays |
| `gir_cairo` | cairo 1.0 | 2D vector drawing |
| `gir_graphene` | Graphene 1.0 | vector / matrix / quaternion primitives |
| `gir_gobject` | GObject 2.0 | the type system, signals, properties |
| `gir_gio` | Gio 2.0 | files, async, D-Bus, networking, applications |
| `gir_gdk_pixbuf` | GdkPixbuf 2.0 | image loading and pixel formats |
| `gir_pango` | Pango 1.0 | text shaping, fonts, layout |
| `gir_dart_gobject` | — | `registerDartType` — a native identity for a Dart class |
| `gir_gdk4` | Gdk 4.0 | display, input, GL / Vulkan contexts |
| `gir_gsk4` | Gsk 4.0 | render nodes and effects |
| `gir_gtk4` | Gtk 4.0 | widgets, dialogs, actions, settings |
| `gir_adw` | Adw 1 | libadwaita's adaptive widgets |
| `gir_gi_repository3` | GIRepository 3.0 | the GIR typelib loader |
| `gir_gtk_source5` | GtkSource 5 | the code-editor component |
| `gir_gtk_templates` | — | the `@GtkTemplate` runtime |
| `gir_gtk_templates_builder` | — | the `build_runner` builder for the templates |

Every name carries the `gir_` prefix: the bare names (`glib`, `gio`,
`cairo`, `graphene`, …) belong to other publishers on pub.dev, so the
prefix is what makes the whole set publishable. The names are decided in
one place — `packageNameFor` in `generator/lib/src/resolve/types.dart` —
and everything else follows from it.

The dependency graph is acyclic, so the publish order is well defined. It
is *computed*, not written down: `tool/release.dart` sorts the packages
topologically over the path dependencies in the working tree.

## Lockstep versioning

All seventeen packages carry the same version. One generator, one
changelog, one release — a consumer of `gir_gtk4` gets the matching
`gir_glib`, and there is no version matrix to reason about.

**The workspace version is the version.** The root `pubspec.yaml` carries
it, and `tool/release.dart` is the only thing that writes a version into
a package's pubspec. The working tree's per-package pubspecs are
`publish_to: none` — they are not published, so their version field is
not the release's business.

## What 1.0 promises

**Within 1.x the emitted API may only grow.**

* A **new** class, method, function, constant or property is additive and
  needs no migration note.
* A **renamed** symbol changes only when the upstream GIR renames it. The
  change ships with a migration note naming the old and the new shape.
* A **removed** symbol is removed only when the upstream GIR removed it,
  and only in a major release.
* A **changed shape** — a different parameter type, a different return
  type, a different ownership rule — is breaking, and lands in a major
  release with a migration note.

The ownership and lifetime rules are part of that promise. `owned`, the
`NativeFinalizer`, the byte-array contract, the `transfer-ownership`
mapping: **these are stable within 1.x.** A change there is a breaking
change, not a patch.

## What 1.0 does not promise

**The set of bound symbols.** What is bound is stated by the skip report,
regenerated with every release: `packages/<lib>/skip_report.txt` names
every symbol the generator could not emit, with a category and a reason.
A symbol that appears there is not bound, and 1.0 does not promise that
it will be. The counts move with the upstream GIR files, so the report —
not a version number — is the contract.

The known gaps at 1.0 are the array residue, the exotic OUT buffers, the
`inout` parameters, and the properties whose GIR getter has no
single-value form. Each is documented in
[skip-categories.md](./skip-categories.md), and each is a *missing
symbol*, not a wrong one.

**Windows and macOS.** The loader knows every platform's file names —
the table is in `generator/lib/src/resolve/platform_libraries.dart` — but
**only Linux is executed and tested**. On macOS the loader additionally
needs the library directory on the loader path (Homebrew's `lib` is not
on it by default). A wrong name on an unexecuted platform is still a
wrong name; the names are facts, the support is not.

## The release process

```
prepare → check → publish → tag
```

**`dart run tool/release.dart prepare`** writes the publication copies
into `<temp>/dart-gir-release/<pkg>/`: the library verbatim, a rewritten
pubspec (the version, no `publish_to: none`, no `resolution: workspace`,
hosted dependencies), and the `README.md`, `CHANGELOG.md` and `LICENSE`
copies pub.dev wants. The working tree stays a workspace with path
dependencies — that is what makes `dart pub get` work offline and keeps
the workspace resolving.

The copies land **outside the repository**, and that is not a detail:
pub reads the ignore rules of the package it publishes, and a package
that sits inside a git repository with git-ignored files packs as an
*empty* archive — *"the pubspec is hidden, probably by .gitignore"*.
`--release-dir <path>` puts them somewhere else.

**`dart run tool/release.dart check`** runs the structural checks that
need no network: the name, the version, the description's length, the
links, the topics, the required files, no path dependencies, no
`publish_to: none`. Then, for every package whose dependencies are
already on pub.dev, it runs the real `dart pub publish --dry-run`. The
packages whose dependencies are not published yet are reported as
*structurally checked only* — which is exactly the state of the world
before the first upload.

**`dart run tool/release.dart publish`** uploads in dependency order.
pub.dev indexes a package asynchronously, so the next package's
dependency may not resolve immediately; the tool waits between uploads,
and `--skip-validation` is the documented escape hatch for the indexing
lag.

**The tag** is `1.0.0` — the version, on the `main` branch.

## Migration notes

Whenever an emitter changes the shape it emits, the changelog entry gets
a **Migration** subsection naming the old shape and the new one. The
emitter's own documentation ([emission.md](./emission.md)) is where the
rule lives; the changelog is where a consumer finds it.

The 1.0.0 entry is the first such migration: the packages were renamed,
the ownership rules landed, the byte-array shapes changed, and the
loader's `openLibrary` signature changed. Every one of those is listed
there.

## The rules the tooling enforces

* **A version bump is made by `tool/release.dart`, and by nothing else.**
* **The working tree stays a workspace.** `publish_to: none`,
  `resolution: workspace` and the path dependencies stay in the
  committed pubspecs; the publication copy is a build output.
* **The CI gate runs `tool/release.dart check` on every pull request**, so
  a package that pub.dev would reject is caught before the release, not
  during it.
* **The generated tree is the source of truth.** The release copies the
  committed `packages/<lib>/lib/`; it never regenerates anything.
* **The copies are outside the repository.** They are a build output, and
  a build output that sits inside the source tree is packed as an empty
  package — see [the release process](#the-release-process).
