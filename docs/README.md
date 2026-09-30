# Design documents

The design references live alongside the workspace root so they're
discoverable from `git ls-files` and easy to link from PRs.

| Doc | Covers |
|---|---|
| [architecture.md](./architecture.md) | High-level pipeline: GIR → loader → emitters → per-package layout |
| [emission.md](./emission.md) | What each emitter (`EnumEmitter`, `FunctionEmitter`, `RecordEmitter`, `ClassEmitter`, `CallableEmitter`, `CallbackEmitter`, signal helper) produces, and how |
| [type-system.md](./type-system.md) | GIR-to-Dart type mapping rules, transfer ownership, nullable handling, cross-namespace resolution, the `relativeTo` plumbing for inherited signals |
| [signals.md](./signals.md) | Typed `onSignalName` design: bucket partitioning, what counts as "kept", the `connectSignal` escape hatch, transfer-none strings + `g_free`, destroy-notify, the inheritance walk |
| [skip-categories.md](./skip-categories.md) | Every category and reason that shows up in `packages/<lib>/skip_report.txt`, alphabetised |

## Where to start

* **Adding a new binding package** — start with [architecture.md](./architecture.md#adding-a-new-binding-package).
* **Understanding why `<X>` is missing from `<pkg>`** — search
  `packages/<lib>/skip_report.txt` for the symbol, then read the
  matching reason in [skip-categories.md](./skip-categories.md).
* **Debugging a typed-signal issue** — read [signals.md](./signals.md).
* **Modifying the generator** — read [emission.md](./emission.md) and
  [type-system.md](./type-system.md) end to end.
