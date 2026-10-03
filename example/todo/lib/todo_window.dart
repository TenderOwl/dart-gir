// Composite widget example: `TodoWindow` extends `AdwApplicationWindow`
// and is backed by a GtkBuilder `.ui` template, wired together by
// `package:gtk_templates` + the `gtk_templates_builder` build_runner
// plugin.
//
// To regenerate the part file after editing this file's annotations:
//   cd example/todo && dart run build_runner build
//
// The user-facing shape mirrors PyGObject's `@Gtk.Template` /
// `Gtk.Template.Child` / `Gtk.Template.Callback`:
//   * `@GtkTemplate(resourcePath: ...)` marks the class as a composite
//     widget; the builder generates a `_<class>BindTemplate()` that
//     does the one-shot `g_type_register_static`,
//     `gtk_widget_class_set_template_from_resource`, and
//     `bind_template_callback_full` plumbing.
//   * `@TemplateChild()` (optionally with `name:`) declares a `late`
//     field that the builder populates from the loaded template via
//     `gtk_widget_get_template_child`.
//   * `@TemplateCallback(name: '...')` declares a method that the
//     builder wires to the named signal handler in the `.ui`. The
//     method name is snake_cased by default, matching the `.ui`'s
//     `handler="..."` attribute.

import 'dart:ffi' as ffi;

import 'package:adw/adw.dart';
import 'package:gir_ffi/gir_ffi.dart'
    show
        adwApplicationWindowGetType,
        gTypeClassRef,
        gTypeCheckClassCast,
        gTypeClassUnref,
        gtkWidgetClassBindTemplateCallbackFull;
import 'package:gtk4/gtk4.dart';
import 'package:gtk_templates/gtk_templates.dart';

part 'todo_window.gtk_templates.dart';

/// One-shot template installer. Called by `TodoApp.onActivate()`
/// BEFORE the first `TodoWindow` is constructed — the template must
/// be set on the GtkApplicationWindow widget class before any
/// instance exists, otherwise `gtk_widget_init_template` aborts.
///
/// The generator writes the trampolines + per-field helpers into
/// the part file (`todo_window.gtk_templates.dart`); this top-level
/// function lives here so it can be invoked from `app.dart`, which
/// can't `import` a `part of` file. The public name is `installTemplate`
/// (not `_$TodoWindowBindTemplate`) because Dart's library privacy
/// rules would hide an underscore-prefixed top-level function from
/// `app.dart`.
void installTodoWindowTemplate() {
  // Install the widget template on the parent class directly. The
  // generator-emitted `g_type_register_static` flow requires the
  // full GTypeInfo struct, which our binding can't model — the
  // simpler path is to install the template on
  // `AdwApplicationWindow`'s WidgetClass (the actual GObject class
  // of an `AdwApplicationWindow.new` instance). `initTemplate()`
  // reads the template from the immediate WidgetClass without
  // walking the parent chain, so the template has to live on the
  // class the instance is actually constructed from.
  //
  // Side effect: all `AdwApplicationWindow` instances in the process
  // pick up the same template. For a single composite widget per
  // process (the example case) this is fine; a v2 builder could
  // register a distinct GType once we model GTypeInfo properly.
  final parentType = adwApplicationWindowGetType();
  final classPtr = gTypeClassRef(parentType);
  final widgetClass = GtkWidgetClass.fromPointer(
    gTypeCheckClassCast(classPtr, parentType),
  );
  widgetClass.setTemplateFromResource('/com/tenderowl/Todo/window.ui');

  // Bind every @TemplateCallback-annotated method by name.
  // The trampolines are pinned in a process-global registry so
  // they outlive every instance.
  //
  // We use `gtkWidgetClassBindTemplateCallbackFull` from
  // `package:gir_ffi` rather than the generator-emitted
  // `widgetClass.bindTemplateCallbackFull` wrapper because the
  // generated one closes the NativeCallable in a `finally`
  // block, which kills the trampoline before GTK has wired
  // the signal connection.
  registerTemplateCallback(
    parentType,
    'on_add_clicked',
    _$TodoWindow_onAddClicked,
  );
  gtkWidgetClassBindTemplateCallbackFull(
    widgetClass.handle,
    'on_add_clicked',
    _$TodoWindow_onAddClicked.nativeFunction.cast(),
  );
  gTypeClassUnref(classPtr);
}

@GtkTemplate(resourcePath: '/com/tenderowl/Todo/window.ui')
class TodoWindow extends AdwApplicationWindow {
  TodoWindow(AdwApplication app) : super(app) {
    // NOTE: `_$TodoWindowBindTemplate()` is invoked from
    // `app.dart`'s `onActivate()` BEFORE this constructor runs.
    // The template must be installed on GtkApplicationWindow's
    // WidgetClass before any instance exists; doing it in a
    // super-initializer wouldn't work because `super(app)` creates
    // an instance synchronously.
    //
    // Load the template XML into this instance. After
    // `_$TodoWindowBindTemplate()` has run, the parent class has a
    // template installed; `initTemplate()` instantiates each named
    // child and wires the `<signal handler="on_add_clicked"/>` to
    // the @TemplateCallback trampoline.
    initTemplate();

    // Wire the @TemplateChild fields via the generated per-field
    // helpers. The dispatch goes through `getTemplateChild` (a
    // runtime helper in `package:gtk_templates`) which fetches the
    // named child from the loaded template and wraps it in the
    // declared Dart type via the constructor passed by the emitter.
    // The gtype is the C-level parent (AdwApplicationWindow), not
    // the GIR supertype.
    //
    // The lookups are tolerant of `null` so the example can show
    // the window even when the per-child plumbing misbehaves
    // (the generator-emitted `getTemplateChild` returns `null`
    // when the named child can't be resolved — and on Fedora 44
    // with our libgtk-4 build the FFI call asserts internally
    // before returning, surfacing as a `Gtk-CRITICAL` warning but
    // the program keeps running). For a production composite
    // widget you'd want `late GtkLabel titleLabel` (non-null) and
    // let any failed lookup throw a `LateInitializationError` so
    // the bug is caught at startup.
    final gtype = adwApplicationWindowGetType();
    // The `_getChild_<field>` helpers (emitted into
    // `todo_window.gtk_templates.dart` by `gtk_templates_builder`)
    // return `T?` so we can null-check on a missing child. A null
    // here means the named child wasn't materialised in the loaded
    // template — usually because the `<template class=...>` in the
    // `.ui` doesn't match the GType we passed to
    // `gtk_widget_class_set_template_from_resource`. In a production
    // composite widget you'd flip the fields to `late T` (non-null)
    // so any failed lookup throws at startup.
    titleLabel = _getChild_titleLabel(this, gtype, 'title_label');
    listBox = _getChild_listBox(this, gtype, 'list_box');
  }

  /// Welcome heading shown in the status page's title slot.
  @TemplateChild()
  late GtkLabel? titleLabel;

  /// Container the user populates with task rows.
  @TemplateChild()
  late GtkListBox? listBox;

  /// Wired by the builder to `<signal name="clicked" handler="on_add_clicked"/>`
  /// in the `.ui`. The `name:` argument matches the `.ui`'s
  /// `handler="on_add_clicked"` attribute verbatim — the example uses
  /// an explicit name rather than letting the builder default from
  /// the method name, to show both patterns.
  ///
  /// Static so the generated `isolateLocal` closure can call it
  /// without capturing `this` — Dart's `NativeCallable.isolateLocal`
  /// requires a top-level function reference for the C-side pointer
  /// to remain valid across constructor invocations.
  ///
  /// The signature is `void()` rather than `void(GtkButton)` because
  /// `bind_template_callback_full` wires the trampoline as a
  /// `GCallback` and GTK invokes it with bound user data, not the
  /// signal args. A real implementation would either keep its own
  /// reference to the source widget (assigned in `initTemplate()`)
  /// or use `g_signal_connect` for parameter-bearing signals.
  @TemplateCallback('on_add_clicked')
  static void onAddClicked() {
    // ignore: avoid_print
    print('TodoWindow: add button clicked');
  }
}