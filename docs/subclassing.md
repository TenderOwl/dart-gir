# Dart-level subclassing

The generated wrappers are plain Dart classes, and they are written so
that *your* code can extend them. This document states what that
gives you, what it costs, and — just as importantly — what it does
**not** give you.

The worked example lives in
[`packages/gtk4/test/gtk4_subclass_test.dart`](../packages/gtk4/test/gtk4_subclass_test.dart);
every claim below is exercised there.

> **Status: on `main`.** The contract described here is committed — the
> generator test that pins it is in `main`, and the `composite-templates`
> branch, the last place it could have been waiting, is a superseded
> prototype. See [branch-state.md](./branch-state.md) for the comparison
> and for how to re-check it.

---

## 1. What is supported

```dart
class TitledButton extends GtkButton {
  TitledButton(String label) {
    setLabel(label);
  }

  @override
  GtkButton? getParent() { … }

  @override
  TitledButtonProps get props => _titledProps;
}

class TitledButtonProps extends GtkButtonProps {
  TitledButtonProps(TitledButton button) : _button = button, super(button);
  final TitledButton _button;
}
```

Three things are possible:

1. **Extend a generated class.** `class TitledButton extends
   GtkButton` — the generated class is emitted as `class`, not
   `final class`, so it is extendable from another library.
2. **Narrow a return type covariantly.** `GtkWidget? getParent()`
   becomes `GtkButton? getParent()`. Dart allows a covariant
   override; the generator emits the base signature so the narrowing
   is legal.
3. **Extend the props companion.** `GtkButtonProps` is public and
   emitted as `class` (not `final class`, not `_GtkButtonProps`), and
   a child's companion extends its parent's, so
   `GtkToggleButtonProps extends GtkButtonProps`. You can add typed
   accessors on top of the generated ones.

The generated side of this contract is pinned by the generator tests
in `generator/test/emitter_test.dart` (group *Dart-level subclassing
contract*). A change that reintroduced `final class` would break
every downstream subclass without failing a single test — which is
why those assertions exist.

---

## 2. What this is **not**

**A Dart subclass is not a GObject subclass.**

Your subclass does not register a `GType`. GTK has no idea it
exists:

- You cannot ask GTK to instantiate your class. `gtk_button_new()`
  returns a `GtkButton`; nothing in the native world can produce a
  `TitledButton`.
- You cannot use your class where GTK expects a custom widget type
  (`GtkBuildable`, `gtk_widget_init_template`, a `GType` in a
  `GtkBuilder` XML file).
- The native type of the object is unchanged. `typeNameFromInstance`
  still reports `GtkButton`.

Registering a real native subclass means registering a `GType`,
installing a `GObjectClass`, and handling the vtable — a different
project. This document is about the Dart-level capability only.

---

## 3. Ownership

**The wrapper owns the native pointer. Your subclass does not.**

`super()` runs the generated constructor, which allocates exactly one
native object and attaches the finalizer to *that* Dart object. Your
subclass is the same Dart object — there is no second allocation and
no second owner.

```dart
final button = TitledButton('Hello');   // one native GtkButton
final parent = inner.getParent();        // same native object, re-wrapped
```

### `cast<T>()` re-wraps, it does not copy

```dart
T cast<T extends Object>(T Function(ffi.Pointer<ffi.Void>) factory) {
  return factory(handle);
}
```

`cast` forwards the handle unchanged. The *original* wrapper remains
the owner: the narrowed wrapper has no finalizer of its own and does
not unref anything. If you drop every reference to the original
wrapper, the finalizer runs and the native object is finalised —
narrowed wrappers do not keep it alive.

The `cast` method's type parameter is bound to `Object`, not to the
class itself, precisely so that a subclass can override it with a
narrower bound.

### The props companion holds the widget, and the widget holds the companion

The generated class declares

```dart
late final GtkButtonProps _props = GtkButtonProps(this);
GtkButtonProps get props => _props;
```

and the companion holds `final GtkButton _self;`. That is a cycle —
the widget references the companion and the companion references the
widget. Dart's tracing garbage collector handles cycles correctly
(they are not reference-counted), so this is not a leak. It does mean
the two objects stay alive as long as *either* is reachable.

The companion's `_self` field is **private to the generated package**.
A user-side companion cannot read it, so it keeps its own typed
reference:

```dart
class TitledButtonProps extends GtkButtonProps {
  TitledButtonProps(TitledButton button) : _button = button, super(button);
  final TitledButton _button;
}
```

---

## 4. A covariant override is a promise you have to keep

Overriding `getParent()` with a narrower return type changes the
**static Dart type**. It changes nothing about the native object:

```dart
@override
GtkButton? getParent() {
  final parent = super.getParent();
  if (parent == null) return null;
  // Only narrow if the native object really is a button.
  final name = typeNameFromInstance(GTypeInstance.fromPointer(parent.handle));
  if (name != 'GtkButton') return null;
  return parent.cast<GtkButton>(GtkButton.fromPointer);
}
```

An override that narrowed *without* checking would hand callers a
`GtkButton` wrapping something that is not a button. Nothing would
complain at the cast: `cast` forwards the handle as-is. The failure
would surface later, as a misbehaving native call, far from the
override that caused it.

**The generator cannot check this for you.** The narrowing is an
assertion about the native object's type, and the only place that can
be verified is at run time, against the GObject type name.

### Overrides replace the behaviour for every caller

Dart dispatches virtually. An override is not "a more specific
version for people who know the type" — it *is* the implementation,
for every caller:

```dart
final button = TitledButton('Hello');
final asWidget = button as GtkWidget;
asWidget.getParent();   // calls TitledButton.getParent()
```

If you need the generated behaviour back, call `super` explicitly and
expose it under a different name.

---

## 5. Lifetime

### The native object lives as long as the Dart wrapper

`fromPointer(handle, owned: true)` attaches a `NativeFinalizer` that
unrefs the object when the Dart wrapper is collected. Your subclass
inherits that: it is the same Dart object, so the same finalizer
applies. Holding a Dart reference to the widget keeps the native
object alive.

### A signal handler that captures `this` keeps both alive

The typed signal helpers take a closure. A closure that captures
`this` holds a strong reference to the Dart object, and the native
signal connection holds the closure for the widget's lifetime. The
Dart object therefore stays reachable, so its finalizer does not run
and the native object is not finalised while the signal is connected.

This is the rule behind the "keep it alive for the object's lifetime"
note in the callback table: a long-lived signal handler must be a
top-level or static function, or must deliberately keep the object
alive.

### Dropping the Dart reference finalises the native object

When the last Dart reference goes away and the finalizer runs, the
native object is unreffed. If the native side still holds a
reference of its own (GTK's widget tree, for example), the object
survives — the finalizer only releases *this* reference.

### `owned` says whether the wrapper still holds the reference

Every generated class, record and interface carries a public
`bool owned` field. It is the wrapper's claim on the reference:

- `true` — the wrapper holds the reference the GIR handed over, and its
  finalizer releases it when the wrapper is collected.
- `false` — the reference has been released (`unref()`, `free()`) or
  handed to the callee, and the wrapper must not release it again.

```dart
final file = GFile.newForPath('/tmp/notes');
expect(file.owned, isTrue);   // the GIR says transfer-ownership="full"
file.unref();
expect(file.owned, isFalse);  // released once, by the caller
```

The field is **mutable** on purpose: a handover to a callee clears it,
so the same rule covers both directions. A parameter the GIR marks
`transfer-ownership="full"` belongs to the callee from the call on, so
the call site hands the reference over — the finalizer is detached and
`owned` is set to `false`:

```dart
// `gtk_widget_add_controller` takes the controller over.
controller.owned;            // true before the call
window.addController(controller);
controller.owned;            // false after it — the callee owns it now
```

Your subclass inherits the flag with the rest of the wrapper: it is one
Dart object, one claim, one finalizer. A subclass that releases the
reference itself must let the wrapper know — call `unref()` rather than
`g_object_unref` behind the wrapper's back, or the collector will
release it a second time.

---

## 6. Cross-package subclassing

Nothing in the contract is package-local:

- The generated class is public and extendable, so
  `class MyThing extends Gtk.Widget` works from any package that
  depends on `package:gtk4`.
- The props companion is public too, so
  `class MyThingProps extends Gtk.WidgetProps` works the same way.
- The generated constructor chains to `fromPointer`, so a subclass
  can call `super()`.

The dependency direction does not change: your package depends on the
generated package, never the other way round.

---

## 7. Known limits

- **Some constructors are factories, not generative constructors.** A
  generated `<constructor>` is emitted as a *generative* constructor
  only when it has no `throws`, no OUT parameters, no string or
  string-list parameters, and no callback parameters — those need a
  body to host the `withNativeString` / `NativeCallable` lifetime
  management, and a generative initializer list has nowhere to put
  it. A Dart subclass cannot call a factory with `super()`, so such a
  class cannot be given a forwarding constructor. Construct it
  through the factory and re-wrap it with `cast` instead.

  ```dart
  // Works: `AdwWindow()` has no parameters.
  class MyAdwWindow extends AdwWindow {
    MyAdwWindow() : super();
  }

  // Does not work: `AdwApplication.new` takes a `String? applicationId`,
  // so it is a factory.
  // class MyAdwApplication extends AdwApplication {
  //   MyAdwApplication() : super(null, GApplicationFlags(0));  // error
  // }
  ```

  `example/gtk4_examples/bin/subclass_smoke.dart` exercises the working case.

- **No native subclassing.** See §2.
- **The narrowed type is not verified by the toolchain.** See §4.
- **The props companion's `_self` is private.** A user-side companion
  needs its own reference to the widget. See §3.
- **Signals connected to a subclass instance keep the Dart object
  alive** for the connection's lifetime. See §5.
- **A generated method whose signature is incompatible with an
  ancestor's is renamed**, not overridden — the skip report records
  it as `override-incompatible with ancestor; renamed to <X>`. A
  subclass overriding such a method must use the renamed spelling.
