/// Central route paths and names for LearnWard.
///
/// Feature widgets must reference these constants instead of hard-coding route
/// strings. Navigation guards added to routes are UX guards only; backend
/// authorization and Row Level Security remain the security boundary.
abstract final class AppRoutes {
  static const String home = '/';
  static const String homeName = 'home';

  static const String foundation = '/foundation';
  static const String foundationName = 'foundation';

  static const String auth = '/auth';
  static const String authName = 'auth';

  static const String createFamily = '/family/create';
  static const String createFamilyName = 'createFamily';

  static const String parentHome = '/parent';
  static const String parentHomeName = 'parentHome';

  static const String createChild = '/parent/children/create';
  static const String createChildName = 'createChild';

  static const String parentRewards = '/parent/rewards';
  static const String parentRewardsName = 'parentRewards';

  static const String parentCreateReward = '/parent/rewards/create';
  static const String parentCreateRewardName = 'parentCreateReward';

  static const String parentEditReward = '/parent/rewards/edit';
  static const String parentEditRewardName = 'parentEditReward';

  static const String parentFulfillmentInbox = '/parent/redemptions';
  static const String parentFulfillmentInboxName = 'parentFulfillmentInbox';

  static const String parentWheelSettings = '/parent/wheel-settings';
  static const String parentWheelSettingsName = 'parentWheelSettings';

  static const String childMode = '/child';
  static const String childModeName = 'childMode';

  static const String childStore = '/child/store';
  static const String childStoreName = 'childStore';

  static const String childRedemptions = '/child/redemptions';
  static const String childRedemptionsName = 'childRedemptions';

  static const String childWheel = '/child/wheel';
  static const String childWheelName = 'childWheel';

  static const String childAddAssessment = '/child/assessments/add';
  static const String childAddAssessmentName = 'childAddAssessment';

  static const String parentReviewAssessment = '/parent/assessments/review';
  static const String parentReviewAssessmentName = 'parentReviewAssessment';

  static const String parentVerifiedHistory = '/parent/assessments/history';
  static const String parentVerifiedHistoryName = 'parentVerifiedHistory';

  // Reserved for later phases
  static const String pair = '/pair';
}
