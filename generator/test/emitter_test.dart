import 'dart:io';

import 'package:gir_generator/src/emit/async_emitter.dart';
import 'package:gir_generator/src/emit/callback_emitter.dart';
import 'package:gir_generator/src/emit/emit.dart';
import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/types.dart' show packageNameFor;
import 'package:test/test.dart';

GirNamespace _glibNs({
  List<GirEnum>? enums,
  List<GirFunction>? functions,
  List<GirClass>? classes,
  List<GirConstant>? constants,
  List<GirCallback>? callbacks,
}) => GirNamespace(
  name: 'GLib',
  version: '2.0',
  sharedLibrary: 'libglib-2.0.so.0',
  cIdentifierPrefixes: const ['G'],
  cSymbolPrefixes: const ['glib', 'g'],
  enumerations: enums,
  functions: functions,
  classes: classes,
  constants: constants,
  callbacks: callbacks,
);

EmitContext _ctx(GirNamespace ns, List<GirNamespace> all, GenerationReport r) =>
    EmitContext(
      namespace: ns,
      allNamespaces: all,
      report: r,
      emittedPackages: {packageNameFor(ns)},
    );

void main() {
  group('EnumEmitter', () {
    test('emits enum with values and fromValue', () {
      final report = GenerationReport();
      final ns = _glibNs();
      final ctx = _ctx(ns, [ns], report);
      final e = GirEnum(
        name: 'FileTest',
        cType: 'GFileTest',
        members: [
          const GirEnumMember(
            name: 'is_regular',
            value: 1,
            cIdentifier: 'G_FILE_TEST_IS_REGULAR',
          ),
          const GirEnumMember(
            name: 'is_dir',
            value: 2,
            cIdentifier: 'G_FILE_TEST_IS_DIR',
          ),
        ],
      );
      final code = EnumEmitter(ctx).emit(e)!;
      expect(code, contains('enum GFileTest {'));
      expect(code, contains('isRegular(1),'));
      expect(code, contains('isDir(2),'));
      expect(code, contains('const GFileTest(this.value);'));
      expect(code, contains('static GFileTest fromValue(int value)'));
      expect(code, contains('1 => isRegular,'));
      expect(code, contains('ArgumentError'));
      expect(report.totalSkipped, 0);
    });

    test('emits bitfield as flags class with operators', () {
      final report = GenerationReport();
      final ns = _glibNs();
      final ctx = _ctx(ns, [ns], report);
      final bf = GirBitfield(
        name: 'IOFlags',
        cType: 'GIOFlags',
        members: [
          const GirEnumMember(
            name: 'append',
            value: 1,
            cIdentifier: 'G_IO_FLAGS_APPEND',
          ),
        ],
      );
      final code = EnumEmitter(ctx).emitBitfield(bf)!;
      expect(code, contains('final class GIOFlags {'));
      expect(code, contains('static const GIOFlags append = GIOFlags(1);'));
      expect(code, contains('GIOFlags operator |(GIOFlags other)'));
    });
  });

  group('CallableEmitter', () {
    test('emits function with string param via withNativeString', () {
      final report = GenerationReport();
      final fn = GirFunction(
        name: 'utf8_strlen',
        cIdentifier: 'g_utf8_strlen',
        returnType: const GirTypeRef(name: 'glong', cType: 'glong'),
        parameters: [
          const GirParameter(
            name: 'str',
            type: GirTypeRef(name: 'utf8', cType: 'gchar*'),
          ),
          const GirParameter(
            name: 'max',
            type: GirTypeRef(name: 'gssize', cType: 'gssize'),
          ),
        ],
      );
      final ns = _glibNs(functions: [fn]);
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitFunction(fn)!;
      expect(code, contains('_gUtf8Strlen'));
      expect(code, contains("glibLookup<"));
      expect(code, contains("'g_utf8_strlen'"));
      expect(code, contains('int utf8Strlen(String str, int max)'));
      expect(code, contains('withNativeString(str, (nativeStr)'));
      expect(code, contains('_gUtf8Strlen(nativeStr.cast<Utf8>(), max)'));
      expect(ctx.usesGirFfi, isTrue);
    });

    test('skips varargs function and records it in the report', () {
      final report = GenerationReport();
      final fn = GirFunction(
        name: 'printf',
        cIdentifier: 'g_printf',
        parameters: [
          const GirParameter(
            name: 'format',
            type: GirTypeRef(name: 'utf8', cType: 'gchar*'),
          ),
          const GirParameter(name: '...', isVarargs: true),
        ],
      );
      final ns = _glibNs(functions: [fn]);
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitFunction(fn);
      expect(code, isNull);
      expect(report.totalSkipped, 1);
      expect(report.entries.single.reason, 'varargs');
      expect(report.entries.single.name, contains('printf'));
    });

    test(
      'emits function with argv-style string list via withNativeStringList',
      () {
        final report = GenerationReport();
        final fn = GirFunction(
          name: 'application_run',
          cIdentifier: 'g_application_run',
          returnType: const GirTypeRef(name: 'gint', cType: 'int'),
          parameters: [
            const GirParameter(
              name: 'application',
              type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
            ),
            const GirParameter(
              name: 'argc',
              type: GirTypeRef(name: 'gint', cType: 'int'),
            ),
            const GirParameter(
              name: 'argv',
              type: GirTypeRef(
                cType: 'char**',
                array: GirArrayInfo(elementType: GirTypeRef(name: 'filename')),
              ),
              nullable: true,
            ),
          ],
        );
        final ns = _glibNs(functions: [fn]);
        final ctx = _ctx(ns, [ns], report);
        final code = FunctionEmitter(ctx).emitFunction(fn)!;
        expect(code, contains('withNativeStringList(argv, (nativeArgv)'));
        expect(code, contains('List<String?>? argv'));
        expect(code, contains('ffi.Pointer<ffi.Pointer<Utf8>>'));
        expect(report.totalSkipped, 0);
        expect(ctx.usesGirFfi, isTrue);
      },
    );

    test('skips function whose argv-style array has bound length', () {
      final report = GenerationReport();
      final fn = GirFunction(
        name: 'weird_run',
        cIdentifier: 'g_weird_run',
        parameters: [
          const GirParameter(
            name: 'argv',
            type: GirTypeRef(
              cType: 'gchar**',
              array: GirArrayInfo(
                lengthParameterIndex: 1,
                elementType: GirTypeRef(name: 'utf8'),
              ),
            ),
          ),
          const GirParameter(
            name: 'argc',
            type: GirTypeRef(name: 'gint'),
          ),
        ],
      );
      final ns = _glibNs(functions: [fn]);
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitFunction(fn);
      expect(code, isNull);
      expect(report.entries.single.reason, contains('array'));
    });

    test(
      'skips introspectable="0" function naming the canonical sibling',
      () {
        final report = GenerationReport();
        final fn = GirFunction(
          name: 'idle_add',
          cIdentifier: 'g_idle_add',
          introspectable: false,
          shadowedBy: 'idle_add_full',
          returnType: const GirTypeRef(name: 'guint', cType: 'guint'),
        );
        final ns = _glibNs(functions: [fn]);
        final ctx = _ctx(ns, [ns], report);
        final code = FunctionEmitter(ctx).emitFunction(fn);
        expect(code, isNull);
        expect(report.entries.single.category, 'callable');
        expect(
          report.entries.single.reason,
          'introspectable=0 (C macro; use idle_add_full)',
        );
      },
    );

    test(
      'skips introspectable="0" function without a sibling with bare reason',
      () {
        final report = GenerationReport();
        final fn = GirFunction(
          name: 'some_macro',
          cIdentifier: 'g_some_macro',
          introspectable: false,
          returnType: const GirTypeRef(name: 'none'),
        );
        final ns = _glibNs(functions: [fn]);
        final ctx = _ctx(ns, [ns], report);
        final code = FunctionEmitter(ctx).emitFunction(fn);
        expect(code, isNull);
        expect(report.entries.single.reason, 'introspectable=0');
      },
    );

    test('emits nullable callback parameter with conditional NativeCallable',
        () {
      final report = GenerationReport();
      // Callbacks declared in the same namespace so the bridge resolves.
      final sourceFunc = GirCallback(
        name: 'SourceFunc',
        cType: 'GSourceFunc',
        returnType: const GirTypeRef(name: 'gboolean'),
        parameters: const [
          GirParameter(
            name: 'data',
            type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
          ),
        ],
      );
      final destroyNotify = GirCallback(
        name: 'DestroyNotify',
        cType: 'GDestroyNotify',
        returnType: const GirTypeRef(name: 'none'),
        parameters: const [
          GirParameter(
            name: 'data',
            type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
          ),
        ],
      );
      final fn = GirFunction(
        name: 'idle_add_full',
        cIdentifier: 'g_idle_add_full',
        returnType: const GirTypeRef(name: 'guint', cType: 'guint'),
        parameters: const [
          GirParameter(
            name: 'priority',
            type: GirTypeRef(name: 'gint', cType: 'gint'),
          ),
          GirParameter(
            name: 'function_',
            type: GirTypeRef(name: 'SourceFunc', cType: 'GSourceFunc'),
          ),
          GirParameter(
            name: 'data',
            type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
            nullable: true,
          ),
          GirParameter(
            name: 'notify',
            type: GirTypeRef(name: 'DestroyNotify', cType: 'GDestroyNotify'),
            nullable: true,
          ),
        ],
      );
      final ns = _glibNs(
        functions: [fn],
        callbacks: [sourceFunc, destroyNotify],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitFunction(fn)!;
      expect(report.totalSkipped, 0);
      // Wrapper parameter type is nullable for the callback.
      expect(code, contains('void Function(ffi.Pointer<ffi.Void>)? notify'));
      // Trailing optional positional parameter for the nullable callback.
      expect(code, contains('[void Function(ffi.Pointer<ffi.Void>)? notify'));
      // Native side gets a null pointer when the user passes nothing —
      // match on the actual variable name (`_nc4`) used for the 4th param.
      expect(code, contains('_nc4?.nativeFunction ?? ffi.nullptr'));
      // Lifecycle: NativeCallable only allocated when non-null; close is
      // also conditional so we don't dereference a null instance.
      expect(code, contains('notify == null ? null'));
      expect(code, contains('_nc4?.close();'));
    });

    test(
      'record OUT param (caller-allocates) uses HeapAnchor, omits manual free',
      () {
        final report = GenerationReport();
        // A function returning void with a single record-typed OUT param
        // (caller-allocates="1") — the canonical pattern exercised by
        // GtkTextBuffer.getStartIter.
        final fn = GirFunction(
          name: 'get_start_iter',
          cIdentifier: 'gtk_text_buffer_get_start_iter',
          returnType: const GirTypeRef(name: 'none'),
          parameters: const [
            GirParameter(
              name: 'iter',
              direction: GirParameterDirection.out,
              callerAllocates: true,
              type: GirTypeRef(name: 'TextIter', cType: 'GtkTextIter*'),
            ),
          ],
        );
        // The OUT param's pointee must be registered in the resolver,
        // otherwise the bridge will reject it. Build a tiny namespace
        // that declares `TextIter` as a record.
        final ns = GirNamespace(
          name: 'Gtk',
          version: '4.0',
          sharedLibrary: 'libgtk-4.so.1',
          cIdentifierPrefixes: const ['Gtk', 'gtk'],
          cSymbolPrefixes: const ['gtk'],
          records: [GirRecord(name: 'TextIter', cType: 'GtkTextIter')],
          functions: [fn],
        );
        final ctx = _ctx(ns, [ns], report);
        final code = FunctionEmitter(ctx).emitFunction(fn)!;
        expect(code, isNotNull);
        expect(report.totalSkipped, 0);

        // The wrapper allocates a finalizer-backed buffer (NOT
        // malloc<T>()) and uses `gir_ffi`'s `HeapAnchor` helper.
        expect(code, contains('HeapAnchor.allocate('));
        expect(code, contains('final _out0Anchor = HeapAnchor.allocate(256);'));
        expect(code, contains('final _out0 = _out0Anchor.buffer;'));

        // The finally block must NOT free the buffer — the
        // NativeFinalizer attached by HeapAnchor does it on GC.
        // (A manually freed buffer would invalidate the returned
        // wrapper's handle and trip the GTK-side null deref that
        // motivated the fix.)
        expect(
          code,
          isNot(contains('malloc.free(_out0);')),
        );

        // The C call writes into the buffer via a `cast<ffi.Void>()`.
        expect(code, contains('_gtkTextBufferGetStartIter('));
        expect(code, contains('_out0.cast<ffi.Void>()'));

        // The wrapper extracts via `T.fromPointer(_buffer.cast<ffi.Void>())`.
        expect(code, contains('GtkTextIter.fromPointer(_out0.cast<ffi.Void>())'));

        // The HeapAnchor helper comes from `package:gir_ffi/gir_ffi.dart`
        // — assert the import was registered so the library emitter
        // wires it in.
        expect(ctx.usesGirFfi, isTrue);
      },
    );

    test(
      'caller-allocated primitive OUT still uses malloc/free (size known)',
      () {
        // Primitive OUT params know their size at compile time, so we
        // keep the malloc<T>() path. This guards against a regression
        // where every OUT param would route through HeapAnchor.
        final report = GenerationReport();
        final fn = GirFunction(
          name: 'get_int',
          cIdentifier: 'g_get_int',
          returnType: const GirTypeRef(name: 'none'),
          parameters: const [
            GirParameter(
              name: 'value',
              direction: GirParameterDirection.out,
              callerAllocates: true,
              type: GirTypeRef(name: 'gint', cType: 'gint*'),
            ),
          ],
        );
        final ns = _glibNs(functions: [fn]);
        final ctx = _ctx(ns, [ns], report);
        final code = FunctionEmitter(ctx).emitFunction(fn)!;
        expect(code, isNotNull);
        expect(report.totalSkipped, 0);
        // Primitive path: `malloc<ffi.Int32>()` + `malloc.free` in finally.
        expect(code, contains('malloc<ffi.Int32>'));
        expect(code, contains('malloc.free(_out0);'));
        // HeapAnchor is NOT used for primitives — its lifetime model
        // assumes the buffer is captured by a returned wrapper, which
        // a primitive isn't.
        expect(code, isNot(contains('HeapAnchor')));
      },
    );
  });

  group('FunctionEmitter.emitConstant', () {
    GirConstant mkConst(String name, String value, GirTypeRef type) =>
        GirConstant(name: name, value: value, type: type);

    test('emits utf8 string constant as Dart const String', () {
      final report = GenerationReport();
      final ns = _glibNs(
        constants: [
          mkConst(
            'DIR_SEPARATOR_S',
            '/',
            const GirTypeRef(name: 'utf8', cType: 'gchar*'),
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single)!;
      expect(code, contains("const dirSeparatorS = '/'"));
      expect(report.totalSkipped, 0);
    });

    test('escapes backslashes in string constants', () {
      final report = GenerationReport();
      final ns = _glibNs(
        constants: [
          mkConst(
            'PROBE',
            r'C:\Users\foo',
            const GirTypeRef(name: 'utf8', cType: 'gchar*'),
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single)!;
      // A literal `\` in GIR becomes `\\` in Dart source so the value
      // round-trips to the same character.
      expect(code, contains(r"const probe = 'C:\\Users\\foo';"));
    });

    test('skips non-primitive, non-string constant types', () {
      final report = GenerationReport();
      // `time_t` resolves to unsupported — should be skipped with reason.
      final ns = _glibNs(
        constants: [
          mkConst(
            'WHEN',
            '1234',
            const GirTypeRef(name: 'time_t', cType: 'time_t'),
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single);
      expect(code, isNull);
      expect(report.entries.single.reason, 'non-primitive type');
    });

    test('skips integer constants that overflow Dart int', () {
      final report = GenerationReport();
      final ns = _glibNs(
        constants: [
          mkConst(
            'MAXUINT64',
            '18446744073709551615',
            const GirTypeRef(name: 'guint64', cType: 'guint64'),
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single);
      expect(code, isNull);
      expect(report.entries.single.reason, contains('unparseable int'));
    });
  });

  group('CallbackEmitter', () {
    GirCallback cb({
      required String name,
      String? cType,
      GirTypeRef? returnType,
      List<GirParameter> parameters = const [],
    }) => GirCallback(
      name: name,
      cType: cType,
      returnType: returnType ?? const GirTypeRef(name: 'none'),
      parameters: parameters,
    );

    test('emits typedef for a callback with primitive parameters and return', () {
      final report = GenerationReport();
      final ns = _glibNs(
        callbacks: [
          cb(
            name: 'CompareDataFunc',
            cType: 'GCompareDataFunc',
            returnType: const GirTypeRef(name: 'gint'),
            parameters: const [
              GirParameter(
                name: 'a',
                type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
              ),
              GirParameter(
                name: 'b',
                type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
              ),
            ],
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single)!;
      // User-facing typedef uses Dart convenience types (`int`) for primitives
      // and `ffi.Pointer<ffi.Void>` for opaque pointers.
      expect(code, contains('typedef GCompareDataFunc'));
      expect(code, contains('int Function('));
      expect(code, contains('ffi.Pointer<ffi.Void>'));
      expect(code, isNot(contains('ffi.Int32'))); // no FFI primitives leak out
      expect(report.totalSkipped, 0);
    });

    test('emits typedef with Pointer<Utf8> for utf8 parameters', () {
      final report = GenerationReport();
      final ns = _glibNs(
        callbacks: [
          cb(
            name: 'LogFunc',
            cType: 'GLogFunc',
            returnType: const GirTypeRef(name: 'none'),
            parameters: const [
              GirParameter(
                name: 'domain',
                type: GirTypeRef(name: 'utf8', cType: 'gchar*'),
              ),
              GirParameter(
                name: 'level',
                type: GirTypeRef(name: 'gint'),
              ),
              GirParameter(
                name: 'message',
                type: GirTypeRef(name: 'utf8', cType: 'gchar*'),
              ),
              GirParameter(
                name: 'user_data',
                type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
              ),
            ],
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single)!;
      expect(code, contains('typedef GLogFunc'));
      expect(code, contains('ffi.Pointer<Utf8>'));
      expect(report.totalSkipped, 0);
    });

    test(
      'renders boolean return as `int` (Dart FFI does not unify bool ↔ Int32)',
      () {
        final report = GenerationReport();
        final ns = _glibNs(
          callbacks: [
            cb(
              name: 'HRFunc',
              cType: 'GHRFunc',
              returnType: const GirTypeRef(name: 'gboolean'),
              parameters: const [
                GirParameter(
                  name: 'key',
                  type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
                ),
              ],
            ),
          ],
        );
        final ctx = _ctx(ns, [ns], report);
        final code = CallbackEmitter(ctx).emit(ns.callbacks.single)!;
        // `bool` is exposed as `int` per the documented convention (0 = false,
        // non-zero = true). The user-facing typedef must not contain `bool`.
        expect(code, contains('typedef GHRFunc'));
        expect(code, contains('int Function('));
        expect(code, isNot(contains('bool')));
      },
    );

    test('skips when an unsupported parameter type is referenced', () {
      final report = GenerationReport();
      final ns = _glibNs(
        callbacks: [
          cb(
            name: 'WithArray',
            returnType: const GirTypeRef(name: 'none'),
            parameters: const [
              GirParameter(
                name: 'data',
                // `array types are handled in a later phase` — must skip.
                type: GirTypeRef(
                  name: 'gint',
                  array: GirArrayInfo(elementType: GirTypeRef(name: 'gint')),
                ),
              ),
            ],
          ),
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single);
      expect(code, isNull);
      expect(report.entries.single.category, 'callback');
      expect(report.entries.single.reason, contains('array'));
    });

    test('skips a callback declared in a non-emitted package', () {
      final report = GenerationReport();
      final ns = _glibNs(
        callbacks: [
          cb(
            name: 'ExternalCb',
            returnType: const GirTypeRef(name: 'none'),
            parameters: const [],
          ),
        ],
      );
      // Mark the glib package as NOT in the emitted set.
      final ctx = EmitContext(
        namespace: ns,
        allNamespaces: [ns],
        report: report,
        emittedPackages: const <String>{},
      );
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single);
      expect(code, isNull);
      expect(report.entries.single.category, 'callback');
      expect(report.entries.single.reason, contains('non-generated package'));
    });
  });

  group('ClassEmitter', () {
    test('emits class with parent extends and finalizer base', () {
      final report = GenerationReport();
      final gobject = GirNamespace(
        name: 'GObject',
        version: '2.0',
        sharedLibrary: 'libgobject-2.0.so.0',
        cIdentifierPrefixes: const ['G'],
        cSymbolPrefixes: const ['gobject', 'g'],
        classes: [
          GirClass(name: 'Object', cType: 'GObject'),
          GirClass(
            name: 'Binding',
            cType: 'GBinding',
            parent: 'Object',
            constructors: [
              GirConstructor(
                name: 'new',
                cIdentifier: 'g_binding_group_source', // placeholder
                returnType: const GirTypeRef(name: 'Binding'),
                parameters: const [],
              ),
            ],
            methods: [
              GirMethod(
                name: 'dup_source',
                cIdentifier: 'g_binding_dup_source',
                returnType: const GirTypeRef(name: 'utf8', cType: 'gchar*'),
              ),
            ],
          ),
        ],
      );
      final ctx = _ctx(gobject, [gobject], report);
      final emitter = ClassEmitter(ctx, emittedPackages: {'gobject'});

      final objectCode = emitter.emitClass(gobject.classes[0])!;
      expect(
        objectCode,
        contains('class GObject implements ffi.Finalizable {'),
      );
      expect(
        objectCode,
        contains('GObject.fromPointer(this.handle, {this.owned = false})'),
      );
      expect(objectCode, contains('_attachFinalizer'));
      expect(ctx.isGObjectRooted(gobject.classes[0]), isTrue);

      final bindingCode = emitter.emitClass(gobject.classes[1])!;
      expect(bindingCode, contains('class GBinding extends GObject {'));
      expect(
        bindingCode,
        contains('GBinding.fromPointer(super.handle, {super.owned})'),
      );
      expect(bindingCode, contains('factory GBinding('));
      expect(bindingCode, contains('GBinding.fromPointer('));
      expect(bindingCode, contains('String dupSource()'));
    });
  });

  group('ClassEmitter implements mirror', () {
    // Build a namespace with one parent class (GObject.Object), one
    // interface (Gtk.Actionable) and one concrete class (Gtk.Button)
    // that implements the interface. The interface mirrors its methods
    // onto the concrete class.
    GirNamespace nsWith({
      required List<GirInterface> interfaces,
      required List<GirClass> classes,
    }) =>
        GirNamespace(
          name: 'Gtk',
          version: '4.0',
          sharedLibrary: 'libgtk-4.so.1',
          cIdentifierPrefixes: const ['Gtk', 'gtk'],
          cSymbolPrefixes: const ['gtk'],
          classes: classes,
          interfaces: interfaces,
        );

    test('class implementing one interface gets interface methods mirrored', () {
      final report = GenerationReport();
      final iface = GirInterface(
        name: 'Actionable',
        cType: 'GtkActionable',
        methods: [
          GirMethod(
            name: 'get_action_name',
            cIdentifier: 'gtk_actionable_get_action_name',
            returnType: GirTypeRef(name: 'utf8', cType: 'const gchar*'),
          ),
          GirMethod(
            name: 'set_action_name',
            cIdentifier: 'gtk_actionable_set_action_name',
            parameters: [
              GirParameter(
                name: 'action_name',
                nullable: true,
                type: GirTypeRef(name: 'utf8', cType: 'const gchar*'),
              ),
            ],
          ),
        ],
      );
      final button = GirClass(
        name: 'Button',
        cType: 'GtkButton',
        parent: 'Widget',
        implements_: const ['Actionable'],
      );
      final ns = nsWith(
        interfaces: [iface],
        classes: [
          GirClass(name: 'Object', cType: 'GObject'),
          GirClass(name: 'Widget', cType: 'GtkWidget', parent: 'Object'),
          button,
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code =
          ClassEmitter(ctx, emittedPackages: const {'gtk4'}).emitClass(button)!;
      expect(code, isNotNull);
      expect(report.totalSkipped, 0);
      // Both interface methods are mirrored onto the class.
      expect(code, contains('String getActionName()'));
      expect(code, contains('void setActionName([String? actionName])'));
      // Native bindings for the interface methods are present.
      expect(code, contains('_gtkActionableGetActionName'));
      expect(code, contains('_gtkActionableSetActionName'));
      // The wrapper threads `this.handle` as the first native argument.
      expect(code, contains('_gtkActionableGetActionName(this.handle'));
    });

    test('class implementing two interfaces gets methods from both', () {
      final report = GenerationReport();
      final actionable = GirInterface(
        name: 'Actionable',
        cType: 'GtkActionable',
        methods: [
          GirMethod(
            name: 'get_action_name',
            cIdentifier: 'gtk_actionable_get_action_name',
            returnType: GirTypeRef(name: 'utf8'),
          ),
        ],
      );
      final buildable = GirInterface(
        name: 'Buildable',
        cType: 'GtkBuildable',
        methods: [
          GirMethod(
            name: 'get_buildable_id',
            cIdentifier: 'gtk_buildable_get_buildable_id',
            returnType: GirTypeRef(name: 'utf8'),
          ),
        ],
      );
      final button = GirClass(
        name: 'Button',
        cType: 'GtkButton',
        parent: 'Widget',
        implements_: const ['Actionable', 'Buildable'],
      );
      final ns = nsWith(
        interfaces: [actionable, buildable],
        classes: [
          GirClass(name: 'Object', cType: 'GObject'),
          GirClass(name: 'Widget', cType: 'GtkWidget', parent: 'Object'),
          button,
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code =
          ClassEmitter(ctx, emittedPackages: const {'gtk4'}).emitClass(button)!;
      expect(code, contains('String getActionName()'));
      expect(code, contains('String getBuildableId()'));
    });

    test(
      'override-incompatible interface method with parent ancestor '
      'is renamed',
      () {
        final report = GenerationReport();
        // Parent class has `activate(GdkEvent*) -> bool`; interface has
        // `activate() -> void`. When mirrored onto the child, the
        // child's own `activate(GdkEvent*) -> bool` shadows the parent
        // — the mirror must rename to `activateWidget` to avoid
        // `invalid_override`.
        final actionable = GirInterface(
          name: 'Actionable',
          cType: 'IActionable',
          methods: [
            GirMethod(
              name: 'activate',
              cIdentifier: 'i_actionable_activate',
              returnType: GirTypeRef(name: 'none'),
            ),
          ],
        );
        final widget = GirClass(
          name: 'Widget',
          cType: 'IWidget',
          parent: 'Object',
          methods: [
            GirMethod(
              name: 'activate',
              cIdentifier: 'i_widget_activate',
              returnType: GirTypeRef(name: 'gboolean'),
            ),
          ],
        );
        final button = GirClass(
          name: 'Button',
          cType: 'IButton',
          parent: 'Widget',
          implements_: const ['Actionable'],
        );
        final ns = nsWith(
          interfaces: [actionable],
          classes: [
            GirClass(name: 'Object', cType: 'IObject'),
            widget,
            button,
          ],
        );
        final ctx = _ctx(ns, [ns], report);
        final code =
            ClassEmitter(ctx, emittedPackages: const {'gtk4'}).emitClass(button)!;
        expect(code, contains('void activateButton()'));
        // Original parent's `activate` is preserved (the rename only
        // affects the mirrored interface method on the child).
        expect(report.entries.any(
          (e) =>
              e.category == 'renamed' &&
              e.reason.contains('override-incompatible with ancestor'),
        ), isTrue);
      },
    );

    test('unresolved interface name is reported as a skip', () {
      final report = GenerationReport();
      final button = GirClass(
        name: 'Button',
        cType: 'IButton',
        parent: 'Widget',
        implements_: const ['NoSuchIface'],
      );
      final ns = nsWith(
        interfaces: const [],
        classes: [
          GirClass(name: 'Object', cType: 'IObject'),
          GirClass(name: 'Widget', cType: 'IWidget', parent: 'Object'),
          button,
        ],
      );
      final ctx = _ctx(ns, [ns], report);
      final code =
          ClassEmitter(ctx, emittedPackages: const {'gtk4'}).emitClass(button)!;
      expect(code, isNotNull);
      expect(report.entries.any(
        (e) =>
            e.category == 'method' && e.reason.contains('NoSuchIface not found'),
      ), isTrue);
    });

    test('interface in non-emitted package is reported as a skip', () {
      final report = GenerationReport();
      final crossIface = GirInterface(
        name: 'Actionable',
        cType: 'OtherActionable',
        methods: [
          GirMethod(
            name: 'go',
            cIdentifier: 'other_actionable_go',
            returnType: GirTypeRef(name: 'none'),
          ),
        ],
      );
      final gtk = nsWith(interfaces: const [], classes: [
        GirClass(name: 'Object', cType: 'IObject'),
        GirClass(name: 'Widget', cType: 'IWidget', parent: 'Object'),
        GirClass(
          name: 'Button',
          cType: 'IButton',
          parent: 'Widget',
          implements_: const ['Actionable'],
        ),
      ]);
      final other = GirNamespace(
        name: 'Other',
        version: '1.0',
        sharedLibrary: 'libother-1.0.so.0',
        cIdentifierPrefixes: const ['Other'],
        cSymbolPrefixes: const ['other'],
        interfaces: [crossIface],
      );
      final ctx = _ctx(gtk, [gtk, other], report);
      final code =
          ClassEmitter(ctx, emittedPackages: const {'gtk4'}).emitClass(
        gtk.classes[2],
      )!;
      expect(code, isNotNull);
      expect(report.entries.any(
        (e) =>
            e.category == 'method' &&
            e.reason.contains('Actionable is in non-generated package'),
      ), isTrue);
    });

    test('cross-package interface mirror adds the foreign import', () {
      final report = GenerationReport();
      // To exercise the cross-package import path, the interface's
      // method must reference a wrapper type whose `requiredImport`
      // is the interface's own package. We use `Gtk.Widget` here —
      // Buildable.getInternalChild returns a GtkWidget, whose Dart
      // wrapper type comes from the `gtk4` package.
      final buildable = GirInterface(
        name: 'Buildable',
        cType: 'GtkBuildable',
        methods: [
          GirMethod(
            name: 'get_internal_child',
            cIdentifier: 'gtk_buildable_get_internal_child',
            returnType:
                const GirTypeRef(name: 'Gtk.Widget', cType: 'GtkWidget*'),
          ),
        ],
      );
      final gtk = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.so.1',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [
          GirClass(name: 'Object', cType: 'GObject'),
          GirClass(name: 'Widget', cType: 'GtkWidget', parent: 'Object'),
        ],
        interfaces: [buildable],
      );
      // A separate "Foo" namespace whose class implements Buildable.
      // Emitting the mirror must add `gtk4` to the Foo package's
      // import list (because the emitted method body uses GtkWidget).
      final foo = GirNamespace(
        name: 'Foo',
        version: '1.0',
        sharedLibrary: 'libfoo-1.0.so.0',
        cIdentifierPrefixes: const ['Foo'],
        cSymbolPrefixes: const ['foo'],
        classes: [
          GirClass(
            name: 'FooWidget',
            cType: 'FooWidget',
            parent: 'Object',
            implements_: const ['Buildable'],
          ),
        ],
      );
      final ctx = _ctx(foo, [gtk, foo], report);
      ClassEmitter(ctx, emittedPackages: const {'gtk4', 'foo'})
          .emitClass(foo.classes[0]);
      expect(ctx.imports.contains('gtk4'), isTrue);
    });

    test('async interface method emits *Callback overload alongside', () {
      final report = GenerationReport();
      final iface = GirInterface(
        name: 'AsyncInitable',
        cType: 'GAsyncInitable',
        methods: [
          GirMethod(
            name: 'init_async',
            cIdentifier: 'g_async_initable_init_async',
            parameters: [
              GirParameter(
                name: 'callback',
                nullable: true,
                scope: 'async',
                type: GirTypeRef(
                  name: 'AsyncReadyCallback',
                  cType: 'GAsyncReadyCallback',
                ),
              ),
              GirParameter(
                name: 'io_priority',
                type: GirTypeRef(name: 'gint'),
              ),
              GirParameter(
                name: 'cancellable',
                nullable: true,
                type: GirTypeRef(name: 'Object', cType: 'GObject*'),
              ),
            ],
            finishFunc: 'init_finish',
          ),
        ],
      );
      final obj = GirClass(
        name: 'SomeObject',
        cType: 'GSomeObject',
        parent: 'Object',
        implements_: const ['AsyncInitable'],
      );
      // AsyncInitable callback needs GAsyncReadyCallback registered.
      final asyncReady = GirCallback(
        name: 'AsyncReadyCallback',
        cType: 'GAsyncReadyCallback',
        returnType: const GirTypeRef(name: 'none'),
        parameters: const [
          GirParameter(
            name: 'source_object',
            type: GirTypeRef(name: 'Object', cType: 'GObject*'),
          ),
          GirParameter(
            name: 'res',
            type: GirTypeRef(name: 'AsyncResult', cType: 'GAsyncResult*'),
          ),
          GirParameter(
            name: 'data',
            type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
          ),
        ],
      );
      // AsyncResult needs to be known to the resolver so the callback
      // bridge accepts it.
      final asyncResultClass = GirClass(
        name: 'AsyncResult',
        cType: 'GAsyncResult',
        parent: 'Object',
      );
      final ns = nsWith(
        interfaces: [iface],
        classes: [
          GirClass(name: 'Object', cType: 'GObject'),
          asyncResultClass,
          obj,
        ],
      );
      // Add AsyncReadyCallback to the namespace via a callback list.
      final nsWithCallbacks = GirNamespace(
        name: ns.name,
        version: ns.version,
        sharedLibrary: 'libgtk-4.so.1',
        cIdentifierPrefixes: ns.cIdentifierPrefixes,
        cSymbolPrefixes: ns.cSymbolPrefixes,
        classes: ns.classes,
        interfaces: ns.interfaces,
        callbacks: [asyncReady],
      );
      final ctx = _ctx(nsWithCallbacks, [nsWithCallbacks], report);
      final code = ClassEmitter(ctx, emittedPackages: const {'glib'})
          .emitClass(obj)!;
      expect(code, isNotNull);
      // Base wrapper for the mirrored async method.
      expect(code, contains('void initAsync('));
      // Lifetime-safe `*Callback` overload — same registry/trampoline
      // pattern as on regular class methods.
      expect(code, contains('void initAsyncCallback('));
    });
  });

  group('ClassEmitter props accessor', () {
    // Build a "GObject.Object"-rooted namespace pair (Gtk + GObject)
    // so `isGObjectRooted(cls)` recognises the chain. The props
    // layer only emits for GObject-rooted classes.
    GirNamespace gobjectNs() => GirNamespace(
          name: 'GObject',
          version: '2.0',
          sharedLibrary: 'libgobject-2.0.so.0',
          cIdentifierPrefixes: const ['GObject', 'gobject'],
          cSymbolPrefixes: const ['gobject'],
          classes: [
            GirClass(name: 'Object', cType: 'GObject'),
          ],
        );

    // Build a class with a single property whose getter and setter
    // are present in `cls.methods`. The props layer delegates to
    // those typed methods.
    GirClass buttonWithProps(String className, GirInterface iface) {
      final dartName = className.toLowerCase();
      return GirClass(
        name: className,
        cType: className,
        parent: 'Widget',
        implements_: const [],
        methods: [
          GirMethod(
            name: 'get_label',
            cIdentifier: '${dartName}_get_label',
            returnType: const GirTypeRef(name: 'utf8'),
          ),
          GirMethod(
            name: 'set_label',
            cIdentifier: '${dartName}_set_label',
            parameters: [
              GirParameter(
                name: 'label',
                type: const GirTypeRef(name: 'utf8'),
              ),
            ],
          ),
        ],
        properties: [
          GirProperty(
            name: 'label',
            type: const GirTypeRef(name: 'utf8'),
            writable: true,
            getter: 'get_label',
            setter: 'set_label',
          ),
        ],
      );
    }

    test('class with one property emits a typed accessor pair', () {
      final report = GenerationReport();
      final iface = GirInterface(name: 'Actionable', cType: 'IActionable');
      final cls = buttonWithProps('TestButton', iface);
      // GObject-rooted: the test must use `GObject.Object` as the
      // root for `isGObjectRooted` to recognise the chain.
      final widget = GirClass(
        name: 'Widget',
        cType: 'TestWidget',
        parent: 'GObject.Object',
      );
      final obj = GirClass(name: 'Object', cType: 'GObject');
      final ns = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [obj, widget, cls],
        interfaces: [iface],
      );
      final ctx = _ctx(ns, [ns, gobjectNs()], report);
      final emitter = ClassEmitter(ctx, emittedPackages: const {'gtk4'});
      final code = emitter.emitClass(cls)!;
      expect(code, isNotNull);
      expect(report.totalSkipped, 0);
      // The `props` field and getter are emitted on the class. The
      // field uses an explicit type annotation so a child class
      // shadowing its parent's `late final _props` picks the child's
      // type for the covariant return on the public `props` getter
      // — without the annotation, Dart would infer the parent's type
      // and reject the assignment.
      expect(code, contains('GtkTestButtonProps get props => _props;'));
      expect(
          code,
          contains(
              'late final GtkTestButtonProps _props = GtkTestButtonProps(this);'));
      // The props companion class has the typed accessor pair.
      final propsCode = emitter.pendingPropsClass!;
      expect(propsCode, contains('String get label'));
      expect(propsCode, contains('set label(String value)'));
      // The accessor delegates to the typed methods on the class.
      expect(propsCode, contains('=> _self.getLabel();'));
      expect(propsCode, contains('_self.setLabel(value);'));
    });

    test('read-only property emits only the getter, no setter', () {
      final report = GenerationReport();
      final cls = GirClass(
        name: 'ReadOnly',
        cType: 'TestReadOnly',
        parent: 'GObject.Object',
        methods: [
          GirMethod(
            name: 'get_value',
            cIdentifier: 'test_get_value',
            returnType: GirTypeRef(name: 'utf8'),
          ),
        ],
        properties: const [
          GirProperty(
            name: 'value',
            type: GirTypeRef(name: 'utf8'),
            getter: 'get_value',
          ),
        ],
      );
      final obj = GirClass(name: 'Object', cType: 'GObject');
      final ns = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [obj, cls],
      );
      final ctx = _ctx(ns, [ns, gobjectNs()], report);
      final emitter = ClassEmitter(ctx, emittedPackages: const {'gtk4'});
      final code = emitter.emitClass(cls)!;
      expect(code, isNotNull);
      // The props class is still emitted — read-only properties are
      // an important use case (e.g. GtkWidget.has-focus).
      expect(emitter.pendingPropsClass, isNotNull);
      final propsCode = emitter.pendingPropsClass!;
      expect(propsCode, contains('String get value'));
      expect(propsCode, isNot(contains('set value(')));
    });

    test('property whose getter has extra args is skipped', () {
      // `get_size(orientation)` — the typed method takes a
      // GtkOrientation. The props layer can only emit a no-arg
      // getter, so the property is recorded as a skip.
      final report = GenerationReport();
      final cls = GirClass(
        name: 'Sized',
        cType: 'TestSized',
        parent: 'GObject.Object',
        methods: [
          GirMethod(
            name: 'get_size',
            cIdentifier: 'test_get_size',
            returnType: GirTypeRef(name: 'gint'),
            parameters: [
              GirParameter(
                name: 'orientation',
                type: GirTypeRef(name: 'Gtk.Orientation'),
              ),
            ],
          ),
        ],
        properties: const [
          GirProperty(
            name: 'size',
            type: GirTypeRef(name: 'gint'),
            getter: 'get_size',
          ),
        ],
      );
      final obj = GirClass(name: 'Object', cType: 'GObject');
      final ns = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [obj, cls],
      );
      final ctx = _ctx(ns, [ns, gobjectNs()], report);
      ClassEmitter(ctx, emittedPackages: const {'gtk4', 'gobject'})
          .emitClass(cls);
      // The property accessor is skipped; no props class is
      // emitted because every property failed.
      expect(
        report.entries.any(
          (e) =>
              e.category == 'property' &&
              e.reason.contains('takes 1 args'),
        ),
        isTrue,
      );
    });

    test('inherited property is surfaced on the leaf class', () {
      // GtkWidget has the `can-focus` property (read-only bool).
      // The leaf's `props` accessor should expose it via the
      // inherited signature.
      final report = GenerationReport();
      final leaf = GirClass(
        name: 'Leaf',
        cType: 'TestLeaf',
        parent: 'Widget',
      );
      final widget = GirClass(
        name: 'Widget',
        cType: 'TestWidget',
        parent: 'GObject.Object',
        methods: [
          GirMethod(
            name: 'get_can_focus',
            cIdentifier: 'test_get_can_focus',
            returnType: GirTypeRef(name: 'gboolean'),
          ),
        ],
        properties: [
          GirProperty(
            name: 'can-focus',
            type: GirTypeRef(name: 'gboolean'),
            getter: 'get_can_focus',
          ),
        ],
      );
      final obj = GirClass(name: 'Object', cType: 'GObject');
      final ns = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [obj, widget, leaf],
      );
      final ctx = _ctx(ns, [ns, gobjectNs()], report);
      final emitter = ClassEmitter(
          ctx, emittedPackages: const {'gtk4', 'gobject'});
      emitter.emitClass(leaf);
      final propsCode = emitter.pendingPropsClass!;
      expect(propsCode, contains('bool get canFocus'));
    });

    test('setter with extra length arg is skipped', () {
      // gtk_text_buffer_set_text(text, len) — the typed setter
      // takes a length in addition to the text. The props layer
      // can only emit a single-arg setter, so the property is
      // skipped with a precise reason.
      final report = GenerationReport();
      final cls = GirClass(
        name: 'Buffer',
        cType: 'TestBuffer',
        parent: 'GObject.Object',
        methods: [
          GirMethod(
            name: 'get_text',
            cIdentifier: 'test_get_text',
            returnType: GirTypeRef(name: 'utf8'),
          ),
          GirMethod(
            name: 'set_text',
            cIdentifier: 'test_set_text',
            parameters: [
              GirParameter(
                name: 'text',
                type: GirTypeRef(name: 'utf8'),
              ),
              GirParameter(
                name: 'length',
                type: GirTypeRef(name: 'gint'),
              ),
            ],
          ),
        ],
        properties: const [
          GirProperty(
            name: 'text',
            type: GirTypeRef(name: 'utf8'),
            writable: true,
            getter: 'get_text',
            setter: 'set_text',
          ),
        ],
      );
      final obj = GirClass(name: 'Object', cType: 'GObject');
      final ns = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [obj, cls],
      );
      final ctx = _ctx(ns, [ns, gobjectNs()], report);
      ClassEmitter(ctx, emittedPackages: const {'gtk4', 'gobject'})
          .emitClass(cls);
      expect(
        report.entries.any(
          (e) =>
              e.category == 'property' && e.reason.contains('takes 2 args'),
        ),
        isTrue,
      );
    });

    test('property whose setter type is narrower than property type is skipped',
        () {
      // set_visible_page(AdwPreferencesPage) — the typed setter's
      // parameter is narrower than the property's declared type
      // (Gtk.Widget). Casting would be unsafe; skip.
      final report = GenerationReport();
      final cls = GirClass(
        name: 'PageHolder',
        cType: 'TestPageHolder',
        parent: 'GObject.Object',
        methods: [
          GirMethod(
            name: 'get_visible_page',
            cIdentifier: 'test_get_visible_page',
            returnType: GirTypeRef(name: 'Gtk.Widget'),
          ),
          GirMethod(
            name: 'set_visible_page',
            cIdentifier: 'test_set_visible_page',
            parameters: [
              GirParameter(
                name: 'page',
                type: GirTypeRef(
                  name: 'Adw.PreferencesPage',
                  cType: 'AdwPreferencesPage*',
                ),
              ),
            ],
          ),
        ],
        properties: const [
          GirProperty(
            name: 'visible-page',
            type: GirTypeRef(name: 'Gtk.Widget'),
            writable: true,
            getter: 'get_visible_page',
            setter: 'set_visible_page',
          ),
        ],
      );
      final obj = GirClass(name: 'Object', cType: 'GObject');
      final widget = GirClass(name: 'Widget', cType: 'GtkWidget');
      final ns = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [obj, widget, cls],
      );
      final ctx = _ctx(ns, [ns, gobjectNs()], report);
      ClassEmitter(ctx, emittedPackages: const {'gtk4', 'gobject'})
          .emitClass(cls);
      expect(
        report.entries.any(
          (e) =>
              e.category == 'property' &&
              e.reason.contains('parameter type does not match'),
        ),
        isTrue,
      );
    });
  });

  group('AsyncCallbackEmitter', () {
    GirCallback asyncReadyCallback() => GirCallback(
          name: 'AsyncReadyCallback',
          cType: 'GAsyncReadyCallback',
          returnType: const GirTypeRef(name: 'none'),
          parameters: const [
            GirParameter(
              name: 'source_object',
              type: GirTypeRef(name: 'Object', cType: 'GObject*'),
            ),
            GirParameter(
              name: 'res',
              type: GirTypeRef(name: 'AsyncResult', cType: 'GAsyncResult*'),
            ),
            GirParameter(
              name: 'data',
              type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
            ),
          ],
        );

    test(
      'emits *Callback convenience overload with typed registry + trampoline',
      () {
        final report = GenerationReport();
        final cb = asyncReadyCallback();
        final fn = GirFunction(
          name: 'open',
          cIdentifier: 'gtk_file_dialog_open',
          parameters: const [
            GirParameter(
              name: 'callback',
              nullable: true,
              scope: 'async',
              type: GirTypeRef(
                name: 'AsyncReadyCallback',
                cType: 'GAsyncReadyCallback',
              ),
            ),
            GirParameter(
              name: 'user_data',
              nullable: true,
              type: GirTypeRef(name: 'gpointer', cType: 'gpointer'),
            ),
          ],
        );
        final ns = _glibNs(functions: [fn], callbacks: [cb]);
        final ctx = _ctx(ns, [ns], report);
        final code = AsyncCallbackEmitter(ctx).emitFunctionOverload(
          fn,
          dartName: 'open',
          ownerName: 'GLib',
          nativeBindingName: '_gtkFileDialogOpen',
        );
        expect(code, isNotNull);
        expect(report.totalSkipped, 0);
        // Typed callback signature for GAsyncReadyCallback.
        expect(code, contains('void Function(GObject?, GAsyncResult) callback'));
        // user_data is hidden from the wrapper.
        expect(code, isNot(contains('Pointer<ffi.Void> userData')));
        // Registry + sequence counter + permanent function pointer.
        // (Top-level for namespace functions; static on class members.)
        expect(code, contains('final _openCallbackRegistry = '
            '<int, void Function(GObject?, GAsyncResult)>{};'));
        expect(code, contains('int _openCallbackSeq = 0;'));
        expect(code, contains('final _openCallbackPtr = '
            'ffi.Pointer.fromFunction<'));
        // Trampoline that looks up by id, calls the typed callback,
        // and frees the data pointer.
        expect(code, contains('void _openCallbackTrampoline('));
        expect(code, contains('final id = data.cast<ffi.IntPtr>().value;'));
        expect(code, contains('final fn = _openCallbackRegistry.remove(id);'));
        expect(code, contains('malloc.free(data);'));
        expect(code, contains('GObject.fromPointer(sourceObject.cast())'));
        expect(code, contains('GAsyncResult.fromPointer(res.cast())'));
        // Convenience overload calls the C function with the
        // trampoline pointer and the malloc'd id pointer.
        expect(code, contains('_gtkFileDialogOpen('));
        expect(code, contains('_openCallbackPtr,'));
        expect(code, contains('_data.cast<ffi.Void>()'));
      },
    );

    test(
      'skips when callback type is not GAsyncReadyCallback',
      () {
        final report = GenerationReport();
        // A non-GAsyncReadyCallback progress callback (just a marker).
        final cb = GirCallback(
          name: 'FileProgressCallback',
          cType: 'GFileProgressCallback',
          returnType: const GirTypeRef(name: 'none'),
          parameters: const [
            GirParameter(
              name: 'current_num_bytes',
              type: GirTypeRef(name: 'goffset', cType: 'goffset'),
            ),
            GirParameter(
              name: 'total_num_bytes',
              type: GirTypeRef(name: 'goffset', cType: 'goffset'),
            ),
          ],
        );
        final fn = GirFunction(
          name: 'copy',
          cIdentifier: 'g_file_copy',
          parameters: const [
            GirParameter(
              name: 'progress_callback',
              scope: 'async',
              type: GirTypeRef(
                name: 'FileProgressCallback',
                cType: 'GFileProgressCallback',
              ),
            ),
          ],
        );
        final ns = _glibNs(functions: [fn], callbacks: [cb]);
        final ctx = _ctx(ns, [ns], report);
        final code = AsyncCallbackEmitter(ctx).emitFunctionOverload(
          fn,
          dartName: 'copy',
          ownerName: 'GLib',
          nativeBindingName: '_gFileCopy',
        );
        expect(code, isNull);
      },
    );

    test(
      'returns null when no scope="async" parameter is present',
      () {
        final report = GenerationReport();
        final fn = GirFunction(
          name: 'utf8_strlen',
          cIdentifier: 'g_utf8_strlen',
          returnType: const GirTypeRef(name: 'glong', cType: 'glong'),
          parameters: const [
            GirParameter(
              name: 'str',
              type: GirTypeRef(name: 'utf8', cType: 'gchar*'),
            ),
          ],
        );
        final ns = _glibNs(functions: [fn]);
        final ctx = _ctx(ns, [ns], report);
        final code = AsyncCallbackEmitter(ctx).emitFunctionOverload(
          fn,
          dartName: 'utf8Strlen',
          ownerName: 'GLib',
          nativeBindingName: '_gUtf8Strlen',
        );
        expect(code, isNull);
      },
    );
  });

  group('PackageEmitter file layout', () {
    // The one-Dart-class-per-file layout is a structural property of
    // generated bindings. A future generator refactor that re-introduces
    // `classes_N.dart` chunking would break the IDE navigation story
    // and the docs; this test guards against that regression by
    // emitting into a temp directory and reading the file structure
    // back out.
    test('one class per file, named after the class; props companion '
        'in its own file; barrel preserves declaration order', () {
      final tmp = Directory.systemTemp.createTempSync('pkgemitter_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // GObject.Object is the GIR root for every GObject-rooted class.
      final gobject = GirNamespace(
        name: 'GObject',
        version: '2.0',
        sharedLibrary: 'libgobject-2.0.so.0',
        cIdentifierPrefixes: const ['GObject', 'gobject'],
        cSymbolPrefixes: const ['gobject'],
        classes: [
          GirClass(
            name: 'Object',
            cType: 'GObject',
            glibTypeName: 'GObject',
          ),
        ],
      );
      // The leaf class: must land in `gtkbutton.dart`. Must also
      // emit a props companion in `gtkbutton_props.dart` because
      // `GtkButton.props.label` round-trips through the typed
      // `getLabel` / `setLabel` methods.
      final buttonClass = GirClass(
        name: 'Button',
        cType: 'GtkButton',
        parent: 'GObject.Object',
        glibTypeName: 'GtkButton',
        methods: [
          GirMethod(
            name: 'get_label',
            cIdentifier: 'gtk_button_get_label',
            returnType: const GirTypeRef(name: 'utf8'),
            returnNullable: true,
          ),
          GirMethod(
            name: 'set_label',
            cIdentifier: 'gtk_button_set_label',
            parameters: [
              GirParameter(
                name: 'label',
                type: const GirTypeRef(name: 'utf8'),
                nullable: true,
              ),
            ],
          ),
        ],
        properties: const [
          GirProperty(
            name: 'label',
            type: GirTypeRef(name: 'utf8'),
            writable: true,
            readable: true,
            getter: 'get_label',
            setter: 'set_label',
          ),
        ],
      );
      final gtk = GirNamespace(
        name: 'Gtk',
        version: '4.0',
        sharedLibrary: 'libgtk-4.0.so.0',
        cIdentifierPrefixes: const ['Gtk', 'gtk'],
        cSymbolPrefixes: const ['gtk'],
        classes: [buttonClass],
      );
      final gobjectEmitter = PackageEmitter(
        namespace: gobject,
        allNamespaces: [gobject],
        packagesDir: tmp.path,
        emittedPackages: const {'gobject'},
      );
      gobjectEmitter.emit();
      final gtkEmitter = PackageEmitter(
        namespace: gtk,
        allNamespaces: [gobject, gtk],
        packagesDir: tmp.path,
        emittedPackages: const {'gobject', 'gtk4'},
      );
      gtkEmitter.emit();

      // Per-class files exist with the right names.
      final gtkSrc = Directory('${tmp.path}/gtk4/lib/src');
      expect(gtkSrc.existsSync(), isTrue);
      expect(File('${gtkSrc.path}/gtkbutton.dart').existsSync(), isTrue,
          reason: 'class GtkButton must live in gtkbutton.dart');
      expect(File('${gtkSrc.path}/gtkbutton_props.dart').existsSync(),
          isTrue,
          reason: 'class GtkButtonProps must live in gtkbutton_props.dart');

      // Each file contains exactly the class whose name it bears.
      final hostSource =
          File('${gtkSrc.path}/gtkbutton.dart').readAsStringSync();
      expect(hostSource, contains('class GtkButton extends GObjectObject {'));
      expect(hostSource, isNot(contains('class GtkButtonProps')));
      final propsSource =
          File('${gtkSrc.path}/gtkbutton_props.dart').readAsStringSync();
      // The GObject.Object parent class declares no properties, so
      // there is no `GObjectObjectProps` for the leaf's props class
      // to extend — the leaf's companion class is a standalone
      // declaration.
      expect(propsSource, contains('class GtkButtonProps {'));
      expect(propsSource, isNot(contains('class GtkButton ')));

      // No `classes_*.dart` chunked class files are produced.
      final chunked = gtkSrc
          .listSync()
          .where((e) => e.path.split(Platform.pathSeparator).last
              .startsWith('classes_'))
          .toList();
      expect(chunked, isEmpty,
          reason: 'classes must be one-per-file, not chunked');

      // The barrel lists per-class files in declaration order — host
      // class first, then its props companion — so IDE jump-to-source
      // visits them in GIR declaration order.
      final barrel = File('${tmp.path}/gtk4/lib/gtk4.dart').readAsStringSync();
      final hostIdx = barrel.indexOf("part 'src/gtkbutton.dart';");
      final propsIdx =
          barrel.indexOf("part 'src/gtkbutton_props.dart';");
      expect(hostIdx, greaterThanOrEqualTo(0));
      expect(propsIdx, greaterThan(hostIdx),
          reason: 'props companion must follow its host in the barrel');
    });
  });
}
