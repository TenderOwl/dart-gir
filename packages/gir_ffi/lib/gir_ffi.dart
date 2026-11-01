import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Directory, File, FileLock, FileMode, Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Runs [body] while holding the process-wide initialisation lock.
///
/// GTK's initialisation is **not thread-safe**: `gtk_init()` opens the
/// display, builds the settings and loads the theme's CSS, and none of
/// that is guarded. Two isolates that call it at the same time leave the
/// display half-initialised — the second one walks into the CSS
/// provider while the first one is still loading it, and the process
/// dies with a segmentation fault inside GTK.
///
/// The lock is an exclusive lock on a file in the temporary directory.
/// An advisory file lock belongs to the *open file*, not to the
/// process, so two isolates — in the same process or in different ones —
/// contend for the same lock. (Windows' byte-range locks are
/// per-process and do not; the lock is therefore reliable on Linux and
/// macOS.)
///
/// ```dart
/// withInitializationLock(gtk.init);
/// ```
///
/// The file is never deleted: a lock is tied to the file it is taken
/// on, and a new file would be a new lock.
void withInitializationLock(void Function() body) {
  final lockFile = File('${Directory.systemTemp.path}/gir-initialization.lock');
  final handle = lockFile.openSync(mode: FileMode.append);
  try {
    handle.lockSync(FileLock.exclusive);
    try {
      body();
    } finally {
      handle.unlockSync();
    }
  } finally {
    handle.closeSync();
  }
}

/// The distribution packages that ship a native library.
///
/// The generator emits one of these per package, carrying the names the
/// platform table holds for the library the package wraps.
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

  /// The install commands for the platform the process runs on.
  ///
  /// Linux does not name its distribution, so every common package
  /// manager is listed and the user picks the line that matches their
  /// system. Windows has no package manager to name, so the list is
  /// empty and the caller falls back to a `PATH` hint.
  List<String> commandsForCurrentPlatform() {
    if (Platform.isMacOS) {
      return homebrew.isEmpty ? const [] : ['brew install $homebrew'];
    }
    if (Platform.isWindows) return const [];
    return [
      if (debian.isNotEmpty) 'sudo apt install $debian',
      if (fedora.isNotEmpty) 'sudo dnf install $fedora',
      if (arch.isNotEmpty) 'sudo pacman -S $arch',
    ];
  }
}

/// A native library the bindings need is not installed.
///
/// The message names the library, the package that needs it, every file
/// name that was tried and the command that installs it — the four
/// things a user needs to fix the problem.
///
/// This is what the loader throws when a library is missing. The old
/// behaviour — a silent fall back to the process namespace — turned a
/// missing library into a *"None of the loaded modules contained the
/// requested symbol"* error hundreds of calls later, which points at the
/// bindings instead of at the system.
class NativeLibraryNotFound implements Exception {
  const NativeLibraryNotFound({
    required this.package,
    required this.library,
    required this.tried,
    required this.install,
  });

  /// The Dart package that needs the library (`gir_gtk4`).
  final String package;

  /// The library's name in the GIR (`Gtk 4.0`).
  final String library;

  /// Every file name that was tried, in order.
  final List<String> tried;

  /// The distribution packages that ship the library.
  final InstallPackages install;

  @override
  String toString() {
    final b = StringBuffer();
    final first = tried.isEmpty ? library : tried.first;
    b.write('Could not load $first');
    if (library.isNotEmpty && library != first) {
      b.write(' ($library)');
    }
    b.write(', needed by package $package.');
    if (tried.length > 1) {
      b.write('\nTried: ${tried.join(', ')}');
    }
    final commands = install.commandsForCurrentPlatform();
    if (commands.isEmpty) {
      b.write(
        '\nAdd the folder that holds $first to your PATH, or install the '
        'library with your package manager.',
      );
    } else {
      b.write('\nInstall it with:');
      for (final command in commands) {
        b.write('\n  $command');
      }
    }
    return b.toString();
  }
}

/// Opens the native libraries of a package.
///
/// The names for the platform the process runs on are tried in order —
/// [linux], [windows] or [macos] — and every name that opens is
/// returned. A namespace may list more than one shared library, and a
/// symbol may live in any of them.
///
/// Throws [NativeLibraryNotFound] when **none** of the names opens.
/// The library is missing, and the user needs to be told which one and
/// how to install it — that is the whole point of the per-platform
/// tables the generator emits.
List<DynamicLibrary> openLibrary({
  required String package,
  required String library,
  required List<String> linux,
  required List<String> windows,
  required List<String> macos,
  required InstallPackages install,
}) {
  final names = namesForCurrentPlatform(
    linux: linux,
    windows: windows,
    macos: macos,
  );
  final libs = <DynamicLibrary>[];
  for (final name in names) {
    try {
      libs.add(DynamicLibrary.open(name));
    } on ArgumentError {
      // Not present under this name; try the next one.
    }
  }
  if (libs.isEmpty) {
    throw NativeLibraryNotFound(
      package: package,
      library: library,
      tried: names,
      install: install,
    );
  }
  return libs;
}

/// The file names to try for the platform the process runs on.
///
/// Anything that is neither Windows nor macOS is treated as Linux: the
/// sonames the GIR carries are the Linux ones, and a platform without
/// a table of its own is better served by them than by nothing.
List<String> namesForCurrentPlatform({
  required List<String> linux,
  required List<String> windows,
  required List<String> macos,
}) {
  if (Platform.isWindows) return windows;
  if (Platform.isMacOS) return macos;
  return linux;
}

/// Looks up [symbol] in the running process — used for GLib-internal
/// helpers (`g_free`) that are loaded globally when libglib is present.
///
/// `DynamicLibrary.process()` is the global symbol namespace of the
/// running process, and it is supported on every platform. The
/// `DynamicLibrary.executable()` alternative is not: it throws
/// `UnsupportedError` on Windows, which would make the allocator
/// helpers fail outright there.
DynamicLibrary _glibProcessLib() => DynamicLibrary.process();

/// The GLib library handle the allocator helpers use.
///
/// `g_free` and `g_malloc` live in libglib. The generated packages load
/// libglib with `dlopen`, and a `dlopen`ed library is *not* part of the
/// process-global symbol namespace, so `DynamicLibrary.process()` cannot
/// see it in every process. The global namespace is tried first (it works
/// when libglib was loaded globally), and an explicitly opened GLib is the
/// fallback.
///
/// Both symbols come from the *same* handle: a buffer handed to a callee
/// that takes ownership has to be allocated by the allocator that callee
/// releases it with.
final DynamicLibrary _glibLib = _lookupGlib();

DynamicLibrary _lookupGlib() {
  try {
    final lib = _glibProcessLib();
    lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('g_free');
    return lib;
  } on ArgumentError {
    // Not globally visible — open GLib explicitly.
  }
  final libs = openLibrary(
    package: 'gir_ffi',
    library: 'GLib 2.0',
    linux: const ['libglib-2.0.so.0', 'libglib-2.0.so'],
    windows: const ['libglib-2.0-0.dll'],
    macos: const ['libglib-2.0.0.dylib'],
    install: const InstallPackages(
      debian: 'libglib2.0-dev',
      fedora: 'glib2-devel',
      homebrew: 'glib',
      arch: 'glib',
    ),
  );
  for (final lib in libs) {
    try {
      lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('g_free');
      return lib;
    } on ArgumentError {
      // Opened, but it does not export `g_free` — try the next one.
    }
  }
  throw StateError(
    'g_free not found: libglib was opened, but it does not export g_free, '
    'so GLib-allocated memory cannot be released.',
  );
}

/// The `g_free` implementation.
final _gFreeNative = _glibLib
    .lookup<NativeFunction<Void Function(Pointer<Void>)>>('g_free');

/// The `g_malloc` implementation.
///
/// `g_malloc(gsize)` — `gsize` is `unsigned long`, i.e. `ffi.Size` on the
/// native side and a plain Dart `int` on this side.
final _gMallocNative = _glibLib
    .lookup<NativeFunction<Pointer<Void> Function(Size)>>('g_malloc');

/// The `g_strfreev` implementation.
///
/// `g_strfreev(gchar **str_array)` — frees a NULL-terminated array of
/// strings *and* the strings in it. It is the deallocator GLib pairs
/// with every `gchar **` it hands over.
final _gStrfreevNative = _glibLib
    .lookup<NativeFunction<Void Function(Pointer<Pointer<Utf8>>)>>(
      'g_strfreev',
    );

/// Releases memory GLib allocated (`g_malloc`, `g_strdup`, …).
///
/// GLib documents `g_free` as the deallocator for its own allocations.
void gFree(Pointer<Void> ptr) {
  if (ptr == nullptr) return;
  _gFreeNative.asFunction<void Function(Pointer<Void>)>().call(ptr);
}

/// Releases a NULL-terminated array of strings GLib allocated.
///
/// This is `g_strfreev`: it frees the array *and* every string in it. A
/// callee that handed the array over (`transfer-ownership="full"`)
/// expects exactly this call.
void gStrfreev(Pointer<Pointer<Utf8>> list) {
  if (list == nullptr) return;
  _gStrfreevNative.asFunction<void Function(Pointer<Pointer<Utf8>>)>().call(
    list,
  );
}

/// Copies a `char **` into a Dart list.
///
/// The strings are copied, so the native array may be released
/// afterwards — pass `free: true` when the GIR says the callee handed
/// the array over (`transfer-ownership="full"`), which is the case for
/// `g_strfreev` and friends. A `transfer-none` array (`g_get_language_names`
/// and the other static tables) must *not* be freed: `free` stays false.
///
/// A NULL array is a Dart `null`, not an empty list — GLib uses NULL to
/// mean "no list at all".
///
/// [length] is the element count when the caller knows it. GLib's GIR
/// binds a `char **` to the parameter that carries its count — an OUT
/// parameter for a callee-allocated array (`g_key_file_get_string_list`
/// and its `gsize *length`), an IN parameter for a caller-provided one
/// (`g_key_file_set_string_list`). Without [length] the array is read
/// until its NULL terminator, which is the `GStrv` convention; with it
/// the read stops after [length] elements, so an array that carries no
/// terminator is read correctly.
///
/// [free] releases the array *and* its strings (`g_strfreev`) — what
/// `transfer-ownership="full"` means for a `gchar **` in GLib.
/// [freeArray] releases the array alone (`g_free`) and leaves the
/// strings alone — what `transfer-ownership="container"` means.
List<String>? stringListFromNative(
  Pointer<Pointer<Utf8>> list, {
  bool free = false,
  bool freeArray = false,
  int? length,
}) {
  if (list == nullptr) return null;
  final out = <String>[];
  var i = 0;
  while (length == null || i < length) {
    final element = list[i];
    if (element == nullptr) break;
    out.add(element.toDartString());
    i++;
  }
  if (free) {
    gStrfreev(list);
  } else if (freeArray) {
    gFree(list.cast());
  }
  return out;
}

/// Allocates [size] bytes with GLib's allocator (`g_malloc`).
///
/// A buffer that a callee takes ownership of (`transfer-ownership="full"`)
/// is released by that callee with `g_free`, so it has to come from
/// `g_malloc` — `malloc` from `package:ffi` is a different heap.
///
/// GLib's `g_malloc(0)` returns `NULL`, so callers that need a valid
/// pointer for an empty buffer should ask for at least one byte.
Pointer<Uint8> gMalloc(int size) {
  if (size <= 0) {
    throw ArgumentError.value(size, 'size', 'must be positive');
  }
  return _gMallocNative
      .asFunction<Pointer<Void> Function(int)>()
      .call(size)
      .cast<Uint8>();
}

/// Copies a Dart [String] into a **GLib-allocated** NUL-terminated buffer.
///
/// GLib takes ownership of a signal's string return value
/// (`g_value_take_string`) and releases it with `g_free` — so the buffer
/// has to come from `g_malloc`, not from Dart's allocator. A Dart string
/// copied with `toNativeUtf8` is freed with `malloc.free` and would
/// crash the GValue's `g_free`.
Pointer<Utf8> gStrdupLike(String value) {
  final bytes = utf8.encode(value);
  final buffer = gMalloc(bytes.length + 1);
  final target = buffer.cast<Uint8>();
  for (var i = 0; i < bytes.length; i++) {
    target[i] = bytes[i];
  }
  target[bytes.length] = 0;
  return buffer.cast<Utf8>();
}

/// Runs [body] with [data] mirrored into a GLib-allocated native buffer.
///
/// The buffer comes from `g_malloc` — the allocator GLib frees its own
/// memory with — so a callee that takes ownership ([owned]) can release it
/// with `g_free`.
///
/// The bytes are copied into the buffer before [body] runs and copied back
/// afterwards, so a callee that *fills* the buffer (a caller-provided
/// output buffer) writes through to [data].
///
/// When [owned] is true the callee takes ownership of the buffer: it is
/// neither released nor copied back. A callee that owns the buffer may
/// also keep it past the call, so the copy-back would read freed memory.
R withNativeBytes<R>(
  Uint8List data,
  R Function(Pointer<Uint8> buffer, int length) body, {
  bool owned = false,
}) {
  final length = data.length;
  // `g_malloc(0)` returns NULL; a zero-length buffer still needs a valid
  // pointer for the callee to read from.
  final buffer = gMalloc(length == 0 ? 1 : length);
  try {
    if (length > 0) {
      buffer.asTypedList(length).setRange(0, length, data);
    }
    final result = body(buffer, length);
    if (!owned && length > 0) {
      data.setRange(0, length, buffer.asTypedList(length));
    }
    return result;
  } finally {
    if (!owned) gFree(buffer.cast());
  }
}

/// Copies [length] bytes from the GLib-allocated buffer at [buffer] into a
/// Dart [Uint8List] and releases the native buffer.
///
/// A callee-allocated byte buffer — `g_file_load_contents`' `contents`, for
/// instance — is native memory the garbage collector cannot see. The GIR
/// hands the buffer over with `transfer-ownership="full"`, so the caller
/// owns it and has to release it; copying it into a Dart list and freeing
/// the original leaves the user with plain Dart memory and no lifetime
/// rules.
Uint8List bytesFromNative(Pointer<Uint8> buffer, int length) {
  if (buffer == nullptr) return Uint8List(0);
  final out = Uint8List(length);
  if (length > 0) out.setRange(0, length, buffer.asTypedList(length));
  gFree(buffer.cast());
  return out;
}

/// Converts a native NUL-terminated UTF-8 string to a Dart [String].
///
/// A callee-allocated buffer — `g_spawn_sync`'s `standard_output`, for
/// instance — is native memory the garbage collector cannot see. The GIR
/// hands it over with `transfer-ownership="full"`, so the caller owns it
/// and has to release it; copying it into a Dart string and freeing the
/// original leaves the user with plain Dart memory and no lifetime
/// rules.
///
/// The size of the buffer is not stated anywhere in the signature, so
/// the string ends at the first NUL. A child process that writes a NUL
/// into its output therefore yields a shorter string than it wrote.
String? nulTerminatedStringFromNative(Pointer<Uint8> buffer) {
  if (buffer == nullptr) return null;
  final value = buffer.cast<Utf8>().toDartString();
  gFree(buffer.cast());
  return value;
}

/// Converts a native NUL-terminated UTF-8 string to a Dart [String].
String? stringFromNative(Pointer<Char> ptr, {bool free = false}) {
  if (ptr == nullptr) return null;
  final value = ptr.cast<Utf8>().toDartString();
  if (free) malloc.free(ptr);
  return value;
}

/// Converts a Dart [String] to a native NUL-terminated UTF-8 string.
Pointer<Char> stringToNative(String? value) {
  if (value == null) return nullptr;
  return value.toNativeUtf8().cast<Char>();
}

/// Runs [body] with [value] marshalled to native memory, freeing it after.
R withNativeString<R>(String? value, R Function(Pointer<Char>) body) {
  final ptr = stringToNative(value);
  try {
    return body(ptr);
  } finally {
    if (ptr != nullptr) malloc.free(ptr);
  }
}

/// Re-wraps a raw native pointer as the user's class via [factory].
///
/// Use this when you have a bare `Pointer<Void>` (e.g. from a custom
/// FFI lookup, from a struct OUT param, from `Pointer.fromAddress`)
/// and want to recover your subclass's methods. The companion to the
/// instance `cast<T>(factory)` method on every generated wrapper —
/// they call this internally when the user passes a raw pointer
/// instead of a wrapper.
T castTo<T extends Object>(
  Pointer<Void> handle,
  T Function(Pointer<Void>) factory,
) {
  return factory(handle);
}

/// Marshals a nullable `List<String?>` to a NULL-terminated
/// `Pointer<Pointer<Utf8>>` for the duration of [body], matching how GLib
/// expects argv-style arrays. Each non-null element is copied to a
/// native NUL-terminated string; the outer pointer and all per-element
/// pointers are freed in a `finally`.
///
/// * Pass `null` to leave the array pointer as NULL — the C side sees
///   `argv == NULL`, which is the accepted convention for
///   `g_application_run` and friends when no command-line parsing is
///   needed.
/// * Pass an empty list to allocate a one-slot array whose only entry
///   is NULL — i.e. `argc = 0, argv = {NULL}`. Same as above but
///   distinguishable from a null pointer for C APIs that require a
///   non-null array.
/// * Null elements inside the list become NULL slots in the array;
///   only the non-null allocations are tracked for freeing.
///
/// [body] receives the array *and* its element count. The count is the
/// number of slots the caller asked for — the terminator is not
/// counted. A C function that takes the count (`g_key_file_set_string_list`
/// and its `gsize length`) reads exactly that many slots; one that does
/// not reads until the terminator.
R withNativeStringList<R>(
  List<String?>? values,
  R Function(Pointer<Pointer<Utf8>> argv, int length) body,
) {
  if (values == null) {
    return body(nullptr, 0);
  }
  final argc = values.length;
  final argv = calloc<Pointer<Utf8>>(argc + 1);
  final strs = <Pointer<Utf8>>[];
  try {
    for (var i = 0; i < argc; i++) {
      final v = values[i];
      if (v == null) {
        argv[i] = nullptr;
      } else {
        final p = v.toNativeUtf8();
        strs.add(p);
        argv[i] = p.cast();
      }
    }
    argv[argc] = nullptr; // explicit NULL terminator
    return body(argv, argc);
  } finally {
    for (final p in strs) {
      calloc.free(p);
    }
    calloc.free(argv);
  }
}

/// Runs [body] with [value] marshalled to native memory and its **byte**
/// length reported.
///
/// This is the companion of [withNativeString] for the C APIs that take a
/// string *and* its length (`g_regex_match_full` and its `gssize
/// string_len`). The count the C side expects is a byte count, not a
/// character count: a Dart string of four characters can be six UTF-8
/// bytes, and passing the character count would truncate the string on
/// the C side.
///
/// The length excludes the NUL terminator, and the string is released
/// when [body] returns.
R withNativeStringBytes<R>(
  String? value,
  R Function(Pointer<Utf8> ptr, int length) body,
) {
  if (value == null) {
    return body(nullptr, 0);
  }
  final bytes = value.toNativeUtf8();
  try {
    return body(bytes, bytes.length - 1);
  } finally {
    malloc.free(bytes.cast());
  }
}

/// Backing store for caller-allocated OUT parameters (e.g. `GtkTextIter*`,
/// `GValue*`) emitted by the generator.
///
/// Holds a fixed-size zero-initialized buffer and frees it via
/// [NativeFinalizer] when the anchor is garbage collected. The corresponding
/// Dart wrapper (e.g. `GtkTextIter.fromPointer(_buffer)`) keeps the
/// anchor reachable as long as the user holds the wrapper — matching
/// GTK's "the iter lives until you drop it" semantics.
///
/// Use [HeapAnchor.allocate] to create a new anchor with a buffer of the
/// requested size. The buffer's lifetime is tied to the anchor's
/// reachability; drop the wrapper and the buffer is freed on the next
/// GC cycle.
class HeapAnchor implements Finalizable {
  HeapAnchor(this.buffer);

  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  /// The heap-allocated buffer. The C function fills this memory; the
  /// wrapper then exposes it as `Pointer<Void>` (or any struct-typed
  /// pointer) to its caller.
  final Pointer<Uint8> buffer;

  /// Allocates a [byteCount]-byte zero-initialized buffer and attaches a
  /// finalizer that calls `malloc.nativeFree` when the anchor is GC'd.
  static HeapAnchor allocate(int byteCount) {
    final anchor = HeapAnchor(calloc<Uint8>(byteCount));
    _finalizer.attach(anchor, anchor.buffer.cast());
    return anchor;
  }
}

/// The registry that ties a wrapper to the buffer it points into.
///
/// A wrapper built from an OUT parameter points *into* a buffer the
/// generator allocated for the call — a `GtkTextIter` is not a pointer
/// to an object, it is a window onto the caller's own memory. If the
/// buffer dies while the wrapper lives, the wrapper reads freed memory.
///
/// The registry is a weak-keyed map: the entry disappears with the
/// wrapper, and the buffer's own [NativeFinalizer] frees the memory
/// once nothing holds the anchor any more.
final Expando<Object> _keepAliveRegistry = Expando<Object>();

/// Ties [anchor] to [wrapper]'s lifetime and returns [wrapper].
///
/// The generator calls this for every wrapper it builds from an OUT
/// parameter's buffer, so the buffer outlives the wrapper that reads
/// from it.
T keepAlive<T extends Object>(T wrapper, Object anchor) {
  _keepAliveRegistry[wrapper] = anchor;
  return wrapper;
}

/// The wrapper cache.
///
/// Native code hands the same pointer over more than once: a property
/// getter, a signal argument, a list item. Without a cache every
/// handover produced a *new* Dart wrapper, so a Dart subclass of a
/// GObject class lost its identity — and its Dart state — on the way
/// out of native code.
///
/// The entries are **weak**. A strong entry would keep every wrapper
/// alive forever: its finalizer would never run, the native object
/// would never be released, and every model object would leak. The Dart
/// side is owned by the application.
///
/// One address can hold several wrappers: the same native object may be
/// seen through different classes (a `GObject` and a `GtkWidget`, say),
/// and each of them wants its own view of it.
final Map<int, List<WeakReference<Object>>> _objectCache =
    <int, List<WeakReference<Object>>>{};

/// The Dart object registered for [address] that is a [T], if any.
///
/// Returns `null` when nothing is registered for the address, when every
/// registered object has been collected, or when none of them is a [T].
T? cachedObject<T extends Object>(int address) {
  final entries = _objectCache[address];
  if (entries == null) return null;
  for (var i = 0; i < entries.length; i++) {
    final hit = entries[i].target;
    if (hit == null) {
      // The Dart object is gone; the address may be reused by a later
      // object, so the stale entry goes.
      entries.removeAt(i);
      i--;
      continue;
    }
    if (hit is T) return hit;
  }
  if (entries.isEmpty) _objectCache.remove(address);
  return null;
}

/// Every Dart object registered for [address] that is a [T], in the order
/// they were registered.
///
/// [cachedObject] returns the first match. This returns all of them, for
/// the rare case where the first match is not the one the caller wants —
/// an address that was freed and handed out again holds the wrapper of
/// the *old* object next to the wrapper of the new one, and the caller
/// may need to tell them apart.
List<T> cachedObjects<T extends Object>(int address) {
  final entries = _objectCache[address];
  if (entries == null) return const [];
  final found = <T>[];
  for (var i = 0; i < entries.length; i++) {
    final hit = entries[i].target;
    if (hit == null) {
      // The Dart object is gone; the address may be reused by a later
      // object, so the stale entry goes.
      entries.removeAt(i);
      i--;
      continue;
    }
    if (hit is T) found.add(hit);
  }
  if (entries.isEmpty) _objectCache.remove(address);
  return found;
}

/// Registers [object] under [address].
///
/// A second wrapper for the same address joins the list rather than
/// replacing the first one: a Dart subclass instance must not be
/// shadowed by a later, less specific wrapper for the same pointer.
void registerDartObject(Object object, int address) {
  final entries = _objectCache.putIfAbsent(
    address,
    () => <WeakReference<Object>>[],
  );
  for (final entry in entries) {
    if (identical(entry.target, object)) return;
  }
  entries.add(WeakReference(object));
  _pruneObjectCache();
}

/// Drops the entries whose Dart object has been collected.
///
/// Called from [registerDartObject] so the map cannot grow without
/// bound; the sweep is amortised — it only runs once the map has grown
/// past twice the number of live entries.
void _pruneObjectCache() {
  if (_objectCache.length < _pruneThreshold) return;
  var live = 0;
  for (final entries in _objectCache.values) {
    entries.removeWhere((entry) => entry.target == null);
    live += entries.length;
  }
  _objectCache.removeWhere((_, entries) => entries.isEmpty);
  _pruneThreshold = (live * 2).clamp(64, 1 << 20);
}

/// The size at which the cache is swept.
int _pruneThreshold = 64;

/// The number of entries in the wrapper cache.
///
/// Dead entries are pruned when they are looked up, so this counts the
/// entries that have not been visited since their object died.
int get cachedObjectCount => _objectCache.length;
