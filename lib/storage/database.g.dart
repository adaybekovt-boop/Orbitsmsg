// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $KeysTableTable extends KeysTable
    with TableInfo<$KeysTableTable, KeyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeysTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<KeyRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  KeyRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $KeysTableTable createAlias(String alias) {
    return $KeysTableTable(attachedDatabase, alias);
  }
}

class KeyRow extends DataClass implements Insertable<KeyRow> {
  final String id;
  final Uint8List data;
  const KeyRow({required this.id, required this.data});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  KeysTableCompanion toCompanion(bool nullToAbsent) {
    return KeysTableCompanion(id: Value(id), data: Value(data));
  }

  factory KeyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyRow(
      id: serializer.fromJson<String>(json['id']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  KeyRow copyWith({String? id, Uint8List? data}) =>
      KeyRow(id: id ?? this.id, data: data ?? this.data);
  KeyRow copyWithCompanion(KeysTableCompanion data) {
    return KeyRow(
      id: data.id.present ? data.id.value : this.id,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyRow(')
          ..write('id: $id, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyRow &&
          other.id == this.id &&
          $driftBlobEquality.equals(other.data, this.data));
}

class KeysTableCompanion extends UpdateCompanion<KeyRow> {
  final Value<String> id;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const KeysTableCompanion({
    this.id = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeysTableCompanion.insert({
    required String id,
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       data = Value(data);
  static Insertable<KeyRow> custom({
    Expression<String>? id,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeysTableCompanion copyWith({
    Value<String>? id,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return KeysTableCompanion(
      id: id ?? this.id,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeysTableCompanion(')
          ..write('id: $id, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PrekeysTableTable extends PrekeysTable
    with TableInfo<$PrekeysTableTable, PrekeyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PrekeysTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 8,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usedMeta = const VerificationMeta('used');
  @override
  late final GeneratedColumn<int> used = GeneratedColumn<int>(
    'used',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, kind, used, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'prekeys';
  @override
  VerificationContext validateIntegrity(
    Insertable<PrekeyRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('used')) {
      context.handle(
        _usedMeta,
        used.isAcceptableOrUnknown(data['used']!, _usedMeta),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PrekeyRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PrekeyRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      used: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}used'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $PrekeysTableTable createAlias(String alias) {
    return $PrekeysTableTable(attachedDatabase, alias);
  }
}

class PrekeyRow extends DataClass implements Insertable<PrekeyRow> {
  final String id;
  final String kind;
  final int used;
  final Uint8List data;
  const PrekeyRow({
    required this.id,
    required this.kind,
    required this.used,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['used'] = Variable<int>(used);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  PrekeysTableCompanion toCompanion(bool nullToAbsent) {
    return PrekeysTableCompanion(
      id: Value(id),
      kind: Value(kind),
      used: Value(used),
      data: Value(data),
    );
  }

  factory PrekeyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PrekeyRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      used: serializer.fromJson<int>(json['used']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'used': serializer.toJson<int>(used),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  PrekeyRow copyWith({String? id, String? kind, int? used, Uint8List? data}) =>
      PrekeyRow(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        used: used ?? this.used,
        data: data ?? this.data,
      );
  PrekeyRow copyWithCompanion(PrekeysTableCompanion data) {
    return PrekeyRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      used: data.used.present ? data.used.value : this.used,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PrekeyRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('used: $used, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, kind, used, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PrekeyRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.used == this.used &&
          $driftBlobEquality.equals(other.data, this.data));
}

class PrekeysTableCompanion extends UpdateCompanion<PrekeyRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<int> used;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const PrekeysTableCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.used = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PrekeysTableCompanion.insert({
    required String id,
    required String kind,
    this.used = const Value.absent(),
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       data = Value(data);
  static Insertable<PrekeyRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<int>? used,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (used != null) 'used': used,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PrekeysTableCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<int>? used,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return PrekeysTableCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      used: used ?? this.used,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (used.present) {
      map['used'] = Variable<int>(used.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PrekeysTableCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('used: $used, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RatchetsTableTable extends RatchetsTable
    with TableInfo<$RatchetsTableTable, RatchetRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RatchetsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
    'peer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, peerId, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ratchets';
  @override
  VerificationContext validateIntegrity(
    Insertable<RatchetRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(
        _peerIdMeta,
        peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RatchetRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RatchetRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      peerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_id'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $RatchetsTableTable createAlias(String alias) {
    return $RatchetsTableTable(attachedDatabase, alias);
  }
}

class RatchetRow extends DataClass implements Insertable<RatchetRow> {
  final String id;
  final String peerId;
  final Uint8List data;
  const RatchetRow({
    required this.id,
    required this.peerId,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  RatchetsTableCompanion toCompanion(bool nullToAbsent) {
    return RatchetsTableCompanion(
      id: Value(id),
      peerId: Value(peerId),
      data: Value(data),
    );
  }

  factory RatchetRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RatchetRow(
      id: serializer.fromJson<String>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'peerId': serializer.toJson<String>(peerId),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  RatchetRow copyWith({String? id, String? peerId, Uint8List? data}) =>
      RatchetRow(
        id: id ?? this.id,
        peerId: peerId ?? this.peerId,
        data: data ?? this.data,
      );
  RatchetRow copyWithCompanion(RatchetsTableCompanion data) {
    return RatchetRow(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RatchetRow(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, peerId, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RatchetRow &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          $driftBlobEquality.equals(other.data, this.data));
}

class RatchetsTableCompanion extends UpdateCompanion<RatchetRow> {
  final Value<String> id;
  final Value<String> peerId;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const RatchetsTableCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RatchetsTableCompanion.insert({
    required String id,
    required String peerId,
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       peerId = Value(peerId),
       data = Value(data);
  static Insertable<RatchetRow> custom({
    Expression<String>? id,
    Expression<String>? peerId,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RatchetsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? peerId,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return RatchetsTableCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RatchetsTableCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PeersTableTable extends PeersTable
    with TableInfo<$PeersTableTable, PeerRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PeersTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lastSeenAtMeta = const VerificationMeta(
    'lastSeenAt',
  );
  @override
  late final GeneratedColumn<int> lastSeenAt = GeneratedColumn<int>(
    'last_seen_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _trustedMeta = const VerificationMeta(
    'trusted',
  );
  @override
  late final GeneratedColumn<int> trusted = GeneratedColumn<int>(
    'trusted',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _trustLevelMeta = const VerificationMeta(
    'trustLevel',
  );
  @override
  late final GeneratedColumn<int> trustLevel = GeneratedColumn<int>(
    'trust_level',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _blockedMeta = const VerificationMeta(
    'blocked',
  );
  @override
  late final GeneratedColumn<int> blocked = GeneratedColumn<int>(
    'blocked',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastReadAtMeta = const VerificationMeta(
    'lastReadAt',
  );
  @override
  late final GeneratedColumn<int> lastReadAt = GeneratedColumn<int>(
    'last_read_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    displayName,
    lastSeenAt,
    trusted,
    trustLevel,
    addedAt,
    blocked,
    lastReadAt,
    data,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'peers';
  @override
  VerificationContext validateIntegrity(
    Insertable<PeerRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('last_seen_at')) {
      context.handle(
        _lastSeenAtMeta,
        lastSeenAt.isAcceptableOrUnknown(
          data['last_seen_at']!,
          _lastSeenAtMeta,
        ),
      );
    }
    if (data.containsKey('trusted')) {
      context.handle(
        _trustedMeta,
        trusted.isAcceptableOrUnknown(data['trusted']!, _trustedMeta),
      );
    }
    if (data.containsKey('trust_level')) {
      context.handle(
        _trustLevelMeta,
        trustLevel.isAcceptableOrUnknown(data['trust_level']!, _trustLevelMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    }
    if (data.containsKey('blocked')) {
      context.handle(
        _blockedMeta,
        blocked.isAcceptableOrUnknown(data['blocked']!, _blockedMeta),
      );
    }
    if (data.containsKey('last_read_at')) {
      context.handle(
        _lastReadAtMeta,
        lastReadAt.isAcceptableOrUnknown(
          data['last_read_at']!,
          _lastReadAtMeta,
        ),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PeerRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PeerRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      lastSeenAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_seen_at'],
      )!,
      trusted: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}trusted'],
      )!,
      trustLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}trust_level'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
      blocked: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}blocked'],
      )!,
      lastReadAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_read_at'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $PeersTableTable createAlias(String alias) {
    return $PeersTableTable(attachedDatabase, alias);
  }
}

class PeerRow extends DataClass implements Insertable<PeerRow> {
  final String id;
  final String displayName;
  final int lastSeenAt;
  final int trusted;
  final int trustLevel;
  final int addedAt;
  final int blocked;
  final int lastReadAt;
  final Uint8List data;
  const PeerRow({
    required this.id,
    required this.displayName,
    required this.lastSeenAt,
    required this.trusted,
    required this.trustLevel,
    required this.addedAt,
    required this.blocked,
    required this.lastReadAt,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    map['last_seen_at'] = Variable<int>(lastSeenAt);
    map['trusted'] = Variable<int>(trusted);
    map['trust_level'] = Variable<int>(trustLevel);
    map['added_at'] = Variable<int>(addedAt);
    map['blocked'] = Variable<int>(blocked);
    map['last_read_at'] = Variable<int>(lastReadAt);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  PeersTableCompanion toCompanion(bool nullToAbsent) {
    return PeersTableCompanion(
      id: Value(id),
      displayName: Value(displayName),
      lastSeenAt: Value(lastSeenAt),
      trusted: Value(trusted),
      trustLevel: Value(trustLevel),
      addedAt: Value(addedAt),
      blocked: Value(blocked),
      lastReadAt: Value(lastReadAt),
      data: Value(data),
    );
  }

  factory PeerRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PeerRow(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      lastSeenAt: serializer.fromJson<int>(json['lastSeenAt']),
      trusted: serializer.fromJson<int>(json['trusted']),
      trustLevel: serializer.fromJson<int>(json['trustLevel']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
      blocked: serializer.fromJson<int>(json['blocked']),
      lastReadAt: serializer.fromJson<int>(json['lastReadAt']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'lastSeenAt': serializer.toJson<int>(lastSeenAt),
      'trusted': serializer.toJson<int>(trusted),
      'trustLevel': serializer.toJson<int>(trustLevel),
      'addedAt': serializer.toJson<int>(addedAt),
      'blocked': serializer.toJson<int>(blocked),
      'lastReadAt': serializer.toJson<int>(lastReadAt),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  PeerRow copyWith({
    String? id,
    String? displayName,
    int? lastSeenAt,
    int? trusted,
    int? trustLevel,
    int? addedAt,
    int? blocked,
    int? lastReadAt,
    Uint8List? data,
  }) => PeerRow(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    trusted: trusted ?? this.trusted,
    trustLevel: trustLevel ?? this.trustLevel,
    addedAt: addedAt ?? this.addedAt,
    blocked: blocked ?? this.blocked,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    data: data ?? this.data,
  );
  PeerRow copyWithCompanion(PeersTableCompanion data) {
    return PeerRow(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      lastSeenAt: data.lastSeenAt.present
          ? data.lastSeenAt.value
          : this.lastSeenAt,
      trusted: data.trusted.present ? data.trusted.value : this.trusted,
      trustLevel: data.trustLevel.present
          ? data.trustLevel.value
          : this.trustLevel,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      blocked: data.blocked.present ? data.blocked.value : this.blocked,
      lastReadAt: data.lastReadAt.present
          ? data.lastReadAt.value
          : this.lastReadAt,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PeerRow(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('trusted: $trusted, ')
          ..write('trustLevel: $trustLevel, ')
          ..write('addedAt: $addedAt, ')
          ..write('blocked: $blocked, ')
          ..write('lastReadAt: $lastReadAt, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    lastSeenAt,
    trusted,
    trustLevel,
    addedAt,
    blocked,
    lastReadAt,
    $driftBlobEquality.hash(data),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerRow &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.lastSeenAt == this.lastSeenAt &&
          other.trusted == this.trusted &&
          other.trustLevel == this.trustLevel &&
          other.addedAt == this.addedAt &&
          other.blocked == this.blocked &&
          other.lastReadAt == this.lastReadAt &&
          $driftBlobEquality.equals(other.data, this.data));
}

class PeersTableCompanion extends UpdateCompanion<PeerRow> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<int> lastSeenAt;
  final Value<int> trusted;
  final Value<int> trustLevel;
  final Value<int> addedAt;
  final Value<int> blocked;
  final Value<int> lastReadAt;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const PeersTableCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.trusted = const Value.absent(),
    this.trustLevel = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.blocked = const Value.absent(),
    this.lastReadAt = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PeersTableCompanion.insert({
    required String id,
    this.displayName = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.trusted = const Value.absent(),
    this.trustLevel = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.blocked = const Value.absent(),
    this.lastReadAt = const Value.absent(),
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       data = Value(data);
  static Insertable<PeerRow> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<int>? lastSeenAt,
    Expression<int>? trusted,
    Expression<int>? trustLevel,
    Expression<int>? addedAt,
    Expression<int>? blocked,
    Expression<int>? lastReadAt,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (lastSeenAt != null) 'last_seen_at': lastSeenAt,
      if (trusted != null) 'trusted': trusted,
      if (trustLevel != null) 'trust_level': trustLevel,
      if (addedAt != null) 'added_at': addedAt,
      if (blocked != null) 'blocked': blocked,
      if (lastReadAt != null) 'last_read_at': lastReadAt,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PeersTableCompanion copyWith({
    Value<String>? id,
    Value<String>? displayName,
    Value<int>? lastSeenAt,
    Value<int>? trusted,
    Value<int>? trustLevel,
    Value<int>? addedAt,
    Value<int>? blocked,
    Value<int>? lastReadAt,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return PeersTableCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      trusted: trusted ?? this.trusted,
      trustLevel: trustLevel ?? this.trustLevel,
      addedAt: addedAt ?? this.addedAt,
      blocked: blocked ?? this.blocked,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (lastSeenAt.present) {
      map['last_seen_at'] = Variable<int>(lastSeenAt.value);
    }
    if (trusted.present) {
      map['trusted'] = Variable<int>(trusted.value);
    }
    if (trustLevel.present) {
      map['trust_level'] = Variable<int>(trustLevel.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (blocked.present) {
      map['blocked'] = Variable<int>(blocked.value);
    }
    if (lastReadAt.present) {
      map['last_read_at'] = Variable<int>(lastReadAt.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PeersTableCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('trusted: $trusted, ')
          ..write('trustLevel: $trustLevel, ')
          ..write('addedAt: $addedAt, ')
          ..write('blocked: $blocked, ')
          ..write('lastReadAt: $lastReadAt, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AvatarsTableTable extends AvatarsTable
    with TableInfo<$AvatarsTableTable, AvatarRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AvatarsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
    'peer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [peerId, updatedAt, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'avatars';
  @override
  VerificationContext validateIntegrity(
    Insertable<AvatarRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('peer_id')) {
      context.handle(
        _peerIdMeta,
        peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {peerId};
  @override
  AvatarRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AvatarRow(
      peerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_id'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $AvatarsTableTable createAlias(String alias) {
    return $AvatarsTableTable(attachedDatabase, alias);
  }
}

class AvatarRow extends DataClass implements Insertable<AvatarRow> {
  final String peerId;
  final int updatedAt;
  final Uint8List data;
  const AvatarRow({
    required this.peerId,
    required this.updatedAt,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['peer_id'] = Variable<String>(peerId);
    map['updated_at'] = Variable<int>(updatedAt);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  AvatarsTableCompanion toCompanion(bool nullToAbsent) {
    return AvatarsTableCompanion(
      peerId: Value(peerId),
      updatedAt: Value(updatedAt),
      data: Value(data),
    );
  }

  factory AvatarRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AvatarRow(
      peerId: serializer.fromJson<String>(json['peerId']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'peerId': serializer.toJson<String>(peerId),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  AvatarRow copyWith({String? peerId, int? updatedAt, Uint8List? data}) =>
      AvatarRow(
        peerId: peerId ?? this.peerId,
        updatedAt: updatedAt ?? this.updatedAt,
        data: data ?? this.data,
      );
  AvatarRow copyWithCompanion(AvatarsTableCompanion data) {
    return AvatarRow(
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AvatarRow(')
          ..write('peerId: $peerId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(peerId, updatedAt, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AvatarRow &&
          other.peerId == this.peerId &&
          other.updatedAt == this.updatedAt &&
          $driftBlobEquality.equals(other.data, this.data));
}

class AvatarsTableCompanion extends UpdateCompanion<AvatarRow> {
  final Value<String> peerId;
  final Value<int> updatedAt;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const AvatarsTableCompanion({
    this.peerId = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AvatarsTableCompanion.insert({
    required String peerId,
    this.updatedAt = const Value.absent(),
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : peerId = Value(peerId),
       data = Value(data);
  static Insertable<AvatarRow> custom({
    Expression<String>? peerId,
    Expression<int>? updatedAt,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (peerId != null) 'peer_id': peerId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AvatarsTableCompanion copyWith({
    Value<String>? peerId,
    Value<int>? updatedAt,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return AvatarsTableCompanion(
      peerId: peerId ?? this.peerId,
      updatedAt: updatedAt ?? this.updatedAt,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AvatarsTableCompanion(')
          ..write('peerId: $peerId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SessionKeysTableTable extends SessionKeysTable
    with TableInfo<$SessionKeysTableTable, SessionKeyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SessionKeysTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
    'peer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, peerId, updatedAt, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'session_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SessionKeyRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(
        _peerIdMeta,
        peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SessionKeyRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SessionKeyRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      peerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_id'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $SessionKeysTableTable createAlias(String alias) {
    return $SessionKeysTableTable(attachedDatabase, alias);
  }
}

class SessionKeyRow extends DataClass implements Insertable<SessionKeyRow> {
  final String id;
  final String peerId;
  final int updatedAt;
  final Uint8List data;
  const SessionKeyRow({
    required this.id,
    required this.peerId,
    required this.updatedAt,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['updated_at'] = Variable<int>(updatedAt);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  SessionKeysTableCompanion toCompanion(bool nullToAbsent) {
    return SessionKeysTableCompanion(
      id: Value(id),
      peerId: Value(peerId),
      updatedAt: Value(updatedAt),
      data: Value(data),
    );
  }

  factory SessionKeyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SessionKeyRow(
      id: serializer.fromJson<String>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'peerId': serializer.toJson<String>(peerId),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  SessionKeyRow copyWith({
    String? id,
    String? peerId,
    int? updatedAt,
    Uint8List? data,
  }) => SessionKeyRow(
    id: id ?? this.id,
    peerId: peerId ?? this.peerId,
    updatedAt: updatedAt ?? this.updatedAt,
    data: data ?? this.data,
  );
  SessionKeyRow copyWithCompanion(SessionKeysTableCompanion data) {
    return SessionKeyRow(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SessionKeyRow(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, peerId, updatedAt, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SessionKeyRow &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          other.updatedAt == this.updatedAt &&
          $driftBlobEquality.equals(other.data, this.data));
}

class SessionKeysTableCompanion extends UpdateCompanion<SessionKeyRow> {
  final Value<String> id;
  final Value<String> peerId;
  final Value<int> updatedAt;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const SessionKeysTableCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SessionKeysTableCompanion.insert({
    required String id,
    required String peerId,
    this.updatedAt = const Value.absent(),
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       peerId = Value(peerId),
       data = Value(data);
  static Insertable<SessionKeyRow> custom({
    Expression<String>? id,
    Expression<String>? peerId,
    Expression<int>? updatedAt,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SessionKeysTableCompanion copyWith({
    Value<String>? id,
    Value<String>? peerId,
    Value<int>? updatedAt,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return SessionKeysTableCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      updatedAt: updatedAt ?? this.updatedAt,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionKeysTableCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RoomsTableTable extends RoomsTable
    with TableInfo<$RoomsTableTable, RoomRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RoomsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _hostPeerIdMeta = const VerificationMeta(
    'hostPeerId',
  );
  @override
  late final GeneratedColumn<String> hostPeerId = GeneratedColumn<String>(
    'host_peer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isHostMeta = const VerificationMeta('isHost');
  @override
  late final GeneratedColumn<bool> isHost = GeneratedColumn<bool>(
    'is_host',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_host" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('active'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    hostPeerId,
    isHost,
    createdAt,
    status,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'rooms';
  @override
  VerificationContext validateIntegrity(
    Insertable<RoomRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('host_peer_id')) {
      context.handle(
        _hostPeerIdMeta,
        hostPeerId.isAcceptableOrUnknown(
          data['host_peer_id']!,
          _hostPeerIdMeta,
        ),
      );
    }
    if (data.containsKey('is_host')) {
      context.handle(
        _isHostMeta,
        isHost.isAcceptableOrUnknown(data['is_host']!, _isHostMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RoomRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RoomRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      hostPeerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host_peer_id'],
      )!,
      isHost: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_host'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
    );
  }

  @override
  $RoomsTableTable createAlias(String alias) {
    return $RoomsTableTable(attachedDatabase, alias);
  }
}

class RoomRow extends DataClass implements Insertable<RoomRow> {
  final String id;
  final String name;
  final String hostPeerId;
  final bool isHost;
  final int createdAt;

  /// 'active' | 'offline'.
  final String status;
  const RoomRow({
    required this.id,
    required this.name,
    required this.hostPeerId,
    required this.isHost,
    required this.createdAt,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['host_peer_id'] = Variable<String>(hostPeerId);
    map['is_host'] = Variable<bool>(isHost);
    map['created_at'] = Variable<int>(createdAt);
    map['status'] = Variable<String>(status);
    return map;
  }

  RoomsTableCompanion toCompanion(bool nullToAbsent) {
    return RoomsTableCompanion(
      id: Value(id),
      name: Value(name),
      hostPeerId: Value(hostPeerId),
      isHost: Value(isHost),
      createdAt: Value(createdAt),
      status: Value(status),
    );
  }

  factory RoomRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RoomRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      hostPeerId: serializer.fromJson<String>(json['hostPeerId']),
      isHost: serializer.fromJson<bool>(json['isHost']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      status: serializer.fromJson<String>(json['status']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'hostPeerId': serializer.toJson<String>(hostPeerId),
      'isHost': serializer.toJson<bool>(isHost),
      'createdAt': serializer.toJson<int>(createdAt),
      'status': serializer.toJson<String>(status),
    };
  }

  RoomRow copyWith({
    String? id,
    String? name,
    String? hostPeerId,
    bool? isHost,
    int? createdAt,
    String? status,
  }) => RoomRow(
    id: id ?? this.id,
    name: name ?? this.name,
    hostPeerId: hostPeerId ?? this.hostPeerId,
    isHost: isHost ?? this.isHost,
    createdAt: createdAt ?? this.createdAt,
    status: status ?? this.status,
  );
  RoomRow copyWithCompanion(RoomsTableCompanion data) {
    return RoomRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      hostPeerId: data.hostPeerId.present
          ? data.hostPeerId.value
          : this.hostPeerId,
      isHost: data.isHost.present ? data.isHost.value : this.isHost,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RoomRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('hostPeerId: $hostPeerId, ')
          ..write('isHost: $isHost, ')
          ..write('createdAt: $createdAt, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, hostPeerId, isHost, createdAt, status);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RoomRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.hostPeerId == this.hostPeerId &&
          other.isHost == this.isHost &&
          other.createdAt == this.createdAt &&
          other.status == this.status);
}

class RoomsTableCompanion extends UpdateCompanion<RoomRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> hostPeerId;
  final Value<bool> isHost;
  final Value<int> createdAt;
  final Value<String> status;
  final Value<int> rowid;
  const RoomsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.hostPeerId = const Value.absent(),
    this.isHost = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RoomsTableCompanion.insert({
    required String id,
    this.name = const Value.absent(),
    this.hostPeerId = const Value.absent(),
    this.isHost = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id);
  static Insertable<RoomRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? hostPeerId,
    Expression<bool>? isHost,
    Expression<int>? createdAt,
    Expression<String>? status,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (hostPeerId != null) 'host_peer_id': hostPeerId,
      if (isHost != null) 'is_host': isHost,
      if (createdAt != null) 'created_at': createdAt,
      if (status != null) 'status': status,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RoomsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? hostPeerId,
    Value<bool>? isHost,
    Value<int>? createdAt,
    Value<String>? status,
    Value<int>? rowid,
  }) {
    return RoomsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      hostPeerId: hostPeerId ?? this.hostPeerId,
      isHost: isHost ?? this.isHost,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (hostPeerId.present) {
      map['host_peer_id'] = Variable<String>(hostPeerId.value);
    }
    if (isHost.present) {
      map['is_host'] = Variable<bool>(isHost.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RoomsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('hostPeerId: $hostPeerId, ')
          ..write('isHost: $isHost, ')
          ..write('createdAt: $createdAt, ')
          ..write('status: $status, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RoomChannelsTableTable extends RoomChannelsTable
    with TableInfo<$RoomChannelsTableTable, RoomChannelRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RoomChannelsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roomIdMeta = const VerificationMeta('roomId');
  @override
  late final GeneratedColumn<String> roomId = GeneratedColumn<String>(
    'room_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES rooms (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 8,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, roomId, name, type, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'room_channels';
  @override
  VerificationContext validateIntegrity(
    Insertable<RoomChannelRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('room_id')) {
      context.handle(
        _roomIdMeta,
        roomId.isAcceptableOrUnknown(data['room_id']!, _roomIdMeta),
      );
    } else if (isInserting) {
      context.missing(_roomIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RoomChannelRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RoomChannelRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      roomId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
    );
  }

  @override
  $RoomChannelsTableTable createAlias(String alias) {
    return $RoomChannelsTableTable(attachedDatabase, alias);
  }
}

class RoomChannelRow extends DataClass implements Insertable<RoomChannelRow> {
  final String id;
  final String roomId;
  final String name;
  final String type;
  final int position;
  const RoomChannelRow({
    required this.id,
    required this.roomId,
    required this.name,
    required this.type,
    required this.position,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['room_id'] = Variable<String>(roomId);
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['position'] = Variable<int>(position);
    return map;
  }

  RoomChannelsTableCompanion toCompanion(bool nullToAbsent) {
    return RoomChannelsTableCompanion(
      id: Value(id),
      roomId: Value(roomId),
      name: Value(name),
      type: Value(type),
      position: Value(position),
    );
  }

  factory RoomChannelRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RoomChannelRow(
      id: serializer.fromJson<String>(json['id']),
      roomId: serializer.fromJson<String>(json['roomId']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'roomId': serializer.toJson<String>(roomId),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'position': serializer.toJson<int>(position),
    };
  }

  RoomChannelRow copyWith({
    String? id,
    String? roomId,
    String? name,
    String? type,
    int? position,
  }) => RoomChannelRow(
    id: id ?? this.id,
    roomId: roomId ?? this.roomId,
    name: name ?? this.name,
    type: type ?? this.type,
    position: position ?? this.position,
  );
  RoomChannelRow copyWithCompanion(RoomChannelsTableCompanion data) {
    return RoomChannelRow(
      id: data.id.present ? data.id.value : this.id,
      roomId: data.roomId.present ? data.roomId.value : this.roomId,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RoomChannelRow(')
          ..write('id: $id, ')
          ..write('roomId: $roomId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, roomId, name, type, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RoomChannelRow &&
          other.id == this.id &&
          other.roomId == this.roomId &&
          other.name == this.name &&
          other.type == this.type &&
          other.position == this.position);
}

class RoomChannelsTableCompanion extends UpdateCompanion<RoomChannelRow> {
  final Value<String> id;
  final Value<String> roomId;
  final Value<String> name;
  final Value<String> type;
  final Value<int> position;
  final Value<int> rowid;
  const RoomChannelsTableCompanion({
    this.id = const Value.absent(),
    this.roomId = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RoomChannelsTableCompanion.insert({
    required String id,
    required String roomId,
    this.name = const Value.absent(),
    required String type,
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       roomId = Value(roomId),
       type = Value(type);
  static Insertable<RoomChannelRow> custom({
    Expression<String>? id,
    Expression<String>? roomId,
    Expression<String>? name,
    Expression<String>? type,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (roomId != null) 'room_id': roomId,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RoomChannelsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? roomId,
    Value<String>? name,
    Value<String>? type,
    Value<int>? position,
    Value<int>? rowid,
  }) {
    return RoomChannelsTableCompanion(
      id: id ?? this.id,
      roomId: roomId ?? this.roomId,
      name: name ?? this.name,
      type: type ?? this.type,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (roomId.present) {
      map['room_id'] = Variable<String>(roomId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RoomChannelsTableCompanion(')
          ..write('id: $id, ')
          ..write('roomId: $roomId, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTableTable extends MessagesTable
    with TableInfo<$MessagesTableTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
    'peer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _directionMeta = const VerificationMeta(
    'direction',
  );
  @override
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
    'direction',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 2,
      maxTextLength: 4,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 16,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roomIdMeta = const VerificationMeta('roomId');
  @override
  late final GeneratedColumn<String> roomId = GeneratedColumn<String>(
    'room_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<String> channelId = GeneratedColumn<String>(
    'channel_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES room_channels (id) ON DELETE CASCADE',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    peerId,
    timestamp,
    direction,
    status,
    data,
    roomId,
    channelId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(
        _peerIdMeta,
        peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(
        _directionMeta,
        direction.isAcceptableOrUnknown(data['direction']!, _directionMeta),
      );
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    if (data.containsKey('room_id')) {
      context.handle(
        _roomIdMeta,
        roomId.isAcceptableOrUnknown(data['room_id']!, _roomIdMeta),
      );
    }
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      peerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_id'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
      direction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}direction'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
      roomId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_id'],
      ),
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_id'],
      ),
    );
  }

  @override
  $MessagesTableTable createAlias(String alias) {
    return $MessagesTableTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final String id;
  final String peerId;
  final int timestamp;
  final String direction;
  final String status;
  final Uint8List data;

  /// Room/channel routing (schema v3 — Discord-style rooms). Both nullable: a
  /// 1:1 DM message leaves them null; a room message carries its owning room +
  /// channel. `channelId` references [RoomChannelsTable] with CASCADE so
  /// deleting a channel reaps its message history. A composite index on
  /// (channel_id, timestamp) is created in `database.dart` for fast per-channel
  /// paging.
  final String? roomId;
  final String? channelId;
  const MessageRow({
    required this.id,
    required this.peerId,
    required this.timestamp,
    required this.direction,
    required this.status,
    required this.data,
    this.roomId,
    this.channelId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['timestamp'] = Variable<int>(timestamp);
    map['direction'] = Variable<String>(direction);
    map['status'] = Variable<String>(status);
    map['data'] = Variable<Uint8List>(data);
    if (!nullToAbsent || roomId != null) {
      map['room_id'] = Variable<String>(roomId);
    }
    if (!nullToAbsent || channelId != null) {
      map['channel_id'] = Variable<String>(channelId);
    }
    return map;
  }

  MessagesTableCompanion toCompanion(bool nullToAbsent) {
    return MessagesTableCompanion(
      id: Value(id),
      peerId: Value(peerId),
      timestamp: Value(timestamp),
      direction: Value(direction),
      status: Value(status),
      data: Value(data),
      roomId: roomId == null && nullToAbsent
          ? const Value.absent()
          : Value(roomId),
      channelId: channelId == null && nullToAbsent
          ? const Value.absent()
          : Value(channelId),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
      direction: serializer.fromJson<String>(json['direction']),
      status: serializer.fromJson<String>(json['status']),
      data: serializer.fromJson<Uint8List>(json['data']),
      roomId: serializer.fromJson<String?>(json['roomId']),
      channelId: serializer.fromJson<String?>(json['channelId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'peerId': serializer.toJson<String>(peerId),
      'timestamp': serializer.toJson<int>(timestamp),
      'direction': serializer.toJson<String>(direction),
      'status': serializer.toJson<String>(status),
      'data': serializer.toJson<Uint8List>(data),
      'roomId': serializer.toJson<String?>(roomId),
      'channelId': serializer.toJson<String?>(channelId),
    };
  }

  MessageRow copyWith({
    String? id,
    String? peerId,
    int? timestamp,
    String? direction,
    String? status,
    Uint8List? data,
    Value<String?> roomId = const Value.absent(),
    Value<String?> channelId = const Value.absent(),
  }) => MessageRow(
    id: id ?? this.id,
    peerId: peerId ?? this.peerId,
    timestamp: timestamp ?? this.timestamp,
    direction: direction ?? this.direction,
    status: status ?? this.status,
    data: data ?? this.data,
    roomId: roomId.present ? roomId.value : this.roomId,
    channelId: channelId.present ? channelId.value : this.channelId,
  );
  MessageRow copyWithCompanion(MessagesTableCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
      direction: data.direction.present ? data.direction.value : this.direction,
      status: data.status.present ? data.status.value : this.status,
      data: data.data.present ? data.data.value : this.data,
      roomId: data.roomId.present ? data.roomId.value : this.roomId,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('timestamp: $timestamp, ')
          ..write('direction: $direction, ')
          ..write('status: $status, ')
          ..write('data: $data, ')
          ..write('roomId: $roomId, ')
          ..write('channelId: $channelId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    peerId,
    timestamp,
    direction,
    status,
    $driftBlobEquality.hash(data),
    roomId,
    channelId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          other.timestamp == this.timestamp &&
          other.direction == this.direction &&
          other.status == this.status &&
          $driftBlobEquality.equals(other.data, this.data) &&
          other.roomId == this.roomId &&
          other.channelId == this.channelId);
}

class MessagesTableCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> peerId;
  final Value<int> timestamp;
  final Value<String> direction;
  final Value<String> status;
  final Value<Uint8List> data;
  final Value<String?> roomId;
  final Value<String?> channelId;
  final Value<int> rowid;
  const MessagesTableCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.timestamp = const Value.absent(),
    this.direction = const Value.absent(),
    this.status = const Value.absent(),
    this.data = const Value.absent(),
    this.roomId = const Value.absent(),
    this.channelId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesTableCompanion.insert({
    required String id,
    required String peerId,
    required int timestamp,
    required String direction,
    required String status,
    required Uint8List data,
    this.roomId = const Value.absent(),
    this.channelId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       peerId = Value(peerId),
       timestamp = Value(timestamp),
       direction = Value(direction),
       status = Value(status),
       data = Value(data);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? peerId,
    Expression<int>? timestamp,
    Expression<String>? direction,
    Expression<String>? status,
    Expression<Uint8List>? data,
    Expression<String>? roomId,
    Expression<String>? channelId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (timestamp != null) 'timestamp': timestamp,
      if (direction != null) 'direction': direction,
      if (status != null) 'status': status,
      if (data != null) 'data': data,
      if (roomId != null) 'room_id': roomId,
      if (channelId != null) 'channel_id': channelId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesTableCompanion copyWith({
    Value<String>? id,
    Value<String>? peerId,
    Value<int>? timestamp,
    Value<String>? direction,
    Value<String>? status,
    Value<Uint8List>? data,
    Value<String?>? roomId,
    Value<String?>? channelId,
    Value<int>? rowid,
  }) {
    return MessagesTableCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      timestamp: timestamp ?? this.timestamp,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      data: data ?? this.data,
      roomId: roomId ?? this.roomId,
      channelId: channelId ?? this.channelId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (roomId.present) {
      map['room_id'] = Variable<String>(roomId.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<String>(channelId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesTableCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('timestamp: $timestamp, ')
          ..write('direction: $direction, ')
          ..write('status: $status, ')
          ..write('data: $data, ')
          ..write('roomId: $roomId, ')
          ..write('channelId: $channelId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StickerPacksTableTable extends StickerPacksTable
    with TableInfo<$StickerPacksTableTable, StickerPackRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StickerPacksTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _installedAtMeta = const VerificationMeta(
    'installedAt',
  );
  @override
  late final GeneratedColumn<int> installedAt = GeneratedColumn<int>(
    'installed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, installedAt, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sticker_packs';
  @override
  VerificationContext validateIntegrity(
    Insertable<StickerPackRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('installed_at')) {
      context.handle(
        _installedAtMeta,
        installedAt.isAcceptableOrUnknown(
          data['installed_at']!,
          _installedAtMeta,
        ),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StickerPackRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StickerPackRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      installedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}installed_at'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $StickerPacksTableTable createAlias(String alias) {
    return $StickerPacksTableTable(attachedDatabase, alias);
  }
}

class StickerPackRow extends DataClass implements Insertable<StickerPackRow> {
  final String id;
  final int installedAt;
  final Uint8List data;
  const StickerPackRow({
    required this.id,
    required this.installedAt,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['installed_at'] = Variable<int>(installedAt);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  StickerPacksTableCompanion toCompanion(bool nullToAbsent) {
    return StickerPacksTableCompanion(
      id: Value(id),
      installedAt: Value(installedAt),
      data: Value(data),
    );
  }

  factory StickerPackRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StickerPackRow(
      id: serializer.fromJson<String>(json['id']),
      installedAt: serializer.fromJson<int>(json['installedAt']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'installedAt': serializer.toJson<int>(installedAt),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  StickerPackRow copyWith({String? id, int? installedAt, Uint8List? data}) =>
      StickerPackRow(
        id: id ?? this.id,
        installedAt: installedAt ?? this.installedAt,
        data: data ?? this.data,
      );
  StickerPackRow copyWithCompanion(StickerPacksTableCompanion data) {
    return StickerPackRow(
      id: data.id.present ? data.id.value : this.id,
      installedAt: data.installedAt.present
          ? data.installedAt.value
          : this.installedAt,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StickerPackRow(')
          ..write('id: $id, ')
          ..write('installedAt: $installedAt, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, installedAt, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StickerPackRow &&
          other.id == this.id &&
          other.installedAt == this.installedAt &&
          $driftBlobEquality.equals(other.data, this.data));
}

class StickerPacksTableCompanion extends UpdateCompanion<StickerPackRow> {
  final Value<String> id;
  final Value<int> installedAt;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const StickerPacksTableCompanion({
    this.id = const Value.absent(),
    this.installedAt = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StickerPacksTableCompanion.insert({
    required String id,
    this.installedAt = const Value.absent(),
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       data = Value(data);
  static Insertable<StickerPackRow> custom({
    Expression<String>? id,
    Expression<int>? installedAt,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (installedAt != null) 'installed_at': installedAt,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StickerPacksTableCompanion copyWith({
    Value<String>? id,
    Value<int>? installedAt,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return StickerPacksTableCompanion(
      id: id ?? this.id,
      installedAt: installedAt ?? this.installedAt,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (installedAt.present) {
      map['installed_at'] = Variable<int>(installedAt.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StickerPacksTableCompanion(')
          ..write('id: $id, ')
          ..write('installedAt: $installedAt, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecentStickersTableTable extends RecentStickersTable
    with TableInfo<$RecentStickersTableTable, RecentStickerRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecentStickersTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _packIdMeta = const VerificationMeta('packId');
  @override
  late final GeneratedColumn<String> packId = GeneratedColumn<String>(
    'pack_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stickerIdMeta = const VerificationMeta(
    'stickerId',
  );
  @override
  late final GeneratedColumn<String> stickerId = GeneratedColumn<String>(
    'sticker_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usedAtMeta = const VerificationMeta('usedAt');
  @override
  late final GeneratedColumn<int> usedAt = GeneratedColumn<int>(
    'used_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [key, packId, stickerId, usedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recent_stickers';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecentStickerRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('pack_id')) {
      context.handle(
        _packIdMeta,
        packId.isAcceptableOrUnknown(data['pack_id']!, _packIdMeta),
      );
    } else if (isInserting) {
      context.missing(_packIdMeta);
    }
    if (data.containsKey('sticker_id')) {
      context.handle(
        _stickerIdMeta,
        stickerId.isAcceptableOrUnknown(data['sticker_id']!, _stickerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_stickerIdMeta);
    }
    if (data.containsKey('used_at')) {
      context.handle(
        _usedAtMeta,
        usedAt.isAcceptableOrUnknown(data['used_at']!, _usedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  RecentStickerRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecentStickerRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      packId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pack_id'],
      )!,
      stickerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sticker_id'],
      )!,
      usedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}used_at'],
      )!,
    );
  }

  @override
  $RecentStickersTableTable createAlias(String alias) {
    return $RecentStickersTableTable(attachedDatabase, alias);
  }
}

class RecentStickerRow extends DataClass
    implements Insertable<RecentStickerRow> {
  /// `<packId>:<stickerId>` — mirrors JS.
  final String key;
  final String packId;
  final String stickerId;
  final int usedAt;
  const RecentStickerRow({
    required this.key,
    required this.packId,
    required this.stickerId,
    required this.usedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['pack_id'] = Variable<String>(packId);
    map['sticker_id'] = Variable<String>(stickerId);
    map['used_at'] = Variable<int>(usedAt);
    return map;
  }

  RecentStickersTableCompanion toCompanion(bool nullToAbsent) {
    return RecentStickersTableCompanion(
      key: Value(key),
      packId: Value(packId),
      stickerId: Value(stickerId),
      usedAt: Value(usedAt),
    );
  }

  factory RecentStickerRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecentStickerRow(
      key: serializer.fromJson<String>(json['key']),
      packId: serializer.fromJson<String>(json['packId']),
      stickerId: serializer.fromJson<String>(json['stickerId']),
      usedAt: serializer.fromJson<int>(json['usedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'packId': serializer.toJson<String>(packId),
      'stickerId': serializer.toJson<String>(stickerId),
      'usedAt': serializer.toJson<int>(usedAt),
    };
  }

  RecentStickerRow copyWith({
    String? key,
    String? packId,
    String? stickerId,
    int? usedAt,
  }) => RecentStickerRow(
    key: key ?? this.key,
    packId: packId ?? this.packId,
    stickerId: stickerId ?? this.stickerId,
    usedAt: usedAt ?? this.usedAt,
  );
  RecentStickerRow copyWithCompanion(RecentStickersTableCompanion data) {
    return RecentStickerRow(
      key: data.key.present ? data.key.value : this.key,
      packId: data.packId.present ? data.packId.value : this.packId,
      stickerId: data.stickerId.present ? data.stickerId.value : this.stickerId,
      usedAt: data.usedAt.present ? data.usedAt.value : this.usedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecentStickerRow(')
          ..write('key: $key, ')
          ..write('packId: $packId, ')
          ..write('stickerId: $stickerId, ')
          ..write('usedAt: $usedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, packId, stickerId, usedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecentStickerRow &&
          other.key == this.key &&
          other.packId == this.packId &&
          other.stickerId == this.stickerId &&
          other.usedAt == this.usedAt);
}

class RecentStickersTableCompanion extends UpdateCompanion<RecentStickerRow> {
  final Value<String> key;
  final Value<String> packId;
  final Value<String> stickerId;
  final Value<int> usedAt;
  final Value<int> rowid;
  const RecentStickersTableCompanion({
    this.key = const Value.absent(),
    this.packId = const Value.absent(),
    this.stickerId = const Value.absent(),
    this.usedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecentStickersTableCompanion.insert({
    required String key,
    required String packId,
    required String stickerId,
    this.usedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       packId = Value(packId),
       stickerId = Value(stickerId);
  static Insertable<RecentStickerRow> custom({
    Expression<String>? key,
    Expression<String>? packId,
    Expression<String>? stickerId,
    Expression<int>? usedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (packId != null) 'pack_id': packId,
      if (stickerId != null) 'sticker_id': stickerId,
      if (usedAt != null) 'used_at': usedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecentStickersTableCompanion copyWith({
    Value<String>? key,
    Value<String>? packId,
    Value<String>? stickerId,
    Value<int>? usedAt,
    Value<int>? rowid,
  }) {
    return RecentStickersTableCompanion(
      key: key ?? this.key,
      packId: packId ?? this.packId,
      stickerId: stickerId ?? this.stickerId,
      usedAt: usedAt ?? this.usedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (packId.present) {
      map['pack_id'] = Variable<String>(packId.value);
    }
    if (stickerId.present) {
      map['sticker_id'] = Variable<String>(stickerId.value);
    }
    if (usedAt.present) {
      map['used_at'] = Variable<int>(usedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecentStickersTableCompanion(')
          ..write('key: $key, ')
          ..write('packId: $packId, ')
          ..write('stickerId: $stickerId, ')
          ..write('usedAt: $usedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VoiceBlobsTableTable extends VoiceBlobsTable
    with TableInfo<$VoiceBlobsTableTable, VoiceBlobRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VoiceBlobsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mimeMeta = const VerificationMeta('mime');
  @override
  late final GeneratedColumn<String> mime = GeneratedColumn<String>(
    'mime',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('audio/webm'),
  );
  static const VerificationMeta _durationMeta = const VerificationMeta(
    'duration',
  );
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
    'duration',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    mime,
    duration,
    createdAt,
    bytes,
    data,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'voice_blobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<VoiceBlobRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('mime')) {
      context.handle(
        _mimeMeta,
        mime.isAcceptableOrUnknown(data['mime']!, _mimeMeta),
      );
    }
    if (data.containsKey('duration')) {
      context.handle(
        _durationMeta,
        duration.isAcceptableOrUnknown(data['duration']!, _durationMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  VoiceBlobRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VoiceBlobRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      mime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime'],
      )!,
      duration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $VoiceBlobsTableTable createAlias(String alias) {
    return $VoiceBlobsTableTable(attachedDatabase, alias);
  }
}

class VoiceBlobRow extends DataClass implements Insertable<VoiceBlobRow> {
  final String id;
  final String mime;
  final int duration;
  final int createdAt;

  /// Raw audio bytes — encrypted at the application layer before landing.
  /// Column getter is `bytes` (not `blob`) because Drift's `Table` base
  /// class exposes a `blob()` column-builder — a member named `blob` would
  /// shadow it and the analyzer refuses to compile.
  final Uint8List bytes;

  /// `{waveform: List<int>, …}` — lightweight metadata JSON.
  final Uint8List data;
  const VoiceBlobRow({
    required this.id,
    required this.mime,
    required this.duration,
    required this.createdAt,
    required this.bytes,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['mime'] = Variable<String>(mime);
    map['duration'] = Variable<int>(duration);
    map['created_at'] = Variable<int>(createdAt);
    map['bytes'] = Variable<Uint8List>(bytes);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  VoiceBlobsTableCompanion toCompanion(bool nullToAbsent) {
    return VoiceBlobsTableCompanion(
      id: Value(id),
      mime: Value(mime),
      duration: Value(duration),
      createdAt: Value(createdAt),
      bytes: Value(bytes),
      data: Value(data),
    );
  }

  factory VoiceBlobRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VoiceBlobRow(
      id: serializer.fromJson<String>(json['id']),
      mime: serializer.fromJson<String>(json['mime']),
      duration: serializer.fromJson<int>(json['duration']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'mime': serializer.toJson<String>(mime),
      'duration': serializer.toJson<int>(duration),
      'createdAt': serializer.toJson<int>(createdAt),
      'bytes': serializer.toJson<Uint8List>(bytes),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  VoiceBlobRow copyWith({
    String? id,
    String? mime,
    int? duration,
    int? createdAt,
    Uint8List? bytes,
    Uint8List? data,
  }) => VoiceBlobRow(
    id: id ?? this.id,
    mime: mime ?? this.mime,
    duration: duration ?? this.duration,
    createdAt: createdAt ?? this.createdAt,
    bytes: bytes ?? this.bytes,
    data: data ?? this.data,
  );
  VoiceBlobRow copyWithCompanion(VoiceBlobsTableCompanion data) {
    return VoiceBlobRow(
      id: data.id.present ? data.id.value : this.id,
      mime: data.mime.present ? data.mime.value : this.mime,
      duration: data.duration.present ? data.duration.value : this.duration,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VoiceBlobRow(')
          ..write('id: $id, ')
          ..write('mime: $mime, ')
          ..write('duration: $duration, ')
          ..write('createdAt: $createdAt, ')
          ..write('bytes: $bytes, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    mime,
    duration,
    createdAt,
    $driftBlobEquality.hash(bytes),
    $driftBlobEquality.hash(data),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VoiceBlobRow &&
          other.id == this.id &&
          other.mime == this.mime &&
          other.duration == this.duration &&
          other.createdAt == this.createdAt &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          $driftBlobEquality.equals(other.data, this.data));
}

class VoiceBlobsTableCompanion extends UpdateCompanion<VoiceBlobRow> {
  final Value<String> id;
  final Value<String> mime;
  final Value<int> duration;
  final Value<int> createdAt;
  final Value<Uint8List> bytes;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const VoiceBlobsTableCompanion({
    this.id = const Value.absent(),
    this.mime = const Value.absent(),
    this.duration = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.bytes = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VoiceBlobsTableCompanion.insert({
    required String id,
    this.mime = const Value.absent(),
    this.duration = const Value.absent(),
    this.createdAt = const Value.absent(),
    required Uint8List bytes,
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       bytes = Value(bytes),
       data = Value(data);
  static Insertable<VoiceBlobRow> custom({
    Expression<String>? id,
    Expression<String>? mime,
    Expression<int>? duration,
    Expression<int>? createdAt,
    Expression<Uint8List>? bytes,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (mime != null) 'mime': mime,
      if (duration != null) 'duration': duration,
      if (createdAt != null) 'created_at': createdAt,
      if (bytes != null) 'bytes': bytes,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VoiceBlobsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? mime,
    Value<int>? duration,
    Value<int>? createdAt,
    Value<Uint8List>? bytes,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return VoiceBlobsTableCompanion(
      id: id ?? this.id,
      mime: mime ?? this.mime,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      bytes: bytes ?? this.bytes,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (mime.present) {
      map['mime'] = Variable<String>(mime.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VoiceBlobsTableCompanion(')
          ..write('id: $id, ')
          ..write('mime: $mime, ')
          ..write('duration: $duration, ')
          ..write('createdAt: $createdAt, ')
          ..write('bytes: $bytes, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FileBlobsTableTable extends FileBlobsTable
    with TableInfo<$FileBlobsTableTable, FileBlobRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FileBlobsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mimeMeta = const VerificationMeta('mime');
  @override
  late final GeneratedColumn<String> mime = GeneratedColumn<String>(
    'mime',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('application/octet-stream'),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('file'),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('file'),
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _durationMeta = const VerificationMeta(
    'duration',
  );
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
    'duration',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _thumbMeta = const VerificationMeta('thumb');
  @override
  late final GeneratedColumn<Uint8List> thumb = GeneratedColumn<Uint8List>(
    'thumb',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    mime,
    name,
    kind,
    size,
    width,
    height,
    duration,
    createdAt,
    bytes,
    thumb,
    data,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'file_blobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<FileBlobRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('mime')) {
      context.handle(
        _mimeMeta,
        mime.isAcceptableOrUnknown(data['mime']!, _mimeMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    }
    if (data.containsKey('duration')) {
      context.handle(
        _durationMeta,
        duration.isAcceptableOrUnknown(data['duration']!, _durationMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('thumb')) {
      context.handle(
        _thumbMeta,
        thumb.isAcceptableOrUnknown(data['thumb']!, _thumbMeta),
      );
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  FileBlobRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FileBlobRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      mime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mime'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      )!,
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      )!,
      duration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      )!,
      thumb: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}thumb'],
      ),
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $FileBlobsTableTable createAlias(String alias) {
    return $FileBlobsTableTable(attachedDatabase, alias);
  }
}

class FileBlobRow extends DataClass implements Insertable<FileBlobRow> {
  final String id;
  final String mime;
  final String name;
  final String kind;
  final int size;
  final int width;
  final int height;
  final int duration;
  final int createdAt;

  /// Encrypted payload bytes. See note on [VoiceBlobsTable.bytes] for why
  /// the getter is `bytes`, not `blob`.
  final Uint8List bytes;

  /// Thumbnail blob (nullable — documents won't have one).
  final Uint8List? thumb;

  /// Everything else (e.g. origin url) as JSON.
  final Uint8List data;
  const FileBlobRow({
    required this.id,
    required this.mime,
    required this.name,
    required this.kind,
    required this.size,
    required this.width,
    required this.height,
    required this.duration,
    required this.createdAt,
    required this.bytes,
    this.thumb,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['mime'] = Variable<String>(mime);
    map['name'] = Variable<String>(name);
    map['kind'] = Variable<String>(kind);
    map['size'] = Variable<int>(size);
    map['width'] = Variable<int>(width);
    map['height'] = Variable<int>(height);
    map['duration'] = Variable<int>(duration);
    map['created_at'] = Variable<int>(createdAt);
    map['bytes'] = Variable<Uint8List>(bytes);
    if (!nullToAbsent || thumb != null) {
      map['thumb'] = Variable<Uint8List>(thumb);
    }
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  FileBlobsTableCompanion toCompanion(bool nullToAbsent) {
    return FileBlobsTableCompanion(
      id: Value(id),
      mime: Value(mime),
      name: Value(name),
      kind: Value(kind),
      size: Value(size),
      width: Value(width),
      height: Value(height),
      duration: Value(duration),
      createdAt: Value(createdAt),
      bytes: Value(bytes),
      thumb: thumb == null && nullToAbsent
          ? const Value.absent()
          : Value(thumb),
      data: Value(data),
    );
  }

  factory FileBlobRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FileBlobRow(
      id: serializer.fromJson<String>(json['id']),
      mime: serializer.fromJson<String>(json['mime']),
      name: serializer.fromJson<String>(json['name']),
      kind: serializer.fromJson<String>(json['kind']),
      size: serializer.fromJson<int>(json['size']),
      width: serializer.fromJson<int>(json['width']),
      height: serializer.fromJson<int>(json['height']),
      duration: serializer.fromJson<int>(json['duration']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
      thumb: serializer.fromJson<Uint8List?>(json['thumb']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'mime': serializer.toJson<String>(mime),
      'name': serializer.toJson<String>(name),
      'kind': serializer.toJson<String>(kind),
      'size': serializer.toJson<int>(size),
      'width': serializer.toJson<int>(width),
      'height': serializer.toJson<int>(height),
      'duration': serializer.toJson<int>(duration),
      'createdAt': serializer.toJson<int>(createdAt),
      'bytes': serializer.toJson<Uint8List>(bytes),
      'thumb': serializer.toJson<Uint8List?>(thumb),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  FileBlobRow copyWith({
    String? id,
    String? mime,
    String? name,
    String? kind,
    int? size,
    int? width,
    int? height,
    int? duration,
    int? createdAt,
    Uint8List? bytes,
    Value<Uint8List?> thumb = const Value.absent(),
    Uint8List? data,
  }) => FileBlobRow(
    id: id ?? this.id,
    mime: mime ?? this.mime,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    size: size ?? this.size,
    width: width ?? this.width,
    height: height ?? this.height,
    duration: duration ?? this.duration,
    createdAt: createdAt ?? this.createdAt,
    bytes: bytes ?? this.bytes,
    thumb: thumb.present ? thumb.value : this.thumb,
    data: data ?? this.data,
  );
  FileBlobRow copyWithCompanion(FileBlobsTableCompanion data) {
    return FileBlobRow(
      id: data.id.present ? data.id.value : this.id,
      mime: data.mime.present ? data.mime.value : this.mime,
      name: data.name.present ? data.name.value : this.name,
      kind: data.kind.present ? data.kind.value : this.kind,
      size: data.size.present ? data.size.value : this.size,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      duration: data.duration.present ? data.duration.value : this.duration,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      thumb: data.thumb.present ? data.thumb.value : this.thumb,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FileBlobRow(')
          ..write('id: $id, ')
          ..write('mime: $mime, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('size: $size, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('duration: $duration, ')
          ..write('createdAt: $createdAt, ')
          ..write('bytes: $bytes, ')
          ..write('thumb: $thumb, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    mime,
    name,
    kind,
    size,
    width,
    height,
    duration,
    createdAt,
    $driftBlobEquality.hash(bytes),
    $driftBlobEquality.hash(thumb),
    $driftBlobEquality.hash(data),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FileBlobRow &&
          other.id == this.id &&
          other.mime == this.mime &&
          other.name == this.name &&
          other.kind == this.kind &&
          other.size == this.size &&
          other.width == this.width &&
          other.height == this.height &&
          other.duration == this.duration &&
          other.createdAt == this.createdAt &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          $driftBlobEquality.equals(other.thumb, this.thumb) &&
          $driftBlobEquality.equals(other.data, this.data));
}

class FileBlobsTableCompanion extends UpdateCompanion<FileBlobRow> {
  final Value<String> id;
  final Value<String> mime;
  final Value<String> name;
  final Value<String> kind;
  final Value<int> size;
  final Value<int> width;
  final Value<int> height;
  final Value<int> duration;
  final Value<int> createdAt;
  final Value<Uint8List> bytes;
  final Value<Uint8List?> thumb;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const FileBlobsTableCompanion({
    this.id = const Value.absent(),
    this.mime = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.size = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.duration = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.bytes = const Value.absent(),
    this.thumb = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FileBlobsTableCompanion.insert({
    required String id,
    this.mime = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.size = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.duration = const Value.absent(),
    this.createdAt = const Value.absent(),
    required Uint8List bytes,
    this.thumb = const Value.absent(),
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       bytes = Value(bytes),
       data = Value(data);
  static Insertable<FileBlobRow> custom({
    Expression<String>? id,
    Expression<String>? mime,
    Expression<String>? name,
    Expression<String>? kind,
    Expression<int>? size,
    Expression<int>? width,
    Expression<int>? height,
    Expression<int>? duration,
    Expression<int>? createdAt,
    Expression<Uint8List>? bytes,
    Expression<Uint8List>? thumb,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (mime != null) 'mime': mime,
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (size != null) 'size': size,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (duration != null) 'duration': duration,
      if (createdAt != null) 'created_at': createdAt,
      if (bytes != null) 'bytes': bytes,
      if (thumb != null) 'thumb': thumb,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FileBlobsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? mime,
    Value<String>? name,
    Value<String>? kind,
    Value<int>? size,
    Value<int>? width,
    Value<int>? height,
    Value<int>? duration,
    Value<int>? createdAt,
    Value<Uint8List>? bytes,
    Value<Uint8List?>? thumb,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return FileBlobsTableCompanion(
      id: id ?? this.id,
      mime: mime ?? this.mime,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      size: size ?? this.size,
      width: width ?? this.width,
      height: height ?? this.height,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      bytes: bytes ?? this.bytes,
      thumb: thumb ?? this.thumb,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (mime.present) {
      map['mime'] = Variable<String>(mime.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (thumb.present) {
      map['thumb'] = Variable<Uint8List>(thumb.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FileBlobsTableCompanion(')
          ..write('id: $id, ')
          ..write('mime: $mime, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('size: $size, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('duration: $duration, ')
          ..write('createdAt: $createdAt, ')
          ..write('bytes: $bytes, ')
          ..write('thumb: $thumb, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KvTableTable extends KvTable with TableInfo<$KvTableTable, KvRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KvTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<Uint8List> value = GeneratedColumn<Uint8List>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'kv';
  @override
  VerificationContext validateIntegrity(
    Insertable<KvRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  KvRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KvRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $KvTableTable createAlias(String alias) {
    return $KvTableTable(attachedDatabase, alias);
  }
}

class KvRow extends DataClass implements Insertable<KvRow> {
  final String key;
  final Uint8List value;
  const KvRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<Uint8List>(value);
    return map;
  }

  KvTableCompanion toCompanion(bool nullToAbsent) {
    return KvTableCompanion(key: Value(key), value: Value(value));
  }

  factory KvRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KvRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<Uint8List>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<Uint8List>(value),
    };
  }

  KvRow copyWith({String? key, Uint8List? value}) =>
      KvRow(key: key ?? this.key, value: value ?? this.value);
  KvRow copyWithCompanion(KvTableCompanion data) {
    return KvRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KvRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, $driftBlobEquality.hash(value));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KvRow &&
          other.key == this.key &&
          $driftBlobEquality.equals(other.value, this.value));
}

class KvTableCompanion extends UpdateCompanion<KvRow> {
  final Value<String> key;
  final Value<Uint8List> value;
  final Value<int> rowid;
  const KvTableCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KvTableCompanion.insert({
    required String key,
    required Uint8List value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<KvRow> custom({
    Expression<String>? key,
    Expression<Uint8List>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KvTableCompanion copyWith({
    Value<String>? key,
    Value<Uint8List>? value,
    Value<int>? rowid,
  }) {
    return KvTableCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<Uint8List>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KvTableCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RoomMembersTableTable extends RoomMembersTable
    with TableInfo<$RoomMembersTableTable, RoomMemberRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RoomMembersTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _roomIdMeta = const VerificationMeta('roomId');
  @override
  late final GeneratedColumn<String> roomId = GeneratedColumn<String>(
    'room_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES rooms (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
    'peer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _avatarDataUrlMeta = const VerificationMeta(
    'avatarDataUrl',
  );
  @override
  late final GeneratedColumn<String> avatarDataUrl = GeneratedColumn<String>(
    'avatar_data_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isOnlineMeta = const VerificationMeta(
    'isOnline',
  );
  @override
  late final GeneratedColumn<bool> isOnline = GeneratedColumn<bool>(
    'is_online',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_online" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _joinedAtMeta = const VerificationMeta(
    'joinedAt',
  );
  @override
  late final GeneratedColumn<int> joinedAt = GeneratedColumn<int>(
    'joined_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    roomId,
    peerId,
    displayName,
    avatarDataUrl,
    isOnline,
    joinedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'room_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<RoomMemberRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('room_id')) {
      context.handle(
        _roomIdMeta,
        roomId.isAcceptableOrUnknown(data['room_id']!, _roomIdMeta),
      );
    } else if (isInserting) {
      context.missing(_roomIdMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(
        _peerIdMeta,
        peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('avatar_data_url')) {
      context.handle(
        _avatarDataUrlMeta,
        avatarDataUrl.isAcceptableOrUnknown(
          data['avatar_data_url']!,
          _avatarDataUrlMeta,
        ),
      );
    }
    if (data.containsKey('is_online')) {
      context.handle(
        _isOnlineMeta,
        isOnline.isAcceptableOrUnknown(data['is_online']!, _isOnlineMeta),
      );
    }
    if (data.containsKey('joined_at')) {
      context.handle(
        _joinedAtMeta,
        joinedAt.isAcceptableOrUnknown(data['joined_at']!, _joinedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {roomId, peerId};
  @override
  RoomMemberRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RoomMemberRow(
      roomId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}room_id'],
      )!,
      peerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      avatarDataUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_data_url'],
      ),
      isOnline: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_online'],
      )!,
      joinedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}joined_at'],
      )!,
    );
  }

  @override
  $RoomMembersTableTable createAlias(String alias) {
    return $RoomMembersTableTable(attachedDatabase, alias);
  }
}

class RoomMemberRow extends DataClass implements Insertable<RoomMemberRow> {
  final String roomId;
  final String peerId;
  final String displayName;
  final String? avatarDataUrl;
  final bool isOnline;
  final int joinedAt;
  const RoomMemberRow({
    required this.roomId,
    required this.peerId,
    required this.displayName,
    this.avatarDataUrl,
    required this.isOnline,
    required this.joinedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['room_id'] = Variable<String>(roomId);
    map['peer_id'] = Variable<String>(peerId);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || avatarDataUrl != null) {
      map['avatar_data_url'] = Variable<String>(avatarDataUrl);
    }
    map['is_online'] = Variable<bool>(isOnline);
    map['joined_at'] = Variable<int>(joinedAt);
    return map;
  }

  RoomMembersTableCompanion toCompanion(bool nullToAbsent) {
    return RoomMembersTableCompanion(
      roomId: Value(roomId),
      peerId: Value(peerId),
      displayName: Value(displayName),
      avatarDataUrl: avatarDataUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(avatarDataUrl),
      isOnline: Value(isOnline),
      joinedAt: Value(joinedAt),
    );
  }

  factory RoomMemberRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RoomMemberRow(
      roomId: serializer.fromJson<String>(json['roomId']),
      peerId: serializer.fromJson<String>(json['peerId']),
      displayName: serializer.fromJson<String>(json['displayName']),
      avatarDataUrl: serializer.fromJson<String?>(json['avatarDataUrl']),
      isOnline: serializer.fromJson<bool>(json['isOnline']),
      joinedAt: serializer.fromJson<int>(json['joinedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'roomId': serializer.toJson<String>(roomId),
      'peerId': serializer.toJson<String>(peerId),
      'displayName': serializer.toJson<String>(displayName),
      'avatarDataUrl': serializer.toJson<String?>(avatarDataUrl),
      'isOnline': serializer.toJson<bool>(isOnline),
      'joinedAt': serializer.toJson<int>(joinedAt),
    };
  }

  RoomMemberRow copyWith({
    String? roomId,
    String? peerId,
    String? displayName,
    Value<String?> avatarDataUrl = const Value.absent(),
    bool? isOnline,
    int? joinedAt,
  }) => RoomMemberRow(
    roomId: roomId ?? this.roomId,
    peerId: peerId ?? this.peerId,
    displayName: displayName ?? this.displayName,
    avatarDataUrl: avatarDataUrl.present
        ? avatarDataUrl.value
        : this.avatarDataUrl,
    isOnline: isOnline ?? this.isOnline,
    joinedAt: joinedAt ?? this.joinedAt,
  );
  RoomMemberRow copyWithCompanion(RoomMembersTableCompanion data) {
    return RoomMemberRow(
      roomId: data.roomId.present ? data.roomId.value : this.roomId,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      avatarDataUrl: data.avatarDataUrl.present
          ? data.avatarDataUrl.value
          : this.avatarDataUrl,
      isOnline: data.isOnline.present ? data.isOnline.value : this.isOnline,
      joinedAt: data.joinedAt.present ? data.joinedAt.value : this.joinedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RoomMemberRow(')
          ..write('roomId: $roomId, ')
          ..write('peerId: $peerId, ')
          ..write('displayName: $displayName, ')
          ..write('avatarDataUrl: $avatarDataUrl, ')
          ..write('isOnline: $isOnline, ')
          ..write('joinedAt: $joinedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    roomId,
    peerId,
    displayName,
    avatarDataUrl,
    isOnline,
    joinedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RoomMemberRow &&
          other.roomId == this.roomId &&
          other.peerId == this.peerId &&
          other.displayName == this.displayName &&
          other.avatarDataUrl == this.avatarDataUrl &&
          other.isOnline == this.isOnline &&
          other.joinedAt == this.joinedAt);
}

class RoomMembersTableCompanion extends UpdateCompanion<RoomMemberRow> {
  final Value<String> roomId;
  final Value<String> peerId;
  final Value<String> displayName;
  final Value<String?> avatarDataUrl;
  final Value<bool> isOnline;
  final Value<int> joinedAt;
  final Value<int> rowid;
  const RoomMembersTableCompanion({
    this.roomId = const Value.absent(),
    this.peerId = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatarDataUrl = const Value.absent(),
    this.isOnline = const Value.absent(),
    this.joinedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RoomMembersTableCompanion.insert({
    required String roomId,
    required String peerId,
    this.displayName = const Value.absent(),
    this.avatarDataUrl = const Value.absent(),
    this.isOnline = const Value.absent(),
    this.joinedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : roomId = Value(roomId),
       peerId = Value(peerId);
  static Insertable<RoomMemberRow> custom({
    Expression<String>? roomId,
    Expression<String>? peerId,
    Expression<String>? displayName,
    Expression<String>? avatarDataUrl,
    Expression<bool>? isOnline,
    Expression<int>? joinedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (roomId != null) 'room_id': roomId,
      if (peerId != null) 'peer_id': peerId,
      if (displayName != null) 'display_name': displayName,
      if (avatarDataUrl != null) 'avatar_data_url': avatarDataUrl,
      if (isOnline != null) 'is_online': isOnline,
      if (joinedAt != null) 'joined_at': joinedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RoomMembersTableCompanion copyWith({
    Value<String>? roomId,
    Value<String>? peerId,
    Value<String>? displayName,
    Value<String?>? avatarDataUrl,
    Value<bool>? isOnline,
    Value<int>? joinedAt,
    Value<int>? rowid,
  }) {
    return RoomMembersTableCompanion(
      roomId: roomId ?? this.roomId,
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      avatarDataUrl: avatarDataUrl ?? this.avatarDataUrl,
      isOnline: isOnline ?? this.isOnline,
      joinedAt: joinedAt ?? this.joinedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (roomId.present) {
      map['room_id'] = Variable<String>(roomId.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (avatarDataUrl.present) {
      map['avatar_data_url'] = Variable<String>(avatarDataUrl.value);
    }
    if (isOnline.present) {
      map['is_online'] = Variable<bool>(isOnline.value);
    }
    if (joinedAt.present) {
      map['joined_at'] = Variable<int>(joinedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RoomMembersTableCompanion(')
          ..write('roomId: $roomId, ')
          ..write('peerId: $peerId, ')
          ..write('displayName: $displayName, ')
          ..write('avatarDataUrl: $avatarDataUrl, ')
          ..write('isOnline: $isOnline, ')
          ..write('joinedAt: $joinedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$OrbitsDatabase extends GeneratedDatabase {
  _$OrbitsDatabase(QueryExecutor e) : super(e);
  $OrbitsDatabaseManager get managers => $OrbitsDatabaseManager(this);
  late final $KeysTableTable keysTable = $KeysTableTable(this);
  late final $PrekeysTableTable prekeysTable = $PrekeysTableTable(this);
  late final $RatchetsTableTable ratchetsTable = $RatchetsTableTable(this);
  late final $PeersTableTable peersTable = $PeersTableTable(this);
  late final $AvatarsTableTable avatarsTable = $AvatarsTableTable(this);
  late final $SessionKeysTableTable sessionKeysTable = $SessionKeysTableTable(
    this,
  );
  late final $RoomsTableTable roomsTable = $RoomsTableTable(this);
  late final $RoomChannelsTableTable roomChannelsTable =
      $RoomChannelsTableTable(this);
  late final $MessagesTableTable messagesTable = $MessagesTableTable(this);
  late final $StickerPacksTableTable stickerPacksTable =
      $StickerPacksTableTable(this);
  late final $RecentStickersTableTable recentStickersTable =
      $RecentStickersTableTable(this);
  late final $VoiceBlobsTableTable voiceBlobsTable = $VoiceBlobsTableTable(
    this,
  );
  late final $FileBlobsTableTable fileBlobsTable = $FileBlobsTableTable(this);
  late final $KvTableTable kvTable = $KvTableTable(this);
  late final $RoomMembersTableTable roomMembersTable = $RoomMembersTableTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    keysTable,
    prekeysTable,
    ratchetsTable,
    peersTable,
    avatarsTable,
    sessionKeysTable,
    roomsTable,
    roomChannelsTable,
    messagesTable,
    stickerPacksTable,
    recentStickersTable,
    voiceBlobsTable,
    fileBlobsTable,
    kvTable,
    roomMembersTable,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'rooms',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('room_channels', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'room_channels',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'rooms',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('room_members', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$KeysTableTableCreateCompanionBuilder =
    KeysTableCompanion Function({
      required String id,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$KeysTableTableUpdateCompanionBuilder =
    KeysTableCompanion Function({
      Value<String> id,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$KeysTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $KeysTableTable> {
  $$KeysTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KeysTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $KeysTableTable> {
  $$KeysTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KeysTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $KeysTableTable> {
  $$KeysTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$KeysTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $KeysTableTable,
          KeyRow,
          $$KeysTableTableFilterComposer,
          $$KeysTableTableOrderingComposer,
          $$KeysTableTableAnnotationComposer,
          $$KeysTableTableCreateCompanionBuilder,
          $$KeysTableTableUpdateCompanionBuilder,
          (KeyRow, BaseReferences<_$OrbitsDatabase, $KeysTableTable, KeyRow>),
          KeyRow,
          PrefetchHooks Function()
        > {
  $$KeysTableTableTableManager(_$OrbitsDatabase db, $KeysTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KeysTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KeysTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KeysTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KeysTableCompanion(id: id, data: data, rowid: rowid),
          createCompanionCallback:
              ({
                required String id,
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => KeysTableCompanion.insert(id: id, data: data, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeysTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $KeysTableTable,
      KeyRow,
      $$KeysTableTableFilterComposer,
      $$KeysTableTableOrderingComposer,
      $$KeysTableTableAnnotationComposer,
      $$KeysTableTableCreateCompanionBuilder,
      $$KeysTableTableUpdateCompanionBuilder,
      (KeyRow, BaseReferences<_$OrbitsDatabase, $KeysTableTable, KeyRow>),
      KeyRow,
      PrefetchHooks Function()
    >;
typedef $$PrekeysTableTableCreateCompanionBuilder =
    PrekeysTableCompanion Function({
      required String id,
      required String kind,
      Value<int> used,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$PrekeysTableTableUpdateCompanionBuilder =
    PrekeysTableCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<int> used,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$PrekeysTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $PrekeysTableTable> {
  $$PrekeysTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get used => $composableBuilder(
    column: $table.used,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PrekeysTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $PrekeysTableTable> {
  $$PrekeysTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get used => $composableBuilder(
    column: $table.used,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PrekeysTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $PrekeysTableTable> {
  $$PrekeysTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get used =>
      $composableBuilder(column: $table.used, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$PrekeysTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $PrekeysTableTable,
          PrekeyRow,
          $$PrekeysTableTableFilterComposer,
          $$PrekeysTableTableOrderingComposer,
          $$PrekeysTableTableAnnotationComposer,
          $$PrekeysTableTableCreateCompanionBuilder,
          $$PrekeysTableTableUpdateCompanionBuilder,
          (
            PrekeyRow,
            BaseReferences<_$OrbitsDatabase, $PrekeysTableTable, PrekeyRow>,
          ),
          PrekeyRow,
          PrefetchHooks Function()
        > {
  $$PrekeysTableTableTableManager(_$OrbitsDatabase db, $PrekeysTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PrekeysTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PrekeysTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PrekeysTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int> used = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PrekeysTableCompanion(
                id: id,
                kind: kind,
                used: used,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                Value<int> used = const Value.absent(),
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => PrekeysTableCompanion.insert(
                id: id,
                kind: kind,
                used: used,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PrekeysTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $PrekeysTableTable,
      PrekeyRow,
      $$PrekeysTableTableFilterComposer,
      $$PrekeysTableTableOrderingComposer,
      $$PrekeysTableTableAnnotationComposer,
      $$PrekeysTableTableCreateCompanionBuilder,
      $$PrekeysTableTableUpdateCompanionBuilder,
      (
        PrekeyRow,
        BaseReferences<_$OrbitsDatabase, $PrekeysTableTable, PrekeyRow>,
      ),
      PrekeyRow,
      PrefetchHooks Function()
    >;
typedef $$RatchetsTableTableCreateCompanionBuilder =
    RatchetsTableCompanion Function({
      required String id,
      required String peerId,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$RatchetsTableTableUpdateCompanionBuilder =
    RatchetsTableCompanion Function({
      Value<String> id,
      Value<String> peerId,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$RatchetsTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $RatchetsTableTable> {
  $$RatchetsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RatchetsTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $RatchetsTableTable> {
  $$RatchetsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RatchetsTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $RatchetsTableTable> {
  $$RatchetsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$RatchetsTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $RatchetsTableTable,
          RatchetRow,
          $$RatchetsTableTableFilterComposer,
          $$RatchetsTableTableOrderingComposer,
          $$RatchetsTableTableAnnotationComposer,
          $$RatchetsTableTableCreateCompanionBuilder,
          $$RatchetsTableTableUpdateCompanionBuilder,
          (
            RatchetRow,
            BaseReferences<_$OrbitsDatabase, $RatchetsTableTable, RatchetRow>,
          ),
          RatchetRow,
          PrefetchHooks Function()
        > {
  $$RatchetsTableTableTableManager(
    _$OrbitsDatabase db,
    $RatchetsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RatchetsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RatchetsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RatchetsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> peerId = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RatchetsTableCompanion(
                id: id,
                peerId: peerId,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String peerId,
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => RatchetsTableCompanion.insert(
                id: id,
                peerId: peerId,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RatchetsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $RatchetsTableTable,
      RatchetRow,
      $$RatchetsTableTableFilterComposer,
      $$RatchetsTableTableOrderingComposer,
      $$RatchetsTableTableAnnotationComposer,
      $$RatchetsTableTableCreateCompanionBuilder,
      $$RatchetsTableTableUpdateCompanionBuilder,
      (
        RatchetRow,
        BaseReferences<_$OrbitsDatabase, $RatchetsTableTable, RatchetRow>,
      ),
      RatchetRow,
      PrefetchHooks Function()
    >;
typedef $$PeersTableTableCreateCompanionBuilder =
    PeersTableCompanion Function({
      required String id,
      Value<String> displayName,
      Value<int> lastSeenAt,
      Value<int> trusted,
      Value<int> trustLevel,
      Value<int> addedAt,
      Value<int> blocked,
      Value<int> lastReadAt,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$PeersTableTableUpdateCompanionBuilder =
    PeersTableCompanion Function({
      Value<String> id,
      Value<String> displayName,
      Value<int> lastSeenAt,
      Value<int> trusted,
      Value<int> trustLevel,
      Value<int> addedAt,
      Value<int> blocked,
      Value<int> lastReadAt,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$PeersTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $PeersTableTable> {
  $$PeersTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get trustLevel => $composableBuilder(
    column: $table.trustLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get blocked => $composableBuilder(
    column: $table.blocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReadAt => $composableBuilder(
    column: $table.lastReadAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PeersTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $PeersTableTable> {
  $$PeersTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get trustLevel => $composableBuilder(
    column: $table.trustLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get blocked => $composableBuilder(
    column: $table.blocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReadAt => $composableBuilder(
    column: $table.lastReadAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PeersTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $PeersTableTable> {
  $$PeersTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSeenAt => $composableBuilder(
    column: $table.lastSeenAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get trusted =>
      $composableBuilder(column: $table.trusted, builder: (column) => column);

  GeneratedColumn<int> get trustLevel => $composableBuilder(
    column: $table.trustLevel,
    builder: (column) => column,
  );

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get blocked =>
      $composableBuilder(column: $table.blocked, builder: (column) => column);

  GeneratedColumn<int> get lastReadAt => $composableBuilder(
    column: $table.lastReadAt,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$PeersTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $PeersTableTable,
          PeerRow,
          $$PeersTableTableFilterComposer,
          $$PeersTableTableOrderingComposer,
          $$PeersTableTableAnnotationComposer,
          $$PeersTableTableCreateCompanionBuilder,
          $$PeersTableTableUpdateCompanionBuilder,
          (
            PeerRow,
            BaseReferences<_$OrbitsDatabase, $PeersTableTable, PeerRow>,
          ),
          PeerRow,
          PrefetchHooks Function()
        > {
  $$PeersTableTableTableManager(_$OrbitsDatabase db, $PeersTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PeersTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PeersTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PeersTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<int> lastSeenAt = const Value.absent(),
                Value<int> trusted = const Value.absent(),
                Value<int> trustLevel = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int> blocked = const Value.absent(),
                Value<int> lastReadAt = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PeersTableCompanion(
                id: id,
                displayName: displayName,
                lastSeenAt: lastSeenAt,
                trusted: trusted,
                trustLevel: trustLevel,
                addedAt: addedAt,
                blocked: blocked,
                lastReadAt: lastReadAt,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> displayName = const Value.absent(),
                Value<int> lastSeenAt = const Value.absent(),
                Value<int> trusted = const Value.absent(),
                Value<int> trustLevel = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int> blocked = const Value.absent(),
                Value<int> lastReadAt = const Value.absent(),
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => PeersTableCompanion.insert(
                id: id,
                displayName: displayName,
                lastSeenAt: lastSeenAt,
                trusted: trusted,
                trustLevel: trustLevel,
                addedAt: addedAt,
                blocked: blocked,
                lastReadAt: lastReadAt,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PeersTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $PeersTableTable,
      PeerRow,
      $$PeersTableTableFilterComposer,
      $$PeersTableTableOrderingComposer,
      $$PeersTableTableAnnotationComposer,
      $$PeersTableTableCreateCompanionBuilder,
      $$PeersTableTableUpdateCompanionBuilder,
      (PeerRow, BaseReferences<_$OrbitsDatabase, $PeersTableTable, PeerRow>),
      PeerRow,
      PrefetchHooks Function()
    >;
typedef $$AvatarsTableTableCreateCompanionBuilder =
    AvatarsTableCompanion Function({
      required String peerId,
      Value<int> updatedAt,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$AvatarsTableTableUpdateCompanionBuilder =
    AvatarsTableCompanion Function({
      Value<String> peerId,
      Value<int> updatedAt,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$AvatarsTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $AvatarsTableTable> {
  $$AvatarsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AvatarsTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $AvatarsTableTable> {
  $$AvatarsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AvatarsTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $AvatarsTableTable> {
  $$AvatarsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$AvatarsTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $AvatarsTableTable,
          AvatarRow,
          $$AvatarsTableTableFilterComposer,
          $$AvatarsTableTableOrderingComposer,
          $$AvatarsTableTableAnnotationComposer,
          $$AvatarsTableTableCreateCompanionBuilder,
          $$AvatarsTableTableUpdateCompanionBuilder,
          (
            AvatarRow,
            BaseReferences<_$OrbitsDatabase, $AvatarsTableTable, AvatarRow>,
          ),
          AvatarRow,
          PrefetchHooks Function()
        > {
  $$AvatarsTableTableTableManager(_$OrbitsDatabase db, $AvatarsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AvatarsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AvatarsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AvatarsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> peerId = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AvatarsTableCompanion(
                peerId: peerId,
                updatedAt: updatedAt,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String peerId,
                Value<int> updatedAt = const Value.absent(),
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => AvatarsTableCompanion.insert(
                peerId: peerId,
                updatedAt: updatedAt,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AvatarsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $AvatarsTableTable,
      AvatarRow,
      $$AvatarsTableTableFilterComposer,
      $$AvatarsTableTableOrderingComposer,
      $$AvatarsTableTableAnnotationComposer,
      $$AvatarsTableTableCreateCompanionBuilder,
      $$AvatarsTableTableUpdateCompanionBuilder,
      (
        AvatarRow,
        BaseReferences<_$OrbitsDatabase, $AvatarsTableTable, AvatarRow>,
      ),
      AvatarRow,
      PrefetchHooks Function()
    >;
typedef $$SessionKeysTableTableCreateCompanionBuilder =
    SessionKeysTableCompanion Function({
      required String id,
      required String peerId,
      Value<int> updatedAt,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$SessionKeysTableTableUpdateCompanionBuilder =
    SessionKeysTableCompanion Function({
      Value<String> id,
      Value<String> peerId,
      Value<int> updatedAt,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$SessionKeysTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $SessionKeysTableTable> {
  $$SessionKeysTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SessionKeysTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $SessionKeysTableTable> {
  $$SessionKeysTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SessionKeysTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $SessionKeysTableTable> {
  $$SessionKeysTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$SessionKeysTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $SessionKeysTableTable,
          SessionKeyRow,
          $$SessionKeysTableTableFilterComposer,
          $$SessionKeysTableTableOrderingComposer,
          $$SessionKeysTableTableAnnotationComposer,
          $$SessionKeysTableTableCreateCompanionBuilder,
          $$SessionKeysTableTableUpdateCompanionBuilder,
          (
            SessionKeyRow,
            BaseReferences<
              _$OrbitsDatabase,
              $SessionKeysTableTable,
              SessionKeyRow
            >,
          ),
          SessionKeyRow,
          PrefetchHooks Function()
        > {
  $$SessionKeysTableTableTableManager(
    _$OrbitsDatabase db,
    $SessionKeysTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SessionKeysTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SessionKeysTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SessionKeysTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> peerId = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SessionKeysTableCompanion(
                id: id,
                peerId: peerId,
                updatedAt: updatedAt,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String peerId,
                Value<int> updatedAt = const Value.absent(),
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => SessionKeysTableCompanion.insert(
                id: id,
                peerId: peerId,
                updatedAt: updatedAt,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SessionKeysTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $SessionKeysTableTable,
      SessionKeyRow,
      $$SessionKeysTableTableFilterComposer,
      $$SessionKeysTableTableOrderingComposer,
      $$SessionKeysTableTableAnnotationComposer,
      $$SessionKeysTableTableCreateCompanionBuilder,
      $$SessionKeysTableTableUpdateCompanionBuilder,
      (
        SessionKeyRow,
        BaseReferences<_$OrbitsDatabase, $SessionKeysTableTable, SessionKeyRow>,
      ),
      SessionKeyRow,
      PrefetchHooks Function()
    >;
typedef $$RoomsTableTableCreateCompanionBuilder =
    RoomsTableCompanion Function({
      required String id,
      Value<String> name,
      Value<String> hostPeerId,
      Value<bool> isHost,
      Value<int> createdAt,
      Value<String> status,
      Value<int> rowid,
    });
typedef $$RoomsTableTableUpdateCompanionBuilder =
    RoomsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> hostPeerId,
      Value<bool> isHost,
      Value<int> createdAt,
      Value<String> status,
      Value<int> rowid,
    });

final class $$RoomsTableTableReferences
    extends BaseReferences<_$OrbitsDatabase, $RoomsTableTable, RoomRow> {
  $$RoomsTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$RoomChannelsTableTable, List<RoomChannelRow>>
  _roomChannelsTableRefsTable(_$OrbitsDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.roomChannelsTable,
        aliasName: $_aliasNameGenerator(
          db.roomsTable.id,
          db.roomChannelsTable.roomId,
        ),
      );

  $$RoomChannelsTableTableProcessedTableManager get roomChannelsTableRefs {
    final manager = $$RoomChannelsTableTableTableManager(
      $_db,
      $_db.roomChannelsTable,
    ).filter((f) => f.roomId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _roomChannelsTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$RoomMembersTableTable, List<RoomMemberRow>>
  _roomMembersTableRefsTable(_$OrbitsDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.roomMembersTable,
        aliasName: $_aliasNameGenerator(
          db.roomsTable.id,
          db.roomMembersTable.roomId,
        ),
      );

  $$RoomMembersTableTableProcessedTableManager get roomMembersTableRefs {
    final manager = $$RoomMembersTableTableTableManager(
      $_db,
      $_db.roomMembersTable,
    ).filter((f) => f.roomId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _roomMembersTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$RoomsTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $RoomsTableTable> {
  $$RoomsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostPeerId => $composableBuilder(
    column: $table.hostPeerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isHost => $composableBuilder(
    column: $table.isHost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> roomChannelsTableRefs(
    Expression<bool> Function($$RoomChannelsTableTableFilterComposer f) f,
  ) {
    final $$RoomChannelsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.roomChannelsTable,
      getReferencedColumn: (t) => t.roomId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomChannelsTableTableFilterComposer(
            $db: $db,
            $table: $db.roomChannelsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> roomMembersTableRefs(
    Expression<bool> Function($$RoomMembersTableTableFilterComposer f) f,
  ) {
    final $$RoomMembersTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.roomMembersTable,
      getReferencedColumn: (t) => t.roomId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomMembersTableTableFilterComposer(
            $db: $db,
            $table: $db.roomMembersTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RoomsTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $RoomsTableTable> {
  $$RoomsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostPeerId => $composableBuilder(
    column: $table.hostPeerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isHost => $composableBuilder(
    column: $table.isHost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RoomsTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $RoomsTableTable> {
  $$RoomsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get hostPeerId => $composableBuilder(
    column: $table.hostPeerId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isHost =>
      $composableBuilder(column: $table.isHost, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  Expression<T> roomChannelsTableRefs<T extends Object>(
    Expression<T> Function($$RoomChannelsTableTableAnnotationComposer a) f,
  ) {
    final $$RoomChannelsTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.roomChannelsTable,
          getReferencedColumn: (t) => t.roomId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$RoomChannelsTableTableAnnotationComposer(
                $db: $db,
                $table: $db.roomChannelsTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> roomMembersTableRefs<T extends Object>(
    Expression<T> Function($$RoomMembersTableTableAnnotationComposer a) f,
  ) {
    final $$RoomMembersTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.roomMembersTable,
      getReferencedColumn: (t) => t.roomId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomMembersTableTableAnnotationComposer(
            $db: $db,
            $table: $db.roomMembersTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RoomsTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $RoomsTableTable,
          RoomRow,
          $$RoomsTableTableFilterComposer,
          $$RoomsTableTableOrderingComposer,
          $$RoomsTableTableAnnotationComposer,
          $$RoomsTableTableCreateCompanionBuilder,
          $$RoomsTableTableUpdateCompanionBuilder,
          (RoomRow, $$RoomsTableTableReferences),
          RoomRow,
          PrefetchHooks Function({
            bool roomChannelsTableRefs,
            bool roomMembersTableRefs,
          })
        > {
  $$RoomsTableTableTableManager(_$OrbitsDatabase db, $RoomsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RoomsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RoomsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RoomsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> hostPeerId = const Value.absent(),
                Value<bool> isHost = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoomsTableCompanion(
                id: id,
                name: name,
                hostPeerId: hostPeerId,
                isHost: isHost,
                createdAt: createdAt,
                status: status,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> name = const Value.absent(),
                Value<String> hostPeerId = const Value.absent(),
                Value<bool> isHost = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoomsTableCompanion.insert(
                id: id,
                name: name,
                hostPeerId: hostPeerId,
                isHost: isHost,
                createdAt: createdAt,
                status: status,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RoomsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({roomChannelsTableRefs = false, roomMembersTableRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (roomChannelsTableRefs) db.roomChannelsTable,
                    if (roomMembersTableRefs) db.roomMembersTable,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (roomChannelsTableRefs)
                        await $_getPrefetchedData<
                          RoomRow,
                          $RoomsTableTable,
                          RoomChannelRow
                        >(
                          currentTable: table,
                          referencedTable: $$RoomsTableTableReferences
                              ._roomChannelsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$RoomsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).roomChannelsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.roomId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (roomMembersTableRefs)
                        await $_getPrefetchedData<
                          RoomRow,
                          $RoomsTableTable,
                          RoomMemberRow
                        >(
                          currentTable: table,
                          referencedTable: $$RoomsTableTableReferences
                              ._roomMembersTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$RoomsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).roomMembersTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.roomId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$RoomsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $RoomsTableTable,
      RoomRow,
      $$RoomsTableTableFilterComposer,
      $$RoomsTableTableOrderingComposer,
      $$RoomsTableTableAnnotationComposer,
      $$RoomsTableTableCreateCompanionBuilder,
      $$RoomsTableTableUpdateCompanionBuilder,
      (RoomRow, $$RoomsTableTableReferences),
      RoomRow,
      PrefetchHooks Function({
        bool roomChannelsTableRefs,
        bool roomMembersTableRefs,
      })
    >;
typedef $$RoomChannelsTableTableCreateCompanionBuilder =
    RoomChannelsTableCompanion Function({
      required String id,
      required String roomId,
      Value<String> name,
      required String type,
      Value<int> position,
      Value<int> rowid,
    });
typedef $$RoomChannelsTableTableUpdateCompanionBuilder =
    RoomChannelsTableCompanion Function({
      Value<String> id,
      Value<String> roomId,
      Value<String> name,
      Value<String> type,
      Value<int> position,
      Value<int> rowid,
    });

final class $$RoomChannelsTableTableReferences
    extends
        BaseReferences<
          _$OrbitsDatabase,
          $RoomChannelsTableTable,
          RoomChannelRow
        > {
  $$RoomChannelsTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $RoomsTableTable _roomIdTable(_$OrbitsDatabase db) =>
      db.roomsTable.createAlias(
        $_aliasNameGenerator(db.roomChannelsTable.roomId, db.roomsTable.id),
      );

  $$RoomsTableTableProcessedTableManager get roomId {
    final $_column = $_itemColumn<String>('room_id')!;

    final manager = $$RoomsTableTableTableManager(
      $_db,
      $_db.roomsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_roomIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$MessagesTableTable, List<MessageRow>>
  _messagesTableRefsTable(_$OrbitsDatabase db) => MultiTypedResultKey.fromTable(
    db.messagesTable,
    aliasName: $_aliasNameGenerator(
      db.roomChannelsTable.id,
      db.messagesTable.channelId,
    ),
  );

  $$MessagesTableTableProcessedTableManager get messagesTableRefs {
    final manager = $$MessagesTableTableTableManager(
      $_db,
      $_db.messagesTable,
    ).filter((f) => f.channelId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesTableRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$RoomChannelsTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $RoomChannelsTableTable> {
  $$RoomChannelsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  $$RoomsTableTableFilterComposer get roomId {
    final $$RoomsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.roomId,
      referencedTable: $db.roomsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomsTableTableFilterComposer(
            $db: $db,
            $table: $db.roomsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> messagesTableRefs(
    Expression<bool> Function($$MessagesTableTableFilterComposer f) f,
  ) {
    final $$MessagesTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messagesTable,
      getReferencedColumn: (t) => t.channelId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableTableFilterComposer(
            $db: $db,
            $table: $db.messagesTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RoomChannelsTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $RoomChannelsTableTable> {
  $$RoomChannelsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  $$RoomsTableTableOrderingComposer get roomId {
    final $$RoomsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.roomId,
      referencedTable: $db.roomsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomsTableTableOrderingComposer(
            $db: $db,
            $table: $db.roomsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RoomChannelsTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $RoomChannelsTableTable> {
  $$RoomChannelsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  $$RoomsTableTableAnnotationComposer get roomId {
    final $$RoomsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.roomId,
      referencedTable: $db.roomsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.roomsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> messagesTableRefs<T extends Object>(
    Expression<T> Function($$MessagesTableTableAnnotationComposer a) f,
  ) {
    final $$MessagesTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messagesTable,
      getReferencedColumn: (t) => t.channelId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableTableAnnotationComposer(
            $db: $db,
            $table: $db.messagesTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RoomChannelsTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $RoomChannelsTableTable,
          RoomChannelRow,
          $$RoomChannelsTableTableFilterComposer,
          $$RoomChannelsTableTableOrderingComposer,
          $$RoomChannelsTableTableAnnotationComposer,
          $$RoomChannelsTableTableCreateCompanionBuilder,
          $$RoomChannelsTableTableUpdateCompanionBuilder,
          (RoomChannelRow, $$RoomChannelsTableTableReferences),
          RoomChannelRow,
          PrefetchHooks Function({bool roomId, bool messagesTableRefs})
        > {
  $$RoomChannelsTableTableTableManager(
    _$OrbitsDatabase db,
    $RoomChannelsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RoomChannelsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RoomChannelsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RoomChannelsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> roomId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoomChannelsTableCompanion(
                id: id,
                roomId: roomId,
                name: name,
                type: type,
                position: position,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String roomId,
                Value<String> name = const Value.absent(),
                required String type,
                Value<int> position = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoomChannelsTableCompanion.insert(
                id: id,
                roomId: roomId,
                name: name,
                type: type,
                position: position,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RoomChannelsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({roomId = false, messagesTableRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (messagesTableRefs) db.messagesTable,
              ],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (roomId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.roomId,
                                referencedTable:
                                    $$RoomChannelsTableTableReferences
                                        ._roomIdTable(db),
                                referencedColumn:
                                    $$RoomChannelsTableTableReferences
                                        ._roomIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesTableRefs)
                    await $_getPrefetchedData<
                      RoomChannelRow,
                      $RoomChannelsTableTable,
                      MessageRow
                    >(
                      currentTable: table,
                      referencedTable: $$RoomChannelsTableTableReferences
                          ._messagesTableRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$RoomChannelsTableTableReferences(
                            db,
                            table,
                            p0,
                          ).messagesTableRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.channelId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$RoomChannelsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $RoomChannelsTableTable,
      RoomChannelRow,
      $$RoomChannelsTableTableFilterComposer,
      $$RoomChannelsTableTableOrderingComposer,
      $$RoomChannelsTableTableAnnotationComposer,
      $$RoomChannelsTableTableCreateCompanionBuilder,
      $$RoomChannelsTableTableUpdateCompanionBuilder,
      (RoomChannelRow, $$RoomChannelsTableTableReferences),
      RoomChannelRow,
      PrefetchHooks Function({bool roomId, bool messagesTableRefs})
    >;
typedef $$MessagesTableTableCreateCompanionBuilder =
    MessagesTableCompanion Function({
      required String id,
      required String peerId,
      required int timestamp,
      required String direction,
      required String status,
      required Uint8List data,
      Value<String?> roomId,
      Value<String?> channelId,
      Value<int> rowid,
    });
typedef $$MessagesTableTableUpdateCompanionBuilder =
    MessagesTableCompanion Function({
      Value<String> id,
      Value<String> peerId,
      Value<int> timestamp,
      Value<String> direction,
      Value<String> status,
      Value<Uint8List> data,
      Value<String?> roomId,
      Value<String?> channelId,
      Value<int> rowid,
    });

final class $$MessagesTableTableReferences
    extends BaseReferences<_$OrbitsDatabase, $MessagesTableTable, MessageRow> {
  $$MessagesTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $RoomChannelsTableTable _channelIdTable(_$OrbitsDatabase db) =>
      db.roomChannelsTable.createAlias(
        $_aliasNameGenerator(
          db.messagesTable.channelId,
          db.roomChannelsTable.id,
        ),
      );

  $$RoomChannelsTableTableProcessedTableManager? get channelId {
    final $_column = $_itemColumn<String>('channel_id');
    if ($_column == null) return null;
    final manager = $$RoomChannelsTableTableTableManager(
      $_db,
      $_db.roomChannelsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_channelIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessagesTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $MessagesTableTable> {
  $$MessagesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roomId => $composableBuilder(
    column: $table.roomId,
    builder: (column) => ColumnFilters(column),
  );

  $$RoomChannelsTableTableFilterComposer get channelId {
    final $$RoomChannelsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.channelId,
      referencedTable: $db.roomChannelsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomChannelsTableTableFilterComposer(
            $db: $db,
            $table: $db.roomChannelsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $MessagesTableTable> {
  $$MessagesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roomId => $composableBuilder(
    column: $table.roomId,
    builder: (column) => ColumnOrderings(column),
  );

  $$RoomChannelsTableTableOrderingComposer get channelId {
    final $$RoomChannelsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.channelId,
      referencedTable: $db.roomChannelsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomChannelsTableTableOrderingComposer(
            $db: $db,
            $table: $db.roomChannelsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $MessagesTableTable> {
  $$MessagesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  GeneratedColumn<String> get roomId =>
      $composableBuilder(column: $table.roomId, builder: (column) => column);

  $$RoomChannelsTableTableAnnotationComposer get channelId {
    final $$RoomChannelsTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.channelId,
          referencedTable: $db.roomChannelsTable,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$RoomChannelsTableTableAnnotationComposer(
                $db: $db,
                $table: $db.roomChannelsTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$MessagesTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $MessagesTableTable,
          MessageRow,
          $$MessagesTableTableFilterComposer,
          $$MessagesTableTableOrderingComposer,
          $$MessagesTableTableAnnotationComposer,
          $$MessagesTableTableCreateCompanionBuilder,
          $$MessagesTableTableUpdateCompanionBuilder,
          (MessageRow, $$MessagesTableTableReferences),
          MessageRow,
          PrefetchHooks Function({bool channelId})
        > {
  $$MessagesTableTableTableManager(
    _$OrbitsDatabase db,
    $MessagesTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> peerId = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
                Value<String> direction = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<String?> roomId = const Value.absent(),
                Value<String?> channelId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesTableCompanion(
                id: id,
                peerId: peerId,
                timestamp: timestamp,
                direction: direction,
                status: status,
                data: data,
                roomId: roomId,
                channelId: channelId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String peerId,
                required int timestamp,
                required String direction,
                required String status,
                required Uint8List data,
                Value<String?> roomId = const Value.absent(),
                Value<String?> channelId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesTableCompanion.insert(
                id: id,
                peerId: peerId,
                timestamp: timestamp,
                direction: direction,
                status: status,
                data: data,
                roomId: roomId,
                channelId: channelId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$MessagesTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({channelId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (channelId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.channelId,
                                referencedTable: $$MessagesTableTableReferences
                                    ._channelIdTable(db),
                                referencedColumn: $$MessagesTableTableReferences
                                    ._channelIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessagesTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $MessagesTableTable,
      MessageRow,
      $$MessagesTableTableFilterComposer,
      $$MessagesTableTableOrderingComposer,
      $$MessagesTableTableAnnotationComposer,
      $$MessagesTableTableCreateCompanionBuilder,
      $$MessagesTableTableUpdateCompanionBuilder,
      (MessageRow, $$MessagesTableTableReferences),
      MessageRow,
      PrefetchHooks Function({bool channelId})
    >;
typedef $$StickerPacksTableTableCreateCompanionBuilder =
    StickerPacksTableCompanion Function({
      required String id,
      Value<int> installedAt,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$StickerPacksTableTableUpdateCompanionBuilder =
    StickerPacksTableCompanion Function({
      Value<String> id,
      Value<int> installedAt,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$StickerPacksTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $StickerPacksTableTable> {
  $$StickerPacksTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get installedAt => $composableBuilder(
    column: $table.installedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StickerPacksTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $StickerPacksTableTable> {
  $$StickerPacksTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get installedAt => $composableBuilder(
    column: $table.installedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StickerPacksTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $StickerPacksTableTable> {
  $$StickerPacksTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get installedAt => $composableBuilder(
    column: $table.installedAt,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$StickerPacksTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $StickerPacksTableTable,
          StickerPackRow,
          $$StickerPacksTableTableFilterComposer,
          $$StickerPacksTableTableOrderingComposer,
          $$StickerPacksTableTableAnnotationComposer,
          $$StickerPacksTableTableCreateCompanionBuilder,
          $$StickerPacksTableTableUpdateCompanionBuilder,
          (
            StickerPackRow,
            BaseReferences<
              _$OrbitsDatabase,
              $StickerPacksTableTable,
              StickerPackRow
            >,
          ),
          StickerPackRow,
          PrefetchHooks Function()
        > {
  $$StickerPacksTableTableTableManager(
    _$OrbitsDatabase db,
    $StickerPacksTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StickerPacksTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StickerPacksTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StickerPacksTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> installedAt = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StickerPacksTableCompanion(
                id: id,
                installedAt: installedAt,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int> installedAt = const Value.absent(),
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => StickerPacksTableCompanion.insert(
                id: id,
                installedAt: installedAt,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StickerPacksTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $StickerPacksTableTable,
      StickerPackRow,
      $$StickerPacksTableTableFilterComposer,
      $$StickerPacksTableTableOrderingComposer,
      $$StickerPacksTableTableAnnotationComposer,
      $$StickerPacksTableTableCreateCompanionBuilder,
      $$StickerPacksTableTableUpdateCompanionBuilder,
      (
        StickerPackRow,
        BaseReferences<
          _$OrbitsDatabase,
          $StickerPacksTableTable,
          StickerPackRow
        >,
      ),
      StickerPackRow,
      PrefetchHooks Function()
    >;
typedef $$RecentStickersTableTableCreateCompanionBuilder =
    RecentStickersTableCompanion Function({
      required String key,
      required String packId,
      required String stickerId,
      Value<int> usedAt,
      Value<int> rowid,
    });
typedef $$RecentStickersTableTableUpdateCompanionBuilder =
    RecentStickersTableCompanion Function({
      Value<String> key,
      Value<String> packId,
      Value<String> stickerId,
      Value<int> usedAt,
      Value<int> rowid,
    });

class $$RecentStickersTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $RecentStickersTableTable> {
  $$RecentStickersTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get packId => $composableBuilder(
    column: $table.packId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stickerId => $composableBuilder(
    column: $table.stickerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get usedAt => $composableBuilder(
    column: $table.usedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecentStickersTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $RecentStickersTableTable> {
  $$RecentStickersTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get packId => $composableBuilder(
    column: $table.packId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stickerId => $composableBuilder(
    column: $table.stickerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get usedAt => $composableBuilder(
    column: $table.usedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecentStickersTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $RecentStickersTableTable> {
  $$RecentStickersTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get packId =>
      $composableBuilder(column: $table.packId, builder: (column) => column);

  GeneratedColumn<String> get stickerId =>
      $composableBuilder(column: $table.stickerId, builder: (column) => column);

  GeneratedColumn<int> get usedAt =>
      $composableBuilder(column: $table.usedAt, builder: (column) => column);
}

class $$RecentStickersTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $RecentStickersTableTable,
          RecentStickerRow,
          $$RecentStickersTableTableFilterComposer,
          $$RecentStickersTableTableOrderingComposer,
          $$RecentStickersTableTableAnnotationComposer,
          $$RecentStickersTableTableCreateCompanionBuilder,
          $$RecentStickersTableTableUpdateCompanionBuilder,
          (
            RecentStickerRow,
            BaseReferences<
              _$OrbitsDatabase,
              $RecentStickersTableTable,
              RecentStickerRow
            >,
          ),
          RecentStickerRow,
          PrefetchHooks Function()
        > {
  $$RecentStickersTableTableTableManager(
    _$OrbitsDatabase db,
    $RecentStickersTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecentStickersTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecentStickersTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$RecentStickersTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> packId = const Value.absent(),
                Value<String> stickerId = const Value.absent(),
                Value<int> usedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecentStickersTableCompanion(
                key: key,
                packId: packId,
                stickerId: stickerId,
                usedAt: usedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String packId,
                required String stickerId,
                Value<int> usedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecentStickersTableCompanion.insert(
                key: key,
                packId: packId,
                stickerId: stickerId,
                usedAt: usedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecentStickersTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $RecentStickersTableTable,
      RecentStickerRow,
      $$RecentStickersTableTableFilterComposer,
      $$RecentStickersTableTableOrderingComposer,
      $$RecentStickersTableTableAnnotationComposer,
      $$RecentStickersTableTableCreateCompanionBuilder,
      $$RecentStickersTableTableUpdateCompanionBuilder,
      (
        RecentStickerRow,
        BaseReferences<
          _$OrbitsDatabase,
          $RecentStickersTableTable,
          RecentStickerRow
        >,
      ),
      RecentStickerRow,
      PrefetchHooks Function()
    >;
typedef $$VoiceBlobsTableTableCreateCompanionBuilder =
    VoiceBlobsTableCompanion Function({
      required String id,
      Value<String> mime,
      Value<int> duration,
      Value<int> createdAt,
      required Uint8List bytes,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$VoiceBlobsTableTableUpdateCompanionBuilder =
    VoiceBlobsTableCompanion Function({
      Value<String> id,
      Value<String> mime,
      Value<int> duration,
      Value<int> createdAt,
      Value<Uint8List> bytes,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$VoiceBlobsTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $VoiceBlobsTableTable> {
  $$VoiceBlobsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VoiceBlobsTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $VoiceBlobsTableTable> {
  $$VoiceBlobsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VoiceBlobsTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $VoiceBlobsTableTable> {
  $$VoiceBlobsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get mime =>
      $composableBuilder(column: $table.mime, builder: (column) => column);

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$VoiceBlobsTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $VoiceBlobsTableTable,
          VoiceBlobRow,
          $$VoiceBlobsTableTableFilterComposer,
          $$VoiceBlobsTableTableOrderingComposer,
          $$VoiceBlobsTableTableAnnotationComposer,
          $$VoiceBlobsTableTableCreateCompanionBuilder,
          $$VoiceBlobsTableTableUpdateCompanionBuilder,
          (
            VoiceBlobRow,
            BaseReferences<
              _$OrbitsDatabase,
              $VoiceBlobsTableTable,
              VoiceBlobRow
            >,
          ),
          VoiceBlobRow,
          PrefetchHooks Function()
        > {
  $$VoiceBlobsTableTableTableManager(
    _$OrbitsDatabase db,
    $VoiceBlobsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VoiceBlobsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VoiceBlobsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VoiceBlobsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> mime = const Value.absent(),
                Value<int> duration = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<Uint8List> bytes = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VoiceBlobsTableCompanion(
                id: id,
                mime: mime,
                duration: duration,
                createdAt: createdAt,
                bytes: bytes,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> mime = const Value.absent(),
                Value<int> duration = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                required Uint8List bytes,
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => VoiceBlobsTableCompanion.insert(
                id: id,
                mime: mime,
                duration: duration,
                createdAt: createdAt,
                bytes: bytes,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VoiceBlobsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $VoiceBlobsTableTable,
      VoiceBlobRow,
      $$VoiceBlobsTableTableFilterComposer,
      $$VoiceBlobsTableTableOrderingComposer,
      $$VoiceBlobsTableTableAnnotationComposer,
      $$VoiceBlobsTableTableCreateCompanionBuilder,
      $$VoiceBlobsTableTableUpdateCompanionBuilder,
      (
        VoiceBlobRow,
        BaseReferences<_$OrbitsDatabase, $VoiceBlobsTableTable, VoiceBlobRow>,
      ),
      VoiceBlobRow,
      PrefetchHooks Function()
    >;
typedef $$FileBlobsTableTableCreateCompanionBuilder =
    FileBlobsTableCompanion Function({
      required String id,
      Value<String> mime,
      Value<String> name,
      Value<String> kind,
      Value<int> size,
      Value<int> width,
      Value<int> height,
      Value<int> duration,
      Value<int> createdAt,
      required Uint8List bytes,
      Value<Uint8List?> thumb,
      required Uint8List data,
      Value<int> rowid,
    });
typedef $$FileBlobsTableTableUpdateCompanionBuilder =
    FileBlobsTableCompanion Function({
      Value<String> id,
      Value<String> mime,
      Value<String> name,
      Value<String> kind,
      Value<int> size,
      Value<int> width,
      Value<int> height,
      Value<int> duration,
      Value<int> createdAt,
      Value<Uint8List> bytes,
      Value<Uint8List?> thumb,
      Value<Uint8List> data,
      Value<int> rowid,
    });

class $$FileBlobsTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $FileBlobsTableTable> {
  $$FileBlobsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get thumb => $composableBuilder(
    column: $table.thumb,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FileBlobsTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $FileBlobsTableTable> {
  $$FileBlobsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mime => $composableBuilder(
    column: $table.mime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get thumb => $composableBuilder(
    column: $table.thumb,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FileBlobsTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $FileBlobsTableTable> {
  $$FileBlobsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get mime =>
      $composableBuilder(column: $table.mime, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<Uint8List> get thumb =>
      $composableBuilder(column: $table.thumb, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$FileBlobsTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $FileBlobsTableTable,
          FileBlobRow,
          $$FileBlobsTableTableFilterComposer,
          $$FileBlobsTableTableOrderingComposer,
          $$FileBlobsTableTableAnnotationComposer,
          $$FileBlobsTableTableCreateCompanionBuilder,
          $$FileBlobsTableTableUpdateCompanionBuilder,
          (
            FileBlobRow,
            BaseReferences<_$OrbitsDatabase, $FileBlobsTableTable, FileBlobRow>,
          ),
          FileBlobRow,
          PrefetchHooks Function()
        > {
  $$FileBlobsTableTableTableManager(
    _$OrbitsDatabase db,
    $FileBlobsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FileBlobsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FileBlobsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FileBlobsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> mime = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> width = const Value.absent(),
                Value<int> height = const Value.absent(),
                Value<int> duration = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<Uint8List> bytes = const Value.absent(),
                Value<Uint8List?> thumb = const Value.absent(),
                Value<Uint8List> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FileBlobsTableCompanion(
                id: id,
                mime: mime,
                name: name,
                kind: kind,
                size: size,
                width: width,
                height: height,
                duration: duration,
                createdAt: createdAt,
                bytes: bytes,
                thumb: thumb,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> mime = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> width = const Value.absent(),
                Value<int> height = const Value.absent(),
                Value<int> duration = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                required Uint8List bytes,
                Value<Uint8List?> thumb = const Value.absent(),
                required Uint8List data,
                Value<int> rowid = const Value.absent(),
              }) => FileBlobsTableCompanion.insert(
                id: id,
                mime: mime,
                name: name,
                kind: kind,
                size: size,
                width: width,
                height: height,
                duration: duration,
                createdAt: createdAt,
                bytes: bytes,
                thumb: thumb,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FileBlobsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $FileBlobsTableTable,
      FileBlobRow,
      $$FileBlobsTableTableFilterComposer,
      $$FileBlobsTableTableOrderingComposer,
      $$FileBlobsTableTableAnnotationComposer,
      $$FileBlobsTableTableCreateCompanionBuilder,
      $$FileBlobsTableTableUpdateCompanionBuilder,
      (
        FileBlobRow,
        BaseReferences<_$OrbitsDatabase, $FileBlobsTableTable, FileBlobRow>,
      ),
      FileBlobRow,
      PrefetchHooks Function()
    >;
typedef $$KvTableTableCreateCompanionBuilder =
    KvTableCompanion Function({
      required String key,
      required Uint8List value,
      Value<int> rowid,
    });
typedef $$KvTableTableUpdateCompanionBuilder =
    KvTableCompanion Function({
      Value<String> key,
      Value<Uint8List> value,
      Value<int> rowid,
    });

class $$KvTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $KvTableTable> {
  $$KvTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KvTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $KvTableTable> {
  $$KvTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KvTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $KvTableTable> {
  $$KvTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<Uint8List> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$KvTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $KvTableTable,
          KvRow,
          $$KvTableTableFilterComposer,
          $$KvTableTableOrderingComposer,
          $$KvTableTableAnnotationComposer,
          $$KvTableTableCreateCompanionBuilder,
          $$KvTableTableUpdateCompanionBuilder,
          (KvRow, BaseReferences<_$OrbitsDatabase, $KvTableTable, KvRow>),
          KvRow,
          PrefetchHooks Function()
        > {
  $$KvTableTableTableManager(_$OrbitsDatabase db, $KvTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KvTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KvTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KvTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<Uint8List> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KvTableCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required Uint8List value,
                Value<int> rowid = const Value.absent(),
              }) =>
                  KvTableCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KvTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $KvTableTable,
      KvRow,
      $$KvTableTableFilterComposer,
      $$KvTableTableOrderingComposer,
      $$KvTableTableAnnotationComposer,
      $$KvTableTableCreateCompanionBuilder,
      $$KvTableTableUpdateCompanionBuilder,
      (KvRow, BaseReferences<_$OrbitsDatabase, $KvTableTable, KvRow>),
      KvRow,
      PrefetchHooks Function()
    >;
typedef $$RoomMembersTableTableCreateCompanionBuilder =
    RoomMembersTableCompanion Function({
      required String roomId,
      required String peerId,
      Value<String> displayName,
      Value<String?> avatarDataUrl,
      Value<bool> isOnline,
      Value<int> joinedAt,
      Value<int> rowid,
    });
typedef $$RoomMembersTableTableUpdateCompanionBuilder =
    RoomMembersTableCompanion Function({
      Value<String> roomId,
      Value<String> peerId,
      Value<String> displayName,
      Value<String?> avatarDataUrl,
      Value<bool> isOnline,
      Value<int> joinedAt,
      Value<int> rowid,
    });

final class $$RoomMembersTableTableReferences
    extends
        BaseReferences<
          _$OrbitsDatabase,
          $RoomMembersTableTable,
          RoomMemberRow
        > {
  $$RoomMembersTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $RoomsTableTable _roomIdTable(_$OrbitsDatabase db) =>
      db.roomsTable.createAlias(
        $_aliasNameGenerator(db.roomMembersTable.roomId, db.roomsTable.id),
      );

  $$RoomsTableTableProcessedTableManager get roomId {
    final $_column = $_itemColumn<String>('room_id')!;

    final manager = $$RoomsTableTableTableManager(
      $_db,
      $_db.roomsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_roomIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$RoomMembersTableTableFilterComposer
    extends Composer<_$OrbitsDatabase, $RoomMembersTableTable> {
  $$RoomMembersTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarDataUrl => $composableBuilder(
    column: $table.avatarDataUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isOnline => $composableBuilder(
    column: $table.isOnline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get joinedAt => $composableBuilder(
    column: $table.joinedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$RoomsTableTableFilterComposer get roomId {
    final $$RoomsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.roomId,
      referencedTable: $db.roomsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomsTableTableFilterComposer(
            $db: $db,
            $table: $db.roomsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RoomMembersTableTableOrderingComposer
    extends Composer<_$OrbitsDatabase, $RoomMembersTableTable> {
  $$RoomMembersTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get peerId => $composableBuilder(
    column: $table.peerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarDataUrl => $composableBuilder(
    column: $table.avatarDataUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isOnline => $composableBuilder(
    column: $table.isOnline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get joinedAt => $composableBuilder(
    column: $table.joinedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$RoomsTableTableOrderingComposer get roomId {
    final $$RoomsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.roomId,
      referencedTable: $db.roomsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomsTableTableOrderingComposer(
            $db: $db,
            $table: $db.roomsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RoomMembersTableTableAnnotationComposer
    extends Composer<_$OrbitsDatabase, $RoomMembersTableTable> {
  $$RoomMembersTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatarDataUrl => $composableBuilder(
    column: $table.avatarDataUrl,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isOnline =>
      $composableBuilder(column: $table.isOnline, builder: (column) => column);

  GeneratedColumn<int> get joinedAt =>
      $composableBuilder(column: $table.joinedAt, builder: (column) => column);

  $$RoomsTableTableAnnotationComposer get roomId {
    final $$RoomsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.roomId,
      referencedTable: $db.roomsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RoomsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.roomsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$RoomMembersTableTableTableManager
    extends
        RootTableManager<
          _$OrbitsDatabase,
          $RoomMembersTableTable,
          RoomMemberRow,
          $$RoomMembersTableTableFilterComposer,
          $$RoomMembersTableTableOrderingComposer,
          $$RoomMembersTableTableAnnotationComposer,
          $$RoomMembersTableTableCreateCompanionBuilder,
          $$RoomMembersTableTableUpdateCompanionBuilder,
          (RoomMemberRow, $$RoomMembersTableTableReferences),
          RoomMemberRow,
          PrefetchHooks Function({bool roomId})
        > {
  $$RoomMembersTableTableTableManager(
    _$OrbitsDatabase db,
    $RoomMembersTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RoomMembersTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RoomMembersTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RoomMembersTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> roomId = const Value.absent(),
                Value<String> peerId = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String?> avatarDataUrl = const Value.absent(),
                Value<bool> isOnline = const Value.absent(),
                Value<int> joinedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoomMembersTableCompanion(
                roomId: roomId,
                peerId: peerId,
                displayName: displayName,
                avatarDataUrl: avatarDataUrl,
                isOnline: isOnline,
                joinedAt: joinedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String roomId,
                required String peerId,
                Value<String> displayName = const Value.absent(),
                Value<String?> avatarDataUrl = const Value.absent(),
                Value<bool> isOnline = const Value.absent(),
                Value<int> joinedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RoomMembersTableCompanion.insert(
                roomId: roomId,
                peerId: peerId,
                displayName: displayName,
                avatarDataUrl: avatarDataUrl,
                isOnline: isOnline,
                joinedAt: joinedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$RoomMembersTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({roomId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (roomId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.roomId,
                                referencedTable:
                                    $$RoomMembersTableTableReferences
                                        ._roomIdTable(db),
                                referencedColumn:
                                    $$RoomMembersTableTableReferences
                                        ._roomIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$RoomMembersTableTableProcessedTableManager =
    ProcessedTableManager<
      _$OrbitsDatabase,
      $RoomMembersTableTable,
      RoomMemberRow,
      $$RoomMembersTableTableFilterComposer,
      $$RoomMembersTableTableOrderingComposer,
      $$RoomMembersTableTableAnnotationComposer,
      $$RoomMembersTableTableCreateCompanionBuilder,
      $$RoomMembersTableTableUpdateCompanionBuilder,
      (RoomMemberRow, $$RoomMembersTableTableReferences),
      RoomMemberRow,
      PrefetchHooks Function({bool roomId})
    >;

class $OrbitsDatabaseManager {
  final _$OrbitsDatabase _db;
  $OrbitsDatabaseManager(this._db);
  $$KeysTableTableTableManager get keysTable =>
      $$KeysTableTableTableManager(_db, _db.keysTable);
  $$PrekeysTableTableTableManager get prekeysTable =>
      $$PrekeysTableTableTableManager(_db, _db.prekeysTable);
  $$RatchetsTableTableTableManager get ratchetsTable =>
      $$RatchetsTableTableTableManager(_db, _db.ratchetsTable);
  $$PeersTableTableTableManager get peersTable =>
      $$PeersTableTableTableManager(_db, _db.peersTable);
  $$AvatarsTableTableTableManager get avatarsTable =>
      $$AvatarsTableTableTableManager(_db, _db.avatarsTable);
  $$SessionKeysTableTableTableManager get sessionKeysTable =>
      $$SessionKeysTableTableTableManager(_db, _db.sessionKeysTable);
  $$RoomsTableTableTableManager get roomsTable =>
      $$RoomsTableTableTableManager(_db, _db.roomsTable);
  $$RoomChannelsTableTableTableManager get roomChannelsTable =>
      $$RoomChannelsTableTableTableManager(_db, _db.roomChannelsTable);
  $$MessagesTableTableTableManager get messagesTable =>
      $$MessagesTableTableTableManager(_db, _db.messagesTable);
  $$StickerPacksTableTableTableManager get stickerPacksTable =>
      $$StickerPacksTableTableTableManager(_db, _db.stickerPacksTable);
  $$RecentStickersTableTableTableManager get recentStickersTable =>
      $$RecentStickersTableTableTableManager(_db, _db.recentStickersTable);
  $$VoiceBlobsTableTableTableManager get voiceBlobsTable =>
      $$VoiceBlobsTableTableTableManager(_db, _db.voiceBlobsTable);
  $$FileBlobsTableTableTableManager get fileBlobsTable =>
      $$FileBlobsTableTableTableManager(_db, _db.fileBlobsTable);
  $$KvTableTableTableManager get kvTable =>
      $$KvTableTableTableManager(_db, _db.kvTable);
  $$RoomMembersTableTableTableManager get roomMembersTable =>
      $$RoomMembersTableTableTableManager(_db, _db.roomMembersTable);
}
