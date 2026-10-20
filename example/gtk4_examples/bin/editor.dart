import 'dart:io' show File, exit;

import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart' hide init;
import 'package:glib/glib.dart';
import 'package:path/path.dart' as p;

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
      ..setContent(buildContentView())
      ..addCssClass('devel');

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
    try {
      final file = dlg?.openFinish(result); // throws GlibException
      print('File: ${file?.getPath()}');
      if (file != null && file.getPath() != null) {
        loadFile(file.getPath()!);
      }
    } on GlibException catch (e) {
      toastOverlay.addToast(
        AdwToast('Error: ${e.code}:${e.domain} -> ${e.message}'),
      );
    } finally {
      dlg = null;
    }
  }

  void loadFile(String path) {
    final file = File(path);
    final fileContent = file.readAsStringSync();
    textBuffer.setText(fileContent, -1);

    final start = textBuffer.getStartIter();
    textBuffer.placeCursor(start);

    final displayName = p.basename(path);
    appWindow.setTitle(displayName);
    toastOverlay.addToast(AdwToast('Opened $displayName'));
  }

  void saveFile(String path) {
    final file = File(path);
    final text = textBuffer.getText(
      textBuffer.getStartIter(),
      textBuffer.getEndIter(),
      false,
    );
    if (text.isEmpty) {
      toastOverlay.addToast(AdwToast('Nothing to save'));
    }

    var displayName = p.basename(path);
    try {
      file.writeAsStringSync(text);
      toastOverlay.addToast(AdwToast('Saved as “$displayName”'));
    } catch (e) {
      toastOverlay.addToast(AdwToast('Unable to save: $displayName'));
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
    // `saveFinish` returns nullable on GIR builds where the C function
    // declares its return as `nullable="1"` (e.g. the GTK 4.10+ GIR),
    // and non-nullable throwing elsewhere — be defensive so the example
    // compiles regardless of the underlying GIR's nullability choice.
    final dlg = saveDlg;
    final path = dlg?.saveFinish(result).getPath();
    if (path != null) {
      saveFile(path);
    }

    saveDlg = null;
  }
}
