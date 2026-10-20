# Changelog

Reverse-chronological record of user-facing changes to the workspace.
Per-package versions stay pinned to the workspace version — `publish_to:
none` keeps everything in lockstep.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
with `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`
sections. Dates are ISO-8601 (YYYY-MM-DD).

## Unreleased

### Added
- **Dart classes can have a native type.** A Dart subclass of a
  generated GObject wrapper had no native identity: as far as GLib was
  concerned it was a plain `GObject`, so a `GListStore` refused it and
  a native round trip through a list item produced a *new* wrapper with
  no Dart state. Four generator features and one runtime package fix
  that:
  - every generated class and interface now exposes
    `static int get GType`, looked up once from the GIR's
    `glib:get-type`;
  - `GTypeInfo`, `GTypeQuery`, `GTypeFundamentalInfo` and
    `GInterfaceInfo` are emitted as `ffi.Struct`, so their layout comes
    from the GIR and they can be passed *by value*;
  - `packages/gir_ffi` keeps a **weak** cache from the native address
    to the Dart object, and `fromPointer` became a **factory** — the
    same native pointer always yields the same Dart object, so a Dart
    subclass survives the trip out of native code;
  - `GObject(int objectType)` instantiates a native type;
  - the new `packages/dart_gobject` package provides
    `registerDartType(name, parentType)`, which registers a GType with
    GLib for a Dart class.

  ```dart
  class TaskObject extends GObject {
    static int get GType => registerDartType('TaskObject', GObject.GType);

    TaskObject({this.completed = false, required this.content}) : super(GType);

    bool completed;
    String content;
  }

  final store = GListStore(TaskObject.GType);
  ```

  `example/todo` is the worked example: a task list whose model is a
  `GListStore` typed with the Dart class's own native type. The design
  is in [docs/dart-gobjects.md](docs/dart-gobjects.md).

- **The generated constructor sinks a widget's floating reference.** A
  widget comes with a *floating* reference: nobody owns it until a
  parent takes it. The wrapper owns the object, so the reference is
  sunk — otherwise the parent that parents the widget would own the
  very reference the wrapper's finalizer releases, and the widget
  would be freed while the parent still uses it.

### Fixed
- **The template builder names a signal's helper the way the bindings
  do.** The builder called `on` + the signal name with its first letter
  capitalized, so `icon-release` became `onIcon-release` — not even a
  Dart identifier, and not the `onIconRelease` the bindings generate.
  The builder now uses the generator's own rule (`toUpperCamel`), so a
  kebab-case signal resolves to the helper that exists.

- **The template builder forwards a signal's arguments.** The generated
  closure took no arguments and called the user's method with none, so
  a signal that declares parameters — `GtkEntry::icon-release`, say —
  was wired to a method that never received them. The closure now
  forwards them, taking their types from the binding's callback type
  and their names from the user's method. A user method whose signature
  does not match the signal's now fails the analyzer when the part file
  is generated, instead of dropping the arguments at run time.

- **The example's list rows are built again.** `GtkSignalListItemFactory`'s
  `setup` and `bind` signals are typed `GObject` by the GIR — GTK's C
  signature passes a `GtkListItem`, but the introspection data does not
  say so. The example cast the argument to `GtkListItem`, which threw a
  `TypeError` that GLib swallowed: the model filled up, but the list
  stayed empty. The example now re-wraps the handle with `cast`, and
  `docs/signals.md` explains the pattern.

- **A window left for the collector is no longer walked by GTK.** A
  window that is only freed when the isolate shuts down stays in GTK's
  global toplevel list, and GTK walks that list on every main-loop
  iteration — so a suite that drives the default main context in
  parallel walks a window that is already gone. The example's test now
  destroys its window while the isolate is alive, after detaching the
  wrapper's finalizer (`gtk_window_destroy` frees the window, so the
  finalizer must not release it twice) and after taking it out of the
  application's window list.

- **An OUT parameter's buffer no longer outlives its wrapper.** The
  generator allocates the buffer the C function writes into and returns a
  view of it, but nothing kept the buffer alive: the anchor became
  unreachable the moment the method returned, the collector freed the
  buffer, and the wrapper — a `GtkTextIter`, a `GdkRectangle` — kept
  reading from released memory. `GtkTextBuffer.getBounds` crashed about
  one run in eight. The wrapper now keeps the buffer alive through
  `keepAlive`, and the buffer is released when the wrapper is collected.

- **A class OUT parameter reads the pointer, not the slot.** For a
  two-star C type (`GUnixFDList**`) the C function writes a *pointer* into
  the caller's slot; the generator wrapped the slot itself, so the
  wrapper pointed at a pointer-sized cell instead of at the object. The
  slot is now a zeroed pointer cell and the value is read out of it, with
  the reference owned when the GIR says `transfer="full"`.

- **A struct OUT parameter is no longer a use-after-free.** The
  generator allocated the buffer the C function writes into, returned
  a view of it and freed the buffer — the returned struct pointed at
  released memory. The buffer's ownership now goes to the struct
  (`refWithFinalizer`), so it is released when the struct is
  collected.

- **The project site is generated.** `site/` used to hold six hand-written
  HTML pages whose numbers were typed by hand and had already drifted twice.
  The sources now live in `site_src/`, and a dependency-free generator in
  `tool/` renders them:
  - `site_src/pages/*.md` — one Markdown file per page, with a small
    front-matter block (`title`, `doc_title`, `description`, `nav_order`,
    `nav_label`, `section_label`) and a deliberately small Markdown subset:
    headings, paragraphs, lists, GFM tables, fenced code blocks, quotes,
    rules, raw HTML, and a set of block directives (`:::{note}`,
    `:::{figure}`, `:::{kv}`, `:::{checklist}`, `:::{phase}`, `:::{cols}`,
    `:::{meta}`, `:::{packages}`).
  - `tool/build_site.dart` renders `site_src/` → `site/`. `--check` fails
    when the committed output is stale; `--serve` builds and serves the
    result locally. `tool/build_site.dart` owns `site/*.html` and
    `site/assets/` and never touches `site/docs/`.
  - `tool/collect_facts.dart` derives `site_src/data/facts.json` from the
    repository: the per-package skip counts, the aggregated coverage
    groups, the SDK constraint, the licence, the size of the generated
    tree and the number of generated accessors, signal helpers and async
    overloads.
  - `site_src/data/packages.json` is the curated package list. It replaces
    both the hand-written coverage table on the home page and the
    `_packageBlurbs` map that used to live in `tool/build_api_docs.dart`.
  - `site_src/assets/style.css` is the new design system.

  The generator uses only `dart:` — no `package:markdown`, no
  `package:yaml`. `package:markdown` is not in the local pub cache, and
  `package:yaml` would force a workspace re-resolution that breaks
  `dart test`; CI must be able to build the site with nothing but the
  Dart SDK.

- **A numbers layer that cannot drift.** A page source carries no
  package, skip-count or test-count number. They come from
  `facts.json` through `{{facts.…}}` placeholders, or from a generated
  table. A placeholder naming a fact that does not exist **fails the
  build**, with the file and the line.

- **The site generator has its own test suite**, in `test/site/`: the
  Markdown subset element by element, the highlighter, the page shell,
  the facts derivation, and a drift check that renders every page from
  `site_src/` in memory and compares it with the committed `site/`. The
  internal-link check that CI used to carry as an ad-hoc Python snippet
  is now a Dart test.

- **A verified record of what is on `main`.** `docs/branch-state.md`
  answers the question that had been open: are the composite-template stack
  and the Dart-level subclassing contract committed on the trunk? Both are.
  The `composite-templates` branch's merge-base with `main` is `ed5ce0f7` —
  *"feat: add subclasssing"* — so the subclassing capability was already on
  `main` before the branch existed, and was never the branch's to deliver.
  Its two remaining commits carry only packaging (Blueprint, GResource,
  Meson, gettext) and a pre-refactor internal layout, so the branch is
  ready to be retired. The document lists the four commands that reproduce
  the comparison.

### Changed
- **The site was redesigned.** The old pages were the recognisable
  "default AI landing page": a blurred sticky header, an eyebrow chip,
  pill badges, big-number stat cards and boxed two-column cells. The
  visual direction is now a **technical dossier, set like an editorial
  print document** — the page is the surface, and structure comes from
  hairline rules, a 70-character measure and a strict typographic scale
  rather than from boxes. Serif headings, sans body, mono labels; one
  Dart-blue accent on paper; no cards, no pills, no shadows, no gradients, no
  rounded panels, no animation. Every page gained a sticky table of
  contents, and light and dark are peers rather than an afterthought.
  The navigation, the footer and the API reference's landing page were
  duplicated in every page; they are written once now.

- **The palette is Dart's own.** The accent is the brand blue —
  `#0175C2` in light mode, `#13B9FD` in dark — and the neutrals are no
  longer grey: paper, ink and every rule between them carry a little
  blue, so the accent belongs to the sheet instead of sitting on top of
  it. `--accent-strong` is the same hue one step deeper, used where the
  accent carries small type (code keywords) and on hover; the brand
  colour only just clears 4.5:1 against the panel colour, so the deeper
  shade does that job. The API reference's injected navigation carries
  the same values, and `::selection` is now themed instead of falling
  back to the browser default.

- **The pipeline diagram's arrowheads now match their connectors.** The
  SVG marker resolves `currentColor` against the referencing path, and
  the group that held it referenced a token that did not exist
  (`--text-3`), so the arrowheads silently inherited the body colour
  while the strokes were muted. The token is gone, the dashes and the
  arrows carry their own, and the second diagram got the same treatment.

- **The API reference's landing page** (`site/docs/index.html`) is
  rendered through the same layout as the rest of the site instead of a
  bespoke string, and the navigation injected into the dartdoc pages was
  restyled to the same palette. The dartdoc pages themselves are not
  restyled — dartdoc owns that markup.

- **CI checks the site.** The workflow now re-derives the facts and
  re-renders the site, and fails if either differs from the committed
  copy — the same rule the repository applies to the generated bindings.

- **The roadmap states what the repository actually contains.** Phase 5 was
  "half landed" on the strength of a working copy; it has now been verified
  against the committed trees, and its exit conditions are checked off one
  by one. The only item left on it is the deletion of the
  `composite-templates` ref — an administrative step, not a capability.

- **A template can live in its own file.** `@GtkTemplate(source:
  GtkTemplateFile('data/window.ui'))` names a `.ui` file instead of
  carrying the XML inline. The builder reads it **through the build's
  asset reader**, so the file is a *tracked build input*: editing it
  re-runs the builder and the next build regenerates the part file.
  Two rules come with that:
  - The file has to be a **public asset** of the package. A build sees
    `lib/**` and `bin/**` and nothing else, so a template under `lib/`
    needs no configuration, and one under `data/` needs
    `additional_public_assets: [data/**]` in the consumer's
    `build.yaml`.
  - A template file that cannot be read **fails the build** with the
    path it looked for. Writing no part file would leave the previous
    one in place, and the stale template would keep running as if the
    edit had never happened.

  The standalone CLI resolves the same path against the *package root*
  of the source file, so it no longer depends on the directory it was
  started in.

- **`example/todo` keeps its template in `data/window.ui`** and has a
  menu: a `GtkMenuButton` in the header bar, with `app.shortcuts` and
  `app.about` on it. The application provides both actions — a menu
  item whose action does not exist is dead, and GTK says so on
  stderr.

### Fixed
- **Editing a template file now changes the app.** The builder read a
  `GtkTemplateFile` off the filesystem, which the build knows nothing
  about: the file was not a build input, so a change to it did not
  invalidate anything, the build reported the input as "skipped", and
  the app came up with the previous template. The file is read through
  the build's asset reader now, and the build reacts to it. The silent
  skip is gone as well: a template file that cannot be read fails the
  build instead of quietly leaving the old part file in place.

- **The composite-template stack renders its template.** `example/todo`
  came up as an empty window: the template was built *lazily*, on the
  first read of a generated field, and nothing read one — so GTK never
  instantiated the template's widget tree. Three separate defects were
  behind it:
  - **The template was never built.** GTK builds a widget's template in
    the instance initializer; Dart has no instance initializer (a field
    initializer cannot touch `this`). The generated mixin now **overrides
    `GtkWidget.initTemplate()`** and the host widget calls it from its
    constructor:

    ```diff
     class TodoWindow extends AdwApplicationWindow with _$TodoWindowTemplate {
    -  TodoWindow(super.app);
    +  TodoWindow(super.app) {
    +    initTemplate();
    +  }
     }
    ```

    `initTemplate()` is idempotent; the lazy path survives as a safety
    net, so a host that forgets the call still gets a working — if late
    — widget.
  - **The children were resolved against the wrong type.**
    `gtk_widget_get_template_child()` wants the type that *declared* the
    child — the widget's own native type — not the child's type. Passing
    the child's type returns `NULL`, so every generated field came back
    empty. The mixin now resolves the instance's native `GType`
    (`widgetTypeOf`).
  - **GTK rejected the XML.** GTK checks the `<template>` element's
    `class` against the widget's type name and `parent` against the
    widget's direct parent type. A Dart subclass has no `GType` of its
    own, so the name the user writes can never match: the runtime now
    rewrites both attributes against the instance's real type. The
    `<signal>` elements are removed before GTK sees them, because
    GtkBuilder resolves a handler as a **C symbol** — the signal is wired
    by the generated mixin's Dart closure instead.

  `example/todo`'s template XML was also malformed (a stray `</object>`
  and a missing `</template>`); it is fixed.

- **The template is installed once per native class.** GTK stores the
  template on the native class and allows exactly one there
  (`gtk_widget_class_set_template()` asserts
  `widget_class->priv->template == NULL`). A Dart subclass does not
  register a `GType` of its own, so two Dart template classes cannot
  share one native widget type — the second one is now rejected with a
  `StateError` instead of tripping a GTK assertion.

- **Nullable scalar OUT parameters are now emitted.** The resolver's
  `bridgeFor` rejected any nullable scalar (primitive, boolean,
  enumeration, bitfield) on a non-return path, so methods whose only
  non-instance parameter was a `<parameter direction="out"
  optional="1" allow-none="1">` (e.g. `GVariant.getString` with its
  `gsize *length`) were dropped wholesale. The generator allocates
  the buffer and reads the result with `outExtract`, so the C
  function's `allow-none="1"` never reaches the FFI boundary —
  passing a valid pointer is always accepted. The lift is restricted
  to `direction == out`; nullable IN-direction scalars remain
  rejected because Dart FFI cannot express `int?` over a primitive
  pointer. Brings back ~50 methods across the corpus, including:
  - `GVariant.getString() → (String, int)`
  - `GVariant.dupBytestring() → (ffi.Pointer<ffi.Uint8>, int)`
  - `GVariant.getBytestringArray()`, `GVariant.dupBytestringArray()`
  - `GDBusConnection.sendMessageWithReply()` / `…Sync()`
  - `GLib.convert` / `convertWithFallback` (the `bytes_read` and
    `bytes_written` out params no longer drop the call).

  Call sites that previously could not reach these methods must be
  updated to consume the tuple return shape — e.g.
  `params?.getString()` is now `(String, int)?`, so the notepad sample
  destructures it as `final (text, _) = result;`. The skip report
  for each affected package drops the matching
  `parameter <name>: nullable scalar parameter (<c type>)` entries.

### Changed
- **Static class functions**: when a GIR `<method>` inside a
  `<class>` / `<record>` / `<interface>` / `<union>` carries
  `moved-to="<bare>"` (the value has no dot, so the target is a
  namespace function, not another class method), the generator drops
  the class-level method and re-emits the namespace function as a
  `static` method on the owning class. The Dart name is
  `toLowerCamel(<GIR function name>)`. Six entries trigger this in
  the in-scope GIRs:
  - `GResource.resourcesRegister(GResource)` / `resourcesUnregister(GResource)`
    — replaces the broken `GResource.register()` instance method
    (which silently dropped extra `GResource*` parameters) and the
    top-level `Gio.resourcesRegister(resource)` wrapper.
  - `GdkEvent.eventsGetAngle(GdkEvent, GdkEvent)`,
    `eventsGetCenter(GdkEvent, GdkEvent)`,
    `eventsGetDistance(GdkEvent, GdkEvent)` — replaces the broken
    instance methods that passed `this.handle` for one of the two
    events and dropped the other.

  Call sites that previously used
  `GResource.register()` / `GdkEvent.getAngle()` / `Gio.resourcesRegister(r)`
  must be updated to the new static-method form. The skip report
  (`packages/<lib>/skip_report.txt`) records each move as
  `brought to <Class> as <methodName>`. See
  [emission.md](./docs/emission.md#class--record--interface-members).

### Added
- **Typed signal helpers** (`onSignalName(<typed callback>)`) on every
  GObject subclass with a supported signal. Examples:
  - `app.onOpen((GFile[] files, String hint) { ... })`
  - `widget.onDirectionChanged((GtkTextDirection previous) { ... })`
  - `anyObject.onNotify((GParamSpec pspec) { ... })`
  Inherited signals are surfaced on every descendant class — e.g.
  `Gio.Application.onNotify(...)`, `AdwApplication.onWindowAdded(...)`.
  See [signals.md](./docs/signals.md).
- **Public `connectSignal` escape hatch** in every package's
  `lib/src/signals.dart` for signal names that don't have a typed
  helper (detailed names like `notify::property-name`, signatures the
  generator can't type). Uses the same trampoline path as the typed
  helpers.
- **Generated classes are now one-Dart-class-per-file**, named after
  the Dart class. `class GtkButton` lands in
  `lib/src/gtkbutton.dart` (was `lib/src/classes_27.dart`),
  `class GApplication` in `lib/src/gapplication.dart` (was
  `lib/src/classes_N.dart`), and so on. The PyGObject-style props
  companion class goes to `lib/src/<lowercased class name>_props.dart`
  next to its host class. All per-class files are still `part of
  '<pkg>.dart'` of the same library, so forward references resolve
  naturally and the public surface is unchanged —
  `import 'package:gtk4/gtk4.dart';` exposes the same names as
  before. Other categories (`enums`, `records`, `functions`,
  `constants`, `callbacks`) keep the existing ~400-line chunking.
  IDE `Ctrl+Click` on a class name now lands in a file that's
  recognisably that class. See
  [emission.md](./docs/emission.md#classemitter) and the
  `PackageEmitter file layout` regression test in
  [`generator/test/emitter_test.dart`](./generator/test/emitter_test.dart).
- **Subclassable generated classes**: `<constructor>` elements that have
  no `throws`, no OUT params, and no `String` / `String?` /
  `List<String?>?` / callback parameters are now emitted as generative
  constructors (chaining via `super.fromPointer(...)` for classes and
  `this.fromPointer(...)` for records) instead of factories. The
  original blocker — `class MyAdwWindow extends AdwWindow { MyAdwWindow()
  : super(); }` failing with *"The generative constructor 'AdwWindow()'
  is expected, but a factory was found"* — is resolved for all such
  simple constructors. Constructors with string / callback params remain
  factories because the factory body wraps them in `withNativeString` /
  `NativeCallable.isolateLocal` for proper C-buffer and
  `NativeCallable` lifetime management, and a generative initializer
  list has no body to host the corresponding `finally` block. Smoke
  test: `example/gtk4_examples/bin/subclass_smoke.dart`.
- **`g_free` binding in `package:gir_ffi`** via
  `DynamicLibrary.process().lookup('g_free')` for transferring
  ownership of `transfer-none` strings out of the trampoline.
- **`HeapAnchor` in `package:gir_ffi`** — a `Finalizable` backed by a
  `NativeFinalizer(malloc.nativeFree)`. Used by the generator's
  caller-allocated record OUT path to keep the buffer alive as long
  as the returned wrapper is reachable, and free it on GC. The static
  `_finalizer` is shared across all anchors; `HeapAnchor.allocate(N)`
  is the only public constructor (allocates a `calloc<Uint8>(N)`
  zero-initialized buffer). See
  [`packages/gir_ffi/test/heap_anchor_test.dart`](./packages/gir_ffi/test/heap_anchor_test.dart)
  (6 tests) for the lifetime contract.
- **GLib root-level namespace functions are now surfaced**:
  `g_get_user_data_dir`, `g_get_user_cache_dir`, `g_get_user_config_dir`,
  `g_get_user_name`, `g_get_real_name`, `g_get_home_dir`,
  `g_idle_add_full`, `g_timeout_add_full`, `g_timeout_add_seconds_full`,
  `g_io_add_watch_full`, `g_child_watch_add_full`, `g_source_set_callback`,
  `g_source_set_funcs`, and similar `_full`-suffixed siblings of the
  non-introspectable convenience macros are now real Dart wrappers. Their
  non-`_full` convenience macros (`g_idle_add`, `g_timeout_add`,
  `g_io_add_watch`, `g_child_watch_add`, `g_log_set_handler`, …) are
  recorded in `skip_report.txt` with reason
  `introspectable=0 (C macro; use <sibling>)`, naming the canonical
  wrapper the user should call. See
  [skip-categories.md](./docs/skip-categories.md#introspectable0--introspectable0-c-macro-use-sibling).
- **Nullable callback parameters** (`nullable="1" allow-none="1"` on a
  `<parameter>` whose `<type>` is a `<callback>`) are now emitted. The
  wrapper parameter becomes nullable (`FuncType?`) and the
  `NativeCallable` allocation, call-site argument, and
  `finally`-block close are all conditional on the user supplying a
  function. Without this change, 17 GLib skip entries
  (`g_idle_add_full`, `g_timeout_add_full`, `g_io_add_watch_full`,
  `g_child_watch_add_full`, `g_source_set_callback`,
  `g_source_set_funcs`, …) were unbindable. The lifetime model is only
  safe for callbacks invoked **synchronously** inside the call; see
  [emission.md](./docs/emission.md#callback-parameters) for the full
  pattern and the caveat about long-lived callbacks (idle sources,
  timeout sources, signal handlers).
- **`docs/`** with design references: [architecture](./docs/architecture.md),
  [emission](./docs/emission.md), [type-system](./docs/type-system.md),
  [signals](./docs/signals.md), [skip-categories](./docs/skip-categories.md).
- **Runtime tests** for the typed-signal pipeline:
  [`packages/gobject/test/signal_helpers_test.dart`](./packages/gobject/test/signal_helpers_test.dart)
  (3 trampoline tests: connect/emit/disconnect, closure capture, parallel
  connections) and
  [`packages/gobject/test/typed_signal_test.dart`](./packages/gobject/test/typed_signal_test.dart)
  (smoke test verifying the public `connectSignal` is reachable).
- **Runtime tests for namespace functions and nullable callbacks**:
  [`packages/glib/test/namespace_functions_smoke_test.dart`](./packages/glib/test/namespace_functions_smoke_test.dart)
  exercises `g_get_user_data_dir`, `g_get_user_name`, `g_get_real_name`
  at runtime and verifies that the `idleAddFull` / `timeoutAddFull`
  wrappers accept a top-level Dart callback plus nullable
  `data` / `notify` parameters.
- **`*Callback` convenience overload for async methods** (`openCallback`,
  `queryInfoAsyncCallback`, …). The base wrapper allocates a
  `NativeCallable` and closes it in `finally` — unsafe for async
  callbacks because GLib holds the pointer past the call. The new
  overload routes the dispatch through a permanent
  `Pointer.fromFunction` over a static trampoline + per-call registry,
  so no `NativeCallable` is ever closed. The user's callback signature
  is typed (`void Function(GObject?, GAsyncResult)` for
  `GAsyncReadyCallback`); `user_data` is hidden (always `null`
  internally). See [docs/async.md](./docs/async.md).
- **GIR `glib:finish-func`, `scope`, `closure` attributes** are now
  parsed into `GirMethod.finishFunc`, `GirParameter.scope`, and
  `GirParameter.closureIndex`. The parser test that previously failed
  (it referenced these fields) is now green.
- **Typed `props` accessor** (PyGObject-style) on every GObject-rooted
  class. Every `<class>` in GIR now exposes a `<ClassName>Props`
  companion instance via `widget.props.<name>`; each accessor
  delegates to the existing typed `get<Name>()` / `set<Name>(value)`
  methods (no GValue boxing, no extra FFI lookup). The props class
  `extends` its parent's props class so inherited accessors surface
  automatically (`button.props.canFocus` is declared on `GtkWidget`
  but reachable on every descendant without re-declaration). The
  accessor signatures inherit the typed method's nullability
  (`String?` for gchar* transfer-none), so reads and writes never
  lie at the type level. Properties whose typed getter/setter can't
  be represented as a no-arg getter / single-arg setter
  (`get_size(orientation)`, `set_text(text, length)`,
  `set_visible_page(NarrowerThanWidget)`, renamed typed methods) are
  recorded in the skip report with a precise reason; the user can
  always call the typed method directly. See
  [emission.md](./docs/emission.md#props-accessor) for the full rule
  set.
- **GIR `<property getter="…">` / `<property setter="…">` /
  `<property transfer-ownership="…">` attributes** are now parsed
  into `GirProperty.getter`, `GirProperty.setter`, and
  `GirProperty.transferOwnership`. The parser regression test
  covers the new fields; the property's `writable` defaults to
  `true` when `setter=` is present (GIR convention) so the props
  layer can emit setters without requiring GIR to spell out
  `writable="1"`.
- **Runtime test for the props accessor**:
  [`packages/gtk4/test/gtk4_props_test.dart`](./packages/gtk4/test/gtk4_props_test.dart)
  exercises `GtkButton.props.label` round-trip through the typed
  `getLabel` / `setLabel`, `props.canShrink = true` round-trip,
  inherited `canFocus` reachability via `extends GtkWidgetProps`,
  compile-time type-safety of the accessor (the Dart type is
  `String` for label and `bool` for canShrink, not `dynamic`), and
  the `late final _props` companion-instance stability across
  repeated accesses.
- **Caller-allocated OUT parameters are now emitted as typed
  wrappers.** Methods like `gtk_text_buffer_get_start_iter` (which
  take a `GtkTextIter*` OUT parameter that the caller fills in) used
  to be skipped with `caller-allocates out parameter iter`. The
  generator now allocates the buffer internally, passes its pointer
  to the native function, and reads back via the type's `fromPointer`
  factory. Primitive OUT params (`gint*`, `guint32*`, `gboolean*`)
  free the buffer in `finally`; record/class OUT params use a
  `HeapAnchor` (in `package:gir_ffi`) with a `NativeFinalizer` so the
  buffer's lifetime is tied to the returned wrapper's reachability.
  The wrapper returns the typed Dart value (`GtkTextIter
  getStartIter()`) directly. Skipped count across the workspace
  dropped from 1793 to 1511 (~282 fewer skips) without regressions.
- **Bound-length and unbounded arrays are now resolved, not skipped.**
  Four array shapes are handled by the resolver:
  - `gchar**` / `const gchar**` / `char**` / `const char**` argv-style
    string lists (the whitelist now matches what the C ABI accepts).
  - `<array length="N">` whose element is an int-sized primitive,
    boolean, enumeration, or bitfield: the wrapper exposes
    `ffi.Pointer<ffi.Int32>` (or `Pointer<ffi.Uint32>` for bitfields)
    and the C-side length parameter is bound to the GIR
    `lengthParameterIndex`.
  - `<array length="N">` whose element is a class/interface/record
    type: the wrapper exposes `ffi.Pointer<ffi.Void>` (the same shape
    a single record param uses today) and the length parameter is
    bound to `lengthParameterIndex`.
  - Unbounded primitive arrays (`<array c:type="int*">` without
    `<array length="…">`): the wrapper exposes
    `ffi.Pointer<ffi.Int32>`; the user provides length via a sibling
    `get_n_items` accessor.
  The user allocates the buffer with `calloc<Int32>(n)` (or
  `calloc<ffi.Void>(n)` for record arrays) and passes the typed
  pointer through. The GIR's length parameter is propagated through
  the natural parameter iteration so the C side always sees the
  matching `nProperties` / `nColors` slot. Across the regenerated
  packages the "array types are handled in a later phase" reason
  dropped from 946 skips to 0; the `gtk4` package's total skip count
  fell from 1767 to 1380 and `glib` from 447 to 391. Remaining
  array skips carry informative reasons (`array of TypeKind.X (later
  phase)`, `array element of unsupported kind`, `array of unknown
  element`) so the gaps are explicit. See
  [emission.md](./docs/emission.md#parameter-marshalling) and
  [type-system.md](./docs/type-system.md#arrays).

### Changed
- **`implements` clauses land on implementing classes** for every
  `<implements name="..."/>` entry in GIR. `class GSimpleAction extends
  GObject implements GAction` (was just `extends GObject`), so the user's
  intent from the original request — `app.addAction(action)` without an
  explicit `as GAction` cast — is now real. The implementing class
  satisfies the interface structurally; the interface itself is emitted
  as `class GAction { ... }` (was `final class GAction { ... }`) so a
  non-`final` Dart class lets other classes implement it. Records and
  unions stay `final class` because they're concrete struct wrappers that
  aren't meant to be subclassed by user code. With this change the analyzer
  reaches the "No issues found!" baseline across the whole workspace for
  the first time since the array work landed. See
  [emission.md](./docs/emission.md#interface-mirroring) for the
  cross-package mirror rules and the defensive rename that fires on
  signature mismatch.
- **`CallableEmitter.emit` accepts a `relativeTo` namespace** so
  interface mirrors resolve parameter and return types against the
  interface's own namespace, not the implementing class's. Without this,
  `GdkPaintable.snapshot(GdkSnapshot, ...)` would be re-bound to
  `GtkSnapshot` when mirrored onto `GtkIconPaintable` and the
  `implements GdkPaintable` structural check would fail with
  `invalid_override` (the two classes are typedef'd to the same C type
  but resolve to different Dart names per namespace).
- **Generative constructors chain to `this.fromPointer(...)`** instead of
  splitting between `super.fromPointer` (subclasses) and `this.fromPointer`
  (records / root classes). The unified form works for both shapes
  because every generated class declares its own `fromPointer` that
  forwards to its super when one exists. Fixes the pre-existing
  `final_not_initialized_constructor` /
  `undefined_constructor_in_initializer` errors on
  `packages/gobject/lib/src/gobject.dart` (`GObject.newv`, etc.) that
  fired the moment `dart analyze` first ran.
- **Type resolution prefers namespace lookup over c-type primitive**
  for `<type name="…" c:type="gpointer"/>` style declarations. Many GLib
  APIs use `<type name="GObject.Object" c:type="gpointer"/>` for backward
  compatibility — the GIR name resolves to a known class but the c-type
  matches the primitive `gpointer` mapping. Previously the c-type won
  and emitted `Pointer<ffi.Void>`; the resolver now tries the namespace
  lookup first, so `GTask.getSourceObject()` returns `GObject?` (matching
  `GAsyncResult.getSourceObject()`) instead of `Pointer<ffi.Void>`,
  satisfying the `implements GAsyncResult` structural check.
- **`_methodKey` is now c-type-aware** when building the per-method
  signature key. `Snapshot<GdkSnapshot*>` and `Snapshot<GtkSnapshot*>`
  now compare unequal so the defensive rename fires on signature
  mismatches that would otherwise produce valid-Dart but invalid-override
  methods once the implements clause lands.
- **`ClassEmitter` walks the parent chain** to emit inherited typed
  `onSignalName` methods on every descendant class. The walk is keyed
  by qualified class name (`'${ns.name}.${cls.name}'`) so `Adw.Application`
  correctly continues to `Gtk.Application` instead of stopping at the
  first match (both have local name `Application`).
- **`EmitContext.bridgeFor` / `resolve`** accept a `relativeTo` namespace
  parameter so inherited-signal arg types resolve against the
  namespace where the signal was authored. `Gtk.Application::window-added`
  now resolves its `Window` arg to `GtkWindow`, not `AdwWindow`.
- **Per-package `signals.dart`** now contains the typed-signal buckets
  (one trampoline + typed registry + connect helper per `FFI shape ×
  Dart type signature` bucket), plus a shared `_destroySignalState` and
  a per-id owner map so destroy-notify cleans up only the owning
  bucket's registry slot.
- **Generator's `signalSkipReason`** returns precise reasons for every
  unsupported signal: weak-ref, detailed names (`notify::x`), arity > 5,
  unsupported arg type, unsupported return type, name collision.
- **`analysis_options.yaml`** for generated packages now suppresses
  FFI analyzer false positives: `non_constant_identifier_names`
  (bucket ids carry the FFI shape), `unrelated_type_equality_checks`
  (raw FFI typedef comparisons), `return_of_invalid_type` (void
  trampoline sentinel), `must_be_a_subtype` (multi-line
  `NativeCallable<T>`), `non_native_function_type_argument_to_pointer`
  (cast of trampoline pointer), `must_be_a_native_function_type`
  (variance across Dart SDK versions).
- **Per-package imports of `gir_ffi`** are now hard-coded in the
  barrel and filtered out of `crossImports` so generated packages no
  longer emit a duplicate `import 'package:gir_ffi/gir_ffi.dart';`.
- **The existing `connectVoidSignal` runtime test was renamed to
  `connectSignal`** to reflect the public API surface; the runtime
  tests are unchanged in spirit (register a custom signal on
  `GObject`, connect via the public API, emit, disconnect).
- **Parser keeps namespace-level `<function>` elements with
  `introspectable="0"`** so `CallableEmitter.emit` can emit a precise
  skip entry. Previously the parser silently dropped them at the
  outer guard, leaving the macros with no trace in `skip_report.txt`.
  Classes, records, and other top-level elements with
  `introspectable="0"` are still dropped at the parser level — only
  `<function>` gets the keep-and-skip treatment.
- **Interface methods are mirrored onto implementing classes.**
  `GtkButton`, `GtkSwitch`, `GtkCheckButton`, `GtkLinkButton`,
  `GtkToggleButton`, `GtkScaleButton`, `GtkListBoxRow`, `AdwActionRow`,
  `GIOModule`, and every other class with `<implements name="..."/>`
  in GIR now exposes the interface's `<method>` instances as its own
  — same native symbol, same `this.handle` self-arg, same wrapper
  pattern. Write `button.setActionName('win.open')` directly instead
  of wrapping in `GtkActionable(button.handle)`. The interface itself
  is still emitted as a concrete `final class GtkXxx` so wrapping
  opaque pointers keeps working. Override-incompatible shadows (e.g.
  `GIOModule.use` shadowing `GTypeModule.use` with a different
  signature) are detected against the parent's combined method map
  (own methods + ancestor interface methods) and renamed to
  `<name><ClassName>` (`useIOModule`). Async interface methods
  (`scope="async"` or `finishFunc`) get the same lifetime-safe
  `*Callback` overload the class's own async methods use. Cross-package
  mirrors add the foreign package to `ctx.imports` only when an emitted
  method body references a wrapper type from that package — primitive
  mirrors don't import. See [emission.md](./docs/emission.md#interface-mirroring)
  for the full rule set.
- **`_emitPropertyAccessor` now resolves the typed method's
  getter/setter signature via `bridgeFor`** instead of the property's
  declared type. The previous behaviour emitted non-nullable Dart
  accessors (`String get label`) for properties whose typed method
  returns nullable (`String? getLabel()` because `gchar*` with
  `transfer-ownership="none"` is implicitly nullable), a type lie that
  would throw at runtime. The fix pins unqualified `<type>` names on
  the typed method to the property's owner namespace
  (`relativeTo: ownerNs`) — without this, the emission namespace
  would shadow the owner's type with a same-named child class
  (e.g. `Adw.Application` masking `Gtk.Application` when emitting
  `AdwMessageDialogProps`, breaking the parent's covariant setter
  with `invalid_override`).

### Fixed
- **`Gtk*Paintable.snapshot(GtkSnapshot, …)` no longer claims to override
  `GdkPaintable.snapshot(GdkSnapshot, …)`**. The two classes are
  typedef'd to the same C type but live in different namespaces
  (`gtk4` vs `gdk4`); the type resolver now threads the interface's
  namespace into the mirror's `bridgeFor` call so the parameter type
  resolves to `GdkSnapshot` (matching the interface) rather than the
  local `GtkSnapshot`.
- **`GtkIconPaintable` and friends no longer fail `dart analyze`** with
  a mix of `non_abstract_class_inherits_abstract_member` and
  `undefined_method _connectSignal_v_X` errors. The generator now
  inherits signals (and their per-bucket `_connectSignal_<bucketId>`
  helpers) from the `implements_` chain, not just the parent chain —
  previously an `implements GListModel` class was missing the
  `onItemsChanged` signal connector the interface declared, and the
  package's `signals.dart` was missing the `_connectSignal_v_X` helper
  the connector called.
- **`late final _props = …` shadowed the parent's late-final with
  the parent's type**, breaking the child's covariant `props` getter.
  Dart's late-final inference for a field that shadows a parent's
  late-final with a different initializer type picks the parent's
  static type, so `GtkButtonProps get props => _props` rejected
  `_props` as `GtkWidgetProps` (`A value of type 'GtkWidgetProps'
  can't be returned from a function with return type 'GtkButtonProps'`).
  The fix adds an explicit type annotation on `_props`
  (`late final GtkButtonProps _props = GtkButtonProps(this);`) so
  the child's static type matches its initializer. Affected every
  GObject-rooted child class in every package (`invalid_override`
  on the public `props` getter for hundreds of classes across the
  12 generated packages).
- **Cross-package covariant setter on inherited properties** when
  the emission namespace shadows the owner's type with a same-named
  child class. `AdwMessageDialogProps.application` was emitted with
  `set application(AdwApplication?)` overriding
  `GtkWindowProps.application`'s `set application(GtkApplication?)`,
  which is an invalid override because `AdwApplication?` is narrower
  than `GtkApplication?`. The resolver in `bridgeFor` was using
  `relativeTo ?? namespace`, which fell back to the emission
  namespace (`Adw`); unqualified `<type name="Application"/>` on
  the typed `set_application` parameter was then resolved against
  `Adw.Application` instead of the property's owner namespace
  (`Gtk.Application`). The fix passes `relativeTo: ownerNs`
  explicitly so unqualified names resolve against the namespace that
  actually declared the typed method.
- **Type lie on props accessors for properties whose typed method
  returns nullable.** `String get label => _self.getLabel()` was
  emitted for `GtkButton.props.label` even though `getLabel()` is
  typed as `String?` (the underlying C function returns `gchar*`
  with `transfer-ownership="none"`, which the resolver maps to
  `String?`). Reading the property before assigning would throw a
  type error at runtime. The fix derives the getter and setter
  types from the typed method's bridge instead of the property's
  declared `<type>` element, so nullability always propagates.
- **Use-after-free in caller-allocated record OUT params.** The
  initial implementation allocated `malloc<Pointer<ffi.Void>>()` (8
  bytes for one pointer) for the buffer and freed it in `finally`,
  causing two bugs: (a) `free(): invalid next size` because GTK wrote
  the full 32-byte `GtkTextIter` into 8 bytes of heap; (b) a SEGV
  inside `gtk_text_iter_get_buffer` because the wrapper freed the
  backing buffer before the iter's handle was dereferenced by the
  next call (e.g. `textBuffer.getText(getStartIter(), getEndIter(),
  false)` in `EditorApp.saveFile`). The fix uses
  `HeapAnchor.allocate(256)` from `package:gir_ffi`, a
  `Finalizable` whose `NativeFinalizer` calls `malloc.nativeFree`
  when the anchor is GC'd. The wrapper holds the anchor via
  `T.fromPointer(_buffer)` (`_buffer` is the anchor's `Pointer<Uint8>`
  field, which the returned wrapper captures as its `handle`); drop
  the wrapper and GC frees the buffer. End-to-end covered by
  [`packages/gtk4/test/gtk4_text_iter_test.dart`](./packages/gtk4/test/gtk4_text_iter_test.dart)
  and [`example/test/editor_savefile_test.dart`](./example/gtk4_examples/test/editor_savefile_test.dart).
- **Inheritance walker stop-at-local-name**: `Adw.Application` →
  `Gtk.Application` previously stopped at `Adw.Application` because both
  classes have local name `Application`. Now keyed by qualified name
  (`Gio.Application`, `Adw.Application` are distinct keys).
- **Signal dedup that merged different signals with the same name**:
  `Gio.DBusObject::interface-added` (1 arg) and
  `Gio.DBusObjectManager::interface-added` (2 args) used to be merged
  into one bucket, dropping the manager's typed helper. Dedup is now
  by `GirSignal` instance identity.
- **`signals_emitter.dart` had an internal duplicate function body**
  from a partial refactor that produced an uncompilable generator.
- **`Utf8` is now used unqualified** in the generated `signals.dart`
  (`ffi.Pointer<Utf8>` in trampolines, `Pointer<Utf8>` in the
  `g_signal_connect_data` binding). The barrel imports
  `package:ffi/ffi.dart` which exports `Utf8`; prefixing with `ffi.`
  resolves to `dart:ffi`'s namespace, which has no `Utf8`. The earlier
  prefix triggered `non_type_as_type_argument` lints on every bucket.
- **Bool/int/double returns from trampolines** now cast back to the
  FFI native type (`ffi.Bool`, `ffi.Int32`, `ffi.Uint32`,
  `ffi.Double`). Without the cast, the analyzer rejected the
  trampoline's return with `return_of_invalid_type`; with the cast
  only on the Dart representation (`bool`/`int`/`double`), the
  runtime rejected it with "NativeCallable cannot be constructed
  dynamically." The fix uses FFI native types in the trampoline
  signature (the `NativeCallable<T>` constraint) and casts the return
  value in the body so the body matches the Dart-primitive callback
  type.
- **Cross-namespace type lookups for callback-typed params** no longer
  accidentally pick up types from the current namespace when the
  signal was authored elsewhere (`GirSignal` carries its originating
  namespace so the resolver searches there first).
- **`(null as dynamic) as ffi.Void`** is the explicit void return
  for trampolines; a bare `return;` is rejected because `ffi.Void`
  is non-nullable, and `return ffi.nullptr` produces a
  `Pointer<Never>` the analyzer refuses to coerce.
- **Callback-typed parameters with unresolvable user-facing signatures
  silently emitted broken wrappers** with a parameter type of
  `void?` that doesn't match the corresponding `NativeCallable<T>`
  signature. Triggered when the callback typedef is reachable only
  through a `<alias>` whose target callback declaration isn't in any
  GIR (e.g. `GObject.ClosureMarshal` aliases a callback typedef that
  lives in GLib's headers but isn't present in the GIR corpus). The
  bridge now skips the parameter (and the callable) with the same
  reason the FFI signature already records, instead of producing a
  wrapper whose parameter type doesn't match its native call site.
  Surfaced during the array-type resolution pass because
  `gtk_cclosure_expression_new`'s `params` array used to be skipped,
  masking the latent bug.

### Added
- **The composite-template stack** — two new packages make GTK
  composite templates usable from Dart:
  - `packages/gtk_templates` — the `@GtkTemplate`, `@GtkTemplateChild`
    and `@GtkTemplateCallback` annotations, the `GtkTemplateXml` /
    `GtkTemplateFile` source variants, `getWidgetClass`, `widgetTypeOf`,
    `prepareTemplateXml`, `claimTemplateType`, `snakeCase` and
    `gbytesFromString`.
  - `packages/gtk_templates_builder` — an AST scanner, a pure codegen,
    a `build_runner` builder and a standalone CLI.

  The builder emits **one part file per source file** —
  `<source-basename>.g.dart`, the `json_serializable` convention —
  holding a `_$<ClassName>Template` mixin per annotated class. The name
  is derivable from the source file's name alone, so the user never has
  to predict a generated filename.

  `build_to: source` lives in the **provider** package's `build.yaml`
  (`packages/gtk_templates_builder/build.yaml`); a consumer's
  `build.yaml` only sets `generate_for`. The builder fails with an
  actionable message — naming the exact `part` line, or the exact
  `import` lines, to add — when the user's library is missing either.

  The design is written up in [docs/templates.md](./docs/templates.md).

- **A callback trampoline for template signals.** Each
  `<signal name="…" handler="…"/>` in the template XML is wired to the
  user's instance method through the child's typed signal API
  (`button.onClicked(() => onClicked())`), with a per-instance closure
  that lives as long as the widget. The user's method must match the
  GIR-declared arity of the signal.

- **`GBytes` in `package:glib`, re-exported from
  `package:gtk_templates`.** `GBytes` is a `<glib:boxed>` opaque
  record, declared only in `GLib-2.0.gir`, so the generator emits it
  once — in the namespace that owns it. `package:gtk_templates`
  re-exports it, so the template codegen and the user's code need a
  single import and a single unambiguous `GBytes`.

- **`example/todo` rebuilt around the template stack.** A libadwaita
  counter whose window is a `@GtkTemplate` host class with an inline
  XML template. The package moved from `src/` to `lib/` — the standard
  Dart layout, matching `example/notepad` — and the generated part file
  is written next to its source.

### Changed
- **The template packages moved to a one-part-file-per-source contract**
  (`0.3.1` → `0.4.0`). The builder used to derive the generated file's
  name from the annotated *class*, so the user had to predict a
  filename to write the `part` directive. It is now derived from the
  *source file* name: one source file with several `@GtkTemplate`
  classes produces one part file holding every mixin. The migration
  diff is in
  [`packages/gtk_templates_builder/CHANGELOG.md`](./packages/gtk_templates_builder/CHANGELOG.md).

- **Dart-level subclassing of the generated wrappers is now a documented,
  tested contract.** Generated GObject classes are emitted as `class`
  (not `final class`) and their `<ClassName>Props` companions are
  public and extendable, so user code can write
  `class MyButton extends GtkButton` and narrow a return type
  covariantly. The contract is now pinned by the generator tests
  (group *Dart-level subclassing contract*) and the ownership and
  lifetime rules are written down in
  [docs/subclassing.md](./docs/subclassing.md), with a worked example
  in
  [`packages/gtk4/test/gtk4_subclass_test.dart`](./packages/gtk4/test/gtk4_subclass_test.dart).
  The capability itself was already present; what was missing was the
  documentation, the regression test and the example.

- **A distinct skip reason for duplicate constants.** Two GIR
  constants that map to the same Dart name — overwhelmingly GDK's
  keyvals, which the GIR declares twice under two capitalisations
  (`KEY_Armenian_at` and `KEY_armenian_at`) — were reported as
  `name collision: <name>`, which said nothing about what happened.
  They now read
  `duplicate constant: <A> and <B> both map to <name>` and name both
  GIR symbols. 335 entries across `gdk4` and `glib` change their
  reason. See
  [skip-categories.md](./docs/skip-categories.md#duplicate-constant-a-and-b-both-map-to-name).

- **The generated packages are regenerated.** `packages/adw`,
  `packages/gi_repository3`, `packages/gdk_pixbuf`, `packages/cairo`
  and parts of `packages/glib` had been committed from an older
  generator and did not match the current one — `adw` was missing
  225 array-typed methods that the generator now emits. They are
  regenerated here, and the corpus-wide skip count drops from 3,472
  to 3,242.

- **The example apps are workspace members.** `example/notepad` and
  `example/todo` now carry `resolution: workspace` and are listed in
  the root pubspec, so they resolve against the root lock file and are
  covered by the root `dart analyze`. Dart's workspace refuses a
  member nested inside another member's directory, so the small demos
  package moved down one level: `example/` now holds
  `example/gtk4_examples/`, `example/notepad/` and `example/todo/`
  side by side, and `example/` itself is no longer a package.

  The generator's `syncRootPubspec` — which rewrites the root
  `workspace:` list on every run — now *discovers* the members
  instead of hard-coding `generator`, `packages/*` and `example`. It
  skips hidden directories (pub's own `.dart_tool/pub/packages/…`
  cache) and skips a package nested inside another package's
  directory.

- **`dart format .` is a no-op again.** The repository had drifted
  from the formatter, and the generated part files were not
  format-clean — so a consumer running `dart format .` would see a
  diff against the checked-in generated file, and the next rebuild
  would revert it. The builder now runs its output through the same
  formatter `dart format` uses (`package:dart_style`), so the two
  cannot disagree, and a test asserts the output is a fixed point of
  the formatter.

## 1.0.0 — 2026-09-28

### Added
- Initial workspace: 11 generated packages (glib, gobject, gio,
  gdk_pixbuf, cairo, pango, gdk4, gtk4, graphene, gsk4, adw) plus
  `gir_ffi` runtime helpers.
- GIR XML loader with transitive include resolution
  (`GirLoader.loadAllWithDependencies`).
- Immutable data model covering `<class>`, `<interface>`, `<record>`,
  `<union>`, `<enumeration>`, `<bitfield>`, `<callback>`, `<function>`,
  `<constant>`, `<alias>`, `<signal>`, `<property>`, `<method>`,
  `<constructor>`, `<parameter>`.
- Type resolver with built-in scalar table, declared-type table, and
  cross-namespace deduplication via `c:type` canonicalisation.
- Per-package emitter pipeline: `EnumEmitter`, `FunctionEmitter`,
  `RecordEmitter`, `ClassEmitter`, `CallbackEmitter`, plus support
  code (`library_emitter.dart`, `context.dart`, `report.dart`).
- `void(void)` signal helpers via per-package `signals.dart` with a
  single trampoline + per-id registry and shared destroy-notify.
- Skip report written to `packages/<lib>/skip_report.txt` for every
  symbol the generator could not emit, with category + reason.
- Generator unit tests (`loader_test`, `parser_test`, `naming_test`,
  `types_test`, `emitter_test`, `signals_emitter_test`,
  `signals_helper_test`).
- Runtime smoke test in `packages/glib/test/glib_smoke_test.dart`
  exercising constant lookup and async-queue callbacks.

### Known limitations
- Variadic functions (`...` parameters) are skipped.
- Non-string-list arrays are skipped ("array types are handled in a
  later phase").
- Nullable scalars (`int?`, `bool?`) as parameters are skipped.
- Detailed signal names (`notify::property-name`) had no escape
  hatch beyond the bare `g_signal_connect_data` lookup.
- Inherited signals on descendant classes were not surfaced — only
  each class's own signals emitted an `onSignalName` method.
- The per-package analysis_options had only `unintended_html_in_doc_comment`
  suppressed; FFI analyzer false positives on bucket identifiers and
  multi-line `NativeCallable<T>` broke regeneration on every run.
- `Utf8` was emitted as `ffi.Utf8` (resolving to `dart:ffi`'s
  namespace, which has no `Utf8`), causing
  `non_type_as_type_argument` errors in every package.
