## Unreleased

### Removed
- The dead "Keyboard Shortcuts" menu entry. It pointed at the
  `win.show-help-overlay` action, which GTK only creates when the
  application ships a `gtk/help-overlay.ui` resource — the notepad ships
  none, so the action never existed and the entry did nothing.

## 1.0.0

- Initial version.
