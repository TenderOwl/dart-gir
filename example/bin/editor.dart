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

class EditorApp {
  late AdwApplication app;
  late AdwApplicationWindow appWindow;
  late AdwToastOverlay toastOverlay;
  late GtkTextView textView;
  late GtkTextBuffer textBuffer;

  GtkFileDialog? dlg;

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
    appWindow.present();
  }

  GtkWidget buildContentView() {
    toastOverlay = AdwToastOverlay();
    final header = AdwHeaderBar();
    final openButton = GtkButton.fromIconName('folder-open-symbolic')
      ..setTooltipText('Open File')
      ..onClicked(() {
        dlg = GtkFileDialog();
        dlg!.openCallback(appWindow, null, onFileDialogClosed);
      });
    header.packStart(openButton);

    final saveButton = GtkButton.fromIconName('document-save-symbolic')
      ..setTooltipText('Save File')
      ..onClicked(() {
        final filePath = appWindow.getTitle();
        if (filePath != 'Editor') {
          saveFile(filePath!);
        }
      });
    header.packStart(saveButton);

    // Initialize text buffer and view
    textBuffer = GtkTextBuffer();
    textView = GtkTextView()
      ..setBuffer(textBuffer)
      ..setLeftMargin(12)
      ..setRightMargin(12)
      ..setTopMargin(12)
      ..setBottomMargin(12);

    final scrollView = GtkScrolledWindow()
      ..setVexpand(true)
      ..setChild(textView);

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
        appWindow.setTitle(file.getPath()!);
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
    // final start = textBuffer.getStartIter();
    // final end = textBuffer.getEndIter();
    // print('  start.offset=${start.getOffset()} end.offset=${end.getOffset()}');
  }

  void saveFile(String path) {
    final file = File(path);
    file.writeAsStringSync(
      textBuffer.getText(
        textBuffer.getStartIter(),
        textBuffer.getEndIter(),
        false,
      ),
    );

    toastOverlay.addToast(AdwToast('Saved to $path'));
  }
}
