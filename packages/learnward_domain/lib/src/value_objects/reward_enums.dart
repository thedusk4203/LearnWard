import '../exceptions/domain_exceptions.dart';

/// Supported reward categories.
enum RewardCategory {
  privilege('privilege', 'Privilege', 'star'),
  experience('experience', 'Experience', 'celebration'),
  treat('treat', 'Treat', 'cake'),
  item('item', 'Item', 'inventory_2'),
  choice('choice', 'Choice', 'how_to_vote'),
  custom('custom', 'Custom', 'more_horiz');

  const RewardCategory(this.value, this.displayName, this.defaultIconKey);

  final String value;
  final String displayName;
  final String defaultIconKey;

  static RewardCategory fromString(String value) {
    for (final category in values) {
      if (category.value == value) return category;
    }
    throw InvalidRewardException('Unknown reward category: $value');
  }

  String toJson() => value;
}

/// Relative probability tiers for Celebration Wheel items.
enum WheelTier {
  common('common', 'Common', 60),
  special('special', 'Special', 30),
  rare('rare', 'Rare', 10);

  const WheelTier(this.value, this.displayName, this.relativeWeight);

  final String value;
  final String displayName;
  final int relativeWeight;

  static WheelTier fromString(String value) {
    for (final tier in values) {
      if (tier.value == value) return tier;
    }
    throw InvalidRewardException('Unknown wheel tier: $value');
  }

  String toJson() => value;
}

/// Origin channel of a reward claim.
enum RewardOrigin {
  store('store', 'Store Purchase'),
  wheel('wheel', 'Wheel Spin');

  const RewardOrigin(this.value, this.displayName);

  final String value;
  final String displayName;

  static RewardOrigin fromString(String value) {
    for (final origin in values) {
      if (origin.value == value) return origin;
    }
    throw InvalidRedemptionException('Unknown reward origin: $value');
  }

  String toJson() => value;
}

/// Lifecycle status for reward redemptions.
enum RewardRedemptionStatus {
  pendingFulfillment('pending_fulfillment', 'Pending Fulfillment'),
  fulfilled('fulfilled', 'Fulfilled'),
  cancelled('cancelled', 'Cancelled');

  const RewardRedemptionStatus(this.value, this.displayName);

  final String value;
  final String displayName;

  static RewardRedemptionStatus fromString(String value) {
    for (final status in values) {
      if (status.value == value) return status;
    }
    throw InvalidRedemptionException('Unknown redemption status: $value');
  }

  bool get isTerminal => this == fulfilled || this == cancelled;

  String toJson() => value;
}
