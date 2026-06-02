// Auto-update Phase 3 — installer downloader tests. Deterministic + OFFLINE:
// MockClient.streaming serves bytes (so we can assert progress callbacks) and a
// real temp dir is injected as the save location. No live GitHub call, no real
// platform temp folder.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbits_flutter/core/update_downloader.dart';
import 'package:orbits_flutter/core/update_downloader_io.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('orbits_downloader_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<Directory> dirResolver() async => tempDir;

  /// Streams [body] back in chunks, optionally with a Content-Length header.
  MockClient streamingBytes(
    List<int> body, {
    int statusCode = 200,
    bool withContentLength = true,
    int chunkSize = 4,
  }) {
    return MockClient.streaming((request, bodyStream) async {
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < body.length; i += chunkSize) {
          yield body.sublist(
            i,
            i + chunkSize > body.length ? body.length : i + chunkSize,
          );
        }
      }

      return http.StreamedResponse(
        chunks(),
        statusCode,
        contentLength: withContentLength ? body.length : null,
      );
    });
  }

  IoUpdateDownloader downloader(MockClient client) => IoUpdateDownloader(
        client: client,
        dirResolver: dirResolver,
        isWindows: true,
      );

  group('platform / filename guards', () {
    test('non-Windows → unsupportedPlatform', () async {
      final d = IoUpdateDownloader(
        client: streamingBytes(utf8.encode('data')),
        dirResolver: dirResolver,
        isWindows: false,
      );
      final r = await d.download('https://x/win.exe',
          fileName: kWindowsInstallerFileName);
      expect(r.status, DownloadStatus.unsupportedPlatform);
    });

    test('non-.exe fileName → invalidFile', () async {
      final d = downloader(streamingBytes(utf8.encode('data')));
      final r = await d.download('https://x/win.zip', fileName: 'win.zip');
      expect(r.status, DownloadStatus.invalidFile);
    });
  });

  group('successful download', () {
    test('writes file, returns path + byte count', () async {
      final bytes = utf8.encode('MZ${'fake-installer-body' * 4}');
      final d = downloader(streamingBytes(bytes));

      final r = await d.download('https://x/win.exe',
          fileName: kWindowsInstallerFileName);

      expect(r.status, DownloadStatus.downloaded);
      expect(r.ok, isTrue);
      expect(r.bytes, bytes.length);
      expect(r.filePath, isNotNull);
      final saved = File(r.filePath!);
      expect(saved.existsSync(), isTrue);
      expect(saved.lengthSync(), bytes.length);
      expect(r.filePath, endsWith(kWindowsInstallerFileName));
    });

    test('reports incremental progress with total', () async {
      final bytes = List<int>.generate(20, (i) => i % 256);
      final d = downloader(streamingBytes(bytes, chunkSize: 5));

      final events = <(int, int?)>[];
      final r = await d.download(
        'https://x/win.exe',
        fileName: kWindowsInstallerFileName,
        onProgress: (received, total) => events.add((received, total)),
      );

      expect(r.status, DownloadStatus.downloaded);
      expect(events.isNotEmpty, isTrue);
      // Monotonic non-decreasing received count, ending at full size.
      expect(events.last.$1, bytes.length);
      expect(events.last.$2, bytes.length); // total from Content-Length
      for (var i = 1; i < events.length; i++) {
        expect(events[i].$1 >= events[i - 1].$1, isTrue);
      }
    });

    test('progress total is null when no Content-Length', () async {
      final bytes = utf8.encode('installer-bytes');
      final d = downloader(streamingBytes(bytes, withContentLength: false));

      int? lastTotal = -1;
      final r = await d.download(
        'https://x/win.exe',
        fileName: kWindowsInstallerFileName,
        onProgress: (received, total) => lastTotal = total,
      );

      expect(r.status, DownloadStatus.downloaded);
      expect(lastTotal, isNull);
    });
  });

  group('validation failures', () {
    test('HTTP error status → httpError (no file kept)', () async {
      final d = downloader(streamingBytes(const [], statusCode: 404));
      final r = await d.download('https://x/win.exe',
          fileName: kWindowsInstallerFileName);

      expect(r.status, DownloadStatus.httpError);
      expect(
        File('${tempDir.path}${Platform.pathSeparator}$kWindowsInstallerFileName')
            .existsSync(),
        isFalse,
      );
    });

    test('empty body → invalidFile and partial file removed', () async {
      final d = downloader(streamingBytes(const []));
      final r = await d.download('https://x/win.exe',
          fileName: kWindowsInstallerFileName);

      expect(r.status, DownloadStatus.invalidFile);
      expect(
        File('${tempDir.path}${Platform.pathSeparator}$kWindowsInstallerFileName')
            .existsSync(),
        isFalse,
      );
    });

    test('size mismatch → sizeMismatch and file removed', () async {
      final bytes = utf8.encode('twelve bytes');
      final d = downloader(streamingBytes(bytes));
      final r = await d.download(
        'https://x/win.exe',
        fileName: kWindowsInstallerFileName,
        expectedSize: bytes.length + 999, // wrong on purpose
      );

      expect(r.status, DownloadStatus.sizeMismatch);
      expect(
        File('${tempDir.path}${Platform.pathSeparator}$kWindowsInstallerFileName')
            .existsSync(),
        isFalse,
      );
    });

    test('matching expectedSize → downloaded', () async {
      final bytes = utf8.encode('exact-size-body');
      final d = downloader(streamingBytes(bytes));
      final r = await d.download(
        'https://x/win.exe',
        fileName: kWindowsInstallerFileName,
        expectedSize: bytes.length,
      );

      expect(r.status, DownloadStatus.downloaded);
      expect(r.bytes, bytes.length);
    });
  });
}
