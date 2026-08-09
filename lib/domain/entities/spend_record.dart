/// The shape the analytics engine works in.
///
/// A denormalised transaction: the row plus the category fields needed to
/// group, colour and label it. Flattening the join here means the engine
/// never touches the database, so it can be exercised in tests from plain
/// literals and reused unchanged on iOS.
library;

import 'package:meta/meta.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import 'enums.dart';

@immutable
class SpendRecord {
  final int id;
  final Money amount;
  final Day occurredOn;

  final int categoryId;
  final String categoryName;
  final String categoryIcon;
  final int categoryColor;
  final CategoryKind categoryKind;

  final String note;
  final String merchant;
  final String? paymentMethod;

  /// Set when this came from a recurring rule. Fixed costs are excluded from
  /// discretionary analysis, which is what makes the variable-spend numbers
  /// meaningful — rent swamps everything otherwise.
  final int? recurringRuleId;

  const SpendRecord({
    required this.id,
    required this.amount,
    required this.occurredOn,
    required this.categoryId,
    required this.categoryName,
    required this.categoryIcon,
    required this.categoryColor,
    required this.categoryKind,
    this.note = '',
    this.merchant = '',
    this.paymentMethod,
    this.recurringRuleId,
  });

  bool get isRecurring => recurringRuleId != null;
  bool get isIncome => categoryKind == CategoryKind.income;
  bool get isExpense => categoryKind == CategoryKind.expense;

  /// What to show as the transaction's title: the merchant if there is one,
  /// otherwise the note, otherwise the category.
  String get displayLabel {
    if (merchant.isNotEmpty) return merchant;
    if (note.isNotEmpty) return note;
    return categoryName;
  }

  @override
  bool operator ==(Object other) => other is SpendRecord && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'SpendRecord(#$id, ${occurredOn.iso}, $amount, $categoryName)';
}
