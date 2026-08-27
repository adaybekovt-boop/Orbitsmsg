// Round 5 B.3 + B.4 — DB corruption quarantine and retention sweep.
//
// B.3: a corrupt SQLite file must be quarantined (renamed aside, reported),
// never left in place to poison every later run; healthy/missing files pass.
//
// B.4: runRetentionSweep deletes messages past the retention window, reaps
// orphaned blobs and VACUUMs without throwing; the bundle cache is capped
// with oldest-first eviction.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/key_store.dart';
import 'package:orbits_flutter/core/vault_kek.dart';
import 'package:orbits_flutter/storage/database.dart';
import 'package:orbits_flutter/storage/db.dart' as db;
import 'package:orbits_flutter/storage/db_health.dart';
import 'package:orbits_flutter/storage/drift_key_store.dart';
import 'package:orbits_flutter/core/bundle_cache.dart'
    show kMaxCachedBundles, pruneCachedBundles;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('orbits_dbhealth');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('B.3 ensureDatabaseHealthy', () {
    test('missing file → ok/missing', () async {
      final r = await ensureDatabaseHealthy(directory: tmp.path);
      expect(r.status, DbHealthStatus.missing);
    });

    test('healthy database → ok', () async {
      final f = File('${tmp.path}/orbits.sqlite');
      final raw = sqlite3.sqlite3.open(f.path);
      raw.execute('CREATE TABLE t (x);');
      raw.dispose();

      final r = await ensureDatabaseHealthy(directory: tmp.path);
      expect(r.status, DbHealthStatus.ok);
      expect(f.existsSync(), isTrue, reason: 'healthy file untouched');
    });

    test('busy/locked healthy file is not quarantined', () async {
      final f = File('${tmp.path}/orbits.sqlite');
      final hold = sqlite3.sqlite3.open(f.path);
      hold.execute('CREATE TABLE t (x);');
      hold.execute('BEGIN EXCLUSIVE;');
      try {
        final r = await ensureDatabaseHealthy(directory: tmp.path);
        expect(r.status, isNot(DbHealthStatus.quarantined),
            reason: 'lock/busy must not move a healthy file');
        expect(f.existsSync(), isTrue);
        expect(
          r.status,
          anyOf(DbHealthStatus.ok, DbHealthStatus.unavailable),
        );
      } finally {
        try {
          hold.execute('COMMIT;');
        } catch (_) {}
        hold.dispose();
      }
    });

    test('permission / I/O errors do not quarantine', () async {
      expect(isTransientDbHealthError('SqliteException: database is locked'),
          isTrue);
      expect(isTransientDbHealthError('SqliteException(5): database is busy'),
          isTrue);
      expect(isTransientDbHealthError('error 8: attempt to write a readonly'),
          isTrue);
      expect(isTransientDbHealthError('PathAccessException: Permission denied'),
          isTrue);
      expect(isTransientDbHealthError('Input/output error'), isTrue);
      expect(isConfirmedDbCorruption('file is not a database'), isTrue);
      expect(
        isConfirmedDbCorruption(null, quickCheck: '*** in database main'),
        isTrue,
      );
      expect(
        isConfirmedDbCorruption('database is locked', quickCheck: null),
        isFalse,
      );

      final f = File('${tmp.path}/orbits.sqlite');
      final raw = sqlite3.sqlite3.open(f.path);
      raw.execute('CREATE TABLE t (x);');
      raw.dispose();
      await Process.run('chmod', ['000', f.path]);
      try {
        final r = await ensureDatabaseHealthy(directory: tmp.path);
        expect(r.status, isNot(DbHealthStatus.quarantined));
        expect(f.existsSync(), isTrue);
      } finally {
        await Process.run('chmod', ['644', f.path]);
      }
    });

    test('corrupt file is quarantined, not deleted, and reported', () async {
      // Real SQLite header + garbage body — opens as SQLite but fails
      // integrity checks / reads.
      final f = File('${tmp.path}/orbits.sqlite');
      final bytes = <int>[ ...utf8Header, ...List<int>.filled(4096, 0xFF) ];
      f.writeAsBytesSync(bytes);

      final r = await ensureDatabaseHealthy(directory: tmp.path);
      expect(r.status, DbHealthStatus.quarantined);
      expect(r.quarantinePath, isNotNull);
      expect(File(r.quarantinePath!).existsSync(), isTrue,
          reason: 'quarantined file preserved for forensics');
      expect(f.existsSync(), isFalse,
          reason: 'original path freed so Drift can recreate');
      expect(lastDatabaseHealthCheck?.status, DbHealthStatus.quarantined);
    });
  });

  group('B.4 retention sweep', () {
    late OrbitsDatabase database;
    setUp(() async {
      database = OrbitsDatabase.forTesting(NativeDatabase.memory());
      setOrbitsDatabase(database);
      await setVaultKek(List<int>.generate(32, (i) => i * 9 & 0xff));
    });
    tearDown(() async {
      clearVaultKek();
      setOrbitsDatabase(database);
      await closeOrbitsDatabase();
    });

    test('old messages deleted, recent kept, VACUUM does not throw',
        () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await db.saveMessage({
        'id': 'm-old',
        'peerId': 'ORBIT-11AA22BB33CC44DD',
        'timestamp': nowMs - const Duration(days: 120).inMilliseconds,
        'direction': 'in',
        'status': 'delivered',
        'payload': {'type': 'text', 'text': 'ancient'},
      });
      await db.saveMessage({
        'id': 'm-new',
        'peerId': 'ORBIT-11AA22BB33CC44DD',
        'timestamp': nowMs - const Duration(days: 10).inMilliseconds,
        'direction': 'in',
        'status': 'delivered',
        'payload': {'type': 'text', 'text': 'fresh'},
      });

      await db.runRetentionSweep(retention: const Duration(days: 90));

      expect(await db.getMessageById('m-old'), isNull,
          reason: 'past-retention messages must be pruned');
      expect(await db.getMessageById('m-new'), isNotNull,
          reason: 'recent history must survive');
    });
  });

  group('B.4 bundle cache quota', () {
    late OrbitsDatabase database;
    setUp(() async {
      database = OrbitsDatabase.forTesting(NativeDatabase.memory());
      setOrbitsDatabase(database);
      await setVaultKek(List<int>.generate(32, (i) => i * 5 & 0xff));
      installDriftKeyStore(database: database);
    });
    tearDown(() async {
      clearVaultKek();
      setOrbitsDatabase(database);
      await closeOrbitsDatabase();
    });

    test('evicts oldest past the cap, keeps newest', () async {
      // Seed cap+20 bundle rows directly through the key store.
      for (var i = 0; i < kMaxCachedBundles + 20; i++) {
        await keyStore().put('keys', {
          'id': 'peer-bundle-ORBIT-A${i.toString().padLeft(15, '0')}',
          'peerId': 'ORBIT-A${i.toString().padLeft(15, '0')}',
          'fingerprint': 'fp$i',
          'storedAt': 1_000_000 + i,
        });
      }
      final evicted = await pruneCachedBundles();
      expect(evicted, 20);
      final remaining = await keyStore().getAll('keys');
      final bundles = remaining
          .where((r) => (r['id'] as String).startsWith('peer-bundle-'))
          .toList();
      expect(bundles.length, kMaxCachedBundles);
      // Oldest evicted: storedAt=1000000 row gone; newest survives.
      final storedAts = bundles.map((b) => b['storedAt'] as int).toList()..sort();
      expect(storedAts.first, 1_000_000 + 20);
    });

    test('under the cap → no-op', () async {
      for (var i = 0; i < 5; i++) {
        await keyStore().put('keys', {
          'id': 'peer-bundle-P$i',
          'peerId': 'P$i',
          'storedAt': i,
        });
      }
      expect(await pruneCachedBundles(), 0);
    });
  });
}

const utf8Header = <int>[
  0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61,
  0x74, 0x20, 0x33, 0x00, // "SQLite format 3\0"
];
