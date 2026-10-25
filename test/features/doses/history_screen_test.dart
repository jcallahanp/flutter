import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/screens/history_screen.dart';
import 'package:wger/l10n/generated/app_localizations.dart';
import 'package:wger/l10n/localizations_delegates.dart';

import '../../helpers/in_memory_drift.dart';

void main() {
  late DriftPowersyncDatabase db;
  late DoseRepository repo;
  final now = DateTime(2026, 10, 25, 12);
  late String doseId;

  setUp(() async {
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      final med = await repo.saveMedication(name: 'Metformin', unit: 'mg');
      doseId = await repo.logDose(
        medicationId: med,
        date: DateTime(2026, 10, 25),
        plannedAmount: 500,
        amount: 500,
        unit: 'mg',
        status: 'taken',
        source: 'one_tap',
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [doseRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HistoryScreen(clock: () => now),
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

  Future<dynamic> dose(WidgetTester tester) async =>
      (await tester.runAsync(() => repo.watchDosesOn(now).first))!.single;

  testWidgets('lists the doses of today by default', (tester) async {
    await pump(tester);
    expect(find.text('Metformin'), findsOneWidget);
    expect(find.text('Taken · 500 mg'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('edit changes status and amount and marks the source manual', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(Key('history-dose-$doseId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-status-partial')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('history-amount')), '250');
    await tester.tap(find.byKey(const Key('history-save')));
    await settle(tester);

    final d = await dose(tester);
    expect(d.status, 'partial');
    expect(d.amount, 250);
    expect(d.source, 'manual');
    expect(d.plannedAmount, 500);
    expect(find.text('Partial · 250 mg'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('refuses a negative amount and a non-zero amount for missed', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(Key('history-dose-$doseId')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('history-amount')), '-1');
    await tester.tap(find.byKey(const Key('history-save')));
    await tester.pump();
    expect(find.text('Enter 0 or more'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-status-missed')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('history-amount')), '2');
    await tester.tap(find.byKey(const Key('history-save')));
    await tester.pump();
    expect(find.text('Must be 0 for skipped or missed'), findsOneWidget);

    expect((await dose(tester)).status, 'taken');
    await finish(tester);
  });

  testWidgets('choosing skipped sets the amount to 0', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(Key('history-dose-$doseId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-status-skipped')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('history-save')));
    await settle(tester);
    final d = await dose(tester);
    expect(d.status, 'skipped');
    expect(d.amount, 0);
    await finish(tester);
  });

  testWidgets('delete asks first and then removes the dose', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(Key('history-delete-$doseId')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this dose?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => repo.watchDosesOn(now).first), hasLength(1));

    await tester.tap(find.byKey(Key('history-delete-$doseId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-delete-confirm')));
    await settle(tester);
    expect(await tester.runAsync(() => repo.watchDosesOn(now).first), isEmpty);
    expect(find.text('No doses logged on this day'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('taken needs an amount above 0 and sets the time when missing', (tester) async {
    await pump(tester);
    // a missed dose, edited to taken
    await tester.runAsync(
      () => repo.updateDose(
        id: doseId,
        status: const Value('missed'),
        amount: const Value(0),
        takenAt: const Value(null),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('history-dose-$doseId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('history-status-taken')));
    await tester.pump();
    // starts from the planned amount
    expect(
      tester.widget<TextField>(find.byKey(const Key('history-amount'))).controller!.text,
      '500',
    );
    await tester.enterText(find.byKey(const Key('history-amount')), '0');
    await tester.tap(find.byKey(const Key('history-save')));
    await tester.pump();
    expect(find.text('Must be above 0 for taken or partial'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('history-amount')), '500');
    await tester.tap(find.byKey(const Key('history-save')));
    await settle(tester);
    final d = await dose(tester);
    expect(d.status, 'taken');
    expect(d.takenAt, isNotNull);
    await finish(tester);
  });
}
