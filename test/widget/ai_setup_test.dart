import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend/ai/ai_provider.dart';
import 'package:spend/ai/ai_providers.dart';
import 'package:spend/core/providers.dart';
import 'package:spend/core/theme/app_theme.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/features/settings/ai_section.dart';

/// The model-download panel in Settings.
///
/// What these guard is not the streaming — that is covered against a real
/// server in test/ai/pull_model_test.dart — but the decisions the screen makes
/// about when to offer a download at all. Both of the behaviours here were
/// wrong in the first version and were found by running the app against a real
/// Ollama rather than by reading the widget.
void main() {
  late SpendDatabase db;

  setUp(() => db = SpendDatabase.memory());
  tearDown(() => db.close());

  Future<void> pump(
    WidgetTester tester,
    AiAvailability availability, {
    Size size = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // Returned synchronously, not as a Future. An async override gives one
        // loading frame, and that frame is an indeterminate
        // LinearProgressIndicator — which pumpAndSettle then waits on until
        // its ten-minute timeout. Resolving immediately keeps the spinner out
        // of the tree entirely.
        aiAvailabilityProvider.overrideWith((ref) => availability),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SingleChildScrollView(child: AiSection())),
        ),
      ),
    );
    await tester.pump();

    // Registered, not called at the end of each body: a failed expect aborts
    // the test, and drift's zero-duration cancel timer would then surface as
    // "A Timer is still pending" instead of the assertion that actually
    // failed. Disposing the container is what cancels the setting streams, so
    // the pump that flushes their timer has to come after it, not before.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  testWidgets('with nothing installed the picker is on screen straight away', (
    tester,
  ) async {
    await pump(
      tester,
      const AiAvailability(
        reachable: true,
        models: [],
        reason: 'Ollama is running but has no models yet.',
      ),
    );

    expect(find.text('Download a model'), findsOneWidget);
    expect(find.text('Get'), findsNWidgets(SuggestedModel.catalogue.length));
    expect(find.text('Installed'), findsNothing);
    // No disclosure to press: there is nothing to collapse it behind.
    expect(find.text('Download another model'), findsNothing);
  });

  testWidgets('a model already installed is named, not offered again', (
    tester,
  ) async {
    await pump(
      tester,
      const AiAvailability(
        reachable: true,
        models: ['llama3.2:3b'],
        activeModel: 'llama3.2:3b',
      ),
    );

    // Collapsed by default — someone who is set up should not be nagged.
    expect(find.text('Download a model'), findsNothing);
    await tester.tap(find.text('Download another model'));
    await tester.pump();

    expect(find.text('Download a model'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    // One fewer Get than the catalogue: the installed one is not offered.
    expect(
      find.text('Get'),
      findsNWidgets(SuggestedModel.catalogue.length - 1),
    );
    // And it no longer implies Ollama might not be running.
    expect(find.textContaining('has to be running first'), findsNothing);
  });

  testWidgets('the picker fits the narrowest window the app allows', (
    tester,
  ) async {
    // WindowModes.minimumSize is 760x620 — the narrowest the window can be
    // dragged to. A previous Row in this app overflowed by 164px at a width
    // that looked generous on paper, so the number here is the real limit
    // rather than a guess.
    await pump(
      tester,
      const AiAvailability(
        reachable: true,
        models: ['llama3.2:3b'],
        activeModel: 'llama3.2:3b',
      ),
      size: const Size(760, 620),
    );

    await tester.tap(find.text('Download another model'));
    await tester.pump();

    expect(find.text('Installed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
