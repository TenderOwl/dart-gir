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
  });

  group('FunctionEmitter.emitConstant', () {
    GirConstant mkConst(String name, String value, GirTypeRef type) =>
        GirConstant(name: name, value: value, type: type);

    test('emits utf8 string constant as Dart const String', () {
      final report = GenerationReport();
      final ns = _glibNs(constants: [
        mkConst(
          'DIR_SEPARATOR_S',
          '/',
          const GirTypeRef(name: 'utf8', cType: 'gchar*'),
        ),
      ]);
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single)!;
      expect(code, contains("const dirSeparatorS = '/'"));
      expect(report.totalSkipped, 0);
    });

    test('escapes backslashes in string constants', () {
      final report = GenerationReport();
      final ns = _glibNs(constants: [
        mkConst(
          'PROBE',
          r'C:\Users\foo',
          const GirTypeRef(name: 'utf8', cType: 'gchar*'),
        ),
      ]);
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single)!;
      // A literal `\` in GIR becomes `\\` in Dart source so the value
      // round-trips to the same character.
      expect(code, contains(r"const probe = 'C:\\Users\\foo';"));
    });

    test('skips non-primitive, non-string constant types', () {
      final report = GenerationReport();
      // `time_t` resolves to unsupported — should be skipped with reason.
      final ns = _glibNs(constants: [
        mkConst(
          'WHEN',
          '1234',
          const GirTypeRef(name: 'time_t', cType: 'time_t'),
        ),
      ]);
      final ctx = _ctx(ns, [ns], report);
      final code = FunctionEmitter(ctx).emitConstant(ns.constants.single);
      expect(code, isNull);
      expect(report.entries.single.reason, 'non-primitive type');
    });

    test('skips integer constants that overflow Dart int', () {
      final report = GenerationReport();
      final ns = _glibNs(constants: [
        mkConst(
          'MAXUINT64',
          '18446744073709551615',
          const GirTypeRef(name: 'guint64', cType: 'guint64'),
        ),
      ]);
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
    }) =>
        GirCallback(
          name: name,
          cType: cType,
          returnType: returnType ?? const GirTypeRef(name: 'none'),
          parameters: parameters,
        );

    test('emits typedef for a callback with primitive parameters and return', () {
      final report = GenerationReport();
      final ns = _glibNs(callbacks: [
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
      ]);
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
      final ns = _glibNs(callbacks: [
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
      ]);
      final ctx = _ctx(ns, [ns], report);
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single)!;
      expect(code, contains('typedef GLogFunc'));
      expect(code, contains('ffi.Pointer<Utf8>'));
      expect(report.totalSkipped, 0);
    });

    test('renders boolean return as `int` (Dart FFI does not unify bool ↔ Int32)',
        () {
      final report = GenerationReport();
      final ns = _glibNs(callbacks: [
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
      ]);
      final ctx = _ctx(ns, [ns], report);
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single)!;
      // `bool` is exposed as `int` per the documented convention (0 = false,
      // non-zero = true). The user-facing typedef must not contain `bool`.
      expect(code, contains('typedef GHRFunc'));
      expect(code, contains('int Function('));
      expect(code, isNot(contains('bool')));
    });

    test('skips when an unsupported parameter type is referenced', () {
      final report = GenerationReport();
      final ns = _glibNs(callbacks: [
        cb(
          name: 'WithArray',
          returnType: const GirTypeRef(name: 'none'),
          parameters: const [
            GirParameter(
              name: 'data',
              // `array types are handled in a later phase` — must skip.
              type: GirTypeRef(
                name: 'gint',
                array: GirArrayInfo(
                  elementType: GirTypeRef(name: 'gint'),
                ),
              ),
            ),
          ],
        ),
      ]);
      final ctx = _ctx(ns, [ns], report);
      final code = CallbackEmitter(ctx).emit(ns.callbacks.single);
      expect(code, isNull);
      expect(report.entries.single.category, 'callback');
      expect(report.entries.single.reason, contains('array'));
    });

    test('skips a callback declared in a non-emitted package', () {
      final report = GenerationReport();
      final ns = _glibNs(callbacks: [
        cb(
          name: 'ExternalCb',
          returnType: const GirTypeRef(name: 'none'),
          parameters: const [],
        ),
      ]);
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
}
