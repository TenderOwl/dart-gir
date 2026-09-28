/// Skip/skip-reason bookkeeping for generated packages.
library;

/// A single skipped declaration.
class SkipEntry {
  const SkipEntry(this.category, this.name, this.reason);

  /// E.g. `function`, `method`, `class`, `enum`, `callback`.
  final String category;

  /// Human-readable declaration name, e.g. `GLib.printf` or `GObject.Binding.get_name`.
  final String name;

  /// Why the declaration was not emitted.
  final String reason;

  @override
  String toString() => '[$category] $name — $reason';
}

/// Collects skipped declarations while emitting a package.
class GenerationReport {
  final List<SkipEntry> entries = [];

  void skip(String category, String name, String reason) {
    entries.add(SkipEntry(category, name, reason));
  }

  int get totalSkipped => entries.length;

  Map<String, int> get byCategory {
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.category] = (counts[e.category] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> get byReason {
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.reason] = (counts[e.reason] ?? 0) + 1;
    }
    return counts;
  }

  /// Renders the report as text for `skip_report.txt`.
  String format(String title, {int maxEntries = 50}) {
    final b = StringBuffer()
      ..writeln('# Skip report for $title')
      ..writeln('Total skipped: $totalSkipped')
      ..writeln();
    final cats = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    b.writeln('## By category');
    for (final e in cats) {
      b.writeln('${e.key}: ${e.value}');
    }
    final reasons = byReason.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    b
      ..writeln()
      ..writeln('## By reason');
    for (final e in reasons) {
      b.writeln('${e.key}: ${e.value}');
    }
    b
      ..writeln()
      ..writeln('## First $maxEntries entries');
    for (final e in entries.take(maxEntries)) {
      b.writeln(e.toString());
    }
    return b.toString();
  }
}
