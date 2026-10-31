# Metrics & Hypotheses v0.1

LearnWard should not optimize for engagement divorced from learning value.

The measurement system must distinguish:
- product usage,
- reward consumption,
- actual learning progress.

## 1. North Star Metric

### Verified Learning Progress Events / Active Child / Week

Abbreviation: **VLPE**

A VLPE occurs when:

```text
Real learning activity
      +
Sufficiently trusted result/evidence
      +
Growth Engine update
      +
Progress/mastery contribution
```

Examples that count:
- verified school test,
- verified practice assessment,
- verified recovery activity that updates mastery,
- trusted integrated result.

Examples that do not count:
- app open,
- spin,
- reward claim,
- store purchase,
- notification click,
- idle time.

## 2. Why VLPE

The product only creates its intended value when:

```text
Learn
  ↓
Evidence
  ↓
Understand progress
```

If spins increase while VLPE remains flat, the product is becoming a reward game rather than a learning motivation system.

## 3. Supporting metrics

| Metric | Purpose |
|---|---|
| VLPE / child / week | Core value creation |
| Results logged / child / week | Capture frequency |
| % results logged by child | Learner ownership |
| % goals chosen by child | Autonomy |
| 4-week subject trend | Directional learning outcome |
| Recovery completion rate | Learning from mistakes |
| Personal-best frequency | Challenge calibration signal |
| Parent approval latency | Operational friction |
| Parent admin minutes/day | Sustainability |
| Reward fulfillment rate | Trust in reward system |
| RP earned / week | Economy monitoring |
| RP spent / week | Economy monitoring |
| Wheel vs Store spend share | Preference / delayed gratification |
| Self-chosen challenge rate | Internalization signal |
| Week 4 / Week 8 retention | Sustainability |

## 4. Parent Intervention Rate

Track:

```text
Number of parent study reminders / week
```

Compare against baseline.

Desired direction:

```text
Before LearnWard: high
After LearnWard:  lower
```

This is a direct measure of whether LearnWard is reducing parent-child friction around study initiation.

## 5. Motivation-transition indicators

The product aims to move attention gradually from external reward to mastery.

Possible behavioral proxies:

### External stage
- child asks primarily about RP/spins,
- child chooses easiest reward-eligible tasks.

### Progress stage
- child asks about baseline/improvement,
- child tracks personal bests.

### Mastery stage
- child voluntarily retries weak topics,
- child completes Recovery Quests,
- child chooses harder goals.

### Ownership stage
- child sets goals without parent prompting,
- child chooses learning activity based on weakness/mastery,
- child continues some learning even when no immediate RP is available.

## 6. Core hypotheses

### H1 — Progress visibility

**Hypothesis:** Showing improvement relative to the learner's own baseline increases motivation more sustainably than showing the raw score alone.

Evidence for:
- children refer to improvement spontaneously,
- interest persists after reward novelty declines.

Evidence against:
- children ignore progress information and care only about RP.

### H2 — Growth-aware fairness

**Hypothesis:** Rewarding improvement in addition to absolute achievement feels fairer across learners with different starting ability.

Evidence for:
- weaker learners remain engaged,
- stronger learners still feel recognized,
- fewer complaints of unfairness.

### H3 — Learner autonomy

**Hypothesis:** Allowing the child to choose goals/challenges/reward paths increases ownership.

Evidence for:
- increasing percentage of self-chosen goals,
- less parent prompting,
- sustained use.

### H4 — Wheel vs Store

**Hypothesis:** Random rewards provide short-term excitement while a guaranteed Store supports saving and delayed gratification.

Evidence for:
- both mechanisms are used,
- some children intentionally save RP,
- Wheel is not mathematically dominant.

### H5 — Verification friction

**Hypothesis:** Parent verification is acceptable if it requires less than a few minutes per day and is reserved for meaningful events.

Evidence against:
- approvals accumulate,
- parent disengages,
- child waits too long for RP.

### H6 — Reward fulfillment trust

**Hypothesis:** Reliable fulfillment is necessary for the economy to retain motivational value.

Target directional signal:
- >90% reward fulfillment.

### H7 — Novelty resistance

**Hypothesis:** Once Wheel novelty decreases, growth/mastery mechanics can sustain meaningful engagement.

This is one of the most important hypotheses in the product.

### H8 — External-learning advantage

**Hypothesis:** Families value a system that works across school, tutoring, paper worksheets, and other apps more than another closed learning platform.

Evidence for:
- diverse result sources are logged naturally,
- parents describe aggregation as a core benefit.

## 7. Guardrail metrics

High engagement is not automatically positive.

Monitor:

### Reward dependency
- refusal to do normal school obligations unless RP is offered,
- escalating demands for rewards.

### Farming
- repeated trivial/easy activities,
- repeated assessments,
- artificial score manipulation.

### Family conflict
- arguments about approvals,
- arguments about probabilities,
- unfulfilled reward disputes.

### Parent burden
- excessive verification,
- reward management becoming another household chore.

### Excessive product engagement
- child spends disproportionate time inside LearnWard rather than learning.

## 8. MVP success gate

The MVP should not be considered successful merely because children enjoy spinning.

Promising evidence should include most of the following:
- regular VLPE creation,
- child-initiated logging,
- lower parent reminder frequency,
- acceptable parent workload,
- high reward fulfillment,
- use of both Wheel and Store,
- interest in personal improvement,
- continued use after novelty declines.

## 9. Product-killing signal

A major negative signal is:

```text
Remove rewards
→ all perceived product value disappears
```

If the durable value is only “do schoolwork to get prizes,” LearnWard has not established the intended product differentiation.
