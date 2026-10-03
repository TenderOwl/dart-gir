import 'dart:ffi' as ffi;
import 'package:adw/adw.dart';
import 'package:gobject/gobject.dart';
import 'package:gir_ffi/gir_ffi.dart' show gTypeClassRef, gTypeCheckClassCast, gTypeClassUnref;

void main() {
  init();
  // Constructing an AdwApplication triggers GType registration of
  // the AdwApplicationWindow class — without that,
  // `typeFromName('AdwApplicationWindow')` returns 0.
  AdwApplication('com.example.debug', .defaultFlags);
  // Force type registration:
  final type = typeFromName('AdwApplicationWindow');
  print('AdwApplicationWindow type = $type');
  if (type == 0) {
    print('Type not registered — typeFromName returns 0 because no instance has been created.');
    return;
  }
  final classPtr = gTypeClassRef(type);
  print('gTypeClassRef returned: $classPtr');
  if (classPtr == ffi.nullptr) return;
  print('Calling gTypeCheckClassCast...');
  final castPtr = gTypeCheckClassCast(classPtr, type);
  print('gTypeCheckClassCast returned: $castPtr');
  gTypeClassUnref(classPtr);
}