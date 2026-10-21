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

    final openAction = GSimpleAction('open')..onActivate(openFileDialog);
    addAction(openAction);

    final saveAction = GSimpleAction('save-as')..onActivate(saveFileDialog);
    addAction(saveAction);

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

    final (ok, contents, etag) = file.loadContentsFinish(result);
    if (!ok) {
      toastOverlay.addToast(AdwToast("Unable to open “$displayName”"));
    }

    String text;

    try {
      text = utf8.decode(contents);
    } catch (error) {
      toastOverlay.addToast(
        AdwToast('Invalid text encoding for “$displayName”'),
      );
      return;
    }

    final buffer = mainTextView.getBuffer();
    buffer.setText(text, -1);
    final start = buffer.getStartIter();
    buffer.placeCursor(start);

    setTitle(displayName);
    toastOverlay.addToast(AdwToast('Opened “$displayName”'));
  }

  void updateCursorPosition(GtkTextBuffer buffer) {
    final insertMark = buffer.getInsert();
    final iter = buffer.getIterAtMark(insertMark);
    final line = iter.getLine() + 1;
    final column = iter.getLineOffset() + 1;
    cursorPos.setLabel('Ln $line, Col $column');
  }

  void saveFileDialog(GVariant? parameter) {
    final native = GtkFileDialog();
    native.saveCallback(this, null, onSaveResponse);
  }

  void onSaveResponse(GObject? source, GAsyncResult result) {
    final dialog = source?.cast<GtkFileDialog>(GtkFileDialog.fromPointer);
    final file = dialog?.saveFinish(result);
    if (file != null) {
      saveFile(file);
    }
  }

  void saveFile(GFile file) {
    final buffer = mainTextView.getBuffer();

    // Retrieve the iterator at the start of the buffer
    final start = buffer.getStartIter();
    // Retrieve the iterator at the end of the buffer
    final end = buffer.getEndIter();
    // Retrieve all the visible text between the two bounds
    final text = buffer.getText(start, end, false);

    // If there is nothing to save, return early
    if (text.isEmpty) return;

    final bytes = GBytes(utf8.encode(text));
    file.replaceContentsBytesAsyncCallback(
      bytes,
      null,
      false,
      .none,
      null,
      saveFileComplete,
    );
  }

  void saveFileComplete(GObject? source, GAsyncResult result) {
    final file = source?.cast<GFile>(GFile.fromPointer);
    final res = file?.replaceContentsFinish(result);
    final info = file?.queryInfo('standard::display-name', .none);

    String? displayName;
    if (info != null) {
      displayName = info.getAttributeString("standard::display-name");
    } else {
      displayName = file?.getBasename();
    }

    String msg;
    if (res == null) {
      msg = 'Unable to save as $displayName';
    } else {
      msg = 'Saved as “$displayName”';
    }
    toastOverlay.addToast(AdwToast(msg));
  }
}
