// The OUT array shapes, against the real Graphene.
//
// An OUT array is read back into a Dart list. Two shapes meet here:
//
//   * a **caller-allocated** array of a fixed size — `graphene_vec2_to_float`
//     and its `float[2]`: the wrapper allocates the buffer itself, passes
//     it and copies the components out after the call;
//   * the same shape for a bigger array — `graphene_matrix_to_float` and
//     its `float[16]`.
//
// A wrong length shows up as a list that is short or long, and a wrong
// element type shows up as garbage components, so every case is checked
// against the values that went in.
//
// Run with:
//   dart test test/out_array_test.dart

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gir_graphene/gir_graphene.dart';
import 'package:test/test.dart';

void main() {
  group('a fixed-size float array', () {
    test('the components come back as a list', () {
      final v = GrapheneVec2.alloc();
      addTearDown(v.free);

      final src = calloc<ffi.Float>(2);
      addTearDown(() => calloc.free(src));
      src[0] = 1.5;
      src[1] = -2.25;
      v.initFromFloat(src);

      final floats = v.toFloat();

      expect(floats, hasLength(2));
      expect(floats[0], 1.5);
      expect(floats[1], -2.25);
    });

    test('a bigger array keeps its own length', () {
      final m = GrapheneMatrix.alloc();
      addTearDown(m.free);
      // `graphene_matrix_alloc` hands out uninitialized memory; the
      // identity matrix is what the values below describe.
      m.initIdentity();

      final floats = m.toFloat();

      // Sixteen components — the size the GIR states (`fixed-size="16"`).
      // A length that came from anywhere else would be wrong here.
      expect(floats, hasLength(16));
      // The identity matrix has one on the diagonal and zero everywhere
      // else. The components are in column-major order, so the diagonal
      // sits at 0, 5, 10 and 15.
      expect(floats[0], 1.0);
      expect(floats[5], 1.0);
      expect(floats[10], 1.0);
      expect(floats[15], 1.0);
      expect(floats.where((f) => f == 0.0), hasLength(12));
    });
  });
}
