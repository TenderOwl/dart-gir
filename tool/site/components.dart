// The design system.
//
// Every block the Markdown parser produces is turned into HTML here.
// The vocabulary is deliberately small — a masthead, a text navigation, a
// sticky rail, hairline-ruled tables, left-ruled notes — and every
// component is structural rather than decorative: no cards, no pills, no
// shadows, no gradients.
//
// The old site's class names (`badge`, `btn`, `stat`, `cell`, `tag`,
// `phase-head`) are retired; this file is the whole vocabulary.

import 'facts.dart';
import 'highlight.dart';
import 'markdown.dart';

/// The repository data a page's directives may draw on.
///
/// The `packages` directive renders the coverage table from the curated
/// package list and the derived skip counts, so the table cannot drift
/// from the repository.
class RenderContext {
  const RenderContext({
    this.packages = const <PackageEntry>[],
    this.packageSkips = const <String, int>{},
  });

  /// Every package the site documents.
  final List<PackageEntry> packages;

  /// The per-package skip counts, keyed by package name.
  final Map<String, int> packageSkips;
}

/// Renders a run of blocks.
String renderBlocks(List<MarkdownBlock> blocks, RenderContext context) {
  final out = StringBuffer();
  for (final block in blocks) {
    out.write(renderBlock(block, context));
  }
  return out.toString();
}

/// Renders one block.
String renderBlock(MarkdownBlock block, RenderContext context) {
  switch (block) {
    case HeadingBlock(:final level, :final text):
      return _heading(level, text);
    case ParagraphBlock(:final text):
      return '<p>${renderInline(text)}</p>';
    case ListBlock(:final ordered, :final items):
      return _list(ordered, items, context);
    case CodeBlock(:final language, :final title, :final code):
      return _code(language, title, code);
    case QuoteBlock(:final blocks):
      return '<blockquote class="quote">'
          '${renderBlocks(blocks, context)}</blockquote>';
    case TableBlock(:final headers, :final alignments, :final rows):
      return _table(headers, alignments, rows);
    case HtmlBlock(:final html):
      return html;
    case RuleBlock():
      return '<hr class="rule">';
    case final DirectiveBlock directive:
      return _directive(directive, context);
  }
}

/// Renders the content before the first `##` heading.
///
/// The first paragraph becomes the page's lede.
String renderPreamble(List<MarkdownBlock> blocks, RenderContext context) {
  final out = StringBuffer();
  var lede = true;
  for (final block in blocks) {
    if (lede && block is ParagraphBlock) {
      out.write('<p class="lede">${renderInline(block.text)}</p>');
      lede = false;
      continue;
    }
    lede = false;
    out.write(renderBlock(block, context));
  }
  return out.toString();
}

/// Renders one numbered section of a page.
String renderSection(Section section, RenderContext context) {
  final out = StringBuffer();
  out.write('<section class="section" id="${section.id}">');
  out.write(
    '<h2 class="section-title">'
    '<span class="section-num">${section.number}</span>'
    '${renderInline(section.title)}</h2>',
  );
  out.write(renderBlocks(section.blocks, context));
  out.write('</section>');
  return out.toString();
}

String _heading(int level, String text) {
  if (level == 1) return '<h1>${renderInline(text)}</h1>';
  if (level == 2) return '<h2>${renderInline(text)}</h2>';
  if (level == 3) return '<h3>${renderInline(text)}</h3>';
  if (level == 4) return '<h4>${renderInline(text)}</h4>';
  return '<h5>${renderInline(text)}</h5>';
}

String _list(bool ordered, List<ListItem> items, RenderContext context) {
  final tag = ordered ? 'ol' : 'ul';
  final out = StringBuffer('<$tag class="list">');
  for (final item in items) {
    final single =
        item.blocks.length == 1 && item.blocks.first is ParagraphBlock;
    final content = single
        ? renderInline((item.blocks.first as ParagraphBlock).text)
        : renderBlocks(item.blocks, context);
    out.write('<li>$content</li>');
  }
  out.write('</$tag>');
  return out.toString();
}

String _code(String language, String? title, String code) {
  final out = StringBuffer('<div class="code">');
  if (title != null && title.isNotEmpty) {
    out.write('<div class="code-title">${escapeHtml(title)}</div>');
  }
  out.write('<pre><code>');
  out.write(highlight(code, language));
  out.write('</code></pre></div>');
  return out.toString();
}

String _table(
  List<String> headers,
  List<ColumnAlignment> alignments,
  List<List<String>> rows,
) {
  final out = StringBuffer('<div class="table-scroll"><table>');
  out.write('<thead><tr>');
  for (var i = 0; i < headers.length; i++) {
    out.write(
      '<th${_alignClass(alignments, i)}>${renderInline(headers[i])}</th>',
    );
  }
  out.write('</tr></thead><tbody>');
  for (final row in rows) {
    out.write('<tr>');
    for (var i = 0; i < row.length; i++) {
      out.write(
        '<td${_alignClass(alignments, i)}>${renderInline(row[i])}</td>',
      );
    }
    out.write('</tr>');
  }
  out.write('</tbody></table></div>');
  return out.toString();
}

String _alignClass(List<ColumnAlignment> alignments, int index) {
  if (index >= alignments.length) return '';
  return switch (alignments[index]) {
    ColumnAlignment.none => '',
    ColumnAlignment.left => ' class="align-left"',
    ColumnAlignment.center => ' class="align-center"',
    ColumnAlignment.right => ' class="align-right"',
  };
}

// ------------------------------------------------------------- directives

String _directive(DirectiveBlock directive, RenderContext context) {
  return switch (directive.name) {
    'note' => _note(directive),
    'figure' => _figure(directive),
    'kv' => _kv(directive),
    'checklist' => _checklist(directive),
    'phase' => _phase(directive),
    'cols' => _cols(directive, context),
    'meta' => _meta(directive),
    'packages' => _packages(context),
    _ => throw FormatException('unknown directive "${directive.name}"'),
  };
}

/// A left-ruled aside. `variant=warn` and `variant=plain` change the
/// rule's colour.
String _note(DirectiveBlock directive) {
  final variant = directive.attribute('variant');
  final classes = variant == null || variant.isEmpty
      ? 'note'
      : 'note note--$variant';
  final out = StringBuffer('<aside class="$classes">');
  final label = directive.label;
  if (label != null && label.isNotEmpty) {
    out.write('<p class="note-label">${renderInline(label)}</p>');
  }
  out.write(renderBlocks(directive.blocks, const RenderContext()));
  out.write('</aside>');
  return out.toString();
}

/// Wraps raw HTML — the inline SVG diagrams — with an optional caption.
String _figure(DirectiveBlock directive) {
  final out = StringBuffer('<figure class="figure">');
  out.write(renderBlocks(directive.blocks, const RenderContext()));
  final label = directive.label;
  if (label != null && label.isNotEmpty) {
    out.write('<figcaption>${renderInline(label)}</figcaption>');
  }
  out.write('</figure>');
  return out.toString();
}

/// A label / value fact list.
String _kv(DirectiveBlock directive) {
  final rows = _directiveLines(directive.blocks);
  final out = StringBuffer('<dl class="kv">');
  for (final row in rows) {
    final colon = row.indexOf(':');
    final label = colon < 0 ? row : row.substring(0, colon).trim();
    final value = colon < 0 ? '' : row.substring(colon + 1).trim();
    out.write('<div class="kv-row"><dt>${renderInline(label)}</dt>');
    out.write('<dd>${renderInline(value)}</dd></div>');
  }
  out.write('</dl>');
  return out.toString();
}

/// A checklist. Items are marked `[x]` or `[ ]`.
String _checklist(DirectiveBlock directive) {
  final out = StringBuffer('<ul class="checklist">');
  for (final line in _directiveLines(directive.blocks)) {
    var text = line;
    var done = false;
    if (text.startsWith('[x]') || text.startsWith('[X]')) {
      done = true;
      text = text.substring(3).trim();
    } else if (text.startsWith('[ ]')) {
      text = text.substring(3).trim();
    }
    final mark = done ? '✓' : '○';
    final state = done ? ' is-done' : '';
    out.write('<li class="checklist-item$state">');
    out.write('<span class="checklist-mark">$mark</span>');
    out.write('<span class="checklist-text">${renderInline(text)}</span>');
    out.write('</li>');
  }
  out.write('</ul>');
  return out.toString();
}

/// A roadmap phase: a vertical rule, a title and a status word.
String _phase(DirectiveBlock directive) {
  final status = directive.attribute('status') ?? 'future';
  final out = StringBuffer('<section class="phase phase--$status">');
  out.write('<header class="phase-head">');
  final label = directive.label;
  if (label != null && label.isNotEmpty) {
    out.write('<h3 class="phase-title">${renderInline(label)}</h3>');
  }
  out.write('<p class="phase-status">${escapeHtml(status)}</p>');
  out.write('</header>');
  out.write(renderBlocks(directive.blocks, const RenderContext()));
  out.write('</section>');
  return out.toString();
}

/// A two-column layout. Each `###` heading starts a new column.
String _cols(DirectiveBlock directive, RenderContext context) {
  final columns = _splitColumns(directive.blocks);
  final out = StringBuffer('<div class="cols">');
  for (final column in columns) {
    out.write('<div class="col">');
    out.write(renderBlocks(column, context));
    out.write('</div>');
  }
  out.write('</div>');
  return out.toString();
}

/// A single monospace line of derived facts.
String _meta(DirectiveBlock directive) {
  final lines = _directiveLines(directive.blocks);
  final text = lines.isEmpty ? '' : lines.join(' ');
  return '<p class="meta">${renderInline(text)}</p>';
}

/// The coverage table: every package, its namespace, its native library,
/// its role and how many symbols were skipped.
String _packages(RenderContext context) {
  final out = StringBuffer();
  out.write('<div class="table-scroll"><table>');
  out.write(
    '<thead><tr><th>Package</th><th>GIR namespace</th>'
    '<th>Native library</th><th>Role in the stack</th>'
    '<th class="align-right">Skipped</th></tr></thead><tbody>',
  );
  for (final package in context.packages) {
    final skipped = context.packageSkips[package.name];
    if (package.generated) {
      out.write(
        '<tr><td><code>${escapeHtml(package.name)}</code></td>'
        '<td>${escapeHtml(package.namespace)}</td>'
        '<td><code>${escapeHtml(package.native)}</code></td>'
        '<td>${escapeHtml(package.role)}</td>'
        '<td class="align-right">${skipped == null ? '—' : formatCount(skipped)}</td></tr>',
      );
    } else {
      out.write(
        '<tr><td><code>${escapeHtml(package.name)}</code></td>'
        '<td colspan="2">${escapeHtml(package.description)}</td>'
        '<td>${escapeHtml(package.role)}</td>'
        '<td class="align-right">—</td></tr>',
      );
    }
  }
  out.write('</tbody></table></div>');
  return out.toString();
}

/// The flat text lines of a directive's content.
List<String> _directiveLines(List<MarkdownBlock> blocks) {
  final lines = <String>[];
  for (final block in blocks) {
    if (block is ParagraphBlock) {
      for (final line in block.text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) lines.add(trimmed);
      }
    } else if (block is ListBlock) {
      for (final item in block.items) {
        for (final line in _directiveLines(item.blocks)) {
          lines.add(line);
        }
      }
    }
  }
  return lines;
}

/// Splits a `cols` directive's content at its `###` headings.
List<List<MarkdownBlock>> _splitColumns(List<MarkdownBlock> blocks) {
  final columns = <List<MarkdownBlock>>[];
  var current = <MarkdownBlock>[];
  for (final block in blocks) {
    if (block is HeadingBlock && block.level == 3) {
      if (current.isNotEmpty) columns.add(current);
      current = <MarkdownBlock>[];
    }
    current.add(block);
  }
  if (current.isNotEmpty) columns.add(current);
  return columns;
}
