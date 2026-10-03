/// Runtime helpers used by the generated `bind<Name>Template()`
/// function and per-`_getChild_<field>` helpers emitted by the
/// `gtk_templates_builder` builder.
///
/// The surface here is intentionally minimal: only what the generated
/// code calls into. End-user code should never import from `src/`.
library;

import 'dart:ffi' as ffi;

import 'package:gir_ffi/gir_ffi.dart' show gtkWidgetGetTemplateChild;
import 'package:gtk4/gtk4.dart';
import 'package:gobject/gobject.dart' show typeFromName;

// Re-export the FFI primitives the generated `bind<Name>Template()`
// calls into. Without these `export`s, the part file would have to
// fall back to raw FFI or the user would have to add
// `import 'package:gir_ffi/gir_ffi.dart';` to their main source —
// which is exactly what this layer exists to hide. Re-exporting via
// `show` keeps the public surface intentional: only the symbols the
// generated code needs are visible.
export 'package:gir_ffi/gir_ffi.dart'
    show
        adwApplicationWindowGetType,
        gTypeCheckClassCast,
        gTypeClassRef,
        gTypeClassUnref,
        gTypeRegisterStaticSimple,
        gObjectNew,
        gObjectNewWithProperty,
        gtkApplicationWindowGetType,
        gtkWidgetClassBindTemplateCallbackFull;

/// Process-global registry of pinned `NativeCallable` trampolines used
/// by `@TemplateCallback`-annotated methods.
///
/// `NativeCallable` instances must outlive the template they're wired
/// into — i.e. they must outlive the running program. The generated
/// `bind<Name>Template()` registers each trampoline here and never
/// closes it; mirroring how `g_idle_add_full` is used in
/// `example/bin/example.dart`.
///
/// The registry is currently write-only: the generated bind function
/// calls [registerTemplateCallback] but no consumer reads
/// [lookupTemplateCallback]. The map is kept around for future
/// introspection tools (e.g., a debug build that prints the
/// registered signals per class).
final Map<String, ffi.NativeCallable<Function>> _callbackRegistry = {};

/// Registers [callable] for [signalName] on the widget class identified
/// by [gtype]. The key is `${gtype}:${signalName}` — multiple unrelated
/// classes that bind to the same signal name don't collide because their
/// GTypes differ.
///
/// Called from the generated `bind<Name>Template()`; not intended for
/// direct user use.
void registerTemplateCallback(
  int gtype,
  String signalName,
  ffi.NativeCallable<Function> callable,
) {
  _callbackRegistry['$gtype:$signalName'] = callable;
}

/// Fetches the pinned [NativeCallable] for [gtype]/[signalName], or
/// `null` if no callback is registered. Currently unused by the
/// generated code (the C side retains its own reference after
/// `bind_template_callback_full`); kept for introspection tools.
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

/// Returns the GType for [name], or throws a `StateError` if the type
/// isn't registered.
///
/// Used by the generated `bind<Name>Template()` as the fallback path
/// for parents that aren't in the emitter's hand-binding whitelist
/// (see `kHandBoundGetTypeCalls` in `gtk_templates_builder`'s
/// `emitter.dart`). The caller is expected to have already ensured
/// the parent type is registered (by constructing a parent instance,
/// for example); this helper just surfaces a clear error message
/// when they forgot.
int ensureTypeRegistered(String name) {
  final type = typeFromName(name);
  if (type == 0) {
    throw StateError(
      'GtkTemplate parent type "$name" is not registered. '
      'Construct a parent instance (or call its `_get_type()` '
      'function) before `bind<Name>Template()`, or add the parent '
      'class to the gtk_templates parent whitelist by exposing a '
      '`<name>_get_type()` hand binding in `package:gir_ffi`.',
    );
  }
  return type;
}

/// Returns the current widget's `GType` (used by generated code that
/// needs to re-resolve `runtimeType` to a GType after the first
/// `typeRegisterStatic` call). When [name] is already registered,
/// the second call returns the same GType as the first — so two
/// `TodoWindow` instances share one GType.
int resolveTemplateGtype(String name) {
  final existing = typeFromName(name);
  if (existing != 0) return existing;
  // The first call into the generated `bind<Name>Template()` will
  // have already registered the type via `gobject.typeRegisterStatic`
  // before calling `resolveTemplateGtype` from a helper. If somehow
  // this is reached with the type unregistered, throw — the user
  // forgot to call `bind<Name>Template()` from their constructor.
  throw StateError(
    'GtkTemplate type "$name" is not registered. '
    'Did you forget to call bind<Name>Template() from your '
    'constructor before initTemplate()?',
  );
}