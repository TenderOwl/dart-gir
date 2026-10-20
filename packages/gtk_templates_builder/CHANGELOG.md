# Changelog

## 0.5.0 — The template is built during construction

The emitted mixin changed in three ways.

### 1. The host class calls `initTemplate()`

0.4.x built the template **lazily**, on the first read of a generated
field. Nothing forced that read, so a window came up **empty** — the
widget existed, the template was never instantiated. GTK builds a
widget's template in the instance initializer; Dart has no instance
initializer (a field initializer cannot touch `this`), so the host
widget now builds its template itself:

```diff
 class TodoWindow extends AdwApplicationWindow with _$TodoWindowTemplate {
-  TodoWindow(super.app);
+  TodoWindow(super.app) {
+    initTemplate();
+  }
 }
```

The mixin now **overrides `GtkWidget.initTemplate()`**: it resolves
the widget's class, installs the template, binds the children, calls
`super.initTemplate()` and wires the signals. It is idempotent. The
lazy path survives as a safety net (`_ensureInstanceInit()`), so a
host that forgets the call still gets a working — if late — widget.

### 2. The children are resolved against the widget's own type

`gtk_widget_get_template_child()` wants the type that *declared* the
child, which is the widget's own native type — not the child's type.
Passing the child's type returns `NULL`, so every generated field
came back empty:

```diff
 final raw = (this as GtkWidget).getTemplateChild(
-  typeFromName('GtkButton'), 'button',
+  widgetTypeOf(this as GtkWidget), 'button',
 );
```

### 3. The XML is prepared for GTK

The runtime rewrites the `<template>` element's `class` and `parent`
attributes to the instance's real native type and that type's parent
(GTK checks both and rejects a mismatch, and a Dart subclass has no
`GType` of its own), and it removes the `<signal>` elements before
GTK sees them — GtkBuilder would resolve the handler name as a C
symbol, which a Dart class cannot provide.

### Breaking changes

- The host class must call `initTemplate()` from its constructor.
- The generated file no longer references `package:gobject/gobject.dart`.
  The import it needs instead is `package:gtk_templates/gtk_templates.dart`;
  the builder's "missing import" diagnostic names the new list.

### Other changes

- The template is installed **once per native class**. GTK stores it
  on the native class and allows exactly one there
  (`gtk_widget_class_set_template()` asserts
  `widget_class->priv->template == NULL`), so the second instance of
  a Dart class reuses it. A *different* Dart class claiming the same
  native type is rejected with a `StateError` instead of a GTK
  assertion.

## 0.4.0 — One part file per source file

The generated mixin is now a `part of` the user's library, and
there is **one part file per source file** rather than one per
class. The part file's name is derived from the source file's
name alone — `my_window.dart` → `my_window.g.dart` — the same
convention `json_serializable` uses, so the user never has to
predict a class-derived filename.

Because the mixin lives in the user's library, the trampoline
resolves the user's instance method names at compile time.

### Breaking changes

- The `part` directive the user writes changes:

  ```diff
  -part 'my_window.mywindow.g.dart';
  +part 'my_window.g.dart';
  ```

- The trampoline dispatches through `dynamic`:

  ```diff
  -button.onClicked(() => this.onClicked());
  +button.onClicked(() => (this as dynamic).onClicked());
  ```

  The mixin is declared `on <ParentType>`, and the analyzer
  rejects a call to a member the parent type does not declare —
  the user's method is declared on *their* class, not on the
  parent. `dynamic` defers the call to the runtime class's
  method table without giving up static analysis on the rest of
  the mixin.

- `CodegenInput.fromPlan` now takes a required `partOfPath`
  argument: the basename of the user file the generated mixin
  is a `part of`.

- The emitted `_TemplateCallbackSpec` class and the
  `_$<Class>Template_callbacks` list are gone. The trampoline
  reads the `<signal>` entries straight from the XML.

### New behaviour

- **The builder checks the `part` directive** and fails the
  build with the exact line to add, instead of leaving the user
  with an "undefined mixin" error at the use site.

- **The builder checks the imports** the generated code needs
  (`package:gtk4/gtk4.dart`, `package:gobject/gobject.dart`
  and the package declaring the parent widget type) and fails
  with the exact import lines to add. A `part of` file inherits
  its library's imports and cannot declare its own, so a missing
  import would otherwise surface inside the *generated* file.

- **`build_to: source`** is declared in this package's
  `build.yaml`, so the generated file lands next to its source
  rather than in `.dart_tool/build/generated/`. Dart requires a
  part file to sit in the same directory as its library.
  Consumers do not have to configure this.

- **The CLI produces byte-identical output** to the
  `build_runner` builder, and reports the same diagnostics
  (exit code 4 for a missing `part` directive, 5 for a missing
  import).

- **The generated file is `dart format`-clean.** The part file lands
  next to the user's source, in the user's package — so running
  `dart format .` over that package must be a no-op, or the
  generated file and the checked-in copy would drift apart on every
  rebuild. The builder now runs its output through the same
  formatter `dart format` uses (`package:dart_style`), so the two
  cannot disagree.

  `codegenLibrary` / `codegenMixin` stay pure string assembly; the
  formatting is a separate step (`formatGeneratedSource`) applied by
  the builder and the CLI. A test asserts the written output is a
  fixed point of the formatter.

### Fixes

- The XML extractors are now a tag scanner rather than a set of
  per-shape regexes. A self-closing `<object id="x"/>` used to
  swallow the *next* object's `<signal>` entries, so the
  trampoline was wired to the wrong child. Nesting is handled
  too: a signal belongs to the nearest enclosing `<object>` that
  carries an `id`, which is GTK's own rule. Children are also
  extracted regardless of the order of the `class` and `id`
  attributes.

- The scanner is compatible with `package:analyzer` 14, where
  `NamedExpression` was replaced by `NamedArgument`.

### New public surface

- `codegenLibrary(List<CodegenInput>)` — pure codegen for a
  whole source file: every mixin, one `part of` directive.
  `codegenMixin(CodegenInput)` remains the single-mixin form.
- `partFileBasename(String)` — the part file's name for a
  source file.
- `checkPartDirective(String source, String partBasename)` —
  `null` when the directive is present, or a diagnostic naming
  the exact line to add.
- `checkRequiredImports(String source, Iterable<String>
  typeNames)` — the import paths the generated code needs that
  the source does not declare.
- `requiredImports(Iterable<String> typeNames)` — the import
  paths the generated code needs.
- `packageForType(String typeName)` — the binding package that
  declares a widget type.

## 0.3.1 — Callback trampoline

The builder now auto-wires `<signal name="X" handler="Y"/>`
entries from the template XML to user-declared instance
methods. The emitted `_$<className>Template` mixin calls
`child.on<SignalName>(() => this.<Y>())` per signal in a
new `_wireSignals()` block at the end of
`_ensureInstanceInit`. The user no longer has to call
`connectSignal(...)` from their constructor.

The user's instance method name must match the XML's
`handler="..."` attribute, converted from snake_case
to `lowerCamelCase` (`on_clicked` → `onClicked`). The
arity must match the GIR-declared arity of the FFI
binding's `on<SignalName>(...)` overload — e.g.
`clicked` on `GtkButton` is `void Function()`, so the
user method takes no arguments. Mismatched arity
surfaces as a runtime type error when the signal fires,
not a build-time diagnostic.

The trampoline uses per-instance `connectSignal` rather
than `GtkWidgetClass.bindTemplateCallbackFull`, because
the latter only accepts `void Function()` with no
instance pointer; bridging to a user-declared instance
method would have required a process-global "current
instance" sentinel. `connectSignal` closes over `this`
and is correct for any number of instances.

### New public surface

- `extractSignalsFromXml(String)` — extracts
  `<signal name="X" handler="Y"/>` entries, paired with the
  `id` and `class` of the `<object>` that owns them.
- `snakeCaseToCamel(String)` — converts a snake-case
  handler name (`on_clicked`) to a `lowerCamelCase` Dart
  method name (`onClicked`). Inverse of
  `package:gtk_templates`'s `snakeCase`.
- `SignalBinding` — the data structure the extractor
  produces and the codegen consumes
  (`signalName`, `childId`, `childType`, `methodName`).
- `CodegenInput.fromPlan(...)` now takes a required
  `xmlSignals: List<SignalBinding>` argument (resolved
  by the builder and the CLI before they call
  `codegenMixin`).

## 0.3.0 — Codegen + callback trampoline

The builder now emits a `_$<className>Template` mixin next
to each annotated input. The mixin:

- Registers the template with the widget class via
  `GtkWidgetClass.setTemplate(...)` exactly once per class
  (idempotent, lazy, anchored by the first read of a
  generated `late final` field).
- Walks the children list extracted from the template XML
  and calls `bindTemplateChildFull(id, false, 0)` for each.
- Exposes each child as a `late final <Type> <id>` field
  on the mixin, populated by `getTemplateChild` after
  `initTemplate()`.
- Walks the `<signal name="X" handler="Y"/>` entries in the
  template XML and emits per-instance
  `child.onX(() => userMethod())` calls. The user method
  must match the GIR-declared signal arity (e.g. `clicked`
  on `GtkButton` is `void Function()`).

### Public surface

- `codegenMixin(CodegenInput)` — pure: turns a
  `ClassTemplatePlan` + resolved XML into a Dart source
  string. Tested directly in `test/codegen_test.dart`.
- `extractChildrenFromXml(String)` — small regex-based
  extractor for `<object class="X" id="Y">` entries.
- `extractSignalsFromXml(String)` — extracts `<signal
  name="X" handler="Y"/>` entries together with their
  parent `<object>` (for child id and class).
- `snakeCaseToCamel(String)` — converts the XML's snake-case
  handler name (`on_clicked`) to the user's camelCase
  Dart method name (`onClicked`).
- `CodegenInput`, `TemplateChildSpec`, `TemplateCallbackSpec`,
  `SignalBinding` — the data structures the codegen consumes.

### Behavioural change

The scanner now records the parent class on
`ClassTemplatePlan` (read from the `extends` clause). The
codegen emits `mixin _$<className>Template on <parentType>`,
so the user's `with _$ClassTemplate` resolves.

### Generator change (shared with the runtime PR)

The generator now parses `<glib:boxed>` from the glib
namespace's GIR, so the glib `GBytes` record is generated
through the standard emit path. The `gtk_templates`
package re-exports the generated `GBytes`.

## 0.2.0 — Breaking change

The builder now emits a `_$<className>Template` mixin next
to each annotated input. The mixin:

- Registers the template with the widget class via
  `GtkWidgetClass.setTemplate(...)` exactly once per class
  (idempotent, lazy, anchored by the first read of a
  generated `late final` field).
- Walks the children list extracted from the template XML
  and calls `bindTemplateChildFull(id, false, 0)` for each.
- Exposes each child as a `late final <Type> <id>` field
  on the mixin, populated by `getTemplateChild` after
  `initTemplate()`.

### Public surface

- `codegenMixin(CodegenInput)` — pure: turns a
  `ClassTemplatePlan` + resolved XML into a Dart source
  string. Tested directly in `test/codegen_test.dart`.
- `extractChildrenFromXml(String)` — small regex-based
  extractor for `<object class="X" id="Y">` entries.
- `CodegenInput`, `TemplateChildSpec`, `TemplateCallbackSpec`
  — the data structures the codegen consumes.

### Behavioural change

The scanner now records the parent class on
`ClassTemplatePlan` (read from the `extends` clause). The
codegen emits `mixin _$<className>Template on <parentType>`,
so the user's `with _$ClassTemplate` resolves.

### First-cut limitation

Callbacks are not auto-wired. The `ClassTemplatePlan.callbacks`
list is preserved and the codegen emits an empty callback
spec table, but the existing
`GtkWidgetClass.bindTemplateCallbackFull` binding only
takes `void Function()` with no instance pointer — bridging
to a user-declared instance method needs a per-instance
`NativeCallable` allocation or a process-global "current
instance" sentinel. The follow-up PR will add the bridge
and emit trampolines. Until then, the user wires callbacks
manually with `connectSignal(...)` from their constructor.

### Migration from 0.2.x

- The 0.2.x user-facing API (`@GtkTemplate(source: ...)`,
  `GtkTemplateXml` / `GtkTemplateFile`, `snakeCase`,
  `getWidgetClass`) is unchanged.
- The fixture / test classes in this package dropped the
  `late final <Type> <name>` declarations: the mixin
  provides them. The user no longer needs to declare
  template-derived fields by hand.

## 0.2.0 — Breaking change

The builder's `ClassTemplatePlan` no longer carries a flat
`resourcePath: String`; it now carries a
`templateSource: GtkTemplateSource` (re-exported from
`package:gtk_templates`):

- `GtkTemplateXml(content)` — raw XML.
- `GtkTemplateFile(path)` — path relative to the package root.

The scanner reads the new `@GtkTemplate(source: ...)` form and
rejects the legacy 0.1.x `@GtkTemplate(resourcePath: ...)` form
with a `log.warning`; the class is skipped from the plan. The
`log` line in `GtkTemplatesBuilder.build` now reads
`className ← kind(value)` (e.g. `NotepadWindow ←
xml(<interface>…</interface>)` or `SampleWindow ←
file(lib/notepad/window.ui)`).

The internal `InstanceCreationExpression` / `MethodInvocation`
distinction is handled by a small `_constructorNameOf` helper
so the scanner accepts both `new GtkTemplateXml(...)` and the
implicit form `GtkTemplateXml(...)`.

## 0.1.0

Initial release.

- `GtkTemplatesBuilder` — a `build_runner` `Builder` that scans
  Dart source for `@GtkTemplate`, `@GtkTemplateChild`, and
  `@GtkTemplateCallback` annotations.
- `scanSource(String)` — pure AST scanner usable from tests
  without going through `build_runner`. Tolerates parse
  diagnostics so fixtures don't need to be compilable Dart.
- `BuilderPlan` / `ClassTemplatePlan` / `WidgetBinding` /
  `CallbackBinding` — the data structures the scanner produces.
- A file-based CLI (`dart run gtk_templates_builder
  <file.dart>...`) that prints the plan to stdout.

This first cut emits **no** `.dart` files — the scanner only
reports the plan. The follow-up PR will use the plan to drive
the generated `_$<className>Template` mixin.
