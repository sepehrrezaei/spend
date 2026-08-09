/// The queries a chat model is allowed to run against your transactions.
///
/// This is the whole safety mechanism for the chat tab. The model never sees
/// raw transactions and is never asked to add anything up; it chooses one of
/// these tools, Dart executes the real query, and the exact figures come back
/// for it to phrase. Anything it says that is not in a tool result is a
/// fabrication, and the UI shows the raw results alongside the answer so that
/// is checkable rather than assumed.
///
/// The tool surface is deliberately small. A 3B model picks the right function
/// from five clearly distinct options far more reliably than from fifteen
/// overlapping ones.
library;

import '../core/date_range.dart';
import '../core/day.dart';
import '../core/money.dart';
import '../data/db/database.dart';
import '../data/repositories/transaction_repository.dart';
import '../domain/analytics/analytics_engine.dart';
import '../domain/entities/spend_record.dart';

/// The outcome of one tool call.
class ToolResult {
  final String tool;
  final Map<String, Object?> arguments;

  /// Exact figures, in major units, for the model to quote.
  final Map<String, Object?> data;

  /// A one-line human summary shown in the transcript as evidence.
  final String evidence;

  final String? error;

  const ToolResult({
    required this.tool,
    required this.arguments,
    this.data = const {},
    this.evidence = '',
    this.error,
  });

  bool get failed => error != null;
}

class ChatTools {
  final TransactionRepository _repo;
  final List<Category> _categories;

  /// Formats an amount for the evidence line shown in the transcript.
  final String Function(Money) money;

  /// The currency every figure is in, e.g. "EUR".
  ///
  /// Included in every result. Without it the model sees a bare 525.84 and
  /// writes "$525.84" — a plausible default that is simply wrong.
  final String currency;

  ChatTools({
    required TransactionRepository repository,
    required List<Category> categories,
    required this.money,
    required this.currency,
  }) : _repo = repository,
       _categories = List.unmodifiable(categories);

  /// Never return more than this to the model. A long list wastes context and
  /// invites it to start summing rows itself.
  static const _maxRows = 15;

  /// Tool definitions in the schema Ollama expects.
  ///
  /// Descriptions are written for the model, not for a developer: they say
  /// when to use the tool, because that is what it gets wrong.
  static List<Map<String, Object?>> get schemas => [
    _fn(
      'list_categories',
      'List the spending categories that exist. Use this first if the question '
          'mentions a category and you are not sure of its exact name.',
      const {},
      const [],
    ),
    _fn(
      'total_spent',
      'Total amount spent between two dates. Use for "how much did I spend on '
          'X", "what did I spend in June", and any question needing one number. '
          'Call it twice with different dates to compare two periods.',
      {
        'from': _dateArg('First day to include, YYYY-MM-DD.'),
        'to': _dateArg('Last day to include, YYYY-MM-DD.'),
        'category': {
          'type': 'string',
          'description': 'Optional exact category name. Omit for all spending.',
        },
      },
      const ['from', 'to'],
    ),
    _fn(
      'spend_by_category',
      'Break spending down by category between two dates. Use for "what did I '
          'spend most on", "where did my money go".',
      {
        'from': _dateArg('First day to include, YYYY-MM-DD.'),
        'to': _dateArg('Last day to include, YYYY-MM-DD.'),
      },
      const ['from', 'to'],
    ),
    _fn(
      'top_merchants',
      'The places you spent the most, between two dates. Use for questions '
          'about shops, restaurants or specific businesses.',
      {
        'from': _dateArg('First day to include, YYYY-MM-DD.'),
        'to': _dateArg('Last day to include, YYYY-MM-DD.'),
        'limit': {
          'type': 'integer',
          'description': 'How many to return. Defaults to 5.',
        },
      },
      const ['from', 'to'],
    ),
    _fn(
      'find_transactions',
      'List individual transactions matching filters. Use only when the '
          'question asks about specific purchases, not for totals.',
      {
        'from': _dateArg('First day to include, YYYY-MM-DD.'),
        'to': _dateArg('Last day to include, YYYY-MM-DD.'),
        'category': {
          'type': 'string',
          'description': 'Optional exact category name.',
        },
        'merchant': {
          'type': 'string',
          'description': 'Optional merchant name, matched loosely.',
        },
        'min_amount': {
          'type': 'number',
          'description': 'Optional minimum amount in major units, e.g. 50.',
        },
      },
      const ['from', 'to'],
    ),
  ];

  static Map<String, Object?> _fn(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
      },
    },
  };

  static Map<String, Object?> _dateArg(String description) => {
    'type': 'string',
    'description': description,
  };

  // --------------------------------------------------------------- execution

  /// Runs a tool the model asked for.
  ///
  /// Arguments are repaired where possible rather than rejected — a small
  /// model will produce "2026-7-1" or swap `from` and `to`, and failing the
  /// whole answer over that is worse than quietly fixing it.
  Future<ToolResult> call(String name, Map<String, Object?> args) async {
    try {
      return switch (name) {
        'list_categories' => _listCategories(args),
        'total_spent' => await _totalSpent(args),
        'spend_by_category' => await _spendByCategory(args),
        'top_merchants' => await _topMerchants(args),
        'find_transactions' => await _findTransactions(args),
        _ => ToolResult(
          tool: name,
          arguments: args,
          error: 'There is no tool called "$name".',
        ),
      };
    } on Object catch (e) {
      return ToolResult(tool: name, arguments: args, error: e.toString());
    }
  }

  ToolResult _listCategories(Map<String, Object?> args) {
    final names = _categories
        .where((c) => !c.isArchived)
        .map((c) => c.name)
        .toList();
    return ToolResult(
      tool: 'list_categories',
      arguments: args,
      data: {'categories': names},
      evidence: '${names.length} categories',
    );
  }

  Future<ToolResult> _totalSpent(Map<String, Object?> args) async {
    final range = _range(args);
    if (range == null) return _badDates('total_spent', args);

    final categoryName = _string(args['category']);
    final category = _resolveCategory(categoryName);
    if (categoryName != null && category == null) {
      return ToolResult(
        tool: 'total_spent',
        arguments: args,
        error:
            'There is no category called "$categoryName". Call list_categories '
            'to see the real names.',
      );
    }

    final records = await _expenses(range, categoryId: category?.id);
    final total = records.map((r) => r.amount).sum();

    return ToolResult(
      tool: 'total_spent',
      arguments: args,
      data: {
        'currency': currency,
        'from': range.start.iso,
        'to': range.end.iso,
        if (category != null) 'category': category.name,
        'total': total.major,
        'transaction_count': records.length,
        'days': range.dayCount,
      },
      evidence:
          '${money(total)}${category == null ? "" : " on ${category.name}"} '
          '· ${range.start.iso} to ${range.end.iso} · ${records.length} entries',
    );
  }

  Future<ToolResult> _spendByCategory(Map<String, Object?> args) async {
    final range = _range(args);
    if (range == null) return _badDates('spend_by_category', args);

    final records = await _expenses(range);
    final summary = const AnalyticsEngine().summarise(
      records: records,
      range: range,
      today: range.end,
    );

    return ToolResult(
      tool: 'spend_by_category',
      arguments: args,
      data: {
        'currency': currency,
        'from': range.start.iso,
        'to': range.end.iso,
        'total': summary.expenseTotal.major,
        'categories': [
          for (final c in summary.categories.take(_maxRows))
            {
              'name': c.name,
              'amount': c.total.major,
              'share_percent': (c.share * 100).round(),
            },
        ],
      },
      evidence:
          '${summary.categories.length} categories, '
          '${money(summary.expenseTotal)} total',
    );
  }

  Future<ToolResult> _topMerchants(Map<String, Object?> args) async {
    final range = _range(args);
    if (range == null) return _badDates('top_merchants', args);

    final limit = (_int(args['limit']) ?? 5).clamp(1, _maxRows);
    final records = await _expenses(range);
    final summary = const AnalyticsEngine().summarise(
      records: records,
      range: range,
      today: range.end,
    );

    return ToolResult(
      tool: 'top_merchants',
      arguments: args,
      data: {
        'currency': currency,
        'from': range.start.iso,
        'to': range.end.iso,
        'merchants': [
          for (final m in summary.topMerchants.take(limit))
            {'name': m.merchant, 'amount': m.total.major, 'visits': m.count},
        ],
      },
      evidence: summary.topMerchants.isEmpty
          ? 'no named merchants in range'
          : 'top: ${summary.topMerchants.first.merchant} '
                '(${money(summary.topMerchants.first.total)})',
    );
  }

  Future<ToolResult> _findTransactions(Map<String, Object?> args) async {
    final range = _range(args);
    if (range == null) return _badDates('find_transactions', args);

    final category = _resolveCategory(_string(args['category']));
    final merchant = _string(args['merchant'])?.toLowerCase();
    final minMajor = _double(args['min_amount']);
    final minimum = minMajor == null ? null : Money.fromMajor(minMajor);

    var records = await _expenses(range, categoryId: category?.id);
    if (merchant != null && merchant.isNotEmpty) {
      records = records
          .where((r) => r.merchant.toLowerCase().contains(merchant))
          .toList();
    }
    if (minimum != null) {
      records = records.where((r) => r.amount >= minimum).toList();
    }
    records.sort((a, b) => b.amount.compareTo(a.amount));

    final shown = records.take(_maxRows).toList();
    return ToolResult(
      tool: 'find_transactions',
      arguments: args,
      data: {
        'currency': currency,
        'from': range.start.iso,
        'to': range.end.iso,
        'match_count': records.length,
        'showing': shown.length,
        'total_of_all_matches': records.map((r) => r.amount).sum().major,
        'transactions': [
          for (final r in shown)
            {
              'date': r.occurredOn.iso,
              'amount': r.amount.major,
              'category': r.categoryName,
              'description': r.displayLabel,
            },
        ],
      },
      evidence:
          '${records.length} matching '
          '${records.length == 1 ? "transaction" : "transactions"}'
          '${records.length > shown.length ? ", showing ${shown.length}" : ""}',
    );
  }

  // ----------------------------------------------------------------- helpers

  Future<List<SpendRecord>> _expenses(
    DateRange range, {
    int? categoryId,
  }) async {
    final all = await _repo.inRange(range);
    return all
        .where(
          (r) =>
              r.isExpense && (categoryId == null || r.categoryId == categoryId),
        )
        .toList();
  }

  ToolResult _badDates(String tool, Map<String, Object?> args) => ToolResult(
    tool: tool,
    arguments: args,
    error:
        'The dates were not usable. Give "from" and "to" as YYYY-MM-DD, for '
        'example 2026-07-01.',
  );

  /// Parses a date range from model-supplied arguments, repairing the usual
  /// mistakes: unpadded months, a swapped pair, and a missing end date.
  DateRange? _range(Map<String, Object?> args) {
    final from = _day(args['from']);
    final to = _day(args['to']);
    if (from == null && to == null) return null;
    if (from == null) return DateRange(to!, to);
    if (to == null) return DateRange(from, from);
    return to < from ? DateRange(to, from) : DateRange(from, to);
  }

  static Day? _day(Object? raw) {
    final text = _string(raw);
    if (text == null) return null;
    final direct = Day.tryParse(text);
    if (direct != null) return direct;

    // Repair "2026-7-1" and "2026/07/01", which small models emit routinely.
    final m = RegExp(
      r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$',
    ).firstMatch(text.trim());
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > Day.daysInMonth(year, month)) return null;
    return Day(year, month, day);
  }

  /// Resolves a category name the model supplied.
  ///
  /// Fuzzy, because a model writes "grocery" for "Groceries" — but only when
  /// exactly one category is close. Returning the wrong category would produce
  /// a confidently wrong figure, which is far worse than an error: an error
  /// sends the model to `list_categories` and it recovers, whereas a silent
  /// mismatch is indistinguishable from a correct answer.
  Category? _resolveCategory(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final wanted = name.trim().toLowerCase();

    for (final c in _categories) {
      if (c.name.toLowerCase() == wanted) return c;
    }

    final close = <Category>[];
    for (final c in _categories) {
      final lower = c.name.toLowerCase();
      final shared = _commonPrefix(lower, wanted);
      final shorter = lower.length < wanted.length
          ? lower.length
          : wanted.length;
      // "grocery" and "groceries" share six characters and diverge only at the
      // ending, so a plain startsWith check misses them.
      if (shared >= 4 && shared >= shorter * 0.6) close.add(c);
    }

    return close.length == 1 ? close.first : null;
  }

  static int _commonPrefix(String a, String b) {
    final limit = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static String? _string(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    return text.isEmpty || text.toLowerCase() == 'null' ? null : text;
  }

  static int? _int(Object? raw) =>
      raw is int ? raw : int.tryParse(_string(raw) ?? '');

  static double? _double(Object? raw) =>
      raw is num ? raw.toDouble() : double.tryParse(_string(raw) ?? '');
}
