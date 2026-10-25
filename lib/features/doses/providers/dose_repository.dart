/*
 * This file is part of wger Workout Manager <https://github.com/wger-project>.
 * Copyright (c) 2026 wger Team
 *
 * wger Workout Manager is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * Repository for medication dose logging (local Drift operations).
 */

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:powersync/powersync.dart' as ps;
import 'package:wger/database/converters/date_only_text_converter.dart';
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';

/// Longest free text the server accepts.
const rawEntryMaxLength = 2000;

final doseRepositoryProvider = Provider<DoseRepository>((ref) {
  final db = ref.read(driftPowerSyncDatabase);
  return DoseRepository(db);
});

Future<String> _detectDeviceTimezone() async {
  return (await FlutterTimezone.getLocalTimezone()).identifier;
}

class DoseRepository {
  final _logger = Logger('DoseRepository');
  final DriftPowersyncDatabase _db;
  final Future<String> Function() _detectTimezone;

  /// [detectTimezone] returns the device's IANA zone name; tests inject one.
  DoseRepository(this._db, {Future<String> Function()? detectTimezone})
    : _detectTimezone = detectTimezone ?? _detectDeviceTimezone;

  /// The slots in display order.
  Stream<List<DoseSlot>> watchSlots() {
    _logger.finer('Watching dose slots');
    final query = _db.select(
      _db.doseSlotTable,
    )..orderBy([(t) => OrderingTerm(expression: t.order), (t) => OrderingTerm(expression: t.name)]);
    return query.watch();
  }

  /// The regimens in force on [date]: started on or before it, not ended
  /// before it.
  Stream<List<Regimen>> watchRegimenOn(DateTime date) {
    _logger.finer('Watching the regimen on $date');
    final day = _dayText(date);
    final query = _db.select(_db.regimenTable)
      ..where(
        (t) =>
            t.startDate.isSmallerOrEqualValue(day) &
            (t.endDate.isNull() | t.endDate.isBiggerOrEqualValue(day)),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.startDate),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch();
  }

  /// The dose logs of the day [date].
  Stream<List<DoseLog>> watchDosesOn(DateTime date) {
    final day = _dayText(date);
    final query = _db.select(_db.doseLogTable)
      ..where((t) => t.date.equals(day))
      ..orderBy([
        (t) => OrderingTerm(expression: t.takenAt),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch();
  }

  /// The free-text entries written on the (device-local) day [date].
  Stream<List<RawEntry>> watchRawEntriesOn(DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final end = DateTime(date.year, date.month, date.day + 1);
    final query = _db.select(_db.rawEntryTable)
      ..where(
        (t) =>
            t.createdOnDevice.isBiggerOrEqualValue(start.toUtc()) &
            t.createdOnDevice.isSmallerThanValue(end.toUtc()),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdOnDevice),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch();
  }

  /// Creates or updates a medication, returns its id. There is no delete:
  /// the server cascades the dose history, so a medication is set inactive.
  Future<String> saveMedication({
    String? id,
    required String name,
    double? strength,
    required String unit,
    String form = '',
    String kind = 'routine',
    bool active = true,
  }) async {
    final newId = id ?? ps.uuid.v7();
    final companion = MedicationTableCompanion(
      id: Value(newId),
      name: Value(name),
      strength: Value(strength),
      unit: Value(unit),
      form: Value(form),
      kind: Value(kind),
      active: Value(active),
    );
    if (id == null) {
      await _db.into(_db.medicationTable).insert(companion);
    } else {
      await (_db.update(_db.medicationTable)..where((t) => t.id.equals(id))).write(companion);
    }
    return newId;
  }

  Future<String> saveSlot({
    String? id,
    required String name,
    required TimeOfDay usualTime,
    int order = 0,
  }) async {
    final newId = id ?? ps.uuid.v7();
    final companion = DoseSlotTableCompanion(
      id: Value(newId),
      name: Value(name),
      usualTime: Value(usualTime),
      order: Value(order),
    );
    if (id == null) {
      await _db.into(_db.doseSlotTable).insert(companion);
    } else {
      await (_db.update(_db.doseSlotTable)..where((t) => t.id.equals(id))).write(companion);
    }
    return newId;
  }

  Future<String> saveRegimen({
    String? id,
    required String medicationId,
    required String slotId,
    required double amount,
    required String unit,
    String schedule = 'daily',
    required DateTime startDate,
    DateTime? endDate,
  }) async {
    final newId = id ?? ps.uuid.v7();
    final companion = RegimenTableCompanion(
      id: Value(newId),
      medicationId: Value(medicationId),
      slotId: Value(slotId),
      amount: Value(amount),
      unit: Value(unit),
      schedule: Value(schedule),
      startDate: Value(_day(startDate)),
      endDate: Value(endDate == null ? null : _day(endDate)),
    );
    if (id == null) {
      await _db.into(_db.regimenTable).insert(companion);
    } else {
      await (_db.update(_db.regimenTable)..where((t) => t.id.equals(id))).write(companion);
    }
    return newId;
  }

  Future<String> logDose({
    required String medicationId,
    String? regimenId,
    required DateTime date,
    DateTime? takenAt,
    double? plannedAmount,
    required double amount,
    required String unit,
    required String status,
    required String source,
    String? rawEntryId,
    String note = '',
  }) async {
    final companion = _doseCompanion(
      id: ps.uuid.v7(),
      medicationId: medicationId,
      regimenId: regimenId,
      date: date,
      takenAt: takenAt,
      plannedAmount: plannedAmount,
      amount: amount,
      unit: unit,
      status: status,
      source: source,
      rawEntryId: rawEntryId,
      note: note,
    );
    await _db.into(_db.doseLogTable).insert(companion);
    return companion.id.value;
  }

  /// Rewrites the dose [id] with the given values.
  Future<void> updateDose({
    required String id,
    required String medicationId,
    String? regimenId,
    required DateTime date,
    DateTime? takenAt,
    double? plannedAmount,
    required double amount,
    required String unit,
    required String status,
    required String source,
    String? rawEntryId,
    String note = '',
  }) async {
    final companion = _doseCompanion(
      id: id,
      medicationId: medicationId,
      regimenId: regimenId,
      date: date,
      takenAt: takenAt,
      plannedAmount: plannedAmount,
      amount: amount,
      unit: unit,
      status: status,
      source: source,
      rawEntryId: rawEntryId,
      note: note,
    );
    await (_db.update(_db.doseLogTable)..where((t) => t.id.equals(id))).write(companion);
  }

  Future<void> deleteDose(String id) async {
    await (_db.delete(_db.doseLogTable)..where((t) => t.id.equals(id))).go();
  }

  /// Undo for a parsed entry: removes the doses it created, and only those.
  Future<void> deleteDosesOf(String rawEntryId) async {
    await (_db.delete(_db.doseLogTable)..where((t) => t.rawEntryId.equals(rawEntryId))).go();
  }

  /// Stores free text for the server to parse. Stamped with the device's IANA
  /// zone and the current instant; the server moves `state` on from `pending`.
  ///
  /// Throws [ArgumentError] for text over [rawEntryMaxLength] characters.
  Future<String> createRawEntry(String text, {String? parentId}) async {
    if (text.length > rawEntryMaxLength) {
      throw ArgumentError.value(
        text.length,
        'text',
        'Entries are limited to $rawEntryMaxLength characters',
      );
    }
    final zone = await _detectTimezone();
    final companion = RawEntryTableCompanion(
      id: Value(ps.uuid.v7()),
      body: Value(text),
      createdOnDevice: Value(DateTime.now().toUtc()),
      timeZone: Value(zone),
      parentId: Value(parentId),
      state: const Value('pending'),
    );
    await _db.into(_db.rawEntryTable).insert(companion);
    return companion.id.value;
  }

  DoseLogTableCompanion _doseCompanion({
    required String id,
    required String medicationId,
    String? regimenId,
    required DateTime date,
    DateTime? takenAt,
    double? plannedAmount,
    required double amount,
    required String unit,
    required String status,
    required String source,
    String? rawEntryId,
    required String note,
  }) => DoseLogTableCompanion(
    id: Value(id),
    medicationId: Value(medicationId),
    regimenId: Value(regimenId),
    date: Value(_day(date)),
    takenAt: Value(takenAt?.toUtc()),
    plannedAmount: Value(plannedAmount),
    amount: Value(amount),
    unit: Value(unit),
    status: Value(status),
    source: Value(source),
    rawEntryId: Value(rawEntryId),
    note: Value(note),
  );

  /// The calendar day of [date] as stored in a date-only column.
  String _dayText(DateTime date) => const DateOnlyTextConverter().toSql(date);

  /// The calendar day of [date] as a UTC midnight, the shape the date-only
  /// converter reads back.
  DateTime _day(DateTime date) => DateTime.utc(date.year, date.month, date.day);
}
