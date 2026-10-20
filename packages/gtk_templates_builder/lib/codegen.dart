/// Pure codegen for the `_$<className>Template` mixin.
///
/// Takes a `ClassTemplatePlan` plus the resolved template
/// XML, returns a Dart source string. No I/O, no FFI, no
/// analyzer — just string assembly. Tested in
/// `test/codegen_test.dart`.
///
/// The emitted file is a `part of` directive: it lives in
/// the **same library** as the user's annotated class, so
/// the mixin can resolve the user's instance method names
/// (the callback trampoline) at compile time.
///
/// One part file per **source file** (not per class), named
/// `<source-basename>.g.dart` — the same convention
/// `json_serializable` uses. The user writes a single
/// `part 'todo_window.g.dart';` line and never has to know
/// the generated class names. A source file with several
/// `@GtkTemplate` classes gets one part file holding every
/// mixin.
///
/// The emitted mixin:
///   - Overrides `GtkWidget.initTemplate()` so that calling it from
///     the widget's constructor builds the template. GTK builds a
///     widget's template in the instance initializer; Dart has no
///     instance-initializer hook, so the call has to come from the
///     constructor body.
///   - Calls `GtkWidgetClass.setTemplate(bytes)` with the
///     `gbytesFromString`-wrapped XML once per **native** class —
///     GTK stores the template on the native class and allows only
///     one per class.
///   - Calls `bindTemplateChildFull` for every
///     `<object id="…">` in the template (the XML is the
///     source of truth for child names and types; the
///     user's `@GtkTemplateChild` annotations are documented
///     but not consulted by the codegen).
///   - Exposes per-instance `late final <Type> <id>` fields
///     on the mixin, populated by `getTemplateChild` after
///     `initTemplate()`.
///   - Wires `<signal name="X" handler="Y"/>` entries to the
///     user's instance method via per-instance
///     `connectSignal` (the callback trampoline). The user
///     method's arity must match the GIR-declared arity of
///     the FFI binding's `on<SignalName>(...)` overload.
library;

import 'builder_plan.dart';

import 'package:dart_style/dart_style.dart';

/// One child element from the template XML.
///
/// `id` is the widget id (`<object id="…">`); `typeName` is
/// the Dart type from the `class` attribute (e.g.
/// `GtkLabel`). The codegen uses both: `id` is passed to
/// `bindTemplateChildFull` / `getTemplateChild`; `typeName`
/// is the declared type of the `late final` field and the
/// argument to `typeFromName(...)`.
class TemplateChildSpec {
  const TemplateChildSpec({required this.id, required this.typeName});

  final String id;
  final String typeName;
}

/// One callback from the user's class.
///
/// `callbackName` is the `snake_case` form GTK looks up in
/// the template XML; `methodName` is the Dart method on the
/// user class. Captured for diagnostics and for any future
/// `bindTemplateCallbackFull`-based bridge, but the
/// trampoline uses the per-instance `connectSignal` path
/// instead.
class TemplateCallbackSpec {
  const TemplateCallbackSpec({
    required this.callbackName,
    required this.methodName,
  });

  final String callbackName;
  final String methodName;
}

/// One signal binding extracted from the template XML.
///
/// The template XML's `<signal name="X" handler="Y"/>` element
/// is a child of an `<object class="T" id="Z">`. The codegen
/// wires the signal to the user's instance method via the
/// per-instance `onX` method on the typed child widget (e.g.
/// `GtkButton.onClicked(void Function() callback)`).
///
/// `signalName` is the GIR-level signal name (e.g. `clicked`).
/// `childId` is the widget id from the parent `<object>`;
/// `childType` is the Dart class (e.g. `GtkButton`).
/// `methodName` is the Dart method on the user class
/// (`<snake_case>` → `<camelCase>` of the XML `handler`).
class SignalBinding {
  const SignalBinding({
    required this.signalName,
    required this.childId,
    required this.childType,
    required this.methodName,
  });

  final String signalName;
  final String childId;
  final String childType;
  final String methodName;
}

/// Resolved input to the codegen. The scanner produces a
/// `ClassTemplatePlan`; the Builder's `build()` resolves the
/// template XML (from inline content or by reading the
/// package-root file) and packages it together with the
/// parent type into a `CodegenInput`.
class CodegenInput {
  const CodegenInput({
    required this.className,
    required this.parentType,
    required this.xmlString,
    required this.children,
    required this.callbacks,
    required this.signals,
    this.partOfPath = 'app.dart',
  });

  /// Build a `CodegenInput` from a `ClassTemplatePlan` plus
  /// the resolved XML and the children / signal lists
  /// extracted from the XML. The plan's `callbacks` list is
  /// forwarded unchanged; the plan's `children` list (from
  /// `@GtkTemplateChild` annotations) is **not** consulted
  /// in the first cut — the XML is the source of truth.
  ///
  /// [partOfPath] is the basename of the user file the
  /// generated mixin will be a `part of`. The user file
  /// declares `part '<partOfPath>.<className>.g.dart';` and
  /// the generated file is `part of '<partOfPath>';`, so the
  /// mixin lives in the same library as the user's class.
  /// Sharing the library is what lets the trampoline resolve
  /// the user's instance method names at compile time
  /// without dynamic casts.
  factory CodegenInput.fromPlan(
    ClassTemplatePlan plan, {
    required String xmlString,
    required List<TemplateChildSpec> xmlChildren,
    required List<SignalBinding> xmlSignals,
    required String partOfPath,
  }) {
    return CodegenInput(
      className: plan.className,
      parentType: plan.parentType,
      xmlString: xmlString,
      children: xmlChildren,
      callbacks: plan.callbacks
          .map(
            (cb) => TemplateCallbackSpec(
              callbackName: cb.callbackName,
              methodName: cb.methodName,
            ),
          )
          .toList(),
      signals: xmlSignals,
      partOfPath: partOfPath,
    );
  }

  final String className;
  final String parentType;
  final String xmlString;
  final List<TemplateChildSpec> children;
  final List<TemplateCallbackSpec> callbacks;
  final List<SignalBinding> signals;

  /// Basename (no directory) of the user file the generated
  /// mixin is a `part of`. Required.
  final String partOfPath;
}

/// Pure: turns a single [input] into a Dart source string.
///
/// The emitted file is a `part of` the user's library. See
/// [codegenLibrary] for the multi-class form — the builder
/// always uses that one, because a source file may carry more
/// than one `@GtkTemplate` class and the part file name must
/// stay derivable from the source file name alone.
String codegenMixin(CodegenInput input) => codegenLibrary([input]);

/// Pure: turns every [inputs] belonging to one source file into
/// a single Dart source string — one part file per input file.
///
/// The emitted file is a `part of '<input>.dart';` and holds
/// one `mixin _$<Class>Template` per annotated class, plus the
/// shared `_TemplateChildSpec` helper.
///
/// One part file per source file (rather than one per class)
/// is what makes the part name derivable from the source file
/// name alone — `todo_window.dart` → `todo_window.g.dart` —
/// the same convention `json_serializable` uses. The user
/// writes one `part 'todo_window.g.dart';` line and never has
/// to know the generated class names.
String codegenLibrary(List<CodegenInput> inputs) {
  if (inputs.isEmpty) {
    throw ArgumentError.value(inputs, 'inputs', 'must not be empty');
  }
  final buffer = StringBuffer();
  final partOfPath = inputs.first.partOfPath;
  for (final input in inputs) {
    if (input.partOfPath != partOfPath) {
      throw ArgumentError.value(
        input.partOfPath,
        'inputs',
        'every input in a part file must share the same partOfPath '
            '(got `$partOfPath` and `${input.partOfPath}`)',
      );
    }
  }

  // ---- header ---------------------------------------------------------
  buffer
    ..writeln('// GENERATED by gtk_templates_builder. Do not edit by hand.')
    ..writeln('// Source:  ${partOfPath.replaceAll('.dart', '')}')
    ..writeln('// Classes: ${inputs.map((i) => i.className).join(', ')}')
    ..writeln('//')
    ..writeln('// ignore_for_file: type=lint')
    ..writeln()
    ..writeln("part of '$partOfPath';")
    ..writeln();

  // ---- shared spec class ----------------------------------------------
  // Emitted once per part file; every mixin in the file uses it.
  buffer
    ..writeln('class _TemplateChildSpec {')
    ..writeln('  const _TemplateChildSpec(this.id, this.typeName);')
    ..writeln('  final String id;')
    ..writeln('  final String typeName;')
    ..writeln('}')
    ..writeln();

  for (final input in inputs) {
    _emitMixin(buffer, input);
  }

  return buffer.toString();
}

/// Formats [source] the way `dart format` would.
///
/// The builder writes its output **next to the user's source**, so
/// the generated part file has to be `dart format`-clean: running
/// `dart format .` over a consumer's package must be a no-op, or the
/// generated file and the checked-in copy would drift apart on every
/// rebuild.
///
/// [codegenLibrary] stays pure string assembly — it is the *builder*
/// and the CLI that run the result through this. Keeping the two
/// apart means the codegen can be asserted on without a formatter in
/// the way, and the formatted output can be asserted on separately.
///
/// The formatter is the same one `dart format` uses, so the two
/// cannot disagree.
String formatGeneratedSource(String source) {
  return DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
      .format(source);
}

/// Emits one class's XML constant, children list and mixin
/// into [buffer].
void _emitMixin(StringBuffer buffer, CodegenInput input) {
  final className = input.className;
  final xmlConstName = '_\$${className}Template_xml';
  final childrenListName = '_\$${className}Template_children';
  final mixinName = '_\$${className}Template';

  // ---- XML constant ---------------------------------------------------
  buffer
    ..writeln("const String $xmlConstName = '''")
    ..write(input.xmlString)
    ..writeln("''';")
    ..writeln();

  // ---- children list --------------------------------------------------
  buffer.writeln('const List<_TemplateChildSpec> $childrenListName = [');
  for (final c in input.children) {
    buffer.writeln("  _TemplateChildSpec('${c.id}', '${c.typeName}'),");
  }
  buffer
    ..writeln('];')
    ..writeln();

  // ---- the mixin ------------------------------------------------------
  buffer.writeln('mixin $mixinName on ${input.parentType} {');
  buffer.writeln('  // Class-level state, computed once on first instance.');
  buffer.writeln('  static bool _classInitialized = false;');
  buffer.writeln('  static late final GBytes _templateBytes;');
  buffer.writeln();
  buffer.writeln('  static GBytes _ensureClassInit(int widgetType) {');
  buffer.writeln('    if (_classInitialized) return _templateBytes;');
  buffer.writeln('    _classInitialized = true;');
  buffer.writeln(
    '    // GTK validates the `<template>` attributes against the',
  );
  buffer.writeln(
    "    // widget's native type. A Dart subclass has no GType of its",
  );
  buffer.writeln('    // own, so they are rewritten to the type the instance');
  buffer.writeln('    // really has.');
  buffer.writeln(
    '    _templateBytes = gbytesFromString('
    'prepareTemplateXml($xmlConstName, widgetType));',
  );
  buffer.writeln('    return _templateBytes;');
  buffer.writeln('  }');
  buffer.writeln();
  buffer.writeln('  // Per-instance init. Idempotent.');
  buffer.writeln('  bool _instanceInitialized = false;');
  buffer.writeln();
  buffer.writeln("  /// Builds the template for this widget.");
  buffer.writeln('  ///');
  buffer.writeln("  /// GTK builds a widget's template in the instance");
  buffer.writeln('  /// initializer. Dart has no instance-initializer hook,');
  buffer.writeln('  /// so call this from the widget\'s constructor:');
  buffer.writeln('  ///');
  buffer.writeln('  /// ```dart');
  buffer.writeln('  /// $className(super.app) {');
  buffer.writeln('  ///   initTemplate();');
  buffer.writeln('  /// }');
  buffer.writeln('  /// ```');
  buffer.writeln('  ///');
  buffer.writeln('  /// Calling it more than once is safe — only the first');
  buffer.writeln('  /// call builds the template.');
  buffer.writeln('  @override');
  buffer.writeln('  void initTemplate() {');
  buffer.writeln('    if (_instanceInitialized) return;');
  buffer.writeln('    _instanceInitialized = true;');
  buffer.writeln('    final widget = this as GtkWidget;');
  buffer.writeln('    final widgetType = widgetTypeOf(widget);');
  buffer.writeln('    final widgetClass = getWidgetClass(widget);');
  buffer.writeln('    if (widgetClass == null) {');
  buffer.writeln('      throw StateError(');
  buffer.writeln(
    "        'gtk_templates: could not resolve widget class for "
    '\$runtimeType\',',
  );
  buffer.writeln('      );');
  buffer.writeln('    }');
  buffer.writeln(
    '    // The template lives on the *native* class and GTK allows',
  );
  buffer.writeln(
    '    // exactly one per class, so install it once no matter how',
  );
  buffer.writeln('    // many instances the Dart class creates.');
  buffer.writeln("    if (claimTemplateType(widgetType, '$className')) {");
  buffer.writeln(
    '      widgetClass.setTemplate(_ensureClassInit(widgetType));',
  );
  buffer.writeln('      for (final child in $childrenListName) {');
  buffer.writeln(
    '        widgetClass.bindTemplateChildFull(child.id, false, 0);',
  );
  buffer.writeln('      }');
  buffer.writeln('    }');
  buffer.writeln('    super.initTemplate();');
  if (input.signals.isNotEmpty) {
    buffer.writeln('    _wireSignals();');
  }
  buffer.writeln('  }');
  buffer.writeln();
  buffer.writeln('  /// Builds the template if the host never called');
  buffer.writeln('  /// [initTemplate].');
  buffer.writeln('  ///');
  buffer.writeln('  /// A widget whose template is built lazily shows up');
  buffer.writeln('  /// empty until something touches it, so calling');
  buffer.writeln('  /// [initTemplate] from the constructor is the supported');
  buffer.writeln('  /// way to use a template. This is the safety net.');
  buffer.writeln('  void _ensureInstanceInit() {');
  buffer.writeln('    if (_instanceInitialized) return;');
  buffer.writeln('    initTemplate();');
  buffer.writeln('  }');
  buffer.writeln();

  // ---- per-child late final fields -----------------------------------
  for (final c in input.children) {
    buffer.writeln('  late final ${c.typeName} ${c.id} = () {');
    buffer.writeln('    _ensureInstanceInit();');
    // `getTemplateChild` wants the type that *declared* the child —
    // the widget's own native type — not the child's type.
    buffer.writeln(
      '    final raw = (this as GtkWidget).getTemplateChild('
      "widgetTypeOf(this as GtkWidget), '${c.id}');",
    );
    // `cast<T>(factory)` lives on every generated wrapper;
    // pass the wrapper's `fromPointer` constructor.
    buffer.writeln(
      "    return raw.cast<${c.typeName}>(${c.typeName}.fromPointer);",
    );
    buffer.writeln('  }();');
    buffer.writeln();
  }

  // ---- signal wiring ----------------------------------------------------
  // The XML carries `<signal name="X" handler="Y"/>` entries
  // inside `<object class="T" id="Z">` parents. After
  // `initTemplate()`, the per-instance closure captures
  // `this` and dispatches to the user's `<methodName>()`.
  // The user-facing method signature must match the
  // GIR-declared signal arity (e.g. `clicked` on `GtkButton`
  // is `void Function()`; the user's method is also
  // `void Function()`). One `connectSignal` call per signal.
  if (input.signals.isNotEmpty) {
    buffer.writeln('  void _wireSignals() {');
    for (final s in input.signals) {
      final signalCap = s.signalName.isEmpty
          ? s.signalName
          : '${s.signalName[0].toUpperCase()}${s.signalName.substring(1)}';
      // Dispatch through `(this as dynamic).<methodName>()`
      // so the user's instance method resolves correctly
      // when the mixin is applied. A bare name would not
      // resolve in the mixin's analyzer context (the parent
      // type doesn't declare it), and even a `this.X` call
      // would fail because the mixin is `on ParentType` and
      // the analyzer rejects unknown members on the
      // constraint. `dynamic` defers the call to the runtime
      // class's method table without giving up the static
      // type analysis on the rest of the mixin.
      buffer.writeln(
        '    ${s.childId}.on$signalCap('
        '() => (this as dynamic).${s.methodName}());',
      );
    }
    buffer.writeln('  }');
    buffer.writeln();
  }

  buffer.writeln('}');
  buffer.writeln();
}

/// The basename of the generated part file for the source file
/// [sourceBasename].
///
/// One part file per source file: `todo_window.dart` →
/// `todo_window.g.dart`. The name is derivable from the source
/// file name alone, so the user never has to predict a
/// class-derived name — the same convention `json_serializable`
/// uses.
String partFileBasename(String sourceBasename) {
  final dot = sourceBasename.lastIndexOf('.');
  final stem = dot < 0 ? sourceBasename : sourceBasename.substring(0, dot);
  return '$stem.g.dart';
}

/// Checks that [source] declares the `part` directive that pulls
/// in the generated file [partBasename].
///
/// Returns `null` when the directive is present, or a
/// human-readable diagnostic naming the exact line to add when
/// it is missing or stale. The check is pure so the builder and
/// the CLI can share it and so it can be unit-tested without a
/// build.
String? checkPartDirective(String source, String partBasename) {
  final pattern = RegExp(
    r'''^\s*part\s+['"]([^'"]+)['"]\s*;''',
    multiLine: true,
  );
  final declared = <String>[];
  for (final m in pattern.allMatches(source)) {
    declared.add(m.group(1)!);
  }
  if (declared.contains(partBasename)) return null;

  final stale = declared.isEmpty
      ? 'it declares no `part` directive at all'
      : 'it declares ${declared.map((d) => "`part '$d';`").join(', ')}, '
            'which does not match the generated file';
  return 'gtk_templates: the source file has no `part` directive for the '
      'generated mixin ($stale).\n'
      'Add this line after the last import:\n\n'
      "    part '$partBasename';\n";
}

/// The FFI binding package that declares [typeName].
///
/// Today the scope is small:
///   - `Adw*` → `package:adw/adw.dart`
///   - everything else → `package:gtk4/gtk4.dart`
String packageForType(String typeName) {
  if (typeName.startsWith('Adw')) return 'package:adw/adw.dart';
  return 'package:gtk4/gtk4.dart';
}

/// The import paths the generated part file needs in scope.
///
/// The generated file is a `part of` the user's library, so it
/// inherits that library's imports — it cannot bring its own.
/// The code it emits references:
///
///   - `GtkWidget`, `getWidgetClass` — `package:gtk4/gtk4.dart`
///   - `gbytesFromString`, `widgetTypeOf`, `prepareTemplateXml`,
///     `claimTemplateType`, `GBytes` —
///     `package:gtk_templates/gtk_templates.dart`
///   - the parent widget type and every child type — the
///     package that declares them.
///
/// [typeNames] carries the parent type and the child types.
Set<String> requiredImports(Iterable<String> typeNames) {
  final packages = <String>{
    'package:gtk4/gtk4.dart',
    'package:gtk_templates/gtk_templates.dart',
  };
  for (final typeName in typeNames) {
    packages.add(packageForType(typeName));
  }
  return packages;
}

/// Checks that [source] imports every package the generated part
/// file needs.
///
/// Returns the list of missing import paths, empty when nothing
/// is missing. A `part of` file inherits its library's imports
/// and cannot declare its own, so a missing import would surface
/// as an "undefined name" error in the *generated* file — far
/// from the cause. Checking up front turns that into an
/// actionable message.
List<String> checkRequiredImports(String source, Iterable<String> typeNames) {
  final missing = <String>[];
  for (final package in requiredImports(typeNames)) {
    if (!source.contains("'$package'")) {
      missing.add(package);
    }
  }
  return missing;
}

/// A tag found by [_scanTags].
class _Tag {
  _Tag(
    this.name,
    this.attributes, {
    this.closing = false,
    this.selfClosing = false,
  });

  /// The element name, e.g. `object`.
  final String name;

  /// The element's attributes, in source order.
  final Map<String, String> attributes;

  /// Whether this is a closing tag (`</name>`).
  final bool closing;

  /// Whether this is a self-closing tag (`<name/>`).
  final bool selfClosing;
}

/// Scans the XML tags in [xml].
///
/// A tag scanner rather than a set of per-shape regexes: the
/// template XML nests, and a regex cannot tell which `<object>`
/// a `<signal>` belongs to when the objects are nested or
/// self-closing.
Iterable<_Tag> _scanTags(String xml) sync* {
  final tagRe = RegExp(
    r'''<(/?)([A-Za-z][A-Za-z0-9_.-]*)((?:"[^"]*"|'[^']*'|[^>"'])*?)(/?)>''',
  );
  final attrRe = RegExp(r'''([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*"([^"]*)"''');
  for (final m in tagRe.allMatches(xml)) {
    final attributes = <String, String>{};
    for (final a in attrRe.allMatches(m.group(3) ?? '')) {
      attributes[a.group(1)!] = a.group(2)!;
    }
    yield _Tag(
      m.group(2)!,
      attributes,
      closing: m.group(1) == '/',
      selfClosing: m.group(4) == '/',
    );
  }
}

/// Extracts `<object class="X" id="Y">` (or self-closing)
/// entries from [xml].
///
/// The codegen only needs the class name and the id. Nested
/// `<object>`s (children of a top-level object) are also
/// captured, matching what `bindTemplateChildFull` actually
/// binds: every `id` is reachable.
///
/// Returned order matches the source order, which is what
/// the codegen uses to keep generated code stable across
/// regenerations.
List<TemplateChildSpec> extractChildrenFromXml(String xml) {
  final result = <TemplateChildSpec>[];
  for (final tag in _scanTags(xml)) {
    if (tag.closing || tag.name != 'object') continue;
    final typeName = tag.attributes['class'];
    final id = tag.attributes['id'];
    if (typeName == null || id == null) continue;
    result.add(TemplateChildSpec(id: id, typeName: typeName));
  }
  return result;
}

/// Extracts `<signal name="X" handler="Y"/>` entries from
/// [xml] together with the parent `<object>` (its `id` and
/// `class`). The codegen needs all three: the signal name to
/// pick the `onX` method on the child, the child id to look up
/// the typed widget, the child type to qualify the method,
/// and the handler (snake_case) to derive the user's Dart
/// method name.
///
/// A signal belongs to the nearest enclosing `<object>` that
/// carries an `id` — GTK's own rule. The scan keeps a stack of
/// the open `<object>` elements so nesting and self-closing
/// tags are handled correctly.
///
/// Returns the signals in source order, which the codegen
/// preserves for stable generation across regenerations.
List<SignalBinding> extractSignalsFromXml(String xml) {
  final result = <SignalBinding>[];
  // The open `<object>` elements, innermost last. A `null` entry
  // is an object without an `id` — it cannot be a template child,
  // but it still has to be tracked so the closing tags stay
  // balanced.
  final stack = <({String? typeName, String? id})>[];
  for (final tag in _scanTags(xml)) {
    if (tag.name == 'object') {
      if (tag.closing) {
        if (stack.isNotEmpty) stack.removeLast();
      } else if (!tag.selfClosing) {
        stack.add((
          typeName: tag.attributes['class'],
          id: tag.attributes['id'],
        ));
      }
      continue;
    }
    if (tag.name != 'signal' || tag.closing) continue;
    final signalName = tag.attributes['name'];
    final handler = tag.attributes['handler'];
    if (signalName == null || handler == null) continue;
    for (final entry in stack.reversed) {
      final typeName = entry.typeName;
      final id = entry.id;
      if (typeName == null || id == null) continue;
      result.add(
        SignalBinding(
          signalName: signalName,
          childId: id,
          childType: typeName,
          methodName: snakeCaseToCamel(handler),
        ),
      );
      break;
    }
  }
  return result;
}

/// `snake_case` → `camelCase`. The XML `handler` attribute is
/// the snake-case form (`on_clicked`); the user's Dart
/// method is the camelCase form (`onClicked`).
String snakeCaseToCamel(String s) {
  if (s.isEmpty) return s;
  final parts = s.split('_');
  final head = parts.first;
  final tail = parts
      .skip(1)
      .map((p) => p.isEmpty ? '' : '${p[0].toUpperCase()}${p.substring(1)}');
  return '$head${tail.join()}';
}
