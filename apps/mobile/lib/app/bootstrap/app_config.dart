/// Build-time configuration for the LearnWard app.
enum AppEnvironment {
  development('development', 'Development'),
  staging('staging', 'Staging'),
  production('production', 'Production');

  const AppEnvironment(this.wireName, this.label);

  /// Value used by `APP_ENV` in build configuration.
  final String wireName;

  /// Human-readable label for development-only surfaces.
  final String label;

  /// Parses a configured environment name, rejecting unknown values.
  static AppEnvironment parse(String value) {
    for (final environment in values) {
      if (environment.wireName == value) {
        return environment;
      }
    }
    throw ArgumentError.value(
      value,
      'APP_ENV',
      'Unknown LearnWard environment',
    );
  }
}

/// Runtime configuration assembled from `--dart-define` values.
///
/// Never put service-role keys or other secrets in this object. Only the
/// Supabase URL and a client-safe publishable key belong in the app bundle.
final class AppConfig {
  const AppConfig({
    required this.environment,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  factory AppConfig.fromEnvironment() {
    return AppConfig(
      environment: AppEnvironment.parse(
        const String.fromEnvironment('APP_ENV', defaultValue: 'development'),
      ),
      supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
    );
  }

  final AppEnvironment environment;
  final String supabaseUrl;
  final String supabasePublishableKey;

  /// Whether both public Supabase values were supplied at build time.
  bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
