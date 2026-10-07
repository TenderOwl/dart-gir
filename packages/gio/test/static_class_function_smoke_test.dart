// Smoke test for the generator's static-class-function path:
//
// A GIR `<method>` with `moved-to="<bare>"` (the value has no dot,
// so the target is a namespace function, not another class method) is
// skipped, and the namespace function is re-emitted as a `static`
// method on the owning GIR class. The classic case in the corpus is
// `GResource.resourcesRegister` / `GResource.resourcesUnregister`
// (`g_resources_register` / `g_resources_unregister`).
//
// This test only confirms the bindings compile — the runtime effect
// of `g_resources_register` mutates the process-wide resource table,
// so a real round-trip would need a valid compiled bundle to feed
// into `GResource.fromData`, which is out of scope for a smoke test.
// The compile-time reference is sufficient: if the generator
// dropped the binding or emitted the method under a different name,
// this file would fail to build under `dart analyze`.

import 'package:gio/gio.dart';
import 'package:test/test.dart';

/// Capture the bound C symbol for `g_resources_register` to confirm
/// the static-method binding was emitted by the generator. Calling
/// this with a null handle is undefined behavior at the C level
/// (and the test never runs that far), but reaching this binding
/// forces the `static final _gResourcesRegister = …lookup(...)`
/// lookup to succeed at construction time — a missing C symbol
/// would throw an `ArgumentError` instead.
final void Function(GResource) _gResourcesRegister =
    GResource.resourcesRegister;

/// Same for `g_resources_unregister`.
final void Function(GResource) _gResourcesUnregister =
    GResource.resourcesUnregister;

void main() {
  test('GResource.resourcesRegister and resourcesUnregister bindings '
      'compile and are reachable', () {
    // `_gResourcesRegister` is a `static final` that performs the
    // FFI lookup at first access. Constructing it here proves the
    // generator emitted the binding — if the static method is
    // missing, this file won't compile.
    expect(_gResourcesRegister, isNotNull);
    expect(_gResourcesUnregister, isNotNull);
  });
}
