import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/gir/loader.dart';

void main() {
  final loader = GirLoader('/usr/share/gir-1.0');
  final repos = loader.loadAllWithDependencies([
    'GLib-2.0', 'GObject-2.0', 'Gio-2.0', 'GdkPixbuf-2.0',
    'cairo-1.0', 'Pango-1.0', 'Gdk-4.0', 'Gtk-4.0', 'Adw-1',
    'Graphene-1.0', 'Gsk-4.0',
  ]);
  final allNamespaces = [for (final r in repos) r.namespace];
  // Count signals by arity.
  final byArity = <String, int>{};
  final examples = <String, List<String>>{};
  for (final ns in allNamespaces) {
    for (final c in ns.classes) {
      for (final sig in c.signals) {
        final key = sig.parameters.length.toString();
        byArity[key] = (byArity[key] ?? 0) + 1;
        if (!examples.containsKey(key)) examples[key] = [];
        if (examples[key]!.length < 5) {
          examples[key]!.add('${ns.name}.${c.name}.${sig.name}(${sig.parameters.map((p) => "${p.name}:${p.type?.name}").join(", ")})');
        }
      }
    }
    for (final i in ns.interfaces) {
      for (final sig in i.signals) {
        final key = sig.parameters.length.toString();
        byArity[key] = (byArity[key] ?? 0) + 1;
      }
    }
  }
  print('=== Signal arity distribution ===');
  byArity.forEach((k, v) => print('arity=$k: $v signals'));
  print('');
  print('=== Examples per arity ===');
  examples.forEach((k, v) {
    print('arity=$k:');
    for (final ex in v) {
      print('  $ex');
    }
  });
}
