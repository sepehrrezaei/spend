import 'package:drift/drift.dart';

import '../db/database.dart';
import '../../domain/entities/enums.dart';

/// Reads and writes spending categories.
class CategoryRepository {
  final SpendDatabase _db;

  CategoryRepository(this._db);

  /// Categories available for new entries, in display order.
  Stream<List<Category>> watchActive() =>
      (_db.select(_db.categories)
            ..where((c) => c.isArchived.equals(false))
            ..orderBy([
              (c) => OrderingTerm(expression: c.sortOrder),
              (c) => OrderingTerm(expression: c.name),
            ]))
          .watch();

  /// Every category including archived ones, for the management screen and
  /// for resolving historical transactions whose category has been retired.
  Stream<List<Category>> watchAll() =>
      (_db.select(_db.categories)..orderBy([
            (c) => OrderingTerm(expression: c.isArchived),
            (c) => OrderingTerm(expression: c.sortOrder),
          ]))
          .watch();

  Future<List<Category>> all() => _db.select(_db.categories).get();

  Future<Category?> byId(int id) => (_db.select(
    _db.categories,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<int> add({
    required String name,
    required int colorValue,
    String iconName = 'tag',
    CategoryKind kind = CategoryKind.expense,
    int? parentId,
  }) async {
    final maxOrder = _db.categories.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.categories,
    )..addColumns([maxOrder])).getSingleOrNull();
    return _db
        .into(_db.categories)
        .insert(
          CategoriesCompanion.insert(
            name: name.trim(),
            iconName: Value(iconName),
            colorValue: colorValue,
            kind: kind,
            parentId: Value(parentId),
            sortOrder: Value((row?.read(maxOrder) ?? 0) + 1),
          ),
        );
  }

  Future<void> update({
    required int id,
    String? name,
    int? colorValue,
    String? iconName,
  }) => (_db.update(_db.categories)..where((c) => c.id.equals(id))).write(
    CategoriesCompanion(
      name: name == null ? const Value.absent() : Value(name.trim()),
      colorValue: colorValue == null ? const Value.absent() : Value(colorValue),
      iconName: iconName == null ? const Value.absent() : Value(iconName),
    ),
  );

  /// Hides a category from pickers while leaving its history intact.
  ///
  /// This is the safe counterpart to deletion. The schema deliberately
  /// refuses to delete a category that still has transactions, because doing
  /// so would either destroy spending history or orphan it.
  Future<void> setArchived(int id, {required bool archived}) =>
      (_db.update(_db.categories)..where((c) => c.id.equals(id))).write(
        CategoriesCompanion(isArchived: Value(archived)),
      );

  /// How many transactions reference [id]. Callers use this to decide between
  /// offering deletion and offering archiving.
  Future<int> usageCount(int id) async {
    final count = _db.transactions.id.count();
    final row =
        await (_db.selectOnly(_db.transactions)
              ..addColumns([count])
              ..where(_db.transactions.categoryId.equals(id)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Deletes a category, refusing when it still has history.
  ///
  /// Returns false rather than throwing, so the UI can offer to archive
  /// instead without having to catch a database exception.
  Future<bool> deleteIfUnused(int id) async {
    if (await usageCount(id) > 0) return false;
    await (_db.delete(_db.categories)..where((c) => c.id.equals(id))).go();
    return true;
  }

  /// Moves every transaction from one category to another. Lets a user retire
  /// a category without losing the spending recorded against it.
  Future<void> reassign({required int from, required int to}) =>
      (_db.update(_db.transactions)..where((t) => t.categoryId.equals(from)))
          .write(TransactionsCompanion(categoryId: Value(to)));

  Future<void> reorder(List<int> idsInOrder) => _db.batch((b) {
    for (final (index, id) in idsInOrder.indexed) {
      b.update(
        _db.categories,
        CategoriesCompanion(sortOrder: Value(index)),
        where: (c) => c.id.equals(id),
      );
    }
  });
}
