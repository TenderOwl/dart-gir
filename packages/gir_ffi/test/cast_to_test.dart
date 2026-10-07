// Headless smoke test for `castTo`, the bare-pointer re-wrap helper
// from `package:gir_ffi/gir_ffi.dart`. The companion to the instance
// `cast<T>(factory)` method on every generated wrapper — `castTo` is
// what users reach for when they have a raw `Pointer<Void>` (e.g. from
// a struct OUT param, a custom FFI lookup, or `Pointer.fromAddress`)
// and want to recover their destination class's API.
//
// We can't link the real generated wrappers here (no libgobject), so
// we model the contract with a tiny user-defined class that has the
// same shape: a `fromPointer(handle)` constructor and a `handle`
// field. If `castTo` round-trips the handle and yields an instance
// whose `handle` field matches what we passed in, the contract holds
// for any real wrapper.

import 'dart:ffi' as ffi;

import 'package:gir_ffi/gir_ffi.dart';
import 'package:test/test.dart';

/// Minimal stand-in for a generated wrapper class. Mirrors the shape
/// of `class X { X.fromPointer(handle, {bool owned = false}); ... }`
/// exactly — the cast method's factory parameter is
/// `T Function(Pointer<Void>)`, so the bare `fromPointer(handle)`
/// constructor (no named `owned` parameter) is the simplest fit.
class FakeWrapper {
  FakeWrapper.fromPointer(this.handle);
  final ffi.Pointer<ffi.Void> handle;
}

void main() {
  group('castTo', () {
    test('forwards the handle unchanged and returns an instance whose '
        '`handle` field matches', () {
      final handle = ffi.Pointer<ffi.Void>.fromAddress(0xdeadbeef);
      final result = castTo<FakeWrapper>(handle, FakeWrapper.fromPointer);
      expect(result, isA<FakeWrapper>());
      expect(result.handle.address, equals(handle.address));
    });

    test('handles a null pointer without crashing (the factory '
        'may choose to honor it or return null)', () {
      // We don't assert the factory's behavior on null — only that
      // `castTo` doesn't pre-emptively reject it. The cast method
      // itself treats the handle as opaque.
      final nullHandle = ffi.nullptr;
      expect(
        () => castTo<FakeWrapper>(nullHandle, FakeWrapper.fromPointer),
        returnsNormally,
      );
    });

    test('factory signature accepts a `Pointer<Void>`-only function '
        '(matches the minimal universal shape)', () {
      // If this compiles, the function-type subtyping works the way
      // the generator assumes. Compile-time check, no runtime
      // assertion needed.
      FakeWrapper Function(ffi.Pointer<ffi.Void>) factory =
          FakeWrapper.fromPointer;
      final handle = ffi.Pointer<ffi.Void>.fromAddress(0x1);
      expect(castTo<FakeWrapper>(handle, factory).handle.address,
          equals(handle.address));
    });
  });
}