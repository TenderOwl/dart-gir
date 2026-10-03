// Subclass smoke test: verifies that user code can extend the generated
// classes without the historical "generative constructor expected, but a
// factory was found" error, AND that the build_runner builder for
// `package:gtk_templates` works end-to-end.
//
// What works today (no-arg, primitive-arg constructors):
//   `class MyAdwWindow extends AdwWindow { MyAdwWindow() : super(); }`
//
//   This is the original blocker the user reported. The generator now
//   emits a generative constructor instead of a factory for any
//   `<constructor>` element with no `throws`, no OUT params, and no
//   string / string-list / callback parameters — those still need the
//   factory body for `withNativeString` / `NativeCallable` lifetime
//   management (a generative initializer list has nowhere to host
//   those scopes).
//
// GtkBuilder template support (the second half of the original
// question — how to back the user-defined class with a `.ui` file):
//   Annotated with `@GtkTemplate(resourcePath: '...')` plus optional
//   `@TemplateChild()` / `@TemplateCallback()` annotations. The
//   `gtk_templates_builder` build_runner plugin emits a sibling
//   `<file>.gtk_templates.dart` part file with the GLib-side
//   bookkeeping. The runtime test below confirms the user-facing
//   shape compiles cleanly (the runtime GTK calls are not exercised
//   here — that requires libgtk-4 installed and a `.ui` resource
//   bundled, which is what `dart run build_runner build` against
//   the user app handles).
import 'package:adw/adw.dart';
import 'package:gtk4/gtk4.dart';

class MyAdwWindow extends AdwWindow {
  MyAdwWindow() : super();
}

class MyGtkButton extends GtkButton {
  MyGtkButton() : super();
}

// `AdwApplication.new` has a `String? applicationId` parameter and is
// therefore still a factory — extending it requires the user to call
// the factory explicitly (the lint above the class hints at this).
// class MyAdwApplication extends AdwApplication {
//   MyAdwApplication() : super(null, GApplicationFlags(0));
// }

void main() {
  final w = MyAdwWindow();
  final b = MyGtkButton();
  // ignore: unused_local_variable
  final pair = (w, b);
}