// The generated site.
//
// The site's output is committed, and CI regenerates it and fails if the
// committed copy differs. This test is the same check, runnable
// anywhere: it renders the pages from `site_src/` in memory and
// compares the result with what is in `site/`.
//
// It also carries the link check that used to live in CI as an
// ad-hoc Python snippet.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/build_site.dart';
import '../../tool/site/facts.dart';

void main() {
  final root = Directory.current.path;
  final build = buildSite(root);

  group('the committed site', () {
    test('matches what the generator produces', () {
      expect(
        diffSite(root, build),
        isEmpty,
        reason: 'run `dart run tool/build_site.dart` and commit the result',
      );
    });

    test('has a page for every source', () {
      final sources = Directory('$root/$sourceDirectory/pages')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .length;
      expect(build.pages, hasLength(sources));
    });

    test('carries the stylesheet', () {
      expect(build.assets.keys, contains('style.css'));
    });
  });

  group('every page', () {
    for (final entry in build.pages.entries) {
      test('${entry.key} links to the API reference and marks itself', () {
        final html = entry.value;
        expect(html, contains('href="docs/">API reference →</a>'));
        expect(html, contains('href="docs/">API reference</a>'));
        expect(html, contains('aria-current="page"'));
        expect(
          html,
          contains('<link rel="stylesheet" href="assets/style.css">'),
        );
        expect(html, contains('class="colophon"'));
      });
    }
  });

  group('internal links', () {
    test('every one of them resolves', () {
      final broken = <String>[];
      for (final entry in build.pages.entries) {
        for (final href in _links(entry.value)) {
          if (href.startsWith('#')) continue;
          if (href.contains('://') || href.startsWith('mailto:')) continue;
          final path = href.split('#').first;
          if (path.isEmpty) continue;
          final target = path.endsWith('/')
              ? Directory('$root/$outputDirectory/$path')
              : File('$root/$outputDirectory/$path');
          if (target is File) {
            if (!target.existsSync()) {
              broken.add('${entry.key} → $href');
            }
            continue;
          }
          // A directory link needs an index inside it. The API
          // reference is a separate build and may be absent, so a
          // missing directory is reported rather than failed.
          final index = File('${target.path}/index.html');
          if (!target.existsSync()) {
            broken.add('${entry.key} → $href (no such directory)');
          } else if (!index.existsSync()) {
            broken.add('${entry.key} → $href (no index.html)');
          }
        }
      }
      expect(broken, isEmpty);
    });

    test('the rail anchors point at sections that exist', () {
      final broken = <String>[];
      for (final entry in build.pages.entries) {
        final ids = _sectionIds(entry.value)..add('content');
        for (final anchor in RegExp(
          r'href="#([^"]+)"',
        ).allMatches(entry.value).map((match) => match.group(1)!)) {
          if (!ids.contains(anchor)) broken.add('${entry.key} → #$anchor');
        }
      }
      expect(broken, isEmpty);
    });

    test('a cross-page anchor points at a section that exists', () {
      final broken = <String>[];
      for (final entry in build.pages.entries) {
        for (final match in RegExp(
          r'href="([a-z_]+\.html)#([^"]+)"',
        ).allMatches(entry.value)) {
          final target = match.group(1)!;
          final anchor = match.group(2)!;
          final page = build.pages[target];
          if (page == null) {
            broken.add('${entry.key} → $target (no such page)');
            continue;
          }
          if (!_sectionIds(page).contains(anchor)) {
            broken.add('${entry.key} → $target#$anchor (no such section)');
          }
        }
      }
      expect(broken, isEmpty);
    });
  });

  group('the page sources', () {
    test('carry no hand-typed skip counts', () {
      final facts = Facts.decode(
        File('$root/site_src/data/facts.json').readAsStringSync(),
      );
      final packageSkips = facts.data['package_skips']! as Map<String, Object?>;
      // Every per-package skip total, and the grand total. A count
      // below 100 is too common in prose to be a useful signal.
      final forbidden = <int>{
        facts.data['total_skipped']! as int,
        for (final value in packageSkips.values)
          if (value is int && value >= 100) value,
      };
      final offenders = <String>[];
      for (final file in Directory(
        '$root/$sourceDirectory/pages',
      ).listSync().whereType<File>()) {
        final name = file.path.split(Platform.pathSeparator).last;
        final source = file.readAsStringSync();
        for (final count in forbidden) {
          final pattern = RegExp('(?<![\\w./])$count(?![\\w./])');
          if (pattern.hasMatch(source)) {
            offenders.add('$name: $count');
          }
        }
        // A count written with a thousands separator, too.
        final grouped = RegExp(r'\b\d{1,3}(?:,\d{3})+\b');
        if (grouped.hasMatch(source)) {
          offenders.add('$name: a grouped number');
        }
      }
      expect(offenders, isEmpty);
    });

    test('name every package they mention in the curated list', () {
      final names = readPackages('$root/$sourceDirectory/data/packages.json')
          .map((package) => package.name)
          .toSet();
      final offenders = <String>[];
      for (final file in Directory(
        '$root/$sourceDirectory/pages',
      ).listSync().whereType<File>()) {
        final name = file.path.split(Platform.pathSeparator).last;
        final source = file.readAsStringSync();
        for (final match in RegExp(
          r'`(gtk4|glib|gio|gobject|adw|cairo|pango|gdk4|gsk4|'
          r'graphene|gtk_source5|gdk_pixbuf|gi_repository3|gir_ffi|'
          r'gtk_templates|gtk_templates_builder)`',
        ).allMatches(source)) {
          if (!names.contains(match.group(1))) {
            offenders.add('$name: ${match.group(1)}');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}

/// Every `href` in an HTML document.
List<String> _links(String html) =>
    RegExp(r'href="([^"]*)"')
        .allMatches(html)
        .map((match) => match.group(1)!)
        .toList();

/// The section anchors a page defines.
Set<String> _sectionIds(String html) =>
    RegExp(r'<section class="section" id="([^"]+)"')
        .allMatches(html)
        .map((match) => match.group(1)!)
        .toSet();
