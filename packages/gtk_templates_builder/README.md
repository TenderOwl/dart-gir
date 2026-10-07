# gtk_templates_builder

`build_runner` `Builder` for `@GtkTemplate` annotation
scanning, plus a pure codegen layer that turns each
`ClassTemplatePlan` into a `_$<className>Template` mixin.

## Status

The 0.3.0 cut **emits code**. For each `@GtkTemplate`
class in the input, the builder writes a
`<input>.<className>.g.dart` file containing the mixin
that registers the template and exposes the children as
`late final` fields. Callbacks are not auto-wired yet;
see "First-cut limitation" below.

## What's in the box

- `GtkTemplatesBuilder` — a `build_runner` `Builder`. Wire
  it up via your consumer package's `build.yaml` (the
  example app under `example/` shows the shape). The
  builder scans, runs the codegen, and writes the
  per-class `.g.dart` file.
- `scanSource(String source, {String? filePath})` — a
  pure AST scanner. Pass it an in-memory Dart string and
  it returns a `BuilderPlan`. Tests use this to assert
  what the builder observed without spinning up
  `build_runner`.
- `codegenMixin(CodegenInput)` — pure codegen. Takes a
  `ClassTemplatePlan` + resolved XML and returns a Dart
  source string. Tests use this directly to assert the
  emitted shape.
- `extractChildrenFromXml(String)` — small regex-based
  extractor for `<object class="X" id="Y">` entries.
- `BuilderPlan` / `ClassTemplatePlan` / `WidgetBinding` /
  `CallbackBinding` — the data structures the scanner
  produces.
- `CodegenInput` / `TemplateChildSpec` /
  `TemplateCallbackSpec` — the data structures the
  codegen consumes.

The scanner accepts both `new GtkTemplateXml(...)` and
the implicit form `GtkTemplateXml(...)` (Dart 2.12+
without the `new` keyword). The constructor name is
matched against `GtkTemplateXml` or `GtkTemplateFile`;
anything else is skipped with a `log.warning` and the
class is dropped from the plan.

## CLI

```
dart run gtk_templates_builder path/to/window.dart
```

Reads each file, runs `scanSource` over it, resolves the
template XML (inline or by reading the file from cwd),
runs the codegen, and writes the per-class
`<input>.<className>.g.dart` file. The path of each
emitted file is printed to stdout.

## Programmatic use

```dart
import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';

final plan = scanSource(mySource, filePath: 'my_source.dart');
for (final cls in plan.classes) {
  final xml = switch (cls.templateSource) {
    GtkTemplateXml(:final content) => content,
    GtkTemplateFile(:final path) => File(path).readAsStringSync(),
  };
  final children = extractChildrenFromXml(xml);
  final input = CodegenInput.fromPlan(
    cls,
    xmlString: xml,
    xmlChildren: children,
  );
  final generated = codegenMixin(input);
  print(generated);
}
```

## User-facing API

```dart
@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class MyWindow extends GtkApplicationWindow
    with _$MyWindowTemplate {
  MyWindow(super.app);
  // The mixin provides `counterLabel` and `button` as
  // `late final` fields, populated from the template on
  // first read.
}
```

The user **does not** declare `late final` fields. The
mixin provides them, populated by `getTemplateChild` after
`initTemplate()`. The XML is the source of truth for
field names and types.

## First-cut limitation

Callbacks are not auto-wired. The `ClassTemplatePlan.callbacks`
list is captured and the codegen emits an empty callback
spec table, but `GtkWidgetClass.bindTemplateCallbackFull`
only accepts `void Function()` with no instance pointer,
and bridging to a user-declared instance method needs a
per-instance `NativeCallable` allocation or a
process-global "current instance" sentinel. Both are
recorded as follow-ups. Until the bridge lands, the
user wires callbacks manually:

```dart
@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class MyWindow extends GtkApplicationWindow
    with _$MyWindowTemplate {
  MyWindow(super.app) {
    // counter is the mixin-provided field; we wire the
    // 'clicked' signal to our instance method.
    counter.connectSignal('clicked', (GtkWidget _) => onClicked());
  }

  void onClicked() {
    print('clicked');
  }
}
```

## Migrating from 0.2.x

The 0.2.x user-facing API (`@GtkTemplate(source: ...)`,
`GtkTemplateXml` / `GtkTemplateFile`) is unchanged. The
behavioural change is that the user no longer declares
`late final` template fields — the mixin provides them.
The builder emits a new file per annotated class instead
of logging the plan.
