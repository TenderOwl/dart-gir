import 'dart:convert';

import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'notepad_window.g.dart';

@GtkTemplate(source: GtkTemplateFile('data/notepad_window.ui'))
class NotepadWindow extends AdwApplicationWindow with _$NotepadWindowTemplate {
  NotepadWindow(super.app) {
    initTemplate();

    final openAction = GSimpleAction('open');
    openAction.onActivate(openFileDialog);
    addAction(openAction);

    final buffer = mainTextView.getBuffer();
    buffer.onNotify((params) {
      if (params.getName() == "cursor-position") {
        updateCursorPosition(buffer);
      }
    });
  }

  void openFileDialog(GVariant? params) {
    final native = GtkFileDialog();
    native.openCallback(this, null, onOpenResponse);
  }

  void onOpenResponse(GObject? source, GAsyncResult result) {
    final dialog = source?.cast<GtkFileDialog>(GtkFileDialog.fromPointer);

    final file = dialog?.openFinish(result);
    if (file == null) return;

    openFile(file);
  }

  /// Loads [file] and shows its text.
  void openFile(GFile file) {
    file.loadContentsAsyncCallback(null, openFileComplete);
  }

  void openFileComplete(GObject? source, GAsyncResult result) {
    if (source == null) return;
    final file = source.cast<GFile>(GFile.fromPointer);

    final info = file.queryInfo("standard::display-name", .none);
    final displayName = info.getAttributeString("standard::display-name");

    final path = file.peekPath();
    final (ok, contents, etag) = file.loadContentsFinish(result);
    if (!ok) {
      print("Unable to open $path: ${contents[1]}");
    }

    String text;

    try {
      text = utf8.decode(contents);
    } catch (error) {
      print(
        'Unable to load the contents of $path: the file is not encoded with UTF-8',
      );
      return;
    }

    final buffer = mainTextView.getBuffer();
    buffer.setText(text, -1);
    final start = buffer.getStartIter();
    buffer.placeCursor(start);

    setTitle(displayName);
  }

  void updateCursorPosition(GtkTextBuffer buffer) {
    final insertMark = buffer.getInsert();
    final iter = buffer.getIterAtMark(insertMark);
    final line = iter.getLine() + 1;
    final column = iter.getLineOffset() + 1;
    cursorPos.setLabel('Ln $line, Col $column');
  }
}
