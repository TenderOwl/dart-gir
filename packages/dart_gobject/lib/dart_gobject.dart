/// Dart-level GObject types.
///
/// A Dart class that extends `GObject` has no native type of its own — the
/// native side only ever sees a plain `GObject`. This package gives such a
/// class a *native identity*:
///
/// ```dart
/// class TaskObject extends GObject {
///   static final int GType = registerDartType('TaskObject', GObject.GType);
///
///   TaskObject({required this.content}) : super(GType);
///
///   final String content;
/// }
/// ```
///
/// The registered type is a real GType, so `GListStore(TaskObject.GType)`
/// type-checks its items natively and `typeNameFromInstance` can name them.
/// The Dart object survives a round trip through native code: the bindings'
/// wrapper cache keeps one Dart object per native pointer, so the object
/// that comes back out of a `GtkListItem` is the very object that went in.
library;

export 'src/gtype_registry.dart'
    show registerDartType, registeredDartTypes, dartTypeOf;
