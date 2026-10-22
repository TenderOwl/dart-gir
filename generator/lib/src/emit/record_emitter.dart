/// Emits opaque handle classes for GIR records and unions.
library;

import '../gir/gir.dart';
import '../resolve/naming.dart';
import '../resolve/types.dart';
import 'async_emitter.dart';
import 'callable.dart';
import 'context.dart';
import 'signals_emitter.dart';

/// Records and unions become opaque pointer wrappers with their GIR
/// constructors, methods and static functions attached.
class RecordEmitter {
  RecordEmitter(this.ctx);

  final EmitContext ctx;

  /// Namespace functions to re-emit as static methods on the owning GIR
  /// record / union / interface. Populated by `PackageEmitter.emit()`
  /// once per package and read in `_emit` — see `class_emitter.dart`
  /// "Static class functions" for the detection rule (`moved-to` value
  /// has no dot).
  Map<String, StaticClassFunction> staticClassFunctions = const {};

  String? emitRecord(GirRecord rec) {
    // The type-system records are emitted as real `ffi.Struct`s: the
    // caller builds them, so the layout has to be known — and it comes
    // from the GIR.
    if (TypeResolver.isStructRecord(rec, ctx.namespace.name)) {
      return _emitStruct(rec);
    }
    return _emit(rec, rec.constructors, rec.methods, rec.functions, rec.doc);
  }

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
    getType: i.glibGetType,
  );

  String? _emit(
    GirRegisteredType type,
    List<GirConstructor> constructors,
    List<GirMethod> methods,
    List<GirFunction> functions,
    String? doc, {
    List<GirSignal> signals = const [],
    bool isInterface = false,
    String? getType,
  }) {
    final dartName = ctx.dartTypeName(ctx.namespace.name, type.name);
    if (ctx.isDuplicateType(type)) {
      ctx.report.skip(
        'record',
        dartName,
        'duplicate declaration owned by an earlier namespace',
      );
      return null;
    }
    if (!ctx.claimName(dartName, kind: 'record', label: dartName)) {
      ctx.report.skip('record', dartName, 'name collision');
      return null;
    }
    final callables = CallableEmitter(ctx);
    final memberNames = <String>{
      'handle',
      'owned',
      'fromPointer',
      dartName,
      'GType',
      '_gType',
    };
    var unnamedCtorUsed = false;
    final b = StringBuffer();
    for (final line in ctx.docLines(doc)) {
      b.writeln(line);
    }
    // The release kind of the wrapper:
    //
    // * An interface is a GObject in C, so it is released with
    //   `g_object_unref` — exactly like a class.
    // * A boxed record or union is released with its own destructor,
    //   which the GIR names (`unref`, `free`, `destroy`, …) or declares
    //   as the record's `free-function`.
    // * A type the GIR gives no destructor keeps the borrowed-reference
    //   behaviour: the reference is never released.
    final destructor = isInterface
        ? null
        : TypeResolver.destructorOf(type, ctx.namespace.name);
    final finalizerMember = isInterface ? null : boxedFinalizerName(type.name);
    // The `NativeFinalizer` that releases the reference, and the
    // expressions that release a surplus reference the cache handed back
    // and adopt a reference the cached wrapper does not own yet.
    final String? finalizerExpr;
    final String? releaseExpr;
    final String? adoptExpr;
    if (isInterface) {
      finalizerExpr = 'gobjectFinalizer';
      releaseExpr = 'gObjectUnref(handle)';
      adoptExpr = '''
        if (gObjectIsFloating(handle)) {
          gObjectRefSink(handle);
        }
        gobjectFinalizer.attach(cached, handle, detach: cached);''';
    } else if (destructor != null && finalizerMember != null) {
      finalizerExpr = finalizerMember;
      releaseExpr = '_release${toUpperCamel(type.name)}(handle)';
      adoptExpr = '$finalizerMember.attach(cached, handle, detach: cached);';
    } else {
      finalizerExpr = null;
      releaseExpr = null;
      adoptExpr = null;
    }
    if (isInterface && packageNameFor(ctx.namespace) != 'gobject') {
      // `gobjectFinalizer` and `gObjectUnref` live in `package:gobject`.
      ctx.imports.add('gobject');
    }
    // Interfaces must NOT be `final class`: the implements-clause plan
    // (T2) requires other classes to be able to `implements <Name>`.
    // `final class` forbids implementation outside the library, and the
    // implementing class lives in another generated file. Records and
    // unions stay `final class` because they're concrete struct wrappers
    // that aren't meant to be subclassed by user code.
    b.writeln(
      isInterface
          ? 'class $dartName implements ffi.Finalizable {'
          : (finalizerExpr == null
                ? 'final class $dartName {'
                : 'final class $dartName implements ffi.Finalizable {'),
    );
    // The `{bool owned}` named parameter is always accepted (even
    // when the class doesn't actually attach a finalizer, because
    // it's not a `GObject` subclass) so existing callers that don't
    // pass `owned` keep working through the default value. Note the
    // cast method's *factory* parameter below doesn't carry `owned` —
    // the borrowed-reference world the cast method operates in never
    // needs to transfer ownership, and dropping `owned` from the
    // factory type lets user subclasses write the shortest possible
    // forwarding constructor (`fromPointer(handle)`).
    // The wrapper cache lives in `package:gir_ffi`.
    ctx.usesGirFfi = true;
    b.writeln(
      _recordFromPointerFactory(
        dartName,
        release: releaseExpr,
        adopt: adoptExpr,
      ),
    );
    b.writeln('$dartName.rawFromPointer(this.handle, {this.owned = false}) {');
    b.writeln('registerDartObject(this, handle.address);');
    if (finalizerExpr != null) {
      b.writeln('if (owned) {');
      if (isInterface) {
        // A freshly created GObject starts out floating: nobody owns it
        // until a parent takes it. The wrapper owns the object, so the
        // reference is sunk — otherwise the parent that takes it would
        // own the very reference this wrapper's finalizer releases.
        b.writeln('  if (gObjectIsFloating(handle)) {');
        b.writeln('    gObjectRefSink(handle);');
        b.writeln('  }');
      }
      b.writeln('  $finalizerExpr.attach(this, handle, detach: this);');
      b.writeln('}');
    }
    b.writeln('}');
    b.writeln('final ffi.Pointer<ffi.Void> handle;');
    // `owned` says whether *this* wrapper still holds the reference the
    // GIR handed over. It is mutable: a callee that takes the reference
    // over (`transfer-ownership="full"`) clears it.
    b.writeln('bool owned;');
    if (destructor != null && finalizerMember != null) {
      final release = '_release${toUpperCamel(type.name)}';
      b.writeln();
      b.writeln('/// Releases an owned `$dartName` with `$destructor`.');
      b.writeln('///');
      b.writeln('/// The finalizer runs when the wrapper is collected, so a');
      b.writeln('/// reference the GIR hands over is released exactly once.');
      b.writeln('static final $finalizerMember = ffi.NativeFinalizer(');
      b.writeln(
        '  ${ctx.pkgIdent}Lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(',
      );
      b.writeln("    '$destructor',");
      b.writeln('  ),');
      b.writeln(');');
      b.writeln();
      b.writeln('static final $release =');
      b.writeln(
        '    ${ctx.pkgIdent}Lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(',
      );
      b.writeln("      '$destructor',");
      b.writeln('    ).asFunction<void Function(ffi.Pointer<ffi.Void>)>();');
      memberNames.add(finalizerMember);
      memberNames.add(release);
    }
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

    // The interface's native type. `glib:get-type` names the `get_type`
    // function GLib exports for every registered type.
    final gTypeAccessor = ctx.gTypeAccessor(getType, what: 'interface');
    if (gTypeAccessor != null) {
      b.writeln();
      b.writeln(gTypeAccessor);
    }

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
      final code = callables.emit(
        c,
        dartName: name,
        ownerName: dartName,
        classMember: true,
        factoryClass: dartName,
        // A boxed constructor hands the caller a reference the GIR marks
        // `transfer-ownership="full"` — the wrapper owns it and releases
        // it when it is collected.
        factoryOwned: c.returnTransfer == GirTransferOwnership.full,
      );
      if (code != null) b.writeln(_indent(code));
    }
    for (final m in methods) {
      final name = CallableEmitter.safeMemberName(
        escapeKeyword(toLowerCamel(m.name)),
      );
      // Moved-to methods are skipped at emission time (the
      // canonical landing site is a namespace function or another
      // class method, depending on whether the value contains a
      // dot). Don't reserve the Dart member name — the namespace
      // function brought to this class as a static method may
      // normalise to the same identifier (e.g. `_register` →
      // `register` colliding with `resources_register`'s
      // normalised `resourcesRegister`).
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
        bodyPrelude: _destructorPrelude(m, destructor, finalizerMember),
      );
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
    // record/union/interface as `static` methods because a sibling
    // `<method>` carries `moved-to="<bare>"`). The pre-scan in
    // `PackageEmitter.emit()` built the map; we filter by the owning
    // type's Dart name. The corresponding namespace function is suppressed
    // by `FunctionEmitter.emitFunction`.
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

  /// Emits a record as an `ffi.Struct`.
  ///
  /// The field list comes from the GIR, so the Dart layout follows the
  /// C one: the same field order, the same widths, and the C ABI's
  /// alignment rules in between.
  String _emitStruct(GirRecord rec) {
    final dartName = ctx.dartTypeName(ctx.namespace.name, rec.name);
    final b = StringBuffer();
    for (final line in ctx.docLines(rec.doc)) {
      b.writeln(line);
    }
    b.writeln('final class $dartName extends ffi.Struct {');
    for (final field in rec.fields) {
      final type = field.type;
      if (type == null) continue;
      final mapping = ctx.resolve(type);
      final native = mapping.kind == TypeKind.callback
          ? 'ffi.Pointer<ffi.Void>'
          : mapping.nativeType;
      final (annotation, dartType) = _structFieldTypes(native);
      if (annotation.isNotEmpty) {
        b.writeln('  $annotation');
      }
      b.writeln('  external $dartType ${field.name};');
    }
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

  /// The lines a boxed type's destructor method starts with.
  ///
  /// The wrapper's finalizer releases the reference when the wrapper is
  /// collected. An *explicit* release takes over from the collector: the
  /// finalizer is detached, so the reference is released once — by the
  /// caller, not by the garbage collector.
  static List<String> _destructorPrelude(
    GirMethod m,
    String? destructor,
    String? finalizerMember,
  ) {
    if (destructor == null || finalizerMember == null) return const [];
    if (m.cIdentifier != destructor) return const [];
    return [
      'if (owned) {',
      '  // The caller releases the reference — the collector must not.',
      '  $finalizerMember.detach(this);',
      '  owned = false;',
      '}',
    ];
  }

  static String _indent(String code) =>
      code.split('\n').map((l) => l.isEmpty ? l : '  $l').join('\n');
}

/// The `fromPointer` factory every record and interface wrapper gets.
///
/// The factory consults the wrapper cache first: the same native pointer
/// always yields the same Dart object. The generative work moves to
/// `rawFromPointer`, which the constructor chain calls — a generative
/// constructor may not redirect to a factory.
///
/// On a cache hit the reference the C call handed over has to be balanced:
///
/// * The cached wrapper owns a reference of its own — the new one is a
///   surplus and goes back.
/// * The cached wrapper owns nothing — it *adopts* the new reference,
///   because the reference was moved to it rather than duplicated (that
///   is what `g_propagate_error` does with its `GError`).
///
/// [release] releases a surplus reference, [adopt] takes over a reference
/// the cached wrapper does not own yet. Both are null when the type has no
/// destructor the bindings can call.
String _recordFromPointerFactory(
  String dartName, {
  String? release,
  String? adopt,
}) {
  final balance = release == null && adopt == null
      ? ''
      : '''
    if (owned) {
      if (cached.owned) {
        // The cached wrapper owns a reference of its own: the new one is
        // a surplus and goes back.
        $release;
      } else {
        // The cached wrapper owns nothing: it adopts the reference.
        $adopt;
        cached.owned = true;
      }
    }''';
  return '''
  /// Wraps the native object at [handle].
  ///
  /// The same native pointer always yields the same Dart object.
  factory $dartName.fromPointer(
    ffi.Pointer<ffi.Void> handle, {
    bool owned = false,
  }) {
    final cached = cachedObject<$dartName>(handle.address);
    if (cached != null) {$balance
      return cached;
    }
    return $dartName.rawFromPointer(handle, owned: owned);
  }''';
}

/// The Dart FFI declaration of a struct field.
///
/// The native type comes from the resolver; a pointer (or a callback,
/// which is a pointer too) needs no annotation.
(String, String) _structFieldTypes(String nativeType) {
  switch (nativeType) {
    case 'ffi.Int8':
      return ('@ffi.Int8()', 'int');
    case 'ffi.Uint8':
      return ('@ffi.Uint8()', 'int');
    case 'ffi.Int16':
      return ('@ffi.Int16()', 'int');
    case 'ffi.Uint16':
      return ('@ffi.Uint16()', 'int');
    case 'ffi.Int32':
      return ('@ffi.Int32()', 'int');
    case 'ffi.Uint32':
      return ('@ffi.Uint32()', 'int');
    case 'ffi.Int64':
      return ('@ffi.Int64()', 'int');
    case 'ffi.Uint64':
      return ('@ffi.Uint64()', 'int');
    case 'ffi.Size':
      return ('@ffi.Size()', 'int');
    case 'ffi.Float':
      return ('@ffi.Float()', 'double');
    case 'ffi.Double':
      return ('@ffi.Double()', 'double');
    default:
      return ('', 'ffi.Pointer<ffi.Void>');
  }
}
