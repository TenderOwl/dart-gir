/// Public surface of `package:gtk_templates_builder`.
///
/// Exports:
///   - [GtkTemplatesBuilder] — the `build_runner` `Builder` that
///     scans annotated Dart files and emits the
///     `_$<className>Template` mixin next to each.
///   - [scanSource] — pure AST scanner. Tests use it directly
///     without going through `build_runner`.
///   - [codegenMixin] — pure codegen that turns a
///     [ClassTemplatePlan] + resolved XML into a Dart source
///     string. Tests use it directly.
///   - [BuilderPlan], [ClassTemplatePlan], [WidgetBinding],
///     [CallbackBinding] — the data structures describing what
///     the scanner found.
///   - [CodegenInput], [TemplateChildSpec], [TemplateCallbackSpec]
///     — the data structures the codegen consumes.
library;

export 'builder.dart' show GtkTemplatesBuilder, scanSource;
export 'builder_plan.dart'
    show BuilderPlan, ClassTemplatePlan, WidgetBinding, CallbackBinding;
export 'codegen.dart'
    show
        codegenMixin,
        extractChildrenFromXml,
        CodegenInput,
        TemplateChildSpec,
        TemplateCallbackSpec;
