// Drives the **real** `build_runner` builder over a source file
// and proves the produced asset type-checks.
//
// `test/codegen_test.dart` tests the codegen function in
// isolation; `test/generated_code_test.dart` tests the generated
// code. This file closes the loop: the builder is the thing users
// actually run, and it is the thing that decides *where* the
// output lands, whether the `part` directive is present, and
// whether the library imports what the generated code needs.
//
// The builder runs against in-memory assets here, so the template
// XML is inline (`GtkTemplateXml`) rather than a file — the
// `GtkTemplateFile` path is resolved against the real filesystem,
// which a `build_test` harness does not provide.

import 'package:build_test/build_test.dart';
import 'package:test/test.dart';

import 'package:gtk_templates_builder/gtk_templates_builder.dart';

import 'support/probe.dart';

/// The inline template XML.
const _xml = '''<interface>
  <template class="Probe" parent="GtkApplicationWindow">
    <child>
      <object class="GtkLabel" id="counterLabel"/>
      <object class="GtkButton" id="button">
        <signal name="clicked" handler="on_clicked"/>
      </object>
    </child>
  </template>
</interface>''';

/// A library with an inline template, a child and a signal.
///
/// The XML is a raw string literal, so the scanner sees a plain
/// string literal argument — which is what `GtkTemplateXml`
/// requires.
const _library =
    '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'probe.g.dart';

@GtkTemplate(source: GtkTemplateXml(r"""$_xml"""))
class Probe extends GtkApplicationWindow with _\$ProbeTemplate {
  Probe(super.app) {
    initTemplate();
  }

  void onClicked() {
    counterLabel.props.label = 'Clicked!';
  }
}
''';

/// Reads the content of the generated asset whose path ends with
/// [suffix], or `null` when the builder wrote no such file.
///
/// The tests run the builder with `flattenOutput: true`, so the
/// generated file is readable at its package path
/// (`pkg|lib/probe.g.dart`) rather than under the artifact tree.
Future<String?> _readOutput(TestBuilderResult result, String suffix) async {
  for (final assetId in result.outputs) {
    if (!assetId.path.endsWith(suffix)) continue;
    return result.readerWriter.readAsString(assetId);
  }
  return null;
}

void main() {
  group('the builder produces a part file that type-checks', () {
    test('the generated asset resolves with no diagnostics', () async {
      final logs = <String>[];
      final result = await testBuilder(
        const GtkTemplatesBuilder(),
        <String, Object>{'pkg|lib/probe.dart': _library},
        generateFor: <String>{'pkg|lib/probe.dart'},
        onLog: (record) => logs.add(record.toString()),
        flattenOutput: true,
      );

      final generated = await _readOutput(result, 'probe.g.dart');
      expect(
        generated,
        isNotNull,
        reason:
            'the builder must write a part file next to its input; '
            'logs:\n${logs.join('\n')}',
      );

      // The part file must declare itself a part of the library,
      // and name the input file — not the class.
      expect(generated, contains("part of 'probe.dart';"));
      expect(
        generated,
        contains('mixin _\$ProbeTemplate on GtkApplicationWindow'),
      );
      expect(generated, contains('late final GtkLabel counterLabel = '));
      expect(generated, contains('late final GtkButton button = '));
      // The trampoline.
      expect(
        generated,
        contains('button.onClicked(() => (this as dynamic).onClicked())'),
      );
      // `_wireSignals()` must be *called*, not just declared.
      expect(generated, contains('    _wireSignals();'));

      // And the whole thing must resolve.
      final diagnostics = await analyzeProbe(
        librarySource: _library,
        partSource: generated!,
      );
      expect(
        diagnostics,
        isEmpty,
        reason:
            'the builder output must resolve cleanly, but the '
            'analyzer reported:\n${formatDiagnostics(diagnostics)}',
      );
    });

    test('two annotated classes share one part file', () async {
      const twoClasses = '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'probe.g.dart';

@GtkTemplate(source: GtkTemplateXml('<interface/>'))
class First extends GtkBox with _\$FirstTemplate {
  First();
}

@GtkTemplate(source: GtkTemplateXml('<interface/>'))
class Second extends GtkBox with _\$SecondTemplate {
  Second();
}
''';
      final result = await testBuilder(
        const GtkTemplatesBuilder(),
        <String, Object>{'pkg|lib/probe.dart': twoClasses},
        generateFor: <String>{'pkg|lib/probe.dart'},
        flattenOutput: true,
      );

      final generated = await _readOutput(result, 'probe.g.dart');
      expect(generated, isNotNull);
      expect(generated, contains('mixin _\$FirstTemplate on GtkBox'));
      expect(generated, contains('mixin _\$SecondTemplate on GtkBox'));
      // Exactly one `part of` — one part file, two mixins.
      expect('part of '.allMatches(generated!).length, 1);
    });
  });

  group('the builder writes format-clean output', () {
    // The builder writes the part file *next to* the user's source, so
    // it lives in the consumer's package. If it were not `dart
    // format`-clean, every consumer running `dart format .` would
    // immediately see a diff against the checked-in generated file —
    // and every rebuild would revert it.
    //
    // `dart format` is idempotent, so "the formatted output is a fixed
    // point of the formatter" is exactly "the output is format-clean".
    test('the generated asset is a fixed point of the formatter', () async {
      final result = await testBuilder(
        const GtkTemplatesBuilder(),
        <String, Object>{'pkg|lib/probe.dart': _library},
        generateFor: <String>{'pkg|lib/probe.dart'},
        flattenOutput: true,
      );

      final generated = await _readOutput(result, 'probe.g.dart');
      expect(generated, isNotNull);
      expect(
        formatGeneratedSource(generated!),
        generated,
        reason:
            'the builder output must be `dart format`-clean, so that '
            'running `dart format .` in the consumer package is a no-op',
      );
    });
  });

  group('the builder fails with an actionable message', () {
    test('a missing part directive is reported', () async {
      const noPart = '''
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

@GtkTemplate(source: GtkTemplateXml('<interface/>'))
class Probe extends GtkBox with _\$ProbeTemplate {
  Probe();
}
''';
      final logs = <String>[];
      await testBuilder(
        const GtkTemplatesBuilder(),
        <String, Object>{'pkg|lib/probe.dart': noPart},
        generateFor: <String>{'pkg|lib/probe.dart'},
        onLog: (record) => logs.add(record.toString()),
        flattenOutput: true,
      );

      final messages = logs.join('\n');
      expect(
        messages,
        contains("part 'probe.g.dart';"),
        reason: 'the diagnostic must name the exact line to add',
      );
    });

    test('a missing import is reported', () async {
      // The generated mixin calls `gbytesFromString`, `getWidgetClass`,
      // `widgetTypeOf`, `prepareTemplateXml` and `claimTemplateType` —
      // all of them live in `package:gtk_templates`. The part file
      // inherits its library's imports, so the library must import it.
      const noTemplates = '''
import 'package:gtk4/gtk4.dart';

part 'probe.g.dart';

@GtkTemplate(source: GtkTemplateXml('<interface/>'))
class Probe extends GtkBox with _\$ProbeTemplate {
  Probe();
}
''';
      final logs = <String>[];
      await testBuilder(
        const GtkTemplatesBuilder(),
        <String, Object>{'pkg|lib/probe.dart': noTemplates},
        generateFor: <String>{'pkg|lib/probe.dart'},
        onLog: (record) => logs.add(record.toString()),
        flattenOutput: true,
      );

      final messages = logs.join('\n');
      expect(
        messages,
        contains("import 'package:gtk_templates/gtk_templates.dart';"),
        reason: 'the diagnostic must name the exact import to add',
      );
    });
  });
}
