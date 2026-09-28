import 'package:gir_generator/src/gir/gir.dart';
import 'package:test/test.dart';

const String _header = '''
<repository version="1.2"
    xmlns="http://www.gtk.org/introspection/core/1.0"
    xmlns:c="http://www.gtk.org/introspection/c/1.0"
    xmlns:glib="http://www.gtk.org/introspection/glib/1.0">
  <include name="GObject" version="2.0"/>
''';

const String _footer = '</repository>';

String gir(String namespaceBody) => '''
$_header
  <namespace name="Test" version="1.0"
      shared-library="libtest-1.0.so.0,libtest-extra.so.0"
      c:identifier-prefixes="Test"
      c:symbol-prefixes="test">
$namespaceBody
  </namespace>
$_footer
''';

void main() {
  late GirParser parser;

  setUp(() => parser = GirParser());

  group('repository/namespace', () {
    test('parses namespace attributes and includes', () {
      final repo = parser.parse(gir(''));
      expect(repo.includes, hasLength(1));
      expect(repo.includes.single.name, 'GObject');
      expect(repo.includes.single.version, '2.0');
      expect(repo.namespace.name, 'Test');
      expect(repo.namespace.version, '1.0');
      expect(repo.namespace.sharedLibraries,
          ['libtest-1.0.so.0', 'libtest-extra.so.0']);
      expect(repo.namespace.cIdentifierPrefixes, ['Test']);
      expect(repo.namespace.cSymbolPrefixes, ['test']);
    });
  });

  group('class', () {
    test('with method, property, signal, parent, implements', () {
      final repo = parser.parse(gir('''
    <class name="Button" c:type="GtkButton" parent="Widget"
        glib:type-name="GtkButton" glib:get-value-func="gtk_button_get_value">
      <doc>A button widget.</doc>
      <implements name="Gtk.Actionable"/>
      <constructor name="new" c:identifier="gtk_button_new">
        <return-value transfer-ownership="full">
          <type name="Button" c:type="GtkButton*"/>
        </return-value>
      </constructor>
      <method name="set_label" c:identifier="gtk_button_set_label" version="4.0">
        <doc>Sets the label.</doc>
        <return-value transfer-ownership="none">
          <type name="none" c:type="void"/>
        </return-value>
        <parameters>
          <instance-parameter name="self" transfer-ownership="none">
            <type name="Button" c:type="GtkButton*"/>
          </instance-parameter>
          <parameter name="label" transfer-ownership="none" nullable="1">
            <type name="utf8" c:type="const gchar*"/>
          </parameter>
        </parameters>
      </method>
      <property name="label" writable="1">
        <type name="utf8" c:type="gchar*"/>
      </property>
      <glib:signal name="clicked">
        <return-value transfer-ownership="none">
          <type name="none" c:type="void"/>
        </return-value>
      </glib:signal>
      <field name="priv"><type name="gint" c:type="gint"/></field>
    </class>
'''));

      final cls = repo.namespace.classes.single;
      expect(cls.name, 'Button');
      expect(cls.cType, 'GtkButton');
      expect(cls.parent, 'Widget');
      expect(cls.glibTypeName, 'GtkButton');
      expect(cls.glibGetValueFunc, 'gtk_button_get_value');
      expect(cls.doc, 'A button widget.');
      expect(cls.implements_, ['Gtk.Actionable']);

      expect(cls.constructors.single.name, 'new');
      expect(cls.constructors.single.cIdentifier, 'gtk_button_new');
      expect(cls.constructors.single.returnTransfer, GirTransferOwnership.full);

      final method = cls.methods.single;
      expect(method.name, 'set_label');
      expect(method.cIdentifier, 'gtk_button_set_label');
      expect(method.version, '4.0');
      expect(method.doc, 'Sets the label.');
      expect(method.instanceParameter, isNotNull);
      expect(method.instanceParameter!.name, 'self');
      expect(method.parameters.single.name, 'label');
      expect(method.parameters.single.nullable, isTrue);
      expect(method.parameters.single.type!.name, 'utf8');
      expect(method.parameters.single.type!.cType, 'const gchar*');

      final prop = cls.properties.single;
      expect(prop.name, 'label');
      expect(prop.writable, isTrue);
      expect(prop.readable, isTrue);

      final signal = cls.signals.single;
      expect(signal.name, 'clicked');
      expect(signal.returnType!.name, 'none');

      expect(cls.fields.single.name, 'priv');
      expect(cls.fields.single.type!.name, 'gint');
    });

    test('abstract, final and virtual-method flags', () {
      final repo = parser.parse(gir('''
    <class name="Base" c:type="TestBase" abstract="1" final="0">
      <virtual-method name="do_thing">
        <return-value><type name="none" c:type="void"/></return-value>
      </virtual-method>
    </class>
'''));
      final cls = repo.namespace.classes.single;
      expect(cls.abstract, isTrue);
      expect(cls.final_, isFalse);
      expect(cls.virtualMethods.single.name, 'do_thing');
    });
  });

  group('enum and bitfield', () {
    test('enumeration with members', () {
      final repo = parser.parse(gir('''
    <enumeration name="Align" c:type="TestAlign" glib:type-name="TestAlign">
      <member name="start" value="0" c:identifier="TEST_ALIGN_START"/>
      <member name="end" value="1" c:identifier="TEST_ALIGN_END"/>
      <member name="big" value="4294967295" c:identifier="TEST_ALIGN_BIG"/>
      <member name="neg" value="-1" c:identifier="TEST_ALIGN_NEG"/>
    </enumeration>
'''));
      final en = repo.namespace.enumerations.single;
      expect(en.name, 'Align');
      expect(en.members, hasLength(4));
      expect(en.members[0].name, 'start');
      expect(en.members[0].value, 0);
      expect(en.members[0].cIdentifier, 'TEST_ALIGN_START');
      expect(en.members[2].value, 4294967295);
      expect(en.members[3].value, -1);
    });

    test('bitfield', () {
      final repo = parser.parse(gir('''
    <bitfield name="Flags" c:type="TestFlags">
      <member name="a" value="1" c:identifier="TEST_FLAGS_A"/>
      <member name="b" value="2" c:identifier="TEST_FLAGS_B"/>
    </bitfield>
'''));
      final bf = repo.namespace.bitfields.single;
      expect(bf, isA<GirBitfield>());
      expect(bf.members.map((m) => m.value), [1, 2]);
    });
  });

  group('callback', () {
    test('callback with return type and parameters', () {
      final repo = parser.parse(gir('''
    <callback name="Func" c:type="TestFunc">
      <doc>Called for each item.</doc>
      <return-value transfer-ownership="none" nullable="1">
        <type name="utf8" c:type="gchar*"/>
      </return-value>
      <parameters>
        <parameter name="item" transfer-ownership="none">
          <type name="utf8" c:type="const gchar*"/>
        </parameter>
        <parameter name="user_data" transfer-ownership="none">
          <type name="gpointer" c:type="gpointer"/>
        </parameter>
      </parameters>
    </callback>
'''));
      final cb = repo.namespace.callbacks.single;
      expect(cb.name, 'Func');
      expect(cb.cType, 'TestFunc');
      expect(cb.returnType!.name, 'utf8');
      expect(cb.returnNullable, isTrue);
      expect(cb.parameters, hasLength(2));
      expect(cb.parameters[1].name, 'user_data');
      expect(cb.doc, 'Called for each item.');
    });
  });

  group('record', () {
    test('record with array field', () {
      final repo = parser.parse(gir('''
    <record name="Item" c:type="TestItem" glib:type-name="TestItem">
      <field name="count"><type name="gint" c:type="gint"/></field>
      <field name="names">
        <array c:type="gchar**" zero-terminated="1" length="0">
          <type name="utf8" c:type="gchar*"/>
        </array>
      </field>
      <method name="get_count" c:identifier="test_item_get_count">
        <return-value><type name="gint" c:type="gint"/></return-value>
      </method>
    </record>
'''));
      final rec = repo.namespace.records.single;
      expect(rec.name, 'Item');
      expect(rec.isBoxed, isTrue);
      expect(rec.fields, hasLength(2));
      final names = rec.fields[1];
      expect(names.name, 'names');
      expect(names.type!.isArray, isTrue);
      expect(names.type!.cType, 'gchar**');
      expect(names.type!.array!.zeroTerminated, isTrue);
      expect(names.type!.array!.lengthParameterIndex, 0);
      expect(names.type!.array!.elementType.name, 'utf8');
      expect(rec.methods.single.cIdentifier, 'test_item_get_count');
    });
  });

  group('function', () {
    test('out parameter, throws, deprecated', () {
      final repo = parser.parse(gir('''
    <function name="parse" c:identifier="test_parse" throws="1" deprecated="1" version="2.0">
      <return-value transfer-ownership="none">
        <type name="gboolean" c:type="gboolean"/>
      </return-value>
      <parameters>
        <parameter name="text" transfer-ownership="none">
          <type name="utf8" c:type="const gchar*"/>
        </parameter>
        <parameter name="result" direction="out" caller-allocates="1" transfer-ownership="full">
          <type name="gint" c:type="gint*"/>
        </parameter>
      </parameters>
    </function>
'''));
      final fn = repo.namespace.functions.single;
      expect(fn.throws, isTrue);
      expect(fn.deprecated, isTrue);
      expect(fn.version, '2.0');
      expect(fn.returnType!.name, 'gboolean');
      final out = fn.parameters[1];
      expect(out.direction, GirParameterDirection.out);
      expect(out.callerAllocates, isTrue);
      expect(out.transferOwnership, GirTransferOwnership.full);
    });

    test('varargs is kept and marked', () {
      final repo = parser.parse(gir('''
    <function name="log" c:identifier="test_log">
      <return-value><type name="none" c:type="void"/></return-value>
      <parameters>
        <parameter name="fmt" transfer-ownership="none">
          <type name="utf8" c:type="const gchar*"/>
        </parameter>
        <varargs/>
      </parameters>
    </function>
'''));
      final fn = repo.namespace.functions.single;
      expect(fn.isVarargs, isTrue);
      expect(fn.parameters.last.isVarargs, isTrue);
    });

    test('shadows / shadowed-by kept as raw strings', () {
      final repo = parser.parse(gir('''
    <function name="get" c:identifier="test_get" shadowed-by="get_full">
      <return-value><type name="gint" c:type="gint"/></return-value>
    </function>
    <function name="get_full" c:identifier="test_get_full" shadows="get">
      <return-value><type name="gint" c:type="gint"/></return-value>
    </function>
'''));
      expect(repo.namespace.functions[0].shadowedBy, 'get_full');
      expect(repo.namespace.functions[1].shadows, 'get');
    });
  });

  group('filtering and attributes', () {
    test('introspectable="0" elements are skipped', () {
      final repo = parser.parse(gir('''
    <function name="hidden" c:identifier="test_hidden" introspectable="0">
      <return-value><type name="none" c:type="void"/></return-value>
    </function>
    <function name="visible" c:identifier="test_visible">
      <return-value><type name="none" c:type="void"/></return-value>
    </function>
    <class name="HiddenClass" c:type="TestHiddenClass" introspectable="0"/>
'''));
      expect(repo.namespace.functions.map((f) => f.name), ['visible']);
      expect(repo.namespace.classes, isEmpty);
    });

    test('transfer-ownership container; nullable="true"', () {
      final repo = parser.parse(gir('''
    <function name="list" c:identifier="test_list">
      <return-value transfer-ownership="container">
        <type name="GLib.List" c:type="GList*"/>
      </return-value>
      <parameters>
        <parameter name="fallback" nullable="true" optional="1">
          <type name="utf8" c:type="const gchar*"/>
        </parameter>
      </parameters>
    </function>
'''));
      final fn = repo.namespace.functions.single;
      expect(fn.returnTransfer, GirTransferOwnership.container);
      expect(fn.parameters.single.nullable, isTrue);
      expect(fn.parameters.single.optional, isTrue);
    });
  });

  group('misc declarations', () {
    test('alias and constant', () {
      final repo = parser.parse(gir('''
    <alias name="MyInt" c:type="TestMyInt">
      <type name="gint" c:type="gint"/>
    </alias>
    <constant name="MAX" value="42" c:type="TEST_MAX">
      <type name="gint" c:type="gint"/>
    </constant>
'''));
      final alias = repo.namespace.aliases.single;
      expect(alias.name, 'MyInt');
      expect(alias.cType, 'TestMyInt');
      expect(alias.target.name, 'gint');
      final c = repo.namespace.constants.single;
      expect(c.name, 'MAX');
      expect(c.value, '42');
      expect(c.cType, 'TEST_MAX');
    });

    test('interface and union', () {
      final repo = parser.parse(gir('''
    <interface name="Iface" c:type="TestIface" glib:type-name="TestIface">
      <method name="act" c:identifier="test_iface_act">
        <return-value><type name="none" c:type="void"/></return-value>
        <parameters>
          <instance-parameter name="self"><type name="Iface" c:type="TestIface*"/></instance-parameter>
        </parameters>
      </method>
      <property name="enabled"><type name="gboolean" c:type="gboolean"/></property>
    </interface>
    <union name="Value" c:type="TestValue">
      <field name="i"><type name="gint" c:type="gint"/></field>
      <field name="d"><type name="gdouble" c:type="gdouble"/></field>
    </union>
'''));
      final iface = repo.namespace.interfaces.single;
      expect(iface.methods.single.instanceParameter!.name, 'self');
      expect(iface.properties.single.name, 'enabled');
      final union = repo.namespace.unions.single;
      expect(union.fields.map((f) => f.name), ['i', 'd']);
    });
  });
}
