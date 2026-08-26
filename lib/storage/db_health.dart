// Native platforms validate the SQLite file before Drift opens it. Web uses
// IndexedDB, so it gets a no-op implementation that does not pull dart:io or
// sqlite3 FFI into the JavaScript compiler.
export 'db_health_stub.dart'
    if (dart.library.io) 'db_health_io.dart';
