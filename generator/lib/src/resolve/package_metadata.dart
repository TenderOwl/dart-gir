/// Per-package pub.dev metadata: the description, the topics, and the links
/// every published package carries.
///
/// The generator writes the *working-tree* pubspec — `publish_to: none`,
/// `resolution: workspace`, path dependencies — so the workspace resolves
/// offline. The publication copy is assembled by `tool/release.dart`, which
/// rewrites those fields and copies the metadata from here.
///
/// The description has to be 60–180 characters: pub.dev rejects anything
/// shorter (a one-word description is not a description) or longer. The
/// table below is the single source of those strings.
library;

/// The project's home page.
const String homepage = 'https://dartgir.tenderowl.com';

/// The repository every package's `repository:` points at.
const String repository = 'https://github.com/TenderOwl/dart-gir';

/// The issue tracker every package's `issue_tracker:` points at.
const String issueTracker = 'https://github.com/TenderOwl/dart-gir/issues';

/// pub.dev allows at most five topics per package, each at most 20
/// characters, lower-case and separated by dashes.
const int maxTopics = 5;

/// The shortest description pub.dev accepts.
const int minDescriptionLength = 60;

/// The longest description pub.dev accepts.
const int maxDescriptionLength = 180;

/// The pub.dev metadata of one package.
class PackageMetadata {
  const PackageMetadata({required this.description, required this.topics});

  /// The package's one-line description, 60–180 characters.
  final String description;

  /// The package's pub.dev topics.
  final List<String> topics;
}

/// The metadata of every published package, keyed by the package name.
///
/// The names are the `gir_` names the generator emits — see
/// `packageNameFor` in `types.dart`.
const Map<String, PackageMetadata> packageMetadata = {
  'gir_glib': PackageMetadata(
    description:
        'Generated Dart FFI bindings for GLib 2.0 — fundamental types, the '
        'main loop, strings, hash tables and byte arrays. Produced by '
        'gir_generator.',
    topics: ['ffi', 'glib', 'bindings', 'gnome'],
  ),
  'gir_gobject': PackageMetadata(
    description:
        'Generated Dart FFI bindings for GObject 2.0 — the type system, '
        'signals, properties and closures everything else in the stack '
        'builds on. Produced by gir_generator.',
    topics: ['ffi', 'gobject', 'bindings', 'gnome'],
  ),
  'gir_gio': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Gio 2.0 — files, networking, '
        'D-Bus, settings and the application platform on top of GLib. '
        'Produced by gir_generator.',
    topics: ['ffi', 'gio', 'bindings', 'gnome'],
  ),
  'gir_gdk_pixbuf': PackageMetadata(
    description:
        'Generated Dart FFI bindings for GdkPixbuf 2.0 — image loading, '
        'pixel-buffer manipulation and PNG / JPEG / ICO I/O. Produced by '
        'gir_generator.',
    topics: ['ffi', 'gdk-pixbuf', 'image', 'bindings'],
  ),
  'gir_cairo': PackageMetadata(
    description:
        'Generated Dart FFI bindings for cairo 1.0 — 2D vector graphics: '
        'paths, surfaces, gradients and transforms. Produced by '
        'gir_generator.',
    topics: ['ffi', 'cairo', 'graphics', 'bindings'],
  ),
  'gir_pango': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Pango 1.0 — text layout, font '
        'shaping and rendering, bridging to Freetype and Fontconfig. '
        'Produced by gir_generator.',
    topics: ['ffi', 'pango', 'text', 'bindings'],
  ),
  'gir_gdk4': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Gdk 4.0 — the display-server '
        'abstraction: surfaces, input events, clipboard and drag-and-drop. '
        'Produced by gir_generator.',
    topics: ['ffi', 'gtk4', 'gdk', 'bindings'],
  ),
  'gir_graphene': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Graphene 1.0 — SIMD-friendly '
        'vector, matrix and quaternion primitives for graphics maths. '
        'Produced by gir_generator.',
    topics: ['ffi', 'graphene', 'graphics', 'bindings'],
  ),
  'gir_gsk4': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Gsk 4.0 — the scene-graph kit: '
        'render nodes, renderers, shaders and transforms. Produced by '
        'gir_generator.',
    topics: ['ffi', 'gtk4', 'rendering', 'bindings'],
  ),
  'gir_gtk4': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Gtk 4.0 — the widget toolkit: '
        'widgets, layout containers, dialogs, actions and accessibility. '
        'Produced by gir_generator.',
    topics: ['ffi', 'gtk4', 'gui', 'bindings'],
  ),
  'gir_adw': PackageMetadata(
    description:
        'Generated Dart FFI bindings for Adw 1 — libadwaita’s adaptive '
        'widgets for GNOME applications: header bars, toasts and '
        'navigation. Produced by gir_generator.',
    topics: ['ffi', 'libadwaita', 'gnome', 'bindings'],
  ),
  'gir_gtk_source5': PackageMetadata(
    description:
        'Generated Dart FFI bindings for GtkSource 5 — source-code-aware '
        'text views: language specs, syntax highlighting and gutter '
        'renderers. Produced by gir_generator.',
    topics: ['ffi', 'gtksourceview', 'text', 'bindings'],
  ),
  'gir_gi_repository3': PackageMetadata(
    description:
        'Generated Dart FFI bindings for GIRepository 3.0 — the GIR '
        'typelib loader, for at-runtime introspection of libraries that '
        'are not statically bound. Produced by gir_generator.',
    topics: ['ffi', 'gir', 'introspection', 'bindings'],
  ),
  'gir_ffi': PackageMetadata(
    description:
        'Shared runtime helpers for GIR-generated Dart FFI bindings — '
        'string marshalling, the wrapper cache, HeapAnchor and the native '
        'library loader.',
    topics: ['ffi', 'bindings', 'runtime'],
  ),
  'gir_dart_gobject': PackageMetadata(
    description:
        'Dart-level GObject types: register a native GType for a Dart class '
        'so it can be stored in a GListStore, type-checked natively, and '
        'found again after a round trip.',
    topics: ['gobject', 'gtype', 'dart', 'ffi'],
  ),
  'gir_gtk_templates': PackageMetadata(
    description:
        'Runtime support for the @GtkTemplate, @GtkTemplateChild and '
        '@GtkTemplateCallback annotations and the _\$ClassTemplate mixin '
        'contract. Pair with gir_gtk_templates_builder.',
    topics: ['gtk4', 'template', 'widget', 'ffi'],
  ),
  'gir_gtk_templates_builder': PackageMetadata(
    description:
        'A build_runner builder that scans Dart source for @GtkTemplate '
        'classes and emits the _\$ClassTemplate mixin that wires the '
        'template, its children and its signal handlers.',
    topics: ['gtk4', 'template', 'build-runner', 'codegen'],
  ),
};

/// The metadata of [pkg], or null when the package is not published.
///
/// A package outside the table is not a publication blocker: the release
/// tool falls back to a generated description.
PackageMetadata? metadataFor(String pkg) => packageMetadata[pkg];
