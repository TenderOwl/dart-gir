# gtk_templates_builder

`build_runner` `Builder` for `@GtkTemplate` annotation
scanning, plus a pure codegen layer that turns each
`ClassTemplatePlan` into a `_$<className>Template` mixin.

## Status

The builder **emits code**. For each source file with
`@GtkTemplate` classes, it writes one `<input>.g.dart` **part
file** next to the source, holding a
`_$<className>Template` mixin per annotated class. The mixin
registers the template, exposes the children as `late final`
fields, and wires the `<signal>` handlers in the XML to user
instance methods via the callback trampoline.

See [Callback trampoline](#callback-trampoline) below.

## The part-file contract

The generated file is a `part of` the user's library, so the
mixin lives in the same library as the user's class. That is
what lets the trampoline resolve the user's instance method
names at compile time.

Two rules follow from it.

**1. The user declares a `part` directive.** One part file per
source file, named after the source file — the same convention
`json_serializable` uses:

```dart
// lib/my_window.dart
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'my_window.g.dart';

@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class MyWindow extends GtkApplicationWindow with _$MyWindowTemplate {
  MyWindow(super.app) {
    initTemplate();
  }
}
```

The name is derivable from the source file's name alone, so
there is never a class-derived filename to predict. A source
file with several annotated classes gets one part file holding
all of their mixins.

**2. The user imports what the generated code needs.** The
generated file is a `part of`, so it inherits the library's
imports and cannot declare its own. It references `GtkWidget`,
`getWidgetClass`, `widgetTypeOf`, `prepareTemplateXml`,
`claimTemplateType`, the parent widget type and every child type
— so the library must import `package:gtk4/gtk4.dart`,
`package:gtk_templates/gtk_templates.dart` and the package that
declares the parent type. The builder checks this and fails the
build with the exact import lines to add.

The builder checks the `part` directive too, and fails with the
exact line to add:

```
gtk_templates: lib/my_window.dart
gtk_templates: the source file has no `part` directive for the
generated mixin (it declares no `part` directive at all).
Add this line after the last import:

    part 'my_window.g.dart';
```

**3. The generated file is `dart format`-clean.** The part file
lands next to your source, in your package — so running
`dart format .` over your package must be a no-op, or the
generated file and your checked-in copy would drift apart on
every rebuild. The builder runs its output through the same
formatter `dart format` uses before writing it, so the two
cannot disagree.

## Consumer setup

Add the builder as a dev dependency and wire it up in your
package's `build.yaml`:

```yaml
# pubspec.yaml
dev_dependencies:
  build_runner: ^2.15.1
  gtk_templates_builder:
    path: ../packages/gtk_templates_builder
```

```yaml
# build.yaml
targets:
  $default:
    builders:
      gtk_templates_builder:
        generate_for:
          - lib/**.dart
```

`build_to: source` is **not** set here. It lives in the
provider package's `build.yaml`
(`packages/gtk_templates_builder/build.yaml`) and is what
makes the generated file land next to its source instead of in
`.dart_tool/build/generated/`. Dart requires a part file to sit
in the same directory as its library, so this is what makes the
`part` directive resolve. It is set once, for every consumer.

Then:

```
dart run build_runner build
```

## What's in the box

- `GtkTemplatesBuilder` — the `build_runner` `Builder`. It
  scans, runs the codegen, and writes the part file.
- `scanSource(String source, {String? filePath})` — a
  pure AST scanner. Pass it an in-memory Dart string and
  it returns a `BuilderPlan`. Tests use this to assert
  what the builder observed without spinning up
  `build_runner`.
- `codegenLibrary(List<CodegenInput>)` — pure codegen for a
  whole source file: every mixin, one `part of` directive.
  `codegenMixin(CodegenInput)` is the single-mixin form.
- `extractChildrenFromXml(String)` — extracts the
  `<object class="X" id="Y">` entries.
- `extractSignalsFromXml(String)` — extracts the
  `<signal name="X" handler="Y"/>` entries, paired with the
  `id` and `class` of the `<object>` that owns them. A signal
  belongs to the nearest enclosing `<object>` that carries an
  `id` — GTK's own rule — so nesting and self-closing tags are
  handled correctly.
- `snakeCaseToCamel(String)` — converts a snake-case
  handler name (`on_clicked`) to a `lowerCamelCase` Dart
  method name (`onClicked`). Mirrors `package:gtk_templates`'s
  `snakeCase` in the inverse direction.
- `partFileBasename(String)` — the part file's name for a
  source file (`my_window.dart` → `my_window.g.dart`).
- `checkPartDirective(String source, String partBasename)` —
  returns `null` when the source declares the right `part`
  directive, or a diagnostic naming the exact line to add.
- `checkRequiredImports(String source, Iterable<String>
  typeNames)` — returns the import paths the generated code
  needs that the source does not declare.
- `BuilderPlan` / `ClassTemplatePlan` / `WidgetBinding` /
  `CallbackBinding` / `SignalBinding` — the data
  structures the scanner produces.
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
runs the codegen, and writes the `<input>.g.dart` part file
next to the source. The path of each emitted file is printed
to stdout. The CLI produces byte-identical output to the
`build_runner` builder.

Exit codes: `0` success, `2` file not found, `4` the source
has no `part` directive, `5` the source is missing an import
the generated code needs.

## Programmatic use

```dart
import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';

final plan = scanSource(mySource, filePath: 'my_source.dart');
final inputs = <CodegenInput>[];
for (final cls in plan.classes) {
  final xml = switch (cls.templateSource) {
    GtkTemplateXml(:final content) => content,
    GtkTemplateFile(:final path) => File(path).readAsStringSync(),
  };
  inputs.add(
    CodegenInput.fromPlan(
      cls,
      xmlString: xml,
      xmlChildren: extractChildrenFromXml(xml),
      xmlSignals: extractSignalsFromXml(xml),
      partOfPath: 'my_source.dart',
    ),
  );
}
print(codegenLibrary(inputs));
```

`partOfPath` is the basename of the user file the generated
mixin is a `part of` — the builder passes the input file's
name, the CLI passes the file it was given.

## User-facing API

```dart
@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class MyWindow extends GtkApplicationWindow
    with _$MyWindowTemplate {
  MyWindow(super.app) {
    // GTK builds a widget's template in the instance
    // initializer; Dart has no equivalent, so the mixin
    // exposes `initTemplate()` and the widget calls it here.
    initTemplate();
  }

  // The mixin provides `counterLabel` and `button` as
  // `late final` fields, populated from the template on
  // first read.
}
```

The user **does not** declare `late final` fields. The
mixin provides them, populated by `getTemplateChild` after
`initTemplate()`. The XML is the source of truth for
field names and types.

`initTemplate()` is not optional in practice: without it the
template is built lazily, on the first read of a generated field,
and a widget nobody touches comes up **empty**.

## Callback trampoline

The builder wires signals automatically. For each
`<signal name="X" handler="Y"/>` in the template XML, the
emitted mixin calls
`child.on<SignalName>(() => (this as dynamic).<Y>())` after
`initTemplate()` returns. The user only has to declare
the matching instance method:

```dart
@GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
class MyWindow extends GtkApplicationWindow
    with _$MyWindowTemplate {
  MyWindow(super.app) {
    initTemplate();
  }

  // 'clicked' on GtkButton has signature `void Function()`
  // in the GTK FFI binding; the user method must match.
  void onClicked() {
    print('clicked');
  }
}
```

with the corresponding XML:

```xml
<object class="GtkButton" id="button">
  <signal name="clicked" handler="on_clicked"/>
</object>
```

The method name is the snake-case `handler` attribute
converted to `lowerCamelCase` (`on_clicked` →
`onClicked`). The signal arity must match the
GIR-declared arity of the FFI binding's
`on<SignalName>(...)` overload — e.g. `clicked` on
`GtkButton` is `void Function()`, so the user method
takes no arguments. Mismatched arity surfaces as a
runtime type error when the signal fires, not a
build-time diagnostic.

The trampoline uses per-instance `connectSignal` rather
than `GtkWidgetClass.bindTemplateCallbackFull`, because
the latter only accepts `void Function()` with no
instance pointer; bridging to a user-declared instance
method would have required a process-global "current
instance" sentinel. `connectSignal` closes over `this`
and is correct for any number of instances.

The dispatch goes through `dynamic` because the mixin is
declared `on <ParentType>`: the analyzer rejects a call to a
member the parent type does not declare, and the user's
method is declared on *their* class, not on the parent.
`dynamic` defers the call to the runtime class's method
table without giving up static analysis on the rest of the
mixin.

## Migrating from 0.3.x

0.3.x emitted one file per **class**
(`<input>.<className>.g.dart`) and required the user to
predict that name to write the `part` directive. 0.4.0 emits
one file per **source file** (`<input>.g.dart`):

```diff
-part 'my_window.mywindow.g.dart';
+part 'my_window.g.dart';
```

The generated file's contents are otherwise unchanged apart
from the trampoline's dispatch, which is now
`(this as dynamic).<method>()` rather than `this.<method>()`.

The `TemplateCallbackSpec` class and the
`_$<Class>Template_callbacks` list are gone from the emitted
code: the trampoline reads the `<signal>` entries straight
from the XML.

`CodegenInput.fromPlan` now takes a required `partOfPath`
argument, and `codegenLibrary` replaces `codegenMixin` for
the multi-class case.

## Migrating from 0.4.x

**The host class must call `initTemplate()` from its constructor.**

```diff
 class MyWindow extends GtkApplicationWindow with _$MyWindowTemplate {
-  MyWindow(super.app);
+  MyWindow(super.app) {
+    initTemplate();
+  }
 }
```

0.4.x built the template lazily, on the first read of a generated
field. Nothing forced that read, so a window came up **empty** — the
template was never instantiated. 0.5.0 makes the mixin override
`GtkWidget.initTemplate()` and the widget builds its template while it
is constructed, which is where GTK builds it.

The generated file no longer needs `package:gobject/gobject.dart`:
the children are resolved against the *widget's* native type (the one
that declared them), not against the child's type. The import it does
need is `package:gtk_templates/gtk_templates.dart`.
