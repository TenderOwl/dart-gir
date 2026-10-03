// A minimal `AdwApplicationWindow` subclass driven by a
// `GtkBuilder` template loaded from `/com/tenderowl/Todo/window.ui`.
//
// The composite-widget setup is glued together by code emitted by the
// `gtk_templates_builder` builder (see
// `lib/todo_window.gtk_templates.dart`):
//
//   * `bindTodoWindowTemplate()` — installs the template on
//     `AdwApplicationWindow`'s WidgetClass via
//     `gtk_widget_class_set_template_from_resource`, wires every
//     `@TemplateCallback` trampoline via
//     `gtk_widget_class_bind_template_callback_full`, and caches
//     the parent GType. Must be called BEFORE the first `TodoWindow`
//     instance is constructed (typically from `app.dart`'s
//     `onActivate()`).
//   * `_getChild_<field>(self, name)` — per-`@TemplateChild`
//     helpers that look up the named child from the loaded
//     template and wrap it in the field's Dart type via
//     `T.fromPointer`. The gtype comes from a `late int parentGtype`
//     cache in the part file.
//
// The user's main source file does NOT import `package:gir_ffi` —
// all FFI plumbing is encapsulated inside the part file (which
// re-exports the `gir_ffi` primitives through
// `package:gtk_templates`'s `template_lookup.dart`).
//
// FUTURE: registering `TodoWindow` as its own GType via
// `g_type_register_static_simple` (so the `.ui`'s
// `<template class="TodoWindow"/>` declaration matches the runtime
// type instead of being installed on the parent class) is tracked
// separately. The current flow installs the template on the parent
// class — every `AdwApplicationWindow` instance in the process
// picks it up, which is fine for a single-window example but
// doesn't isolate the template to this class. See the design notes
// in `CHANGELOG.md`.

import 'dart:ffi' as ffi;

import 'package:adw/adw.dart';
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'todo_window.gtk_templates.dart';

@GtkTemplate(resourcePath: '/com/tenderowl/Todo/window.ui')
class TodoWindow extends AdwApplicationWindow {
  TodoWindow(AdwApplication app) : super(app) {
    // `bindTodoWindowTemplate()` was already called from
    // `app.dart`'s `onActivate()` before this constructor runs.
    // Materialise the template into this instance: instantiate
    // each named child and wire the `<signal handler="..."/>`
    // entries to the @TemplateCallback trampolines (already
    // installed by bindTodoWindowTemplate()).
    initTemplate();

    // Per-`@TemplateChild` fields. The gtype is cached in the
    // part file's `parentGtype` variable, so we don't pass it.
    titleLabel = _getChild_titleLabel(this, 'title_label');
    listBox = _getChild_listBox(this, 'list_box');
  }

  /// Welcome heading shown in the status page's title slot.
  @TemplateChild()
  late GtkLabel? titleLabel;

  /// Container the user populates with task rows.
  @TemplateChild()
  late GtkListBox? listBox;

  /// Wired by the builder to `<signal name="clicked"
  /// handler="on_add_clicked"/>` in the `.ui`. The `name:`
  /// argument matches the `.ui`'s `handler="on_add_clicked"`
  /// attribute verbatim — the example uses an explicit name rather
  /// than letting the builder default from the method name, to
  /// show both patterns.
  ///
  /// Static so the generated `isolateLocal` closure can call it
  /// without capturing `this` — Dart's `NativeCallable.isolateLocal`
  /// requires a top-level function reference for the C-side pointer
  /// to remain valid across constructor invocations.
  ///
  /// The signature is `void()` rather than `void(GtkButton)`
  /// because `bind_template_callback_full` wires the trampoline as
  /// a `GCallback`, and GTK invokes it with the bound user data —
  /// not the signal args. A real implementation would either keep
  /// its own reference to the source widget (assigned in
  /// `initTemplate()`) or use `g_signal_connect` for
  /// parameter-bearing signals.
  @TemplateCallback('on_add_clicked')
  static void onAddClicked() {
    print('TodoWindow: add button clicked');
  }
}