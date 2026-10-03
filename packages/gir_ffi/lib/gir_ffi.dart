import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Loads the first available library from [names].
///
/// Falls back to the current process when none can be opened (symbols may
/// already be loaded globally).
DynamicLibrary openLibrary(List<String> names) {
  for (final name in names) {
    try {
      return DynamicLibrary.open(name);
    } on ArgumentError {
      // try next candidate
    }
  }
  return Platform.isLinux
      ? DynamicLibrary.process()
      : DynamicLibrary.executable();
}

/// Looks up [symbol] in the running process — used for GLib-internal
/// helpers (`g_free`) that are loaded globally when libglib is
/// present. Falls back to opening `libglib-2.0.so` explicitly when
/// the symbol hasn't been loaded yet (e.g. when our binding is the
/// first GLib call from the user's process).
DynamicLibrary _glibProcessLib() => Platform.isLinux
    ? DynamicLibrary.process()
    : DynamicLibrary.executable();

/// Opens `libglib-2.0.so` (or the platform equivalent) explicitly.
/// Use this for symbols that aren't yet in the running process —
/// `g_bytes_new`, `g_type_class_ref`, etc. — when called before any
/// generated GLib wrapper has had a chance to dlopen libglib.
DynamicLibrary _libglib() => openLibrary(const [
      'libglib-2.0.so.0',
      'libglib-2.0.so',
      'libglib-2.0.dylib',
      'libglib-2.0.tbd',
    ]);

/// Opens `libgobject-2.0.so` (or the platform equivalent) explicitly.
DynamicLibrary _libgobject() => openLibrary(const [
      'libgobject-2.0.so.0',
      'libgobject-2.0.so',
      'libgobject-2.0.dylib',
      'libgobject-2.0.tbd',
    ]);

/// Opens `libgtk-4.so` (or the platform equivalent) explicitly.
DynamicLibrary _libgtk4() => openLibrary(const [
      'libgtk-4.so.0',
      'libgtk-4.so',
      'libgtk-4.dylib',
      'libgtk-4.tbd',
    ]);

/// Opens `libadwaita-1.so` (or the platform equivalent) explicitly.
DynamicLibrary _libadwaita() => openLibrary(const [
      'libadwaita-1.so.0',
      'libadwaita-1.so',
      'libadwaita-1.dylib',
      'libadwaita-1.tbd',
    ]);

final _gFreeNative = _glibProcessLib()
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>('g_free');
void gFree(Pointer<Void> ptr) {
  if (ptr == nullptr) return;
  _gFreeNative.asFunction<void Function(Pointer<Void>)>().call(ptr);
}

/// Wraps a Dart-owned byte buffer in a GLib `GBytes` by copying the
/// bytes into GLib-managed memory.
///
/// `g_bytes_new` is in `GLib-2.0.gir` but our generator currently
/// skips it (the parameter is `const void*`, which the bridge rules
/// treat as an unsupported pointee type). The example apps that
/// load `.gresource` bundles at startup need this entry, hence the
/// handwritten binding here. Tracks upstream GIR; will move to the
/// generated `package:glib` once the generator is taught to emit
/// `const void*` as `ffi.Pointer<ffi.Uint8>`.
final _gBytesNewNative = _libglib()
    .lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>, IntPtr)>>(
      'g_bytes_new',
    );

/// `Pointer<Bytes>` → owned `GBytes*`. Returns `nullptr` if [bytes] is
/// `null` (mirrors GLib's behaviour for zero-length inputs).
Pointer<Void> gBytesNew(Pointer<Void> bytes, int length) {
  if (bytes == nullptr || length == 0) return nullptr;
  return _gBytesNewNative
      .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()
      .call(bytes, length);
}

/// Looks up the `GTypeClass` for a given [type] and returns a
/// borrowed pointer. The result is owned by GLib and must NOT be
/// freed; pair with [gTypeClassUnref] when finished.
///
/// `g_type_class_ref` is not in `GLib-2.0.gir` because the function
/// returns a `gpointer` (untyped) — the type system uses C macros
/// like `G_TYPE_CHECK_INSTANCE_CAST` to do nominal-to-structural
/// conversions at the use site. Our handwritten binding here lets
/// the `gtk_templates_builder` emit code that follows the same
/// pattern: peek the class, cast to `GtkWidgetClass*`, set the
/// template on it.
final _gTypeClassRefNative = _libgobject()
    .lookup<NativeFunction<Pointer<Void> Function(IntPtr)>>('g_type_class_ref');
Pointer<Void> gTypeClassRef(int type) {
  if (type == 0) return nullptr;
  return _gTypeClassRefNative.asFunction<Pointer<Void> Function(int)>().call(type);
}

/// Decrements the reference count of a [GTypeClass] returned by
/// [gTypeClassRef]. No-op if `classPtr` is `nullptr`.
final _gTypeClassUnrefNative = _libgobject()
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>('g_type_class_unref');
void gTypeClassUnref(Pointer<Void> classPtr) {
  if (classPtr == nullptr) return;
  _gTypeClassUnrefNative.asFunction<void Function(Pointer<Void>)>().call(classPtr);
}

/// Macro equivalent of `G_TYPE_CHECK_CLASS_CAST(klass, type, klass)`.
///
/// `g_type_check_class_cast` is not in `GLib-2.0.gir` (it returns
/// a `gpointer` — untyped). The handwritten binding lets us cast a
/// `GTypeClass*` (returned by `g_type_class_ref`) to a typed class
/// pointer (e.g. `GtkWidgetClass*`) without dropping into a C macro.
final _gTypeCheckClassCastNative = _libgobject().lookup<
    NativeFunction<Pointer<Void> Function(Pointer<Void>, IntPtr)>>(
  'g_type_check_class_cast',
);
Pointer<Void> gTypeCheckClassCast(Pointer<Void> typeClass, int type) {
  if (typeClass == nullptr) return nullptr;
  return _gTypeCheckClassCastNative
      .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()
      .call(typeClass, type);
}

/// Registers a static subclass of [parent] named [name] with no
/// `class_init` / `instance_init` callbacks.
///
/// `g_type_register_static_simple` is the simpler form of
/// `g_type_register_static` that doesn't require the caller to
/// construct a `GTypeInfo` struct (whose size depends on the
/// platform and which our binding can't easily model). It's used by
/// PyGObject's `@Gtk.Template` decorator and by every "static type"
/// registration helper in the C ecosystem.
///
/// Returns the new GType ID, or 0 on failure.
final _gTypeRegisterStaticSimpleNative = _libgobject().lookup<
    NativeFunction<
        IntPtr Function(IntPtr, Pointer<Utf8>, IntPtr, Pointer<Void>, IntPtr,
            Pointer<Void>, IntPtr)>>(
  'g_type_register_static_simple',
);
int gTypeRegisterStaticSimple(int parent, String name) {
  final nameBytes = name.toNativeUtf8();
  try {
    final type = _gTypeRegisterStaticSimpleNative
        .asFunction<
            int Function(int, Pointer<Utf8>, int, Pointer<Void>, int,
                Pointer<Void>, int)>()
        .call(
          // class_size must be >= sizeof(GTypeClass) — pick a
          // conservative 256 bytes so the C side has room for the
          // vtable-ish members.
          parent,
          nameBytes,
          256,
          nullptr,
          // instance_size: same — 256 bytes for any fields the
          // user might add via `late` declarations on the Dart side.
          256,
          nullptr,
          0,
        );
    return type;
  } finally {
    calloc.free(nameBytes);
  }
}

/// Underlying C entry for `gtk_widget_class_bind_template_callback_full`.
///
/// The generator-generated `GtkWidgetClass.bindTemplateCallbackFull`
/// wraps a Dart callback in a `NativeCallable.isolateLocal` and
/// closes it before the C side has had a chance to keep a reference
/// to it — so the trampoline dies and the user's signal handler is
/// silently dropped. This binding bypasses the wrapper, letting the
/// `gtk_templates_builder` emit code that pins the `NativeCallable`
/// in the per-process callback registry (see `template_lookup.dart`)
/// for the lifetime of the program.
///
/// Signature: `gtk_widget_class_bind_template_callback_full(
///   GtkWidgetClass*, const gchar*, GCallback)` where `GCallback`
///   is `void (*)()`.
final _gtkWidgetClassBindTemplateCallbackFullNative = _libgtk4().lookup<
    NativeFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>)>>(
  'gtk_widget_class_bind_template_callback_full',
);
void gtkWidgetClassBindTemplateCallbackFull(
  Pointer<Void> widgetClass,
  String callbackName,
  Pointer<Void> callbackSymbol,
) {
  if (widgetClass == nullptr || callbackSymbol == nullptr) return;
  final nameBytes = callbackName.toNativeUtf8();
  try {
    _gtkWidgetClassBindTemplateCallbackFullNative
        .asFunction<void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>)>()
        .call(widgetClass, nameBytes, callbackSymbol);
  } finally {
    calloc.free(nameBytes);
  }
}

/// Looks up the GType for `GtkApplicationWindow`.
///
/// The generator does not emit `_get_type` accessors (they're flagged
/// as missing getter `get_<name>` for various `<class>.get_type` calls
/// in the skip report, and the GIR `<function name="..._get_type">`
/// entries are filtered out as constructors/callable boilerplate).
/// The companion builder's `@GtkTemplate` installer needs the
/// `GtkApplicationWindow` GType to call `setTemplateFromResource`
/// against the parent WidgetClass without registering a fresh
/// subclass (which would require modeling the `GTypeInfo` struct).
/// Calling `gtk_application_window_get_type()` here is the canonical
/// way to obtain the GType — and as a side effect, it triggers the
/// class' lazy `class_init`, so subsequent `typeFromName` calls
/// return the same value.
final _gtkApplicationWindowGetTypeNative = _libgtk4()
    .lookup<NativeFunction<IntPtr Function()>>('gtk_application_window_get_type');
int gtkApplicationWindowGetType() {
  return _gtkApplicationWindowGetTypeNative.asFunction<int Function()>().call();
}

/// Looks up the GType for `AdwApplicationWindow`.
///
/// Same rationale as [gtkApplicationWindowGetType] — needed because
/// the generator skips `_get_type` accessors. Setting the template on
/// `AdwApplicationWindow`'s WidgetClass (the actual GObject class of
/// an `AdwApplicationWindow.new` instance) means every
/// `AdwApplicationWindow` instance in the process picks up the same
/// template, which is what `@GtkTemplate` on a class that subclasses
/// `AdwApplicationWindow` (like the `TodoWindow` example) needs.
final _adwApplicationWindowGetTypeNative = _libadwaita()
    .lookup<NativeFunction<IntPtr Function()>>('adw_application_window_get_type');
int adwApplicationWindowGetType() {
  return _adwApplicationWindowGetTypeNative.asFunction<int Function()>().call();
}

/// Looks up a named child widget of [widget]'s loaded template, typed
/// as `GType widget_type`.
///
/// The generator-emitted `GtkWidget.getTemplateChild` wrapper swaps
/// the first two parameters (it emits `(Pointer<Void>, Size, ...)`
/// where C requires `(GType, GtkWidget*, ...)`), which causes FFI to
/// silently read garbage and either hang or return `nullptr` for
/// otherwise-valid lookups. This handwritten binding calls into
/// `gtk_widget_get_template_child` with the correct parameter order
/// so the template-child wiring in `package:gtk_templates` works.
///
/// `gtk_widget_get_template_child` returns the borrowed `GtkWidget*`
/// for the child named [name] in the template associated with
/// `widget_type` (the GType of the widget, NOT the WidgetClass).
/// Returns `nullptr` if the child isn't declared in the template.
final _gtkWidgetGetTemplateChildNative = _libgtk4().lookup<
    NativeFunction<
        Pointer<Void> Function(
          IntPtr,
          Pointer<Void>,
          Pointer<Utf8>,
        )>>('gtk_widget_get_template_child');
Pointer<Void> gtkWidgetGetTemplateChild(
  int widgetType,
  Pointer<Void> widget,
  String name,
) {
  if (widget == nullptr) return nullptr;
  final nameBytes = name.toNativeUtf8();
  try {
    return _gtkWidgetGetTemplateChildNative
        .asFunction<Pointer<Void> Function(int, Pointer<Void>, Pointer<Utf8>)>()
        .call(widgetType, widget, nameBytes);
  } finally {
    calloc.free(nameBytes);
  }
}

/// Converts a native NUL-terminated UTF-8 string to a Dart [String].
String? stringFromNative(Pointer<Char> ptr, {bool free = false}) {
  if (ptr == nullptr) return null;
  final value = ptr.cast<Utf8>().toDartString();
  if (free) malloc.free(ptr);
  return value;
}

/// Converts a Dart [String] to a native NUL-terminated UTF-8 string.
Pointer<Char> stringToNative(String? value) {
  if (value == null) return nullptr;
  return value.toNativeUtf8().cast<Char>();
}

/// Runs [body] with [value] marshalled to native memory, freeing it after.
R withNativeString<R>(String? value, R Function(Pointer<Char>) body) {
  final ptr = stringToNative(value);
  try {
    return body(ptr);
  } finally {
    if (ptr != nullptr) malloc.free(ptr);
  }
}

/// Marshals a nullable `List<String?>` to a NULL-terminated
/// `Pointer<Pointer<Utf8>>` for the duration of [body], matching how GLib
/// expects argv-style arrays. Each non-null element is copied to a
/// native NUL-terminated string; the outer pointer and all per-element
/// pointers are freed in a `finally`.
///
/// * Pass `null` to leave the array pointer as NULL — the C side sees
///   `argv == NULL`, which is the accepted convention for
///   `g_application_run` and friends when no command-line parsing is
///   needed.
/// * Pass an empty list to allocate a one-slot array whose only entry
///   is NULL — i.e. `argc = 0, argv = {NULL}`. Same as above but
///   distinguishable from a null pointer for C APIs that require a
///   non-null array.
/// * Null elements inside the list become NULL slots in the array;
///   only the non-null allocations are tracked for freeing.
R withNativeStringList<R>(
  List<String?>? values,
  R Function(Pointer<Pointer<Utf8>> argv) body,
) {
  if (values == null) {
    return body(nullptr);
  }
  final argc = values.length;
  final argv = calloc<Pointer<Utf8>>(argc + 1);
  final strs = <Pointer<Utf8>>[];
  try {
    for (var i = 0; i < argc; i++) {
      final v = values[i];
      if (v == null) {
        argv[i] = nullptr;
      } else {
        final p = v.toNativeUtf8();
        strs.add(p);
        argv[i] = p.cast();
      }
    }
    argv[argc] = nullptr; // explicit NULL terminator
    return body(argv);
  } finally {
    for (final p in strs) {
      calloc.free(p);
    }
    calloc.free(argv);
  }
}

/// Backing store for caller-allocated OUT parameters (e.g. `GtkTextIter*`,
/// `GValue*`) emitted by the generator.
///
/// Holds a fixed-size zero-initialized buffer and frees it via
/// [NativeFinalizer] when the anchor is garbage collected. The corresponding
/// Dart wrapper (e.g. `GtkTextIter.fromPointer(_buffer)`) keeps the
/// anchor reachable as long as the user holds the wrapper — matching
/// GTK's "the iter lives until you drop it" semantics.
///
/// Use [HeapAnchor.allocate] to create a new anchor with a buffer of the
/// requested size. The buffer's lifetime is tied to the anchor's
/// reachability; drop the wrapper and the buffer is freed on the next
/// GC cycle.
class HeapAnchor implements Finalizable {
  HeapAnchor(this.buffer);

  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  /// The heap-allocated buffer. The C function fills this memory; the
  /// wrapper then exposes it as `Pointer<Void>` (or any struct-typed
  /// pointer) to its caller.
  final Pointer<Uint8> buffer;

  /// Allocates a [byteCount]-byte zero-initialized buffer and attaches a
  /// finalizer that calls `malloc.nativeFree` when the anchor is GC'd.
  static HeapAnchor allocate(int byteCount) {
    final anchor = HeapAnchor(calloc<Uint8>(byteCount));
    _finalizer.attach(anchor, anchor.buffer.cast());
    return anchor;
  }
}
