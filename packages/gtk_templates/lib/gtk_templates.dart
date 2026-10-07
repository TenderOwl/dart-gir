/// Public surface of `package:gtk_templates`.
///
/// Exports:
///   - `@GtkTemplate` / `@GtkTemplateChild` / `@GtkTemplateCallback`
///     marker annotations read by `gtk_templates_builder`.
///   - `GtkTemplateSource` sealed hierarchy: `GtkTemplateXml`
///     (inline XML) and `GtkTemplateFile` (path relative to the
///     package root). The two variants of `@GtkTemplate.source:`.
///   - `getWidgetClass(GtkWidget)` runtime helper used by the
///     codegen-emitted `_$ClassTemplate` mixin to walk from a
///     widget instance to its `GtkWidgetClass*`.
///   - `snakeCase(String)` conversion used by the mixin when
///     registering callback symbols.
///   - `GBytes` and `gbytesFromString` for the codegen's
///     `setTemplate` path. Hand-written until `package:gobject`
///     regenerates with a generated `GBytes` record.
library;

export 'src/annotations.dart'
    show
        GtkTemplate,
        GtkTemplateChild,
        GtkTemplateCallback,
        GtkTemplateSource,
        GtkTemplateXml,
        GtkTemplateFile;
export 'src/bytes.dart' show GBytes, gbytesFromString;
export 'src/runtime.dart' show getWidgetClass, snakeCase;

