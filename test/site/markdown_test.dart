// The Markdown subset the site generator understands.
//
// Every construct in the subset gets a test here. The renderer is the
// largest new piece of code in the site pipeline and the easiest place
// for a subtle bug to hide, so the tests are explicit about the exact
// HTML each construct produces.

import 'package:test/test.dart';

import '../../tool/site/directives.dart';
import '../../tool/site/facts.dart';
import '../../tool/site/frontmatter.dart';
import '../../tool/site/markdown.dart';

void main() {
  group('front matter', () {
    test('is parsed and the body is returned', () {
      final front = parseFrontMatter('''
---
title: Features
nav_order: 2
---
Body text.
''');
      expect(front.title, 'Features');
      expect(front.navOrder, 2);
      expect(front.body.trim(), 'Body text.');
    });

    test('unquotes values', () {
      final front = parseFrontMatter('''
---
title: "A quoted title"
description: 'single quoted'
---
''');
      expect(front.title, 'A quoted title');
      expect(front.description, 'single quoted');
    });

    test('a source without front matter keeps its body', () {
      final front = parseFrontMatter('Just a body.');
      expect(front.values, isEmpty);
      expect(front.body, 'Just a body.');
    });

    test('an unterminated block is an error', () {
      expect(
        () => parseFrontMatter('---\ntitle: x\n'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('headings', () {
    test('become blocks with their level', () {
      final blocks = parseBlocks('# One\n\n## Two\n\n### Three');
      expect(blocks, hasLength(3));
      expect((blocks[0] as HeadingBlock).level, 1);
      expect((blocks[0] as HeadingBlock).text, 'One');
      expect((blocks[1] as HeadingBlock).level, 2);
      expect((blocks[2] as HeadingBlock).level, 3);
    });

    test('a hash without a space is not a heading', () {
      final blocks = parseBlocks('#not a heading');
      expect(blocks.single, isA<ParagraphBlock>());
    });

    test('trailing hashes are stripped', () {
      final blocks = parseBlocks('## Title ##');
      expect((blocks.single as HeadingBlock).text, 'Title');
    });
  });

  group('sections', () {
    test('split the document and are numbered', () {
      final document = parseMarkdown('''
Intro paragraph.

## First

Body one.

## Second

Body two.
''');
      expect(document.preamble, hasLength(1));
      expect(document.sections, hasLength(2));
      expect(document.sections.first.number, '01');
      expect(document.sections.last.number, '02');
      expect(document.sections.first.id, 'first');
    });

    test('slugs ignore punctuation and inline markup', () {
      expect(
        slugify('Why it isn\'t a "GTK bindings" project'),
        'why-it-isn-t-a-gtk-bindings-project',
      );
      expect(
        slugify('Typed `props` and **signals**'),
        'typed-props-and-signals',
      );
    });
  });

  group('lists', () {
    test('unordered items are collected', () {
      final blocks = parseBlocks('- one\n- two');
      final list = blocks.single as ListBlock;
      expect(list.ordered, isFalse);
      expect(list.items, hasLength(2));
      expect((list.items.first.blocks.single as ParagraphBlock).text, 'one');
    });

    test('ordered items are marked as such', () {
      final list = parseBlocks('1. one\n2. two').single as ListBlock;
      expect(list.ordered, isTrue);
      expect(list.items, hasLength(2));
    });

    test('a nested list becomes a child block', () {
      final list =
          parseBlocks('''
- outer
  - inner
''').single
              as ListBlock;
      final outer = list.items.single.blocks;
      expect(outer.first, isA<ParagraphBlock>());
      expect(outer.last, isA<ListBlock>());
    });

    test('a lazy continuation stays with its item', () {
      final list =
          parseBlocks('''
- first line
continued
- second
''').single
              as ListBlock;
      expect(list.items, hasLength(2));
      expect(
        (list.items.first.blocks.single as ParagraphBlock).text,
        'first line continued',
      );
    });
  });

  group('tables', () {
    test('rows and alignment are parsed', () {
      final table =
          parseBlocks('''
| Name | Count |
| --- | ---: |
| a | 1 |
''').single
              as TableBlock;
      expect(table.headers, <String>['Name', 'Count']);
      expect(table.alignments[1], ColumnAlignment.right);
      expect(table.rows.single, <String>['a', '1']);
    });
  });

  group('code fences', () {
    test('the language and the title are read from the info string', () {
      final code =
          parseBlocks('''
```dart title="props.dart"
final x = 1;
```
''').single
              as CodeBlock;
      expect(code.language, 'dart');
      expect(code.title, 'props.dart');
      expect(code.code, 'final x = 1;');
    });

    test('an unterminated fence is an error', () {
      expect(
        () => parseBlocks('```dart\nfinal x = 1;'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('raw HTML', () {
    test('is passed through verbatim', () {
      final html =
          parseBlocks('''
<figure>
  <svg viewBox="0 0 10 10">
    <rect x="1" y="1" width="8" height="8"/>
  </svg>
</figure>
''').single
              as HtmlBlock;
      expect(html.html, contains('<svg viewBox="0 0 10 10">'));
      expect(html.html, contains('</figure>'));
    });

    test('a block that contains blank lines is not cut short', () {
      final html =
          parseBlocks('''
<svg>
  <text>a</text>

  <text>b</text>
</svg>
''').single
              as HtmlBlock;
      expect(html.html, contains('<text>b</text>'));
      expect(html.html.trimRight(), endsWith('</svg>'));
    });
  });

  group('inline', () {
    test('code spans are escaped and wrapped', () {
      expect(renderInline('a `<b>` c'), 'a <code>&lt;b&gt;</code> c');
    });

    test('strong and emphasis', () {
      expect(renderInline('**bold**'), '<strong>bold</strong>');
      expect(renderInline('*soft*'), '<em>soft</em>');
    });

    test('an underscore inside a word is not emphasis', () {
      expect(renderInline('get_surface'), 'get_surface');
    });

    test('links and images', () {
      expect(renderInline('[text](a.html)'), '<a href="a.html">text</a>');
      expect(renderInline('![alt](a.png)'), '<img src="a.png" alt="alt">');
    });

    test('autolinks', () {
      expect(
        renderInline('<https://example.com>'),
        '<a href="https://example.com">https://example.com</a>',
      );
    });

    test('existing entities survive, bare ampersands do not', () {
      expect(renderInline('a &amp; b & c'), 'a &amp; b &amp; c');
    });
  });

  group('directives', () {
    test('the header carries a name, a label and attributes', () {
      final header = parseDirectiveHeader(':::{phase status=done} Phase 0');
      expect(header.name, 'phase');
      expect(header.label, 'Phase 0');
      expect(header.attribute('status'), 'done');
    });

    test('attributes may sit inside the braces', () {
      final header = parseDirectiveHeader(':::{note variant=warn} Careful');
      expect(header.name, 'note');
      expect(header.attribute('variant'), 'warn');
      expect(header.label, 'Careful');
    });

    test('an apostrophe in a label is not a quote', () {
      final header = parseDirectiveHeader(":::{note} the project's licence");
      expect(header.label, "the project's licence");
    });

    test('an unknown directive is an error', () {
      expect(
        () => parseDirectiveHeader(':::{nope}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a directive block is parsed with its content', () {
      final blocks = parseBlocks('''
:::{note} Ownership
Text of the note.
:::
''');
      final directive = blocks.single as DirectiveBlock;
      expect(directive.name, 'note');
      expect(directive.label, 'Ownership');
      expect(directive.blocks, hasLength(1));
    });

    test('directives nest', () {
      final blocks = parseBlocks('''
:::{phase status=wip} Phase
:::{checklist}
[ ] a thing
:::
:::
''');
      final phase = blocks.single as DirectiveBlock;
      expect(phase.name, 'phase');
      final checklist = phase.blocks.single as DirectiveBlock;
      expect(checklist.name, 'checklist');
    });
  });

  group('facts', () {
    final facts = Facts(const <String, Object?>{
      'total_skipped': 3242,
      'skips': <String, Object?>{'c_macro': 150},
      'packages': <Object?>[
        <String, Object?>{'name': 'glib', 'skipped': 351},
      ],
    });

    test('a path resolves', () {
      expect(facts.lookup('total_skipped'), '3,242');
      expect(facts.lookup('skips.c_macro'), '150');
      expect(facts.lookup('packages.0.name'), 'glib');
    });

    test('an unknown path resolves to null', () {
      expect(facts.lookup('nope'), isNull);
      expect(facts.lookup('skips.nope'), isNull);
      expect(facts.lookup('packages.9.name'), isNull);
    });

    test('placeholders are substituted', () {
      expect(
        facts.substitute('a {{facts.total_skipped}} b', sourceName: 'x.md'),
        'a 3,242 b',
      );
    });

    test('an unknown placeholder fails with the file and the line', () {
      expect(
        () => facts.substitute(
          'ok\nbroken {{facts.nope}}\n',
          sourceName: 'page.md',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('page.md:2'), contains('facts.nope')),
          ),
        ),
      );
    });

    test('counts are grouped by thousands', () {
      expect(formatCount(3242), '3,242');
      expect(formatCount(351), '351');
      expect(formatCount(0), '0');
    });
  });
}
