// A deliberately small Markdown subset, rendered to HTML.
//
// The site needs headings, paragraphs, lists, tables, code fences, quotes,
// rules, raw HTML and a handful of block directives. It does not need
// everything CommonMark defines, and a smaller surface is a smaller
// surface for subtle bugs — so the subset is explicit, small, and
// covered by unit tests in `test/site/markdown_test.dart`.
//
// Raw HTML *blocks* are passed through verbatim. The design page carries
// three inline SVG diagrams that depend on page CSS classes, and they
// cannot become external `.svg` files without losing that dependency.

import 'directives.dart';

/// The block-level elements the parser produces.
sealed class MarkdownBlock {
  const MarkdownBlock();
}

/// An ATX heading.
class HeadingBlock extends MarkdownBlock {
  const HeadingBlock(this.level, this.text);

  /// The heading level, 1 through 6.
  final int level;

  /// The raw inline text, without the leading hashes.
  final String text;
}

/// A paragraph — a run of lines with no blank line between them.
class ParagraphBlock extends MarkdownBlock {
  const ParagraphBlock(this.text);

  /// The raw inline text.
  final String text;
}

/// One entry of a list.
class ListItem {
  const ListItem(this.blocks);

  /// The item's content, parsed as blocks (so nested lists work).
  final List<MarkdownBlock> blocks;
}

/// An ordered or unordered list.
class ListBlock extends MarkdownBlock {
  const ListBlock(this.ordered, this.items);

  /// Whether the list is numbered.
  final bool ordered;

  /// The list's entries.
  final List<ListItem> items;
}

/// A fenced code block.
class CodeBlock extends MarkdownBlock {
  const CodeBlock(this.language, this.title, this.code);

  /// The info string's first word, e.g. `dart`. Empty when absent.
  final String language;

  /// The optional `title=` attribute of the info string.
  final String? title;

  /// The block's raw text.
  final String code;
}

/// A block quote.
class QuoteBlock extends MarkdownBlock {
  const QuoteBlock(this.blocks);

  /// The quoted content, parsed as blocks.
  final List<MarkdownBlock> blocks;
}

/// The horizontal alignment of a table column.
enum ColumnAlignment { none, left, center, right }

/// A GFM-style table.
class TableBlock extends MarkdownBlock {
  const TableBlock(this.headers, this.alignments, this.rows);

  /// The header cells, as raw inline text.
  final List<String> headers;

  /// The per-column alignment.
  final List<ColumnAlignment> alignments;

  /// The body rows, as raw inline text per cell.
  final List<List<String>> rows;
}

/// A raw HTML block, passed through verbatim.
class HtmlBlock extends MarkdownBlock {
  const HtmlBlock(this.html);

  /// The block's source text.
  final String html;
}

/// A thematic break.
class RuleBlock extends MarkdownBlock {
  const RuleBlock();
}

/// A `:::{name}` container.
class DirectiveBlock extends MarkdownBlock {
  const DirectiveBlock(this.name, this.label, this.attributes, this.blocks);

  /// The directive name.
  final String name;

  /// The optional label.
  final String? label;

  /// The `key=value` attributes.
  final Map<String, String> attributes;

  /// The value of the `key=value` attribute [key], or `null`.
  String? attribute(String key) => attributes[key];

  /// The container's content, parsed as blocks.
  final List<MarkdownBlock> blocks;
}

/// A numbered `##` section of a page.
class Section {
  const Section({
    required this.number,
    required this.id,
    required this.title,
    required this.blocks,
  });

  /// The section's number, e.g. `01`.
  final String number;

  /// The section's anchor id.
  final String id;

  /// The section's raw heading text.
  final String title;

  /// The section's content.
  final List<MarkdownBlock> blocks;
}

/// A parsed page: the content before the first `##`, then the sections.
class Document {
  const Document({required this.preamble, required this.sections});

  /// The content before the first `##` heading.
  final List<MarkdownBlock> preamble;

  /// The page's `##` sections.
  final List<Section> sections;
}

/// Parses [source] into a document.
///
/// Throws a [FormatException] when a directive header is malformed or
/// names a directive the generator does not know.
Document parseMarkdown(String source) {
  final blocks = _parseBlocks(_splitLines(source));
  return buildDocument(blocks);
}

/// Parses [source] into its top-level blocks.
List<MarkdownBlock> parseBlocks(String source) =>
    _parseBlocks(_splitLines(source));

/// Splits a flat block list into a preamble and numbered `##` sections.
Document buildDocument(List<MarkdownBlock> blocks) {
  final preamble = <MarkdownBlock>[];
  final sections = <Section>[];
  var index = 0;
  while (index < blocks.length && !_isSectionHeading(blocks[index])) {
    preamble.add(blocks[index]);
    index++;
  }
  var number = 0;
  while (index < blocks.length) {
    final heading = blocks[index] as HeadingBlock;
    number++;
    final body = <MarkdownBlock>[];
    index++;
    while (index < blocks.length && !_isSectionHeading(blocks[index])) {
      body.add(blocks[index]);
      index++;
    }
    sections.add(
      Section(
        number: number.toString().padLeft(2, '0'),
        id: slugify(heading.text),
        title: heading.text,
        blocks: body,
      ),
    );
  }
  return Document(preamble: preamble, sections: sections);
}

bool _isSectionHeading(MarkdownBlock block) =>
    block is HeadingBlock && block.level == 2;

List<String> _splitLines(String source) {
  final text = source.replaceAll('\r\n', '\n');
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

// ---------------------------------------------------------------- parsing

List<MarkdownBlock> _parseBlocks(List<String> lines) {
  final blocks = <MarkdownBlock>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    final fence = _fenceMatch(line);
    if (fence != null) {
      final result = _consumeFence(lines, i, fence);
      blocks.add(result.block);
      i = result.next;
      continue;
    }

    if (_isDirectiveStart(line)) {
      final result = _consumeDirective(lines, i);
      blocks.add(result.block);
      i = result.next;
      continue;
    }

    final heading = _headingMatch(line);
    if (heading != null) {
      blocks.add(HeadingBlock(heading.level, heading.text));
      i++;
      continue;
    }

    if (_isRule(line)) {
      blocks.add(const RuleBlock());
      i++;
      continue;
    }

    if (_isQuote(line)) {
      final result = _consumeQuote(lines, i);
      blocks.add(QuoteBlock(result.blocks));
      i = result.next;
      continue;
    }

    if (_isTableStart(lines, i)) {
      final result = _consumeTable(lines, i);
      blocks.add(result.block);
      i = result.next;
      continue;
    }

    if (_isHtmlStart(line)) {
      final result = _consumeHtml(lines, i);
      blocks.add(HtmlBlock(result.html));
      i = result.next;
      continue;
    }

    if (_listMarker(line) != null) {
      final result = _consumeList(lines, i);
      blocks.add(result.block);
      i = result.next;
      continue;
    }

    final result = _consumeParagraph(lines, i);
    blocks.add(ParagraphBlock(result.text));
    i = result.next;
  }
  return blocks;
}

class _Fence {
  const _Fence(this.marker, this.info);

  final String marker;
  final String info;
}

_Fence? _fenceMatch(String line) {
  final match = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*(.*)$').firstMatch(line);
  if (match == null) return null;
  return _Fence(match.group(1)!, match.group(2)!.trim());
}

({MarkdownBlock block, int next}) _consumeFence(
  List<String> lines,
  int start,
  _Fence fence,
) {
  final body = <String>[];
  var i = start + 1;
  var closed = false;
  while (i < lines.length) {
    final line = lines[i];
    final closing = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*$').firstMatch(line);
    if (closing != null &&
        closing.group(1)![0] == fence.marker[0] &&
        closing.group(1)!.length >= fence.marker.length) {
      i++;
      closed = true;
      break;
    }
    body.add(line);
    i++;
  }
  if (!closed) {
    throw FormatException('unterminated code fence on line ${start + 1}');
  }
  final info = _splitInfo(fence.info);
  var language = '';
  String? title;
  for (final part in info) {
    final equals = part.indexOf('=');
    if (equals > 0 && part.substring(0, equals) == 'title') {
      title = part.substring(equals + 1);
    } else if (language.isEmpty) {
      language = part;
    }
  }
  return (block: CodeBlock(language, title, body.join('\n')), next: i);
}

/// Splits a fence's info string into tokens, keeping quoted runs together.
///
/// `dart title="a long name"` yields `['dart', 'title=a long name']`.
List<String> _splitInfo(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (quote.isNotEmpty) {
      if (ch == quote) {
        quote = '';
      } else {
        buffer.write(ch);
      }
      continue;
    }
    if ((ch == '"' || ch == "'") &&
        (buffer.isEmpty || buffer.toString().endsWith('='))) {
      quote = ch;
      continue;
    }
    if (ch == ' ' || ch == '\t') {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(ch);
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  return tokens;
}

bool _isDirectiveStart(String line) => RegExp(r'^\s*:::\{').hasMatch(line);

({MarkdownBlock block, int next}) _consumeDirective(
  List<String> lines,
  int start,
) {
  final header = parseDirectiveHeader(lines[start]);
  final body = <String>[];
  var i = start + 1;
  var closed = false;
  var depth = 1;
  while (i < lines.length) {
    final line = lines[i];
    if (_isDirectiveStart(line)) {
      // A nested directive — its own terminator belongs to it.
      depth++;
      body.add(line);
      i++;
      continue;
    }
    if (RegExp(r'^\s*:::\s*$').hasMatch(line)) {
      depth--;
      if (depth == 0) {
        i++;
        closed = true;
        break;
      }
      body.add(line);
      i++;
      continue;
    }
    body.add(line);
    i++;
  }
  if (!closed) {
    throw FormatException(
      'unterminated "${header.name}" directive starting on line ${start + 1}',
    );
  }
  return (
    block: DirectiveBlock(
      header.name,
      header.label,
      header.attributes,
      _parseBlocks(body),
    ),
    next: i,
  );
}

({int level, String text})? _headingMatch(String line) {
  final match = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(line);
  if (match == null) return null;
  return (level: match.group(1)!.length, text: match.group(2)!);
}

bool _isRule(String line) =>
    RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$').hasMatch(line);

bool _isQuote(String line) => RegExp(r'^\s{0,3}>').hasMatch(line);

({List<MarkdownBlock> blocks, int next}) _consumeQuote(
  List<String> lines,
  int start,
) {
  final body = <String>[];
  var i = start;
  while (i < lines.length) {
    final line = lines[i];
    if (_isQuote(line)) {
      body.add(line.replaceFirst(RegExp(r'^\s{0,3}> ?'), ''));
      i++;
      continue;
    }
    if (line.trim().isNotEmpty && !_startsNewBlock(lines, i)) {
      body.add(line.trim());
      i++;
      continue;
    }
    break;
  }
  return (blocks: _parseBlocks(body), next: i);
}

bool _isTableStart(List<String> lines, int index) {
  if (index + 1 >= lines.length) return false;
  if (!lines[index].contains('|')) return false;
  return _isDelimiterRow(lines[index + 1]);
}

bool _isDelimiterRow(String line) {
  if (!line.contains('-')) return false;
  return RegExp(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$').hasMatch(line);
}

({MarkdownBlock block, int next}) _consumeTable(List<String> lines, int start) {
  final headers = _splitRow(lines[start]);
  final alignments = _parseAlignments(lines[start + 1]);
  final rows = <List<String>>[];
  var i = start + 2;
  while (i < lines.length &&
      lines[i].trim().isNotEmpty &&
      lines[i].contains('|')) {
    rows.add(_splitRow(lines[i]));
    i++;
  }
  return (block: TableBlock(headers, alignments, rows), next: i);
}

List<String> _splitRow(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  return text.split('|').map((cell) => cell.trim()).toList();
}

List<ColumnAlignment> _parseAlignments(String line) {
  return _splitRow(line).map((cell) {
    final left = cell.startsWith(':');
    final right = cell.endsWith(':');
    if (left && right) return ColumnAlignment.center;
    if (right) return ColumnAlignment.right;
    if (left) return ColumnAlignment.left;
    return ColumnAlignment.none;
  }).toList();
}

bool _isHtmlStart(String line) =>
    RegExp(r'^\s{0,3}<(/?[A-Za-z!][A-Za-z0-9-]*)').hasMatch(line);

({String html, int next}) _consumeHtml(List<String> lines, int start) {
  final buffer = <String>[];
  var depth = 0;
  var inComment = false;
  var i = start;
  while (i < lines.length) {
    final line = lines[i];
    buffer.add(line);
    i++;
    var j = 0;
    while (j < line.length) {
      if (inComment) {
        final close = line.indexOf('-->', j);
        if (close < 0) {
          j = line.length;
        } else {
          inComment = false;
          j = close + 3;
        }
        continue;
      }
      final lt = line.indexOf('<', j);
      if (lt < 0) break;
      if (line.startsWith('<!--', lt)) {
        inComment = true;
        j = lt + 4;
        continue;
      }
      final end = _tagEnd(line, lt);
      if (end < 0) {
        j = line.length;
        break;
      }
      final tag = line.substring(lt, end + 1);
      if (tag.startsWith('</')) {
        depth--;
      } else if (!tag.endsWith('/>') && !_isVoidTag(tag)) {
        depth++;
      }
      j = end + 1;
    }
    if (!inComment && depth <= 0) break;
  }
  return (html: buffer.join('\n'), next: i);
}

int _tagEnd(String line, int start) {
  var i = start + 1;
  var quote = '';
  while (i < line.length) {
    final ch = line[i];
    if (quote.isNotEmpty) {
      if (ch == quote) quote = '';
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == '>') {
      return i;
    }
    i++;
  }
  return -1;
}

bool _isVoidTag(String tag) {
  final name = RegExp(r'^</?\s*([A-Za-z][A-Za-z0-9-]*)').firstMatch(tag);
  if (name == null) return false;
  const voidTags = <String>{
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };
  return voidTags.contains(name.group(1)!.toLowerCase());
}

class _Marker {
  const _Marker(this.indent, this.marker, this.spaces, this.content);

  final int indent;
  final String marker;
  final int spaces;
  final String content;

  bool get ordered => RegExp(r'^\d').hasMatch(marker);
}

_Marker? _listMarker(String line) {
  final match = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])(\s+)(.*)$').firstMatch(line);
  if (match == null) return null;
  return _Marker(
    match.group(1)!.length,
    match.group(2)!,
    match.group(3)!.length,
    match.group(4)!,
  );
}

int _indentOf(String line) => line.length - line.trimLeft().length;

({MarkdownBlock block, int next}) _consumeList(List<String> lines, int start) {
  final first = _listMarker(lines[start])!;
  final items = <ListItem>[];
  var i = start;
  while (i < lines.length) {
    final marker = _listMarker(lines[i]);
    if (marker == null) break;
    final contentIndent = marker.indent + marker.marker.length + marker.spaces;
    final content = <String>[marker.content];
    i++;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        final next = i + 1;
        if (next < lines.length && _indentOf(lines[next]) >= contentIndent) {
          content.add('');
          i++;
          continue;
        }
        break;
      }
      final lineIndent = _indentOf(line);
      if (lineIndent >= contentIndent) {
        content.add(line.substring(contentIndent));
        i++;
        continue;
      }
      if (_listMarker(line) != null) break;
      if (_startsNewBlock(lines, i)) break;
      // A lazy continuation belongs to the paragraph above it.
      if (content.isNotEmpty &&
          content.last.trim().isNotEmpty &&
          _listMarker(content.last) == null &&
          !content.last.startsWith(' ')) {
        content[content.length - 1] = '${content.last} ${line.trim()}';
      } else {
        content.add(line.trim());
      }
      i++;
    }
    items.add(ListItem(_parseBlocks(content)));
  }
  return (block: ListBlock(first.ordered, items), next: i);
}

bool _startsNewBlock(List<String> lines, int index) {
  final line = lines[index];
  if (_fenceMatch(line) != null) return true;
  if (_isDirectiveStart(line)) return true;
  if (_headingMatch(line) != null) return true;
  if (_isRule(line)) return true;
  if (_isQuote(line)) return true;
  if (_isHtmlStart(line)) return true;
  if (_listMarker(line) != null) return true;
  return false;
}

({String text, int next}) _consumeParagraph(List<String> lines, int start) {
  final buffer = <String>[];
  var i = start;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) break;
    if (i > start && _startsNewBlock(lines, i)) break;
    buffer.add(line.trim());
    i++;
  }
  return (text: buffer.join('\n'), next: i);
}

// ---------------------------------------------------------------- inline

/// The marker that stands in for a code span while the rest of the inline
/// text is escaped and formatted.
const String _codeMarker = '@@code:';

/// The marker that stands in for an autolink.
const String _linkMarker = '@@link:';

/// The marker that stands in for an image.
const String _imageMarker = '@@image:';

/// Renders the inline subset: code, strong, emphasis, links, images and
/// autolinks.
String renderInline(String text) {
  final codeSpans = <String>[];
  final autolinks = <String>[];
  final images = <String>[];

  var working = text.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (match) {
    codeSpans.add(match.group(1)!);
    return '$_codeMarker${codeSpans.length - 1}@@';
  });

  working = working.replaceAllMapped(
    RegExp(r'<((?:https?|ftp)://[^>\s]+|mailto:[^>\s]+)>'),
    (match) {
      autolinks.add(match.group(1)!);
      return '$_linkMarker${autolinks.length - 1}@@';
    },
  );

  working = escapeHtml(working);

  working = working.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\(([^)\s]*)(?:\s+"[^"]*")?\)'),
    (match) {
      images.add('<img src="${match.group(2)}" alt="${match.group(1)}">');
      return '$_imageMarker${images.length - 1}@@';
    },
  );

  working = working.replaceAllMapped(
    RegExp(r'(?<!!)\[([^\]]*)\]\(([^)\s]*)(?:\s+"([^"]*)")?\)'),
    (match) {
      final title = match.group(3);
      final titleAttribute = title == null ? '' : ' title="$title"';
      return '<a href="${match.group(2)}"$titleAttribute>${match.group(1)}</a>';
    },
  );

  working = working.replaceAllMapped(
    RegExp(r'\*\*(.+?)\*\*', dotAll: true),
    (match) => '<strong>${match.group(1)}</strong>',
  );

  working = working.replaceAllMapped(
    RegExp(r'(?<![*\w])\*([^*\n]+)\*(?!\*)'),
    (match) => '<em>${match.group(1)}</em>',
  );

  working = working.replaceAllMapped(
    RegExp(r'(?<![\w_])_([^_\n]+)_(?![\w_])'),
    (match) => '<em>${match.group(1)}</em>',
  );

  working = working.replaceAllMapped(
    RegExp('$_codeMarker(\\d+)@@'),
    (match) =>
        '<code>${escapeHtml(codeSpans[int.parse(match.group(1)!)])}</code>',
  );

  working = working.replaceAllMapped(RegExp('$_linkMarker(\\d+)@@'), (match) {
    final url = autolinks[int.parse(match.group(1)!)];
    return '<a href="${escapeHtml(url)}">${escapeHtml(url)}</a>';
  });

  working = working.replaceAllMapped(
    RegExp('$_imageMarker(\\d+)@@'),
    (match) => images[int.parse(match.group(1)!)],
  );

  return working;
}

/// Escapes HTML, leaving existing entities (`&amp;`, `&#8230;`, …) alone.
String escapeHtml(String input) {
  final buffer = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (ch == '&') {
      final entity = _entityAt(input, i);
      if (entity != null) {
        buffer.write(entity);
        i += entity.length - 1;
      } else {
        buffer.write('&amp;');
      }
    } else if (ch == '<') {
      buffer.write('&lt;');
    } else if (ch == '>') {
      buffer.write('&gt;');
    } else if (ch == '"') {
      buffer.write('&quot;');
    } else {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

String? _entityAt(String input, int index) {
  final match = RegExp(r'&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);')
      .matchAsPrefix(input, index);
  return match?.group(0);
}

/// Turns a heading's text into a URL anchor.
String slugify(String text) {
  var slug = text.toLowerCase();
  slug = slug.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (match) => match.group(1)!,
  );
  slug = slug.replaceAll(RegExp(r'[*_`~]'), '');
  slug = slug.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
  return slug;
}

/// The plain text of a heading, for use in navigation labels.
String plainText(String text) {
  var plain = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (match) => match.group(1)!,
  );
  plain = plain.replaceAll(RegExp(r'[*_`~]'), '');
  return plain.trim();
}
