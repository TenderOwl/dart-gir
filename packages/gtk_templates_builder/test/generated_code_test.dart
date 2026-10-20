// Proves that the **generated** mixin type-checks.
//
// This is the test that was missing when four codegen bugs shipped
// to `main`: `_wireSignals()` was declared but never called,
// `cast<T>()` was missing its `factory` argument, the
// `package:gobject` import was missing, and the parent type's
// package was not imported.
//
// `test/codegen_test.dart` and `test/e2e_test.dart` only parse the
// generated source — a parse cannot see a missing import, a wrong
// argument count, or an unresolved member. These tests resolve it.
//
// Two layers:
//
//   1. The fixture under `test/fixtures/` is part of the package's
//      own analysis, so `dart analyze` already covers it. This
//      file asserts the same thing explicitly, so a regression is
//      reported by the test suite and not only by the analyzer.
//
//   2. A mutation table: each historical bug is re-introduced on
//      purpose and the analyzer must flag it. That proves the
//      check has teeth — a passing "no errors" assertion means
//      something.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/probe.dart';

/// The probe library: the same imports the generated code relies
/// on, plus a `part` directive.
const _probeLibrary = '''
import 'package:adw/adw.dart';
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'probe.g.dart';

class Probe extends AdwApplicationWindow with _\$ProbeTemplate {
  Probe(super.app) {
    initTemplate();
  }

  void onClicked() {}
}
''';

/// The probe part file: a trimmed-down version of what the
/// codegen emits.
const _probePart = '''
part of 'probe.dart';

class _TemplateChildSpec {
  const _TemplateChildSpec(this.id, this.typeName);
  final String id;
  final String typeName;
}

const String _\$ProbeTemplate_xml = '<interface/>';

const List<_TemplateChildSpec> _\$ProbeTemplate_children = [
  _TemplateChildSpec('button', 'GtkButton'),
];

mixin _\$ProbeTemplate on AdwApplicationWindow {
  static bool _classInitialized = false;
  static late final GBytes _templateBytes;

  static GBytes _ensureClassInit(int widgetType) {
    if (_classInitialized) return _templateBytes;
    _classInitialized = true;
    _templateBytes = gbytesFromString(
      prepareTemplateXml(_\$ProbeTemplate_xml, widgetType),
    );
    return _templateBytes;
  }

  bool _instanceInitialized = false;

  @override
  void initTemplate() {
    if (_instanceInitialized) return;
    _instanceInitialized = true;
    final widget = this as GtkWidget;
    final widgetType = widgetTypeOf(widget);
    final widgetClass = getWidgetClass(widget);
    if (widgetClass == null) {
      throw StateError('no widget class');
    }
    if (claimTemplateType(widgetType, 'Probe')) {
      widgetClass.setTemplate(_ensureClassInit(widgetType));
      for (final child in _\$ProbeTemplate_children) {
        widgetClass.bindTemplateChildFull(child.id, false, 0);
      }
    }
    super.initTemplate();
    _wireSignals();
  }

  void _ensureInstanceInit() {
    if (_instanceInitialized) return;
    initTemplate();
  }

  late final GtkButton button = () {
    _ensureInstanceInit();
    final raw = (this as GtkWidget).getTemplateChild(
      widgetTypeOf(this as GtkWidget), 'button',
    );
    return raw.cast<GtkButton>(GtkButton.fromPointer);
  }();

  void _wireSignals() {
    button.onClicked(() => (this as dynamic).onClicked());
  }
}
''';

void main() {
  group('the generated mixin type-checks', () {
    test('the on-disk fixture resolves with no errors or warnings', () async {
      final root = await packageRoot();
      final libraryPath = p.join(
        root.path,
        'test',
        'fixtures',
        'sample_window.dart',
      );
      final partPath = p.join(
        root.path,
        'test',
        'fixtures',
        'sample_window.g.dart',
      );

      final collection = AnalysisContextCollection(
        includedPaths: <String>[root.path],
      );
      try {
        final errors = await diagnosticsForLibrary(
          collection,
          libraryPath,
          partPath,
        );
        expect(
          errors,
          isEmpty,
          reason:
              'the generated mixin must resolve cleanly, but the '
              'analyzer reported:\n${formatDiagnostics(errors)}',
        );
      } finally {
        collection.dispose();
      }
    });

    test(
      'the generated part file declares itself a part of the library',
      () async {
        final root = await packageRoot();
        final part = File(
          p.join(root.path, 'test', 'fixtures', 'sample_window.g.dart'),
        );
        expect(
          await part.readAsString(),
          contains("part of 'sample_window.dart';"),
        );
      },
    );
  });

  group('the analyzer catches the historical codegen bugs', () {
    test('a clean probe resolves without diagnostics', () async {
      final diagnostics = await analyzeProbe(
        librarySource: _probeLibrary,
        partSource: _probePart,
      );
      expect(
        diagnostics,
        isEmpty,
        reason:
            'the baseline probe must be clean, but the analyzer '
            'reported:\n${formatDiagnostics(diagnostics)}',
      );
    });

    test('an uncalled _wireSignals() is flagged', () async {
      // Bug 1: the method was emitted but never invoked, so the
      // callback never fired. The analyzer sees an unused private
      // method.
      final mutated = _probePart.replaceFirst('    _wireSignals();\n', '');
      expect(mutated, isNot(equals(_probePart)), reason: 'mutation applied');

      final diagnostics = await analyzeProbe(
        librarySource: _probeLibrary,
        partSource: mutated,
      );
      expect(
        diagnostics,
        isNotEmpty,
        reason: 'an uncalled _wireSignals() must be flagged',
      );
    });

    test('a cast<T>() without its factory argument is flagged', () async {
      // Bug 2: `raw.cast<GtkLabel>()` — the generated wrapper's
      // `cast<T>` takes a `factory` argument.
      final mutated = _probePart.replaceFirst(
        'raw.cast<GtkButton>(GtkButton.fromPointer)',
        'raw.cast<GtkButton>()',
      );
      expect(mutated, isNot(equals(_probePart)), reason: 'mutation applied');

      final diagnostics = await analyzeProbe(
        librarySource: _probeLibrary,
        partSource: mutated,
      );
      expect(
        diagnostics,
        isNotEmpty,
        reason: 'a cast<T>() without its factory must be flagged',
      );
    });

    test('a missing package:gtk_templates import is flagged', () async {
      // The generated code calls `gbytesFromString`, `getWidgetClass`,
      // `widgetTypeOf`, `prepareTemplateXml` and `claimTemplateType` —
      // all of them live in `package:gtk_templates`. The part file
      // inherits its library's imports, so the library must import it.
      //
      // (This used to be the `package:gobject` import: the generated
      // code called `typeFromName` to resolve the child's type. It
      // resolves the *widget's* type now — the one that declared the
      // child — so the generated code no longer needs `gobject`.)
      final mutated = _probeLibrary.replaceFirst(
        "import 'package:gtk_templates/gtk_templates.dart';\n",
        '',
      );
      expect(mutated, isNot(equals(_probeLibrary)), reason: 'mutation applied');

      final diagnostics = await analyzeProbe(
        librarySource: mutated,
        partSource: _probePart,
      );
      expect(
        diagnostics,
        isNotEmpty,
        reason: 'a missing package:gtk_templates import must be flagged',
      );
    });

    test('a missing parent-type package import is flagged', () async {
      // Bug 4: the parent widget type (`AdwApplicationWindow`)
      // lives in `package:adw`, which the library must import.
      final mutated = _probeLibrary.replaceFirst(
        "import 'package:adw/adw.dart';\n",
        '',
      );
      expect(mutated, isNot(equals(_probeLibrary)), reason: 'mutation applied');

      final diagnostics = await analyzeProbe(
        librarySource: mutated,
        partSource: _probePart,
      );
      expect(
        diagnostics,
        isNotEmpty,
        reason: 'a missing parent-type package import must be flagged',
      );
    });
  });
}
