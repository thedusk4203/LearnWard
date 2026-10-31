# LearnWard

**LearnWard** is a family-centered learning motivation system that turns a child's real academic progress into visible growth, mastery, and meaningful rewards.

> **Product thesis:** Help children see themselves getting better.

LearnWard is not intended to be another curriculum platform, homework app, or generic chore/reward chart. It is designed as a **motivation layer over learning that already happens anywhere**: school tests, tutoring, worksheets, practice books, online learning platforms, homework, and self-study.

## Core loop

```text
LEARN ANYWHERE
     │
     ▼
CAPTURE RESULT
     │
     ▼
VERIFY EVIDENCE
     │
     ▼
GROWTH ENGINE
  ╱      │       ╲
 ▼       ▼        ▼
XP    Mastery     RP
 │       │         │
 │       │      ┌──┴───┐
 │       │      ▼      ▼
Level    │    Wheel   Store
 │       │      └──┬───┘
 │       │         ▼
 └───────┼──► Family Reward
         │
         ▼
   NEXT CHALLENGE
```

## Current product direction

- Initial target: children roughly **10–15 years old**, especially late-primary and middle-school learners.
- External-learning-first: LearnWard should understand progress from learning that happens outside the app.
- Reward **growth, mastery, recovery, and meaningful effort**, not obedience.
- Keep two primary resources:
  - **Study XP** — permanent progression; never spent or lost.
  - **Reward Points (RP)** — spendable on a random reward wheel or guaranteed reward store.
- The wheel is a celebration mechanic, not the product moat.
- The long-term moat is the **Growth Engine + longitudinal learning history + personalized mastery model**.
- Mastery must remain separate from reward: academic evidence updates learning state; RP/XP never inflate mastery directly.
- Mobile delivery is **Android + iOS from one role-aware Flutter codebase** for v1.

## Documentation

| Document | Purpose |
|---|---|
| [Product Definition](docs/00-product-definition.md) | Users, problem, JTBD, value proposition, scope and positioning |
| [Product Principles](docs/01-product-principles.md) | Non-negotiable product rules and safety constraints |
| [Competitive Landscape](docs/02-competitive-landscape.md) | Market map, competitors and identified white space |
| [Growth Engine v0.1](docs/03-growth-engine-v0.1.md) | Initial academic scoring and progress-recognition model |
| [Reward Economy v0.1](docs/04-reward-economy-v0.1.md) | XP/RP economy, wheel/store and anti-farming rules |
| [Pilot Plan v0.1](docs/05-pilot-plan-v0.1.md) | Four-week pre-build validation experiment |
| [Metrics & Hypotheses](docs/06-metrics-and-hypotheses.md) | North Star, secondary metrics and validation criteria |
| [Learning Engine & Mastery v0.1](docs/07-learning-engine-mastery-v0.1.md) | Subject/topic/skill model, mastery confidence, freshness and next-challenge logic |
| [Mobile Architecture v0.1](docs/08-mobile-architecture-v0.1.md) | Android/iOS delivery, Flutter architecture, offline strategy, backend direction and security boundaries |

## Product status

**Phase:** Discovery / product definition  
**Code:** Not started intentionally  
**Mobile target:** Android + iOS / Flutter  
**Next gate:** Validate the motivation + growth + mastery loop with a small real-world pilot before production implementation.

## Working rule

Do not add a feature merely because it increases engagement. New features should strengthen at least one of:

1. verified learning progress,
2. progress visibility,
3. learner autonomy,
4. mastery,
5. sustainable family motivation,
6. lower parent administrative burden.

If a feature mainly increases spins, screen time, or app dependency without strengthening learning, it should not be part of LearnWard.
