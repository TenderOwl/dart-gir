import 'dart:io' show File, exit;

import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart' hide init;
import 'package:glib/glib.dart';

void main(List<String> args) {
  init();

  final app = EditorApp('com.tenderowl.editor');
  app.run(args);
}

/// Implements a simple text editor using GTK4 and Adwaita.
/// https://developer.gnome.org/documentation/tutorials/beginners/getting_started.html
class EditorApp {
  late AdwApplication app;
  late AdwApplicationWindow appWindow;
  late AdwToastOverlay toastOverlay;
  late GtkTextView mainTextView;
  late GtkTextBuffer textBuffer;
  late GtkLabel cursorPos;

  GtkFileDialog? dlg;
  GtkFileDialog? saveDlg;

  EditorApp(String applicationId) {
    app = AdwApplication(applicationId, .handlesOpen);

    // Connect the 'activate' signal to the `onActivate` callback.
    app.onActivate(onActivate);

    // Connect the 'shutdown' signal to quit the application properly.
    app.onShutdown(onQuit);
    app.setAccelsForAction('window.close', ['<Primary>w']);
  }

  void run(List<String> args) {
    app.run(args.length, args);
  }

  void onQuit() {
    app.quit();
    exit(0);
  }

  void onActivate() {
    appWindow = AdwApplicationWindow(app)
      ..setDefaultSize(800, 600)
      ..setTitle('Editor')
      ..setContent(buildContentView());

    setupActions();

    appWindow.present();
  }

  void setupActions() {
    final openAction = GSimpleAction('open', null)
      ..onActivate((_) {
        dlg = GtkFileDialog();
        dlg!.openCallback(appWindow, null, onFileDialogClosed);
      });
    appWindow.addAction(GAction.fromPointer(openAction.handle));
    app.setAccelsForAction('win.open', ['<Primary>o']);

    final saveAction = GSimpleAction('save-as', null)
      ..onActivate((_) {
        saveFileDialog();
      });
    appWindow.addAction(GAction.fromPointer(saveAction.handle));
    app.setAccelsForAction('win.save-as', ['<Primary><Shift>s']);
  }

  GtkWidget buildContentView() {
    toastOverlay = AdwToastOverlay();
    final header = AdwHeaderBar();
    final openButton = GtkButton.withLabel('Open')
      ..setTooltipText('Open File')
      ..setActionName('win.open');
    header.packStart(openButton);

    final saveButton = GtkButton.fromIconName('document-save-as-symbolic')
      ..setTooltipText('Save as..')
      ..setActionName('win.save-as');
    header.packStart(saveButton);

    cursorPos = GtkLabel('Ln 0, Col 0')
      ..addCssClass('dim-label')
      ..addCssClass('numeric');
    header.packEnd(cursorPos);

    // Initialize text buffer and view
    textBuffer = GtkTextBuffer();
    textBuffer.onNotify((pspec) {
      if (pspec.getName() == 'cursor-position') {
        updateCursorPos();
      }
    });
    mainTextView = GtkTextView()
      ..setBuffer(textBuffer)
      ..setMonospace(true);

    final scrollView = GtkScrolledWindow()
      ..setHexpand(true)
      ..setVexpand(true)
      ..setMarginStart(6)
      ..setMarginEnd(6)
      ..setMarginTop(6)
      ..setMarginBottom(6)
      ..setChild(mainTextView);

    final contentBox = GtkBox(.vertical, 0)..append(scrollView);

    final toolbarView = AdwToolbarView()
      ..addTopBar(header)
      ..setContent(contentBox);

    toastOverlay.setChild(toolbarView);
    return toastOverlay;
  }

  void onFileDialogClosed(GObject? sourceObject, GAsyncResult result) {
    // final dlg = sourceObject as GtkFileDialog;
    print('File dialog closed');
    try {
      final file = dlg?.openFinish(result); // throws GlibException
      print('File: ${file?.getPath()}');
      if (file != null && file.getPath() != null) {
        readFile(file.getPath()!);
        appWindow.setTitle(file.getBasename()!);
      }
    } on GlibException catch (e) {
      // Includes the GTK_DIALOG_ERROR_DISMISSED case when the user
      // cancels.
      print('Error: ${e.toString()}');
      toastOverlay.addToast(AdwToast('Error: ${e.toString()}'));
    } finally {
      dlg = null;
    }
  }

  void readFile(String path) {
    final file = File(path);
    final fileContent = file.readAsStringSync();
    textBuffer.setText(fileContent, -1);
    // Round-trip through the iter API to demonstrate that the
    // caller-allocates OUT parameters are now generated as returning
    // a typed `GtkTextIter` (the wrapper allocates internally, calls
    // the C function, and reads back via `fromPointer`).
    final start = textBuffer.getStartIter();
    final end = textBuffer.getEndIter();
    print('  start.offset=${start.getOffset()} end.offset=${end.getOffset()}');

    textBuffer.placeCursor(start);
  }

  void saveFile(String path) {
    final file = File(path);
    final text = textBuffer.getText(
      textBuffer.getStartIter(),
      textBuffer.getEndIter(),
      false,
    );
    if (text.isNotEmpty) {
      file.writeAsStringSync(text);
      toastOverlay.addToast(AdwToast('Saved to $path'));
    } else {
      toastOverlay.addToast(AdwToast('Nothing to save'));
    }
  }

  void updateCursorPos() {
    final cursorPos = textBuffer.getInsert();
    final iter = textBuffer.getIterAtMark(cursorPos);
    this.cursorPos.setText(
      'Ln ${iter.getLine() + 1}, Col ${iter.getLineOffset() + 1}',
    );
  }

  void saveFileDialog() {
    saveDlg = GtkFileDialog();
    saveDlg!.saveCallback(appWindow, null, onSaveResponse);
  }

  void onSaveResponse(GObject? sourceObject, GAsyncResult result) {
    final path = saveDlg!.saveFinish(result).getPath();
    if (path != null) {
      saveFile(path);
    }

    saveDlg = null;
  }
}
