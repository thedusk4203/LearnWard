# Reward Economy v0.1

LearnWard uses two primary resources:

- **Study XP** — permanent progression.
- **Reward Points (RP)** — spendable family reward currency.

Do not add additional currencies unless a concrete product need emerges.

## 1. Study XP

Purpose:
- show cumulative learning effort,
- unlock levels and long-term progression,
- support subject/skill identity,
- remain independent from family reward spending.

Properties:
- never spent,
- never removed,
- never reset as punishment,
- can be earned broadly from legitimate learning activity.

## 2. Reward Points

Purpose:
- connect verified learning progress with meaningful family rewards,
- give the child a real choice between randomness and certainty.

RP should be harder to farm than XP.

## 3. Primary choice

```text
                 RP
                 │
          ┌──────┴──────┐
          ▼             ▼
       Wheel          Store
      Random         Guaranteed
```

Example:

```text
Current balance: 47 RP

Spin                10 RP
+30 min gaming      40 RP
Choose dinner       80 RP
Movie outing       150 RP
Wishlist item      600 RP
```

The design goal is not to make one branch strictly better than the other.

## 4. Wheel principles

The wheel exists to provide surprise and celebration.

Rules:
- every spin wins an approved reward,
- no empty outcomes,
- no loss of RP after a valid spin,
- no near-miss manipulation,
- no paid rerolls,
- no purchase of spins,
- no advertising-for-spins,
- no cash-out,
- no real-money probability manipulation.

## 5. Store principles

The Store provides certainty and supports delayed gratification.

Good reward categories:
- privileges,
- experiences,
- family activities,
- choices,
- physical items,
- wishlist goals.

Examples:
- extra game time,
- choose dinner,
- movie night,
- visit a favorite place,
- book/comic,
- save toward headphones.

## 6. Wheel expected value

The wheel must not be mathematically dominant over the store.

Desired relationship:

```text
Wheel = surprise
Store = certainty
```

Not:

```text
Wheel = clearly superior expected value
Store = irrational choice
```

The product should eventually calculate or estimate expected reward cost to help parents balance the pool.

## 7. Reward categories

Suggested default mix should lean toward non-monetary rewards:

1. Privileges
2. Experiences
3. Family/social rewards
4. Choices
5. Physical items
6. Money-like rewards

The app should not imply that every learning event needs a cash reward.

## 8. Parent reward definition

A reward model may eventually include:

| Field | Example |
|---|---|
| Name | Extra gaming |
| Value | 30 minutes |
| Category | Privilege |
| Availability | Weekend only |
| Stock | 4 / month |
| Cooldown | 2 days |
| Wheel pools | Fun |
| Store cost | 50 RP |
| Estimated real cost | 0 VND |

## 9. Reward pools

Children may choose among parent-approved pools such as:
- Fun,
- Food,
- Experience,
- Family,
- Surprise.

This increases autonomy without giving the child control over unsafe or unaffordable rewards.

## 10. Reward budget

Future parent controls should support a monthly reward budget.

Example:

```text
October reward budget
Budget:        500,000 VND
Committed:     260,000 VND
Remaining:     240,000 VND
```

The economy should not create obligations a parent cannot fulfill.

## 11. Reward fulfillment

Reward lifecycle:

```text
Earned
  ↓
Claimed / Won
  ↓
Pending fulfillment
  ↓
Fulfilled
  ↓
History
```

Parent fulfillment should be simple and auditable.

A high reward-fulfillment rate is important for maintaining trust.

## 12. Anti-farming principles

Reward Points should require stronger trust than XP.

Initial rules:

1. Verified assessments can generate full RP.
2. Self-reported assessments generate pending RP until verified.
3. Below-level activities receive reduced RP.
4. Repeating the same assessment does not generate new Growth/PB bonuses.
5. Only a bounded number of practice assessments per day receive full RP.
6. School exams or explicitly parent-created challenges may be exempt from practice caps.

## 13. Example daily RP capacity

Possible v0.1 rule:

```text
First 2 qualifying practice assessments/day
→ full XP + full RP

Additional practice assessments
→ XP + mastery evidence
→ reduced/no RP depending on policy
```

Do not cap learning activity itself; cap only the family reward economy.

## 14. Evidence trust levels

```text
Level 0 — Self reported
Level 1 — Evidence attached
Level 2 — Parent verified
Level 3 — Machine verified
Level 4 — Trusted integration
```

MVP only needs Levels 0–2.

## 15. Ticket abstraction

A visible “ticket” may be used as UI language for the wheel, but it should not become a third economy.

Example:

```text
10 RP → one spin
```

The UI may render this as a ticket, while internally the transaction is simply an RP spend.

## 16. Reward fading principle

Do not silently inflate prices or reduce reward rates over time.

Instead, gradually introduce additional sources of motivation:

```text
Rewards
   ↓
Goals
   ↓
Personal bests
   ↓
Skill/mastery progression
   ↓
Self-chosen challenges
```

The system should make mastery progressively more salient without retroactively devaluing earned rewards.
