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
 * Pure logic of the one-tap "took as planned" action. No database, no clock.
 */

import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/regimen.dart';

/// A slot's occurrence on day D runs until this hour on D+1: doses taken
/// after midnight still belong to the evening before.
const slotCarryOverHour = 4;

/// A dose to be saved with `DoseRepository.logDose`.
class DoseDraft {
  final String medicationId;
  final String regimenId;
  final DateTime date;
  final double amount;
  final String unit;
  final double plannedAmount;
  final String status;
  final String source;
  final DateTime takenAt;

  const DoseDraft({
    required this.medicationId,
    required this.regimenId,
    required this.date,
    required this.amount,
    required this.unit,
    required this.plannedAmount,
    this.status = 'taken',
    this.source = 'one_tap',
    required this.takenAt,
  });
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// The regimen items planned for [slot] on [date]: the slot's regimens in
/// force that day, of an active medication of kind `routine`. The one filter
/// shared by the one-tap logic and the Today screen.
List<Regimen> slotItems({
  required DoseSlot slot,
  required DateTime date,
  required List<Regimen> regimen,
  required List<Medication> medications,
}) {
  final day = _day(date);
  final planned = {
    for (final m in medications)
      if (m.active && m.kind == 'routine') m.id,
  };
  return regimen.where((r) {
    if (r.slotId != slot.id || !planned.contains(r.medicationId)) {
      return false;
    }
    final end = r.endDate == null ? null : _day(r.endDate!);
    return !_day(r.startDate).isAfter(day) && (end == null || !end.isBefore(day));
  }).toList();
}

/// The items of [slot] with no dose logged (any status) for [date].
List<Regimen> unloggedItems({
  required DoseSlot slot,
  required DateTime date,
  required List<Regimen> regimen,
  required List<Medication> medications,
  required List<DoseLog> logged,
}) {
  final day = _day(date);
  final done = {
    for (final l in logged)
      if (l.regimenId != null && _day(l.date) == day) l.regimenId!,
  };
  return slotItems(
    slot: slot,
    date: date,
    regimen: regimen,
    medications: medications,
  ).where((r) => !done.contains(r.id)).toList();
}

/// One `taken` draft per item of [slot] not yet logged for [slotDate], at the
/// planned amount, taken at [now].
List<DoseDraft> oneTapDrafts({
  required DoseSlot slot,
  required DateTime slotDate,
  required List<Regimen> regimen,
  required List<Medication> medications,
  required List<DoseLog> logged,
  required DateTime now,
}) {
  return [
    for (final r in unloggedItems(
      slot: slot,
      date: slotDate,
      regimen: regimen,
      medications: medications,
      logged: logged,
    ))
      DoseDraft(
        medicationId: r.medicationId,
        regimenId: r.id,
        date: _day(slotDate),
        amount: r.amount,
        unit: r.unit,
        plannedAmount: r.amount,
        takenAt: now,
      ),
  ];
}

/// The date a one-tap on [slot] logs for at [now]: the latest occurrence
/// that is current and still has unlogged items. An occurrence on day D runs
/// until [slotCarryOverHour]:00 on D+1, so before that hour yesterday's is
/// current, and it is the only current one while today's has not started
/// (now is before the slot's usual time), whether or not it is fully logged.
///
/// Otherwise today if it has unlogged items, then yesterday (before the
/// carry-over hour) if it has, else today.
DateTime defaultSlotDate(
  DoseSlot slot,
  DateTime now, {
  required List<Regimen> regimen,
  required List<Medication> medications,
  required List<DoseLog> logged,
}) {
  final today = _day(now);
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  final carryOver = now.hour < slotCarryOverHour;

  bool hasUnlogged(DateTime date) => unloggedItems(
    slot: slot,
    date: date,
    regimen: regimen,
    medications: medications,
    logged: logged,
  ).isNotEmpty;

  final usual = slot.usualTime.hour * 60 + slot.usualTime.minute;
  final started = now.hour * 60 + now.minute >= usual;

  // Before the carry-over hour, today's occurrence has not started until the
  // slot's usual time: yesterday's is the current one, logged or not, and
  // tonight's dose is never logged early
  if (carryOver && !started) {
    return yesterday;
  }
  if (hasUnlogged(today)) {
    return today;
  }
  if (carryOver && hasUnlogged(yesterday)) {
    return yesterday;
  }
  return today;
}

/// When a dose without a recorded time was taken: [now] for today, else
/// [date] at the slot's [usualTime] (noon without a slot). One rule for the
/// history edit and for doses logged by a proposal.
DateTime defaultTakenAt({required DateTime date, required DateTime now, TimeOfDay? usualTime}) {
  final day = DateTime(date.year, date.month, date.day);
  if (day == _day(now)) {
    return now;
  }
  return DateTime(day.year, day.month, day.day, usualTime?.hour ?? 12, usualTime?.minute ?? 0);
}
