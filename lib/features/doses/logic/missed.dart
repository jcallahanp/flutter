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
 * Pure logic of the missed-slot prompt. No database, no clock.
 */

import 'package:wger/features/doses/logic/one_tap.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';

/// Days before today that are checked.
const missedLookbackDays = 7;

/// A slot on a past day with regimen items that have no dose logged.
class MissedSlot {
  final DoseSlot slot;

  /// Calendar day, midnight
  final DateTime date;
  final List<Regimen> items;

  const MissedSlot({required this.slot, required this.date, required this.items});
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// For each of the [lookbackDays] days before [today] (never today), the slots
/// that have a regimen item (by [slotItems]) with no dose logged. A day with
/// an entry still `pending` or `no_key` is skipped, since the entry may log
/// those doses once read. Oldest first, slots in the given order.
List<MissedSlot> missedSlots({
  required DateTime today,
  required List<DoseSlot> slots,
  required List<Regimen> regimen,
  required List<Medication> medications,
  required List<DoseLog> doses,
  required List<RawEntry> entries,
  int lookbackDays = missedLookbackDays,
}) {
  final base = _day(today);
  final unread = {
    for (final e in entries)
      if (e.state == 'pending' || e.state == 'no_key') _day(e.createdOnDevice.toLocal()),
  };
  final result = <MissedSlot>[];
  for (var back = lookbackDays; back >= 1; back--) {
    final date = DateTime(base.year, base.month, base.day - back);
    if (unread.contains(date)) {
      continue;
    }
    for (final slot in slots) {
      final items = unloggedItems(
        slot: slot,
        date: date,
        regimen: regimen,
        medications: medications,
        logged: doses,
      );
      if (items.isNotEmpty) {
        result.add(MissedSlot(slot: slot, date: date, items: items));
      }
    }
  }
  return result;
}
