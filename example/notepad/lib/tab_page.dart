import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart';
import 'package:gtk_source5/gtk_source5.dart';

class TabPage extends AdwBin {
  late final GtkSourceView textView;
  late final GtkSourceBuffer buffer;
  late final GtkSourceLanguage? language;
  // Hold a strong reference to the loader for the lifetime of the
  // async load. The `loadAsyncCallback` registry holds the callback by
  // id; the loader wrapper must outlive the operation, otherwise the
  // trampoline's per-call slot can hold a stale `loader.handle`.
  late final GtkSourceFileLoader loader;
  static const textViewMargin = 16;

  // Forward `fromPointer` to `AdwBin` so callers can re-wrap a handle
  // they got back from another widget (e.g. `AdwTabPage.getChild()`,
  // which returns `GtkWidget.fromPointer(...)` and can't be cast to
  // `TabPage` because the runtime class is just `GtkWidget`). The
  // parent `AdwBin.fromPointer(handle, {bool owned = false})` accepts
  // a named `owned` parameter; we don't need to pass it — the borrowed
  // world of `cast<T>(factory)` never transfers ownership.
  TabPage.fromPointer(super.handle) : super.fromPointer();

  TabPage() {
    buffer = GtkSourceBuffer();
    textView = GtkSourceView.withBuffer(buffer)
      ..setLeftMargin(textViewMargin)
      ..setRightMargin(textViewMargin)
      ..setTopMargin(textViewMargin)
      ..setBottomMargin(textViewMargin)
      ..setWrapMode(.word)
      ..setAutoIndent(true)
      ..setPixelsAboveLines(4)
      ..setPixelsBelowLines(4)
      ..setPixelsInsideWrap(4);

    // Try to set the language to markdown, fall back to plain text if not found
    final manager = GtkSourceLanguageManager();
    language = manager.getLanguage('markdown');
    if (language != null) {
      buffer.setLanguage(language);
    }

    _buildUI();

    textView.grabFocus();
  }

  void _buildUI() {
    final toolbar = _buildToolbar();
    final scrolled = GtkScrolledWindow()..setChild(textView);
    final toolbarView = AdwToolbarView()
      ..addTopBar(toolbar)
      ..setContent(scrolled);

    setChild(toolbarView);
  }

  GtkWidget _buildToolbar() {
    final toolbar = GtkBox(.horizontal, 0)
      ..addCssClass('toolbar')
      ..setHomogeneous(true);

    // Left box for menu bar
    final leftBox = GtkBox(.horizontal, 0);
    toolbar.append(leftBox);

    // Center box for paragraph and list buttons
    final centerBox = GtkBox(.horizontal, 0);
    toolbar.append(centerBox);

    final paragraphButton = GtkDropDown()
      ..setModel(
        GtkStringList(['Title', 'Subtitle', 'Heading', 'Body', 'Code']),
      );
    centerBox.append(paragraphButton);

    final listButton = GtkDropDown()
      ..setModel(GtkStringList(['Bullet', 'Number', 'Check']));
    centerBox.append(listButton);

    final boldButton = GtkButton.fromIconName('format-text-bold-symbolic');
    centerBox.append(boldButton);

    final italicButton = GtkButton.fromIconName('format-text-italic-symbolic');
    centerBox.append(italicButton);

    final linkButton = GtkButton.fromIconName('insert-link-symbolic');
    centerBox.append(linkButton);

    toolbar.append(centerBox);

    // Right box for actions
    final rightBox = GtkBox(.horizontal, 0);
    toolbar.append(rightBox);

    return toolbar;
  }

  void loadFile(String filepath) {
    final gfile = GFile.newForPath(filepath);
    final file = GtkSourceFile()..setLocation(gfile);
    loader = GtkSourceFileLoader(buffer, file);

    // The lifetime-safe overload routes the dispatcher through a
    // permanent trampoline + per-call registry (see
    // `gtksourcefileloader.dart`'s `_loadAsyncCallbackPtr`), so the
    // loader wrapper must outlive the operation — held in the `loader`
    // field above.
    loader.loadAsyncCallback(200, null, null, null, null, onLoadComplete);
  }

  void onLoadComplete(GObject? source, GAsyncResult result) {
    try {
      loader.loadFinish(result);
    } catch (e) {
      activateActionVariant(
        'app.show-toast',
        GVariant.string('Failed to load file.'),
      );
    }
  }
}
