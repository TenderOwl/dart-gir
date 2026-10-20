// The facts layer.
//
// The facts are derived from the repository, so the tests check the
// derivation: that a skip report is parsed correctly, that the groups
// add up, that the curated package list is well-formed, and that the
// committed `facts.json` is what the collector produces today.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/collect_facts.dart';
import '../../tool/site/facts.dart';

void main() {
  group('skip reports', () {
    const report = '''
# Skip report for package glib (GLib 2.0)
Total skipped: 351

## By category
callable: 332
alias: 13

## By reason
introspectable=0: 98
return: array of TypeKind.string (later phase): 6
inout parameter rc: 2

## First 50 entries
[constant] GLib.CSET_a_2_z — duplicate constant: ...
''';

    test('the header gives the package and the namespace', () {
      final parsed = parseSkipReport(report)!;
      expect(parsed.package, 'glib');
      expect(parsed.namespace, 'GLib 2.0');
      expect(parsed.total, 351);
    });

    test('the category block is parsed', () {
      final parsed = parseSkipReport(report)!;
      expect(parsed.byCategory, <String, int>{'callable': 332, 'alias': 13});
    });

    test('the reason block is parsed, including colons in the reason', () {
      final parsed = parseSkipReport(report)!;
      expect(parsed.byReason['introspectable=0'], 98);
      expect(
        parsed.byReason['return: array of TypeKind.string (later phase)'],
        6,
      );
      expect(parsed.byReason['inout parameter rc'], 2);
    });

    test('the entries after the reason block are not reasons', () {
      final parsed = parseSkipReport(report)!;
      expect(parsed.byReason, hasLength(3));
    });

    test('content that is not a report is rejected', () {
      expect(parseSkipReport('hello'), isNull);
    });
  });

  group('aggregation', () {
    test('every reason lands in exactly one group', () {
      final reports = <SkipReport>[
        parseSkipReport('''
# Skip report for package a (A 1.0)
Total skipped: 4

## By category
callable: 4

## By reason
missing getter get_label: 2
introspectable=0: 1
moved to Foo.bar: 1
''')!,
      ];
      final counts = aggregateSkipGroups(reports);
      expect(counts['missing_getter'], 2);
      expect(counts['c_macro'], 1);
      expect(counts['other'], 1);
      expect(counts.values.reduce((a, b) => a + b), 4);
    });

    test('the groups add up to the total across the real reports', () {
      final root = Directory.current.path;
      final facts = Facts.decode(
        File('$root/site_src/data/facts.json').readAsStringSync(),
      );
      final skips = facts.data['skips']! as Map<String, Object?>;
      final sum = skips.values.whereType<int>().fold<int>(
        0,
        (total, count) => total + count,
      );
      final total = facts.data['total_skipped']! as int;
      expect(sum, total);
    });
  });

  group('the workspace list', () {
    test('is read out of the root pubspec', () {
      const pubspec = '''
name: dart_gir
environment:
  sdk: ^3.13.4

workspace:
  - example/todo
  - packages/glib
  - packages/gtk4
''';
      expect(parseWorkspaceList(pubspec), <String>{'glib', 'gtk4'});
    });

    test('the SDK constraint is read out of the pubspec', () {
      expect(parseSdkConstraint('environment:\n  sdk: ^3.13.4\n'), '^3.13.4');
    });
  });

  group('the committed facts', () {
    final root = Directory.current.path;

    test('match what the collector produces today', () {
      final committed = File('$root/site_src/data/facts.json')
          .readAsStringSync();
      expect(collectFacts(root), committed);
    });

    test('are stable across runs', () {
      expect(collectFacts(root), collectFacts(root));
    });

    test('carry the totals the site quotes', () {
      final facts = Facts.decode(
        File('$root/site_src/data/facts.json').readAsStringSync(),
      );
      expect(facts.lookup('total_skipped'), isNotNull);
      expect(facts.lookup('license'), 'BSD-3-Clause');
      expect(facts.lookup('sdk_constraint'), '^3.13.4');
      expect(facts.lookup('features.typed_signals'), isNotNull);
      expect(facts.lookup('package_skips.glib'), '351');
    });
  });

  group('the curated package list', () {
    test('has an entry for every workspace package', () {
      final root = Directory.current.path;
      final workspace = parseWorkspaceList(
        File('$root/pubspec.yaml').readAsStringSync(),
      );
      final packages = readPackages('$root/site_src/data/packages.json');
      final names = packages.map((package) => package.name).toSet();
      for (final name in workspace) {
        expect(names, contains(name), reason: '$name is missing');
      }
    });

    test('every entry has a name and a blurb', () {
      final root = Directory.current.path;
      for (final package in readPackages('$root/site_src/data/packages.json')) {
        expect(package.name, isNotEmpty);
        expect(package.blurb, isNotEmpty);
        expect(package.role, isNotEmpty);
      }
    });

    test('a generated package names its namespace and native library', () {
      final root = Directory.current.path;
      for (final package in readPackages('$root/site_src/data/packages.json')) {
        if (!package.generated) continue;
        expect(package.namespace, isNotEmpty, reason: package.name);
        expect(package.native, isNotEmpty, reason: package.name);
      }
    });
  });
}
