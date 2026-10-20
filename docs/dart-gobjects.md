# Dart GObjects

A Dart class can extend a generated GObject wrapper — the generated
classes are `class`, not `final class`, and their props companions are
public. What it could not do was have a **native type of its own**: a
Dart subclass of `GObject` was a plain `GObject` as far as GLib was
concerned. `GListStore` type-checks its items against the type it was
created with, so a Dart subclass could not be put into one; a native
round trip through a property or a list item produced a *new* wrapper
and the Dart state was lost.

This document describes how that is solved, and what it costs.

## The shape of the solution

Four generator features and one hand-written runtime package:

| Piece | Where | What it does |
|---|---|---|
| `static int get GType` | the generator | every generated class and interface exposes the native `GType` the GIR declares through `glib:get-type` |
| `ffi.Struct` for the type-system records | the generator | `GTypeInfo`, `GTypeQuery`, `GTypeFundamentalInfo` and `GInterfaceInfo` carry the C layout, so they can be passed *by value* |
| the wrapper cache | `packages/gir_ffi` | `fromPointer` is a **factory**: the same native pointer always yields the same Dart object |
| `GObject(int objectType)` | the generator | a Dart subclass can instantiate a native type |
| `registerDartType` | `packages/dart_gobject` | registers a native type for a Dart class |

```dart
class TaskObject extends GObject {
  static int get GType => registerDartType('TaskObject', GObject.GType);

  TaskObject({this.completed = false, required this.content}) : super(GType);

  bool completed;
  String content;
}

final store = GListStore(TaskObject.GType);
store.append(TaskObject(content: 'write the docs'));
```

## The native type

`registerDartType(name, parentType)` registers a *static* GType with
GLib and returns it. The type adds no native fields beyond its
parent's and installs no properties or signals — it exists so that the
Dart class has a native identity:

* `GListStore` type-checks its items against it, natively;
* `typeNameFromInstance` can name an instance of it;
* every place that accepts a `GObject` accepts it.

The registration needs a `GTypeInfo`, and the `GTypeInfo` struct is
what the GIR describes:

```c
struct GTypeInfo {
  guint16 class_size;
  GBaseInitFunc base_init;
  GBaseFinalizeFunc base_finalize;
  GClassInitFunc class_init;
  GClassFinalizeFunc class_finalize;
  gconstpointer class_data;
  guint16 instance_size;
  guint16 n_preallocs;
  GInstanceInitFunc instance_init;
  const GValueTable *value_table;
};
```

The generator emits that as a Dart `ffi.Struct`:

```dart
final class GTypeInfo extends ffi.Struct {
  @ffi.Uint16()
  external int class_size;
  external ffi.Pointer<ffi.Void> base_init;
  // …
}
```

Dart FFI derives the layout from the field declarations, so the
struct's offsets match C's. The struct is allocated in native memory
(`calloc<GTypeInfo>()`) and filled in — `ffi.Struct` has no generative
constructor, so it cannot be instantiated in Dart.

The class and instance sizes come from the parent:
`g_type_query` reports both, and the derived type inherits them.

**The name is the type's identity.** GLib refuses to register a name
twice, so the runtime keeps a registry: registering the same name
again returns the type registered first. `registerDartType` throws a
`StateError` when GLib refuses the registration outright — for
instance when the name is taken by a native type.

### The one deviation from PyGObject

PyGObject creates the type when the Python class is defined. Dart has
no runtime class-creation hook, so the type is created *explicitly*:
the class asks for it, by name. That is the whole difference.

## The wrapper cache

Native code hands the same pointer over more than once: a property
getter, a signal argument, a list item. Without a cache every handover
produced a *new* Dart wrapper, so a Dart subclass of a GObject class
lost its identity — and its Dart state — on the way out of native
code.

`packages/gir_ffi` keeps a map from the native address to the Dart
object:

```dart
T? cachedObject<T extends Object>(int address);
void registerDartObject(Object object, int address);
```

The entries are **weak**. A strong entry would keep every wrapper
alive forever: its finalizer would never run, the native object would
never be released, and every model object would leak. The Dart side is
owned by the application.

One address can hold several wrappers: the same native object may be
seen through different classes (a `GObject` and a `GtkWidget`, say),
and each of them wants its own view of it. The lookup returns the
first live entry that `is T`.

`fromPointer` is therefore a **factory**:

```dart
factory GObject.fromPointer(ffi.Pointer<ffi.Void> handle, {bool owned = false}) {
  final cached = cachedObject<GObject>(handle.address);
  if (cached != null) {
    if (owned) {
      gObjectUnref(handle);
    }
    return cached;
  }
  return GObject.rawFromPointer(handle, owned: owned);
}
```

A cache hit with `owned: true` releases the surplus reference the
caller handed over: the cached wrapper already owns one.

The generative constructor is `rawFromPointer`; a generative
constructor may not redirect to a factory, so every constructor in the
generated code calls `this.rawFromPointer(...)` instead.

## What it looks like in practice

`example/todo` is a small task list. Its model is a `GListStore` typed
with the Dart class's own native type:

```dart
final GListStore tasks = GListStore(TaskObject.GType);
```

The store checks every item against that type, natively: a plain
`GObject` is rejected (`g_list_store_append` asserts
`g_type_is_a (G_OBJECT_TYPE (item), store->item_type)`), and a
`TaskObject` is accepted.

The list view's `bind` callback then reads the item back:

```dart
itemFactory.onBind((item) {
  final listItem = item as GtkListItem;
  final row = listItem.getChild() as TaskRow;
  final task = listItem.getItem() as TaskObject;
  row.bind(task);
});
```

`getItem()` returns the *same* `TaskObject` the window created — the
cache found it — so the row writes back into the object the
application still holds.

## The rules

* **The type name is global.** GLib's type names live in one namespace
  per process. `registerDartType` is idempotent per name, and the
  registry lives in `packages/dart_gobject`.
* **`GType` is not `lowerCamelCase`.** The generator emits
  `static int get GType` for every class, and a Dart subclass uses the
  same name. The `non_constant_identifier_names` lint fires on it; the
  generated packages, `packages/dart_gobject` and `example/todo` turn
  that lint off. A user package that declares a Dart GObject has to do
  the same, or suppress the lint on the declaration.
* **A Dart GObject has no native fields.** The type inherits the
  parent's class and instance sizes. Anything the object needs beyond
  that lives on the Dart side.
* **The instance is released by the garbage collector.** The wrapper
  owns the reference `g_object_newv` handed it, and a `NativeFinalizer`
  releases it when the wrapper is collected. See the lifecycle notes
  below.

## Lifecycle notes

The bindings release a native object when the Dart wrapper that owns it
is collected. GTK frees widgets when their parent goes away. The two do
not always agree, and a mismatch is a use-after-free. The rules the
example follows:

* **A widget that is parented needs its floating reference sunk.**
  `gtk_box_new` returns a widget with a *floating* reference: nobody
  owns it until a parent takes it. The generated constructor sinks it
  (`g_object_ref_sink`) when the wrapper takes ownership, so the
  parent's reference and the wrapper's are two references — not one
  that both of them release.
* **A widget that GTK frees must not also be unreffed by the
  finalizer.** `gtk_window_destroy` *frees* the window; the wrapper's
  finalizer would release it a second time. Detach the attachment
  before destroying it:
  `gobjectFinalizer.detach(window); window.destroy();`
* **GTK's selection models dispose the model they wrap** — and they
  dispose it before they disconnect the handlers they connected to it.
  The model has to outlive the selection: keep the model reachable
  while the selection is alive.
* **A Dart signal handler must not outlive the isolate.** A GObject
  that is finalized while the VM shuts down destroys its signal
  handlers, and the destroy-notify calls back into Dart — which the VM
  refuses to do while it is shutting down. Disconnect the handlers
  while the program is still running.
* **A window that is only freed at shutdown stays in GTK's toplevel
  list.** GTK walks that list on every main-loop iteration, so a
  window that was freed but not removed is walked after it is gone.
  Destroy the window while the isolate is alive, and take it out of the
  application's window list first:
  `gobjectFinalizer.detach(window); window.setApplication(null); window.destroy();`

## The generated `GType` accessor

Every generated class and interface exposes its native type:

```dart
/// The native `GType` of this class.
static int get GType => _gType;

/// The cached native `GType` of this class.
static final int _gType = gobjectLookup<ffi.NativeFunction<ffi.Size Function()>>(
  'g_object_get_type',
).asFunction<int Function()>()();
```

The lookup happens once, on first access. The GIR's `glib:get-type`
attribute names the `get_type` function GLib exports for the type; a
class without one (a GIR-only record) does not get the accessor.

## Where the pieces live

| File | What |
|---|---|
| `generator/lib/src/gir/model.dart` | `GirClass.glibGetType`, `GirInterface.glibGetType` |
| `generator/lib/src/gir/parser.dart` | reads `glib:get-type` |
| `generator/lib/src/emit/context.dart` | `EmitContext.gTypeAccessor` |
| `generator/lib/src/emit/class_emitter.dart` | the accessor, the `fromPointer` factory, `rawFromPointer`, `GObject(int objectType)` |
| `generator/lib/src/emit/record_emitter.dart` | the accessor, the `ffi.Struct` records |
| `generator/lib/src/resolve/types.dart` | `TypeResolver.structRecords` — the four type-system records |
| `packages/gir_ffi/lib/gir_ffi.dart` | the wrapper cache |
| `packages/dart_gobject/lib/src/gtype_registry.dart` | `registerDartType` |
| `example/todo/lib/task_object.dart` | the worked example |
