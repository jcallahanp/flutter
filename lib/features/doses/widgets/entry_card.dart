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
 * One typed entry: its text, the doses the server made from it, its state,
 * the server's question with a reply box, and Undo.
 */

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wger/core/error_dialogs.dart';
import 'package:wger/core/formatting/formatting.dart';
import 'package:wger/features/doses/logic/missed.dart';
import 'package:wger/features/doses/logic/one_tap.dart';
import 'package:wger/features/doses/models/dose_log.dart';
import 'package:wger/features/doses/models/dose_slot.dart';
import 'package:wger/features/doses/models/medication.dart';
import 'package:wger/features/doses/models/parse_result.dart';
import 'package:wger/features/doses/models/raw_entry.dart';
import 'package:wger/features/doses/models/regimen.dart';
import 'package:wger/features/doses/providers/dose_repository.dart';
import 'package:wger/l10n/generated/app_localizations.dart';

/// The reply that confirms an `add_medication` proposal.
const addMedicationReply = 'yes, add it as an as-needed med';

final _dosesOfEntryProvider = StreamProvider.autoDispose.family<List<DoseLog>, String>(
  (ref, id) => ref.watch(doseRepositoryProvider).watchDosesOfEntry(id),
);
final _regimenOnProvider = StreamProvider.autoDispose.family<List<Regimen>, DateTime>(
  (ref, day) => ref.watch(doseRepositoryProvider).watchRegimenOn(day),
);
final _dosesOnProvider = StreamProvider.autoDispose.family<List<DoseLog>, DateTime>(
  (ref, day) => ref.watch(doseRepositoryProvider).watchDosesOn(day),
);
final _parseResultProvider = StreamProvider.autoDispose.family<ParseResult?, String>(
  (ref, id) => ref.watch(doseRepositoryProvider).watchParseResultFor(id),
);

class EntryCard extends ConsumerStatefulWidget {
  final RawEntry entry;

  /// The entries that answer each entry, by parent id; the card renders its
  /// replies, and theirs, recursively
  final Map<String, List<RawEntry>> repliesOf;
  final List<Medication> medications;
  final List<DoseSlot> slots;

  /// The current time, for doses logged by a proposal
  final DateTime now;

  const EntryCard({
    super.key,
    required this.entry,
    this.repliesOf = const {},
    required this.medications,
    this.slots = const [],
    required this.now,
  });

  @override
  ConsumerState<EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends ConsumerState<EntryCard> {
  final _reply = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reply.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _sendReply(String text) async {
    if (text.trim().isEmpty) {
      return;
    }
    await _run(() async {
      try {
        await ref
            .read(doseRepositoryProvider)
            .createRawEntry(text.trim(), parentId: widget.entry.id);
        _reply.clear();
      } catch (e, st) {
        if (mounted) {
          showGeneralErrorDialog(e, st, context: context);
        }
      }
    });
  }

  /// The calendar day of a proposal's `date`, only from the last
  /// [missedLookbackDays] days up to today: a parser slip must not write
  /// into the future or far back.
  DateTime? _proposalDate(Object? text) {
    final parsed = text is String ? DateTime.tryParse(text) : null;
    if (parsed == null) {
      return null;
    }
    final today = DateTime(widget.now.year, widget.now.month, widget.now.day);
    final date = DateTime(parsed.year, parsed.month, parsed.day);
    final oldest = DateTime(today.year, today.month, today.day - missedLookbackDays);
    return date.isBefore(oldest) || date.isAfter(today) ? null : date;
  }

  Future<void> _markRestTaken(String slotId, DateTime date) => _run(
    () => ref
        .read(doseRepositoryProvider)
        .logRestTaken(slotId: slotId, date: date, now: widget.now, rawEntryId: widget.entry.id),
  );

  Future<void> _undo() async {
    final i18n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.entryUndoTitle),
        content: Text(i18n.entryUndoBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(i18n.cancel)),
          FilledButton(
            key: const Key('entry-undo-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(i18n.entryUndo),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(doseRepositoryProvider).deleteDosesOf(widget.entry.id);
    }
  }

  String _stateLine(AppLocalizations i18n) => switch (widget.entry.state) {
    'pending' => i18n.entryWaiting,
    'no_key' => i18n.entryNoKey,
    'over_limit' => i18n.entryOverLimit,
    'failed' => i18n.entryFailed,
    'needs_answer' => i18n.entryNeedsAnswer,
    _ => i18n.entryRead,
  };

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context);
    final entry = widget.entry;
    final doses = ref.watch(_dosesOfEntryProvider(entry.id)).value ?? const <DoseLog>[];
    final result = ref.watch(_parseResultProvider(entry.id)).value;
    final question = entry.state == 'needs_answer' ? result?.question ?? '' : '';
    final replies = widget.repliesOf[entry.id] ?? const <RawEntry>[];
    final answered = replies.isNotEmpty;
    final proposal = answered ? null : result?.proposal;
    final type = proposal?['type'];
    // mark_rest_taken writes one_tap doses linked to this entry; once there,
    // the proposal is done
    final restDone = doses.any((d) => d.source == 'one_tap');
    final restSlot = type == 'mark_rest_taken'
        ? widget.slots.where((s) => s.id == proposal?['slot_id']).firstOrNull
        : null;
    final restDate = type == 'mark_rest_taken' ? _proposalDate(proposal?['date']) : null;
    // Nothing to offer once every item of the slot has a dose that day
    final restLogged = restSlot != null && restDate != null
        ? ref.watch(_dosesOnProvider(restDate)).value
        : null;
    final restRegimen = restSlot != null && restDate != null
        ? ref.watch(_regimenOnProvider(restDate)).value
        : null;
    final restOpen =
        restSlot != null &&
        restDate != null &&
        restLogged != null &&
        restRegimen != null &&
        unloggedItems(
          slot: restSlot,
          date: restDate,
          regimen: restRegimen,
          medications: widget.medications,
          logged: restLogged,
        ).isNotEmpty;
    final locale = Localizations.localeOf(context).toString();
    String dayLabel(DateTime d) {
      final today = DateTime(widget.now.year, widget.now.month, widget.now.day);
      if (d == today) {
        return i18n.entryDayToday;
      }
      return d == DateTime(today.year, today.month, today.day - 1)
          ? i18n.missedPromptYesterday
          : DateFormat.MMMEd(locale).format(d);
    }

    final names = {for (final m in widget.medications) m.id: m.name};

    return Card(
      key: Key('entry-${entry.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.text),
            for (final d in doses)
              ListTile(
                key: Key('entry-dose-${d.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(names[d.medicationId] ?? ''),
                subtitle: d.status == 'skipped' || d.status == 'missed'
                    ? null
                    : Text('${localizedNumberFormat(context).format(d.amount)} ${d.unit}'),
                trailing: Text(_statusText(i18n, d.status)),
              ),
            const SizedBox(height: 4),
            Text(_stateLine(i18n), style: Theme.of(context).textTheme.bodySmall),
            if (question.isNotEmpty && !answered) ...[
              const SizedBox(height: 8),
              Text(question, key: const Key('entry-question')),
              if (restSlot != null && restDate != null && restOpen && !restDone)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('entry-mark-rest-taken'),
                    onPressed: _busy ? null : () => _markRestTaken(restSlot.id, restDate),
                    child: Text(i18n.entryMarkRestTaken(restSlot.name, dayLabel(restDate))),
                  ),
                ),
              if (type == 'add_medication')
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('entry-add-medication'),
                    onPressed: _busy ? null : () => _sendReply(addMedicationReply),
                    child: Text(i18n.entryAddMedication),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('entry-reply-field'),
                      controller: _reply,
                      maxLength: rawEntryMaxLength,
                      decoration: InputDecoration(hintText: i18n.entryReplyHint),
                    ),
                  ),
                  IconButton(
                    key: const Key('entry-reply-send'),
                    icon: const Icon(Icons.send),
                    tooltip: i18n.entryReplySend,
                    onPressed: _busy || _reply.text.trim().isEmpty
                        ? null
                        : () => _sendReply(_reply.text),
                  ),
                ],
              ),
            ],
            if (doses.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('entry-undo'),
                  onPressed: _undo,
                  child: Text(i18n.entryUndo),
                ),
              ),
            for (final reply in replies)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: EntryCard(
                  entry: reply,
                  repliesOf: widget.repliesOf,
                  medications: widget.medications,
                  slots: widget.slots,
                  now: widget.now,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _statusText(AppLocalizations i18n, String status) => switch (status) {
  'taken' => i18n.doseStatusTaken,
  'partial' => i18n.doseStatusPartial,
  'skipped' => i18n.doseStatusSkipped,
  'missed' => i18n.doseStatusMissed,
  _ => status,
};
