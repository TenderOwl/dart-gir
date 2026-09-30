/// Emits opaque handle classes for GIR records and unions.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import 'callable.dart';
import 'context.dart';
import 'signals_emitter.dart';

/// Records and unions become opaque pointer wrappers with their GIR
/// constructors, methods and static functions attached.
class RecordEmitter {
  RecordEmitter(this.ctx);

  final EmitContext ctx;

  String? emitRecord(GirRecord rec) =>
      _emit(rec, rec.constructors, rec.methods, rec.functions, rec.doc);

  String? emitUnion(GirUnion u) =>
      _emit(u, u.constructors, u.methods, u.functions, u.doc);

  /// Interfaces are emitted as opaque handle classes (no vtable support yet).
  String? emitInterface(GirInterface i) =>
      _emit(i, const [], i.methods, i.functions, i.doc, signals: i.signals);

  String? _emit(
    GirRegisteredType type,
    List<GirConstructor> constructors,
    List<GirMethod> methods,
    List<GirFunction> functions,
    String? doc, {
    List<GirSignal> signals = const [],
  }) {
    final dartName = ctx.dartTypeName(ctx.namespace.name, type.name);
    if (ctx.isDuplicateType(type)) {
      ctx.report.skip('record', dartName,
          'duplicate declaration owned by an earlier namespace');
      return null;
    }
    if (!ctx.claimName(dartName)) {
      ctx.report.skip('record', dartName, 'name collision');
      return null;
    }
    final callables = CallableEmitter(ctx);
    final memberNames = <String>{'handle', 'fromPointer', dartName};
    var unnamedCtorUsed = false;
    final b = StringBuffer();
    for (final line in ctx.docLines(doc)) {
      b.writeln(line);
    }
    b.writeln('final class $dartName {');
    b.writeln('$dartName.fromPointer(this.handle);');
    b.writeln('final ffi.Pointer<ffi.Void> handle;');

    for (final c in constructors) {
      final name = RecordEmitter.ctorName(c);
      if (name.isEmpty) {
        if (unnamedCtorUsed) {
          ctx.report.skip('constructor', dartName, 'duplicate new()');
          continue;
        }
        unnamedCtorUsed = true;
      } else if (!memberNames.add(name)) {
        ctx.report.skip('constructor', '$dartName.$name', 'name collision');
        continue;
      }
      final code = callables.emit(c,
          dartName: name,
          ownerName: dartName,
          classMember: true,
          factoryClass: dartName,
          factoryOwned: false);
      if (code != null) b.writeln(_indent(code));
    }
    for (final m in methods) {
      final name = CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));
      if (CallableEmitter.conflictsWithObjectMember(name) ||
          !memberNames.add(name)) {
        ctx.report.skip('method', '$dartName.$name', 'name collision');
        continue;
      }
      final code = callables.emit(m,
          dartName: name,
          ownerName: dartName,
          classMember: true,
          selfArgExpr: 'this.handle');
      if (code != null) b.writeln(_indent(code));
    }
    for (final f in functions) {
      final name = CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(f.name)));
      if (!memberNames.add(name)) {
        ctx.report.skip('function', '$dartName.$name', 'name collision');
        continue;
      }
      final code = callables.emit(f,
          dartName: name, ownerName: dartName, staticMember: true);
      if (code != null) b.writeln(_indent(code));
    }
    final signalCode = emitSignalConnectors(ctx, signals, dartName, memberNames);
    if (signalCode.isNotEmpty) b.writeln(_indent(signalCode));
    b.write('}');
    return b.toString();
  }

  /// Public name for a GIR constructor (`new` → `''`, `new_with_label` →
  /// `withLabel`).
  static String ctorName(GirConstructor c) {
    var name = c.name;
    if (name == 'new') return '';
    if (name.startsWith('new_')) name = name.substring(4);
    return escapeKeyword(toLowerCamel(name));
  }

  static String _indent(String code) => code
      .split('\n')
      .map((l) => l.isEmpty ? l : '  $l')
      .join('\n');
}
