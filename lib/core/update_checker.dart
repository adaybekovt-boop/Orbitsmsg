// Update-checking foundation (auto-update Phase 1).
//
// Pure, testable logic ONLY: read the installed version, fetch the latest
// GitHub release metadata, compare semantic versions correctly, and parse the
// release (notes + assets). This phase does NOT download anything, does NOT
// launch an installer, and does NOT create/delete releases or tags.
//
// Testability: all HTTP is behind an injectable `http.Client`, and the parsing
// + comparison are pure functions, so unit tests are deterministic and offline
// (no live GitHub calls).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

const String tkMessengerLatestReleaseApi =
    'https://api.github.com/repos/adaybekovt-boop/tkmessenger/releases/latest';

/// Full releases list (newest first). Preferred over `/releases/latest` so we
/// can apply release-line filtering: GitHub's "latest" ignores semver lines and
/// could point at a higher minor (e.g. 9.1.0) we don't want to offer 9.0.x users.
const String tkMessengerReleasesApi =
    'https://api.github.com/repos/adaybekovt-boop/tkmessenger/releases?per_page=100';

const String tkMessengerLatestReleasePage =
    'https://github.com/adaybekovt-boop/tkmessenger/releases/latest';

/// Which releases an update check is allowed to offer.
enum ReleaseLinePolicy {
  /// DEFAULT. Only releases on the same `major.minor` line as the installed
  /// version (e.g. a 9.0.2 user is offered 9.0.3 / 9.0.10 but NOT 9.1.0).
  sameMinor,

  /// Any stable release, regardless of line (allows cross-minor upgrades such
  /// as 9.0.x → 9.1.0). Opt-in; wire this when a cross-line bump is intended.
  anyStable,
}

// ─────────────────────────────────────────────────────────────────────
// Semantic version
// ─────────────────────────────────────────────────────────────────────

/// A strict `major.minor.patch` semantic version. Compared NUMERICALLY (never
/// as strings), so `9.0.10 > 9.0.2` and `10.0.0 > 9.9.9`. Build metadata
/// (`+901`) and a leading `v`/`V` are stripped before parsing; a tag that
/// doesn't match `X.Y.Z` is considered unusable (parse returns null).
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
  bool operator ==(Object other) =>
      other is ReleaseVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// Recommended public name for [ReleaseVersion] (the app/release version type).
typedef SemverVersion = ReleaseVersion;
typedef AppVersion = ReleaseVersion;

/// Strip a leading `v`/`V` and any `+build` / `-prerelease` suffix, returning a
/// bare `X.Y.Z`-ish string. Does NOT validate — see [parseReleaseVersion].
String normalizeReleaseVersion(String version) {
  var s = version.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  // Drop build metadata (`+901`) and any pre-release label (`-rc.1`).
  s = s.split('+').first.split('-').first;
  return s;
}

/// Parse a release tag / version into a [ReleaseVersion], or `null` if it isn't
/// a usable `X.Y.Z` semantic version. Accepts `v9.0.1`, `9.0.1`, `9.0.1+901`.
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

// ─────────────────────────────────────────────────────────────────────
// Release / asset models
// ─────────────────────────────────────────────────────────────────────

/// One downloadable asset attached to a GitHub release. Carries metadata only —
/// nothing is downloaded in this phase.
class ReleaseAssetInfo {
  const ReleaseAssetInfo({
    required this.name,
    required this.downloadUrl,
    this.size,
    this.contentType,
  });

  final String name;
  final String downloadUrl;
  final int? size;
  final String? contentType;

  String get _lower => name.toLowerCase();

  bool get isWindowsExe => _lower.endsWith('.exe') && _lower.contains('windows');
  bool get isAndroidApk => _lower.endsWith('.apk');
  bool get isAndroidUniversalApk =>
      isAndroidApk && _lower.contains('android') && _lower.contains('universal');
  bool get isAndroidArm64Apk =>
      isAndroidApk && _lower.contains('android') && _lower.contains('arm64');
  bool get isWebAsset =>
      _lower.contains('web') &&
      (_lower.endsWith('.zip') || _lower.endsWith('.tar.gz'));

  /// Parse a GitHub `assets[]` entry, or `null` if it lacks a usable
  /// name + browser_download_url.
  static ReleaseAssetInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || name.isEmpty || url is! String || url.isEmpty) {
      return null;
    }
    return ReleaseAssetInfo(
      name: name,
      downloadUrl: url,
      size: (json['size'] as num?)?.toInt(),
      contentType: json['content_type'] is String
          ? json['content_type'] as String
          : null,
    );
  }
}

/// Parsed metadata of a GitHub release. [version] is null when the tag isn't a
/// usable semver. [isUsable] is false for drafts, pre-releases, or an
/// unparseable tag — those must NOT be offered as updates.
class GitHubReleaseInfo {
  const GitHubReleaseInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.draft,
    required this.prerelease,
    required this.assets,
    required this.version,
  });

  final String tag;
  final String? name;
  final String? body; // release notes
  final String htmlUrl;
  final bool draft;
  final bool prerelease;
  final List<ReleaseAssetInfo> assets;
  final ReleaseVersion? version;

  bool get isUsable => !draft && !prerelease && version != null;

  ReleaseAssetInfo? get windowsExeAsset =>
      _firstWhere((a) => a.isWindowsExe);
  ReleaseAssetInfo? get androidUniversalApkAsset =>
      _firstWhere((a) => a.isAndroidUniversalApk);
  ReleaseAssetInfo? get androidArm64ApkAsset =>
      _firstWhere((a) => a.isAndroidArm64Apk);
  List<ReleaseAssetInfo> get webAssets =>
      assets.where((a) => a.isWebAsset).toList(growable: false);

  ReleaseAssetInfo? _firstWhere(bool Function(ReleaseAssetInfo) test) {
    for (final a in assets) {
      if (test(a)) return a;
    }
    return null;
  }

  /// Parse a GitHub `releases/latest` response. Returns `null` if `tag_name`
  /// is missing/empty (an unusable response).
  static GitHubReleaseInfo? tryParse(Map<String, Object?> json) {
    final tag = json['tag_name'];
    if (tag is! String || tag.trim().isEmpty) return null;

    final assets = switch (json['assets']) {
      final List<Object?> list => list
          .map(ReleaseAssetInfo.tryParse)
          .whereType<ReleaseAssetInfo>()
          .toList(growable: false),
      _ => const <ReleaseAssetInfo>[],
    };

    final htmlUrl = switch (json['html_url']) {
      final String url when url.isNotEmpty => url,
      _ => tkMessengerLatestReleasePage,
    };

    return GitHubReleaseInfo(
      tag: tag,
      name: json['name'] is String ? json['name'] as String : null,
      body: json['body'] is String ? json['body'] as String : null,
      htmlUrl: htmlUrl,
      draft: json['draft'] == true,
      prerelease: json['prerelease'] == true,
      assets: assets,
      version: parseReleaseVersion(tag),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Result
// ─────────────────────────────────────────────────────────────────────

/// High-level outcome of an update check.
enum UpdateStatus {
  /// Installed version is the latest (or newer). No update.
  upToDate,

  /// A newer, usable release exists.
  updateAvailable,

  /// The check itself failed (network / HTTP / malformed response).
  error,

  /// The latest release exists but is unusable (draft, pre-release, or its
  /// tag isn't a valid semantic version), so no update can be offered.
  latestUnusable,
}

/// Why an update check failed or couldn't be used.
enum UpdateCheckError {
  network,
  http,
  timeout,
  malformedResponse,
  missingTag,
  invalidLatestVersion,
  draftOrPrerelease,
  unknown,
}

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
    this.error,
    this.release,
    this.latestUnusable = false,
    this.checkedAt,
  });

  factory UpdateCheckResult.error({
    required String currentVersion,
    required String message,
    UpdateCheckError error = UpdateCheckError.unknown,
    DateTime? checkedAt,
  }) {
    return UpdateCheckResult(
      currentVersion: currentVersion,
      latestVersion: '',
      latestTag: '',
      releaseUrl: tkMessengerLatestReleasePage,
      isUpdateAvailable: false,
      errorMessage: message,
      error: error,
      checkedAt: checkedAt,
    );
  }

  final String currentVersion;
  final String latestVersion;
  final String latestTag;
  final String releaseUrl;
  final bool isUpdateAvailable;

  /// Convenience asset URLs (back-compat). The full set is in [release].assets.
  final String? windowsAssetUrl;
  final String? androidUniversalAssetUrl;
  final String? androidArm64AssetUrl;

  final String? errorMessage;
  final UpdateCheckError? error;

  /// Full parsed release (notes + assets), when one was fetched. Null on a
  /// transport/parse error.
  final GitHubReleaseInfo? release;

  /// True when the latest release was fetched but can't be offered as an update
  /// (draft / pre-release / invalid tag).
  final bool latestUnusable;

  /// When this check ran (set by [UpdateChecker.check]); null for pure parses.
  final DateTime? checkedAt;

  bool get hasError => errorMessage != null;

  /// Release notes / body of the latest release, if available.
  String? get releaseNotes => release?.body;

  /// All assets attached to the latest release (empty when none/unavailable).
  List<ReleaseAssetInfo> get assets => release?.assets ?? const <ReleaseAssetInfo>[];

  String? get preferredAndroidAssetUrl =>
      androidUniversalAssetUrl ?? androidArm64AssetUrl;

  UpdateStatus get status {
    if (hasError) return UpdateStatus.error;
    if (latestUnusable) return UpdateStatus.latestUnusable;
    return isUpdateAvailable ? UpdateStatus.updateAvailable : UpdateStatus.upToDate;
  }
}

// ─────────────────────────────────────────────────────────────────────
// Checker
// ─────────────────────────────────────────────────────────────────────

/// Read the installed app version (via package_info_plus). Returns the bare
/// `version` (without the `+build` suffix). Not used by the offline unit tests.
Future<String> readInstalledVersion() async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
}

class UpdateChecker {
  UpdateChecker({
    http.Client? client,
    Uri? releasesUri,
    ReleaseLinePolicy linePolicy = ReleaseLinePolicy.sameMinor,
    Duration timeout = const Duration(seconds: 10),
    DateTime Function() now = DateTime.now,
  })  : _client = client ?? http.Client(),
        _releasesUri = releasesUri ?? Uri.parse(tkMessengerReleasesApi),
        _linePolicy = linePolicy,
        _timeout = timeout,
        _now = now;

  final http.Client _client;
  final Uri _releasesUri;
  final ReleaseLinePolicy _linePolicy;
  final Duration _timeout;
  final DateTime Function() _now;

  ReleaseLinePolicy get linePolicy => _linePolicy;

  /// Provider-ready convenience: read the installed version, then check. Does
  /// NOT auto-run at startup and does NOT touch the UI — callers decide when.
  Future<UpdateCheckResult> checkForUpdates() async {
    final current = await readInstalledVersion();
    return check(currentVersion: current);
  }

  Future<UpdateCheckResult> check({required String currentVersion}) async {
    final checkedAt = _now();
    try {
      final response = await _client.get(
        _releasesUri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'TK-Messenger-update-checker',
        },
      ).timeout(_timeout);

      if (response.statusCode != 200) {
        return UpdateCheckResult.error(
          currentVersion: currentVersion,
          message: 'GitHub вернул ${response.statusCode}',
          error: UpdateCheckError.http,
          checkedAt: checkedAt,
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        return UpdateCheckResult.error(
          currentVersion: currentVersion,
          message: 'Некорректный ответ GitHub',
          error: UpdateCheckError.malformedResponse,
          checkedAt: checkedAt,
        );
      }
      // The /releases endpoint returns a JSON array (newest first).
      if (decoded is! List) {
        return UpdateCheckResult.error(
          currentVersion: currentVersion,
          message: 'Некорректный ответ GitHub',
          error: UpdateCheckError.malformedResponse,
          checkedAt: checkedAt,
        );
      }

      return parseGitHubReleases(
        decoded,
        currentVersion: currentVersion,
        checkedAt: checkedAt,
        linePolicy: _linePolicy,
      );
    } on TimeoutException {
      return UpdateCheckResult.error(
        currentVersion: currentVersion,
        message: 'Истекло время ожидания',
        error: UpdateCheckError.timeout,
        checkedAt: checkedAt,
      );
    } catch (error) {
      return UpdateCheckResult.error(
        currentVersion: currentVersion,
        message: error.toString(),
        error: UpdateCheckError.network,
        checkedAt: checkedAt,
      );
    }
  }
}

/// Pure parse of a GitHub `releases/latest` JSON object into an
/// [UpdateCheckResult]. Deterministic + offline (no I/O, no clock unless
/// [checkedAt] is supplied). Drafts / pre-releases / invalid tags are reported
/// as [UpdateStatus.latestUnusable] (never offered as an update); a missing
/// `tag_name` is an error.
UpdateCheckResult parseGitHubRelease(
  Map<String, Object?> json, {
  required String currentVersion,
  DateTime? checkedAt,
}) {
  final release = GitHubReleaseInfo.tryParse(json);
  if (release == null) {
    return UpdateCheckResult.error(
      currentVersion: currentVersion,
      message: 'В релизе нет tag_name',
      error: UpdateCheckError.missingTag,
      checkedAt: checkedAt,
    );
  }

  final normalizedCurrent = normalizeReleaseVersion(currentVersion);
  final latestVersionStr = normalizeReleaseVersion(release.tag);

  final windowsUrl = release.windowsExeAsset?.downloadUrl;
  final androidUniversalUrl = release.androidUniversalApkAsset?.downloadUrl;
  final androidArm64Url = release.androidArm64ApkAsset?.downloadUrl;

  // Drafts / pre-releases / invalid tags: fetched, but NOT offerable.
  if (!release.isUsable) {
    return UpdateCheckResult(
      currentVersion: normalizedCurrent,
      latestVersion: latestVersionStr,
      latestTag: release.tag,
      releaseUrl: release.htmlUrl,
      isUpdateAvailable: false,
      windowsAssetUrl: windowsUrl,
      androidUniversalAssetUrl: androidUniversalUrl,
      androidArm64AssetUrl: androidArm64Url,
      release: release,
      latestUnusable: true,
      checkedAt: checkedAt,
    );
  }

  final current = parseReleaseVersion(currentVersion);
  final latest = release.version; // non-null because isUsable

  final isUpdateAvailable =
      current != null && latest != null && latest.compareTo(current) > 0;

  return UpdateCheckResult(
    currentVersion: normalizedCurrent,
    latestVersion: latestVersionStr,
    latestTag: release.tag,
    releaseUrl: release.htmlUrl,
    isUpdateAvailable: isUpdateAvailable,
    windowsAssetUrl: windowsUrl,
    androidUniversalAssetUrl: androidUniversalUrl,
    androidArm64AssetUrl: androidArm64Url,
    release: release,
    checkedAt: checkedAt,
  );
}

/// Pure selection over a GitHub `/releases` array (the list endpoint). Picks the
/// highest STABLE release (drafts, pre-releases, and unparseable tags are
/// ignored) that the [linePolicy] permits, then compares it to [currentVersion]:
///
///  • [ReleaseLinePolicy.sameMinor] (default) keeps only releases on the same
///    `major.minor` line as the installed version, so a 9.0.2 user is offered
///    9.0.3 / 9.0.10 but never 9.1.0.
///  • [ReleaseLinePolicy.anyStable] considers every stable release.
///
/// If no permitted release exists (empty list, only drafts/pre-releases, or
/// nothing on this line), the user is reported as up to date — never an error.
/// Deterministic + offline (no I/O, no clock unless [checkedAt] is supplied).
UpdateCheckResult parseGitHubReleases(
  List<Object?> releasesJson, {
  required String currentVersion,
  DateTime? checkedAt,
  ReleaseLinePolicy linePolicy = ReleaseLinePolicy.sameMinor,
}) {
  final current = parseReleaseVersion(currentVersion);
  final normalizedCurrent = normalizeReleaseVersion(currentVersion);

  // Keep only usable releases: stable (not draft / not pre-release) with a
  // valid X.Y.Z tag. Everything else is silently skipped.
  final usable = <GitHubReleaseInfo>[];
  for (final entry in releasesJson) {
    if (entry is! Map<String, Object?>) continue;
    final release = GitHubReleaseInfo.tryParse(entry);
    if (release != null && release.isUsable) usable.add(release);
  }

  bool permitted(GitHubReleaseInfo r) {
    if (linePolicy == ReleaseLinePolicy.anyStable) return true;
    // sameMinor: restrict to the installed version's major.minor line. If the
    // installed version is unparseable we can't define a line — don't filter.
    if (current == null) return true;
    final v = r.version!; // non-null: isUsable guarantees it
    return v.major == current.major && v.minor == current.minor;
  }

  // Highest permitted version wins.
  GitHubReleaseInfo? best;
  for (final r in usable) {
    if (!permitted(r)) continue;
    if (best == null || r.version!.compareTo(best.version!) > 0) best = r;
  }

  if (best == null) {
    // Nothing to offer on this line → up to date (within the current line).
    return UpdateCheckResult(
      currentVersion: normalizedCurrent,
      latestVersion: current?.toString() ?? '',
      latestTag: '',
      releaseUrl: tkMessengerLatestReleasePage,
      isUpdateAvailable: false,
      checkedAt: checkedAt,
    );
  }

  final latest = best.version!;
  final isUpdateAvailable = current != null && latest.compareTo(current) > 0;

  return UpdateCheckResult(
    currentVersion: normalizedCurrent,
    latestVersion: normalizeReleaseVersion(best.tag),
    latestTag: best.tag,
    releaseUrl: best.htmlUrl,
    isUpdateAvailable: isUpdateAvailable,
    windowsAssetUrl: best.windowsExeAsset?.downloadUrl,
    androidUniversalAssetUrl: best.androidUniversalApkAsset?.downloadUrl,
    androidArm64AssetUrl: best.androidArm64ApkAsset?.downloadUrl,
    release: best,
    checkedAt: checkedAt,
  );
}
