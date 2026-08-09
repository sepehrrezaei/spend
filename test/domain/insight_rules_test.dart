import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/date_range.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/domain/analytics/analytics_engine.dart';
import 'package:spend/domain/analytics/budget_status.dart';
import 'package:spend/domain/analytics/insight_rules.dart';
import 'package:spend/domain/analytics/period_summary.dart';
import 'package:spend/domain/entities/budget_definition.dart';
import 'package:spend/domain/entities/enums.dart';
import 'package:spend/domain/entities/spend_record.dart';

String euros(Money m) => '€${m.major.toStringAsFixed(2)}';
final rules = InsightRules(euros);
const engine = AnalyticsEngine();

var _nextId = 1;

SpendRecord rec(
  String iso,
  int minor, {
  int cat = 1,
  String name = 'Groceries',
  String merchant = '',
  bool recurring = false,
}) => SpendRecord(
  id: _nextId++,
  amount: Money(minor),
  occurredOn: Day.parse(iso),
  categoryId: cat,
  categoryName: name,
  categoryIcon: 'tag',
  categoryColor: 0,
  categoryKind: CategoryKind.expense,
  merchant: merchant,
  recurringRuleId: recurring ? 7 : null,
);

final july = DateRange.month(Day(2025, 7, 1));
final june = DateRange.month(Day(2025, 6, 1));

PeriodSummary summarise(
  List<SpendRecord> records, {
  List<SpendRecord> previous = const [],
  String today = '2025-07-31',
}) => engine.summarise(
  records: records,
  previousRecords: previous,
  range: july,
  previousRange: june,
  today: Day.parse(today),
);

List<Insight> run(
  PeriodSummary summary, {
  List<BudgetStatus> budgets = const [],
  Map<int, List<Money>> history = const {},
  List<SpendRecord> scan = const [],
  String today = '2025-07-31',
}) => rules.evaluate(
  summary: summary,
  budgets: budgets,
  categoryHistory: history,
  historyRecords: scan,
  today: Day.parse(today),
);

Insight? find(List<Insight> insights, String rule) {
  for (final i in insights) {
    if (i.rule == rule) return i;
  }
  return null;
}

BudgetStatus budgetStatus({
  required int limit,
  required int spent,
  String today = '2025-07-20',
  int? categoryId = 1,
}) => BudgetStatus(
  budget: BudgetDefinition(
    id: 1,
    categoryId: categoryId,
    period: BudgetPeriod.monthly,
    limit: Money(limit),
    startsOn: Day(2025, 1, 1),
  ),
  period: july,
  asOf: Day.parse(today),
  spent: Money(spent),
  transactionCount: 1,
);

void main() {
  setUp(() => _nextId = 1);

  group('budgets', () {
    test('an exceeded budget is an alert with the overspend', () {
      final insights = run(
        summarise([rec('2025-07-01', 52000)]),
        budgets: [budgetStatus(limit: 45000, spent: 52000)],
      );
      final i = find(insights, 'budget_exceeded')!;
      expect(i.severity, InsightSeverity.alert);
      expect(i.facts['over_by_minor'], 7000);
      expect(i.detail, contains('€70.00'));
    });

    test('running ahead is a caution, not an alert', () {
      final insights = run(
        summarise([rec('2025-07-01', 30000)]),
        budgets: [
          budgetStatus(limit: 40000, spent: 30000, today: '2025-07-08'),
        ],
      );
      final i = find(insights, 'budget_over_pace')!;
      expect(i.severity, InsightSeverity.caution);
      expect(i.facts['projected_minor'], greaterThan(40000));
    });

    test('a healthy budget produces nothing', () {
      final insights = run(
        summarise([rec('2025-07-01', 10000)]),
        budgets: [budgetStatus(limit: 45000, spent: 10000)],
      );
      expect(find(insights, 'budget_exceeded'), isNull);
      expect(find(insights, 'budget_over_pace'), isNull);
    });
  });

  group('category anomalies', () {
    test('flags a category well above its own recent norm', () {
      final summary = summarise([rec('2025-07-01', 40000)]);
      final insights = run(
        summary,
        // Five stable months, then the current one at four times the rate.
        history: {
          1: [
            Money(10000),
            Money(10500),
            Money(9800),
            Money(10200),
            Money(40000),
          ],
        },
      );
      final i = find(insights, 'category_unusually_high')!;
      expect(i.severity, InsightSeverity.caution);
      expect(i.facts['current_minor'], 40000);
      expect(i.facts['average_minor'], 10125);
      expect(i.facts['difference_minor'], 29875);
      // The z-score decides whether the rule fires; it is not handed to the
      // model, because "a z-score of 2.14" means nothing to a reader.
      expect(i.facts.containsKey('z_score'), isFalse);
      expect(i.detail, contains('€400.00'));
    });

    test('an unusually quiet category is good news, not a warning', () {
      final summary = summarise([rec('2025-07-01', 2000)]);
      final insights = run(
        summary,
        history: {
          1: [
            Money(20000),
            Money(21000),
            Money(19500),
            Money(20500),
            Money(2000),
          ],
        },
      );
      final i = find(insights, 'category_unusually_low')!;
      expect(i.severity, InsightSeverity.good);
    });

    test('says nothing without enough history to have a norm', () {
      final summary = summarise([rec('2025-07-01', 40000)]);
      final insights = run(
        summary,
        history: {
          1: [Money(10000), Money(40000)],
        },
      );
      expect(find(insights, 'category_unusually_high'), isNull);
    });

    test('ignores a large percentage swing on a trivial amount', () {
      // €2 to €8 is a 300% rise and completely meaningless.
      final summary = summarise([rec('2025-07-01', 800)]);
      final insights = run(
        summary,
        history: {
          1: [Money(200), Money(180), Money(220), Money(200), Money(800)],
        },
      );
      expect(find(insights, 'category_unusually_high'), isNull);
    });

    test('a mostly-empty history means no norm, so no anomaly', () {
      // The regression this guards: with only two months of real data in a
      // six-month window, averaging the empty months in dragged the mean to
      // near zero and flagged six ordinary categories at once.
      final summary = summarise([rec('2025-07-01', 120000)]);
      final insights = run(
        summary,
        history: {
          1: [Money.zero, Money.zero, Money.zero, Money(115000), Money(120000)],
        },
      );
      expect(find(insights, 'category_unusually_high'), isNull);
    });

    test('at most two anomalies surface, the most extreme ones', () {
      final summary = summarise([
        rec('2025-07-01', 40000, cat: 1, name: 'Groceries'),
        rec('2025-07-02', 30000, cat: 2, name: 'Dining'),
        rec('2025-07-03', 26000, cat: 3, name: 'Transport'),
      ]);
      final steady = [Money(10000), Money(10200), Money(9800), Money(10000)];
      final insights = run(
        summary,
        history: {
          1: [...steady, Money(40000)], // biggest jump
          2: [...steady, Money(30000)],
          3: [...steady, Money(26000)], // smallest jump
        },
      );

      final anomalies = insights
          .where((i) => i.rule == 'category_unusually_high')
          .toList();
      expect(anomalies, hasLength(2));
      expect(
        anomalies.map((a) => a.facts['category']),
        containsAll(['Groceries', 'Dining']),
      );
      expect(
        anomalies.map((a) => a.facts['category']),
        isNot(contains('Transport')),
      );
    });

    test(
      'a perfectly steady category does not become infinitely anomalous',
      () {
        // Zero deviation would divide by zero; the floor keeps it sane, and an
        // identical month must not be flagged at all.
        final summary = summarise([rec('2025-07-01', 10000)]);
        final insights = run(
          summary,
          history: {
            1: [
              Money(10000),
              Money(10000),
              Money(10000),
              Money(10000),
              Money(10000),
            ],
          },
        );
        expect(find(insights, 'category_unusually_high'), isNull);
        expect(find(insights, 'category_unusually_low'), isNull);
      },
    );
  });

  group('trend', () {
    test('names the single fastest-growing category', () {
      final summary = summarise(
        [
          rec('2025-07-01', 20000, cat: 1, name: 'Groceries'),
          rec('2025-07-02', 12000, cat: 2, name: 'Dining'),
        ],
        previous: [
          rec('2025-06-01', 18000, cat: 1, name: 'Groceries'),
          rec('2025-06-02', 3000, cat: 2, name: 'Dining'),
        ],
      );
      final i = find(
        summary.categories.isEmpty ? [] : run(summary),
        'category_growing',
      )!;
      expect(i.facts['category'], 'Dining');
      expect(i.facts['increase_minor'], 9000);
    });

    test('ignores growth that is only a few euros', () {
      final summary = summarise(
        [rec('2025-07-01', 1500)],
        previous: [rec('2025-06-01', 500)],
      );
      expect(find(run(summary), 'category_growing'), isNull);
    });

    test('reports pace against the same days last period', () {
      final summary = summarise(
        [rec('2025-07-01', 30000)],
        previous: [rec('2025-06-01', 10000)],
        today: '2025-07-10',
      );
      final i = find(run(summary, today: '2025-07-10'), 'period_ahead')!;
      expect(i.severity, InsightSeverity.caution);
      expect(i.facts['elapsed_days'], 10);
      expect(i.facts['previous_same_days_minor'], 10000);
    });

    test('spending less is surfaced as good', () {
      final summary = summarise(
        [rec('2025-07-01', 5000)],
        previous: [rec('2025-06-01', 30000)],
        today: '2025-07-10',
      );
      final i = find(run(summary, today: '2025-07-10'), 'period_behind')!;
      expect(i.severity, InsightSeverity.good);
    });
  });

  group('composition', () {
    test('notes when most spending is already committed', () {
      final summary = summarise([
        rec('2025-07-01', 120000, cat: 2, name: 'Rent', recurring: true),
        rec('2025-07-04', 20000),
      ]);
      final i = find(run(summary), 'fixed_cost_heavy')!;
      expect(i.facts['fixed_minor'], 120000);
      expect(i.facts['discretionary_minor'], 20000);
    });

    test('compares weekends by daily rate, not by total', () {
      // Weekdays total far more, but there are far more of them. Per day the
      // weekend is heavier, which is the fact worth reporting.
      final records = <SpendRecord>[
        for (final d in [5, 6, 12, 13, 19, 20, 26, 27])
          rec('2025-07-${d.toString().padLeft(2, "0")}', 8000),
        for (final d in [7, 8, 9, 10, 11, 14, 15, 16, 17, 18])
          rec('2025-07-${d.toString().padLeft(2, "0")}', 2000),
      ];
      final summary = summarise(records);
      final i = find(run(summary), 'weekend_heavy')!;
      expect(summary.weekdayTotal.minor, 20000);
      expect(summary.weekendTotal.minor, 64000);
      // Percentages, not raw ratios: a bare 1.8 gets written as
      // "1.8 times" or worse, mashed into a neighbouring figure.
      expect(i.facts['weekend_percent_of_weekday'], greaterThan(160));
    });

    test('a dominant one-off purchase is called out', () {
      final summary = summarise([
        rec('2025-07-01', 90000, merchant: 'Decathlon'),
        rec('2025-07-02', 10000),
      ]);
      final i = find(run(summary), 'single_large_purchase')!;
      expect(i.facts['label'], 'Decathlon');
      expect(i.facts['percent_of_period'], greaterThan(80));
    });

    test('rent dominating the month is not treated as news', () {
      final summary = summarise([
        rec('2025-07-01', 120000, name: 'Rent', recurring: true),
        rec('2025-07-02', 10000),
      ]);
      expect(find(run(summary), 'single_large_purchase'), isNull);
    });

    test('a no-spend streak is reported as an achievement', () {
      final summary = summarise([
        rec('2025-07-01', 5000),
        rec('2025-07-20', 5000),
      ]);
      final i = find(run(summary), 'no_spend_streak')!;
      expect(i.severity, InsightSeverity.good);
      expect(i.facts['longest_streak'], 18);
    });
  });

  group('unrecorded subscriptions', () {
    test('spots the same charge in three consecutive months', () {
      final scan = [
        rec('2025-05-03', 1099, merchant: 'Spotify'),
        rec('2025-06-03', 1099, merchant: 'Spotify'),
        rec('2025-07-03', 1099, merchant: 'Spotify'),
      ];
      final i = find(run(summarise([]), scan: scan), 'possible_subscription')!;
      expect(i.facts['merchant'], 'Spotify');
      expect(i.facts['typical_minor'], 1099);
      expect(i.facts['months_seen'], 3);
    });

    test('tolerates a small price change', () {
      final scan = [
        rec('2025-05-03', 1099, merchant: 'Spotify'),
        rec('2025-06-03', 1099, merchant: 'Spotify'),
        rec('2025-07-03', 1149, merchant: 'Spotify'),
      ];
      expect(
        find(run(summarise([]), scan: scan), 'possible_subscription'),
        isNotNull,
      );
    });

    test('does not flag something already recorded as recurring', () {
      final scan = [
        rec('2025-05-03', 1099, merchant: 'Spotify', recurring: true),
        rec('2025-06-03', 1099, merchant: 'Spotify', recurring: true),
        rec('2025-07-03', 1099, merchant: 'Spotify', recurring: true),
      ];
      expect(
        find(run(summarise([]), scan: scan), 'possible_subscription'),
        isNull,
      );
    });

    test('three coffees in one month is not a subscription', () {
      final scan = [
        rec('2025-07-03', 350, merchant: 'Coffee Company'),
        rec('2025-07-10', 350, merchant: 'Coffee Company'),
        rec('2025-07-17', 350, merchant: 'Coffee Company'),
      ];
      expect(
        find(run(summarise([]), scan: scan), 'possible_subscription'),
        isNull,
      );
    });

    test('wildly varying amounts at one merchant are not a subscription', () {
      final scan = [
        rec('2025-05-03', 1200, merchant: 'Albert Heijn'),
        rec('2025-06-03', 4500, merchant: 'Albert Heijn'),
        rec('2025-07-03', 2200, merchant: 'Albert Heijn'),
      ];
      expect(
        find(run(summarise([]), scan: scan), 'possible_subscription'),
        isNull,
      );
    });
  });

  group('ordering and the model brief', () {
    test('alerts come before cautions, which come before the rest', () {
      final summary = summarise([
        rec('2025-07-01', 120000, cat: 2, name: 'Rent', recurring: true),
        rec('2025-07-04', 20000),
      ]);
      final insights = run(
        summary,
        budgets: [budgetStatus(limit: 45000, spent: 140000)],
      );
      expect(insights.first.severity, InsightSeverity.alert);
      final weights = insights.map((i) => i.severity.weight).toList();
      expect(
        weights,
        orderedEquals(([...weights]..sort((a, b) => b.compareTo(a)))),
      );
    });

    test('the brief gives the model major units, never raw cents', () {
      final summary = summarise([rec('2025-07-01', 123456)]);
      final brief = FinanceBrief.from(
        summary: summary,
        insights: run(summary),
        currency: 'EUR',
      );
      final json = brief.toJson();

      // 1234.56, not 123456 — a model handed cents writes "123,456 euros".
      expect(json['spent'], 1234.56);
      expect(json['currency'], 'EUR');
      expect((json['top_categories'] as List).first, {
        'name': 'Groceries',
        'amount': 1234.56,
        'share_percent': 100,
      });
      expect(json['period'], '2025-07-01 to 2025-07-31');
    });

    test('the comparison window is named with its real dates', () {
      // The regression this guards: given only "spent_same_days_last_period",
      // the model described the previous month as "last year's same period".
      final complete = summarise([rec('2025-07-05', 5000)]);
      final brief = FinanceBrief.from(
        summary: complete,
        insights: const [],
        currency: 'EUR',
      );
      expect(
        (brief.toJson()['comparison'] as Map)['dates'],
        '2025-06-01 to 2025-06-30',
      );

      // Mid-period, the comparison is truncated to the elapsed days so it is
      // like for like — and says so.
      final partial = summarise([rec('2025-07-05', 5000)], today: '2025-07-10');
      final partialBrief = FinanceBrief.from(
        summary: partial,
        insights: const [],
        currency: 'EUR',
      );
      expect(
        (partialBrief.toJson()['comparison'] as Map)['dates'],
        '2025-06-01 to 2025-06-10',
      );
    });

    test('ratios reach the model as whole percentages, not raw fractions', () {
      final summary = summarise(
        [rec('2025-07-01', 20000, cat: 2, name: 'Dining')],
        previous: [rec('2025-06-01', 2000, cat: 2, name: 'Dining')],
      );
      final growth = find(run(summary), 'category_growing')!;
      // 9.0 as a fraction reads as "9 times"; 900 percent cannot be misread.
      expect(growth.facts['increase_percent'], 900);
      expect(growth.facts.containsKey('increase_fraction'), isFalse);
    });

    test(
      'the brief carries structured facts, not prose, for each observation',
      () {
        final summary = summarise([rec('2025-07-01', 52000)]);
        final brief = FinanceBrief.from(
          summary: summary,
          insights: run(
            summary,
            budgets: [budgetStatus(limit: 45000, spent: 52000)],
          ),
          currency: 'EUR',
        );
        final observations = brief.toJson()['observations'] as List;
        final first = observations.first as Map;
        expect(first['rule'], 'budget_exceeded');
        expect(first['severity'], 'alert');

        // Amounts reach the model in major units with the "_minor" suffix
        // stripped. The regression this guards: handed "increase_minor: 10466"
        // the model wrote "an increase in minor expenses of €10466" — echoing
        // the key name and overstating the figure a hundredfold.
        final facts = first['facts'] as Map;
        expect(facts['over_by'], 70.0);
        expect(facts.containsKey('over_by_minor'), isFalse);
        expect(facts['limit'], 450.0);
        expect(facts['spent'], 520.0);
        // Non-amount facts are untouched.
        expect(facts['days_remaining'], isA<int>());
        expect(facts['scope'], 'category');
      },
    );
  });
}
