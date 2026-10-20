# Design documents

The design references live alongside the workspace root so they're
discoverable from `git ls-files` and easy to link from PRs.

| Doc | Covers |
|---|---|
| [architecture.md](./architecture.md) | High-level pipeline: GIR → loader → emitters → per-package layout |
| [emission.md](./emission.md) | What each emitter (`EnumEmitter`, `FunctionEmitter`, `RecordEmitter`, `ClassEmitter`, `CallableEmitter`, `CallbackEmitter`, signal helper) produces, and how |
| [type-system.md](./type-system.md) | GIR-to-Dart type mapping rules, transfer ownership, nullable handling, cross-namespace resolution, the `relativeTo` plumbing for inherited signals |
| [signals.md](./signals.md) | Typed `onSignalName` design: bucket partitioning, what counts as "kept", the `connectSignal` escape hatch, transfer-none strings + `g_free`, destroy-notify, the inheritance walk |
| [async.md](./async.md) | The GLib `*_async` + `*_finish` pattern: the two wrapper shapes, the callback signature, and how to pair them |
| [templates.md](./templates.md) | The composite-template stack: annotation surface, scanner plan, the one-part-file-per-source convention, codegen output contract, runtime init order, the callback trampoline, known limits |
| [subclassing.md](./subclassing.md) | Dart-level subclassing of the generated wrappers: the extendable contract, ownership and lifetime rules, what a covariant override promises, and what a Dart subclass is not |
| [dart-gobjects.md](./dart-gobjects.md) | Dart classes with a native type: `registerDartType`, the `GType` accessor, the `ffi.Struct` type-system records, the wrapper cache, and the lifetime rules |
| [branch-state.md](./branch-state.md) | What is committed on `main` and what is not: the verified branch comparison, the composite-template and subclassing inventories, and how to re-check them |
| [skip-categories.md](./skip-categories.md) | Every category and reason that shows up in `packages/<lib>/skip_report.txt`, alphabetised |
| [site.md](./site.md) | The site pipeline: the Markdown subset, the block directives, the facts layer, the design system and the drift checks |

## Where to start

* **Adding a new binding package** — start with [architecture.md](./architecture.md#adding-a-new-binding-package).
* **Understanding why `<X>` is missing from `<pkg>`** — search
  `packages/<lib>/skip_report.txt` for the symbol, then read the
  matching reason in [skip-categories.md](./skip-categories.md).
* **Debugging a typed-signal issue** — read [signals.md](./signals.md).
* **Using a GTK composite template in Dart** — read
  [templates.md](./templates.md).
* **Extending a generated wrapper** — read
  [subclassing.md](./subclassing.md).
* **Giving a Dart class a native type** — read
  [dart-gobjects.md](./dart-gobjects.md).
* **Checking what is on `main` and what is still on a branch** — read
  [branch-state.md](./branch-state.md).
* **Modifying the generator** — read [emission.md](./emission.md) and
  [type-system.md](./type-system.md) end to end.
* **Changing the project site** — read [site.md](./site.md). The site's
  sources live in `site_src/`; the output in `site/` is generated and
  must not be edited by hand.
