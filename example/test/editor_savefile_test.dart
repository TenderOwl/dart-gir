// Integration smoke test for the editor's saveFile code path.
//
// This mirrors what `EditorApp.saveFile` does:
//   1. setText("...") on a GtkTextBuffer
//   2. Call getText(getStartIter(), getEndIter(), false)
//   3. Verify the returned string round-trips.
//
// Before the HeapAnchor fix, step 2 segfaulted inside
// `gtk_text_iter_get_buffer` because the underlying buffer backing
// the iter had already been freed by the time the second C call
// dereferenced the iter's handle. The HeapAnchor-backed buffer is
// finalizer-attached, so it stays alive as long as the user holds
// the returned `GtkTextIter`.
//
// Run with:
//   dart test test/editor_savefile_test.dart

import 'dart:io';

import 'package:gtk4/gtk4.dart';
import 'package:test/test.dart';

void main() {
  test('saveFile flow: setText → getStartIter/getEndIter → getText', () {
    final buffer = GtkTextBuffer();
    final payload = 'first line\nsecond line\nthird\n';
    buffer.setText(payload, -1);

    // Exact pattern from `EditorApp.saveFile`:
    final start = buffer.getStartIter();
    final end = buffer.getEndIter();
    final written = buffer.getText(start, end, false);
    expect(written, payload);

    // Round-trip via a real file: write to disk, read back, and
    // confirm we can re-feed it into a fresh buffer.
    final tmp = Directory.systemTemp.createTempSync('editor_savefile_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/out.txt');
    file.writeAsStringSync(written);
    final reread = file.readAsStringSync();
    expect(reread, payload);

    final buffer2 = GtkTextBuffer();
    buffer2.setText(reread, -1);
    final start2 = buffer2.getStartIter();
    final end2 = buffer2.getEndIter();
    expect(buffer2.getText(start2, end2, false), payload);
  });

  test('saveFile flow with hidden-chars flag (true)', () {
    final buffer = GtkTextBuffer();
    buffer.setText('hello world', -1);
    // The third arg toggles whether invisible text is included; passing
    // `true` exercises the second return branch of `getText`. Before
    // the fix, the same anchor was freed before this branch ran.
    final start = buffer.getStartIter();
    final end = buffer.getEndIter();
    expect(buffer.getText(start, end, true), 'hello world');
  });
}
