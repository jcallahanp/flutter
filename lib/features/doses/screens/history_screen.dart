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
 * History: the doses of a chosen day, with edit and delete.
 */

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/core/formatting/formatting.dart';
import 'package:wger/core/wide_screen_wrapper.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

const _statuses = ['taken', 'partial', 'skipped', 'missed'];

String _statusLabel(AppLocalizations i18n, String status) => switch (status) {
  'taken' => i18n.doseStatusTaken,
  'partial' => i18n.doseStatusPartial,
  'skipped' => i18n.doseStatusSkipped,
  'missed' => i18n.doseStatusMissed,
  _ => status,
};

class HistoryScreen extends ConsumerStatefulWidget {
  /// The current time; tests inject one.
  final DateTime Function() clock;

  const HistoryScreen({super.key, this.clock = DateTime.now});

  static const routeName = '/doses-history';

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    final now = widget.clock();
    _day = DateTime(now.year, now.month, now.day);
  }

  Future<void> _pickDay() async {
    final now = widget.clock();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null) {
      setState(() => _day = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _edit(DoseLog dose, String name) async {
    final result = await showDialog<_Edit>(
      context: context,
      builder: (_) => _EditDialog(dose: dose, name: name),
    );
    if (result != null) {
      await ref
          .read(doseRepositoryProvider)
          .updateDose(
            id: dose.id,
            status: Value(result.status),
            amount: Value(result.amount),
            source: const Value('manual'),
          );
    }
  }

  Future<void> _delete(DoseLog dose) async {
    final i18n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.historyDeleteTitle),
        content: Text(i18n.historyDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(i18n.cancel)),
          FilledButton(
            key: const Key('history-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(doseRepositoryProvider).deleteDose(dose.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    final repo = ref.watch(doseRepositoryProvider);
    final locale = Localizations.localeOf(context).toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(i18n.historyTitle),
        actions: [
          TextButton.icon(
            key: const Key('history-pick-day'),
            icon: const Icon(Icons.calendar_today),
            label: Text(DateFormat.yMMMEd(locale).format(_day)),
            onPressed: _pickDay,
          ),
        ],
      ),
      body: WidescreenWrapper(
        child: StreamBuilder<List<Medication>>(
          stream: repo.watchMedications(),
          builder: (context, meds) => StreamBuilder<List<DoseLog>>(
            key: ValueKey(_day),
            stream: repo.watchDosesOn(_day),
            builder: (context, doses) {
              if (!doses.hasData || !meds.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final names = {for (final m in meds.data!) m.id: m.name};
              if (doses.data!.isEmpty) {
                return Center(child: Text(i18n.historyNothing));
              }
              return ListView(
                children: [
                  for (final d in doses.data!)
                    ListTile(
                      key: Key('history-dose-${d.id}'),
                      title: Text(names[d.medicationId] ?? ''),
                      subtitle: Text(
                        '${_statusLabel(i18n, d.status)} · '
                        '${localizedNumberFormat(context).format(d.amount)} ${d.unit}',
                      ),
                      onTap: () => _edit(d, names[d.medicationId] ?? ''),
                      trailing: IconButton(
                        key: Key('history-delete-${d.id}'),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: i18n.delete,
                        onPressed: () => _delete(d),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Edit {
  final String status;
  final double amount;

  const _Edit(this.status, this.amount);
}

class _EditDialog extends StatefulWidget {
  final DoseLog dose;
  final String name;

  const _EditDialog({required this.dose, required this.name});

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late String _status = widget.dose.status;
  late final TextEditingController _amount;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: _plain(widget.dose.amount));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String _plain(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  void _setStatus(String status) {
    setState(() {
      _status = status;
      _error = null;
      if (status == 'skipped' || status == 'missed') {
        _amount.text = '0';
      }
    });
  }

  void _save() {
    final i18n = AppLocalizations.of(context);
    final value = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    if (value == null || value < 0) {
      setState(() => _error = i18n.historyAmountInvalid);
      return;
    }
    if ((_status == 'skipped' || _status == 'missed') && value != 0) {
      setState(() => _error = i18n.historyAmountZero);
      return;
    }
    Navigator.pop(context, _Edit(_status, value));
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text('${i18n.historyEditTitle}: ${widget.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final s in _statuses)
                ChoiceChip(
                  key: Key('history-status-$s'),
                  label: Text(_statusLabel(i18n, s)),
                  selected: _status == s,
                  onSelected: (_) => _setStatus(s),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('history-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '${i18n.amount} (${widget.dose.unit})',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(i18n.cancel)),
        FilledButton(
          key: const Key('history-save'),
          onPressed: _save,
          child: Text(i18n.save),
        ),
      ],
    );
  }
}
