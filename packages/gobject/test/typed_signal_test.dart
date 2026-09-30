// Smoke check that the typed-signal trampoline pipeline is reachable
// from outside the helper file via the public `connectSignal` escape
// hatch. End-to-end tests for `connectSignal` + per-bucket registries
// live in `signal_helpers_test.dart`.

import 'dart:ffi' as ffi;

import 'package:gobject/gobject.dart';
import 'package:test/test.dart';

void main() {
  test('typed signal helpers compile and link', () {
    // Connecting through the public `connectSignal` with a NULL instance
    // returns 0 — GLib rejects the call. The important part is that the
    // call site compiles and runs without crashing, exercising the
    // per-package `_gSignalConnectData` binding.
    final id = connectSignal(ffi.nullptr, 'dartgir-skip', () {});
    expect(id, 0, reason: 'GLib returns 0 for invalid instance');
  });
}
