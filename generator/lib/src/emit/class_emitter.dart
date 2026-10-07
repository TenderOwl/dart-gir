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

  /// Namespace functions to re-emit as static methods on the owning GIR
  /// class. Populated by `PackageEmitter.emit()` once per package and
  /// read in `emitClass` — see `class_emitter.dart` "Static class
  /// functions" for the detection rule (`moved-to` value has no dot).
  /// Optional so the emitter remains constructible without the pre-scan.
  Map<String, StaticClassFunction> staticClassFunctions = const {};

  /// Set by [emitClass] when the class has at least one emitted
  /// property accessor. The caller should append this string as a
  /// top-level class declaration in the same part file, immediately
  /// before the corresponding class. Reset to `null` before each
  /// emit.
  String? pendingPropsClass;

  /// Set of fully-qualified props class names that this class
  /// emission actually emitted (i.e. the props class has at least
  /// one accessor). Used by other class emissions to decide whether
  /// they can `extends` a parent props class. Reset to `null`
  /// alongside `pendingPropsClass`.
  Set<String>? emittedPropsClasses;

  /// Returns `true` if [cls] would emit a props companion class —
  /// i.e. it's GObject-rooted, has at least one property (own or
  /// inherited), and has at least one property accessor that won't
  /// be skipped. Used by the package emitter to populate the
  /// `emittedPropsClasses` set in advance of the main emission
  /// loop, so that `extends <parentProps>` clauses resolve
  /// correctly regardless of class declaration order.
  bool wouldEmitPropsClass(GirClass cls) {
    if (!ctx.isGObjectRooted(cls)) return false;
    final inherited = _inheritedProperties(cls);
    if (inherited.isEmpty) return false;
    // Walk the inherited properties to check whether at least one
    // accessor will actually be emitted. We use a lightweight check
    // (does the typed method exist?) rather than re-running the
    // full property emission logic. Setters with multiple non-self
    // args or getters with extra args will still skip during the
    // actual emission, but the props class declaration stays alive.
    for (final access in inherited) {
      final prop = access.property;
      final owner = access.owner;
      if (prop.readable) {
        final getterName = prop.getter ?? 'get_${prop.name}';
        if (_findMethodByName(owner, getterName) != null) return true;
      }
      if (prop.writable) {
        final setterName = prop.setter ?? 'set_${prop.name}';
        if (_findMethodByName(owner, setterName) != null) return true;
      }
    }
    return false;
  }

  String? emitClass(GirClass cls) {
    pendingPropsClass = null;
    final dartName = ctx.dartTypeName(ctx.namespace.name, cls.name);
    if (ctx.isDuplicateType(cls)) {
      ctx.report.skip(
        'class',
        dartName,
        'duplicate declaration owned by an earlier namespace',
      );
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
        ctx.report.skip(
          'class',
          dartName,
          'parent ${cls.parent} not found; emitted without superclass',
        );
      } else {
        final (parentNs, parentCls) = found;
        final parentPkg = parentNs.name == ctx.namespace.name
            ? null
            : packageNameFor(parentNs);
        if (parentPkg != null && !emittedPackages.contains(parentPkg)) {
          ctx.report.skip(
            'class',
            dartName,
            'parent ${cls.parent} is in non-generated package $parentPkg',
          );
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

    // Build the set of interfaces the class can structurally satisfy
    // — populated by `_emitInterfaceMirrors` once it walks each
    // `<implements>` entry and decides whether the mirror is intact
    // (no override-incompatible rename, no collision). The
    // `implements <Name>` clause is built from this set so we never
    // emit a clause the Dart analyzer would reject.
    final implementsOk = <String>{}; // Dart type names
    final currentPkg = packageNameFor(ctx.namespace);
    for (final implName in cls.implements_) {
      final decl = ctx.findDeclaration(implName);
      if (decl == null) continue;
      final (ns, obj) = decl;
      // findDeclaration returns Object; every type it can resolve
      // extends GirRegisteredType, so the cast is safe.
      final reg = obj is GirRegisteredType ? obj : null;
      if (reg == null) continue;
      final implPkg = packageNameFor(ns);
      // Skip interfaces in packages the user isn't regenerating
      // (same policy as the mirrored-method emission).
      if (implPkg != currentPkg && !emittedPackages.contains(implPkg)) {
        continue;
      }
      implementsOk.add(ctx.dartTypeName(ns.name, reg.name));
      // Make the foreign import visible so the implements-clause
      // identifier resolves at compile time.
      if (implPkg != currentPkg) {
        ctx.imports.add(implPkg);
      }
    }

    final callables = CallableEmitter(ctx);
    final memberNames = <String>{'handle', 'owned', 'fromPointer', dartName};
    final ancestorSigs = _ancestorMethodSigs(cls);
    final interfaceSigs = _interfaceMethodSigs(cls);
    final inheritedSigs = _inheritedSigs(cls);
    final inheritedProps = _inheritedProperties(cls);
    // Reserve the `props` field/getter and the props companion class
    // name before the property loop runs, so they survive the
    // `memberNames.add(name)` collision checks below. The companion
    // class is intentionally public (no leading underscore) so that
    // cross-package subclasses can `extends` it for covariant return
    // types — e.g. `_AdwAvatarProps extends _GtkWidgetProps` would
    // not compile across the package boundary because Dart's part
    // system hides underscore-prefixed names from other libraries.
    memberNames.add('props');
    memberNames.add('_props');
    final propsClassName = '${dartName}Props';
    var unnamedCtorUsed = false;
    final b = StringBuffer();
    for (final line in ctx.docLines(cls.doc)) {
      b.writeln(line);
    }
    // The class header placeholder is emitted with the *current*
    // implementsOk set; it gets replaced after `_emitInterfaceMirrors`
    // mutates the set (a rename removes an interface from the set so
    // the post-mirror header reflects what's structurally satisfied).
    b.writeln('__DART_GIR_HEADER_PLACEHOLDER__');
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
          'void _attachFinalizer() => gobjectFinalizer.attach(this, handle, detach: this);',
        );
      }
    } else {
      b.writeln(
        '$dartName.fromPointer(super.handle, {super.owned}) : super.fromPointer();',
      );
    }
    // `cast<T>(factory)` lets the user recover the destination class's
    // methods from a borrowed wrapper (e.g. `GObject` from
    // `GListModel.getObject`, `GtkWidget` from `AdwTabPage.getChild`).
    // The bound is `Object` so subclasses can validly override — most
    // wrappers in the corpus don't form an `extends` chain (interfaces
    // like `GFile` are emitted as `class GFile {` with no parent, so
    // `T extends GObject` would conflict when GFile overrides the
    // inherited `cast` from any GObject subclass). `Object` is the
    // trivial bound that lets `T` be any class the user has a
    // `fromPointer` for; the factory parameter type-checks the
    // destination.
    b.writeln();
    b.writeln('/// Re-wraps this wrapper\'s [handle] as [T] via [factory].');
    b.writeln('///');
    b.writeln('/// Use this when another wrapper returns this class\'s');
    b.writeln('/// instance but the caller needs the destination class\'s');
    b.writeln('/// methods. Pass the destination class\'s `fromPointer` as');
    b.writeln(
      '/// the callback, e.g. `wrapper.cast<GFile>(GFile.fromPointer)`.',
    );
    b.writeln('/// The handle is forwarded as-is; the original wrapper');
    b.writeln('/// (which produced this object) remains the owner.');
    b.writeln('T cast<T extends Object>(');
    b.writeln('  T Function(ffi.Pointer<ffi.Void>) factory,');
    b.writeln(') {');
    b.writeln('  return factory(handle);');
    b.writeln('}');

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
      final code = callables.emit(
        c,
        dartName: name,
        ownerName: dartName,
        classMember: true,
        factoryClass: dartName,
        sinkFloating: sink,
      );
      if (code != null) b.writeln(_indent(code));
    }
    for (final m in cls.methods) {
      var name = CallableEmitter.safeMemberName(
        escapeKeyword(toLowerCamel(m.name)),
      );
      // A member whose inherited signature differs (return type, parameter
      // types, nullability) is not a valid Dart override; rename it by
      // appending the class's GIR name (`activate` on AdwActionRow →
      // `activateActionRow`).
      final ancestorSig = ancestorSigs[name];
      if (ancestorSig != null && ancestorSig != _methodKey(m)) {
        final renamed = '$name${cls.name}';
        ctx.report.skip(
          'renamed',
          '$dartName.$name',
          'override-incompatible with ancestor; renamed to $renamed',
        );
        name = renamed;
      }
      // Same defensive rule for implemented interfaces: a class method
      // whose signature disagrees with the interface's same-named method
      // would be flagged `invalid_override` by the Dart analyzer once
      // the implements clause lands (`GTask.getSourceObject` returning
      // `Pointer<Void>` vs. `GAsyncResult.getSourceObject` returning
      // `GObject?`). Rename the class's variant so the interface's
      // method remains the canonical override target.
      final ifaceSig = interfaceSigs[name];
      if (ifaceSig != null && ifaceSig != _methodKey(m)) {
        final renamed = '$name${cls.name}';
        ctx.report.skip(
          'renamed',
          '$dartName.$name',
          'override-incompatible with interface; renamed to $renamed',
        );
        name = renamed;
        // The rename removes the implements-clause guarantee for this
        // interface, so drop it from the implements list.
        for (final implName in cls.implements_) {
          final decl = ctx.findInterface(implName);
          if (decl == null) continue;
          final (ns, iface) = decl;
          for (final im in iface.methods) {
            final imName = CallableEmitter.safeMemberName(
              escapeKeyword(toLowerCamel(im.name)),
            );
            if (imName == name.replaceFirst(cls.name, '')) {
              implementsOk.remove(ctx.dartTypeName(ns.name, iface.name));
            }
          }
        }
      }
      // Moved-to methods are skipped at emission time — the
      // canonical landing site is a namespace function or another
      // class method (depending on whether the value contains a
      // dot). Don't reserve the Dart member name: the namespace
      // function brought to this class as a static method may
      // normalise to the same identifier (`_register` → `register`
      // is fine; an artificial `_bar`/`bar` would collide).
      if (m.movedTo == null) {
        if (CallableEmitter.conflictsWithObjectMember(name) ||
            !memberNames.add(name)) {
          ctx.report.skip('method', '$dartName.$name', 'name collision');
          continue;
        }
      }
      final code = callables.emit(
        m,
        dartName: name,
        ownerName: dartName,
        classMember: true,
        selfArgExpr: 'this.handle',
      );
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
      final name = CallableEmitter.safeMemberName(
        escapeKeyword(toLowerCamel(f.name)),
      );
      if (!memberNames.add(name)) {
        ctx.report.skip('function', '$dartName.$name', 'name collision');
        continue;
      }
      final code = callables.emit(
        f,
        dartName: name,
        ownerName: dartName,
        staticMember: true,
      );
      if (code != null) b.writeln(_indent(code));
    }
    // Static class functions (namespace functions brought to this
    // class as `static` methods because a sibling `<method>` carries
    // `moved-to="<bare>"`). The pre-scan in `PackageEmitter.emit()`
    // built the map; we filter by the owning class's Dart name. The
    // corresponding namespace function is suppressed by
    // `FunctionEmitter.emitFunction` so there's only one call site.
    for (final entry in staticClassFunctions.values) {
      if (entry.ownerClassDartName != dartName) continue;
      final name = CallableEmitter.safeMemberName(
        escapeKeyword(toLowerCamel(entry.namespaceFunctionName)),
      );
      if (CallableEmitter.conflictsWithObjectMember(name) ||
          !memberNames.add(name)) {
        ctx.report.skip(
          'function',
          '$dartName.$name',
          'name collision (static class function from ${entry.fn.cIdentifier ?? entry.namespaceFunctionName})',
        );
        continue;
      }
      final code = callables.emit(
        entry.fn,
        dartName: name,
        ownerName: dartName,
        staticMember: true,
      );
      if (code != null) b.writeln(_indent(code));
    }
    final inherited = inheritedSignals(cls, ctx);
    final allSignals = [...cls.signals, ...inherited];
    final entries = <({GirSignal signal, GirNamespace? ns})>[
      for (final s in cls.signals) (signal: s, ns: ctx.namespace),
      for (final i in inherited)
        (signal: i, ns: _signalOwnerNs(cls, i.name, ctx)),
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
      b.writeln(
        _emitInterfaceMirrors(
          cls,
          dartName,
          callables,
          memberNames,
          interfaceSigs,
          inheritedSigs,
          implementsOk.isEmpty ? null : implementsOk,
        ),
      );
    }

    // `props` accessor — PyGObject-style typed property namespace. The
    // helper class `_$<cls>Props` is emitted as a *top-level* class
    // (alongside the class declaration in the same part file), so only
    // the field + getter go inside the class body.
    if (ctx.isGObjectRooted(cls) && inheritedProps.isNotEmpty) {
      // Stash the props class source for the caller to emit at
      // top-level alongside this class.
      pendingPropsClass = _emitPropsClass(dartName, inheritedProps, cls);
      if (pendingPropsClass != null) {
        b.writeln('');
        b.writeln('  /// PyGObject-style typed property accessor. Reads and');
        b.writeln('  /// writes via the existing `get<Name>` / `set<Name>`');
        b.writeln('  /// methods; each property here corresponds to a GIR');
        b.writeln('  /// `<property>` element on this class (or one of its');
        b.writeln('  /// ancestors). See [$propsClassName] for the typed');
        b.writeln('  /// accessor pair per property.');
        // Explicit type annotation on `_props` so the child's late-final
        // field type is the child props class, not the parent's. Dart's
        // late-final inference for a field that shadows a parent's
        // late-final field with a different initializer type picks the
        // parent's static type, breaking the covariant return on the
        // public `props` getter below (e.g. `GtkButtonProps get props
        // => _props` would reject `_props` as `GtkWidgetProps`).
        b.writeln(
          '  late final $propsClassName _props = '
          '$propsClassName(this);',
        );
        b.writeln('  $propsClassName get props => _props;');
      }
    }

    b.write('}');
    // Replace the placeholder header with the final one — built from
    // the post-mirror `implementsOk` set (renames may have removed
    // entries). Without this rewrite, the header would include
    // `implements <Name>` for an interface whose methods were
    // renamed away, which Dart's analyzer would reject.
    final header =
        'class $dartName${parentName != null ? ' extends $parentName' : ''}'
        '${parentName == null && rooted ? ' implements ffi.Finalizable' : ''}'
        '${implementsOk.isNotEmpty ? ' implements ${implementsOk.join(', ')}' : ''} {';
    return b.toString().replaceFirst('__DART_GIR_HEADER_PLACEHOLDER__', header);
  }

  /// Returns the union of this class's properties and its ancestors',
  /// deduplicated by kebab-case GIR name. Each entry uses the leaf
  /// class's getter/setter when both exist (matches Dart's name
  /// resolution rules: parent's property is shadowed by the child's if
  /// the child declares the same name).
  List<_PropertyAccess> _inheritedProperties(GirClass cls) {
    final result = <_PropertyAccess>[];
    final seen = <String>{};
    // Walk ancestors first, leaf first so the leaf's access methods
    // win on dedup collisions.
    void visit(GirClass c) {
      for (final p in c.properties) {
        if (seen.add(p.name)) {
          result.add(_PropertyAccess(property: p, owner: c));
        }
      }
      if (c.parent != null) {
        final found = ctx.findClass(c.parent!);
        if (found != null) visit(found.$2);
      }
    }

    visit(cls);
    return result;
  }

  /// Emits the `<ClassName>Props` companion class that backs the
  /// `props` field. Returns `null` if no property accessor could be
  /// emitted (every property was skipped), so the caller can suppress
  /// the `props` field rather than emit a half-broken surface.
  String? _emitPropsClass(
    String dartName,
    List<_PropertyAccess> accesses,
    GirClass cls,
  ) {
    final propsClassName = '${dartName}Props';
    final b = StringBuffer();
    b.writeln('/// PyGObject-style typed property accessor. Each getter');
    b.writeln('/// and setter delegates to the existing typed');
    b.writeln('/// `get<Name>` / `set<Name>` methods on [$dartName].');
    b.writeln('///');
    b.writeln('/// Skipped properties (unsupported type, missing getter');
    b.writeln('/// or setter) are recorded in the generation report.');
    // If the parent class would emit a props companion class, extend
    // it so the child's getter can override the parent's with a
    // covariant narrower type (e.g. `GtkButtonProps extends
    // GtkWidgetProps`). The check uses [wouldEmitPropsClass] so that
    // parents with no own properties but inherited ones (e.g.
    // `GtkGestureDrag`, which has no own `<property>` but inherits
    // `button` from `GtkGestureSingle`) still get an `extends` clause.
    String? extendsClause;
    if (cls.parent != null) {
      final found = ctx.findClass(cls.parent!);
      if (found != null && wouldEmitPropsClass(found.$2)) {
        final parentDartName = ctx.dartTypeName(found.$1.name, found.$2.name);
        extendsClause = '${parentDartName}Props';
      }
    }
    // `class` (not `final class`) so subclasses in *other* packages can
    // extend it for cross-package covariant-return override. Within a
    // single package the props classes are leaf-most classes, but
    // cross-package subclassing (e.g. `AdwAvatar extends GtkWidget`)
    // makes them mid-hierarchy.
    b.writeln(
      'class $propsClassName '
      '${extendsClause != null ? 'extends $extendsClause ' : ''}{',
    );
    // Constructor forwards `_self` to the parent props class when
    // extending one. Use an initializing formal on the super call to
    // give it the child's `_self` — Dart allows `super.x` only when
    // `x` is the formal parameter from the constructor's parameter
    // list, so we capture it in a local first.
    if (extendsClause != null) {
      b.writeln(
        '  $propsClassName($dartName \$self) : _self = \$self, super(\$self);',
      );
    } else {
      b.writeln('  $propsClassName(this._self);');
    }
    b.writeln('  final $dartName _self;');
    var emitted = 0;
    for (final access in accesses) {
      final prop = access.property;
      final owner = access.owner;
      final accessor = _emitPropertyAccessor(prop, owner, dartName, cls);
      if (accessor == null) continue;
      b.writeln('');
      if (prop.deprecated) {
        b.writeln('  // deprecated since ${prop.version ?? 'this version'}.');
      }
      b.writeln(accessor);
      emitted++;
    }
    if (emitted == 0) return null;
    b.write('}');
    return b.toString();
  }

  /// Emits one `get`/`set` accessor pair (or single accessor for
  /// read-only / write-only properties) for [prop] on the owner class.
  /// Returns the accessor source (without surrounding newlines) or
  /// `null` if the property's getter/setter can't be resolved.
  String? _emitPropertyAccessor(
    GirProperty prop,
    GirClass owner,
    String dartName,
    GirClass leaf,
  ) {
    // Resolve the property's Dart type for skip-reason reporting only
    // (e.g. unsupported array types). The accessor signatures below
    // are derived from the typed method's bridge, not from this, so
    // nullability propagates correctly: `<type name="utf8"/>` declared
    // on the property is `String`, but `gtk_button_get_label` returns
    // `String?` because the C function's `transfer-ownership="none"`
    // gchar* is nullable — and the props getter must mirror that.
    final ownerNs = _namespaceOfClass(owner) ?? ctx.namespace;
    final propertyType = _resolvePropertyType(prop, ownerNs);
    if (propertyType == null) {
      ctx.report.skip(
        'property',
        '$dartName.${prop.name}',
        'unsupported type ${prop.type?.name ?? prop.type?.cType}',
      );
      return null;
    }
    // Find the backing typed methods. Match by GIR name (the
    // `<method name="…">` element), not by C identifier — the
    // generator's normalizer already turned `gtk_button_get_label`
    // into the method `name="get_label"`.
    final readable = prop.readable;
    final writable = prop.writable;
    if (!readable && !writable) return null;
    String? getterCall;
    String? getterDartType;
    String? setterCall;
    String? setterDartType;
    if (readable) {
      // GIR convention: if `getter=` is omitted, the C function is
      // `get_<name>`. Many properties omit the attribute explicitly.
      final effectiveGetterName = prop.getter ?? 'get_${prop.name}';
      final m = _findMethodByName(owner, effectiveGetterName);
      if (m == null) {
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'missing getter $effectiveGetterName',
        );
        return null;
      }
      // The property getter exposes zero non-self arguments. A
      // typed method like `get_size(orientation)` takes an extra
      // `GtkOrientation` and can't be represented as a no-arg props
      // getter.
      if (m.parameters.isNotEmpty) {
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'getter $effectiveGetterName takes '
              '${m.parameters.length} args; props layer only supports 0',
        );
        return null;
      }
      // Skip when the leaf's emission would have renamed the typed
      // method due to an override-incompatible ancestor — we can't
      // dispatch to a renamed method without tracking the rename
      // mapping. The user can still call the renamed method
      // directly.
      if (_wasRenamed(m, owner)) {
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'getter $effectiveGetterName was renamed; '
              'call the renamed method directly',
        );
        return null;
      }
      // Resolve the typed method's return type via `bridgeFor` so
      // the props getter inherits the correct nullability (e.g.
      // `String?` for gchar* transfer-none). Fall back to the
      // property's declared type only if the method's bridge isn't
      // available — in practice that won't happen because the method
      // emits its own wrapper with the same bridge, but keeping the
      // fallback makes the props layer robust to future refactors.
      // The `relativeTo: ownerNs` is essential: unqualified `<type>`
      // names in the typed method's signature resolve against the
      // namespace where the method was *declared* (e.g. Gtk for
      // `GtkWindow.set_application`'s `Application` parameter), not
      // the emission namespace (which would be Adw when emitting
      // AdwMessageDialogProps, picking up `Adw.Application` by
      // mistake and breaking the parent's covariant setter).
      final (bridge, _) = ctx.bridgeFor(
        m.returnType,
        nullable: m.returnNullable,
        transfer: m.returnTransfer,
        forReturn: true,
        relativeTo: ownerNs,
      );
      getterDartType = bridge?.wrapperType ?? propertyType;
      getterCall = _getterName(m);
    }
    if (writable) {
      final effectiveSetterName = prop.setter ?? 'set_${prop.name}';
      final m = _findMethodByName(owner, effectiveSetterName);
      if (m == null) {
        // Construct-only properties (`construct-only="1"` in GIR) are
        // writable but have no public setter — they're set via the
        // class constructor. Fall back to read-only rather than
        // dropping the whole property.
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'construct-only or no public setter; emitting getter only',
        );
      } else if (m.parameters.length > 1) {
        // The property setter exposes exactly one value (the
        // property's own value). C functions that take an extra
        // `length` / `n_bytes` / `len` parameter — e.g.
        // `gtk_text_buffer_set_text(text, len)` — can't be
        // represented as a single-arg props setter. Skip with a
        // precise reason; the user can still call the typed method
        // directly.
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'setter $effectiveSetterName takes '
              '${m.parameters.length} args; props layer only supports 1',
        );
      } else if (_wasRenamed(m, owner)) {
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'setter $effectiveSetterName was renamed; '
              'call the renamed method directly',
        );
      } else if (m.parameters.isNotEmpty &&
          !_matchesPropertyType(m.parameters.first.type, prop.type, owner)) {
        // The typed setter's parameter type is narrower than the
        // property's declared type (e.g. `set_visible_page(Adw…Page)`
        // when the property type is `Gtk.Widget`). Without a
        // covariant cast we'd need a Dart `as`; rather than emit an
        // unsafe cast, skip the property. The user can still call
        // the typed method directly with the narrower type.
        ctx.report.skip(
          'property',
          '$dartName.${prop.name}',
          'setter $effectiveSetterName parameter type does '
              'not match property type; skipping',
        );
      } else {
        // Resolve the typed setter's parameter type via `bridgeFor`
        // for the same nullability reasons as the getter: the props
        // setter signature must accept the same value type the typed
        // method accepts, including nullability (`String` vs
        // `String?`). The `relativeTo: ownerNs` pins unqualified
        // `<type>` names to the namespace where the property was
        // declared; without this, the emission namespace (which can
        // be a descendant of the owner) would shadow the owner's
        // type with a same-named child class (e.g. Adw.Application
        // masking Gtk.Application).
        final param = m.parameters.first;
        final (bridge, _) = ctx.bridgeFor(
          param.type,
          nullable: param.nullable,
          transfer: param.transferOwnership,
          relativeTo: ownerNs,
        );
        setterDartType = bridge?.wrapperType ?? propertyType;
        setterCall = _setterName(m);
      }
    }
    if (getterCall == null && setterCall == null) return null;
    final propName = escapeKeyword(toLowerCamel(prop.name));
    final b = StringBuffer();
    if (getterCall != null) {
      b.writeln('  $getterDartType get $propName => _self.$getterCall();');
    }
    if (setterCall != null) {
      b.writeln('  set $propName($setterDartType value) {');
      b.writeln('    _self.$setterCall(value);');
      b.writeln('  }');
    }
    // Trim the trailing newline — the caller adds blank lines between
    // accessors for readability.
    final s = b.toString();
    return s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  }

  /// Resolves the Dart type for [prop]. Returns `null` if the property
  /// type can't be mapped (e.g. unsupported array). Uses the same
  /// qualified-name resolution as [CallableEmitter] for class-typed
  /// parameters: `Widget` in `Gtk` namespace becomes `GtkWidget`,
  /// not bare `Widget`.
  String? _resolvePropertyType(GirProperty prop, GirNamespace ownerNs) {
    if (prop.type == null) return null;
    final mapping = ctx.resolver.resolve(prop.type!, currentNamespace: ownerNs);
    if (mapping.dartType.isEmpty ||
        mapping.dartType == 'unsupported' ||
        mapping.kind.toString().contains('unsupported')) {
      return null;
    }
    // For class / interface / record / union / bitfield / enum types,
    // qualify the Dart name with its namespace so the import resolver
    // can find it. For built-in scalar types (gboolean → bool, gint
    // → int, utf8 → String, etc.) `mapping.dartType` is already the
    // final Dart type and needs no prefix.
    switch (mapping.kind) {
      case TypeKind.classType:
      case TypeKind.interface:
      case TypeKind.record:
      case TypeKind.union:
      case TypeKind.bitfield:
      case TypeKind.enumeration:
        // Resolve the declaration namespace: a qualified name
        // (`Gtk.Align`) points to the namespace named in the prefix;
        // an unqualified name belongs to the property's owner
        // namespace. We don't fall back to `ctx.namespace` here
        // because the emission namespace is often different from the
        // declaring namespace (Adw classes emitting Gtk-inherited
        // properties).
        final declNs = _namespaceOfTypeRef(prop.type!, ownerNs);
        if (declNs == null) return mapping.dartType;
        return ctx.dartTypeName(declNs.name, mapping.dartType);
      case TypeKind.primitive:
      case TypeKind.boolean:
      case TypeKind.string:
      case TypeKind.voidType:
        return mapping.dartType;
      default:
        return null;
    }
  }

  /// Returns the namespace that declares [cls] (the namespace the
  /// class lives in). Used by [_resolvePropertyType] to disambiguate
  /// unqualified `<type>` names on properties the class declares.
  GirNamespace? _namespaceOfClass(GirClass cls) {
    for (final ns in ctx.allNamespaces) {
      for (final c in ns.classes) {
        if (identical(c, cls)) return ns;
      }
    }
    return null;
  }

  /// Walks the namespace tree to find the namespace that declares
  /// [ref]. Unqualified names resolve to [ownerNs] (the namespace
  /// that declared the property), not the emission namespace.
  GirNamespace? _namespaceOfTypeRef(GirTypeRef ref, GirNamespace? ownerNs) {
    if (ref.name == null) return null;
    if (ref.name!.contains('.')) {
      // Already qualified — the first segment names the namespace.
      final nsName = ref.name!.split('.').first;
      return _nsByName(nsName);
    }
    return ownerNs;
  }

  GirNamespace? _nsByName(String name) {
    for (final ns in ctx.allNamespaces) {
      if (ns.name == name) return ns;
    }
    return null;
  }

  /// Looks up a method on [owner] (or its parent chain) by GIR name.
  /// Used to find the typed `get<Name>` / `set<Name>` instance methods
  /// that back each property.
  GirMethod? _findMethodByName(GirClass owner, String girName) {
    var current = owner;
    final seen = <String>{};
    while (seen.add(current.name)) {
      for (final m in current.methods) {
        if (m.name == girName) return m;
      }
      if (current.parent == null) return null;
      final found = ctx.findClass(current.parent!);
      if (found == null) return null;
      current = found.$2;
    }
    return null;
  }

  /// Computes the Dart-level getter name (e.g. `getLabel`) from a GIR
  /// method `get_label`. Falls back to the GIR name when the prefix
  /// is missing.
  String _getterName(GirMethod m) =>
      CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));

  /// Computes the Dart-level setter name (e.g. `setLabel`) from a GIR
  /// method `set_label`. Falls back to the GIR name when the prefix
  /// is missing.
  String _setterName(GirMethod m) =>
      CallableEmitter.safeMemberName(escapeKeyword(toLowerCamel(m.name)));

  /// Returns `true` when [mType] (the typed setter's first parameter
  /// type) is the same Dart type as [propType] (the property's
  /// declared type). Used to filter out properties whose typed
  /// setter accepts a narrower subclass than the property itself
  /// declares — e.g. `set_visible_page(AdwPreferencesPage)` when the
  /// property type is `Gtk.Widget`.
  bool _matchesPropertyType(
    GirTypeRef? mType,
    GirTypeRef? propType,
    GirClass owner,
  ) {
    if (mType == null || propType == null) return true;
    final ownerNs = _namespaceOfClass(owner) ?? ctx.namespace;
    final m = ctx.resolver.resolve(mType, currentNamespace: ownerNs);
    final p = ctx.resolver.resolve(propType, currentNamespace: ownerNs);
    return m.dartType == p.dartType;
  }

  /// Returns `true` if [m] would have been renamed in [owner]'s
  /// emission because its signature differs from an ancestor's
  /// same-named method. Detected by comparing the candidate's
  /// signature key against the ancestor chain's combined map.
  bool _wasRenamed(GirMethod m, GirClass owner) {
    final name = CallableEmitter.safeMemberName(
      escapeKeyword(toLowerCamel(m.name)),
    );
    // Walk the owner chain and collect ancestor signatures for the
    // same Dart name. If any ancestor has a same-named method with
    // a different signature, the leaf's emission would have renamed.
    var current = owner;
    final seen = <String>{};
    while (current.parent != null && seen.add(current.name)) {
      final found = ctx.findClass(current.parent!);
      if (found == null) break;
      current = found.$2;
      for (final am in current.methods) {
        if (am == m) continue; // skip self
        final amName = CallableEmitter.safeMemberName(
          escapeKeyword(toLowerCamel(am.name)),
        );
        if (amName == name) {
          // Same Dart name on ancestor; if the ancestor's signature
          // differs from ours, we were renamed.
          if (_methodKey(am) != _methodKey(m)) return true;
        }
      }
    }
    return false;
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
  ///
  /// When [satisfiedIfDangling] is non-null, entries are removed
  /// whenever a defensive rename fires (the rename means the class
  /// no longer structurally satisfies the interface, so emitting
  /// `implements <Name>` would be a Dart compile error). The caller
  /// uses the resulting set to build the `implements <Name>` clause.
  String _emitInterfaceMirrors(
    GirClass cls,
    String dartName,
    CallableEmitter callables,
    Set<String> memberNames,
    Map<String, String> interfaceSigs,
    Map<String, String> inheritedSigs,
    Set<String>? satisfiedIfDangling,
  ) {
    final b = StringBuffer();
    final seenInterfaces = <String>{};
    for (final implName in cls.implements_) {
      final found = ctx.findInterface(implName);
      if (found == null) {
        ctx.report.skip(
          'method',
          '$dartName.${cls.name}',
          'interface $implName not found',
        );
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
        ctx.report.skip(
          'method',
          '$dartName.${cls.name}',
          'interface $implName is in non-generated package $ifacePkg',
        );
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
        var name = CallableEmitter.safeMemberName(
          escapeKeyword(toLowerCamel(m.name)),
        );
        final mirroredKey = _methodKey(m);
        // Override-incompatible with the parent class's same-named
        // method → rename so we don't shadow it with a different
        // signature (Dart would emit `invalid_override`). Common
        // example: a parent class returns `bool use()` while the
        // interface declares `void use()`.
        final inheritedSig = inheritedSigs[name];
        if (inheritedSig != null && inheritedSig != mirroredKey) {
          final renamed = '$name${cls.name}';
          ctx.report.skip(
            'renamed',
            '$dartName.$name',
            'override-incompatible with ancestor; renamed to $renamed',
          );
          name = renamed;
          // The rename means the class no longer matches the
          // interface's signature — drop it from the implements
          // clause so Dart's structural check doesn't reject the
          // declaration.
          satisfiedIfDangling?.remove(
            ctx.dartTypeName(ifaceNs.name, iface.name),
          );
        }
        // Override-incompatible with the interface's own expected
        // signature → rename so the class doesn't claim to satisfy
        // the interface (purely defensive until Phase 2 promotes
        // interfaces to `abstract`).
        final ifaceSig = interfaceSigs[name];
        if (ifaceSig != null && ifaceSig != mirroredKey) {
          final renamed = '$name${cls.name}';
          ctx.report.skip(
            'renamed',
            '$dartName.$name',
            'override-incompatible with interface; renamed to $renamed',
          );
          name = renamed;
          satisfiedIfDangling?.remove(
            ctx.dartTypeName(ifaceNs.name, iface.name),
          );
        }
        if (CallableEmitter.conflictsWithObjectMember(name) ||
            !memberNames.add(name)) {
          ctx.report.skip('method', '$dartName.$name', 'name collision');
          continue;
        }
        final code = callables.emit(
          m,
          dartName: name,
          ownerName: dartName,
          classMember: true,
          selfArgExpr: 'this.handle',
          // Resolve parameter and return types against the
          // interface's own namespace, not the implementing class's.
          // `GdkPaintable.snapshot(GdkSnapshot, …)` and a Gtk mirror
          // for `GtkIconPaintable` would otherwise re-bind `Snapshot`
          // to the local `GtkSnapshot` class and break the
          // `implements GdkPaintable` structural check.
          relativeTo: ifaceNs,
        );
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
      final name = CallableEmitter.safeMemberName(
        escapeKeyword(toLowerCamel(m.name)),
      );
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
    GirInterface iface,
    GirNamespace ifaceNs,
    String ifacePkg,
  ) {
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
      // Use the canonical C type when the GIR declared both a name and
      // a c:type that disagree — `<type name="Snapshot" c:type=
      // "GdkSnapshot*"/>` and `<type name="Snapshot" c:type=
      // "GtkSnapshot*"/>` resolve to different classes in different
      // namespaces, and the implements-clause plan needs the two
      // signatures to compare unequal so the defensive rename fires.
      final n = t.name ?? t.cType ?? '?';
      final dot = n.lastIndexOf('.');
      final base = dot >= 0 ? n.substring(dot + 1) : n;
      final c = t.cType;
      if (c != null && c.isNotEmpty && c != base) {
        return '$base<$c>';
      }
      return base;
    }

    final params = m.parameters
        .map(
          (p) =>
              '${p.direction.name}:${typeKey(p.type)}${p.nullable ? '?' : ''}',
        )
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
      // Also probe interfaces the class implements — a class that
      // `implements GActionGroup` exposes GActionGroup's `action-added`
      // signal through its own `onActionAdded` helper.
      for (final implName in current.implements_) {
        final ifound = ctx.findInterface(implName);
        if (ifound == null) continue;
        final (iNs, iface) = ifound;
        if (iface.signals.any((s) => s.name == signalName)) {
          return iNs;
        }
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

/// One property's worth of metadata, plus the class that *owns* the
/// backing getter / setter methods. Used by the `props` accessor
/// emission to keep the leaf-class's method names (which always win
/// in Dart's name resolution rules over the parent's, when both
/// exist).
class _PropertyAccess {
  const _PropertyAccess({required this.property, required this.owner});
  final GirProperty property;
  final GirClass owner;
}
