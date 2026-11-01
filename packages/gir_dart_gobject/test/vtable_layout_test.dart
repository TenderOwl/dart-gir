// The ABI tables of `GObjectClass` and `GtkWidgetClass`, cross-checked
// against the installed headers.
//
// The vtable slot offsets cannot be derived from the introspection data:
// the GIR lists a class's virtual methods alphabetically, while the C
// class struct declares them in the order the vtable uses. The offsets
// in `GObjectVtable` and `GtkWidgetVtable` are therefore hand-authored
// — and a hand-authored offset that does not match the header is a
// crash waiting to happen.
//
// This test reads the installed headers and checks the offsets against
// them. It skips when a header is not installed, so the suite still
// runs on a machine without the development headers.

import 'dart:io';

import 'package:gir_dart_gobject/gir_dart_gobject.dart';
import 'package:test/test.dart';

const _gobjectHeader = '/usr/include/glib-2.0/gobject/gobject.h';
const _gtkHeader = '/usr/include/gtk-4.0/gtk/gtkwidget.h';

/// The size of a pointer on the platform the bindings target.
const _pointerBytes = 8;

/// The body of the struct that starts at [marker] in [source].
String _structBody(String source, String marker) {
  final start = source.indexOf(marker);
  expect(start, isNonNegative, reason: 'the header has no `$marker`');
  final end = source.indexOf('};', start);
  expect(end, isNonNegative, reason: 'the header has no end of `$marker`');
  return source.substring(start, end);
}

/// The names of the function-pointer members of a struct body, in
/// declaration order.
List<String> _slots(String body) =>
    RegExp(r'\(\s*\*\s*(\w+)\s*\)')
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();

/// The size of a struct body, in bytes.
///
/// Every member of the class structs is pointer-sized — a pointer, a
/// `gsize`, a `GType`, or the parent class struct — so the size is the
/// number of members times the size of a pointer. The array member
/// counts once per element.
int _structSize(String body) {
  var words = 0;
  final cleaned = body.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  for (final declaration in cleaned.split(';')) {
    final trimmed = declaration.trim();
    if (trimmed.isEmpty) continue;
    final array = RegExp(r'\[\s*(\d+)\s*\]').firstMatch(trimmed);
    if (array != null) {
      words += int.parse(array.group(1)!);
      continue;
    }
    words += 1;
  }
  return words * _pointerBytes;
}

void main() {
  test('the vtable offsets match the installed GObjectClass', () {
    if (!File(_gobjectHeader).existsSync()) {
      markTestSkipped('the GLib headers are not installed');
      return;
    }
    final source = File(_gobjectHeader).readAsStringSync();

    // The fields of `struct _GObjectClass`, in declaration order. The
    // vtable starts after `g_type_class` (one `GType`) and
    // `construct_properties` (one pointer).
    final body = _structBody(source, 'struct  _GObjectClass');

    final slots = _slots(body);
    expect(
      slots,
      containsAll(<String>[
        'constructor',
        'set_property',
        'get_property',
        'dispose',
        'finalize',
        'dispatch_properties_changed',
        'notify',
        'constructed',
      ]),
      reason: 'the header no longer declares the slots the table names',
    );

    // Every slot before the first function pointer is one pointer wide.
    const headerBytes = 8; // GTypeClass { GType g_type; }
    const pointerBytes = 8; // GSList *construct_properties;

    int offsetOf(String name) {
      final index = slots.indexOf(name);
      expect(index, isNonNegative, reason: 'the header has no `$name` slot');
      return headerBytes + pointerBytes + index * pointerBytes;
    }

    expect(GObjectVtable.constructor, offsetOf('constructor'));
    expect(GObjectVtable.setProperty, offsetOf('set_property'));
    expect(GObjectVtable.getProperty, offsetOf('get_property'));
    expect(GObjectVtable.dispose, offsetOf('dispose'));
    expect(GObjectVtable.finalize, offsetOf('finalize'));
    expect(
      GObjectVtable.dispatchPropertiesChanged,
      offsetOf('dispatch_properties_changed'),
    );
    expect(GObjectVtable.notify, offsetOf('notify'));
    expect(GObjectVtable.constructed, offsetOf('constructed'));
  });

  test('the vtable offsets match the installed GtkWidgetClass', () {
    if (!File(_gobjectHeader).existsSync() || !File(_gtkHeader).existsSync()) {
      markTestSkipped('the GLib or the GTK headers are not installed');
      return;
    }
    final gobjectSource = File(_gobjectHeader).readAsStringSync();
    final gtkSource = File(_gtkHeader).readAsStringSync();

    // `GtkWidgetClass` continues the parent class struct directly, so its
    // first slot sits at the size of `GInitiallyUnownedClass` — which
    // holds a `GObjectClass` and nothing else.
    final gobjectSize = _structSize(
      _structBody(gobjectSource, 'struct  _GObjectClass'),
    );

    // The header declares the struct twice — once in the typedef, once
    // in the definition. The definition is the one with the body.
    final body = _structBody(gtkSource, 'struct _GtkWidgetClass\n{');
    final slots = _slots(body);
    expect(
      slots,
      containsAll(<String>[
        'show',
        'hide',
        'map',
        'unmap',
        'realize',
        'unrealize',
        'root',
        'unroot',
        'size_allocate',
        'state_flags_changed',
        'direction_changed',
        'get_request_mode',
        'measure',
        'mnemonic_activate',
        'grab_focus',
        'focus',
        'set_focus_child',
        'move_focus',
        'keynav_failed',
        'query_tooltip',
        'compute_expand',
        'css_changed',
        'system_setting_changed',
        'snapshot',
        'contains',
      ]),
      reason: 'the header no longer declares the slots the table names',
    );

    int offsetOf(String name) {
      final index = slots.indexOf(name);
      expect(index, isNonNegative, reason: 'the header has no `$name` slot');
      return gobjectSize + index * _pointerBytes;
    }

    expect(GtkWidgetVtable.show, offsetOf('show'));
    expect(GtkWidgetVtable.hide, offsetOf('hide'));
    expect(GtkWidgetVtable.map, offsetOf('map'));
    expect(GtkWidgetVtable.unmap, offsetOf('unmap'));
    expect(GtkWidgetVtable.realize, offsetOf('realize'));
    expect(GtkWidgetVtable.unrealize, offsetOf('unrealize'));
    expect(GtkWidgetVtable.root, offsetOf('root'));
    expect(GtkWidgetVtable.unroot, offsetOf('unroot'));
    expect(GtkWidgetVtable.sizeAllocate, offsetOf('size_allocate'));
    expect(GtkWidgetVtable.stateFlagsChanged, offsetOf('state_flags_changed'));
    expect(GtkWidgetVtable.directionChanged, offsetOf('direction_changed'));
    expect(GtkWidgetVtable.getRequestMode, offsetOf('get_request_mode'));
    expect(GtkWidgetVtable.measure, offsetOf('measure'));
    expect(GtkWidgetVtable.mnemonicActivate, offsetOf('mnemonic_activate'));
    expect(GtkWidgetVtable.grabFocus, offsetOf('grab_focus'));
    expect(GtkWidgetVtable.focus, offsetOf('focus'));
    expect(GtkWidgetVtable.setFocusChild, offsetOf('set_focus_child'));
    expect(GtkWidgetVtable.moveFocus, offsetOf('move_focus'));
    expect(GtkWidgetVtable.keynavFailed, offsetOf('keynav_failed'));
    expect(GtkWidgetVtable.queryTooltip, offsetOf('query_tooltip'));
    expect(GtkWidgetVtable.computeExpand, offsetOf('compute_expand'));
    expect(GtkWidgetVtable.cssChanged, offsetOf('css_changed'));
    expect(
      GtkWidgetVtable.systemSettingChanged,
      offsetOf('system_setting_changed'),
    );
    expect(GtkWidgetVtable.snapshot, offsetOf('snapshot'));
    expect(GtkWidgetVtable.contains, offsetOf('contains'));
  });
}
