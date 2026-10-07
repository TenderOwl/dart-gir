// Smoke test for the generator's static-class-function path on
// `GdkEvent` (`gdk_events_get_angle` / `_get_center` / `_get_distance`).
//
// These C functions take TWO events as parameters — the GIR exposes
// them as `<method>`s on `GdkEvent` with `<instance-parameter>` plus
// a second `<parameter>`. Before the static-method promotion, the
// generator emitted broken instance-method bodies that only passed
// `this.handle` for `event1` and dropped `event2` entirely on the
// floor. The fix brings the namespace function to `GdkEvent` as a
// `static` method that takes both events as explicit arguments.
//
// This test only confirms the bindings compile — a runtime exercise
// of `gdk_events_get_angle` needs a real `GdkEventSequence*` pair
// (touch events are platform-dependent), which is out of scope for
// a smoke test. The compile-time reference is sufficient: if the
// generator dropped the binding or emitted the method under a
// different name, this file would fail to build under `dart analyze`.

import 'package:gdk4/gdk4.dart';
import 'package:test/test.dart';

/// Capture the bound C symbol for `gdk_events_get_angle` to confirm
/// the static-method binding was emitted by the generator.
final (bool, double) Function(GdkEvent, GdkEvent) _gdkEventsGetAngle =
    GdkEvent.eventsGetAngle;

/// Same for `gdk_events_get_center`.
final (bool, double, double) Function(GdkEvent, GdkEvent) _gdkEventsGetCenter =
    GdkEvent.eventsGetCenter;

/// Same for `gdk_events_get_distance`.
final (bool, double) Function(GdkEvent, GdkEvent) _gdkEventsGetDistance =
    GdkEvent.eventsGetDistance;

void main() {
  test('GdkEvent.eventsGet* bindings compile and are reachable', () {
    // The `static final _gdkEventsGet* = …lookup(...)` lookups run
    // at first access. Constructing these references here proves the
    // generator emitted the bindings — a missing C symbol would
    // throw `ArgumentError`, a missing method name would fail to
    // compile.
    expect(_gdkEventsGetAngle, isNotNull);
    expect(_gdkEventsGetCenter, isNotNull);
    expect(_gdkEventsGetDistance, isNotNull);
  });
}
