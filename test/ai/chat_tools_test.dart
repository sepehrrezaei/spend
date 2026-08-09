import 'package:flutter_test/flutter_test.dart';
import 'package:spend/ai/chat_tools.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/data/db/database.dart';
import 'package:spend/data/repositories/transaction_repository.dart';

void main() {
  late SpendDatabase db;
  late ChatTools tools;

  setUp(() async {
    db = SpendDatabase.memory();
    final repo = TransactionRepository(db);

    Future<void> add(String iso, int minor, int category, [String who = '']) =>
        repo.add(
          amount: Money(minor),
          categoryId: category,
          occurredOn: Day.parse(iso),
          merchant: who,
        );

    // Groceries=1, Dining=2, Transport=3, Income=11 in the seeded set.
    await add('2026-06-15', 4000, 1, 'Jumbo');
    await add('2026-07-02', 12000, 1, 'Albert Heijn');
    await add('2026-07-09', 3000, 1, 'Albert Heijn');
    await add('2026-07-14', 8000, 2, 'Cafe Luxe');
    await add('2026-07-20', 25000, 3, 'NS');
    await add('2026-07-25', 300000, 11, 'Salary'); // income
    await add('2026-08-03', 5000, 1, 'Lidl');

    tools = ChatTools(
      repository: repo,
      categories: await db.select(db.categories).get(),
      money: (m) => '€${m.major.toStringAsFixed(2)}',
      currency: 'EUR',
    );
  });

  tearDown(() => db.close());

  group('total_spent', () {
    test('sums only the requested window', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-07-01',
        'to': '2026-07-31',
      });
      expect(r.failed, isFalse);
      // 120 + 30 + 80 + 250, and not June, August, or the salary.
      expect(r.data['total'], 480.0);
      expect(r.data['transaction_count'], 4);
    });

    test('never counts income as spending', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-07-25',
        'to': '2026-07-25',
      });
      expect(r.data['total'], 0.0);
      expect(r.data['transaction_count'], 0);
    });

    test('filters by category, matched case-insensitively', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-07-01',
        'to': '2026-07-31',
        'category': 'groceries',
      });
      expect(r.data['category'], 'Groceries');
      expect(r.data['total'], 150.0);
    });

    test('accepts a near-miss category name', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-07-01',
        'to': '2026-07-31',
        'category': 'grocery',
      });
      expect(r.failed, isFalse);
      expect(r.data['category'], 'Groceries');
    });

    test('an ambiguous near-miss is refused rather than guessed', () async {
      // "s" is close to nothing in particular; guessing between Shopping and
      // Subscriptions would produce a confidently wrong figure.
      final r = await tools.call('total_spent', {
        'from': '2026-07-01',
        'to': '2026-07-31',
        'category': 'sub',
      });
      expect(r.failed, isTrue, reason: 'too short to disambiguate');
    });

    test(
      'a made-up category fails with instructions, not a wrong number',
      () async {
        final r = await tools.call('total_spent', {
          'from': '2026-07-01',
          'to': '2026-07-31',
          'category': 'Yachts',
        });
        expect(r.failed, isTrue);
        expect(r.error, contains('Yachts'));
        expect(r.error, contains('list_categories'));
        expect(r.data, isEmpty);
      },
    );

    test('returns figures in major units, ready to quote', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-07-02',
        'to': '2026-07-02',
      });
      // 120.0, never 12000 — the model would write "12000 euros".
      expect(r.data['total'], 120.0);
    });
  });

  group('repairing what the model sends', () {
    test('accepts unpadded and slash-separated dates', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-7-1',
        'to': '2026/07/31',
      });
      expect(r.failed, isFalse);
      expect(r.data['from'], '2026-07-01');
      expect(r.data['to'], '2026-07-31');
      expect(r.data['total'], 480.0);
    });

    test(
      'swapped dates are put back in order rather than returning nothing',
      () async {
        final r = await tools.call('total_spent', {
          'from': '2026-07-31',
          'to': '2026-07-01',
        });
        expect(r.data['from'], '2026-07-01');
        expect(r.data['total'], 480.0);
      },
    );

    test('a single date is treated as that one day', () async {
      final r = await tools.call('total_spent', {'from': '2026-07-02'});
      expect(r.data['from'], '2026-07-02');
      expect(r.data['to'], '2026-07-02');
      expect(r.data['total'], 120.0);
    });

    test('unusable dates fail loudly and say what is wanted', () async {
      final r = await tools.call('total_spent', {
        'from': 'last month',
        'to': 'now',
      });
      expect(r.failed, isTrue);
      expect(r.error, contains('YYYY-MM-DD'));
    });

    test('an impossible date is rejected, not rolled over', () async {
      final r = await tools.call('total_spent', {
        'from': '2026-02-30',
        'to': '2026-02-30',
      });
      expect(r.failed, isTrue);
    });

    test('an unknown tool name is reported rather than ignored', () async {
      final r = await tools.call('delete_everything', {});
      expect(r.failed, isTrue);
      expect(r.error, contains('delete_everything'));
    });
  });

  group('other tools', () {
    test('spend_by_category ranks and shares add up', () async {
      final r = await tools.call('spend_by_category', {
        'from': '2026-07-01',
        'to': '2026-07-31',
      });
      final categories = r.data['categories'] as List;
      expect(r.data['total'], 480.0);
      expect((categories.first as Map)['name'], 'Transport');
      expect((categories.first as Map)['amount'], 250.0);
      final shares = [
        for (final c in categories) (c as Map)['share_percent'] as int,
      ];
      expect(shares.reduce((a, b) => a + b), closeTo(100, 2));
    });

    test('top_merchants aggregates repeat visits', () async {
      final r = await tools.call('top_merchants', {
        'from': '2026-07-01',
        'to': '2026-07-31',
      });
      final merchants = r.data['merchants'] as List;
      expect((merchants.first as Map)['name'], 'NS');
      final ah =
          merchants.firstWhere((m) => (m as Map)['name'] == 'Albert Heijn')
              as Map;
      expect(ah['amount'], 150.0);
      expect(ah['visits'], 2);
    });

    test('find_transactions filters by amount and merchant', () async {
      final byAmount = await tools.call('find_transactions', {
        'from': '2026-07-01',
        'to': '2026-07-31',
        'min_amount': 100,
      });
      expect(byAmount.data['match_count'], 2); // 120 and 250

      final byMerchant = await tools.call('find_transactions', {
        'from': '2026-07-01',
        'to': '2026-07-31',
        'merchant': 'albert',
      });
      expect(byMerchant.data['match_count'], 2);
      expect(byMerchant.data['total_of_all_matches'], 150.0);
    });

    test('every result states its currency', () async {
      // Without this the model sees a bare 525.84 and writes "\$525.84".
      for (final call in [
        ('total_spent', {'from': '2026-07-01', 'to': '2026-07-31'}),
        ('spend_by_category', {'from': '2026-07-01', 'to': '2026-07-31'}),
        ('top_merchants', {'from': '2026-07-01', 'to': '2026-07-31'}),
        ('find_transactions', {'from': '2026-07-01', 'to': '2026-07-31'}),
      ]) {
        final r = await tools.call(call.$1, call.$2);
        expect(r.data['currency'], 'EUR', reason: call.$1);
      }
    });

    test('list_categories returns the real names', () async {
      final r = await tools.call('list_categories', {});
      final names = r.data['categories'] as List;
      expect(names, contains('Groceries'));
      expect(names, hasLength(11));
    });
  });

  group('tool schemas', () {
    test('are well formed and small enough for a 3B model to choose from', () {
      final schemas = ChatTools.schemas;
      expect(schemas, hasLength(5));
      for (final s in schemas) {
        expect(s['type'], 'function');
        final fn = s['function'] as Map<String, Object?>;
        expect(fn['name'], isA<String>());
        expect((fn['description'] as String).length, greaterThan(30));
        final params = fn['parameters'] as Map<String, Object?>;
        expect(params['type'], 'object');
        // Every required key must actually be declared.
        final properties = params['properties'] as Map;
        for (final key in params['required'] as List) {
          expect(
            properties.containsKey(key),
            isTrue,
            reason: '$key in ${fn['name']}',
          );
        }
      }
    });
  });
}
