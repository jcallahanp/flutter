import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/database/powersync/database.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/screens/today_screen.dart';
import 'package:wger/l10n/generated/app_localizations.dart';
import 'package:wger/l10n/localizations_delegates.dart';

import '../../helpers/in_memory_drift.dart';

void main() {
  late DriftPowersyncDatabase db;
  late DoseRepository repo;
  final now = DateTime(2026, 10, 25, 12, 0);

  setUp(() async {
    db = await openTestDatabase();
    repo = DoseRepository(db, detectTimezone: () async => 'Europe/Berlin');
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [doseRepositoryProvider.overrideWithValue(repo)],
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
}
