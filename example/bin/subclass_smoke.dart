// Subclass smoke test: verifies that user code can extend the generated
// classes without the historical "generative constructor expected, but a
// factory was found" error.
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
// What is intentionally still a factory:
//   Constructors with `String`, `String?`, `List<String?>?`, or
//   callback parameters. Forwarding their arguments requires either
//   pre-converting strings (which would leak the C-side buffer) or
//   holding a `NativeCallable` open without a `finally` block to
//   close it. Keeping the factory form for those cases preserves the
//   lifetime invariants the runtime tests assert.
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