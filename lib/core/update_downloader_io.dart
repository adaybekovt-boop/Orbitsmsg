// dart:io implementation of the installer downloader (desktop/mobile builds).

import 'dart:async';
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
    this.maxBytes = kMaxInstallerBytes,
    this.connectTimeout = kDownloadConnectTimeout,
    this.idleTimeout = kDownloadIdleTimeout,
  })  : _client = client ?? http.Client(),
        _dirResolver = dirResolver ?? _defaultDir,
        _isWindows = isWindows ?? (!kIsWeb && Platform.isWindows);

  final http.Client _client;
  final DirResolver _dirResolver;
  final bool _isWindows;
  final int maxBytes;
  final Duration connectTimeout;
  final Duration idleTimeout;

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
    if (!_safeExeFileName(fileName)) {
      return const DownloadResult(
        DownloadStatus.invalidFile,
        message: 'Expected a bare .exe file name',
      );
    }
    if (expectedSize != null && expectedSize > maxBytes) {
      return DownloadResult(
        DownloadStatus.tooLarge,
        message: 'Expected $expectedSize bytes exceeds cap $maxBytes',
      );
    }

    File? target;
    File? part;
    IOSink? sink;
    try {
      final dir = await _dirResolver();
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      target = File('${dir.path}${Platform.pathSeparator}$fileName');
      part = File('${target.path}.part');
      _deleteQuietlySync(target);
      _deleteQuietlySync(part);

      final response = await _client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(connectTimeout);
      if (response.statusCode != 200) {
        return DownloadResult(
          DownloadStatus.httpError,
          message: 'HTTP ${response.statusCode}',
        );
      }

      final declared = response.contentLength;
      if (declared != null && declared > maxBytes) {
        return DownloadResult(
          DownloadStatus.tooLarge,
          message: 'Content-Length $declared exceeds cap $maxBytes',
        );
      }

      final total = declared ?? expectedSize;
      var received = 0;
      sink = part.openWrite();
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        received += chunk.length;
        if (received > maxBytes) {
          throw const _DownloadTooLarge();
        }
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final written = part.lengthSync();
      if (written <= 0) {
        _deleteQuietlySync(part);
        return const DownloadResult(
          DownloadStatus.invalidFile,
          message: 'Downloaded file is empty',
        );
      }
      if (expectedSize != null &&
          expectedSize > 0 &&
          written != expectedSize) {
        _deleteQuietlySync(part);
        return DownloadResult(
          DownloadStatus.sizeMismatch,
          message: 'Expected $expectedSize bytes, got $written',
        );
      }

      // Atomic replace: write completed `.part`, then rename onto the final
      // name only after the body is complete.
      if (target.existsSync()) {
        target.deleteSync();
      }
      part.renameSync(target.path);
      part = null;

      return DownloadResult(
        DownloadStatus.downloaded,
        filePath: target.path,
        bytes: written,
      );
    } on TimeoutException catch (e) {
      await _abort(sink, part, target);
      return DownloadResult(DownloadStatus.timeout, message: '$e');
    } on _DownloadTooLarge {
      await _abort(sink, part, target);
      return DownloadResult(
        DownloadStatus.tooLarge,
        message: 'Exceeded cap $maxBytes bytes',
      );
    } catch (e) {
      await _abort(sink, part, target);
      return DownloadResult(DownloadStatus.error, message: '$e');
    }
  }

  static bool _safeExeFileName(String fileName) {
    if (!fileName.toLowerCase().endsWith('.exe')) return false;
    if (fileName.contains('/') ||
        fileName.contains('\\') ||
        fileName.contains('..')) {
      return false;
    }
    return fileName == fileName.split(RegExp(r'[\\/]')).last;
  }

  static Future<void> _abort(IOSink? sink, File? part, File? target) async {
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (part != null) _deleteQuietlySync(part);
    if (target != null) _deleteQuietlySync(target);
  }

  static void _deleteQuietlySync(File f) {
    try {
      if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }
}

class _DownloadTooLarge implements Exception {
  const _DownloadTooLarge();
}
