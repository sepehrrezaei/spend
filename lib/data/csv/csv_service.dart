/// CSV import and export.
///
/// Separate from backup on purpose. A backup is this app's own complete state,
/// checksummed and restorable. A CSV is an interchange format for getting
/// history *in* from a bank and figures *out* to a spreadsheet — lossy in both
/// directions, and never something to rely on for safety.
library;

// Only the codec. The package also exports a top-level `csv` instance, which
// would read confusingly next to this file's own CsvService.
import 'package:csv/csv.dart' show Csv;
import 'package:meta/meta.dart';

import '../../core/day.dart';
import '../../core/money.dart';

/// Date layouts seen in real bank exports.
///
/// Dutch banks are the priority here: ING and ABN AMRO both emit bare
/// `YYYYMMDD`, which no general-purpose date parser handles.
enum CsvDateFormat {
  iso('YYYY-MM-DD'),
  compact('YYYYMMDD'),
  dayFirstDash('DD-MM-YYYY'),
  dayFirstSlash('DD/MM/YYYY'),
  monthFirstSlash('MM/DD/YYYY');

  const CsvDateFormat(this.label);
  final String label;

  Day? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    try {
      return switch (this) {
        CsvDateFormat.iso => Day.tryParse(s),
        CsvDateFormat.compact =>
          s.length == 8 && int.tryParse(s) != null
              ? Day(
                  int.parse(s.substring(0, 4)),
                  int.parse(s.substring(4, 6)),
                  int.parse(s.substring(6, 8)),
                )
              : null,
        CsvDateFormat.dayFirstDash => _split(s, '-', dayFirst: true),
        CsvDateFormat.dayFirstSlash => _split(s, '/', dayFirst: true),
        CsvDateFormat.monthFirstSlash => _split(s, '/', dayFirst: false),
      };
    } catch (_) {
      // A single unparseable cell must not abort the whole import.
      return null;
    }
  }

  static Day? _split(String s, String sep, {required bool dayFirst}) {
    final parts = s.split(sep);
    if (parts.length != 3) return null;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    var y = int.tryParse(parts[2]);
    if (a == null || b == null || y == null) return null;
    if (y < 100) y += 2000; // two-digit years
    final day = dayFirst ? a : b;
    final month = dayFirst ? b : a;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > Day.daysInMonth(y, month)) return null;
    return Day(y, month, day);
  }
}

/// A parsed CSV before any interpretation.
@immutable
class CsvTable {
  final List<String> headers;
  final List<List<String>> rows;

  const CsvTable({required this.headers, required this.rows});

  bool get isEmpty => rows.isEmpty;
  int get columnCount => headers.length;
}

/// Which column means what.
@immutable
class CsvMapping {
  final int dateColumn;
  final int amountColumn;
  final int? descriptionColumn;
  final int? categoryColumn;
  final CsvDateFormat dateFormat;

  /// Bank exports usually record spending as negative and income as positive,
  /// the opposite of this app's convention where an expense amount is a
  /// positive magnitude. When set, signs are flipped on the way in.
  final bool flipSigns;

  const CsvMapping({
    required this.dateColumn,
    required this.amountColumn,
    required this.dateFormat,
    this.descriptionColumn,
    this.categoryColumn,
    this.flipSigns = true,
  });

  CsvMapping copyWith({
    int? dateColumn,
    int? amountColumn,
    int? descriptionColumn,
    int? categoryColumn,
    CsvDateFormat? dateFormat,
    bool? flipSigns,
    bool clearDescription = false,
    bool clearCategory = false,
  }) => CsvMapping(
    dateColumn: dateColumn ?? this.dateColumn,
    amountColumn: amountColumn ?? this.amountColumn,
    dateFormat: dateFormat ?? this.dateFormat,
    descriptionColumn: clearDescription
        ? null
        : descriptionColumn ?? this.descriptionColumn,
    categoryColumn: clearCategory
        ? null
        : categoryColumn ?? this.categoryColumn,
    flipSigns: flipSigns ?? this.flipSigns,
  );
}

/// One row, interpreted.
@immutable
class CsvRow {
  final Day date;
  final Money amount;
  final String description;
  final String? categoryName;
  final int sourceLine;

  const CsvRow({
    required this.date,
    required this.amount,
    required this.description,
    required this.sourceLine,
    this.categoryName,
  });

  bool get isIncome => amount.isNegative;
}

/// Rows that could not be interpreted, kept so the user sees what was dropped
/// instead of silently importing 400 of 500 rows.
@immutable
class CsvRejection {
  final int sourceLine;
  final String reason;
  final List<String> raw;

  const CsvRejection({
    required this.sourceLine,
    required this.reason,
    required this.raw,
  });
}

@immutable
class CsvParseResult {
  final List<CsvRow> rows;
  final List<CsvRejection> rejected;

  const CsvParseResult({required this.rows, required this.rejected});

  Money get total => rows.map((r) => r.amount).sum();
  Day? get earliest => rows.isEmpty
      ? null
      : rows.map((r) => r.date).reduce((a, b) => a < b ? a : b);
  Day? get latest => rows.isEmpty
      ? null
      : rows.map((r) => r.date).reduce((a, b) => a > b ? a : b);
}

class CsvService {
  const CsvService();

  /// Parses raw text into a table, coping with either delimiter.
  ///
  /// Delimiter detection is delegated to the codec. It matters because Dutch
  /// and German exports are usually semicolon-delimited — the comma is already
  /// the decimal separator there.
  ///
  /// Number parsing stays off deliberately: every cell is kept as text so that
  /// [Money.tryParse] and [CsvDateFormat] decide how to read it. Letting the
  /// CSV layer coerce "12,40" to a double would reintroduce exactly the
  /// floating-point rounding this app avoids everywhere else.
  CsvTable parseTable(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const CsvTable(headers: [], rows: []);

    final raw = Csv(
      autoDetect: true,
      skipEmptyLines: true,
      dynamicTyping: false,
    ).decode(trimmed);

    if (raw.isEmpty) return const CsvTable(headers: [], rows: []);

    final headers = [for (final h in raw.first) h.toString().trim()];
    final rows = [
      for (final r in raw.skip(1))
        if (r.any((c) => c.toString().trim().isNotEmpty))
          [for (final c in r) c.toString()],
    ];
    return CsvTable(headers: headers, rows: rows);
  }

  /// Guesses which column is which.
  ///
  /// Scores columns by how many of their values actually parse, rather than by
  /// matching header names — header text varies by bank and language ("Datum",
  /// "Date", "Transactiedatum") but a column of dates is recognisable whatever
  /// it is called.
  CsvMapping? detectMapping(CsvTable table) {
    if (table.isEmpty || table.columnCount < 2) return null;
    final sample = table.rows.take(40).toList();

    var bestDateColumn = -1;
    var bestDateFormat = CsvDateFormat.iso;
    var bestDateScore = 0;
    for (var c = 0; c < table.columnCount; c++) {
      for (final format in CsvDateFormat.values) {
        var score = 0;
        for (final row in sample) {
          if (c >= row.length) continue;
          if (format.parse(row[c]) != null) score++;
        }
        if (score > bestDateScore) {
          bestDateScore = score;
          bestDateColumn = c;
          bestDateFormat = format;
        }
      }
    }

    var bestAmountColumn = -1;
    var bestAmountScore = 0;
    for (var c = 0; c < table.columnCount; c++) {
      if (c == bestDateColumn) continue;
      var score = 0;
      for (final row in sample) {
        if (c >= row.length) continue;
        final v = row[c].trim();
        if (v.isEmpty) continue;
        // Require a separator or a sign: a column of plain integers is more
        // likely an account or sequence number than an amount.
        if (Money.tryParse(v) != null &&
            (v.contains(',') || v.contains('.') || v.startsWith('-'))) {
          score++;
        }
      }
      if (score > bestAmountScore) {
        bestAmountScore = score;
        bestAmountColumn = c;
      }
    }

    if (bestDateColumn < 0 || bestAmountColumn < 0) return null;
    if (bestDateScore < sample.length * 0.6) return null;

    // Description: the widest remaining text column.
    var descriptionColumn = -1;
    var bestLength = 0.0;
    for (var c = 0; c < table.columnCount; c++) {
      if (c == bestDateColumn || c == bestAmountColumn) continue;
      var total = 0;
      var count = 0;
      for (final row in sample) {
        if (c >= row.length) continue;
        total += row[c].trim().length;
        count++;
      }
      final avg = count == 0 ? 0.0 : total / count;
      if (avg > bestLength && avg >= 3) {
        bestLength = avg;
        descriptionColumn = c;
      }
    }

    // If most amounts are negative, this is a bank export using the opposite
    // sign convention to ours.
    var negatives = 0;
    var amounts = 0;
    for (final row in sample) {
      if (bestAmountColumn >= row.length) continue;
      final m = Money.tryParse(row[bestAmountColumn]);
      if (m == null || m.isZero) continue;
      amounts++;
      if (m.isNegative) negatives++;
    }

    return CsvMapping(
      dateColumn: bestDateColumn,
      amountColumn: bestAmountColumn,
      descriptionColumn: descriptionColumn < 0 ? null : descriptionColumn,
      dateFormat: bestDateFormat,
      flipSigns: amounts > 0 && negatives > amounts * 0.5,
    );
  }

  /// Interprets every row under [mapping].
  CsvParseResult interpret(CsvTable table, CsvMapping mapping) {
    final rows = <CsvRow>[];
    final rejected = <CsvRejection>[];

    for (final (index, raw) in table.rows.indexed) {
      final line = index + 2; // +1 for the header, +1 for 1-based counting

      String cell(int? c) => c == null || c >= raw.length ? '' : raw[c].trim();

      final date = mapping.dateFormat.parse(cell(mapping.dateColumn));
      if (date == null) {
        rejected.add(
          CsvRejection(
            sourceLine: line,
            reason: 'Could not read the date',
            raw: raw,
          ),
        );
        continue;
      }

      final parsed = Money.tryParse(cell(mapping.amountColumn));
      if (parsed == null) {
        rejected.add(
          CsvRejection(
            sourceLine: line,
            reason: 'Could not read the amount',
            raw: raw,
          ),
        );
        continue;
      }
      if (parsed.isZero) {
        rejected.add(
          CsvRejection(sourceLine: line, reason: 'Amount is zero', raw: raw),
        );
        continue;
      }

      final amount = mapping.flipSigns ? -parsed : parsed;
      final category = cell(mapping.categoryColumn);

      rows.add(
        CsvRow(
          date: date,
          amount: amount,
          description: cell(mapping.descriptionColumn),
          categoryName: category.isEmpty ? null : category,
          sourceLine: line,
        ),
      );
    }

    return CsvParseResult(rows: rows, rejected: rejected);
  }

  /// Renders transactions as CSV for a spreadsheet.
  ///
  /// Amounts are written with a dot decimal separator and unquoted, because
  /// that is what every spreadsheet reads without a locale prompt.
  String export(
    List<
      ({Day date, Money amount, String category, String merchant, String note})
    >
    entries,
  ) {
    final rows = <List<String>>[
      ['Date', 'Amount', 'Category', 'Merchant', 'Note'],
      for (final e in entries)
        [e.date.iso, e.amount.toString(), e.category, e.merchant, e.note],
    ];
    return Csv(lineDelimiter: '\n').encode(rows);
  }
}
