# Skip categories and reasons

Every symbol the generator cannot emit is recorded in
`packages/<lib>/skip_report.txt` as `(category, name, reason)`. Use this
file when triaging "why is `<X>` missing from package `<Y>`?".

## Categories

| Category | Source | Examples |
|---|---|---|
| `class` | `ClassEmitter.emitClass` | `parent ... is in non-generated package`, `name collision` |
| `record` | `RecordEmitter._emit` | `duplicate declaration owned by an earlier namespace`, `name collision` |
| `callable` | `CallableEmitter.emit` | `no c:identifier`, `varargs`, `moved to`, `shadowed by` |
| `method` | `ClassEmitter` | `name collision`, `override-incompatible with ancestor; renamed to <X>` |
| `function` | `ClassEmitter` / `FunctionEmitter` | `name collision` |
| `constructor` | `ClassEmitter` | `duplicate new()`, `name collision` |
| `callback` | `CallbackEmitter` | `callback <X> not found`, `callback <X> has unsupported signature` |
| `enum` | `EnumEmitter` | (rare — enums almost always emit) |
| `signal` | `signals_emitter.signalSkipReason` | `arity N exceeds supported max (5)`, `unsupported arg type`, `unsupported return type`, `weak-ref`, `detailed signal names`, `name collision` |
| `alias` | (always) | `aliases are resolved to their target` |
| `renamed` | `ClassEmitter` | `override-incompatible with ancestor; renamed to <X>` |

## Common reasons (alphabetical)

### `aliases are resolved to their target`

Every `<alias>` is skipped at the `PackageEmitter` level — the resolver
unwinds aliases inline so callers see the target type.

### `arity N exceeds supported max (5)`

`signalSkipReason` rejects signals with more than 5 parameters. The
largest signal in the current GIR corpus is
`Gio.DBusObjectManagerClient::interface-proxy-signal` (5 args). To use a
signal with more args, fall back to `connectSignal` with a
`void Function()` callback and read the values yourself via
`g_signal_get_invocation_hint` or by querying the property after the
signal fires.

### `array types are handled in a later phase`

Returned for any non-string-list array (`<array length="…">` whose
element type isn't `utf8`/`filename`/`gchar*`). Open a generator issue
with the GIR excerpt.

### `callback <X> has unsupported signature`

The inner callback's signature couldn't be marshalled (e.g. an unsupported
arg type, a callback-typed param). Look up the inner callback in
`skip_report.txt` to find the precise cause.

### `callback <X> is in non-generated package <pkg>`

The callback is declared in a package that wasn't in the generator's
target list. Run the generator with that package as a target, or
re-add it to the workspace's emitted-packages set.

### `callback return type (<X>)`

A `GirCallable` that returns a callback. None of the GIR files in scope
declare one; if you hit this, open an issue.

### `detailed signal names (notify::property-name) are out of scope; use connectSignal`

The signal name contains `::`. Use `connectSignal(handle,
'notify::property-name', () {})` instead.

### `duplicate declaration owned by an earlier namespace`

`EmitContext.isDuplicateType` detects cross-namespace declarations with
the same `c:type`. Only the first declaration (in dependency order)
is emitted; the rest are skipped.

### `duplicate new()`

A class with two unnamed constructors. The GIR corpus shouldn't have
these; if it does, open an issue.

### `introspectable=0` / `introspectable=0 (C macro; use <sibling>)`

The GIR element is marked `introspectable="0"`. GLib uses this attribute
to indicate that the C declaration is a convenience macro that expands
to the canonical sibling — emitting a Dart wrapper around the macro
would either duplicate the C ABI (drift risk) or silently route to the
wrong symbol.

Two variants of the reason show up in the skip report:

- `introspectable=0 (C macro; use <sibling>)` — the macro has a sibling
  declared via `shadows` / `shadowed-by`. Use the sibling instead, which
  the generator emits as a real wrapper. Examples: `g_idle_add` →
  `g_idle_add_full`, `g_timeout_add` → `g_timeout_add_full`,
  `g_io_add_watch` → `g_io_add_watch_full`, `g_child_watch_add` →
  `g_child_watch_add_full`, `g_log_set_handler` → `g_log_set_handler_full`.
- `introspectable=0` — bare reason, no canonical sibling. Most often a
  helper macro or a function whose ABI is unsafe to bind directly
  (`g_assertion_message_*`, `g_clear_pointer`, `g_steal_pointer`, …). If
  you genuinely need one, raise an issue with the GIR excerpt.

In both cases the entry lists the symbol under the `[callable]`
category so you can grep for the exact name:

```
[callable] GLib.idleAdd — introspectable=0 (C macro; use idle_add_full)
[callable] GLib.clearPointer — introspectable=0
```

Namespace-level `<function>` elements with `introspectable="0"` are kept
in the parsed model (not silently dropped) so the emitter can surface a
precise reason. Classes, records, and other top-level elements with
`introspectable="0"` are still dropped at the parser level — they have
no useful binding to surface.

### `moved to <X>` / `shadowed by <X>`

The C function was renamed. Skipped — call the canonical replacement.

### `name collision`

A member with the same Dart name already exists. Common cases:
* `<method>` collides with a Dart `Object` member
  (`toString`, `hashCode`, `noSuchMethod`, `runtimeType`).
* A signal's `on<Name>` collides with another member named the same.
* A constructor's name collides with a sibling.

See the message for the colliding name.

### `nullable scalar parameter (<X>)`

A `nullable="1"` scalar (`int?`, `bool?`, etc.) — the FFI signature can't
represent a nullable scalar through a pointer. Open a generator issue
with the GIR excerpt if you hit one in the wild.

### `override-incompatible with ancestor; renamed to <X>`

`ClassEmitter._ancestorMethodSigs` detects ancestor methods with the
same name but different signatures (return type, parameter types, or
nullability). The method is renamed by appending the class's GIR name
(`activate` on `AdwActionRow` → `activateActionRow`). Skip reports this
as `renamed`, not `method`, so the count of skipped methods stays
informative.

### `parent ... is in non-generated package <pkg>`

The class extends a type whose package isn't being generated. Add that
package to the target list.

### `parent ... not found; emitted without superclass`

The class's `parent="..."` couldn't be resolved. The class is emitted
without a superclass — its constructor won't chain.

### `type <X> is in non-generated package <pkg>`

Same idea as the callback version, but for class/record/enum types.

### `unsupported arg type at index N: <T>` / `unsupported return type: <T>`

Signal-arg or signal-return types not in the supported shape list (see
[signals.md](./signals.md)). Fall back to `connectSignal`.

### `unsupported C type: <T>`

A scalar name not in the built-in table (`TypeResolver._byGirName` and
`_byCType`). Examples: `va_list`, complex GCC types. Open an issue if
the GIR type is reasonable.

### `varargs`

Functions with `...` parameters are skipped — variadic FFI calls
require bespoke trampolines that the generator doesn't yet emit.

### `weak-ref is not connectable via g_signal_connect_data`

The signal is `weak-ref` (used by `g_object_weak_ref`). Use
`g_object_weak_ref` directly through `gobjectLookup` instead.
