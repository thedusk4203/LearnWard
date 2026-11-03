import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Test double for [LearningRepository] with deterministic in-memory state.
final class FakeLearningRepository implements LearningRepository {
  FakeLearningRepository({List<LearningNode>? initialNodes}) {
    if (initialNodes != null) {
      _nodes.addAll(initialNodes);
    } else {
      _seedPilotCatalog();
    }
  }

  final List<LearningNode> _nodes = [];
  final Map<String, List<AssessmentLearningMapping>> _mappings = {};
  final List<LearningEvidenceEvent> _evidence = [];
  final Map<String, Map<String, dynamic>> _receipts = {};
  final String _activeCatalogVersion = 'pilot-v0.1';

  void _seedPilotCatalog() {
    for (final s in ['math', 'english', 'literature', 'science', 'other']) {
      _nodes.add(
        LearningNode(
          id: LearningNodeId('node-root-$s'),
          catalogVersion: 'pilot-v0.1',
          nodeType: LearningNodeType.subject,
          subjectKey: s,
          canonicalKey: 'pilot-v0.1:subject:$s',
          title: s.toUpperCase(),
        ),
      );
    }
    // Seed sample Single Digit Addition skill node
    _nodes.add(
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition:single_digit',
        title: 'Single Digit Addition',
        parentId: LearningNodeId('node-root-math'),
      ),
    );
  }

  void addNode(LearningNode node) => _nodes.add(node);
  void addEvidence(LearningEvidenceEvent event) => _evidence.add(event);

  @override
  Future<List<LearningNode>> getCatalogNodes({
    required String catalogVersion,
    String? subjectKey,
  }) async {
    return _nodes.where((n) {
      if (n.catalogVersion != catalogVersion) return false;
      if (subjectKey != null && n.subjectKey != subjectKey) return false;
      return true;
    }).toList();
  }

  @override
  Future<List<AssessmentLearningMapping>> getAssessmentLearningMappings(
    AssessmentId assessmentId,
  ) async {
    return _mappings[assessmentId.value] ?? [];
  }

  @override
  Future<List<AssessmentLearningMapping>> setAssessmentLearningMappings({
    required AssessmentId assessmentId,
    required List<AssessmentLearningMapping> mappings,
  }) async {
    _mappings[assessmentId.value] = List.from(mappings);
    return _mappings[assessmentId.value]!;
  }

  @override
  Future<Map<String, dynamic>> processLearningEvent({
    required String commandId,
    required String verifiedLearningEventId,
  }) async {
    // 1. Replay check
    final existing = _receipts[commandId];
    if (existing != null) {
      return existing;
    }

    final result = <String, dynamic>{
      'command_id': commandId,
      'verified_learning_event_id': verifiedLearningEventId,
      'status': 'completed',
    };
    _receipts[commandId] = result;
    return result;
  }

  @override
  Future<Map<String, dynamic>> catchUpUnprocessedLearning(
    FamilyId familyId,
  ) async {
    return {
      'family_id': familyId.value,
      'processed_count': 0,
      'status': 'completed',
    };
  }

  @override
  Future<List<ChildMasteryProjection>> getChildMastery({
    required ChildId childId,
  }) async {
    final effectiveAsOf = DateTime.now().toUtc();
    final childEvidence = _evidence.where((e) => e.childId == childId).toList();
    final nodeIds = childEvidence.map((e) => e.learningNodeId).toSet();

    final projections = <ChildMasteryProjection>[];

    for (final nodeId in nodeIds) {
      final node = _nodes.firstWhere(
        (n) => n.id == nodeId,
        orElse: () => LearningNode(
          id: nodeId,
          catalogVersion: _activeCatalogVersion,
          nodeType: LearningNodeType.skill,
          subjectKey: 'math',
          canonicalKey: 'custom:$nodeId',
          title: 'Custom Node',
        ),
      );

      final nodeEv = childEvidence
          .where((e) => e.learningNodeId == nodeId)
          .toList();
      final rebuild = MasteryEngine.rebuildNodeMastery(nodeEv);
      final conf = ConfidenceEngine.evaluate(
        masteryScore: rebuild.masteryScore,
        evidence: nodeEv,
        asOf: effectiveAsOf,
      );

      projections.add(
        ChildMasteryProjection(
          childId: childId,
          learningNodeId: nodeId,
          nodeCanonicalKey: node.canonicalKey,
          nodeTitle: node.title,
          nodeType: node.nodeType,
          subjectKey: node.subjectKey,
          masteryScore: rebuild.masteryScore,
          distinctAssessmentCount: rebuild.distinctAssessmentCount,
          lastEvidenceOccurredAt: nodeEv.isNotEmpty
              ? nodeEv.last.effectiveOccurredAt
              : effectiveAsOf,
          confidenceBand: conf.confidenceBand,
          confidenceUnits: conf.confidenceUnits,
          masteryBand: conf.masteryBand,
          asOf: effectiveAsOf,
          updatedAt: effectiveAsOf,
        ),
      );
    }

    return projections;
  }
}
