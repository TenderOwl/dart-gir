#!/usr/bin/env bash
# Wrapper invoked by the `dart-build` meson target. Runs
# `build_runner build` + the staging-to-lib sync, then AOT-compiles
# the example binary. The meson `command` array takes a single
# shell-out, so we have to bash out for the multi-step pipeline.
#
# Arguments:
#   $1 — output path for the AOT-compiled binary
#   $2 — entry-point path (`bin/todo.dart`)
set -euo pipefail

output="$1"
entry="$2"

# `build_runner` requires `pubspec.yaml` in the current directory;
# the script is invoked from `_build/...` (meson working dir), so cd
# to the package root first.
package_root="$(dirname "$(dirname "$(readlink -f "$0")")")"
cd "$package_root"

# Regenerate the `*.gtk_templates.dart` part files via the
# build_runner builder, then copy them into `lib/` so the user's
# `part '<basename>.gtk_templates.dart';` directives resolve at
# AOT compile time. build_runner 2.4.x writes to
# `.dart_tool/build/generated/`, hence the explicit sync step.
dart run build_runner build --delete-conflicting-outputs
dart run tool/sync_templates.dart

dart compile exe -o "$output" "$entry"