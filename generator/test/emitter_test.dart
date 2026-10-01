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
}
