import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app shell launches on a device', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(
            InMemoryLocalMetadataStore(),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LearnWard'), findsOneWidget);
    expect(find.text('No Family Found'), findsOneWidget);
  });
}
