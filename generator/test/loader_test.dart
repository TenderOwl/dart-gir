import 'dart:io';

import 'package:gir_generator/src/gir/gir.dart';
import 'package:test/test.dart';

const String girDir = '/usr/share/gir-1.0';

void main() {
  // The directory may exist (other `-dev` packages create it for
  // their own `.typelib` files) without containing any `.gir` files.
  // Skip when there are no CGC-side GIR sources to load, since the
  // loader's job is to read those.
  final available = Directory(girDir).existsSync() &&
      Directory(girDir)
          .listSync()
          .any((e) => e.path.endsWith('.gir'));

  group('GirLoader', skip: available ? null : 'no .gir files at $girDir', () {
    late GirLoader loader;

    setUp(() => loader = GirLoader(girDir));

    test('loads GLib-2.0', () {
      final repo = loader.load('GLib-2.0');
      expect(repo.namespace.name, 'GLib');
      expect(repo.namespace.version, '2.0');
      expect(repo.namespace.sharedLibraries, isNotEmpty);
    });

    test('caches repositories', () {
      final a = loader.load('GLib-2.0');
      final b = loader.load('GLib-2.0');
      expect(identical(a, b), isTrue);
    });

    test('include closure of Gtk-4.0 is in dependency order', () {
      final repos = loader.loadWithDependencies('Gtk-4.0');
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
          expect(dep, lessThan(self),
              reason: '${include.name} should come before ${repo.namespace.name}');
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
    });

    test('missing GIR file throws FileSystemException', () {
      expect(() => loader.load('NoSuch-99.0'),
          throwsA(isA<FileSystemException>()));
    });
  });
}
