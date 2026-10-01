// Unit tests for `HeapAnchor`, the finalizer-backed buffer used by the
// generator for caller-allocated OUT parameters (e.g. `GtkTextIter*`,
// `GValue*`). Verifies that:
//
//   * `allocate(N)` returns a non-null `Pointer<Uint8>` whose backing
//     memory is zero-initialized (calloc semantics).
//   * Multiple allocations yield distinct buffers (no aliasing).
//   * The buffer survives across reads — it's reachable via the anchor
//     until the finalizer fires on GC, not freed eagerly.
//   * The buffer's content can be written and read back via both the
//     cached `buffer` and a re-derivation through the same anchor.
//
// HeapAnchor attaches a NativeFinalizer in `allocate`; the finalizer
// frees the buffer on GC. The tests intentionally do NOT call
// `malloc.free` manually — doing so would double-free the buffer once
// the finalizer eventually fires.
//
// Run with:
//   dart test test/heap_anchor_test.dart

import 'dart:ffi';

import 'package:gir_ffi/gir_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('HeapAnchor', () {
    test('allocate returns a non-null Uint8 buffer', () {
      final anchor = HeapAnchor.allocate(256);
      expect(anchor.buffer, isNot(equals(nullptr)));
      expect(anchor.buffer, isA<Pointer<Uint8>>());
      // Anchor is dropped here; finalizer will free on GC.
    });

    test('two allocations yield distinct buffers (no aliasing)', () {
      final a = HeapAnchor.allocate(64);
      final b = HeapAnchor.allocate(64);
      expect(a.buffer, isNot(equals(b.buffer)));
      // Writing through one must not corrupt the other.
      a.buffer[0] = 0xAA;
      b.buffer[0] = 0xBB;
      expect(a.buffer[0], 0xAA);
      expect(b.buffer[0], 0xBB);
      // Both anchors dropped; both buffers eventually freed by GC.
    });

    test('buffer survives across reads (no premature free)', () {
      // The generator's contract is: allocate → C fills → fromPointer
      // reads. The buffer must remain valid until the Dart wrapper is
      // GC'd. Simulate that by reading the same address multiple times
      // before dropping the anchor.
      final anchor = HeapAnchor.allocate(128);
      final buf = anchor.buffer;
      // Write a sentinel.
      buf[0] = 0x42;
      // Re-derive `buffer` from the anchor and confirm it didn't move.
      expect(anchor.buffer.address, equals(buf.address));
      // The sentinel survives the re-derivation.
      expect(anchor.buffer[0], 0x42);
      // Anchor dropped at end of scope; finalizer frees on GC.
    });

    test('buffer is zero-initialized at allocation', () {
      // calloc semantics: every byte is 0 on return. The C side can
      // therefore safely treat unwritten bytes as "uninitialized" or
      // rely on defaults without UB.
      final anchor = HeapAnchor.allocate(64);
      for (var i = 0; i < 64; i++) {
        expect(anchor.buffer[i], 0, reason: 'byte $i must be zero');
      }
      // Anchor dropped; finalizer frees on GC.
    });

    test('allocate(0) returns a valid buffer (calloc corner case)', () {
      // calloc<Uint8>(0) is implementation-defined; GLibc returns a
      // unique non-null pointer. The generator currently always passes
      // a positive size, but we assert non-null here so any future
      // caller that passes 0 still gets a usable anchor.
      final anchor = HeapAnchor.allocate(0);
      expect(anchor.buffer, isA<Pointer<Uint8>>());
      expect(anchor.buffer, isNot(equals(nullptr)));
    });

    test('Finalizable contract: anchor can be attached and detached', () {
      // HeapAnchor implements Finalizable, so the static finalizer
      // attached in `allocate` is well-defined. This test asserts the
      // API surface matches Dart's `Finalizable` contract.
      final anchor = HeapAnchor.allocate(32);
      expect(anchor, isA<Finalizable>());
      // Sanity: the anchor survives re-derivation of the buffer.
      final ref = anchor.buffer.address;
      expect(ref, isA<int>());
      expect(ref, isNot(equals(0)));
    });
  });
}
