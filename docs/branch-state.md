# Branch state

A verified record of what is on `main` and what is not. Every claim below
was checked against the **committed trees** — not against a working copy —
so it describes what a fresh clone would actually get.

| Branch | Tip | Subject |
| --- | --- | --- |
| `main` | `4deb5b37` | *docs: add dark mode toggle into notepad example* |
| `origin/main` | `4deb5b37` | *docs: add dark mode toggle into notepad example* |
| `composite-templates` | `932de6ba` | *fix: composite template generation and loading* |
| `origin/composite-templates` | `932de6ba` | *fix: composite template generation and loading* |

**The conclusion in one line:** both capabilities the `composite-templates`
branch was holding are on `main`, and everything the branch still has that
`main` does not is the prototype that was never in scope — so the branch is
ready to be retired.

`main` and `origin/main` are the **same commit**: the trunk is published.
The one thing left is the `composite-templates` ref, which still exists
both locally and on the remote.

## How to re-check this

Four commands, run against the refs and never against the working tree:

```console
git merge-base composite-templates main
git log --oneline main..composite-templates
git log --oneline composite-templates..main
git diff --stat main...composite-templates
```

`git merge-base` is the one that decides the question: it names the commit
the two lines of history last shared. The other three describe what each
side did afterwards, and between them they account for every difference.

---

## 1. The composite-template half is on `main`

Both packages ship it, and `main` carries the whole stack:

| Piece | Path on `main` |
| --- | --- |
| Annotations, runtime helpers | `packages/gtk_templates/lib/src/{annotations,bytes,runtime}.dart` |
| Runtime tests | `packages/gtk_templates/test/runtime_test.dart` |
| Scanner plan, codegen | `packages/gtk_templates_builder/lib/{builder_plan,codegen}.dart` |
| `build_runner` builder | `packages/gtk_templates_builder/lib/builder.dart` |
| Standalone CLI | `packages/gtk_templates_builder/bin/gtk_templates_builder.dart` |
| Codegen tests | `packages/gtk_templates_builder/test/{codegen_test,e2e_test,builder_output_test,generated_code_test}.dart` |
| Worked example | `example/todo/` — `lib/todo_window.dart` plus the generated `lib/todo_window.g.dart` |
| Native example test | `example/todo/test/todo_widget_test.dart` |
| Design reference | `docs/templates.md` |

The landed shape is **one part file per source file** (`<source>.g.dart`,
beside the source), the `json_serializable` convention, with the template
installed by the mixin's override of `GtkWidget.initTemplate()`. CI builds
`example/todo` with `build_runner` and analyzes the result on every push,
and `packages/gtk_templates_builder/test/generated_code_test.dart` resolves
the generated part file with the real analyzer.

## 2. The subclassing half is on `main`

The extendable contract is in the generator's output and is pinned by a
test:

| Claim | Where it lives on `main` |
| --- | --- |
| Generated classes are `class`, not `final class` | `generator/lib/src/emit/class_emitter.dart` |
| Props companions are public and extendable | the same emitter, the `*Props` companion |
| The contract is asserted | `generator/test/emitter_test.dart`, group *Dart-level subclassing contract* |
| It is exercised against real GTK types | `packages/gtk4/test/gtk4_subclass_test.dart` |
| The rules are written down | `docs/subclassing.md` |

## 3. What the branch added on top

The merge-base of `composite-templates` and `main` is `ed5ce0f7` —
*"feat: add subclasssing"*. That is the branch point **and** the subclassing
commit: the subclassing capability was already on `main` before the branch
started, so it was never an unmerged capability of the branch.

The branch holds two commits on top of that point:

| Commit | Subject |
| --- | --- |
| `836fd87e` | *feat: add composite templates support* |
| `932de6ba` | *fix: composite template generation and loading* |

`main` is **33 commits** ahead of the branch point. Among them are its own
composite-template work (`b4e3e26c`, `57629492`, `24ad716e`), the
subclassing contract (`4a8d6c90`), the generated site (`59a4d36`), the
byte-buffer work (`5de5cf58`, `b59a56d3`) and the notepad's own history.

## 4. What the branch still has that `main` does not

Every path the branch adds is packaging or an older internal layout:

| Branch-only path | What it is | Why it is not wanted |
| --- | --- | --- |
| `example/todo/data/ui/window.blp`, `shortcuts.blp` | Blueprint templates | Blueprint is a separate compiler in the build; out of scope for a binding generator |
| `example/todo/data/resources.gresource.xml`, `data/icons/**` | GResource bundle | Same — application packaging, not bindings |
| `example/todo/meson.build`, `meson.options`, `subprojects/`, `**/meson.build` | Meson build | The workspace builds with `dart pub`; a second build system doubles the surface |
| `example/todo/po/` | gettext catalogues | Translation infrastructure is not a binding concern |
| `example/todo/data/*.desktop.in.in`, `*.service.in`, `*.gschema.xml.in` | Desktop/service/schema files | Packaging again |
| `example/todo/lib/todo_window.gtk_templates.dart` | One part file **per class** | The landed convention is one part file per source file; two conventions would have to be supported forever |
| `packages/gtk_templates/lib/src/gtk_template.dart`, `template_callback.dart`, `template_child.dart`, `template_lookup.dart` | The pre-refactor internal layout | Folded into `annotations.dart` and `runtime.dart` on `main` |
| `packages/gtk_templates_builder/lib/src/{emitter,generator,model,naming,visitors}.dart` | The pre-refactor internal layout | Replaced by `builder_plan.dart` + `codegen.dart` on `main` |
| `example/bin/**`, `example/pubspec.yaml` | The pre-`example/`-split layout | `main` splits it into `example/gtk4_examples`, `example/notepad`, `example/todo` |

The branch also used **program-lifetime `NativeCallable`** trampolines for
signal handlers; the landed design uses per-instance closures that live as
long as the widget. The per-instance closure is the smaller surface and the
one that is documented.

`main` additionally has, and the branch does not: `docs/templates.md`,
`docs/subclassing.md`, `docs/site.md`, `packages/gtk4/test/gtk4_subclass_test.dart`,
the analyzer-resolved codegen tests, the native example test, and the
generated site.

## 5. Conclusion

| Branch | Status |
| --- | --- |
| `main` | The trunk. Carries both capabilities. Published: `main` and `origin/main` are the same commit (`4deb5b37`). |
| `composite-templates` | Nothing left to merge. Its merge-base is the subclassing commit itself, and its two unique commits are the out-of-scope prototype. **Ready to be retired.** |
| `array-types`, `notepad`, `props` | Merged into `main`; do not build on them. |
| `gasync` | Superseded — do not build on it. |
| `origin/main` | In sync with local `main`. |

One action remains, and it is the owner's:

```console
git branch -D composite-templates
git push origin --delete composite-templates
```

Both refs still exist — the local branch and `origin/composite-templates`,
each at `932de6ba`.
