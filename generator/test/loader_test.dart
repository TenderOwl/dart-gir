import 'dart:io';

import 'package:gir_generator/src/gir/gir.dart';
import 'package:test/test.dart';

/// The directory the `.gir` files live in.
///
/// `GIR_DIR` points the test at another corpus — a machine that has
/// only some of the files, or a fixture directory.
final String girDir = Platform.environment['GIR_DIR'] ?? '/usr/share/gir-1.0';

/// Whether the `.gir` file of [namespace] is installed.
///
/// The directory is not all-or-nothing: the packages that ship the
/// files are separate (`gir1.2-glib-2.0`, `gir1.2-gtk-4.0`, …), so a
/// machine can have GLib's files and not GTK's. The check is
/// therefore per file — a test skips when *its* input is missing, and
/// the others still run.
bool haveGir(String namespace) => File('$girDir/$namespace.gir').existsSync();

/// The reason a test cannot run, or `null` when it can.
String? missingGir(String namespace) =>
    haveGir(namespace) ? null : '$namespace.gir is not installed at $girDir';

void main() {
  group('GirLoader', () {
    late GirLoader loader;

    setUp(() => loader = GirLoader(girDir));

    test('loads GLib-2.0', () {
      final repo = loader.load('GLib-2.0');
      expect(repo.namespace.name, 'GLib');
      expect(repo.namespace.version, '2.0');
      expect(repo.namespace.sharedLibraries, isNotEmpty);
    }, skip: missingGir('GLib-2.0'));

    test('caches repositories', () {
      final a = loader.load('GLib-2.0');
      final b = loader.load('GLib-2.0');
      expect(identical(a, b), isTrue);
    }, skip: missingGir('GLib-2.0'));

    test('include closure of Gtk-4.0 is in dependency order', () {
      // The closure is the file *and* everything it includes, so the
      // test skips when any of them is missing — not only when
      // `Gtk-4.0.gir` itself is.
      final List<GirRepository> repos;
      try {
        repos = loader.loadWithDependencies('Gtk-4.0');
      } on FileSystemException catch (error) {
        markTestSkipped('the GIR files are not installed: ${error.message}');
        return;
      }
      final names = repos.map((r) => r.namespace.name).toList();

      expect(names.last, 'Gtk');

      int indexOf(String name) {
        final i = names.indexOf(name);
        expect(i, isNonNegative, reason: '$name should be in the closure');
        return i;
      }

      expect(indexOf('GLib'), lessThan(indexOf('GObject')));
      expect(indexOf('GObject'), lessThan(indexOf('Gtk')));

      for (final repo in repos) {
        final self = names.indexOf(repo.namespace.name);
        for (final include in repo.includes) {
          final dep = names.indexOf(include.name);
          expect(
            dep,
            lessThan(self),
            reason: '${include.name} should come before ${repo.namespace.name}',
          );
        }
      }
    });

    test('Gtk.Button exists with parent Gtk.Widget', () {
      final repo = loader.load('Gtk-4.0');
      final button = repo.namespace.classes
          .where((c) => c.name == 'Button')
          .firstOrNull;
      expect(button, isNotNull);
      expect(button!.parent, anyOf('Widget', 'Gtk.Widget'));
      expect(button.cType, 'GtkButton');
      expect(button.methods, isNotEmpty);
    }, skip: missingGir('Gtk-4.0'));

    test('missing GIR file throws FileSystemException', () {
      expect(
        () => loader.load('NoSuch-99.0'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
