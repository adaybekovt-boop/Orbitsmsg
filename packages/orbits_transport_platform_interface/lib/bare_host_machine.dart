// Deterministic Bare / worklet host lifecycle. Every OS plugin must
// apply the same rules before talking to a local runtime.

/// Structured host errors. Codes are stable for Flutter ↔ native IPC.
class BareHostException implements Exception {
  BareHostException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BareHostException($code)';
}

const String kBareErrorRemoteJs = 'REMOTE_JS';
const String kBareErrorNotStarted = 'NOT_STARTED';
const String kBareErrorSuspended = 'SUSPENDED';
const String kBareErrorIpcFrame = 'IPC_FRAME';
const String kBareErrorPathRequired = 'PATH_REQUIRED';
const String kBareErrorOversize = 'OVERSIZE';
const String kBareErrorBundleMissing = 'BUNDLE_MISSING';
const String kBareErrorBundleTampered = 'BUNDLE_TAMPERED';
const String kBareErrorAbiMismatch = 'ABI_MISMATCH';
const String kBareErrorMalformed = 'MALFORMED';
const String kBareErrorRuntimeMissing = 'BARE_RUNTIME_MISSING';

const int kBareMaxAttachmentBytes = 50 * 1024 * 1024;
const int kBareIpcMaxFrameBytes = 256 * 1024;

/// Shared state machine for start/publish/send/suspend/stop.
///
/// Production never fetches remote executable JS. Large files move by
/// path only. Crash recovery does not wipe application data.
class BareHostMachine {
  bool started = false;
  bool suspended = false;
  bool published = false;
  bool crashed = false;
  bool ready = false;
  int restartCount = 0;
  int restartBudget = 3;
  Duration startupTimeout = const Duration(seconds: 8);
  String? lastError;
  final List<String> calls = <String>[];

  void start(Map<String, Object?> config) {
    _assertNoRemoteJs(config);
    _assertBundle(config);
    _assertIpcVersion(config);
    calls.add('start');
    started = true;
    ready = true;
    suspended = false;
    crashed = false;
    lastError = null;
  }

  void stop() {
    calls.add('stop');
    started = false;
    ready = false;
    published = false;
    suspended = false;
    crashed = false;
  }

  void publish(Map<String, Object?> binding) {
    _requireStarted();
    if (binding['deviceId'] is! String ||
        (binding['deviceId'] as String).isEmpty) {
      throw BareHostException(kBareErrorMalformed, 'publish needs deviceId');
    }
    calls.add('publish');
    published = true;
  }

  void unpublish() {
    calls.add('unpublish');
    published = false;
  }

  void connect(Map<String, Object?> peer) {
    _requireLive();
    calls.add('connect');
  }

  void disconnect(String peerId) {
    _requireLive();
    calls.add('disconnect');
  }

  void send(String peerId, String channel, List<int> frame) {
    _requireLive();
    if (frame.length > kBareIpcMaxFrameBytes) {
      throw BareHostException(kBareErrorIpcFrame, 'IPC frame exceeds cap');
    }
    calls.add('send');
  }

  void sendFile(String peerId, String path, int sizeBytes) {
    _requireLive();
    if (path.isEmpty) {
      throw BareHostException(
        kBareErrorPathRequired,
        'sendFile requires a path',
      );
    }
    if (sizeBytes > kBareMaxAttachmentBytes) {
      throw BareHostException(
        kBareErrorOversize,
        'attachment exceeds path-transfer cap',
      );
    }
    calls.add('sendFile');
  }

  void suspend() {
    calls.add('suspend');
    suspended = true;
  }

  void resume() {
    calls.add('resume');
    suspended = false;
  }

  void refreshNetwork() {
    _requireLive();
    calls.add('refreshNetwork');
  }

  /// Simulate worklet death. Flutter must call [recover] and must not
  /// treat Drift as dirty.
  void crash() {
    calls.add('crash');
    crashed = true;
    started = false;
    ready = false;
    published = false;
    suspended = false;
    lastError = 'startup_failed';
  }

  void recover(Map<String, Object?> config) {
    calls.add('recover');
    if (restartCount >= restartBudget) {
      throw BareHostException(
        kBareErrorRuntimeMissing,
        'restart budget exceeded',
      );
    }
    restartCount += 1;
    start(config);
  }

  void shutdown() {
    calls.add('shutdown');
    stop();
  }

  void _requireStarted() {
    if (!started) {
      throw BareHostException(kBareErrorNotStarted, 'not started');
    }
  }

  void _requireLive() {
    _requireStarted();
    if (suspended) {
      throw BareHostException(kBareErrorSuspended, 'suspended');
    }
  }

  void _assertNoRemoteJs(Map<String, Object?> config) {
    if (config['remoteJs'] == true) {
      throw BareHostException(
        kBareErrorRemoteJs,
        'production Bare must not fetch remote JS',
      );
    }
    for (final key in const ['remoteJsUrl', 'bundleUrl', 'scriptUrl']) {
      final value = config[key];
      if (value is String &&
          (value.startsWith('http://') || value.startsWith('https://'))) {
        throw BareHostException(
          kBareErrorRemoteJs,
          'production Bare must not fetch remote JS',
        );
      }
    }
  }

  void _assertBundle(Map<String, Object?> config) {
    if (config['requireLocalBundle'] == true &&
        config['localBundlePresent'] != true) {
      throw BareHostException(
        kBareErrorBundleMissing,
        'local Bare bundle missing',
      );
    }
    final expected = config['expectedBundleSha256'];
    final actual = config['localBundleSha256'];
    if (expected is String && actual is String && expected != actual) {
      throw BareHostException(
        kBareErrorBundleTampered,
        'local bundle hash mismatch',
      );
    }
  }

  void _assertIpcVersion(Map<String, Object?> config) {
    final version = config['ipcVersion'];
    if (version is String &&
        version.isNotEmpty &&
        version != 'orbits-bare-ipc-v1') {
      throw BareHostException(kBareErrorAbiMismatch, 'unsupported IPC version');
    }
  }
}
