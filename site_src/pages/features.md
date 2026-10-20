---
title: Everything the generator gives you
description: Typed properties, typed signals, interface mirroring, caller-allocated OUT parameters, async overloads, skip reports and one-class-per-file emission in dart-gir.
nav_order: 2
nav_label: Features
section_label: Feature list
---

Each item below is implemented in the generator and present in the checked-in output, not aspirational. Where a feature has limits, the limit is stated next to it.

## Typed properties

Every GObject-rooted class gets a `<ClassName>Props` companion reached through `.props`. Each accessor delegates to the already-generated typed `get<Name>()` / `set<Name>(value)` methods — no `GValue` boxing, no attribute-string lookups, no `dynamic`. **{{facts.features.props_accessors}} accessors** across {{facts.features.props_classes}} props classes.

```dart title="generated props class"
class GtkButtonProps extends GtkWidgetProps {
  GtkButtonProps(GtkButton $self) : _self = $self, super($self);
  final GtkButton _self;

  // Type and nullability come from the typed method's bridge,
  // never from the property's raw <type> element.
  bool get canShrink => _self.getCanShrink();
  set canShrink(bool value) => _self.setCanShrink(value);

  String? get label => _self.getLabel();
  set label(String value) => _self.setLabel(value);
}
```

- **Inheritance works.** `props.canFocus` is declared on `GtkWidgetProps` and reachable on every descendant, with no redeclaration.
- **Nullability is honest.** A property backed by a `gchar*` with `transfer-ownership="none"` is `String?`, because the native getter genuinely can return NULL. The accessor type is derived from the typed method's bridge, so it cannot drift into a type lie.
- **Explicit field types.** `late final GtkButtonProps _props` — Dart's late-final inference would otherwise adopt the parent's type and break every child's covariant override with `invalid_override`.

:::{note variant=plain} Known limit
A property whose typed getter or setter is not representable as a no-arg getter / single-arg setter — `get_size(orientation)`, `set_text(text, length)`, `set_visible_page(…)` — is recorded in the skip report with a precise reason instead of being emitted wrong. The typed method is always still available.
:::

## Typed signal handlers

**{{facts.features.typed_signals}}** generated `onSignalName(callback)` methods with real Dart parameter types, bucketed by `FFI shape × Dart signature` so a single trampoline serves every signal that shares a shape.

```dart title="inherited signals"
// Gtk.Widget::direction-changed, reachable on any Gtk.TextView
textView.onDirectionChanged((GtkTextDirection previous) {
  print('now ' + previous.name);
});

// Gtk.Application::window-added, reached from Adw.Application
app.onWindowAdded((GtkWindow window) { ... });

// notify with a detailed name — no typed helper, so use the escape hatch
textView.connectSignal('notify::cursor-position', (params) { ... });
```

- **Inherited by default.** The emitter walks the full parent chain, keyed by *qualified* class name — so `Adw.Application` correctly continues to `Gio.Application` even though both classes are locally named `Application`.
- **Cross-package types resolve against the author.** A signal declared in `Gtk` but emitted into `Adw` resolves its `Window` argument to `GtkWindow`, not `AdwWindow`.
- **Dedup by identity, not by name** — `Gio.DBusObject::interface-added` and `Gio.DBusObjectManager::interface-added` have different arities and stay separate buckets.
- **transfer-none strings are freed.** Strings coming out of a trampoline are released through a `g_free` binding resolved out of the running process.
- **Destroy-notify is per-bucket.** Teardown cleans up only the owning bucket's registry slot, so disconnecting one signal cannot corrupt another.
- **`connectSignal` escape hatch** for anything the generator will not type: detailed names, arity above 5, weak-ref signals, untypable arguments. Same trampoline path.

## Interface methods mirrored onto concrete classes

GIR models interfaces as separate types, which in practice means wrapping your own object to call one method. dart-gir emits an interface's methods onto every implementing class.

```dart title=mirrored
button.setActionName('win.open');
```

```dart title="what you had to write"
GtkActionable(button.handle)
    .setActionName('win.open');
```

- Same native symbol, same `this.handle` self-argument, same wrapper pattern — mirroring is additive, not a second code path.
- The interface is still emitted as a concrete class, so wrapping an opaque pointer keeps working when you genuinely have one.
- **Override-incompatible shadows are renamed, not dropped.** `GIOModule.use` shadowing `GTypeModule.use` with a different signature is detected against the parent's combined method map and emitted as `useIOModule`.
- Async interface methods receive the same lifetime-safe `*Callback` overload as native async methods — **{{facts.features.async_callbacks}}** of them are emitted today.

## Safe callbacks, including async ones

A callback parameter is the easiest way to write a use-after-free in FFI. The generator has two distinct strategies and applies the safe one automatically.

:::{cols}
### Synchronous callbacks

A `NativeCallable.isolateLocal` is allocated at the call site and closed in a `finally`. Safe because the native callee cannot retain it past the call. Nullable callback parameters are supported — nothing is allocated or closed if you pass `null`, which is what unblocked the whole family of GLib `g_*_add_full` source functions.

### Asynchronous callbacks

Never `.close()` a `NativeCallable` that GLib may invoke later. The `*Callback` overloads instead route dispatch through a permanent `Pointer.fromFunction` over a static trampoline plus a per-call registry, so no `NativeCallable` is ever closed and `user_data` stays an internal implementation detail.
:::

:::{note variant=warn} The one caveat, stated plainly
The synchronous strategy is only correct for callbacks invoked *before* the native call returns. For a long-lived callback — an idle source, a timeout, a signal handler — pass a top-level or static Dart function and keep the wrapper alive; a closure that only exists inside the call is not safe to retain natively. This is documented in `docs/emission.md` and `docs/async.md`.
:::

## Caller-allocated OUT parameters become return values

C APIs that fill a caller-supplied struct are the worst part of FFI by hand. The generator allocates the buffer, calls through, reads the value back through the type's `fromPointer` factory, and hands you a value.

```dart title="out parameter"
// C: void gtk_text_buffer_get_start_iter(GtkTextBuffer*, GtkTextIter* out);
final iter = buffer.getStartIter();   // GtkTextIter
final text = buffer.getText(iter, buffer.getEndIter(), false);
```

- Primitive OUT params (`gint*`, `guint32*`, `gboolean*`) free their buffer in a `finally`.
- Record and class OUT params are anchored with `HeapAnchor` from `package:gir_ffi` — a `Finalizable` with a `NativeFinalizer(malloc.nativeFree)`, so the buffer lives exactly as long as the returned wrapper is reachable and is freed on GC.
- Emitting this path cut the workspace's skip count by roughly 282 symbols with no regressions.

:::{note}
**This feature has a scar on it.** The first implementation malloc'd 8 bytes for a 32-byte struct — `free(): invalid next size` — and then freed the backing buffer before the returned wrapper had dereferenced it, producing a SEGV inside `gtk_text_iter_get_buffer`. Both are recorded in the changelog, and both now have end-to-end tests. It is a good illustration of why pointer lifetime belongs in the generator rather than in application code.
:::

## The plumbing you stop doing by hand

:::{cols}
### Cross-package wiring

The resolver emits imports and path-dependencies automatically. `Adw` classes use `GtkWidget`, `GdkCursor` and `GObject` without a single manual `path:` entry. A cross-package import is added only when an emitted body actually references a type from that package.

### Type resolution by `c:type`

A built-in scalar table plus a declared-type table, with cross-namespace deduplication driven by canonical `c:type` values — so `GList` and its many spellings resolve to one Dart type.

### Namespace functions

GLib's root-level functions are surfaced as real Dart wrappers (`g_get_user_data_dir`, `g_idle_add_full`, `g_io_add_watch_full`), with a precise skip reason for the non-introspectable C macros that have no symbol to bind to.

### Nullable and ownership-aware types

`transfer-ownership="none"` pointers become nullable, transfer-full strings are copied and freed, and ownership transfers are treated as correctness concerns rather than formatting.
:::

## Small things that add up

- **One Dart class per file, named after the class.** `class GtkButton` lives in `lib/src/gtkbutton.dart`, its props companion in `lib/src/gtkbutton_props.dart`. `Ctrl+Click` on a class name lands in a file that is recognisably that class. All files stay `part of` the same library, so the public barrel is unchanged and forward references still resolve.
- **Per-package `signals.dart`** with one trampoline and typed registry per shape bucket, plus a shared destroy-notify.
- **Handwritten runtime helpers** in `package:gir_ffi` — string marshalling, `withNativeStringList` (NULL-terminated argv, distinguishing `null` from empty), `gFree`, `HeapAnchor`.
- **Per-namespace library loading.** Each package gets a generated `<ns>Libs` list and a `<ns>Lookup<T>(symbol)` helper that tries each candidate library in turn, then the running process — so symbols that live in a sibling library are still reachable.
- **Analyzer-aware emission.** Generated packages carry a curated set of lint suppressions for genuine FFI false positives, and keep the doc-comment HTML suppression the GIR docs require.
- **Immutable GIR data model** covering class, interface, record, union, enumeration, bitfield, callback, function, constant, alias, signal, property, method, constructor, parameter — with transitive include resolution.
- **Tokenizer-based renaming** that splits snake_case into Dart camelCase and resolves Dart keywords, so `get_surface` becomes `getSurface` and nothing collides with the language.

## Coverage, and the honest gaps

Every symbol the generator cannot emit is written to `packages/<lib>/skip_report.txt` with a category and a reason. There is no silent omission. Across the generated packages there are **{{facts.total_skipped}}** recorded entries.

| Reason recorded in the report | Entries | How much it actually hurts |
| --- | ---: | --- |
| Property has no typed getter at all | {{facts.skips.missing_getter}} | Cosmetic for most of them — the property is construct-only or write-only in GIR. The typed setter, where one exists, is still emitted. |
| Array / collection types — *"handled in a later phase"* | {{facts.skips.array_types}} | **The largest remaining functional gap**, though the count has fallen sharply since the `array-types` work landed — it was 946 entries before. |
| Property construct-only or no public setter | {{facts.skips.construct_only}} | Cosmetic — the getter is emitted, the entry records the missing setter. |
| Duplicate constant — two GIR symbols, one Dart name | {{facts.skips.duplicate_constant}} | Benign, and now self-explanatory: the report names both symbols. Almost entirely GDK `KEY_*` keyvals, which the GIR declares twice under two capitalisations. |
| Name collision | {{facts.skips.name_collision}} | An enum, class, record or function already holds the Dart name. |
| Unsupported type | {{facts.skips.unsupported_type}} | Real — the C type has no Dart equivalent yet. |
| C macro (`introspectable="0"`) | {{facts.skips.c_macro}} | None. A macro has no symbol to bind. The report names the `_full` wrapper to call instead. |
| Return type could not be named | {{facts.skips.unnamed_return}} | Real — mostly string-list and array returns. |
| Unsupported OUT buffer | {{facts.skips.unsupported_out_buffer}} | Real — the buffer type has no Dart mapping. |
| Override-incompatible — emitted under a renamed method | {{facts.skips.override_incompatible}} | Largely handled: the entry names the renamed method to call. |
| inout parameter | {{facts.skips.inout_parameter}} | Real. The read-only-out direction has no emission path yet. |
| Alias resolved to its target | {{facts.skips.alias_resolved}} | Benign. The symbol exists, just under its target name. |
| Unsupported return type | {{facts.skips.unsupported_return_type}} | Real — mostly string-list and array returns. |
| Unsupported argument type | {{facts.skips.unsupported_argument_type}} | Real. The parameter's C type has no Dart equivalent yet. |
| Nullable scalar parameter (`glong*`, `gint*`, …) | {{facts.skips.nullable_scalar_parameter}} | Real but mechanical — needs an explicit nullable-scalar mapping in the resolver. |
| Duplicate declaration owned by an earlier namespace | {{facts.skips.duplicate_declaration}} | Benign. The symbol exists, just in the package that owns it. |
| Everything else (props-layer arity, moved or renamed members, array parameters in callback signatures) | {{facts.skips.other}} | A long tail, individually listed with a precise reason. |
| **Total entries across all generated packages** | **{{facts.total_skipped}}** | |

Aggregated from the `## By reason` section of every `skip_report.txt` on the current `main` branch — the table above is generated from `site_src/data/facts.json`, which is itself derived from the repository. The two dominant categories — missing getters and construct-only properties — account for over 40% of all entries and neither is a functional hole.

:::{note}
**How to use the report:** if a symbol you expect is missing, grep `packages/<lib>/skip_report.txt` for it. Every line states the reason, and the reason names the category documented in `docs/skip-categories.md`. That is the intended workflow — not "open an issue and wait".
:::

## Not built yet

Stated up front so nobody has to discover it by hitting it:

:::{checklist}
[ ] Array and collection returns / parameters are the biggest remaining hole ({{facts.skips.array_types}} recorded skips, down from 946 before the `array-types` work landed).
[ ] Dart-level subclassing of generated wrappers is on `main`, but it is a Dart-side contract only: a subclass does not register a `GType` of its own, so it cannot be used as a template parent. See the [roadmap](roadmap.html) and `docs/subclassing.md`.
[ ] Composite templates *are* on `main`: `packages/gtk_templates` and `packages/gtk_templates_builder`, with a worked example in `example/todo/` and the design written up in `docs/templates.md`.
[ ] Unions and bitfields are parsed but not emitted as first-class Dart types.
[ ] No pub.dev publication; packages are `publish_to: none`.
[ ] Linux is the only platform the runtime is exercised on. Windows and macOS library resolution is unhandled and produces poor error messages.
[ ] CI does not run any test that makes a native call.
:::

- [See when each of these lands](roadmap.html) →
- [How it works](design.html) →
