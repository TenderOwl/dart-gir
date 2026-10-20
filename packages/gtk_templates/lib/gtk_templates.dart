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
///   - `widgetTypeOf(GtkWidget)`, `prepareTemplateXml(String, int)`
///     and `claimTemplateType(int, String)` — the helpers the
///     emitted mixin uses to resolve the instance's native type,
///     make the XML's `<template class=… parent=…>` attributes match
///     it, and keep the one-template-per-native-class rule GTK
///     enforces.
///   - `snakeCase(String)` conversion used by the mixin when
///     registering callback symbols.
///   - `gbytesFromString` for the codegen's `setTemplate` path.
///     The `GBytes` record itself is owned by `package:glib`
///     (the generator emits it as part of the standard
///     `<glib:boxed>` pass); re-export it from here so the
///     user code only needs one import.
library;

export 'package:glib/glib.dart' show GBytes;

export 'src/annotations.dart'
    show
        GtkTemplate,
        GtkTemplateChild,
        GtkTemplateCallback,
        GtkTemplateSource,
        GtkTemplateXml,
        GtkTemplateFile;
export 'src/bytes.dart' show gbytesFromString;
export 'src/runtime.dart'
    show
        claimTemplateType,
        getWidgetClass,
        prepareTemplateXml,
        rewriteTemplateTypes,
        snakeCase,
        stripTemplateSignals,
        widgetTypeOf;
