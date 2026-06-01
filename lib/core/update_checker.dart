import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const String tkMessengerLatestReleaseApi =
    'https://api.github.com/repos/adaybekovt-boop/tkmessenger/releases/latest';

const String tkMessengerLatestReleasePage =
    'https://github.com/adaybekovt-boop/tkmessenger/releases/latest';

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.latestTag,
    required this.releaseUrl,
    required this.isUpdateAvailable,
    this.windowsAssetUrl,
    this.androidUniversalAssetUrl,
    this.androidArm64AssetUrl,
    this.errorMessage,
  });

  factory UpdateCheckResult.error({
    required String currentVersion,
    required String message,
  }) {
    return UpdateCheckResult(
      currentVersion: currentVersion,
      latestVersion: '',
      latestTag: '',
      releaseUrl: tkMessengerLatestReleasePage,
      isUpdateAvailable: false,
      errorMessage: message,
    );
  }

  final String currentVersion;
  final String latestVersion;
  final String latestTag;
  final String releaseUrl;
  final bool isUpdateAvailable;
  final String? windowsAssetUrl;
  final String? androidUniversalAssetUrl;
  final String? androidArm64AssetUrl;
  final String? errorMessage;

  bool get hasError => errorMessage != null;

  String? get preferredAndroidAssetUrl =>
      androidUniversalAssetUrl ?? androidArm64AssetUrl;
}

class UpdateChecker {
  UpdateChecker({
    http.Client? client,
    Uri? latestReleaseUri,
    Duration timeout = const Duration(seconds: 10),
  })  : _client = client ?? http.Client(),
        _latestReleaseUri =
            latestReleaseUri ?? Uri.parse(tkMessengerLatestReleaseApi),
        _timeout = timeout;

  final http.Client _client;
  final Uri _latestReleaseUri;
  final Duration _timeout;

  Future<UpdateCheckResult> check({required String currentVersion}) async {
    try {
      final response = await _client.get(
        _latestReleaseUri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'TK-Messenger-update-checker',
        },
      ).timeout(_timeout);

      if (response.statusCode != 200) {
        return UpdateCheckResult.error(
          currentVersion: currentVersion,
          message: 'GitHub вернул ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        return UpdateCheckResult.error(
          currentVersion: currentVersion,
          message: 'Некорректный ответ GitHub',
        );
      }

      return parseGitHubRelease(
        decoded,
        currentVersion: currentVersion,
      );
    } on TimeoutException {
      return UpdateCheckResult.error(
        currentVersion: currentVersion,
        message: 'Истекло время ожидания',
      );
    } catch (error) {
      return UpdateCheckResult.error(
        currentVersion: currentVersion,
        message: error.toString(),
      );
    }
  }
}

UpdateCheckResult parseGitHubRelease(
  Map<String, Object?> json, {
  required String currentVersion,
}) {
  final tag = json['tag_name'];
  if (tag is! String || tag.trim().isEmpty) {
    return UpdateCheckResult.error(
      currentVersion: currentVersion,
      message: 'В релизе нет tag_name',
    );
  }

  final releaseUrl = switch (json['html_url']) {
    final String url when url.isNotEmpty => url,
    _ => tkMessengerLatestReleasePage,
  };
  final latestVersion = normalizeReleaseVersion(tag);
  final current = parseReleaseVersion(currentVersion);
  final latest = parseReleaseVersion(latestVersion);

  final assets = switch (json['assets']) {
    final List<Object?> list => list.whereType<Map<String, Object?>>().toList(),
    _ => const <Map<String, Object?>>[],
  };

  final windowsAsset = _findAssetUrl(assets, (name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.exe') && lower.contains('windows');
  });

  final androidUniversalAsset = _findAssetUrl(assets, (name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.apk') &&
        lower.contains('android') &&
        lower.contains('universal');
  });

  final androidArm64Asset = _findAssetUrl(assets, (name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.apk') &&
        lower.contains('android') &&
        lower.contains('arm64');
  });

  return UpdateCheckResult(
    currentVersion: normalizeReleaseVersion(currentVersion),
    latestVersion: latestVersion,
    latestTag: tag,
    releaseUrl: releaseUrl,
    isUpdateAvailable:
        current != null && latest != null && latest.compareTo(current) > 0,
    windowsAssetUrl: windowsAsset,
    androidUniversalAssetUrl: androidUniversalAsset,
    androidArm64AssetUrl: androidArm64Asset,
  );
}

String normalizeReleaseVersion(String version) {
  final withoutBuild = version.trim().split('+').first;
  return withoutBuild.startsWith('v') || withoutBuild.startsWith('V')
      ? withoutBuild.substring(1)
      : withoutBuild;
}

ReleaseVersion? parseReleaseVersion(String version) {
  final normalized = normalizeReleaseVersion(version);
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(normalized);
  if (match == null) return null;
  return ReleaseVersion(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(ReleaseVersion other) {
    final majorDiff = major.compareTo(other.major);
    if (majorDiff != 0) return majorDiff;
    final minorDiff = minor.compareTo(other.minor);
    if (minorDiff != 0) return minorDiff;
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}

String? _findAssetUrl(
  List<Map<String, Object?>> assets,
  bool Function(String name) matches,
) {
  for (final asset in assets) {
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is String && url is String && url.isNotEmpty && matches(name)) {
      return url;
    }
  }
  return null;
}
