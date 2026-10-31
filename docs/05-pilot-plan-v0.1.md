# Pilot Plan v0.1

The goal of the pilot is to validate the **motivation + growth loop before building the application**.

A small family pilot is sufficient at this stage. The objective is not statistical proof; it is to detect strong behavioral signals, friction, and failure modes.

## Pilot duration

4 weeks, plus an optional baseline week.

## Pilot participants

Initial participants may be children already available within the family network, ideally in the late-primary or middle-school range.

## Week 0 — Baseline

Track only:
- subject,
- assessment/task,
- score,
- date,
- whether the child initiated the learning,
- number of parent reminders.

Do not enable rewards yet.

Purpose:
- establish current behavior,
- observe existing motivation,
- estimate normal result frequency,
- measure parent intervention rate.

## Week 1 — Score → RP → Wheel

Enable the simplest version of the original concept:

```text
Verified score
    ↓
Base RP
    ↓
10 RP = one spin
```

Questions to observe:
- Does the child care about earning RP?
- Does the wheel increase willingness to log results?
- Does the child ask to study more, or merely ask how to obtain spins?
- Does parent verification become annoying?

Keep the rules simple.

## Week 2 — Add Growth

Introduce:
- rolling baseline,
- Improvement Bonus,
- Personal Best,
- Personal Goal.

Result feedback should show progress explicitly.

Example:

```text
7.5 / 10
▲ +1.1 above recent baseline
🎯 Goal achieved
🏆 Personal best
```

Observe whether the child starts asking questions such as:
- “What was my previous average?”
- “How much did I improve?”
- “What do I need next time?”

This week tests whether **progress visibility itself becomes motivating**.

## Week 3 — Wheel vs Store

Introduce a guaranteed reward store.

```text
RP
├─ Spin now
└─ Save for guaranteed reward
```

Observe:
- immediate spending vs saving,
- whether children understand the tradeoff,
- whether reward pricing feels fair,
- whether certain reward types dominate,
- whether parents can fulfill rewards reliably.

## Week 4 — Mastery / Recovery / Ownership

Introduce lightweight versions of:
- topic progress,
- Recovery Quest,
- self-chosen goal,
- self-chosen challenge.

The key question:

> When reward novelty starts decreasing, does progress/mastery still produce motivation?

## Daily pilot data

Capture:

| Field | Notes |
|---|---|
| Date | |
| Child | |
| Subject | |
| Activity type | |
| Score | if applicable |
| Baseline | if available |
| RP awarded | |
| XP awarded | |
| Who initiated activity? | child / parent / school |
| Who logged result? | child / parent |
| Parent reminders today | count |
| Reward claimed? | |
| Parent admin time | approximate minutes |
| Notes | reactions / complaints / unexpected behavior |

## Weekly child interview

Keep questions neutral and brief.

Suggested questions:

1. What part of the system did you like most this week?
2. What part was annoying?
3. Did the points make you want to learn, or only want the reward?
4. Did seeing improvement matter to you?
5. Did you care about beating your own previous score?
6. Would you rather spin or save? Why?
7. Which rewards actually feel worth working toward?
8. Was anything unfair?
9. What would make you want to use this next week?
10. If rewards disappeared, which parts would you still care about?

Do not lead the child toward positive answers.

## Weekly parent interview

Suggested questions:

1. Did you remind the child less, the same, or more?
2. How much daily admin work did the system create?
3. Were any reward obligations inconvenient?
4. Did the scoring feel fair?
5. Did the child try to exploit the rules?
6. Did you notice more ownership of learning?
7. Did the system create arguments?
8. Which reward types worked best?
9. Would you continue the system without an app?
10. What would have to improve for you to use it for months?

## Expected failure modes

Actively watch for:

### Spin fixation

```text
Child only cares about spins
→ does not care about progress
```

This threatens the product thesis.

### Easy-task farming

```text
Child chooses easy worksheets
→ maximizes RP
```

This validates the need for difficulty-aware rules.

### Parent verification overload

```text
Too many approvals
→ parent stops using system
```

This validates the need for automation / trust tiers.

### Reward inflation

```text
Too many rewards earned
→ parent cannot fulfill
```

This validates reward caps and budget controls.

### Reward bargaining

```text
Child refuses normal learning unless RP is offered
```

This may indicate excessive externalization of motivation.

### Novelty collapse

```text
Week 1 excitement
Week 3 indifference
```

The key test is whether growth/mastery mechanics soften this decline.

## Pilot success signals

Initial directional targets:

| Signal | Target / interpretation |
|---|---|
| Verified learning events | ≥2 / child / week |
| Child voluntarily logs results | ≥50% by later weeks |
| Parent approval time | ideally <24h |
| Parent admin burden | ideally <5 min/day |
| Reward fulfillment | >90% |
| Self-chosen goals | increasing over time |
| Parent reminders | lower than baseline |
| Week 4 usage | still active |
| Child talks about improvement | strong positive signal |
| Child cares only about wheel | strong negative signal |

## Decision gate after pilot

### Proceed toward MVP if

Evidence suggests:
- children value progress visibility,
- reward mechanics initiate usage without fully dominating it,
- parents can operate the system with low friction,
- the Growth Engine feels fair,
- usage persists after novelty declines.

### Revise before coding if

- scoring feels arbitrary,
- children optimize only for rewards,
- parent workload is high,
- reward fulfillment is unreliable,
- progress/mastery is ignored.

### Stop or fundamentally rethink if

The only durable value is:

```text
Do schoolwork → receive prizes
```

because that would reduce LearnWard to an easily copied reward chart rather than the intended learning motivation system.
