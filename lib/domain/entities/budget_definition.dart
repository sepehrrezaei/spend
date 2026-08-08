/// A spending limit, independent of storage.
library;

import 'package:meta/meta.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import 'enums.dart';

@immutable
class BudgetDefinition {
  final int id;

  /// Null means this limit applies to total spending rather than one category.
  final int? categoryId;

  final BudgetPeriod period;
  final Money limit;

  /// When this limit took effect.
  final Day startsOn;

  /// Null while this is the limit currently in force.
  ///
  /// Changing a budget closes the old row and opens a new one rather than
  /// overwriting, so a past month is still judged against the limit that
  /// actually applied at the time instead of being retroactively rewritten.
  final Day? endsOn;

  const BudgetDefinition({
    required this.id,
    required this.categoryId,
    required this.period,
    required this.limit,
    required this.startsOn,
    this.endsOn,
  });

  bool get isOverall => categoryId == null;

  bool appliesOn(Day day) =>
      day >= startsOn && (endsOn == null || day <= endsOn!);
}
