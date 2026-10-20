import 'package:gtk_templates/gtk_templates.dart';
import 'package:gtk_templates_builder/gtk_templates_builder.dart';
import 'package:test/test.dart';

void main() {
  group('extractChildrenFromXml', () {
    test('extracts a single self-closing object', () {
      const xml = '''
        <interface>
          <template class="Foo" parent="GtkBox">
            <object class="GtkLabel" id="counterLabel"/>
          </template>
        </interface>
      ''';
      final children = extractChildrenFromXml(xml);
      expect(children, hasLength(1));
      expect(children[0].id, 'counterLabel');
      expect(children[0].typeName, 'GtkLabel');
    });

    test('extracts multiple objects in source order', () {
      const xml = '''
        <interface>
          <template class="Foo" parent="GtkBox">
            <object class="GtkLabel" id="a"/>
            <object class="GtkButton" id="b"/>
            <object class="GtkBox" id="c"/>
          </template>
        </interface>
      ''';
      final children = extractChildrenFromXml(xml);
      expect(children.map((c) => c.id), ['a', 'b', 'c']);
      expect(children.map((c) => c.typeName), [
        'GtkLabel',
        'GtkButton',
        'GtkBox',
      ]);
    });

    test('returns empty list when there are no objects', () {
      const xml = '<interface><template class="Foo"/></interface>';
      expect(extractChildrenFromXml(xml), isEmpty);
    });
  });

  group('codegenMixin', () {
    test('emits `part of` directive when partOfPath is given', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkApplicationWindow',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
        partOfPath: 'my_window.dart',
      );
      final src = codegenMixin(input);
      expect(src, contains("part of 'my_window.dart';"));
      // The generated part file must NOT carry its own
      // imports — they're inherited from the parent file.
      expect(src, isNot(contains("import 'package:")));
    });

    test('emits the mixin with the class name and parent type', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkApplicationWindow',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('mixin _\$SampleTemplate on GtkApplicationWindow'));
    });

    test('embeds the XML as a top-level const string', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkApplicationWindow',
        xmlString: '<interface><template class="Sample"/></interface>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('const String _\$SampleTemplate_xml = '));
      expect(
        src,
        contains('<interface><template class="Sample"/></interface>'),
      );
    });

    test('emits a `late final` per child', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [
          TemplateChildSpec(id: 'counter', typeName: 'GtkLabel'),
          TemplateChildSpec(id: 'button', typeName: 'GtkButton'),
        ],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('late final GtkLabel counter = '));
      expect(src, contains('late final GtkButton button = '));
    });

    test('resolves the children against the widget\'s own native type', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [
          TemplateChildSpec(id: 'counter', typeName: 'GtkLabel'),
          TemplateChildSpec(id: 'button', typeName: 'GtkButton'),
        ],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      // `gtk_widget_get_template_child()` wants the type that
      // *declared* the child — the widget's own native type — not the
      // child's type.
      expect(src, contains("widgetTypeOf(this as GtkWidget), 'counter'"));
      expect(src, contains("widgetTypeOf(this as GtkWidget), 'button'"));
      expect(src, isNot(contains("typeFromName('GtkLabel')")));
      expect(src, isNot(contains("typeFromName('GtkButton')")));
    });

    test('emits the children list and spec classes', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [TemplateChildSpec(id: 'a', typeName: 'GtkLabel')],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('class _TemplateChildSpec'));
      expect(
        src,
        contains(
          "const List<_TemplateChildSpec> _\$SampleTemplate_children = [",
        ),
      );
      expect(src, contains("_TemplateChildSpec('a', 'GtkLabel')"));
    });

    test('emits the class-init idempotency guard', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('static bool _classInitialized = false'));
      expect(src, contains('_ensureClassInit'));
    });

    test('rewrites the XML\'s template attributes at runtime', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      // A Dart subclass has no GType of its own, so the XML's
      // `class` / `parent` attributes are rewritten against the
      // instance's real native type before GTK sees them.
      expect(src, contains('prepareTemplateXml('));
      expect(src, contains('_ensureClassInit(int widgetType)'));
      expect(src, contains('gbytesFromString('));
    });

    test('emits the per-instance init with getWidgetClass', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('final widget = this as GtkWidget;'));
      expect(src, contains('getWidgetClass(widget)'));
      expect(src, contains('widgetClass.setTemplate('));
      expect(src, contains('widgetClass.bindTemplateChildFull'));
    });

    test('overrides initTemplate so the widget can build its template', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      // GTK builds a widget's template in the instance initializer.
      // Dart has no instance-initializer hook, so the mixin overrides
      // `initTemplate()` and the widget calls it from its constructor.
      expect(src, contains('@override'));
      expect(src, contains('void initTemplate() {'));
      // … and the real GTK call still happens.
      expect(src, contains('super.initTemplate();'));
    });

    test('installs the template on the native class only once', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      // GTK stores the template on the native class and allows only
      // one per class, so the install is guarded.
      expect(src, contains("claimTemplateType(widgetType, 'Sample')"));
    });

    test('keeps a lazy fallback for a host that never calls initTemplate', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
        signals: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('void _ensureInstanceInit() {'));
      expect(src, contains('initTemplate();'));
    });

    test('emits per-instance connectSignal wiring for <signal> entries', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [TemplateChildSpec(id: 'button', typeName: 'GtkButton')],
        callbacks: [],
        signals: [
          SignalBinding(
            signalName: 'clicked',
            childId: 'button',
            childType: 'GtkButton',
            methodName: 'onClicked',
          ),
        ],
      );
      final src = codegenMixin(input);
      expect(src, contains('void _wireSignals()'));
      expect(
        src,
        contains("button.onClicked(() => (this as dynamic).onClicked())"),
      );
      // The wiring runs at the end of initTemplate(), after the
      // template has been built.
      expect(src, contains('super.initTemplate();'));
      expect(src, contains('_wireSignals();'));
    });
  });

  group('snakeCaseToCamel', () {
    test('converts snake_case to camelCase', () {
      expect(snakeCaseToCamel('on_clicked'), 'onClicked');
      expect(snakeCaseToCamel('button_clicked'), 'buttonClicked');
      expect(snakeCaseToCamel('hello'), 'hello');
      expect(snakeCaseToCamel(''), '');
      expect(snakeCaseToCamel('a_b_c'), 'aBC');
    });
  });

  group('extractSignalsFromXml', () {
    test('extracts a single signal with the right child info', () {
      const xml = '''
        <interface>
          <template class="Foo" parent="GtkBox">
            <object class="GtkButton" id="button">
              <signal name="clicked" handler="on_clicked"/>
            </object>
          </template>
        </interface>
      ''';
      final signals = extractSignalsFromXml(xml);
      expect(signals, hasLength(1));
      expect(signals[0].signalName, 'clicked');
      expect(signals[0].childId, 'button');
      expect(signals[0].childType, 'GtkButton');
      expect(signals[0].methodName, 'onClicked');
    });

    test('returns empty when there are no signals', () {
      const xml = '<interface><template class="Foo"/></interface>';
      expect(extractSignalsFromXml(xml), isEmpty);
    });
  });

  group('CodegenInput.fromPlan', () {
    test('maps plan fields and forward callbacks', () {
      final plan = ClassTemplatePlan(
        className: 'X',
        parentType: 'GtkBox',
        templateSource: const GtkTemplateXml('<interface/>'),
        children: const [
          WidgetBinding(fieldName: 'label', childName: 'counterLabel'),
        ],
        callbacks: const [
          CallbackBinding(methodName: 'onClicked', callbackName: 'on_clicked'),
        ],
      );
      final input = CodegenInput.fromPlan(
        plan,
        xmlString: '<interface/>',
        xmlChildren: const [
          TemplateChildSpec(id: 'counterLabel', typeName: 'GtkLabel'),
        ],
        xmlSignals: const [],
        partOfPath: 'x.dart',
      );
      expect(input.className, 'X');
      expect(input.parentType, 'GtkBox');
      expect(input.xmlString, '<interface/>');
      expect(input.children.single.id, 'counterLabel');
      expect(input.children.single.typeName, 'GtkLabel');
      expect(input.callbacks.single.callbackName, 'on_clicked');
      expect(input.callbacks.single.methodName, 'onClicked');
    });
  });
}
