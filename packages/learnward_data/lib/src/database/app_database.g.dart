// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $LocalMetadataEntriesTable extends LocalMetadataEntries
    with TableInfo<$LocalMetadataEntriesTable, LocalMetadataEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMetadataEntriesTable(this.attachedDatabase, [this._alias]);
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
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_metadata_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalMetadataEntry> instance, {
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
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  LocalMetadataEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMetadataEntry(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LocalMetadataEntriesTable createAlias(String alias) {
    return $LocalMetadataEntriesTable(attachedDatabase, alias);
  }
}

class LocalMetadataEntry extends DataClass
    implements Insertable<LocalMetadataEntry> {
  final String key;
  final String value;
  final DateTime updatedAt;
  const LocalMetadataEntry({
    required this.key,
    required this.value,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LocalMetadataEntriesCompanion toCompanion(bool nullToAbsent) {
    return LocalMetadataEntriesCompanion(
      key: Value(key),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory LocalMetadataEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMetadataEntry(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  LocalMetadataEntry copyWith({
    String? key,
    String? value,
    DateTime? updatedAt,
  }) => LocalMetadataEntry(
    key: key ?? this.key,
    value: value ?? this.value,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LocalMetadataEntry copyWithCompanion(LocalMetadataEntriesCompanion data) {
    return LocalMetadataEntry(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMetadataEntry(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMetadataEntry &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class LocalMetadataEntriesCompanion
    extends UpdateCompanion<LocalMetadataEntry> {
  final Value<String> key;
  final Value<String> value;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const LocalMetadataEntriesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMetadataEntriesCompanion.insert({
    required String key,
    required String value,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value),
       updatedAt = Value(updatedAt);
  static Insertable<LocalMetadataEntry> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMetadataEntriesCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return LocalMetadataEntriesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
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
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMetadataEntriesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalAssessmentDraftsTable extends LocalAssessmentDrafts
    with TableInfo<$LocalAssessmentDraftsTable, LocalAssessmentDraftEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalAssessmentDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localDraftIdMeta = const VerificationMeta(
    'localDraftId',
  );
  @override
  late final GeneratedColumn<String> localDraftId = GeneratedColumn<String>(
    'local_draft_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _familyIdMeta = const VerificationMeta(
    'familyId',
  );
  @override
  late final GeneratedColumn<String> familyId = GeneratedColumn<String>(
    'family_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _childIdMeta = const VerificationMeta(
    'childId',
  );
  @override
  late final GeneratedColumn<String> childId = GeneratedColumn<String>(
    'child_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverAssessmentIdMeta =
      const VerificationMeta('serverAssessmentId');
  @override
  late final GeneratedColumn<String> serverAssessmentId =
      GeneratedColumn<String>(
        'server_assessment_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _subjectKeyMeta = const VerificationMeta(
    'subjectKey',
  );
  @override
  late final GeneratedColumn<String> subjectKey = GeneratedColumn<String>(
    'subject_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('math'),
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _assessmentTypeMeta = const VerificationMeta(
    'assessmentType',
  );
  @override
  late final GeneratedColumn<String> assessmentType = GeneratedColumn<String>(
    'assessment_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _difficultyMeta = const VerificationMeta(
    'difficulty',
  );
  @override
  late final GeneratedColumn<String> difficulty = GeneratedColumn<String>(
    'difficulty',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rawScoreMeta = const VerificationMeta(
    'rawScore',
  );
  @override
  late final GeneratedColumn<double> rawScore = GeneratedColumn<double>(
    'raw_score',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _maxScoreMeta = const VerificationMeta(
    'maxScore',
  );
  @override
  late final GeneratedColumn<double> maxScore = GeneratedColumn<double>(
    'max_score',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localPhotoPathMeta = const VerificationMeta(
    'localPhotoPath',
  );
  @override
  late final GeneratedColumn<String> localPhotoPath = GeneratedColumn<String>(
    'local_photo_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _entryContextMeta = const VerificationMeta(
    'entryContext',
  );
  @override
  late final GeneratedColumn<String> entryContext = GeneratedColumn<String>(
    'entry_context',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('shared_child'),
  );
  static const VerificationMeta _occurredAtMeta = const VerificationMeta(
    'occurredAt',
  );
  @override
  late final GeneratedColumn<DateTime> occurredAt = GeneratedColumn<DateTime>(
    'occurred_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    localDraftId,
    familyId,
    childId,
    serverAssessmentId,
    subjectKey,
    subject,
    title,
    assessmentType,
    difficulty,
    rawScore,
    maxScore,
    localPhotoPath,
    entryContext,
    occurredAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_assessment_drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalAssessmentDraftEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_draft_id')) {
      context.handle(
        _localDraftIdMeta,
        localDraftId.isAcceptableOrUnknown(
          data['local_draft_id']!,
          _localDraftIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localDraftIdMeta);
    }
    if (data.containsKey('family_id')) {
      context.handle(
        _familyIdMeta,
        familyId.isAcceptableOrUnknown(data['family_id']!, _familyIdMeta),
      );
    } else if (isInserting) {
      context.missing(_familyIdMeta);
    }
    if (data.containsKey('child_id')) {
      context.handle(
        _childIdMeta,
        childId.isAcceptableOrUnknown(data['child_id']!, _childIdMeta),
      );
    } else if (isInserting) {
      context.missing(_childIdMeta);
    }
    if (data.containsKey('server_assessment_id')) {
      context.handle(
        _serverAssessmentIdMeta,
        serverAssessmentId.isAcceptableOrUnknown(
          data['server_assessment_id']!,
          _serverAssessmentIdMeta,
        ),
      );
    }
    if (data.containsKey('subject_key')) {
      context.handle(
        _subjectKeyMeta,
        subjectKey.isAcceptableOrUnknown(data['subject_key']!, _subjectKeyMeta),
      );
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('assessment_type')) {
      context.handle(
        _assessmentTypeMeta,
        assessmentType.isAcceptableOrUnknown(
          data['assessment_type']!,
          _assessmentTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_assessmentTypeMeta);
    }
    if (data.containsKey('difficulty')) {
      context.handle(
        _difficultyMeta,
        difficulty.isAcceptableOrUnknown(data['difficulty']!, _difficultyMeta),
      );
    } else if (isInserting) {
      context.missing(_difficultyMeta);
    }
    if (data.containsKey('raw_score')) {
      context.handle(
        _rawScoreMeta,
        rawScore.isAcceptableOrUnknown(data['raw_score']!, _rawScoreMeta),
      );
    } else if (isInserting) {
      context.missing(_rawScoreMeta);
    }
    if (data.containsKey('max_score')) {
      context.handle(
        _maxScoreMeta,
        maxScore.isAcceptableOrUnknown(data['max_score']!, _maxScoreMeta),
      );
    } else if (isInserting) {
      context.missing(_maxScoreMeta);
    }
    if (data.containsKey('local_photo_path')) {
      context.handle(
        _localPhotoPathMeta,
        localPhotoPath.isAcceptableOrUnknown(
          data['local_photo_path']!,
          _localPhotoPathMeta,
        ),
      );
    }
    if (data.containsKey('entry_context')) {
      context.handle(
        _entryContextMeta,
        entryContext.isAcceptableOrUnknown(
          data['entry_context']!,
          _entryContextMeta,
        ),
      );
    }
    if (data.containsKey('occurred_at')) {
      context.handle(
        _occurredAtMeta,
        occurredAt.isAcceptableOrUnknown(data['occurred_at']!, _occurredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_occurredAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localDraftId};
  @override
  LocalAssessmentDraftEntry map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalAssessmentDraftEntry(
      localDraftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_draft_id'],
      )!,
      familyId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}family_id'],
      )!,
      childId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}child_id'],
      )!,
      serverAssessmentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_assessment_id'],
      ),
      subjectKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_key'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      assessmentType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}assessment_type'],
      )!,
      difficulty: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}difficulty'],
      )!,
      rawScore: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}raw_score'],
      )!,
      maxScore: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}max_score'],
      )!,
      localPhotoPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_photo_path'],
      ),
      entryContext: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry_context'],
      )!,
      occurredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}occurred_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LocalAssessmentDraftsTable createAlias(String alias) {
    return $LocalAssessmentDraftsTable(attachedDatabase, alias);
  }
}

class LocalAssessmentDraftEntry extends DataClass
    implements Insertable<LocalAssessmentDraftEntry> {
  final String localDraftId;
  final String familyId;
  final String childId;
  final String? serverAssessmentId;
  final String subjectKey;
  final String subject;
  final String title;
  final String assessmentType;
  final String difficulty;
  final double rawScore;
  final double maxScore;
  final String? localPhotoPath;
  final String entryContext;
  final DateTime occurredAt;
  final DateTime updatedAt;
  const LocalAssessmentDraftEntry({
    required this.localDraftId,
    required this.familyId,
    required this.childId,
    this.serverAssessmentId,
    required this.subjectKey,
    required this.subject,
    required this.title,
    required this.assessmentType,
    required this.difficulty,
    required this.rawScore,
    required this.maxScore,
    this.localPhotoPath,
    required this.entryContext,
    required this.occurredAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_draft_id'] = Variable<String>(localDraftId);
    map['family_id'] = Variable<String>(familyId);
    map['child_id'] = Variable<String>(childId);
    if (!nullToAbsent || serverAssessmentId != null) {
      map['server_assessment_id'] = Variable<String>(serverAssessmentId);
    }
    map['subject_key'] = Variable<String>(subjectKey);
    map['subject'] = Variable<String>(subject);
    map['title'] = Variable<String>(title);
    map['assessment_type'] = Variable<String>(assessmentType);
    map['difficulty'] = Variable<String>(difficulty);
    map['raw_score'] = Variable<double>(rawScore);
    map['max_score'] = Variable<double>(maxScore);
    if (!nullToAbsent || localPhotoPath != null) {
      map['local_photo_path'] = Variable<String>(localPhotoPath);
    }
    map['entry_context'] = Variable<String>(entryContext);
    map['occurred_at'] = Variable<DateTime>(occurredAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LocalAssessmentDraftsCompanion toCompanion(bool nullToAbsent) {
    return LocalAssessmentDraftsCompanion(
      localDraftId: Value(localDraftId),
      familyId: Value(familyId),
      childId: Value(childId),
      serverAssessmentId: serverAssessmentId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverAssessmentId),
      subjectKey: Value(subjectKey),
      subject: Value(subject),
      title: Value(title),
      assessmentType: Value(assessmentType),
      difficulty: Value(difficulty),
      rawScore: Value(rawScore),
      maxScore: Value(maxScore),
      localPhotoPath: localPhotoPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPhotoPath),
      entryContext: Value(entryContext),
      occurredAt: Value(occurredAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory LocalAssessmentDraftEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalAssessmentDraftEntry(
      localDraftId: serializer.fromJson<String>(json['localDraftId']),
      familyId: serializer.fromJson<String>(json['familyId']),
      childId: serializer.fromJson<String>(json['childId']),
      serverAssessmentId: serializer.fromJson<String?>(
        json['serverAssessmentId'],
      ),
      subjectKey: serializer.fromJson<String>(json['subjectKey']),
      subject: serializer.fromJson<String>(json['subject']),
      title: serializer.fromJson<String>(json['title']),
      assessmentType: serializer.fromJson<String>(json['assessmentType']),
      difficulty: serializer.fromJson<String>(json['difficulty']),
      rawScore: serializer.fromJson<double>(json['rawScore']),
      maxScore: serializer.fromJson<double>(json['maxScore']),
      localPhotoPath: serializer.fromJson<String?>(json['localPhotoPath']),
      entryContext: serializer.fromJson<String>(json['entryContext']),
      occurredAt: serializer.fromJson<DateTime>(json['occurredAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localDraftId': serializer.toJson<String>(localDraftId),
      'familyId': serializer.toJson<String>(familyId),
      'childId': serializer.toJson<String>(childId),
      'serverAssessmentId': serializer.toJson<String?>(serverAssessmentId),
      'subjectKey': serializer.toJson<String>(subjectKey),
      'subject': serializer.toJson<String>(subject),
      'title': serializer.toJson<String>(title),
      'assessmentType': serializer.toJson<String>(assessmentType),
      'difficulty': serializer.toJson<String>(difficulty),
      'rawScore': serializer.toJson<double>(rawScore),
      'maxScore': serializer.toJson<double>(maxScore),
      'localPhotoPath': serializer.toJson<String?>(localPhotoPath),
      'entryContext': serializer.toJson<String>(entryContext),
      'occurredAt': serializer.toJson<DateTime>(occurredAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  LocalAssessmentDraftEntry copyWith({
    String? localDraftId,
    String? familyId,
    String? childId,
    Value<String?> serverAssessmentId = const Value.absent(),
    String? subjectKey,
    String? subject,
    String? title,
    String? assessmentType,
    String? difficulty,
    double? rawScore,
    double? maxScore,
    Value<String?> localPhotoPath = const Value.absent(),
    String? entryContext,
    DateTime? occurredAt,
    DateTime? updatedAt,
  }) => LocalAssessmentDraftEntry(
    localDraftId: localDraftId ?? this.localDraftId,
    familyId: familyId ?? this.familyId,
    childId: childId ?? this.childId,
    serverAssessmentId: serverAssessmentId.present
        ? serverAssessmentId.value
        : this.serverAssessmentId,
    subjectKey: subjectKey ?? this.subjectKey,
    subject: subject ?? this.subject,
    title: title ?? this.title,
    assessmentType: assessmentType ?? this.assessmentType,
    difficulty: difficulty ?? this.difficulty,
    rawScore: rawScore ?? this.rawScore,
    maxScore: maxScore ?? this.maxScore,
    localPhotoPath: localPhotoPath.present
        ? localPhotoPath.value
        : this.localPhotoPath,
    entryContext: entryContext ?? this.entryContext,
    occurredAt: occurredAt ?? this.occurredAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LocalAssessmentDraftEntry copyWithCompanion(
    LocalAssessmentDraftsCompanion data,
  ) {
    return LocalAssessmentDraftEntry(
      localDraftId: data.localDraftId.present
          ? data.localDraftId.value
          : this.localDraftId,
      familyId: data.familyId.present ? data.familyId.value : this.familyId,
      childId: data.childId.present ? data.childId.value : this.childId,
      serverAssessmentId: data.serverAssessmentId.present
          ? data.serverAssessmentId.value
          : this.serverAssessmentId,
      subjectKey: data.subjectKey.present
          ? data.subjectKey.value
          : this.subjectKey,
      subject: data.subject.present ? data.subject.value : this.subject,
      title: data.title.present ? data.title.value : this.title,
      assessmentType: data.assessmentType.present
          ? data.assessmentType.value
          : this.assessmentType,
      difficulty: data.difficulty.present
          ? data.difficulty.value
          : this.difficulty,
      rawScore: data.rawScore.present ? data.rawScore.value : this.rawScore,
      maxScore: data.maxScore.present ? data.maxScore.value : this.maxScore,
      localPhotoPath: data.localPhotoPath.present
          ? data.localPhotoPath.value
          : this.localPhotoPath,
      entryContext: data.entryContext.present
          ? data.entryContext.value
          : this.entryContext,
      occurredAt: data.occurredAt.present
          ? data.occurredAt.value
          : this.occurredAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalAssessmentDraftEntry(')
          ..write('localDraftId: $localDraftId, ')
          ..write('familyId: $familyId, ')
          ..write('childId: $childId, ')
          ..write('serverAssessmentId: $serverAssessmentId, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('subject: $subject, ')
          ..write('title: $title, ')
          ..write('assessmentType: $assessmentType, ')
          ..write('difficulty: $difficulty, ')
          ..write('rawScore: $rawScore, ')
          ..write('maxScore: $maxScore, ')
          ..write('localPhotoPath: $localPhotoPath, ')
          ..write('entryContext: $entryContext, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    localDraftId,
    familyId,
    childId,
    serverAssessmentId,
    subjectKey,
    subject,
    title,
    assessmentType,
    difficulty,
    rawScore,
    maxScore,
    localPhotoPath,
    entryContext,
    occurredAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalAssessmentDraftEntry &&
          other.localDraftId == this.localDraftId &&
          other.familyId == this.familyId &&
          other.childId == this.childId &&
          other.serverAssessmentId == this.serverAssessmentId &&
          other.subjectKey == this.subjectKey &&
          other.subject == this.subject &&
          other.title == this.title &&
          other.assessmentType == this.assessmentType &&
          other.difficulty == this.difficulty &&
          other.rawScore == this.rawScore &&
          other.maxScore == this.maxScore &&
          other.localPhotoPath == this.localPhotoPath &&
          other.entryContext == this.entryContext &&
          other.occurredAt == this.occurredAt &&
          other.updatedAt == this.updatedAt);
}

class LocalAssessmentDraftsCompanion
    extends UpdateCompanion<LocalAssessmentDraftEntry> {
  final Value<String> localDraftId;
  final Value<String> familyId;
  final Value<String> childId;
  final Value<String?> serverAssessmentId;
  final Value<String> subjectKey;
  final Value<String> subject;
  final Value<String> title;
  final Value<String> assessmentType;
  final Value<String> difficulty;
  final Value<double> rawScore;
  final Value<double> maxScore;
  final Value<String?> localPhotoPath;
  final Value<String> entryContext;
  final Value<DateTime> occurredAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const LocalAssessmentDraftsCompanion({
    this.localDraftId = const Value.absent(),
    this.familyId = const Value.absent(),
    this.childId = const Value.absent(),
    this.serverAssessmentId = const Value.absent(),
    this.subjectKey = const Value.absent(),
    this.subject = const Value.absent(),
    this.title = const Value.absent(),
    this.assessmentType = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.rawScore = const Value.absent(),
    this.maxScore = const Value.absent(),
    this.localPhotoPath = const Value.absent(),
    this.entryContext = const Value.absent(),
    this.occurredAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalAssessmentDraftsCompanion.insert({
    required String localDraftId,
    required String familyId,
    required String childId,
    this.serverAssessmentId = const Value.absent(),
    this.subjectKey = const Value.absent(),
    required String subject,
    required String title,
    required String assessmentType,
    required String difficulty,
    required double rawScore,
    required double maxScore,
    this.localPhotoPath = const Value.absent(),
    this.entryContext = const Value.absent(),
    required DateTime occurredAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : localDraftId = Value(localDraftId),
       familyId = Value(familyId),
       childId = Value(childId),
       subject = Value(subject),
       title = Value(title),
       assessmentType = Value(assessmentType),
       difficulty = Value(difficulty),
       rawScore = Value(rawScore),
       maxScore = Value(maxScore),
       occurredAt = Value(occurredAt),
       updatedAt = Value(updatedAt);
  static Insertable<LocalAssessmentDraftEntry> custom({
    Expression<String>? localDraftId,
    Expression<String>? familyId,
    Expression<String>? childId,
    Expression<String>? serverAssessmentId,
    Expression<String>? subjectKey,
    Expression<String>? subject,
    Expression<String>? title,
    Expression<String>? assessmentType,
    Expression<String>? difficulty,
    Expression<double>? rawScore,
    Expression<double>? maxScore,
    Expression<String>? localPhotoPath,
    Expression<String>? entryContext,
    Expression<DateTime>? occurredAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localDraftId != null) 'local_draft_id': localDraftId,
      if (familyId != null) 'family_id': familyId,
      if (childId != null) 'child_id': childId,
      if (serverAssessmentId != null)
        'server_assessment_id': serverAssessmentId,
      if (subjectKey != null) 'subject_key': subjectKey,
      if (subject != null) 'subject': subject,
      if (title != null) 'title': title,
      if (assessmentType != null) 'assessment_type': assessmentType,
      if (difficulty != null) 'difficulty': difficulty,
      if (rawScore != null) 'raw_score': rawScore,
      if (maxScore != null) 'max_score': maxScore,
      if (localPhotoPath != null) 'local_photo_path': localPhotoPath,
      if (entryContext != null) 'entry_context': entryContext,
      if (occurredAt != null) 'occurred_at': occurredAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalAssessmentDraftsCompanion copyWith({
    Value<String>? localDraftId,
    Value<String>? familyId,
    Value<String>? childId,
    Value<String?>? serverAssessmentId,
    Value<String>? subjectKey,
    Value<String>? subject,
    Value<String>? title,
    Value<String>? assessmentType,
    Value<String>? difficulty,
    Value<double>? rawScore,
    Value<double>? maxScore,
    Value<String?>? localPhotoPath,
    Value<String>? entryContext,
    Value<DateTime>? occurredAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return LocalAssessmentDraftsCompanion(
      localDraftId: localDraftId ?? this.localDraftId,
      familyId: familyId ?? this.familyId,
      childId: childId ?? this.childId,
      serverAssessmentId: serverAssessmentId ?? this.serverAssessmentId,
      subjectKey: subjectKey ?? this.subjectKey,
      subject: subject ?? this.subject,
      title: title ?? this.title,
      assessmentType: assessmentType ?? this.assessmentType,
      difficulty: difficulty ?? this.difficulty,
      rawScore: rawScore ?? this.rawScore,
      maxScore: maxScore ?? this.maxScore,
      localPhotoPath: localPhotoPath ?? this.localPhotoPath,
      entryContext: entryContext ?? this.entryContext,
      occurredAt: occurredAt ?? this.occurredAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localDraftId.present) {
      map['local_draft_id'] = Variable<String>(localDraftId.value);
    }
    if (familyId.present) {
      map['family_id'] = Variable<String>(familyId.value);
    }
    if (childId.present) {
      map['child_id'] = Variable<String>(childId.value);
    }
    if (serverAssessmentId.present) {
      map['server_assessment_id'] = Variable<String>(serverAssessmentId.value);
    }
    if (subjectKey.present) {
      map['subject_key'] = Variable<String>(subjectKey.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (assessmentType.present) {
      map['assessment_type'] = Variable<String>(assessmentType.value);
    }
    if (difficulty.present) {
      map['difficulty'] = Variable<String>(difficulty.value);
    }
    if (rawScore.present) {
      map['raw_score'] = Variable<double>(rawScore.value);
    }
    if (maxScore.present) {
      map['max_score'] = Variable<double>(maxScore.value);
    }
    if (localPhotoPath.present) {
      map['local_photo_path'] = Variable<String>(localPhotoPath.value);
    }
    if (entryContext.present) {
      map['entry_context'] = Variable<String>(entryContext.value);
    }
    if (occurredAt.present) {
      map['occurred_at'] = Variable<DateTime>(occurredAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalAssessmentDraftsCompanion(')
          ..write('localDraftId: $localDraftId, ')
          ..write('familyId: $familyId, ')
          ..write('childId: $childId, ')
          ..write('serverAssessmentId: $serverAssessmentId, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('subject: $subject, ')
          ..write('title: $title, ')
          ..write('assessmentType: $assessmentType, ')
          ..write('difficulty: $difficulty, ')
          ..write('rawScore: $rawScore, ')
          ..write('maxScore: $maxScore, ')
          ..write('localPhotoPath: $localPhotoPath, ')
          ..write('entryContext: $entryContext, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $LocalMetadataEntriesTable localMetadataEntries =
      $LocalMetadataEntriesTable(this);
  late final $LocalAssessmentDraftsTable localAssessmentDrafts =
      $LocalAssessmentDraftsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localMetadataEntries,
    localAssessmentDrafts,
  ];
}

typedef $$LocalMetadataEntriesTableCreateCompanionBuilder =
    LocalMetadataEntriesCompanion Function({
      required String key,
      required String value,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$LocalMetadataEntriesTableUpdateCompanionBuilder =
    LocalMetadataEntriesCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$LocalMetadataEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalMetadataEntriesTable> {
  $$LocalMetadataEntriesTableFilterComposer({
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

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalMetadataEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalMetadataEntriesTable> {
  $$LocalMetadataEntriesTableOrderingComposer({
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

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalMetadataEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalMetadataEntriesTable> {
  $$LocalMetadataEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LocalMetadataEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalMetadataEntriesTable,
          LocalMetadataEntry,
          $$LocalMetadataEntriesTableFilterComposer,
          $$LocalMetadataEntriesTableOrderingComposer,
          $$LocalMetadataEntriesTableAnnotationComposer,
          $$LocalMetadataEntriesTableCreateCompanionBuilder,
          $$LocalMetadataEntriesTableUpdateCompanionBuilder,
          (
            LocalMetadataEntry,
            BaseReferences<
              _$AppDatabase,
              $LocalMetadataEntriesTable,
              LocalMetadataEntry
            >,
          ),
          LocalMetadataEntry,
          PrefetchHooks Function()
        > {
  $$LocalMetadataEntriesTableTableManager(
    _$AppDatabase db,
    $LocalMetadataEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMetadataEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMetadataEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalMetadataEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalMetadataEntriesCompanion(
                key: key,
                value: value,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalMetadataEntriesCompanion.insert(
                key: key,
                value: value,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalMetadataEntriesTable, LocalMetadataEntry>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalMetadataEntriesTable,
                    LocalMetadataEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalMetadataEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalMetadataEntriesTable,
      LocalMetadataEntry,
      $$LocalMetadataEntriesTableFilterComposer,
      $$LocalMetadataEntriesTableOrderingComposer,
      $$LocalMetadataEntriesTableAnnotationComposer,
      $$LocalMetadataEntriesTableCreateCompanionBuilder,
      $$LocalMetadataEntriesTableUpdateCompanionBuilder,
      (
        LocalMetadataEntry,
        BaseReferences<
          _$AppDatabase,
          $LocalMetadataEntriesTable,
          LocalMetadataEntry
        >,
      ),
      LocalMetadataEntry,
      PrefetchHooks Function()
    >;
typedef $$LocalAssessmentDraftsTableCreateCompanionBuilder =
    LocalAssessmentDraftsCompanion Function({
      required String localDraftId,
      required String familyId,
      required String childId,
      Value<String?> serverAssessmentId,
      Value<String> subjectKey,
      required String subject,
      required String title,
      required String assessmentType,
      required String difficulty,
      required double rawScore,
      required double maxScore,
      Value<String?> localPhotoPath,
      Value<String> entryContext,
      required DateTime occurredAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$LocalAssessmentDraftsTableUpdateCompanionBuilder =
    LocalAssessmentDraftsCompanion Function({
      Value<String> localDraftId,
      Value<String> familyId,
      Value<String> childId,
      Value<String?> serverAssessmentId,
      Value<String> subjectKey,
      Value<String> subject,
      Value<String> title,
      Value<String> assessmentType,
      Value<String> difficulty,
      Value<double> rawScore,
      Value<double> maxScore,
      Value<String?> localPhotoPath,
      Value<String> entryContext,
      Value<DateTime> occurredAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$LocalAssessmentDraftsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalAssessmentDraftsTable> {
  $$LocalAssessmentDraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get localDraftId => $composableBuilder(
    column: $table.localDraftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get familyId => $composableBuilder(
    column: $table.familyId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get childId => $composableBuilder(
    column: $table.childId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverAssessmentId => $composableBuilder(
    column: $table.serverAssessmentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get assessmentType => $composableBuilder(
    column: $table.assessmentType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rawScore => $composableBuilder(
    column: $table.rawScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get maxScore => $composableBuilder(
    column: $table.maxScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPhotoPath => $composableBuilder(
    column: $table.localPhotoPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entryContext => $composableBuilder(
    column: $table.entryContext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalAssessmentDraftsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalAssessmentDraftsTable> {
  $$LocalAssessmentDraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get localDraftId => $composableBuilder(
    column: $table.localDraftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get familyId => $composableBuilder(
    column: $table.familyId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get childId => $composableBuilder(
    column: $table.childId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverAssessmentId => $composableBuilder(
    column: $table.serverAssessmentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get assessmentType => $composableBuilder(
    column: $table.assessmentType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rawScore => $composableBuilder(
    column: $table.rawScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get maxScore => $composableBuilder(
    column: $table.maxScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPhotoPath => $composableBuilder(
    column: $table.localPhotoPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entryContext => $composableBuilder(
    column: $table.entryContext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalAssessmentDraftsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalAssessmentDraftsTable> {
  $$LocalAssessmentDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get localDraftId => $composableBuilder(
    column: $table.localDraftId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get familyId =>
      $composableBuilder(column: $table.familyId, builder: (column) => column);

  GeneratedColumn<String> get childId =>
      $composableBuilder(column: $table.childId, builder: (column) => column);

  GeneratedColumn<String> get serverAssessmentId => $composableBuilder(
    column: $table.serverAssessmentId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get assessmentType => $composableBuilder(
    column: $table.assessmentType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => column,
  );

  GeneratedColumn<double> get rawScore =>
      $composableBuilder(column: $table.rawScore, builder: (column) => column);

  GeneratedColumn<double> get maxScore =>
      $composableBuilder(column: $table.maxScore, builder: (column) => column);

  GeneratedColumn<String> get localPhotoPath => $composableBuilder(
    column: $table.localPhotoPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entryContext => $composableBuilder(
    column: $table.entryContext,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LocalAssessmentDraftsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalAssessmentDraftsTable,
          LocalAssessmentDraftEntry,
          $$LocalAssessmentDraftsTableFilterComposer,
          $$LocalAssessmentDraftsTableOrderingComposer,
          $$LocalAssessmentDraftsTableAnnotationComposer,
          $$LocalAssessmentDraftsTableCreateCompanionBuilder,
          $$LocalAssessmentDraftsTableUpdateCompanionBuilder,
          (
            LocalAssessmentDraftEntry,
            BaseReferences<
              _$AppDatabase,
              $LocalAssessmentDraftsTable,
              LocalAssessmentDraftEntry
            >,
          ),
          LocalAssessmentDraftEntry,
          PrefetchHooks Function()
        > {
  $$LocalAssessmentDraftsTableTableManager(
    _$AppDatabase db,
    $LocalAssessmentDraftsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalAssessmentDraftsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$LocalAssessmentDraftsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalAssessmentDraftsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> localDraftId = const Value.absent(),
                Value<String> familyId = const Value.absent(),
                Value<String> childId = const Value.absent(),
                Value<String?> serverAssessmentId = const Value.absent(),
                Value<String> subjectKey = const Value.absent(),
                Value<String> subject = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> assessmentType = const Value.absent(),
                Value<String> difficulty = const Value.absent(),
                Value<double> rawScore = const Value.absent(),
                Value<double> maxScore = const Value.absent(),
                Value<String?> localPhotoPath = const Value.absent(),
                Value<String> entryContext = const Value.absent(),
                Value<DateTime> occurredAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalAssessmentDraftsCompanion(
                localDraftId: localDraftId,
                familyId: familyId,
                childId: childId,
                serverAssessmentId: serverAssessmentId,
                subjectKey: subjectKey,
                subject: subject,
                title: title,
                assessmentType: assessmentType,
                difficulty: difficulty,
                rawScore: rawScore,
                maxScore: maxScore,
                localPhotoPath: localPhotoPath,
                entryContext: entryContext,
                occurredAt: occurredAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String localDraftId,
                required String familyId,
                required String childId,
                Value<String?> serverAssessmentId = const Value.absent(),
                Value<String> subjectKey = const Value.absent(),
                required String subject,
                required String title,
                required String assessmentType,
                required String difficulty,
                required double rawScore,
                required double maxScore,
                Value<String?> localPhotoPath = const Value.absent(),
                Value<String> entryContext = const Value.absent(),
                required DateTime occurredAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalAssessmentDraftsCompanion.insert(
                localDraftId: localDraftId,
                familyId: familyId,
                childId: childId,
                serverAssessmentId: serverAssessmentId,
                subjectKey: subjectKey,
                subject: subject,
                title: title,
                assessmentType: assessmentType,
                difficulty: difficulty,
                rawScore: rawScore,
                maxScore: maxScore,
                localPhotoPath: localPhotoPath,
                entryContext: entryContext,
                occurredAt: occurredAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $LocalAssessmentDraftsTable,
                    LocalAssessmentDraftEntry
                  >(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalAssessmentDraftsTable,
                    LocalAssessmentDraftEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalAssessmentDraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalAssessmentDraftsTable,
      LocalAssessmentDraftEntry,
      $$LocalAssessmentDraftsTableFilterComposer,
      $$LocalAssessmentDraftsTableOrderingComposer,
      $$LocalAssessmentDraftsTableAnnotationComposer,
      $$LocalAssessmentDraftsTableCreateCompanionBuilder,
      $$LocalAssessmentDraftsTableUpdateCompanionBuilder,
      (
        LocalAssessmentDraftEntry,
        BaseReferences<
          _$AppDatabase,
          $LocalAssessmentDraftsTable,
          LocalAssessmentDraftEntry
        >,
      ),
      LocalAssessmentDraftEntry,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalMetadataEntriesTableTableManager get localMetadataEntries =>
      $$LocalMetadataEntriesTableTableManager(_db, _db.localMetadataEntries);
  $$LocalAssessmentDraftsTableTableManager get localAssessmentDrafts =>
      $$LocalAssessmentDraftsTableTableManager(_db, _db.localAssessmentDrafts);
}
