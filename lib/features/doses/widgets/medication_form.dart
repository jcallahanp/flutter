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
import 'package:wger/core/consts.dart';
import 'package:wger/core/widgets/decimal_input.dart';
import 'package:wger/core/widgets/form_submit_button.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

/// Shows the medication form in a dialog. A new routine medication can be put
/// in one of [slots] right away.
Future<void> showMedicationForm(
  BuildContext context, {
  Medication? medication,
  required List<DoseSlot> slots,
}) {
  final i18n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(medication == null ? i18n.routineAddMedication : i18n.routineEditMedication),
      content: SingleChildScrollView(
        child: MedicationForm(medication: medication, slots: slots),
      ),
    ),
  );
}

/// Shows the form that puts [medication] in a slot.
Future<void> showRegimenForm(
  BuildContext context, {
  required Medication medication,
  required List<DoseSlot> slots,
}) {
  final i18n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(i18n.routinePutInSlot),
      content: SingleChildScrollView(
        child: RegimenForm(medication: medication, slots: slots),
      ),
    ),
  );
}

/// The slot, amount and unit fields shared by the two forms. The state holds
/// the entered values, read by the form that embeds it.
class _PlacementFields extends StatelessWidget {
  final List<DoseSlot> slots;
  final String? slotId;

  /// Offer "No slot" as a choice
  final bool optional;
  final num? amount;
  final TextEditingController unit;
  final ValueChanged<String?> onSlotChanged;
  final ValueChanged<num?> onAmountChanged;
  final String? error;

  const _PlacementFields({
    required this.slots,
    required this.slotId,
    required this.optional,
    required this.amount,
    required this.unit,
    required this.onSlotChanged,
    required this.onAmountChanged,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Column(
      children: [
        DropdownButtonFormField<String?>(
          key: const Key('slotInput'),
          initialValue: slotId,
          decoration: InputDecoration(labelText: i18n.routineSlot),
          items: [
            if (optional) DropdownMenuItem(value: null, child: Text(i18n.routineNoSlot)),
            for (final slot in slots) DropdownMenuItem(value: slot.id, child: Text(slot.name)),
          ],
          onChanged: onSlotChanged,
        ),
        if (slotId != null) ...[
          DecimalInputWidget(
            key: const Key('medAmountInput'),
            value: amount,
            labelText: i18n.amount,
            isRequired: true,
            min: 0,
            max: 9999999.999,
            onChanged: onAmountChanged,
          ),
          if (error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          TextFormField(
            key: const Key('regimenUnitInput'),
            controller: unit,
            decoration: InputDecoration(labelText: i18n.unit),
            maxLength: 20,
            validator: (value) => value == null || value.trim().isEmpty ? i18n.enterValue : null,
          ),
        ],
      ],
    );
  }
}

Widget _buttons(BuildContext context, Future<void> Function() onSave) {
  final i18n = AppLocalizations.of(context);
  return Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(i18n.cancel)),
      FormSubmitButton(
        key: const Key(SUBMIT_BUTTON_KEY_NAME),
        label: i18n.save,
        onPressed: onSave,
      ),
    ],
  );
}

/// Create/edit form for a medication: name, strength, unit, form and kind.
/// A new routine medication can also be put in a slot with an amount.
class MedicationForm extends ConsumerStatefulWidget {
  final Medication? medication;
  final List<DoseSlot> slots;

  const MedicationForm({this.medication, required this.slots, super.key});

  @override
  ConsumerState<MedicationForm> createState() => _MedicationFormState();
}

class _MedicationFormState extends ConsumerState<MedicationForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _formName;
  final _regimenUnit = TextEditingController();
  num? _strength;
  num? _amount;
  late String _kind;
  String? _slotId;
  String? _placementError;

  @override
  void initState() {
    super.initState();
    final med = widget.medication;
    _name = TextEditingController(text: med?.name ?? '');
    _unit = TextEditingController(text: med?.unit ?? '');
    _formName = TextEditingController(text: med?.form ?? '');
    _strength = med?.strength;
    _kind = med?.kind ?? 'routine';
    _slotId = null;
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _formName.dispose();
    _regimenUnit.dispose();
    super.dispose();
  }

  bool get _offersSlot =>
      widget.medication == null && _kind == 'routine' && widget.slots.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            key: const Key('medNameInput'),
            controller: _name,
            decoration: InputDecoration(labelText: i18n.name),
            maxLength: 100,
            validator: (value) => value == null || value.trim().isEmpty ? i18n.enterValue : null,
          ),
          DecimalInputWidget(
            key: const Key('medStrengthInput'),
            value: _strength,
            labelText: i18n.routineStrength,
            min: 0,
            max: 9999999.999,
            onChanged: (value) => _strength = value,
          ),
          TextFormField(
            key: const Key('medUnitInput'),
            controller: _unit,
            decoration: InputDecoration(labelText: i18n.unit),
            maxLength: 20,
            validator: (value) => value == null || value.trim().isEmpty ? i18n.enterValue : null,
          ),
          TextFormField(
            key: const Key('medFormInput'),
            controller: _formName,
            decoration: InputDecoration(labelText: i18n.routineForm),
            maxLength: 20,
          ),
          DropdownButtonFormField<String>(
            key: const Key('medKindInput'),
            initialValue: _kind,
            decoration: InputDecoration(labelText: i18n.routineKind),
            items: [
              DropdownMenuItem(value: 'routine', child: Text(i18n.routineKindRoutine)),
              DropdownMenuItem(value: 'as_needed', child: Text(i18n.routineKindAsNeeded)),
              DropdownMenuItem(value: 'one_off', child: Text(i18n.routineKindOneOff)),
            ],
            onChanged: (value) => setState(() => _kind = value ?? _kind),
          ),
          if (_offersSlot)
            _PlacementFields(
              slots: widget.slots,
              slotId: _slotId,
              optional: true,
              amount: _amount,
              unit: _regimenUnit,
              onSlotChanged: (value) => setState(() => _slotId = value),
              onAmountChanged: (value) => _amount = value,
              error: _placementError,
            ),
          const SizedBox(height: 8),
          _buttons(context, _save),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    if (_offersSlot && _slotId != null && (_amount ?? 0) <= 0) {
      setState(() => _placementError = AppLocalizations.of(context).enterValidNumber);
      return;
    }
    final repo = ref.read(doseRepositoryProvider);
    final med = widget.medication;
    final id = await repo.saveMedication(
      id: med?.id,
      name: _name.text.trim(),
      strength: _strength?.toDouble(),
      unit: _unit.text.trim(),
      form: _formName.text.trim(),
      kind: _kind,
      active: med?.active ?? true,
    );
    // A medication that is no longer routine is no longer in any slot
    if (med != null && med.kind == 'routine' && _kind != 'routine') {
      await repo.endOpenRegimensOf(id, DateTime.now());
    }
    if (_offersSlot && _slotId != null) {
      await repo.saveRegimen(
        medicationId: id,
        slotId: _slotId!,
        amount: _amount!.toDouble(),
        unit: _regimenUnit.text.trim(),
        startDate: DateTime.now(),
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

/// Puts an existing medication in a slot with an amount, starting today.
class RegimenForm extends ConsumerStatefulWidget {
  final Medication medication;
  final List<DoseSlot> slots;

  const RegimenForm({required this.medication, required this.slots, super.key});

  @override
  ConsumerState<RegimenForm> createState() => _RegimenFormState();
}

class _RegimenFormState extends ConsumerState<RegimenForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _unit;
  num? _amount;
  late String? _slotId;
  String? _placementError;

  @override
  void initState() {
    super.initState();
    _unit = TextEditingController(text: widget.medication.unit);
    _slotId = widget.slots.isEmpty ? null : widget.slots.first.id;
  }

  @override
  void dispose() {
    _unit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.medication.name, style: Theme.of(context).textTheme.titleMedium),
          _PlacementFields(
            slots: widget.slots,
            slotId: _slotId,
            optional: false,
            amount: _amount,
            unit: _unit,
            onSlotChanged: (value) => setState(() => _slotId = value),
            onAmountChanged: (value) => _amount = value,
            error: _placementError,
          ),
          const SizedBox(height: 8),
          _buttons(context, () async {
            if (_slotId == null || !_form.currentState!.validate()) {
              return;
            }
            final i18n = AppLocalizations.of(context);
            if ((_amount ?? 0) <= 0) {
              setState(() => _placementError = i18n.enterValidNumber);
              return;
            }
            try {
              await ref
                  .read(doseRepositoryProvider)
                  .saveRegimen(
                    medicationId: widget.medication.id,
                    slotId: _slotId!,
                    amount: _amount!.toDouble(),
                    unit: _unit.text.trim(),
                    startDate: DateTime.now(),
                  );
            } on ArgumentError {
              setState(() => _placementError = i18n.routineAlreadyInSlot);
              return;
            }
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          }),
        ],
      ),
    );
  }
}
