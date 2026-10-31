import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/auth/presentation/auth_screen.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  group('Auth Routing and Screen Security', () {
    testWidgets('Supabase configured with no session redirects to /auth', (
      tester,
    ) async {
      const config = AppConfig(
        environment: AppEnvironment.staging,
        supabaseUrl: 'https://example.supabase.co',
        supabasePublishableKey: 'sb_pub_key_123',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(config),
            currentUserIdProvider.overrideWithValue(null),
            localMetadataStoreProvider.overrideWithValue(
              InMemoryLocalMetadataStore(),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Unauthenticated user is redirected to AuthScreen
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text('Adult Sign In'), findsOneWidget);
      expect(find.byKey(const Key('send_magic_link_button')), findsOneWidget);

      // Staging mode MUST NOT have the demo bypass button
      expect(find.byKey(const Key('demo_bypass_button')), findsNothing);
    });

    testWidgets(
      'Production mode never renders development demo bypass button',
      (tester) async {
        const config = AppConfig(
          environment: AppEnvironment.production,
          supabaseUrl: 'https://prod.supabase.co',
          supabasePublishableKey: 'sb_pub_key_prod',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(config),
              currentUserIdProvider.overrideWithValue(null),
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byKey(const Key('demo_bypass_button')), findsNothing);
      },
    );

    testWidgets(
      'Development mode with demo allowed renders demo bypass button',
      (tester) async {
        const config = AppConfig(
          environment: AppEnvironment.development,
          supabaseUrl: 'http://127.0.0.1:45321',
          supabasePublishableKey: 'sb_local_key',
          enableLocalDemo: true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(config),
              currentUserIdProvider.overrideWithValue(null),
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byKey(const Key('demo_bypass_button')), findsOneWidget);
      },
    );
  });
}
