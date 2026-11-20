import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'persian_digits.dart';

const timetableDays = [
  'شنبه',
  'یکشنبه',
  'دوشنبه',
  'سه‌شنبه',
  'چهارشنبه',
  'پنجشنبه',
  'جمعه',
];

int? timetableMinute(String value) {
  final parts = asciiDigits(value).trim().split(RegExp(r'[:٫]'));
  if (parts.length != 2 ||
      parts.any((part) => !RegExp(r'^\d{1,2}$').hasMatch(part)))
    return null;
  final hour = int.parse(parts.first), minute = int.parse(parts.last);
  return hour < 24 && minute < 60 ? hour * 60 + minute : null;
}

String timetableTime(int minute) => persianDigits(
  (minute ~/ 60).toString().padLeft(2, '0') +
      ':' +
      (minute % 60).toString().padLeft(2, '0'),
);

String timetableDirection(String value) => switch (value) {
  'outbound' => 'رفت',
  'inbound' => 'برگشت',
  _ => 'جهت نامشخص',
};

class TimetableEntry {
  final int? id;
  final String stop, service, direction, source, notes;
  final int days;
  final int? arrival, departure;
  final bool manual;

  const TimetableEntry({
    this.id,
    required this.stop,
    required this.service,
    required this.direction,
    required this.days,
    this.arrival,
    this.departure,
    this.source = '',
    this.notes = '',
    this.manual = true,
  });

  factory TimetableEntry.fromRow(Map<String, Object?> row) => TimetableEntry(
    id: row['id'] as int?,
    stop: row['stop'] as String,
    service: row['service'] as String,
    direction: row['direction'] as String,
    days: row['days'] as int,
    arrival: row['arrival'] as int?,
    departure: row['departure'] as int?,
    source: row['source'] as String,
    notes: row['notes'] as String,
    manual: row['manual'] == 1,
  );

  Map<String, Object?> toRow() => {
    'stop': stop,
    'service': service,
    'direction': direction,
    'days': days,
    'arrival': arrival,
    'departure': departure,
    'source': source.trim(),
    'notes': notes.trim(),
    'manual': manual ? 1 : 0,
  };

  Map<String, Object?> toImportedRow() {
    final row = toRow();
    final identity = {...row}..remove('manual');
    return {
      ...row,
      'origin': sha256.convert(utf8.encode(jsonEncode(identity))).toString(),
    };
  }

  void validate() {
    if (stop.isEmpty ||
        service.isEmpty ||
        !['outbound', 'inbound', 'unknown'].contains(direction) ||
        days < 1 ||
        days > 127 ||
        (arrival == null && departure == null) ||
        [
          arrival,
          departure,
        ].whereType<int>().any((time) => time < 0 || time >= 1440) ||
        source.length > 500 ||
        notes.length > 1000) {
      throw const FormatException(
        'زمان، روزها یا اطلاعات برنامهٔ حرکت معتبر نیست.',
      );
    }
  }
}

List<TimetableEntry> parseTimetable(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map ||
      decoded['schema'] != 1 ||
      decoded['entries'] is! List) {
    throw const FormatException('قالب فایل زمان‌بندی شناخته نشد.');
  }
  final entries = decoded['entries'] as List;
  if (entries.length > 50000)
    throw const FormatException('فایل زمان‌بندی بیش از حد بزرگ است.');
  return entries.map((value) {
    if (value is! Map ||
        value['stop'] is! String ||
        value['service'] is! String ||
        value['direction'] is! String ||
        value['days'] is! int ||
        value['source'] is! String ||
        (value['source'] as String).trim().isEmpty ||
        (value['notes'] != null && value['notes'] is! String)) {
      throw const FormatException('یکی از ردیف‌ها یا منبع آن معتبر نیست.');
    }
    int? time(String key) {
      final raw = value[key];
      if (raw == null) return null;
      final parsed = raw is String ? timetableMinute(raw) : null;
      if (parsed == null)
        throw const FormatException('زمان باید با قالب ساعت:دقیقه ثبت شود.');
      return parsed;
    }

    final row = TimetableEntry(
      stop: value['stop'] as String,
      service: value['service'] as String,
      direction: value['direction'] as String,
      days: value['days'] as int,
      arrival: time('arrival'),
      departure: time('departure'),
      manual: false,
      source: value['source'] as String,
      notes: value['notes'] as String? ?? '',
    );
    row.validate();
    return row;
  }).toList();
}

class TimetableStore {
  Future<Database>? _database;

  Future<Database> _open() => _database ??= _openDatabase();

  Future<Database> _openDatabase() async {
    final dir = await getApplicationSupportDirectory();
    final seed = parseTimetable(
      await rootBundle.loadString('assets/data/timetable.json'),
    );
    return openDatabase(
      p.join(dir.path, 'timetable.sqlite'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE timetable (
          id INTEGER PRIMARY KEY, stop TEXT NOT NULL, service TEXT NOT NULL,
          direction TEXT NOT NULL, days INTEGER NOT NULL, arrival INTEGER,
          departure INTEGER, notes TEXT NOT NULL, source TEXT NOT NULL,
          manual INTEGER NOT NULL, origin TEXT UNIQUE
        )''');
        await db.execute(
          'CREATE INDEX timetable_station ON timetable(stop, service)',
        );
        final batch = db.batch();
        for (final row in seed) {
          batch.insert(
            'timetable',
            row.toImportedRow(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      },
    );
  }

  Future<List<TimetableEntry>> forStop(String stop) async {
    final rows = await (await _open()).query(
      'timetable',
      where: 'stop = ?',
      whereArgs: [stop],
      orderBy: 'COALESCE(arrival, departure), service, id',
    );
    return rows.map(TimetableEntry.fromRow).toList();
  }

  Future<void> save(TimetableEntry entry) async {
    entry.validate();
    final db = await _open();
    final row = {...entry.toRow(), 'manual': 1};
    if (entry.id == null) {
      await db.insert('timetable', row);
    } else {
      await db.update('timetable', row, where: 'id = ?', whereArgs: [entry.id]);
    }
  }

  Future<void> delete(int id) async {
    await (await _open()).delete('timetable', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> importRows(List<TimetableEntry> rows) async {
    final db = await _open();
    return db.transaction((tx) async {
      var inserted = 0;
      for (final row in rows) {
        row.validate();
        await tx.insert(
          'timetable',
          row.toImportedRow(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        inserted +=
            (await tx.rawQuery('SELECT changes() AS total')).single['total']
                as int;
      }
      return inserted;
    });
  }

  Future<void> dispose() async {
    final opened = _database;
    if (opened != null) await (await opened).close();
  }
}
