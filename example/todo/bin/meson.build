dart = find_program('dart')

custom_target(
  'dart-build',
  build_by_default: true,
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
    dart,
    'compile',
    'exe',
    '-o', '@OUTPUT@',
    meson.project_source_root() / 'bin' / meson.project_name() + '.dart',
  ],
)
