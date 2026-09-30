import 'package:gir_generator/src/emit/context.dart';
import 'package:gir_generator/src/emit/report.dart';
import 'package:gir_generator/src/emit/signals_helper.dart';
import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/types.dart' show packageNameFor;
import 'package:test/test.dart';

GirNamespace _ns({
  List<GirClass> classes = const [],
  List<GirInterface> interfaces = const [],
}) =>
    GirNamespace(
      name: 'TestNS',
      version: '1.0',
      cIdentifierPrefixes: const ['T'],
      classes: classes,
      interfaces: interfaces,
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
        GirClass(name: 'Foo', signals: [GirSignal(name: 'bar')]),
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
        GirInterface(name: 'IFoo', signals: [GirSignal(name: 'bar')]),
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
                GirParameter(name: 'msg', type: GirTypeRef(name: 'utf8')),
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

  test('emits the synthetic v_0_ bucket for the connectSignal escape hatch',
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
                GirParameter(name: 'msg', type: GirTypeRef(name: 'utf8')),
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
