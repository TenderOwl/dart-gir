// End-to-end test for the caller-allocated OUT parameter pipeline.
//
// Reproducer for the SEGV seen when `textBuffer.getStartIter()` was
// followed by another call that dereferences the returned iter. The
// `getStartIter` wrapper allocates a `HeapAnchor`-backed 256-byte
// buffer (lifetime tied to the returned `GtkTextIter` via Dart's
// `NativeFinalizer`), GTK fills it via `*iter = ...`, and the wrapper
// exposes the buffer as the iter's `handle`. Subsequent reads through
// that handle stay valid as long as the user holds the `GtkTextIter`.
//
// We avoid a full GTK app setup by constructing a `GtkTextBuffer`
// directly, setting its text, and exercising the start/end/getText
// trio. This is the smallest reproducer of the SEGV that previously
// fired in `example/bin/editor.dart`'s `saveFile` path.

import 'package:gtk4/gtk4.dart';
import 'package:test/test.dart';

void main() {
  test('GtkTextBuffer.getStartIter → getText survives', () {
    final buffer = GtkTextBuffer();
    buffer.setText('hello\nworld\n', -1);

    final start = buffer.getStartIter();
    final end = buffer.getEndIter();
    final text = buffer.getText(start, end, false);
    expect(text, 'hello\nworld\n');
  });

  test('GtkTextBuffer.getBounds returns matching start/end iters', () {
    final buffer = GtkTextBuffer();
    buffer.setText('abc', -1);
    final (start, end) = buffer.getBounds();
    expect(start.getOffset(), 0);
    expect(end.getOffset(), 3);
    expect(buffer.getText(start, end, false), 'abc');
  });

  test('GtkTextBuffer.getSlice matches getText', () {
    final buffer = GtkTextBuffer();
    buffer.setText('hello\nworld\n', -1);
    final start = buffer.getStartIter();
    final end = buffer.getEndIter();
    expect(buffer.getSlice(start, end, false), 'hello\nworld\n');
  });
}
