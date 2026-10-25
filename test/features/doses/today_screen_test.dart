import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/screens/today_screen.dart';
import 'package:wger/features/doses/widgets/entry_card.dart';
import 'package:wger/features/doses/widgets/log_box.dart';
import 'package:wger/features/doses/widgets/missed_prompt.dart';
import 'package:wger/l10n/generated/app_localizations.dart';
import 'package:wger/l10n/localizations_delegates.dart';

import '../../helpers/in_memory_drift.dart';
import 'fakes.dart';

void main() {
  late DriftPowersyncDatabase db;
  late DoseRepository repo;
  var now = DateTime(2026, 10, 25, 12, 0);
  var speech = FakeSpeech();
  var dismissals = FakeDismissals();

  setUp(() async {
    now = DateTime(2026, 10, 25, 12, 0);
    speech = FakeSpeech();
    dismissals = FakeDismissals();
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          doseRepositoryProvider.overrideWithValue(repo),
          speechInputProvider.overrideWithValue(speech),
          missedDismissalsProvider.overrideWithValue(dismissals),
        ],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: TodayScreen(clock: () => now),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  }

  testWidgets('shows the empty state without slots', (tester) async {
    await pump(tester);
    expect(find.text('No slots in your routine yet.'), findsOneWidget);
    expect(find.byKey(const Key('empty-open-routine')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Took as planned logs the unlogged items and disables the button', (tester) async {
    await tester.runAsync(() async {
      final slot = await repo.saveSlot(
        name: 'Morning',
        usualTime: const TimeOfDay(hour: 8, minute: 0),
      );
      for (final name in ['Metformin', 'Vitamin D']) {
        final med = await repo.saveMedication(name: name, unit: 'mg');
        await repo.saveRegimen(
          medicationId: med,
          slotId: slot,
          amount: 1,
          unit: 'tablet',
          startDate: DateTime(2026, 1, 1),
        );
      }
    });
    await pump(tester);

    const key = Key('took-as-planned-Morning');
    expect(tester.widget<FilledButton>(find.byKey(key)).onPressed, isNotNull);
    expect(find.text('Not logged'), findsNWidgets(2));

    await tester.tap(find.byKey(key));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final doses = await tester.runAsync(() => repo.watchDosesOn(now).first);
    expect(doses, hasLength(2));
    expect(doses!.every((d) => d.status == 'taken' && d.source == 'one_tap'), isTrue);
    expect(doses.every((d) => d.takenAt != null && d.plannedAmount == 1), isTrue);
    expect(tester.widget<FilledButton>(find.byKey(key)).onPressed, isNull);
    expect(find.text('Taken'), findsWidgets);
    await finish(tester);
  });

  Future<void> seedEvening() async {
    final slot = await repo.saveSlot(
      name: 'Evening',
      usualTime: const TimeOfDay(hour: 21, minute: 0),
    );
    final med = await repo.saveMedication(name: 'Metformin', unit: 'mg');
    await repo.saveRegimen(
      medicationId: med,
      slotId: slot,
      amount: 1,
      unit: 'tablet',
      startDate: DateTime(2026, 1, 1),
    );
  }

  testWidgets('after midnight the slot is logged for yesterday and says so', (tester) async {
    now = DateTime(2026, 10, 25, 0, 40);
    await tester.runAsync(seedEvening);
    await pump(tester);
    expect(find.text('Yesterday · Evening'), findsOneWidget);

    await tester.tap(find.byKey(const Key('took-as-planned-Evening')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final doses = await tester.runAsync(() => repo.watchDosesOn(DateTime(2026, 10, 24)).first);
    expect(doses, hasLength(1));
    final today = await tester.runAsync(() => repo.watchDosesOn(DateTime(2026, 10, 25)).first);
    expect(today, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('took-as-planned-Evening'))).onPressed,
      isNull,
    );
    await finish(tester);
  });

  testWidgets("lists today's entries as cards with their state", (tester) async {
    await tester.runAsync(() async {
      await seedEvening();
      await repo.createRawEntry('took my pills');
      await repo.createRawEntry('and an aspirin');
    });
    // the entries are stamped with the real clock
    now = DateTime.now();
    await pump(tester);
    expect(find.text('took my pills'), findsOneWidget);
    expect(find.text('and an aspirin'), findsOneWidget);
    expect(find.text('Waiting to be read'), findsNWidgets(2));
    await finish(tester);
  });

  testWidgets('a reply shows under its entry, not as a card of its own', (tester) async {
    await tester.runAsync(() async {
      await seedEvening();
      final parent = await repo.createRawEntry('took pills');
      await repo.createRawEntry('the white ones', parentId: parent);
    });
    now = DateTime.now();
    await pump(tester);
    final replyCard = find.ancestor(
      of: find.text('the white ones'),
      matching: find.byType(EntryCard),
    );
    expect(replyCard, findsNWidgets(2));
    await finish(tester);
  });

  testWidgets('log box sends trimmed text as a raw entry and refuses blank', (tester) async {
    await tester.runAsync(seedEvening);
    now = DateTime.now();
    await pump(tester);
    const send = Key('log-box-send');
    expect(tester.widget<IconButton>(find.byKey(send)).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('log-box-field')), '   ');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(send)).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('log-box-field')), '  took my pills ');
    await tester.pump();
    await tester.tap(find.byKey(send));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final entries = await tester.runAsync(() => repo.watchRawEntriesSince(DateTime(2000)).first);
    expect(entries!.single.text, 'took my pills');
    expect(entries.single.state, 'pending');
    expect(tester.widget<TextField>(find.byKey(const Key('log-box-field'))).controller!.text, '');
    await finish(tester);
  });

  testWidgets('mic asks for nothing on open, inserts recognized words, stops on send', (
    tester,
  ) async {
    await tester.runAsync(seedEvening);
    now = DateTime.now();
    await pump(tester);
    expect(speech.initializeCalls, 0);
    await tester.enterText(find.byKey(const Key('log-box-field')), 'took');
    await tester.tap(find.byKey(const Key('log-box-mic')));
    await tester.pump();
    expect(speech.initializeCalls, 1);
    expect(speech.listening, isTrue);
    speech.onWords!('metformin and a pill');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(const Key('log-box-field'))).controller!.text,
      'took metformin and a pill',
    );
    await tester.tap(find.byKey(const Key('log-box-send')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(speech.listening, isFalse);
    // a late final result after stop does not refill the cleared box
    speech.onWords!('took metformin and a pill again');
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('log-box-field'))).controller!.text, '');
    await finish(tester);
  });

  testWidgets('mic denied hides the button and says why in one line', (tester) async {
    speech = FakeSpeech(available: false);
    await tester.runAsync(seedEvening);
    await pump(tester);
    expect(find.byKey(const Key('log-box-mic')), findsOneWidget);
    await tester.tap(find.byKey(const Key('log-box-mic')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('log-box-mic')), findsNothing);
    expect(find.text('Dictation is not available or not allowed on this device.'), findsOneWidget);
    expect(find.byKey(const Key('log-box-send')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('no mic where speech is not plausible', (tester) async {
    speech = FakeSpeech(plausible: false);
    await tester.runAsync(seedEvening);
    await pump(tester);
    expect(find.byKey(const Key('log-box-mic')), findsNothing);
    expect(find.byKey(const Key('log-box-mic-unavailable')), findsNothing);
    await finish(tester);
  });

  testWidgets('an earlier entry with a question still shows after midnight', (tester) async {
    late String id;
    await tester.runAsync(() async {
      await seedEvening();
      id = await repo.createRawEntry('took pills at 23:50');
      await (db.update(db.rawEntryTable)..where((t) => t.id.equals(id))).write(
        RawEntryTableCompanion(
          state: const Value('needs_answer'),
          createdOnDevice: Value(DateTime(2026, 10, 24, 23, 50).toUtc()),
        ),
      );
      final old = await repo.createRawEntry('parsed long ago');
      await (db.update(db.rawEntryTable)..where((t) => t.id.equals(old))).write(
        RawEntryTableCompanion(
          state: const Value('parsed'),
          createdOnDevice: Value(DateTime(2026, 10, 24, 20).toUtc()),
        ),
      );
    });
    now = DateTime(2026, 10, 25, 0, 10);
    await pump(tester);
    expect(find.text('took pills at 23:50'), findsOneWidget);
    expect(find.text('parsed long ago'), findsNothing);
    await finish(tester);
  });

  testWidgets('an answered question leaves Today after its day, an open reply keeps it', (
    tester,
  ) async {
    Future<void> stamp(String id, String state, DateTime at) =>
        (db.update(db.rawEntryTable)..where((t) => t.id.equals(id))).write(
          RawEntryTableCompanion(state: Value(state), createdOnDevice: Value(at.toUtc())),
        );
    await tester.runAsync(() async {
      await seedEvening();
      final answered = await repo.createRawEntry('answered question');
      await stamp(answered, 'needs_answer', DateTime(2026, 10, 24, 20));
      final reply = await repo.createRawEntry('my answer', parentId: answered);
      await stamp(reply, 'parsed', DateTime(2026, 10, 24, 20, 5));

      final carried = await repo.createRawEntry('carried question');
      await stamp(carried, 'needs_answer', DateTime(2026, 10, 24, 21));
      final reply2 = await repo.createRawEntry('still unread answer', parentId: carried);
      await stamp(reply2, 'pending', DateTime(2026, 10, 24, 21, 5));
    });
    now = DateTime(2026, 10, 25, 10);
    await pump(tester);
    expect(find.text('answered question'), findsNothing);
    expect(find.text('carried question'), findsOneWidget);
    expect(find.text('still unread answer'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('missed prompt shows when the stored choice cannot be read', (tester) async {
    dismissals.throwOnRead = true;
    await tester.runAsync(() async {
      await seedEvening();
      final meds = await repo.watchMedications().first;
      final regimen = (await repo.watchOpenRegimens().first).single;
      for (var d = 18; d <= 23; d++) {
        await repo.logDose(
          medicationId: meds.single.id,
          regimenId: regimen.id,
          date: DateTime(2026, 10, d),
          amount: 1,
          unit: 'tablet',
          status: 'taken',
          source: 'manual',
        );
      }
    });
    await pump(tester);
    expect(find.text('No Evening meds logged yesterday. Mark as missed?'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('missed prompt: Yes logs missed doses, oldest day first', (tester) async {
    await tester.runAsync(() async {
      await seedEvening();
      // a dose on the 18th to 23rd keeps those days quiet, the 24th is open
      final meds = await repo.watchMedications().first;
      final regimen = (await repo.watchOpenRegimens().first).single;
      for (var d = 18; d <= 23; d++) {
        await repo.logDose(
          medicationId: meds.single.id,
          regimenId: regimen.id,
          date: DateTime(2026, 10, d),
          amount: 1,
          unit: 'tablet',
          status: 'taken',
          source: 'manual',
        );
      }
    });
    await pump(tester);
    expect(find.text('No Evening meds logged yesterday. Mark as missed?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('missed-yes-Evening-2026-10-24')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final doses = (await tester.runAsync(() => repo.watchDosesOn(DateTime(2026, 10, 24)).first))!;
    expect(doses, hasLength(1));
    expect(doses.single.status, 'missed');
    expect(doses.single.amount, 0);
    expect(doses.single.source, 'missed_prompt');
    expect(doses.single.plannedAmount, 1);
    expect(find.textContaining('Mark as missed?'), findsNothing);
    await finish(tester);
  });

  testWidgets('missed prompt: Not now hides it for that slot and day on this device', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seedEvening();
      final meds = await repo.watchMedications().first;
      final regimen = (await repo.watchOpenRegimens().first).single;
      for (var d = 18; d <= 23; d++) {
        await repo.logDose(
          medicationId: meds.single.id,
          regimenId: regimen.id,
          date: DateTime(2026, 10, d),
          amount: 1,
          unit: 'tablet',
          status: 'taken',
          source: 'manual',
        );
      }
    });
    await pump(tester);
    await tester.tap(find.byKey(const Key('missed-not-now-Evening-2026-10-24')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mark as missed?'), findsNothing);
    expect(dismissals.keys, hasLength(1));
    expect(dismissals.keys.single, startsWith('doses.missed.dismissed.'));
    expect(dismissals.keys.single, endsWith('.2026-10-24'));
    expect(
      await tester.runAsync(() => repo.watchDosesOn(DateTime(2026, 10, 24)).first),
      isEmpty,
    );
    await finish(tester);

    // remembered on a fresh screen
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
    await tester.runAsync(() async {
      await seedEvening();
      final meds = await repo.watchMedications().first;
      final regimen = (await repo.watchOpenRegimens().first).single;
      for (var d = 18; d <= 23; d++) {
        await repo.logDose(
          medicationId: meds.single.id,
          regimenId: regimen.id,
          date: DateTime(2026, 10, d),
          amount: 1,
          unit: 'tablet',
          status: 'taken',
          source: 'manual',
        );
      }
      // the slot id differs on the new database, so reuse the stored key
      dismissals.keys
        ..clear()
        ..add(missedDismissKey((await repo.watchSlots().first).single.id, DateTime(2026, 10, 24)));
    });
    await pump(tester);
    expect(find.textContaining('Mark as missed?'), findsNothing);
    await finish(tester);
  });
}
