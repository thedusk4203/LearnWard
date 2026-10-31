# Learning Engine & Mastery Model v0.1

The Learning Engine is the layer that turns verified academic evidence into a persistent picture of **what the learner is getting better at** and **what they should work on next**.

It is deliberately separate from the Reward Economy.

```text
Academic evidence
      │
      ▼
Learning Engine
      │
      ├── Mastery state
      ├── Confidence
      ├── Freshness
      ├── Recovery need
      └── Next challenge candidates

Growth Engine
      │
      └── XP / RP / goal progress
```

A learner must never gain mastery merely because an activity generated a large RP bonus. Mastery is updated from academic evidence only.

---

## 1. Product objective

The Learning Engine should help a child answer four questions:

1. **What am I already good at?**
2. **What am I improving at?**
3. **Where am I still weak?**
4. **What is a useful thing to work on next?**

The parent should be able to understand the same state without needing educational-data-science terminology.

The engine is not intended to make high-stakes educational decisions or replace a teacher.

---

## 2. v0.1 design principles

1. Prefer explainability over predictive sophistication.
2. Never pretend sparse evidence is precise.
3. Keep **mastery**, **confidence**, and **freshness** separate.
4. Do not infer detailed skill mastery from an aggregate score when the evidence does not support it.
5. Child progress is personalized; do not compare siblings or rank children against one another.
6. Mistakes are evidence for the next learning step, not punishment events.
7. Recommendations should preserve child choice.
8. Mastery should be reversible in interpretation, but prior achievement should not be erased from history.
9. The same underlying academic evidence should produce the same mastery update regardless of the reward currently configured by the family.
10. v0.1 should work with very little data and degrade gracefully when topic/skill metadata is missing.

---

## 3. Knowledge hierarchy

LearnWard should use a hierarchy that is useful without requiring a complete national curriculum on day one.

```text
Subject
  └── Domain
       └── Topic
            └── Skill
                 └── Evidence
```

Example:

```text
Mathematics
  └── Algebra
       └── Linear Equations
            ├── Solve one-step equations
            ├── Solve multi-step equations
            ├── Equations with fractions
            └── Word problems using equations
```

Another example:

```text
English
  └── Grammar
       └── Tenses
            ├── Present simple
            ├── Present continuous
            └── Past simple
```

### v0.1 requirement

The system must support partial classification.

An assessment may be known only as:

```text
Mathematics
```

or:

```text
Mathematics → Algebra
```

or, when richer evidence exists:

```text
Mathematics → Algebra → Linear Equations → Multi-step equations
```

Missing metadata must not block result capture.

---

## 4. Evidence granularity rule

The engine must not claim more detail than the evidence supports.

### Aggregate assessment only

Example:

```text
Math midterm
8.0 / 10
```

If no item/topic breakdown exists, it may update:

- Mathematics-level progress,
- a known domain/topic if the parent or source explicitly tags it.

It must **not** automatically conclude:

```text
Fractions mastery = 82%
Geometry mastery = 78%
Linear equations mastery = 91%
```

unless the assessment contains evidence mapped to those skills.

### Item-level evidence

If LearnWard knows:

```text
Question 1 → Linear equations → correct
Question 2 → Linear equations → correct
Question 3 → Fractions → incorrect
...
```

then skill-level mastery may be updated directly.

This distinction is fundamental to the credibility of the Learning Engine.

---

## 5. Mastery is not one number

Each tracked skill/topic should maintain at least three independent properties:

```text
Mastery score
Confidence
Freshness
```

Example:

```text
Linear Equations

Mastery:    78 / 100
Confidence: Medium
Freshness:  Recent
```

This is better than simply displaying:

```text
78% mastered
```

because 78 based on one worksheet is not equivalent to 78 based on ten verified assessments from multiple sources.

---

## 6. Mastery score v0.1

For v0.1, use an exponentially weighted moving update.

Represent mastery on a 0–100 scale.

For each comparable evidence event:

```text
M_new = M_old + α_effective × (P - M_old)
```

Where:

- `M_old` = current mastery estimate,
- `P` = observed performance on a 0–100 scale,
- `α_effective` = update strength after evidence weighting.

### Initial state

The first credible evidence initializes the estimate rather than assuming a child starts at zero.

Example:

```text
First verified Linear Equations assessment = 70%

M = 70
Confidence = Low
```

A child should not have to climb artificially from 0 simply because LearnWard has never seen them before.

---

## 7. Base update strength

Use a deliberately conservative default:

```text
α_base = 0.35
```

Example:

```text
Current mastery M = 70
New observed performance P = 80
α = 0.35

M_new = 70 + 0.35 × (80 - 70)
      = 73.5
```

One good test moves the estimate, but does not completely redefine the learner.

This parameter is a product hypothesis and must be calibrated during pilots.

---

## 8. Evidence weighting

Not all evidence deserves equal update strength.

v0.1 should multiply the base alpha by an evidence weight.

Suggested starting values:

| Evidence | Weight |
|---|---:|
| Self-reported result, no evidence | 0.25 |
| Photo attached, not yet verified | 0.50 |
| Parent-verified result | 1.00 |
| Trusted source/import | 1.00 |
| Machine-extracted but not human-confirmed | 0.75 |

Then:

```text
α_effective = α_base × evidence_weight
```

Example:

```text
α_base = 0.35
Photo only weight = 0.50

α_effective = 0.175
```

The purpose is not to punish self-reporting. It is to avoid treating uncertain data as equally authoritative.

---

## 9. Assessment specificity weighting

Verification quality and diagnostic specificity are different concepts.

A fully verified school exam may still be too broad to update a specific skill strongly.

Suggested specificity weights:

| Evidence mapping | Specificity weight |
|---|---:|
| Subject only | 0.35 |
| Domain | 0.50 |
| Topic | 0.75 |
| Skill/item-level | 1.00 |

For mastery updates:

```text
α_effective
= α_base
× verification_weight
× specificity_weight
```

This allows broad school results to contribute without pretending they diagnose every sub-skill precisely.

---

## 10. Difficulty in mastery

Difficulty should not be converted directly into large mastery bonuses.

A score of 80 on a hard task is useful evidence, but difficulty labels are often subjective across schools, tutors, books, and parents.

For v0.1:

- difficulty is stored,
- it affects comparability and recommendation logic,
- it does **not** directly multiply mastery score,
- below-level work may receive lower diagnostic weight when used to estimate current-grade mastery.

Future versions may calibrate source/item difficulty using historical data.

---

## 11. Mastery bands

The numerical score is an internal estimate. The child-facing product should emphasize interpretable bands.

Suggested initial bands:

| Mastery estimate | Label |
|---:|---|
| No evidence | Unseen |
| < 50 | Emerging |
| 50–69 | Developing |
| 70–84 | Secure |
| ≥ 85 | Mastery candidate |

`Mastery candidate` is intentional.

The system should not display **Mastered** unless confidence is sufficient.

---

## 12. Confidence v0.1

Confidence answers:

> How much evidence does LearnWard have for this mastery estimate?

Do not compute confidence solely from the mastery score.

### Suggested evidence-unit system

For each recent piece of mapped evidence:

```text
confidence_units
= verification_weight × specificity_weight
```

Use evidence from a recent window such as 60 days for the initial model.

Suggested thresholds:

| Confidence units | Confidence |
|---:|---|
| < 1.5 | Low |
| 1.5–3.5 | Medium |
| > 3.5 | High |

High confidence should additionally require at least two distinct assessment events.

A future version may also reward source diversity and assessment-type diversity.

---

## 13. Declaring mastery

For v0.1:

```text
Mastered
IF mastery score ≥ 85
AND confidence = High
AND at least 2 recent verified evidence events
```

This prevents a single 10/10 worksheet from instantly declaring a skill mastered.

Possible UI:

```text
Linear Equations
MASTERED

Mastery 88
High confidence
Last demonstrated 6 days ago
```

---

## 14. Freshness

Knowledge can become stale, but v0.1 should not silently erase achievement using an unvalidated forgetting formula.

Track freshness separately.

Suggested initial labels:

| Time since credible evidence | Freshness |
|---:|---|
| ≤ 14 days | Recent |
| 15–45 days | Aging |
| > 45 days | Needs refresh |

These thresholds must eventually vary by skill type and learner behavior.

### Important rule

If a mastered skill becomes stale:

```text
Mastery history remains.
Current state becomes: Mastered · Needs refresh
```

Do not abruptly show:

```text
Mastered → Developing
```

merely because time passed.

A later evidence event can recalibrate the mastery estimate.

---

## 15. Recovery state

A recent assessment may reveal errors even when historical mastery is high.

Track a separate recovery signal:

```text
No recovery needed
Review suggested
Recovery quest active
Recovery verified
```

Example:

```text
Fractions
Mastery: 76
Confidence: High
Freshness: Recent
Recovery: Review suggested

Reason:
3 recent fraction errors in the latest test
```

This prevents the mastery number from hiding actionable mistakes.

---

## 16. Skill graph

Skills may have prerequisite relationships.

Example:

```text
Integer operations
      │
      ▼
One-step equations
      │
      ▼
Multi-step equations
      │
      ▼
Equation word problems
```

For v0.1, prerequisite edges should be explicit and curated, not generated automatically by an opaque model.

A full Vietnamese curriculum graph is **not required** before validating the product.

Start with small manually defined subject/topic maps for the pilot.

---

## 17. Next Challenge Engine v0.1

The engine should generate **candidates**, not commands.

A child should normally receive up to three choices.

Priority order:

### Priority A — Recovery

If recent verified evidence exposes a meaningful error cluster:

```text
Recommend a Recovery Quest first.
```

### Priority B — Developing skill

If:

```text
mastery ≈ 50–84
```

recommend another comparable activity at an appropriate difficulty.

### Priority C — Refresh

If a previously secure/mastered skill has stale evidence:

```text
Recommend a short refresh challenge.
```

### Priority D — Unlock next skill

If:

```text
mastery ≥ 85
AND confidence = High
```

recommend a prerequisite-linked next skill.

### Priority E — Exploration

Allow the child to select an unseen nearby skill when no urgent recovery need exists.

---

## 18. Recommended challenge difficulty

The product should aim for tasks that are challenging but realistically achievable.

For the pilot, use a simple heuristic rather than pretending to estimate exact success probability.

```text
If recent score < 50:
    suggest easier / corrective work

If recent score 50–69:
    suggest normal practice

If recent score 70–89:
    suggest normal or hard practice

If recent score ≥ 90 with high confidence:
    suggest harder / next-skill work
```

This is a testable product heuristic, not a validated pedagogical law.

---

## 19. Preserve learner autonomy

Recommended UI:

```text
What do you want to tackle next?

1. Fix 4 mistakes from your last Algebra test
2. Try another Linear Equations challenge
3. Explore Equation Word Problems
```

Avoid:

```text
YOU MUST DO THIS NEXT.
```

Exceptions may exist for parent/teacher-assigned work, but the motivational layer should default toward meaningful choice.

---

## 20. Subject-level progress

A subject should not be calculated as a naive average of every child skill.

For v0.1, subject progress can be presented using:

- recent verified assessment trend,
- number of tracked topics,
- topic mastery distribution,
- personal baseline change.

Example:

```text
Mathematics

Recent score trend     ▲ +0.8
Tracked topics         5
Mastered               2
Secure                 1
Developing             2
Needs refresh          1
```

Avoid a misleading universal number such as:

```text
Math mastery = 73.42%
```

until the curriculum coverage model is strong enough to justify it.

---

## 21. Topic-level aggregation

If a parent/child wants a topic summary, v0.1 may aggregate only skills for which evidence exists.

Always show coverage.

Example:

```text
Linear Equations
Secure

Evidence coverage:
3 of 4 tracked skills
```

Do not interpret missing skills as zero mastery.

---

## 22. Relationship to the Growth Engine

The two engines use overlapping evidence but answer different questions.

### Growth Engine

> How should this result be recognized and rewarded?

Produces:

- RP,
- XP,
- goal completion,
- growth recognition,
- personal-best events.

### Learning Engine

> What does this result tell us about the learner's knowledge state?

Produces:

- mastery updates,
- confidence,
- freshness,
- recovery status,
- next challenge candidates.

Reward bonuses must never feed back into mastery.

---

## 23. Worked example

Existing state:

```text
Mathematics
└── Algebra
    └── Linear Equations
        └── Multi-step equations

Mastery:    68
Confidence: Medium
Freshness:  Recent
```

New evidence:

```text
Practice test
Skill-level mapping available
Score: 80%
Verification: Parent verified
Specificity: Skill-level
```

Calculation:

```text
α_base = 0.35
verification_weight = 1.00
specificity_weight = 1.00

α_effective = 0.35

M_new
= 68 + 0.35 × (80 - 68)
= 72.2
```

New state:

```text
Mastery:    72
Label:      Secure
Confidence: Medium → may increase depending on accumulated units
Freshness:  Recent
```

Growth Engine independently calculates RP/XP from the same assessment.

---

## 24. Sparse-data behavior

LearnWard must remain useful before it has rich data.

### One result

Show:

```text
Early estimate
Low confidence
```

### No skill mapping

Update broad subject/topic progress only.

### No comparable history

Do not fabricate growth.

### Conflicting evidence

Lower confidence in interpretation and request more evidence rather than hiding disagreement.

Example:

```text
Recent results vary widely.
Let's get another result before calling this skill secure.
```

---

## 25. Data model sketch

Conceptual entities:

```text
Learner
Subject
Domain
Topic
Skill
PrerequisiteEdge
Assessment
AssessmentItem
EvidenceMapping
MasteryState
RecoveryState
Recommendation
```

Important MasteryState fields:

```text
learner_id
skill_or_topic_id
mastery_score
confidence_level
confidence_units
freshness_state
last_evidence_at
last_verified_at
evidence_count
model_version
```

Every update should be reproducible from stored evidence and model version.

---

## 26. Auditability

Parent and child should be able to inspect why a state changed.

Example:

```text
Why did Linear Equations move from 68 → 72?

Because:
- New verified practice test
- Score: 80%
- Skill-level evidence
- Previous estimate: 68
```

Do not expose unnecessary mathematical detail by default, but preserve it for transparency and debugging.

---

## 27. What v0.1 intentionally does not do

- deep knowledge tracing,
- automatic curriculum generation,
- item-response-theory calibration,
- cross-school score normalization,
- teacher-grade prediction,
- high-stakes mastery certification,
- automatic forgetting curves,
- AI-generated prerequisite graphs,
- universal subject mastery percentages,
- autonomous recommendation with no child choice.

These require substantially more data or validation.

---

## 28. Upgrade path

After sufficient real interaction data exists, evaluate models such as:

- improved EWMA / recency models,
- Bayesian Knowledge Tracing (BKT),
- Performance Factor Analysis,
- Elo-style learner/item rating,
- Item Response Theory where item calibration is feasible,
- forgetting-aware models,
- calibrated knowledge-tracing models.

Model complexity should be earned by measurable improvement in:

1. prediction calibration,
2. recommendation quality,
3. fairness across learner groups,
4. explainability,
5. real learning outcomes.

Do not adopt a deep model merely because it is more sophisticated.

---

## 29. Research rationale

The initial design is intentionally conservative.

Knowledge-tracing literature commonly models a learner's changing state over discrete skills and includes approaches such as Bayesian Knowledge Tracing, factor models, and modern deep models. BKT is historically tied to mastery learning and interpretable skill states.

Research comparing mastery criteria also suggests that the **quality/source of evidence and mastery threshold choices can matter more than choosing a sophisticated learner model**, and identifies exponential moving averages as a practical baseline for mastery decisions.

References:

- Corbett & Anderson lineage / overview: *Knowledge Tracing: A Survey*, ACM Computing Surveys — https://doi.org/10.1145/3569576
- Pelánek & Řihák, *Analysis and design of mastery learning criteria* — https://doi.org/10.1080/13614568.2018.1476596
- Winget & Persky, *A Practical Review of Mastery Learning* — https://pmc.ncbi.nlm.nih.gov/articles/PMC10159400/
- Shen et al., *A Survey of Knowledge Tracing: Models, Variants, and Applications* — IEEE Transactions on Learning Technologies, 2024.

---

## 30. v0.1 decisions to freeze

Unless pilot evidence contradicts them:

1. Hierarchy: `Subject → Domain → Topic → Skill`.
2. Evidence granularity limits mastery granularity.
3. Mastery, confidence, and freshness remain separate.
4. v0.1 mastery update uses an explainable weighted EMA.
5. First credible evidence initializes mastery rather than starting every learner at zero.
6. `Mastered` requires both a high estimate and sufficient confidence.
7. Time staleness produces `Needs refresh`, not silent mastery erasure.
8. Recovery is a first-class learning state.
9. Next Challenge Engine returns choices, not commands.
10. Reward output never directly changes mastery.

These rules define the initial Learning Engine contract.