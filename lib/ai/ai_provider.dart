/// The optional language-model layer.
///
/// Deliberately narrow. A provider is handed an already-computed
/// [FinanceBrief] and asked for prose about it — it is never given raw
/// transactions, never asked to add anything up, and its output is never
/// parsed back into numbers. If every implementation here vanished, the
/// Insights tab would still show every figure it shows today.
library;

import 'package:meta/meta.dart';

import '../domain/analytics/insight_rules.dart';

/// A narration failure worth telling the user about.
///
/// Exists because silently swallowing errors here made a broken request
/// indistinguishable from a model with nothing to say — the UI showed "no
/// response" and there was no way to tell why.
class AiException implements Exception {
  final String message;
  const AiException(this.message);

  @override
  String toString() => message;
}

/// Whether a model can currently be reached, and what is available.
class AiAvailability {
  final bool reachable;
  final List<String> models;
  final String? activeModel;

  /// Why it is unreachable, in words meant for the user rather than a log.
  final String? reason;

  const AiAvailability({
    required this.reachable,
    this.models = const [],
    this.activeModel,
    this.reason,
  });

  const AiAvailability.unavailable(String this.reason)
    : reachable = false,
      models = const [],
      activeModel = null;

  bool get hasModel => reachable && models.isNotEmpty;
}

/// A source of narrated advice.
abstract class AiProvider {
  /// Cheap reachability probe. Must not throw.
  Future<AiAvailability> check();

  /// Streams prose about [brief], token by token.
  ///
  /// Streaming rather than a single result because generation on CPU takes
  /// tens of seconds; watching text appear is tolerable where staring at a
  /// spinner for the same duration is not.
  Stream<String> narrate(FinanceBrief brief);

  /// Releases any held resources.
  void dispose() {}
}

/// The provider used when no model is configured or reachable.
///
/// Not an error state. The Insights tab is designed to be complete without a
/// model, so this simply produces nothing and the deterministic cards stand on
/// their own.
class NullAiProvider implements AiProvider {
  final String reason;

  const NullAiProvider([this.reason = 'No local model configured']);

  @override
  Future<AiAvailability> check() async => AiAvailability.unavailable(reason);

  @override
  Stream<String> narrate(FinanceBrief brief) => const Stream.empty();

  @override
  void dispose() {}
}

/// Progress of a model download.
///
/// Ollama reports bytes per layer rather than for the whole pull, so [fraction]
/// is the progress of the layer currently downloading, not of everything left
/// to do. A pull visibly restarts its bar several times; that is the server's
/// shape, and pretending otherwise would mean inventing a total.
@immutable
class PullProgress {
  /// The server's own words — "pulling manifest", "verifying sha256 digest".
  final String status;

  final int completedBytes;
  final int totalBytes;

  /// Set when the pull failed. The stream ends after this.
  final String? error;

  const PullProgress({
    required this.status,
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  bool get isDone => status == 'success';
  bool get hasFailed => error != null;

  /// Null when the server has not said how big this layer is — during manifest
  /// and verification steps there is nothing to measure, and a determinate bar
  /// frozen at zero reads as broken rather than as busy.
  double? get fraction =>
      totalBytes > 0 ? (completedBytes / totalBytes).clamp(0.0, 1.0) : null;
}
