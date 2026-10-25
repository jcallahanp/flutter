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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/core/consts.dart';
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/screens/routine_screen.dart';
import 'package:wger/l10n/generated/app_localizations.dart';
import 'package:wger/l10n/localizations_delegates.dart';

import '../../helpers/in_memory_drift.dart';

void main() {
  late DriftPowersyncDatabase db;
  late DoseRepository repo;

  setUp(() async {
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
  });

  Widget screen() => ProviderScope(
    overrides: [doseRepositoryProvider.overrideWithValue(repo)],
    child: const MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RoutineScreen(),
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
  }

  // Unmount first so drift's stream timers are gone before the db closes
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
  }

  Finder field(String key) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField));

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key(SUBMIT_BUTTON_KEY_NAME)));
    await tester.pumpAndSettle();
  }

  testWidgets('adds a slot and a medication in it, listed under the slot', (tester) async {
    await tester.runAsync(() async {});
    await pump(tester);

    await tester.tap(find.text('Add slot'));
    await tester.pumpAndSettle();
    await tester.enterText(field('slotNameInput'), 'Morning');
    await tester.enterText(field('slotTimeInput'), '07:30');
    await save(tester);
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text('07:30'), findsOneWidget);

    await tester.tap(find.text('Add medication'));
    await tester.pumpAndSettle();
    await tester.enterText(field('medNameInput'), 'Metformin');
    await tester.enterText(field('medStrengthInput'), '500');
    await tester.enterText(field('medUnitInput'), 'mg');
    // Medications start with "No slot"; choose Morning
    await tester.tap(find.byKey(const Key('slotInput')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Morning').last);
    await tester.pumpAndSettle();
    await tester.enterText(field('medAmountInput'), '0');
    await tester.enterText(field('regimenUnitInput'), 'tablet');
    await save(tester);
    expect(find.text('Please enter a valid number'), findsOneWidget);
    await tester.enterText(field('medAmountInput'), '1');
    await tester.enterText(field('regimenUnitInput'), 'tablet');
    await save(tester);

    // The regimen row sits under Morning
    expect(find.byKey(const Key('slot-Morning')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('slot-Morning')),
        matching: find.textContaining('Metformin'),
      ),
      findsOneWidget,
    );
    final regimens = await tester.runAsync(() => repo.watchOpenRegimens().first);
    expect(regimens!.single.amount, 1);
    expect(regimens.single.unit, 'tablet');
    expect(regimens.single.schedule, 'daily');
    await finish(tester);
  });

  testWidgets('as needed meds are in their own section, one-off meds nowhere', (tester) async {
    await tester.runAsync(() async {
      final slot = await repo.saveSlot(
        name: 'Morning',
        usualTime: const TimeOfDay(hour: 7, minute: 30),
      );
      final once = await repo.saveMedication(name: 'Amoxicillin', unit: 'mg', kind: 'one_off');
      await repo.saveRegimen(
        medicationId: once,
        slotId: slot,
        amount: 1,
        unit: 'tablet',
        startDate: DateTime.now(),
      );
      await repo.saveMedication(name: 'Ibuprofen', unit: 'mg', kind: 'as_needed');
    });
    await pump(tester);

    expect(find.text('As needed'), findsOneWidget);
    expect(find.textContaining('Ibuprofen'), findsOneWidget);
    expect(find.textContaining('Amoxicillin'), findsNothing);
    await finish(tester);
  });

  testWidgets('ending a regimen asks first, removes it and keeps past doses', (tester) async {
    late String med;
    await tester.runAsync(() async {
      final slot = await repo.saveSlot(
        name: 'Morning',
        usualTime: const TimeOfDay(hour: 7, minute: 30),
      );
      med = await repo.saveMedication(name: 'Metformin', strength: 500, unit: 'mg');
      final regimen = await repo.saveRegimen(
        medicationId: med,
        slotId: slot,
        amount: 1,
        unit: 'tablet',
        startDate: DateTime.now().subtract(const Duration(days: 5)),
      );
      await repo.logDose(
        medicationId: med,
        regimenId: regimen,
        date: DateTime.now().subtract(const Duration(days: 2)),
        amount: 1,
        unit: 'tablet',
        status: 'taken',
        source: 'one_tap',
      );
    });
    await pump(tester);

    await tester.tap(find.byKey(const Key('end-regimen-Metformin')));
    await tester.pumpAndSettle();
    expect(find.text('End this entry?'), findsOneWidget);

    // Cancelling changes nothing
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('end-regimen-Metformin')), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-regimen-Metformin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('end-regimen-Metformin')), findsNothing);
    final past = await tester.runAsync(
      () => repo.watchDosesOn(DateTime.now().subtract(const Duration(days: 2))).first,
    );
    expect(past, hasLength(1));
    final open = await tester.runAsync(() => repo.watchOpenRegimens().first);
    expect(open, isEmpty);
    final today = await tester.runAsync(() => repo.watchRegimenOn(DateTime.now()).first);
    expect(today, isEmpty);
    await finish(tester);
  });

  testWidgets('deactivating a medication asks first and ends its regimens', (tester) async {
    await tester.runAsync(() async {
      final slot = await repo.saveSlot(
        name: 'Morning',
        usualTime: const TimeOfDay(hour: 7, minute: 30),
      );
      final med = await repo.saveMedication(name: 'Metformin', strength: 500, unit: 'mg');
      await repo.saveRegimen(
        medicationId: med,
        slotId: slot,
        amount: 1,
        unit: 'tablet',
        startDate: DateTime.now(),
      );
    });
    await pump(tester);

    await tester.tap(find.byKey(const Key('deactivate-Metformin')));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate this medication?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('end-regimen-Metformin')), findsNothing);
    expect(find.text('Inactive'), findsOneWidget);
    final meds = await tester.runAsync(() => repo.watchMedications().first);
    expect(meds!.single.active, isFalse);
    final today = await tester.runAsync(() => repo.watchRegimenOn(DateTime.now()).first);
    expect(today, isEmpty);
    await finish(tester);
  });

  testWidgets('a slot time that is not HH:MM is refused', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add slot'));
    await tester.pumpAndSettle();
    await tester.enterText(field('slotNameInput'), 'Morning');
    await tester.enterText(field('slotTimeInput'), '7.30');
    await save(tester);
    expect(find.text('Enter a time as HH:MM'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a duplicate slot name is refused', (tester) async {
    await tester.runAsync(
      () => repo.saveSlot(name: 'Morning', usualTime: const TimeOfDay(hour: 7, minute: 30)),
    );
    await pump(tester);
    await tester.tap(find.text('Add slot'));
    await tester.pumpAndSettle();
    await tester.enterText(field('slotNameInput'), ' Morning ');
    await tester.enterText(field('slotTimeInput'), '08:00');
    await save(tester);
    expect(find.text('A slot with this name already exists'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('inactive as needed meds stay listed; leaving routine ends regimens', (tester) async {
    await tester.runAsync(() async {
      await repo.saveMedication(name: 'Ibuprofen', unit: 'mg', kind: 'as_needed', active: false);
      final slot = await repo.saveSlot(
        name: 'Morning',
        usualTime: const TimeOfDay(hour: 7, minute: 30),
      );
      final med = await repo.saveMedication(name: 'Metformin', unit: 'mg');
      await repo.saveRegimen(
        medicationId: med,
        slotId: slot,
        amount: 1,
        unit: 'tablet',
        startDate: DateTime.now().subtract(const Duration(days: 3)),
      );
    });
    await pump(tester);
    expect(find.text('Ibuprofen'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-medication-Metformin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('medKindInput')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('As needed').last);
    await tester.pumpAndSettle();
    await save(tester);

    final today = await tester.runAsync(() => repo.watchRegimenOn(DateTime.now()).first);
    expect(today, isEmpty);
    await finish(tester);
  });
}
