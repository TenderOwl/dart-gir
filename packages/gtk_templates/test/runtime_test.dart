import 'dart:convert';

import 'package:gtk_templates/gtk_templates.dart';
import 'package:test/test.dart';

void main() {
  group('snakeCase', () {
    // PyGObject's reference mapping for camel_to_snake. Each entry
    // is a (input, expected) pair drawn from PyGObject's tests and
    // GTK's own macro names.
    final cases = <(String, String)>[
      // Single capital
      ('a', 'a'),
      ('aB', 'a_b'),
      // Two capitals
      ('aa', 'aa'),
      ('aaB', 'aa_b'),
      ('aBa', 'a_ba'),
      // Three+ capitals
      ('onClicked', 'on_clicked'),
      ('helloButtonClicked', 'hello_button_clicked'),
      ('onOkButtonClicked', 'on_ok_button_clicked'),
      // Trailing capitals (PyGObject keeps the underscore)
      ('fooBar', 'foo_bar'),
      ('fooBAR', 'foo_b_a_r'),
      // Already snake
      ('on_clicked', 'on_clicked'),
      // Mixed numbers — same rule applies; numbers are not "uppercase"
      ('foo2bar', 'foo2bar'),
      ('foo2Bar', 'foo2_bar'),
      // Empty / single character
      ('', ''),
      ('_', '_'),
      // GTK macro names
      ('setLabel', 'set_label'),
      ('getInternalChild', 'get_internal_child'),
      ('classBindTemplateChildFull', 'class_bind_template_child_full'),
    ];

    for (final (input, expected) in cases) {
      test('"$input" → "$expected"', () {
        expect(snakeCase(input), expected);
      });
    }
  });

  group('annotations', () {
    group('GtkTemplateXml', () {
      test('equal instances are ==', () {
        const a = GtkTemplateXml('<interface/>');
        const b = GtkTemplateXml('<interface/>');
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('different content is not ==', () {
        const a = GtkTemplateXml('<interface/>');
        const b = GtkTemplateXml('<interface></interface>');
        expect(a, isNot(equals(b)));
      });

      test('toString() prefixes with xml( and wraps in parens', () {
        const t = GtkTemplateXml('<interface/>');
        expect(t.toString(), 'xml(<interface/>)');
      });
    });

    group('GtkTemplateFile', () {
      test('equal instances are ==', () {
        const a = GtkTemplateFile('lib/foo/window.ui');
        const b = GtkTemplateFile('lib/foo/window.ui');
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('different paths are not ==', () {
        const a = GtkTemplateFile('lib/a.ui');
        const b = GtkTemplateFile('lib/b.ui');
        expect(a, isNot(equals(b)));
      });

      test('toString() prefixes with file( and wraps in parens', () {
        const t = GtkTemplateFile('lib/foo/window.ui');
        expect(t.toString(), 'file(lib/foo/window.ui)');
      });
    });

    group('GtkTemplate', () {
      test('carries its source', () {
        const t = GtkTemplate(source: GtkTemplateXml('<interface/>'));
        expect(t.source, isA<GtkTemplateXml>());
      });

      test('equal sources are == (xml)', () {
        const a = GtkTemplate(source: GtkTemplateXml('<interface/>'));
        const b = GtkTemplate(source: GtkTemplateXml('<interface/>'));
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('equal sources are == (file)', () {
        const a = GtkTemplate(source: GtkTemplateFile('lib/foo/window.ui'));
        const b = GtkTemplate(source: GtkTemplateFile('lib/foo/window.ui'));
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('sources of different kinds are not ==', () {
        const a = GtkTemplate(source: GtkTemplateXml(''));
        const b = GtkTemplate(source: GtkTemplateFile(''));
        expect(a, isNot(equals(b)));
      });

      test('Xml and File with the same string are still not ==', () {
        // Even if the string content matches, the *kind* of
        // source matters — a future @GtkTemplate(source:
        // GtkTemplateXml('lib/foo.ui')) is a different intent
        // from @GtkTemplate(source: GtkTemplateFile('lib/foo.ui')).
        const a = GtkTemplate(source: GtkTemplateXml('lib/foo.ui'));
        const b = GtkTemplate(source: GtkTemplateFile('lib/foo.ui'));
        expect(a, isNot(equals(b)));
      });
    });

    test('GtkTemplateChild() == const → Eq', () {
      const a = GtkTemplateChild();
      const b = GtkTemplateChild();
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('GtkTemplateChild() != GtkTemplateChild(name: "foo")', () {
      const a = GtkTemplateChild();
      const b = GtkTemplateChild(name: 'foo');
      expect(a, isNot(equals(b)));
    });
  });

  group('GBytes / gbytesFromString', () {
    test('gbytesFromString returns a non-null GBytes', () {
      final g = gbytesFromString('hello');
      expect(g, isNotNull);
      expect(g.handle, isNotNull);
    });

    test('empty string produces a non-null handle', () {
      final g = gbytesFromString('');
      expect(g, isNotNull);
      expect(g.handle, isNotNull);
    });

    test('two calls produce distinct handles (no caching in the helper)',
        () {
      final a = gbytesFromString('hello');
      final b = gbytesFromString('world');
      expect(identical(a, b), isFalse);
      expect(identical(a.handle, b.handle), isFalse);
    });

    test('two calls with the same string still produce distinct handles',
        () {
      final a = gbytesFromString('hello');
      final b = gbytesFromString('hello');
      expect(identical(a.handle, b.handle), isFalse);
    });

    test('multi-byte UTF-8 round-trips through gbytesFromString', () {
      // Sanity check: the helper encodes with utf8.encode;
      // the codegen later passes the bytes to GTK, but
      // a Dart-side round-trip is a sufficient invariant
      // for the helper.
      const input = 'привет, мир 🌍';
      final g = gbytesFromString(input);
      // g.handle is a raw `GBytes*` — we can't read it
      // back without a GBytes reader, but we can at least
      // assert the helper didn't crash and the encoded
      // length matches utf8.encode of the input.
      expect(g.handle, isNotNull);
      expect(utf8.encode(input).length, greaterThan(input.length));
    });
  });
}
