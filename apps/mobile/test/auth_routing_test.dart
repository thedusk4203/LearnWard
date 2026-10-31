import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/auth/presentation/auth_screen.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('Auth Routing and Screen Security', () {
    testWidgets(
      'deterministic dynamic auth transition: unauthenticated -> emit signedIn -> leaves /auth -> emit signedOut -> returns to /auth',
      (tester) async {
        final authController = StreamController<AuthState>.broadcast();
        addTearDown(authController.close);

        const config = AppConfig(
          environment: AppEnvironment.staging,
          supabaseUrl: 'https://example.supabase.co',
          supabasePublishableKey: 'sb_pub_key_123',
        );
        final fakeFamilyRepo = FakeFamilyRepository(
          currentUserId: 'adult-123',
          families: [],
        );
        final fakeChildRepo = FakeChildProfileRepository();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(config),
              authStateProvider.overrideWith((ref) => authController.stream),
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
              familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
              childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            ],
            child: const LearnWardApp(),
          ),
        );

        // 1. Initial state: unauthenticated
        authController.add(
          const AuthState(AuthChangeEvent.initialSession, null),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.text('Adult Sign In'), findsOneWidget);

        // 2. Emit authentication event: signed in
        final user = User(
          id: 'adult-123',
          appMetadata: {},
          userMetadata: {},
          aud: 'authenticated',
          createdAt: DateTime.now().toIso8601String(),
        );
        final session = Session(
          accessToken: 'test-token',
          tokenType: 'bearer',
          user: user,
        );
        authController.add(AuthState(AuthChangeEvent.signedIn, session));
        await tester.pumpAndSettle();

        // Router automatically reacts: leaves /auth and routes to family home
        expect(find.byType(AuthScreen), findsNothing);
        expect(find.text('No Family Found'), findsOneWidget);

        // 3. Emit signed out event
        authController.add(const AuthState(AuthChangeEvent.signedOut, null));
        await tester.pumpAndSettle();

        // Router automatically reacts: redirects back to /auth
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.text('Adult Sign In'), findsOneWidget);
      },
    );

    testWidgets('Supabase configured with no session redirects to /auth', (
      tester,
    ) async {
      final authController = StreamController<AuthState>.broadcast();
      addTearDown(authController.close);

      const config = AppConfig(
        environment: AppEnvironment.staging,
        supabaseUrl: 'https://example.supabase.co',
        supabasePublishableKey: 'sb_pub_key_123',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(config),
            authStateProvider.overrideWith((ref) => authController.stream),
            localMetadataStoreProvider.overrideWithValue(
              InMemoryLocalMetadataStore(),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      authController.add(const AuthState(AuthChangeEvent.initialSession, null));
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
        final authController = StreamController<AuthState>.broadcast();
        addTearDown(authController.close);

        const config = AppConfig(
          environment: AppEnvironment.production,
          supabaseUrl: 'https://prod.supabase.co',
          supabasePublishableKey: 'sb_pub_key_prod',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(config),
              authStateProvider.overrideWith((ref) => authController.stream),
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        authController.add(
          const AuthState(AuthChangeEvent.initialSession, null),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byKey(const Key('demo_bypass_button')), findsNothing);
      },
    );

    testWidgets(
      'Development mode with demo allowed renders demo bypass button',
      (tester) async {
        final authController = StreamController<AuthState>.broadcast();
        addTearDown(authController.close);

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
              authStateProvider.overrideWith((ref) => authController.stream),
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        authController.add(
          const AuthState(AuthChangeEvent.initialSession, null),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byKey(const Key('demo_bypass_button')), findsOneWidget);
      },
    );
  });
}
