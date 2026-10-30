/// The platform-aware native library names the generator emits.
///
/// The GIR files in scope carry **only** the Linux soname — every
/// namespace says `libgtk-4.so.1`, `libadwaita-1.so.0`,
/// `libglib-2.0.so.0` and nothing else. The other platforms' file names
/// cannot be derived from it: GTK 4 on Windows ships `libgtk-4.dll`,
/// with no version suffix at all, while on macOS the same library is
/// `libgtk-4.0.dylib`.
///
/// So the names are **tabulated** here, one row per native library, and
/// the generator emits the row into the package's `lib/src/lib.dart`.
/// The runtime (`package:gir_ffi`) carries the mechanism — it opens the
/// names and throws an actionable error when none of them is there — but
/// not the data: what a library is called on Windows is a fact about the
/// library, and the generator is where the GIR-derived facts live.
library;

/// The distribution packages that ship one native library.
///
/// The runtime turns this into the install command for the platform the
/// process runs on — `gir_ffi`'s `InstallPackages` is the mirror of this
/// class, and the generator emits it by name.
class InstallPackages {
  const InstallPackages({
    required this.debian,
    required this.fedora,
    required this.homebrew,
    required this.arch,
  });

  /// The Debian/Ubuntu package (`apt install`).
  final String debian;

  /// The Fedora/RHEL package (`dnf install`).
  final String fedora;

  /// The Homebrew formula (`brew install`).
  final String homebrew;

  /// The Arch Linux package (`pacman -S`).
  final String arch;
}

/// One native library, as it is named on the platforms the bindings
/// target.
///
/// The Linux name is the table's key: it is the name the GIR gives, and
/// it is the name the GIR's `shared-library` attribute carries.
class PlatformLibrary {
  const PlatformLibrary({
    required this.windows,
    required this.macOS,
    required this.install,
  });

  /// The Windows file name — `libgtk-4.dll`, `libglib-2.0-0.dll`.
  final List<String> windows;

  /// The macOS file name — `libgtk-4.0.dylib`, `libglib-2.0.0.dylib`.
  final List<String> macOS;

  /// The distribution packages that ship the library.
  final InstallPackages install;
}

/// The table: Linux soname → the other platforms' names.
///
/// Every namespace the generator emits is in here. A library that is
/// not gets a mechanically derived name (see [deriveWindowsName]) and a
/// line in the skip report, so a new namespace degrades into a warning
/// instead of a broken loader.
const Map<String, PlatformLibrary> platformLibraries = {
  'libglib-2.0.so.0': PlatformLibrary(
    windows: ['libglib-2.0-0.dll'],
    macOS: ['libglib-2.0.0.dylib'],
    install: InstallPackages(
      debian: 'libglib2.0-dev',
      fedora: 'glib2-devel',
      homebrew: 'glib',
      arch: 'glib',
    ),
  ),
  'libgobject-2.0.so.0': PlatformLibrary(
    windows: ['libgobject-2.0-0.dll'],
    macOS: ['libgobject-2.0.0.dylib'],
    install: InstallPackages(
      debian: 'libglib2.0-dev',
      fedora: 'glib2-devel',
      homebrew: 'glib',
      arch: 'glib',
    ),
  ),
  'libgio-2.0.so.0': PlatformLibrary(
    windows: ['libgio-2.0-0.dll'],
    macOS: ['libgio-2.0.0.dylib'],
    install: InstallPackages(
      debian: 'libglib2.0-dev',
      fedora: 'glib2-devel',
      homebrew: 'glib',
      arch: 'glib',
    ),
  ),
  'libgdk_pixbuf-2.0.so.0': PlatformLibrary(
    windows: ['libgdk_pixbuf-2.0-0.dll'],
    macOS: ['libgdk_pixbuf-2.0.0.dylib'],
    install: InstallPackages(
      debian: 'libgdk-pixbuf-2.0-dev',
      fedora: 'gdk-pixbuf2-devel',
      homebrew: 'gdk-pixbuf',
      arch: 'gdk-pixbuf2',
    ),
  ),
  'libcairo-gobject.so.2': PlatformLibrary(
    windows: ['libcairo-gobject-2.dll'],
    macOS: ['libcairo-gobject.2.dylib'],
    install: InstallPackages(
      debian: 'libcairo2-dev',
      fedora: 'cairo-gobject-devel',
      homebrew: 'cairo',
      arch: 'cairo',
    ),
  ),
  'libpango-1.0.so.0': PlatformLibrary(
    windows: ['libpango-1.0-0.dll'],
    macOS: ['libpango-1.0.0.dylib'],
    install: InstallPackages(
      debian: 'libpango1.0-dev',
      fedora: 'pango-devel',
      homebrew: 'pango',
      arch: 'pango',
    ),
  ),
  'libgtk-4.so.1': PlatformLibrary(
    // GTK 4 on Windows carries **no** version suffix — this is the row
    // that proves the names cannot be derived from the soname.
    windows: ['libgtk-4.dll'],
    macOS: ['libgtk-4.0.dylib'],
    install: InstallPackages(
      debian: 'libgtk-4-dev',
      fedora: 'gtk4-devel',
      homebrew: 'gtk4',
      arch: 'gtk4',
    ),
  ),
  'libadwaita-1.so.0': PlatformLibrary(
    windows: ['libadwaita-1-0.dll'],
    macOS: ['libadwaita-1.0.dylib'],
    install: InstallPackages(
      debian: 'libadwaita-1-dev',
      fedora: 'libadwaita-devel',
      homebrew: 'libadwaita',
      arch: 'libadwaita',
    ),
  ),
  'libgraphene-1.0.so.0': PlatformLibrary(
    windows: ['libgraphene-1.0-0.dll'],
    macOS: ['libgraphene-1.0.0.dylib'],
    install: InstallPackages(
      debian: 'libgraphene-1.0-dev',
      fedora: 'graphene-devel',
      homebrew: 'graphene',
      arch: 'graphene',
    ),
  ),
  'libgtksourceview-5.so.0': PlatformLibrary(
    windows: ['libgtksourceview-5-0.dll'],
    macOS: ['libgtksourceview-5.0.dylib'],
    install: InstallPackages(
      debian: 'libgtksourceview-5-dev',
      fedora: 'gtksourceview5-devel',
      homebrew: 'gtksourceview5',
      arch: 'gtksourceview5',
    ),
  ),
  'libgirepository-2.0.so.0': PlatformLibrary(
    windows: ['libgirepository-2.0-0.dll'],
    macOS: ['libgirepository-2.0.0.dylib'],
    install: InstallPackages(
      debian: 'libglib2.0-dev',
      fedora: 'glib2-devel',
      homebrew: 'glib',
      arch: 'glib',
    ),
  ),
};

/// The platform names of one namespace.
///
/// The Windows and macOS lists run **parallel** to [linux]: the i-th
/// name is the Windows name of the i-th library, so a namespace that
/// lists two shared libraries gets two names per platform.
class PlatformLibraryNames {
  const PlatformLibraryNames({
    required this.linux,
    required this.windows,
    required this.macOS,
    required this.install,
    required this.derived,
  });

  /// The Linux sonames — the GIR's own `shared-library` list, unchanged.
  final List<String> linux;

  /// The Windows file names, parallel to [linux].
  final List<String> windows;

  /// The macOS file names, parallel to [linux].
  final List<String> macOS;

  /// The distribution packages that ship the namespace's library.
  final InstallPackages install;

  /// The Linux names that are **not** in [platformLibraries] — the ones
  /// whose Windows and macOS names were derived mechanically.
  final List<String> derived;
}

/// The platform names for a namespace's `shared-library` list.
///
/// The Linux names are the GIR's own. The Windows and macOS names come
/// from [platformLibraries]; a library that is not in the table gets a
/// mechanically derived name and lands in [PlatformLibraryNames.derived]
/// — the generator reports those in the skip report so the row can be
/// added.
PlatformLibraryNames resolvePlatformNames(List<String> sharedLibraries) {
  final linux = List<String>.of(sharedLibraries);
  final windows = <String>[];
  final macOS = <String>[];
  final derived = <String>[];
  InstallPackages? install;

  for (final name in linux) {
    final entry = platformLibraries[name];
    if (entry == null) {
      derived.add(name);
      windows.add(deriveWindowsName(name));
      macOS.add(deriveMacOSName(name));
      continue;
    }
    windows.addAll(entry.windows);
    macOS.addAll(entry.macOS);
    install ??= entry.install;
  }

  return PlatformLibraryNames(
    linux: linux,
    windows: windows,
    macOS: macOS,
    install:
        install ??
        (linux.isEmpty
            ? const InstallPackages(
                debian: '',
                fedora: '',
                homebrew: '',
                arch: '',
              )
            : deriveInstallPackages(linux.first)),
    derived: derived,
  );
}

/// The Windows name of a Linux soname: `libfoo-1.0.so.0` →
/// `libfoo-1.0-0.dll`.
///
/// This is the convention the Windows GTK and MSYS2 builds follow for
/// the versioned libraries — but not for all of them: GTK 4 ships
/// `libgtk-4.dll`, with no version suffix. That is why the table
/// exists; this derivation is the fallback for a library nobody
/// tabulated, and it is reported as such.
String deriveWindowsName(String linux) {
  final m = RegExp(r'^(.*)\.so\.(\d+)$').firstMatch(linux);
  if (m == null) return '$linux.dll';
  return '${m.group(1)}-${m.group(2)}.dll';
}

/// The macOS name of a Linux soname: `libfoo-1.0.so.0` →
/// `libfoo-1.0.0.dylib`.
String deriveMacOSName(String linux) {
  final m = RegExp(r'^(.*)\.so\.(\d+)$').firstMatch(linux);
  if (m == null) return linux.replaceAll('.so', '.dylib');
  return '${m.group(1)}.${m.group(2)}.dylib';
}

/// The install packages for a library that is not in the table.
///
/// A best-effort guess from the library's own name: Debian ships the
/// development files as `<name>-dev` and Fedora as `<name>-devel`. The
/// guess is wrong often enough that the generator reports the library
/// in the skip report — the row in [platformLibraries] is the fix.
InstallPackages deriveInstallPackages(String linux) {
  final base = linux.replaceFirst(RegExp(r'\.so(\.\d+)?$'), '');
  return InstallPackages(
    debian: '$base-dev',
    fedora: '$base-devel',
    homebrew: base,
    arch: base,
  );
}
