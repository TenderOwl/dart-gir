/// Emits opaque handle classes for GIR records and unions.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import 'async_emitter.dart';
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
  String? emitInterface(GirInterface i) => _emit(
        i,
        const [],
        i.methods,
        i.functions,
        i.doc,
        signals: i.signals,
        isInterface: true,
      );

  String? _emit(
    GirRegisteredType type,
    List<GirConstructor> constructors,
    List<GirMethod> methods,
    List<GirFunction> functions,
    String? doc, {
    List<GirSignal> signals = const [],
    bool isInterface = false,
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
    // Interfaces must NOT be `final class`: the implements-clause plan
    // (T2) requires other classes to be able to `implements <Name>`.
    // `final class` forbids implementation outside the library, and the
    // implementing class lives in another generated file. Records and
    // unions stay `final class` because they're concrete struct wrappers
    // that aren't meant to be subclassed by user code.
    b.writeln(isInterface ? 'class $dartName {' : 'final class $dartName {');
    // The `{bool owned}` named parameter is always accepted (even
    // when the class doesn't actually attach a finalizer, because
    // it's not a `GObject` subclass) so existing callers that don't
    // pass `owned` keep working through the default value. Note the
    // cast method's *factory* parameter below doesn't carry `owned` —
    // the borrowed-reference world the cast method operates in never
    // needs to transfer ownership, and dropping `owned` from the
    // factory type lets user subclasses write the shortest possible
    // forwarding constructor (`fromPointer(handle)`).
    b.writeln('$dartName.fromPointer(this.handle, {bool owned = false});');
    b.writeln('final ffi.Pointer<ffi.Void> handle;');
    // `cast<T>(factory)` lets the user recover the destination class's
    // methods from a borrowed wrapper (e.g. `GObject` from
    // `GListModel.getObject`, `GtkWidget` from `AdwTabPage.getChild`).
    // The bound is `Object` rather than `extends $dartName` because
    // most wrappers in the corpus don't form an `extends` chain
    // (interfaces like `GFile` are emitted as `class GFile {` with
    // no parent — they're "structurally" GObject but Dart's static
    // type system doesn't see the relationship). `Object` is the
    // trivial bound that lets `T` be any class the user has a
    // `fromPointer` for; the factory parameter type-checks the
    // destination. All wrappers emit the same signature so the
    // subclass overrides are valid.
    b.writeln();
    b.writeln('/// Re-wraps this wrapper\'s [handle] as [T] via [factory].');
    b.writeln('///');
    b.writeln('/// Use this when another wrapper returns this class\'s');
    b.writeln('/// instance but the caller needs the destination class\'s');
    b.writeln('/// methods. Pass the destination class\'s `fromPointer` as');
    b.writeln('/// the callback, e.g. `wrapper.cast<GFile>(GFile.fromPointer)`.');
    b.writeln('/// The handle is forwarded as-is; the original wrapper');
    b.writeln('/// (which produced this object) remains the owner.');
    b.writeln('T cast<T extends Object>(');
    b.writeln('  T Function(ffi.Pointer<ffi.Void>) factory,');
    b.writeln(') {');
    b.writeln('  return factory(handle);');
    b.writeln('}');

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
      // `*Callback` lifetime-safe overload for async methods. Skip when
      // the base wrapper was skipped (shadowed/moved/...).
      if (code != null &&
          (m.finishFunc != null ||
              m.parameters.any((p) => p.scope == 'async'))) {
        final async = AsyncCallbackEmitter(ctx).emitMethodOverload(
          m,
          dartName: name,
          className: dartName,
          selfArgExpr: 'this.handle',
          nativeBindingName: '_${toLowerCamel(m.cIdentifier!)}',
        );
        if (async != null && memberNames.add('${name}Callback')) {
          b.writeln(_indent(async));
        }
      }
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
    final entries = <({GirSignal signal, GirNamespace? ns})>[
      for (final s in signals) (signal: s, ns: ctx.namespace),
    ];
    final signalCode = emitSignalConnectors(
      ctx,
      signals,
      dartName,
      memberNames,
      buckets: buildSignalBuckets(entries, ctx),
    );
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
