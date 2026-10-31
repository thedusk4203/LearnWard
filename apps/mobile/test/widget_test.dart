import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';

void main() {
  testWidgets('renders the Phase 0 foundation shell', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LearnWardApp()));
    await tester.pumpAndSettle();

    expect(find.text('LearnWard'), findsOneWidget);
    expect(find.text('Engineering foundation ready'), findsOneWidget);
    expect(find.text('Development'), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
  });

  testWidgets('reflects an injected environment configuration', (tester) async {
    const config = AppConfig(
      environment: AppEnvironment.staging,
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: 'public-test-key',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appConfigProvider.overrideWithValue(config)],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Staging'), findsOneWidget);
    expect(find.text('Configured'), findsOneWidget);
  });
}
