// A very small syntax highlighter.
//
// The site used to hand-tokenise its code samples in the HTML source —
// every sample carried a `<span class="tok-k">` around every keyword. That
// put markup in the page sources and made the Markdown port impossible.
// The highlighter here does the same job from the fenced block's
// language, so a page source is just the code.
//
// Unknown languages render as plain escaped text.

import 'markdown.dart';

/// Highlights [code] as [language] and returns HTML.
///
/// The result is safe to drop inside `<pre><code>`.
String highlight(String code, String language) {
  final name = language.trim().toLowerCase();
  if (name == 'dart') return _scan(code, _Language.dartLanguage);
  if (name == 'c' || name == 'cpp' || name == 'h') {
    return _scan(code, _Language.c);
  }
  if (name == 'sh' ||
      name == 'bash' ||
      name == 'shell' ||
      name == 'console' ||
      name == 'terminal') {
    return _scan(code, _Language.shell);
  }
  return escapeHtml(code);
}

/// The lexical rules of one language.
class _Language {
  const _Language({
    required this.keywords,
    required this.types,
    required this.lineComment,
    required this.blockComment,
    required this.multilineStrings,
    required this.dollarVariables,
  });

  final Set<String> keywords;
  final Set<String> types;
  final String lineComment;
  final String blockComment;

  /// Whether `'''` / `"""` open a multi-line string.
  final bool multilineStrings;

  /// Whether `$name` is a variable worth colouring.
  final bool dollarVariables;

  static const _Language dartLanguage = _Language(
    keywords: <String>{
      'abstract',
      'as',
      'assert',
      'async',
      'await',
      'base',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'continue',
      'covariant',
      'default',
      'deferred',
      'do',
      'dynamic',
      'else',
      'enum',
      'export',
      'extends',
      'extension',
      'external',
      'factory',
      'false',
      'final',
      'finally',
      'for',
      'get',
      'hide',
      'if',
      'implements',
      'import',
      'in',
      'inout',
      'interface',
      'is',
      'late',
      'library',
      'mixin',
      'new',
      'null',
      'on',
      'operator',
      'out',
      'part',
      'required',
      'rethrow',
      'return',
      'sealed',
      'set',
      'show',
      'static',
      'super',
      'switch',
      'sync',
      'this',
      'throw',
      'true',
      'try',
      'typedef',
      'var',
      'void',
      'when',
      'while',
      'with',
      'yield',
    },
    types: <String>{
      'bool',
      'double',
      'int',
      'num',
      'Object',
      'String',
      'List',
      'Map',
      'Set',
      'Future',
      'Stream',
      'Never',
      'Function',
    },
    lineComment: '//',
    blockComment: '/*',
    multilineStrings: true,
    dollarVariables: false,
  );

  static const _Language c = _Language(
    keywords: <String>{
      'auto',
      'break',
      'case',
      'const',
      'continue',
      'default',
      'do',
      'else',
      'enum',
      'extern',
      'for',
      'goto',
      'if',
      'inline',
      'register',
      'restrict',
      'return',
      'sizeof',
      'static',
      'struct',
      'switch',
      'typedef',
      'union',
      'volatile',
      'while',
    },
    types: <String>{
      'char',
      'double',
      'float',
      'int',
      'long',
      'short',
      'signed',
      'size_t',
      'ssize_t',
      'uint8_t',
      'uint32_t',
      'uint64_t',
      'int32_t',
      'int64_t',
      'unsigned',
      'void',
      'gboolean',
      'gchar',
      'gint',
      'guint',
      'gsize',
      'gpointer',
    },
    lineComment: '//',
    blockComment: '/*',
    multilineStrings: false,
    dollarVariables: false,
  );

  static const _Language shell = _Language(
    keywords: <String>{
      'case',
      'do',
      'done',
      'elif',
      'else',
      'esac',
      'fi',
      'for',
      'function',
      'if',
      'in',
      'local',
      'return',
      'then',
      'until',
      'while',
    },
    types: <String>{},
    lineComment: '#',
    blockComment: '',
    multilineStrings: false,
    dollarVariables: true,
  );
}

String _scan(String code, _Language lang) {
  final out = StringBuffer();
  var i = 0;
  while (i < code.length) {
    final ch = code[i];

    if (lang.lineComment.isNotEmpty && code.startsWith(lang.lineComment, i)) {
      final end = code.indexOf('\n', i);
      final stop = end < 0 ? code.length : end;
      out.write(_span('tok-c', code.substring(i, stop)));
      i = stop;
      continue;
    }

    if (lang.blockComment.isNotEmpty && code.startsWith(lang.blockComment, i)) {
      final closer = lang.blockComment.substring(2);
      final end = code.indexOf(closer, i + lang.blockComment.length);
      final stop = end < 0 ? code.length : end + closer.length;
      out.write(_span('tok-c', code.substring(i, stop)));
      i = stop;
      continue;
    }

    if (ch == '"' || ch == "'") {
      final stop = _scanString(code, i, ch, lang.multilineStrings);
      out.write(_span('tok-s', code.substring(i, stop)));
      i = stop;
      continue;
    }

    if (lang.dollarVariables && ch == r'$') {
      final match = RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(code, i);
      if (match != null) {
        out.write(_span('tok-t', match.group(0)!));
        i = match.end;
        continue;
      }
    }

    if (ch == '@' && lang == _Language.dartLanguage) {
      final match = RegExp(r'@[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(code, i);
      if (match != null) {
        out.write(_span('tok-f', match.group(0)!));
        i = match.end;
        continue;
      }
    }

    if (_isDigit(ch)) {
      final match = RegExp(r'[0-9][0-9A-Za-z_.]*').matchAsPrefix(code, i);
      final text = match?.group(0) ?? ch;
      out.write(_span('tok-n', text));
      i += text.length;
      continue;
    }

    if (_isIdentifierStart(ch)) {
      final match = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').matchAsPrefix(code, i);
      final word = match?.group(0) ?? ch;
      i += word.length;
      if (lang.keywords.contains(word)) {
        out.write(_span('tok-k', word));
      } else if (lang.types.contains(word)) {
        out.write(_span('tok-t', word));
      } else if (_callFollows(code, i)) {
        out.write(_span('tok-f', word));
      } else {
        out.write(escapeHtml(word));
      }
      continue;
    }

    out.write(escapeHtml(ch));
    i++;
  }
  return out.toString();
}

/// Finds the end of the string literal that starts at [start].
int _scanString(String code, int start, String delimiter, bool multiline) {
  if (multiline && code.startsWith(delimiter * 3, start)) {
    final closer = delimiter * 3;
    final end = code.indexOf(closer, start + 3);
    if (end < 0) return code.length;
    return end + 3;
  }
  var i = start + 1;
  while (i < code.length) {
    final ch = code[i];
    if (ch == r'\') {
      i += 2;
      continue;
    }
    if (ch == delimiter) return i + 1;
    if (ch == '\n' && !multiline) return i;
    i++;
  }
  return code.length;
}

/// Whether the next non-space character is an opening parenthesis.
bool _callFollows(String code, int index) {
  var i = index;
  while (i < code.length && code[i] == ' ') {
    i++;
  }
  return i < code.length && code[i] == '(';
}

bool _isDigit(String ch) =>
    ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;

bool _isIdentifierStart(String ch) {
  final code = ch.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a) ||
      ch == '_' ||
      ch == r'$';
}

String _span(String cssClass, String text) =>
    '<span class="$cssClass">${escapeHtml(text)}</span>';
