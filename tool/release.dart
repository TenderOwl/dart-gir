/// The release tool: prepare, check and publish the 17 packages.
///
/// The repository stays a Dart **workspace**: path dependencies and
/// `resolution: workspace` are what make `dart pub get` work offline and
/// keep the workspace resolving. Publication happens from a *prepared copy*
/// of each package in a directory *outside* the repository, where the
/// pubspec is rewritten:
///
///   - the version comes from the root pubspec (the workspace version);
///   - `publish_to: none` and `resolution: workspace` are gone;
///   - the path dependencies become hosted constraints (`^<version>`);
///   - `README.md`, `CHANGELOG.md` and `LICENSE` are copied in.
///
/// Usage:
///
/// ```
/// dart run tool/release.dart prepare [--version 1.0.0]
/// dart run tool/release.dart check
/// dart run tool/release.dart publish [--dry-run] [--skip-validation]
/// ```
///
/// `prepare` is idempotent and writes only into the release directory,
/// which is outside the repository. `check` runs the structural checks
/// pub.dev would run, and
/// — for every package whose dependencies are already on pub.dev — the
/// real `dart pub publish --dry-run`. `publish` uploads in topological
/// order, because a package cannot be published before the packages it
/// depends on.
library;

import 'dart:io';

/// The directory the prepared copies live in.
///
/// It must be **outside the repository**. pub reads the ignore rules of
/// the package it publishes, and a package that sits inside a git
/// repository with git-ignored files packs as an empty archive — *"the
/// pubspec is hidden, probably by .gitignore"*. The working tree stays
/// the source of truth; the copy is a build output, and a build output
/// belongs outside the source tree.
///
/// `--release-dir <path>` overrides it.
String get defaultReleaseDir => '${Directory.systemTemp.path}/dart-gir-release';

/// The release directory in use.
String releaseDir = defaultReleaseDir;

/// The packages that are published, in the order they are published.
///
/// The order is derived from the dependency graph (the path dependencies
/// in the working tree), not hard-coded: a topological sort over the
/// pubspecs is the only order that stays correct when a package is added.
const String packagesDir = 'packages';

/// The metadata every published package carries.
const String homepage = 'https://dartgir.tenderowl.com';
const String repository = 'https://github.com/TenderOwl/dart-gir';
const String issueTracker = 'https://github.com/TenderOwl/dart-gir/issues';

/// The shortest description pub.dev accepts.
const int minDescriptionLength = 60;

/// The longest description pub.dev accepts.
const int maxDescriptionLength = 180;

/// The most topics pub.dev accepts.
const int maxTopics = 5;

/// One package's pubspec, as far as the release tool cares about it.
class Pubspec {
  Pubspec({
    required this.name,
    required this.version,
    required this.description,
    required this.homepage,
    required this.repository,
    required this.issueTracker,
    required this.topics,
    required this.dependencies,
    required this.devDependencies,
    required this.pathDependencies,
    required this.publishTo,
    required this.resolution,
    required this.sdk,
  });

  /// The package's name.
  final String name;

  /// The package's version, or null when the pubspec declares none.
  final String? version;

  /// The package's one-line description.
  final String description;

  /// The package's `homepage:`.
  final String? homepage;

  /// The package's `repository:`.
  final String? repository;

  /// The package's `issue_tracker:`.
  final String? issueTracker;

  /// The package's `topics:`.
  final List<String> topics;

  /// The package's runtime dependencies, keyed by name.
  final Map<String, String> dependencies;

  /// The package's dev dependencies, keyed by name.
  final Map<String, String> devDependencies;

  /// The dependencies that are declared as a path.
  final Set<String> pathDependencies;

  /// The package's `publish_to:`, or null when it declares none.
  final String? publishTo;

  /// The package's `resolution:`, or null when it declares none.
  final String? resolution;

  /// The SDK constraint.
  final String? sdk;

  /// Reads a pubspec.
  ///
  /// The parser is deliberately small: it understands the shape this
  /// repository writes — a flat `name:`/`version:`/`description:` header,
  /// a `topics:` list, an `environment:` block and a dependency map whose
  /// entries are either a version constraint or a `path:`. It is not a
  /// YAML parser, and it does not need to be: the pubspecs it reads are
  /// written by this repository's generator and by hand, and a pubspec
  /// shape it cannot read is reported as an error rather than guessed at.
  static Pubspec parse(String source, {required String file}) {
    final lines = source.split('\n');
    String? name;
    String? version;
    String? description;
    String? home;
    String? repo;
    String? issues;
    String? publishTo;
    String? resolution;
    String? sdk;
    final topics = <String>[];
    final dependencies = <String, String>{};
    final devDependencies = <String, String>{};
    final pathDependencies = <String>{};

    // The description may be a folded block (`>-`), in which case the
    // text continues on the following indented lines.
    String? foldedDescription;

    var i = 0;
    String? section;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        i++;
        continue;
      }

      if (line.startsWith('  ') && !line.startsWith('    ')) {
        // A list item under a key.
        if (section == 'topics' && trimmed.startsWith('- ')) {
          topics.add(trimmed.substring(2).trim());
          i++;
          continue;
        }
        // An indented `key: value` under a section.
        final m = RegExp(r'^  ([A-Za-z0-9_]+):\s*(.*)$').firstMatch(line);
        if (m != null && section != null) {
          final key = m.group(1)!;
          final value = m.group(2)!.trim();
          if (section == 'environment' && key == 'sdk') {
            sdk = value;
          } else if (section == 'dependencies' ||
              section == 'dev_dependencies') {
            if (value.isEmpty) {
              // The constraint is on the next line(s) — a `path:` entry.
              var j = i + 1;
              var constraint = '';
              while (j < lines.length && lines[j].startsWith('    ')) {
                constraint += lines[j].trim();
                j++;
              }
              if (section == 'dependencies') {
                dependencies[key] = constraint;
                if (constraint.startsWith('path:')) {
                  pathDependencies.add(key);
                }
              } else {
                devDependencies[key] = constraint;
              }
              i = j;
              continue;
            }
            if (section == 'dependencies') {
              dependencies[key] = value;
            } else {
              devDependencies[key] = value;
            }
          }
          i++;
          continue;
        }
        i++;
        continue;
      }

      final m = RegExp(r'^([A-Za-z0-9_]+):\s*(.*)$').firstMatch(line);
      if (m == null) {
        i++;
        continue;
      }
      final key = m.group(1)!;
      final value = m.group(2)!.trim();

      switch (key) {
        case 'name':
          name = value;
          section = null;
        case 'version':
          version = value;
          section = null;
        case 'description':
          if (value == '>-') {
            // A folded block: the text is the following indented lines.
            final parts = <String>[];
            var j = i + 1;
            while (j < lines.length && lines[j].startsWith('  ')) {
              parts.add(lines[j].trim());
              j++;
            }
            foldedDescription = parts.join(' ');
            i = j;
            section = null;
            continue;
          }
          description = value;
          section = null;
        case 'homepage':
          home = _unquote(value);
          section = null;
        case 'repository':
          repo = _unquote(value);
          section = null;
        case 'issue_tracker':
          issues = _unquote(value);
          section = null;
        case 'publish_to':
          publishTo = value;
          section = null;
        case 'resolution':
          resolution = value;
          section = null;
        case 'topics':
          section = 'topics';
        case 'environment':
          section = 'environment';
        case 'dependencies':
          section = 'dependencies';
        case 'dev_dependencies':
          section = 'dev_dependencies';
        default:
          section = null;
      }
      i++;
    }

    final text = _unquote(description ?? foldedDescription ?? '');
    if (name == null) {
      throw FormatException('$file: no `name:` field');
    }
    return Pubspec(
      name: name,
      version: version,
      description: text,
      homepage: home,
      repository: repo,
      issueTracker: issues,
      topics: topics,
      dependencies: dependencies,
      devDependencies: devDependencies,
      pathDependencies: pathDependencies,
      publishTo: publishTo,
      resolution: resolution,
      sdk: sdk,
    );
  }
}

/// Strips the surrounding quotes of a YAML scalar.
///
/// The generator writes the description double-quoted — a plain YAML
/// scalar cannot contain `": "` — and the release tool re-quotes it when
/// it writes the publication copy.
String _unquote(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 &&
      ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

/// A YAML scalar, double-quoted — the same shape the generator writes.
String _yamlString(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// One package in the release set.
class ReleasePackage {
  ReleasePackage({
    required this.name,
    required this.directory,
    required this.pubspec,
    required this.dependencies,
  });

  /// The package's name.
  final String name;

  /// The package's directory in the working tree (`packages/<name>`).
  final String directory;

  /// The package's working-tree pubspec.
  final Pubspec pubspec;

  /// The names of the packages this one depends on.
  final List<String> dependencies;
}

/// A structural problem with a package's publication copy.
class CheckFailure {
  CheckFailure(this.package, this.message);

  /// The package the failure belongs to.
  final String package;

  /// What is wrong.
  final String message;

  @override
  String toString() => '$package: $message';
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }
  final command = args.first;
  final rest = args.skip(1).toList();

  switch (command) {
    case 'prepare':
      await _prepare(rest);
    case 'check':
      await _check(rest);
    case 'publish':
      await _publish(rest);
    case '-h':
    case '--help':
    case 'help':
      _usage();
    default:
      stderr.writeln('unknown command: $command');
      _usage();
      exit(64);
  }
}

void _usage() {
  stdout.writeln('''
Usage:
  dart run tool/release.dart prepare [--version <version>] [--release-dir <dir>]
  dart run tool/release.dart check
  dart run tool/release.dart publish [--dry-run] [--skip-validation]

`prepare` writes the publication copies outside the repository — pub
packs a git-ignored package as an empty archive, so the copy cannot
live inside the working tree.
`check` runs the structural checks on them (and the real pub.dev dry run
for the packages whose dependencies are already published).
`publish` uploads them in dependency order.
''');
}

/// The workspace version: the root pubspec's `version:`.
String _workspaceVersion() {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    throw StateError(
      'pubspec.yaml not found — run this from the repository root',
    );
  }
  final spec = Pubspec.parse(file.readAsStringSync(), file: 'pubspec.yaml');
  final version = spec.version;
  if (version == null || version.isEmpty) {
    throw StateError('the root pubspec declares no `version:`');
  }
  return version;
}

/// The published packages, in dependency order.
List<ReleasePackage> _releasePackages() {
  final root = Directory(packagesDir);
  if (!root.existsSync()) {
    throw StateError(
      '$packagesDir/ not found — run this from the repository root',
    );
  }
  final packages = <ReleasePackage>[];
  for (final entity in root.listSync().whereType<Directory>()) {
    final pubspecFile = File('${entity.path}/pubspec.yaml');
    if (!pubspecFile.existsSync()) continue;
    final spec = Pubspec.parse(
      pubspecFile.readAsStringSync(),
      file: pubspecFile.path,
    );
    final deps =
        spec.dependencies.keys
            .where((d) => spec.pathDependencies.contains(d))
            .toList()
          ..sort();
    packages.add(
      ReleasePackage(
        name: spec.name,
        directory: entity.path,
        pubspec: spec,
        dependencies: deps,
      ),
    );
  }
  return _topological(packages);
}

/// Orders [packages] so that every package comes after the ones it
/// depends on.
List<ReleasePackage> _topological(List<ReleasePackage> packages) {
  final byName = {for (final p in packages) p.name: p};
  final ordered = <ReleasePackage>[];
  final done = <String>{};
  final visiting = <String>{};

  void visit(ReleasePackage p) {
    if (done.contains(p.name)) return;
    if (!visiting.add(p.name)) {
      throw StateError('the dependency graph has a cycle at ${p.name}');
    }
    for (final dep in p.dependencies) {
      final target = byName[dep];
      if (target != null) visit(target);
    }
    visiting.remove(p.name);
    done.add(p.name);
    ordered.add(p);
  }

  // Sort the input so the order does not depend on the file system.
  final sorted = [...packages]..sort((a, b) => a.name.compareTo(b.name));
  for (final p in sorted) {
    visit(p);
  }
  return ordered;
}

/// The publication copy of a package's pubspec.
String _publicationPubspec(ReleasePackage pkg, String version) {
  final spec = pkg.pubspec;
  final deps = <String, String>{};
  for (final entry in spec.dependencies.entries) {
    if (entry.key == 'ffi' || !spec.pathDependencies.contains(entry.key)) {
      deps[entry.key] = entry.value;
      continue;
    }
    // A sibling package becomes a hosted constraint on the same version.
    deps[entry.key] = '^$version';
  }

  final b = StringBuffer()
    ..writeln('name: ${spec.name}')
    ..writeln('version: $version')
    ..writeln('description: ${_yamlString(spec.description)}')
    ..writeln('homepage: ${_yamlString(spec.homepage ?? homepage)}')
    ..writeln('repository: ${_yamlString(spec.repository ?? repository)}')
    ..writeln(
      'issue_tracker: ${_yamlString(spec.issueTracker ?? issueTracker)}',
    )
    ..writeln('topics:');
  for (final t in spec.topics) {
    b.writeln('  - $t');
  }
  b
    ..writeln()
    ..writeln('environment:')
    ..writeln('  sdk: ${spec.sdk ?? '^3.13.4'}')
    ..writeln()
    ..writeln('dependencies:');
  final keys = deps.keys.toList()..sort();
  for (final k in keys) {
    b.writeln('  $k: ${deps[k]}');
  }
  final devKeys = spec.devDependencies.keys.toList()..sort();
  if (devKeys.isNotEmpty) {
    b
      ..writeln()
      ..writeln('dev_dependencies:');
    for (final k in devKeys) {
      b.writeln('  $k: ${spec.devDependencies[k]}');
    }
  }
  return b.toString();
}

/// The publication copy of a package's README.
String _readme(ReleasePackage pkg, String version) {
  final spec = pkg.pubspec;
  final b = StringBuffer()
    ..writeln('# ${spec.name}')
    ..writeln()
    ..writeln(spec.description)
    ..writeln()
    ..writeln('## Install')
    ..writeln()
    ..writeln('```yaml')
    ..writeln('dependencies:')
    ..writeln('  ${spec.name}: ^$version')
    ..writeln('```')
    ..writeln()
    ..writeln('```dart')
    ..writeln("import 'package:${spec.name}/${spec.name}.dart';")
    ..writeln('```')
    ..writeln()
    ..writeln('## What this package is')
    ..writeln()
    ..writeln(
      'Generated Dart FFI bindings, produced by the `gir_generator` '
      'generator from the upstream GIR file. The emitted code is the only '
      'API surface — raw FFI is the escape hatch.',
    )
    ..writeln()
    ..writeln('## Support')
    ..writeln()
    ..writeln(
      '**Linux only at 1.0.** The loader knows the Windows and macOS file '
      'names of every native library, but only Linux is executed and '
      'tested. On macOS the loader also needs the library directory on '
      'the loader path (Homebrew\'s `lib` is not on it by default).',
    )
    ..writeln()
    ..writeln('## Documentation')
    ..writeln()
    ..writeln('- API reference: $homepage/docs/${spec.name}/')
    ..writeln('- Project: $homepage')
    ..writeln('- Source: $repository')
    ..writeln('- Issues: $issueTracker')
    ..writeln()
    ..writeln('## Licence')
    ..writeln()
    ..writeln('BSD 3-Clause — see the `LICENSE` file.');
  return b.toString();
}

/// Writes the publication copies.
Future<void> _prepare(List<String> args) async {
  releaseDir = _releaseDirArgument(args) ?? releaseDir;
  final version = _versionArgument(args) ?? _workspaceVersion();
  final packages = _releasePackages();
  final out = Directory(releaseDir);
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);

  final changelog = File('CHANGELOG.md').existsSync()
      ? File('CHANGELOG.md').readAsStringSync()
      : '# Changelog\n';
  final license = File('LICENSE').existsSync()
      ? File('LICENSE').readAsStringSync()
      : '';

  for (final pkg in packages) {
    final dir = Directory('$releaseDir/${pkg.name}');
    dir.createSync(recursive: true);

    // The library, verbatim.
    final lib = Directory('${pkg.directory}/lib');
    if (!lib.existsSync()) {
      throw StateError('${pkg.directory}/lib not found');
    }
    _copyTree(lib, Directory('${dir.path}/lib'));

    // The pubspec, rewritten for publication.
    File('${dir.path}/pubspec.yaml')
        .writeAsStringSync(_publicationPubspec(pkg, version));

    // The files pub.dev wants.
    File('${dir.path}/README.md').writeAsStringSync(_readme(pkg, version));
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(changelog);
    if (license.isNotEmpty) {
      File('${dir.path}/LICENSE').writeAsStringSync(license);
    }
    final analysisOptions = File('${pkg.directory}/analysis_options.yaml');
    if (analysisOptions.existsSync()) {
      analysisOptions.copySync('${dir.path}/analysis_options.yaml');
    }
  }

  stdout.writeln(
    'prepare: wrote ${packages.length} package(s) to $releaseDir/ '
    '(version $version)',
  );
  for (final pkg in packages) {
    stdout.writeln('  ${pkg.name}');
  }
}

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync()) {
    final name = entity.path.split(Platform.pathSeparator).last;
    if (entity is Directory) {
      _copyTree(entity, Directory('${to.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${to.path}/$name');
    }
  }
}

/// The `--version` argument, when there is one.
String? _versionArgument(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--version' && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('--version=')) {
      return args[i].substring('--version='.length);
    }
  }
  return null;
}

/// The `--release-dir` argument, when there is one.
String? _releaseDirArgument(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--release-dir' && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('--release-dir=')) {
      return args[i].substring('--release-dir='.length);
    }
  }
  return null;
}

/// The structural checks a publication copy has to pass.
List<CheckFailure> _checkPackage(ReleasePackage pkg, String version) {
  final failures = <CheckFailure>[];
  final dir = Directory('$releaseDir/${pkg.name}');
  final pubspecFile = File('${dir.path}/pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    return [
      CheckFailure(pkg.name, 'no prepared pubspec — run `prepare` first'),
    ];
  }
  final spec = Pubspec.parse(
    pubspecFile.readAsStringSync(),
    file: pubspecFile.path,
  );

  if (spec.name != pkg.name) {
    failures.add(
      CheckFailure(pkg.name, 'the prepared pubspec is named `${spec.name}`'),
    );
  }
  if (spec.version != version) {
    failures.add(
      CheckFailure(
        pkg.name,
        'the version is `${spec.version}`, expected `$version`',
      ),
    );
  }
  final length = spec.description.length;
  if (length < minDescriptionLength || length > maxDescriptionLength) {
    failures.add(
      CheckFailure(
        pkg.name,
        'the description is $length characters; pub.dev wants '
        '$minDescriptionLength–$maxDescriptionLength',
      ),
    );
  }
  for (final entry in {
    'homepage': _unquote(spec.homepage ?? ''),
    'repository': _unquote(spec.repository ?? ''),
    'issue_tracker': _unquote(spec.issueTracker ?? ''),
  }.entries) {
    final value = entry.value;
    if (value.isEmpty) {
      failures.add(CheckFailure(pkg.name, 'no `${entry.key}:`'));
    } else if (!value.startsWith('http://') && !value.startsWith('https://')) {
      failures.add(
        CheckFailure(pkg.name, '`${entry.key}:` is not an absolute URL'),
      );
    }
  }
  if (spec.topics.isEmpty) {
    failures.add(CheckFailure(pkg.name, 'no `topics:`'));
  } else if (spec.topics.length > maxTopics) {
    failures.add(
      CheckFailure(
        pkg.name,
        '${spec.topics.length} topics; pub.dev allows $maxTopics',
      ),
    );
  }
  for (final topic in spec.topics) {
    if (topic.length > 20) {
      failures.add(
        CheckFailure(
          pkg.name,
          'the topic `$topic` is longer than 20 characters',
        ),
      );
    }
    if (!RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(topic)) {
      failures.add(
        CheckFailure(pkg.name, 'the topic `$topic` is not lower-case-dashed'),
      );
    }
  }
  if (spec.publishTo != null) {
    failures.add(
      CheckFailure(pkg.name, '`publish_to: ${spec.publishTo}` is still there'),
    );
  }
  if (spec.resolution != null) {
    failures.add(
      CheckFailure(pkg.name, '`resolution: ${spec.resolution}` is still there'),
    );
  }
  if (spec.pathDependencies.isNotEmpty) {
    failures.add(
      CheckFailure(
        pkg.name,
        'the path dependencies are still there: '
        '${spec.pathDependencies.join(', ')}',
      ),
    );
  }
  for (final required in ['README.md', 'CHANGELOG.md', 'LICENSE']) {
    if (!File('${dir.path}/$required').existsSync()) {
      failures.add(CheckFailure(pkg.name, 'no `$required`'));
    }
  }
  if (!Directory('${dir.path}/lib').existsSync()) {
    failures.add(CheckFailure(pkg.name, 'no `lib/`'));
  }
  return failures;
}

/// Whether [name] exists on pub.dev.
Future<bool> _publishedOnPubDev(String name) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('https://pub.dev/api/packages/$name'),
    );
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == 200;
  } on Object {
    // No network, or pub.dev is down: the answer is "not published",
    // which is the safe reading — the package is then only structurally
    // checked.
    return false;
  } finally {
    client.close();
  }
}

/// Runs the checks.
Future<void> _check(List<String> args) async {
  releaseDir = _releaseDirArgument(args) ?? releaseDir;
  final version = _versionArgument(args) ?? _workspaceVersion();
  final packages = _releasePackages();

  // The copies are a build output of the working tree, so they are
  // rebuilt before they are checked. A copy left over from an earlier
  // version would otherwise be validated — and the check would report
  // the *old* version's metadata against the *new* workspace version.
  await _prepare(args);

  final failures = <CheckFailure>[];
  for (final pkg in packages) {
    failures.addAll(_checkPackage(pkg, version));
  }

  // The real dry run, for the packages whose dependencies are already on
  // pub.dev. Before the first upload none of them are, so every package
  // is reported as *structurally checked only* — which is exactly what
  // the release script has to say about the state of the world.
  final published = <String, bool>{};
  for (final pkg in packages) {
    published[pkg.name] = await _publishedOnPubDev(pkg.name);
  }

  final dryRun = <String>[];
  final structuralOnly = <String>[];
  for (final pkg in packages) {
    final depsPublished = pkg.dependencies.every((d) => published[d] == true);
    if (!depsPublished) {
      structuralOnly.add(pkg.name);
      continue;
    }
    final result = await Process.run('dart', [
      'pub',
      'publish',
      '--dry-run',
      '-C',
      '$releaseDir/${pkg.name}',
    ]);
    if (result.exitCode != 0) {
      failures.add(
        CheckFailure(
          pkg.name,
          'the pub.dev dry run failed:\n${result.stdout}${result.stderr}',
        ),
      );
    } else {
      dryRun.add(pkg.name);
    }
  }

  stdout.writeln('release check — version $version');
  stdout.writeln('');
  for (final pkg in packages) {
    final state = dryRun.contains(pkg.name)
        ? 'dry run passed'
        : 'structurally checked only';
    stdout.writeln('  ${pkg.name.padRight(26)} $state');
  }
  stdout.writeln('');
  stdout.writeln(
    '${packages.length - failures.length}/${packages.length} package(s) '
    'are publishable.',
  );
  if (failures.isNotEmpty) {
    stdout.writeln('');
    for (final failure in failures) {
      stdout.writeln('  ✗ $failure');
    }
    exit(1);
  }
}

/// Publishes the packages, in dependency order.
Future<void> _publish(List<String> args) async {
  releaseDir = _releaseDirArgument(args) ?? releaseDir;
  final version = _versionArgument(args) ?? _workspaceVersion();
  final dryRun = args.contains('--dry-run');
  final skipValidation = args.contains('--skip-validation');
  final packages = _releasePackages();

  await _prepare(args);

  for (final pkg in packages) {
    final flag = dryRun ? '--dry-run' : '';
    stdout.writeln('publishing ${pkg.name} $version…');
    final result = await Process.run('dart', [
      'pub',
      'publish',
      if (flag.isNotEmpty) flag,
      if (skipValidation) '--skip-validation',
      '-C',
      '$releaseDir/${pkg.name}',
    ]);
    stdout.write(result.stdout);
    if (result.stderr.isNotEmpty) stderr.write(result.stderr);
    if (result.exitCode != 0) {
      stderr.writeln('publish failed for ${pkg.name}');
      exit(result.exitCode);
    }
    if (!dryRun) {
      // pub.dev indexes a package asynchronously; the next package's
      // dependency may not be resolvable yet. Waiting a little is cheaper
      // than a failed upload.
      await Future<void>.delayed(const Duration(seconds: 30));
    }
  }
  stdout.writeln('published ${packages.length} package(s) at $version');
}
