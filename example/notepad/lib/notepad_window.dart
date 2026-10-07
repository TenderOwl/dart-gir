import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
import 'package:glib/glib.dart';
import 'package:gobject/gobject.dart';
import 'package:gtk4/gtk4.dart';
import 'package:notepad/tabs_view.dart';

class NotepadWindow extends AdwApplicationWindow {
  late final AdwToastOverlay toastOverlay;
  late TabsView tabsView;
  // Hold strong references to widgets the user wires into the live widget
  // tree. Local variables would go out of scope when `_buildUI()` returns,
  // and the Dart GC would fire the wrapper's finalizer (`g_object_unref`)
  // while the widget is still parented — GTK raises
  // "GtkButton has a parent … during dispose" and segfaults inside
  // `gtk_accessible_update_state` from the unrealize path. Every widget
  // that lives as long as the window must be held in a field so the
  // wrapper stays alive until the parent unrefs it during shutdown.
  late final AdwTabBar tabsBar;
  late final GtkButton newButton;
  late final GtkButton openButton;
  late final GtkMenuButton menuButton;
  late final AdwHeaderBar headerBar;
  late final AdwToolbarView toolbarView;
  late final GMenu menuModel;

  GtkFileDialog? openDialog;

  NotepadWindow(super.app) {
    setDefaultSize(800, 600);
    setTitle("Notepad");

    _buildUI();
    _setupActions();

    if (tabsView.isEmpty) {
      tabsView.createTab();
    }
  }

  void _buildUI() {
    tabsView = TabsView();
    tabsBar = AdwTabBar()
      ..setView(tabsView)
      ..setAutohide(false)
      ..setExpandTabs(false);

    newButton = GtkButton()
      ..setIconName("list-add-symbolic")
      ..setTooltipText("Add new tab")
      ..setValign(.center)
      ..onClicked(() => tabsView.createTab());

    openButton = GtkButton()
      ..setIconName("document-open-symbolic")
      ..setTooltipText("Open file")
      ..setValign(.center)
      ..onClicked(onOpenFile);

    menuModel = _buildMenu();
    menuButton = GtkMenuButton()
      ..setTooltipText("Main Menu")
      ..setIconName("open-menu-symbolic")
      ..setValign(.center)
      ..setMenuModel(menuModel);

    headerBar = AdwHeaderBar()
      ..packStart(newButton)
      ..packStart(openButton)
      ..setTitleWidget(tabsBar)
      ..packEnd(menuButton);

    toolbarView = AdwToolbarView()
      ..addTopBar(headerBar)
      // ..addTopBar(tabsBar)
      ..setContent(tabsView);

    toastOverlay = AdwToastOverlay()..setChild(toolbarView);
    setContent(toastOverlay);
  }

  GMenu _buildMenu() {
    final GMenu menuModel = GMenu();
    menuModel.appendItem(GMenuItem("Preferences", "app.preferences"));
    menuModel.appendItem(GMenuItem("About", "app.about"));

    final quitSubmenu = GMenu();
    quitSubmenu.appendItem(GMenuItem("Quit", "app.quit"));
    menuModel.appendSection(null, quitSubmenu);

    return menuModel;
  }

  void _setupActions() {
    final createTab = GSimpleAction("tab.create")
      ..onActivate((_) => tabsView.createTab());
    addAction(createTab);

    final closeTab = GSimpleAction("tab.close")
      ..onActivate((_) {
        tabsView.closeTab();
      });
    addAction(closeTab);

    final app = super.getApplication();
    if (app != null) {
      app.setAccelsForAction("win.tab.create", ["<Primary>n"]);
      app.setAccelsForAction("win.tab.close", ["<Primary>w"]);
    }
  }

  void onOpenFile() {
    openDialog = GtkFileDialog()
      ..setDefaultFilter(
        GtkFileFilter()
          ..addMimeTypes(["text/plain", "text/markdown", "text/css"]),
      )
      ..setTitle("Open File")
      ..setInitialFolder(GFile.newForPath(getHomeDir()))
      ..setAcceptLabel("Open");

    openDialog!.openMultipleCallback(this, null, onOpenMultiple);
  }

  void onOpenMultiple(GObject? source, GAsyncResult result) {
    final dialog = openDialog;
    if (dialog == null) return;
    final files = dialog.openMultipleFinish(result);

    for (int i = 0; i < files.getNItems(); i++) {
      final item = files.getObject(i);
      if (item == null) continue;

      final file = item.cast<GFile>(GFile.fromPointer);
      final path = file.getPath();
      // TODO: Send inapp notification if path is null
      if (path == null) continue;

      tabsView.loadFile(path);
    }

    openDialog = null;
  }

  void showToast(String title) {
    toastOverlay.addToast(AdwToast(title));
  }
}
