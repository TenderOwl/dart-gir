import 'package:gir_gobject/gir_gobject.dart';

import 'vtable.dart';

/// A Dart class that has a native type *and* can override GObject's
/// virtual functions.
///
/// A Dart class that extends `GObject` has no native type of its own —
/// the native side only ever sees a plain `GObject`. [registerDartType]
/// gives it one; this class adds the other half: the Dart class can
/// answer GObject's virtual calls.
///
/// ```dart
/// class TaskObject extends DartGObject {
///   static int get GType => registerDartType('TaskObject', GObject.GType);
///
///   TaskObject() : super(GType) {
///     installGObjectVfuncs(GType);
///   }
///
///   @override
///   void dartDispose() {
///     // release what this object owns …
///   }
/// }
/// ```
///
/// The call order is the C one: the Dart override runs first and the
/// inherited implementation runs after it, so the override can still use
/// the object and the parent's resources are released last.
abstract class DartGObject extends GObject {
  /// Creates an instance of the native type [objectType].
  ///
  /// The `constructed` call GObject makes from `g_object_new` arrives
  /// before this constructor's body runs — the Dart object does not exist
  /// yet — so it is delivered here, at the first point the object does.
  DartGObject(super.objectType) {
    deliverPendingConstructed(this);
  }

  /// Called when GObject has finished constructing the instance.
  ///
  /// The call is delivered from [DartGObject]'s constructor, which runs
  /// *before* the subclass's own constructor body — the subclass's fields
  /// are not set yet.
  void dartConstructed() {}

  /// Called when the instance is disposed.
  ///
  /// GObject calls this when the last reference to the object goes away
  /// and the object is being torn down. Release what the object owns
  /// here; the inherited implementation runs afterwards.
  void dartDispose() {}

  /// Called when the instance is finalized.
  ///
  /// This is the last call the object receives. The inherited
  /// implementation frees the memory afterwards.
  void dartFinalize() {}
}
