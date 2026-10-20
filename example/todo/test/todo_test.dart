// The consumer-side view of the part-file contract.
//
// `example/todo` is the worked example for the composite-template
// stack: it is a *real* consumer that declares `@GtkTemplate`, pulls
// the generated part file in with a `part` directive, and relies on
// the builder writing the mixin next to its source.
//
// These assertions are deliberately about the *files* rather than
// about behaviour — a GTK window needs a display. What they pin is
// the contract that makes the example work:
//
//   1. the source declares `part 'todo_window.g.dart';`
//   2. the generated file exists, next to the source
//   3. the generated file declares itself a part of that source
//
// Point 2 is the one that breaks most easily: `build_to: source` has
// to be set in the *provider* package's `build.yaml`, or the mixin
// lands in `.dart_tool/build/generated/` where the `part` directive
// cannot resolve it.
//
// Run with:
//   dart run build_runner build && dart test

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The package root — the directory holding this package's
/// `pubspec.yaml`.
///
/// The suite runs both from the workspace root (`dart test
/// example/todo`) and from the package directory (`cd example/todo &&
/// dart test`), so the paths have to be resolved against the package
/// rather than against the current working directory.
Future<Directory> _packageRoot() async {
  final uri = await Isolate.resolvePackageUri(
    Uri.parse('package:todo/_probe.dart'),
  );
  if (uri == null) {
    throw StateError('cannot resolve the `todo` package');
  }
  // <root>/example/todo/lib/_probe.dart → <root>/example/todo
  return File.fromUri(uri).parent.parent;
}

void main() {
  late Directory root;
  late File source;
  late File generated;

  setUpAll(() async {
    root = await _packageRoot();
    source = File('${root.path}/lib/todo_window.dart');
    generated = File('${root.path}/lib/todo_window.g.dart');
  });

  group('the part-file contract', () {
    test('the source declares the part directive', () {
      expect(source.readAsStringSync(), contains("part 'todo_window.g.dart';"));
    });

    test('the generated part file sits next to its source', () {
      expect(
        generated.existsSync(),
        isTrue,
        reason:
            'the builder must write the mixin next to its source; run '
            '`dart run build_runner build` first',
      );
    });

    test('the generated part file declares itself a part of the source', () {
      final text = generated.readAsStringSync();
      expect(text, contains("part of 'todo_window.dart';"));
      // It is a `part of`, so it inherits the library's imports and
      // must not declare its own.
      expect(text, isNot(contains("import 'package:")));
    });

    test('the generated part file holds the mixin for the annotated class', () {
      final text = generated.readAsStringSync();
      expect(
        text,
        contains('mixin _\$TodoWindowTemplate on AdwApplicationWindow'),
      );
    });
  });
}
