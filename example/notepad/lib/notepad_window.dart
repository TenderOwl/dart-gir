import 'package:adw/adw.dart';
import 'package:gio/gio.dart';
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
  late final GtkMenuButton menuButton;
  late final AdwHeaderBar headerBar;
  late final AdwToolbarView toolbarView;
  late final GMenu menuModel;

  NotepadWindow(super.app) {
    setDefaultSize(800, 600);
    setTitle("Notepad");

    _buildUI();
  }

  void _buildUI() {
    tabsView = TabsView();
    tabsBar = AdwTabBar()..setView(tabsView);

    newButton = GtkButton()
      ..setIconName("list-add-symbolic")
      ..setTooltipText("Add new tab")
      ..onClicked(() => tabsView.newTab());

    menuModel = _buildMenu();
    menuButton = GtkMenuButton()
      ..setTooltipText("Main Menu")
      ..setIconName("open-menu-symbolic")
      ..setMenuModel(menuModel);

    headerBar = AdwHeaderBar()
      ..packStart(newButton)
      ..packEnd(menuButton);

    toolbarView = AdwToolbarView()
      ..addTopBar(headerBar)
      ..addTopBar(tabsBar)
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
}
