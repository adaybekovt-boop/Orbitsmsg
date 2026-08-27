// Owned WebRTC dial (R13).
//
// `Future.timeout` only rejects the wrapper; the inner createOffer /
// setLocalDescription keeps running and used to publish a late OFFER after
// the caller had already given up. [DialAttempt] is the generation token:
// once cancelled, [tryPublish] refuses and [dispose] must run.

import 'dart:async';

class DialAttempt {
  DialAttempt(this.generation);

  final int generation;
  bool cancelled = false;
  bool published = false;
  String? connectionId;

  void cancel({void Function()? dispose}) {
    cancelled = true;
    dispose?.call();
  }

  /// Returns true only when this attempt is still the live one.
  bool tryPublish() {
    if (cancelled) return false;
    published = true;
    return true;
  }
}

/// Run [createOffer] under [timeout]. On timeout the attempt is cancelled
/// and [dispose] runs. A completion that arrives after cancel must not
/// invoke [publishOffer].
Future<T> runOwnedDial<T>({
  required DialAttempt attempt,
  required Future<T> Function() createOffer,
  required void Function(T offer) publishOffer,
  required void Function() dispose,
  required Duration timeout,
}) async {
  final T offer;
  try {
    offer = await createOffer().timeout(timeout);
  } on TimeoutException {
    attempt.cancel(dispose: dispose);
    rethrow;
  } catch (_) {
    attempt.cancel(dispose: dispose);
    rethrow;
  }
  if (!attempt.tryPublish()) {
    dispose();
    throw TimeoutException('dial attempt cancelled');
  }
  publishOffer(offer);
  return offer;
}
