/// Public surface of `package:gtk_templates_builder`.
///
/// Exports:
///   - [GtkTemplatesBuilder] — the `build_runner` `Builder` that
///     scans annotated Dart files and emits one
///     `<input>.g.dart` part file per source file.
///   - [scanSource] — pure AST scanner. Tests use it directly
///     without going through `build_runner`.
///   - [codegenLibrary] / [codegenMixin] — pure codegen that
///     turns [ClassTemplatePlan]s + resolved XML into a Dart
///     source string. Tests use them directly.
///   - [formatGeneratedSource] — runs the generated source through
///     the same formatter `dart format` uses, so the part file the
///     builder writes is format-clean.
///   - [partFileBasename] / [checkPartDirective] — the naming
///     and validation rules for the generated part file.
///   - [BuilderPlan], [ClassTemplatePlan], [WidgetBinding],
///     [CallbackBinding] — the data structures describing what
///     the scanner found.
///   - [CodegenInput], [TemplateChildSpec], [TemplateCallbackSpec]
///     — the data structures the codegen consumes.
library;

export 'builder.dart'
    show GtkTemplatesBuilder, scanSource, findPackageRoot, templateAssetId;
export 'builder_plan.dart'
    show BuilderPlan, ClassTemplatePlan, WidgetBinding, CallbackBinding;
export 'codegen.dart'
    show
        codegenLibrary,
        codegenMixin,
        formatGeneratedSource,
        extractChildrenFromXml,
        extractSignalsFromXml,
        snakeCaseToCamel,
        upperCamel,
        partFileBasename,
        checkPartDirective,
        checkRequiredImports,
        requiredImports,
        packageForType,
        CodegenInput,
        TemplateChildSpec,
        TemplateCallbackSpec,
        SignalBinding;
