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
import 'package:wger/core/widgets/form_submit_button.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

/// "HH:MM" as shown and entered.
String formatSlotTime(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

TimeOfDay? parseSlotTime(String text) {
  final match = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(text.trim());
  if (match == null) {
    return null;
  }
  return TimeOfDay(hour: int.parse(match.group(1)!), minute: int.parse(match.group(2)!));
}

/// Shows the slot form in a dialog. [slots] are all current slots.
Future<void> showSlotForm(BuildContext context, {DoseSlot? slot, required List<DoseSlot> slots}) {
  final i18n = AppLocalizations.of(context);
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(slot == null ? i18n.routineAddSlot : i18n.routineEditSlot),
      content: SingleChildScrollView(
        child: SlotForm(slot: slot, slots: slots),
      ),
    ),
  );
}

/// Create/edit form for a dose slot: name, usual time and order.
class SlotForm extends ConsumerStatefulWidget {
  final DoseSlot? slot;
  final List<DoseSlot> slots;

  const SlotForm({this.slot, required this.slots, super.key});

  @override
  ConsumerState<SlotForm> createState() => _SlotFormState();
}

class _SlotFormState extends ConsumerState<SlotForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _time;
  late final TextEditingController _order;

  @override
  void initState() {
    super.initState();
    final slot = widget.slot;
    _name = TextEditingController(text: slot?.name ?? '');
    _time = TextEditingController(text: slot == null ? '' : formatSlotTime(slot.usualTime));
    _order = TextEditingController(text: (slot?.order ?? widget.slots.length).toString());
  }

  @override
  void dispose() {
    _name.dispose();
    _time.dispose();
    _order.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            key: const Key('slotNameInput'),
            controller: _name,
            decoration: InputDecoration(labelText: i18n.routineSlotName),
            maxLength: 40,
            validator: (value) {
              final name = value?.trim() ?? '';
              if (name.isEmpty) {
                return i18n.enterValue;
              }
              final taken = widget.slots.any((s) => s.name == name && s.id != widget.slot?.id);
              return taken ? i18n.routineSlotExists : null;
            },
          ),
          TextFormField(
            key: const Key('slotTimeInput'),
            controller: _time,
            keyboardType: TextInputType.datetime,
            decoration: InputDecoration(
              labelText: i18n.routineUsualTime,
              suffixIcon: IconButton(
                icon: const Icon(Icons.schedule),
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: parseSlotTime(_time.text) ?? const TimeOfDay(hour: 8, minute: 0),
                  );
                  if (picked != null) {
                    _time.text = formatSlotTime(picked);
                  }
                },
              ),
            ),
            validator: (value) =>
                parseSlotTime(value ?? '') == null ? i18n.routineInvalidTime : null,
          ),
          TextFormField(
            key: const Key('slotOrderInput'),
            controller: _order,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: i18n.routineOrder),
            validator: (value) => int.tryParse(value ?? '') == null ? i18n.enterValidNumber : null,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(i18n.cancel),
              ),
              FormSubmitButton(
                key: const Key(SUBMIT_BUTTON_KEY_NAME),
                label: i18n.save,
                onPressed: () async {
                  if (!_form.currentState!.validate()) {
                    return;
                  }
                  await ref
                      .read(doseRepositoryProvider)
                      .saveSlot(
                        id: widget.slot?.id,
                        name: _name.text.trim(),
                        usualTime: parseSlotTime(_time.text)!,
                        order: int.parse(_order.text),
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
