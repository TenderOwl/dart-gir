import 'package:gir_generator/src/resolve/naming.dart';
import 'package:test/test.dart';

void main() {
  group('toLowerCamel', () {
    test('snake_case', () {
      expect(toLowerCamel('set_label'), 'setLabel');
      expect(toLowerCamel('get_default_value'), 'getDefaultValue');
    });

    test('kebab-case', () {
      expect(toLowerCamel('gtk-button'), 'gtkButton');
    });

    test('ALL_CAPS', () {
      expect(toLowerCamel('GTK_ALIGN_FILL'), 'gtkAlignFill');
      expect(toLowerCamel('G_FILE_TEST_EXISTS'), 'gFileTestExists');
    });

    test('existing camelCase is preserved', () {
      expect(toLowerCamel('alreadyCamel'), 'alreadyCamel');
      expect(toLowerCamel('widget'), 'widget');
    });

    test('internal digits are preserved', () {
      expect(toLowerCamel('h264_decoder'), 'h264Decoder');
      expect(toLowerCamel('base64_encode'), 'base64Encode');
    });
  });

  group('toUpperCamel', () {
    test('snake_case', () {
      expect(toUpperCamel('button_box'), 'ButtonBox');
    });

    test('ALL_CAPS', () {
      expect(toUpperCamel('GTK_BUTTON'), 'GtkButton');
    });

    test('existing UpperCamel stays stable', () {
      expect(toUpperCamel('GtkButton'), 'GtkButton');
    });

    test('digits preserved', () {
      expect(toUpperCamel('utf8_string'), 'Utf8String');
    });
  });

  group('enumValueName', () {
    test('strips the type prefix', () {
      expect(enumValueName('GTK_ALIGN_FILL', typePrefix: 'GTK_ALIGN'), 'fill');
      expect(enumValueName('G_FILE_TEST_EXISTS', typePrefix: 'G_FILE_TEST'),
          'exists');
    });

    test('multi-word remainder is camelCased', () {
      expect(
          enumValueName('GTK_SORT_ASCENDING_ORDER', typePrefix: 'GTK_SORT'),
          'ascendingOrder');
    });

    test('member not sharing the prefix is converted as-is', () {
      expect(enumValueName('GDK_MOTION_NOTIFY', typePrefix: 'GDK_EVENT'),
          'gdkMotionNotify');
    });

    test('member equal to prefix alone falls back to full name', () {
      expect(enumValueName('GTK_ALIGN_', typePrefix: 'GTK_ALIGN'),
          'gtkAlign');
    });
  });

  group('escapeKeyword', () {
    test('reserved words get a trailing underscore', () {
      expect(escapeKeyword('in'), 'in_');
      expect(escapeKeyword('is'), 'is_');
      expect(escapeKeyword('default'), 'default_');
      expect(escapeKeyword('function'), 'function_');
      expect(escapeKeyword('new'), 'new_');
      expect(escapeKeyword('class'), 'class_');
      expect(escapeKeyword('dynamic'), 'dynamic_');
      expect(escapeKeyword('this'), 'this_');
      expect(escapeKeyword('true'), 'true_');
      expect(escapeKeyword('false'), 'false_');
      expect(escapeKeyword('null'), 'null_');
      expect(escapeKeyword('assert'), 'assert_');
      expect(escapeKeyword('enum'), 'enum_');
      expect(escapeKeyword('extends'), 'extends_');
      expect(escapeKeyword('with'), 'with_');
      expect(escapeKeyword('covariant'), 'covariant_');
      expect(escapeKeyword('required'), 'required_');
      expect(escapeKeyword('late'), 'late_');
      expect(escapeKeyword('static'), 'static_');
      expect(escapeKeyword('operator'), 'operator_');
    });

    test('names already ending with underscore are not doubled', () {
      expect(escapeKeyword('in_'), 'in_');
    });

    test('ordinary names pass through', () {
      expect(escapeKeyword('label'), 'label');
      expect(escapeKeyword('innerWidth'), 'innerWidth');
    });
  });

  group('dartFileName', () {
    test('simple type', () {
      expect(dartFileName('GtkButton'), 'gtk_button.dart');
      expect(dartFileName('Widget'), 'widget.dart');
    });

    test('acronym prefix', () {
      expect(dartFileName('GFileInputStream'), 'g_file_input_stream.dart');
      expect(dartFileName('GdkPixbuf'), 'gdk_pixbuf.dart');
    });
  });

  group('stripNsPrefix', () {
    test('strips matching prefix', () {
      expect(stripNsPrefix('GObject', ['G']), 'Object');
      expect(stripNsPrefix('GtkButton', ['Gtk']), 'Button');
    });

    test('leaves unmatched names unchanged', () {
      expect(stripNsPrefix('Widget', ['Gtk']), 'Widget');
    });

    test('never strips to empty', () {
      expect(stripNsPrefix('G', ['G']), 'G');
    });
  });
}
