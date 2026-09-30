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
  test('returns null when no class has a kept void(void) signal', () {
    final ctx = _ctx(_ns());
    expect(emitSignalsHelper(ctx), isNull);
    expect(ctx.usesGirFfi, isFalse);
  });

  test('emits helper when a class has a kept signal', () {
    final ns = _ns(
      classes: [
        GirClass(name: 'Foo', signals: [GirSignal(name: 'bar')]),
      ],
    );
    final ctx = _ctx(ns);
    final code = emitSignalsHelper(ctx);
    expect(code, isNotNull);
    expect(code!, contains('_connectVoidSignal'));
    expect(code, contains('_voidSignalTrampoline'));
    expect(code, contains('_destroyVoidSignalState'));
    expect(code, contains('_gSignalConnectData'));
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

  test('does not emit helper when only non-void signals are present', () {
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

  test('isKeptSignal returns true only for void(void)', () {
    expect(isKeptSignal(GirSignal(name: 'foo')), isTrue);
    expect(
      isKeptSignal(GirSignal(
        name: 'foo',
        parameters: const [
          GirParameter(name: 'x', type: GirTypeRef(name: 'gint')),
        ],
      )),
      isFalse,
    );
    expect(isKeptSignal(GirSignal(name: 'foo', returnType: const GirTypeRef(name: 'gint'))), isFalse);
  });
}
