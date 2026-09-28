import 'package:gir_generator/src/gir/gir.dart';
import 'package:gir_generator/src/resolve/types.dart';
import 'package:test/test.dart';

GirNamespace _glib() => GirNamespace(
      name: 'GLib',
      version: '2.0',
      cIdentifierPrefixes: ['G'],
      enumerations: [
        GirEnum(name: 'FileTest', cType: 'GFileTest'),
      ],
      bitfields: [
        GirBitfield(name: 'IOCondition', cType: 'GIOCondition'),
      ],
      records: [
        GirRecord(name: 'Error', cType: 'GError'),
      ],
    );

GirNamespace _gobject() => GirNamespace(
      name: 'GObject',
      version: '2.0',
      cIdentifierPrefixes: ['G'],
      classes: [
        GirClass(name: 'Object', cType: 'GObject'),
      ],
      interfaces: [
        GirInterface(name: 'TypePlugin', cType: 'GTypePlugin'),
      ],
    );

GirNamespace _gtk() => GirNamespace(
      name: 'Gtk',
      version: '4.0',
      cIdentifierPrefixes: ['Gtk'],
      classes: [
        GirClass(name: 'Widget', cType: 'GtkWidget', parent: 'GObject.Object'),
        GirClass(name: 'Button', cType: 'GtkButton', parent: 'Widget'),
      ],
      enumerations: [
        GirEnum(name: 'Align', cType: 'GtkAlign'),
      ],
      callbacks: [
        GirCallback(name: 'TickCallback', cType: 'GtkTickCallback'),
      ],
    );

void main() {
  late GirNamespace glib;
  late GirNamespace gobject;
  late GirNamespace gtk;
  late TypeResolver resolver;

  setUp(() {
    glib = _glib();
    gobject = _gobject();
    gtk = _gtk();
    resolver = TypeResolver([glib, gobject, gtk]);
  });

  group('built-in scalar table', () {
    TypeMapping resolveName(String name, [String? cType]) => resolver.resolve(
        GirTypeRef(name: name, cType: cType),
        currentNamespace: gtk);

    test('void / none', () {
      expect(resolveName('void').kind, TypeKind.voidType);
      expect(resolveName('void').dartType, 'void');
      expect(resolveName('void').nativeType, 'ffi.Void');
      expect(resolveName('none').kind, TypeKind.voidType);
    });

    test('gboolean is an Int32-backed bool', () {
      final m = resolveName('gboolean');
      expect(m.kind, TypeKind.boolean);
      expect(m.dartType, 'bool');
      expect(m.nativeType, 'ffi.Int32');
    });

    test('integer widths', () {
      expect(resolveName('gint').nativeType, 'ffi.Int32');
      expect(resolveName('guint').nativeType, 'ffi.Uint32');
      expect(resolveName('gint32').nativeType, 'ffi.Int32');
      expect(resolveName('guint32').nativeType, 'ffi.Uint32');
      expect(resolveName('gint64').nativeType, 'ffi.Int64');
      expect(resolveName('guint64').nativeType, 'ffi.Uint64');
      expect(resolveName('glong').nativeType, 'ffi.Long');
      expect(resolveName('gulong').nativeType, 'ffi.UnsignedLong');
      expect(resolveName('gshort').nativeType, 'ffi.Int16');
      expect(resolveName('gushort').nativeType, 'ffi.Uint16');
      expect(resolveName('gint16').nativeType, 'ffi.Int16');
      expect(resolveName('guint16').nativeType, 'ffi.Uint16');
      expect(resolveName('gintptr').nativeType, 'ffi.IntPtr');
      expect(resolveName('guintptr').nativeType, 'ffi.Size');
      expect(resolveName('gint8').nativeType, 'ffi.Int8');
      expect(resolveName('guint8').nativeType, 'ffi.Uint8');
      expect(resolveName('guchar').nativeType, 'ffi.Uint8');
      expect(resolveName('gchar').nativeType, 'ffi.Int8');
      expect(resolveName('gsize').nativeType, 'ffi.Size');
      expect(resolveName('gssize').nativeType, 'ffi.IntPtr');
      expect(resolveName('gint').dartType, 'int');
    });

    test('floating point', () {
      expect(resolveName('gfloat').nativeType, 'ffi.Float');
      expect(resolveName('gfloat').dartType, 'double');
      expect(resolveName('gdouble').nativeType, 'ffi.Double');
    });

    test('strings', () {
      for (final name in ['utf8', 'filename']) {
        final m = resolveName(name);
        expect(m.kind, TypeKind.string);
        expect(m.dartType, 'String');
        expect(m.isPointer, isTrue);
      }
    });

    test('opaque pointers', () {
      for (final name in ['gpointer', 'gconstpointer']) {
        final m = resolveName(name);
        expect(m.kind, TypeKind.pointer);
        expect(m.nativeType, 'Pointer<ffi.Void>');
        expect(m.isPointer, isTrue);
      }
    });

    test('gunichar and GType', () {
      expect(resolveName('gunichar').nativeType, 'ffi.Uint32');
      expect(resolveName('GType').nativeType, 'ffi.Size');
    });

    test('c:type fallback when GIR name is unknown', () {
      final m = resolver.resolve(const GirTypeRef(name: 'CustomInt', cType: 'gint'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.primitive);
      expect(m.nativeType, 'ffi.Int32');
    });

    test('c:type gchar* maps to string', () {
      final m = resolver.resolve(
          const GirTypeRef(cType: 'gchar*'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.string);
      expect(m.dartType, 'String');
    });
  });

  group('namespace resolution', () {
    test('same-namespace class', () {
      final m = resolver.resolve(const GirTypeRef(name: 'Widget'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.classType);
      expect(m.dartType, 'Widget');
      expect(m.requiredImport, isNull);
      expect(m.isPointer, isTrue);
    });

    test('qualified cross-namespace class carries requiredImport', () {
      final m = resolver.resolve(const GirTypeRef(name: 'GObject.Object'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.classType);
      expect(m.dartType, 'Object');
      expect(m.requiredImport, 'gobject');
    });

    test('unqualified name falls back to other namespaces', () {
      final m = resolver.resolve(const GirTypeRef(name: 'FileTest'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.enumeration);
      expect(m.dartType, 'FileTest');
      expect(m.requiredImport, 'glib');
    });

    test('current namespace wins over others for unqualified names', () {
      final m = resolver.resolve(const GirTypeRef(name: 'Align'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.enumeration);
      expect(m.requiredImport, isNull);
    });

    test('interface, record, bitfield, callback classification', () {
      expect(
          resolver
              .resolve(const GirTypeRef(name: 'GObject.TypePlugin'),
                  currentNamespace: gtk)
              .kind,
          TypeKind.interface);
      expect(
          resolver
              .resolve(const GirTypeRef(name: 'GLib.Error'),
                  currentNamespace: gtk)
              .kind,
          TypeKind.record);
      final bf = resolver.resolve(const GirTypeRef(name: 'GLib.IOCondition'),
          currentNamespace: gtk);
      expect(bf.kind, TypeKind.bitfield);
      expect(bf.nativeType, 'ffi.Uint32');
      final cb = resolver.resolve(const GirTypeRef(name: 'TickCallback'),
          currentNamespace: gtk);
      expect(cb.kind, TypeKind.callback);
      expect(cb.dartType, 'TickCallback');
    });

    test('dartTypeName returns the public name', () {
      expect(
          resolver.dartTypeName(const GirTypeRef(name: 'Gtk.Button'),
              currentNamespace: gtk),
          'Button');
      expect(
          resolver.dartTypeName(const GirTypeRef(name: 'gboolean'),
              currentNamespace: gtk),
          'bool');
    });
  });

  group('unsupported types never throw', () {
    test('unknown name', () {
      final m = resolver.resolve(const GirTypeRef(name: 'NoSuchType'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.unsupported);
      expect(m.reason, contains('NoSuchType'));
    });

    test('unknown qualified namespace', () {
      final m = resolver.resolve(const GirTypeRef(name: 'Foo.Bar'),
          currentNamespace: gtk);
      expect(m.kind, TypeKind.unsupported);
    });

    test('va_list and varargs', () {
      expect(
          resolver
              .resolve(const GirTypeRef(name: 'va_list'),
                  currentNamespace: gtk)
              .kind,
          TypeKind.unsupported);
      expect(
          resolver
              .resolve(const GirTypeRef(name: '...'), currentNamespace: gtk)
              .kind,
          TypeKind.unsupported);
    });

    test('arrays are deferred to a later phase', () {
      final m = resolver.resolve(
        const GirTypeRef(
          name: 'gint',
          array: GirArrayInfo(elementType: GirTypeRef(name: 'gint')),
        ),
        currentNamespace: gtk,
      );
      expect(m.kind, TypeKind.unsupported);
      expect(m.reason, contains('array'));
    });
  });

  group('packageNameFor', () {
    test('core stack explicit mapping', () {
      expect(packageNameFor(glib), 'glib');
      expect(packageNameFor(gobject), 'gobject');
      expect(packageNameFor(GirNamespace(name: 'Gio', version: '2.0')), 'gio');
      expect(packageNameFor(GirNamespace(name: 'GdkPixbuf', version: '2.0')),
          'gdk_pixbuf');
      expect(packageNameFor(GirNamespace(name: 'cairo', version: '1.0')),
          'cairo');
      expect(packageNameFor(GirNamespace(name: 'Pango', version: '1.0')),
          'pango');
      expect(packageNameFor(GirNamespace(name: 'Gdk', version: '4.0')),
          'gdk4');
      expect(packageNameFor(gtk), 'gtk4');
      expect(packageNameFor(GirNamespace(name: 'Adw', version: '1')), 'adw');
    });

    test('generic fallback appends major version', () {
      expect(packageNameFor(GirNamespace(name: 'Gst', version: '1.0')),
          'gst1');
      expect(packageNameFor(GirNamespace(name: 'Soup', version: '3.0')),
          'soup3');
      expect(packageNameFor(GirNamespace(name: 'MyLib', version: '')),
          'my_lib');
    });
  });
}
