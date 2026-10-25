import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/widgets/entry_card.dart';
import 'package:wger/l10n/generated/app_localizations.dart';
import 'package:wger/l10n/localizations_delegates.dart';

import '../../helpers/in_memory_drift.dart';

void main() {
  late DriftPowersyncDatabase db;
  late DoseRepository repo;
  final now = DateTime(2026, 10, 25, 12);

  setUp(() async {
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
  });

  Future<RawEntry> entryOf(String id) => repo
      .watchRawEntriesSince(DateTime(2000))
      .first
      .then(
        (l) => l.firstWhere((e) => e.id == id),
      );

  Future<void> setState(String id, String state) => (db.update(
    db.rawEntryTable,
  )..where((t) => t.id.equals(id))).write(RawEntryTableCompanion(state: Value(state)));

  Future<void> parseResult(
    String entryId, {
    String question = '',
    Map<String, dynamic>? proposal,
  }) => db
      .into(db.parseResultTable)
      .insert(
        ParseResultTableCompanion.insert(
          id: 'p-$entryId',
          rawEntryId: entryId,
          model: 'm',
          toolCalls: '[]',
          question: question,
          proposal: Value(proposal),
          inputTokens: 1,
          outputTokens: 1,
          error: '',
          created: DateTime.utc(2026, 10, 25),
        ),
      );

  Future<void> pump(WidgetTester tester, String entryId, {List<Medication>? meds}) async {
    final entry = (await tester.runAsync(() => entryOf(entryId)))!;
    final all = (await tester.runAsync(() => repo.watchRawEntriesSince(DateTime(2000)).first))!;
    final repliesOf = <String, List<RawEntry>>{};
    for (final e in all) {
      if (e.parentId != null) {
        (repliesOf[e.parentId!] ??= []).add(e);
      }
    }
    final slots = (await tester.runAsync(() => repo.watchSlots().first))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [doseRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: EntryCard(
                entry: entry,
                repliesOf: repliesOf,
                slots: slots,
                medications: meds ?? const [],
                now: now,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  }

  Future<({String slot, String a, String b, String ra, String rb})> seedRoutine() async {
    final slot = await repo.saveSlot(
      name: 'Evening',
      usualTime: const TimeOfDay(hour: 21, minute: 0),
    );
    final a = await repo.saveMedication(name: 'Metformin', unit: 'mg');
    final b = await repo.saveMedication(name: 'Vitamin D', unit: 'IU');
    Future<String> reg(String med) => repo.saveRegimen(
      medicationId: med,
      slotId: slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 1, 1),
    );
    return (slot: slot, a: a, b: b, ra: await reg(a), rb: await reg(b));
  }

  testWidgets('shows the question, the proposal button and a reply box', (tester) async {
    late String id;
    await tester.runAsync(() async {
      final ids = await seedRoutine();
      id = await repo.createRawEntry('took my evening pills');
      await setState(id, 'needs_answer');
      await parseResult(
        id,
        question: 'Did you take the rest?',
        proposal: {'type': 'mark_rest_taken', 'slot_id': ids.slot, 'date': '2026-10-24'},
      );
    });
    await pump(tester, id);
    expect(find.text('Mark the rest of Evening (yesterday) as taken'), findsOneWidget);
    expect(find.text('took my evening pills'), findsOneWidget);
    expect(find.text('Did you take the rest?'), findsOneWidget);
    expect(find.byKey(const Key('entry-mark-rest-taken')), findsOneWidget);
    expect(find.byKey(const Key('entry-reply-field')), findsOneWidget);
    expect(find.byKey(const Key('entry-add-medication')), findsNothing);
    await finish(tester);
  });

  testWidgets('shows the add_medication proposal button and sends the exact reply', (tester) async {
    late String id;
    await tester.runAsync(() async {
      id = await repo.createRawEntry('took ibuprofen');
      await setState(id, 'needs_answer');
      await parseResult(
        id,
        question: 'Add Ibuprofen?',
        proposal: {'type': 'add_medication', 'name': 'Ibuprofen'},
      );
    });
    await pump(tester, id);
    expect(find.byKey(const Key('entry-mark-rest-taken')), findsNothing);
    await tester.tap(find.byKey(const Key('entry-add-medication')));
    await settle(tester);

    final all = (await tester.runAsync(() => repo.watchRawEntriesSince(DateTime(2000)).first))!;
    final reply = all.singleWhere((e) => e.parentId == id);
    expect(reply.text, 'yes, add it as an as-needed med');
    await finish(tester);
  });

  testWidgets('a typed answer is stored as a reply to the entry', (tester) async {
    late String id;
    await tester.runAsync(() async {
      id = await repo.createRawEntry('took pills');
      await setState(id, 'needs_answer');
      await parseResult(id, question: 'Which pills?');
    });
    await pump(tester, id);
    await tester.enterText(find.byKey(const Key('entry-reply-field')), '  the white ones ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('entry-reply-send')));
    await settle(tester);

    final all = (await tester.runAsync(() => repo.watchRawEntriesSince(DateTime(2000)).first))!;
    final reply = all.singleWhere((e) => e.parentId == id);
    expect(reply.text, 'the white ones');
    await finish(tester);
  });

  testWidgets('mark the rest taken logs only the unlogged items for the slot and date', (
    tester,
  ) async {
    late String id;
    late ({String slot, String a, String b, String ra, String rb}) ids;
    await tester.runAsync(() async {
      ids = await seedRoutine();
      await repo.logDose(
        medicationId: ids.a,
        regimenId: ids.ra,
        date: DateTime(2026, 10, 24),
        amount: 1,
        unit: 'tablet',
        status: 'taken',
        source: 'parsed',
      );
      id = await repo.createRawEntry('took metformin yesterday evening');
      await setState(id, 'needs_answer');
      await parseResult(
        id,
        question: 'Mark the rest as taken?',
        proposal: {'type': 'mark_rest_taken', 'slot_id': ids.slot, 'date': '2026-10-24'},
      );
    });
    await pump(tester, id);
    await tester.tap(find.byKey(const Key('entry-mark-rest-taken')));
    await settle(tester);

    final doses = (await tester.runAsync(() => repo.watchDosesOn(DateTime(2026, 10, 24)).first))!;
    expect(doses, hasLength(2));
    final added = doses.singleWhere((d) => d.medicationId == ids.b);
    expect(added.rawEntryId, id);
    expect(added.status, 'taken');
    await finish(tester);
  });

  testWidgets('Undo removes the doses of the entry after a confirm', (tester) async {
    late String id;
    late String med;
    await tester.runAsync(() async {
      med = await repo.saveMedication(name: 'Metformin', unit: 'mg');
      id = await repo.createRawEntry('took metformin');
      await setState(id, 'parsed');
      await repo.logDose(
        medicationId: med,
        date: DateTime(2026, 10, 25),
        amount: 500,
        unit: 'mg',
        status: 'taken',
        source: 'parsed',
        rawEntryId: id,
      );
      await repo.logDose(
        medicationId: med,
        date: DateTime(2026, 10, 24),
        amount: 500,
        unit: 'mg',
        status: 'taken',
        source: 'one_tap',
      );
    });
    final meds = (await tester.runAsync(() => repo.watchMedications().first))!;
    await pump(tester, id, meds: meds);
    expect(find.text('Metformin'), findsOneWidget);

    await tester.tap(find.byKey(const Key('entry-undo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entry-undo-confirm')));
    await settle(tester);

    expect(await tester.runAsync(() => repo.watchDosesOfEntry(id).first), isEmpty);
    // the dose of another source stays
    expect(
      await tester.runAsync(() => repo.watchDosesOn(DateTime(2026, 10, 24)).first),
      hasLength(1),
    );
    expect(find.text('Metformin'), findsNothing);
    await finish(tester);
  });

  testWidgets('states read as one plain sentence each', (tester) async {
    final expected = {
      'pending': 'Waiting to be read',
      'no_key': 'The server has no parser key yet, so your entry is kept as it is.',
      'over_limit':
          'The daily reading limit was reached, so this entry was not read. Your text is kept.',
      'failed': 'This entry could not be read; your text is kept.',
    };
    for (final MapEntry(key: state, value: line) in expected.entries) {
      late String id;
      await tester.runAsync(() async {
        id = await repo.createRawEntry('text $state');
        await setState(id, state);
      });
      await pump(tester, id);
      expect(find.text(line), findsOneWidget, reason: state);
    }
    await finish(tester);
  });

  testWidgets('a proposal date outside the last 7 days up to today shows no button', (
    tester,
  ) async {
    for (final date in ['2026-10-26', '2026-10-17', '2026-10-10', 'garbage', '']) {
      late String id;
      await tester.runAsync(() async {
        final ids = await repo.watchSlots().first.then((l) => l.isEmpty ? null : l.first.id);
        final slot =
            ids ??
            await repo.saveSlot(name: 'Evening', usualTime: const TimeOfDay(hour: 21, minute: 0));
        id = await repo.createRawEntry('entry $date');
        await setState(id, 'needs_answer');
        await parseResult(
          id,
          question: 'Mark the rest?',
          proposal: {'type': 'mark_rest_taken', 'slot_id': slot, 'date': date},
        );
      });
      await pump(tester, id);
      expect(find.text('Mark the rest?'), findsOneWidget, reason: date);
      expect(find.byKey(const Key('entry-mark-rest-taken')), findsNothing, reason: date);
    }
    // the edges are in: seven days back and today
    for (final date in ['2026-10-18', '2026-10-25']) {
      late String id;
      await tester.runAsync(() async {
        final slot = (await repo.watchSlots().first).first.id;
        id = await repo.createRawEntry('edge $date');
        await setState(id, 'needs_answer');
        await parseResult(
          id,
          question: 'Edge?',
          proposal: {'type': 'mark_rest_taken', 'slot_id': slot, 'date': date},
        );
      });
      await pump(tester, id);
      expect(find.byKey(const Key('entry-mark-rest-taken')), findsOneWidget, reason: date);
    }
    final doses = await tester.runAsync(() => repo.watchDosesBetween(DateTime(2026), now).first);
    expect(doses, isEmpty);
    await finish(tester);
  });

  testWidgets('the proposal goes away once the rest is marked taken', (tester) async {
    late String id;
    await tester.runAsync(() async {
      final ids = await seedRoutine();
      id = await repo.createRawEntry('took metformin');
      await setState(id, 'needs_answer');
      await parseResult(
        id,
        question: 'Mark the rest?',
        proposal: {'type': 'mark_rest_taken', 'slot_id': ids.slot, 'date': '2026-10-25'},
      );
    });
    await pump(tester, id);
    await tester.tap(find.byKey(const Key('entry-mark-rest-taken')));
    await settle(tester);
    expect(find.byKey(const Key('entry-mark-rest-taken')), findsNothing);
    await finish(tester);
  });

  testWidgets('replies nest to any depth and only the last open question has a reply box', (
    tester,
  ) async {
    late String root;
    await tester.runAsync(() async {
      root = await repo.createRawEntry('took pills');
      await setState(root, 'needs_answer');
      await parseResult(root, question: 'Which pills?');
      final first = await repo.createRawEntry('white ones', parentId: root);
      await setState(first, 'needs_answer');
      await parseResult(first, question: 'How many?');
      final second = await repo.createRawEntry('two', parentId: first);
      await setState(second, 'needs_answer');
      await parseResult(second, question: 'Since when?');
    });
    await pump(tester, root);
    expect(find.text('took pills'), findsOneWidget);
    expect(find.text('white ones'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(find.text('Which pills?'), findsNothing);
    expect(find.text('How many?'), findsNothing);
    expect(find.text('Since when?'), findsOneWidget);
    expect(find.byKey(const Key('entry-reply-field')), findsOneWidget);
    await finish(tester);
  });
}
