import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/day.dart';
import 'package:spend/core/money.dart';
import 'package:spend/data/csv/csv_service.dart';

const csv = CsvService();

void main() {
  group('date formats', () {
    test('handles the bare YYYYMMDD that Dutch banks emit', () {
      expect(CsvDateFormat.compact.parse('20260725'), Day(2026, 7, 25));
      expect(CsvDateFormat.compact.parse('2026072'), isNull);
      expect(CsvDateFormat.compact.parse('abcdefgh'), isNull);
    });

    test('handles day-first and month-first separators', () {
      expect(CsvDateFormat.dayFirstDash.parse('25-07-2026'), Day(2026, 7, 25));
      expect(CsvDateFormat.dayFirstSlash.parse('25/07/2026'), Day(2026, 7, 25));
      expect(
        CsvDateFormat.monthFirstSlash.parse('07/25/2026'),
        Day(2026, 7, 25),
      );
    });

    test('rejects impossible dates rather than rolling them over', () {
      expect(CsvDateFormat.dayFirstDash.parse('30-02-2026'), isNull);
      expect(CsvDateFormat.dayFirstDash.parse('32-01-2026'), isNull);
      expect(CsvDateFormat.dayFirstDash.parse('01-13-2026'), isNull);
      // But a real leap day is fine.
      expect(CsvDateFormat.dayFirstDash.parse('29-02-2024'), Day(2024, 2, 29));
    });

    test('expands two-digit years', () {
      expect(CsvDateFormat.dayFirstSlash.parse('25/07/26'), Day(2026, 7, 25));
    });
  });

  group('delimiter detection', () {
    test('reads semicolon-delimited exports', () {
      // Semicolons are standard where the comma is the decimal separator.
      final table = csv.parseTable(
        'Datum;Bedrag;Omschrijving\n'
        '2026-07-25;-12,40;Albert Heijn\n',
      );
      expect(table.headers, ['Datum', 'Bedrag', 'Omschrijving']);
      expect(table.rows, hasLength(1));
      expect(table.rows.first[1], '-12,40');
    });

    test('reads comma-delimited exports', () {
      final table = csv.parseTable(
        'Date,Amount,Description\n2026-07-25,-12.40,Tesco\n',
      );
      expect(table.headers, ['Date', 'Amount', 'Description']);
      expect(table.rows.first[2], 'Tesco');
    });

    test('skips blank lines and tolerates CRLF', () {
      final table = csv.parseTable(
        'Date,Amount\r\n2026-07-25,-5.00\r\n\r\n2026-07-26,-6.00\r\n',
      );
      expect(table.rows, hasLength(2));
    });

    test('empty input yields an empty table rather than throwing', () {
      expect(csv.parseTable('').isEmpty, isTrue);
      expect(csv.parseTable('   ').isEmpty, isTrue);
    });
  });

  group('column detection', () {
    test(
      'finds date, amount and description regardless of header language',
      () {
        final table = csv.parseTable(
          'Transactiedatum;Naam;Bedrag (EUR);Rekening\n'
          '20260701;Albert Heijn Amsterdam;-12,40;NL01INGB0001\n'
          '20260702;Jumbo Utrecht;-31,15;NL01INGB0001\n'
          '20260703;Salaris werkgever;3200,00;NL01INGB0001\n'
          '20260704;NS Reizigers;-4,20;NL01INGB0001\n',
        );
        final mapping = csv.detectMapping(table)!;

        expect(mapping.dateColumn, 0);
        expect(mapping.dateFormat, CsvDateFormat.compact);
        expect(mapping.amountColumn, 2);
        expect(mapping.descriptionColumn, 1);
        // Mostly negative amounts means the bank's sign convention.
        expect(mapping.flipSigns, isTrue);
      },
    );

    test('does not mistake an account number column for amounts', () {
      final table = csv.parseTable(
        'Date,Account,Amount\n'
        '2026-07-01,1234567890,-12.40\n'
        '2026-07-02,1234567890,-31.15\n'
        '2026-07-03,1234567890,-4.20\n',
      );
      final mapping = csv.detectMapping(table)!;
      expect(mapping.amountColumn, 2);
    });

    test('detects our own export, where amounts are already positive', () {
      final table = csv.parseTable(
        'Date,Amount,Category,Merchant,Note\n'
        '2026-07-01,12.40,Groceries,Albert Heijn,\n'
        '2026-07-02,31.15,Groceries,Jumbo,\n'
        '2026-07-03,4.20,Transport,NS,\n',
      );
      final mapping = csv.detectMapping(table)!;
      expect(mapping.dateColumn, 0);
      expect(mapping.amountColumn, 1);
      expect(
        mapping.flipSigns,
        isFalse,
        reason: 'positive amounts mean no flip needed',
      );
    });

    test('gives up rather than guessing on a file with no dates', () {
      final table = csv.parseTable('Name,Value\nfoo,1\nbar,2\n');
      expect(csv.detectMapping(table), isNull);
    });
  });

  group('interpretation', () {
    CsvParseResult run(String text) {
      final table = csv.parseTable(text);
      return csv.interpret(table, csv.detectMapping(table)!);
    }

    test('flips bank signs so expenses become positive magnitudes', () {
      final result = run(
        'Datum;Naam;Bedrag\n'
        '20260701;Albert Heijn;-12,40\n'
        '20260702;Jumbo;-31,15\n'
        '20260725;Salaris;3200,00\n',
      );
      expect(result.rejected, isEmpty);
      expect(result.rows, hasLength(3));

      final ah = result.rows.first;
      expect(ah.date, Day(2026, 7, 1));
      expect(ah.amount, Money(1240), reason: 'expense becomes positive');
      expect(ah.description, 'Albert Heijn');
      expect(ah.isIncome, isFalse);

      // Income keeps the opposite sign, which is how the app distinguishes it.
      final salary = result.rows.last;
      expect(salary.amount, Money(-320000));
      expect(salary.isIncome, isTrue);
    });

    test('reports unreadable rows instead of dropping them silently', () {
      final table = csv.parseTable(
        'Date,Amount,Note\n'
        '2026-07-01,-12.40,ok\n'
        'not-a-date,-5.00,bad date\n'
        '2026-07-03,,missing amount\n'
        '2026-07-04,0.00,zero\n'
        '2026-07-05,-7.50,ok\n',
      );
      final result = csv.interpret(table, csv.detectMapping(table)!);

      expect(result.rows, hasLength(2));
      expect(result.rejected, hasLength(3));
      expect(result.rejected.map((r) => r.sourceLine), [3, 4, 5]);
      expect(result.rejected.first.reason, contains('date'));
      expect(result.rejected[1].reason, contains('amount'));
      expect(result.rejected[2].reason, contains('zero'));
    });

    test('summarises the range and total for a confirmation step', () {
      final result = run(
        'Date,Amount,Note\n'
        '2026-07-10,-10.00,a\n'
        '2026-07-01,-20.00,b\n'
        '2026-07-31,-30.00,c\n',
      );
      expect(result.earliest, Day(2026, 7, 1));
      expect(result.latest, Day(2026, 7, 31));
      expect(result.total, Money(6000));
    });

    test('an amount with grouped thousands survives', () {
      final result = run(
        'Datum;Naam;Bedrag\n'
        '20260701;Huur;-1.200,00\n'
        '20260702;Boodschappen;-12,40\n'
        '20260703;Vervoer;-4,20\n',
      );
      expect(result.rows.first.amount, Money(120000));
    });
  });

  group('export', () {
    test('round-trips through our own importer', () {
      final text = csv.export([
        (
          date: Day(2026, 7, 25),
          amount: Money(1240),
          category: 'Groceries',
          merchant: 'Albert Heijn',
          note: 'weekly',
        ),
        (
          date: Day(2026, 7, 26),
          amount: Money(-320000),
          category: 'Income',
          merchant: 'Salary',
          note: '',
        ),
      ]);

      expect(text, contains('Date,Amount,Category,Merchant,Note'));
      expect(text, contains('2026-07-25'));

      // Re-importing what we exported must give back the same figures.
      final table = csv.parseTable(text);
      final mapping = csv.detectMapping(table)!;
      final result = csv.interpret(table, mapping);
      expect(result.rejected, isEmpty);
      expect(result.rows.map((r) => r.amount.minor), [1240, -320000]);
      expect(result.rows.first.date, Day(2026, 7, 25));
    });

    test('quotes fields containing the delimiter', () {
      final text = csv.export([
        (
          date: Day(2026, 7, 25),
          amount: Money(500),
          category: 'Other',
          merchant: 'Smith, Jones & Co',
          note: 'line one',
        ),
      ]);
      final table = csv.parseTable(text);
      expect(table.rows.first[3], 'Smith, Jones & Co');
    });
  });
}
