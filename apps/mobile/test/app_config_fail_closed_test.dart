import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';

void main() {
  group('AppConfig and Fail-Closed Security Policy', () {
    test('development mode permits in-memory demo repositories when Supabase is unconfigured', () {
      const config = AppConfig(
        environment: AppEnvironment.development,
        supabaseUrl: '',
        supabasePublishableKey: '',
      );

      expect(config.canUseLocalDemoRepositories, isTrue);
      expect(() => config.validate(), returnsNormally);

      final container = ProviderContainer(
        overrides: [appConfigProvider.overrideWithValue(config)],
      );
      addTearDown(container.dispose);

      expect(() => container.read(familyRepositoryProvider), returnsNormally);
      expect(
        () => container.read(childProfileRepositoryProvider),
        returnsNormally,
      );
    });

    test(
      'staging mode FAILS CLOSED when Supabase configuration is missing',
      () {
        const config = AppConfig(
          environment: AppEnvironment.staging,
          supabaseUrl: '',
          supabasePublishableKey: '',
        );

        expect(config.canUseLocalDemoRepositories, isFalse);
        expect(
          () => config.validate(),
          throwsA(isA<MissingSupabaseConfigurationException>()),
        );

        final container = ProviderContainer(
          overrides: [appConfigProvider.overrideWithValue(config)],
        );
        addTearDown(container.dispose);

        expect(
          () => container.read(familyRepositoryProvider),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'error message',
              contains('MissingSupabaseConfigurationException'),
            ),
          ),
        );
        expect(
          () => container.read(childProfileRepositoryProvider),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'error message',
              contains('MissingSupabaseConfigurationException'),
            ),
          ),
        );
      },
    );

    test(
      'production mode FAILS CLOSED when Supabase configuration is missing',
      () {
        const config = AppConfig(
          environment: AppEnvironment.production,
          supabaseUrl: '',
          supabasePublishableKey: '',
        );

        expect(config.canUseLocalDemoRepositories, isFalse);
        expect(
          () => config.validate(),
          throwsA(isA<MissingSupabaseConfigurationException>()),
        );

        final container = ProviderContainer(
          overrides: [appConfigProvider.overrideWithValue(config)],
        );
        addTearDown(container.dispose);

        expect(
          () => container.read(familyRepositoryProvider),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'error message',
              contains('MissingSupabaseConfigurationException'),
            ),
          ),
        );
        expect(
          () => container.read(childProfileRepositoryProvider),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'error message',
              contains('MissingSupabaseConfigurationException'),
            ),
          ),
        );
      },
    );
  });
}
