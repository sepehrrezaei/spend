/// Prompt construction for the narration task.
library;

import 'dart:convert';

import '../domain/analytics/insight_rules.dart';

abstract final class PromptBuilder {
  /// The system prompt.
  ///
  /// Tuned against observed behaviour rather than guessed at. Left to itself
  /// on a bare pair of figures, a small model volunteers things like "the
  /// individual may be struggling to manage their finances" — moralising
  /// invented from two numbers. The constraints below exist to stop that:
  /// speak to the user directly, use only supplied figures, no invented
  /// causes, no lecturing.
  static const system = '''
You write short, factual notes about a person's own spending data.

Rules, all of them strict:
- Address the reader as "you". Never write about "the user" or "the individual".
- Use ONLY the figures given in the JSON. Never calculate, estimate, or infer a
  number that is not present. If you want to state an amount, copy it exactly.
- Never invent a time frame. The comparison period is named explicitly in the
  data; describe it exactly as labelled. Do not call it "last year", "last
  quarter" or anything other than what the label says.
- Percentages are given as whole numbers in fields ending in "_percent". State
  them as percentages. Never reinterpret one as a multiple ("times").
- Never speculate about the reader's finances, habits, income, motives or
  circumstances. You know nothing beyond the data provided.
- No moralising, no praise, no encouragement, no warnings about debt.
- Write 2 to 4 sentences of plain prose. No lists, no headings, no markdown.
- Prefer the observations marked "alert" and "caution", but never mention those
  labels. Do not write "this is a cautionary alert" — just say the thing.
- If something specific and useful can be suggested from the data, end with one
  concrete sentence. Otherwise stop.

Currency amounts in the JSON are in major units of the stated currency.''';

  /// The user turn: the brief as JSON plus a one-line instruction.
  ///
  /// Structured JSON rather than pre-written English, so the model has no
  /// prose to parrot back and must ground every claim in a value.
  static String userMessage(FinanceBrief brief) {
    final json = const JsonEncoder.withIndent('  ').convert(brief.toJson());
    return 'Here is the data for the current period:\n\n$json\n\n'
        'Write the note.';
  }
}
