// A template that lives on the Dart class's own native type.
//
// GTK keeps a template on the *native class* and allows exactly one per
// class. A Dart class without a type of its own shares its parent's — so
// two Dart classes with the same parent could not both have a template.
//
// A class that registers a type of its own gets a class of its own to put
// the template on. This suite pins that: two Dart classes, both deriving
// from `GtkBox`, each with a template of its own.
//
// The test mirrors what the builder's generated mixin does — the runtime
// helpers are the same ones the generated code calls.

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:gir_ffi/gir_ffi.dart';
import 'package:gir_gtk4/gir_gtk4.dart';
import 'package:gir_gtk_templates/gir_gtk_templates.dart';
import 'package:test/test.dart';

/// The suite needs a display: GTK cannot build a widget's template
/// without one.
final skip =
    (Platform.environment['DISPLAY'] ?? '').isEmpty &&
    (Platform.environment['WAYLAND_DISPLAY'] ?? '').isEmpty;

/// The first Dart class — a `GtkBox` with a type and a template of its
/// own.
class FirstBox extends GtkBox {
  static int get GType => registerDartType('FirstBox', GtkBox.GType);

  FirstBox() : super.rawFromPointer(newDartInstance(GType), owned: true);
}

/// The second Dart class — the same parent, the same shape, a different
/// template.
class SecondBox extends GtkBox {
  static int get GType => registerDartType('SecondBox', GtkBox.GType);

  SecondBox() : super.rawFromPointer(newDartInstance(GType), owned: true);
}

/// Installs [xml] on the type [ownType] and builds it on [widget].
///
/// This is what the builder's generated mixin does, step by step.
void installTemplate(
  GtkWidget widget,
  int ownType,
  String owner,
  String xml,
  List<String> children,
) {
  final widgetClass = getWidgetClass(widget);
  expect(widgetClass, isNotNull);

  if (claimTemplateType(ownType, owner)) {
    widgetClass!.setTemplate(
      gbytesFromString(prepareTemplateXml(xml, ownType)),
    );
    for (final child in children) {
      widgetClass.bindTemplateChildFull(child, false, 0);
    }
  }
  widget.initTemplate();
}

const String _firstXml =
    '<interface><template class="FirstBox" parent="GtkBox">'
    '<object class="GtkLabel" id="first_label"/>'
    '</template></interface>';

const String _secondXml =
    '<interface><template class="SecondBox" parent="GtkBox">'
    '<object class="GtkLabel" id="second_label"/>'
    '</template></interface>';

void main() {
  group('a template on the Dart class\'s own type', () {
    test('the instance belongs to the Dart class\'s own type', () {
      withInitializationLock(init);

      final box = FirstBox();

      expect(widgetTypeOf(box), FirstBox.GType);
      expect(widgetTypeOf(box), isNot(GtkBox.GType));

      box.unref();
    }, skip: skip);

    test('the template is built and its child is bound', () {
      withInitializationLock(init);

      final box = FirstBox();
      installTemplate(box, FirstBox.GType, 'FirstBox', _firstXml, [
        'first_label',
      ]);

      final child = box.getTemplateChild(FirstBox.GType, 'first_label');
      expect(child.handle, isNot(ffi.nullptr));
      expect(child.cast<GtkLabel>(GtkLabel.fromPointer), isA<GtkLabel>());

      // The child belongs to the type that declared it — the parent's
      // type does not hold it.
      expect(
        box.getTemplateChild(GtkBox.GType, 'first_label').handle,
        ffi.nullptr,
      );

      box.unref();
    }, skip: skip);

    test('two Dart classes with the same parent each have a template', () {
      withInitializationLock(init);

      final first = FirstBox();
      final second = SecondBox();

      installTemplate(first, FirstBox.GType, 'FirstBox', _firstXml, [
        'first_label',
      ]);
      installTemplate(second, SecondBox.GType, 'SecondBox', _secondXml, [
        'second_label',
      ]);

      // Each widget finds *its own* child, and not the other's.
      expect(
        first.getTemplateChild(FirstBox.GType, 'first_label').handle,
        isNot(ffi.nullptr),
      );
      expect(
        first.getTemplateChild(FirstBox.GType, 'second_label').handle,
        ffi.nullptr,
      );
      expect(
        second.getTemplateChild(SecondBox.GType, 'second_label').handle,
        isNot(ffi.nullptr),
      );
      expect(
        second.getTemplateChild(SecondBox.GType, 'first_label').handle,
        ffi.nullptr,
      );

      first.unref();
      second.unref();
    }, skip: skip);
  });

  group('requireOwnType', () {
    test('a widget of the right type is accepted', () {
      withInitializationLock(init);

      final box = FirstBox();
      expect(
        () => requireOwnType(box, FirstBox.GType, 'FirstBox'),
        returnsNormally,
      );

      box.unref();
    }, skip: skip);

    test('a widget of the wrong type is refused, and says why', () {
      withInitializationLock(init);

      // A widget created through the parent's constructor is an
      // instance of the *parent's* type — the template would land on
      // the parent's class, where another Dart class may already have
      // put one.
      final plain = GtkBox(GtkOrientation.horizontal, 0);

      expect(
        () => requireOwnType(plain, FirstBox.GType, 'FirstBox'),
        throwsA(
          isA<StateError>()
              .having(
                (e) => e.message,
                'message',
                contains('`FirstBox` was created as `GtkBox`'),
              )
              .having((e) => e.message, 'message', contains('newDartInstance')),
        ),
      );

      plain.unref();
    }, skip: skip);
  });
}
