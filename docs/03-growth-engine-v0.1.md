# Growth Engine v0.1

The Growth Engine is the first core product primitive for LearnWard.

Its purpose is to translate a verified academic result into an explainable combination of:
- Reward Points (RP),
- Study XP,
- mastery updates,
- goal progress,
- next-step recommendations.

The v0.1 model intentionally favors **simplicity and explainability** over statistical sophistication.

## 1. Assessment input

Minimum fields:

| Field | Example |
|---|---|
| Subject | Mathematics |
| Topic | Linear Equations |
| Grade level | 8 |
| Raw score | 15 |
| Maximum score | 20 |
| Assessment type | Practice Test |
| Difficulty | Normal |
| Source | School / Tutor / Worksheet / App |
| Date | 2026-10-31 |
| Evidence | Photo |
| Verification | Parent verified |
| Personal goal | 7.0 / 10 |

## 2. Normalize score

All scored assessments should be normalized to a 10-point scale for the initial engine:

```text
S = raw_score / maximum_score × 10
```

Example:

```text
15 / 20 = 7.5 / 10
```

Internally, retain the original raw score and denominator.

## 3. Comparable results

Growth should not be calculated against arbitrary historical results.

Results are comparable when sufficiently similar by:
- subject,
- grade level,
- assessment type,
- difficulty band.

Topic is preferred when enough history exists.

Fallback hierarchy:

```text
Topic baseline
    ↓ if insufficient history
Subject baseline
    ↓ if insufficient history
No growth bonus yet
```

## 4. Rolling baseline

For v0.1:

```text
Baseline = mean(last 3 comparable verified results)
```

Example:

```text
6.0
6.5
6.8

Baseline = 6.43
```

New result:

```text
7.5
```

Growth:

```text
Δ = 7.5 - 6.43 = +1.07
```

Future versions may use EWMA or calibrated learner models, but v0.1 should remain easy to explain.

## 5. Reward Points formula

```text
RP = Score
   + Growth Bonus
   + Goal Bonus
   + Personal Best Bonus
   + Challenge Bonus
   + Recovery Bonus
```

The UI should explain the components rather than exposing a cryptic formula.

## 6. Base score component

The normalized score becomes the base RP amount:

```text
7.5 / 10 → +7.5 RP
```

This preserves the original product intuition that a real test score has direct reward value.

## 7. Growth Bonus

| Improvement vs baseline | Bonus |
|---:|---:|
| < +0.50 | +0 RP |
| +0.50 to +0.99 | +1 RP |
| +1.00 to +1.49 | +2 RP |
| +1.50 to +1.99 | +3 RP |
| ≥ +2.00 | +4 RP |

Example:

```text
Baseline 6.43
Current  7.50
Δ        +1.07

Growth Bonus = +2 RP
```

## 8. High-performer protection

A learner already scoring near the ceiling has less room for raw improvement.

If:

```text
baseline ≥ 8.5
AND current ≥ 8.5
```

award:

```text
Mastery Maintenance +1 RP
```

If:

```text
baseline ≥ 9.0
AND current ≥ 9.0
for 3 comparable verified results
```

unlock a mastery recognition event/badge.

This prevents the system from implicitly punishing strong learners.

## 9. Personal Goal Bonus

The child should choose the target before the result is known.

Example:

```text
Baseline: 6.4
Target:   7.0
```

If achieved:

```text
+1 RP
```

If the target is a reasonable stretch target, for example:

```text
target ≥ baseline + 1.0
```

then:

```text
+2 RP
```

The app should reject trivial target farming such as setting a target materially below the current baseline.

## 10. Personal Best Bonus

If the new score exceeds the comparable historical best by at least 0.25:

```text
New Personal Best → +1 RP
```

Keep this small because the Growth Bonus may already reward the same improvement.

## 11. Difficulty / Challenge Bonus

Use additive bonuses rather than large multipliers.

| Difficulty | Bonus |
|---|---:|
| Below level | 0 |
| Normal | 0 |
| Hard | +1 RP |
| Challenge | +2 RP |

Challenge Bonus activates only when the learner achieves a minimum threshold such as:

```text
score ≥ 5 / 10
```

This prevents selecting impossibly hard material solely to farm challenge credit.

## 12. Below-level protection

If a learner repeatedly chooses assessments materially below their current reward level:

```text
XP: yes
Mastery evidence: yes
RP: 25% of normal base amount
Growth Bonus: disabled
PB Bonus: disabled for reward purposes
```

The UI should frame this positively:

> Good practice. This activity is below your current Reward Level, so it earns reduced RP.

## 13. Mistake Recovery

After an assessment with identifiable errors, LearnWard may create a Recovery Quest.

Example:

```text
20 questions
14 correct
6 incorrect
```

Recovery options:

- review mistakes,
- retry equivalent questions,
- explain the corrected method,
- complete a short targeted practice set.

Possible v0.1 rewards:

```text
Partial recovery → +10 XP +1 RP
Full recovery    → +15 XP +2 RP
```

The goal is to convert errors into another learning opportunity rather than a punishment event.

## 14. Worked example

History:

```text
6.0
6.5
6.8
```

Baseline:

```text
6.43
```

New result:

```text
Score:         7.5
Difficulty:    Hard
Personal goal: 7.0
Previous best: 6.8
```

Calculation:

| Component | RP |
|---|---:|
| Base score | +7.5 |
| Growth +1.07 | +2.0 |
| Goal achieved | +1.0 |
| Personal best | +1.0 |
| Hard challenge | +1.0 |
| **Total** | **12.5 RP** |

Suggested UI:

```text
7.5 / 10

▲ Great improvement
+1.1 above your recent baseline

🎯 Goal achieved
🏆 New personal best
🔥 Hard challenge

+12.5 RP
+35 XP
```

## 15. XP v0.1

XP is progression, not currency.

A simple initial formula:

```text
XP = 10 + (2 × RP_awarded)
```

Example:

```text
12.5 RP → 35 XP
```

Additional XP may later come from:
- study sessions,
- recovery,
- consistency,
- projects,
- reading,
- self-directed challenges.

XP should:
- never be spent,
- never be removed for poor performance,
- never reset as punishment.

## 16. Explainability requirement

Every Growth Engine result should be auditable.

Parent and child should be able to answer:

```text
Why did I get this much RP?
Why is this considered improvement?
Why did this task earn reduced RP?
Why did mastery change?
```

No opaque ML model should replace this explainability requirement in the early product.

## 17. Future extensions

Potential future engine improvements:
- EWMA baseline,
- confidence-weighted evidence,
- source calibration,
- curriculum-aware difficulty normalization,
- topic mastery graph,
- knowledge decay,
- adaptive challenge selection,
- expected-score prediction,
- learner-specific improvement velocity.

These are explicitly post-validation features.
