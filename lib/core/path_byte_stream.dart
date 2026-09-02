// Open a local filesystem path as a byte stream.
//
// dart:io lives in the `_io` impl so chat / connections stay web-safe.
// Callers must still refuse `://` paths. The web stub always returns null
// — web chat keeps picker bytes + PeerJS base64.

import 'path_byte_stream_stub.dart'
    if (dart.library.io) 'path_byte_stream_io.dart' as impl;

/// Size in bytes, or null if the path is missing / not a local file.
int? localPathLength(String path) => impl.localPathLength(path);

/// `File.openRead()` for a local existing path. Null on web or if refused.
Stream<List<int>>? openLocalPathByteStream(String path) =>
    impl.openLocalPathByteStream(path);
