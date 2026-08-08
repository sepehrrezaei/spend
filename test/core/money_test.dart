import 'package:flutter_test/flutter_test.dart';
import 'package:spend/core/money.dart';

void main() {
  group('exactness', () {
    test('the sum that breaks floating point is exact here', () {
      // 0.1 + 0.2 == 0.30000000000000004 as doubles.
      final sum = Money.fromMajor(0.1) + Money.fromMajor(0.2);
      expect(sum.minor, 30);
      expect(sum, Money.fromMajor(0.3));
    });

    test('repeated addition does not drift', () {
      var total = Money.zero;
      for (var i = 0; i < 1000; i++) {
        total += Money(10); // 10 cents, a thousand times
      }
      expect(total.minor, 10000); // exactly €100.00
    });

    test('a realistic ledger sums exactly', () {
      final ledger = [
        Money.tryParse('12,40')!,
        Money.tryParse('3,99')!,
        Money.tryParse('87,15')!,
        Money.tryParse('0,01')!,
        Money.tryParse('1.234,56')!,
      ];
      expect(ledger.sum().minor, 1240 + 399 + 8715 + 1 + 123456);
    });
  });

  group('parsing', () {
    test('accepts both decimal separator conventions', () {
      expect(Money.tryParse('12.40')!.minor, 1240);
      expect(Money.tryParse('12,40')!.minor, 1240);
    });

    test('rightmost separator wins when both are present', () {
      expect(Money.tryParse('1.234,56')!.minor, 123456); // European
      expect(Money.tryParse('1,234.56')!.minor, 123456); // Anglo
      expect(Money.tryParse('1.234.567,89')!.minor, 123456789);
    });

    test('three trailing digits read as grouping, not decimals', () {
      expect(Money.tryParse('12,345')!.minor, 1234500);
      expect(Money.tryParse('12.345')!.minor, 1234500);
      expect(Money.tryParse('1,005')!.minor, 100500);
      expect(Money.tryParse('1,999')!.minor, 199900);
    });

    test('grouping only applies where a grouped number is plausible', () {
      expect(Money.tryParse('0,005')!.minor, 1); // leading zero
      expect(Money.tryParse(',005')!.minor, 1); // no integer part
      expect(Money.tryParse('1234,567')!.minor, 123457); // head too long
    });

    test('one or two trailing digits read as decimals', () {
      expect(Money.tryParse('12,4')!.minor, 1240);
      expect(Money.tryParse('12,45')!.minor, 1245);
    });

    test('strips currency symbols and pasted whitespace', () {
      expect(Money.tryParse('€12,40')!.minor, 1240);
      expect(Money.tryParse('  12,40 EUR ')!.minor, 1240);
      expect(Money.tryParse(' 12,40')!.minor, 1240); // non-breaking space
      expect(Money.tryParse(' 1.234,56')!.minor, 123456); // narrow nbsp
    });

    test('handles bare integers and leading decimals', () {
      expect(Money.tryParse('12')!.minor, 1200);
      expect(Money.tryParse('0')!.minor, 0);
      expect(Money.tryParse(',50')!.minor, 50);
      expect(Money.tryParse('.5')!.minor, 50);
    });

    test('rounds beyond two decimals half away from zero', () {
      // Four decimals are unambiguous — no grouping convention produces them.
      expect(Money.tryParse('1,9999')!.minor, 200);
      expect(Money.tryParse('1,0049')!.minor, 100);
      expect(Money.tryParse('12,3456')!.minor, 1235);
      // A leading zero rules out grouping, so three decimals stay decimals.
      expect(Money.tryParse('0,005')!.minor, 1);
      expect(Money.tryParse('0,004')!.minor, 0);
    });

    test('handles negatives', () {
      expect(Money.tryParse('-12,40')!.minor, -1240);
      expect(Money.tryParse('-€12,40')!.minor, -1240);
      expect(Money.tryParse('+12,40')!.minor, 1240);
    });

    test('rejects input that is not an amount', () {
      const bad = [
        '', '   ', 'abc', '€', '-', '12-40',
        '1,2,3.4.5', // separators in nonsense positions
        '1,23,456', // groups that are not threes
        '12.34.56', // ditto, with the other separator
        '1.234,567.89', // separator style changes partway through
      ];
      for (final input in bad) {
        expect(Money.tryParse(input), isNull, reason: 'should reject "$input"');
      }
    });
  });

  group('arithmetic', () {
    test('scaling rounds to the nearest cent', () {
      expect((Money(1000) * 0.335).minor, 335);
      expect((Money(101) * 0.5).minor, 51); // 50.5 rounds away from zero
      expect((Money(-101) * 0.5).minor, -51); // and symmetrically for debits
    });

    test('ratioTo returns null rather than infinity on a zero budget', () {
      expect(Money(500).ratioTo(Money.zero), isNull);
      expect(Money(500).ratioTo(Money(1000)), 0.5);
    });

    test('negation and subtraction round-trip', () {
      final a = Money(1234);
      final b = Money(999);
      expect((a - b) + b, a);
      expect(-(-a), a);
      expect(a.abs(), a);
      expect((-a).abs(), a);
    });

    test('comparison operators order correctly', () {
      expect(Money(100) < Money(200), isTrue);
      expect(Money(200) > Money(100), isTrue);
      expect(Money(100) <= Money(100), isTrue);
      expect(Money(100) >= Money(100), isTrue);
      expect(Money(-100) < Money.zero, isTrue);

      final sorted = [Money(300), Money(-100), Money(0), Money(150)]..sort();
      expect(sorted.map((m) => m.minor), [-100, 0, 150, 300]);
    });

    test('value equality, so amounts work as map keys and in sets', () {
      expect(Money(1234), Money(1234));
      expect(Money(1234).hashCode, Money(1234).hashCode);
      expect({Money(100), Money(100)}.length, 1);
    });
  });

  test('round-trips through parse, store and format without loss', () {
    for (final input in ['0,01', '12,40', '999,99', '1.234,56', '-87,05']) {
      final parsed = Money.tryParse(input)!;
      final reparsed = Money.tryParse(parsed.toString())!;
      expect(reparsed.minor, parsed.minor, reason: 'round-trip of "$input"');
    }
  });
}
