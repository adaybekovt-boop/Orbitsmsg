// Web stub for the installer downloader. The web build can't save a local
// installer file, so downloads report "unsupported".

import 'package:http/http.dart' as http;

import 'update_downloader.dart';

UpdateDownloader createUpdateDownloader({http.Client? client}) =>
    const _StubUpdateDownloader();

class _StubUpdateDownloader implements UpdateDownloader {
  const _StubUpdateDownloader();

  @override
  Future<DownloadResult> download(
    String url, {
    required String fileName,
    int? expectedSize,
    DownloadProgress? onProgress,
  }) async =>
      const DownloadResult(DownloadStatus.unsupportedPlatform);
}
