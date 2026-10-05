# Type system

How GIR `<type>` references become Dart wrapper types, FFI native types,
and parameter/return marshalling expressions.

The bridge is built in two layers:

1. `TypeResolver.resolve(GirTypeRef)` produces an immutable
   `TypeMapping` (GIR-side classification → Dart-side primitives).
2. `EmitContext.bridgeFor(GirTypeRef?, ...)` wraps a `TypeMapping` in a
   `TypeBridge` with the actual `toNative` / `fromNative` code
   expressions used by emitters.

## Built-in scalar table

`TypeResolver._byGirName` and `_byCType` cover the GLib/C scalars:

| GIR name / c:type | Dart type | Native type |
|---|---|---|
| `none`, `void` | `void` | `ffi.Void` |
| `gboolean` | `bool` | `ffi.Int32` |
| `gint`, `gint32`, `gint8`, `gint16`, `gshort`, `glong` | `int` | `ffi.Int32` |
| `guint`, `guint32`, `guint8`, `guint16`, `gushort`, `gulong`, `gsize` | `int` | `ffi.Uint32` |
| `gint64` | `int` | `ffi.Int64` |
| `guint64` | `int` | `ffi.Uint64` |
| `gdouble` | `double` | `ffi.Double` |
| `gfloat` | `double` | `ffi.Float` |
| `utf8`, `filename`, `gchar*` | `String` / `String?` | `Pointer<Utf8>` |
| `gunichar` | `int` | `ffi.Uint32` |

`TypeResolver.isStringListArray(GirTypeRef)` upgrades arrays of `utf8` /
`filename` / `gchar*` (with `c:type` in `gchar**`, `const gchar* const*`,
`const gchar**`, `char**`, `const char* const*`, `const char**`) to
`List<String?>?` (and `Pointer<Pointer<Utf8>>` natively). Other arrays
dispatch by element kind:

| Element kind | Length binding | Mapping |
|---|---|---|
| int-sized primitive / boolean / enumeration / bitfield | `<array length="N">` | `ffi.Pointer<ffi.Int32>` (or `Uint32` for bitfields), with `arrayLengthParameter=N`; the wrapper iteration emits a sibling `int` slot at the GIR's `lengthParameterIndex` |
| int-sized primitive / boolean / enumeration / bitfield | unbounded (`<array c:type="…*">` only) | `ffi.Pointer<ffi.Int32>` (or `Uint32`); no length slot — caller is responsible for providing length via a sibling `get_n_items` accessor |
| class / interface / record | `<array length="N">` | `ffi.Pointer<ffi.Void>`, with `arrayLengthParameter=N`. Typed `asTypedList(n)` iteration is a follow-up — generated records are currently opaque pointer classes, not `StructBase` subclasses, so `Pointer<RecordClass>` isn't a valid FFI type yet. |
| union | any | `array of TypeKind.union (later phase)` — unions are not used in element position in the GIR corpus today. |
| string (utf8) | `<array length="N">` (bound) | `array of TypeKind.string (later phase)` — a bound-length array of strings is unusual and not yet supported. |
| element type unresolved | any | `array element of unsupported kind (<reason>)` |
| element type with neither `<type name=…>` nor `c:type=` | any | `array of unknown element` |

All four supported shapes (argv string list, bound enum/primitive array,
bound record/class array, unbounded primitive array) are emitted by the
existing parameter-marshalling loop without further changes — the GIR's
length parameter is already in `fn.parameters` at the index named by
`arrayLengthParameter`, so the loop iterates both naturally and the
wrapper signature carries both slots in declaration order.

## Declared-type table

Once the type name doesn't match a built-in, the resolver looks it up
across all loaded namespaces:

| GIR element | Kind | Dart wrapper | Native type |
|---|---|---|---|
| `<class>` | `classType` | `<CIdentifier><TypeName>` | `Pointer<ffi.Void>` |
| `<interface>` | `interface` | same | same |
| `<record>` | `record` | same | same |
| `<union>` | `union` | same | same |
| `<callback>` | `callback` | inline Dart signature | `Pointer<NativeFunction<...>>` |
| `<bitfield>` | `bitfield` | `<CIdentifier><TypeName>` | `ffi.Uint32` |
| `<enumeration>` | `enumeration` | `<CIdentifier><TypeName>` | `ffi.Int32` |
| `<alias>` | resolved recursively to target | inherits target | inherits target |

The C identifier prefix (`c:identifier-prefixes` on the namespace) is
prepended to the local name to form the Dart type name: `Gio.Application`
+ prefix `G` → `GApplication`. Records named `_data__union` are
sanitised to `DataUnion` via `toUpperCamel`.

## Transfer ownership

`GirTransferOwnership.{none, container, full}` is plumbed through
`bridgeFor`'s `transfer` parameter. Currently only the `string` and
`class/record` paths consume it:

* `transfer="full"` for a string parameter is treated the same as
  `none` (the wrapper always passes a borrowed view through
  `withNativeString`).
* `transfer="full"` for a class return: the wrapper takes ownership of
  the returned pointer and the user must call `g_object_unref` /
  equivalent (encoded in the doc comment).
* `transfer="none"` for a string return: `stringFromNative(..., free:
  false)` — the caller does not free.

The current corpus has `transfer="full"` mostly on return values; the
generator emits the documented ownership contract and leaves the actual
`g_object_unref` to the caller.

## Nullable handling

* `nullable="1"` parameters / returns produce `String?` /
  `<Wrapper>?` wrapper types.
* `nullable="0"` produces the non-null variant. In `bridgeFor` this
  becomes `$read!` (string) or a non-null `fromPointer` (class).

Nullable scalar parameters (`int?`, `bool?`) are skipped with
`nullable scalar parameter (<name>)` — the trampoline FFI signature
can't carry a non-nullable pointer to a nullable scalar.

## Cross-namespace resolution

`TypeResolver._lookup` searches the current namespace first, then every
other loaded namespace, for the unqualified name. Qualified names
(`Gio.AppInfo`) are looked up by namespace prefix and local name. When
the resolved declaration lives in a different namespace than the
current one, the bridge records the package via `requiredImport` and the
emitter adds it to `ctx.imports`.

Aliases are unwound recursively (`GirAlias.target` is resolved against
the alias's namespace, not the current one). Duplicate declarations
across namespaces (e.g. `GObject-2.0.gir` re-declares `GIOCondition`)
canonicalise to the **first** namespace in dependency order that has the
matching `c:type`. See `TypeResolver.canonicalNamespace`.

## `relativeTo` for inherited signals

`EmitContext.bridgeFor` and `EmitContext.resolve` accept a `relativeTo`
namespace used for unqualified lookup. The signals pipeline threads
this through `buildSignalBuckets` → `_signatureFor` → `_ffiShapeFor` →
`bridgeFor` so an inherited signal like `Gio.Application::open`
resolves its `Window` arg against the `Gio` namespace (where the signal
was authored) rather than the current namespace (where the wrapper
class lives). Without this, `Window` would resolve to whichever
namespace happens to define a class named `Window` first — for `Adw`
that means `AdwWindow`, which is wrong.

## What's intentionally unsupported

| Reason | Where it surfaces |
|---|---|
| `array of TypeKind.X (later phase)` | Array element is a kind the resolver can't yet emit (union, GValue*, bound string array, …) |
| `array element of unsupported kind (<reason>)` | Inner element type was rejected by the resolver; the parent reason is appended |
| `array of unknown element` | Array has no `<type>` and no `c:type=` to identify the element |
| `unsupported C type: <name>` | Scalar names not in the built-in table (e.g. `va_list`) |
| `callback <name> is in non-generated package <pkg>` | Callback declared in a package we're not regenerating |
| `type <name> is in non-generated package <pkg>` | Same for class/record/etc. |
| `callback return type (<name>)` | Callbacks as return values |
| `nullable scalar parameter (<name>)` | `int?` / `bool?` parameters |
| `callback <name> has unsupported signature` | Inner callback type can't be marshalled (also raised when the user-facing signature can't be resolved, e.g. an alias to a callback that isn't in any GIR) |
| `type ... is in non-generated package ...` | Cross-package type whose package isn't generated |

See [skip-categories.md](./skip-categories.md) for the full enumeration.
