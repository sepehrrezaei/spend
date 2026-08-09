/// Enumerations shared by the storage schema and the analytics engine.
///
/// These live in `domain/` rather than alongside the Drift tables so the
/// analytics code can reason about them without depending on the database.
library;

/// Whether a category records money going out or coming in.
///
/// Amounts are always stored as the magnitude the user typed; direction lives
/// here, on the category, not in the sign of the amount. That keeps stored
/// data matching what was entered, and leaves negative amounts free to mean
/// what they naturally should — a refund against an expense category.
enum CategoryKind {
  expense,
  income;

  String get label => switch (this) {
    CategoryKind.expense => 'Expense',
    CategoryKind.income => 'Income',
  };
}

/// How often a budget resets.
enum BudgetPeriod {
  weekly,
  monthly,
  yearly;

  String get label => switch (this) {
    BudgetPeriod.weekly => 'Weekly',
    BudgetPeriod.monthly => 'Monthly',
    BudgetPeriod.yearly => 'Yearly',
  };
}

/// How often a recurring charge repeats.
enum Cadence {
  weekly,
  fortnightly,
  monthly,
  quarterly,
  yearly;

  String get label => switch (this) {
    Cadence.weekly => 'Weekly',
    Cadence.fortnightly => 'Every 2 weeks',
    Cadence.monthly => 'Monthly',
    Cadence.quarterly => 'Quarterly',
    Cadence.yearly => 'Yearly',
  };

  /// Roughly how many times this repeats in a year. Used to normalise
  /// differently-paced subscriptions onto a comparable monthly figure.
  double get occurrencesPerYear => switch (this) {
    Cadence.weekly => 52,
    Cadence.fortnightly => 26,
    Cadence.monthly => 12,
    Cadence.quarterly => 4,
    Cadence.yearly => 1,
  };
}
