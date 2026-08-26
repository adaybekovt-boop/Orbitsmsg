// Lost-inbound ledger (audit Round 5 B.5).
//
// While the vault is locked, encrypted row writes fail closed
// (`wrapBlobSync` throws). Historically `_persistBestEffort` swallowed that
// error with a debug-only print — so messages arriving while the app was
// auto-locked vanished WITHOUT A TRACE, and the chat looked empty.
//
// The ledger makes every such loss observable:
//   • increments a counter (surfaced via MessagingState.lostInboundCount so
//     the UI can show "messages arrived while locked — reconnecting");
//   • emits a structured payload through error_reporter — visible in
//     release builds too, not just kDebugMode.

import '../core/error_reporter.dart';

typedef ReportFn = void Function(Object? error, [Map<String, Object?>? extra]);

class LostInboundLedger {
  LostInboundLedger({ReportFn? report})
      : _report = report ?? reportError;

  final ReportFn _report;

  /// How many inbound messages have been dropped since session start.
  int get drops => _drops;
  int _drops = 0;

  /// Record one lost inbound message and report it loudly (release too).
  void recordDrop({
    required String msgId,
    required Object error,
    required String fromPeer,
  }) {
    _drops++;
    _report(
      StateError(
        'inbound message LOST: persist failed (vault locked or DB write '
        'failed). The sender believes it was delivered.',
      ),
      <String, Object?>{
        'source': 'messaging.inbound.drop',
        'msgId': msgId,
        'from': fromPeer,
        'error': error.toString(),
      },
    );
  }

  /// Reset on logout / account switch.
  void reset() => _drops = 0;
}
