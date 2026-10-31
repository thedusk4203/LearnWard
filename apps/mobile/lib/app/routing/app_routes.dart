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

  static const String childMode = '/child';
  static const String childModeName = 'childMode';

  // Reserved for later phases
  static const String pair = '/pair';
}
