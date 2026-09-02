// Aggregate, privacy-safe fallback counters. No peer IDs, bodies, or keys.

class FallbackTelemetry {
  int peerjsFallbackCount = 0;
  int hyperswarmFailCount = 0;
  int mailboxDrainCount = 0;

  void recordPeerjsFallback() => peerjsFallbackCount += 1;
  void recordHyperswarmFail() => hyperswarmFailCount += 1;
  void recordMailboxDrain() => mailboxDrainCount += 1;

  Map<String, int> aggregates() => <String, int>{
    'peerjsFallback': peerjsFallbackCount,
    'hyperswarmFail': hyperswarmFailCount,
    'mailboxDrain': mailboxDrainCount,
  };
}

final fallbackTelemetry = FallbackTelemetry();
