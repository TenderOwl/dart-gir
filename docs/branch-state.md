# Branch state

A verified record of what is on `main` and what is not. Every claim below
was checked against the **committed trees** — not against a working copy —
so it describes what a fresh clone would actually get.

| Ref | Tip | Subject |
| --- | --- | --- |
| `main` | `c0c59c51` | *feat: async-arrays and owned references* |
| `origin/main` | `c0c59c51` | *feat: async-arrays and owned references* |
| `notes-editor` | `4efb06d9` | *feat: real-word app example* — local only, in-flight work |
| `backup/main-merged` | `c0c59c51` | local only, a safety branch for the merged work |
| `origin/notepad` | `43eccbf1` | remote only |
| `origin/website` | `e88c6827` | remote only |

**The conclusion in one line:** both capabilities the `composite-templates`
branch was holding are on `main`, and everything the branch still had that
`main` did not is the prototype that was never in scope — so the branch is
**retired**.

`main` and `origin/main` are the **same commit**: the trunk is published. The
`composite-templates` ref — the one thing this document was waiting for — is
gone: the local branch first, then the remote ref.

## How to re-check this

Four commands, run against the refs and never against the working tree:

```console
git merge-base 932de6ba main
git log --oneline main..932de6ba
git log --oneline 932de6ba..main
git diff --stat main...932de6ba
```

`git merge-base` is the one that decides the question: it names the commit
the two lines of history last shared. The other three describe what each
side did afterwards, and between them they account for every difference.

The branch is retired, so the commands name its tip commit — `932de6ba` —
instead of a branch name. The object survives in the object store and in the
reflog, so they still resolve.

---

## 1. The composite-template half is on `main`

Both packages ship it, and `main` carries the whole stack:

| Piece | Path on `main` |
| --- | --- |
| Annotations, runtime helpers | `packages/gir_gtk_templates/lib/src/{annotations,bytes,runtime}.dart` |
| Runtime tests | `packages/gir_gtk_templates/test/runtime_test.dart` |
| Scanner plan, codegen | `packages/gir_gtk_templates_builder/lib/{builder_plan,codegen}.dart` |
| `build_runner` builder | `packages/gir_gtk_templates_builder/lib/builder.dart` |
| Standalone CLI | `packages/gir_gtk_templates_builder/bin/gtk_templates_builder.dart` |
| Codegen tests | `packages/gir_gtk_templates_builder/test/{codegen_test,e2e_test,builder_output_test,generated_code_test}.dart` |
| Worked example | `example/todo/` — `lib/todo_window.dart` plus the generated `lib/todo_window.g.dart` |
| Native example test | `example/todo/test/todo_widget_test.dart` |
| Design reference | `docs/templates.md` |

The landed shape is **one part file per source file** (`<source>.g.dart`,
beside the source), the `json_serializable` convention, with the template
installed by the mixin's override of `GtkWidget.initTemplate()`. CI builds
`example/todo` with `build_runner` and analyzes the result on every push,
and `packages/gir_gtk_templates_builder/test/generated_code_test.dart` resolves
the generated part file with the real analyzer.

## 2. The subclassing half is on `main`

The extendable contract is in the generator's output and is pinned by a
test:

| Claim | Where it lives on `main` |
| --- | --- |
| Generated classes are `class`, not `final class` | `generator/lib/src/emit/class_emitter.dart` |
| Props companions are public and extendable | the same emitter, the `*Props` companion |
| The contract is asserted | `generator/test/emitter_test.dart`, group *Dart-level subclassing contract* |
| It is exercised against real GTK types | `packages/gir_gtk4/test/gtk4_subclass_test.dart` |
| The rules are written down | `docs/subclassing.md` |

## 3. What the branch added on top

The merge-base of the retired `composite-templates` branch and `main` is
`ed5ce0f7` — *"feat: add subclasssing"*. That is the branch point **and** the
subclassing commit: the subclassing capability was already on `main` before
the branch started, so it was never an unmerged capability of the branch.

The branch held two commits on top of that point:

| Commit | Subject |
| --- | --- |
| `836fd87e` | *feat: add composite templates support* |
| `932de6ba` | *fix: composite template generation and loading* |

`main` is **34 commits** ahead of the branch point. Among them are its own
composite-template work (`b4e3e26c`, `57629492`, `24ad716e`), the
subclassing contract (`4a8d6c90`), the generated site (`59a4d36`), the
byte-buffer work (`5de5cf58`, `b59a56d3`), the ownership transfer and the
byte-array lifetime (`c0c59c51`) and the notepad's own history.

## 4. What the branch still had that `main` did not

Every path the branch added is packaging or an older internal layout:

| Branch-only path | What it is | Why it is not wanted |
| --- | --- | --- |
| `example/todo/data/ui/window.blp`, `shortcuts.blp` | Blueprint templates | Blueprint is a separate compiler in the build; out of scope for a binding generator |
| `example/todo/data/resources.gresource.xml`, `data/icons/**` | GResource bundle | Same — application packaging, not bindings |
| `example/todo/meson.build`, `meson.options`, `subprojects/`, `**/meson.build` | Meson build | The workspace builds with `dart pub`; a second build system doubles the surface |
| `example/todo/po/` | gettext catalogues | Translation infrastructure is not a binding concern |
| `example/todo/data/*.desktop.in.in`, `*.service.in`, `*.gschema.xml.in` | Desktop/service/schema files | Packaging again |
| `example/todo/lib/todo_window.gtk_templates.dart` | One part file **per class** | The landed convention is one part file per source file; two conventions would have to be supported forever |
| `packages/gir_gtk_templates/lib/src/gtk_template.dart`, `template_callback.dart`, `template_child.dart`, `template_lookup.dart` | The pre-refactor internal layout | Folded into `annotations.dart` and `runtime.dart` on `main` |
| `packages/gir_gtk_templates_builder/lib/src/{emitter,generator,model,naming,visitors}.dart` | The pre-refactor internal layout | Replaced by `builder_plan.dart` + `codegen.dart` on `main` |
| `example/bin/**`, `example/pubspec.yaml` | The pre-`example/`-split layout | `main` splits it into `example/gtk4_examples`, `example/notepad`, `example/todo` |

The branch also used **program-lifetime `NativeCallable`** trampolines for
signal handlers; the landed design uses per-instance closures that live as
long as the widget. The per-instance closure is the smaller surface and the
one that is documented.

`main` additionally has, and the branch did not: `docs/templates.md`,
`docs/subclassing.md`, `docs/site.md`, `packages/gir_gtk4/test/gtk4_subclass_test.dart`,
the analyzer-resolved codegen tests, the native example test, and the
generated site.

## 5. Conclusion

| Ref | Status |
| --- | --- |
| `main` | The trunk. Carries both capabilities. Published: `main` and `origin/main` are the same commit (`c0c59c51`). |
| `composite-templates` | **Retired.** Nothing was ever left to merge: its merge-base was the subclassing commit itself, and its two unique commits were the out-of-scope prototype. The local branch and the remote ref are gone. |
| `array-types`, `notepad`, `props` | Merged into `main` long ago and the local branches are deleted — do not recreate them. |
| `gasync` | Superseded — do not build on it. The local branch is deleted. |
| `notes-editor` | Local only, and in flight — do not touch it. |
| `backup/main-merged` | Local only, a safety branch for the merged work. It can go once the trunk is where it should be. |
| `origin/main` | In sync with local `main`. |

The retirement was the owner's, in two commands:

```console
git branch -D composite-templates
git push origin --delete composite-templates
```

Both refs are gone — the local branch and `origin/composite-templates`, each
at `932de6ba`. The commit itself survives in the object store and in the
reflog, which is why the four commands above still work.
