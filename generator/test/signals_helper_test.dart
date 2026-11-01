import 'package:gir_generator/src/emit/context.dart';
import 'package:gir_generator/src/emit/report.dart';
import 'package:gir_generator/src/emit/signals_helper.dart';
import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/types.dart' show packageNameFor;
import 'package:test/test.dart';

GirNamespace _ns({
  List<GirClass> classes = const [],
  List<GirInterface> interfaces = const [],
  List<GirBitfield> bitfields = const [],
}) => GirNamespace(
  name: 'TestNS',
  version: '1.0',
  cIdentifierPrefixes: const ['T'],
  classes: classes,
  interfaces: interfaces,
  bitfields: bitfields,
);

EmitContext _ctx(GirNamespace ns) => EmitContext(
  namespace: ns,
  allNamespaces: [ns],
  report: GenerationReport(),
  emittedPackages: {packageNameFor(ns)},
);

void main() {
  test('returns null when no class has a kept signal', () {
    final ctx = _ctx(_ns());
    expect(emitSignalsHelper(ctx), isNull);
    expect(ctx.usesGirFfi, isFalse);
  });

  test('emits helper when a class has a kept void(void) signal', () {
    final ns = _ns(
      classes: [
        GirClass(
          name: 'Foo',
          signals: [GirSignal(name: 'bar')],
        ),
      ],
    );
    final ctx = _ctx(ns);
    final code = emitSignalsHelper(ctx);
    expect(code, isNotNull);
    expect(code!, contains('_connectSignal_v_0'));
    expect(code, contains('_signalTrampoline_v_0'));
    expect(code, contains('_destroySignalState'));
    expect(code, contains('_gSignalConnectData'));
    expect(code, contains('connectSignal'));
    expect(ctx.usesGirFfi, isTrue);
  });

  test('emits helper when an interface has a kept signal', () {
    final ns = _ns(
      interfaces: [
        GirInterface(
          name: 'IFoo',
          signals: [GirSignal(name: 'bar')],
        ),
      ],
    );
    final ctx = _ctx(ns);
    final code = emitSignalsHelper(ctx);
    expect(code, isNotNull);
    expect(ctx.usesGirFfi, isTrue);
  });

  test('does not emit helper when only unsupported signals are present', () {
    final ns = _ns(
      classes: [
        GirClass(
          name: 'Foo',
          signals: [
            GirSignal(
              name: 'with-arg',
              parameters: const [
                GirParameter(
                  name: 'pspec',
                  type: GirTypeRef(name: 'ParamSpec'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final ctx = _ctx(ns);
    expect(emitSignalsHelper(ctx), isNull);
  });

  test('emits per-bucket trampoline + registry for typed signals', () {
    // Build a namespace that has a typed signal AND its argument type
    // registered as a class in the same namespace. Without an inline GIR
    // parser, the cleanest path is to use a string argument (which goes
    // through `bridgeFor` and resolves cleanly via the TypeResolver).
    final ns = _ns(
      classes: [
        GirClass(
          name: 'Foo',
          signals: [
            GirSignal(
              name: 'with-string',
              parameters: const [
                GirParameter(
                  name: 'msg',
                  type: GirTypeRef(name: 'utf8'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final ctx = _ctx(ns);
    final code = emitSignalsHelper(ctx);
    expect(code, isNotNull);
    // A typed signal must land in its own bucket — `v_1_s` (one string arg).
    expect(code!, contains('_connectSignal_v_1_s'));
    expect(code, contains('_signalTrampoline_v_1_s'));
    expect(code, contains('gFree'));
  });

  test(
    'emits the synthetic v_0_ bucket for the connectSignal escape hatch',
    () {
      // Namespace with only typed signals — no void(void) — must still
      // emit a v_0_ bucket so `connectSignal` resolves.
      final ns = _ns(
        classes: [
          GirClass(
            name: 'Foo',
            signals: [
              GirSignal(
                name: 'with-string',
                parameters: const [
                  GirParameter(
                    name: 'msg',
                    type: GirTypeRef(name: 'utf8'),
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final ctx = _ctx(ns);
      final code = emitSignalsHelper(ctx);
      expect(code, isNotNull);
      expect(code!, contains('_connectSignal_v_0'));
      expect(code, contains('connectSignal'));
    },
  );

  group('the return shapes the marshaller carries', () {
    // GLib's generic marshaller maps a GValue onto an ffi type and back.
    // `value_to_ffi_type` and `value_from_ffi_type` in
    // `gobject/gclosure.c` decide what passes, and what it owns:
    //
    // * a **string** return: `g_value_take_string` — the GValue takes the
    //   buffer, so the trampoline has to hand over a GLib-allocated copy;
    // * an **object** return: `g_value_take_object` — the GValue takes a
    //   reference, so the trampoline hands over the pointer unchanged;
    // * a **flags** return: `g_value_set_flags` — the value is copied.

    GirNamespace nsWith(GirSignal signal) => _ns(
      classes: [
        GirClass(name: 'Foo', signals: [signal]),
      ],
    );

    test('a string return is copied into a GLib-allocated buffer', () {
      final ctx = _ctx(
        nsWith(
          GirSignal(
            name: 'format-entry-text',
            returnType: const GirTypeRef(name: 'utf8', cType: 'gchar*'),
            parameters: const [
              GirParameter(
                name: 'path',
                type: GirTypeRef(name: 'utf8'),
              ),
            ],
          ),
        ),
      );
      final code = emitSignalsHelper(ctx)!;

      // The callback writes a Dart string; the trampoline hands the
      // marshaller a GLib-allocated copy, because the GValue releases it
      // with `g_free`.
      expect(code, contains('String? Function(String path) callback'));
      expect(code, contains('gStrdupLike(result)'));
      // The trampoline's own return type is a pointer.
      expect(code, contains('ffi.Pointer<Utf8> Function('));
      // A pointer return takes no exceptional return value.
      expect(code, isNot(contains('exceptionalReturn')));
    });

    test('an object return hands the marshaller the pointer', () {
      final ctx = _ctx(
        _ns(
          classes: [
            GirClass(name: 'Bar'),
            GirClass(
              name: 'Foo',
              signals: [
                GirSignal(
                  name: 'create-window',
                  returnType: const GirTypeRef(name: 'Bar', cType: 'TBar*'),
                ),
              ],
            ),
          ],
        ),
      );
      final code = emitSignalsHelper(ctx)!;

      // The callback returns the wrapper; the trampoline hands over the
      // pointer — `g_value_take_object` gives the GValue a reference of
      // its own.
      expect(code, contains('TBar? Function() callback'));
      expect(code, contains('result?.handle ?? ffi.nullptr'));
      expect(code, contains('ffi.Pointer<ffi.Void> Function('));
    });

    test('a flags return carries the flags value', () {
      final ctx = _ctx(
        _ns(
          bitfields: [GirBitfield(name: 'DragAction', cType: 'TDragAction')],
          classes: [
            GirClass(
              name: 'Foo',
              signals: [
                GirSignal(
                  name: 'enter',
                  returnType: const GirTypeRef(
                    name: 'DragAction',
                    cType: 'TDragAction',
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      final code = emitSignalsHelper(ctx)!;

      // A flags return is an unsigned int; the callback writes the flags
      // class and the trampoline unwraps its value.
      expect(code, contains('TDragAction Function() callback'));
      expect(code, contains('return result.value;'));
      expect(code, contains('ffi.Uint32 Function('));
    });

    test('a strv argument is copied into a Dart list', () {
      final ctx = _ctx(
        nsWith(
          GirSignal(
            name: 'ask-question',
            parameters: const [
              GirParameter(
                name: 'message',
                type: GirTypeRef(name: 'utf8'),
              ),
              // An array with no C type whose element is a string — the
              // shape of a `GStrv`.
              GirParameter(
                name: 'choices',
                type: GirTypeRef(
                  array: GirArrayInfo(elementType: GirTypeRef(name: 'utf8')),
                ),
              ),
            ],
          ),
        ),
      );
      final code = emitSignalsHelper(ctx)!;

      expect(
        code,
        contains('void Function(String message, List<String>? choices)'),
      );
      expect(code, contains('stringListFromNative('));
      // The GValue owns the array, so the trampoline copies it and
      // leaves it alone.
      expect(code, isNot(contains('gStrfreev')));
    });
  });

  test('isKeptSignal returns true only for supported signatures', () {
    final ctx = _ctx(_ns());
    expect(isKeptSignal(GirSignal(name: 'foo'), ctx), isTrue);
    // Detailed signal names (with `::` detail) are out of scope.
    expect(
      isKeptSignal(GirSignal(name: 'notify::name'), ctx),
      isFalse,
      reason: 'detailed signals are out of scope; use connectSignal',
    );
  });

  test('weak-ref is rejected', () {
    final ctx = _ctx(_ns());
    expect(isKeptSignal(GirSignal(name: 'weak-ref'), ctx), isFalse);
  });
}
