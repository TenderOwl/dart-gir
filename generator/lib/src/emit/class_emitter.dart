/// Emits Dart classes for GIR classes, with inheritance and ownership.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart';
import 'async_emitter.dart';
import 'callable.dart';
import 'context.dart';
import 'record_emitter.dart';
import 'signals_emitter.dart';

/// GIR classes become pointer-wrapper classes mirroring the GType hierarchy.
class ClassEmitter {
  ClassEmitter(this.ctx, {required this.emittedPackages});

  final EmitContext ctx;

  /// Packages generated in this run; parents in other packages cannot be
  /// extended.
  final Set<String> emittedPackages;

  String? emitClass(GirClass cls) {
    final dartName = ctx.dartTypeName(ctx.namespace.name, cls.name);
    if (ctx.isDuplicateType(cls)) {
      ctx.report.skip('class', dartName,
          'duplicate declaration owned by an earlier namespace');
      return null;
    }
    if (!ctx.claimName(dartName)) {
      ctx.report.skip('class', dartName, 'name collision');
      return null;
    }

    // Resolve parent.
    String? parentName;
    if (cls.parent != null) {
      final found = ctx.findClass(cls.parent!);
      if (found == null) {
        ctx.report.skip('class', dartName,
            'parent ${cls.parent} not found; emitted without superclass');
      } else {
        final (parentNs, parentCls) = found;
        final parentPkg = parentNs.name == ctx.namespace.name
            ? null
            : packageNameFor(parentNs);
        if (parentPkg != null && !emittedPackages.contains(parentPkg)) {
          ctx.report.skip('class', dartName,
              'parent ${cls.parent} is in non-generated package $parentPkg');
        } else {
          parentName = ctx.dartTypeName(parentNs.name, parentCls.name);
          if (parentPkg != null) ctx.imports.add(parentPkg);
        }
      }
    }

    final rooted = ctx.isGObjectRooted(cls);
    final sink = rooted && ctx.sinksFloatingRefs(cls);
    if (rooted && packageNameFor(ctx.namespace) != 'gobject') {
      ctx.imports.add('gobject');
    }

    final callables = CallableEmitter(ctx);
    final memberNames = <String>{'handle', 'owned', 'fromPointer', dartName};
    final ancestorSigs = _ancestorMethodSigs(cls);
    var unnamedCtorUsed = false;
    final b = StringBuffer();
    for (final line in ctx.docLines(cls.doc)) {
      b.writeln(line);
    }
    b.writeln(
        'class $dartName${parentName != null ? ' extends $parentName' : ''}'
        '${parentName == null && rooted ? ' implements ffi.Finalizable' : ''} {');
    if (parentName == null) {
      if (rooted) {
        b.writeln('$dartName.fromPointer(this.handle, {this.owned = false}) {');
        b.writeln('if (owned) {');
        b.writeln('_attachFinalizer();');
        b.writeln('}');
        b.writeln('}');
      } else {
        b.writeln('$dartName.fromPointer(this.handle, {this.owned = false});');
      }
      b.writeln('final ffi.Pointer<ffi.Void> handle;');
      b.writeln('final bool owned;');
      if (rooted) {
        b.writeln(
            'void _attachFinalizer() => gobjectFinalizer.attach(this, handle, detach: this);');
      }
    } else {
      b.writeln(
          '$dartName.fromPointer(super.handle, {super.owned}) : super.fromPointer();');
    }

    for (final c in cls.constructors) {
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
          sinkFloating: sink);
      if (code != null) b.writeln(_indent(code));
    }
    for (final m in cls.methods) {
      var name =
          CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));
      // A member whose inherited signature differs (return type, parameter
      // types, nullability) is not a valid Dart override; rename it by
      // appending the class's GIR name (`activate` on AdwActionRow →
      // `activateActionRow`).
      final ancestorSig = ancestorSigs[name];
      if (ancestorSig != null && ancestorSig != _methodKey(m)) {
        final renamed = '$name${cls.name}';
        ctx.report.skip('renamed', '$dartName.$name',
            'override-incompatible with ancestor; renamed to $renamed');
        name = renamed;
      }
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
      // `*Callback` lifetime-safe overload for async methods. Generated
      // alongside the base wrapper when a parameter is `scope="async"`.
      // Skip when the base wrapper was skipped (shadowed/moved/...).
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
    for (final f in cls.functions) {
      final name = CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(f.name)));
      if (!memberNames.add(name)) {
        ctx.report.skip('function', '$dartName.$name', 'name collision');
        continue;
      }
      final code = callables.emit(f,
          dartName: name, ownerName: dartName, staticMember: true);
      if (code != null) b.writeln(_indent(code));
    }
    final inherited = inheritedSignals(cls, ctx);
    final allSignals = [...cls.signals, ...inherited];
    final entries = <({GirSignal signal, GirNamespace? ns})>[
      for (final s in cls.signals) (signal: s, ns: ctx.namespace),
      for (final i in inherited) (signal: i, ns: _signalOwnerNs(cls, i.name, ctx)),
    ];
    final signalCode = emitSignalConnectors(
      ctx,
      allSignals,
      dartName,
      memberNames,
      buckets: buildSignalBuckets(entries, ctx),
    );
    if (signalCode.isNotEmpty) {
      b.writeln(_indent(signalCode));
    }
    b.write('}');
    return b.toString();
  }

  static String _indent(String code) =>
      code.split('\n').map((l) => l.isEmpty ? l : '  $l').join('\n');

  /// Signature keys of all ancestor instance methods, by emitted Dart name.
  Map<String, String> _ancestorMethodSigs(GirClass cls) {
    final map = <String, String>{};
    var current = cls;
    final seen = <String>{};
    while (current.parent != null && seen.add(current.name)) {
      final found = ctx.findClass(current.parent!);
      if (found == null) break;
      current = found.$2;
      for (final m in current.methods) {
        final name =
            CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));
        map.putIfAbsent(name, () => _methodKey(m));
      }
    }
    return map;
  }

  /// A structural signature key: return type, nullability, and parameter
  /// types/directions. Type names are compared unqualified.
  static String _methodKey(GirFunction m) {
    String typeKey(GirTypeRef? t) {
      if (t == null) return 'void';
      if (t.isArray) return '[]${typeKey(t.array!.elementType)}';
      final n = t.name ?? t.cType ?? '?';
      final dot = n.lastIndexOf('.');
      return dot >= 0 ? n.substring(dot + 1) : n;
    }

    final params = m.parameters
        .map((p) =>
            '${p.direction.name}:${typeKey(p.type)}${p.nullable ? '?' : ''}')
        .join(',');
    return '${typeKey(m.returnType)}${m.returnNullable ? '?' : ''}($params)';
  }

  /// Returns the namespace where [signalName] is declared, walking up
  /// [cls]'s parent chain. Used to resolve signal arg types against the
  /// namespace where the signal was authored (Gtk's `Window` arg vs.
  /// Adw's `Window`).
  static GirNamespace? _signalOwnerNs(
    GirClass cls,
    String signalName,
    EmitContext ctx,
  ) {
    var current = cls;
    var currentNs = ctx.namespace;
    final seen = <String>{};
    while (seen.add('${currentNs.name}.${current.name}')) {
      if (current.signals.any((s) => s.name == signalName)) {
        return currentNs;
      }
      if (current.parent == null) break;
      final found = ctx.findClass(current.parent!);
      if (found == null) break;
      final (ns, parent) = found;
      currentNs = ns;
      current = parent;
    }
    return ctx.namespace;
  }
}
