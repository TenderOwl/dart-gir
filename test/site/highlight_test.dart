// The code highlighter.
//
// The site used to hand-tokenise its code samples in the HTML; the
// highlighter does the same job from the fenced block's language.

import 'package:test/test.dart';

import '../../tool/site/highlight.dart';

void main() {
  group('dart', () {
    test('keywords are marked', () {
      expect(
        highlight('final x = 1;', 'dart'),
        contains('<span class="tok-k">final</span>'),
      );
    });

    test('strings are marked', () {
      expect(
        highlight("x = 'a';", 'dart'),
        contains('<span class="tok-s">\'a\'</span>'),
      );
    });

    test('comments are marked', () {
      expect(
        highlight('// note', 'dart'),
        contains('<span class="tok-c">// note</span>'),
      );
    });

    test('numbers are marked', () {
      expect(
        highlight('x = 42;', 'dart'),
        contains('<span class="tok-n">42</span>'),
      );
    });

    test('a call is marked', () {
      expect(
        highlight('print(x);', 'dart'),
        contains('<span class="tok-f">print</span>'),
      );
    });

    test('annotations are marked', () {
      expect(
        highlight('@override', 'dart'),
        contains('<span class="tok-f">@override</span>'),
      );
    });

    test('markup in the source is escaped', () {
      expect(highlight('a < b && c > d', 'dart'), isNot(contains('< b')));
      expect(highlight('a < b && c > d', 'dart'), contains('&lt;'));
    });
  });

  group('c', () {
    test('keywords, types and comments are marked', () {
      final html = highlight('int main(void) { return 0; } // done', 'c');
      expect(html, contains('<span class="tok-t">int</span>'));
      expect(html, contains('<span class="tok-k">return</span>'));
      expect(html, contains('<span class="tok-c">// done</span>'));
    });
  });

  group('shell', () {
    test('a hash starts a comment', () {
      expect(
        highlight('# a comment', 'sh'),
        contains('<span class="tok-c"># a comment</span>'),
      );
    });

    test('a variable is marked', () {
      expect(
        highlight(r'echo $HOME', 'sh'),
        contains('<span class="tok-t">\$HOME</span>'),
      );
    });
  });

  group('unknown languages', () {
    test('render as plain escaped text', () {
      expect(
        highlight('<b> & </b>', 'brainfuck'),
        '&lt;b&gt; &amp; &lt;/b&gt;',
      );
    });
  });
}
