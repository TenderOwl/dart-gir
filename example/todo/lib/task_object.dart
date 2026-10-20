// A task in the list — a Dart-level `GObject` subclass.
//
// The interesting part is the *native* type. `TaskObject.GType` is a
// real GType registered with GLib and derived from `GObject`, so:
//
//   * a `GListStore` type-checks its items against it natively — only
//     a `TaskObject` can get into the store;
//   * `typeNameFromInstance` can name an instance of it;
//   * every place that accepts a `GObject` accepts it.
//
// The Dart state (`content`, `completed`) lives on the Dart side. The
// native type adds no fields of its own — it exists to give the Dart
// class a native identity.
//
// The instance survives a round trip through native code: the
// wrapper cache in `package:gir_ffi` maps the native pointer back to
// *this* Dart object, so the list factory's `bind` gets the very
// `TaskObject` the window created.

import 'package:dart_gobject/dart_gobject.dart';
import 'package:gobject/gobject.dart';

class TaskObject extends GObject {
  /// The native `GType` of this class.
  ///
  /// The name is the type's identity in GLib — registering it twice
  /// would fail — so the runtime returns the type registered first.
  static int get GType => registerDartType('TaskObject', GObject.GType);

  TaskObject({this.completed = false, required this.content}) : super(GType);

  /// Whether the task is done.
  bool completed;

  /// The task's text.
  String content;
}
