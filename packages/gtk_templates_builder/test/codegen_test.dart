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
      expect(children.map((c) => c.typeName), ['GtkLabel', 'GtkButton', 'GtkBox']);
    });

    test('returns empty list when there are no objects', () {
      const xml = '<interface><template class="Foo"/></interface>';
      expect(extractChildrenFromXml(xml), isEmpty);
    });
  });

  group('codegenMixin', () {
    test('emits the mixin with the class name and parent type', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkApplicationWindow',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
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
      );
      final src = codegenMixin(input);
      expect(src, contains('late final GtkLabel counter = '));
      expect(src, contains('late final GtkButton button = '));
      expect(
        src,
        contains("typeFromName('GtkLabel'), 'counter'"),
      );
      expect(
        src,
        contains("typeFromName('GtkButton'), 'button'"),
      );
    });

    test('emits the children list and spec classes', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [TemplateChildSpec(id: 'a', typeName: 'GtkLabel')],
        callbacks: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('class _TemplateChildSpec'));
      expect(src, contains('class _TemplateCallbackSpec'));
      expect(
        src,
        contains(
          "const List<_TemplateChildSpec> _\$SampleTemplate_children = [",
        ),
      );
      expect(
        src,
        contains("_TemplateChildSpec('a', 'GtkLabel')"),
      );
    });

    test('emits the class-init idempotency guard', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('static bool _classInitialized = false'));
      expect(src, contains('_ensureClassInit'));
      expect(src, contains('gbytesFromString(_\$SampleTemplate_xml)'));
    });

    test('emits the per-instance init with getWidgetClass', () {
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [],
      );
      final src = codegenMixin(input);
      expect(src, contains('getWidgetClass(this as GtkWidget)'));
      expect(src, contains('widgetClass.setTemplate(_templateBytes)'));
      expect(src, contains('widgetClass.bindTemplateChildFull'));
      expect(src, contains('(this as GtkWidget).initTemplate()'));
    });

    test('emits the callbacks list with the user methods (first cut)', () {
      // The first cut captures callbacks but doesn't wire
      // them; the list is preserved for the follow-up.
      const input = CodegenInput(
        className: 'Sample',
        parentType: 'GtkBox',
        xmlString: '<interface/>',
        children: [],
        callbacks: [
          TemplateCallbackSpec(
            callbackName: 'on_clicked',
            methodName: 'onClicked',
          ),
        ],
      );
      final src = codegenMixin(input);
      expect(
        src,
        contains(
          "const List<_TemplateCallbackSpec> _\$SampleTemplate_callbacks = [",
        ),
      );
      expect(
        src,
        contains("_TemplateCallbackSpec('on_clicked', 'onClicked')"),
      );
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
          CallbackBinding(
            methodName: 'onClicked',
            callbackName: 'on_clicked',
          ),
        ],
      );
      final input = CodegenInput.fromPlan(
        plan,
        xmlString: '<interface/>',
        xmlChildren: const [
          TemplateChildSpec(id: 'counterLabel', typeName: 'GtkLabel'),
        ],
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
