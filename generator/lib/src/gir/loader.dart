import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'parser.dart';

/// Loads GIR repositories from a directory of `.gir` files, resolving
/// `<include>` dependencies transitively.
class GirLoader {
  GirLoader(this.girDir, {GirParser? parser}) : _parser = parser ?? GirParser();

  final String girDir;
  final GirParser _parser;
  final Map<String, GirRepository> _cache = {};

  String pathFor(String nameVersion) => p.join(girDir, '$nameVersion.gir');

  /// Loads and caches a repository by `Name-Version` (e.g. `Gtk-4.0`).
  GirRepository load(String nameVersion) {
    return _cache.putIfAbsent(nameVersion, () {
      final file = pathFor(nameVersion);
      if (!File(file).existsSync()) {
        throw FileSystemException('GIR file not found', file);
      }
      return _parser.parseFile(file);
    });
  }

  /// Returns the transitive include closure of [nameVersion], in dependency
  /// order (each repository appears after all of its includes). The requested
  /// repository is last.
  List<GirRepository> loadWithDependencies(String nameVersion) {
    final result = <GirRepository>[];
    final visited = <String>{};

    void visit(String key) {
      if (!visited.add(key)) return;
      final repo = load(key);
      for (final include in repo.includes) {
        visit(include.key);
      }
      result.add(repo);
    }

    visit(nameVersion);
    return result;
  }

  /// Same as [loadWithDependencies] but for several roots, deduplicated.
  List<GirRepository> loadAllWithDependencies(Iterable<String> nameVersions) {
    final result = <GirRepository>[];
    final visited = <String>{};

    void visit(String key) {
      if (!visited.add(key)) return;
      final repo = load(key);
      for (final include in repo.includes) {
        visit(include.key);
      }
      result.add(repo);
    }

    for (final key in nameVersions) {
      visit(key);
    }
    return result;
  }
}
