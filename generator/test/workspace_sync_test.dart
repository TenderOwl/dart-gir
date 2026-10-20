// Tests for `syncRootPubspec` — the generator rewrites the root
// pubspec's `workspace:` list every time it runs.
//
// The list has to be *discovered*, not hard-coded: the repository
// holds packages under `packages/`, `generator/` and `example/`, and
// the set changes as packages are added. Two rules matter:
//
//   - a package nested inside another package's directory is not a
//     member (Dart's workspace refuses it), and
//   - hidden directories — `.dart_tool/pub/packages/…` is pub's own
//     cache of the workspace — are not packages.

import 'dart:io';

import 'package:gir_generator/src/emit/library_emitter.dart';
import 'package:test/test.dart';

/// Creates a package directory (a directory holding a `pubspec.yaml`)
/// at [path], relative to [root].
void _makePackage(Directory root, String path) {
  Directory('${root.path}/$path').createSync(recursive: true);
  File('${root.path}/$path/pubspec.yaml')
      .writeAsStringSync('name: ${path.split('/').last}\n');
}

void main() {
  late Directory root;
  late File pubspec;

  setUp(() {
    root = Directory.systemTemp.createTempSync('gir_workspace_');
    pubspec = File('${root.path}/pubspec.yaml');
    pubspec.writeAsStringSync('''
name: dart_gir
publish_to: none

environment:
  sdk: ^3.13.4

workspace:
  - generator

dev_dependencies:
  test: ^1.32.0
''');
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The `workspace:` entries of the rewritten root pubspec.
  List<String> workspaceEntries() {
    final lines = pubspec.readAsLinesSync();
    final start = lines.indexOf('workspace:');
    expect(start, isNot(-1), reason: 'the workspace section must survive');
    final out = <String>[];
    for (final line in lines.skip(start + 1)) {
      if (!line.startsWith('  - ')) break;
      out.add(line.substring(4));
    }
    return out;
  }

  test('every package in the tree is listed', () {
    _makePackage(root, 'generator');
    _makePackage(root, 'packages/glib');
    _makePackage(root, 'packages/gtk4');
    _makePackage(root, 'example/notepad');
    _makePackage(root, 'example/todo');

    syncRootPubspec(root.path);

    expect(
      workspaceEntries(),
      containsAll(['generator', 'packages/glib', 'packages/gtk4']),
    );
    expect(workspaceEntries(), contains('example/notepad'));
    expect(workspaceEntries(), contains('example/todo'));
  });

  test('the list is replaced, not appended to', () {
    _makePackage(root, 'generator');
    syncRootPubspec(root.path);
    syncRootPubspec(root.path);

    final entries = workspaceEntries();
    expect(entries.where((e) => e == 'generator'), hasLength(1));
    expect(entries.toSet(), hasLength(entries.length));
  });

  test('a package nested inside another package is not listed', () {
    // Dart's workspace refuses a member nested inside another
    // member's directory — listing both would break `dart pub get`.
    _makePackage(root, 'packages/glib');
    _makePackage(root, 'packages/glib/nested');

    syncRootPubspec(root.path);

    expect(workspaceEntries(), contains('packages/glib'));
    expect(workspaceEntries(), isNot(contains('packages/glib/nested')));
  });

  test('hidden directories are not packages', () {
    // `.dart_tool/pub/packages/…` is pub's own cache of the
    // workspace — it mirrors the real package layout.
    _makePackage(root, 'packages/glib');
    _makePackage(root, '.dart_tool/pub/packages/glib');
    _makePackage(root, '.git/somewhere');

    syncRootPubspec(root.path);

    expect(workspaceEntries(), contains('packages/glib'));
    expect(workspaceEntries().where((e) => e.contains('.dart_tool')), isEmpty);
    expect(workspaceEntries().where((e) => e.contains('.git')), isEmpty);
  });

  test('the root package is not a member of its own list', () {
    _makePackage(root, 'generator');
    syncRootPubspec(root.path);
    expect(workspaceEntries(), isNot(contains('')));
  });

  test('the rest of the root pubspec is left alone', () {
    _makePackage(root, 'generator');
    syncRootPubspec(root.path);

    final text = pubspec.readAsStringSync();
    expect(text, contains('name: dart_gir'));
    expect(text, contains('publish_to: none'));
    expect(text, contains('dev_dependencies:'));
  });
}
