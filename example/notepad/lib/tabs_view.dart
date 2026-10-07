import 'package:adw/adw.dart';
import 'package:gtk4/gtk4.dart';
import 'package:notepad/tab_page.dart';
import 'package:path/path.dart' as path;

class TabsView extends AdwTabView {
  final _tabs = <GtkWidget>[];

  bool get isEmpty => _tabs.isEmpty;

  TabPage createTab({String? title}) {
    print("New tab created");
    final tabContent = TabPage();

    final tabPage = append(tabContent);
    _tabs.add(tabContent);
    tabPage.setTitle(title ?? 'New Tab ${_tabs.length + 1}');

    // Select the new tab
    setSelectedPage(tabPage);

    // Return the *original* `TabPage` so callers (e.g. `loadFile`)
    // can use the same Dart instance the constructor ran on.
    // Re-wrapping via `page.getChild().cast<TabPage>(TabPage.
    // fromPointer)` would hand back a fresh wrapper that has the
    // same `handle` but never went through the user-defined
    // constructor — any `late final` fields (e.g. `buffer`) stay
    // uninitialized, which used to throw inside `loadFile` and
    // silently swallow the async load.
    return tabContent;
  }

  void closeTab() {
    final page = getSelectedPage();
    if (page == null) return;

    final child = page.getChild();
    final tabPage = _tabs.firstWhere(
      (w) => w.handle.address == child.handle.address,
    );
    _tabs.remove(tabPage);

    closePage(page);
  }

  void loadFile(String filepath) {
    final basename = path.basename(filepath);
    final tabPage = createTab(title: basename);
    tabPage.loadFile(filepath);
  }
}
