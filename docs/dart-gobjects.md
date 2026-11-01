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
| `registerDartType` | `packages/gir_dart_gobject` | registers a native type for a Dart class |
| `DartSignal` / `DartProperty` | `packages/gir_dart_gobject` | signals and properties a Dart type declares natively |
| `VfuncOverride` | `packages/gir_dart_gobject` | the virtual functions a Dart type answers |
| `newDartInstance` | `packages/gir_dart_gobject` | an instance of a Dart type, with its construct properties |

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
  registry lives in `packages/gir_dart_gobject`.
* **`GType` is not `lowerCamelCase`.** The generator emits
  `static int get GType` for every class, and a Dart subclass uses the
  same name. The `non_constant_identifier_names` lint fires on it; the
  generated packages, `packages/gir_dart_gobject` and `example/todo` turn
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

### The native suites run one after another

`dart test` runs the test *files* in parallel, and each file gets its
own isolate — but the isolates share one process, and therefore one
GLib, one GTK and one heap. Two suites that initialise GTK at the same
time race inside GTK's initialisation, and the process aborts with a
heap corruption.

The suites that initialise GTK are `packages/gir_gtk4` (which calls
`gtk_init()` in its `setUpAll`) and `example/notepad` (which calls
`init()`). Run the native suites with `--concurrency=1`; CI does.

This is a property of the *test setup*, not of the bindings: the suites
share GTK's global state, not a GObject, a main context or a buffer.

### The wrapper's lifetime

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
| `packages/gir_dart_gobject/lib/src/gtype_registry.dart` | `registerDartType` — the type, its class initializer, its interfaces |
| `packages/gir_dart_gobject/lib/src/signals.dart` | `DartSignal`, `emitDartSignal`, `connectDartSignal` |
| `packages/gir_dart_gobject/lib/src/properties.dart` | `DartProperty`, `getDartProperty`, `setDartProperty` |
| `packages/gir_dart_gobject/lib/src/vtable.dart` | `GObjectVtable` — the GObject class struct's offsets |
| `packages/gir_dart_gobject/lib/src/widget_vfuncs.dart` | `GtkWidgetVtable` — the GtkWidget class struct's offsets |
| `packages/gir_dart_gobject/lib/src/construction.dart` | `newDartInstance` — an instance of a Dart type |
| `packages/gir_gtk_templates/lib/src/runtime.dart` | `requireOwnType` — the template's own-type check |
| `example/todo/lib/task_object.dart` | the worked example |
| `example/todo/lib/task_row.dart` | a template on a Dart class's own type |

## Answering GObject's virtual calls

A Dart class with a native type is a real GObject as far as GLib is
concerned — but GObject's *virtual* functions still point at the C
implementation. A Dart class that wants to answer `dispose` has nowhere
to put its answer: the class struct is C memory, and the GIR does not
describe it.

`packages/gir_dart_gobject` closes that gap for a curated slice of
`GObjectClass`:

| Slot | Dart entry point |
|---|---|
| `constructed` | `dartConstructed()` |
| `dispose` | `dartDispose()` |
| `finalize` | `dartFinalize()` |

```dart
class TaskObject extends DartGObject {
  static int get GType =>
      registerDartType('TaskObject', GObject.GType, vfuncs: true);

  TaskObject() : super(GType);

  @override
  void dartDispose() {
    // release what this object owns …
  }
}
```

### The ABI table is hand-written

The slot offsets cannot be derived from the introspection data. The GIR
lists a class's virtual methods **alphabetically**; the C class struct
declares them in the order the vtable uses. `GObjectClass` is

```c
struct _GObjectClass {
  GTypeClass   g_type_class;              //  0
  GSList      *construct_properties;      //  8
  GObject*   (*constructor)         (...);// 16
  void       (*set_property)        (...);// 24
  void       (*get_property)        (...);// 32
  void       (*dispose)             (...);// 40
  void       (*finalize)            (...);// 48
  void       (*dispatch_properties_changed) (...); // 56
  void       (*notify)              (...);// 64
  void       (*constructed)         (...);// 72
  ...
};
```

so `dispose` is at byte 40 and `finalize` at byte 48 on a 64-bit Linux
build. Those numbers live in `GObjectVtable`, and
`packages/gir_dart_gobject/test/vtable_layout_test.dart` reads the
installed header and checks them — the test skips when the headers are
not installed, so the suite still runs without them.

### How the call reaches Dart

`installGObjectVfuncs(type)` takes the class struct of the type
(`g_type_class_ref`), saves the inherited implementation of every slot it
patches and writes a permanent trampoline over it. The trampoline calls
the Dart object, then the saved implementation — the C convention, in
which the subclass runs first and chains up afterwards.

The trampolines are permanent: GObject calls them for the life of the
type, and a closed `NativeCallable` would leave a dangling C function
pointer.

`constructed` is the odd one out. GObject calls it from `g_object_new`,
*before* the Dart wrapper exists, so the call is recorded and delivered
by `DartGObject`'s constructor — the first point at which the object
does.

### The lifecycle rule

The wiring is **opt-in**, and it has to be. A GObject that carries a Dart
callback must not be finalized while the isolate shuts down: GObject
would call back into a VM that is already tearing itself down, and the
VM aborts the process. This is the same rule the signal handlers follow
(see [docs/templates.md](templates.md) for the template stack's version
of it), and it is why `registerDartType` does not wire the virtual
functions unless it is asked to.

A type that opts in has to release its objects before the isolate ends:

```dart
final object = TaskObject();
// … use it …
object.unref(); // releases the reference the wrapper owns
```

## Signals on a Dart type

A Dart type can declare a **signal of its own**. The signal is a real
GLib signal: `g_signal_lookup` finds it, `g_signal_emit` reaches it, and
a C caller can connect to it.

```dart
class TaskObject extends DartGObject {
  static int get GType => registerDartType(
    'TaskObject',
    GObject.GType,
    signals: {
      'completed': DartSignal.withoutArgument((self) {
        (self! as TaskObject).onCompleted();
      }),
      'progress': DartSignal.withArgument(
        DartSignalArgument.integer,
        (self, value) => (self! as TaskObject).onProgress(value! as int),
      ),
    },
  );
}
```

The signal is declared while the type's **class** is initialized, the way
a native class declares its own: `registerDartType` installs a
`class_init` trampoline, and the trampoline calls
`g_signal_newv` with a class closure over the Dart handler.

Three details make that work:

* **The class closure is a `GClosure`, not a callback.** GLib needs a
  `GClosure` to marshal the signal's arguments. The runtime creates one
  with `g_cclosure_new` and the generic marshaller, and the closure's
  user data is the *installation id* as a pointer value — so the
  trampoline can find the Dart handler without allocating anything and
  without a destroy notify.
* **`g_signal_newv` sinks the closure.** It consumes the caller's
  initial reference, so the runtime must **not** unref it: an unref
  leaves a dangling closure, and the Dart handler never runs.
* **The signal's argument has one type.** `DartSignalArgument` picks it:
  `integer`, `boolean`, `real`, `string` or `object`. The generic
  marshaller carries those, so the argument arrives in Dart with its
  type intact.

A Dart type's signal is emitted from Dart with `emitDartSignal`:

```dart
emitDartSignal(task, 'completed');
emitDartSignal(task, 'progress', 42);
```

and connected to from Dart with `connectDartSignal`:

```dart
connectDartSignal(task, 'completed', (self, args) {
  print('${(self! as TaskObject).content} is done');
});
```

## Properties on a Dart type

A Dart type can declare **properties of its own**, and the native side
sees them: `g_object_get_property`, `g_object_set_property` and
`g_object_notify` all work on them.

```dart
class TaskObject extends DartGObject {
  static int get GType => registerDartType(
    'TaskObject',
    GObject.GType,
    properties: {
      'content': DartProperty.string(
        getter: (self) => (self! as TaskObject).content,
        setter: (self, value) => (self! as TaskObject).content = value!,
      ),
      'done': DartProperty.boolean(
        getter: (self) => (self! as TaskObject).done,
        setter: (self, value) => (self! as TaskObject).done = value,
      ),
    },
  );
}
```

The property is a real `GParamSpec`, installed with
`g_object_class_install_property` while the class is initialized.

**The property's virtual functions are patched before the property is
installed.** `g_object_base_class_init` *resets* `set_property` and
`get_property` to `NULL` in the derived class struct, and GLib refuses a
writable property whose class has no `set_property` — so the runtime
writes the two slots first and installs the property afterwards.

Writing a property notifies: `g_object_notify_by_pspec` runs after the
Dart setter, so a native observer of `notify` sees the change.

From Dart, `getDartProperty` and `setDartProperty` read and write the
property by name.

## Interfaces on a Dart type

A Dart type can implement a **GObject interface**:

```dart
static int get GType => registerDartType(
  'TaskObject',
  GObject.GType,
  interfaces: [GInitable.GType],
);
```

The interface is added with `g_type_add_interface_static`, which has to
happen **after** `g_type_register_static` and **before** the class is
initialized — GLib refuses the call from inside `class_init`. The
runtime therefore adds the interfaces first and forces the class
initialization afterwards.

`addDartInterface(type, interfaceType)` does the same for a type that is
already registered.

## The GTK widget virtual functions

`GtkWidget` has three virtual functions that matter to a custom widget:
`snapshot`, `measure` and `size_allocate`. A Dart class that registers a
type of its own can answer them:

```dart
class MyBox extends GtkBox {
  static int get GType => registerDartType(
    'MyBox',
    GtkBox.GType,
    overrides: [sizeAllocateOverride((widget, width, height, baseline) {
      // the Dart answer …
    })],
  );
}
```

Each override **chains up**: the runtime saves the inherited
implementation and calls it after the Dart handler, the way a C subclass
does.

The slot offsets cannot be derived from the introspection data — the GIR
lists a class's virtual methods alphabetically, the C class struct
declares them in vtable order. `GtkWidgetVtable` holds the numbers, and
`packages/gir_dart_gobject/test/vtable_layout_test.dart` reads the
installed `gtkwidget.h` and checks them against it. The test skips when
the headers are not installed.

`sizeof(GObjectClass)` is 136 on a 64-bit build, so `GtkWidgetClass`'s
slots start there: `size_allocate` is at 200, `snapshot` at 320.

The ABI table lives in the **runtime** package, not in the generator:
the generated packages cannot depend on `gir_dart_gobject` — the
dependency runs the other way — and the table describes the *runtime's*
patching, not the GIR.

## A template on the Dart class's own type

GTK keeps a widget's template on the **native class** and allows exactly
one per class. A Dart class without a type of its own shares its
parent's class, so two Dart classes with the same parent could not both
have a template.

A Dart class that registers a type of its own gets a class of its own to
put the template on:

```dart
@GtkTemplate(source: GtkTemplateFile('data/task_row.ui'))
class TaskRow extends GtkBox with _$TaskRowTemplate {
  static int get GType => registerDartType('TaskRow', GtkBox.GType);

  TaskRow()
      : super.rawFromPointer(
          newDartInstance(
            GType,
            constructProperties: {'orientation': GtkOrientation.horizontal.value},
          ),
          owned: true,
        ) {
    initTemplate();
  }
}
```

Two things have to line up:

* **The widget is an instance of the type.** `newDartInstance` creates one
  — with the construct properties the type needs, because GLib refuses to
  set a construct-only property afterwards. The generated mixin checks it
  and says what is wrong when it is not:
  *"`TaskRow` was created as `GtkBox`, not as `TaskRow`."*
* **The template is claimed on that type.** The builder's scanner sees
  the `GType` accessor and emits the own-type path: the mixin claims
  `TaskRow.GType` instead of the type the instance happens to have.

`newDartInstance` is the general form: `g_object_newv` with the type's
construct properties. The value types it fills are objects, strings,
integers, booleans, doubles and enumerations.

## What is still not in the slice

- **`GObject.constructed` as a normal override.** It is delivered, but
  it runs before the subclass's own constructor body — the Dart object
  exists, the subclass's fields do not.
- **A signal with more than one argument.** The generic marshaller
  carries one argument; a signal with two would need its own marshaller.
- **A signal with a return value.** `g_signal_newv` declares the
  return type, but the runtime does not marshal one back.
- **A property of a boxed, variant or pointer type.** The property's
  value type comes from the declaration, and only the five kinds above
  are wired.
- **The GTK widget virtual functions beyond the three.** `GtkWidget`'s
  other slots — `get_request_mode`, `get_preferred_width`, and the rest
  of the class struct — are not in the table.
- **A type with native fields.** The type inherits the parent's class and
  instance sizes; anything the object needs beyond that lives on the
  Dart side.
