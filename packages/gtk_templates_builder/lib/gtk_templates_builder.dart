/// build_runner builder entry-point for `package:gtk_templates`.
///
/// Re-exports the [gtkTemplatesBuilder] factory for `build.yaml`
/// registration. Consumers do not import this package directly; the
/// builder is auto-applied to packages that depend on
/// `gtk_templates_builder` via the `auto_apply: dependents` setting
/// in [build.yaml].
library;

export 'src/builder.dart';