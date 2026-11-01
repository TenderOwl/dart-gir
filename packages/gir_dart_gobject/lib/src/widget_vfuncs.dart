import 'dart:ffi' as ffi;

import 'objects.dart';
import 'vtable.dart';

/// The byte offsets of `GtkWidgetClass`'s virtual functions.
///
/// The class struct layout is not in the introspection data, so the
/// offsets are hand-authored here and cross-checked against the
/// installed header by `vtable_layout_test.dart`, which skips when the
/// header is not installed.
///
/// `GtkWidgetClass` continues the parent class struct directly — there
/// is no data field between the parent's struct and the first slot:
///
/// ```c
/// struct _GtkWidgetClass {
///   GInitiallyUnownedClass parent_class;   //  0  { GObjectClass … }
///   void (* show)                (GtkWidget *widget);   // 136
///   void (* hide)                (GtkWidget *widget);   // 144
///   …
///   void (* size_allocate)       (…);                   // 200
///   …
///   void (* snapshot)            (…);                   // 320
///   gboolean (* contains)        (…);                   // 328
///   …
/// };
/// ```
///
/// `GInitiallyUnownedClass` holds a `GObjectClass` and nothing else,
/// so the first slot of `GtkWidgetClass` sits at the size of
/// `GObjectClass` — 136 bytes on a 64-bit build: the class struct holds
/// the virtual functions and the private data GObject keeps
/// (`flags`, `n_construct_properties`, `pspecs`, `n_pspecs` and the
/// padding).
abstract final class GtkWidgetVtable {
  /// The offset of `GtkWidgetClass::show`.
  static const int show = 136;

  /// The offset of `GtkWidgetClass::hide`.
  static const int hide = 144;

  /// The offset of `GtkWidgetClass::map`.
  static const int map = 152;

  /// The offset of `GtkWidgetClass::unmap`.
  static const int unmap = 160;

  /// The offset of `GtkWidgetClass::realize`.
  static const int realize = 168;

  /// The offset of `GtkWidgetClass::unrealize`.
  static const int unrealize = 176;

  /// The offset of `GtkWidgetClass::root`.
  static const int root = 184;

  /// The offset of `GtkWidgetClass::unroot`.
  static const int unroot = 192;

  /// The offset of `GtkWidgetClass::size_allocate`.
  static const int sizeAllocate = 200;

  /// The offset of `GtkWidgetClass::state_flags_changed`.
  static const int stateFlagsChanged = 208;

  /// The offset of `GtkWidgetClass::direction_changed`.
  static const int directionChanged = 216;

  /// The offset of `GtkWidgetClass::get_request_mode`.
  static const int getRequestMode = 224;

  /// The offset of `GtkWidgetClass::measure`.
  static const int measure = 232;

  /// The offset of `GtkWidgetClass::mnemonic_activate`.
  static const int mnemonicActivate = 240;

  /// The offset of `GtkWidgetClass::grab_focus`.
  static const int grabFocus = 248;

  /// The offset of `GtkWidgetClass::focus`.
  static const int focus = 256;

  /// The offset of `GtkWidgetClass::set_focus_child`.
  static const int setFocusChild = 264;

  /// The offset of `GtkWidgetClass::move_focus`.
  static const int moveFocus = 272;

  /// The offset of `GtkWidgetClass::keynav_failed`.
  static const int keynavFailed = 280;

  /// The offset of `GtkWidgetClass::query_tooltip`.
  static const int queryTooltip = 288;

  /// The offset of `GtkWidgetClass::compute_expand`.
  static const int computeExpand = 296;

  /// The offset of `GtkWidgetClass::css_changed`.
  static const int cssChanged = 304;

  /// The offset of `GtkWidgetClass::system_setting_changed`.
  static const int systemSettingChanged = 312;

  /// The offset of `GtkWidgetClass::snapshot`.
  static const int snapshot = 320;

  /// The offset of `GtkWidgetClass::contains`.
  static const int contains = 328;
}

/// The signature of `GtkWidgetClass::size_allocate`.
typedef _SizeAllocate = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
);

/// The signature of `GtkWidgetClass::measure`.
typedef _Measure = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Int32,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);

/// The signature of `GtkWidgetClass::snapshot`.
typedef _Snapshot = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
);

/// The permanent trampolines.
///
/// A class lives for as long as its type does, so its vfuncs must never
/// be closed — a closed `NativeCallable` would leave a dangling C
/// function pointer.
final ffi.NativeCallable<_SizeAllocate> _sizeAllocateCallable =
    ffi.NativeCallable<_SizeAllocate>.isolateLocal(_sizeAllocateBridge);
final ffi.NativeCallable<_Measure> _measureCallable =
    ffi.NativeCallable<_Measure>.isolateLocal(_measureBridge);
final ffi.NativeCallable<_Snapshot> _snapshotCallable =
    ffi.NativeCallable<_Snapshot>.isolateLocal(_snapshotBridge);

void _sizeAllocateBridge(
  ffi.Pointer<ffi.Void> widget,
  int width,
  int height,
  int baseline,
) {
  final handler = vfuncHandler(widget, GtkWidgetVtable.sizeAllocate);
  if (handler is void Function(Object?, int, int, int)) {
    handler(dartObjectFor(widget), width, height, baseline);
  }
  final address = inheritedVfunc(widget, GtkWidgetVtable.sizeAllocate);
  if (address != null && address != 0) {
    ffi.Pointer<ffi.NativeFunction<_SizeAllocate>>.fromAddress(address)
        .asFunction<void Function(ffi.Pointer<ffi.Void>, int, int, int)>()(
      widget,
      width,
      height,
      baseline,
    );
  }
}

void _measureBridge(
  ffi.Pointer<ffi.Void> widget,
  int orientation,
  int forSize,
  ffi.Pointer<ffi.Void> minimum,
  ffi.Pointer<ffi.Void> natural,
  ffi.Pointer<ffi.Void> minimumBaseline,
  ffi.Pointer<ffi.Void> naturalBaseline,
) {
  final handler = vfuncHandler(widget, GtkWidgetVtable.measure);
  if (handler is void Function(Object?, int, int, int, int, int, int)) {
    handler(
      dartObjectFor(widget),
      orientation,
      forSize,
      minimum.cast<ffi.Int32>().value,
      natural.cast<ffi.Int32>().value,
      minimumBaseline.cast<ffi.Int32>().value,
      naturalBaseline.cast<ffi.Int32>().value,
    );
  }
  final address = inheritedVfunc(widget, GtkWidgetVtable.measure);
  if (address != null && address != 0) {
    ffi.Pointer<ffi.NativeFunction<_Measure>>.fromAddress(address)
        .asFunction<
          void Function(
            ffi.Pointer<ffi.Void>,
            int,
            int,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>,
          )
        >()(
      widget,
      orientation,
      forSize,
      minimum,
      natural,
      minimumBaseline,
      naturalBaseline,
    );
  }
}

void _snapshotBridge(
  ffi.Pointer<ffi.Void> widget,
  ffi.Pointer<ffi.Void> snapshot,
) {
  final handler = vfuncHandler(widget, GtkWidgetVtable.snapshot);
  if (handler is void Function(Object?, ffi.Pointer<ffi.Void>)) {
    handler(dartObjectFor(widget), snapshot);
  }
  final address = inheritedVfunc(widget, GtkWidgetVtable.snapshot);
  if (address != null && address != 0) {
    ffi.Pointer<ffi.NativeFunction<_Snapshot>>.fromAddress(
      address,
    ).asFunction<void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>()(
      widget,
      snapshot,
    );
  }
}

/// Overrides `GtkWidgetClass::size_allocate`.
///
/// The handler receives the widget, the width, the height and the
/// baseline the widget was allocated. The inherited implementation runs
/// afterwards, so the widget's own layout still happens.
VfuncOverride sizeAllocateOverride(
  void Function(Object? widget, int width, int height, int baseline) handler,
) => VfuncOverride(
  GtkWidgetVtable.sizeAllocate,
  _sizeAllocateCallable.nativeFunction.address,
  handler,
);

/// Overrides `GtkWidgetClass::measure`.
///
/// The handler receives the widget, the orientation, the size the
/// measurement is for and the four measurements — the minimum and the
/// natural size, and their baselines. The measurements are the values
/// the widget asks for; the inherited implementation runs afterwards.
VfuncOverride measureOverride(
  void Function(
    Object? widget,
    int orientation,
    int forSize,
    int minimum,
    int natural,
    int minimumBaseline,
    int naturalBaseline,
  )
  handler,
) => VfuncOverride(
  GtkWidgetVtable.measure,
  _measureCallable.nativeFunction.address,
  handler,
);

/// Overrides `GtkWidgetClass::snapshot`.
///
/// The handler receives the widget and the native snapshot — cast it
/// with the generated package's `GtkSnapshot`. The inherited
/// implementation runs afterwards.
VfuncOverride snapshotOverride(
  void Function(Object? widget, ffi.Pointer<ffi.Void> snapshot) handler,
) => VfuncOverride(
  GtkWidgetVtable.snapshot,
  _snapshotCallable.nativeFunction.address,
  handler,
);
