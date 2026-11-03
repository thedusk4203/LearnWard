import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Test double for [LearningRepository] with deterministic in-memory state.
final class FakeLearningRepository implements LearningRepository {
  FakeLearningRepository({
    List<LearningNode>? initialNodes,
    List<LearningPrerequisite>? initialPrerequisites,
    this.clock,
    this.defaultSchoolGrade = 2,
  }) {
    if (initialNodes != null) {
      _nodes.addAll(initialNodes);
    } else {
      _seedPilotCatalog();
    }
    if (initialPrerequisites != null) {
      _prerequisites
        ..clear()
        ..addAll(initialPrerequisites);
    }
  }

  final List<LearningNode> _nodes = [];
  final List<LearningPrerequisite> _prerequisites = [];
  final Map<String, List<AssessmentLearningMapping>> _mappings = {};
  final List<LearningEvidenceEvent> _evidence = [];
  final Map<String, ChildMasteryState> _masteryStates = {};
  final Map<String, int?> _childSchoolGrades = {};
  final Map<String, Map<String, dynamic>> _receipts = {};
  String _activeCatalogVersion = 'pilot-v0.1';
  final DateTime Function()? clock;
  int? defaultSchoolGrade;

  DateTime _nowUtc() => (clock != null ? clock!() : DateTime.now()).toUtc();

  void _seedPilotCatalog() {
    const subjects = <(String, String, int)>[
      ('math', 'Mathematics', 1),
      ('english', 'English Language', 2),
      ('literature', 'Literature & Reading', 3),
      ('science', 'Natural Sciences', 4),
      ('other', 'Other Subjects', 5),
    ];
    for (final (key, title, sortOrder) in subjects) {
      _nodes.add(
        LearningNode(
          id: LearningNodeId('node-root-$key'),
          catalogVersion: 'pilot-v0.1',
          nodeType: LearningNodeType.subject,
          subjectKey: key,
          canonicalKey: 'pilot-v0.1:subject:$key',
          title: title,
          sortOrder: sortOrder,
        ),
      );
    }

    _nodes.addAll([
      LearningNode(
        id: LearningNodeId('b0000001-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.domain,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic',
        title: 'Arithmetic & Numbers',
        parentId: LearningNodeId('node-root-math'),
        gradeMin: 1,
        gradeMax: 6,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.topic,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition',
        title: 'Addition Operations',
        parentId: LearningNodeId('b0000001-0000-0000-0000-000000000001'),
        gradeMin: 1,
        gradeMax: 4,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition:single_digit',
        title: 'Single Digit Addition',
        parentId: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
        gradeMin: 1,
        gradeMax: 2,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000002'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition:double_digit',
        title: 'Double Digit Addition',
        parentId: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
        gradeMin: 2,
        gradeMax: 4,
        sortOrder: 2,
      ),
      LearningNode(
        id: LearningNodeId('b0000001-0000-0000-0000-000000000002'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.domain,
        subjectKey: 'english',
        canonicalKey: 'pilot-v0.1:english:grammar',
        title: 'Grammar & Mechanics',
        parentId: LearningNodeId('node-root-english'),
        gradeMin: 1,
        gradeMax: 8,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000002-0000-0000-0000-000000000002'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.topic,
        subjectKey: 'english',
        canonicalKey: 'pilot-v0.1:english:grammar:punctuation',
        title: 'Sentence Punctuation',
        parentId: LearningNodeId('b0000001-0000-0000-0000-000000000002'),
        gradeMin: 1,
        gradeMax: 5,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000003'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'english',
        canonicalKey: 'pilot-v0.1:english:grammar:punctuation:end_marks',
        title: 'Sentence End Marks',
        parentId: LearningNodeId('b0000002-0000-0000-0000-000000000002'),
        gradeMin: 1,
        gradeMax: 3,
        sortOrder: 1,
      ),
    ]);

    _prerequisites.add(
      LearningPrerequisite(
        catalogVersion: 'pilot-v0.1',
        subjectKey: 'math',
        prerequisiteNodeId: LearningNodeId(
          'b0000003-0000-0000-0000-000000000001',
        ),
        dependentNodeId: LearningNodeId('b0000003-0000-0000-0000-000000000002'),
      ),
    );
  }

  void setActiveCatalogVersion(String version) {
    _activeCatalogVersion = version;
  }

  void addNode(LearningNode node) => _nodes.add(node);
  void addPrerequisite(LearningPrerequisite prerequisite) =>
      _prerequisites.add(prerequisite);
  void addEvidence(LearningEvidenceEvent event) => _evidence.add(event);

  void setMasteryState(ChildMasteryState state) {
    _masteryStates['${state.childId.value}:${state.learningNodeId.value}'] =
        state;
  }

  void setChildSchoolGrade(ChildId childId, int? schoolGrade) {
    _childSchoolGrades[childId.value] = schoolGrade;
  }

  int? _resolveSchoolGrade(ChildId childId) {
    if (_childSchoolGrades.containsKey(childId.value)) {
      return _childSchoolGrades[childId.value];
    }
    return defaultSchoolGrade;
  }

  List<ChildMasteryState> _resolveMasteryStates(
    ChildId childId,
    DateTime asOf,
  ) {
    final byNodeId = <String, ChildMasteryState>{};
    for (final entry in _masteryStates.entries) {
      if (entry.value.childId == childId) {
        byNodeId[entry.value.learningNodeId.value] = entry.value;
      }
    }

    final childEvidence = _evidence.where((e) => e.childId == childId).toList();
    final evidenceNodeIds = childEvidence.map((e) => e.learningNodeId).toSet();

    for (final nodeId in evidenceNodeIds) {
      if (byNodeId.containsKey(nodeId.value)) continue;
      final nodeEv = childEvidence
          .where((e) => e.learningNodeId == nodeId)
          .toList();
      final rebuild = MasteryEngine.rebuildNodeMastery(nodeEv);
      final conf = ConfidenceEngine.evaluate(
        masteryScore: rebuild.masteryScore,
        evidence: nodeEv,
        asOf: asOf,
      );
      final sorted = MasteryEngine.sortCanonical(nodeEv);
      byNodeId[nodeId.value] = ChildMasteryState(
        familyId: sorted.first.familyId,
        childId: childId,
        learningNodeId: nodeId,
        engineVersion: 'mastery-v0.1',
        masteryScore: rebuild.masteryScore,
        effectiveEvidenceCount: rebuild.effectiveEvidenceCount,
        distinctAssessmentCount: rebuild.distinctAssessmentCount,
        lastEvidenceEventId: sorted.last.id,
        lastEvidenceOccurredAt: sorted.last.effectiveOccurredAt,
        masteryAttainedAt:
            rebuild.masteryScore >= 85.0 &&
                conf.confidenceBand == ConfidenceBand.high
            ? asOf
            : null,
        updatedAt: asOf,
      );
    }

    return byNodeId.values.toList();
  }

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
    final effectiveAsOf = _nowUtc();
    final states = _resolveMasteryStates(childId, effectiveAsOf);
    final childEvidence = _evidence.where((e) => e.childId == childId).toList();

    final projections = <ChildMasteryProjection>[];

    for (final state in states) {
      final node = _nodes.firstWhere(
        (n) => n.id == state.learningNodeId,
        orElse: () => LearningNode(
          id: state.learningNodeId,
          catalogVersion: _activeCatalogVersion,
          nodeType: LearningNodeType.skill,
          subjectKey: 'math',
          canonicalKey: 'custom:${state.learningNodeId.value}',
          title: 'Custom Node',
        ),
      );
      if (node.catalogVersion != _activeCatalogVersion || !node.isActive) {
        continue;
      }

      final nodeEv = childEvidence
          .where((e) => e.learningNodeId == state.learningNodeId)
          .toList();
      final conf = ConfidenceEngine.evaluate(
        masteryScore: state.masteryScore,
        evidence: nodeEv,
        asOf: effectiveAsOf,
      );
      final band =
          NextChallengeEngine.evaluateAuthoritativeMasteryBand(
            isObserved: true,
            masteryScore: state.masteryScore,
            masteryAttainedAt: state.masteryAttainedAt,
            asOf: effectiveAsOf,
          ) ??
          MasteryBand.noData;

      projections.add(
        ChildMasteryProjection(
          childId: childId,
          learningNodeId: state.learningNodeId,
          nodeCanonicalKey: node.canonicalKey,
          nodeTitle: node.title,
          nodeType: node.nodeType,
          subjectKey: node.subjectKey,
          masteryScore: state.masteryScore,
          distinctAssessmentCount: state.distinctAssessmentCount,
          lastEvidenceOccurredAt: state.lastEvidenceOccurredAt,
          masteryAttainedAt: state.masteryAttainedAt,
          confidenceBand: conf.confidenceBand,
          confidenceUnits: conf.confidenceUnits,
          masteryBand: band,
          asOf: effectiveAsOf,
          updatedAt: state.updatedAt,
        ),
      );
    }

    return projections;
  }

  @override
  Future<LearningOverview> getChildLearningOverview({
    required ChildId childId,
  }) async {
    final effectiveAsOf = _nowUtc();
    return NextChallengeEngine.buildOverview(
      childId: childId,
      schoolGrade: _resolveSchoolGrade(childId),
      activeCatalogVersion: _activeCatalogVersion,
      catalogNodes: _nodes,
      prerequisites: _prerequisites,
      masteryStates: _resolveMasteryStates(childId, effectiveAsOf),
      evidenceEvents: _evidence.where((e) => e.childId == childId),
      asOf: effectiveAsOf,
    );
  }

  @override
  Future<LearningNodeState> getNodeLearningState({
    required ChildId childId,
    required String learningNodeId,
  }) async {
    final effectiveAsOf = _nowUtc();
    return NextChallengeEngine.buildNodeState(
      childId: childId,
      learningNodeId: learningNodeId,
      schoolGrade: _resolveSchoolGrade(childId),
      activeCatalogVersion: _activeCatalogVersion,
      catalogNodes: _nodes,
      prerequisites: _prerequisites,
      masteryStates: _resolveMasteryStates(childId, effectiveAsOf),
      evidenceEvents: _evidence.where((e) => e.childId == childId),
      asOf: effectiveAsOf,
    );
  }

  @override
  Future<NextChallengeRecommendationSet> getNextChallengeCandidates({
    required ChildId childId,
    SubjectKey? subjectKey,
    int limit = 3,
  }) async {
    final effectiveAsOf = _nowUtc();
    return NextChallengeEngine.getNextChallengeCandidates(
      childId: childId,
      schoolGrade: _resolveSchoolGrade(childId),
      activeCatalogVersion: _activeCatalogVersion,
      catalogNodes: _nodes,
      prerequisites: _prerequisites,
      masteryStates: _resolveMasteryStates(childId, effectiveAsOf),
      evidenceEvents: _evidence.where((e) => e.childId == childId),
      asOf: effectiveAsOf,
      subjectKeyFilter: subjectKey?.value,
      limit: limit,
    );
  }
}
