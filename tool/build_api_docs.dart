// Build script for the public API reference.
//
// Runs `dart doc` once per workspace package, drops the output under
// `site/docs/<package>/` so each package has its own docs subdirectory
// that mirrors pub.dev's per-package URL layout. Then writes a hand-
// crafted landing page at `site/docs/index.html` that lists every
// package with a one-line description and links into each docs
// subdirectory.
//
// Usage:
//   dart run tool/build_api_docs.dart [--verbose]
//
// The script deliberately depends only on `dart:` (no extra packages)
// so it works against a freshly cloned workspace without forcing
// dependency re-resolution.
import 'dart:convert';
import 'dart:io';

const String _pubspecFile = 'pubspec.yaml';
const String _outputDir = 'site/docs';

/// One-line descriptions for the API landing page's package index.
const Map<String, String> _packageBlurbs = {
  'gir_ffi': 'Hand-written runtime helpers shared by every binding '
      '(withNativeString, withNativeStringList, HeapAnchor, g_free).',
  'glib': 'GLib 2.0 — fundamental types, main loop, file I/O, strings, '
      'hash tables, byte arrays.',
  'gobject': 'GObject 2.0 — type system, signals, properties, closures, '
      'the GValue / GParam machinery.',
  'gio': 'Gio 2.0 — file, network, settings, app, dbus — the I/O and '
      'application platform on top of GLib.',
  'gdk_pixbuf': 'GdkPixbuf 2.0 — image loading, pixel-buffer manipulation, '
      'PNG / JPEG / ICO / animated-GIF I/O.',
  'cairo': 'cairo 1.0 — 2D vector graphics: paths, surfaces, gradients, '
      'transforms, the rendering engine GTK4 paints with.',
  'pango': 'Pango 1.0 — text layout, fonts, shaping, and rendering. '
      'Bridges to Freetype / Fontconfig on the C side.',
  'gdk4': 'Gdk 4 — display server abstraction, surfaces, input events, '
      'clipboard, drag-and-drop, cursors.',
  'graphene': 'Graphene 1.0 — SIMD-friendly vector, matrix, and quaternion '
      'primitives for graphics math.',
  'gsk4': 'Gsk 4 — the scene graph kit: render nodes, renderers, '
      'shaders, transforms, the layer between GTK4 and the GPU.',
  'gtk4': 'Gtk 4 — the widget toolkit. Widgets, layout containers, '
      'dialogs, accessibility (GtkAccessible), templates (GtkBuildable).',
  'adw': 'Adw 1 — Libadwaita: adaptive widgets for GNOME applications '
      '(AdwApplicationWindow, AdwActionRow, AdwNavigationView, …).',
  'gtk_source5': 'GtkSource 5 — source-code-aware text view: language '
      'specs, syntax highlighting, code folding, gutter renderers.',
  'gi_repository3': 'GIR typelib loader — at-runtime GIR parsing for '
      'libraries that aren\'t statically bound.',
  'gtk_templates_builder': '`build_runner` builder for the `@Template` '
      'annotation pipeline (see also `gtk_templates`).',
};

Future<void> main(List<String> args) async {
  final verbose = args.contains('--verbose') || args.contains('-v');
  void log(String message) {
    stdout.writeln('build_api_docs: $message');
  }

  log('resolving package list from $_pubspecFile');
  final packages = _readWorkspacePackages().toList()..sort();
  if (verbose) {
    log('workspace lists ${packages.length} package(s): '
        '${packages.join(', ')}');
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
    final result = await Process.run(
      'dart',
      <String>['doc', '--output', '$outputRoot/$pkg'],
      workingDirectory: 'packages/$pkg',
    );
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

  log('docs: ${packages.length} packages, $totalClasses classes, '
      '$totalMembers members → $_outputDir/');
  log('open $_outputDir/index.html in a browser to inspect');
}

Set<String> _readWorkspacePackages() {
  final pubspec = File(_pubspecFile);
  if (!pubspec.existsSync()) {
    stderr.writeln('build_api_docs: $_pubspecFile not found');
    exit(2);
  }
  return _parseWorkspaceList(pubspec.readAsStringSync());
}

/// Hand-rolled mini-parser for the `workspace:` section of
/// `pubspec.yaml`. Avoids pulling `package:yaml` (which would force
/// a re-resolution of the workspace's `analyzer` constraint and
/// break `dart test`).
Set<String> _parseWorkspaceList(String content) {
  final lines = content.split('\n');
  var inWorkspace = false;
  final packages = <String>{};
  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.startsWith('workspace:')) {
      inWorkspace = line.endsWith(':') || line == 'workspace:';
      continue;
    }
    if (!inWorkspace) continue;
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      // Out of the workspace section (top-level key).
      inWorkspace = false;
      continue;
    }
    // Match `  - packages/<name>` and `  - example` / `  - generator`.
    final dash = line.indexOf('-');
    if (dash < 0) continue;
    final entry = line.substring(dash + 1).trim();
    if (entry.startsWith('packages/')) {
      packages.add(entry.substring('packages/'.length));
    }
  }
  if (packages.isEmpty) {
    stderr.writeln(
        'build_api_docs: $_pubspecFile has no `workspace:` list — '
        'expected the 14 binding package directories.');
    exit(2);
  }
  return packages;
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

void _writeLandingPage(
  List<String> packages, {
  required void Function(String) log,
}) {
  final cards = <String>[];
  for (final pkg in packages) {
    final blurb = _packageBlurbs[pkg] ??
        // Fallback blurb for any package we don't have a hard-coded
        // entry for. The drift check below warns about missing entries.
        'GIR-derived Dart FFI bindings for $pkg.';
    cards.add('<li><a href="$pkg/">$pkg</a> '
        '<span class="docs-pkg-blurb">— ${_escapeHtml(blurb)}</span></li>');
  }

  final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>dart-gir API reference</title>
<meta name="description" content="Generated API reference for the dart-gir workspace: ${packages.length} Dart FFI packages for GLib, GObject, Gio, Cairo, Pango, GTK4, libadwaita, and the rest of the GObject stack.">
<link rel="stylesheet" href="../assets/style.css">
<style>
body { max-width: 880px; margin: 0 auto; padding: 32px 24px 64px; color: var(--text); background: var(--bg); font-family: system-ui, -apple-system, sans-serif; }
.docs-list { list-style: none; padding: 0; margin: 24px 0; display: grid; gap: 12px; }
.docs-list li { padding: 14px 18px; border: 1px solid var(--hairline, #d8d8d8); border-radius: 8px; background: var(--panel, #fafafa); }
.docs-list a { color: var(--link, #0175C2); font-weight: 600; font-size: 16px; text-decoration: none; font-family: ui-monospace, SFMono-Regular, monospace; }
.docs-list a:hover { text-decoration: underline; }
.docs-pkg-blurb { color: var(--text-2, #555); font-size: 14px; margin-left: 4px; }
.docs-back { display: inline-block; margin-bottom: 24px; color: var(--link, #0175C2); text-decoration: none; font-size: 14px; }
.docs-back:hover { text-decoration: underline; }
h1 { font-size: 28px; margin: 0 0 8px 0; }
.lead { color: var(--text-2, #555); margin: 0 0 24px 0; font-size: 16px; line-height: 1.55; }
</style>
</head>
<body>
<a class="docs-back" href="../">\u2190 dart-gir home</a>
<h1>API reference</h1>
<p class="lead">
Generated documentation for the <strong>${packages.length}</strong> packages
in the dart-gir workspace. Each link opens that package's API landing page.
Type names and method signatures link to the live docs; cross-package
references resolve through the public <code>docs/&lt;pkg&gt;/</code> URL space.
</p>
<ul class="docs-list">
${cards.join('\n')}
</ul>
</body>
</html>
''';

  File('$_outputDir/index.html').writeAsStringSync(html);

  // Drift check: warn if any package lacks a curated blurb. Easy to add
  // new entries; we'd rather see the warning than silently ship the
  // generic fallback.
  final missing = packages.where((p) => !_packageBlurbs.containsKey(p));
  if (missing.isNotEmpty) {
    log('warning: ${missing.length} package(s) have no blurb in '
        '_packageBlurbs: ${missing.join(', ')}');
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
  final mainSite = '$up../';             // workspace root → site/index.html
  final apiHome = '$up../index.html';   // API landing page
  final otherPkgPrefix = '$up../';        // relative to peer package

  // Top-of-page header. Single line of compact links so it doesn't
  // dominate the page. `currentPkg` is rendered as a non-link badge
  // so the user always sees where they are.
  final header = '<div class="docs-site-nav">'
      '<a class="docs-site-nav-home" href="$mainSite">\u2190 dart-gir home</a>'
      '<span class="docs-site-nav-sep">\u00b7</span>'
      '<a class="docs-site-nav-api" href="$apiHome">API reference</a>'
      '<span class="docs-site-nav-sep">\u00b7</span>'
      '<span class="docs-site-nav-current">$currentPkg</span>'
      '</div>';

  // CSS shim that styles the header without overriding dartdoc's own
  // styling. Inlined into the first <style> block we find, falling
  // back to a fresh <style> in <head>.
  final css = '<style>'
      '.docs-site-nav{display:flex;align-items:center;gap:12px;'
      'padding:10px 24px;background:#f5f5f7;'
      'border-bottom:1px solid #dadce0;font-family:system-ui,-apple-system,sans-serif;'
      'font-size:14px;line-height:1.4;}'
      '.docs-site-nav a{color:#0175C2;text-decoration:none;font-weight:600;}'
      '.docs-site-nav a:hover{text-decoration:underline;}'
      '.docs-site-nav-sep{color:#999;}'
      '.docs-site-nav-current{color:#111;font-weight:600;'
      'font-family:ui-monospace,SFMono-Regular,monospace;}'
      '.docs-other-pkgs{margin:0;padding:0;}'
      '</style>';

  // Skip the patch if we've already done it (idempotent).
  if (original.contains('class="docs-site-nav"')) {
    return;
  }

  var patched = original;

  // Inject CSS once per page.
  if (patched.contains('<style>')) {
    patched = patched.replaceFirst(
        '<style>', '$css<style>');
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
      final block = '<ol class="docs-other-pkgs">'
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