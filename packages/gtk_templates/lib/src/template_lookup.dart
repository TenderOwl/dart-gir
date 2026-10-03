/// Runtime helpers used by the generated `_$<Class>BindTemplate()`
/// methods emitted by the `gtk_templates_builder` builder.
///
/// The surface here is intentionally minimal: only what the generated
/// code calls into. End-user code should never import from `src/`.
library;

import 'dart:ffi' as ffi;

import 'package:gir_ffi/gir_ffi.dart' show gtkWidgetGetTemplateChild;
import 'package:gtk4/gtk4.dart';
import 'package:gobject/gobject.dart';

/// Process-global registry of pinned `NativeCallable` trampolines used
/// by `@TemplateCallback`-annotated methods.
///
/// `NativeCallable` instances must outlive the template they're wired
/// into — i.e. they must outlive the running program. The generated
/// `_$<Class>BindTemplate()` registers each trampoline here and never
/// closes it; mirroring how `g_idle_add_full` is used in
/// `example/bin/example.dart`.
final Map<String, ffi.NativeCallable<Function>> _callbackRegistry = {};

/// Registers [callable] for [signalName] on the widget class identified
/// by [gtype]. The key is `${gtype}:${signalName}` — multiple unrelated
/// classes that bind to the same signal name don't collide because their
/// GTypes differ.
///
/// Called from the generated `_$<Class>BindTemplate()`; not intended for
/// direct user use.
void registerTemplateCallback(
  int gtype,
  String signalName,
  ffi.NativeCallable<Function> callable,
) {
  _callbackRegistry['$gtype:$signalName'] = callable;
}

/// Fetches the pinned [NativeCallable] for [gtype]/[signalName], or
/// `null` if no callback is registered. The widget-class binding uses
/// this so the trampoline's C-side function pointer can be looked up
/// at `bind_template_callback_full` time.
ffi.NativeCallable<Function>? lookupTemplateCallback(
  int gtype,
  String signalName,
) {
  return _callbackRegistry['$gtype:$signalName'];
}

/// Fetches a named child widget from [handle]'s loaded template, typed
/// via the per-element helper [fromPointer].
///
/// The generated `_getChild_<fieldName>` function (emitted by the
/// builder for each `@TemplateChild()` field) calls this with the right
/// `T.fromPointer` constructor for [T].
///
/// [handle] is the widget's `ffi.Pointer<ffi.Void>`. [gtype] is the
/// GType the template was loaded against (returned from
/// `gobject.typeFromName`). [name] is the id from the
/// `<object id="...">` element.
///
/// Returns `null` if no child with that id exists in the template —
/// which surfaces as a `LateInitializationError` if the user's
/// `late` field assumes non-null.
T? getTemplateChild<T extends GtkWidget>(
  ffi.Pointer<ffi.Void> handle,
  int gtype,
  String name,
  T Function(ffi.Pointer<ffi.Void>) fromPointer,
) {
  // The generator emits `GtkWidget.getTemplateChild` with the first
  // two parameter types swapped (Pointer<Void>, Size) instead of the
  // C-canonical (GType, GtkWidget*). That signature mismatch causes
  // FFI to read garbage and either hang or return `nullptr`. Use the
  // hand-rolled binding from `package:gir_ffi` which honours the
  // real C signature `gtk_widget_get_template_child(GType, GtkWidget*,
  // const gchar*)`.
  final raw = gtkWidgetGetTemplateChild(gtype, handle, name);
  if (raw == ffi.nullptr) return null;
  return fromPointer(raw);
}

/// Returns the current widget's `GType` (used by generated code that
/// needs to re-resolve `runtimeType` to a GType after the first
/// `typeRegisterStatic` call). When [name] is already registered,
/// the second call returns the same GType as the first — so two
/// `TodoWindow` instances share one GType.
int resolveTemplateGtype(String name) {
  final existing = typeFromName(name);
  if (existing != 0) return existing;
  // The first call into the generated `_$<Class>BindTemplate()` will
  // have already registered the type via `gobject.typeRegisterStatic`
  // before calling `resolveTemplateGtype` from a helper. If somehow
  // this is reached with the type unregistered, throw — the user
  // forgot to call `_$<Class>BindTemplate()` from their constructor.
  throw StateError(
    'GtkTemplate type "$name" is not registered. '
    'Did you forget to call _\$${name}BindTemplate() from your '
    'constructor before initTemplate()?',
  );
}