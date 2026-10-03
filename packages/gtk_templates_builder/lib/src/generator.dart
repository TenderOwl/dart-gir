/// The build_runner Generator that walks each library element and
/// emits the `*.gtk_templates.dart` part file content.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'emitter.dart';
import 'visitors.dart';

class GtkTemplatesGenerator extends Generator {
  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final visitor = GtkTemplatesVisitor();
    final classes = visitor.visit(library.element);
    if (classes.isEmpty) return null;
    final sourcePath = buildStep.inputId.path;
    final emitter = Emitter(sourcePath);
    return emitter.emit(classes);
  }
}