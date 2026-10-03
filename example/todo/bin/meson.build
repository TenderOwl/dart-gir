dart = find_program('dart')

# `build_runner` writes generated `*.gtk_templates.dart` files into
# `.dart_tool/build/generated/todo/lib/...` rather than directly into
# the source tree (build_runner 2.4.x doesn't auto-promote plain
# `Builder` outputs). `tool/sync_templates.dart` copies them into
# `lib/` so the user's `part '<basename>.gtk_templates.dart';`
# directives resolve at AOT compile time. We chain both into the
# dart-build target so users only need `meson compile -C _build`.
custom_target(
  'dart-build',
  build_by_default: true,
  # Always rebuild — picks up source edits, and re-runs the
  # build_runner + sync step so `*.gtk_templates.dart` part files
  # are present before `dart compile` AOT-reads them.
  build_always_stale: true,
  output: meson.project_name(),
  console: true,
  install: true,
  install_dir: bindir,
  env: {
    'CARGO_HOME': meson.project_build_root() / 'cargo-home',
    'APP_ID': application_id,
    'GETTEXT_PACKAGE': meson.project_name(),
    'LOCALEDIR': localedir,
    'RESOURCES_FILE': pkgdatadir / 'resources.gresource',
  },
  command: [
    meson.project_source_root() / 'bin' / 'build_with_part_files.sh',
    '@OUTPUT@',
    meson.project_source_root() / 'bin' / meson.project_name() + '.dart',
  ],
)
