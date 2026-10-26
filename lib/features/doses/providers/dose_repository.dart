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
import 'package:wger/features/doses/logic/one_tap.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/parse_result.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';

/// Longest free text the server accepts.
const rawEntryMaxLength = 2000;

/// The largest amount the server stores (10 digits, 3 of them decimals).
const maxDoseAmount = 10000000;

/// [text] as a dose amount (a comma counts as the decimal point), rounded to
/// the 3 places the server keeps. `null` for anything that is not a plain
/// finite number below [maxDoseAmount]: NaN, Infinity and 1e400 would break
/// reads or block the upload queue.
double? parseDoseAmount(String text) {
  final value = double.tryParse(text.trim().replaceAll(',', '.'));
  if (value == null || !value.isFinite || value.abs() >= maxDoseAmount) {
    return null;
  }
  return (value * 1000).round() / 1000;
}

void _checkAmount(String name, double? value) {
  if (value != null && (!value.isFinite || value.abs() >= maxDoseAmount)) {
    throw ArgumentError.value(value, name, 'Not an amount the server can store');
  }
}

/// [text] cut to at most [rawEntryMaxLength] code points; a surrogate pair is
/// never split.
String truncateToEntryLimit(String text) =>
    String.fromCharCodes(text.runes.take(rawEntryMaxLength));

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

  /// The regimens in force on at least one day from [from] to [to].
  Stream<List<Regimen>> watchRegimenBetween(DateTime from, DateTime to) {
    final query = _db.select(_db.regimenTable)
      ..where(
        (t) =>
            t.startDate.isSmallerOrEqualValue(_dayText(to)) &
            (t.endDate.isNull() | t.endDate.isBiggerOrEqualValue(_dayText(from))),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.startDate),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch();
  }

  /// All medications, by name.
  Stream<List<Medication>> watchMedications() {
    final query = _db.select(_db.medicationTable)
      ..orderBy([(t) => OrderingTerm(expression: t.name), (t) => OrderingTerm(expression: t.id)]);
    return query.watch();
  }

  /// The regimens that have no end date.
  Stream<List<Regimen>> watchOpenRegimens() {
    final query = _db.select(_db.regimenTable)
      ..where((t) => t.endDate.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.startDate),
        (t) => OrderingTerm(expression: t.id),
      ]);
    return query.watch();
  }

  /// Ends the regimen [id]: it is no longer planned from [firstDayOff] on
  /// (stored as the end date of the day before, which is inclusive). The doses
  /// already logged stay.
  Future<void> endRegimen(String id, DateTime firstDayOff) async {
    await (_db.update(_db.regimenTable)..where((t) => t.id.equals(id))).write(
      RegimenTableCompanion(endDate: Value(_dayBefore(firstDayOff))),
    );
  }

  /// Ends every open regimen of the medication [medicationId] from
  /// [firstDayOff] on, like [endRegimen].
  Future<void> endOpenRegimensOf(String medicationId, DateTime firstDayOff) async {
    await (_db.update(_db.regimenTable)
          ..where((t) => t.medicationId.equals(medicationId) & t.endDate.isNull()))
        .write(RegimenTableCompanion(endDate: Value(_dayBefore(firstDayOff))));
  }

  /// Sets the medication [id] inactive and ends its open regimens from
  /// [firstDayOff] on.
  Future<void> deactivateMedication(String id, DateTime firstDayOff) async {
    await _db.transaction(() async {
      await (_db.update(_db.medicationTable)..where((t) => t.id.equals(id))).write(
        const MedicationTableCompanion(active: Value(false)),
      );
      await endOpenRegimensOf(id, firstDayOff);
    });
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

  /// The dose logs from [from] to [to], both days inclusive.
  Stream<List<DoseLog>> watchDosesBetween(DateTime from, DateTime to) {
    final query = _db.select(_db.doseLogTable)
      ..where(
        (t) =>
            t.date.isBiggerOrEqualValue(_dayText(from)) &
            t.date.isSmallerOrEqualValue(_dayText(to)),
      )
      ..orderBy([(t) => OrderingTerm(expression: t.date), (t) => OrderingTerm(expression: t.id)]);
    return query.watch();
  }

  /// The doses created from the raw entry [rawEntryId].
  Stream<List<DoseLog>> watchDosesOfEntry(String rawEntryId) {
    final query = _db.select(_db.doseLogTable)
      ..where((t) => t.rawEntryId.equals(rawEntryId))
      ..orderBy([(t) => OrderingTerm(expression: t.date), (t) => OrderingTerm(expression: t.id)]);
    return query.watch();
  }

  /// The server's parse result of the raw entry [rawEntryId], `null` until it
  /// has synced down.
  Stream<ParseResult?> watchParseResultFor(String rawEntryId) {
    final query = _db.select(_db.parseResultTable)
      ..where((t) => t.rawEntryId.equals(rawEntryId))
      ..orderBy([(t) => OrderingTerm.desc(t.created), (t) => OrderingTerm(expression: t.id)])
      ..limit(1);
    return query.watchSingleOrNull();
  }

  /// The entries written on or after the (device-local) day [from], oldest
  /// first.
  Stream<List<RawEntry>> watchRawEntriesSince(DateTime from) {
    final start = DateTime(from.year, from.month, from.day);
    // Filtered after parsing, see watchRawEntriesOn
    return _db.select(_db.rawEntryTable).watch().map((rows) {
      final recent = rows.where((e) => !e.createdOnDevice.isBefore(start)).toList();
      recent.sort((a, b) {
        final byTime = a.createdOnDevice.compareTo(b.createdOnDevice);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
      return recent;
    });
  }

  /// The free-text entries written on the (device-local) day [date].
  Stream<List<RawEntry>> watchRawEntriesOn(DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final end = DateTime(date.year, date.month, date.day + 1);
    // Filtered after parsing rather than in SQL: rows synced back from
    // Postgres carry timestamptz text ("2026-10-25 20:00:00+00", a space and
    // an offset), which does not compare lexically with the ISO form written
    // here. The converter parses all of them.
    return _db.select(_db.rawEntryTable).watch().map((rows) {
      final day = rows
          .where((e) => !e.createdOnDevice.isBefore(start) && e.createdOnDevice.isBefore(end))
          .toList();
      day.sort((a, b) {
        final byTime = a.createdOnDevice.compareTo(b.createdOnDevice);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
      return day;
    });
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
    _checkAmount('strength', strength);
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
    // The server keeps slot names unique and would drop the upload silently
    final clash =
        await (_db.select(
              _db.doseSlotTable,
            )..where(
              (t) =>
                  t.name.equals(name) & (id == null ? const Constant(true) : t.id.equals(id).not()),
            ))
            .get();
    if (clash.isNotEmpty) {
      throw ArgumentError.value(name, 'name', 'A slot with this name exists');
    }
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
    _checkAmount('amount', amount);
    if (endDate == null) {
      final open =
          await (_db.select(_db.regimenTable)..where(
                (t) =>
                    t.medicationId.equals(medicationId) &
                    t.slotId.equals(slotId) &
                    t.endDate.isNull() &
                    (id == null ? const Constant(true) : t.id.equals(id).not()),
              ))
              .get();
      if (open.isNotEmpty) {
        throw ArgumentError.value(slotId, 'slotId', 'The medication is already in this slot');
      }
    }
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

  /// Logs a dose. A second log for one (regimen, date) updates the existing
  /// row (an explicit edit), or with [onlyIfAbsent] leaves it as it is and
  /// returns its id (one-tap, missed prompt, proposals).
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
    bool onlyIfAbsent = false,
  }) async {
    _checkAmount('amount', amount);
    _checkAmount('plannedAmount', plannedAmount);
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
    // The server keeps one log per regimen and day and refuses a second, which
    // the upload would then drop silently: log again onto the existing row.
    // Lookup and write share a transaction, so concurrent calls cannot both
    // insert.
    return _db.transaction(() async {
      if (regimenId != null) {
        final existing =
            await (_db.select(_db.doseLogTable)
                  ..where((t) => t.regimenId.equals(regimenId) & t.date.equals(_dayText(date)))
                  ..limit(1))
                .getSingleOrNull();
        if (existing != null && onlyIfAbsent) {
          return existing.id;
        }
        if (existing != null) {
          await (_db.update(_db.doseLogTable)..where((t) => t.id.equals(existing.id))).write(
            companion.copyWith(id: const Value.absent()),
          );
          return existing.id;
        }
      }
      await _db.into(_db.doseLogTable).insert(companion);
      return companion.id.value;
    });
  }

  /// Logs as taken, at the planned amount, the items of the slot [slotId] that
  /// have no dose on [date] yet (the one-tap logic; a day past is stamped
  /// with the slot's usual time, today with [now]), linked to [rawEntryId] so
  /// Undo can remove them. Does nothing for an unknown slot.
  Future<void> logRestTaken({
    required String slotId,
    required DateTime date,
    required DateTime now,
    String? rawEntryId,
  }) async {
    final slot = await (_db.select(
      _db.doseSlotTable,
    )..where((t) => t.id.equals(slotId))).getSingleOrNull();
    if (slot == null) {
      return;
    }
    final day = _dayText(date);
    final regimen =
        await (_db.select(_db.regimenTable)..where(
              (t) =>
                  t.startDate.isSmallerOrEqualValue(day) &
                  (t.endDate.isNull() | t.endDate.isBiggerOrEqualValue(day)),
            ))
            .get();
    final medications = await _db.select(_db.medicationTable).get();
    final logged = await (_db.select(_db.doseLogTable)..where((t) => t.date.equals(day))).get();
    final drafts = oneTapDrafts(
      slot: slot,
      slotDate: date,
      regimen: regimen,
      medications: medications,
      logged: logged,
      now: now,
    );
    for (final d in drafts) {
      await logDose(
        medicationId: d.medicationId,
        regimenId: d.regimenId,
        date: d.date,
        takenAt: defaultTakenAt(date: date, now: now, usualTime: slot.usualTime),
        plannedAmount: d.plannedAmount,
        amount: d.amount,
        unit: d.unit,
        status: d.status,
        source: d.source,
        rawEntryId: rawEntryId,
        onlyIfAbsent: true,
      );
    }
  }

  /// The usual time of the slot of the regimen [regimenId], `null` when the
  /// regimen or its slot is unknown.
  Future<TimeOfDay?> usualTimeOfRegimen(String regimenId) async {
    final regimen = await (_db.select(
      _db.regimenTable,
    )..where((t) => t.id.equals(regimenId))).getSingleOrNull();
    if (regimen == null) {
      return null;
    }
    final slot = await (_db.select(
      _db.doseSlotTable,
    )..where((t) => t.id.equals(regimen.slotId))).getSingleOrNull();
    return slot?.usualTime;
  }

  /// Changes the given fields of the dose [id]; those left out stay as they
  /// are (so editing the amount keeps the regimen and raw entry links).
  Future<void> updateDose({
    required String id,
    Value<String> medicationId = const Value.absent(),
    Value<String?> regimenId = const Value.absent(),
    Value<DateTime> date = const Value.absent(),
    Value<DateTime?> takenAt = const Value.absent(),
    Value<double?> plannedAmount = const Value.absent(),
    Value<double> amount = const Value.absent(),
    Value<String> unit = const Value.absent(),
    Value<String> status = const Value.absent(),
    Value<String> source = const Value.absent(),
    Value<String?> rawEntryId = const Value.absent(),
    Value<String> note = const Value.absent(),
  }) async {
    _checkAmount('amount', amount.present ? amount.value : null);
    _checkAmount('plannedAmount', plannedAmount.present ? plannedAmount.value : null);
    final companion = DoseLogTableCompanion(
      medicationId: medicationId,
      regimenId: regimenId,
      date: date.present ? Value(_day(date.value)) : const Value.absent(),
      takenAt: takenAt.present ? Value(takenAt.value?.toUtc()) : const Value.absent(),
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
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'An entry cannot be empty');
    }
    // The server counts code points
    if (text.runes.length > rawEntryMaxLength) {
      throw ArgumentError.value(
        text.runes.length,
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
  DateTime _dayBefore(DateTime date) => DateTime.utc(date.year, date.month, date.day - 1);

  DateTime _day(DateTime date) => DateTime.utc(date.year, date.month, date.day);
}
