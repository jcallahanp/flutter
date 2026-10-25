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

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:wger/features/doses/logic/missed.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';

void main() {
  final evening = DoseSlot.fromDb(
    id: 's-eve',
    name: 'Evening',
    usualTime: const TimeOfDay(hour: 21, minute: 0),
    order: 0,
  );
  Medication med(String id) =>
      Medication.fromDb(id: id, name: id, unit: 'mg', form: '', kind: 'routine', active: true);
  Regimen reg(String id, String medId, {DateTime? start, DateTime? end}) => Regimen.fromDb(
    id: id,
    medicationId: medId,
    slotId: 's-eve',
    amount: 2,
    unit: 'tablet',
    schedule: 'daily',
    startDate: start ?? DateTime(2026, 1, 1),
    endDate: end,
  );
  DoseLog log(String regimenId, String medId, DateTime date) => DoseLog.fromDb(
    id: 'l-$regimenId-$date',
    medicationId: medId,
    regimenId: regimenId,
    date: date,
    amount: 2,
    unit: 'tablet',
    status: 'taken',
    source: 'manual',
    note: '',
  );
  RawEntry entry(DateTime created, String state) => RawEntry.fromDb(
    id: 'e-$created',
    body: 'text',
    createdOnDevice: created,
    timeZone: 'Europe/Berlin',
    state: state,
  );

  final today = DateTime(2026, 10, 25, 12);
  final meds = [med('a'), med('b')];
  final regimen = [reg('r-a', 'a'), reg('r-b', 'b')];

  List<MissedSlot> run({
    List<Regimen>? regimenOverride,
    List<DoseLog> doses = const [],
    List<RawEntry> entries = const [],
  }) => missedSlots(
    today: today,
    slots: [evening],
    regimen: regimenOverride ?? regimen,
    medications: meds,
    doses: doses,
    entries: entries,
  );

  test('never_asks_about_today', () {
    final result = run();
    expect(result, hasLength(7));
    expect(result.first.date, DateTime(2026, 10, 18));
    expect(result.last.date, DateTime(2026, 10, 24));
    expect(result.any((m) => m.date == DateTime(2026, 10, 25)), isFalse);
  });

  test('pending_entry_suppresses_prompt', () {
    for (final state in ['pending', 'no_key']) {
      final result = run(entries: [entry(DateTime(2026, 10, 24, 22, 30), state)]);
      expect(result.any((m) => m.date == DateTime(2026, 10, 24)), isFalse, reason: state);
      expect(result, hasLength(6));
    }
    // A read entry does not suppress
    final read = run(entries: [entry(DateTime(2026, 10, 24, 22, 30), 'parsed')]);
    expect(read, hasLength(7));
  });

  test('only_unlogged_items', () {
    final result = run(doses: [log('r-a', 'a', DateTime.utc(2026, 10, 24))]);
    final yesterday = result.firstWhere((m) => m.date == DateTime(2026, 10, 24));
    expect(yesterday.items.map((r) => r.id), ['r-b']);
    final full = run(
      doses: [
        log('r-a', 'a', DateTime.utc(2026, 10, 24)),
        log('r-b', 'b', DateTime.utc(2026, 10, 24)),
      ],
    );
    expect(full.any((m) => m.date == DateTime(2026, 10, 24)), isFalse);
  });

  test('ended_regimen_not_missed', () {
    final result = run(
      regimenOverride: [
        reg('r-a', 'a', end: DateTime(2026, 10, 20)),
        reg('r-b', 'b', start: DateTime(2026, 10, 23)),
      ],
    );
    final a = result.where((m) => m.items.any((r) => r.id == 'r-a')).map((m) => m.date);
    expect(a.every((d) => !d.isAfter(DateTime(2026, 10, 20))), isTrue);
    final b = result.where((m) => m.items.any((r) => r.id == 'r-b')).map((m) => m.date);
    expect(b, [DateTime(2026, 10, 23), DateTime(2026, 10, 24)]);
  });
}
