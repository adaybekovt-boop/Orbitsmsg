import 'package:orbits_flutter/mailbox/blind_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_capability.dart';
import 'package:orbits_flutter/mailbox/mailbox_grant_store.dart';
import 'package:orbits_flutter/mailbox/mailbox_secret_store.dart';

Future<({MailboxSecretStore secrets, DerivedMailboxCaps caps})>
deriveFreshMailbox() async {
  final secrets = MailboxSecretStore();
  final caps = await secrets.deriveOwn();
  return (secrets: secrets, caps: caps);
}

MailboxCapability registerCaps(
  BlindMailboxStore store,
  DerivedMailboxCaps caps, {
  int quotaBytes = 64 * 1024,
  int retentionMs = 60 * 1000,
  int? expiresAt,
  bool adminOk = true,
}) {
  return store.grant(
    queueId: caps.queueId,
    readCapHash: caps.readCapHashHex,
    depositCapHash: caps.depositCapHashHex,
    quotaBytes: quotaBytes,
    retentionMs: retentionMs,
    expiresAt: expiresAt ?? DateTime.now().millisecondsSinceEpoch + 60 * 1000,
    adminOk: adminOk,
  );
}

void shareGrant(
  MailboxGrantStore grants,
  String peerId,
  DerivedMailboxCaps caps, {
  String? hint,
}) {
  grants.put(
    peerId,
    MailboxGrant(
      queueId: caps.queueId,
      depositCap: caps.depositCap,
      envelopeKey: caps.envelopeKey,
      storagePeerHint: hint,
    ),
  );
}
