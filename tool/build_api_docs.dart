// Build script for the public API reference.
//
// Runs `dart doc` once per workspace package, drops the output under
// `site/docs/<package>/` so each package has its own docs subdirectory
// that mirrors pub.dev's per-package URL layout. Then renders a landing
// page at `site/docs/index.html` through the site's own layout, so the
// API reference looks like the rest of the site instead of carrying a
// second, bespoke design.
//
// Usage:
//   dart run tool/build_api_docs.dart [--verbose]
//
// The script deliberately depends only on `dart:` (no extra packages)
// so it works against a freshly cloned workspace without forcing
// dependency re-resolution.
import 'dart:convert';
import 'dart:io';

import 'build_site.dart';
import 'site/facts.dart';
import 'site/layout.dart';
import 'site/markdown.dart';

const String _pubspecFile = 'pubspec.yaml';
const String _outputDir = 'site/docs';

Future<void> main(List<String> args) async {
  final verbose = args.contains('--verbose') || args.contains('-v');
  void log(String message) {
    stdout.writeln('build_api_docs: $message');
  }

  log('resolving package list from $_pubspecFile');
  final packages = _readWorkspacePackages().toList()..sort();
  if (verbose) {
    log(
      'workspace lists ${packages.length} package(s): '
      '${packages.join(', ')}',
    );
  }

  log('preparing output directory $_outputDir');
  final outputDir = Directory(_outputDir);
  if (outputDir.existsSync()) {
    await outputDir.delete(recursive: true);
  }
  await outputDir.create(recursive: true);

  var totalClasses = 0;
  var totalMembers = 0;
  final outputRoot = Directory(_outputDir).absolute.path;
  for (final pkg in packages) {
    log('documenting $pkg (dart doc in packages/$pkg)');
    final result = await Process.run('dart', <String>[
      'doc',
      '--output',
      '$outputRoot/$pkg',
    ], workingDirectory: 'packages/$pkg');
    if (result.exitCode != 0) {
      stderr.writeln('build_api_docs: `dart doc` failed for $pkg:');
      stderr.writeln(result.stdout);
      stderr.writeln(result.stderr);
      exit(result.exitCode);
    }
    if (verbose && result.stdout.toString().trim().isNotEmpty) {
      stdout.writeln(result.stdout);
    }
    final counts = _countOutput(pkg);
    totalClasses += counts.classes;
    totalMembers += counts.members;
  }

  log('validating each package produced a landing page');
  for (final pkg in packages) {
    final indexFile = File('$_outputDir/$pkg/index.html');
    if (!indexFile.existsSync()) {
      log('warning: $pkg produced no index.html');
    }
  }

  log('injecting cross-package navigation into every page');
  _injectCrossPackageNav(packages, log: log);

  log('writing $_outputDir/index.html landing page');
  _writeLandingPage(packages, log: log);

  log(
    'docs: ${packages.length} packages, $totalClasses classes, '
    '$totalMembers members → $_outputDir/',
  );
  log('open $_outputDir/index.html in a browser to inspect');
}

Set<String> _readWorkspacePackages() {
  final pubspec = File(_pubspecFile);
  if (!pubspec.existsSync()) {
    stderr.writeln('build_api_docs: $_pubspecFile not found');
    exit(2);
  }
  return parseWorkspaceList(pubspec.readAsStringSync());
}

class _Counts {
  _Counts(this.classes, this.members);
  final int classes;
  final int members;
}

_Counts _countOutput(String pkg) {
  final indexFile = File('$_outputDir/$pkg/index.json');
  int classes = 0;
  int members = 0;
  if (indexFile.existsSync()) {
    try {
      final parsed = jsonDecode(indexFile.readAsStringSync());
      if (parsed is List) {
        members = parsed.length;
      } else if (parsed is Map<String, Object?>) {
        final packages = parsed['packages'];
        if (packages is List) {
          members = packages.length;
        }
      }
    } catch (_) {
      // Best-effort only — never fail the build on a malformed index.json.
    }
  }
  // Cheap class count: count `<li class="class-item">` occurrences on
  // the package's index page. dartdoc emits one per documented class
  // under the per-library category listing. This survives Dart SDK
  // changes to inner markup.
  final pkgIndex = File('$_outputDir/$pkg/index.html');
  if (pkgIndex.existsSync()) {
    final text = pkgIndex.readAsStringSync();
    final re = RegExp(r'class="class-item"');
    classes = re.allMatches(text).length;
  }
  return _Counts(classes, members);
}

/// Renders the API reference landing page through the site's own layout.
///
/// The page lives one directory down, so every link and the stylesheet
/// reference are prefixed with `../`.
void _writeLandingPage(
  List<String> packages, {
  required void Function(String) log,
}) {
  final root = Directory.current.path;
  final curated = readPackages('$root/$sourceDirectory/data/packages.json');
  final factsFile = File('$root/$sourceDirectory/data/facts.json');
  final facts = factsFile.existsSync()
      ? Facts.decode(factsFile.readAsStringSync())
      : const Facts(<String, Object?>{});

  final byName = <String, PackageEntry>{
    for (final package in curated) package.name: package,
  };

  final rows = StringBuffer();
  var missing = <String>[];
  for (final pkg in packages) {
    final entry = byName[pkg];
    if (entry == null) {
      missing.add(pkg);
      rows.write(
        '<div class="kv-row"><dt>${_escapeHtml(pkg)}</dt>'
        '<dd>GIR-derived Dart FFI bindings for ${_escapeHtml(pkg)}.</dd></div>',
      );
      continue;
    }
    rows.write(
      '<div class="kv-row"><dt><code>${_escapeHtml(entry.name)}</code></dt>'
      '<dd>${_escapeHtml(entry.blurb)}</dd></div>',
    );
  }

  final nav = siteNav(readPageSources(root, facts));
  final sections = const <Section>[
    Section(
      number: '01',
      id: 'packages',
      title: 'The packages',
      blocks: <MarkdownBlock>[],
    ),
    Section(
      number: '02',
      id: 'about',
      title: 'About this reference',
      blocks: <MarkdownBlock>[],
    ),
  ];
  final content = StringBuffer()
    ..write(
      '<p class="lede">Generated documentation for the '
      '<strong>${packages.length}</strong> packages in the dart-gir '
      'workspace. Each entry opens that package\'s API landing page; type '
      'names and method signatures link to the live docs, and '
      'cross-package references resolve through the public '
      '<code>docs/&lt;pkg&gt;/</code> URL space.</p>',
    )
    ..write(
      '<section class="section" id="packages">'
      '<h2 class="section-title">'
      '<span class="section-num">01</span>The packages</h2>'
      '<dl class="kv">$rows</dl></section>',
    )
    ..write(
      '<section class="section" id="about">'
      '<h2 class="section-title">'
      '<span class="section-num">02</span>About this reference</h2>'
      '<p>These pages are produced by <code>dart doc</code> from the '
      'committed <code>packages/&lt;lib&gt;/lib/src/*.dart</code> — the '
      'generated source itself, not a copy. Every doc comment in the '
      'reference therefore comes from the upstream GIR file the generator '
      'read, or from the generator\'s own emission.</p>'
      '<p>The <a href="../index.html">home page</a> carries the prose; this '
      'reference carries the signatures.</p></section>',
    );

  final html = renderSitePage(
    SitePage(
      title: 'API reference',
      docTitle: 'dart-gir API reference',
      description:
          'Generated API reference for the dart-gir workspace: '
          '${packages.length} Dart FFI packages for GLib, GObject, Gio, '
          'Cairo, Pango, GTK4, libadwaita, and the rest of the GObject '
          'stack.',
      kicker: 'Generated reference',
      ogType: 'website',
      basePath: '../',
      activePath: 'docs/',
      nav: nav,
      sections: sections,
      railFacts: siteRailFacts(facts, curated),
      content: content.toString(),
      footerColumns: footerColumns,
    ),
  );

  File('$_outputDir/index.html').writeAsStringSync(html);

  if (missing.isNotEmpty) {
    log(
      'warning: ${missing.length} package(s) have no entry in '
      '$sourceDirectory/data/packages.json: ${missing.join(', ')}',
    );
  }
}

/// Walks every generated HTML page and injects cross-package navigation.
///
/// Two pieces are injected into every page (top-of-page header on all
/// pages; sidebar cross-package list on the package landing page only).
/// The class pages have JavaScript-populated sidebars, so we only touch
/// the static `<ol>` that lives in the package landing page.
void _injectCrossPackageNav(
  List<String> packages, {
  required void Function(String) log,
}) {
  final sorted = packages.toList()..sort();
  var totalPages = 0;
  for (final pkg in sorted) {
    final root = Directory('$_outputDir/$pkg');
    if (!root.existsSync()) continue;
    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'))
        .toList();
    for (final file in files) {
      _patchPage(file, pkg, sorted);
      totalPages += 1;
    }
  }
  log('cross-navigation: $totalPages HTML page(s) patched');
}

void _patchPage(File file, String currentPkg, List<String> allPackages) {
  final original = file.readAsStringSync();

  // Compute the relative paths for the top-of-page header. From
  // `<root>/index.html` (depth 0) the main site is two `..`s away;
  // from `<root>/<lib>/<page>.html` (depth 2) it's three.
  final pkgRoot = '$_outputDir/$currentPkg';
  final relative = file.path.substring(pkgRoot.length + 1);
  final depth = relative.split('/').length - 1;
  final up = '../' * depth;
  final mainSite = '$up../'; // workspace root → site/index.html
  final apiHome = '$up../index.html'; // API landing page
  final otherPkgPrefix = '$up../'; // relative to peer package

  // Top-of-page header. Single line of compact links so it doesn't
  // dominate the page. `currentPkg` is rendered as a non-link badge
  // so the user always sees where they are.
  final header =
      '<div class="docs-site-nav">'
      '<a class="docs-site-nav-home" href="$mainSite">← dart-gir home</a>'
      '<span class="docs-site-nav-sep">·</span>'
      '<a class="docs-site-nav-api" href="$apiHome">API reference</a>'
      '<span class="docs-site-nav-sep">·</span>'
      '<span class="docs-site-nav-current">$currentPkg</span>'
      '</div>';

  // CSS shim that styles the header without overriding dartdoc's own
  // styling. Inlined into the first <style> block we find, falling
  // back to a fresh <style> in <head>. The palette is the site's own —
  // paper, ink, hairline, rust — so the reference does not look like a
  // different website pasted into the same page.
  final css =
      '<style>'
      '.docs-site-nav{display:flex;align-items:baseline;gap:0.9rem;'
      'flex-wrap:wrap;padding:0.7rem 1.6rem;background:#fbfaf7;'
      'border-bottom:1px solid #e3e0d9;'
      'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;'
      'font-size:12.5px;letter-spacing:0.04em;color:#5b6068;}'
      '.docs-site-nav a{color:#9c3d12;text-decoration:none;}'
      '.docs-site-nav a:hover{text-decoration:underline;}'
      '.docs-site-nav-sep{color:#c9c5bb;}'
      '.docs-site-nav-current{color:#17181c;font-weight:600;}'
      '.docs-other-pkgs{margin:0;padding:0;}'
      '@media (prefers-color-scheme: dark){'
      '.docs-site-nav{background:#121316;border-bottom-color:#2a2d31;'
      'color:#9aa0a8;}'
      '.docs-site-nav a{color:#e08a5f;}'
      '.docs-site-nav-sep{color:#3b4046;}'
      '.docs-site-nav-current{color:#e9e7e2;}}'
      '</style>';

  // Skip the patch if we've already done it (idempotent).
  if (original.contains('class="docs-site-nav"')) {
    return;
  }

  var patched = original;

  // Inject CSS once per page.
  if (patched.contains('<style>')) {
    patched = patched.replaceFirst('<style>', '$css<style>');
  } else {
    patched = patched.replaceFirst('</head>', '$css</head>');
  }

  // Inject the header right after <body ...>.
  patched = patched.replaceFirstMapped(
    RegExp(r'<body([^>]*)>'),
    (m) => '<body${m[1]}>$header',
  );

  // On the package landing page only, augment the static <ol>
  // Libraries sidebar with an "Other packages" list. Class pages
  // have a JavaScript-populated sidebar that we can't statically
  // patch; the top-of-page header still gives them a way to reach
  // peer packages via the "API reference" link.
  if (relative == 'index.html') {
    final otherLinks = <String>[];
    for (final pkg in allPackages) {
      if (pkg == currentPkg) continue;
      otherLinks.add('<li><a href="$otherPkgPrefix$pkg/">$pkg</a></li>');
    }
    if (otherLinks.isNotEmpty) {
      final block =
          '<ol class="docs-other-pkgs">'
          '<li class="section-title">Other packages</li>'
          '${otherLinks.join('')}'
          '</ol>';
      // Inject right after the existing static <ol> that lists the
      // current package's libraries.
      patched = patched.replaceFirstMapped(
        RegExp(r'(<li><a href="[^"]+/">[^<]+</a></li>\s*</ol>)'),
        (m) => '${m[0]}\n$block',
      );
    }
  }

  if (patched != original) {
    file.writeAsStringSync(patched);
  }
}

String _escapeHtml(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
