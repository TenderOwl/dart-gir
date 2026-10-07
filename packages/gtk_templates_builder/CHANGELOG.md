# Changelog

## 0.3.0 — Codegen

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
