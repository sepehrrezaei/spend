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

// ------------------------------------------------------------------- pull

enum PullStatus { idle, pulling, done, failed }

class ModelPullState {
  final PullStatus status;
  final String statusMessage;

  /// Download fraction in [0, 1], or `null` when Ollama has not sent byte
  /// counts yet (e.g. during "pulling manifest").
  final double? fraction;
  final String? error;

  const ModelPullState({
    this.status = PullStatus.idle,
    this.statusMessage = '',
    this.fraction,
    this.error,
  });

  bool get isPulling => status == PullStatus.pulling;
}

/// Drives an `/api/pull` request and tracks streaming progress.
///
/// Tied to the current provider so that changing the host or toggling Local AI
/// off resets it — a pull to the old address should not bleed into a new one.
class ModelPull extends Notifier<ModelPullState> {
  StreamSubscription<PullProgress>? _sub;

  @override
  ModelPullState build() {
    ref.onDispose(() => _sub?.cancel());
    ref.watch(aiProviderProvider); // reset when provider changes
    return const ModelPullState();
  }

  Future<void> pull(String modelName) async {
    if (state.isPulling) return;
    final name = modelName.trim();
    if (name.isEmpty) return;

    final provider = ref.read(aiProviderProvider);
    if (provider is! OllamaProvider) {
      state = const ModelPullState(
        status: PullStatus.failed,
        error: 'Local AI is not enabled.',
      );
      return;
    }

    await _sub?.cancel();
    state = ModelPullState(
      status: PullStatus.pulling,
      statusMessage: 'Starting…',
    );

    _sub = provider.pullModel(name).listen(
      (p) {
        state = ModelPullState(
          status: PullStatus.pulling,
          statusMessage: p.status,
          fraction: p.fraction,
        );
      },
      onError: (Object e) {
        state = ModelPullState(
          status: PullStatus.failed,
          error: e is AiException ? e.message : e.toString(),
        );
      },
      onDone: () {
        // If we never heard "success" treat it as complete anyway.
        if (state.isPulling) {
          state = ModelPullState(
            status: PullStatus.done,
            statusMessage: state.statusMessage,
          );
        }
        // Refresh availability so the new model shows up in the dropdown.
        ref.invalidate(aiAvailabilityProvider);
      },
    );
  }

  void reset() {
    _sub?.cancel();
    state = const ModelPullState();
  }
}

final modelPullProvider = NotifierProvider<ModelPull, ModelPullState>(
  ModelPull.new,
);

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
