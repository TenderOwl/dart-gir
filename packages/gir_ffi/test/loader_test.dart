// The native library loader.
//
// The loader is the one place that decides whether a native library is
// there. It used to fall back to the process namespace when it was not,
// which turned a missing library into a *"None of the loaded modules
// contained the requested symbol"* error hundreds of calls later — an
// error that points at the bindings instead of at the system.
//
// These tests pin the two halves of the contract:
//
//   * a library that is there opens, and the handle is the real one;
//   * a library that is not there throws `NativeLibraryNotFound`, and
//     the message names the library, the package, every name that was
//     tried and the command that installs it.
//
// The "library that is there" test uses GLib, which is present on every
// machine that runs the native suites — and it skips itself where it is
// not.

import 'dart:ffi';
import 'dart:io';

import 'package:gir_ffi/gir_ffi.dart';
import 'package:test/test.dart';

/// The install packages of GLib — the same row the generator emits.
const InstallPackages _glibInstall = InstallPackages(
  debian: 'libglib2.0-dev',
  fedora: 'glib2-devel',
  homebrew: 'glib',
  arch: 'glib',
);

/// The file name GLib has on this platform.
String get _glibName {
  if (Platform.isWindows) return 'libglib-2.0-0.dll';
  if (Platform.isMacOS) return 'libglib-2.0.0.dylib';
  return 'libglib-2.0.so.0';
}

/// Whether GLib can be opened on this machine.
bool get _hasGlib {
  try {
    DynamicLibrary.open(_glibName);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// A name that no system has.
const String _missing = 'libgir-ffi-does-not-exist.so.0';

void main() {
  group('openLibrary', () {
    test('opens a library that is present', () {
      final libs = openLibrary(
        package: 'gir_ffi',
        library: 'GLib 2.0',
        linux: const ['libglib-2.0.so.0'],
        windows: const ['libglib-2.0-0.dll'],
        macos: const ['libglib-2.0.0.dylib'],
        install: _glibInstall,
      );

      expect(libs, isNotEmpty);
      // The handle is the real library, not a stand-in: `g_free` is
      // GLib's own export.
      expect(
        libs.first.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'g_free',
        ),
        isNotNull,
      );
    }, skip: _hasGlib ? null : 'GLib is not installed');

    test('opens every name it can', () {
      // A namespace may list more than one shared library — GLib's own
      // namespace lists `libgobject-2.0.so.0` and `libglib-2.0.so.0`.
      // Both are opened, and a symbol may live in either.
      final libs = openLibrary(
        package: 'glib',
        library: 'GLib 2.0',
        linux: const ['libgobject-2.0.so.0', 'libglib-2.0.so.0'],
        windows: const ['libgobject-2.0-0.dll', 'libglib-2.0-0.dll'],
        macos: const ['libgobject-2.0.0.dylib', 'libglib-2.0.0.dylib'],
        install: _glibInstall,
      );

      expect(libs, hasLength(2));
      expect(
        libs.first.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'g_object_unref',
        ),
        isNotNull,
      );
    }, skip: _hasGlib ? null : 'GLib is not installed');

    test('throws NativeLibraryNotFound when no name opens', () {
      expect(
        () => openLibrary(
          package: 'gtk4',
          library: 'Gtk 4.0',
          linux: const [_missing],
          windows: const ['libgir-ffi-does-not-exist.dll'],
          macos: const ['libgir-ffi-does-not-exist.dylib'],
          install: const InstallPackages(
            debian: 'libgtk-4-dev',
            fedora: 'gtk4-devel',
            homebrew: 'gtk4',
            arch: 'gtk4',
          ),
        ),
        throwsA(isA<NativeLibraryNotFound>()),
      );
    });
  });

  group('NativeLibraryNotFound', () {
    late NativeLibraryNotFound error;

    setUp(() {
      try {
        openLibrary(
          package: 'gtk4',
          library: 'Gtk 4.0',
          linux: const [_missing],
          windows: const ['libgir-ffi-does-not-exist.dll'],
          macos: const ['libgir-ffi-does-not-exist.dylib'],
          install: const InstallPackages(
            debian: 'libgtk-4-dev',
            fedora: 'gtk4-devel',
            homebrew: 'gtk4',
            arch: 'gtk4',
          ),
        );
        fail('the loader should have thrown');
      } on NativeLibraryNotFound catch (e) {
        error = e;
      }
    });

    test('names the library and the package', () {
      expect(error.package, 'gtk4');
      expect(error.library, 'Gtk 4.0');
      expect(error.tried, isNotEmpty);
    });

    test('names every name that was tried', () {
      expect(error.tried, contains(_missing));
    });

    test('the message says what to install', () {
      final message = error.toString();
      expect(message, contains('gtk4'));
      expect(message, contains('Gtk 4.0'));
      expect(message, contains(_missing));

      if (Platform.isLinux) {
        // Linux does not name its distribution, so every common package
        // manager is listed.
        expect(message, contains('sudo apt install libgtk-4-dev'));
        expect(message, contains('sudo dnf install gtk4-devel'));
        expect(message, contains('sudo pacman -S gtk4'));
      } else if (Platform.isMacOS) {
        expect(message, contains('brew install gtk4'));
      } else {
        // Windows has no package manager to name — the message points at
        // the PATH instead.
        expect(message.toLowerCase(), contains('path'));
      }
    });
  });

  group('InstallPackages', () {
    test('lists the package managers of the platform', () {
      final commands = _glibInstall.commandsForCurrentPlatform();
      if (Platform.isLinux) {
        expect(commands, hasLength(3));
        expect(commands.first, contains('apt install'));
      } else if (Platform.isMacOS) {
        expect(commands, ['brew install glib']);
      } else {
        expect(commands, isEmpty);
      }
    });
  });
}
