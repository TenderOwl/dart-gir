# Emission reference

How each emitter turns a part of the GIR model into Dart source. Every
emitter returns either a string of code (concatenated into the relevant
part-file) or `null` when the symbol is skipped (with the reason recorded
in `GenerationReport`).

## EnumEmitter — `generator/lib/src/emit/enum_emitter.dart`

Emits `<enumeration>` and `<bitfield>`.

* GIR `<enumeration>` → Dart `enum` with `fromValue(int)` and a `value`
  getter. Members are renamed via `enumValueName` — strips the enum
  type's C prefix (`GTK_ALIGN_FILL` → `fill`).
* GIR `<bitfield>` → Dart class with `static const` values, `|`, `&`,
  `^`, `~`, and a `(BitfieldClass)(int)` constructor. Not a Dart `enum`
  because bitfield members combine.

Both are emitted as plain Dart declarations, so each package gets
`lib/src/enums_0.dart`, `lib/src/enums_1.dart`, … chunked at ~400 lines
per file. **Classes are not chunked** — see
[ClassEmitter](#classemitter) for the one-class-per-file layout.

## FunctionEmitter — `generator/lib/src/emit/function_emitter.dart`

Emits `<constant>` and `<function>`.

* `<constant>` → `const <dartType> <name> = <value>;` where `value` is a
  Dart literal (string → `'foo'`, integer → `42`, boolean → `true/false`).
* `<function>` → delegates to `CallableEmitter.emit` with `staticMember:
  false` and `classMember: false`. The wrapper carries a private native
  binding plus the public Dart signature.

## RecordEmitter — `generator/lib/src/emit/record_emitter.dart`

Emits `<record>`, `<union>`, and `<interface>`.

Each becomes an **opaque handle class**:

```dart
final class GFileInfo {
  GFileInfo.fromPointer(this.handle);
  final ffi.Pointer<ffi.Void> handle;
  // …constructors, methods, static functions, signals
}
```

Records have no fields; the GIR corpus has no vtable support yet, so
interfaces (e.g. `Gio.DBusObjectManager`) are emitted the same way rather
than as Dart `implements`. Methods on the record go through
`CallableEmitter` with `selfArgExpr: 'this.handle'`.

## ClassEmitter — `generator/lib/src/emit/class_emitter.dart`

Emits `<class>`.

Output for `final class GtkButton extends GtkWidget implements ffi.Finalizable`:

* A default constructor `GtkButton.fromPointer(super.handle, {super.owned})`
  if there's a parent, or `GtkButton.fromPointer(this.handle, {this.owned
  = false})` with a finalizer attachment otherwise.
* `<constructor>` → `factory GtkButton.new(...)` (named for
  `GirConstructor` whose `cIdentifier` doesn't start with `new_`) or
  `GtkButton(...)` (default `new()` constructor). Wraps the constructor
  result in `_attachFinalizer()` when `sinkFloating` is true (the class
  is in the `InitiallyUnowned` chain).
* `<method>` → `R methodName(...)` with `selfArgExpr: 'this.handle'`.
  Override-incompatible ancestor methods are renamed to disambiguate
  (`activate` on `AdwActionRow` becomes `activateActionRow` when
  `GtkWidget.activate` has a different signature). The skip reason
  `override-incompatible with ancestor; renamed to <name>` is recorded.
* `<function>` → `static R name(...)` with no self-arg.
* **Static class functions (moved-to without class prefix)** — when a
  GIR `<method>` inside the class / record / interface / union carries
  `moved-to="<bare>"` (the value has no dot, so the target is a
  namespace function, not another class method), the class-level
  method is dropped via the existing `movedTo != null` skip rule and
  the corresponding namespace `<function>` is re-emitted as a
  `static` method on this class. The Dart name is
  `toLowerCamel(namespaceFunctionName)`. The six entries that
  trigger this in the in-scope GIRs are `GResource.resourcesRegister`
  / `resourcesUnregister` and `GdkEvent.eventsGetAngle` /
  `eventsGetCenter` / `eventsGetDistance`. `g_iconv` (GIconv) is
  `introspectable="0"` and is already skipped upstream — the static
  promotion doesn't fire there.
* **Inherited typed `onSignalName` methods** are appended after methods
  — see [signals.md](./signals.md) for details.
* **Interface-mirrored methods** are appended last — see
  [Interface mirroring](#interface-mirroring) below for the full rule
  set, the rename-on-conflict logic, and the cross-package import
  heuristic.
* **Props accessor** — see [Props accessor](#props-accessor) below for
  the PyGObject-style `widget.props.<name>` namespace.

The set of reserved class member names: `handle`, `owned`, `fromPointer`,
plus the package's Dart class name. Any GIR member whose lowerCamel
collides gets a `name collision` skip. The `props` field and getter are
also reserved — see below.

### File layout

Each generated `class` / `final class` lands in its own
`lib/src/<lowercased_dart_class_name>.dart` file. The lowercased
Dart class name is used verbatim — `GtkButton` →
`lib/src/gtkbutton.dart`, `GApplication` → `lib/src/gapplication.dart`,
`GInitiallyUnowned` → `lib/src/ginitiallyunowned.dart` — matching the
upstream g-i convention and the user's stated pattern. No
separator insertion (`GtkButtonAccessible` stays
`lib/src/gtkbuttonaccessible.dart`); see the file-naming open
question at the bottom of the plan snapshot if long names become a
problem.

The PyGObject-style `<ClassName>Props` companion class is placed in
`lib/src/<lowercased_dart_class_name>_props.dart` next to its host
class: `class GtkButtonProps` → `lib/src/gtkbutton_props.dart`. Both
files are `part of '<pkg>.dart'` of the same library. Dart compiles
every part of one library into a single compilation unit, so
forward references resolve naturally: `GtkButton`'s `_props` /
`props` references `GtkButtonProps`, and `GtkButtonProps`'s
constructor takes `GtkButton` as `_self` — neither import gymnastics
nor ordering constraints.

The package barrel (`lib/<pkg>.dart`) lists the per-class files in
GIR declaration order — host first, then its companion, then the next
class. IDE jump-to-source (Ctrl+Click) on a class name now lands in
a file that opens with that class.

The chunking rule (~400 lines per file) applies only to the other
categories: `lib/src/enums_<i>.dart`, `lib/src/records_<i>.dart`,
`lib/src/functions_<i>.dart`, `lib/src/constants_<i>.dart`,
`lib/src/callbacks.dart`. The singular support parts
(`lib/src/signals.dart`, `lib/src/exception.dart`,
`lib/src/object_support.dart`, `lib/src/lib.dart`) are unchanged.

The naming helper lives in `generator/lib/src/emit/emitter.dart`:

```dart
String _fileNameForClass(String dartName, {bool props = false}) {
  final base = dartName.toLowerCase();
  return props ? '${base}_props' : base;
}
```

### Props accessor

GObject classes in PyGObject expose `widget.props.label`, `widget.props.xalign`,
etc. as a typed namespace that mirrors every GIR `<property>` element.
This generator emits the same surface: every GObject-rooted class declares
`late final <ClassName>Props _props = <ClassName>Props(this);` and a
`getter props => _props` so users can write:

```dart
final button = GtkButton();
button.props.label = 'Save';
print(button.props.label);            // 'Save'
print(button.props.canShrink);        // false
print(button.props.canFocus);         // inherited from GtkWidget
```

The `<ClassName>Props` companion class is emitted alongside its host
class (in the same part file). Each GIR `<property>` becomes a
getter/setter pair that delegates to the existing typed `get<Name>()`
/ `set<Name>(value)` instance methods — no GValue boxing, no extra
FFI lookups, the same `this.handle` self-arg path the typed methods
use:

```dart
class GtkButtonProps extends GtkWidgetProps {
  GtkButtonProps(GtkButton $self) : _self = $self, super($self);
  final GtkButton _self;

  bool get canShrink => _self.getCanShrink();
  set canShrink(bool value) {
    _self.setCanShrink(value);
  }

  String get label => _self.getLabel();
  set label(String value) {
    _self.setLabel(value);
  }

  // …inherited canFocus, canTarget, halign, valign, … from GtkWidgetProps
}
```

**Inherited properties** surface automatically: child props classes
`extends` their parent's (`GtkButtonProps extends GtkWidgetProps`),
so the parent's accessors are inherited without re-declaration.
Cross-package subclasses (`AdwMessageDialogProps extends GtkWindowProps`)
follow the same rule — the props class is intentionally `class`
(not `final class`) and uses public names (no leading underscore) so
the extends clause resolves across package boundaries.

**Nullability** is propagated from the typed method's bridge, not the
property's declared `<type>`. A property declared as `<type name="utf8"/>`
maps to a non-nullable `String` if the typed `get<Name>` returns
`String`, but to `String?` if the typed method returns `String?` (the
common case for `gchar*` with `transfer-ownership="none"`). The props
getter and setter signatures mirror the typed method's nullability so
assignments and reads never lie at the type level.

**Namespace resolution** for unqualified `<type>` references on the
backing typed method uses the property's *owner* namespace, not the
emission namespace. `GtkWindow.set_application` declares its parameter
as `<type name="Application"/>` — when `AdwMessageDialogProps` emits
the inherited `application` setter, the resolver pins that lookup to
`Gtk` (where `Application` resolves to `GtkApplication?`), preventing
the emission namespace's `Adw.Application` from shadowing it and
breaking the parent's covariant setter.

**Skip semantics** — properties whose accessor can't be represented as
a no-arg getter / single-arg setter are recorded in the skip report
with a precise reason and dropped silently:

* `unsupported type <name>` — array of complex struct, etc.
* `missing getter <name>` — the property's `getter=` attribute names a
  C function that isn't in the GIR `<method>` set.
* `getter <name> takes N args` — typed getter has extra non-self args
  (e.g. `get_size(orientation)`).
* `getter <name> was renamed` — the typed method was renamed to
  disambiguate against an override-incompatible ancestor. The user
  can still call the renamed method directly.
* `setter <name> takes N args` — typed setter has extra non-self args
  (e.g. `set_text(text, length)`).
* `setter <name> was renamed` — same as the getter case.
* `setter <name> parameter type does not match property type` —
  typed setter accepts a narrower subclass than the property declares
  (e.g. `set_visible_page(AdwPreferencesPage)` for a property typed
  as `Gtk.Widget`). Without a covariant cast this would need an
  unsafe `as`; rather than emit it, skip. The typed method is still
  reachable directly.
* `construct-only or no public setter` — `construct-only="1"` properties
  are set via the class constructor; the getter is still emitted but
  no setter (recorded as a skip on the setter half only).

The companion class itself is suppressed (no `props` field, no
`<ClassName>Props` declaration) when **every** property was skipped —
this keeps the public surface from emitting a half-broken object.

### Interface mirroring

GIR's `<class>` may declare `<implements name="..."/>` — concrete
classes advertise that they satisfy a GObject interface's contract.
The interface itself is emitted as `class GtkActionable { ... }`
(non-`final`) by [`RecordEmitter`](#recorder-emitter) (see above), so
users with an opaque pointer can still wrap it and call actionable
methods directly. The implementing class now declares the
`implements` clause (`class GtkButton extends GtkWidget implements
GtkActionable`), so Dart's structural check enforces the contract at
compile time and `button.setActionName('win.open')` works without an
explicit `as GtkActionable` cast. For ergonomic use on the concrete
widget, the class emitter mirrors every `<method>` declared on each
implemented interface onto the class as if it were its own. Result:
`button.setActionName('win.open')` compiles and dispatches to
`gtk_actionable_set_action_name` with `this.handle` — no
`GtkActionable(button.handle)` wrapper required.

```dart
// GtkButton extends GtkWidget, implements Gtk.Actionable.
class GtkButton extends GtkWidget implements GtkActionable {
  // ... <constructor>, <method>, <function>, signals ...

  // Mirrored from GtkActionable.get_action_name:
  static final _gtkActionableGetActionName = gtk4Lookup<…>(
    'gtk_actionable_get_action_name',
  ).asFunction<ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>)>();
  String? getActionName() {
    return stringFromNative(
      (_gtkActionableGetActionName(this.handle)).cast(),
      free: false,
    );
  }

  // Mirrored from GtkActionable.set_action_name:
  void setActionName([String? actionName]) {
    withNativeString(actionName, (nativeActionName) {
      _gtkActionableSetActionName(this.handle, nativeActionName.cast<Utf8>());
    });
  }
}
```

**Resolution rules** (failure → recorded skip, mirror dropped):

* Interface name in `implements_` doesn't resolve → `interface <name> not found`.
* Interface lives in a non-emitted package → `interface <name> is in non-generated package <pkg>`.
* Method name collides with a class member or another mirrored method → `name collision`.

**Override-incompatible rename** (mirrored method has a different
signature than a parent's same-named method). The mirror's signature
key is compared against:

1. The parent chain's combined method map
   (`_inheritedSigs`), which walks each ancestor and adds its own
   methods first (they shadow interface methods with the same name in
   Dart's resolution rules) and then the methods mirrored onto each
   ancestor's interfaces. This catches cases like:
   * `GtkCellAreaBox.packEnd(4 args)` shadows
     `GtkCellArea.packEnd(2 args)` (the parent absorbed `packEnd` from
     `GtkCellLayout`).
   * `GIOModule.use()` (the `GObject.TypePlugin` interface method,
     `void use()`) shadows `GTypeModule.use()` (the parent's own
     `bool use()`).

   When the signatures differ, the mirror is renamed to `<name><ClassName>`
   (`packEndCellAreaBox`, `useIOModule`) and recorded with
   `override-incompatible with ancestor; renamed to <name>`. The
   parent's method is preserved; the renamed mirror is a distinct
   method that the user can call explicitly when they want the
   interface behavior.

2. The interface's own expected signature
   (`_interfaceMethodSigs`). A class method that diverges from its
   declared interface is renamed so it doesn't claim to satisfy the
   contract. `_methodKey` is c-type-aware, so two GIR types with the
   same `<type name>` but different `c:type` (e.g. `<type name="Snapshot"
   c:type="GdkSnapshot*"/>` vs `<type name="Snapshot" c:type=
   "GtkSnapshot*"/>`) compare unequal and the rename fires. When the
   rename fires, the offending interface is dropped from the
   `implements` clause so Dart's structural check doesn't reject the
   class declaration.

**Async interface methods** mirror the same logic the class's own
methods use: a method with `scope="async"` parameter or `finishFunc`
emits a lifetime-safe `*Callback` overload alongside the base
wrapper (`button.initAsyncCallback(...)`).

**Cross-package mirrors**. When the interface is in another emitted
package (e.g. `PangoFontFamily implements Gio.ListModel`), the
emitter scans each mirrored method's parameter and return types via
the resolver. If a type's `requiredImport` is the interface's own
package — meaning the emitted Dart code references a wrapper class
that lives in that package (e.g. `GtkWidget` from `gtk4`) — the
import is added to the package barrel. If the only types referenced
are primitives, `Pointer<Void>`, or types from other already-imported
packages (e.g. `GObject` from `gobject`), the import is suppressed
to avoid `unused_import` warnings.

**Namespace-relative type resolution**. The mirror's
`CallableEmitter.emit` call threads the interface's namespace
through to `bridgeFor` via a `relativeTo` parameter, so parameter and
return types resolve against the interface's own namespace, not the
implementing class's. Without this, `GdkPaintable.snapshot(GdkSnapshot,
…)` would be re-bound to `GtkSnapshot` when mirrored onto
`GtkIconPaintable` and the `implements GdkPaintable` structural check
would fail with `invalid_override` (the two classes are typedef'd to
the same C type but resolve to different Dart names per namespace).

**Interface signals**. The `implements_` chain is walked by both
`inheritedSignals` (per-class inheritance of `onSignalName`
connectors) and `_signalsIncludingAncestors` (per-package emission of
the `_connectSignal_<bucketId>` helpers in `signals.dart`). Without
this walk, `class GtkStringList extends GObject implements GListModel`
was missing the `onItemsChanged` connector the `GListModel` interface
declared, and the package's `signals.dart` was missing the
`_connectSignal_v_3_i_i_i_int_int_int` helper the connector called
(`unknown_method _connectSignal_v_X` from the analyzer).

## CallableEmitter — `generator/lib/src/emit/callable.dart`

Used by every emitter that produces a function-shaped wrapper (methods,
constructors, static functions, top-level functions, callback wrappers).

For each call it emits:

1. A private native binding `<int Function(...)> _<name>Native(...)` that
   does the FFI lookup, parameter marshalling, native call, and return
   conversion.
2. A public Dart wrapper `<dartReturn> <name>(...)` that calls the
   private native binding.

### Parameter marshalling

Each `<parameter>` is classified:

| GIR kind | Wrapper type | Native type | Marshalling |
|---|---|---|---|
| primitive (`gint`, `gdouble`, `gboolean`) | `int` / `double` / `bool` | `ffi.Int32` / `ffi.Double` / `ffi.Int32` (gboolean) | Direct |
| string (`utf8`, `gchar*`, `filename`) | `String` / `String?` | `Pointer<Utf8>` | `withNativeString` outer wrap |
| string list | `List<String?>?` | `Pointer<Pointer<Utf8>>` | `withNativeStringList` outer wrap |
| class/record/union/interface | wrapper class | `Pointer<Void>` | `.handle` ↔ `fromPointer(ptr)` |
| enum / bitfield | wrapper class | `Int32` / `Uint32` | `.value` ↔ `Wrapper.fromValue(...)` |
| callback | inline Dart signature (nullable for `nullable="1"`) | `Pointer<NativeFunction>` | `NativeCallable.isolateLocal` wrap + `.close()` in `finally` (conditional on null for nullable callbacks) |
| out / inout | wrapper type | `Pointer<...>` | `calloc<...>` + `.value` extraction |
| bound-length array of primitive/enum/bitfield/bool | `ffi.Pointer<ffi.Int32>` (or `Uint32` for bitfields) | same | Direct (user `calloc<Int32>(n)`); the GIR's `<array length="N">` resolves to a sibling `int` parameter at index `N` that the natural parameter iteration adds to the signature |
| bound-length array of class/interface/record | `ffi.Pointer<ffi.Void>` | same | Direct (user passes `Pointer<ffi.Void>`); `<array length="N">` binds to a sibling `int` parameter. Typed `asTypedList(n)` iteration is deferred until generated records become real `StructBase` subclasses. |
| unbound primitive/enum/bitfield array (`<array c:type="…">` with no `<array length>`) | `ffi.Pointer<ffi.Int32>` (or `Uint32`) | same | Direct; the user provides length via a sibling `get_n_items` accessor. |
| caller-provided byte array (`<array length="N">` of `guint8`/`guchar`, `direction="in"`) | `Uint8List` | `Pointer<Uint8>` | `withNativeBytes` outer wrap — the list is mirrored into a `g_malloc`ed buffer, the count is absorbed from the signature, and `owned: true` hands the buffer to the callee (`transfer="full"`). |

The wrapper type for a class/record/union/interface carries the package
name when the declaring namespace differs from the current namespace
(emit context adds the package to `ctx.imports`).

### Callback parameters

User-supplied callbacks are **not** aliased to a typed function pointer at
the call site. Instead, `CallableEmitter.emit` allocates a temporary
`NativeCallable<T>` with the wrapper signature in `T`, captures the
user's Dart callback, and closes the callable in a `finally` block:

```dart
final callable = ffi.NativeCallable<...>.isolateLocal(callback);
try {
  _someFunctionNative(..., callable.nativeFunction);
} finally {
  callable.close();
}
```

The Dart `typedef` for the callback is still emitted (named after the
GIR `c:type`, e.g. `GCompareDataFunc`) so callers can name the type, but
the call site uses the inline signature for `NativeCallable` to work
around `Pointer.fromFunction`'s static-function constraint.

Nullable callback parameters (e.g. `notify` on `g_idle_add_full`) take
the wrapper parameter type with a trailing `?` and become trailing
positional optional parameters in the Dart signature. The
`NativeCallable` allocation is conditional on the user passing a
function, and the call site forwards either `.nativeFunction` or
`ffi.nullptr`. The `finally` block uses `?.close()` so the cleanup is
also conditional:

```dart
final _nc = notify == null
    ? null
    : ffi.NativeCallable<...>.isolateLocal(notify);
try {
  _native(..., _nc?.nativeFunction ?? ffi.nullptr);
} finally {
  _nc?.close();
}
```

This pattern is only safe for callbacks invoked **synchronously** inside
the call — see `g_async_queue_sort` in `packages/glib/test/glib_smoke_test.dart`
for a working example. Long-lived callbacks (idle sources, timeout
sources, signal handlers, …) register a C function pointer that GLib
later invokes from the main loop; the wrapping `NativeCallable` would
already be `.close()`d by then. For those, build a `Pointer` via
`Pointer.fromFunction` with a top-level Dart function whose lifetime
outlives the source, or use `connectSignal` /
`g_signal_connect_data` directly.

### Variadic / skipped

* Varargs (`...`) parameters → skip with `varargs`.
* Moved/shadowed functions → skip with the destination.

### OUT parameters

GIR `direction="out"` parameters come in three flavors, and the **pointer
depth of the parameter's `c:type`** decides which one applies.

**Primitive OUT** (`gint*`, `guint32*`, `gboolean*`, …). The size is
known at compile time, so the wrapper allocates one slot of the pointee
with `malloc<T>()` and frees it in `finally`:

```dart
gint value() {
  final _out0 = malloc<ffi.Int32>();
  try {
    _someFunction(_out0);
    return _out0.value;
  } finally {
    malloc.free(_out0);
  }
}
```

**Struct OUT** (`GtkTextIter*`, `GdkRGBA*`, `GITypeInfo*` — one star).
GLib writes the *entire struct* (not a pointer to it) into the
caller-provided buffer, but the generator has no static `sizeof(T)` to
allocate the right amount. The previous implementation under-allocated
(8 bytes for a 32-byte struct), causing heap corruption, and then freed
the buffer in `finally` — invalidating the returned wrapper's handle
and crashing on the next C deref.

The fix uses a `HeapAnchor` from `package:gir_ffi`:

```dart
GtkTextIter getStartIter() {
  final _out0Anchor = HeapAnchor.allocate(256);
  final _out0 = _out0Anchor.buffer;
  _gtkTextBufferGetStartIter(this.handle, _out0.cast<ffi.Void>());
  return keepAlive(
    GtkTextIter.fromPointer(_out0.cast<ffi.Void>()),
    _out0Anchor,
  );
}
```

The anchor's `Finalizable` + `NativeFinalizer` frees the buffer, but
only once nothing holds it any more. The wrapper *is* that holder: the
wrapper is a view into the caller's buffer, so it has to keep the
buffer alive for as long as it lives. `keepAlive` (also in
`package:gir_ffi`) ties the anchor to the wrapper through a weak-keyed
`Expando`; drop the wrapper and the anchor becomes unreachable, the
finalizer calls `malloc.nativeFree`.

Without that tie the anchor was unreachable the moment the method
returned — the collector freed the buffer while the wrapper was still
reading from it, and `GtkTextBuffer.getBounds` crashed about one run
in eight.

`usesGirFfi` is set so the package barrel adds
`import 'package:gir_ffi/gir_ffi.dart';` automatically.

The 256-byte size is a deliberate blanket upper bound — it covers
every struct currently in the GIR corpus (largest is `PangoLayoutRun`
at ~176 bytes) and keeps allocation O(1) per call. Per-type sizing
(using a future GIR `sizeof` annotation or a build-time probe) is a
known follow-up.

**Pointer OUT** (`GUnixFDList**`, `GFile**` — two stars). The C function
writes a *pointer* into the caller's slot, so the value is the object
that pointer refers to, not the slot. The slot is a pointer-sized cell,
zeroed so an out parameter the C function leaves untouched reads as
NULL rather than as a wild pointer, and it is freed as soon as the call
returns:

```dart
GUnixFDList? fdList() {
  final _out0 = calloc<ffi.Pointer<ffi.Void>>();
  try {
    _someFunction(_out0);
    return (_out0.value) == ffi.nullptr
        ? null
        : GUnixFDList.fromPointer(_out0.value.cast<ffi.Void>(), owned: true);
  } finally {
    malloc.free(_out0);
  }
}
```

`owned: true` comes from the GIR's `transfer="full"`: the C function
hands the reference over, so the wrapper owns it and releases it when
it is collected.

**Byte-buffer OUT** (`char**`, `guchar**` — two stars, an array of
bytes). This is the shape of `g_file_load_contents`' `contents`: the C
function *allocates* the buffer, fills it, and writes the pointer into
the caller's slot. A sibling parameter carries the byte count, and the
GIR binds the two together with `<array length="N">` — `N` is the
0-based index of the count parameter in the callable's parameter list.

The wrapper copies the bytes into a Dart `Uint8List` and releases the
native buffer. A raw pointer would not do: the garbage collector cannot
see native memory, so a buffer handed over with `transfer="full"` would
leak, and a `Uint8List` leaves the user with plain Dart memory and no
lifetime rules.

```dart
(bool, Uint8List, String?) loadContents([GCancellable? cancellable]) {
  final _out0 = calloc<ffi.Pointer<ffi.Uint8>>();
  final _out1 = malloc<ffi.Size>();
  final _out2 = malloc<ffi.Pointer<Utf8>>();
  final _error = calloc<ffi.Pointer<ffi.Void>>();
  try {
    final _ret = _gFileLoadContents(
      this.handle, cancellable?.handle ?? ffi.nullptr,
      _out0, _out1, _out2, _error,
    );
    if (_error.value != ffi.nullptr) {
      throw GlibException.fromError(_error.value);
    }
    return (
      (_ret) != 0,
      bytesFromNative(_out0.value.cast<ffi.Uint8>(), _out1.value),
      stringFromNative(_out2.value.cast(), free: true),
    );
  } finally {
    malloc.free(_out0);
    malloc.free(_out1);
    malloc.free(_out2);
    calloc.free(_error);
  }
}
```

The byte count is **absorbed** into the buffer: the count is a property
of the buffer, so it is not a second element of the returned record. The
count's slot is still allocated — the C function writes into it — and
still released, but the Dart API does not repeat it.

The shape is narrow on purpose. A parameter qualifies when it is
`direction="out"`, `caller-allocates="0"` (the *callee* allocates),
`transfer-ownership="full"` (the caller owns it), an array of bytes
handed over as a double pointer, and it has a length binding. That
excludes the look-alikes: `g_spawn_sync`'s `standard_output` (a
`gchar**` with no length binding — the size would have to come from
`strlen`), `g_utf8_validate`'s `end` (a `const gchar **` pointing *into*
the input, and `transfer-ownership="none"`), `g_base64_encode_step`'s
`out` (a single `gchar*`), and the caller-allocated buffers of
`g_input_stream_read`.

`bytesFromNative` (in `package:gir_ffi`) does the copy and the release;
`gFree` resolves `g_free` through an explicitly opened GLib, because a
`dlopen`ed library is not part of the process-global symbol namespace.

**Byte-array IN** (`<array length="N">` of `guint8` / `guchar`, direction
`in`). This is the mirror of the byte-buffer OUT: the *caller* owns the
buffer, hands it to the callee, and a sibling parameter carries the
byte count. It is the shape of `g_bytes_new`'s `data` and of
`g_file_replace_contents`' `contents`.

The wrapper takes a Dart `Uint8List` and mirrors it into a
GLib-allocated native buffer for the call. The byte count is **absorbed**
the same way it is on the OUT side: it is the length of the list, so it
disappears from the Dart signature while the native signature keeps it
(the C ABI needs it).

```dart
factory GBytes(Uint8List data) {
  return withNativeBytes(data, (_bytesBuf0, _bytesLen0) {
    return GBytes.fromPointer(_gBytesNew(_bytesBuf0, _bytesLen0));
  });
}
```

`withNativeBytes` (in `package:gir_ffi`) allocates the buffer with
`g_malloc` — the allocator GLib frees its own memory with — copies the
bytes in, and copies them back out afterwards. The copy-back is what
makes a caller-provided *output* buffer work: `g_converter_convert`'s
`outbuf` and `g_buffered_input_stream_peek`'s `buffer` are filled by the
callee, and the bytes land in the caller's list. For a pure input the
copy-back is a no-op.

`transfer-ownership="full"` flips the ownership: the callee owns the
buffer and releases it with `g_free`, so the wrapper neither releases
nor copies back — it hands the buffer over (`withNativeBytes(..., owned:
true)`). `g_bytes_new_take` and `g_byte_array_new_take` are that shape.

The rule is narrow on purpose. A parameter qualifies when it is
`direction="in"`, an array of **unsigned** bytes (`gchar` arrays are
text, not bytes), it has a length binding (`<array length="N">` with
`N > 0` — `length="0"` is the GIR's way of saying "not length-bound"),
the count sibling is an IN integer, the callable has **no**
`GDestroyNotify` sibling, and the callable is **not async**.

The last two exclusions are the interesting ones:

* A `GDestroyNotify` sibling means the callee takes over the buffer's
  *lifetime* — `g_variant_new_from_data`,
  `g_memory_input_stream_new_from_data`,
  `g_tls_password_set_value_full`. The buffer cannot be a temporary
  that dies with the call, so those keep a raw pointer.
* An async callable keeps its buffer past the call. GIO says it
  outright for `g_file_replace_contents_async`: *"no copy of `@contents`
  will be made, so it must stay valid until `@callback` is called"*. The
  `GBytes` variant (`g_file_replace_contents_bytes_async`) is the one
  that works asynchronously — GIO holds a reference to the bytes "for
  the duration of the call" without copying them.

A byte-array parameter also rules out the generative-constructor form of
a constructor: the mirroring needs a body, and a generative initializer
list has none. `GBytes(Uint8List)` is therefore a factory constructor.

Caveat documented for users: GTK functions that *copy* an OUT struct
into GTK-owned memory (e.g. `gtk_text_iter_copy`) keep using the
caller's pointer for the copy; the anchor protects only the buffer we
handed to GLib. If a returned wrapper's lifetime exceeds the buffer's
(rare, but possible if GTK holds the pointer past the Dart GC), the
finalizer will free it and the next access from native code will SEGV.
Use `Pointer<...>` directly when you need full control.

## CallbackEmitter — `generator/lib/src/emit/callback_emitter.dart`

Emits `<callback>` declarations as Dart function typedefs:

```dart
typedef GDestroyNotify = void Function(ffi.Pointer<ffi.Void> data);
```

The typedef's name matches the GIR `c:type` so users can refer to the
canonical C identifier. Nullable callback **return** types are still
skipped (none of the GIR files in scope declare one) — see
[skip-categories.md](./skip-categories.md). Nullable callback
**parameters** are accepted and emitted via the conditional pattern
described above.

## AsyncCallbackEmitter — `generator/lib/src/emit/async_emitter.dart`

Emits the lifetime-safe `*Callback` convenience overload alongside
every async method (a method whose callback parameter carries
`scope="async"` AND whose callback type is `GAsyncReadyCallback`).

The base wrapper (emitted by `CallableEmitter`) is unsafe for
async callbacks because it closes its wrapping `NativeCallable` in
`finally` — leaving a dangling C function pointer when GLib later
dispatches the callback from the main loop. The `*Callback` overload
replaces the `NativeCallable` with a permanent `Pointer.fromFunction`
over a static trampoline + a per-call registry:

```dart
// Generated alongside `void open(...)`:
void openCallback(
  GtkWindow? parent,
  GCancellable? cancellable,
  void Function(GObject? sourceObject, GAsyncResult result) topLevel,
);

static final _openCallbackRegistry =
    <int, void Function(GObject?, GAsyncResult)>{};
static int _openCallbackSeq = 0;
static final _openCallbackPtr = ffi.Pointer.fromFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>)>(_openCallbackTrampoline);

static void _openCallbackTrampoline(
  ffi.Pointer<ffi.Void> sourceObject,
  ffi.Pointer<ffi.Void> res,
  ffi.Pointer<ffi.Void> data,
) {
  final id = data.cast<ffi.IntPtr>().value;
  final fn = _openCallbackRegistry.remove(id);
  malloc.free(data);
  if (fn == null) return;
  fn(
    sourceObject == ffi.nullptr
        ? null
        : GObject.fromPointer(sourceObject.cast()),
    GAsyncResult.fromPointer(res.cast()),
  );
}
```

`Pointer.fromFunction` is permanent (lifetime = program), the
trampoline is a static method so `Pointer.fromFunction` accepts it,
and the per-call `id` (carried in the malloc'd `data` pointer) routes
the dispatch back to the user's typed callback. No `NativeCallable`
to close, no dangling pointer risk.

The convenience overload:

* **hides `user_data`** — always passes `ffi.nullptr` internally.
  Dart closures already capture state.
* **types the callback** — `void Function(GObject?, GAsyncResult)`
  for `GAsyncReadyCallback`. Other async callbacks fall back to the
  FFI-compatible shape with `Pointer<Void>` parameters.

Methods with multiple `scope="async"` callback parameters (e.g.
`g_file_copy_async` with its progress callback) target the
`GAsyncReadyCallback` specifically; the other async callbacks keep
their existing emission.

See [async.md](./async.md) for the user-facing guide and
[signals.md](./signals.md) for the related signal-helper pattern.

## SignalHelper — `generator/lib/src/emit/signals_helper.dart`

Emits `lib/src/signals.dart` when at least one kept signal exists.

Per-package contents:

1. **`_gSignalConnectData`** — one-time FFI binding for
   `g_signal_connect_data`. Casts the trampoline pointer to
   `Pointer<NativeFunction<void Function(Pointer<Void>, Pointer<Void>)>>`
   so any bucket signature is assignable at the call site.
2. **`_signalRegistryOwner`** — `Map<int, Map<int, Function>>` mapping each
   live handler id to its bucket's registry. Destroy-notify reads this
   to clean up only the owning bucket.
3. **`_nextSignalId` / `_destroySignalState`** — id allocator + shared
   destroy-notify trampoline.
4. **One bucket per `(FFI shape × Dart type signature)`** — see
   [signals.md](./signals.md) for the partitioning rule. Each bucket
   declares: `_signalRegistry_<id>` (`Map<int, TCallback>`), the trampoline
   `_signalTrampoline_<id>`, the per-bucket `NativeCallable
   _signalCallable_<id>`, and `_connectSignal_<id>(handle, name,
   callback)`.
5. **`connectSignal(handle, name, callback)`** — public escape hatch that
   uses the synthetic `v_0_` bucket for arbitrary signal names (e.g.
   `notify::property-name`).

The barrel's `part 'src/signals.dart';` plus the file-level
`part of '../<pkg>.dart';` makes the singletons reachable from every
class in the same library without an extra import.

## Cross-package imports

Every emitter that resolves a cross-package type calls
`ctx.bridgeFor(...)`, which records the required package via
`ctx.imports.add(...)`. `emitter.dart` then writes a deduplicated
`import 'package:<name>/<name>.dart';` for each entry when emitting the
barrel. `pubspecFor` mirrors this in `pubspec.yaml` as path-deps. The
filter excludes `gir_ffi` (already hard-coded in the barrel + pubspec).
