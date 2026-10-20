// The site generator.
//
// Renders `site_src/pages/*.md` into `site/*.html` and copies
// `site_src/assets/` into `site/assets/`. The output is committed, and
// CI regenerates it and fails if the committed copy differs — the same
// rule the repository already applies to the generated bindings.
//
// Usage:
//   dart run tool/build_site.dart            # write the site
//   dart run tool/build_site.dart --check    # fail if the site is stale
//   dart run tool/build_site.dart --serve    # build, then serve site/
//
// The script depends only on `dart:` — no `package:markdown`, no
// `package:yaml`. A site build must work in CI with nothing but the
// Dart SDK, and adding a dependency would force a workspace
// re-resolution that breaks `dart test` (see the note in
// `tool/build_api_docs.dart`).

import 'dart:io';

import 'site/components.dart';
import 'site/facts.dart';
import 'site/frontmatter.dart';
import 'site/layout.dart';
import 'site/markdown.dart';

/// The directory holding the page sources.
const String sourceDirectory = 'site_src';

/// The directory the site is written to.
const String outputDirectory = 'site';

/// A page source: its file name and its front matter.
class PageSource {
  const PageSource(this.fileName, this.front);

  /// The source file's name, e.g. `index.md`.
  final String fileName;

  /// The page's front matter.
  final FrontMatter front;

  /// The output file's name, e.g. `index.html`.
  String get outputName => fileName.replaceAll(RegExp(r'\.md$'), '.html');
}

/// The rendered site: the pages and the assets.
class SiteBuild {
  const SiteBuild(this.pages, this.assets);

  /// The rendered pages, keyed by their file name.
  final Map<String, String> pages;

  /// The static assets, keyed by their path under `site/assets/`.
  final Map<String, String> assets;
}

/// The colophon's link columns — the same three the old site carried.
const List<FooterColumn> footerColumns = <FooterColumn>[
  FooterColumn('Project', <FooterLink>[
    FooterLink('features.html', 'Features'),
    FooterLink('design.html', 'Design reference'),
    FooterLink('roadmap.html', 'Roadmap'),
  ]),
  FooterColumn('Source', <FooterLink>[
    FooterLink(
      'https://github.com/TenderOwl/dart-gir',
      'Repository',
      external: true,
    ),
    FooterLink(
      'https://github.com/TenderOwl/dart-gir/tree/main/docs',
      'docs/',
      external: true,
    ),
    FooterLink('docs/', 'API reference'),
    FooterLink(
      'https://github.com/TenderOwl/dart-gir/blob/main/CHANGELOG.md',
      'Changelog',
      external: true,
    ),
  ]),
  FooterColumn('More', <FooterLink>[
    FooterLink('about.html', 'About'),
    FooterLink(
      'about.html#ai-assisted-development',
      'AI development statement',
    ),
    FooterLink('license.html', 'License'),
  ]),
];

/// Reads the page sources and their front matter.
List<PageSource> readPageSources(String root, Facts facts) {
  final directory = Directory('$root/$sourceDirectory/pages');
  if (!directory.existsSync()) {
    throw StateError('missing ${directory.path}');
  }
  final sources = <PageSource>[];
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final name = file.path.split(Platform.pathSeparator).last;
    final source = facts.substitute(
      file.readAsStringSync(),
      sourceName: '$sourceDirectory/pages/$name',
    );
    sources.add(PageSource(name, parseFrontMatter(source)));
  }
  return sources;
}

/// The primary navigation, in page order, with the API reference last.
List<NavEntry> siteNav(List<PageSource> pages) {
  final entries =
      pages
          .map(
            (page) => NavEntry(
              page.outputName,
              page.front.navLabel,
              page.front.navOrder,
            ),
          )
          .toList()
        ..sort((a, b) {
          final byOrder = a.order.compareTo(b.order);
          return byOrder != 0 ? byOrder : a.label.compareTo(b.label);
        });
  entries.add(
    const NavEntry('docs/', 'API reference →', 1 << 29, variant: 'api'),
  );
  return entries;
}

/// Renders the whole site in memory.
SiteBuild buildSite(String root) {
  final factsFile = File('$root/$sourceDirectory/data/facts.json');
  if (!factsFile.existsSync()) {
    throw StateError(
      'missing ${factsFile.path} — run `dart run tool/collect_facts.dart`',
    );
  }
  final facts = Facts.decode(factsFile.readAsStringSync());
  final packages = readPackages('$root/$sourceDirectory/data/packages.json');
  final sources = readPageSources(root, facts);
  final nav = siteNav(sources);
  final railFacts = siteRailFacts(facts, packages);
  final context = RenderContext(
    packages: packages,
    packageSkips: _packageSkips(facts),
  );

  final pages = <String, String>{};
  for (final source in sources) {
    final file = '$sourceDirectory/pages/${source.fileName}';
    final body = facts.substitute(source.front.body, sourceName: file);
    final document = parseMarkdown(body);
    final content = StringBuffer()
      ..write(renderPreamble(document.preamble, context));
    for (final section in document.sections) {
      content.write(renderSection(section, context));
    }
    pages[source.outputName] = renderSitePage(
      SitePage(
        title: source.front.title,
        docTitle: source.front.docTitle,
        description: source.front.description,
        kicker: source.front.sectionLabel,
        ogType: source.front.ogType,
        basePath: '',
        activePath: source.outputName,
        nav: nav,
        sections: document.sections,
        railFacts: railFacts,
        content: content.toString(),
        footerColumns: footerColumns,
      ),
    );
  }

  final assets = <String, String>{};
  final assetDirectory = Directory('$root/$sourceDirectory/assets');
  if (assetDirectory.existsSync()) {
    for (final file in assetDirectory.listSync().whereType<File>()) {
      final name = file.path.split(Platform.pathSeparator).last;
      assets[name] = file.readAsStringSync();
    }
  }

  return SiteBuild(pages, assets);
}

/// The derived facts shown at the foot of the rail.
List<RailFact> siteRailFacts(Facts facts, List<PackageEntry> packages) {
  final namespaces = packages.where((package) => package.generated).length;
  final skipped = facts.lookup('total_skipped') ?? '—';
  return <RailFact>[
    RailFact('packages', '${packages.length}'),
    RailFact('namespaces', '$namespaces'),
    RailFact('skipped symbols', skipped),
  ];
}

/// The per-package skip counts, read out of the facts.
Map<String, int> _packageSkips(Facts facts) {
  final list = facts.data['package_skips'];
  if (list is! Map<String, Object?>) return const <String, int>{};
  final result = <String, int>{};
  for (final entry in list.entries) {
    final value = entry.value;
    if (value is int) result[entry.key] = value;
  }
  return result;
}

/// Writes the rendered site to `site/`, leaving `site/docs/` alone.
void writeSite(String root, SiteBuild build) {
  final outputDir = Directory('$root/$outputDirectory');
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }
  for (final entity in outputDir.listSync()) {
    final name = entity.path.split(Platform.pathSeparator).last;
    if (name.endsWith('.html') || name == 'assets') {
      entity.deleteSync(recursive: true);
    }
  }
  for (final entry in build.pages.entries) {
    File('$root/$outputDirectory/${entry.key}').writeAsStringSync(entry.value);
  }
  final assetDir = Directory('$root/$outputDirectory/assets');
  assetDir.createSync(recursive: true);
  for (final entry in build.assets.entries) {
    File('$root/$outputDirectory/assets/${entry.key}')
        .writeAsStringSync(entry.value);
  }
}

/// Compares the rendered site with the committed one.
///
/// Returns the list of differences; an empty list means the committed
/// output is up to date.
List<String> diffSite(String root, SiteBuild build) {
  final differences = <String>[];
  for (final entry in build.pages.entries) {
    final file = File('$root/$outputDirectory/${entry.key}');
    if (!file.existsSync()) {
      differences.add('missing $outputDirectory/${entry.key}');
    } else if (file.readAsStringSync() != entry.value) {
      differences.add('stale $outputDirectory/${entry.key}');
    }
  }
  final outputDir = Directory('$root/$outputDirectory');
  if (outputDir.existsSync()) {
    for (final entity in outputDir.listSync()) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.endsWith('.html')) continue;
      if (!build.pages.containsKey(name)) {
        differences.add('orphaned $outputDirectory/$name');
      }
    }
  }
  for (final entry in build.assets.entries) {
    final file = File('$root/$outputDirectory/assets/${entry.key}');
    if (!file.existsSync()) {
      differences.add('missing $outputDirectory/assets/${entry.key}');
    } else if (file.readAsStringSync() != entry.value) {
      differences.add('stale $outputDirectory/assets/${entry.key}');
    }
  }
  return differences;
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final check = args.contains('--check');
  final serve = args.contains('--serve');

  void log(String message) => stdout.writeln('build_site: $message');

  final build = buildSite(root);
  log(
    'rendered ${build.pages.length} page(s) and '
    '${build.assets.length} asset(s) from $sourceDirectory/',
  );

  if (check) {
    final differences = diffSite(root, build);
    if (differences.isEmpty) {
      log('$outputDirectory/ is up to date');
      return;
    }
    for (final difference in differences) {
      stderr.writeln('build_site: $difference');
    }
    stderr.writeln(
      'build_site: run `dart run tool/build_site.dart` and commit the result',
    );
    exit(1);
  }

  writeSite(root, build);
  log('wrote $outputDirectory/');

  if (serve) {
    await _serve(root, args);
  }
}

Future<void> _serve(String root, List<String> args) async {
  final index = args.indexOf('--serve');
  var port = 8080;
  if (index >= 0 && index + 1 < args.length) {
    final parsed = int.tryParse(args[index + 1]);
    if (parsed != null) port = parsed;
  }
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln(
    'build_site: serving $outputDirectory/ on '
    'http://localhost:${server.port} — Ctrl-C to stop',
  );
  await for (final request in server) {
    try {
      final path = request.uri.path;
      final relative = path == '/' ? 'index.html' : path.substring(1);
      final file = File('$root/$outputDirectory/$relative');
      if (file.existsSync()) {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          _contentType(relative),
        );
        await request.response.addStream(file.openRead());
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('not found');
      }
      await request.response.close();
    } catch (error) {
      stderr.writeln('build_site: $error');
    }
  }
}

String _contentType(String path) {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (path.endsWith('.json')) return 'application/json; charset=utf-8';
  if (path.endsWith('.svg')) return 'image/svg+xml';
  return 'application/octet-stream';
}
