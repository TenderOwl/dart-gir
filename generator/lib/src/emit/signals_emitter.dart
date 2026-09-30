/// Emits typed signal-connection helpers (`onSignalName`) for GIR signals.
///
/// Currently limited to `void(void)` signals — the most common case
/// (`activate`, `clicked`, `shutdown`, …). Signals with parameters or a
/// non-void return are recorded as skips in the report so the gap is
/// visible; a follow-up plan will extend the trampoline table.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import 'context.dart';

/// Builds Dart code for typed `onSignalName` methods on [className] for
/// each kept signal in [signals]. Returns the concatenation of doc +
/// method bodies, separated by blank lines.
///
/// Signals that don't match the current MVP scope are recorded as
/// `signal` skips via [EmitContext.report] and omitted from the output.
String emitSignalConnectors(
  EmitContext ctx,
  List<GirSignal> signals,
  String className,
  Set<String> memberNames,
) {
  final b = StringBuffer();
  for (final sig in signals) {
    final skipReason = signalSkipReason(sig);
    if (skipReason != null) {
      ctx.report.skip('signal', '$className.${sig.name}', skipReason);
      continue;
    }
    final methodName = 'on${toUpperCamel(sig.name)}';
    if (!memberNames.add(methodName)) {
      ctx.report.skip(
        'signal',
        '$className.${sig.name}',
        'name collision (a member named `$methodName` already exists)',
      );
      continue;
    }
    for (final line in ctx.docLines(sig.doc)) {
      b.writeln(line);
    }
    b.writeln(
      'int $methodName(void Function() callback) {',
    );
    b.writeln(
      '  return _connectVoidSignal(this.handle, ${_stringLiteral(sig.name)}, callback);',
    );
    b.writeln('}');
    b.writeln();
  }
  return b.toString();
}

/// Why [sig] is out of MVP scope, or null when it is a plain `void(void)`
/// signal that gets a typed helper.
String? signalSkipReason(GirSignal sig) {
  // `weak-ref` is dispatched by g_object_weak_ref, not g_signal_emit, and
  // connecting it via g_signal_connect_data is rejected by GObject.
  if (sig.name == 'weak-ref') {
    return 'weak-ref is not connectable via g_signal_connect_data';
  }
  if (sig.returnType != null) {
    final name = sig.returnType!.name;
    if (name != null && name != 'none' && name != 'void') {
      return 'only void(void) supported in this release';
    }
  }
  if (sig.parameters.isNotEmpty) {
    return 'only void(void) supported in this release';
  }
  return null;
}

/// Whether [sig] gets a typed `onSignalName` helper in this release.
bool isKeptSignal(GirSignal sig) => signalSkipReason(sig) == null;

/// Single-quoted Dart string literal for [value].
String _stringLiteral(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return "'$escaped'";
}
