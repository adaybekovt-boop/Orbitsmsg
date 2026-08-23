// Windows installer download (auto-update Phase 3).
//
// Streams the `orbits-windows-x64.exe` release asset to a private temp folder
// with progress, size cap, idle timeout, and an atomic `.part` rename.
// Integrity of the bytes is NOT established here — an adjacent `.sha256` file
// is ignored. The installer launcher requires a pinned Authenticode signature
// (U-1) before `Process.start`.
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
  tooLarge,
  timeout,
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

/// Hard cap on installer size. GitHub Content-Length is attacker-controlled
/// via a compromised release; we also count bytes as they arrive.
const int kMaxInstallerBytes = 200 * 1024 * 1024;

/// Abort if the TCP/HTTP handshake stalls.
const Duration kDownloadConnectTimeout = Duration(seconds: 20);

/// Abort if no body chunk arrives for this long (slowloris / hung socket).
const Duration kDownloadIdleTimeout = Duration(seconds: 30);

UpdateDownloader createUpdateDownloader({http.Client? client}) =>
    impl.createUpdateDownloader(client: client);
