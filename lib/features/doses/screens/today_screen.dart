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
 * Today: the routine slots with a one-tap "took as planned", and the doses
 * logged today.
 */

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/core/formatting/formatting.dart';
import 'package:wger/core/wide_screen_wrapper.dart';
import 'package:wger/features/doses/logic/missed.dart';
import 'package:wger/features/doses/logic/one_tap.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/screens/history_screen.dart';
import 'package:wger/features/doses/screens/routine_screen.dart';
import 'package:wger/features/doses/widgets/entry_card.dart';
import 'package:wger/features/doses/widgets/log_box.dart';
import 'package:wger/features/doses/widgets/missed_prompt.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

final _slotsProvider = StreamProvider.autoDispose<List<DoseSlot>>(
  (ref) => ref.watch(doseRepositoryProvider).watchSlots(),
);
final _medicationsProvider = StreamProvider.autoDispose<List<Medication>>(
  (ref) => ref.watch(doseRepositoryProvider).watchMedications(),
);
final _regimenOnProvider = StreamProvider.autoDispose.family<List<Regimen>, DateTime>(
  (ref, day) => ref.watch(doseRepositoryProvider).watchRegimenOn(day),
);
final _dosesOnProvider = StreamProvider.autoDispose.family<List<DoseLog>, DateTime>(
  (ref, day) => ref.watch(doseRepositoryProvider).watchDosesOn(day),
);
final _rawEntriesOnProvider = StreamProvider.autoDispose.family<List<RawEntry>, DateTime>(
  (ref, day) => ref.watch(doseRepositoryProvider).watchRawEntriesOn(day),
);
final _recentRegimenProvider = StreamProvider.autoDispose.family<List<Regimen>, DateTime>(
  (ref, today) => ref
      .watch(doseRepositoryProvider)
      .watchRegimenBetween(
        DateTime(today.year, today.month, today.day - missedLookbackDays),
        today,
      ),
);
final _recentDosesProvider = StreamProvider.autoDispose.family<List<DoseLog>, DateTime>(
  (ref, today) => ref
      .watch(doseRepositoryProvider)
      .watchDosesBetween(DateTime(today.year, today.month, today.day - missedLookbackDays), today),
);
final _recentEntriesProvider = StreamProvider.autoDispose.family<List<RawEntry>, DateTime>(
  (ref, today) => ref
      .watch(doseRepositoryProvider)
      .watchRawEntriesSince(DateTime(today.year, today.month, today.day - missedLookbackDays)),
);

/// The Meds tab.
class TodayScreen extends ConsumerStatefulWidget {
  /// The current time; tests inject one.
  final DateTime Function() clock;

  const TodayScreen({super.key, this.clock = DateTime.now});

  static const routeName = '/doses-today';

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  Timer? _boundaryTimer;

  @override
  void initState() {
    super.initState();
    _scheduleBoundary();
  }

  @override
  void dispose() {
    _boundaryTimer?.cancel();
    super.dispose();
  }

  /// Rebuilds at the next midnight or [slotCarryOverHour]:00, where "today" and
  /// the slots' default dates change.
  void _scheduleBoundary() {
    final now = widget.clock();
    final carry = DateTime(now.year, now.month, now.day, slotCarryOverHour);
    final next = now.isBefore(carry) ? carry : DateTime(now.year, now.month, now.day + 1);
    _boundaryTimer = Timer(next.difference(now), () {
      if (!mounted) {
        return;
      }
      setState(() {});
      _scheduleBoundary();
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    final now = widget.clock();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);

    final slots = ref.watch(_slotsProvider).value;
    final meds = ref.watch(_medicationsProvider).value;
    final regimenToday = ref.watch(_regimenOnProvider(today)).value;
    final regimenYesterday = ref.watch(_regimenOnProvider(yesterday)).value;
    final dosesToday = ref.watch(_dosesOnProvider(today)).value;
    final dosesYesterday = ref.watch(_dosesOnProvider(yesterday)).value;
    final entries = ref.watch(_rawEntriesOnProvider(today)).value;
    final recentRegimen = ref.watch(_recentRegimenProvider(today)).value;
    final recentDoses = ref.watch(_recentDosesProvider(today)).value;
    final recentEntries = ref.watch(_recentEntriesProvider(today)).value;

    final ready =
        slots != null &&
        meds != null &&
        regimenToday != null &&
        regimenYesterday != null &&
        dosesToday != null &&
        dosesYesterday != null &&
        entries != null &&
        recentRegimen != null &&
        recentDoses != null &&
        recentEntries != null;

    Widget body;
    if (!ready) {
      body = const Center(child: CircularProgressIndicator());
    } else if (slots.isEmpty) {
      body = _EmptyState(onOpenRoutine: () => _openRoutine(context));
    } else {
      // A regimen can be in force on one of the two days only
      final regimen = {
        for (final r in [...regimenYesterday, ...regimenToday]) r.id: r,
      }.values.toList();
      final logged = [...dosesYesterday, ...dosesToday];
      final missed = missedSlots(
        today: today,
        slots: slots,
        regimen: recentRegimen,
        medications: meds,
        doses: recentDoses,
        entries: recentEntries,
      );
      final ids = {for (final e in entries) e.id};
      final topLevel = entries.where((e) => e.parentId == null || !ids.contains(e.parentId));
      body = ListView(
        padding: const EdgeInsets.all(8),
        children: [
          const LogBox(),
          MissedPrompt(missed: missed, today: today),
          for (final slot in slots)
            _SlotCard(
              slot: slot,
              now: now,
              regimen: regimen,
              medications: meds,
              logged: logged,
            ),
          for (final e in topLevel)
            EntryCard(
              entry: e,
              replies: entries.where((r) => r.parentId == e.id).toList(),
              medications: meds,
              now: now,
            ),
          _SectionTitle(i18n.todayLoggedTitle),
          if (dosesToday.isEmpty) ListTile(title: Text(i18n.todayNothingLogged)),
          for (final dose in dosesToday) _DoseTile(dose: dose, medications: meds),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(i18n.todayTitle),
        actions: [
          IconButton(
            key: const Key('open-history'),
            icon: const Icon(Icons.history),
            tooltip: i18n.historyOpen,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => HistoryScreen(clock: widget.clock)),
            ),
          ),
          IconButton(
            key: const Key('open-routine'),
            icon: const Icon(Icons.tune),
            tooltip: i18n.todaySetUpRoutine,
            onPressed: () => _openRoutine(context),
          ),
        ],
      ),
      body: WidescreenWrapper(child: body),
    );
  }
}

void _openRoutine(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RoutineScreen()));
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onOpenRoutine;

  const _EmptyState({required this.onOpenRoutine});

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(i18n.todayNoSlots),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('empty-open-routine'),
            onPressed: onOpenRoutine,
            child: Text(i18n.todaySetUpRoutine),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

String _statusLabel(AppLocalizations i18n, String status) => switch (status) {
  'taken' => i18n.doseStatusTaken,
  'partial' => i18n.doseStatusPartial,
  'skipped' => i18n.doseStatusSkipped,
  'missed' => i18n.doseStatusMissed,
  _ => status,
};

String _amountText(BuildContext context, double amount, String unit) =>
    '${localizedNumberFormat(context).format(amount)} $unit';

class _SlotCard extends ConsumerStatefulWidget {
  final DoseSlot slot;
  final DateTime now;
  final List<Regimen> regimen;
  final List<Medication> medications;
  final List<DoseLog> logged;

  const _SlotCard({
    required this.slot,
    required this.now,
    required this.regimen,
    required this.medications,
    required this.logged,
  });

  @override
  ConsumerState<_SlotCard> createState() => _SlotCardState();
}

class _SlotCardState extends ConsumerState<_SlotCard> {
  bool _saving = false;

  Future<void> _save(List<DoseDraft> drafts) async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(doseRepositoryProvider);
      for (final d in drafts) {
        await repo.logDose(
          medicationId: d.medicationId,
          regimenId: d.regimenId,
          date: d.date,
          takenAt: d.takenAt,
          plannedAmount: d.plannedAmount,
          amount: d.amount,
          unit: d.unit,
          status: d.status,
          source: d.source,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final now = widget.now;
    final regimen = widget.regimen;
    final medications = widget.medications;
    final logged = widget.logged;
    final i18n = AppLocalizations.of(context);
    final slotDate = defaultSlotDate(
      slot,
      now,
      regimen: regimen,
      medications: medications,
      logged: logged,
    );
    final items = slotItems(
      slot: slot,
      date: slotDate,
      regimen: regimen,
      medications: medications,
    );
    final doneOn = {
      for (final l in logged)
        if (l.regimenId != null && DateUtils.isSameDay(l.date, slotDate)) l.regimenId!: l,
    };
    final drafts = oneTapDrafts(
      slot: slot,
      slotDate: slotDate,
      regimen: regimen,
      medications: medications,
      logged: logged,
      now: now,
    );
    final names = {for (final m in medications) m.id: m.name};
    final isToday = DateUtils.isSameDay(slotDate, now);

    return Card(
      key: Key('today-slot-${slot.name}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(slot.name, style: Theme.of(context).textTheme.titleMedium),
            if (!isToday) Text(i18n.todayYesterdaySlot(slot.name)),
            const SizedBox(height: 4),
            for (final item in items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(names[item.medicationId] ?? ''),
                subtitle: Text(_amountText(context, item.amount, item.unit)),
                trailing: doneOn[item.id] == null
                    ? Text(i18n.todayNotLogged)
                    : _StatusChip(doneOn[item.id]!.status),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: Key('took-as-planned-${slot.name}'),
                onPressed: drafts.isEmpty || _saving ? null : () => _save(drafts),
                child: Text(i18n.todayTookAsPlanned),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;

  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) =>
      Chip(label: Text(_statusLabel(AppLocalizations.of(context), status)));
}

class _DoseTile extends StatelessWidget {
  final DoseLog dose;
  final List<Medication> medications;

  const _DoseTile({required this.dose, required this.medications});

  @override
  Widget build(BuildContext context) {
    final name = medications.where((m) => m.id == dose.medicationId).firstOrNull?.name ?? '';
    final skippedOrMissed = dose.status == 'skipped' || dose.status == 'missed';
    return ListTile(
      key: Key('dose-${dose.id}'),
      title: Text(name),
      subtitle: skippedOrMissed ? null : Text(_amountText(context, dose.amount, dose.unit)),
      trailing: _StatusChip(dose.status),
    );
  }
}
