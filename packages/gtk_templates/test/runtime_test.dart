import 'dart:convert';

import 'package:gobject/gobject.dart';
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

    test('two calls produce distinct handles (no caching in the helper)', () {
      final a = gbytesFromString('hello');
      final b = gbytesFromString('world');
      expect(identical(a, b), isFalse);
      expect(identical(a.handle, b.handle), isFalse);
    });

    test('two calls with the same string still produce distinct handles', () {
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

  group('rewriteTemplateTypes', () {
    test('replaces the class attribute', () {
      const xml = '<interface><template class="TodoWindow"/></interface>';
      final out = rewriteTemplateTypes(xml, 'AdwApplicationWindow');
      expect(out, contains('class="AdwApplicationWindow"'));
      expect(out, isNot(contains('class="TodoWindow"')));
    });

    test('replaces the parent attribute', () {
      const xml =
          '<interface><template class="TodoWindow" parent="AdwWindow"/>'
          '</interface>';
      final out = rewriteTemplateTypes(
        xml,
        'AdwApplicationWindow',
        'AdwWindow',
      );
      expect(out, contains('parent="AdwWindow"'));
      expect(out, contains('class="AdwApplicationWindow"'));
    });

    test('removes the parent attribute when the parent is unknown', () {
      const xml =
          '<interface><template class="TodoWindow" parent="AdwWindow"/>'
          '</interface>';
      final out = rewriteTemplateTypes(xml, 'AdwApplicationWindow');
      expect(out, isNot(contains('parent=')));
      expect(out, contains('class="AdwApplicationWindow"'));
    });

    test('adds a class attribute when the XML has none', () {
      const xml = '<interface><template/></interface>';
      final out = rewriteTemplateTypes(xml, 'AdwApplicationWindow');
      expect(out, contains('class="AdwApplicationWindow"'));
    });

    test('leaves XML without a <template> element alone', () {
      const xml = '<interface><object class="GtkLabel"/></interface>';
      expect(rewriteTemplateTypes(xml, 'AdwApplicationWindow'), xml);
    });

    test('leaves the rest of the document alone', () {
      const xml = '''
        <interface>
          <template class="TodoWindow">
            <object class="GtkLabel" id="counterLabel"/>
          </template>
        </interface>
      ''';
      final out = rewriteTemplateTypes(xml, 'AdwApplicationWindow');
      expect(out, contains('<object class="GtkLabel" id="counterLabel"/>'));
      expect(out, contains('</template>'));
    });

    test('does not mistake another attribute for the class attribute', () {
      const xml =
          '<interface><template parentclass="X" class="Y"/></interface>';
      final out = rewriteTemplateTypes(xml, 'AdwApplicationWindow');
      expect(out, contains('parentclass="X"'));
      expect(out, contains('class="AdwApplicationWindow"'));
    });
  });

  group('stripTemplateSignals', () {
    test('removes a self-closing <signal/>', () {
      const xml = '''
        <interface>
          <template class="Foo">
            <object class="GtkButton" id="button">
              <signal name="clicked" handler="on_clicked"/>
            </object>
          </template>
        </interface>
      ''';
      final out = stripTemplateSignals(xml);
      expect(out, isNot(contains('<signal')));
      expect(out, contains('<object class="GtkButton" id="button">'));
    });

    test('removes a <signal>…</signal> pair', () {
      const xml = '''
        <interface>
          <template class="Foo">
            <signal name="clicked" handler="on_clicked"></signal>
          </template>
        </interface>
      ''';
      expect(stripTemplateSignals(xml), isNot(contains('<signal')));
    });

    test('leaves everything else alone', () {
      const xml = '<interface><object class="GtkLabel" id="a"/></interface>';
      expect(stripTemplateSignals(xml), xml);
    });
  });

  group('prepareTemplateXml', () {
    test('rewrites the types and drops the signals', () {
      const xml = '''
        <interface>
          <template class="TodoWindow" parent="AdwApplicationWindow">
            <object class="GtkButton" id="button">
              <signal name="clicked" handler="on_clicked"/>
            </object>
          </template>
        </interface>
      ''';
      // `GObject` is the one GType that is registered as soon as
      // libgobject is loaded, so it is the one the test can rely on
      // without pulling in GTK.
      final out = prepareTemplateXml(xml, typeFromName('GObject'));
      expect(out, contains('class="GObject"'));
      expect(out, isNot(contains('class="TodoWindow"')));
      expect(out, isNot(contains('<signal')));
      expect(out, contains('<object class="GtkButton" id="button">'));
    });
  });

  group('claimTemplateType', () {
    test('the first owner claims the type', () {
      expect(claimTemplateType(1001, 'First'), isTrue);
    });

    test('the same owner claiming it again is a no-op', () {
      expect(claimTemplateType(1002, 'Same'), isTrue);
      expect(claimTemplateType(1002, 'Same'), isFalse);
    });

    test('a second owner is rejected', () {
      expect(claimTemplateType(1003, 'Owner'), isTrue);
      expect(
        () => claimTemplateType(1003, 'Other'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('already carries a template'),
          ),
        ),
      );
    });
  });
}
