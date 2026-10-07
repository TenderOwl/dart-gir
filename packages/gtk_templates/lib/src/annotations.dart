/// Marker annotations for GTK composite templates.
///
/// These are pure-metadata constant constructors — they carry no
/// runtime behaviour. The `gtk_templates_builder` reads them at
/// build time via the `analyzer` package and emits a per-class
/// `_$ClassTemplate` mixin (see `docs/templates.md`).
///
/// Example (inline XML):
///
/// ```dart
/// @GtkTemplate(source: GtkTemplateXml('''
/// <interface>
///   <template class="MyWindow" parent="GtkApplicationWindow">
///     <object class="GtkButton" id="button">
///       <signal name="clicked" handler="on_clicked"/>
///     </object>
///   </template>
/// </interface>
/// '''))
/// class MyWindow extends GtkApplicationWindow
///     with _$MyWindowTemplate {
///   @GtkTemplateChild(name: 'button')
///   late final GtkButton button;
///
///   @GtkTemplateCallback()
///   void onClicked(GtkWidget sender) {
///     button.setLabel('Clicked!');
///   }
/// }
/// ```
///
/// Example (file in the package source tree):
///
/// ```dart
/// @GtkTemplate(source: GtkTemplateFile('lib/myapp/window.ui'))
/// class MyWindow extends GtkApplicationWindow
///     with _$MyWindowTemplate { ... }
/// ```
library;

/// Where a composite template's XML comes from.
///
/// Two variants:
///
///   - [GtkTemplateXml] — the raw XML string, embedded as a Dart
///     string literal at the call site. Convenient for small
///     templates, prototypes, and tests; no I/O at build or
///     runtime.
///   - [GtkTemplateFile] — a path to a `.ui` file, resolved
///     relative to the **package root** (the directory holding
///     `pubspec.yaml`). The codegen reads the file at build
///     time and embeds the contents as a string; the runtime
///     path is then identical to [GtkTemplateXml].
///
/// Both variants reduce at codegen time to a `GBytes` passed to
/// `GtkWidgetClass.setTemplate`. `GtkWidgetClass.setTemplateFromResource`
/// is not part of this surface; users who need it call the
/// lower-level API directly.
sealed class GtkTemplateSource {
  const GtkTemplateSource();

  @override
  String toString();
}

/// Raw XML, embedded as a Dart string literal at the call site.
final class GtkTemplateXml extends GtkTemplateSource {
  /// `const` so the annotation is parseable as a constant
  /// expression by the `analyzer` package.
  const GtkTemplateXml(this.content);

  /// The full `<interface>...</interface>` document. Multiline
  /// raw strings (e.g. `'''…'''`) work.
  final String content;

  @override
  String toString() => 'xml($content)';
}

/// Path to a `.ui` file, resolved relative to the package root.
///
/// The path is captured verbatim at the call site; resolution
/// against the package root happens at codegen time, on the
/// build machine, not when the user's code runs. The file's
/// contents are then embedded as a string in the generated
/// mixin (no runtime I/O).
final class GtkTemplateFile extends GtkTemplateSource {
  /// `const` so the annotation is parseable as a constant
  /// expression by the `analyzer` package.
  const GtkTemplateFile(this.path);

  /// Path to a `.ui` file, relative to the package root. The
  /// `lib/` prefix is allowed and conventional; e.g.
  /// `'lib/myapp/window.ui'`.
  final String path;

  @override
  String toString() => 'file($path)';
}

/// Marks a Dart class as a GTK composite-template host.
///
/// The single mandatory named argument is [source], one of:
///   - `GtkTemplateXml('…')` for inline XML,
///   - `GtkTemplateFile('path/relative/to/package/root.ui')` for
///     a `.ui` file in the package source tree.
///
/// The codegen emits a `_$ClassTemplate` mixin that:
/// 1. On first instance construction, calls
///    `GtkWidgetClass.setTemplate(bytes)` with the (codegen-read)
///    XML wrapped in a `GBytes`, then walks the field list to
///    install per-instance bindings via
///    `bind_template_child_full` / `bind_template_callback_full`.
/// 2. In the mixin's `initTemplate()` override, populates each
///    `late final` field via `GtkWidget.getTemplateChild`.
/// 3. For each `@GtkTemplateCallback` method, connects the
///    corresponding signal via `widget.connectSignal(...)`.
///
/// ### Migrating from 0.1.x
///
/// 0.1.0's `@GtkTemplate(resourcePath: '/com/myapp/foo.ui')` is
/// gone. Two replacements are available:
///   - If the `.ui` file lives in the package source tree,
///     switch to `@GtkTemplate(source: GtkTemplateFile('lib/<path>.ui'))`.
///   - If the XML is short enough, inline it with
///     `@GtkTemplate(source: GtkTemplateXml('<interface>…</interface>'))`.
///
/// `GtkWidgetClass.setTemplateFromResource` is no longer in the
/// codegen dispatch; users who need it can call the lower-level
/// API directly outside the `gtk_templates` system.
class GtkTemplate {
  /// `const` so the annotation is parseable as a constant
  /// expression by the `analyzer` package.
  const GtkTemplate({required this.source});

  /// Where the template XML comes from.
  final GtkTemplateSource source;
}

/// Marks a `late final` field as a template child.
///
/// [name] is the `id` attribute in the template XML. When null, the
/// codegen uses the snake-case form of the field name (matching
/// the PyGObject / GTK macro convention).
class GtkTemplateChild {
  const GtkTemplateChild({this.name});

  /// Template-XML `id`, or null to default to the snake-case
  /// field name.
  final String? name;
}

/// Marks an instance method as a template-callback sink.
///
/// The codegen connects the method to the widget's signal whose
/// `handler` attribute in the template XML matches the
/// snake-case form of the method name. Signature must be one of
/// `void()` or `void(GtkWidget sender)` in this first cut; other
/// signatures are documented but not emitted yet.
class GtkTemplateCallback {
  const GtkTemplateCallback();
}
