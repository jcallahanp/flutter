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
import 'package:material_ui/material_ui.dart';
import 'package:wger/core/formatting/formatting.dart';
import 'package:wger/core/wide_screen_wrapper.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/regimen.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/features/doses/widgets/medication_form.dart';
import 'package:wger/features/doses/widgets/slot_form.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

final _slotsProvider = StreamProvider.autoDispose<List<DoseSlot>>(
  (ref) => ref.watch(doseRepositoryProvider).watchSlots(),
);
final _medicationsProvider = StreamProvider.autoDispose<List<Medication>>(
  (ref) => ref.watch(doseRepositoryProvider).watchMedications(),
);
final _regimensProvider = StreamProvider.autoDispose<List<Regimen>>(
  (ref) => ref.watch(doseRepositoryProvider).watchOpenRegimens(),
);

/// Sets up the routine: the slots of the day, the medications, and which
/// medication goes in which slot with what amount.
class RoutineScreen extends ConsumerWidget {
  const RoutineScreen({super.key});

  static const routeName = '/doses-routine';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = AppLocalizations.of(context);
    final slots = ref.watch(_slotsProvider).value;
    final meds = ref.watch(_medicationsProvider).value;
    final regimens = ref.watch(_regimensProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(i18n.routineTitle)),
      body: WidescreenWrapper(
        child: slots == null || meds == null || regimens == null
            ? const Center(child: CircularProgressIndicator())
            : _RoutineList(slots: slots, meds: meds, regimens: regimens),
      ),
    );
  }
}

class _RoutineList extends ConsumerWidget {
  final List<DoseSlot> slots;
  final List<Medication> meds;
  final List<Regimen> regimens;

  const _RoutineList({required this.slots, required this.meds, required this.regimens});

  /// Open regimens of active, non-one-off medications in [slot].
  List<({Regimen regimen, Medication med})> _rowsOf(DoseSlot slot, Map<String, Medication> byId) {
    final rows = <({Regimen regimen, Medication med})>[];
    for (final regimen in regimens) {
      final med = byId[regimen.medicationId];
      if (regimen.slotId == slot.id && med != null && med.active && med.kind != 'one_off') {
        rows.add((regimen: regimen, med: med));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = AppLocalizations.of(context);
    final byId = {for (final med in meds) med.id: med};
    final asNeeded = meds.where((m) => m.kind == 'as_needed').toList();
    final routine = meds.where((m) => m.kind == 'routine').toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (slots.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(i18n.routineNoSlots),
          ),
        for (final slot in slots)
          _SlotCard(
            slot: slot,
            rows: _rowsOf(slot, byId),
            slots: slots,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text(i18n.routineAddSlot),
            onPressed: () => showSlotForm(context, slots: slots),
          ),
        ),
        if (asNeeded.isNotEmpty) ...[
          _SectionTitle(i18n.routineAsNeeded),
          for (final med in asNeeded) _MedicationTile(med: med, slots: slots),
        ],
        _SectionTitle(i18n.routineMedications),
        for (final med in routine) _MedicationTile(med: med, slots: slots),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text(i18n.routineAddMedication),
            onPressed: () => showMedicationForm(context, slots: slots),
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

String _number(BuildContext context, double value) => localizedNumberFormat(context).format(value);

/// "500 mg" or just the unit when there is no strength.
String _strengthText(BuildContext context, Medication med) =>
    med.strength == null ? med.unit : '${_number(context, med.strength!)} ${med.unit}';

class _SlotCard extends StatelessWidget {
  final DoseSlot slot;
  final List<({Regimen regimen, Medication med})> rows;
  final List<DoseSlot> slots;

  const _SlotCard({required this.slot, required this.rows, required this.slots});

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Card(
      key: Key('slot-${slot.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(slot.name, style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(formatSlotTime(slot.usualTime)),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              tooltip: i18n.routineEditSlot,
              onPressed: () => showSlotForm(context, slot: slot, slots: slots),
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(i18n.routineNothingInSlot),
            ),
          for (final row in rows)
            ListTile(
              title: Text('${row.med.name} ${_strengthText(context, row.med)}'),
              subtitle: Text('${_number(context, row.regimen.amount)} ${row.regimen.unit}'),
              trailing: IconButton(
                key: Key('end-regimen-${row.med.name}'),
                icon: const Icon(Icons.event_busy),
                tooltip: i18n.routineEnd,
                onPressed: () => _confirmEnd(context, row.med, row.regimen),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmEnd(BuildContext context, Medication med, Regimen regimen) async {
    final i18n = AppLocalizations.of(context);
    final repo = ProviderScope.containerOf(context).read(doseRepositoryProvider);
    final confirmed = await _confirm(
      context,
      title: i18n.routineEndTitle,
      body: i18n.routineEndBody(med.name, slot.name),
      action: i18n.routineEnd,
    );
    if (confirmed) {
      await repo.endRegimen(regimen.id, DateTime.now());
    }
  }
}

class _MedicationTile extends StatelessWidget {
  final Medication med;
  final List<DoseSlot> slots;

  const _MedicationTile({required this.med, required this.slots});

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    final detail = [
      _strengthText(context, med),
      if (med.form.isNotEmpty) med.form,
    ].join(' · ');
    return ListTile(
      title: Text(med.name),
      subtitle: Text(detail),
      leading: med.active ? null : Chip(label: Text(i18n.routineInactive)),
      trailing: Wrap(
        children: [
          if (med.active && med.kind == 'routine' && slots.isNotEmpty)
            IconButton(
              key: Key('put-in-slot-${med.name}'),
              icon: const Icon(Icons.playlist_add),
              tooltip: i18n.routinePutInSlot,
              onPressed: () => showRegimenForm(context, medication: med, slots: slots),
            ),
          IconButton(
            key: Key('edit-medication-${med.name}'),
            icon: const Icon(Icons.edit),
            tooltip: i18n.routineEditMedication,
            onPressed: () => showMedicationForm(context, medication: med, slots: slots),
          ),
          if (med.active)
            IconButton(
              key: Key('deactivate-${med.name}'),
              icon: const Icon(Icons.block),
              tooltip: i18n.routineDeactivate,
              onPressed: () => _confirmDeactivate(context),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDeactivate(BuildContext context) async {
    final i18n = AppLocalizations.of(context);
    final repo = ProviderScope.containerOf(context).read(doseRepositoryProvider);
    final confirmed = await _confirm(
      context,
      title: i18n.routineDeactivateTitle,
      body: i18n.routineDeactivateBody(med.name),
      action: i18n.routineDeactivate,
    );
    if (confirmed) {
      await repo.deactivateMedication(med.id, DateTime.now());
    }
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final i18n = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(i18n.cancel)),
        TextButton(
          key: const Key('confirm-button'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}
