// Security event log (Phase 5) — an audit trail of peer connections + fraud
// findings, persisted in the Drift DB so it survives a restart.
//
// NOTE on storage: the spec called for a dedicated `SecurityLogsTable`. Adding
// a new Drift table requires a build_runner codegen pass, which fails on this
// project's non-ASCII ("Проекты") path — a known environment blocker (the AOT
// snapshot writer + package-root detection choke on the Cyrillic path; see
// MEMORY.md). To keep the feature functional without that blocked codegen
// step, the log is stored as a capped JSON list in the existing Drift `kv`
// table (via idb_store). The per-entry shape — {peerId, ipAddress, timestamp,
// eventType} — matches the intended columns 1:1, so promoting it to a real
// table once codegen is unblocked is a drop-in change.

import 'dart:convert';

import 'idb_store.dart';

const String _kSecurityLogKey = 'orbits_security_log';
const int _kMaxEntries = 200;

class SecurityLogEntry {
  const SecurityLogEntry({
    required this.peerId,
    required this.ipAddress,
    required this.timestamp,
    required this.eventType,
  });

  final String peerId;
  final String ipAddress;
  final int timestamp;
  final String eventType;

  Map<String, Object?> toJson() => {
        'peerId': peerId,
        'ipAddress': ipAddress,
        'timestamp': timestamp,
        'eventType': eventType,
      };

  static SecurityLogEntry fromJson(Map<String, Object?> m) => SecurityLogEntry(
        peerId: (m['peerId'] as String?) ?? '',
        ipAddress: (m['ipAddress'] as String?) ?? '',
        timestamp: (m['timestamp'] as num?)?.toInt() ?? 0,
        eventType: (m['eventType'] as String?) ?? '',
      );
}

/// Append [entry] to the audit log (capped at [_kMaxEntries], oldest dropped).
Future<void> appendSecurityLog(SecurityLogEntry entry) async {
  final list = await getSecurityLogs();
  list.add(entry);
  final capped =
      list.length > _kMaxEntries ? list.sublist(list.length - _kMaxEntries) : list;
  final encoded = jsonEncode([for (final e in capped) e.toJson()]);
  await idbSetString(_kSecurityLogKey, encoded);
}

/// The full security audit trail, oldest-first.
Future<List<SecurityLogEntry>> getSecurityLogs() async {
  final raw = await idbGetString(_kSecurityLogKey);
  if (raw == null || raw.isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return [
      for (final e in decoded)
        if (e is Map) SecurityLogEntry.fromJson(Map<String, Object?>.from(e)),
    ];
  } catch (_) {
    return [];
  }
}

Future<void> clearSecurityLogs() => idbDel(_kSecurityLogKey);
