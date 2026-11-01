import '../value_objects/identifiers.dart';
import '../value_objects/rp_minor.dart';
import '../value_objects/xp_amount.dart';

/// Immutable entry in the authoritative append-only XP ledger.
final class XpLedgerEntry {
  const XpLedgerEntry({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.amount,
    required this.reasonCode,
    required this.sourceType,
    this.sourceId,
    this.engineVersion,
    required this.idempotencyKey,
    this.metadata = const {},
    required this.createdAt,
  });

  final String id;
  final FamilyId familyId;
  final ChildId childId;
  final XpAmount amount;
  final String reasonCode;
  final String sourceType;
  final String? sourceId;
  final String? engineVersion;
  final String idempotencyKey;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is XpLedgerEntry && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'XpLedgerEntry($id, child: $childId, amount: ${amount.value} XP, reason: $reasonCode)';
}

/// Immutable entry in the authoritative append-only RP ledger.
final class RpLedgerEntry {
  const RpLedgerEntry({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.amountMinor,
    required this.reasonCode,
    required this.sourceType,
    this.sourceId,
    this.engineVersion,
    required this.idempotencyKey,
    this.metadata = const {},
    required this.createdAt,
  });

  final String id;
  final FamilyId familyId;
  final ChildId childId;
  final RpMinor amountMinor;
  final String reasonCode;
  final String sourceType;
  final String? sourceId;
  final String? engineVersion;
  final String idempotencyKey;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RpLedgerEntry && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'RpLedgerEntry($id, child: $childId, amount: ${amountMinor.formatRp()} RP, reason: $reasonCode)';
}
