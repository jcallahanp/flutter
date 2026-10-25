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

import 'package:drift/drift.dart' show Value;
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
    final evening = await repo.saveSlot(
      name: 'Evening',
      usualTime: const TimeOfDay(hour: 20, minute: 0),
    );
    Future<String> regimen(DateTime start, DateTime? end, {String? slot}) => repo.saveRegimen(
      medicationId: ids.med,
      slotId: slot ?? ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: start,
      endDate: end,
    );

    final open = await regimen(DateTime(2026, 10, 1), null);
    final lastDay = await regimen(DateTime(2026, 10, 1), DateTime(2026, 10, 25));
    await regimen(DateTime(2026, 9, 1), DateTime(2026, 10, 24));
    await regimen(DateTime(2026, 10, 26), null, slot: evening);

    final found = await repo.watchRegimenOn(DateTime(2026, 10, 25, 14, 30)).first;
    expect(found.map((r) => r.id).toSet(), {open, lastDay});
  });

  test('endRegimen and deactivateMedication end open regimens and keep doses', () async {
    final ids = await medAndSlot();
    final other = await repo.saveMedication(name: 'Statin', unit: 'mg');
    final evening = await repo.saveSlot(
      name: 'Evening',
      usualTime: const TimeOfDay(hour: 20, minute: 0),
    );
    Future<String> regimen(String med, {String? slot}) => repo.saveRegimen(
      medicationId: med,
      slotId: slot ?? ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 10, 1),
    );
    final a = await regimen(ids.med);
    final b = await regimen(ids.med, slot: evening);
    final c = await regimen(other);
    await dose(ids.med, DateTime(2026, 10, 20));

    expect(await repo.watchOpenRegimens().first, hasLength(3));
    await repo.endRegimen(a, DateTime(2026, 10, 25, 9));
    expect((await repo.watchOpenRegimens().first).map((r) => r.id).toSet(), {b, c});

    await repo.deactivateMedication(ids.med, DateTime(2026, 10, 25));
    expect((await repo.watchOpenRegimens().first).map((r) => r.id), [c]);
    final meds = await repo.watchMedications().first;
    expect(meds.map((m) => m.name), ['Metformin', 'Statin']);
    expect(meds.first.active, isFalse);
    expect(meds.last.active, isTrue);
    expect(await repo.watchDosesOn(DateTime(2026, 10, 20)).first, hasLength(1));

    // Ended from the 25th: still planned on the 24th, not on the 25th
    expect(await repo.watchRegimenOn(DateTime(2026, 10, 24)).first, hasLength(3));
    final onDay = await repo.watchRegimenOn(DateTime(2026, 10, 25)).first;
    expect(onDay.map((r) => r.id), [c]);
  });

  test('refuses a duplicate slot name and a second open regimen in a slot', () async {
    final ids = await medAndSlot();
    expect(
      () => repo.saveSlot(name: 'Morning', usualTime: const TimeOfDay(hour: 9, minute: 0)),
      throwsArgumentError,
    );
    // Saving the slot itself under its own name is fine
    await repo.saveSlot(
      id: ids.slot,
      name: 'Morning',
      usualTime: const TimeOfDay(hour: 9, minute: 0),
    );

    Future<String> regimen() => repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 10, 1),
    );
    final first = await regimen();
    expect(regimen, throwsArgumentError);
    await repo.endRegimen(first, DateTime(2026, 10, 25));
    await regimen();
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

  test('createRawEntry refuses blank text', () async {
    expect(() => repo.createRawEntry(''), throwsArgumentError);
    expect(() => repo.createRawEntry(' \n\t '), throwsArgumentError);
    expect(await db.select(db.rawEntryTable).get(), isEmpty);
  });

  test('watchRawEntriesOn filters the local day across stored formats', () async {
    final day = DateTime(2026, 10, 25, 15);
    final start = DateTime(2026, 10, 25);
    final end = DateTime(2026, 10, 26);
    String iso(DateTime t) => t.toUtc().toIso8601String();
    // Postgres/PowerSync style: space separator
    String spaced(DateTime t) => iso(t).replaceFirst('T', ' ');

    Future<void> insert(String id, String created) => db.customStatement(
      'INSERT INTO healthhub_rawentry (id, text, created_on_device, time_zone, state) '
      "VALUES (?, 'x', ?, 'UTC', 'pending')",
      [id, created],
    );

    await insert('a-first-ms', iso(start));
    await insert('b-spaced', spaced(start.add(const Duration(hours: 5))));
    await insert(
      'c-offset',
      '${spaced(start.add(const Duration(hours: 9))).replaceAll('Z', '')}+00',
    );
    await insert('d-last-ms', iso(end.subtract(const Duration(milliseconds: 1))));
    await insert('e-before', iso(start.subtract(const Duration(milliseconds: 1))));
    await insert('f-after', spaced(end));

    final found = await repo.watchRawEntriesOn(day).first;
    expect(found.map((e) => e.id), ['a-first-ms', 'b-spaced', 'c-offset', 'd-last-ms']);
  });

  test('logDose onto an existing (regimen, date) updates that row', () async {
    final ids = await medAndSlot();
    final regimenId = await repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 10, 1),
    );
    final day = DateTime(2026, 10, 25);
    Future<String> log(String status, double amount) => repo.logDose(
      medicationId: ids.med,
      regimenId: regimenId,
      date: day,
      amount: amount,
      unit: 'tablet',
      status: status,
      source: 'one_tap',
    );

    final first = await log('missed', 0);
    final second = await log('taken', 1);

    expect(second, first);
    final doses = await repo.watchDosesOn(day).first;
    expect(doses, hasLength(1));
    expect(doses.single.status, 'taken');
    expect(doses.single.amount, 1);

    // another day, or no regimen, still inserts
    await repo.logDose(
      medicationId: ids.med,
      regimenId: regimenId,
      date: DateTime(2026, 10, 26),
      amount: 1,
      unit: 'tablet',
      status: 'taken',
      source: 'one_tap',
    );
    await dose(ids.med, day);
    await dose(ids.med, day);
    expect(await db.select(db.doseLogTable).get(), hasLength(4));
  });

  test('concurrent logDose calls for one (regimen, date) leave one row', () async {
    final ids = await medAndSlot();
    final regimenId = await repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 10, 1),
    );
    Future<String> log() => repo.logDose(
      medicationId: ids.med,
      regimenId: regimenId,
      date: DateTime(2026, 10, 25),
      amount: 1,
      unit: 'tablet',
      status: 'taken',
      source: 'one_tap',
    );

    final results = await Future.wait([log(), log(), log()]);

    expect(results.toSet(), hasLength(1));
    expect(await db.select(db.doseLogTable).get(), hasLength(1));
  });

  test('updateDose changes only the fields passed', () async {
    final ids = await medAndSlot();
    final regimenId = await repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 10, 1),
    );
    final entry = await repo.createRawEntry('one');
    final day = DateTime(2026, 10, 25);
    final takenAt = DateTime.utc(2026, 10, 25, 8);
    final id = await repo.logDose(
      medicationId: ids.med,
      regimenId: regimenId,
      date: day,
      takenAt: takenAt,
      plannedAmount: 1,
      amount: 1,
      unit: 'tablet',
      status: 'taken',
      source: 'parsed',
      rawEntryId: entry,
      note: 'with food',
    );

    await repo.updateDose(id: id, amount: const Value(0.5), status: const Value('partial'));

    final row = (await repo.watchDosesOn(day).first).single;
    expect(row.amount, 0.5);
    expect(row.status, 'partial');
    expect(row.regimenId, regimenId);
    expect(row.rawEntryId, entry);
    expect(row.takenAt?.toUtc(), takenAt);
    expect(row.plannedAmount, 1);
    expect(row.note, 'with food');
    expect(row.source, 'parsed');

    // an explicit null clears the link
    await repo.updateDose(id: id, rawEntryId: const Value(null));
    expect((await repo.watchDosesOn(day).first).single.rawEntryId, isNull);
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
      amount: const Value(0.5),
      plannedAmount: const Value(1),
      status: const Value('partial'),
      source: const Value('manual'),
      note: const Value('half'),
    );
    doses = await repo.watchDosesOn(day).first;
    expect(doses.single.amount, 0.5);
    expect(doses.single.status, 'partial');
    expect(doses.single.note, 'half');

    await repo.deleteDose(id);
    expect(await repo.watchDosesOn(day).first, isEmpty);
  });

  test('watchDosesOfEntry and watchDosesBetween select the right doses', () async {
    final ids = await medAndSlot();
    final entry = await repo.createRawEntry('took metformin');
    await dose(ids.med, DateTime(2026, 10, 20), rawEntryId: entry);
    await dose(ids.med, DateTime(2026, 10, 22));
    await dose(ids.med, DateTime(2026, 10, 26));

    expect(await repo.watchDosesOfEntry(entry).first, hasLength(1));
    expect(await repo.watchDosesOfEntry('other').first, isEmpty);
    final range = await repo
        .watchDosesBetween(DateTime(2026, 10, 20), DateTime(2026, 10, 25))
        .first;
    expect(range.map((d) => d.date), [DateTime.utc(2026, 10, 20), DateTime.utc(2026, 10, 22)]);
  });

  test('watchParseResultFor is null until the server result arrives', () async {
    final entry = await repo.createRawEntry('some text');
    expect(await repo.watchParseResultFor(entry).first, isNull);

    await db
        .into(db.parseResultTable)
        .insert(
          ParseResultTableCompanion.insert(
            id: 'p1',
            rawEntryId: entry,
            model: 'm',
            toolCalls: '[]',
            question: 'Which one?',
            proposal: const Value({'type': 'add_medication'}),
            inputTokens: 1,
            outputTokens: 1,
            error: '',
            created: DateTime.utc(2026, 10, 25),
          ),
        );
    final result = await repo.watchParseResultFor(entry).first;
    expect(result!.question, 'Which one?');
    expect(result.proposal, {'type': 'add_medication'});
    expect(await repo.watchParseResultFor('other').first, isNull);
  });

  test('watchRawEntriesSince lists recent entries oldest first', () async {
    await repo.createRawEntry('a');
    await repo.createRawEntry('b');
    final entries = await repo
        .watchRawEntriesSince(DateTime.now().subtract(const Duration(days: 1)))
        .first;
    expect(entries.map((e) => e.text), ['a', 'b']);
    expect(
      await repo.watchRawEntriesSince(DateTime.now().add(const Duration(days: 2))).first,
      isEmpty,
    );
  });

  test('watchRegimenBetween returns regimens in force on any day of the range', () async {
    final ids = await medAndSlot();
    Future<String> regimen(DateTime start, DateTime? end) => repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: start,
      endDate: end,
    );
    await regimen(DateTime(2026, 1, 1), DateTime(2026, 10, 10));
    final endsInside = await regimen(DateTime(2026, 1, 1), DateTime(2026, 10, 19));
    final open = await regimen(DateTime(2026, 1, 1), null);
    await regimen(DateTime(2026, 10, 26), DateTime(2026, 12, 31));

    final found = await repo
        .watchRegimenBetween(DateTime(2026, 10, 18), DateTime(2026, 10, 24))
        .first;
    expect(found.map((r) => r.id).toSet(), {endsInside, open});
  });

  test('logRestTaken logs only the unlogged items of the slot, linked to the entry', () async {
    final ids = await medAndSlot();
    final other = await repo.saveMedication(name: 'Vitamin D', unit: 'IU');
    final r1 = await repo.saveRegimen(
      medicationId: ids.med,
      slotId: ids.slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 1, 1),
    );
    await repo.saveRegimen(
      medicationId: other,
      slotId: ids.slot,
      amount: 2,
      unit: 'drop',
      startDate: DateTime(2026, 1, 1),
    );
    final day = DateTime(2026, 10, 24);
    await repo.logDose(
      medicationId: ids.med,
      regimenId: r1,
      date: day,
      amount: 1,
      unit: 'tablet',
      status: 'skipped',
      source: 'manual',
    );
    final entry = await repo.createRawEntry('rest taken');

    await repo.logRestTaken(
      slotId: ids.slot,
      date: day,
      now: DateTime(2026, 10, 25, 9),
      rawEntryId: entry,
    );
    final doses = await repo.watchDosesOn(day).first;
    expect(doses, hasLength(2));
    final added = doses.singleWhere((d) => d.medicationId == other);
    expect(
      [added.status, added.source, added.amount, added.plannedAmount],
      [
        'taken',
        'one_tap',
        2,
        2,
      ],
    );
    expect(added.rawEntryId, entry);
    expect(doses.singleWhere((d) => d.medicationId == ids.med).status, 'skipped');

    await repo.logRestTaken(slotId: 'unknown', date: day, now: DateTime(2026, 10, 25));
    expect(await repo.watchDosesOn(day).first, hasLength(2));
  });
}
