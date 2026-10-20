// The page shell.
//
// The shell used to be duplicated verbatim in every page, which is how
// the pages drifted apart. It is written once now, and the API
// reference landing page — one directory down — uses it too.

import 'package:test/test.dart';

import '../../tool/site/layout.dart';
import '../../tool/site/markdown.dart';

SitePage _page({
  String basePath = '',
  String activePath = 'index.html',
  List<Section> sections = const <Section>[],
}) {
  return SitePage(
    title: 'A title',
    docTitle: 'dart-gir — A title',
    description: 'A description.',
    kicker: 'A kicker',
    ogType: 'website',
    basePath: basePath,
    activePath: activePath,
    nav: const <NavEntry>[
      NavEntry('index.html', 'Home', 1),
      NavEntry('features.html', 'Features', 2),
      NavEntry('docs/', 'API reference →', 99, variant: 'api'),
    ],
    sections: sections,
    railFacts: const <RailFact>[RailFact('packages', '16')],
    content: '<p>Body.</p>',
    footerColumns: const <FooterColumn>[
      FooterColumn('Project', <FooterLink>[
        FooterLink('features.html', 'Features'),
        FooterLink('https://example.com', 'External', external: true),
      ]),
    ],
  );
}

void main() {
  group('head', () {
    test('carries the metadata', () {
      final html = renderSitePage(_page());
      expect(html, contains('<title>dart-gir — A title</title>'));
      expect(
        html,
        contains('<meta name="description" content="A description.">'),
      );
      expect(html, contains('<meta property="og:type" content="website">'));
      expect(html, contains('<link rel="stylesheet" href="assets/style.css">'));
    });

    test('the stylesheet path follows the base path', () {
      final html = renderSitePage(_page(basePath: '../'));
      expect(html, contains('href="../assets/style.css"'));
    });
  });

  group('masthead and navigation', () {
    test('the wordmark and the meta line are present', () {
      final html = renderSitePage(_page());
      expect(html, contains('class="wordmark"'));
      expect(html, contains('Dart FFI bindings for GObject'));
    });

    test('the current page is marked with aria-current', () {
      final html = renderSitePage(_page());
      expect(
        html,
        contains(
          '<a class="nav-item is-current" aria-current="page" '
          'href="index.html">Home</a>',
        ),
      );
      expect(html, isNot(contains('aria-current="page" href="features.html"')));
    });

    test('no page is current on a page outside the navigation', () {
      final html = renderSitePage(_page(activePath: 'docs/'));
      expect(html, contains('aria-current="page" href="docs/"'));
    });

    test('links follow the base path', () {
      final html = renderSitePage(_page(basePath: '../'));
      expect(html, contains('href="../features.html"'));
    });
  });

  group('rail', () {
    test('lists the sections with their numbers', () {
      final html = renderSitePage(
        _page(
          sections: const <Section>[
            Section(
              number: '01',
              id: 'first',
              title: 'First section',
              blocks: <MarkdownBlock>[],
            ),
          ],
        ),
      );
      expect(html, contains('class="rail-toc"'));
      expect(
        html,
        contains(
          '<a href="#first"><span class="rail-num">01</span>'
          'First section</a>',
        ),
      );
    });

    test('shows the derived facts', () {
      final html = renderSitePage(_page());
      expect(html, contains('<dt>packages</dt><dd>16</dd>'));
    });
  });

  group('colophon', () {
    test('lists the footer columns', () {
      final html = renderSitePage(_page());
      expect(html, contains('class="colophon"'));
      expect(html, contains('Features'));
    });

    test('external links are not prefixed with the base path', () {
      final html = renderSitePage(_page(basePath: '../'));
      expect(html, contains('href="https://example.com"'));
      expect(html, isNot(contains('href="../https://example.com"')));
    });
  });

  test('the document is a complete HTML page', () {
    final html = renderSitePage(_page());
    expect(html, startsWith('<!DOCTYPE html>'));
    expect(html, contains('<html lang="en">'));
    expect(html.trimRight(), endsWith('</html>'));
  });
}
