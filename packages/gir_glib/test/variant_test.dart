// The reference semantics of `GVariant` — the one type in the corpus
// that uses *floating* references.
//
// A floating reference belongs to nobody: the value a constructor
// hands over is floating, and the first consumer either sinks it or
// takes it over. The GIR names the sink as the type's copy function
// (`g_variant_ref_sink`), so the bindings take a reference of their
// own — and own it.
//
// The bug this pins: the constructor used to hand the floating
// reference over as it was, and the wrapper did not own it. A consumer
// that assumes ownership — GLib's `g_variant_new_variant`, GTK's
// `gtk_actionable_set_action_target_value` — then owned the very
// reference the wrapper's `unref()` released. The reference count
// underflowed and the heap was corrupted.
//
// Run with:
//   dart test test/variant_test.dart

import 'package:gir_glib/gir_glib.dart';
import 'package:test/test.dart';

void main() {
  group('GVariant floating references', () {
    test('a constructor takes a reference of its own', () {
      final variant = GVariant.string('hello');

      // The wrapper owns the reference — `owned` is the single source
      // of truth for that.
      expect(variant.owned, isTrue);
      // The reference is not floating any more: the constructor sank
      // it, so the wrapper owns exactly one reference.
      expect(variant.isFloating(), isFalse);
      expect(variant.getString().$1, 'hello');

      variant.unref();
      expect(variant.owned, isFalse);
    });

    test('a consumer that assumes ownership keeps a reference of its own', () {
      final variant = GVariant.string('hello');

      // `g_variant_new_variant` takes ownership of the value it is
      // given: "if @child is a floating reference, the new instance
      // takes ownership of @child".
      final boxed = GVariant.variant(variant);

      // The consumer took a reference of its own; the wrapper still
      // owns the one it took.
      expect(variant.owned, isTrue);
      variant.unref();

      // The value survives the wrapper's release — the consumer holds a
      // reference of its own. Before the fix the release dropped the
      // consumer's reference and the value was freed underneath it.
      expect(boxed.nChildren(), 1);
      final child = boxed.getChildValue(0);
      expect(child.getString().$1, 'hello');
      child.unref();

      boxed.unref();
    });
  });
}
