import 'package:gir_generator/src/emit/context.dart';
import 'package:gir_generator/src/emit/report.dart';
import 'package:gir_generator/src/emit/signals_emitter.dart';
import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/types.dart' show packageNameFor;
import 'package:test/test.dart';

GirNamespace _ns() => GirNamespace(
      name: 'TestNS',
      version: '1.0',
      cIdentifierPrefixes: const ['T'],
    );

EmitContext _ctx(GirNamespace ns) => EmitContext(
      namespace: ns,
      allNamespaces: [ns],
      report: GenerationReport(),
      emittedPackages: {packageNameFor(ns)},
    );

void main() {
  test('emits onSignalName for a void(void) signal', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: 'foo');
    final code = emitSignalConnectors(ctx, [sig], 'TestClass', <String>{});
    expect(code, contains('int onFoo(void Function() callback)'));
    expect(code, contains(
      "return _connectVoidSignal(this.handle, 'foo', callback);",
    ));
    expect(ctx.report.totalSkipped, 0);
  });

  test('emits two helpers when the class has two void(void) signals', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final signals = [GirSignal(name: 'foo'), GirSignal(name: 'bar')];
    final code = emitSignalConnectors(ctx, signals, 'TestClass', <String>{});
    expect(code, contains('int onFoo(void Function() callback)'));
    expect(code, contains('int onBar(void Function() callback)'));
    expect(ctx.report.totalSkipped, 0);
  });

  test('skips a signal that has a parameter', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(
      name: 'with-arg',
      parameters: const [
        GirParameter(
          name: 'pspec',
          type: GirTypeRef(name: 'ParamSpec'),
        ),
      ],
    );
    final code = emitSignalConnectors(ctx, [sig], 'TestClass', <String>{});
    expect(code, isEmpty);
    expect(ctx.report.entries.single.category, 'signal');
    expect(
      ctx.report.entries.single.reason,
      'only void(void) supported in this release',
    );
  });

  test('skips a signal that has a non-void return', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(
      name: 'returns-int',
      returnType: const GirTypeRef(name: 'gint'),
    );
    final code = emitSignalConnectors(ctx, [sig], 'TestClass', <String>{});
    expect(code, isEmpty);
    expect(ctx.report.entries.single.category, 'signal');
  });

  test('records a name collision when onSignalName already exists', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: 'foo');
    final members = <String>{'onFoo'};
    final code = emitSignalConnectors(ctx, [sig], 'TestClass', members);
    expect(code, isEmpty);
    expect(ctx.report.entries.single.category, 'signal');
    expect(ctx.report.entries.single.reason, contains('name collision'));
  });

  test('escapes single quotes in signal names', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: "weird'signal");
    final code = emitSignalConnectors(ctx, [sig], 'TestClass', <String>{});
    expect(code, contains(r"'weird\'signal'"));
  });

  test('uses doc comment when present', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: 'foo', doc: 'Fires when foo happens.');
    final code = emitSignalConnectors(ctx, [sig], 'TestClass', <String>{});
    expect(code, contains('/// Fires when foo happens.'));
  });
}
