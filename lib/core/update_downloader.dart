// Windows installer download (auto-update Phase 3).
//
// Streams the `orbits-windows-x64.exe` release asset to a private temp folder
// with progress, then verifies it's a non-empty .exe of the expected size. We
// download to a temp path only — never into the install dir, never over the
// running .exe (Phase 4's installer does the actual update).
//
// dart:io (File/HttpClient/Directory) lives in the conditional `_io`/`_stub`
// impls so this stays importable from the web build.

import 'package:http/http.dart' as http;

import 'update_downloader_io.dart'
    if (dart.library.html) 'update_downloader_stub.dart' as impl;

enum DownloadStatus {
  downloaded,
  unsupportedPlatform,
  invalidFile,
  httpError,
  sizeMismatch,
  error,
}

/// Progress callback: [received] bytes so far, [total] bytes if the server sent
/// a Content-Length (else null).
typedef DownloadProgress = void Function(int received, int? total);

class DownloadResult {
  const DownloadResult(
    this.status, {
    this.filePath,
    this.bytes,
    this.message,
  });

  final DownloadStatus status;

  /// Absolute path to the saved installer (only when [status] == downloaded).
  final String? filePath;

  /// Total bytes written.
  final int? bytes;
  final String? message;

  bool get ok => status == DownloadStatus.downloaded;
}

abstract class UpdateDownloader {
  /// Downloads [url] to a temp file named [fileName]. If [expectedSize] is given
  /// and non-zero it is verified against the bytes written. [onProgress] fires
  /// as chunks arrive.
  Future<DownloadResult> download(
    String url, {
    required String fileName,
    int? expectedSize,
    DownloadProgress? onProgress,
  });
}

/// Default asset/file name for the Windows installer.
const String kWindowsInstallerFileName = 'orbits-windows-x64.exe';

UpdateDownloader createUpdateDownloader({http.Client? client}) =>
    impl.createUpdateDownloader(client: client);
