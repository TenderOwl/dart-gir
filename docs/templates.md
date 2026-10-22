# The composite-template stack

`packages/gtk_templates` + `packages/gtk_templates_builder` let a
Dart class host a GTK composite template: a `.ui` document that
describes a widget tree, whose children become fields on your Dart
class and whose `<signal>` handlers become calls into your methods.

This document is the design reference for the stack. For the
task-oriented version (how to set it up, how to migrate) see the two
package READMEs.

| Piece | Where |
|---|---|
| Annotations + runtime helpers | `packages/gtk_templates/lib/` |
| AST scanner, codegen, `build_runner` builder, CLI | `packages/gtk_templates_builder/lib/`, `bin/` |
| Worked example | `example/todo/` |

> **Status: on `main`.** This is the landed design. The
> `composite-templates` branch holds a superseded prototype of the same
> capability — Blueprint and GResource templates, Meson and gettext
> packaging, one part file per class instead of one per source file, and
> program-lifetime `NativeCallable` trampolines. It is not to be merged;
> [branch-state.md](./branch-state.md) records the comparison item by
> item.

---

## 1. Annotation surface

Three marker annotations, all `const` so the scanner can read them as
constant expressions. They carry no runtime behaviour.

### `@GtkTemplate`

Required, exactly one per host class.

```dart
@GtkTemplate(source: GtkTemplateXml('''<interface>…</interface>'''))
class MyWindow extends GtkApplicationWindow with _$MyWindowTemplate {
  MyWindow(super.app) {
    initTemplate();
  }
}
```

`initTemplate()` is the generated mixin's override of
`GtkWidget.initTemplate()`: it installs the template on the native
class and builds it for this instance. **The host widget has to call
it** — GTK builds a widget's template in the instance initializer and
Dart has no equivalent (see §5).

`source:` is a `GtkTemplateSource`, a sealed hierarchy with two
variants:

- **`GtkTemplateXml(content)`** — the XML inline as a Dart string
  literal. Convenient for small templates and tests; no file I/O at
  build or run time.
- **`GtkTemplateFile(path)`** — a path to a `.ui` file, resolved
  **relative to the package root** (the directory holding
  `pubspec.yaml`). The builder reads the file at build time and
  embeds the contents as a string, so the runtime path is identical
  to `GtkTemplateXml`. See §1.1 for the rules the file has to follow.

The scanner only accepts a *string literal* argument. A
concatenation, an interpolation, or a `const` variable is rejected
with a warning and the class is skipped.

The old 0.1.x form `@GtkTemplate(resourcePath: '/com/myapp/foo.ui')`
is gone. `GtkWidgetClass.setTemplateFromResource` is not part of the
codegen dispatch; call it yourself if you need GResource loading.

### 1.1 A template that lives in a file

`GtkTemplateFile` is the form to use for anything that is not a toy.
The file is read **through the build's asset reader**, not off the
filesystem, and that has two consequences worth knowing.

**Editing the template re-runs the builder.** An asset the builder
reads is a *tracked input* of the build step: change it, and the next
`dart run build_runner build` regenerates the part file. Read off the
filesystem the file would be invisible to the build, the part file
would keep the old template, and the edit would silently do nothing —
the build would report "skipped" and the app would come up with the
previous template.

**The file has to be a public asset of the package.** A build only
sees a package's public directories — `lib/**` and `bin/**`, plus a
few named files. A template under `lib/` therefore needs no
configuration at all:

```dart
@GtkTemplate(source: GtkTemplateFile('lib/window.ui'))
class MyWindow extends AdwApplicationWindow with _$MyWindowTemplate { … }
```

Anything else — `data/window.ui`, say — has to be declared in the
consumer's `build.yaml`:

```yaml
additional_public_assets:
  - data/**
```

Without that, the builder cannot read the file and **fails the
build** with the path it looked for:

```
gtk_templates: lib/my_window.dart points at a template file that could not be read.
  package: my_app
  path:    data/window.ui
The path is relative to the package root — the directory holding pubspec.yaml — and the file has to be inside the package.
```

The build failing is deliberate. The alternative — writing no part
file — would leave the previous one in place, and the stale template
would keep running as if the edit had never happened.

The `example/todo` package uses the `data/` layout and declares it
that way; see `example/todo/build.yaml`.

### `@GtkTemplateChild`

Marks a field as a template child.

```dart
@GtkTemplateChild(name: 'button')
late final GtkButton button;
```

`name:` is the `id` attribute in the template XML. When omitted, the
field name is used verbatim.

> **The XML is the source of truth.** The codegen derives the child
> list from `<object class="…" id="…">` elements, not from the
> annotations. `@GtkTemplateChild` is currently documentation and a
> placeholder for a future consistency check; it is *not* what
> determines the emitted `late final` fields. A field whose name
> does not match an XML `id` will simply never be populated — the
> generated mixin declares its own `late final <Type> <id>` field
> with the XML's spelling.

### `@GtkTemplateCallback`

Marks an instance method as a template-callback sink.

```dart
@GtkTemplateCallback()
void onClicked() { … }
```

The callback name GTK looks up is the snake-case form of the method
name (`onClicked` → `on_clicked`). As with children, the XML's
`<signal handler="…">` attribute is what actually drives the wiring;
the annotation records intent.

---

## 2. The scanner plan

`scanSource(String source, {String? filePath})` in
`packages/gtk_templates_builder/lib/builder.dart` parses the source
with `package:analyzer`'s `parseString` (`throwIfDiagnostics: false`
— the scanner tolerates diagnostics so fixtures need not be
compilable Dart) and returns a `BuilderPlan`:

```
BuilderPlan
└── classes: List<ClassTemplatePlan>
    ├── className      — simple class name; the mixin is _$<className>Template
    ├── parentType     — simple name of the `extends` clause (default: GtkWidget)
    ├── templateSource — GtkTemplateXml | GtkTemplateFile
    ├── children       — List<WidgetBinding>  (fieldName → childName)
    └── callbacks      — List<CallbackBinding> (methodName → callbackName)
```

The scanner walks only **top-level** classes. A `@GtkTemplate` class
nested inside another class is not picked up.

`BuilderPlan` and its members live in
`packages/gtk_templates_builder/lib/builder_plan.dart`. The scanner
is a pure function over a string — it does no I/O, does not resolve
the `GtkTemplateFile` contents, and does not read the XML. Those are
the builder's job.

### Analyzer API notes

The scanner walks the analyzer's **v1** AST projection:
`NamedArgument` (not `NamedExpression`), `arg.name.lexeme` (not
`arg.name.label.name`), and `arg.argumentExpression` (not
`arg.argumentExpression2`, which returns a `ParsedValueArguments`
wrapper). `arg.argumentExpression` is deprecated in analyzer 14; the
uses carry an `// ignore: deprecated_member_use` because the rest of
the scanner is v1-shaped.

Both constructor-invocation shapes are accepted: the explicit
`new GtkTemplateXml(…)` (`InstanceCreationExpression`) and the
implicit `GtkTemplateXml(…)` (`MethodInvocation` with a null
target).

---

## 3. Part-file convention

**One part file per source file**, named `<source-basename>.g.dart`:

| Source | Generated part file |
|---|---|
| `lib/todo_window.dart` | `lib/todo_window.g.dart` |

This is the `json_serializable` convention, and it is chosen for one
reason: **the user never has to predict a generated filename.** A
source file with three `@GtkTemplate` classes still produces exactly
one part file, holding three mixins. The name is a pure function of
the source file's name, so `part 'todo_window.g.dart';` is the only
line the user has to write — and it is derivable by reading their own
file's name.

The generated file is a `part of` the user's library:

```dart
// GENERATED by gtk_templates_builder. Do not edit by hand.
// Source:  todo_window
// Classes: TodoWindow
//
// ignore_for_file: type=lint

part of 'todo_window.dart';
```

Because it is a `part of`:

- It **inherits the user's library's imports** and cannot declare its
  own. The library must import `package:gtk4/gtk4.dart`,
  `package:gtk_templates/gtk_templates.dart`, and the package that
  declares the parent type and every child type.
- It shares a scope with the user's class, which is what lets the
  signal trampoline reach the user's instance methods.
- Dart requires a part file to sit in the **same directory** as its
  library. The output must therefore be written next to the source.

### Where `build_to: source` goes

`build_to: source` is a property of the **builder definition**, so it
belongs in the **provider** package's `build.yaml`
(`packages/gtk_templates_builder/build.yaml`):

```yaml
builders:
  gtk_templates_builder:
    import: "package:gtk_templates_builder/builder.dart"
    builder_factories: ["gtkTemplatesBuilder"]
    build_extensions: {".dart": [".g.dart"]}
    auto_apply: dependents
    build_to: source
```

A consumer's `build.yaml` configures only *what to run over* — its
`targets:` section accepts only `enabled`, `generate_for`,
`options`, `dev_options` and `release_options`, and rejects
`build_to` outright:

```yaml
targets:
  $default:
    builders:
      gtk_templates_builder:
        generate_for:
          - lib/**.dart
```

### `build_extensions`

`{".dart": [".g.dart"]}` — the builder runs on every `.dart` input
and emits a `.g.dart` sibling.

> The `$lib$` placeholder is **not** usable for this. In
> `build_runner` 2.16.x it was repurposed to mean "a virtual file",
> not "files under `lib/`". The working form for "every Dart source"
> is the `.dart` extension key.

Because `.dart` also matches the builder's own output, the builder
explicitly skips inputs whose path ends in `.g.dart` — a generated
part file carries a `part of` directive, not a `part` one, and is not
a source.

### Why the builder cannot inject the `part` directive

The obvious design — the builder writes the `part '…';` line into the
user's source — is not implementable under `build_runner`:

- A builder **cannot rewrite its own primary input**. `build_runner`
  throws `InvalidOutputException('Asset already exists')` when a
  builder writes to an asset it is building from, and
  `build_state.dart` defines a file as a source if it is an input.
- `source_gen` — the machinery behind `json_serializable` and
  `freezed` — does **not** inject `part` directives either. It warns
  and skips the input.

So the `part` line is the user's to write. The builder's job is to
make that line trivially derivable and to fail loudly when it is
missing.

---

## 4. Codegen output contract

`codegenLibrary(List<CodegenInput>)` is pure string assembly — no
I/O, no FFI, no analyzer. `codegenMixin(CodegenInput)` is the
single-class form of the same function.

For each annotated class the part file holds:

### The XML constant

```dart
const String _$TodoWindowTemplate_xml = '''<interface>…</interface>''';
```

### The children list

```dart
const List<_TemplateChildSpec> _$TodoWindowTemplate_children = [
  _TemplateChildSpec('counterLabel', 'GtkLabel'),
  _TemplateChildSpec('button', 'GtkButton'),
];
```

`_TemplateChildSpec` is a tiny helper class emitted **once per part
file** and shared by every mixin in it.

### The mixin

```dart
mixin _$TodoWindowTemplate on AdwApplicationWindow {
  static bool _classInitialized = false;
  static late final GBytes _templateBytes;

  static GBytes _ensureClassInit(int widgetType) { … }

  bool _instanceInitialized = false;

  @override
  void initTemplate() { … }

  void _ensureInstanceInit() { … }

  late final GtkLabel counterLabel = () { … }();
  late final GtkButton button = () { … }();

  void _wireSignals() { … }
}
```

---

## 5. Runtime init order

### The rule: build the template from the constructor

GTK builds a widget's template in the **instance initializer** —
`gtk_widget_init_template()` is called from the subclass's `init`.
Dart has no instance initializer: a field initializer cannot touch
`this` (the analyzer rejects `this` and every instance member in an
initializer), and the native widget does not exist until the super
constructor has returned.

So the generated mixin **overrides `GtkWidget.initTemplate()`** and the
host widget calls it from its constructor body:

```dart
class TodoWindow extends AdwApplicationWindow with _$TodoWindowTemplate {
  TodoWindow(super.app) {
    initTemplate();
  }
}
```

`initTemplate()` is idempotent — only the first call builds anything.

Without that call the template is built **lazily**, on the first read
of a generated field (see `_ensureInstanceInit()` below). A widget that
is never touched stays empty: the window comes up, the template is
never instantiated, and nothing is on screen. The lazy path is a safety
net, not the supported way to use a template.

### The class stage

`_ensureClassInit(widgetType)`, run at most once per Dart class:

1. `prepareTemplateXml(xml, widgetType)` rewrites the XML (see below).
2. `gbytesFromString(...)` wraps it in a `GBytes`.
3. The `GBytes` is cached in a `static late final`.

### The instance stage

`initTemplate()`, run at most once per instance:

1. `widgetTypeOf(widget)` — the instance's native `GType`.
2. `getWidgetClass(widget)` — walks `handle` → `GTypeInstance*` → type
   name → `GType` → `TypeClass*` → `GtkWidgetClass.fromPointer`. Returns
   `null` if the lookup fails; the mixin throws a `StateError` in that
   case.
3. `claimTemplateType(widgetType, '<DartClassName>')` — GTK stores the
   template on the **native class** and allows exactly one per class
   (`gtk_widget_class_set_template()` asserts
   `widget_class->priv->template == NULL`). A Dart subclass has no
   `GType` of its own, so the first instance installs the template and
   every later instance reuses it. A *different* Dart class claiming
   the same native type is a hard error, reported as a `StateError`
   instead of a GTK assertion. The claim is **process-wide** — it lives
   in the native type's `qdata`, so a second isolate of the same
   process sees it and does not install a second template.
4. `widgetClass.setTemplate(_templateBytes)` and
   `widgetClass.bindTemplateChildFull(child.id, false, 0)` for every
   child in the XML, in source order — **only on the first instance**,
   for the reason above.
5. `super.initTemplate()` — GTK instantiates the template's widget tree.
6. `_wireSignals()` — **only if the template declares at least one
   `<signal>`**.

After step 5, each generated `late final` field resolves its value
on first read:

```dart
late final GtkButton button = () {
  _ensureInstanceInit();
  final raw = (this as GtkWidget).getTemplateChild(
    widgetTypeOf(this as GtkWidget), 'button',
  );
  return raw.cast<GtkButton>(GtkButton.fromPointer);
}();
```

`getTemplateChild()`'s first argument is the type that **declared** the
child — the widget's own native type — not the child's type. Passing
the child's type returns `NULL`.

`cast<T>(factory)` lives on every generated GObject wrapper; the
wrapper's `fromPointer` constructor is passed so the cast is checked
at runtime rather than reinterpreted.

### What the runtime does to the XML

`prepareTemplateXml(xml, widgetType)` applies two rewrites before the
XML reaches GTK:

1. **The `<template>` attributes are rewritten.** GTK checks
   `class` against the widget's type name and `parent` against the
   widget's direct parent type, and rejects a mismatch. A Dart
   subclass has no `GType` of its own, so the type name the user
   writes (`class="TodoWindow"`) can never match. The runtime
   substitutes the instance's real type and that type's parent, so the
   XML can name the Dart class and still satisfy GTK. When the parent
   type cannot be resolved the `parent` attribute is dropped — GTK
   treats it as optional.
2. **`<signal>` elements are removed.** GtkBuilder resolves
   `<signal handler="…">` by looking the handler name up as a **C
   symbol** in the object's class scope. A Dart class has no C
   symbols, so GTK would fail with *"No function named `on_clicked`"*
   and skip the connection. The `<signal>` element is still what the
   **builder** reads to generate the trampoline; it is only removed
   from the copy of the XML that is handed to GTK.

---

## 6. The callback trampoline

The XML's `<signal name="X" handler="Y"/>` is wired to the user's
method through the child's typed signal API:

```dart
void _wireSignals() {
  button.onClicked(() => (this as dynamic).onClicked());
}
```

### Why `dynamic`

The mixin is declared `on <ParentType>`. The analyzer rejects a call
to a member the *constraint* does not declare, so neither a bare
`onClicked()` nor `this.onClicked()` type-checks — the user's method
lives on the class that *applies* the mixin, not on the mixin's
constraint. `(this as dynamic).onClicked()` defers the lookup to the
runtime method table of the applying class.

The trade-off: a typo in the method name is a runtime `NoSuchMethodError`
rather than a compile error. The generated file is covered by the
analyzer-resolution tests, but the *dispatch target* cannot be
statically checked from inside the mixin.

### The helper name

The builder calls the *typed* signal helper the bindings generate:
`on` + the signal name in UpperCamelCase. The generator's rule
(`generator/lib/src/resolve/naming.dart`, `toUpperCamel`) splits on
`_`, `-` and whitespace and then on camelCase humps:

| XML `name` | helper |
|---|---|
| `clicked` | `onClicked` |
| `icon-release` | `onIconRelease` |
| `icon_press` | `onIconPress` |

The builder has to agree with the generator *exactly* — a different
spelling names a method that does not exist on the widget class, and
the generated part file does not compile. The builder's own fixture
proves it: the generated part file is resolved with the real analyzer
against `package:gtk4`.

### Arity rules

The user's method signature must match the GIR-declared arity of the
FFI binding's `on<SignalName>(…)` overload:

| Signal | GIR arity | User method |
|---|---|---|
| `GtkButton::clicked` | `void()` | `void onClicked()` |
| `GtkEntry::icon-release` | `void(GtkEntryIconPosition)` | `void onIconRelease(GtkEntryIconPosition pos)` |

The generated closure forwards the signal's arguments to the user's
method:

```dart
void _wireSignals() {
  increment.onClicked(() => (this as dynamic).onIncrementClicked());
  entry.onIconRelease((pos) => (this as dynamic).onIconRelease(pos));
}
```

The closure's parameter *types* come from the binding's callback type
— Dart infers them from the expected type — and their *names* come
from the user's method, which the scanner records. A user method whose
signature does not match the signal's therefore fails the analyzer
when the part file is generated, instead of silently dropping the
arguments at runtime.

### Lifetime

The closure created in `_wireSignals()` captures `this` and is
handed to the child's signal connection. It lives as long as the
signal connection does — that is, for the life of the widget. The
mixin performs no explicit teardown; GTK drops the connection when
the widget is destroyed, and the closure's captured `this` goes with
it.

This is a *per-instance* connection, made after `initTemplate()`. It
is not a class-level `bindTemplateCallbackFull` binding, and it does
not require the callback to be a top-level or static Dart function —
it is a Dart closure, not a `NativeCallable`.

> The `composite-templates` branch explored a program-lifetime
> `NativeCallable` trampoline for this. That design is **not** in
> `main`; the per-instance closure above is what ships. See
> [branch-state.md](./branch-state.md).

---

## 7. Diagnostics

The builder fails loudly rather than letting a mistake surface far
from its cause. Both failures are logged with `log.severe` *and*
thrown — `build_runner` swallows builder exceptions and reports them
through the log, so the log call is what the user actually sees.

### Missing `part` directive

```
gtk_templates: lib/todo_window.dart
gtk_templates: the source file has no `part` directive for the
generated mixin (it declares no `part` directive at all).
Add this line after the last import:

    part 'todo_window.g.dart';
```

The check is `checkPartDirective(String source, String partBasename)`
in `lib/codegen.dart` — pure, so the builder and the standalone CLI
share it.

### Missing imports

```
gtk_templates: lib/todo_window.dart is missing the imports the
generated mixin needs:
  import 'package:gtk_templates/gtk_templates.dart';
The generated file is a `part of` this library and inherits its
imports, so add the lines above to this file.
```

`checkRequiredImports(source, typeNames)` checks for
`package:gtk4/gtk4.dart`, `package:gtk_templates/gtk_templates.dart`,
and — via `packageForType` — the package that declares the parent type
and every child type. `Adw*` maps to `package:adw/adw.dart`;
everything else maps to `package:gtk4/gtk4.dart`.

### Missing template file

```
gtk_templates: lib/todo_window.dart points at a template file that could not be read.
  package: todo
  path:    data/window.ui
The path is relative to the package root — the directory holding pubspec.yaml — and the file has to be inside the package.
```

A `GtkTemplateFile` that names a file the build cannot read is a hard
failure, not a warning: the alternative — writing no part file — would
leave the previous one in place, and the stale template would keep
running as if the edit had never happened (see §1.1).

The usual cause is that the file is not a *public asset* of the
package: a build sees `lib/**` and `bin/**`, and nothing else unless
the package says so in its `build.yaml`.

```yaml
additional_public_assets:
  - data/**
```

### CLI

`packages/gtk_templates_builder/bin/gtk_templates_builder.dart` runs
the same scanner and codegen outside `build_runner`:

```console
$ dart run gtk_templates_builder lib/todo_window.dart
```

It writes the same part file, next to the source, and produces
byte-identical output to the `build_runner` path. Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic failure |
| 2 | Bad usage |
| 3 | Nothing was written — no `@GtkTemplate` class was found |
| 4 | The `part` directive is missing |
| 5 | A required import is missing |
| 6 | The `.ui` file could not be read |

---

## 8. Known limits

- **The XML extraction is a tag scanner, not a parser.**
  `extractChildrenFromXml` and `extractSignalsFromXml` walk the
  document's tags and attributes. They do not build a tree, do not
  resolve `<property>` values, do not evaluate expressions, and do
  not understand namespaces or entity references beyond the raw
  attribute text. A `<signal>` belongs to the nearest enclosing
  `<object>` that carries an `id` — GTK's own rule — and nested and
  self-closing `<object>` tags are handled by keeping a stack.
  Anything beyond that (e.g. a `<signal>` on an `<object>` with no
  `id`) is not bound.
- **No Blueprint, no GResource.** Only `GtkTemplateXml` and
  `GtkTemplateFile` are supported. `setTemplateFromResource` is not
  in the codegen dispatch.
- **`dynamic` dispatch.** The trampoline resolves the user's method
  at run time. A rename that breaks the connection is not a compile
  error (see §6).
- **`@GtkTemplateChild` does not drive the codegen.** The XML does.
  The annotation is documentation today (see §1).
- **Only top-level classes are scanned.** A `@GtkTemplate` class
  nested inside another class is not found.
- **`snakeCase` does not coalesce trailing capitals.** `fooURL` →
  `foo_u_r_l`, where PyGObject would produce `foo_url`. GTK template
  symbols rarely hit this, but it is a difference from the reference
  implementation.
- **`GtkTemplateFile` resolution is build-time, and strict.** The file is
  read through the build's asset reader, so it has to be a public asset
  of the package (§1.1) and a missing or unreadable file **fails the
  build**. The path is relative to the package root, not to the source
  file and not to the current working directory.
- **One `GBytes` per class, shared across instances.** The template
  bytes are cached in a `static late final`. This is correct — GTK
  copies the template — but it does mean the XML string is retained
  for the life of the process.
- **One template per native class.** GTK stores the template on the
  native class, and a Dart subclass does not register a `GType` of its
  own. Two Dart template classes that extend the *same* native widget
  type therefore collide: the second one is rejected with a
  `StateError` (`claimTemplateType`) instead of tripping GTK's
  `widget_class->priv->template == NULL` assertion. Sharing a native
  type between two template classes needs a real `GType` — which means
  a C extension, not a Dart mixin.

  The ownership registry behind that check lives in the **type system** —
  the owner's name is kept in the native type's `qdata`, under a quark
  (`g_quark_from_string()` interns the key, so every isolate of the
  process agrees on it). That makes the registry per **process**, like
  GTK's slot, instead of per **isolate**: two template classes in two
  isolates of one process are caught by the registry, and the second one
  is rejected with a `StateError` rather than tripping GTK's own
  assertion, which tears the heap down.

  The `qdata` is native memory, so the owner's name is stored there as
  a `g_strdup`'d copy — a Dart `String` lives in the isolate that
  created it and the other isolate could not read it. The copy is
  released when the type is finalized, which for a widget type is
  never: the registry holds one name per template class for the life of
  the process.
- **The template must be built from the constructor.** Dart has no
  instance initializer, so the host widget has to call
  `initTemplate()` itself (see §5). Forgetting it does not fail
  loudly: the template is then built lazily, on the first read of a
  generated field, and a widget that is never touched stays empty.

---

## 9. Tests

| File | Covers |
|---|---|
| `packages/gtk_templates_builder/test/codegen_test.dart` | Pure codegen output shapes |
| `packages/gtk_templates_builder/test/builder_test.dart` | The scanner's plan output |
| `packages/gtk_templates_builder/test/e2e_test.dart` | Scanner → codegen → expected source; XML extractors |
| `packages/gtk_templates_builder/test/generated_code_test.dart` | The on-disk fixture resolves with **zero** analyzer diagnostics, plus four mutation regressions |
| `packages/gtk_templates_builder/test/builder_output_test.dart` | The `build_runner` output resolves with zero diagnostics, satisfies the part-file contract, reads a template **file** through the build, and fails when that file is missing |
| `packages/gtk_templates/test/runtime_test.dart` | `snakeCase`, `getWidgetClass`, `gbytesFromString`, the XML rewrites, the template claim |
| `example/todo/test/todo_widget_test.dart` | The window really is built from the template (native; needs a display) |
| `example/todo/test/todo_test.dart` | The file contract: the part directive, the generated file next to its source, the template coming from the `.ui` file |

**The rule: generated code must type-check.** A parse-only check is
not enough — the builder's output is resolved with the real analyzer
in `generated_code_test.dart` and `builder_output_test.dart`, and the
fixture under `test/fixtures/` is part of the package's own analysis
so `dart analyze` covers it too.

Four codegen bugs shipped to `main` before those tests existed: an
uncalled `_wireSignals()`, a `cast<T>()` without its factory
argument, a missing `package:gobject` import, and a missing
parent-type import. Each is now a regression test.

`example/todo/test/todo_widget_test.dart` is the **native** half: it
builds the real window and asserts that the content is there, that
the children are bound, and that the signal handler is connected. GTK
needs a display, so the suite skips itself when there is none — CI
runs headless:

```console
xvfb-run -a dart test example/todo
```

Its teardown disconnects the Dart signal handlers and destroys the
windows. Two reasons, both about the isolate shutting down:

- A `GObject` that is finalized *while the isolate shuts down*
  destroys its signal handlers, and the destroy-notify GObject calls
  is a Dart callback — the VM refuses to run a callback while it is
  shutting down and aborts. That is a pre-existing property of the
  bindings' signal plumbing (it reproduces with three lines and no
  template code).
- A window that is only freed at shutdown is still in GTK's global
  toplevel list; GTK walks that list on every main-loop iteration,
  and the stale pointer is a use-after-free — which matters because
  `dart test` runs the GTK-using suites concurrently, in one process.
