import 'package:adw/adw.dart';
import 'package:gtk4/gtk4.dart';

class TabsView extends AdwTabView {
  final _tabs = <AdwTabPage>[];

  void newTab() {
    print("New tab created");
    final tab = GtkBox(.vertical, 12)
      ..append(GtkLabel('New Tab ${_tabs.length + 1}'));

    append(tab);
  }
}
