/// Origin table for an actor-bound local outbox record.
enum LegacyOutboxRecordSource { assessmentDraft, rewardCommand }

/// Read-only projection of a local outbox record bearing a non-empty `actorUserId`.
final class ActorBoundOutboxRecord {
  const ActorBoundOutboxRecord({
    required this.source,
    required this.recordId,
    required this.familyId,
    required this.actorUserId,
    this.childId,
  });

  final LegacyOutboxRecordSource source;
  final String recordId;
  final String familyId;
  final String? childId;
  final String actorUserId;
}

/// Read-only port exposing actor-bound outbox provenance for legacy Child Mode ownership checks.
abstract interface class LegacyOutboxProvenanceSource {
  /// Lists local assessment drafts and pending reward commands whose `actorUserId` is non-empty.
  Future<List<ActorBoundOutboxRecord>> listActorBoundRecords();
}
