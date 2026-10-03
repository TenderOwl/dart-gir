/// `build_runner` builder factory for `package:gtk_templates`.
///
/// We use a plain `Builder` (not `source_gen.PartBuilder`) because
/// `PartBuilder` writes to a staging dir under `.dart_tool/build/`
/// and depends on `source_gen`'s `combining_builder` post-process to
/// promote the output to the source tree. In `build_runner` 2.4.x,
/// that post-process is gated on `hideOutput: true` chain markers
/// that source_gen doesn't emit on a single PartBuilder — so the
/// file stays in the staging dir and `dart analyze` can't find it.
/// A plain Builder writes directly to the path computed from
/// `buildStep.allowedOutputs.first`.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'generator.dart';

Builder gtkTemplatesBuilder(BuilderOptions options) {
  return _GtkTemplatesBuilder();
}

class _GtkTemplatesBuilder extends Builder {
  @override
  final buildExtensions = const {
    '.dart': ['.gtk_templates.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    // Read the input library so we can resolve annotated classes via
    // the analyzer — same approach source_gen.PartBuilder uses.
    final lib = await buildStep.resolver
        .libraryFor(buildStep.inputId, allowSyntaxErrors: true);
    final generator = GtkTemplatesGenerator();
    final generated = await generator.generate(
      LibraryReader(lib),
      buildStep,
    );
    if (generated == null) return;
    final outputId = buildStep.allowedOutputs.first;
    await buildStep.writeAsString(outputId, generated);
  }
}