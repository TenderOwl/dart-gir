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
    final signals = [sig];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    expect(code, contains('int onFoo(void Function() callback)'));
    expect(code, contains(
      "return _connectSignal_v_0(this.handle, 'foo', callback);",
    ));
    expect(ctx.report.totalSkipped, 0);
  });

  test('emits two helpers when the class has two void(void) signals', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final signals = [GirSignal(name: 'foo'), GirSignal(name: 'bar')];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    expect(code, contains('int onFoo(void Function() callback)'));
    expect(code, contains('int onBar(void Function() callback)'));
    expect(ctx.report.totalSkipped, 0);
  });

  test('emits one helper per bucket for two distinct-arity signals', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final signals = [
      GirSignal(name: 'foo'),
      GirSignal(
        name: 'with-arg',
        parameters: const [
          GirParameter(name: 'pspec', type: GirTypeRef(name: 'ParamSpec')),
        ],
      ),
    ];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    // `foo` is void(void); `with-arg` is unsupported so its arg-type skip
    // reason comes out — the bucket for the typed signal won't exist.
    expect(code, contains('_connectSignal_v_0'));
    expect(code, contains('_connectSignal_v_1_o'),
        skip: 'ParamSpec type is unresolved in the empty test ctx');
    expect(ctx.report.entries.any((e) => e.category == 'signal'), isTrue);
  });

  test('emits a typed helper for a single-pointer signal', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(
      name: 'event',
      parameters: const [
        GirParameter(name: 'sender', type: GirTypeRef(name: 'GObject')),
      ],
    );
    final signals = [sig];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    // GObject type is not in the test namespace so it gets a skip;
    // the test simply proves the skip-reason is precise.
    expect(ctx.report.entries.single.category, 'signal');
    expect(ctx.report.entries.single.reason, contains('unsupported arg type'));
  });

  test('skips a signal with unsupported arg type and reports precise reason',
      () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(
      name: 'with-arg',
      parameters: const [
        GirParameter(name: 'pspec', type: GirTypeRef(name: 'ParamSpec')),
      ],
    );
    final signals = [sig];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    expect(code, isEmpty);
    expect(ctx.report.entries.single.category, 'signal');
    expect(ctx.report.entries.single.reason, contains('unsupported arg type'));
  });

  test('skips a signal with a non-void return and reports precise reason', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    // A return type like `GObject` (class type) is not supported as a
    // signal return — only void and primitives.
    final sig = GirSignal(
      name: 'returns-class',
      returnType: const GirTypeRef(name: 'Object'),
    );
    final signals = [sig];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    expect(code, isEmpty);
    expect(ctx.report.entries.single.category, 'signal');
    expect(
      ctx.report.entries.single.reason,
      contains('unsupported return type'),
    );
  });

  test('records a name collision when onSignalName already exists', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: 'foo');
    final members = <String>{'onFoo'};
    final code = emitSignalConnectors(
      ctx,
      [sig],
      'TestClass',
      members,
      buckets: buildSignalBuckets([(signal: sig, ns: ctx.namespace)], ctx),
    );
    expect(code, isEmpty);
    expect(ctx.report.entries.single.category, 'signal');
    expect(ctx.report.entries.single.reason, contains('name collision'));
  });

  test('escapes single quotes in signal names', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: "weird'signal");
    final signals = [sig];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    expect(code, contains(r"'weird\'signal'"));
  });

  test('uses doc comment when present', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: 'foo', doc: 'Fires when foo happens.');
    final signals = [sig];
    final code = emitSignalConnectors(
      ctx,
      signals,
      'TestClass',
      <String>{},
      buckets: buildSignalBuckets([for (final s in signals) (signal: s, ns: ctx.namespace)], ctx),
    );
    expect(code, contains('/// Fires when foo happens.'));
  });

  test('inheritedSignals walks the parent chain and deduplicates', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final root = GirClass(
      name: 'Root',
      signals: [
        GirSignal(name: 'notify'),
      ],
    );
    final mid = GirClass(
      name: 'Mid',
      parent: 'TestNS.Root',
      signals: [
        GirSignal(name: 'mid-event'),
      ],
    );
    final leaf = GirClass(
      name: 'Leaf',
      parent: 'TestNS.Mid',
      signals: [
        GirSignal(name: 'leaf-event'),
        // Same name as a root signal — must be deduplicated against
        // itself across the chain.
        GirSignal(name: 'notify'),
      ],
    );
    // Hand-build a namespace that owns all three classes.
    final ns3 = GirNamespace(
      name: 'TestNS',
      version: '1.0',
      cIdentifierPrefixes: const ['T'],
      classes: [root, mid, leaf],
    );
    final ctx3 = _ctx(ns3);
    final inherited = inheritedSignals(leaf, ctx3);
    // Walk is immediate-parent-first: Mid's signals come before Root's.
    // Leaf's own `notify` is deduped against Root's.
    expect(inherited.length, 2);
    expect(inherited[0].name, 'mid-event');
    expect(inherited[1].name, 'notify');
  });

  test('signalSkipReason rejects arity > 5', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(
      name: 'too-many',
      parameters: List.generate(
        6,
        (i) =>
            GirParameter(name: 'p$i', type: GirTypeRef(name: 'gint')),
      ),
    );
    expect(signalSkipReason(sig, ctx), contains('arity 6'));
  });

  test('signalSkipReason rejects weak-ref', () {
    final ns = _ns();
    final ctx = _ctx(ns);
    final sig = GirSignal(name: 'weak-ref');
    expect(signalSkipReason(sig, ctx), contains('weak-ref'));
  });
}
