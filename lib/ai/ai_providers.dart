/// Dependency injection for the optional model layer and the insight rules.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/date_range.dart';
import '../core/day.dart';
import '../core/money.dart';
import '../core/providers.dart';
import '../domain/analytics/analytics_engine.dart';
import '../domain/analytics/insight_rules.dart';
import '../domain/entities/spend_record.dart';
import 'package:meta/meta.dart';

import 'ai_provider.dart';
import 'ollama_provider.dart';

// ------------------------------------------------------------------ settings

final ollamaHostProvider = settingProvider(
  SettingKeys.ollamaHost,
  OllamaProvider.defaultHost,
);

final ollamaModelProvider = settingProvider(
  SettingKeys.ollamaModel,
  OllamaProvider.defaultModel,
);

final aiEnabledProvider = settingProvider(SettingKeys.ollamaEnabled, 'true');

final aiProviderProvider = Provider<AiProvider>((ref) {
  final enabled = (ref.watch(aiEnabledProvider).value ?? 'true') == 'true';
  if (!enabled) {
    return const NullAiProvider('Local AI is switched off in Settings');
  }

  final provider = OllamaProvider(
    host: ref.watch(ollamaHostProvider).value ?? OllamaProvider.defaultHost,
    model: ref.watch(ollamaModelProvider).value ?? OllamaProvider.defaultModel,
  );
  ref.onDispose(provider.dispose);
  return provider;
});

/// Whether a model can be reached right now.
///
/// Deliberately a plain future rather than a poll. Availability only changes
/// when the user starts or stops a container, and quietly hammering localhost
/// every few seconds forever would be rude for no benefit — the Insights tab
/// offers a refresh instead.
final aiAvailabilityProvider = FutureProvider<AiAvailability>(
  (ref) => ref.watch(aiProviderProvider).check(),
);

// ------------------------------------------------------------------ insights

/// Per-category monthly totals over the last six months, for the anomaly rule.
final categoryHistoryProvider = StreamProvider<Map<int, List<Money>>>((ref) {
  final end = ref.watch(currentRangeProvider).end;
  final start = end.firstOfMonth.addMonths(-5);
  return ref
      .watch(transactionRepositoryProvider)
      .watchInRange(DateRange(start, end))
      .map(
        (records) => const AnalyticsEngine().categoryMonthlyTotals(
          records,
          endMonth: end,
          months: 6,
        ),
      );
});

/// Recent transactions, for spotting unrecorded subscriptions.
final subscriptionScanProvider = StreamProvider<List<SpendRecord>>((ref) {
  final end = ref.watch(currentRangeProvider).end;
  final start = end.firstOfMonth.addMonths(-3);
  return ref
      .watch(transactionRepositoryProvider)
      .watchInRange(DateRange(start, end));
});

/// The deterministic observations. Always available, model or not.
final insightsProvider = Provider<AsyncValue<List<Insight>>>((ref) {
  final money = ref.watch(moneyFormatterProvider);
  final budgets = ref.watch(budgetStatusesProvider).value ?? const [];
  final history = ref.watch(categoryHistoryProvider).value ?? const {};
  final scan = ref.watch(subscriptionScanProvider).value ?? const [];
  final categories = ref.watch(allCategoriesProvider).value ?? const [];

  return ref
      .watch(periodSummaryProvider)
      .whenData(
        (summary) => InsightRules(money.format).evaluate(
          summary: summary,
          budgets: budgets,
          categoryHistory: history,
          historyRecords: scan,
          categoryNames: {for (final c in categories) c.id: c.name},
          today: Day.today(),
        ),
      );
});

/// The brief handed to the model — exactly the figures already on screen.
final financeBriefProvider = Provider<AsyncValue<FinanceBrief>>((ref) {
  final insights = ref.watch(insightsProvider).value ?? const [];
  final currency = ref.watch(currencyProvider).value ?? 'EUR';

  return ref
      .watch(periodSummaryProvider)
      .whenData(
        (summary) => FinanceBrief.from(
          summary: summary,
          insights: insights,
          currency: currency,
        ),
      );
});

// ----------------------------------------------------------------- narration

enum NarrationStatus { idle, running, done, failed }

class NarrationState {
  final NarrationStatus status;
  final String text;
  final String? error;

  const NarrationState({
    this.status = NarrationStatus.idle,
    this.text = '',
    this.error,
  });

  bool get isRunning => status == NarrationStatus.running;
  bool get hasText => text.trim().isNotEmpty;
}

/// Runs a narration on demand and accumulates the streamed text.
///
/// Manual rather than automatic. A generation costs tens of seconds of CPU,
/// and firing one every time the period selector moves would make the app feel
/// broken while producing text nobody asked for.
class Narration extends Notifier<NarrationState> {
  StreamSubscription<String>? _subscription;

  @override
  NarrationState build() {
    ref.onDispose(() => _subscription?.cancel());
    // Changing period invalidates whatever was written about the old one.
    ref.watch(currentRangeProvider);
    return const NarrationState();
  }

  Future<void> run() async {
    if (state.isRunning) return;

    final brief = ref.read(financeBriefProvider).value;
    if (brief == null) return;

    await _subscription?.cancel();
    state = const NarrationState(status: NarrationStatus.running);

    final buffer = StringBuffer();
    _subscription = ref
        .read(aiProviderProvider)
        .narrate(brief)
        .listen(
          (chunk) {
            buffer.write(chunk);
            state = NarrationState(
              status: NarrationStatus.running,
              text: buffer.toString(),
            );
          },
          onError: (Object e) {
            state = NarrationState(
              status: NarrationStatus.failed,
              text: buffer.toString(),
              error: e.toString(),
            );
          },
          onDone: () {
            state = NarrationState(
              // An empty response means the provider was unavailable rather
              // than that the model had nothing to say.
              status: buffer.isEmpty
                  ? NarrationStatus.failed
                  : NarrationStatus.done,
              text: buffer.toString(),
              error: buffer.isEmpty ? 'No response from the model.' : null,
            );
          },
        );
  }

  void clear() {
    _subscription?.cancel();
    state = const NarrationState();
  }
}

final narrationProvider = NotifierProvider<Narration, NarrationState>(
  Narration.new,
);

/// Models offered in Settings, with the reason each is here.
///
/// A bare list of names tells a user nothing about which to pick, and picking
/// wrong on a 16GB machine means a model that swaps rather than one that is
/// slow. Sizes are the download, not the memory footprint.
@immutable
class SuggestedModel {
  final String name;
  final String size;
  final String note;
  final bool recommended;

  const SuggestedModel({
    required this.name,
    required this.size,
    required this.note,
    this.recommended = false,
  });

  static const catalogue = <SuggestedModel>[
    SuggestedModel(
      name: OllamaProvider.defaultModel,
      size: '~2 GB',
      note: 'Comfortable on 16GB. Enough for the narration this app asks for.',
      recommended: true,
    ),
    SuggestedModel(
      name: 'llama3.2:1b',
      size: '~1.3 GB',
      note: 'Faster and lighter. Blunter prose, same figures.',
    ),
    SuggestedModel(
      name: 'qwen2.5:7b',
      size: '~4.7 GB',
      note: 'Better phrasing, noticeably slower on CPU.',
    ),
  ];
}
