/// The storage schema.
///
/// Two conventions run through every table:
///
///  * Amounts are `INTEGER` minor units mapped to [Money], never `REAL`.
///  * Dates are `TEXT` in `YYYY-MM-DD` mapped to [Day], never `DATETIME`.
///    ISO text sorts chronologically under plain lexical comparison, groups by
///    month with `substr(occurred_on, 1, 7)`, and carries no timezone that
///    could shift a purchase into an adjacent reporting period.
library;

import 'package:drift/drift.dart';

import '../../core/day.dart';
import '../../core/money.dart';
import '../../domain/entities/enums.dart';

/// Maps the [Money] value type onto an integer column of minor units.
class MoneyConverter extends TypeConverter<Money, int> {
  const MoneyConverter();

  @override
  Money fromSql(int fromDb) => Money(fromDb);

  @override
  int toSql(Money value) => value.minor;
}

/// Maps the [Day] value type onto an ISO `YYYY-MM-DD` text column.
class DayConverter extends TypeConverter<Day, String> {
  const DayConverter();

  @override
  Day fromSql(String fromDb) => Day.parse(fromDb);

  @override
  String toSql(Day value) => value.iso;
}

/// Spending categories, optionally nested one level for subcategories.
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get name => text().withLength(min: 1, max: 60)();

  /// A stable key into the app's icon table rather than a raw code point.
  ///
  /// Flutter's release builds tree-shake icon fonts, which silently blanks
  /// any `IconData` built from a runtime integer. A name also survives a
  /// backup taken on one app version and restored on another.
  TextColumn get iconName => text().withDefault(const Constant('tag'))();

  /// Packed ARGB.
  IntColumn get colorValue => integer()();

  IntColumn get parentId => integer().nullable().references(
    Categories,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get kind => textEnum<CategoryKind>()();

  /// Archived categories keep their history but stop appearing in pickers,
  /// so retiring a category never orphans or rewrites past transactions.
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Recurring charges: rent, subscriptions, gym.
///
/// Declared before [Transactions] because that table references it.
class RecurringRules extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get label => text().withLength(min: 1, max: 80)();

  IntColumn get amountMinor => integer().map(const MoneyConverter())();

  IntColumn get categoryId =>
      integer().references(Categories, #id, onDelete: KeyAction.restrict)();

  TextColumn get cadence => textEnum<Cadence>()();

  /// The next date this rule is expected to produce a transaction.
  TextColumn get nextDueOn => text().map(const DayConverter())();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

/// A single spend (or, with a negative amount, income).
@TableIndex(name: 'idx_txn_occurred_on', columns: {#occurredOn})
@TableIndex(name: 'idx_txn_category', columns: {#categoryId})
@TableIndex(
  name: 'idx_txn_category_occurred',
  columns: {#categoryId, #occurredOn},
)
class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get amountMinor => integer().map(const MoneyConverter())();

  /// Restricted rather than cascading: deleting a category must not silently
  /// delete the spending history recorded against it. The UI archives
  /// instead, or reassigns first.
  IntColumn get categoryId =>
      integer().references(Categories, #id, onDelete: KeyAction.restrict)();

  TextColumn get occurredOn => text().map(const DayConverter())();

  TextColumn get note => text().withDefault(const Constant(''))();

  TextColumn get merchant => text().withDefault(const Constant(''))();

  TextColumn get paymentMethod => text().nullable()();

  /// Set when this transaction came from a [RecurringRules] entry, which is
  /// what lets analytics separate fixed costs from discretionary spending.
  IntColumn get recurringRuleId => integer().nullable().references(
    RecurringRules,
    #id,
    onDelete: KeyAction.setNull,
  )();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// A spending cap for a category, or for everything when [categoryId] is null.
class Budgets extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Null means this is the overall budget across all categories.
  IntColumn get categoryId => integer().nullable().references(
    Categories,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get period => textEnum<BudgetPeriod>()();

  IntColumn get amountMinor => integer().map(const MoneyConverter())();

  /// When this budget took effect. Editing a budget inserts a new row rather
  /// than mutating the old one, so historical periods keep being judged
  /// against the limit that actually applied at the time.
  TextColumn get startsOn => text().map(const DayConverter())();

  /// Null while this is the budget currently in force.
  TextColumn get endsOn => text().map(const DayConverter()).nullable()();
}

/// Key/value application settings: currency, theme, AI configuration.
class AppSettings extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
