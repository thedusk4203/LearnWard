/// Central route paths and names for LearnWard.
///
/// Feature widgets must reference these constants instead of hard-coding route
/// strings. Paths for later phases are reserved here but are intentionally not
/// registered until their flows exist.
abstract final class AppRoutes {
  static const String home = '/';
  static const String homeName = 'home';

  // Reserved for later phases. Do not register placeholder routes that imply
  // product flows already exist.
  static const String auth = '/auth';
  static const String onboarding = '/onboarding';
  static const String parent = '/parent';
  static const String child = '/child';
  static const String pair = '/pair';
}
