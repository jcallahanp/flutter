import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:wger/features/doses/logic/one_tap.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/regimen.dart';

void main() {
  final evening = DoseSlot.fromDb(
    id: 's-eve',
    name: 'Evening',
    usualTime: const TimeOfDay(hour: 21, minute: 0),
    order: 1,
  );

  Medication med(String id, {String kind = 'routine', bool active = true}) => Medication.fromDb(
    id: id,
    name: id,
    unit: 'mg',
    form: '',
    kind: kind,
    active: active,
  );

  Regimen reg(String id, String medId, {DateTime? start, DateTime? end, String slot = 's-eve'}) =>
      Regimen.fromDb(
        id: id,
        medicationId: medId,
        slotId: slot,
        amount: 2,
        unit: 'tablet',
        schedule: 'daily',
        startDate: start ?? DateTime(2026, 1, 1),
        endDate: end,
      );

  DoseLog log(String regimenId, String medId, DateTime date, {String status = 'taken'}) =>
      DoseLog.fromDb(
        id: 'l-$regimenId-$date',
        medicationId: medId,
        regimenId: regimenId,
        date: date,
        amount: 2,
        unit: 'tablet',
        status: status,
        source: 'manual',
        note: '',
      );

  final meds = [med('a'), med('b')];
  final regimen = [reg('r-a', 'a'), reg('r-b', 'b')];
  final today = DateTime(2026, 10, 25);
  final yesterday = DateTime(2026, 10, 24);

  test('one_tap_skips_logged_items', () {
    final drafts = oneTapDrafts(
      slot: evening,
      slotDate: today,
      regimen: regimen,
      medications: meds,
      logged: [log('r-a', 'a', today, status: 'skipped')],
      now: DateTime(2026, 10, 25, 21, 5),
    );
    expect(drafts.map((d) => d.regimenId), ['r-b']);
    final d = drafts.single;
    expect(d.medicationId, 'b');
    expect(d.amount, 2);
    expect(d.plannedAmount, 2);
    expect(d.unit, 'tablet');
    expect(d.status, 'taken');
    expect(d.source, 'one_tap');
    expect(d.date, today);
    expect(d.takenAt, DateTime(2026, 10, 25, 21, 5));
  });

  test('one_tap_uses_slot_date', () {
    final now = DateTime(2026, 10, 25, 0, 40);
    final logged = [log('r-a', 'a', today), log('r-b', 'b', today)];
    // Yesterday evening is still unlogged: it is the current occurrence, even
    // when tonight's is already logged
    final date = defaultSlotDate(
      evening,
      now,
      regimen: regimen,
      medications: meds,
      logged: logged,
    );
    expect(date, yesterday);
    final drafts = oneTapDrafts(
      slot: evening,
      slotDate: date,
      regimen: regimen,
      medications: meds,
      logged: logged,
      now: now,
    );
    expect(drafts, hasLength(2));
    expect(drafts.every((d) => d.date == yesterday), isTrue);
  });

  test('default slot date: yesterday until 04:00 even when logged, today after', () {
    final all = [log('r-a', 'a', yesterday), log('r-b', 'b', yesterday)];
    expect(
      defaultSlotDate(
        evening,
        DateTime(2026, 10, 25, 0, 40),
        regimen: regimen,
        medications: meds,
        logged: all,
      ),
      yesterday,
    );
    // so a second tap at 00:40 adds nothing (tonight's dose is not logged early)
    expect(
      oneTapDrafts(
        slot: evening,
        slotDate: yesterday,
        regimen: regimen,
        medications: meds,
        logged: all,
        now: DateTime(2026, 10, 25, 0, 40),
      ),
      isEmpty,
    );
    expect(
      defaultSlotDate(
        evening,
        DateTime(2026, 10, 25, 4, 0),
        regimen: regimen,
        medications: meds,
        logged: [],
      ),
      today,
    );
  });

  test('default slot date when everything is logged', () {
    final all = [log('r-a', 'a', today), log('r-b', 'b', today)];
    expect(
      defaultSlotDate(
        evening,
        DateTime(2026, 10, 25, 22),
        regimen: regimen,
        medications: meds,
        logged: all,
      ),
      today,
    );
    // Before 04:00, with today's occurrence not yet started: yesterday
    final allBoth = [...all, log('r-a', 'a', yesterday), log('r-b', 'b', yesterday)];
    expect(
      defaultSlotDate(
        evening,
        DateTime(2026, 10, 25, 1),
        regimen: regimen,
        medications: meds,
        logged: allBoth,
      ),
      yesterday,
    );
  });

  test('one_tap_twice_adds_nothing', () {
    final now = DateTime(2026, 10, 25, 21);
    final first = oneTapDrafts(
      slot: evening,
      slotDate: today,
      regimen: regimen,
      medications: meds,
      logged: [],
      now: now,
    );
    expect(first, hasLength(2));
    final saved = [for (final d in first) log(d.regimenId, d.medicationId, d.date)];
    final second = oneTapDrafts(
      slot: evening,
      slotDate: today,
      regimen: regimen,
      medications: meds,
      logged: saved,
      now: now,
    );
    expect(second, isEmpty);
  });

  test('slot items filter: dates, activity, kind, slot', () {
    final items = slotItems(
      slot: evening,
      date: today,
      regimen: [
        reg('ok', 'a'),
        reg('future', 'a', start: DateTime(2026, 10, 26)),
        reg('ended', 'a', end: DateTime(2026, 10, 24)),
        reg('last-day', 'a', end: today),
        reg('inactive', 'c'),
        reg('as-needed', 'd'),
        reg('other-slot', 'a', slot: 's-morning'),
      ],
      medications: [
        med('a'),
        med('c', active: false),
        med('d', kind: 'as_needed'),
      ],
    );
    expect(items.map((r) => r.id), ['ok', 'last-day']);
  });
}
