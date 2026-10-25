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
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';

import '../../helpers/in_memory_drift.dart';

void main() {
  late DriftPowersyncDatabase db;
  late DoseRepository repo;

  setUp(() async {
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
  });

  tearDown(() => db.close());

  Future<({String med, String slot})> medAndSlot() async {
    final med = await repo.saveMedication(name: 'Metformin', strength: 500, unit: 'mg');
    final slot = await repo.saveSlot(
      name: 'Morning',
      usualTime: const TimeOfDay(hour: 8, minute: 0),
    );
    return (med: med, slot: slot);
  }

  Future<String> dose(String med, DateTime date, {String? rawEntryId}) => repo.logDose(
    medicationId: med,
    date: date,
    amount: 1,
    unit: 'tablet',
    status: 'taken',
    source: rawEntryId == null ? 'one_tap' : 'parsed',
    rawEntryId: rawEntryId,
  );

  test('creates a medication, a slot and a regimen', () async {
    final ids = await medAndSlot();
    final regimenId = await repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 10, 1),
    );

    final slots = await repo.watchSlots().first;
    expect(slots.single.name, 'Morning');
    expect(slots.single.usualTime, const TimeOfDay(hour: 8, minute: 0));

    final regimen = await repo.watchRegimenOn(DateTime(2026, 10, 25)).first;
    expect(regimen.single.id, regimenId);
    expect(regimen.single.medicationId, ids.med);
    expect(regimen.single.schedule, 'daily');
    expect(regimen.single.endDate, isNull);

    final meds = await db.select(db.medicationTable).get();
    expect(meds.single.active, isTrue);
    expect(meds.single.kind, 'routine');
    expect(meds.single.strength, 500);
  });

  test('saveMedication with an id updates the row', () async {
    final id = await repo.saveMedication(name: 'Metformin', unit: 'mg');
    await repo.saveMedication(id: id, name: 'Metformin', unit: 'mg', active: false);

    final meds = await db.select(db.medicationTable).get();
    expect(meds, hasLength(1));
    expect(meds.single.active, isFalse);
  });

  test('watchRegimenOn excludes ended and not yet started regimens', () async {
    final ids = await medAndSlot();
    Future<String> regimen(DateTime start, DateTime? end) => repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: start,
      endDate: end,
    );

    final open = await regimen(DateTime(2026, 10, 1), null);
    final lastDay = await regimen(DateTime(2026, 10, 1), DateTime(2026, 10, 25));
    await regimen(DateTime(2026, 9, 1), DateTime(2026, 10, 24));
    await regimen(DateTime(2026, 10, 26), null);

    final found = await repo.watchRegimenOn(DateTime(2026, 10, 25, 14, 30)).first;
    expect(found.map((r) => r.id).toSet(), {open, lastDay});
  });

  test('createRawEntry stores the time zone and a pending state', () async {
    final before = DateTime.now().toUtc();
    final id = await repo.createRawEntry('took two ibuprofen at noon');

    final row = await (db.select(db.rawEntryTable)..where((t) => t.id.equals(id))).getSingle();
    expect(row.text, 'took two ibuprofen at noon');
    expect(row.timeZone, 'Europe/Berlin');
    expect(row.state, 'pending');
    expect(row.parentId, isNull);
    expect(
      row.createdOnDevice.toUtc().isBefore(before.subtract(const Duration(seconds: 1))),
      isFalse,
    );

    final child = await repo.createRawEntry('the 400 mg one', parentId: id);
    final childRow = await (db.select(
      db.rawEntryTable,
    )..where((t) => t.id.equals(child))).getSingle();
    expect(childRow.parentId, id);
  });

  test('createRawEntry accepts 2000 characters and refuses more', () async {
    await repo.createRawEntry('a' * 2000);
    expect(() => repo.createRawEntry('a' * 2001), throwsArgumentError);
    expect(await db.select(db.rawEntryTable).get(), hasLength(1));
  });

  test('watchRawEntriesOn returns the entries of that day only', () async {
    final id = await repo.createRawEntry('today');
    final today = DateTime.now();

    expect((await repo.watchRawEntriesOn(today).first).map((e) => e.id), [id]);
    expect(await repo.watchRawEntriesOn(today.subtract(const Duration(days: 1))).first, isEmpty);
  });

  test('deleteDosesOf removes only the doses of that entry', () async {
    final ids = await medAndSlot();
    final entry = await repo.createRawEntry('one');
    final other = await repo.createRawEntry('two');
    final day = DateTime(2026, 10, 25);

    await dose(ids.med, day, rawEntryId: entry);
    await dose(ids.med, day, rawEntryId: entry);
    final kept = await dose(ids.med, day, rawEntryId: other);
    final manual = await dose(ids.med, day);

    await repo.deleteDosesOf(entry);

    final left = await repo.watchDosesOn(day).first;
    expect(left.map((d) => d.id).toSet(), {kept, manual});
  });

  test('logDose, updateDose and deleteDose round-trip a day', () async {
    final ids = await medAndSlot();
    final day = DateTime(2026, 10, 25);
    final id = await dose(ids.med, day);

    var doses = await repo.watchDosesOn(day).first;
    expect(doses.single.date, DateTime.utc(2026, 10, 25));
    expect(doses.single.status, 'taken');
    expect(doses.single.note, '');
    expect(await repo.watchDosesOn(DateTime(2026, 10, 26)).first, isEmpty);

    await repo.updateDose(
      id: id,
      medicationId: ids.med,
      date: day,
      amount: 0.5,
      plannedAmount: 1,
      unit: 'tablet',
      status: 'partial',
      source: 'manual',
      note: 'half',
    );
    doses = await repo.watchDosesOn(day).first;
    expect(doses.single.amount, 0.5);
    expect(doses.single.status, 'partial');
    expect(doses.single.note, 'half');

    await repo.deleteDose(id);
    expect(await repo.watchDosesOn(day).first, isEmpty);
  });
}
