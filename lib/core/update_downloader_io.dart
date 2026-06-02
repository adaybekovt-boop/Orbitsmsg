// dart:io implementation of the installer downloader (desktop/mobile builds).

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_downloader.dart';

/// Resolves the directory the installer is saved into. Injectable so tests use
/// a temp dir instead of the real platform temp folder.
typedef DirResolver = Future<Directory> Function();

UpdateDownloader createUpdateDownloader({http.Client? client}) =>
    IoUpdateDownloader(client: client);

class IoUpdateDownloader implements UpdateDownloader {
  IoUpdateDownloader({
    http.Client? client,
    DirResolver? dirResolver,
    bool? isWindows,
  })  : _client = client ?? http.Client(),
        _dirResolver = dirResolver ?? _defaultDir,
        _isWindows = isWindows ?? (!kIsWeb && Platform.isWindows);

  final http.Client _client;
  final DirResolver _dirResolver;
  final bool _isWindows;

  static Future<Directory> _defaultDir() async {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}${Platform.pathSeparator}orbits_update');
  }

  @override
  Future<DownloadResult> download(
    String url, {
    required String fileName,
    int? expectedSize,
    DownloadProgress? onProgress,
  }) async {
    if (!_isWindows) {
      return const DownloadResult(DownloadStatus.unsupportedPlatform);
    }
    if (!fileName.toLowerCase().endsWith('.exe')) {
      return const DownloadResult(
        DownloadStatus.invalidFile,
        message: 'Expected an .exe asset',
      );
    }

    File? target;
    IOSink? sink;
    try {
      final dir = await _dirResolver();
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      target = File('${dir.path}${Platform.pathSeparator}$fileName');
      // Remove any leftover partial download before starting.
      if (target.existsSync()) {
        target.deleteSync();
      }

      final response =
          await _client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        return DownloadResult(
          DownloadStatus.httpError,
          message: 'HTTP ${response.statusCode}',
        );
      }

      final total = response.contentLength ?? expectedSize;
      var received = 0;
      sink = target.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final written = target.lengthSync();
      if (written <= 0) {
        await _deleteQuietly(target);
        return const DownloadResult(
          DownloadStatus.invalidFile,
          message: 'Downloaded file is empty',
        );
      }
      if (expectedSize != null &&
          expectedSize > 0 &&
          written != expectedSize) {
        await _deleteQuietly(target);
        return DownloadResult(
          DownloadStatus.sizeMismatch,
          message: 'Expected $expectedSize bytes, got $written',
        );
      }

      return DownloadResult(
        DownloadStatus.downloaded,
        filePath: target.path,
        bytes: written,
      );
    } catch (e) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (target != null) {
        await _deleteQuietly(target);
      }
      return DownloadResult(DownloadStatus.error, message: '$e');
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }
}
