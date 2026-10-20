// The page shell: head, masthead, navigation, rail, colophon.
//
// The shell is written once here and used by every page, including the
// API reference landing page one directory down (`basePath: '../'`).
// The old site duplicated the whole `<head>`, header and footer in every
// page; that duplication is what let the pages drift apart.

import 'markdown.dart';

/// One entry of the primary navigation.
class NavEntry {
  const NavEntry(this.href, this.label, this.order, {this.variant = ''});

  /// The link target, relative to the site root.
  final String href;

  /// The visible label.
  final String label;

  /// The sort position; lower comes first.
  final int order;

  /// An extra class for the entry — `api` for the API reference link.
  final String variant;
}

/// One link of a colophon column.
class FooterLink {
  const FooterLink(this.href, this.label, {this.external = false});

  /// The link target, relative to the site root.
  final String href;

  /// The visible label.
  final String label;

  /// Whether the link leaves the site.
  final bool external;
}

/// One column of the colophon.
class FooterColumn {
  const FooterColumn(this.heading, this.links);

  /// The column's heading.
  final String heading;

  /// The column's links.
  final List<FooterLink> links;
}

/// A label / value pair shown in the rail.
class RailFact {
  const RailFact(this.label, this.value);

  /// The fact's label.
  final String label;

  /// The fact's value.
  final String value;
}

/// Everything the shell needs to render one page.
class SitePage {
  const SitePage({
    required this.title,
    required this.docTitle,
    required this.description,
    required this.kicker,
    required this.ogType,
    required this.basePath,
    required this.activePath,
    required this.nav,
    required this.sections,
    required this.railFacts,
    required this.content,
    required this.footerColumns,
  });

  /// The document title.
  final String title;

  /// The browser title.
  final String docTitle;

  /// The meta description.
  final String description;

  /// The kicker line above the `h1`.
  final String kicker;

  /// The `og:type` meta value.
  final String ogType;

  /// The path prefix back to the site root — `''` or `'../'`.
  final String basePath;

  /// The path of the current page, relative to the site root.
  final String activePath;

  /// The primary navigation.
  final List<NavEntry> nav;

  /// The page's `##` sections, for the rail's table of contents.
  final List<Section> sections;

  /// The derived facts shown at the foot of the rail.
  final List<RailFact> railFacts;

  /// The page's rendered content.
  final String content;

  /// The colophon's link columns.
  final List<FooterColumn> footerColumns;
}

/// Renders a complete HTML document for [page].
String renderSitePage(SitePage page) {
  final base = page.basePath;
  final out = StringBuffer();
  out.writeln('<!DOCTYPE html>');
  out.writeln('<html lang="en">');
  out.writeln('<head>');
  out.writeln('<meta charset="utf-8">');
  out.writeln(
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
  );
  out.writeln('<title>${_text(page.docTitle)}</title>');
  out.writeln('<meta name="description" content="${_attr(page.description)}">');
  out.writeln('<meta property="og:title" content="${_attr(page.docTitle)}">');
  out.writeln(
    '<meta property="og:description" content="${_attr(page.description)}">',
  );
  out.writeln('<meta property="og:type" content="${_attr(page.ogType)}">');
  out.writeln('<link rel="stylesheet" href="${base}assets/style.css">');
  out.writeln('</head>');
  out.writeln('<body>');
  out.writeln('<a class="skip-link" href="#content">Skip to content</a>');
  out.write(_masthead(page));
  out.writeln('<div class="frame">');
  out.write(_rail(page));
  out.writeln('<main class="doc" id="content">');
  out.writeln('<article class="page">');
  out.writeln('<header class="page-head">');
  if (page.kicker.isNotEmpty) {
    out.writeln('<p class="kicker">${_text(page.kicker)}</p>');
  }
  out.writeln('<h1 class="page-title">${_text(page.title)}</h1>');
  out.writeln('</header>');
  out.write(page.content);
  out.writeln('</article>');
  out.writeln('</main>');
  out.writeln('</div>');
  out.write(_colophon(page));
  out.writeln('</body>');
  out.writeln('</html>');
  return out.toString();
}

String _masthead(SitePage page) {
  final out = StringBuffer();
  out.writeln('<header class="masthead">');
  out.writeln('<div class="masthead-inner">');
  out.writeln(
    '<a class="wordmark" href="${page.basePath}index.html">dart-gir</a>',
  );
  out.writeln(
    '<p class="masthead-meta">'
    'Dart FFI bindings for GObject · BSD-3-Clause</p>',
  );
  out.writeln('</div>');
  out.writeln('<nav class="nav" aria-label="Primary">');
  for (final entry in page.nav) {
    final current = entry.href == page.activePath;
    final currentAttribute = current ? ' aria-current="page"' : '';
    final classes = entry.variant.isEmpty
        ? 'nav-item'
        : 'nav-item nav-item--${entry.variant}';
    final classAttribute = current ? '$classes is-current' : classes;
    out.writeln(
      '<a class="$classAttribute"$currentAttribute '
      'href="${page.basePath}${entry.href}">${_text(entry.label)}</a>',
    );
  }
  out.writeln('</nav>');
  out.writeln('</header>');
  return out.toString();
}

String _rail(SitePage page) {
  final out = StringBuffer();
  out.writeln('<aside class="rail">');
  if (page.sections.isNotEmpty) {
    out.writeln('<nav class="rail-toc" aria-label="On this page">');
    out.writeln('<p class="rail-heading">On this page</p>');
    out.writeln('<ol class="rail-list">');
    for (final section in page.sections) {
      out.writeln(
        '<li><a href="#${section.id}">'
        '<span class="rail-num">${section.number}</span>'
        '${_text(plainText(section.title))}</a></li>',
      );
    }
    out.writeln('</ol>');
    out.writeln('</nav>');
  }
  if (page.railFacts.isNotEmpty) {
    out.writeln('<div class="rail-meta">');
    out.writeln('<p class="rail-heading">At a glance</p>');
    out.writeln('<dl class="rail-facts">');
    for (final fact in page.railFacts) {
      out.writeln(
        '<div class="rail-fact"><dt>${_text(fact.label)}</dt>'
        '<dd>${_text(fact.value)}</dd></div>',
      );
    }
    out.writeln('</dl>');
    out.writeln('</div>');
  }
  out.writeln('</aside>');
  return out.toString();
}

String _colophon(SitePage page) {
  final out = StringBuffer();
  out.writeln('<footer class="colophon">');
  out.writeln('<div class="colophon-inner">');
  out.writeln('<div class="colophon-about">');
  out.writeln('<p class="colophon-name">dart-gir</p>');
  out.writeln('<p>Dart FFI bindings for the GObject ecosystem.</p>');
  out.writeln(
    '<p class="colophon-fine">'
    'Copyright © 2026 Andrey Maksimov · BSD-3-Clause</p>',
  );
  out.writeln(
    '<p class="colophon-fine">'
    'Generated code is committed; the generator is the source of truth.</p>',
  );
  out.writeln('</div>');
  out.writeln('<nav class="colophon-links" aria-label="Footer">');
  for (final column in page.footerColumns) {
    out.writeln('<div class="colophon-column">');
    out.writeln('<p class="colophon-heading">${_text(column.heading)}</p>');
    out.writeln('<ul>');
    for (final link in column.links) {
      final target = link.external ? ' rel="noopener"' : '';
      final href = link.external ? link.href : '${page.basePath}${link.href}';
      out.writeln('<li><a href="$href"$target>${_text(link.label)}</a></li>');
    }
    out.writeln('</ul>');
    out.writeln('</div>');
  }
  out.writeln('</nav>');
  out.writeln('</div>');
  out.writeln('</footer>');
  return out.toString();
}

String _text(String value) => escapeHtml(value);

String _attr(String value) => escapeHtml(value);
