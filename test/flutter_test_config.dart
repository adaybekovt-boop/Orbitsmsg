import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Load the OS SQLite that Drift tests need on Linux CI/desktops.
/// `sqlite3_flutter_libs` does not bundle a .so for Linux.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isLinux) {
    Object? lastError;
    for (final name in const ['libsqlite3.so.0', 'libsqlite3.so']) {
      try {
        final lib = DynamicLibrary.open(name);
        open.overrideFor(OperatingSystem.linux, () => lib);
        lastError = null;
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw StateError(
        'Drift tests require system SQLite (libsqlite3.so.0). '
        'Install libsqlite3-0 / libsqlite3-dev. Last error: $lastError',
      );
    }
  }
  await testMain();
}
