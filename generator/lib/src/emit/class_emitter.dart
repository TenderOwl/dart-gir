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
    final interfaceSigs = _interfaceMethodSigs(cls);
    final inheritedSigs = _inheritedSigs(cls);
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

    // Mirror instance methods from every implemented GIR interface
    // onto the class. Users then write `button.setActionName('win.open')`
    // directly instead of `GtkActionable(button.handle).setActionName(...)`.
    // The interface's own `final class` keeps its methods so wrapping
    // opaque pointers still works.
    if (cls.implements_.isNotEmpty) {
      b.writeln(_emitInterfaceMirrors(
        cls,
        dartName,
        callables,
        memberNames,
        interfaceSigs,
        inheritedSigs,
      ));
    }

    b.write('}');
    return b.toString();
  }

  /// Mirrors instance methods declared on the GIR interfaces that [cls]
  /// implements onto the generated class. Each interface method is
  /// emitted as a regular instance method with `this.handle` as the
  /// self-argument (matching the FFI call signature on the
  /// concrete-class instance).
  ///
  /// Failure modes (each reported to `ctx.report` with the matching
  /// reason and skipped silently, matching the parent-ancestor
  /// resolution path):
  ///
  /// * Interface name doesn't resolve → `interface <name> not found`.
  /// * Interface lives in a non-emitted package →
  ///   `interface <name> is in non-generated package <pkg>`.
  /// * Class already has a member of that name → `name collision`
  ///   (the class's own method wins; the interface still has it).
  /// * Method signature diverges from the interface's expected
  ///   override → renamed `<name><ClassName>` (recorded as
  ///   `override-incompatible with interface; renamed to <name>`).
  ///
  /// The mirrored method reuses the interface's native binding
  /// (e.g. `gtk_actionable_set_action_name` is looked up once per
  /// concrete class, not once per call).
  String _emitInterfaceMirrors(
    GirClass cls,
    String dartName,
    CallableEmitter callables,
    Set<String> memberNames,
    Map<String, String> interfaceSigs,
    Map<String, String> inheritedSigs,
  ) {
    final b = StringBuffer();
    final seenInterfaces = <String>{};
    for (final implName in cls.implements_) {
      final found = ctx.findInterface(implName);
      if (found == null) {
        ctx.report.skip('method', '$dartName.${cls.name}',
            'interface $implName not found');
        continue;
      }
      final (ifaceNs, iface) = found;
      // Cross-package: the interface lives in another emitted package,
      // so we *may* need an import — but only if at least one of the
      // mirrored methods references a wrapper type from that package
      // (e.g. `GIcon`, `GObject`). Most interface mirrors operate on
      // `Pointer<Void>` and primitives, so the import would be unused
      // and trip `unused_import`. The check below scans each method's
      // parameter and return-type bridges for foreign-package
      // references and only adds the import when one is found.
      final ifacePkg = packageNameFor(ifaceNs);
      if (ifacePkg != packageNameFor(ctx.namespace) &&
          !emittedPackages.contains(ifacePkg)) {
        ctx.report.skip('method', '$dartName.${cls.name}',
            'interface $implName is in non-generated package $ifacePkg');
        continue;
      }
      if (ifacePkg != packageNameFor(ctx.namespace) &&
          _interfaceNeedsImport(iface, ifaceNs, ifacePkg)) {
        ctx.imports.add(ifacePkg);
      }
      // Dedup: avoid emitting the same interface's methods twice if a
      // class declares it twice (rare, but harmless).
      if (!seenInterfaces.add('${ifaceNs.name}.${iface.name}')) continue;
      for (final m in iface.methods) {
        var name =
            CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));
        final mirroredKey = _methodKey(m);
        // Override-incompatible with the parent class's same-named
        // method → rename so we don't shadow it with a different
        // signature (Dart would emit `invalid_override`). Common
        // example: a parent class returns `bool use()` while the
        // interface declares `void use()`.
        final inheritedSig = inheritedSigs[name];
        if (inheritedSig != null && inheritedSig != mirroredKey) {
          final renamed = '$name${cls.name}';
          ctx.report.skip('renamed', '$dartName.$name',
              'override-incompatible with ancestor; renamed to $renamed');
          name = renamed;
        }
        // Override-incompatible with the interface's own expected
        // signature → rename so the class doesn't claim to satisfy
        // the interface (purely defensive until Phase 2 promotes
        // interfaces to `abstract`).
        final ifaceSig = interfaceSigs[name];
        if (ifaceSig != null && ifaceSig != mirroredKey) {
          final renamed = '$name${cls.name}';
          ctx.report.skip('renamed', '$dartName.$name',
              'override-incompatible with interface; renamed to $renamed');
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
        // Async-callback lifetime-safe overload — same detection rule
        // as class methods (line 143-156).
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
    }
    return b.toString();
  }

  static String _indent(String code) =>
      code.split('\n').map((l) => l.isEmpty ? l : '  $l').join('\n');

  /// Signature keys of all ancestor instance methods, by emitted Dart
  /// name. Includes the ancestor's interface-mirrored methods, so the
  /// rename pass on the class's own methods (`activate` →
  /// `activateActionRow`) fires when the class declares a method with
  /// the same name as an interface method the parent absorbed. Without
  /// the interface-method sweep, `CellAreaBox.packEnd(4 args)` would
  /// silently try to override `CellArea.packEnd(2 args)` (mirrored
  /// from `GtkCellLayout`) and trip `invalid_override`.
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
      for (final implName in current.implements_) {
        final ifound = ctx.findInterface(implName);
        if (ifound == null) continue;
        for (final m in ifound.$2.methods) {
          final name = CallableEmitter.safeMemberName(
            escapeKeyword(toLowerCamel(m.name)),
          );
          map.putIfAbsent(name, () => _methodKey(m));
        }
      }
    }
    return map;
  }

  /// Signature keys of all methods declared on interfaces that [cls]
  /// implements, by emitted Dart name. Used by the override-incompatible
  /// renaming pass — a class method whose signature differs from the
  /// matching interface method is renamed (e.g. `activate` →
  /// `activateActionRow`) so it doesn't override the interface's
  /// signature when (eventually) wired up via `implements`. Mirrors
  /// [_ancestorMethodSigs] but traverses [GirClass.implements_] instead
  /// of the parent chain.
  Map<String, String> _interfaceMethodSigs(GirClass cls) {
    final map = <String, String>{};
    for (final name in cls.implements_) {
      final found = ctx.findInterface(name);
      if (found == null) continue;
      for (final m in found.$2.methods) {
        final dartName = CallableEmitter.safeMemberName(
          escapeKeyword(toLowerCamel(m.name)),
        );
        map.putIfAbsent(dartName, () => _methodKey(m));
      }
    }
    return map;
  }

  /// Signature keys of every method already in scope on [cls] *before*
  /// interface mirroring runs — the parent's instance methods *and* any
  /// interface methods the parent (or its parents) had mirrored onto
  /// them. Used by the interface-mirroring pass to detect
  /// override-incompatible shadows: if the interface declares
  /// `use()` returning `void` but the parent class's `use()` returns
  /// `bool`, mirroring the interface's `use()` would shadow the
  /// parent's method with an incompatible signature. We rename the
  /// mirrored method (`useIOModule`) to avoid the clash.
  ///
  /// The recursion includes the parent's mirrored interface methods
  /// because once a parent has absorbed an interface method, that
  /// method is part of its public surface and any subclass mirroring
  /// the same interface must take it into account. Without this,
  /// `CellAreaBox.packEnd(4 args)` would silently shadow the parent's
  /// `CellArea.packEnd(2 args)` (mirrored from `GtkCellLayout`).
  ///
  /// Order matters: parent's own methods are recorded *first* (they
  /// take priority over any interface method with the same name —
  /// Dart's name resolution picks the parent's method). Without this
  /// ordering, the interface method would be recorded first and
  /// `putIfAbsent` would lock in the wrong (interface) signature.
  Map<String, String> _inheritedSigs(GirClass cls) {
    final map = <String, String>{};
    // 1. Walk the parent chain first. Parent methods always shadow
    //    interface methods with the same name in Dart's resolution
    //    rules, so they win the putIfAbsent race.
    var current = cls;
    final seen = <String>{};
    while (current.parent != null && seen.add(current.name)) {
      final found = ctx.findClass(current.parent!);
      if (found == null) break;
      current = found.$2;
      for (final m in current.methods) {
        final name = CallableEmitter.safeMemberName(
          escapeKeyword(toLowerCamel(m.name)),
        );
        map.putIfAbsent(name, () => _methodKey(m));
      }
      for (final implName in current.implements_) {
        final ifound = ctx.findInterface(implName);
        if (ifound == null) continue;
        for (final m in ifound.$2.methods) {
          final name = CallableEmitter.safeMemberName(
            escapeKeyword(toLowerCamel(m.name)),
          );
          map.putIfAbsent(name, () => _methodKey(m));
        }
      }
    }
    // 2. The class's own declared methods override parent methods.
    for (final m in cls.methods) {
      final name =
          CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));
      map.putIfAbsent(name, () => _methodKey(m));
    }
    // 3. Note: cls.implements_ is intentionally NOT included — the
    //    class is currently in the middle of being emitted, and the
    //    interface methods are about to be added in [_emitInterfaceMirrors].
    //    Including them here would mean they always shadow the parent's
    //    own methods, which is the wrong direction.
    return map;
  }

  /// Returns `true` if any of [iface]'s methods reference a class or
  /// record type declared in [ifaceNs] (i.e. a type whose wrapper
  /// Dart name would require an `import 'package:<ifacePkg>/<ifacePkg>.dart';`
  /// in the emitting package's barrel). Used to suppress
  /// `unused_import` warnings when the interface only takes / returns
  /// primitives, `Pointer<Void>`, or types from a *different* package
  /// that the emitting package already imports (e.g. `GObject` lives
  /// in `gobject`, not in `gio`, so mirroring `Gio.ListModel.getItem`
  /// onto a Pango class needs `gobject`, not `gio`).
  bool _interfaceNeedsImport(
      GirInterface iface, GirNamespace ifaceNs, String ifacePkg) {
    bool refsForeignWrapper(GirFunction m) {
      final types = <GirTypeRef?>[
        m.returnType,
        for (final p in m.parameters) p.type,
      ];
      for (final t in types) {
        if (t == null) continue;
        final mapping = ctx.resolver.resolve(t, currentNamespace: ifaceNs);
        // Only count types whose required import is the interface's
        // own package. A `requiredImport` of any other value (e.g.
        // `gobject`) means the emitting package already imports it
        // (or will import it via its own class emission).
        if (mapping.requiredImport == ifacePkg) return true;
      }
      return false;
    }

    for (final m in iface.methods) {
      if (refsForeignWrapper(m)) return true;
    }
    return false;
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
